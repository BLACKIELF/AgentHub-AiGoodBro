package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/klauspost/compress/zstd"
	"github.com/router-for-me/CLIProxyAPI/v8/internal/registry"
)

func modelRequest(t *testing.T, s startup, endpoint, model string, stream bool) *http.Response {
	t.Helper()
	body, _ := json.Marshal(map[string]any{
		"model": model, "input": "synthetic", "stream": stream,
		"reasoning": map[string]string{"effort": "max", "summary": "auto"},
		"tools":     []any{map[string]any{"type": "function", "name": "fixture_tool", "parameters": map[string]any{"type": "object"}}},
	})
	req, _ := http.NewRequest(http.MethodPost, endpoint, strings.NewReader(string(body)))
	req.Header.Set("Authorization", "Bearer "+s.ClientKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func TestResponseModelOutsideStartupCatalog(t *testing.T) {
	for _, route := range []string{"/v1/responses", "/responses", "/v1/responses/compact", "/responses/compact"} {
		for _, stream := range []bool{false, true} {
			if stream && strings.HasSuffix(route, "/compact") {
				continue
			}
			t.Run(fmt.Sprintf("%s/stream=%t", route, stream), func(t *testing.T) {
				b := newFakeBridge(t)
				s := newStartup(t, b)
				var expected atomic.Value
				var calls atomic.Int32
				upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					calls.Add(1)
					if !b.hasLease("A") || r.Header.Get("Authorization") != "Bearer fixture-A" {
						t.Error("request bypassed protected admission")
					}
					var body map[string]any
					if json.NewDecoder(r.Body).Decode(&body) != nil || body["model"] != expected.Load() {
						t.Error("upstream did not receive the exact requested model")
					}
					reasoning, _ := body["reasoning"].(map[string]any)
					tools, _ := body["tools"].([]any)
					retainedTool := false
					for _, tool := range tools {
						value, _ := tool.(map[string]any)
						if value["type"] == "function" && value["name"] == "fixture_tool" {
							retainedTool = true
						}
					}
					if reasoning["effort"] != "max" || reasoning["summary"] != "auto" || !retainedTool {
						t.Errorf("model routing changed effort=%v summary=%v toolCount=%d", reasoning["effort"], reasoning["summary"], len(tools))
					}
					if strings.HasSuffix(route, "/compact") {
						if r.URL.Path != "/responses/compact" {
							t.Error("wrong compact upstream route")
						}
						w.Header().Set("Content-Type", "application/json")
						_, _ = io.WriteString(w, `{"id":"fixture-compact","object":"response.compaction","output":[]}`)
						return
					}
					complete(w, "A")
				}))
				defer upstream.Close()
				_, server, _ := startTestRuntime(t, s, upstream.URL)
				// A saved model, an unseen future ID and an existing menu entry
				// must use the same route without aliases or a silent downgrade.
				for _, model := range []string{"gpt-6.1-sol", "fixture-future-model", "fixture-model"} {
					expected.Store(model)
					resp := modelRequest(t, s, server.URL+route, model, stream)
					body := consume(t, resp)
					if resp.StatusCode != http.StatusOK {
						t.Fatalf("model %s: status %d: %s", model, resp.StatusCode, body)
					}
					waitEmpty(t, b)
				}
				if calls.Load() != 3 {
					t.Fatal("request was dropped or replayed")
				}
			})
		}
	}
}

func TestUnlistedModelReturnsUpstreamRejection(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	var calls atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		var body map[string]any
		if json.NewDecoder(r.Body).Decode(&body) != nil || body["model"] != "fixture-unavailable-model" {
			t.Error("model rejection triggered a silent model substitution")
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		_, _ = io.WriteString(w, `{"error":{"message":"fixture upstream rejects this model","type":"invalid_request_error","code":"model_not_found"}}`)
	}))
	defer upstream.Close()
	_, server, _ := startTestRuntime(t, s, upstream.URL)
	resp := modelRequest(t, s, server.URL+"/v1/responses", "fixture-unavailable-model", false)
	body := consume(t, resp)
	if resp.StatusCode != http.StatusBadRequest || !strings.Contains(body, "fixture upstream rejects this model") || strings.Contains(body, "unknown provider") {
		t.Fatalf("upstream error not preserved: status %d: %s", resp.StatusCode, body)
	}
	waitEmpty(t, b)
	// The existing manager may check the other admitted account's entitlement,
	// but must stay bounded and retain the same requested model on every attempt.
	if calls.Load() < 1 || calls.Load() > int32(len(s.Accounts)) {
		t.Fatalf("unexpected upstream attempts: %d", calls.Load())
	}
}

func TestChatGPTModelRejectionDoesNotCoolOrRetryAccounts(t *testing.T) {
	for _, stream := range []bool{false, true} {
		t.Run(fmt.Sprintf("stream=%t", stream), func(t *testing.T) {
			b := newFakeBridge(t)
			s := newStartup(t, b)
			var calls atomic.Int32
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				var body struct {
					Model string `json:"model"`
				}
				_ = json.NewDecoder(r.Body).Decode(&body)
				if body.Model == "gpt-6.1-sol" {
					w.Header().Set("Content-Type", "application/json")
					w.WriteHeader(http.StatusBadRequest)
					_, _ = io.WriteString(w, `{"detail":"The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account."}`)
					return
				}
				complete(w, "A")
			}))
			defer upstream.Close()
			rt, server, _ := startTestRuntime(t, s, upstream.URL)
			resp := modelRequest(t, s, server.URL+"/v1/responses", "gpt-6.1-sol", stream)
			body := consume(t, resp)
			if resp.StatusCode != http.StatusBadRequest || !strings.Contains(body, "not supported when using Codex with a ChatGPT account") {
				t.Fatalf("original model rejection lost: status %d", resp.StatusCode)
			}
			waitEmpty(t, b)
			if calls.Load() != 1 {
				t.Fatalf("rejected request tried %d accounts", calls.Load())
			}
			rows, err := rt.store.Load(context.Background())
			if err != nil || len(rows) != 0 {
				t.Fatal("model rejection persisted credential cooldown")
			}
			for _, id := range rt.ids {
				a, _ := rt.manager.GetByID(id)
				if a.NextRetryAfter.After(time.Now()) || a.Unavailable {
					t.Fatal("model rejection disabled account")
				}
			}
			resp = modelRequest(t, s, server.URL+"/v1/responses", "fixture-model", stream)
			consume(t, resp)
			if resp.StatusCode != http.StatusOK || calls.Load() != 2 {
				t.Fatal("another model was blocked or replayed")
			}
			waitEmpty(t, b)
		})
	}
}

func TestModelRegistrationPreservesCooldownAcrossExpansionAndRestart(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	var callsMu sync.Mutex
	var calls []string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer fixture-")
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		model, _ := body["model"].(string)
		callsMu.Lock()
		calls = append(calls, id+":"+model)
		callsMu.Unlock()
		if id == "A" && model == "gpt-6.1-sol" {
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = fmt.Fprintf(w, `{"error":{"type":"usage_limit_reached","message":"limit","resets_at":%d}}`, time.Now().Add(120*time.Second).Unix())
			return
		}
		complete(w, id)
	}))
	defer upstream.Close()
	rt, server, _ := startTestRuntime(t, s, upstream.URL)
	turn := func(model string) {
		r := modelRequest(t, s, server.URL+"/v1/responses", model, false)
		_ = consume(t, r)
		if r.StatusCode != 200 {
			t.Fatalf("turn failed: %d", r.StatusCode)
		}
		waitEmpty(t, b)
	}
	turn("gpt-6.1-sol")
	turn("fixture-another-model")
	turn("gpt-6.1-sol")
	server.Close()
	rt.close()
	rt, server, _ = startTestRuntime(t, s, upstream.URL)
	// Expand the new runtime before touching the saved model. Reconciliation
	// must not prune its restored cooldown just because it is absent from s.Models.
	turn("fixture-after-restart")
	turn("gpt-6.1-sol")
	callsMu.Lock()
	defer callsMu.Unlock()
	var limitedModelCalls []string
	for _, call := range calls {
		if strings.HasSuffix(call, ":gpt-6.1-sol") {
			limitedModelCalls = append(limitedModelCalls, strings.Split(call, ":")[0])
		}
	}
	if strings.Join(limitedModelCalls, ",") != "A,B,B,B" {
		t.Fatalf("model cooldown was lost: %v", limitedModelCalls)
	}
	if !registry.GetGlobalRegistry().IsModelQuotaExceededForClient("A", "gpt-6.1-sol") {
		t.Fatal("registration cleared the active quota projection")
	}
}

func TestInvalidOrUnauthenticatedModelDoesNotReachAdmission(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	var calls atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls.Add(1) }))
	defer upstream.Close()
	rt, server, _ := startTestRuntime(t, s, upstream.URL)
	for _, body := range []string{`{`, `{}`, `{"model":null}`, `{"model":42}`, `{"model":""}`, `{"model":"other/provider"}`, `{"model":" model"}`, `{"model":"` + strings.Repeat("a", 129) + `"}`} {
		req, _ := http.NewRequest(http.MethodPost, server.URL+"/v1/responses", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+s.ClientKey)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		_ = consume(t, resp)
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("invalid model accepted: %d", resp.StatusCode)
		}
	}
	unauthorized := s
	unauthorized.ClientKey = "wrong"
	resp := modelRequest(t, unauthorized, server.URL+"/v1/responses", "fixture-unauthorized-model", false)
	_ = consume(t, resp)
	if resp.StatusCode != http.StatusUnauthorized || calls.Load() != 0 || len(rt.models) != 2 {
		t.Fatal("rejected request mutated model registry or reached upstream")
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if len(b.acquired) != 0 || len(b.commands) != 0 {
		t.Fatal("rejected request acquired a lease or read the pool")
	}
}

func TestConcurrentModelRegistrationIsBoundedAndKeepsCatalog(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	rt, server, _ := startTestRuntime(t, s, "http://127.0.0.1:1")
	var wg sync.WaitGroup
	for i := 0; i < 32; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			if err := rt.ensureResponseModel(context.Background(), fmt.Sprintf("fixture-concurrent-%d", i%8)); err != nil {
				t.Error(err)
			}
		}(i)
	}
	wg.Wait()
	for _, account := range s.Accounts {
		for i := 0; i < 8; i++ {
			if !registry.GetGlobalRegistry().ClientSupportsModel(account.ID, fmt.Sprintf("fixture-concurrent-%d", i)) {
				t.Fatal("concurrent registration lost a model")
			}
		}
	}
	req, _ := http.NewRequest(http.MethodGet, server.URL+"/v1/models", nil)
	req.Header.Set("Authorization", "Bearer "+s.ClientKey)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body := consume(t, resp)
	if resp.StatusCode != 200 || strings.Contains(body, "fixture-concurrent") || strings.Contains(body, nativeImageModel) || !strings.Contains(body, "fixture-model") {
		t.Fatal("routing observations were advertised as available models")
	}
	// Fill the private map without 1000 registry rebuilds: only the rejection
	// path is under test here, and it must make no partial registration.
	for len(rt.models) < maximumRoutedModels {
		id := fmt.Sprintf("fixture-limit-%d", len(rt.models))
		rt.models[id] = proxyModelInfo(id)
	}
	if err := rt.ensureResponseModel(context.Background(), "fixture-over-limit"); err == nil || len(rt.models) != maximumRoutedModels || registry.GetGlobalRegistry().ClientSupportsModel("A", "fixture-over-limit") {
		t.Fatal("model routing capacity did not fail closed")
	}
}

func TestCompressedResponseModelPreservesBody(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		if json.NewDecoder(r.Body).Decode(&body) != nil || body["model"] != "fixture-compressed-model" {
			t.Error("compressed model was lost")
		}
		complete(w, "A")
	}))
	defer upstream.Close()
	_, server, _ := startTestRuntime(t, s, upstream.URL)
	encoder, err := zstd.NewWriter(nil)
	if err != nil {
		t.Fatal(err)
	}
	defer encoder.Close()
	body := encoder.EncodeAll([]byte(`{"model":"fixture-compressed-model","input":"synthetic"}`), nil)
	req, _ := http.NewRequest(http.MethodPost, server.URL+"/v1/responses", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+s.ClientKey)
	req.Header.Set("Content-Encoding", "zstd")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_ = consume(t, resp)
	if resp.StatusCode != 200 {
		t.Fatalf("compressed request failed: %d", resp.StatusCode)
	}
	waitEmpty(t, b)
}

func TestInvalidThinkingSuffixDoesNotReachAdmission(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	var calls atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		complete(w, "A")
	}))
	defer upstream.Close()
	rt, server, _ := startTestRuntime(t, s, upstream.URL)
	for _, suffix := range []string{"", "unknown", "high/other", "high\n", "-2", "9223372036854775808", "high)(low"} {
		resp := modelRequest(t, s, server.URL+"/v1/responses", "fixture-invalid-suffix("+suffix+")", false)
		body := consume(t, resp)
		if resp.StatusCode != http.StatusBadRequest || !strings.Contains(body, `"code":"invalid_model"`) {
			t.Errorf("invalid suffix %q was accepted: status %d", suffix, resp.StatusCode)
		}
		waitEmpty(t, b)
	}
	if calls.Load() != 0 || len(rt.models) != 2 {
		t.Error("invalid suffix registered a model or reached upstream")
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if len(b.acquired) != 0 || len(b.commands) != 0 {
		t.Error("invalid suffix reached protected admission")
	}
}

func TestResponseThinkingSuffixPreservesSelection(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	var expected atomic.Value
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		if json.NewDecoder(r.Body).Decode(&body) != nil || body["model"] != "fixture-suffix-model" {
			t.Error("thinking suffix changed the underlying model")
		}
		reasoning, _ := body["reasoning"].(map[string]any)
		if reasoning["effort"] != expected.Load() || reasoning["summary"] != "auto" || !b.hasLease("A") {
			t.Errorf("thinking suffix lost intent or admission: effort=%v", reasoning["effort"])
		}
		complete(w, "A")
	}))
	defer upstream.Close()
	_, server, _ := startTestRuntime(t, s, upstream.URL)
	for _, tc := range []struct{ suffix, effort string }{{"high", "high"}, {"MAX", "max"}, {"0", "none"}, {"-1", "auto"}} {
		expected.Store(tc.effort)
		resp := modelRequest(t, s, server.URL+"/v1/responses", "fixture-suffix-model("+tc.suffix+")", false)
		body := consume(t, resp)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("valid thinking suffix rejected: status %d: %s", resp.StatusCode, body)
		}
		waitEmpty(t, b)
	}
}

func TestCanceledModelRegistrationLeavesCatalogUnchanged(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	rt, _, _ := startTestRuntime(t, s, "http://127.0.0.1:1")
	ctx, cancel := context.WithCancel(context.Background())
	rt.modelMu.Lock()
	result := make(chan error, 1)
	started := make(chan struct{})
	go func() {
		close(started)
		result <- rt.ensureResponseModel(ctx, "fixture-canceled-model")
	}()
	<-started
	cancel()
	rt.modelMu.Unlock()
	if err := <-result; !errors.Is(err, context.Canceled) {
		t.Errorf("canceled registration returned %v", err)
	}
	if len(rt.models) != 2 || registry.GetGlobalRegistry().ClientSupportsModel("A", "fixture-canceled-model") {
		t.Error("canceled registration mutated the catalog")
	}
	for _, model := range []string{"fixture-model", "fixture-canceled-http-model"} {
		req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"`+model+`","input":"synthetic"}`)).WithContext(ctx)
		req.Header.Set("Authorization", "Bearer "+s.ClientKey)
		reply := httptest.NewRecorder()
		rt.handler.ServeHTTP(reply, req)
		if reply.Code != http.StatusRequestTimeout || len(rt.models) != 2 {
			t.Error("canceled request reached routing or returned a capacity error")
		}
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if len(b.acquired) != 0 || len(b.commands) != 0 {
		t.Error("canceled request reached protected admission")
	}
}

func TestAllAccountsCoolingRemainRoutableWithoutNewLeases(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	var calls atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = fmt.Fprintf(w, `{"error":{"type":"usage_limit_reached","message":"limit","resets_at":%d}}`, time.Now().Add(120*time.Second).Unix())
	}))
	defer upstream.Close()
	rt, server, _ := startTestRuntime(t, s, upstream.URL)
	for i := 0; i < 2; i++ {
		resp := modelRequest(t, s, server.URL+"/v1/responses", "fixture-all-cooling-model", false)
		body := consume(t, resp)
		if resp.StatusCode != http.StatusTooManyRequests || strings.Contains(body, "unknown provider") {
			t.Fatalf("cooldown became a routing error: status %d: %s", resp.StatusCode, body)
		}
		waitEmpty(t, b)
		if i == 0 {
			if err := rt.ensureResponseModel(context.Background(), "fixture-expand-during-cooldown"); err != nil {
				t.Fatal(err)
			}
		}
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if calls.Load() != int32(len(s.Accounts)) || len(b.acquired) != len(s.Accounts) {
		t.Fatal("catalog expansion allowed reuse of a cooling account")
	}
}
