package main

import (
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"
)

// Exercise the actual host-admitted HTTP runtime, not a duplicate classifier.
// Only response.metadata is newly bufferable. Generated output, a dispatched
// server tool, and an unknown event still commit the response before overload.
func TestCodexMetadataBootstrap1026(t *testing.T) {
	for _, tc := range []struct {
		name       string
		boundary   string
		wantCalls  []string
		wantMarker string
	}{
		{"metadata_then_overload", "", []string{"A", "B"}, "done-B"},
		{"text_then_overload", "text", []string{"A"}, "partial-metadata-A"},
		{"server_tool_then_overload", "tool", []string{"A"}, "web_search_call"},
		{"unknown_event_then_overload", "unknown", []string{"A"}, "response.future_metadata"},
		{"metadata_then_success", "success", []string{"A"}, "done-A"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			b := newFakeBridge(t)
			s := newStartup(t, b)
			var mu sync.Mutex
			var calls []string
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				id := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer fixture-")
				if !b.hasLease(id) {
					t.Error("upstream attempt has no protected host lease")
				}
				mu.Lock()
				calls = append(calls, id)
				mu.Unlock()
				if id == "B" {
					complete(w, id)
					return
				}
				w.Header().Set("Content-Type", "text/event-stream")
				sse(w, map[string]any{"type": "response.created", "response": map[string]any{"id": "resp_metadata_A", "model": "fixture-model"}})
				sse(w, map[string]any{"type": "response.in_progress", "response": map[string]any{"id": "resp_metadata_A"}})
				sse(w, map[string]any{"type": "response.metadata", "response_id": "resp_metadata_A", "sequence_number": 2, "metadata": map[string]any{"fixture": "metadata-A"}})
				switch tc.boundary {
				case "text":
					sse(w, map[string]any{"type": "response.output_item.added", "output_index": 0, "item": map[string]any{"id": "msg_metadata_A", "type": "message", "role": "assistant", "content": []any{}}})
					sse(w, map[string]any{"type": "response.output_text.delta", "item_id": "msg_metadata_A", "output_index": 0, "content_index": 0, "delta": "partial-metadata-A"})
				case "tool":
					sse(w, map[string]any{"type": "response.output_item.added", "output_index": 0, "item": map[string]any{"id": "ws_metadata_A", "type": "web_search_call", "status": "in_progress"}})
					sse(w, map[string]any{"type": "response.web_search_call.searching", "item_id": "ws_metadata_A", "output_index": 0})
				case "unknown":
					sse(w, map[string]any{"type": "response.future_metadata", "fixture": "unknown-A"})
				case "success":
					sse(w, map[string]any{"type": "response.output_text.delta", "delta": "first-metadata-A"})
					complete(w, id)
					return
				}
				sse(w, map[string]any{"type": "error", "error": map[string]any{"type": "service_unavailable_error", "code": "server_is_overloaded", "message": "synthetic overload"}, "sequence_number": 3})
			}))
			defer upstream.Close()
			_, server, _ := startTestRuntime(t, s, upstream.URL)
			response := request(t, s, server.URL, true)
			body := consume(t, response)
			waitEmpty(t, b)
			mu.Lock()
			gotCalls := append([]string(nil), calls...)
			mu.Unlock()
			if response.StatusCode != http.StatusOK || !strings.Contains(body, tc.wantMarker) {
				t.Fatalf("status=%d calls=%v body=%s", response.StatusCode, gotCalls, body)
			}
			if !reflect.DeepEqual(gotCalls, tc.wantCalls) {
				t.Fatalf("upstream calls=%v want=%v", gotCalls, tc.wantCalls)
			}
			if !reflect.DeepEqual(acquiredSnapshot(b), tc.wantCalls) {
				t.Fatalf("host admissions=%v want=%v", acquiredSnapshot(b), tc.wantCalls)
			}
			if tc.boundary == "" {
				for _, leaked := range []string{"resp_metadata_A", "metadata-A", "server_is_overloaded"} {
					if strings.Contains(body, leaked) {
						t.Fatalf("uncommitted attempt leaked %q downstream", leaked)
					}
				}
			}
			if tc.boundary == "success" {
				last := -1
				for _, event := range []string{"response.created", "response.in_progress", "response.metadata", "response.output_text.delta", "response.completed"} {
					next := strings.Index(body, event)
					if next <= last {
						t.Fatalf("buffered event order lost at %s: %s", event, body)
					}
					last = next
				}
			}
		})
	}
}
