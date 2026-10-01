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

type catalogTransport func(*http.Request) (*http.Response, error)

func (f catalogTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func fixtureModelCatalog() []byte {
	models := []any{}
	for _, slug := range []string{"gpt-6.1-sol", "fixture-future-model"} {
		models = append(models, map[string]any{
			"slug": slug, "display_name": slug, "description": "Synthetic catalog fixture",
			"default_reasoning_level": "low", "supported_reasoning_levels": []any{
				map[string]string{"effort": "low", "description": "Low"},
				map[string]string{"effort": "max", "description": "Max"}},
			"shell_type": "unified_exec", "visibility": "list", "supported_in_api": true,
			"priority": 1, "base_instructions": "Synthetic instructions.",
			"default_reasoning_summary": "none", "support_verbosity": true,
			"default_verbosity": "low", "apply_patch_tool_type": "freeform",
			"truncation_policy": map[string]any{"mode": "tokens", "limit": 10000},
			"context_window":    272000, "effective_context_window_percent": 95,
			"input_modalities": []string{"text", "image"}, "experimental_supported_tools": []string{},
			"future_capability": map[string]bool{"preserve": true},
		})
	}
	body, _ := json.Marshal(map[string]any{"models": models})
	return body
}

func TestDesktopCatalogPreservesNativeMetadataAndIsolatesPool(t *testing.T) {
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, "auth.json"), []byte(`{"auth_mode":"chatgpt","tokens":{"access_token":"fixture-desktop"}}`), 0600); err != nil {
		t.Fatal(err)
	}
	var poolCalls, officialCalls atomic.Int32
	pool := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		poolCalls.Add(1)
		w.WriteHeader(500)
	}))
	defer pool.Close()
	body := fixtureModelCatalog()
	catalog := desktopModelCatalog{client: &http.Client{Transport: catalogTransport(func(r *http.Request) (*http.Response, error) {
		officialCalls.Add(1)
		if r.URL.String() != desktopModelCatalogURL+"?client_version=0.159.0" || r.Method != "GET" || r.Body != nil {
			t.Error("catalog left the fixed official discovery route")
		}
		if r.Header.Get("Authorization") != "Bearer fixture-desktop" || r.Header.Get("ChatGPT-Account-ID") != "fixture-account" || r.Header.Get("If-None-Match") != `"old"` {
			t.Error("native discovery identity or cache validator lost")
		}
		for _, name := range []string{"Cookie", "X-Forwarded-For", "OpenAI-Organization", "X-Untrusted"} {
			if r.Header.Get(name) != "" {
				t.Errorf("unapproved header forwarded: %s", name)
			}
		}
		return &http.Response{StatusCode: 200, Header: http.Header{"Etag": []string{`"fixture"`}}, Body: io.NopCloser(strings.NewReader(string(body)))}, nil
	})}}
	gateway, endpoint, err := startDesktopGatewayWithCatalog(desktopConnection{Endpoint: pool.URL + "/v1", ClientKey: "fixture-pool"}, []string{"CODEX_HOME=" + home}, catalog)
	if err != nil {
		t.Fatal(err)
	}
	defer gateway.Close()
	for _, token := range []string{"invalid", "fixture-desktop"} {
		r, _ := http.NewRequest("GET", endpoint+"/models?client_version=0.159.0", nil)
		r.Header.Set("Authorization", "Bearer "+token)
		r.Header.Set("ChatGPT-Account-ID", "fixture-account")
		r.Header.Set("If-None-Match", `"old"`)
		for _, name := range []string{"Cookie", "X-Forwarded-For", "OpenAI-Organization", "X-Untrusted"} {
			r.Header.Set(name, "untrusted")
		}
		response, err := http.DefaultClient.Do(r)
		if err != nil {
			t.Fatal(err)
		}
		got, _ := io.ReadAll(response.Body)
		response.Body.Close()
		if token == "invalid" {
			if response.StatusCode != 401 {
				t.Fatal("unauthorized catalog request accepted")
			}
		} else if response.StatusCode != 200 || string(got) != string(body) || response.Header.Get("ETag") != `"fixture"` {
			t.Fatal("native catalog or future capabilities changed")
		}
	}
	if officialCalls.Load() != 1 || poolCalls.Load() != 0 {
		t.Fatal("catalog used pool admission or invalid caller reached official endpoint")
	}
}

func TestDesktopCatalogRejectsInvalidQueryAndResponse(t *testing.T) {
	for _, query := range []string{"", "client_version=", "client_version=a&client_version=b", "client_version=a&url=https://example.invalid", "client_version=%0a", "client_version=%zz", "other=value"} {
		t.Run("query-"+query, func(t *testing.T) {
			catalog := desktopModelCatalog{client: &http.Client{Transport: catalogTransport(func(*http.Request) (*http.Response, error) { t.Fatal("bad query reached network"); return nil, nil })}}
			w := httptest.NewRecorder()
			catalog.ServeHTTP(w, httptest.NewRequest("GET", "/v1/models?"+query, nil))
			if w.Code != 400 {
				t.Fatalf("bad query status %d", w.Code)
			}
		})
	}
	for _, tc := range []struct {
		name   string
		status int
		body   string
		want   int
	}{
		{"native", 200, `{"models":[]}`, 200},
		{"generic", 200, `{"object":"list","data":[]}`, 502},
		{"null", 200, `{"models":null}`, 502},
		{"malformed", 200, `{`, 502},
		{"too-large", 200, strings.Repeat(" ", desktopModelCatalogLimit+1), 502},
		{"unauthorized", 401, "private", 401}, {"forbidden", 403, "private", 403},
		{"rate-limit", 429, "private", 429}, {"redirect", 302, "private", 502},
		{"server-error", 500, "private", 502}, {"not-modified", 304, "", 304},
	} {
		t.Run(tc.name, func(t *testing.T) {
			catalog := desktopModelCatalog{client: &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }, Transport: catalogTransport(func(*http.Request) (*http.Response, error) {
				return &http.Response{StatusCode: tc.status, Header: http.Header{"Location": []string{"https://example.invalid"}}, Body: io.NopCloser(strings.NewReader(tc.body))}, nil
			})}}
			w := httptest.NewRecorder()
			catalog.ServeHTTP(w, httptest.NewRequest("GET", "/v1/models?client_version=0.159.0", nil))
			if w.Code != tc.want || w.Header().Get("Location") != "" || strings.Contains(w.Body.String(), "private") {
				t.Fatalf("unsafe reply: status %d", w.Code)
			}
		})
	}
}

func TestDesktopCatalogUsesOnlyNativeNetworkProxyAndRejectsRedirects(t *testing.T) {
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:1")
	for _, proxy := range []string{"", "http://127.0.0.1:7890", "socks5://127.0.0.1:7891"} {
		handler, closeIdle, err := newDesktopModelCatalog(proxy)
		if err != nil {
			t.Fatal(err)
		}
		client := handler.(desktopModelCatalog).client
		transport := client.Transport.(*http.Transport)
		if proxy == "" {
			if transport.Proxy != nil {
				t.Fatal("inherited proxy environment")
			}
		} else {
			url, err := transport.Proxy(httptest.NewRequest("GET", desktopModelCatalogURL, nil))
			if err != nil || url.String() != proxy {
				t.Fatal("native proxy choice changed")
			}
		}
		if client.CheckRedirect(nil, nil) != http.ErrUseLastResponse {
			t.Fatal("redirect can receive Desktop credentials")
		}
		if transport.TLSClientConfig != nil && transport.TLSClientConfig.InsecureSkipVerify {
			t.Fatal("TLS verification disabled")
		}
		closeIdle()
	}
	if _, _, err := newDesktopModelCatalog("http://user:password@127.0.0.1:7890"); err == nil {
		t.Fatal("unsafe network proxy accepted")
	}
}
