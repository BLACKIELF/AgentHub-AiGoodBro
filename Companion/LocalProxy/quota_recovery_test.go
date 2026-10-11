package main

import (
	"context"
	"encoding/json"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	auth "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
	executor "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/executor"
)

func quotaRecoveryProof(t time.Time) bridgeReply {
	return bridgeReply{OK: true, QuotaObservedAt: float64(t.UnixNano()) / 1e9}
}

func quotaRecoveryContext(rt *runtime) context.Context {
	scope := &requestScope{id: "00000000-0000-4000-8000-000000000001", ctx: context.Background(), recovery: rt.recovery}
	return context.WithValue(context.Background(), scopeKey{}, scope)
}

func markCredentialQuota(rt *runtime, id string) {
	retry := 24 * time.Hour
	rt.manager.MarkResult(context.Background(), auth.Result{AuthID: id, Provider: "codex", Model: "fixture-model", CredentialScope: true, RetryAfter: &retry, Error: &auth.Error{HTTPStatus: http.StatusTooManyRequests}})
}

func recoveryRuntime(t *testing.T, b *fakeBridge) (*runtime, startup) {
	t.Helper()
	s := newStartup(t, b)
	rt, err := newRuntime(s, &events{out: io.Discard}, "")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(rt.close)
	return rt, s
}

func TestQuotaRecoveryLegacySnapshotBeforeStartup(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	until := time.Now().Add(24 * time.Hour).UTC()
	rows := []map[string]any{
		{"id": "A", "until": until, "reason": "credential_quota", "exceeded": true, "recover": until},
		// The old store converted the triggering model's SDK "quota" reason.
		{"id": "A", "model": "fixture-model", "until": until, "reason": "temporary_error", "exceeded": true, "recover": until},
	}
	if err := os.MkdirAll(s.StateDirectory, 0700); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(rows)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(s.StateDirectory, "cooldown.json")
	if err = os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	modified := time.Now().Add(-2 * time.Minute).UTC()
	if err = os.Chtimes(path, modified, modified); err != nil {
		t.Fatal(err)
	}
	observed := time.Now().Add(-time.Minute)
	b.beforeReply = func(q bridgeRequest, reply bridgeReply) bridgeReply {
		if q.Command == "quota_recovery" {
			return quotaRecoveryProof(observed)
		}
		return reply
	}
	rt, err := newRuntime(s, &events{out: io.Discard}, "")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(rt.close)
	a, _ := rt.manager.GetByID("A")
	if !a.UpdatedAt.Equal(modified) {
		t.Fatal("legacy migration invented a new error time at startup")
	}
	rt.reconcileQuota(quotaRecoveryContext(rt))
	a, _ = rt.manager.GetByID("A")
	if !a.Quota.Exceeded || !a.NextRetryAfter.Equal(until) || !a.ModelStates["fixture-model"].Quota.Exceeded {
		t.Fatal("fresh subscription evidence cleared uncertain legacy errors")
	}
}

func TestQuotaRecoveryLegacyModel429KeepsInheritedCredentialDeadline(t *testing.T) {
	b := newFakeBridge(t)
	rt, s := recoveryRuntime(t, b)
	markCredentialQuota(rt, "A")
	retry := time.Minute
	rt.manager.MarkResult(context.Background(), auth.Result{AuthID: "A", Provider: "codex", Model: "fixture-model", RetryAfter: &retry, Error: &auth.Error{HTTPStatus: 429}})
	before, _ := rt.manager.GetByID("A")
	if !before.NextRetryAfter.Equal(before.ModelStates["fixture-model"].NextRetryAfter) {
		t.Fatal("fixture did not reproduce the SDK's inherited credential deadline")
	}
	rt.close()
	path := filepath.Join(s.StateDirectory, "cooldown.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var rows []map[string]any
	if err = json.Unmarshal(data, &rows); err != nil {
		t.Fatal(err)
	}
	// Reproduce exactly what the old safeCooldown serializer retained after
	// credential 429 -> ordinary model 429: identical deadlines, no provenance.
	for _, row := range rows {
		delete(row, "error")
		delete(row, "updatedAt")
		if row["reason"] == "quota" {
			row["reason"] = "temporary_error"
		}
	}
	data, err = json.Marshal(rows)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	modified := time.Now().Add(-2 * time.Minute)
	if err = os.Chtimes(path, modified, modified); err != nil {
		t.Fatal(err)
	}
	b.beforeReply = func(q bridgeRequest, reply bridgeReply) bridgeReply {
		if q.Command == "quota_recovery" {
			return quotaRecoveryProof(time.Now())
		}
		return reply
	}
	rt, err = newRuntime(s, &events{out: io.Discard}, "")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(rt.close)
	restored, _ := rt.manager.GetByID("A")
	rt.reconcileQuota(quotaRecoveryContext(rt))
	after, _ := rt.manager.GetByID("A")
	if after.Generation != restored.Generation || !after.Quota.Exceeded || !after.ModelStates["fixture-model"].Quota.Exceeded || !after.ModelStates["fixture-model"].NextRetryAfter.Equal(before.ModelStates["fixture-model"].NextRetryAfter) {
		t.Fatal("fresh subscription proof erased an independent model limit from the old format")
	}
}

func TestQuotaRecoveryPreservesUnrelatedErrorAfterRestart(t *testing.T) {
	for _, status := range []int{401, 403, 500, 0, 429} {
		t.Run(strconv.Itoa(status), func(t *testing.T) {
			b := newFakeBridge(t)
			rt, s := recoveryRuntime(t, b)
			markCredentialQuota(rt, "A")
			retry := time.Minute
			rt.manager.MarkResult(context.Background(), auth.Result{AuthID: "A", Provider: "codex", Model: "fixture-model", RetryAfter: &retry, Error: &auth.Error{HTTPStatus: status, Code: "fixture-private-code", Message: "fixture-private-upstream-body"}})
			rt.close()
			rt, err := newRuntime(s, &events{out: io.Discard}, "")
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(rt.close)
			before, _ := rt.manager.GetByID("A")
			b.beforeReply = func(q bridgeRequest, reply bridgeReply) bridgeReply {
				if q.Command == "quota_recovery" {
					return quotaRecoveryProof(time.Now())
				}
				return reply
			}
			rt.reconcileQuota(quotaRecoveryContext(rt))
			after, _ := rt.manager.GetByID("A")
			if !after.Quota.Exceeded || !after.NextRetryAfter.Equal(before.NextRetryAfter) || after.Generation != before.Generation {
				t.Fatal("official subscription evidence cleared an unrelated persisted failure")
			}
			data, err := os.ReadFile(filepath.Join(s.StateDirectory, "cooldown.json"))
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(string(data), "fixture-private") {
				t.Fatal("safe cooldown leaked upstream error text or code")
			}
		})
	}
}

func TestQuotaRecoveryCredentialReasonCanHideIndependentModelLimit(t *testing.T) {
	b := newFakeBridge(t)
	rt, s := recoveryRuntime(t, b)
	retry := time.Minute
	rt.manager.MarkResult(context.Background(), auth.Result{AuthID: "A", Provider: "codex", Model: "fixture-other-model", RetryAfter: &retry, Error: &auth.Error{HTTPStatus: 429}})
	markCredentialQuota(rt, "A")
	a, _ := rt.manager.GetByID("A")
	state := a.ModelStates["fixture-other-model"]
	if state.Quota.Reason != "credential_quota" || state.LastError == nil || state.LastError.HTTPStatus != 429 || state.LastError.Code == credentialQuotaErrorCode || !state.NextRetryAfter.Equal(a.NextRetryAfter) {
		t.Fatal("fixture did not reproduce propagation hiding an independent model limit behind credential_quota")
	}
	rt.close()
	rt, err := newRuntime(s, &events{out: io.Discard}, "")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(rt.close)
	b.beforeReply = func(q bridgeRequest, reply bridgeReply) bridgeReply {
		if q.Command == "quota_recovery" {
			return quotaRecoveryProof(time.Now())
		}
		return reply
	}
	before, _ := rt.manager.GetByID("A")
	rt.reconcileQuota(quotaRecoveryContext(rt))
	after, _ := rt.manager.GetByID("A")
	if after.Generation != before.Generation || !after.Quota.Exceeded || !after.ModelStates["fixture-other-model"].NextRetryAfter.Equal(state.NextRetryAfter) {
		t.Fatal("credential_quota reason alone cleared an independent model restriction")
	}
}

func TestQuotaRecoveryUnblocksSDKSelectionAfterRestart(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		complete(w, strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer fixture-"))
	}))
	t.Cleanup(upstream.Close)
	rt, server, _ := startTestRuntime(t, s, upstream.URL)
	markCredentialQuota(rt, "A")
	server.Close()
	rt.close()
	rt, server, _ = startTestRuntime(t, s, upstream.URL)
	b.beforeReply = func(q bridgeRequest, reply bridgeReply) bridgeReply {
		if q.Command == "quota_recovery" {
			return quotaRecoveryProof(time.Now())
		}
		return reply
	}
	resp := request(t, s, server.URL, false)
	body := consume(t, resp)
	if resp.StatusCode != http.StatusOK || !strings.Contains(body, "done-A") {
		t.Fatalf("recovered account was still filtered before the selector: status=%d", resp.StatusCode)
	}
	waitEmpty(t, b)
}

func TestQuotaRecoveryKnownCleanSiblingSurvivesRestart(t *testing.T) {
	b := newFakeBridge(t)
	rt, s := recoveryRuntime(t, b)
	rt.manager.MarkResult(context.Background(), auth.Result{AuthID: "A", Provider: "codex", Model: "fixture-sibling", Success: true})
	markCredentialQuota(rt, "A")
	before, _ := rt.manager.GetByID("A")
	if before.ModelStates["fixture-sibling"].LastError != nil || before.ModelStates["fixture-sibling"].Quota.Reason != "credential_quota" {
		t.Fatal("fixture sibling was not clean before credential quota propagation")
	}
	rt.close()
	rt, err := newRuntime(s, &events{out: io.Discard}, "")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(rt.close)
	restored, _ := rt.manager.GetByID("A")
	if restored.ModelStates["fixture-sibling"].LastError != nil {
		t.Fatal("explicitly known absence became an unknown legacy failure")
	}
	b.beforeReply = func(q bridgeRequest, reply bridgeReply) bridgeReply {
		if q.Command == "quota_recovery" {
			return quotaRecoveryProof(time.Now())
		}
		return reply
	}
	rt.reconcileQuota(quotaRecoveryContext(rt))
	after, _ := rt.manager.GetByID("A")
	if after.Quota.Exceeded || after.ModelStates["fixture-sibling"].Quota.Exceeded || after.ModelStates["fixture-model"].Quota.Exceeded {
		t.Fatal("proven credential quota with a known clean sibling did not recover")
	}
}

func TestQuotaRecoveryProofValidation(t *testing.T) {
	now := time.Now()
	for _, tc := range []struct {
		name  string
		edit  func(*bridgeReply)
		valid bool
	}{
		{"fresh", func(*bridgeReply) {}, true},
		{"missing", func(r *bridgeReply) { r.QuotaObservedAt = 0 }, false},
		{"stale", func(r *bridgeReply) { *r = quotaRecoveryProof(now.Add(-6 * time.Minute)) }, false},
		{"future", func(r *bridgeReply) { *r = quotaRecoveryProof(now.Add(time.Minute)) }, false},
		{"nan", func(r *bridgeReply) { r.QuotaObservedAt = math.NaN() }, false},
		{"infinity", func(r *bridgeReply) { r.QuotaObservedAt = math.Inf(1) }, false},
		{"overflow", func(r *bridgeReply) { r.QuotaObservedAt = math.MaxFloat64 }, false},
		{"rejected", func(r *bridgeReply) { r.OK = false }, false},
		{"conflicting_error", func(r *bridgeReply) { r.Error = "identity" }, false},
		{"credentials", func(r *bridgeReply) { r.AccessToken = "synthetic" }, false},
		{"lease", func(r *bridgeReply) { r.LeaseID = "synthetic" }, false},
		{"order", func(r *bridgeReply) { r.Order = []string{"A"} }, false},
		{"credits", func(r *bridgeReply) { r.CreditFallback = true }, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reply := quotaRecoveryProof(now.Add(-time.Second))
			tc.edit(&reply)
			_, valid := quotaProofObserved(reply, now)
			if valid != tc.valid {
				t.Fatalf("proof accepted=%v want=%v", valid, tc.valid)
			}
		})
	}
}

func TestQuotaRecoveryCutoffPreservesOtherRestrictions(t *testing.T) {
	now := time.Now()
	until := now.Add(time.Hour)
	for _, tc := range []struct {
		name  string
		edit  func(*auth.Auth)
		valid bool
	}{
		{"credential_quota", func(*auth.Auth) {}, true},
		{"disabled", func(a *auth.Auth) { a.Disabled = true }, false},
		{"disabled_status", func(a *auth.Auth) { a.Status = auth.StatusDisabled }, false},
		{"other_auth_quota", func(a *auth.Auth) { a.Quota.Reason = "quota" }, false},
		{"auth_unauthorized", func(a *auth.Auth) { a.LastError = &auth.Error{HTTPStatus: 401} }, false},
		{"unknown_auth_error", func(a *auth.Auth) { a.LastError = &auth.Error{} }, false},
		{"auth_other_deadline", func(a *auth.Auth) { a.NextRetryAfter = until.Add(time.Minute) }, false},
		{"model_disabled", func(a *auth.Auth) { a.ModelStates["fixture-model"].Status = auth.StatusDisabled }, false},
		{"ordinary_model_429_same_deadline", func(a *auth.Auth) { a.ModelStates["fixture-model"].LastError = &auth.Error{HTTPStatus: 429} }, false},
		{"model_forbidden", func(a *auth.Auth) { a.ModelStates["fixture-model"].LastError = &auth.Error{HTTPStatus: 403} }, false},
		{"model_unknown_reason", func(a *auth.Auth) { a.ModelStates["fixture-model"].Quota.Reason = "unknown" }, false},
		{"model_longer_retry", func(a *auth.Auth) { a.ModelStates["fixture-model"].NextRetryAfter = until.Add(time.Minute) }, false},
		{"model_longer_quota", func(a *auth.Auth) { a.ModelStates["fixture-model"].Quota.NextRecoverAt = until.Add(time.Minute) }, false},
		{"legacy_shared_deadline", func(a *auth.Auth) {
			a.LastError = nil
			a.ModelStates["fixture-model"].LastError = nil
			a.ModelStates["fixture-model"].Quota.Reason = "temporary_error"
		}, false},
		{"credential_auth_missing_provenance", func(a *auth.Auth) { a.LastError = nil }, false},
		{"triggering_model_missing_provenance", func(a *auth.Auth) { a.ModelStates["fixture-model"].LastError = nil }, false},
		{"proven_clean_sibling", func(a *auth.Auth) {
			a.ModelStates["fixture-model"].LastError = nil
			a.ModelStates["fixture-model"].Quota.Reason = "credential_quota"
		}, true},
		{"legacy_unknown_with_error", func(a *auth.Auth) { a.ModelStates["fixture-model"].Quota.Reason = "temporary_error" }, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			failure := &auth.Error{HTTPStatus: 429, Code: credentialQuotaErrorCode}
			a := &auth.Auth{Quota: auth.QuotaState{Exceeded: true, Reason: "credential_quota", NextRecoverAt: until}, NextRetryAfter: until, UpdatedAt: now.Add(-time.Minute), LastError: failure, ModelStates: map[string]*auth.ModelState{
				"fixture-model": {Quota: auth.QuotaState{Exceeded: true, Reason: "quota", NextRecoverAt: until}, NextRetryAfter: until, UpdatedAt: now.Add(-30 * time.Second), LastError: failure},
			}}
			tc.edit(a)
			cutoff, valid := quotaRecoveryCutoff(a, now)
			if valid != tc.valid || valid && !cutoff.Equal(a.ModelStates["fixture-model"].UpdatedAt) {
				t.Fatalf("recoverable=%v want=%v; cutoff must include the newest model error", valid, tc.valid)
			}
		})
	}
}

func TestQuotaRecoveryPendingProofCannotEraseNewResult(t *testing.T) {
	for _, status := range []int{429, 401, 500, 0} {
		for _, credential := range []bool{false, true} {
			t.Run(strconv.Itoa(status)+"/credential="+strconv.FormatBool(credential), func(t *testing.T) {
				b := newFakeBridge(t)
				rt, _ := recoveryRuntime(t, b)
				markCredentialQuota(rt, "A")
				latest := make(chan *auth.Auth, 1)
				b.beforeReply = func(q bridgeRequest, reply bridgeReply) bridgeReply {
					if q.Command == "quota_recovery" {
						proof := quotaRecoveryProof(time.Now())
						retry := 48 * time.Hour
						rt.manager.MarkResult(context.Background(), auth.Result{AuthID: "A", Provider: "codex", Model: "fixture-model", CredentialScope: credential, RetryAfter: &retry, Error: &auth.Error{HTTPStatus: status}})
						a, _ := rt.manager.GetByID("A")
						latest <- a
						return proof
					}
					return reply
				}
				rt.reconcileQuota(quotaRecoveryContext(rt))
				before := <-latest
				after, _ := rt.manager.GetByID("A")
				if after.Generation != before.Generation || !after.NextRetryAfter.Equal(before.NextRetryAfter) || !after.Quota.Exceeded {
					t.Fatal("pending host evidence overwrote a newer SDK result")
				}
			})
		}
	}
}

func TestQuotaRecoveryActiveScopesPreventReset(t *testing.T) {
	for _, reserveDuringProof := range []bool{false, true} {
		t.Run(strconv.FormatBool(reserveDuringProof), func(t *testing.T) {
			b := newFakeBridge(t)
			rt, _ := recoveryRuntime(t, b)
			markCredentialQuota(rt, "A")
			scope := &requestScope{recovery: rt.recovery}
			defer scope.releaseQuotaAccounts()
			if !reserveDuringProof {
				scope.reserveQuotaAccount("A")
				scope.reserveQuotaAccount("A")
			}
			b.beforeReply = func(q bridgeRequest, reply bridgeReply) bridgeReply {
				if q.Command == "quota_recovery" {
					if reserveDuringProof {
						scope.reserveQuotaAccount("A")
					}
					return quotaRecoveryProof(time.Now())
				}
				return reply
			}
			rt.reconcileQuota(quotaRecoveryContext(rt))
			a, _ := rt.manager.GetByID("A")
			if !a.Quota.Exceeded {
				t.Fatal("active request lost its quota result state")
			}
			account := rt.recovery.accounts["A"]
			account.mu.Lock()
			active := account.active
			account.mu.Unlock()
			if active != 1 {
				t.Fatalf("duplicate reservation changed active scopes to %d", active)
			}
			scope.releaseQuotaAccounts()
			scope.releaseQuotaAccounts()
			account.mu.Lock()
			active = account.active
			account.mu.Unlock()
			if active != 0 {
				t.Fatalf("scope cleanup retained or double-released its reservation: %d", active)
			}
		})
	}
}

type quotaResultBlockingWriter struct {
	started, release chan struct{}
	once             sync.Once
}

func (w *quotaResultBlockingWriter) Write(p []byte) (int, error) {
	w.once.Do(func() { close(w.started) })
	<-w.release
	return len(p), nil
}

func TestQuotaRecoveryResultLockSpansSDKPublishAndUnlocksStaleResults(t *testing.T) {
	b := newFakeBridge(t)
	rt, _ := recoveryRuntime(t, b)
	w := &quotaResultBlockingWriter{started: make(chan struct{}), release: make(chan struct{})}
	var releaseOnce sync.Once
	unblock := func() { releaseOnce.Do(func() { close(w.release) }) }
	t.Cleanup(unblock)
	rt.selector.events.out = w
	finished := make(chan struct{})
	go func() { markCredentialQuota(rt, "A"); close(finished) }()
	select {
	case <-w.started:
	case <-time.After(time.Second):
		t.Fatal("SDK result hook did not run")
	}
	account := rt.recovery.accounts["A"]
	if account.mu.TryLock() {
		account.mu.Unlock()
		t.Fatal("result lock ended before hook publication")
	}
	checked := make(chan struct{})
	go func() { rt.reconcileQuota(quotaRecoveryContext(rt)); close(checked) }()
	select {
	case <-checked:
	case <-time.After(time.Second):
		t.Fatal("quota preflight blocked on a pending SDK result")
	}
	unblock()
	select {
	case <-finished:
	case <-time.After(time.Second):
		t.Fatal("SDK result failed to unlock")
	}
	a, _ := rt.manager.GetByID("A")
	priorVersion := a.CredentialVersion
	if _, err := rt.manager.Register(context.Background(), a); err != nil {
		t.Fatal(err)
	}
	rt.manager.MarkResult(context.Background(), auth.Result{AuthID: "A", Provider: "codex", Model: "fixture-model", CredentialVersion: priorVersion, Error: &auth.Error{HTTPStatus: 401}})
	if !account.mu.TryLock() {
		t.Fatal("SDK stale-result early return leaked the recovery lock")
	}
	account.mu.Unlock()
}

func TestQuotaRecoveryHostDenialPreservesParticipation(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	b.setOrder("B")
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		complete(w, strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer fixture-"))
	}))
	t.Cleanup(upstream.Close)
	rt, server, _ := startTestRuntime(t, s, upstream.URL)
	markCredentialQuota(rt, "A")
	b.beforeReply = func(q bridgeRequest, reply bridgeReply) bridgeReply {
		if q.Command == "quota_recovery" {
			return bridgeReply{Error: "not_participating"}
		}
		return reply
	}
	resp := request(t, s, server.URL, false)
	body := consume(t, resp)
	if resp.StatusCode != http.StatusOK || !strings.Contains(body, "done-B") {
		t.Fatal("host participation denial changed the eligible account")
	}
	a, _ := rt.manager.GetByID("A")
	if !a.Quota.Exceeded {
		t.Fatal("host-denied account was reset")
	}
	waitEmpty(t, b)
}

func TestQuotaRecoveryAllAccountsSharePreflightDeadline(t *testing.T) {
	b := newFakeBridge(t)
	rt, _ := recoveryRuntime(t, b)
	markCredentialQuota(rt, "A")
	markCredentialQuota(rt, "B")
	release := make(chan struct{})
	defer close(release)
	b.beforeReply = func(q bridgeRequest, reply bridgeReply) bridgeReply {
		if q.Command == "quota_recovery" {
			<-release
		}
		return reply
	}
	start := time.Now()
	rt.reconcileQuota(quotaRecoveryContext(rt))
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Fatalf("preflight multiplied the deadline by account count: %s", elapsed)
	}
	for _, id := range rt.ids {
		a, _ := rt.manager.GetByID(id)
		if !a.Quota.Exceeded {
			t.Fatal("timed-out proof cleared a quota")
		}
	}
}

func TestQuotaRecoveryProofReturningDuringResultPublishDoesNotBlock(t *testing.T) {
	b := newFakeBridge(t)
	rt, _ := recoveryRuntime(t, b)
	markCredentialQuota(rt, "A")
	w := &quotaResultBlockingWriter{started: make(chan struct{}), release: make(chan struct{})}
	var releaseOnce sync.Once
	unblock := func() { releaseOnce.Do(func() { close(w.release) }) }
	t.Cleanup(unblock)
	rt.selector.events.out = w
	resultFinished := make(chan struct{})
	b.beforeReply = func(q bridgeRequest, reply bridgeReply) bridgeReply {
		if q.Command == "quota_recovery" {
			proof := quotaRecoveryProof(time.Now())
			go func() { markCredentialQuota(rt, "A"); close(resultFinished) }()
			<-w.started
			return proof
		}
		return reply
	}
	checked := make(chan struct{})
	go func() { rt.reconcileQuota(quotaRecoveryContext(rt)); close(checked) }()
	select {
	case <-checked:
	case <-time.After(time.Second):
		t.Fatal("proof response waited for an in-progress SDK result lock")
	}
	unblock()
	select {
	case <-resultFinished:
	case <-time.After(time.Second):
		t.Fatal("SDK result did not finish")
	}
	a, _ := rt.manager.GetByID("A")
	if !a.Quota.Exceeded {
		t.Fatal("newer SDK error was cleared")
	}
}

func TestQuotaRecoveryResultMetadataAndErrorIsolation(t *testing.T) {
	r := newQuotaRecovery([]string{"A"})
	metadata := map[string]any{"original": true}
	failure := &auth.Error{HTTPStatus: 429, Code: "fixture-code"}
	result := r.ApplyResultPolicy(context.Background(), auth.Result{AuthID: "A", CredentialScope: true, Error: failure, Options: executor.Options{Metadata: metadata}})
	finishQuotaResult(result)
	finishQuotaResult(result)
	if len(metadata) != 1 || failure.Code != "fixture-code" || result.Error.Code != credentialQuotaErrorCode {
		t.Fatal("post-execution policy changed caller metadata or upstream error")
	}
	for _, code := range []string{auth.ErrorCodeRequestScoped, auth.ErrorCodeForceCooldown, auth.ErrorCodeConnectionLifecycle, auth.ErrorCodeTransientTransport} {
		result := r.ApplyResultPolicy(context.Background(), auth.Result{AuthID: "A", CredentialScope: true, Error: &auth.Error{HTTPStatus: 429, Code: code}})
		finishQuotaResult(result)
		if result.Error.Code != code {
			t.Fatal("quota provenance changed an SDK error policy")
		}
	}
}

func TestQuotaRecoveryNilFailureAndCancellationFailClosed(t *testing.T) {
	b := newFakeBridge(t)
	rt, _ := recoveryRuntime(t, b)
	markCredentialQuota(rt, "A")
	ctx, cancel := context.WithCancel(quotaRecoveryContext(rt))
	cancel()
	rt.reconcileQuota(ctx)
	rt.manager.MarkResult(context.Background(), auth.Result{AuthID: "A", Provider: "codex", Model: "fixture-model"})
	b.beforeReply = func(q bridgeRequest, reply bridgeReply) bridgeReply {
		if q.Command == "quota_recovery" {
			t.Error("unknown failure or cancellation reached quota proof")
			return quotaRecoveryProof(time.Now())
		}
		return reply
	}
	rt.reconcileQuota(quotaRecoveryContext(rt))
	a, _ := rt.manager.GetByID("A")
	if !a.Quota.Exceeded || a.LastError == nil || a.LastError.HTTPStatus != 0 {
		t.Fatal("unknown SDK failure was erased or misclassified")
	}
}
