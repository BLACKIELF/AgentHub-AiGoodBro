package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	auth "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
)

func networkFixture(t *testing.T) (*runtime, *fakeBridge, startup, *synchronizedBuffer) {
	return networkFixtureWithUpstream(t, "")
}
func networkFixtureWithUpstream(t *testing.T, upstream string) (*runtime, *fakeBridge, startup, *synchronizedBuffer) {
	t.Helper()
	b := newFakeBridge(t)
	s := newStartup(t, b)
	s.Accounts = nil
	s.AccountIdentityHashes = map[string]string{}
	for i := 1; i <= 4; i++ {
		id := fmt.Sprintf("00000000-0000-4000-8000-%012d", i)
		s.Accounts = append(s.Accounts, struct {
			ID string `json:"id"`
		}{id})
		s.AccountIdentityHashes[id] = fmt.Sprintf("%064x", i)
	}
	out := &synchronizedBuffer{}
	rt, err := newRuntime(s, &events{out: out}, upstream)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(rt.close)
	return rt, b, s, out
}
func forbidden(rt *runtime, id, model string) {
	rt.manager.MarkResult(context.Background(), auth.Result{AuthID: id, Provider: "codex", Model: model, Error: &auth.Error{HTTPStatus: 403}})
}
func classifyFixture(t *testing.T, rt *runtime) {
	t.Helper()
	for _, id := range rt.ids[:3] {
		forbidden(rt, id, "fixture-model")
	}
	if !rt.network.applyPending() {
		t.Fatal("three distinct identities did not classify")
	}
}
func probeProof(q bridgeRequest, s startup) bridgeReply {
	return bridgeReply{OK: true, ProbeStatus: "reachable", ProbeIdentityHash: s.AccountIdentityHashes[q.ProfileID], ProbeObservedAt: float64(time.Now().UnixNano()) / 1e9}
}

func TestNetworkFixedListenerAndValidation(t *testing.T) {
	held, err := listenProxy(0)
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	port := held.Addr().(*net.TCPAddr).Port
	occupied, err := listenProxy(port)
	if occupied != nil {
		occupied.Close()
		t.Fatal("occupied fixed port silently changed")
	}
	if !errors.Is(err, syscall.EADDRINUSE) {
		t.Fatalf("error=%v", err)
	}
	for _, port := range []int{-1, 1, 1023, 65536} {
		if listener, err := listenProxy(port); err == nil {
			listener.Close()
			t.Fatalf("accepted invalid port %d", port)
		}
	}
	b := newFakeBridge(t)
	s := newStartup(t, b)
	s.Port = 18080
	if err := s.validate(); err != nil {
		t.Fatal(err)
	}
	s.AccountIdentityHashes = map[string]string{"A": "invalid"}
	if s.validate() == nil {
		t.Fatal("accepted malformed identity")
	}
	for _, raw := range []string{"http://example.invalid:9097", "http://localhost:9097", "http://127.0.0.1:9097/path", "http://user@127.0.0.1", "http://127.0.0.1?key=value"} {
		if (egressSettings{MihomoAPI: raw}).validate() == nil {
			t.Fatalf("unsafe controller accepted: %s", raw)
		}
	}
}
func TestNetwork403DistinctIdentitiesAndConsecutiveModels(t *testing.T) {
	for _, scenario := range []string{"same_identity", "different_models", "interrupted", "outside_window", "three"} {
		t.Run(scenario, func(t *testing.T) {
			rt, _, _, _ := networkFixture(t)
			if scenario == "same_identity" {
				rt.network.identities[rt.ids[1]] = rt.network.identities[rt.ids[0]]
				rt.network.identities[rt.ids[2]] = rt.network.identities[rt.ids[0]]
			}
			forbidden(rt, rt.ids[0], "fixture-model")
			if scenario == "interrupted" {
				rt.manager.MarkResult(context.Background(), auth.Result{AuthID: rt.ids[3], Provider: "codex", Model: "fixture-model", Success: true})
			}
			if scenario == "outside_window" {
				rt.network.mu.Lock()
				observations := rt.network.streaks["fixture-model"]
				observations[0].at = time.Now().Add(-61 * time.Second)
				rt.network.streaks["fixture-model"] = observations
				rt.network.mu.Unlock()
			}
			model := "fixture-model"
			if scenario == "different_models" {
				model = "other"
			}
			forbidden(rt, rt.ids[1], model)
			forbidden(rt, rt.ids[2], "fixture-model")
			changed := rt.network.applyPending()
			if changed != (scenario == "three") {
				t.Fatalf("classified=%v", changed)
			}
			for _, id := range rt.ids[:3] {
				a, _ := rt.manager.GetByID(id)
				ms := a.ModelStates["fixture-model"]
				if ms == nil {
					continue
				}
				if scenario == "three" {
					if !egressModel(ms) || time.Until(ms.NextRetryAfter) > 5*time.Minute {
						t.Fatal("403 not narrowed to egress five minutes")
					}
				} else if ms.LastError.Code == egressErrorCode {
					t.Fatal("false egress classification")
				}
			}
		})
	}
}
func TestNetwork403DoesNotChangeUnrelatedCooldowns(t *testing.T) {
	rt, _, _, _ := networkFixture(t)
	retry := 3 * time.Hour
	rt.manager.MarkResult(context.Background(), auth.Result{AuthID: rt.ids[0], Provider: "codex", Model: "quota-model", RetryAfter: &retry, Error: &auth.Error{HTTPStatus: 429}})
	before, _ := rt.manager.GetByID(rt.ids[0])
	quota := before.ModelStates["quota-model"]
	classifyFixture(t, rt)
	after, _ := rt.manager.GetByID(rt.ids[0])
	if !reflect.DeepEqual(quota, after.ModelStates["quota-model"]) {
		t.Fatal("egress altered model 429")
	}
	for _, id := range rt.ids[:3] {
		forbidden(rt, id, "fixture-model")
	}
	rt.manager.MarkResult(context.Background(), auth.Result{AuthID: rt.ids[0], Provider: "codex", Model: "fixture-model", Error: &auth.Error{HTTPStatus: 401}})
	rt.network.applyPending()
	after, _ = rt.manager.GetByID(rt.ids[0])
	if after.ModelStates["fixture-model"].LastError.HTTPStatus != 401 {
		t.Fatal("pending classification erased 401")
	}
}
func TestNetworkCloudflare403PreservesPriorQuota(t *testing.T) {
	for _, priorQuota := range []bool{false, true} {
		t.Run(fmt.Sprint(priorQuota), func(t *testing.T) {
			rt, _, _, _ := networkFixture(t)
			if priorQuota {
				for _, id := range rt.ids[:3] {
					retry := time.Hour
					rt.manager.MarkResult(context.Background(), auth.Result{AuthID: id, Provider: "codex", Model: "fixture-model", RetryAfter: &retry, Error: &auth.Error{HTTPStatus: 429}})
				}
			}
			for _, id := range rt.ids[:3] {
				rt.manager.MarkResult(context.Background(), auth.Result{AuthID: id, Provider: "codex", Model: "fixture-model", Error: &auth.Error{HTTPStatus: 403, Message: "cloudflare challenge"}})
			}
			if rt.network.applyPending() == priorQuota {
				t.Fatal("cloudflare classification ignored prior quota provenance")
			}
		})
	}
}
func TestNetworkProofStrictness(t *testing.T) {
	now := time.Now()
	hash := strings.Repeat("a", 64)
	good := bridgeReply{OK: true, ProbeStatus: "reachable", ProbeObservedAt: float64(now.UnixNano()) / 1e9, ProbeIdentityHash: hash}
	if _, ok := egressProofObserved(good, hash, now.Add(-time.Second), now); !ok {
		t.Fatal("valid proof refused")
	}
	for _, edit := range []func(*bridgeReply){func(p *bridgeReply) { p.AccessToken = "fixture" }, func(p *bridgeReply) { p.LeaseID = "lease" }, func(p *bridgeReply) { p.QuotaObservedAt = 1 }, func(p *bridgeReply) { p.ProbeIdentityHash = strings.Repeat("b", 64) }, func(p *bridgeReply) { p.ProbeStatus = "ok" }, func(p *bridgeReply) { p.ProbeObservedAt = math.NaN() }, func(p *bridgeReply) { p.ProbeObservedAt = float64(now.Add(-3 * time.Minute).Unix()) }, func(p *bridgeReply) { p.ProbeObservedAt = float64(now.Add(3 * time.Second).Unix()) }} {
		bad := good
		edit(&bad)
		if _, ok := egressProofObserved(bad, hash, now.Add(-time.Second), now); ok {
			t.Fatal("malformed proof accepted")
		}
	}
}
func TestNetworkFreshProofClearsOnlyEgress(t *testing.T) {
	rt, b, s, _ := networkFixture(t)
	classifyFixture(t, rt)
	id := rt.ids[0]
	retry := time.Hour
	rt.manager.MarkResult(context.Background(), auth.Result{AuthID: id, Provider: "codex", Model: "quota-model", RetryAfter: &retry, Error: &auth.Error{HTTPStatus: 429}})
	before, _ := rt.manager.GetByID(id)
	quota := before.ModelStates["quota-model"]
	b.beforeReply = func(q bridgeRequest, r bridgeReply) bridgeReply {
		if q.Command == "egress_probe" {
			if q.LeaseID != "" {
				t.Error("probe acquired lease")
			}
			return probeProof(q, s)
		}
		return r
	}
	rt.network.probeAccount(context.Background(), id, true)
	after, _ := rt.manager.GetByID(id)
	if after.ModelStates["fixture-model"].LastError != nil || after.ModelStates["fixture-model"].Unavailable {
		t.Fatal("valid fresh proof failed to clear target")
	}
	if !reflect.DeepEqual(quota, after.ModelStates["quota-model"]) {
		t.Fatal("probe cleared unrelated quota")
	}
	if !after.Quota.Exceeded {
		t.Fatal("probe cleared auth quota")
	}
	if b.count() != 0 {
		t.Fatal("probe created lease")
	}
}
func TestNetworkProofCannotEraseNewErrorOrActiveRequest(t *testing.T) {
	for _, scenario := range []string{"401", "429", "500", "version", "active", "wrong_identity", "denied", "cancelled", "stale"} {
		t.Run(scenario, func(t *testing.T) {
			rt, b, s, _ := networkFixture(t)
			classifyFixture(t, rt)
			id := rt.ids[0]
			scope := &requestScope{recovery: rt.recovery}
			defer scope.releaseQuotaAccounts()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			b.beforeReply = func(q bridgeRequest, r bridgeReply) bridgeReply {
				if q.Command != "egress_probe" {
					return r
				}
				proof := probeProof(q, s)
				switch scenario {
				case "401", "429", "500":
					status := map[string]int{"401": 401, "429": 429, "500": 500}[scenario]
					rt.manager.MarkResult(context.Background(), auth.Result{AuthID: id, Provider: "codex", Model: "fixture-model", Error: &auth.Error{HTTPStatus: status}})
				case "version":
					a, _ := rt.manager.GetByID(id)
					_, _ = rt.manager.Update(context.Background(), a)
				case "active":
					scope.reserveQuotaAccount(id)
				case "wrong_identity":
					proof.ProbeIdentityHash = strings.Repeat("f", 64)
				case "denied":
					return bridgeReply{Error: "not_participating"}
				case "cancelled":
					cancel()
				case "stale":
					proof.ProbeObservedAt = float64(time.Now().Add(-time.Minute).UnixNano()) / 1e9
				}
				return proof
			}
			rt.network.probeAccount(ctx, id, true)
			after, _ := rt.manager.GetByID(id)
			if after.ModelStates["fixture-model"].LastError == nil {
				t.Fatal("proof erased concurrent or unproved error")
			}
		})
	}
}
func TestNetworkProbeThrottlesAndSingleFlight(t *testing.T) {
	rt, b, s, _ := networkFixture(t)
	classifyFixture(t, rt)
	id := rt.ids[0]
	entered := make(chan struct{})
	release := make(chan struct{})
	var calls atomic.Int32
	b.beforeReply = func(q bridgeRequest, r bridgeReply) bridgeReply {
		if q.Command == "egress_probe" {
			calls.Add(1)
			close(entered)
			<-release
			proof := probeProof(q, s)
			proof.ProbeStatus = "unreachable"
			return proof
		}
		return r
	}
	done := make(chan struct{})
	go func() { rt.network.probeAccount(context.Background(), id, false); close(done) }()
	<-entered
	rt.network.probeAccount(context.Background(), id, true)
	close(release)
	<-done
	rt.network.probeAccount(context.Background(), id, false)
	if calls.Load() != 1 {
		t.Fatal("probe duplicated in flight or ignored two minute cadence")
	}
}

func TestNetworkProbeBatchMatchesHostCapacity(t *testing.T) {
	rt, b, s, _ := networkFixture(t)
	classifyFixture(t, rt)
	entered := make(chan string, len(rt.ids))
	release := make(chan struct{})
	var once sync.Once
	defer once.Do(func() { close(release) })
	var active, peak atomic.Int32
	b.beforeReply = func(q bridgeRequest, r bridgeReply) bridgeReply {
		if q.Command != "egress_probe" {
			return r
		}
		count := active.Add(1)
		defer active.Add(-1)
		for old := peak.Load(); count > old; old = peak.Load() {
			if peak.CompareAndSwap(old, count) {
				break
			}
		}
		entered <- q.ProfileID
		<-release
		proof := probeProof(q, s)
		proof.ProbeStatus = "unreachable"
		return proof
	}
	done := make(chan struct{})
	go func() { rt.network.probeAccounts(context.Background(), "", true); close(done) }()
	for i := 0; i < 2; i++ {
		select {
		case <-entered:
		case <-time.After(2 * time.Second):
			t.Fatal("host probe slots did not fill")
		}
	}
	select {
	case <-entered:
		t.Fatal("batch exceeded the host's two probe slots")
	case <-time.After(75 * time.Millisecond):
	}
	once.Do(func() { close(release) })
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("queued probe did not resume")
	}
	if peak.Load() != 2 || len(entered) != 1 {
		t.Fatalf("peak=%d queued completions=%d", peak.Load(), len(entered))
	}
}
func TestNetworkCooldownKindRoundTrip(t *testing.T) {
	rt, _, s, _ := networkFixture(t)
	classifyFixture(t, rt)
	records, err := rt.store.Load(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	found := 0
	for _, r := range records {
		if r.LastError != nil && r.LastError.Code == egressErrorCode {
			found++
		}
	}
	if found < 3 {
		t.Fatal("egress provenance lost on disk")
	}
	data, err := os.ReadFile(s.StateDirectory + "/cooldown.json")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"kind":"egress"`) {
		t.Fatal("kind missing")
	}
}

type controllerFixture struct {
	mu         sync.Mutex
	now        string
	all        []string
	delays     map[string]string
	calls      []string
	puts       []string
	groupReads int
	raceAt     int
	redirect   string
}

func (f *controllerFixture) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, r.Method+" "+r.URL.Path)
	if f.redirect != "" {
		http.Redirect(w, r, f.redirect, http.StatusFound)
		return
	}
	if r.URL.Path == "/proxies/group" {
		if r.Method == http.MethodPut {
			var body struct {
				Name string `json:"name"`
			}
			_ = json.NewDecoder(r.Body).Decode(&body)
			f.puts = append(f.puts, body.Name)
			f.now = body.Name
			w.WriteHeader(204)
			return
		}
		f.groupReads++
		if f.raceAt == f.groupReads {
			f.now = "user-choice"
		}
		_ = json.NewEncoder(w).Encode(mihomoGroup{Type: "Selector", Now: f.now, All: f.all})
		return
	}
	node := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/proxies/"), "/delay")
	switch f.delays[node] {
	case "dead":
		w.WriteHeader(504)
		_, _ = w.Write([]byte(`{"message":"timeout"}`))
	case "unauthorized":
		w.WriteHeader(401)
	case "malformed":
		_, _ = w.Write([]byte(`{"delay":"no"}`))
	default:
		_, _ = w.Write([]byte(`{"delay":11}`))
	}
}
func TestNetworkWatchdogOnlySwitchesDeadAndReadsBack(t *testing.T) {
	for _, scenario := range []string{"healthy", "readonly", "switch", "all_dead", "controller_failure", "malformed", "pre_race", "post_race"} {
		t.Run(scenario, func(t *testing.T) {
			rt, b, s, out := networkFixture(t)
			classifyFixture(t, rt)
			f := &controllerFixture{now: "current", all: []string{"current", "first", "second", "user-choice"}, delays: map[string]string{"current": "dead", "first": "dead"}}
			switch scenario {
			case "healthy":
				f.delays["current"] = "healthy"
			case "all_dead":
				f.delays["second"] = "dead"
			case "controller_failure":
				f.delays["current"] = "unauthorized"
			case "malformed":
				f.delays["current"] = "malformed"
			case "pre_race":
				f.raceAt = 2
			case "post_race":
				f.raceAt = 3
			}
			server := httptest.NewServer(http.HandlerFunc(f.serve))
			defer server.Close()
			rt.network.settings = egressSettings{Enabled: true, MihomoAPI: server.URL, Group: "group", Whitelist: []string{"not-member", "first", "second"}}
			var probes atomic.Int32
			b.beforeReply = func(q bridgeRequest, r bridgeReply) bridgeReply {
				if q.Command == "egress_probe" {
					probes.Add(1)
					return probeProof(q, s)
				}
				return r
			}
			rt.network.checkEgress(context.Background(), scenario != "readonly", "check-id")
			f.mu.Lock()
			puts := append([]string(nil), f.puts...)
			f.mu.Unlock()
			shouldPut := scenario == "switch" || scenario == "post_race"
			if (len(puts) > 0) != shouldPut {
				t.Fatalf("unexpected PUTs %v", puts)
			}
			if scenario == "switch" {
				if !reflect.DeepEqual(puts, []string{"second"}) || probes.Load() != 3 {
					t.Fatalf("switch/probes=%v/%d", puts, probes.Load())
				}
				if !strings.Contains(out.String(), `"state":"switched"`) {
					t.Fatal("switch event missing")
				}
			} else if probes.Load() != 0 {
				t.Fatal("unsuccessful switch probed accounts")
			}
			if !strings.Contains(out.String(), `"requestID":"check-id"`) {
				t.Fatal("self-check lost correlation")
			}
		})
	}
}
func TestNetworkControllerNoRedirectNoEnvironmentProxy(t *testing.T) {
	var external atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { external.Add(1) }))
	defer target.Close()
	f := &controllerFixture{redirect: target.URL}
	controller := httptest.NewServer(http.HandlerFunc(f.serve))
	defer controller.Close()
	t.Setenv("HTTP_PROXY", target.URL)
	t.Setenv("HTTPS_PROXY", target.URL)
	c, err := newMihomoController(egressSettings{MihomoAPI: controller.URL, MihomoSecret: "fixture-secret"})
	if err != nil {
		t.Fatal(err)
	}
	defer c.transport.CloseIdleConnections()
	if c.transport.Proxy != nil {
		t.Fatal("controller inherits environment proxy")
	}
	if _, err := c.group(context.Background(), "group"); err == nil {
		t.Fatal("redirect was accepted")
	}
	if external.Load() != 0 {
		t.Fatal("controller leaked request via redirect")
	}
}
func TestNetworkRuntimeCancelAndSelfCheckCorrelation(t *testing.T) {
	rt, _, _, out := networkFixture(t)
	requestID := "00000000-0000-4000-8000-000000000099"
	rt.network.command(networkCommand{Command: "self_check", RequestID: requestID})
	rt.network.start()
	rt.close()
	if !strings.Contains(out.String(), `"requestID":"`+requestID+`"`) {
		t.Fatal("disabled self-check did not reply")
	}
	rt.network.command(networkCommand{Command: "self_check", RequestID: requestID})
	if !strings.Contains(out.String(), `"state":"unavailable"`) {
		t.Fatal("stopped self-check did not reply")
	}
}

func TestNetworkCooldownShadowAndIdentityRoundTrip(t *testing.T) {
	rt, _, s, _ := networkFixture(t)
	id := rt.ids[0]
	now := time.Now()
	until := now.Add(time.Hour)
	record := auth.CooldownStateRecord{Provider: "codex", AuthID: id, Model: "fixture-model", NextRetryAfter: until, UpdatedAt: now, Quota: auth.QuotaState{Exceeded: true, Reason: "credential_quota", NextRecoverAt: until}, LastError: &auth.Error{HTTPStatus: 429, Code: credentialQuotaErrorCode}, CredentialQuotaPropagated: true, IndependentState: &auth.ModelState{Status: auth.StatusError, Unavailable: true, NextRetryAfter: now.Add(5 * time.Minute), UpdatedAt: now, LastError: &auth.Error{HTTPStatus: 403, Code: egressErrorCode, Message: "must not persist upstream private text"}}}
	if err := rt.store.Save(context.Background(), []auth.CooldownStateRecord{record}); err != nil {
		t.Fatal(err)
	}
	records, err := rt.store.Load(context.Background())
	if err != nil || len(records) != 1 {
		t.Fatalf("load=%d %v", len(records), err)
	}
	restored := records[0]
	if !restored.CredentialQuotaPropagated || restored.IndependentState == nil || restored.IndependentState.LastError.Code != egressErrorCode || restored.IndependentState.LastError.Message != "" {
		t.Fatal("shadow provenance lost or text persisted")
	}
	data, _ := os.ReadFile(s.StateDirectory + "/cooldown.json")
	if strings.Contains(string(data), "must not persist") {
		t.Fatal("unsafe shadow serialized")
	}
	rt.store.identities = map[string]string{id: strings.Repeat("f", 64)}
	records, err = rt.store.Load(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if records[0].IndependentState.LastError.Code == egressErrorCode {
		t.Fatal("old identity egress shadow accepted for new identity")
	}
}

func TestNetworkWatchdogSingleFlightAndCancellation(t *testing.T) {
	rt, _, _, out := networkFixture(t)
	entered := make(chan struct{})
	var once sync.Once
	var delays atomic.Int32
	var puts atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPut {
			puts.Add(1)
			return
		}
		if r.URL.Path == "/proxies/group" {
			_ = json.NewEncoder(w).Encode(mihomoGroup{Type: "Selector", Now: "current", All: []string{"current", "backup"}})
			return
		}
		delays.Add(1)
		once.Do(func() { close(entered) })
		<-r.Context().Done()
	}))
	defer server.Close()
	rt.network.settings = egressSettings{Enabled: true, MihomoAPI: server.URL, Group: "group", Whitelist: []string{"backup"}}
	rt.network.watchEvery = 5 * time.Millisecond
	rt.network.start()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("runtime ticker did not run without HTTP requests")
	}
	requestID := "00000000-0000-4000-8000-000000000099"
	rt.network.checkEgress(context.Background(), false, requestID)
	stopped := make(chan struct{})
	go func() { rt.close(); close(stopped) }()
	select {
	case <-stopped:
	case <-time.After(time.Second):
		t.Fatal("runtime cancellation waited on stalled controller")
	}
	if delays.Load() != 1 || puts.Load() != 0 {
		t.Fatal("watchdog overlapped or switched on controller failure")
	}
	if !strings.Contains(out.String(), `"requestID":"`+requestID+`"`) {
		t.Fatal("busy self-check dropped its reply")
	}
}

func TestNetworkProofRejectsUnknownFields(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "lp-proof-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	listener, err := net.Listen("unix", dir+"/proof.sock")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		var q bridgeRequest
		_ = json.NewDecoder(conn).Decode(&q)
		_ = json.NewEncoder(conn).Encode(map[string]any{"ok": true, "probeStatus": "reachable", "probeObservedAt": float64(time.Now().UnixNano()) / 1e9, "probeIdentityHash": strings.Repeat("a", 64), "unexpected": "payload"})
	}()
	b := bridge{socket: dir + "/proof.sock"}
	if _, err := b.call(context.Background(), "egress_probe", "00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002", ""); err == nil {
		t.Fatal("non-proof field accepted")
	}
}

func TestNetworkRecoveredAccountIsActuallySelectable(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { complete(w, "recovered") }))
	defer upstream.Close()
	rt, b, s, _ := networkFixtureWithUpstream(t, upstream.URL)
	classifyFixture(t, rt)
	id := rt.ids[0]
	b.setOrder(id)
	b.beforeReply = func(q bridgeRequest, r bridgeReply) bridgeReply {
		if q.Command == "egress_probe" {
			return probeProof(q, s)
		}
		return r
	}
	rt.network.probeAccount(context.Background(), id, true)
	server := httptest.NewServer(rt.handler)
	defer server.Close()
	response := request(t, s, server.URL, false)
	body := consume(t, response)
	if response.StatusCode != http.StatusOK || !strings.Contains(body, "done-recovered") {
		t.Fatalf("recovered SDK selector remained blocked: status %d", response.StatusCode)
	}
	waitEmpty(t, b)
}

func TestNetworkSDK38QuotaShadowCannotBeResetByQuotaProof(t *testing.T) {
	for _, status := range []int{403, 429} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			rt, b, _, _ := networkFixture(t)
			id := rt.ids[0]
			retry := time.Hour
			rt.manager.MarkResult(context.Background(), auth.Result{AuthID: id, Provider: "codex", Model: "fixture-model", RetryAfter: &retry, Error: &auth.Error{HTTPStatus: status}})
			markCredentialQuota(rt, id)
			if !rt.store.hasIndependentCooldown(id, time.Now()) {
				t.Fatal("SDK independent layer was not remembered")
			}
			var calls atomic.Int32
			b.beforeReply = func(q bridgeRequest, r bridgeReply) bridgeReply {
				if q.Command == "quota_recovery" {
					calls.Add(1)
					return quotaRecoveryProof(time.Now())
				}
				return r
			}
			rt.reconcileQuota(quotaRecoveryContext(rt))
			a, _ := rt.manager.GetByID(id)
			if calls.Load() != 0 || !a.Quota.Exceeded {
				t.Fatal("quota proof erased a hidden independent cooldown")
			}
		})
	}
}
