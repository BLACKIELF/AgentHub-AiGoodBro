package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/router-for-me/CLIProxyAPI/v8/internal/registry"
	auth "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
)

func hotCommand(rt *runtime, id string) networkCommand {
	return networkCommand{Command: "register_account", RunID: rt.runID, RequestID: uuid.NewString(), ProfileID: id, IdentityHash: fmt.Sprintf("%064x", id)}
}
func registerFixture(t *testing.T, rt *runtime, cmd networkCommand) event {
	t.Helper()
	out := &synchronizedBuffer{}
	rt.registerAccount(cmd, &events{out: out})
	var reply event
	if err := json.Unmarshal([]byte(out.String()), &reply); err != nil {
		t.Fatal(err)
	}
	if reply.Event != "account_registered" || reply.RequestID != cmd.RequestID || reply.RunID != cmd.RunID || reply.ProfileID != cmd.ProfileID || reply.IdentityHash != cmd.IdentityHash {
		t.Fatalf("uncorrelated ACK: %+v", reply)
	}
	return reply
}
func hotRuntime(t *testing.T) (*runtime, *fakeBridge, startup) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	s.AccountIdentityHashes = map[string]string{"A": fmt.Sprintf("%064x", "A"), "B": fmt.Sprintf("%064x", "B")}
	rt, err := newRuntime(s, &events{out: &synchronizedBuffer{}}, "http://127.0.0.1:1")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(rt.close)
	return rt, b, s
}
func TestHotRegistrationBoundedIdentityAndIdempotency(t *testing.T) {
	rt, _, _ := hotRuntime(t)
	valid := hotCommand(rt, "C")
	for name, change := range map[string]func(*networkCommand){
		"wrong-run":   func(c *networkCommand) { c.RunID = "old-run" },
		"bad-id":      func(c *networkCommand) { c.ProfileID = "../C" },
		"bad-hash":    func(c *networkCommand) { c.IdentityHash = "not-a-hash" },
		"bad-request": func(c *networkCommand) { c.RequestID = "no-uuid" },
	} {
		t.Run(name, func(t *testing.T) {
			c := valid
			change(&c)
			r := registerFixture(t, rt, c)
			if r.State != "rejected" || !reflect.DeepEqual(rt.registeredIDs(), []string{"A", "B"}) {
				t.Fatalf("admitted invalid command: %+v", r)
			}
		})
	}
	r := registerFixture(t, rt, valid)
	if r.State != "registered" || !reflect.DeepEqual(rt.registeredIDs(), []string{"A", "B", "C"}) {
		t.Fatalf("not added: %+v", r)
	}
	first, ok := rt.manager.GetByID("C")
	if !ok {
		t.Fatal("missing auth")
	}
	if len(first.Metadata) != 1 || first.Metadata["type"] != "codex" || rt.recovery.account("C") == nil || rt.network.identity("C") != valid.IdentityHash || !registry.GetGlobalRegistry().ClientSupportsModel("C", "fixture-model") {
		t.Fatal("incomplete token-free registration")
	}
	// A lost ACK can retry without replacing auth or clearing its cooldown.
	rt.manager.MarkResult(context.Background(), auth.Result{AuthID: "C", Provider: "codex", Model: "fixture-model", Error: &auth.Error{HTTPStatus: 429}})
	cooled, _ := rt.manager.GetByID("C")
	valid.RequestID = uuid.NewString()
	if registerFixture(t, rt, valid).State != "registered" {
		t.Fatal("same identity retry rejected")
	}
	after, _ := rt.manager.GetByID("C")
	if after.RegistrationEpoch != first.RegistrationEpoch || !reflect.DeepEqual(after.ModelStates, cooled.ModelStates) {
		t.Fatal("idempotent retry changed epoch/cooldown")
	}
	changed := valid
	changed.IdentityHash = fmt.Sprintf("%064x", "different")
	if registerFixture(t, rt, changed).ErrorCode != "identity" {
		t.Fatal("same id changed identity accepted")
	}
	duplicate := hotCommand(rt, "D")
	duplicate.IdentityHash = valid.IdentityHash
	if registerFixture(t, rt, duplicate).ErrorCode != "duplicate_identity" {
		t.Fatal("duplicate account identity accepted")
	}
	rt.gate.Lock()
	rt.stopping = true
	rt.gate.Unlock()
	if registerFixture(t, rt, hotCommand(rt, "E")).ErrorCode != "stopping" {
		t.Fatal("stopping run accepted new account")
	}
}
func TestHotRegistrationPreservesUnexpiredCooldown(t *testing.T) {
	for _, independent := range []bool{false, true} {
		t.Run(fmt.Sprint(independent), func(t *testing.T) {
			rt, _, s := hotRuntime(t)
			row := safeCooldown{ID: "C", Model: "fixture-model"}
			if independent {
				row.Independent = &safeIndependentCooldown{Until: time.Now().Add(time.Hour)}
			} else {
				row.Until = time.Now().Add(time.Hour)
			}
			data, _ := json.Marshal([]safeCooldown{row})
			path := filepath.Join(s.StateDirectory, "cooldown.json")
			if err := os.WriteFile(path, data, 0600); err != nil {
				t.Fatal(err)
			}
			reply := registerFixture(t, rt, hotCommand(rt, "C"))
			after, _ := os.ReadFile(path)
			if reply.ErrorCode != "cooldown_pending" || string(after) != string(data) || len(rt.registeredIDs()) != 2 || rt.network.identity("C") != "" {
				t.Fatal("hot registration bypassed or mutated pending cooldown")
			}
			if _, ok := rt.manager.GetByID("C"); ok {
				t.Fatal("rejected account leaked into manager")
			}
			if err := os.WriteFile(path, []byte("broken"), 0600); err != nil {
				t.Fatal(err)
			}
			if registerFixture(t, rt, hotCommand(rt, "C")).ErrorCode != "cooldown_unavailable" {
				t.Fatal("unknown cooldown failed open")
			}
		})
	}
}
func TestHotRegistrationKeepsExistingStreamAndRequiresNewHostOrder(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	s.AccountIdentityHashes = map[string]string{"A": fmt.Sprintf("%064x", "A"), "B": fmt.Sprintf("%064x", "B")}
	b.setOrder("A")
	release := make(chan struct{})
	var once sync.Once
	defer once.Do(func() { close(release) })
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer fixture-")
		if id == "A" {
			w.Header().Set("Content-Type", "text/event-stream")
			sse(w, map[string]any{"type": "response.created", "response": map[string]any{"id": "resp_fixture", "status": "in_progress"}})
			sse(w, map[string]any{"type": "response.output_text.delta", "delta": "old-stream"})
			select {
			case <-release:
			case <-r.Context().Done():
				return
			}
		}
		complete(w, id)
	}))
	defer upstream.Close()
	rt, server, _ := startTestRuntime(t, s, upstream.URL)
	old := request(t, s, server.URL, true)
	if !b.hasLease("A") {
		t.Fatal("old stream not admitted")
	}
	if registerFixture(t, rt, hotCommand(rt, "C")).State != "registered" {
		t.Fatal("hot add failed")
	}
	// ACK alone cannot expose C: the host still offers only A.
	second := request(t, s, server.URL, false)
	consume(t, second)
	if b.hasLease("C") {
		t.Fatal("helper selected C before host activation")
	}
	b.setOrder("C", "A")
	fresh := request(t, s, server.URL, false)
	if body := consume(t, fresh); !strings.Contains(body, "done-C") {
		t.Fatalf("new request did not route C: %s", body)
	}
	if !b.hasLease("A") {
		t.Fatal("hot add released prior stream")
	}
	once.Do(func() { close(release) })
	if body := consume(t, old); !strings.Contains(body, "old-stream") || !strings.Contains(body, "done-A") {
		t.Fatal("old stream interrupted")
	}
	waitEmpty(t, b)
	if !reflect.DeepEqual(acquiredSnapshot(b), []string{"A", "C"}) {
		t.Fatalf("unexpected admissions: %v", acquiredSnapshot(b))
	}
}
func TestHotRegistrationConcurrentReadersAndStop(t *testing.T) {
	rt, _, _ := hotRuntime(t)
	done := make(chan struct{})
	var readers sync.WaitGroup
	for i := 0; i < 6; i++ {
		readers.Add(1)
		go func() {
			defer readers.Done()
			for {
				select {
				case <-done:
					return
				default:
					for _, id := range rt.registeredIDs() {
						_ = rt.recovery.account(id)
						_ = rt.network.identity(id)
					}
					_ = rt.ensureResponseModel(context.Background(), "fixture-dynamic")
				}
			}
		}()
	}
	for i := 0; i < 20; i++ {
		if registerFixture(t, rt, hotCommand(rt, fmt.Sprintf("hot-%d", i))).State != "registered" {
			t.Fatal("concurrent registration rejected")
		}
	}
	close(done)
	readers.Wait()
	end := make(chan struct{})
	go func() { rt.close(); close(end) }()
	reply := registerFixture(t, rt, hotCommand(rt, "stop-race"))
	if reply.State != "registered" && reply.ErrorCode != "stopping" {
		t.Fatalf("unexpected stop outcome %+v", reply)
	}
	select {
	case <-end:
	case <-time.After(3 * time.Second):
		t.Fatal("close/register deadlock")
	}
	if registerFixture(t, rt, hotCommand(rt, "after-close")).ErrorCode != "stopping" {
		t.Fatal("closed run revived")
	}
}

// A host that stops consuming stdout must not hold the runtime admission gate.
type stalledHotACK struct {
	entered chan struct{}
	release chan struct{}
}

func (w *stalledHotACK) Write(data []byte) (int, error) {
	close(w.entered)
	<-w.release
	return len(data), nil
}
func TestHotRegistrationStalledACKDoesNotHoldShutdown(t *testing.T) {
	rt, _, _ := hotRuntime(t)
	out := &stalledHotACK{entered: make(chan struct{}), release: make(chan struct{})}
	registered := make(chan struct{})
	go func() { rt.registerAccount(hotCommand(rt, "C"), &events{out: out}); close(registered) }()
	select {
	case <-out.entered:
	case <-time.After(3 * time.Second):
		t.Fatal("ACK writer never entered")
	}
	defer close(out.release)
	stopped := make(chan struct{})
	go func() { rt.close(); close(stopped) }()
	select {
	case <-stopped:
	case <-time.After(3 * time.Second):
		t.Fatal("stalled ACK held shutdown gate")
	}
	select {
	case <-registered:
		t.Fatal("fixture ACK was not stalled")
	default:
	}
}
