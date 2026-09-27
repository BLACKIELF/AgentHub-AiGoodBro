package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestCompactUsesUpstreamHandlerAndProtectedLease(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/responses/compact" || !b.hasLease("A") {
			t.Errorf("compact path or lease incorrect: %s", r.URL.Path)
		}
		var body map[string]any
		if json.NewDecoder(r.Body).Decode(&body) != nil || body["model"] != "fixture-model" {
			t.Error("compact request lost selected model")
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"id":"fixture-compact","object":"response.compaction","output":[]}`)
	}))
	defer upstream.Close()
	_, server, _ := startTestRuntime(t, s, upstream.URL)
	for _, route := range []string{"/v1/responses/compact", "/responses/compact"} {
		req, _ := http.NewRequest("POST", server.URL+route, strings.NewReader(`{"model":"fixture-model","input":[]}`))
		req.Header.Set("Authorization", "Bearer "+s.ClientKey)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		body := consume(t, resp)
		if resp.StatusCode != 200 || !strings.Contains(body, "fixture-compact") {
			t.Fatalf("compact status %d: %s", resp.StatusCode, body)
		}
		waitEmpty(t, b)
	}
}
