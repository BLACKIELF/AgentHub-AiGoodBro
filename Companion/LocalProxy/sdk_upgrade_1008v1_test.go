package main

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

// Keep the upstream connection open after its terminal SSE event. Completion
// must release the host lease and order snapshot without waiting for EOF or the
// runtime's fifteen-minute request deadline, in both bootstrap and started paths.
func TestSDKTerminalStreamClosesSilentUpstream1008(t *testing.T) {
	for _, terminal := range []string{"response.completed", "response.incomplete", "response.done"} {
		for _, started := range []bool{false, true} {
			name := terminal + "/bootstrap"
			if started {
				name = terminal + "/started"
			}
			t.Run(name, func(t *testing.T) {
				b := newFakeBridge(t)
				s := newStartup(t, b)
				hold := make(chan struct{})
				var releaseOnce sync.Once
				unblock := func() { releaseOnce.Do(func() { close(hold) }) }
				upstreamClosed := make(chan struct{})
				var closedOnce sync.Once
				upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					defer closedOnce.Do(func() { close(upstreamClosed) })
					if !b.hasLease("A") {
						t.Error("terminal fixture received an account without its host lease")
					}
					w.Header().Set("Content-Type", "text/event-stream")
					if started {
						sse(w, map[string]any{"type": "response.output_text.delta", "delta": "done-A"})
					}
					status := "completed"
					if terminal == "response.incomplete" {
						status = "incomplete"
					}
					sse(w, map[string]any{"type": terminal, "response": map[string]any{
						"id": "resp_fixture", "object": "response", "status": status, "model": "fixture-model",
						"output": []any{map[string]any{"type": "message", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": "done-A"}}}},
						"usage":  map[string]int{"input_tokens": 1, "output_tokens": 1, "total_tokens": 2},
					}})
					select {
					case <-hold:
					case <-r.Context().Done():
					}
				}))
				t.Cleanup(upstream.Close)
				_, server, _ := startTestRuntime(t, s, upstream.URL)
				t.Cleanup(unblock)
				ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
				defer cancel()
				req, err := http.NewRequestWithContext(ctx, http.MethodPost, server.URL+"/v1/responses", strings.NewReader(`{"model":"fixture-model","input":"synthetic","stream":true}`))
				if err != nil {
					t.Fatal(err)
				}
				req.Header.Set("Authorization", "Bearer "+s.ClientKey)
				req.Header.Set("Content-Type", "application/json")
				response, err := http.DefaultClient.Do(req)
				if err != nil {
					t.Fatal(err)
				}
				body, readErr := io.ReadAll(response.Body)
				response.Body.Close()
				if readErr != nil || response.StatusCode != http.StatusOK || !strings.Contains(string(body), "done-A") || strings.Contains(string(body), "stream error") {
					t.Fatalf("terminal stream waited for silence/EOF or changed its result: status=%d readErr=%v", response.StatusCode, readErr)
				}
				waitEmpty(t, b)
				waitForBridgeCommandCount(t, b, "order_end", 1)
				if b.snapshotCount() != 0 || !reflect.DeepEqual(acquiredSnapshot(b), []string{"A"}) {
					t.Fatal("terminal response retained its snapshot or replayed another account")
				}
				select {
				case <-upstreamClosed:
				case <-time.After(time.Second):
					t.Fatal("terminal response left its upstream body open")
				}
			})
		}
	}
}
