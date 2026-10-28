package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/google/uuid"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Only the already-owned backend may answer these internal read-only RPCs.
// Nothing starts a second official app-server or refreshes a token here.
type desktopEvidenceConfig struct{ Address, Key, WriterID, RunID string }
type desktopEvidenceProof struct {
	WriterID   string          `json:"writerID"`
	RunID      string          `json:"proxyRunID"`
	BackendID  string          `json:"backendID"`
	ObservedAt float64         `json:"observedAt"`
	AuthDigest string          `json:"authDigest"`
	Account    json.RawMessage `json:"account"`
	RateLimits json.RawMessage `json:"rateLimits"`
}
type desktopEvidence struct {
	mu                                                           sync.Mutex
	config                                                       desktopEvidenceConfig
	backendID, prefix, initializeID, digest, accountID, limitsID string
	initialized                                                  bool
	clientReady                                                  bool
	account, limits                                              json.RawMessage
	started                                                      time.Time
	pending                                                      bool
	readDigest                                                   func() (string, error)
	readRun                                                      func() (string, error)
	activeRun                                                    string
	write                                                        func([]byte) error
	publish                                                      func(desktopEvidenceProof)
	ctx                                                          context.Context
	cancel                                                       context.CancelFunc
	done                                                         chan struct{}
}

func newDesktopEvidence(config desktopEvidenceConfig, home string, write func([]byte) error) *desktopEvidence {
	e := newDesktopEvidenceWith(config, func() (string, error) { return desktopAuthDigest(filepath.Join(home, "auth.json")) }, write, nil)
	e.publish = func(proof desktopEvidenceProof) { e.send(proof) }
	e.readRun = func() (string, error) { return desktopEvidenceRun(config) }
	return e
}
func newDesktopEvidenceWith(config desktopEvidenceConfig, read func() (string, error), write func([]byte) error, publish func(desktopEvidenceProof)) *desktopEvidence {
	ctx, cancel := context.WithCancel(context.Background())
	id := strings.ReplaceAll(uuid.NewString(), "-", "")
	return &desktopEvidence{config: config, backendID: id, prefix: "aigoodbro-evidence-" + id + "-", readDigest: read, write: write, publish: publish, ctx: ctx, cancel: cancel, done: make(chan struct{})}
}
func (e *desktopEvidence) start() {
	go func() {
		defer close(e.done)
		timer := time.NewTicker(15 * time.Second)
		defer timer.Stop()
		for {
			select {
			case <-e.ctx.Done():
				return
			case <-timer.C:
				e.probe()
			}
		}
	}()
}
func (e *desktopEvidence) close() { e.cancel(); <-e.done }
func (e *desktopEvidence) fromClient(line []byte) {
	var request struct {
		ID     json.RawMessage `json:"id"`
		Method string          `json:"method"`
	}
	if json.Unmarshal(line, &request) == nil && request.Method == "initialize" && len(request.ID) > 0 {
		e.mu.Lock()
		e.initializeID = string(request.ID)
		e.mu.Unlock()
	}
}
func (e *desktopEvidence) afterClient(line []byte, forwardErr error) {
	if forwardErr != nil {
		return
	}
	var request struct {
		Method string `json:"method"`
	}
	if json.Unmarshal(line, &request) != nil {
		return
	}
	if request.Method == "initialized" {
		e.mu.Lock()
		e.clientReady = true
		e.mu.Unlock()
		go e.probe()
	}
}

// Returns true for private responses, including late replies from old cycles.
func (e *desktopEvidence) fromBackend(line []byte) bool {
	var reply struct {
		ID     json.RawMessage `json:"id"`
		Result json.RawMessage `json:"result"`
		Error  json.RawMessage `json:"error"`
	}
	if json.Unmarshal(line, &reply) != nil {
		return false
	}
	e.mu.Lock()
	initialize := e.initializeID != "" && string(reply.ID) == e.initializeID && !e.initialized
	hasError := len(reply.Error) > 0 && !bytes.Equal(reply.Error, []byte("null"))
	if initialize && !hasError && len(reply.Result) > 0 {
		e.initialized = true
	}
	e.mu.Unlock()
	if initialize {
		go e.probe()
		return false
	}
	var id string
	if json.Unmarshal(reply.ID, &id) != nil || len(id) < len(e.prefix) || id[:len(e.prefix)] != e.prefix {
		return false
	}
	e.mu.Lock()
	if !e.pending || time.Since(e.started) > 10*time.Second || hasError || len(reply.Result) == 0 || bytes.Equal(reply.Result, []byte("null")) || len(reply.Result) > 1<<20 {
		e.mu.Unlock()
		return true
	}
	switch id {
	case e.accountID:
		e.account = append([]byte(nil), reply.Result...)
	case e.limitsID:
		e.limits = append([]byte(nil), reply.Result...)
	default:
		e.mu.Unlock()
		return true
	}
	if len(e.account) == 0 || len(e.limits) == 0 {
		e.mu.Unlock()
		return true
	}
	proof := desktopEvidenceProof{WriterID: e.config.WriterID, RunID: e.activeRun, BackendID: e.backendID, AuthDigest: e.digest, ObservedAt: float64(time.Now().UnixNano()) / 1e9, Account: e.account, RateLimits: e.limits}
	e.pending = false
	e.mu.Unlock()
	run, runErr := e.currentRun()
	if digest, err := e.readDigest(); err == nil && digest == proof.AuthDigest && e.ctx.Err() == nil && runErr == nil && run == proof.RunID {
		go e.publish(proof)
	}
	return true
}
func (e *desktopEvidence) probe() {
	if e.ctx.Err() != nil {
		return
	}
	e.mu.Lock()
	if !e.initialized || !e.clientReady || (e.pending && time.Since(e.started) < 10*time.Second) {
		e.mu.Unlock()
		return
	}
	digest, err := e.readDigest()
	if err != nil {
		e.mu.Unlock()
		return
	}
	run, err := e.currentRun()
	if err != nil {
		e.mu.Unlock()
		return
	}
	e.activeRun = run
	e.digest = digest
	e.account = nil
	e.limits = nil
	e.started = time.Now()
	e.pending = true
	cycle := uuid.NewString()
	e.accountID, e.limitsID = e.prefix+cycle+"-account", e.prefix+cycle+"-limits"
	accountID, limitsID := e.accountID, e.limitsID
	e.mu.Unlock()
	for _, request := range []any{map[string]any{"id": accountID, "method": "account/read", "params": map[string]any{"refreshToken": false}}, map[string]any{"id": limitsID, "method": "account/rateLimits/read"}} {
		line, _ := json.Marshal(request)
		if e.ctx.Err() != nil || e.write(append(line, '\n')) != nil {
			e.mu.Lock()
			e.pending = false
			e.mu.Unlock()
			return
		}
	}
}
func (e *desktopEvidence) currentRun() (string, error) {
	if e.readRun != nil {
		return e.readRun()
	}
	return e.config.RunID, nil
}
func desktopAuthDigest(path string) (string, error) {
	f, err := desktopOpenFile(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > 1<<20 {
		return "", errors.New("desktop_auth_unverified")
	}
	data, err := io.ReadAll(io.LimitReader(f, (1<<20)+1))
	if err != nil || len(data) > 1<<20 {
		return "", errors.New("desktop_auth_unverified")
	}
	latest, err := os.Lstat(path)
	if err != nil || !os.SameFile(info, latest) || info.Size() != latest.Size() || info.ModTime() != latest.ModTime() {
		return "", errors.New("desktop_auth_changed")
	}
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:]), nil
}
func (e *desktopEvidence) send(proof desktopEvidenceProof) {
	ctx, cancel := context.WithTimeout(e.ctx, 3*time.Second)
	defer cancel()
	conn, err := dialControl(ctx, e.config.Address)
	if err != nil {
		return
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
	packet := struct {
		SchemaVersion int                  `json:"schemaVersion"`
		Key           string               `json:"key"`
		Proof         desktopEvidenceProof `json:"proof"`
	}{1, e.config.Key, proof}
	if json.NewEncoder(conn).Encode(packet) != nil {
		return
	}
	var reply struct {
		OK bool `json:"ok"`
	}
	_ = json.NewDecoder(io.LimitReader(conn, 1024)).Decode(&reply)
}
