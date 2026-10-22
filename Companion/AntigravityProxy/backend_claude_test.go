package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

type adapterRoundTrip func(*http.Request) (*http.Response, error)

func (f adapterRoundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func adapterResponse(status int, body string) *http.Response {
	return &http.Response{StatusCode: status, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body))}
}
func mockOAuthHTTP(fn adapterRoundTrip) *oauthHTTP {
	return &oauthHTTP{transport: fn, client: &http.Client{Transport: fn, Timeout: time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
}
func fixtureClaudeCredential() credential {
	return credential{Provider: "claude", AccountID: providerAccountID("claude", "fixture-account"), Generation: randomID(),
		MaskedIdentity: "f***@e***", AccountSubject: "fixture-account", OrganizationID: "fixture-org", DeviceID: strings.Repeat("a", 64), AccessToken: "synthetic-access", RefreshToken: "synthetic-refresh", ExpiresAt: time.Now().Add(time.Hour).Unix()}
}

func TestClaudeOAuthCallbackStateHostAndReplay(t *testing.T) {
	state, verifier := randomID(), randomID()
	u, _ := url.Parse(claudeAuthorizationURL(state, verifier))
	sum := sha256.Sum256([]byte(verifier))
	if u.Host != "claude.ai" || u.Query().Get("redirect_uri") != "http://localhost:54545/callback" || u.Query().Get("code_challenge") != base64.RawURLEncoding.EncodeToString(sum[:]) {
		t.Fatal("invalid PKCE authorization URL")
	}
	ch := make(chan oauthResult, 1)
	handler := claudeCallbackHandler(state, ch)
	call := func(host, remote, query string) int {
		r := httptest.NewRequest("GET", "http://"+host+"/callback?"+query, nil)
		r.RemoteAddr = remote
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w.Code
	}
	for _, test := range []struct{ host, remote, query string }{
		{"localhost:54545", "127.0.0.1:1", "state=wrong&code=fixture"},
		{"evil.test:54545", "127.0.0.1:1", "state=" + state + "&code=fixture"},
		{"localhost:54545", "192.0.2.1:1", "state=" + state + "&code=fixture"},
		{"localhost:54545", "127.0.0.1:1", "state=" + state + "&state=" + state + "&code=fixture"},
	} {
		if call(test.host, test.remote, test.query) != 400 {
			t.Fatal("invalid callback accepted")
		}
	}
	if len(ch) != 0 {
		t.Fatal("invalid callback consumed flow")
	}
	if call("localhost:54545", "127.0.0.1:1", "state="+state+"&code=fixture") != 200 || call("localhost:54545", "127.0.0.1:1", "state="+state+"&code=fixture") != 409 {
		t.Fatal("callback replay guard failed")
	}
}

func TestClaudeExchangeUsesStableIdentityAndNoExecutorRefreshSecret(t *testing.T) {
	b := newClaudeBackend("").(*claudeBackend)
	calls := 0
	b.http = mockOAuthHTTP(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.URL.String() != "https://platform.claude.com/v1/oauth/token" || r.Method != "POST" {
			t.Fatal("unexpected endpoint")
		}
		var payload map[string]string
		if json.NewDecoder(r.Body).Decode(&payload) != nil || payload["code"] != "fixture-code" || payload["state"] != "fixture-state" || payload["code_verifier"] != "fixture-verifier" {
			t.Fatal("code exchange not bound")
		}
		return adapterResponse(200, `{"access_token":"synthetic-access","refresh_token":"synthetic-refresh","expires_in":3600,"account":{"uuid":"fixture-account","email_address":"fixture@example.test"},"organization":{"uuid":"fixture-org"}}`), nil
	})
	c, err := b.exchangeCode(context.Background(), "fixture-code", "fixture-state", "fixture-verifier")
	if err != nil || c.AccountID != providerAccountID("claude", "fixture-account") || c.Provider != "claude" || c.AccountSubject != "fixture-account" || c.OrganizationID != "fixture-org" || c.validate() != nil {
		t.Fatalf("credential rejected: %v", err)
	}
	if strings.Contains(c.MaskedIdentity, "fixture") || strings.Contains(c.MaskedIdentity, "example") {
		t.Fatal("identity not masked")
	}
	a, err := b.requestAuth(c)
	if err != nil || a.Metadata["refresh_token"] != nil || a.Storage != nil {
		t.Fatal("executor received refresh persistence authority")
	}
	if _, err = b.exchangeCode(context.Background(), "fixture-code#other", "fixture-state", "fixture-verifier"); err == nil || calls != 1 {
		t.Fatal("fragment replaced checked state")
	}
	c.Provider = "kimi"
	if _, err = b.requestAuth(c); err == nil {
		t.Fatal("foreign provider accepted")
	}
}

func TestClaudeRefreshRotationAndAmbiguousFailure(t *testing.T) {
	c := fixtureClaudeCredential()
	b := newClaudeBackend("").(*claudeBackend)
	b.http = mockOAuthHTTP(func(r *http.Request) (*http.Response, error) {
		return adapterResponse(200, `{"access_token":"synthetic-new-access","refresh_token":"synthetic-new-refresh","expires_in":7200,"account":{"uuid":"fixture-account"}}`), nil
	})
	next, err := b.refresh(context.Background(), c)
	if err != nil || next.RefreshToken != "synthetic-new-refresh" || next.Generation != c.Generation || c.RefreshToken != "synthetic-refresh" {
		t.Fatal("rotation broke immutable credential generation")
	}
	for _, fn := range []adapterRoundTrip{
		func(*http.Request) (*http.Response, error) { return nil, errors.New("secret-server-url-and-token") },
		func(*http.Request) (*http.Response, error) {
			return adapterResponse(200, `broken secret response`), nil
		},
		func(*http.Request) (*http.Response, error) {
			return adapterResponse(200, `{"access_token":"synthetic-access","expires_in":3600,"account":{"uuid":"other-account"}}`), nil
		},
	} {
		b.http = mockOAuthHTTP(fn)
		_, err = b.refresh(context.Background(), c)
		if statusCode(err) != 401 || strings.Contains(err.Error(), "secret") {
			t.Fatal("ambiguous or wrong-identity refresh remained replayable")
		}
	}
	b.http = mockOAuthHTTP(func(*http.Request) (*http.Response, error) {
		r := adapterResponse(429, `secret body`)
		r.Header.Set("Retry-After", "60")
		return r, nil
	})
	_, err = b.refresh(context.Background(), c)
	if statusCode(err) != 429 {
		t.Fatal("explicit retryable HTTP status lost")
	}
}

func TestClaudeModelCatalogIsObservedAndPaginated(t *testing.T) {
	b := newClaudeBackend("").(*claudeBackend)
	c := fixtureClaudeCredential()
	calls := 0
	b.http = mockOAuthHTTP(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.URL.Host != "api.anthropic.com" || r.Header.Get("Authorization") != "Bearer "+c.AccessToken || r.Header.Get("Anthropic-Beta") != "oauth-2025-04-20" {
			t.Fatal("model request lost OAuth headers")
		}
		if calls == 1 {
			return adapterResponse(200, `{"data":[{"id":"fixture-z"}],"has_more":true,"last_id":"fixture-z"}`), nil
		}
		if r.URL.Query().Get("after_id") != "fixture-z" {
			t.Fatal("pagination lost cursor")
		}
		return adapterResponse(200, `{"data":[{"id":"fixture-a"},{"id":"fixture-z"},{"id":"../invalid"}],"has_more":false}`), nil
	})
	models, err := b.models(context.Background(), c)
	if err != nil || strings.Join(models, ",") != "fixture-a,fixture-z" {
		t.Fatalf("catalog: %v %v", models, err)
	}
	b.http = mockOAuthHTTP(func(*http.Request) (*http.Response, error) { return adapterResponse(403, `secret denied`), nil })
	models, err = b.models(context.Background(), c)
	if statusCode(err) != 403 || len(models) != 0 {
		t.Fatal("failed catalog gained speculative models")
	}
}

func TestOAuthTransportRejectsForeignOriginsAndAllRedirects(t *testing.T) {
	calls := 0
	tr := oauthOriginTransport{base: adapterRoundTrip(func(*http.Request) (*http.Response, error) { calls++; return adapterResponse(200, `{}`), nil }), hosts: map[string]bool{"api.anthropic.com": true}}
	for _, raw := range []string{"http://api.anthropic.com/v1/models", "https://evil.test/v1/models", "https://api.anthropic.com:444/v1/models", "https://user@api.anthropic.com/v1/models"} {
		r, _ := http.NewRequest("GET", raw, nil)
		if _, err := tr.RoundTrip(r); err == nil {
			t.Fatal("foreign endpoint accepted")
		}
	}
	r, _ := http.NewRequest("GET", "https://api.anthropic.com/v1/models", nil)
	r.Response = &http.Response{StatusCode: 302}
	if _, err := tr.RoundTrip(r); err == nil {
		t.Fatal("same-host redirect accepted")
	}
	r.Response = nil
	if _, err := tr.RoundTrip(r); err != nil || calls != 1 {
		t.Fatal("fixed origin rejected")
	}
}
