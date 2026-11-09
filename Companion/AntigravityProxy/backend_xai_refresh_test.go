package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestXAIRefreshPreservesErrorClassification(t *testing.T) {
	tests := []struct {
		name          string
		endpoint      string
		status        int
		body          string
		transportFail bool
		cancel        bool
		deadline      bool
		idSubject     string
		wantStatus    int
		wantReason    string
	}{
		{name: "token transport", endpoint: xaiTokenEndpoint, transportFail: true, wantStatus: 502, wantReason: "oauth_transport_failed"},
		{name: "token malformed 200", endpoint: xaiTokenEndpoint, status: 200, body: `private-fixture-not-json`, wantStatus: 502, wantReason: "invalid_token_response"},
		{name: "token incomplete 200", endpoint: xaiTokenEndpoint, status: 200, body: `{}`, wantStatus: 502, wantReason: "invalid_token_response"},
		{name: "token unavailable", endpoint: xaiTokenEndpoint, status: 503, wantStatus: 503},
		{name: "token cancelled", endpoint: xaiTokenEndpoint, cancel: true},
		{name: "token deadline", endpoint: xaiTokenEndpoint, deadline: true},
		{name: "invalid grant", endpoint: xaiTokenEndpoint, status: 400, body: `{"error":"invalid_grant"}`, wantStatus: 401},
		{name: "revoked in 200", endpoint: xaiTokenEndpoint, status: 200, body: `{"error":"invalid_token"}`, wantStatus: 401},
		{name: "pending is not revoked", endpoint: xaiTokenEndpoint, status: 400, body: `{"error":"authorization_pending"}`, wantStatus: 502, wantReason: "oauth_token_rejected"},
		{name: "identity unavailable", endpoint: xaiUserInfoEndpoint, status: 503, wantStatus: 503},
		{name: "identity rate limited", endpoint: xaiUserInfoEndpoint, status: 429, wantStatus: 429},
		{name: "identity transport", endpoint: xaiUserInfoEndpoint, transportFail: true, wantStatus: 502, wantReason: "oauth_transport_failed"},
		{name: "identity cancelled", endpoint: xaiUserInfoEndpoint, cancel: true},
		{name: "identity malformed 200", endpoint: xaiUserInfoEndpoint, status: 200, body: `private-fixture-not-json`, wantStatus: 502, wantReason: "invalid_upstream_response"},
		{name: "identity missing subject", endpoint: xaiUserInfoEndpoint, status: 200, body: `{}`, wantStatus: 502, wantReason: "oauth_identity_failed"},
		{name: "identity rejected", endpoint: xaiUserInfoEndpoint, status: 401, wantStatus: 401},
		{name: "different identity", endpoint: xaiUserInfoEndpoint, status: 200, body: `{"sub":"other-account"}`, wantStatus: 401},
		{name: "different ID token subject", endpoint: xaiUserInfoEndpoint, status: 200, body: `{"sub":"fixture-account"}`, idSubject: "other-account", wantStatus: 401},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			b := newXAIBackend("").(*xaiBackend)
			original := fixtureDeviceCredential("xai")
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if test.deadline {
				var deadlineCancel context.CancelFunc
				ctx, deadlineCancel = context.WithDeadline(ctx, time.Now().Add(-time.Second))
				defer deadlineCancel()
			}
			tokenCalls, identityCalls := 0, 0
			b.http = mockOAuthHTTP(func(r *http.Request) (*http.Response, error) {
				switch r.URL.String() {
				case xaiTokenEndpoint:
					tokenCalls++
					if r.Method != http.MethodPost || r.ParseForm() != nil || r.PostForm.Get("refresh_token") != original.RefreshToken {
						t.Fatal("refresh did not use the original slot credential")
					}
				case xaiUserInfoEndpoint:
					identityCalls++
					if r.Method != http.MethodGet || r.Header.Get("Authorization") != "Bearer synthetic-new-access" {
						t.Fatal("identity did not use the rotated access token")
					}
				default:
					t.Fatal("unexpected endpoint")
				}
				if r.URL.String() == test.endpoint {
					if test.cancel {
						cancel()
						return nil, ctx.Err()
					}
					if test.deadline {
						return nil, ctx.Err()
					}
					if test.transportFail {
						return nil, errors.New("private-fixture-transport-detail")
					}
					response := adapterResponse(test.status, test.body)
					response.Header.Set("Retry-After", "17")
					return response, nil
				}
				payload := map[string]any{"access_token": "synthetic-new-access", "refresh_token": "synthetic-rotated-refresh", "expires_in": 3600}
				if test.idSubject != "" {
					payload["id_token"] = syntheticJWT(map[string]string{"sub": test.idSubject})
				}
				body, _ := json.Marshal(payload)
				return adapterResponse(200, string(body)), nil
			})
			next, err := b.refresh(ctx, original)
			if err == nil || next != (credential{}) {
				t.Fatal("failed verification exposed a credential candidate")
			}
			if strings.Contains(err.Error(), "private-fixture") || strings.Contains(err.Error(), "synthetic-") {
				t.Fatal("upstream private detail escaped the safe error")
			}
			if test.cancel && !errors.Is(err, context.Canceled) {
				t.Fatal("cancellation was reclassified")
			}
			if test.deadline && !errors.Is(err, context.DeadlineExceeded) {
				t.Fatal("deadline was reclassified")
			}
			if test.wantStatus != 0 && statusCode(err) != test.wantStatus {
				t.Fatalf("status = %d, want %d", statusCode(err), test.wantStatus)
			}
			if test.wantReason != "" && err.Error() != test.wantReason {
				t.Fatalf("wrong safe error category: %v", err)
			}
			if tokenCalls > 1 || (test.endpoint == xaiTokenEndpoint && identityCalls != 0) || (test.endpoint == xaiUserInfoEndpoint && identityCalls != 1) {
				t.Fatal("unexpected retry or verification request after failure")
			}

			// Exercise the real pool classification without any credential write.
			now := time.Unix(1_800_000_000, 0)
			p := &pool{now: func() time.Time { return now }}
			e := &poolEntry{view: accountView{State: "ready"}, credential: original}
			p.recordErrorLocked(e, err)
			if test.wantStatus == 401 {
				if e.view.State != "reauth_required" {
					t.Fatal("revocation or identity mismatch did not fail closed")
				}
			} else if e.view.State != "ready" {
				t.Fatal("transient failure incorrectly revoked the account")
			}
			if (test.cancel || test.deadline) && (e.view.LastError != "" || e.view.CooldownUntil != 0) {
				t.Fatal("cancellation mutated pool error state")
			}
			if test.wantStatus >= 500 && e.view.CooldownUntil != now.Add(5*time.Second).Unix() {
				t.Fatal("transient upstream failure lost its bounded cooldown")
			}
			if test.wantStatus == 429 && e.view.CooldownUntil != now.Add(17*time.Second).Unix() {
				t.Fatal("identity rate limit lost Retry-After")
			}
			if e.credential != original {
				t.Fatal("failed refresh changed the active slot credential")
			}
		})
	}
}
