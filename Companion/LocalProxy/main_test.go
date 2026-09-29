package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"github.com/gin-gonic/gin"
	auth "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
	logrus "github.com/sirupsen/logrus"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestMain(m *testing.M) {
	if os.Getenv("AIGOODBRO_DESKTOP_TEST_CHILD") == "1" {
		main()
		os.Exit(0)
	}
	gin.SetMode(gin.ReleaseMode)
	gin.DefaultWriter = io.Discard
	gin.DefaultErrorWriter = io.Discard
	logrus.SetOutput(io.Discard)
	if os.Getenv("AIGOODBRO_PROTOCOL_FIXTURE_CHILD") == "1" {
		runProtocolFixtureChild()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

type fakeBridge struct {
	failHeartbeat      bool
	expiresDelta       time.Duration
	mu                 sync.Mutex
	listener           net.Listener
	socket             string
	owned              map[string]string
	busy               map[string]bool
	acquired, released []string
	commands           []string
	order              []string
	denyRelease        bool
	admission          func(command, profileID string) bool
}

func newFakeBridge(t *testing.T) *fakeBridge {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "lp-")
	if err != nil {
		t.Fatal(err)
	}
	b := &fakeBridge{socket: filepath.Join(dir, "b.sock"), owned: map[string]string{}, busy: map[string]bool{}, order: []string{"A", "B"}}
	b.listener, err = net.Listen("unix", b.socket)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { b.listener.Close(); os.RemoveAll(dir) })
	go func() {
		for {
			c, err := b.listener.Accept()
			if err != nil {
				return
			}
			go b.serve(c)
		}
	}()
	return b
}
func (b *fakeBridge) serve(c net.Conn) {
	defer c.Close()
	var q bridgeRequest
	if json.NewDecoder(c).Decode(&q) != nil {
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	b.commands = append(b.commands, q.Command)
	reply := bridgeReply{OK: true}
	switch q.Command {
	case "order":
		reply.Order = append([]string(nil), b.order...)
	case "acquire", "acquire_credit_primary", "acquire_credit_secondary", "acquire_desktop", "acquire_desktop_credit_primary", "acquire_desktop_credit_secondary":
		if b.admission != nil && !b.admission(q.Command, q.ProfileID) {
			reply = bridgeReply{Error: "quota"}
		} else if b.busy[q.ProfileID] || b.owned[q.ProfileID] != "" {
			reply = bridgeReply{Error: "busy"}
		} else {
			b.owned[q.ProfileID] = q.RequestID
			b.acquired = append(b.acquired, q.ProfileID)
			reply.LeaseID = "lease-" + q.ProfileID
			reply.AccessToken = "fixture-" + q.ProfileID
			reply.AccountID = "fixture-account-" + q.ProfileID
			delta := b.expiresDelta
			if delta == 0 {
				delta = time.Hour
			}
			reply.ExpiresAt = time.Now().Add(delta).Unix()
		}
	case "release":
		if b.denyRelease {
			reply.OK = false
		} else if b.owned[q.ProfileID] != q.RequestID {
			reply.OK = false
		} else {
			delete(b.owned, q.ProfileID)
			b.released = append(b.released, q.ProfileID)
		}
	case "heartbeat":
		reply.OK = !b.failHeartbeat && b.owned[q.ProfileID] == q.RequestID
	default:
		reply.OK = false
	}
	_ = json.NewEncoder(c).Encode(reply)
}
func (b *fakeBridge) hasLease(id string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.owned[id] != ""
}
func (b *fakeBridge) count() int { b.mu.Lock(); defer b.mu.Unlock(); return len(b.owned) }
func newStartup(t *testing.T, b *fakeBridge) startup {
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	s := startup{SchemaVersion: 1, RunID: "run-test", ControlSocket: b.socket, ControlKey: strings.Repeat("k", 32), ClientKey: strings.Repeat("c", 32), StateDirectory: filepath.Join(dir, "state"), Models: []string{"fixture-model"}}
	for _, id := range []string{"A", "B"} {
		s.Accounts = append(s.Accounts, struct {
			ID string `json:"id"`
		}{id})
	}
	return s
}

type synchronizedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (b *synchronizedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.Write(p)
}
func (b *synchronizedBuffer) String() string { b.mu.Lock(); defer b.mu.Unlock(); return b.b.String() }
func startTestRuntime(t *testing.T, s startup, upstream string) (*runtime, *httptest.Server, *synchronizedBuffer) {
	t.Helper()
	out := &synchronizedBuffer{}
	rt, err := newRuntime(s, &events{out: out}, upstream)
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(rt.handler)
	t.Cleanup(func() { server.Close(); rt.close() })
	return rt, server, out
}
func request(t *testing.T, s startup, url string, stream bool) *http.Response {
	t.Helper()
	body := fmt.Sprintf(`{"model":"fixture-model","input":"synthetic","stream":%t}`, stream)
	req, _ := http.NewRequest("POST", url+"/v1/responses", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+s.ClientKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}
func consume(t *testing.T, r *http.Response) string {
	t.Helper()
	defer r.Body.Close()
	body, err := io.ReadAll(r.Body)
	if err != nil {
		t.Fatal(err)
	}
	return string(body)
}
func sse(w http.ResponseWriter, v any) {
	body, _ := json.Marshal(v)
	kind, _ := v.(map[string]any)["type"].(string)
	_, _ = fmt.Fprintf(w, "event: %s\ndata: %s\n\n", kind, body)
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
}
func complete(w http.ResponseWriter, id string) {
	w.Header().Set("Content-Type", "text/event-stream")
	sse(w, map[string]any{"type": "response.completed", "response": map[string]any{"id": "resp_fixture", "object": "response", "status": "completed", "model": "fixture-model", "output": []any{map[string]any{"type": "message", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": "done-" + id}}}}, "usage": map[string]int{"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}})
}
func waitEmpty(t *testing.T, b *fakeBridge) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if b.count() == 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("lease not released")
}

func TestSubscriptionsBeforeCreditsAndDesktopLastWithinPhases(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	s.CreditFallback = true
	s.DesktopFallback = true
	// Deliberately place Desktop first: its priority must not beat other tiers.
	s.Accounts = append(s.Accounts[:0], struct {
		ID string `json:"id"`
	}{"Desktop"}, struct {
		ID string `json:"id"`
	}{"A"}, struct {
		ID string `json:"id"`
	}{"B"})
	b.order = []string{"Desktop", "A", "B"}
	balances := map[string]int{"A": 2500, "B": 2200, "Desktop": 2500}
	free := map[string]bool{"A": true, "B": true, "Desktop": true}
	b.admission = func(command, id string) bool {
		if id == "Desktop" {
			return command == "acquire_desktop" && free[id] || command == "acquire_desktop_credit_primary" && balances[id] > 2000
		}
		if command == "acquire" {
			return free[id]
		}
		if command == "acquire_credit_primary" {
			return balances[id] > 2000
		}
		if command == "acquire_credit_secondary" {
			return balances[id] > 1500
		}
		return false
	}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer fixture-")
		if !b.hasLease(id) {
			t.Error("upstream without lease")
		}
		complete(w, id)
	}))
	defer upstream.Close()
	_, server, _ := startTestRuntime(t, s, upstream.URL)
	turn := func(want string) {
		t.Helper()
		response := request(t, s, server.URL, false)
		body := consume(t, response)
		if response.StatusCode != 200 || !strings.Contains(body, "done-"+want) {
			t.Fatalf("wanted %s, got %d %s", want, response.StatusCode, body)
		}
		waitEmpty(t, b)
	}
	turn("A") // Subscription quota before any credit balance.
	b.mu.Lock()
	free["A"] = false
	b.mu.Unlock()
	turn("B") // Another account's subscription wins over A's credits.
	b.mu.Lock()
	free["B"] = false
	b.mu.Unlock()
	turn("Desktop") // Desktop subscription also precedes every paid tier.
	b.mu.Lock()
	free["Desktop"] = false
	b.mu.Unlock()
	turn("A")
	b.mu.Lock()
	balances["A"] = 2000
	b.mu.Unlock()
	turn("B")
	b.mu.Lock()
	balances["B"] = 2000
	b.mu.Unlock()
	turn("A") // Only after every primary-tier balance has reached its floor.
	b.mu.Lock()
	balances["A"] = 1500
	b.mu.Unlock()
	turn("B")
	b.mu.Lock()
	balances["B"] = 1500
	b.mu.Unlock()
	turn("Desktop")
}

func TestCreditFallbackDisabledNeverAttemptsPaidAdmission(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	s.DesktopFallback = true
	b.admission = func(command, id string) bool { return command == "acquire_desktop" && id == "B" }
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { complete(w, "B") }))
	defer upstream.Close()
	_, server, _ := startTestRuntime(t, s, upstream.URL)
	response := request(t, s, server.URL, false)
	if body := consume(t, response); response.StatusCode != 200 || !strings.Contains(body, "done-B") {
		t.Fatalf("desktop fallback failed: %d", response.StatusCode)
	}
	waitEmpty(t, b)
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, command := range b.commands {
		if strings.Contains(command, "credit") {
			t.Fatalf("paid admission without opt-in: %s", command)
		}
	}
}

func TestLeaseBeforeUpstreamAndQuotaFailover(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	var mu sync.Mutex
	calls := []string{}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer fixture-")
		if !b.hasLease(id) {
			t.Error("upstream without lease")
		}
		if r.Header.Get("Chatgpt-Account-Id") != "fixture-account-"+id {
			t.Error("missing account identity header")
		}
		mu.Lock()
		calls = append(calls, id)
		mu.Unlock()
		if id == "A" {
			w.WriteHeader(429)
			_, _ = fmt.Fprintf(w, `{"error":{"type":"usage_limit_reached","message":"fixture-sensitive-error","resets_at":%d}}`, time.Now().Add(2*time.Minute).Unix())
			return
		}
		complete(w, id)
	}))
	defer upstream.Close()
	_, server, out := startTestRuntime(t, s, upstream.URL)
	r := request(t, s, server.URL, false)
	body := consume(t, r)
	if r.StatusCode != 200 || !strings.Contains(body, "done-B") {
		t.Fatalf("response %d %s", r.StatusCode, body)
	}
	waitEmpty(t, b)
	r = request(t, s, server.URL, false)
	_ = consume(t, r)
	waitEmpty(t, b)
	mu.Lock()
	defer mu.Unlock()
	if strings.Join(calls, ",") != "A,B,B" {
		t.Fatalf("calls %v", calls)
	}
	for _, secret := range []string{"fixture-A", "fixture-account-", "fixture-sensitive-error", "synthetic"} {
		if strings.Contains(out.String(), secret) {
			t.Fatal("event contains sensitive content")
		}
	}
	raw, err := os.ReadFile(filepath.Join(s.StateDirectory, "cooldown.json"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "fixture-sensitive-error") {
		t.Fatal("persisted upstream text")
	}
}
func TestUnauthorizedNeverRefreshesAndBusySkips(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	calls := []string{}
	var mu sync.Mutex
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer fixture-")
		mu.Lock()
		calls = append(calls, id)
		mu.Unlock()
		if id == "A" {
			w.WriteHeader(401)
			_, _ = io.WriteString(w, `{"error":{"type":"invalid_api_key","message":"invalid"}}`)
			return
		}
		complete(w, id)
	}))
	defer upstream.Close()
	rt, server, _ := startTestRuntime(t, s, upstream.URL)
	r := request(t, s, server.URL, false)
	_ = consume(t, r)
	waitEmpty(t, b)
	mu.Lock()
	if strings.Join(calls, ",") != "A,B" {
		t.Errorf("calls %v", calls)
	}
	mu.Unlock()
	for _, a := range rt.manager.List() {
		if a.Metadata["refresh_token"] != nil || a.Metadata["access_token"] != nil {
			t.Fatal("manager retained credential")
		}
		if a.Runtime.(auth.RefreshEvaluator).ShouldRefresh(time.Now(), a) {
			t.Fatal("refresh enabled")
		}
	}
}
func TestAllBusyFailsClosedAndNoUnauthorizedRoutes(t *testing.T) {
	b := newFakeBridge(t)
	b.busy["A"] = true
	b.busy["B"] = true
	s := newStartup(t, b)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Error("unexpected upstream") }))
	defer upstream.Close()
	_, server, _ := startTestRuntime(t, s, upstream.URL)
	r := request(t, s, server.URL, false)
	_ = consume(t, r)
	if r.StatusCode != 503 {
		t.Fatalf("status %d", r.StatusCode)
	}
	for _, path := range []string{"/v0/management/auth-files", "/v1/responses", "/anything"} {
		req, _ := http.NewRequest("GET", server.URL+path, nil)
		req.Header.Set("Authorization", "Bearer "+s.ClientKey)
		r, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		r.Body.Close()
		if r.StatusCode != 404 {
			t.Errorf("route exposed %s %d", path, r.StatusCode)
		}
	}
	req, _ := http.NewRequest("GET", server.URL+"/v1/models", nil)
	r, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	r.Body.Close()
	if r.StatusCode != 401 {
		t.Fatal("missing auth accepted")
	}
}
func TestPartialStreamNeverReplaysAndReleases(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	delivered := make(chan struct{})
	var mu sync.Mutex
	calls := []string{}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer fixture-")
		mu.Lock()
		calls = append(calls, id)
		mu.Unlock()
		w.Header().Set("Content-Type", "text/event-stream")
		sse(w, map[string]any{"type": "response.created", "response": map[string]any{"id": "resp_fixture", "status": "in_progress"}})
		sse(w, map[string]any{"type": "response.output_item.added", "output_index": 0, "item": map[string]any{"id": "msg_fixture", "type": "message", "role": "assistant", "content": []any{}}})
		sse(w, map[string]any{"type": "response.output_text.delta", "item_id": "msg_fixture", "output_index": 0, "content_index": 0, "delta": "partial-fixture"})
		select {
		case <-delivered:
		case <-time.After(3 * time.Second):
			t.Error("no downstream output")
		}
		sse(w, map[string]any{"type": "response.failed", "response": map[string]any{"id": "resp_fixture", "status": "failed", "error": map[string]any{"type": "usage_limit_reached", "message": "synthetic"}}})
	}))
	defer upstream.Close()
	_, server, _ := startTestRuntime(t, s, upstream.URL)
	r := request(t, s, server.URL, true)
	scanner := bufio.NewScanner(r.Body)
	var text strings.Builder
	once := sync.Once{}
	for scanner.Scan() {
		line := scanner.Text()
		text.WriteString(line)
		if strings.Contains(line, "partial-fixture") {
			once.Do(func() { close(delivered) })
		}
	}
	r.Body.Close()
	if !strings.Contains(text.String(), "partial-fixture") {
		t.Fatal("partial missing")
	}
	waitEmpty(t, b)
	mu.Lock()
	defer mu.Unlock()
	if strings.Join(calls, ",") != "A" {
		t.Fatalf("replayed %v", calls)
	}
}
func TestCancellationAndConcurrentRequests(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	started := make(chan string, 4)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer fixture-")
		if !b.hasLease(id) {
			t.Error("no lease")
		}
		started <- id
		w.Header().Set("Content-Type", "text/event-stream")
		sse(w, map[string]any{"type": "response.output_text.delta", "delta": "held"})
		<-r.Context().Done()
	}))
	defer upstream.Close()
	_, server, _ := startTestRuntime(t, s, upstream.URL)
	ctx1, cancel1 := context.WithCancel(context.Background())
	ctx2, cancel2 := context.WithCancel(context.Background())
	defer cancel1()
	defer cancel2()
	run := func(ctx context.Context) {
		req, _ := http.NewRequestWithContext(ctx, "POST", server.URL+"/v1/responses", strings.NewReader(`{"model":"fixture-model","input":"synthetic","stream":true}`))
		req.Header.Set("Authorization", "Bearer "+s.ClientKey)
		resp, err := http.DefaultClient.Do(req)
		if err == nil {
			_, _ = io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
		}
	}
	go run(ctx1)
	first := <-started
	go run(ctx2)
	second := <-started
	if first == second {
		t.Fatal("double ownership")
	}
	cancel1()
	cancel2()
	waitEmpty(t, b)
}
func TestCooldownPersistsAcrossRestart(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	calls := []string{}
	var mu sync.Mutex
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer fixture-")
		mu.Lock()
		calls = append(calls, id)
		mu.Unlock()
		if id == "A" {
			w.WriteHeader(429)
			_, _ = fmt.Fprintf(w, `{"error":{"type":"usage_limit_reached","message":"limit","resets_at":%d}}`, time.Now().Add(120*time.Second).Unix())
			return
		}
		complete(w, id)
	}))
	defer upstream.Close()
	rt, server, _ := startTestRuntime(t, s, upstream.URL)
	r := request(t, s, server.URL, false)
	_ = consume(t, r)
	waitEmpty(t, b)
	server.Close()
	rt.close()
	_, server2, _ := startTestRuntime(t, s, upstream.URL)
	r = request(t, s, server2.URL, false)
	_ = consume(t, r)
	waitEmpty(t, b)
	mu.Lock()
	defer mu.Unlock()
	if strings.Join(calls, ",") != "A,B,B" {
		t.Fatalf("cooldown lost: %v", calls)
	}
	info, _ := os.Stat(filepath.Join(s.StateDirectory, "cooldown.json"))
	if info.Mode().Perm() != 0600 {
		t.Fatal("file permissions")
	}
	info, _ = os.Stat(s.StateDirectory)
	if info.Mode().Perm() != 0700 {
		t.Fatal("directory permissions")
	}
}
func TestStateSymlinkAndRedirectBlocked(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	realDir := s.StateDirectory
	os.MkdirAll(realDir, 0700)
	link := realDir + "-link"
	os.Symlink(realDir, link)
	s.StateDirectory = link
	if _, err := newRuntime(s, &events{out: io.Discard}, ""); err == nil {
		t.Fatal("symlink accepted")
	}
	s.StateDirectory = realDir
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Error("redirect followed") }))
	defer target.Close()
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, target.URL+"/responses", 307) }))
	defer upstream.Close()
	_, server, _ := startTestRuntime(t, s, upstream.URL)
	r := request(t, s, server.URL, false)
	_ = consume(t, r)
	waitEmpty(t, b)
}
func TestReleaseUnknownEmitsSafeError(t *testing.T) {
	b := newFakeBridge(t)
	b.denyRelease = true
	s := newStartup(t, b)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { complete(w, "A") }))
	defer upstream.Close()
	_, server, out := startTestRuntime(t, s, upstream.URL)
	r := request(t, s, server.URL, false)
	_ = consume(t, r)
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if strings.Contains(out.String(), "lease_release_unknown") {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("release ambiguity hidden")
}

func TestExpiredCredentialFailsBeforeTransmission(t *testing.T) {
	b := newFakeBridge(t)
	b.expiresDelta = -time.Minute
	s := newStartup(t, b)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Error("expired credential transmitted") }))
	defer upstream.Close()
	_, server, out := startTestRuntime(t, s, upstream.URL)
	r := request(t, s, server.URL, false)
	_ = consume(t, r)
	if r.StatusCode != 503 {
		t.Errorf("status %d", r.StatusCode)
	}
	waitEmpty(t, b)
	if !strings.Contains(out.String(), "login_expired") {
		t.Fatal("missing expiry state")
	}
}
func TestFailedHeartbeatCancelsAndCleansUp(t *testing.T) {
	b := newFakeBridge(t)
	b.failHeartbeat = true
	b.owned["A"] = "request-heartbeat"
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	out := &synchronizedBuffer{}
	scope := &requestScope{id: "request-heartbeat", ctx: ctx, cancel: cancel, bridge: &bridge{socket: b.socket}, events: &events{out: out}, done: make(chan struct{}), exited: make(chan struct{}), heartbeatPeriod: time.Millisecond}
	scope.add(lease{"A", "lease-A"})
	go scope.heartbeats()
	select {
	case <-ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("heartbeat did not cancel")
	}
	scope.close()
	waitEmpty(t, b)
	if !strings.Contains(out.String(), "lease_heartbeat_failed") {
		t.Fatal("heartbeat failure hidden")
	}
}
