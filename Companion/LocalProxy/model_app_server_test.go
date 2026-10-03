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

// Opt in with an installed official executable. All homes, credentials, leases
// and HTTP peers belong to this test; no live Desktop or account is contacted.
func TestRealAppServerRoutesSavedAndNewModels(t *testing.T) {
	codex := os.Getenv("AIGOODBRO_TEST_CODEX_EXECUTABLE")
	if codex == "" {
		t.Skip("set AIGOODBRO_TEST_CODEX_EXECUTABLE for isolated real app-server coverage")
	}
	if !filepath.IsAbs(codex) {
		t.Fatal("official executable must use an absolute path")
	}
	b := newFakeBridge(t)
	s := newStartup(t, b)
	var expected atomic.Value
	expected.Store("gpt-6.1-sol")
	var calls atomic.Int32
	const marker = "MODEL_ROUTE_PROTOCOL_OK"
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			w.Header().Set("Content-Type", "application/json")
			switch {
			case strings.HasPrefix(r.URL.Path, "/backend-api/wham/accounts/check"):
				_, _ = io.WriteString(w, `{"accounts":[{"id":"fixture-account","workspace_backend_origin":"https://127.0.0.1","account_routing_override":"NO_CONSTRAINT"}]}`)
			case strings.HasPrefix(r.URL.Path, "/backend-api/wham/config/bundle"):
				_, _ = io.WriteString(w, `{}`)
			default:
				w.WriteHeader(http.StatusNotFound)
			}
			return
		}
		if r.Method != http.MethodPost || r.URL.Path != "/responses" {
			// Optional official control-plane calls stay on this local fixture.
			if !strings.HasPrefix(r.URL.Path, "/backend-api/") {
				t.Error("unexpected upstream path")
			}
			w.WriteHeader(http.StatusNotFound)
			return
		}
		if !b.hasLease("A") || r.Header.Get("Authorization") != "Bearer fixture-A" || r.Header.Get("ChatGPT-Account-ID") != "fixture-account-A" {
			t.Error("real app-server bypassed synthetic protected admission")
		}
		var body map[string]any
		if json.NewDecoder(r.Body).Decode(&body) != nil || body["model"] != expected.Load() {
			t.Error("real app-server model changed before upstream")
		}
		reasoning, _ := body["reasoning"].(map[string]any)
		if reasoning["effort"] != "max" {
			t.Error("saved reasoning effort lost on the full route")
		}
		calls.Add(1)
		w.Header().Set("Content-Type", "text/event-stream")
		item := map[string]any{"id": "msg_route", "type": "message", "role": "assistant", "status": "completed",
			"content": []any{map[string]any{"type": "output_text", "text": marker, "annotations": []any{}}}}
		sse(w, map[string]any{"type": "response.created", "response": map[string]any{"id": "resp_route"}})
		sse(w, map[string]any{"type": "response.output_item.added", "output_index": 0, "item": map[string]any{"id": "msg_route", "type": "message", "role": "assistant", "status": "in_progress", "content": []any{}}})
		sse(w, map[string]any{"type": "response.output_text.delta", "item_id": "msg_route", "output_index": 0, "content_index": 0, "delta": marker})
		sse(w, map[string]any{"type": "response.output_item.done", "output_index": 0, "item": item})
		sse(w, map[string]any{"type": "response.completed", "response": map[string]any{"id": "resp_route", "object": "response", "status": "completed", "model": body["model"], "output": []any{item}, "usage": map[string]int{"input_tokens": 10, "output_tokens": 1, "total_tokens": 11}}})
	}))
	defer upstream.Close()
	_, server, _ := startTestRuntime(t, s, upstream.URL)
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	home := filepath.Join(root, "codex")
	if err := os.Mkdir(home, 0700); err != nil {
		t.Fatal(err)
	}
	write := func(path string, body []byte) {
		t.Helper()
		if err := os.WriteFile(path, body, 0600); err != nil {
			t.Fatal(err)
		}
	}
	claims := map[string]any{"email": "fixture@example.invalid", "https://api.openai.com/auth": map[string]any{"chatgpt_account_id": "fixture-account", "chatgpt_user_id": "fixture-user", "chatgpt_plan_type": "plus"}}
	claimJSON, _ := json.Marshal(claims)
	idToken := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none"}`)) + "." + base64.RawURLEncoding.EncodeToString(claimJSON) + ".fixture"
	authBytes, _ := json.Marshal(map[string]any{"auth_mode": "chatgpt", "tokens": map[string]string{"id_token": idToken, "access_token": "fixture-desktop-token", "refresh_token": "fixture-refresh-token", "account_id": "fixture-account"}, "last_refresh": "2099-01-01T00:00:00Z"})
	authPath := filepath.Join(home, "auth.json")
	write(authPath, authBytes)
	configBytes := []byte(fmt.Sprintf("chatgpt_base_url=%q\ncli_auth_credentials_store=\"file\"\n", upstream.URL+"/backend-api/"))
	write(filepath.Join(home, "config.toml"), configBytes)
	connection := filepath.Join(root, "connection.json")
	connectionBytes, _ := json.Marshal(desktopConnection{SchemaVersion: 1, Endpoint: server.URL + "/v1", ClientKey: s.ClientKey, RunID: "model-fixture", CodexExecutable: codex})
	write(connection, connectionBytes)
	helper, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	var threadID string
	for run := 0; run < 3; run++ {
		func() {
			program := helper
			args := []string{"-c", "features.code_mode_host=true", "app-server", "--analytics-default-enabled"}
			env := []string{"PATH=/usr/bin:/bin", "LANG=en_US.UTF-8", "HOME=" + root, "CODEX_HOME=" + home, "TMPDIR=" + root}
			if run == 0 {
				// Reproduce the old provider history, with a model outside s.Models.
				program = codex
				args = append(args, "-c", `model_provider="aigoodbro_local"`, "-c", `model_providers.aigoodbro_local={name="Fixture",base_url="`+server.URL+`/v1",env_key="AIGOODBRO_PROXY_KEY",wire_api="responses",requires_openai_auth=false,supports_websockets=false}`, "-c", "features.enable_request_compression=false")
				env = append(env, "AIGOODBRO_PROXY_KEY="+s.ClientKey)
			} else {
				env = append(env, "AIGOODBRO_DESKTOP_TEST_CHILD=1", "AIGOODBRO_PROXY_CONNECTION_FILE="+connection)
			}
			cmd := exec.Command(program, args...)
			cmd.Env, cmd.Dir, cmd.Stderr = env, root, io.Discard
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
						t.Error("isolated app-server did not stop gracefully")
					}
				}
			}()
			incoming := make(chan map[string]any, 1024)
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
			until := func(match func(map[string]any) bool) map[string]any {
				t.Helper()
				timer := time.NewTimer(30 * time.Second)
				defer timer.Stop()
				for {
					select {
					case msg, ok := <-incoming:
						if !ok {
							t.Fatalf("isolated app-server run %d exited before reply", run)
						}
						if match(msg) {
							return msg
						}
					case <-timer.C:
						t.Fatalf("isolated app-server run %d reply timed out", run)
					}
				}
			}
			sequence := 0
			rpc := func(method string, params map[string]any) map[string]any {
				t.Helper()
				sequence++
				if err := json.NewEncoder(stdin).Encode(map[string]any{"id": sequence, "method": method, "params": params}); err != nil {
					t.Fatal(err)
				}
				reply := until(func(msg map[string]any) bool { return msg["id"] == float64(sequence) })
				if reply["error"] != nil {
					t.Fatalf("isolated %s returned an RPC error", method)
				}
				result, _ := reply["result"].(map[string]any)
				return result
			}
			rpc("initialize", map[string]any{"clientInfo": map[string]string{"name": "model_fixture", "version": "1"}, "capabilities": map[string]bool{"experimentalApi": true}})
			_ = json.NewEncoder(stdin).Encode(map[string]any{"method": "initialized", "params": map[string]any{}})
			params := map[string]any{"cwd": root, "approvalPolicy": "never", "sandbox": "read-only", "modelProvider": "aigoodbro_local"}
			method := "thread/start"
			if run == 0 {
				params["model"] = "gpt-6.1-sol"
				params["config"] = map[string]string{"model_reasoning_effort": "max"}
			} else {
				method = "thread/resume"
				params["threadId"] = threadID
				if run == 2 {
					method = "thread/fork"
				}
			}
			result := rpc(method, params)
			if result["model"] != "gpt-6.1-sol" || run > 0 && result["modelProvider"] != "openai" {
				t.Fatal("saved model or provider not restored")
			}
			threadID = result["thread"].(map[string]any)["id"].(string)
			turn := func(override string) {
				turn := map[string]any{"threadId": threadID, "input": []any{map[string]string{"type": "text", "text": "Return the fixture marker."}}}
				if override != "" {
					turn["model"], turn["effort"] = override, "max"
				}
				rpc("turn/start", turn)
				finished := until(func(msg map[string]any) bool { return msg["method"] == "turn/completed" })
				status := finished["params"].(map[string]any)["turn"].(map[string]any)["status"]
				if status != "completed" {
					t.Fatalf("full protocol turn failed: %v", status)
				}
				waitEmpty(t, b)
			}
			turn("")
			if run == 2 {
				expected.Store("fixture-future-model")
				turn("fixture-future-model")
			}
		}()
	}
	if calls.Load() != 4 {
		t.Fatalf("expected four protected upstream turns, got %d", calls.Load())
	}
	after, _ := os.ReadFile(authPath)
	configAfter, _ := os.ReadFile(filepath.Join(home, "config.toml"))
	if !bytes.Equal(after, authBytes) || !bytes.Equal(configAfter, configBytes) {
		t.Fatal("adapter changed isolated identity or saved config")
	}
	t.Log("PASS: real app-server legacy start, omitted-model resume, fork and unseen-model turn through gateway, Go runtime, protected lease and local upstream; no live call")
}
