//go:build windows

package main

import (
	"bufio"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// This is dispatched only by the test binary copied to its isolated backend
// fixture name. It never runs the official Codex executable or contacts upstream.
func windowsDesktopBackendFixture() bool {
	if os.Getenv("AIGOODBRO_WINDOWS_BACKEND_FIXTURE") != "1" || !strings.EqualFold(filepath.Base(os.Args[0]), "fixture-evidence-backend.exe") {
		return false
	}
	reader := bufio.NewScanner(os.Stdin)
	for reader.Scan() {
		var request struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
		}
		if json.Unmarshal(reader.Bytes(), &request) != nil {
			continue
		}
		if len(request.ID) == 0 {
			continue
		}
		result := any(map[string]any{})
		switch request.Method {
		case "account/read":
			result = map[string]any{"account": map[string]any{"type": "chatgpt", "email": "synthetic@example.invalid", "planType": "plus"}}
		case "account/rateLimits/read":
			result = map[string]any{"rateLimits": map[string]any{"primary": map[string]any{"usedPercent": 1, "windowDurationMins": 300, "resetsAt": time.Now().Add(time.Hour).Unix()}, "secondary": map[string]any{"usedPercent": 2, "windowDurationMins": 10080, "resetsAt": time.Now().Add(time.Hour).Unix()}}}
		}
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"id": json.RawMessage(request.ID), "result": result})
	}
	return true
}
func TestWindowsDesktopActualAdapterUsesOneBackendForAuthenticatedEvidence(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "private-desktop")
	if err := privateDirectory(dir, true); err != nil {
		t.Fatal(err)
	}
	backend := filepath.Join(dir, "fixture-evidence-backend.exe")
	source, err := os.Open(os.Args[0])
	if err != nil {
		t.Fatal(err)
	}
	defer source.Close()
	destination, err := os.OpenFile(backend, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = io.Copy(destination, source); err != nil {
		t.Fatal(err)
	}
	destination.Close()
	auth := []byte(`{"auth_mode":"chatgpt","tokens":{"access_token":"synthetic-test-token"}}`)
	if err = os.WriteFile(filepath.Join(dir, "auth.json"), auth, 0600); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	key := strings.Repeat("b", 64)
	proofs := make(chan desktopEvidenceProof, 1)
	go func() {
		c, err := listener.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		var packet struct {
			SchemaVersion int                  `json:"schemaVersion"`
			Key           string               `json:"key"`
			Proof         desktopEvidenceProof `json:"proof"`
		}
		if json.NewDecoder(c).Decode(&packet) == nil && packet.Key == key && packet.SchemaVersion == 1 {
			proofs <- packet.Proof
			_, _ = io.WriteString(c, "{\"ok\":true}\n")
		}
	}()
	connection := desktopConnection{SchemaVersion: 1, RunID: "fixture-proxy-run", Endpoint: "http://127.0.0.1:42123/v1", ClientKey: strings.Repeat("c", 64), CodexExecutable: backend, WriterID: "fixture-writer", EvidenceEndpoint: "tcp:" + listener.Addr().String(), EvidenceKey: key}
	path := filepath.Join(dir, "desktop-connection.json")
	data, _ := json.Marshal(connection)
	if err = os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	command := exec.Command(os.Args[0], "app-server")
	command.Env = append(os.Environ(), "AIGOODBRO_DESKTOP_TEST_CHILD=1", "AIGOODBRO_WINDOWS_BACKEND_FIXTURE=1", "AIGOODBRO_PROXY_CONNECTION_FILE="+path, "CODEX_HOME="+dir)
	input, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	output, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	command.Stderr = io.Discard
	if err = command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { input.Close(); _ = command.Process.Kill(); _ = command.Wait() })
	lines := make(chan string, 8)
	go func() {
		scanner := bufio.NewScanner(output)
		for scanner.Scan() {
			lines <- scanner.Text()
		}
		close(lines)
	}()
	_, _ = io.WriteString(input, "{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"synthetic\",\"version\":\"0\"}}}\n")
	select {
	case line := <-lines:
		if !strings.Contains(line, `"id":1`) {
			t.Fatal("ordinary initialize response missing")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("adapter did not initialize")
	}
	_, _ = io.WriteString(input, "{\"method\":\"initialized\"}\n")
	select {
	case proof := <-proofs:
		if proof.WriterID != "fixture-writer" || proof.RunID != "fixture-proxy-run" || proof.BackendID == "" || proof.AuthDigest == "" || len(proof.Account) == 0 || len(proof.RateLimits) == 0 {
			t.Fatal("same-backend evidence missing required binding")
		}
	case <-time.After(8 * time.Second):
		t.Fatal("actual Windows adapter did not publish authenticated same-backend evidence")
	}
	select {
	case line := <-lines:
		t.Fatalf("private evidence RPC leaked: %q", line)
	case <-time.After(30 * time.Millisecond):
	}
	input.Close()
	finished := make(chan error, 1)
	go func() { finished <- command.Wait() }()
	select {
	case <-finished:
	case <-time.After(5 * time.Second):
		t.Fatal("owned backend failed EOF exit")
	}
}

func TestWindowsDesktopGatewayReloadsOnlySameWriterConnectionAfterRestart(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "private-desktop")
	if err := privateDirectory(dir, true); err != nil {
		t.Fatal(err)
	}
	source, err := os.Open(os.Args[0])
	if err != nil {
		t.Fatal(err)
	}
	defer source.Close()
	backend := filepath.Join(dir, "fixture-evidence-backend.exe")
	destination, err := os.OpenFile(backend, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = io.Copy(destination, source); err != nil {
		t.Fatal(err)
	}
	destination.Close()
	if err = os.WriteFile(filepath.Join(dir, "auth.json"), []byte(`{"auth_mode":"chatgpt","tokens":{"access_token":"synthetic-local-bearer"}}`), 0600); err != nil {
		t.Fatal(err)
	}
	first := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+strings.Repeat("a", 64) {
			t.Error("first run key mismatch")
		}
		_, _ = io.WriteString(w, "first")
	}))
	defer first.Close()
	second := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+strings.Repeat("b", 64) {
			t.Error("new run key mismatch")
		}
		_, _ = io.WriteString(w, "second")
	}))
	defer second.Close()
	c := desktopConnection{SchemaVersion: 1, RunID: "first-run", Endpoint: first.URL + "/v1", ClientKey: strings.Repeat("a", 64), CodexExecutable: backend, WriterID: "same-writer", EvidenceEndpoint: "tcp:127.0.0.1:42123", EvidenceKey: strings.Repeat("e", 64)}
	path := filepath.Join(dir, "desktop-connection.json")
	save := func() {
		data, _ := json.Marshal(c)
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	save()
	t.Setenv("AIGOODBRO_PROXY_CONNECTION_FILE", path)
	gateway, endpoint, err := startDesktopGatewayWithCatalog(c, []string{"CODEX_HOME=" + dir}, http.NotFoundHandler())
	if err != nil {
		t.Fatal(err)
	}
	defer gateway.Close()
	request := func() string {
		req, _ := http.NewRequest("POST", endpoint+"/responses", strings.NewReader(`{"model":"synthetic"}`))
		req.Header.Set("Authorization", "Bearer synthetic-local-bearer")
		response, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		body, _ := io.ReadAll(response.Body)
		return string(body)
	}
	if body := request(); body != "first" {
		t.Fatal("initial gateway route failed")
	}
	c.Endpoint = second.URL + "/v1"
	c.ClientKey = strings.Repeat("b", 64)
	c.RunID = "second-run"
	save()
	if body := request(); body != "second" {
		t.Fatal("same owned writer did not adopt new loopback endpoint/key")
	}
	c.WriterID = "unrelated-writer"
	save()
	if body := request(); body == "second" {
		t.Fatal("gateway accepted another writer connection")
	}
}
