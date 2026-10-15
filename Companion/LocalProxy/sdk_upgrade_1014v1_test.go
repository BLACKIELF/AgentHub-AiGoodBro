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
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	provider "github.com/router-for-me/CLIProxyAPI/v8/internal/runtime/executor"
	auth "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
	executor "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/executor"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/config"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/translator"
)

type sdkTransport1014 func(*http.Request) (*http.Response, error)

func (f sdkTransport1014) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// A closed HTTP/2 client connection must not poison an account, or enable an
// automatic replay when the production adapter's RequestRetry remains zero.
func TestSDKHTTP2ClosedConnectionNoCooldownOrReplay1014(t *testing.T) {
	for _, message := range []string{"http2: client connection force closed via ClientConn.Close", "http2: client conn is closed"} {
		for _, stream := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/stream=%t", message, stream), func(t *testing.T) {
				b := newFakeBridge(t)
				b.order = []string{"A"}
				s := newStartup(t, b)
				s.Accounts = s.Accounts[:1]
				upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { complete(w, "A") }))
				t.Cleanup(upstream.Close)
				rt, server, _ := startTestRuntime(t, s, upstream.URL)
				var attempts atomic.Int32
				rt.manager.SetRoundTripperProvider(transportProvider{origin: upstream.URL, transport: sdkTransport1014(func(r *http.Request) (*http.Response, error) {
					if attempts.Add(1) == 1 {
						return nil, errors.New(message)
					}
					return rt.transport.RoundTrip(r)
				})})
				response := request(t, s, server.URL, stream)
				consume(t, response)
				waitEmpty(t, b)
				if response.StatusCode == http.StatusOK || attempts.Load() != 1 {
					t.Fatalf("closed connection was replayed: status=%d attempts=%d", response.StatusCode, attempts.Load())
				}
				a, _ := rt.manager.GetByID("A")
				if a.Unavailable || !a.NextRetryAfter.IsZero() || a.Quota.Exceeded {
					t.Fatal("HTTP/2 connection lifecycle failure cooled the credential")
				}
				if state := a.ModelStates["fixture-model"]; state != nil && (state.Unavailable || !state.NextRetryAfter.IsZero() || state.Quota.Exceeded) {
					t.Fatal("HTTP/2 connection lifecycle failure cooled the model")
				}
				response = request(t, s, server.URL, stream)
				body := consume(t, response)
				waitEmpty(t, b)
				if response.StatusCode != http.StatusOK || !strings.Contains(body, "done-A") || attempts.Load() != 2 || !reflect.DeepEqual(acquiredSnapshot(b), []string{"A", "A"}) {
					t.Fatalf("a separate new request could not reuse the credential: status=%d attempts=%d", response.StatusCode, attempts.Load())
				}
			})
		}
	}
}

func TestSDKSplitSSEEventsLoopback1014(t *testing.T) {
	for _, newline := range []string{"\n", "\r\n"} {
		for _, mode := range []string{"nonstream", "bootstrap", "started"} {
			t.Run(fmt.Sprintf("%q/%s", newline, mode), func(t *testing.T) {
				b := newFakeBridge(t)
				s := newStartup(t, b)
				upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					if !b.hasLease("A") {
						t.Error("split SSE request arrived without host admission")
					}
					w.Header().Set("Content-Type", "text/event-stream")
					if mode == "started" {
						sse(w, map[string]any{"type": "response.output_text.delta", "delta": "done-split"})
					}
					parts := []string{
						`event: response.completed`,
						`data: {"type":"response.completed","response":{"id":"resp_split","object":"response","status":"completed",`,
						`data: "model":"fixture-model","output":[{"type":"message","role":"assistant",`,
						`data: "content":[{"type":"output_text","text":"done-split"}]}],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}`,
						"", "",
					}
					_, _ = io.WriteString(w, strings.Join(parts, newline))
					w.(http.Flusher).Flush()
					if mode != "nonstream" {
						<-r.Context().Done()
					}
				}))
				t.Cleanup(upstream.Close)
				_, server, _ := startTestRuntime(t, s, upstream.URL)
				ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
				defer cancel()
				payload := fmt.Sprintf(`{"model":"fixture-model","input":"synthetic","stream":%t}`, mode != "nonstream")
				req, err := http.NewRequestWithContext(ctx, http.MethodPost, server.URL+"/v1/responses", strings.NewReader(payload))
				if err != nil {
					t.Fatal(err)
				}
				req.Header.Set("Authorization", "Bearer "+s.ClientKey)
				req.Header.Set("Content-Type", "application/json")
				response, err := http.DefaultClient.Do(req)
				if err != nil {
					t.Fatal(err)
				}
				body := consume(t, response)
				if response.StatusCode != http.StatusOK || !strings.Contains(body, "done-split") || strings.Contains(body, "stream error") {
					t.Fatalf("split event failed: status=%d", response.StatusCode)
				}
				if mode == "nonstream" {
					if !json.Valid([]byte(body)) {
						t.Fatal("split nonstream response was incomplete JSON")
					}
				} else {
					terminal := false
					for _, line := range strings.Split(body, "\n") {
						if strings.HasPrefix(line, "data:") && strings.Contains(line, "response.completed") {
							terminal = json.Valid([]byte(strings.TrimSpace(strings.TrimPrefix(line, "data:"))))
						}
					}
					if !terminal {
						t.Fatal("split terminal SSE event was not assembled into complete JSON")
					}
				}
				waitEmpty(t, b)
				waitForBridgeCommandCount(t, b, "order_end", 1)
				if b.snapshotCount() != 0 || !reflect.DeepEqual(acquiredSnapshot(b), []string{"A"}) {
					t.Fatal("split SSE response retained its order snapshot or replayed another account")
				}
			})
		}
	}
}

// Preserve cancellation timing deterministically around a real Codex HTTP error.
// The base executor still parses the upstream status, quota scope and RetryAfter.
type sdkCanceledStream1014 struct {
	auth.ProviderExecutor
	bootstrap bool
	plain     bool
	calls     atomic.Int32
}

func (e *sdkCanceledStream1014) ExecuteStream(ctx context.Context, a *auth.Auth, req executor.Request, opts executor.Options) (*executor.StreamResult, error) {
	e.calls.Add(1)
	err := error(context.Canceled)
	if !e.plain {
		result, upstreamErr := e.ProviderExecutor.ExecuteStream(ctx, a, req, opts)
		if result != nil || upstreamErr == nil {
			return nil, errors.New("quota fixture did not return a synchronous upstream rejection")
		}
		err = upstreamErr
	}
	scopeFrom(ctx).cancel()
	if !e.bootstrap {
		return nil, err
	}
	chunks := make(chan executor.StreamChunk, 1)
	chunks <- executor.StreamChunk{Err: err}
	close(chunks)
	return &executor.StreamResult{Chunks: chunks}, nil
}

func TestSDKCanceledStreamRetainsOnlyConfirmedQuota1014(t *testing.T) {
	for _, bootstrap := range []bool{false, true} {
		for _, plain := range []bool{false, true} {
			t.Run(fmt.Sprintf("bootstrap=%t/plain=%t", bootstrap, plain), func(t *testing.T) {
				b := newFakeBridge(t)
				s := newStartup(t, b)
				var upstreamCalls atomic.Int32
				upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					upstreamCalls.Add(1)
					if !b.hasLease("A") {
						t.Error("quota request arrived without host admission")
					}
					w.Header().Set("Content-Type", "application/json")
					w.WriteHeader(http.StatusTooManyRequests)
					_, _ = io.WriteString(w, `{"error":{"type":"usage_limit_reached","message":"synthetic-upstream-quota-detail","resets_in_seconds":600}}`)
				}))
				t.Cleanup(upstream.Close)
				rt, _, events := startTestRuntime(t, s, upstream.URL)
				cfg := &config.Config{}
				cfg.Codex.DisableCodexCloaking = true
				cfg.Codex.StreamBootstrapBuffering = true
				fixture := &sdkCanceledStream1014{ProviderExecutor: provider.NewCodexExecutor(cfg), bootstrap: bootstrap, plain: plain}
				rt.manager.RegisterExecutor(fixture)
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				scope := &requestScope{id: uuid.NewString(), ctx: ctx, cancel: cancel, bridge: rt.selector.bridge, events: rt.selector.events, recovery: rt.recovery, responseHeader: make(http.Header), done: make(chan struct{}), exited: make(chan struct{})}
				go scope.heartbeats()
				closed := atomic.Bool{}
				closeScope := func() {
					if closed.CompareAndSwap(false, true) {
						scope.close()
					}
				}
				t.Cleanup(closeScope)
				ctx = context.WithValue(ctx, scopeKey{}, scope)
				_, err := rt.manager.ExecuteStream(ctx, []string{"codex"}, executor.Request{Model: "fixture-model", Payload: []byte(`{"model":"fixture-model","input":"synthetic","stream":true}`)}, executor.Options{Stream: true, SourceFormat: translator.FormatOpenAIResponse})
				if !errors.Is(err, context.Canceled) || fixture.calls.Load() != 1 {
					t.Fatal("canceled execution changed its cancellation result or replayed")
				}
				closeScope()
				waitEmpty(t, b)
				if !reflect.DeepEqual(acquiredSnapshot(b), []string{"A"}) {
					t.Fatal("canceled stream admitted another account")
				}
				a, _ := rt.manager.GetByID("A")
				rows, loadErr := rt.store.Load(context.Background())
				if loadErr != nil {
					t.Fatal(loadErr)
				}
				if plain {
					if upstreamCalls.Load() != 0 || a.Unavailable || !a.NextRetryAfter.IsZero() || a.Quota.Exceeded || len(rows) != 0 {
						t.Fatal("plain cancellation invented a credential cooldown")
					}
					return
				}
				if upstreamCalls.Load() != 1 || !a.Quota.Exceeded || !a.NextRetryAfter.After(time.Now().Add(9*time.Minute)) || !isCredentialQuotaError(a.LastError) || len(rows) == 0 {
					t.Fatal("cancellation dropped confirmed upstream quota, deadline or persistence")
				}
				if state := a.ModelStates["fixture-model"]; state == nil || !state.Quota.Exceeded || !state.NextRetryAfter.Equal(a.NextRetryAfter) {
					t.Fatal("cancellation dropped the triggering model cooldown")
				}
				encoded, _ := json.Marshal(rows)
				if bytes.Contains(encoded, []byte("synthetic-upstream-quota-detail")) || strings.Contains(events.String(), "synthetic-upstream-quota-detail") {
					t.Fatal("cooldown persistence or host events exposed upstream error details")
				}
			})
		}
	}
}

func TestSDKToolSchemaIntegerBoundsLoopback1014(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	checked := make(chan bool, 1)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestBytes, _ := io.ReadAll(r.Body)
		r.Body = io.NopCloser(bytes.NewReader(requestBytes))
		var body struct {
			Tools []struct {
				Type       string `json:"type"`
				Parameters struct {
					Properties map[string]map[string]json.RawMessage `json:"properties"`
				} `json:"parameters"`
			} `json:"tools"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("tool schema request was not valid JSON (bytes=%d)", len(requestBytes))
			checked <- false
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		var props map[string]map[string]json.RawMessage
		for _, tool := range body.Tools {
			if tool.Type == "function" {
				props = tool.Parameters.Properties
				break
			}
		}
		if props == nil {
			t.Error("normalized request did not contain a function tool")
			checked <- false
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		for _, key := range []string{"minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"} {
			if _, exists := props["overflow"][key]; exists {
				t.Errorf("out-of-range integer schema %s reached upstream", key)
			}
		}
		for name, want := range map[string]string{"minimum": "-9223372036854775808", "maximum": "9223372036854775807"} {
			if string(props["exact"][name]) != want {
				t.Errorf("valid int64 %s lost precision", name)
			}
		}
		if string(props["fraction"]["maximum"]) != "18446744073709552000.0001" || string(props["seed"]["minimum"]) != "0" || string(props["seed"]["type"]) != `"integer"` {
			t.Error("numeric schema normalization changed valid bounds or types")
		}
		var defaults map[string]json.RawMessage
		if json.Unmarshal(props["user_data"]["default"], &defaults) != nil || string(defaults["maximum"]) != "18446744073709552000" {
			t.Error("numeric schema normalization deleted user data")
		}
		if !b.hasLease("A") {
			t.Error("tool schema request arrived without host admission")
		}
		checked <- true
		complete(w, "A")
	}))
	t.Cleanup(upstream.Close)
	_, server, _ := startTestRuntime(t, s, upstream.URL)
	payload := `{"model":"fixture-model","input":"synthetic","stream":false,"tools":[{"type":"function","name":"synthetic_tool","parameters":{"type":"object","properties":{"overflow":{"type":"integer","minimum":-9223372036854775809,"maximum":9223372036854775808,"exclusiveMinimum":-1.8446744073709552e19,"exclusiveMaximum":18446744073709552000.0},"exact":{"type":"integer","minimum":-9223372036854775808,"maximum":9223372036854775807},"seed":{"type":"integer","minimum":0,"maximum":18446744073709551615},"fraction":{"type":"number","maximum":18446744073709552000.0001},"user_data":{"type":"object","default":{"maximum":18446744073709552000}}}}}]}`
	req, _ := http.NewRequest(http.MethodPost, server.URL+"/v1/responses", strings.NewReader(payload))
	req.Header.Set("Authorization", "Bearer "+s.ClientKey)
	req.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body := consume(t, response)
	if response.StatusCode != http.StatusOK || !strings.Contains(body, "done-A") {
		t.Fatalf("normalized tool schema failed: status=%d", response.StatusCode)
	}
	select {
	case ok := <-checked:
		if !ok {
			t.Fatal("upstream tool schema validation failed")
		}
	default:
		t.Fatal("tool schema normalization was not exercised through HTTP")
	}
	waitEmpty(t, b)
	if !reflect.DeepEqual(acquiredSnapshot(b), []string{"A"}) {
		t.Fatal("tool schema request replayed another account")
	}
}
