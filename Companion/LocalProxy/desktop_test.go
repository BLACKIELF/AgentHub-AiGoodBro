package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func desktopFixture(t *testing.T, script string) (string, desktopConnection) {
	t.Helper()
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(dir, "fake-codex")
	if err := os.WriteFile(exe, []byte("#!/bin/sh\n"+script+"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	c := desktopConnection{SchemaVersion: 1, Endpoint: "http://127.0.0.1:42123/v1", ClientKey: strings.Repeat("k", 40) + "+/A=", RunID: "fixture-run", CodexExecutable: exe}
	path := filepath.Join(dir, "connection.json")
	desktopWriteConnection(t, path, c)
	return path, c
}

func desktopWriteConnection(t *testing.T, path string, c desktopConnection) {
	t.Helper()
	data, err := json.Marshal(c)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
}

func TestDesktopTransforms(t *testing.T) {
	for _, method := range []string{"thread/start", "thread/resume", "thread/fork"} {
		input := []byte(`{"id":42,"method":"` + method + `","params":{"modelProvider":"old","model":"original-model","effort":"high","config":{"x":1},"tools":[{"name":"fixture"}],"response":{"a":true}},"extra":[1,2]}` + "\n")
		var got map[string]any
		if err := json.Unmarshal(transformDesktopLine(input), &got); err != nil {
			t.Fatal(err)
		}
		params := got["params"].(map[string]any)
		if params["modelProvider"] != "openai" || params["model"] != "original-model" || params["effort"] != "high" || got["id"] != float64(42) || !reflect.DeepEqual(params["tools"], []any{map[string]any{"name": "fixture"}}) || !reflect.DeepEqual(params["config"], map[string]any{"x": float64(1)}) || !reflect.DeepEqual(params["response"], map[string]any{"a": true}) || !reflect.DeepEqual(got["extra"], []any{float64(1), float64(2)}) {
			t.Fatalf("%s changed unrelated data: %#v", method, got)
		}
	}
	list := []byte(`{"id":"history","method":"thread/list","params":{"modelProviders":["old"],"cursor":"abc"}}` + "\r\n")
	changed := transformDesktopLine(list)
	if !bytes.HasSuffix(changed, []byte("\r\n")) {
		t.Fatal("line ending changed")
	}
	var got map[string]any
	if err := json.Unmarshal(changed, &got); err != nil {
		t.Fatal(err)
	}
	params := got["params"].(map[string]any)
	if got["id"] != "history" || params["cursor"] != "abc" || !reflect.DeepEqual(params["modelProviders"], []any{}) {
		t.Fatalf("history filter: %#v", got)
	}
	for _, raw := range [][]byte{[]byte("unknown raw line\n"), []byte(` {"method":"other","params":{}} ` + "\n"), []byte(`{"method":"thread/start","params":null}` + "\n")} {
		if !bytes.Equal(transformDesktopLine(raw), raw) {
			t.Fatal("unknown or invalid line changed")
		}
	}
}

func TestDesktopConnectionValidation(t *testing.T) {
	path, c := desktopFixture(t, "exit 0")
	if _, err := readDesktopConnection(path); err != nil {
		t.Fatalf("valid connection: %v", err)
	}
	for _, change := range []func(*desktopConnection){
		func(c *desktopConnection) { c.SchemaVersion = 2 },
		func(c *desktopConnection) { c.Endpoint = "http://localhost:42123/v1" },
		func(c *desktopConnection) { c.Endpoint = "http://127.0.0.1:0/v1" },
		func(c *desktopConnection) { c.Endpoint = "http://127.0.0.1:42123/v1/other" },
		func(c *desktopConnection) { c.ClientKey = "short" },
		func(c *desktopConnection) { c.ClientKey = strings.Repeat("k", 24) + "\n" },
		func(c *desktopConnection) { c.RunID = "bad id" },
		func(c *desktopConnection) { c.CodexExecutable = "relative" },
	} {
		bad := c
		change(&bad)
		desktopWriteConnection(t, path, bad)
		if _, err := readDesktopConnection(path); err == nil {
			t.Fatalf("accepted invalid connection: %+v", bad)
		}
	}
	desktopWriteConnection(t, path, c)
	if err := os.Chmod(path, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := readDesktopConnection(path); err == nil {
		t.Fatal("accepted permissive mode")
	}
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(filepath.Dir(path), "link.json")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if _, err := readDesktopConnection(link); err == nil {
		t.Fatal("accepted symlink")
	}
	if err := os.WriteFile(path, bytes.Repeat([]byte("x"), desktopConnectionLimit+1), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := readDesktopConnection(path); err == nil {
		t.Fatal("accepted oversized connection")
	}
}

func TestDesktopArgsAndPassthrough(t *testing.T) {
	path, c := desktopFixture(t, `printf '%s\n' "$@" > "$AIGOODBRO_FIXTURE_ARGS"; printf '%s' "${AIGOODBRO_PROXY_KEY:-}" > "$AIGOODBRO_FIXTURE_KEY"; exit 23`)
	argsPath := filepath.Join(t.TempDir(), "args")
	keyPath := filepath.Join(t.TempDir(), "key")
	t.Setenv("AIGOODBRO_FIXTURE_ARGS", argsPath)
	t.Setenv("AIGOODBRO_FIXTURE_KEY", keyPath)
	for _, tc := range []struct {
		args      []string
		wantProxy bool
	}{
		{[]string{"--version"}, false},
		{[]string{"-c", `model="original"`, "app-server", "--listen", "stdio://"}, true},
	} {
		cmd := desktopTestCommand(t, path, tc.args...)
		if err := cmd.Run(); err == nil || cmd.ProcessState.ExitCode() != 23 {
			t.Fatalf("exit result = %v", err)
		}
		args, err := os.ReadFile(argsPath)
		if err != nil {
			t.Fatal(err)
		}
		key, err := os.ReadFile(keyPath)
		if err != nil {
			t.Fatal(err)
		}
		if bytes.Contains(args, []byte(c.ClientKey)) || len(key) != 0 || (tc.wantProxy && (!bytes.Contains(args, []byte(`model_provider="openai"`)) || !bytes.Contains(args, []byte(`openai_base_url="http://127.0.0.1:`)) || !bytes.Contains(args, []byte(`model="original"`)))) || (!tc.wantProxy && string(args) != "--version\n") {
			t.Fatalf("wrong args or key placement: args=%q, key-present=%t", args, len(key) != 0)
		}
	}
}

func TestDesktopKeepsOfficialRuntimeDiscovery(t *testing.T) {
	got := desktopEnvironment([]string{"HOME=/fixture", "CODEX_CLI_PATH=/adapter", "AIGOODBRO_PROXY_KEY=fixture-secret", "AIGOODBRO_PROXY_CONNECTION_FILE=/connection", "PATH=/bin"}, "/official/Resources/codex")
	want := []string{"HOME=/fixture", "PATH=/bin", "CODEX_CLI_PATH=/official/Resources/codex"}
	if !reflect.DeepEqual(got, want) {
		t.Fatal("official runtime path or environment isolation lost")
	}
}

func TestDesktopInputHasNoFormer64MiBLimit(t *testing.T) {
	// Exercise an unchanged JSONL record without keeping a second large copy.
	input := io.MultiReader(strings.NewReader(`{"method":"fixture","payload":"`), io.LimitReader(repeatedByte('x'), 65<<20), strings.NewReader("\"}\n"))
	out := &countingDesktopWriter{}
	if err := forwardDesktopInput(input, out); err != nil || out.n <= 64<<20 || !out.closed {
		t.Fatalf("large Desktop record failed: bytes=%d closed=%t error=%v", out.n, out.closed, err)
	}
}

type repeatedByte byte

func (b repeatedByte) Read(p []byte) (int, error) {
	for i := range p {
		p[i] = byte(b)
	}
	return len(p), nil
}

type countingDesktopWriter struct {
	n      int
	closed bool
}

func (w *countingDesktopWriter) Write(p []byte) (int, error) { w.n += len(p); return len(p), nil }
func (w *countingDesktopWriter) Close() error                { w.closed = true; return nil }

func TestDesktopChildExitWithOpenStdin(t *testing.T) {
	path, _ := desktopFixture(t, "exit 7")
	readEnd, writeEnd, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer writeEnd.Close()
	defer readEnd.Close()
	cmd := desktopTestCommand(t, path, "app-server")
	cmd.Stdin = readEnd
	done := make(chan error, 1)
	go func() { done <- cmd.Run() }()
	select {
	case err := <-done:
		if err == nil || cmd.ProcessState.ExitCode() != 7 {
			t.Fatalf("exit result = %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("wrapper waited for stdin after child exited")
	}
}

func TestDesktopBridgeClosesGatewayAfterBackendExit(t *testing.T) {
	path, _ := desktopFixture(t, `printf '%s\n' "$@"; exit 0`)
	cmd := desktopTestCommand(t, path, "app-server")
	data, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	var address string
	for _, arg := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(arg, `openai_base_url="`) {
			endpoint := strings.TrimSuffix(strings.TrimPrefix(arg, `openai_base_url="`), `"`)
			address = strings.TrimSuffix(strings.TrimPrefix(endpoint, "http://"), "/v1")
		}
	}
	if address == "" {
		t.Fatal("gateway endpoint missing")
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		connection, err := net.DialTimeout("tcp", address, 100*time.Millisecond)
		if err != nil {
			return
		}
		_ = connection.Close()
		if time.Now().After(deadline) {
			t.Fatal("gateway survived its backend")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestDesktopBridgeBoundsShutdownAfterInputEOF(t *testing.T) {
	path, _ := desktopFixture(t, `trap 'exit 0' TERM; while :; do sleep 0.1; done`)
	cmd := desktopTestCommand(t, path, "app-server")
	done := make(chan error, 1)
	go func() { done <- cmd.Run() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("backend did not shut down gracefully: %v", err)
		}
	case <-time.After(7 * time.Second):
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		t.Fatal("backend survived Desktop input EOF")
	}
}

func desktopTestCommand(t *testing.T, connection string, args ...string) *exec.Cmd {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(self, args...)
	cmd.Env = append(os.Environ(), "AIGOODBRO_DESKTOP_TEST_CHILD=1", "AIGOODBRO_PROXY_CONNECTION_FILE="+connection)
	cmd.Stderr = os.Stderr
	return cmd
}
