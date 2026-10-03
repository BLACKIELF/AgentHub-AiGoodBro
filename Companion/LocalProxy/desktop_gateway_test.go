package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

func TestDesktopGatewayAuthenticatesStripsIdentityAndRefreshes(t *testing.T) {
	home := t.TempDir()
	path := filepath.Join(home, "auth.json")
	writeAuth := func(token string) {
		data, _ := json.Marshal(map[string]any{"auth_mode": "chatgpt", "tokens": map[string]string{"access_token": token}})
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	writeAuth("fixture-desktop-token")
	var calls atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.Header.Get("Authorization") != "Bearer fixture-pool-key" || r.Header.Get("ChatGPT-Account-ID") != "" || r.Header.Get("Cookie") != "" || r.Header.Get("Forwarded") != "" {
			t.Error("Desktop identity reached the pool")
		}
		_, _ = io.Copy(w, r.Body)
	}))
	defer upstream.Close()
	gateway, endpoint, err := startDesktopGateway(desktopConnection{Endpoint: upstream.URL + "/v1", ClientKey: "fixture-pool-key"}, []string{"CODEX_HOME=" + home})
	if err != nil {
		t.Fatal(err)
	}
	defer gateway.Close()
	post := func(token string, expected int) {
		req, _ := http.NewRequest("POST", endpoint+"/responses", strings.NewReader("synthetic"))
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("ChatGPT-Account-ID", "fixture-desktop-account")
		req.Header.Set("Cookie", "fixture-cookie")
		req.Header.Set("Forwarded", "fixture-forwarded")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != expected || (expected == 200 && string(body) != "synthetic") {
			t.Fatalf("status=%d expected=%d", resp.StatusCode, expected)
		}
	}
	post("wrong", 401)
	post("fixture-desktop-token", 200)
	writeAuth("fixture-refreshed-token")
	post("fixture-desktop-token", 401)
	post("fixture-refreshed-token", 200)
	if calls.Load() != 2 {
		t.Fatal("unauthorized request reached pool")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	post("fixture-refreshed-token", 401)
}

func TestLargeImageRequestPassesFormer32MiBLimit(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	imageURL := "data:image/png;base64," + strings.Repeat("A", 40<<20)
	var received atomic.Bool
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var payload struct {
			Input []struct {
				Content []struct {
					ImageURL string `json:"image_url"`
				} `json:"content"`
			} `json:"input"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Error("large upstream JSON decode failed")
			w.WriteHeader(500)
			return
		}
		for _, item := range payload.Input {
			for _, content := range item.Content {
				if content.ImageURL == imageURL {
					received.Store(true)
				}
			}
		}
		complete(w, "large-image")
	}))
	defer upstream.Close()
	_, server, _ := startTestRuntime(t, s, upstream.URL)
	data, _ := json.Marshal(map[string]any{"model": "fixture-model", "stream": true, "input": []any{map[string]any{"role": "user", "content": []any{map[string]any{"type": "input_image", "image_url": imageURL}}}}})
	req, _ := http.NewRequest("POST", server.URL+"/v1/responses", strings.NewReader(string(data)))
	req.Header.Set("Authorization", "Bearer "+s.ClientKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_ = consume(t, resp)
	if resp.StatusCode != 200 || !received.Load() {
		t.Fatalf("large image rejected or truncated: status=%d delivered=%t", resp.StatusCode, received.Load())
	}
	waitEmpty(t, b)
}
