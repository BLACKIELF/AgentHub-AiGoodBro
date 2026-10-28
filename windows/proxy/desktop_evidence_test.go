package main

import (
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestWindowsDesktopEvidenceUsesSameBackendAndDoesNotLeakPrivateReplies(t *testing.T) {
	var mu sync.Mutex
	var requests []map[string]any
	proofs := make(chan desktopEvidenceProof, 2)
	digest := strings.Repeat("a", 64)
	e := newDesktopEvidenceWith(desktopEvidenceConfig{WriterID: "synthetic-writer", RunID: "synthetic-run"}, func() (string, error) { return digest, nil }, func(line []byte) error {
		var q map[string]any
		_ = json.Unmarshal(line, &q)
		mu.Lock()
		requests = append(requests, q)
		mu.Unlock()
		return nil
	}, func(p desktopEvidenceProof) { proofs <- p })
	defer e.cancel()
	e.initialized = true
	e.clientReady = true
	e.probe()
	mu.Lock()
	snapshot := append([]map[string]any(nil), requests...)
	mu.Unlock()
	if len(snapshot) != 2 || snapshot[0]["method"] != "account/read" || snapshot[1]["method"] != "account/rateLimits/read" {
		t.Fatal("official same-backend quota RPCs missing")
	}
	if snapshot[0]["params"].(map[string]any)["refreshToken"] != false {
		t.Fatal("evidence collector requested refresh")
	}
	for i, q := range snapshot {
		line, _ := json.Marshal(map[string]any{"id": q["id"], "result": map[string]any{"synthetic": i}})
		if !e.fromBackend(line) {
			t.Fatal("private reply leaked into Desktop")
		}
	}
	select {
	case p := <-proofs:
		if p.AuthDigest != digest || p.WriterID != "synthetic-writer" || p.BackendID == "" {
			t.Fatal("proof lost bound owner/digest")
		}
		if len(p.BackendID) != 32 || strings.IndexFunc(p.BackendID, func(c rune) bool { return !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') }) >= 0 {
			t.Fatal("backend ID does not match native account evidence contract")
		}
	case <-time.After(time.Second):
		t.Fatal("same-generation proof missing")
	}
	if e.fromBackend([]byte(`{"id":"ordinary-client","result":{}}`)) {
		t.Fatal("ordinary RPC consumed")
	}
	// Old cycle replies are swallowed, but never attributed to a new cycle.
	e.probe()
	for _, q := range snapshot {
		line, _ := json.Marshal(map[string]any{"id": q["id"], "result": map[string]any{"late": true}})
		if !e.fromBackend(line) {
			t.Fatal("late private reply leaked")
		}
	}
	select {
	case <-proofs:
		t.Fatal("late old cycle generated fresh evidence")
	case <-time.After(30 * time.Millisecond):
	}
}
func TestWindowsDesktopEvidenceRejectsAuthRotationAcrossRPCPair(t *testing.T) {
	digest := strings.Repeat("a", 64)
	var requests []map[string]any
	proofs := make(chan desktopEvidenceProof, 1)
	e := newDesktopEvidenceWith(desktopEvidenceConfig{}, func() (string, error) { return digest, nil }, func(line []byte) error {
		var q map[string]any
		_ = json.Unmarshal(line, &q)
		requests = append(requests, q)
		return nil
	}, func(p desktopEvidenceProof) { proofs <- p })
	defer e.cancel()
	e.initialized = true
	e.clientReady = true
	e.probe()
	digest = strings.Repeat("b", 64)
	for _, q := range requests {
		line, _ := json.Marshal(map[string]any{"id": q["id"], "result": map[string]any{"synthetic": true}})
		e.fromBackend(line)
	}
	select {
	case <-proofs:
		t.Fatal("mixed-generation proof published")
	case <-time.After(30 * time.Millisecond):
	}
}

func TestWindowsDesktopEvidenceWaitsForForwardedInitializedAndBindsRestartRun(t *testing.T) {
	var mu sync.Mutex
	var requests []map[string]any
	proofs := make(chan desktopEvidenceProof, 1)
	run := "run-before"
	e := newDesktopEvidenceWith(desktopEvidenceConfig{RunID: run}, func() (string, error) { return strings.Repeat("a", 64), nil }, func(line []byte) error {
		var q map[string]any
		_ = json.Unmarshal(line, &q)
		mu.Lock()
		requests = append(requests, q)
		mu.Unlock()
		return nil
	}, func(p desktopEvidenceProof) { proofs <- p })
	defer e.cancel()
	e.readRun = func() (string, error) { return run, nil }
	e.fromClient([]byte(`{"id":1,"method":"initialize"}`))
	e.fromBackend([]byte(`{"id":1,"result":{}}`))
	time.Sleep(20 * time.Millisecond)
	mu.Lock()
	n := len(requests)
	mu.Unlock()
	if n != 0 {
		t.Fatal("quota RPC raced before initialized notification")
	}
	e.afterClient([]byte(`{"method":"initialized"}`), nil)
	time.Sleep(20 * time.Millisecond)
	mu.Lock()
	snapshot := append([]map[string]any(nil), requests...)
	mu.Unlock()
	if len(snapshot) != 2 {
		t.Fatal("same backend evidence not started after initialization")
	}
	run = "run-after"
	for _, q := range snapshot {
		line, _ := json.Marshal(map[string]any{"id": q["id"], "result": map[string]any{"synthetic": true}})
		e.fromBackend(line)
	}
	select {
	case <-proofs:
		t.Fatal("old-run pair crossed new connection epoch")
	case <-time.After(20 * time.Millisecond):
	}
}
