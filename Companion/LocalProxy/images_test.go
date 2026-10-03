package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const imageFixtureResponse = `{"created":123,"data":[{"b64_json":"c3ludGhldGlj","generation_id":"fixture-image"}]}`

func imageRequest(t *testing.T, endpoint, token, body string) *http.Response {
	t.Helper()
	req, _ := http.NewRequest("POST", endpoint, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("ChatGPT-Account-ID", "fixture-desktop-identity")
	req.Header.Set("Cookie", "fixture-desktop-cookie")
	req.Header.Set("OpenAI-Project", "fixture-desktop-project")
	req.Header.Set("X-Codex-Image-Turn-Id", "fixture-image-turn")
	req.Header.Set("Originator", "codex_desktop")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func TestNativeImagesThroughDesktopGatewayPreserveBodyAndLeasedIdentity(t *testing.T) {
	b := newFakeBridge(t)
	b.busy["A"] = true
	s := newStartup(t, b)
	body := `{"model":"gpt-image-2","prompt":"synthetic","background":"transparent","n":1,"images":[{"image_url":"data:image/png;base64,` + strings.Repeat("A", 40<<20) + `"}]}`
	wantHash := sha256.Sum256([]byte(body))
	var calls atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		data, _ := io.ReadAll(r.Body)
		if sha256.Sum256(data) != wantHash {
			t.Error("image JSON/model/reference changed or truncated")
		}
		if !b.hasLease("B") || r.Header.Get("Authorization") != "Bearer fixture-B" || r.Header.Get("ChatGPT-Account-ID") != "fixture-account-B" {
			t.Error("image request bypassed selected lease")
		}
		if r.Header.Get("Cookie") != "" || r.Header.Get("OpenAI-Project") != "" {
			t.Error("Desktop identity leaked")
		}
		if r.Header.Get("X-Codex-Image-Turn-Id") != "fixture-image-turn" || r.Header.Get("Originator") != "codex_desktop" {
			t.Error("native image protocol headers lost")
		}
		if r.URL.Path != "/images/generations" && r.URL.Path != "/images/edits" {
			t.Error("wrong upstream image endpoint")
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Codex-Imagegen-Request-Id", "fixture-image-request")
		w.Header().Set("Set-Cookie", "must-not-cross")
		_, _ = io.WriteString(w, imageFixtureResponse)
	}))
	defer upstream.Close()
	_, pool, _ := startTestRuntime(t, s, upstream.URL)
	home := t.TempDir()
	authBytes, _ := json.Marshal(map[string]any{"auth_mode": "chatgpt", "tokens": map[string]string{"access_token": "fixture-desktop-bearer"}})
	if err := os.WriteFile(filepath.Join(home, "auth.json"), authBytes, 0600); err != nil {
		t.Fatal(err)
	}
	gateway, endpoint, err := startDesktopGateway(desktopConnection{Endpoint: pool.URL + "/v1", ClientKey: s.ClientKey}, []string{"CODEX_HOME=" + home})
	if err != nil {
		t.Fatal(err)
	}
	defer gateway.Close()
	for _, path := range []string{"/images/generations", "/images/edits"} {
		resp := imageRequest(t, endpoint+path, "fixture-desktop-bearer", body)
		if result := consume(t, resp); resp.StatusCode != 200 || result != imageFixtureResponse {
			t.Fatalf("image route failed: %d", resp.StatusCode)
		}
		if resp.Header.Get("X-Codex-Imagegen-Request-Id") != "fixture-image-request" || resp.Header.Get("Set-Cookie") != "" {
			t.Error("response headers not isolated/preserved")
		}
		waitEmpty(t, b)
	}
	if calls.Load() != 2 {
		t.Fatal("wrong upstream call count")
	}
}

func TestNativeImageQuotaRejectionRotatesAndLiveOrderApplies(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	var calls atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.Header.Get("Authorization") == "Bearer fixture-A" {
			w.Header().Set("Retry-After", "120")
			w.WriteHeader(429)
			_, _ = io.WriteString(w, `{"error":{"message":"synthetic image limit"}}`)
			return
		}
		_, _ = io.WriteString(w, imageFixtureResponse)
	}))
	defer upstream.Close()
	rt, pool, _ := startTestRuntime(t, s, upstream.URL)
	body := `{"model":"gpt-image-2","prompt":"synthetic"}`
	resp := imageRequest(t, pool.URL+"/images/generations", s.ClientKey, body)
	if result := consume(t, resp); resp.StatusCode != 200 || result != imageFixtureResponse {
		t.Fatalf("quota fallback failed: %d", resp.StatusCode)
	}
	waitEmpty(t, b)
	a, _ := rt.manager.GetByID("A")
	if state := a.ModelStates[nativeImageModel]; state == nil || !state.NextRetryAfter.After(time.Now()) {
		t.Fatal("image cooldown not retained")
	}
	b.mu.Lock()
	b.order = []string{"B", "A"}
	b.mu.Unlock()
	resp = imageRequest(t, pool.URL+"/images/edits", s.ClientKey, body)
	if result := consume(t, resp); resp.StatusCode != 200 || result != imageFixtureResponse {
		t.Fatal("live order failed")
	}
	waitEmpty(t, b)
	if calls.Load() != 3 {
		t.Fatal("wrong image retry count")
	}
}

func TestNativeImagesDoNotReplayUncertainOrRequestSpecificFailures(t *testing.T) {
	for _, failure := range []string{"disconnect", "truncated", "redirect", "403", "404", "503"} {
		t.Run(failure, func(t *testing.T) {
			b := newFakeBridge(t)
			s := newStartup(t, b)
			var calls atomic.Int32
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				switch failure {
				case "disconnect":
					conn, _, _ := w.(http.Hijacker).Hijack()
					conn.Close()
				case "truncated":
					w.Header().Set("Content-Length", "1000")
					_, _ = io.WriteString(w, "{")
				case "redirect":
					w.Header().Set("Location", "https://example.invalid/credential-leak")
					w.WriteHeader(307)
				case "403":
					w.WriteHeader(403)
				case "404":
					w.WriteHeader(404)
				case "503":
					w.WriteHeader(503)
				}
			}))
			defer upstream.Close()
			_, pool, events := startTestRuntime(t, s, upstream.URL)
			resp := imageRequest(t, pool.URL+"/v1/images/generations", s.ClientKey, `{"model":"gpt-image-2","prompt":"synthetic"}`)
			_ = consume(t, resp)
			if resp.StatusCode < 400 || resp.Header.Get("Location") != "" {
				t.Fatal("failure/redirect treated as success")
			}
			waitEmpty(t, b)
			if calls.Load() != 1 {
				t.Fatalf("uncertain image generation replayed %d times", calls.Load())
			}
			if strings.Contains(events.String(), "login_expired") {
				t.Fatal("image permission/request failure incorrectly expired account login")
			}
		})
	}
}

func TestNativeImageCancellationReleasesLease(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	started := make(chan struct{})
	upstreamCancelled := make(chan struct{})
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		close(started)
		select {
		case <-r.Context().Done():
			close(upstreamCancelled)
		case <-time.After(5 * time.Second):
			t.Error("upstream image request was not cancelled")
		}
	}))
	defer upstream.Close()
	_, pool, _ := startTestRuntime(t, s, upstream.URL)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "POST", pool.URL+"/v1/images/generations", strings.NewReader(`{"model":"gpt-image-2","prompt":"synthetic"}`))
	req.Header.Set("Authorization", "Bearer "+s.ClientKey)
	done := make(chan struct{})
	go func() {
		defer close(done)
		response, _ := http.DefaultClient.Do(req)
		if response != nil {
			response.Body.Close()
		}
	}()
	select {
	case <-started:
	case <-time.After(3 * time.Second):
		t.Fatal("image request did not start")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("image cancellation did not finish")
	}
	waitEmpty(t, b)
	select {
	case <-upstreamCancelled:
	case <-time.After(3 * time.Second):
		t.Fatal("cancel did not reach image upstream")
	}
}

func TestNativeImagesRejectUnauthorizedAndUnsupportedPaths(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Error("invalid image request reached upstream") }))
	defer upstream.Close()
	_, pool, _ := startTestRuntime(t, s, upstream.URL)
	for _, tc := range []struct {
		path, token, body string
		status            int
	}{
		{"/v1/images/generations", "wrong", `{}`, 401},
		{"/v1/images/edits", s.ClientKey, `{"model":`, 400},
		{"/v1/images/variations", s.ClientKey, `{}`, 404},
		{"/v1/images/generations/other", s.ClientKey, `{}`, 404},
	} {
		resp := imageRequest(t, pool.URL+tc.path, tc.token, tc.body)
		_ = consume(t, resp)
		if resp.StatusCode != tc.status {
			t.Fatalf("invalid image request status=%d want=%d", resp.StatusCode, tc.status)
		}
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if len(b.acquired) != 0 {
		t.Fatal("invalid request acquired credentials")
	}
}
