package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"strings"
	"testing"
	"time"
)

func TestWindowsDesktopEvidenceCrossLanguageFixture(t *testing.T) {
	input, output := os.Getenv("AIGOODBRO_TEST_EVIDENCE_INPUT"), os.Getenv("AIGOODBRO_TEST_EVIDENCE_OUTPUT")
	if input == "" && output == "" {
		t.Skip("explicit synthetic Rust cross-language fixture only")
	}
	if input == "" || output == "" {
		t.Fatal("incomplete cross-language fixture")
	}
	file, err := os.Open(input)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	var fixture struct {
		Synthetic bool            `json:"syntheticFixture"`
		WriterID  string          `json:"writerID"`
		RunID     string          `json:"proxyRunID"`
		AuthPath  string          `json:"authPath"`
		Account   json.RawMessage `json:"account"`
		Limits    json.RawMessage `json:"rateLimits"`
	}
	if json.NewDecoder(io.LimitReader(file, 2<<20)).Decode(&fixture) != nil || !fixture.Synthetic || !identifier.MatchString(fixture.WriterID) || !identifier.MatchString(fixture.RunID) {
		t.Fatal("fixture is not explicitly synthetic")
	}
	auth, err := os.ReadFile(fixture.AuthPath)
	if err != nil || len(auth) > 1<<20 || !strings.Contains(string(auth), "synthetic") {
		t.Fatal("cross-language fixture must not contain real credentials")
	}
	digest := sha256.Sum256(auth)
	var requests []map[string]any
	proofs := make(chan desktopEvidenceProof, 1)
	e := newDesktopEvidenceWith(desktopEvidenceConfig{WriterID: fixture.WriterID, RunID: fixture.RunID}, func() (string, error) { return hex.EncodeToString(digest[:]), nil }, func(line []byte) error {
		var request map[string]any
		_ = json.Unmarshal(line, &request)
		requests = append(requests, request)
		return nil
	}, func(p desktopEvidenceProof) { proofs <- p })
	defer e.cancel()
	e.initialized = true
	e.clientReady = true
	e.probe()
	if len(requests) != 2 {
		t.Fatal("production collector did not issue the official RPC pair")
	}
	for i, request := range requests {
		result := fixture.Account
		if i == 1 {
			result = fixture.Limits
		}
		line, _ := json.Marshal(map[string]any{"id": request["id"], "result": json.RawMessage(result)})
		if !e.fromBackend(line) {
			t.Fatal("private RPC was not consumed")
		}
	}
	select {
	case proof := <-proofs:
		destination, err := os.OpenFile(output, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			t.Fatal(err)
		}
		defer destination.Close()
		if err = json.NewEncoder(destination).Encode(proof); err != nil {
			t.Fatal(err)
		}
		if err = destination.Sync(); err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("production collector did not publish the proof")
	}
}
