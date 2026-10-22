package main

import (
	"bytes"
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
	"sync"
	"sync/atomic"
	"testing"
	"time"

	ag "github.com/router-for-me/CLIProxyAPI/v8/internal/auth/antigravity"
	executor "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/executor"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/translator"
)

const testModel = "fixture-model"
const testKey = "synthetic-local-client-key-for-offline-tests"

func testCredential(digit string) credential {
	return credential{Provider: "antigravity", AccountID: "ag-" + strings.Repeat(digit, 32), Generation: strings.Repeat(digit, 32),
		MaskedIdentity: "f***@e***", AccessToken: "synthetic-access", RefreshToken: "synthetic-refresh",
		ProjectID: "synthetic-project", ExpiresAt: time.Now().Add(time.Hour).Unix()}
}

func readyPool(count int) *pool {
	var accounts []savedAccount
	for _, id := range []string{"a", "b", "c"}[:count] {
		accounts = append(accounts, savedAccount{Credential: testCredential(id), Enabled: true, ConcurrencyLimit: 1})
	}
	p := newPool(accounts)
	for _, e := range p.entries {
		e.catalogAt = time.Now()
		e.view.Models = []string{testModel}
		e.view.State = "ready"
	}
	return p
}

type fakeBackend struct {
	refreshFn func(context.Context, credential) (credential, error)
	executeFn func(context.Context, credential, executor.Request, executor.Options) (executor.Response, error)
	streamFn  func(context.Context, credential, executor.Request, executor.Options) (*executor.StreamResult, error)
	modelsFn  func(context.Context, credential) ([]string, error)
}

func (b *fakeBackend) refresh(ctx context.Context, c credential) (credential, error) {
	if b.refreshFn != nil {
		return b.refreshFn(ctx, c)
	}
	c.ExpiresAt = time.Now().Add(time.Hour).Unix()
	return c, nil
}
func (b *fakeBackend) models(ctx context.Context, c credential) ([]string, error) {
	if b.modelsFn != nil {
		return b.modelsFn(ctx, c)
	}
	return []string{testModel}, nil
}
func (b *fakeBackend) execute(ctx context.Context, c credential, r executor.Request, o executor.Options) (executor.Response, error) {
	if b.executeFn != nil {
		return b.executeFn(ctx, c, r, o)
	}
	return executor.Response{Payload: []byte(`{"ok":true}`)}, nil
}
func (b *fakeBackend) count(ctx context.Context, c credential, r executor.Request, o executor.Options) (executor.Response, error) {
	return b.execute(ctx, c, r, o)
}
func (b *fakeBackend) stream(ctx context.Context, c credential, r executor.Request, o executor.Options) (*executor.StreamResult, error) {
	return b.streamFn(ctx, c, r, o)
}
func noPersist(context.Context, credential, string, string) error { return nil }

func TestAuthResultCodeRetainsSafeStageOnly(t *testing.T) {
	cases := []struct {
		err  error
		want string
	}{
		{nil, "ok"},
		{context.Canceled, "oauth_cancelled"},
		{context.DeadlineExceeded, "oauth_timeout"},
		{errors.New("credential_store_rejected"), "credential_store_rejected"},
		{oauthStageError{code: "oauth_token_exchange_failed", status: 400}, "oauth_token_exchange_failed_http_400"},
		{oauthStageError{code: "oauth_identity_failed", status: 503}, "oauth_identity_failed_http_503"},
		{oauthStageFailure(context.Background(), "oauth_project_failed", &ag.HTTPStatusError{StatusCodeValue: 403, Message: "secret response body"}), "oauth_project_failed_http_403"},
		{errors.New("oauth_token_exchange_failed: secret response body"), "oauth_failed"},
	}
	for _, item := range cases {
		if got := authResultCode(item.err); got != item.want {
			t.Fatalf("auth result code = %q, want %q", got, item.want)
		}
	}
}

func TestOAuthPKCEAndOneShotCallback(t *testing.T) {
	state, verifier := randomID(), randomID()
	u, _ := url.Parse(authorizationURL(state, verifier, "http://127.0.0.1:12345/oauth-callback"))
	hash := sha256.Sum256([]byte(verifier))
	if u.Scheme != "https" || u.Host != "accounts.google.com" || u.Query().Get("code_challenge_method") != "S256" || u.Query().Get("code_challenge") != base64.RawURLEncoding.EncodeToString(hash[:]) {
		t.Fatal("PKCE not bound")
	}
	ch := make(chan oauthResult, 1)
	h := callbackHandler(state, "127.0.0.1:12345", ch)
	call := func(query, host, remote string) int {
		r := httptest.NewRequest("GET", "http://"+host+"/oauth-callback?"+query, nil)
		r.RemoteAddr = remote
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w.Code
	}
	if call("state=wrong&code=synthetic", "127.0.0.1:12345", "127.0.0.1:9") != 400 {
		t.Fatal("wrong state accepted")
	}
	if call("state="+state+"&code=synthetic", "example.test:12345", "127.0.0.1:9") != 400 {
		t.Fatal("foreign host accepted")
	}
	if call("state="+state+"&code=synthetic", "127.0.0.1:12345", "192.0.2.1:9") != 400 {
		t.Fatal("non-loopback accepted")
	}
	if call("state="+state+"&state="+state+"&code=synthetic", "127.0.0.1:12345", "127.0.0.1:9") != 400 {
		t.Fatal("duplicate state accepted")
	}
	if len(ch) != 0 {
		t.Fatal("invalid callback consumed session")
	}
	if call("state="+state+"&code=synthetic", "127.0.0.1:12345", "127.0.0.1:9") != 200 {
		t.Fatal("valid callback rejected")
	}
	if call("state="+state+"&code=synthetic", "127.0.0.1:12345", "127.0.0.1:9") != 409 {
		t.Fatal("callback replay accepted")
	}
}

func TestPoolConcurrentAdmissionCooldownAndRevocation(t *testing.T) {
	p := readyPool(2)
	a, err := p.acquire(context.Background(), testModel, map[string]bool{})
	if err != nil {
		t.Fatal(err)
	}
	b, err := p.acquire(context.Background(), testModel, map[string]bool{})
	if err != nil {
		t.Fatal(err)
	}
	if a.entry == b.entry {
		t.Fatal("concurrency limit bypassed")
	}
	if _, err = p.acquire(context.Background(), testModel, map[string]bool{}); err == nil {
		t.Fatal("unbounded admission")
	}
	a.finish(upstreamError{status: 429, delay: time.Minute})
	b.finish(nil)
	c, err := p.acquire(context.Background(), testModel, map[string]bool{})
	if err != nil || c.entry != b.entry {
		t.Fatal("cooling identity selected")
	}
	p.remove(c.entry.view.ID, c.entry.view.Generation)
	select {
	case <-c.ctx.Done():
	default:
		t.Fatal("removed identity kept request alive")
	}
	c.finish(nil)
	if _, err = p.acquire(context.Background(), testModel, map[string]bool{}); err == nil {
		t.Fatal("cooldown not enforced")
	}
	p.mu.Lock()
	p.now = func() time.Time { return time.Now().Add(2 * time.Minute) }
	p.mu.Unlock()
	d, err := p.acquire(context.Background(), testModel, map[string]bool{})
	if err != nil {
		t.Fatal("cooldown did not recover")
	}
	d.finish(nil)
}

func TestParallelPoolNeverExceedsLimit(t *testing.T) {
	p := readyPool(2)
	var workers sync.WaitGroup
	for range 50 {
		workers.Go(func() {
			for range 20 {
				l, err := p.acquire(context.Background(), testModel, map[string]bool{})
				if err == nil {
					rows, _ := p.snapshots()
					for _, row := range rows {
						if row.InFlight > row.ConcurrencyLimit {
							t.Error("limit exceeded")
						}
					}
					l.finish(nil)
				}
			}
		})
	}
	workers.Wait()
	rows, _ := p.snapshots()
	for _, row := range rows {
		if row.InFlight != 0 {
			t.Fatal("leaked lease")
		}
	}
}

func TestRemovedAccountCannotPersistLateRefresh(t *testing.T) {
	p := readyPool(1)
	e := p.entries[p.order[0]]
	e.credential.ExpiresAt = time.Now().Unix()
	started, release := make(chan struct{}), make(chan struct{})
	b := &fakeBackend{refreshFn: func(_ context.Context, c credential) (credential, error) {
		close(started)
		<-release
		c.ExpiresAt = time.Now().Add(time.Hour).Unix()
		return c, nil
	}}
	var saved atomic.Int32
	done := make(chan error, 1)
	go func() {
		_, err := p.prepare(context.Background(), e, b, func(context.Context, credential, string, string) error { saved.Add(1); return nil })
		done <- err
	}()
	<-started
	p.remove(e.view.ID, e.view.Generation)
	close(release)
	if err := <-done; !errors.Is(err, context.Canceled) || saved.Load() != 0 {
		t.Fatal("revoked refresh reached credential store")
	}
}

func TestRefreshRequiresDurableAckAndSerializes(t *testing.T) {
	p := readyPool(1)
	e := p.entries[p.order[0]]
	original := e.credential
	e.credential.ExpiresAt = time.Now().Unix()
	if _, err := p.prepare(context.Background(), e, &fakeBackend{}, func(context.Context, credential, string, string) error { return errors.New("keychain_locked") }); err == nil {
		t.Fatal("unpersisted refresh accepted")
	}
	if e.credential.AccessToken != original.AccessToken || e.credential.ExpiresAt > time.Now().Unix() {
		t.Fatal("failed persistence changed credential")
	}
	var refreshed atomic.Int32
	b := &fakeBackend{refreshFn: func(_ context.Context, c credential) (credential, error) {
		refreshed.Add(1)
		c.ExpiresAt = time.Now().Add(time.Hour).Unix()
		return c, nil
	}}
	var group sync.WaitGroup
	for range 10 {
		group.Go(func() {
			if _, err := p.prepare(context.Background(), e, b, noPersist); err != nil {
				t.Error(err)
			}
		})
	}
	group.Wait()
	if refreshed.Load() != 1 {
		t.Fatal("parallel refresh duplicated")
	}
}

func TestCatalogHasNoStaticFallback(t *testing.T) {
	p := newPool([]savedAccount{{Credential: testCredential("a"), Enabled: true, ConcurrencyLimit: 1}})
	p.refreshCatalogs(context.Background(), &fakeBackend{modelsFn: func(context.Context, credential) ([]string, error) { return nil, upstreamError{status: 503} }}, noPersist)
	_, models := p.snapshots()
	if len(models) != 0 {
		t.Fatal("invented models")
	}
	if _, err := p.acquire(context.Background(), testModel, map[string]bool{}); err == nil {
		t.Fatal("unknown catalog was admitted")
	}
	p.refreshCatalogs(context.Background(), &fakeBackend{}, noPersist)
	p.mu.Lock()
	for _, e := range p.entries {
		e.view.CooldownUntil = 0
		e.catalogAt = time.Now().Add(-catalogTTL - time.Second)
	}
	p.mu.Unlock()
	if _, err := p.acquire(context.Background(), testModel, map[string]bool{}); err == nil {
		t.Fatal("stale catalog was admitted")
	}
}

func TestEmptyCatalogDoesNotAdvertiseReady(t *testing.T) {
	p := newPool([]savedAccount{{Credential: testCredential("a"), Enabled: true, ConcurrencyLimit: 1}})
	p.refreshCatalogs(context.Background(), &fakeBackend{modelsFn: func(context.Context, credential) ([]string, error) {
		return []string{}, nil
	}}, noPersist)
	rows, models := p.snapshots()
	if len(rows) != 1 || rows[0].State != "checking" || len(models) != 0 {
		t.Fatal("empty observed catalog advertised a ready account")
	}
	if _, err := p.acquire(context.Background(), testModel, nil); err == nil {
		t.Fatal("empty catalog admitted a request")
	}
	p.refreshCatalogs(context.Background(), &fakeBackend{}, noPersist)
	rows, models = p.snapshots()
	if rows[0].State != "ready" || len(models) != 1 || models[0] != testModel {
		t.Fatal("nonempty observed catalog did not restore readiness")
	}
}

func request(g *gateway, path, body string, headers map[string]string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodPost, "http://127.0.0.1:18081"+path, strings.NewReader(body))
	r.RemoteAddr = "127.0.0.1:9"
	for k, v := range headers {
		r.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	g.ServeHTTP(w, r)
	return w
}
func testGateway(p *pool, b backend) *gateway {
	return &gateway{pool: p, backend: b, persist: noPersist, key: testKey, host: "127.0.0.1:18081", slots: make(chan struct{}, 4)}
}

func TestGatewayRejectsUnauthorizedAndManagement(t *testing.T) {
	g := testGateway(readyPool(1), &fakeBackend{})
	body := `{"model":"fixture-model"}`
	if request(g, "/v1/responses", body, nil).Code != 401 {
		t.Fatal("missing key accepted")
	}
	if request(g, "/v1/responses", body, map[string]string{"Authorization": "Bearer " + testKey, "Origin": "https://example.test"}).Code != 403 {
		t.Fatal("browser request accepted")
	}
	if request(g, "/v0/management/auth-files", body, map[string]string{"Authorization": "Bearer " + testKey}).Code != 404 {
		t.Fatal("management route exposed")
	}
	if request(g, "/v1/responses", `{"model":"not-in-catalog"}`, map[string]string{"Authorization": "Bearer " + testKey}).Code != 404 {
		t.Fatal("unknown model accepted")
	}
	if request(g, "/v1/responses", `{"model":"fixture-model","previous_response_id":"synthetic"}`, map[string]string{"Authorization": "Bearer " + testKey}).Code != 400 {
		t.Fatal("unsupported stateful response accepted")
	}
}

func TestGatewayRoutesBothProtocolsAndRetries429(t *testing.T) {
	p := readyPool(2)
	var calls atomic.Int32
	b := &fakeBackend{executeFn: func(_ context.Context, c credential, _ executor.Request, o executor.Options) (executor.Response, error) {
		calls.Add(1)
		if c.AccountID == testCredential("a").AccountID {
			return executor.Response{}, upstreamError{status: 429, delay: time.Minute}
		}
		if o.SourceFormat != translator.FormatGemini {
			t.Fatal("wrong Gemini translation")
		}
		return executor.Response{Payload: []byte(`{"totalTokens":3}`)}, nil
	}}
	w := request(testGateway(p, b), "/v1beta/models/fixture-model:countTokens", `{"contents":[]}`, map[string]string{"X-Goog-Api-Key": testKey})
	if w.Code != 200 || calls.Load() != 2 || !strings.Contains(w.Body.String(), "totalTokens") {
		t.Fatal("Gemini failover failed")
	}
	rows, _ := p.snapshots()
	if rows[0].State != "cooling" || rows[0].InFlight != 0 || rows[1].InFlight != 0 {
		t.Fatal("account result not reflected")
	}
}

func TestStreamingFailureNeverReplaysAfterOutput(t *testing.T) {
	var calls atomic.Int32
	b := &fakeBackend{streamFn: func(context.Context, credential, executor.Request, executor.Options) (*executor.StreamResult, error) {
		calls.Add(1)
		ch := make(chan executor.StreamChunk, 2)
		ch <- executor.StreamChunk{Payload: []byte("event: response.created\ndata: {}\n\n")}
		ch <- executor.StreamChunk{Err: upstreamError{status: 429}}
		close(ch)
		return &executor.StreamResult{Chunks: ch}, nil
	}}
	w := request(testGateway(readyPool(2), b), "/v1/responses", `{"model":"fixture-model","stream":true}`, map[string]string{"Authorization": "Bearer " + testKey})
	if w.Code != 200 || calls.Load() != 1 || !strings.Contains(w.Body.String(), "upstream_stream_failed") {
		t.Fatal("partial stream replayed or hidden")
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestSDKTranslatesResponsesAndGeminiOffline(t *testing.T) {
	b := newBackend("")
	var upstreamCalls atomic.Int32
	b.transport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		upstreamCalls.Add(1)
		if r.URL.Host != "daily-cloudcode-pa.googleapis.com" || r.Header.Get("Authorization") != "Bearer synthetic-access" {
			t.Fatal("unexpected upstream binding")
		}
		data, _ := io.ReadAll(r.Body)
		if !bytes.Contains(data, []byte(`"project":"synthetic-project"`)) || !bytes.Contains(data, []byte(`"contents"`)) {
			t.Fatal("request not translated")
		}
		return &http.Response{StatusCode: 200, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(`{"response":{"candidates":[{"content":{"role":"model","parts":[{"text":"fixture answer"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":2,"totalTokenCount":3},"responseId":"fixture-response"}}`))}, nil
	})
	for _, format := range []translator.Format{translator.FormatOpenAIResponse, translator.FormatGemini} {
		body := []byte(`{"model":"gemini-3-flash","input":"fixture request"}`)
		if format == translator.FormatGemini {
			body = []byte(`{"contents":[{"role":"user","parts":[{"text":"fixture request"}]}]}`)
		}
		result, err := b.execute(context.Background(), testCredential("a"), executor.Request{Model: "gemini-3-flash", Payload: body, Format: format}, executor.Options{SourceFormat: format, ResponseFormat: format, OriginalRequest: body, Headers: http.Header{}})
		if err != nil || !json.Valid(result.Payload) || !bytes.Contains(result.Payload, []byte("fixture answer")) {
			t.Fatal("SDK response translation failed")
		}
	}
	if upstreamCalls.Load() != 2 {
		t.Fatal("unexpected auxiliary upstream calls")
	}
}

func TestGoogleTransportRejectsCredentialRedirectTargets(t *testing.T) {
	called := false
	transport := googleTransport{base: roundTripFunc(func(*http.Request) (*http.Response, error) { called = true; return nil, nil })}
	for _, endpoint := range []string{"https://example.test/token", "http://oauth2.googleapis.com/token", "https://oauth2.googleapis.com:444/token", "https://user@oauth2.googleapis.com/token"} {
		r, _ := http.NewRequest("POST", endpoint, nil)
		if _, err := transport.RoundTrip(r); err == nil {
			t.Fatal("foreign credential destination accepted")
		}
	}
	r, _ := http.NewRequest("POST", "https://oauth2.googleapis.com/token", nil)
	r.Response = &http.Response{StatusCode: http.StatusTemporaryRedirect}
	if _, err := transport.RoundTrip(r); err == nil {
		t.Fatal("same-origin credential redirect accepted")
	}
	if _, err := transport.RoundTrip(nil); err == nil {
		t.Fatal("nil request accepted")
	}
	if called {
		t.Fatal("rejected destination reached transport")
	}
}

func TestStrictIPCAndStartupLimits(t *testing.T) {
	var s startup
	if decodeStrict([]byte(`{"schemaVersion":1,"arbitraryConfig":true}`), &s) == nil {
		t.Fatal("arbitrary config accepted")
	}
	if decodeStrict([]byte(`{} {}`), &s) == nil {
		t.Fatal("extra command accepted")
	}
	s = startup{SchemaVersion: 1, ClientKey: testKey, Port: 18081, Accounts: []savedAccount{{Credential: testCredential("a"), Enabled: true, ConcurrencyLimit: 1}}}
	if s.validate() != nil {
		t.Fatal("valid bootstrap rejected")
	}
	s.Accounts = append(s.Accounts, s.Accounts[0])
	if s.validate() == nil {
		t.Fatal("duplicate account accepted")
	}
}

func TestProviderPoolAndModelCatalogAreIsolated(t *testing.T) {
	p := readyPool(1)
	other := testCredential("b")
	other.Provider = "claude"
	other.AccountID = "claude-" + strings.Repeat("b", 32)
	other.ProjectID = ""
	if err := other.validate(); err != nil {
		t.Fatal("typed provider credential rejected")
	}
	p.add(savedAccount{Credential: other, Enabled: true, ConcurrencyLimit: 1})
	p.mu.Lock()
	e := p.entries[other.AccountID]
	e.catalogAt = time.Now()
	e.view.State = "ready"
	e.view.Models = []string{testModel, "claude-only-fixture"}
	p.mu.Unlock()
	for _, provider := range []string{"antigravity", "claude"} {
		l, err := p.acquireProvider(context.Background(), provider, testModel, map[string]bool{})
		if err != nil || l.entry.credential.Provider != provider {
			t.Fatal("same-name model crossed provider")
		}
		l.finish(nil)
	}
	_, legacy := p.snapshotsForProvider("antigravity")
	if len(legacy) != 1 || legacy[0] != testModel {
		t.Fatal("catalog crossed provider")
	}
	_, claude := p.snapshotsForProvider("claude")
	if len(claude) != 2 {
		t.Fatal("provider catalog lost real model")
	}
	var selected string
	b := &fakeBackend{executeFn: func(_ context.Context, c credential, _ executor.Request, o executor.Options) (executor.Response, error) {
		selected = c.Provider
		if o.SourceFormat != translator.FormatOpenAIResponse {
			t.Fatal("wrong Responses source format")
		}
		return executor.Response{Payload: []byte(`{"ok":true}`)}, nil
	}}
	g := testGateway(p, b)
	w := request(g, "/providers/claude/v1/responses", `{"model":"fixture-model"}`, map[string]string{"Authorization": "Bearer " + testKey})
	if w.Code != 200 || selected != "claude" {
		t.Fatal("provider route failed")
	}
	w = request(g, "/v1/responses", `{"model":"fixture-model"}`, map[string]string{"Authorization": "Bearer " + testKey})
	if w.Code != 200 || selected != "antigravity" {
		t.Fatal("legacy route was not Antigravity-only")
	}
	if request(g, "/providers/unknown/v1/responses", `{"model":"fixture-model"}`, map[string]string{"Authorization": "Bearer " + testKey}).Code != 404 {
		t.Fatal("unregistered provider accepted")
	}
}

func TestGatewayPassesNativeClaudeAndChatFormats(t *testing.T) {
	for _, test := range []struct {
		path   string
		format translator.Format
		count  bool
	}{
		{"/v1/messages", translator.FormatClaude, false},
		{"/v1/messages/count_tokens", translator.FormatClaude, true},
		{"/v1/chat/completions", translator.FormatOpenAI, false},
	} {
		t.Run(test.path, func(t *testing.T) {
			b := &fakeBackend{executeFn: func(_ context.Context, _ credential, _ executor.Request, o executor.Options) (executor.Response, error) {
				if o.SourceFormat != test.format || o.ResponseFormat != test.format {
					t.Fatal("native protocol misrouted")
				}
				if o.Headers.Get("Authorization") != "" || o.Headers.Get("X-Api-Key") != "" {
					t.Fatal("local key forwarded upstream")
				}
				return executor.Response{Payload: []byte(`{"ok":true}`)}, nil
			}}
			w := request(testGateway(readyPool(1), b), test.path, `{"model":"fixture-model","messages":[]}`, map[string]string{"X-Api-Key": testKey})
			if w.Code != 200 {
				t.Fatal("native route rejected")
			}
		})
	}
}

func TestCatalogExcludesExplicitlyEmptyOrExpiredQuota(t *testing.T) {
	now := time.Date(2026, 10, 22, 0, 0, 0, 0, time.UTC)
	data := []byte(`{"models":{
		"available":{"quotaInfo":{"remainingFraction":0.5,"resetTime":"2026-10-23T00:00:00Z"}},
		"exhausted":{"quotaInfo":{"remainingFraction":0,"resetTime":"2026-10-23T00:00:00Z"}},
		"expired":{"quotaInfo":{"remainingFraction":0.5,"resetTime":"2026-10-21T00:00:00Z"}},
		"bad":{"quotaInfo":{"remainingFraction":2}},
		"unknown":{}}}`)
	models, err := availableAntigravityModels(data, now)
	if err != nil || len(models) != 2 || models[0] != "available" || models[1] != "unknown" {
		t.Fatal("exhausted or expired quota was advertised")
	}
}

func TestFirstStreamChunkSkipsEmptyAndCancels(t *testing.T) {
	chunks := make(chan executor.StreamChunk, 2)
	chunks <- executor.StreamChunk{}
	chunks <- executor.StreamChunk{Err: upstreamError{status: 429}}
	first, ok := firstStreamChunk(context.Background(), chunks)
	if !ok || first.Err == nil || statusCode(first.Err) != 429 {
		t.Fatal("empty chunk committed response")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	first, ok = firstStreamChunk(ctx, make(chan executor.StreamChunk))
	if !ok || !errors.Is(first.Err, context.Canceled) {
		t.Fatal("silent stream ignored cancellation")
	}
}
