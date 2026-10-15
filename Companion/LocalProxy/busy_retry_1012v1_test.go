package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type busyHTTPResult1012 struct {
	response *http.Response
	body     string
	err      error
}

func busyHTTP1012(ctx context.Context, s startup, endpoint string) busyHTTPResult1012 {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint+"/v1/responses", strings.NewReader(`{"model":"fixture-model","input":"synthetic","stream":false}`))
	if err != nil {
		return busyHTTPResult1012{err: err}
	}
	req.Header.Set("Authorization", "Bearer "+s.ClientKey)
	req.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		return busyHTTPResult1012{err: err}
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	return busyHTTPResult1012{response: response, body: string(body), err: err}
}

func awaitBusySignal1012(t *testing.T, signal <-chan struct{}, label string) {
	t.Helper()
	select {
	case <-signal:
	case <-time.After(3 * time.Second):
		t.Fatal(label)
	}
}

func awaitBusyHTTP1012(t *testing.T, results <-chan busyHTTPResult1012) busyHTTPResult1012 {
	t.Helper()
	select {
	case result := <-results:
		if result.err != nil {
			t.Fatal(result.err)
		}
		return result
	case <-time.After(3 * time.Second):
		t.Fatal("synthetic HTTP request did not finish")
		return busyHTTPResult1012{}
	}
}

func TestHTTPBusyBudgetAdvertisesRetryAndPoolRecovers1012(t *testing.T) {
	for _, delayedReply := range []bool{false, true} {
		name := "poll_budget"
		if delayedReply {
			name = "between_acquires"
		}
		t.Run(name, func(t *testing.T) {
			b := newFakeBridge(t)
			b.busy["A"], b.busy["B"] = true, true
			// Hold A to cross the pre-acquire deadline, or B to cross the
			// post-pass deadline. Channels make both branches deterministic.
			heldProfile := "B"
			if delayedReply {
				heldProfile = "A"
			}
			entered, resume := make(chan struct{}), make(chan struct{})
			var once, resumeOnce sync.Once
			defer resumeOnce.Do(func() { close(resume) })
			b.beforeReply = func(q bridgeRequest, reply bridgeReply) bridgeReply {
				if q.Command == "acquire" && q.ProfileID == heldProfile && reply.Error == "busy" {
					once.Do(func() { close(entered) })
					<-resume
				}
				return reply
			}
			s := newStartup(t, b)
			var calls atomic.Int32
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				complete(w, "A")
			}))
			defer upstream.Close()
			rt, server, out := startTestRuntime(t, s, upstream.URL)
			const waitBudget = 250 * time.Millisecond
			rt.selector.waitFor = waitBudget
			results := make(chan busyHTTPResult1012, 1)
			go func() { results <- busyHTTP1012(context.Background(), s, server.URL) }()
			awaitBusySignal1012(t, entered, "busy acquire did not reach its controlled gate")
			timer := time.NewTimer(waitBudget)
			<-timer.C
			resumeOnce.Do(func() { close(resume) })
			result := awaitBusyHTTP1012(t, results)
			response, body := result.response, result.body
			if response.StatusCode != http.StatusServiceUnavailable || response.Header.Get("Retry-After") != "1" || !strings.Contains(body, "eligible accounts remain busy") {
				t.Fatalf("busy budget lost retry guidance: status=%d retry=%q body=%s", response.StatusCode, response.Header.Get("Retry-After"), body)
			}
			if calls.Load() != 0 || b.count() != 0 || strings.Contains(out.String(), "lease_acquire_unknown") {
				t.Fatal("known busy wait spent quota, retained a lease or stopped the pool")
			}
			b.mu.Lock()
			delete(b.busy, "A")
			b.mu.Unlock()
			response = request(t, s, server.URL, false)
			body = consume(t, response)
			if response.StatusCode != http.StatusOK || response.Header.Get("Retry-After") != "" || !strings.Contains(body, "done-A") || calls.Load() != 1 {
				t.Fatalf("released capacity did not recover the same pool: status=%d retry=%q", response.StatusCode, response.Header.Get("Retry-After"))
			}
			waitEmpty(t, b)
		})
	}
}

func TestHTTPControlBusyBudgetAdvertisesRetryWithoutLease1012(t *testing.T) {
	b := newFakeBridge(t)
	b.failures = map[string]string{"acquire\x00A": "control_busy", "acquire\x00B": "control_busy"}
	s := newStartup(t, b)
	var upstreamCalls atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upstreamCalls.Add(1)
		complete(w, "unexpected")
	}))
	defer upstream.Close()
	rt, server, out := startTestRuntime(t, s, upstream.URL)
	rt.selector.waitFor = time.Second
	const exchangeBudget = 175 * time.Millisecond
	rt.selector.bridge.exchangeTimeout = exchangeBudget
	started := time.Now()
	result := busyHTTP1012(context.Background(), s, server.URL)
	if result.err != nil {
		t.Fatal(result.err)
	}
	if result.response.StatusCode != http.StatusServiceUnavailable || result.response.Header.Get("Retry-After") != "1" || !strings.Contains(result.body, "proxy control channel is busy") {
		t.Fatalf("known control refusal lost retry guidance: status=%d retry=%q body=%s", result.response.StatusCode, result.response.Header.Get("Retry-After"), result.body)
	}
	if time.Since(started) < exchangeBudget || bridgeCommandCount(b, "acquire") < 2 {
		t.Fatal("control busy did not exhaust its bounded safe-retry exchange")
	}
	if upstreamCalls.Load() != 0 || b.count() != 0 || bridgeCommandCount(b, "release") != 0 || bridgeCommandCount(b, "acquire_resolve") != 0 || strings.Contains(out.String(), "lease_acquire_unknown") {
		t.Fatal("explicit control refusal consumed upstream quota or invented lease ownership")
	}
}

func TestHTTPControlBusyCancellationStopsPolling1012(t *testing.T) {
	b := newFakeBridge(t)
	b.failures = map[string]string{"acquire\x00A": "control_busy", "acquire\x00B": "control_busy"}
	entered, resume, ended := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var enterOnce, resumeOnce, endOnce sync.Once
	defer resumeOnce.Do(func() { close(resume) })
	b.beforeReply = func(q bridgeRequest, reply bridgeReply) bridgeReply {
		if q.Command == "acquire" {
			enterOnce.Do(func() { close(entered) })
			<-resume
		}
		if q.Command == "order_end" {
			endOnce.Do(func() { close(ended) })
		}
		return reply
	}
	s := newStartup(t, b)
	var upstreamCalls atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upstreamCalls.Add(1)
		complete(w, "unexpected")
	}))
	defer upstream.Close()
	rt, server, out := startTestRuntime(t, s, upstream.URL)
	rt.selector.waitFor = 5 * time.Second
	rt.selector.bridge.exchangeTimeout = time.Second
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	results := make(chan busyHTTPResult1012, 1)
	go func() { results <- busyHTTP1012(ctx, s, server.URL) }()
	awaitBusySignal1012(t, entered, "control refusal never reached the host")
	cancel()
	resumeOnce.Do(func() { close(resume) })
	select {
	case result := <-results:
		if result.err == nil || !strings.Contains(result.err.Error(), context.Canceled.Error()) {
			t.Fatalf("HTTP cancellation did not reach the client: %v", result.err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("cancelled HTTP request remained blocked")
	}
	awaitBusySignal1012(t, ended, "cancelled scope did not retire its order snapshot")
	if bridgeCommandCount(b, "acquire") != 1 || bridgeCommandCount(b, "acquire_resolve") != 0 || b.count() != 0 || upstreamCalls.Load() != 0 || strings.Contains(out.String(), "lease_acquire_unknown") {
		t.Fatal("cancellation restarted polling, retained ownership or called the provider")
	}
}

func TestProtocolHelperParallelOrdinaryWaitsBeforeDeferred1012(t *testing.T) {
	b := newFakeBridge(t)
	b.order, b.deferredIDs = []string{"A", "B", "C"}, []string{"C"}
	b.creditFallback = true
	parked, releaseA, releaseB := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var parkedOnce, releaseAOnce, releaseBOnce sync.Once
	defer releaseAOnce.Do(func() { close(releaseA) })
	defer releaseBOnce.Do(func() { close(releaseB) })
	var acquireMu sync.Mutex
	busyProfiles := map[string]bool{}
	var deferredCalls, creditCalls atomic.Int32
	b.beforeReply = func(q bridgeRequest, reply bridgeReply) bridgeReply {
		if strings.HasPrefix(q.Command, "acquire") && q.Command != "acquire_resolve" {
			if q.ProfileID == "C" {
				deferredCalls.Add(1)
			}
			if strings.Contains(q.Command, "credit") {
				creditCalls.Add(1)
			}
		}
		if q.Command == "acquire" && reply.Error == "busy" && b.count() == 2 {
			acquireMu.Lock()
			busyProfiles[q.ProfileID] = true
			if busyProfiles["A"] && busyProfiles["B"] {
				parkedOnce.Do(func() { close(parked) })
			}
			acquireMu.Unlock()
		}
		return reply
	}
	s := newStartup(t, b)
	s.Accounts = append(s.Accounts, struct {
		ID string `json:"id"`
	}{"C"})
	started := make(chan string, 3)
	var aCalls, upstreamCalls atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer fixture-")
		if !b.hasLease(id) || r.Header.Get("Chatgpt-Account-Id") != "fixture-account-"+id {
			t.Error("helper reached provider without the exact admitted account")
		}
		upstreamCalls.Add(1)
		select {
		case started <- id:
		case <-r.Context().Done():
			return
		}
		var release <-chan struct{}
		if id == "A" && aCalls.Add(1) == 1 {
			release = releaseA
		} else if id == "B" {
			release = releaseB
		}
		if release != nil {
			select {
			case <-release:
			case <-r.Context().Done():
				return
			}
		}
		complete(w, id)
	}))
	t.Cleanup(upstream.Close)
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(self)
	cmd.Env = append(os.Environ(), "AIGOODBRO_PROTOCOL_FIXTURE_CHILD=1", "AIGOODBRO_FIXTURE_UPSTREAM="+upstream.URL)
	input, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	output, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	childOut, childErr := &synchronizedBuffer{}, &synchronizedBuffer{}
	cmd.Stderr = childErr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	ready, exited := make(chan int, 1), make(chan struct{})
	var childExitError error
	go func() {
		scanner := bufio.NewScanner(output)
		for scanner.Scan() {
			line := scanner.Bytes()
			_, _ = fmt.Fprintln(childOut, string(line))
			var frame event
			if json.Unmarshal(line, &frame) == nil && frame.Event == "ready" {
				ready <- frame.Port
			}
		}
		childExitError = cmd.Wait()
		close(exited)
	}()
	t.Cleanup(func() {
		_, _ = io.WriteString(input, "{\"command\":\"stop\"}\n")
		_ = input.Close()
		select {
		case <-exited:
		case <-time.After(5 * time.Second):
			_ = cmd.Process.Kill()
			<-exited
		}
		if childExitError != nil {
			t.Errorf("isolated helper exit: %v %s", childExitError, childErr.String())
		}
	})
	if err := json.NewEncoder(input).Encode(s); err != nil {
		t.Fatal(err)
	}
	var endpoint string
	select {
	case port := <-ready:
		endpoint = fmt.Sprintf("http://127.0.0.1:%d", port)
	case <-exited:
		t.Fatalf("isolated helper stopped before readiness: %v %s", childExitError, childErr.String())
	case <-time.After(3 * time.Second):
		t.Fatal("isolated helper did not announce readiness")
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	run := func() <-chan busyHTTPResult1012 {
		results := make(chan busyHTTPResult1012, 1)
		go func() { results <- busyHTTP1012(ctx, s, endpoint) }()
		return results
	}
	wantStarted := func(want string) {
		t.Helper()
		select {
		case id := <-started:
			if id != want {
				t.Fatalf("expected admitted %s, got %s", want, id)
			}
		case <-time.After(3 * time.Second):
			t.Fatalf("account %s did not reach the loopback provider", want)
		}
	}
	first := run()
	wantStarted("A")
	second := run()
	wantStarted("B")
	third := run()
	awaitBusySignal1012(t, parked, "third HTTP request did not wait on both ordinary accounts")
	if b.count() != 2 || upstreamCalls.Load() != 2 || deferredCalls.Load() != 0 || creditCalls.Load() != 0 {
		t.Fatal("parallel ordinary occupancy overflowed to a later account or paid pass")
	}
	releaseAOnce.Do(func() { close(releaseA) })
	wantStarted("A")
	for _, result := range []busyHTTPResult1012{awaitBusyHTTP1012(t, first), awaitBusyHTTP1012(t, third)} {
		if result.response.StatusCode != http.StatusOK || !strings.Contains(result.body, "done-A") {
			t.Fatalf("released ordinary capacity did not resume HTTP: %d %s", result.response.StatusCode, result.body)
		}
	}
	releaseBOnce.Do(func() { close(releaseB) })
	result := awaitBusyHTTP1012(t, second)
	if result.response.StatusCode != http.StatusOK || !strings.Contains(result.body, "done-B") {
		t.Fatalf("parallel B response failed: %d %s", result.response.StatusCode, result.body)
	}
	waitEmpty(t, b)
	if upstreamCalls.Load() != 3 || deferredCalls.Load() != 0 || creditCalls.Load() != 0 || strings.Contains(childOut.String(), "lease_acquire_unknown") || strings.Contains(childOut.String(), "lease_release_unknown") {
		t.Fatal("production helper replayed, used deferred capacity or lost ownership")
	}
}
