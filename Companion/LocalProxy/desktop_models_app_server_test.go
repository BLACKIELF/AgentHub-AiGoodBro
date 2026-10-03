package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestRealAppServerListsNativeDesktopCatalog(t *testing.T) {
	codex := os.Getenv("AIGOODBRO_TEST_CODEX_EXECUTABLE")
	if codex == "" {
		t.Skip("set AIGOODBRO_TEST_CODEX_EXECUTABLE for isolated native model/list coverage")
	}
	if !filepath.IsAbs(codex) {
		t.Fatal("official executable must use an absolute path")
	}
	root := t.TempDir()
	home := filepath.Join(root, "codex")
	if err := os.Mkdir(home, 0700); err != nil {
		t.Fatal(err)
	}
	claims, _ := json.Marshal(map[string]any{"email": "fixture@example.invalid", "https://api.openai.com/auth": map[string]string{"chatgpt_account_id": "fixture-account", "chatgpt_plan_type": "plus"}})
	id := "e30." + base64.RawURLEncoding.EncodeToString(claims) + ".fixture"
	auth, _ := json.Marshal(map[string]any{"auth_mode": "chatgpt", "tokens": map[string]string{"id_token": id, "access_token": "fixture-desktop", "refresh_token": "fixture-refresh", "account_id": "fixture-account"}, "last_refresh": "2099-01-01T00:00:00Z"})
	authPath := filepath.Join(home, "auth.json")
	if err := os.WriteFile(authPath, auth, 0600); err != nil {
		t.Fatal(err)
	}
	var poolCalls, catalogCalls atomic.Int32
	pool := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		poolCalls.Add(1)
		w.WriteHeader(404)
	}))
	defer pool.Close()
	control := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if strings.Contains(r.URL.Path, "/wham/accounts/check") {
			_, _ = io.WriteString(w, `{"accounts":[{"id":"fixture-account","workspace_backend_origin":"https://127.0.0.1","account_routing_override":"NO_CONSTRAINT"}]}`)
		} else {
			_, _ = io.WriteString(w, `{}`)
		}
	}))
	defer control.Close()
	config := []byte(fmt.Sprintf("chatgpt_base_url=%q\ncli_auth_credentials_store=\"file\"\n", control.URL+"/backend-api/"))
	configPath := filepath.Join(home, "config.toml")
	if err := os.WriteFile(configPath, config, 0600); err != nil {
		t.Fatal(err)
	}
	catalog := desktopModelCatalog{client: &http.Client{Transport: catalogTransport(func(r *http.Request) (*http.Response, error) {
		catalogCalls.Add(1)
		if r.URL.Host != "chatgpt.com" || r.URL.Path != "/backend-api/codex/models" || r.URL.Query().Get("client_version") == "" || r.Header.Get("Authorization") != "Bearer fixture-desktop" {
			t.Error("real app-server discovery route or identity lost")
		}
		return &http.Response{StatusCode: 200, Header: http.Header{"Etag": []string{`"fixture-native"`}}, Body: io.NopCloser(bytes.NewReader(fixtureModelCatalog()))}, nil
	})}}
	gateway, endpoint, err := startDesktopGatewayWithCatalog(desktopConnection{Endpoint: pool.URL + "/v1", ClientKey: "fixture-pool"}, []string{"CODEX_HOME=" + home}, catalog)
	if err != nil {
		t.Fatal(err)
	}
	defer gateway.Close()
	cmd := exec.Command(codex, desktopArgs([]string{"app-server"}, 0, endpoint)...)
	cmd.Env = []string{"PATH=/usr/bin:/bin", "LANG=en_US.UTF-8", "HOME=" + root, "CODEX_HOME=" + home, "TMPDIR=" + root}
	cmd.Dir, cmd.Stderr = root, io.Discard
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = stdin.Close()
		done := make(chan error, 1)
		go func() { done <- cmd.Wait() }()
		select {
		case <-done:
		case <-time.After(8 * time.Second):
			_ = cmd.Process.Signal(os.Interrupt)
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				t.Error("isolated app-server did not stop")
			}
		}
	}()
	incoming := make(chan map[string]any, 128)
	go func() {
		defer close(incoming)
		scanner := bufio.NewScanner(stdout)
		scanner.Buffer(make([]byte, 4096), 16<<20)
		for scanner.Scan() {
			var msg map[string]any
			if json.Unmarshal(scanner.Bytes(), &msg) == nil {
				incoming <- msg
			}
		}
	}()
	rpc := func(id int, method string, params map[string]any) map[string]any {
		t.Helper()
		if err := json.NewEncoder(stdin).Encode(map[string]any{"id": id, "method": method, "params": params}); err != nil {
			t.Fatal(err)
		}
		timer := time.NewTimer(30 * time.Second)
		defer timer.Stop()
		for {
			select {
			case msg, ok := <-incoming:
				if !ok {
					t.Fatal("app-server exited before catalog reply")
				}
				if msg["id"] == float64(id) {
					if msg["error"] != nil {
						t.Fatalf("%s RPC error: %v", method, msg["error"])
					}
					return msg["result"].(map[string]any)
				}
			case <-timer.C:
				t.Fatal("app-server catalog reply timed out")
			}
		}
	}
	rpc(1, "initialize", map[string]any{"clientInfo": map[string]string{"name": "catalog_fixture", "version": "1"}, "capabilities": map[string]bool{"experimentalApi": true}})
	_ = json.NewEncoder(stdin).Encode(map[string]any{"method": "initialized", "params": map[string]any{}})
	result := rpc(2, "model/list", map[string]any{})
	found := map[string]bool{}
	for _, item := range result["data"].([]any) {
		model := item.(map[string]any)
		found[model["model"].(string)] = true
	}
	if !found["gpt-6.1-sol"] || !found["fixture-future-model"] || catalogCalls.Load() == 0 || poolCalls.Load() != 0 {
		t.Fatalf("native catalog missing: models=%v, catalog=%d, pool=%d", found, catalogCalls.Load(), poolCalls.Load())
	}
	afterAuth, _ := os.ReadFile(authPath)
	afterConfig, _ := os.ReadFile(configPath)
	if !bytes.Equal(auth, afterAuth) || !bytes.Equal(config, afterConfig) {
		t.Fatal("model discovery changed isolated auth/config")
	}
	t.Log("PASS: bundled official app-server model/list exposes 6.1 and a future model through Desktop gateway, with no account-pool admission or live requests")
}
