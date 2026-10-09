package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

func TestDesktopGatewayForwardingErrorClassification(t *testing.T) {
	canceled, cancel := context.WithCancel(context.Background())
	cancel()
	expired, expire := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
	defer expire()
	refused := &net.OpError{Op: "dial", Net: "tcp", Err: &os.SyscallError{Syscall: "connect", Err: syscall.ECONNREFUSED}}
	for _, tc := range []struct {
		name    string
		ctx     context.Context
		err     error
		message string
	}{
		{"connection refused", context.Background(), refused, "saved desktop proxy connection is unavailable"},
		{"wrapped connection refused", context.Background(), &url.Error{Op: "Post", URL: "http://fixture-private-endpoint", Err: refused}, "saved desktop proxy connection is unavailable"},
		{"response timeout", context.Background(), &net.OpError{Op: "read", Net: "tcp", Err: os.ErrDeadlineExceeded}, "request forwarding timed out"},
		{"wrapped deadline", context.Background(), fmt.Errorf("fixture-private-error: %w", context.DeadlineExceeded), "request forwarding timed out"},
		{"expired request", expired, io.EOF, "request forwarding timed out"},
		{"wrapped cancellation", context.Background(), fmt.Errorf("fixture-private-error: %w", context.Canceled), "request forwarding was canceled"},
		{"canceled request", canceled, refused, "request forwarding was canceled"},
		{"connection reset", context.Background(), &net.OpError{Op: "read", Net: "tcp", Err: syscall.ECONNRESET}, "could not forward this request"},
		{"closed connection", context.Background(), io.EOF, "could not forward this request"},
		{"non-dial refusal", context.Background(), &net.OpError{Op: "read", Net: "tcp", Err: syscall.ECONNREFUSED}, "could not forward this request"},
		{"untyped refusal", context.Background(), errors.New("fixture-private-error: connection refused"), "could not forward this request"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodPost, "/v1/responses", nil).WithContext(tc.ctx)
			w := httptest.NewRecorder()
			desktopGatewayForwardingError(w, r, tc.err)
			body := w.Body.String()
			if w.Code != http.StatusServiceUnavailable || !strings.Contains(body, tc.message) {
				t.Fatalf("status=%d body=%q", w.Code, body)
			}
			if strings.Contains(body, "proxy is stopped") || strings.Contains(body, "fixture-private") {
				t.Fatalf("response asserted an unverified state or disclosed a transport error: %q", body)
			}
			if tc.message != "saved desktop proxy connection is unavailable" && strings.Contains(body, "Reconnect") {
				t.Fatalf("ordinary request failure advised reconnecting: %q", body)
			}
		})
	}
}

func TestDesktopGatewayForwardingFailures(t *testing.T) {
	for _, kind := range []string{"refused", "closed", "deadline", "canceled", "http error"} {
		t.Run(kind, func(t *testing.T) {
			home := t.TempDir()
			if err := os.WriteFile(filepath.Join(home, "auth.json"), []byte(`{"auth_mode":"chatgpt","tokens":{"access_token":"fixture-desktop-token"}}`), 0600); err != nil {
				t.Fatal(err)
			}
			var calls atomic.Int32
			canceledRequest, cancelRequest := context.WithCancel(context.Background())
			defer cancelRequest()
			release := make(chan struct{})
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				_, _ = io.Copy(io.Discard, r.Body)
				switch kind {
				case "closed":
					conn, _, err := w.(http.Hijacker).Hijack()
					if err != nil {
						t.Error(err)
						return
					}
					_ = conn.Close()
				case "deadline", "canceled":
					if kind == "canceled" {
						cancelRequest()
					}
					select {
					case <-r.Context().Done():
					case <-release:
					}
				case "http error":
					http.Error(w, "fixture pool response", http.StatusServiceUnavailable)
				}
			}))
			defer upstream.Close()
			defer close(release)
			gateway, _, err := startDesktopGatewayWithCatalog(desktopConnection{Endpoint: upstream.URL + "/v1", ClientKey: "fixture-pool-key"}, []string{"CODEX_HOME=" + home}, http.NotFoundHandler())
			if err != nil {
				t.Fatal(err)
			}
			defer gateway.Close()
			if kind == "refused" {
				upstream.Close()
			}
			r := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader("synthetic"))
			r.Header.Set("Authorization", "Bearer fixture-desktop-token")
			if kind == "deadline" {
				ctx, cancel := context.WithTimeout(r.Context(), time.Second)
				defer cancel()
				r = r.WithContext(ctx)
			} else if kind == "canceled" {
				r = r.WithContext(canceledRequest)
			}
			w := httptest.NewRecorder()
			gateway.Handler.ServeHTTP(w, r)
			want := map[string]string{
				"refused":    "saved desktop proxy connection is unavailable",
				"closed":     "could not forward this request",
				"deadline":   "request forwarding timed out",
				"canceled":   "request forwarding was canceled",
				"http error": "fixture pool response",
			}[kind]
			if w.Code != http.StatusServiceUnavailable || !strings.Contains(w.Body.String(), want) {
				t.Fatalf("status=%d body=%q", w.Code, w.Body.String())
			}
			if kind == "refused" {
				if calls.Load() != 0 {
					t.Fatal("request reached the closed pool")
				}
			} else if calls.Load() != 1 {
				t.Fatalf("expected one forwarding attempt, got %d", calls.Load())
			}
		})
	}
}

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
