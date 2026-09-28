package main

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
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
		if code := runDesktopAdapter(path, tc.args); code != 23 {
			t.Fatalf("exit code = %d", code)
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
	old := os.Stdin
	os.Stdin = readEnd
	defer func() { os.Stdin = old }()
	done := make(chan int, 1)
	go func() { done <- runDesktopAdapter(path, []string{"app-server"}) }()
	select {
	case code := <-done:
		if code != 7 {
			t.Fatalf("exit code = %d", code)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("wrapper waited for stdin after child exited")
	}
}
