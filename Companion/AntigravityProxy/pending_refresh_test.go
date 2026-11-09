package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestXAIRotatedRefreshIsSavedBeforeIdentityAndRetriedWithoutRotation(t *testing.T) {
	original := fixtureDeviceCredential("xai")
	original.ExpiresAt = time.Now().Unix()
	p := newPool([]savedAccount{{Credential: original, Enabled: true, ConcurrencyLimit: 1}})
	e := p.entries[original.AccountID]
	b := newXAIBackend("").(*xaiBackend)
	tokenCalls, identityCalls, pendingSaves, activeSaves := 0, 0, 0, 0
	persist := func(_ context.Context, c credential, purpose, correlation string) error {
		switch purpose {
		case "refresh_pending":
			pendingSaves++
		case "refresh_promote":
			activeSaves++
		case "refresh_discard":
		default:
			t.Errorf("unexpected persistence purpose %q", purpose)
		}
		return nil
	}
	b.http = mockOAuthHTTP(func(r *http.Request) (*http.Response, error) {
		switch r.URL.String() {
		case xaiTokenEndpoint:
			tokenCalls++
			if tokenCalls > 1 {
				return adapterResponse(400, `{"error":"invalid_grant"}`), nil
			}
			return adapterResponse(200, `{"access_token":"synthetic-rotated-access","refresh_token":"synthetic-rotated-refresh","expires_in":3600}`), nil
		case xaiUserInfoEndpoint:
			identityCalls++
			if pendingSaves != 1 || e.credential != original {
				t.Error("rotated candidate was not durably staged before identity verification")
			}
			if r.Header.Get("Authorization") != "Bearer synthetic-rotated-access" {
				t.Error("identity verification did not reuse the staged access token")
			}
			if identityCalls == 1 {
				return adapterResponse(503, ""), nil
			}
			return adapterResponse(200, `{"sub":"fixture-account"}`), nil
		default:
			t.Fatal("unexpected endpoint")
			return nil, nil
		}
	})
	if _, err := p.prepare(context.Background(), e, b, persist); statusCode(err) != 503 {
		t.Error("identity outage did not retain its transient status")
	}
	if pendingSaves != 1 || activeSaves != 0 || e.credential != original {
		t.Error("identity outage lost the pending candidate or changed the active credential")
	}
	got, err := p.prepare(context.Background(), e, b, persist)
	if err != nil || got.AccessToken != "synthetic-rotated-access" || activeSaves != 1 || tokenCalls != 1 || identityCalls != 2 {
		t.Error("retry did not verify and promote the saved candidate without reusing the spent refresh token")
	}
}

type stagedFixtureBackend struct {
	fakeBackend
	begin  func(context.Context, credential) (credential, error)
	verify func(context.Context, credential) (credential, error)
}

func (b *stagedFixtureBackend) beginRefresh(ctx context.Context, c credential) (credential, error) {
	return b.begin(ctx, c)
}
func (b *stagedFixtureBackend) verifyRefresh(ctx context.Context, c credential) (credential, error) {
	return b.verify(ctx, c)
}

type pendingFixtureVault struct {
	active                       credential
	pending                      *pendingRefresh
	fail                         string
	stages, promotions, discards int
}

func (v *pendingFixtureVault) persist(_ context.Context, c credential, purpose, base string) error {
	if purpose == v.fail {
		return errors.New("fixture_keychain_unavailable")
	}
	next := pendingRefresh{BaseFingerprint: base, Credential: c}
	switch purpose {
	case "refresh_pending":
		if !next.validFor(v.active) || (v.pending != nil && *v.pending != next) {
			return errors.New("fixture_cas_failed")
		}
		v.pending = &next
		v.stages++
	case "refresh_promote":
		if v.pending == nil || *v.pending != next || (!next.validFor(v.active) && v.active != c) {
			return errors.New("fixture_cas_failed")
		}
		v.active = c
		v.promotions++
	case "refresh_discard":
		if v.pending != nil && *v.pending != next {
			return errors.New("fixture_cas_failed")
		}
		v.pending = nil
		v.discards++
	default:
		return errors.New("fixture_unexpected_purpose")
	}
	return nil
}
func pendingFixture(t *testing.T) (*pool, *poolEntry, *stagedFixtureBackend, *pendingFixtureVault, *int, *int) {
	t.Helper()
	c := fixtureDeviceCredential("xai")
	c.ExpiresAt = time.Now().Unix()
	p := newPool([]savedAccount{{Credential: c, Enabled: true, ConcurrencyLimit: 1}})
	v := &pendingFixtureVault{active: c}
	begin, verify := 0, 0
	b := &stagedFixtureBackend{}
	b.begin = func(_ context.Context, c credential) (credential, error) {
		begin++
		c.AccessToken = "synthetic-next-access"
		c.RefreshToken = "synthetic-next-refresh"
		c.ExpiresAt = time.Now().Add(time.Hour).Unix()
		return c, nil
	}
	b.verify = func(_ context.Context, c credential) (credential, error) { verify++; return c, nil }
	return p, p.entries[c.AccountID], b, v, &begin, &verify
}

func TestPendingRefreshRestartRetriesOnlySavedCandidate(t *testing.T) {
	p, e, b, v, begin, verify := pendingFixture(t)
	b.verify = func(_ context.Context, c credential) (credential, error) {
		*verify++
		return credential{}, upstreamError{status: 503}
	}
	for range 3 {
		if _, err := p.prepare(context.Background(), e, b, v.persist); statusCode(err) != 503 {
			t.Fatal("outage was not retained")
		}
	}
	if *begin != 1 || *verify != 3 || v.pending == nil || v.promotions != 0 || v.stages != 1 {
		t.Fatal("outage repeated token rotation or lost pending state")
	}
	// Serialize the same private bootstrap envelope used on native restart.
	bootstrap := startup{SchemaVersion: 1, ClientKey: testKey, Accounts: []savedAccount{{Credential: v.active, PendingRefresh: v.pending, Enabled: true, ConcurrencyLimit: 1}}}
	data, _ := json.Marshal(bootstrap)
	var rehydrated startup
	if json.Unmarshal(data, &rehydrated) != nil || rehydrated.validate() != nil {
		t.Fatal("pending bootstrap did not round-trip")
	}
	p = newPool(rehydrated.Accounts)
	e = p.entries[v.active.AccountID]
	b.begin = func(context.Context, credential) (credential, error) {
		t.Fatal("restart reused the spent refresh token")
		return credential{}, nil
	}
	b.verify = func(_ context.Context, c credential) (credential, error) {
		*verify++
		if c != v.pending.Credential {
			t.Fatal("restart verified another candidate")
		}
		return c, nil
	}
	got, err := p.prepare(context.Background(), e, b, v.persist)
	if err != nil || got != v.active || v.pending != nil || v.promotions != 1 || *verify != 4 {
		t.Fatal("restart did not promote the verified pending candidate")
	}
}

func TestPendingRefreshACKFailuresNeverExposeCandidate(t *testing.T) {
	for _, failure := range []string{"refresh_pending", "refresh_promote", "refresh_discard"} {
		t.Run(failure, func(t *testing.T) {
			p, e, b, v, begin, verify := pendingFixture(t)
			original := e.credential
			v.fail = failure
			got, err := p.prepare(context.Background(), e, b, v.persist)
			if failure == "refresh_discard" {
				if err != nil || got != v.active || got == original || e.pendingRefresh == nil {
					t.Fatal("cleanup failure discarded a verified durable active credential")
				}
			} else if err == nil || got != (credential{}) || e.credential != original || v.active != original {
				t.Fatal("failed ACK activated a candidate")
			}
			if failure == "refresh_pending" && *verify != 0 {
				t.Fatal("identity request ran before pending ACK")
			}
			beforeVerify := *verify
			v.fail = ""
			got, err = p.prepare(context.Background(), e, b, v.persist)
			if err != nil || got != v.active || v.pending != nil || e.pendingRefresh != nil || *begin != 1 {
				t.Fatal("retry did not reuse the existing candidate")
			}
			if failure == "refresh_discard" && *verify != beforeVerify {
				t.Fatal("cleanup retry reverified or rotated active credential")
			}
		})
	}
}

func TestPendingRefreshIdentityRejectionAndCAS(t *testing.T) {
	for _, scenario := range []string{"different-subject", "different-id-token", "changed-active"} {
		t.Run(scenario, func(t *testing.T) {
			p, e, b, v, _, _ := pendingFixture(t)
			original := e.credential
			b.verify = func(_ context.Context, c credential) (credential, error) {
				if scenario == "changed-active" {
					v.active.AccessToken = "synthetic-newer-active"
					return c, nil
				}
				return credential{}, upstreamError{status: 401}
			}
			if got, err := p.prepare(context.Background(), e, b, v.persist); err == nil || got != (credential{}) || e.credential != original || v.promotions != 0 {
				t.Fatal("unverified or stale candidate became active")
			}
			if scenario != "changed-active" && v.pending != nil {
				t.Fatal("rejected identity left a reusable candidate")
			}
		})
	}
}

func TestPendingRefreshRemovalFencesEveryStage(t *testing.T) {
	for _, stage := range []string{"token", "pending-ack", "verify", "active-ack"} {
		t.Run(stage, func(t *testing.T) {
			p, e, b, v, _, _ := pendingFixture(t)
			remove := func() {
				p.remove(e.view.ID, e.view.Generation)
				newer := v.active
				newer.Generation = strings.Repeat("z", 32)
				if !p.add(savedAccount{Credential: newer, Enabled: true, ConcurrencyLimit: 1}) {
					t.Fatal("synthetic re-login failed")
				}
			}
			begin := b.begin
			b.begin = func(ctx context.Context, c credential) (credential, error) {
				next, err := begin(ctx, c)
				if stage == "token" {
					remove()
				}
				return next, err
			}
			b.verify = func(_ context.Context, c credential) (credential, error) {
				if stage == "verify" {
					remove()
				}
				return c, nil
			}
			persist := func(ctx context.Context, c credential, purpose, base string) error {
				err := v.persist(ctx, c, purpose, base)
				if (stage == "pending-ack" && purpose == "refresh_pending") || (stage == "active-ack" && purpose == "refresh_promote") {
					remove()
				}
				return err
			}
			got, err := p.prepare(context.Background(), e, b, persist)
			if !errors.Is(err, context.Canceled) || got != (credential{}) {
				t.Fatal("removed generation returned an executable credential")
			}
			current := p.entries[e.view.ID]
			if current == e || current.pendingRefresh != nil || current.credential.Generation != strings.Repeat("z", 32) {
				t.Fatal("late result crossed re-login generation")
			}
			if stage == "token" && v.stages != 0 {
				t.Fatal("removed token result reached persistence")
			}
		})
	}
}

func TestPendingRefreshConcurrentRequestsRotateOnce(t *testing.T) {
	p, e, b, v, begin, verify := pendingFixture(t)
	var group sync.WaitGroup
	for range 12 {
		group.Go(func() {
			if _, err := p.prepare(context.Background(), e, b, v.persist); err != nil {
				t.Error("concurrent preparation failed")
			}
		})
	}
	group.Wait()
	if *begin != 1 || *verify != 1 || v.stages != 1 || v.promotions != 1 {
		t.Fatal("parallel requests duplicated rotation or verification")
	}
}

func TestPromotedPendingCleanupFailureCannotReturnExpiredAccess(t *testing.T) {
	for _, restart := range []bool{false, true} {
		t.Run(map[bool]string{false: "same-process", true: "restart"}[restart], func(t *testing.T) {
			p, e, b, v, begin, verify := pendingFixture(t)
			v.fail = "refresh_discard"
			promoted, err := p.prepare(context.Background(), e, b, v.persist)
			if err != nil || v.pending == nil {
				t.Fatal("fixture did not retain committed cleanup")
			}
			if restart {
				boot := startup{SchemaVersion: 1, ClientKey: testKey, Accounts: []savedAccount{{Credential: v.active, PendingRefresh: v.pending, Enabled: true, ConcurrencyLimit: 1}}}
				if boot.validate() != nil {
					t.Fatal("completed promotion cannot resume cleanup")
				}
				p = newPool(boot.Accounts)
				e = p.entries[promoted.AccountID]
			}
			p.now = func() time.Time { return time.Unix(promoted.ExpiresAt+1, 0) }
			if got, err := p.prepare(context.Background(), e, b, v.persist); err == nil || got != (credential{}) || *begin != 1 || *verify != 1 || e.credential != promoted {
				t.Fatal("cleanup outage used expired access or rotated before old pending was removed")
			}
			v.fail = ""
			originalBegin := b.begin
			b.begin = func(ctx context.Context, c credential) (credential, error) {
				if c != promoted {
					t.Fatal("cleanup retry reverted to spent refresh credential")
				}
				next, err := originalBegin(ctx, c)
				next.ExpiresAt = p.now().Add(time.Hour).Unix()
				return next, err
			}
			if got, err := p.prepare(context.Background(), e, b, v.persist); err != nil || got.ExpiresAt <= p.now().Unix() || *begin != 2 || *verify != 2 || v.pending != nil {
				t.Fatal("cleanup recovery did not refresh the current verified credential")
			}
		})
	}
}

func TestPendingRefreshValidationAndFingerprint(t *testing.T) {
	c := credential{Provider: "xai", AccountID: "xai-9a267f1b514e28a8722e1514725495bf", Generation: strings.Repeat("b", 32), MaskedIdentity: "f***@例***", AccessToken: "synthetic-active-access", RefreshToken: "synthetic-active-refresh", ExpiresAt: 1_800_000_000, AccountSubject: "fixture-account"}
	if c.fingerprint() != "0043118735138636d00aec427c6234cfae627da7b470fbbd089c90c65d9dfe88" {
		t.Fatal("native/Go UTF-8 fingerprint contract changed")
	}
	valid := pendingRefresh{BaseFingerprint: c.fingerprint(), Credential: c}
	valid.Credential.AccessToken = "synthetic-pending-access"
	if !valid.validFor(c) {
		t.Fatal("valid pending rejected")
	}
	for _, field := range []string{"base", "provider", "generation", "subject", "mask", "token", "project"} {
		t.Run(field, func(t *testing.T) {
			bad := valid
			switch field {
			case "base":
				bad.BaseFingerprint = strings.Repeat("0", 64)
			case "provider":
				bad.Credential.Provider = "kimi"
			case "generation":
				bad.Credential.Generation = strings.Repeat("z", 32)
			case "subject":
				bad.Credential.AccountSubject = "other"
			case "mask":
				bad.Credential.MaskedIdentity = "other***"
			case "token":
				bad.Credential.AccessToken = strings.Repeat("x", 16385)
			case "project":
				bad.Credential.ProjectID = "other"
			}
			s := startup{SchemaVersion: 1, ClientKey: testKey, Accounts: []savedAccount{{Credential: c, PendingRefresh: &bad, ConcurrencyLimit: 1}}}
			if bad.validFor(c) || s.validate() == nil {
				t.Fatal("invalid pending accepted")
			}
		})
	}
}
