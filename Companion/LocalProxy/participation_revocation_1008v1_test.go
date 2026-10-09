package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Simulate the host's authoritative refusal before a lease/token is issued.
// The production Swift guard is exercised separately by its native fixtures.
func denyFutureParticipation1008(b *fakeBridge, ids ...string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.failures == nil {
		b.failures = make(map[string]string)
	}
	for _, id := range ids {
		for _, command := range admissionCommands(true, true) {
			b.failures[command+"\x00"+id] = "not_participating"
		}
	}
}

func assertNoParticipationFailureEvent1008(t *testing.T, out *synchronizedBuffer, ids ...string) {
	t.Helper()
	for _, id := range ids {
		if strings.Contains(out.String(), `"profileID":"`+id+`","state":"temporary_error"`) ||
			strings.Contains(out.String(), `"profileID":"`+id+`","state":"quota"`) ||
			strings.Contains(out.String(), `"profileID":"`+id+`","state":"quota_unknown"`) {
			t.Fatalf("participation refusal was reported as an account failure: %s", out.String())
		}
	}
}

func TestParticipationRemovalStopsFrozenBusyWaitAndKeepsOrder(t *testing.T) {
	b := newFakeBridge(t)
	s := dynamicOrderStartup1008(t, b, "A", "B", "C")
	b.setOrder("A", "B", "C")
	b.busy = map[string]bool{"A": true, "B": true, "C": true}
	waiting, proceed := make(chan struct{}), make(chan struct{})
	var waitingOnce, proceedOnce sync.Once
	unblock := func() { proceedOnce.Do(func() { close(proceed) }) }
	b.beforeReply = func(q bridgeRequest, reply bridgeReply) bridgeReply {
		if q.Command == "acquire" && q.ProfileID == "C" && reply.Error == "busy" {
			waitingOnce.Do(func() { close(waiting) })
			<-proceed
		}
		return reply
	}
	var upstreamIDs []string
	var upstreamMu sync.Mutex
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer fixture-")
		upstreamMu.Lock()
		upstreamIDs = append(upstreamIDs, id)
		upstreamMu.Unlock()
		complete(w, id)
	}))
	t.Cleanup(upstream.Close)
	rt, server, out := startTestRuntime(t, s, upstream.URL)
	rt.selector.waitFor = time.Second
	t.Cleanup(unblock)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	finished := make(chan dynamicOrderHTTPResult1008, 1)
	go func() { finished <- dynamicOrderRequest1008(ctx, s, server.URL) }()
	select {
	case <-waiting:
	case <-ctx.Done():
		t.Fatal("request did not reach the busy admission wait")
	}
	denyFutureParticipation1008(b, "A")
	b.mu.Lock()
	b.busy["A"], b.busy["B"], b.busy["C"] = false, false, false
	b.order = []string{"C", "B"} // New priority must not replace this request's B/C order.
	b.mu.Unlock()
	unblock()
	select {
	case result := <-finished:
		if result.err != nil || result.status != http.StatusOK || !strings.Contains(result.body, "done-B") {
			t.Fatalf("old wait ignored removal or changed remaining order: %+v", result)
		}
	case <-ctx.Done():
		t.Fatal("request did not finish after participation removal")
	}
	waitEmpty(t, b)
	if got := acquiredSnapshot(b); !reflect.DeepEqual(got, []string{"B"}) || bridgeCommandCount(b, "order") != 1 {
		t.Fatalf("removed account acquired a lease or frozen order was requeried: %v", got)
	}
	upstreamMu.Lock()
	defer upstreamMu.Unlock()
	if !reflect.DeepEqual(upstreamIDs, []string{"B"}) {
		t.Fatalf("unexpected upstream identities: %v", upstreamIDs)
	}
	assertNoParticipationFailureEvent1008(t, out, "A")
}

func TestParticipationRemovalSkipsFrozenHTTPRetry(t *testing.T) {
	b := newFakeBridge(t)
	s := dynamicOrderStartup1008(t, b, "A", "B", "C")
	b.setOrder("A", "B", "C")
	started, proceed := make(chan struct{}), make(chan struct{})
	var startedOnce, proceedOnce sync.Once
	unblock := func() { proceedOnce.Do(func() { close(proceed) }) }
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer fixture-")
		if !b.hasLease(id) {
			t.Error("mock upstream received an unleased identity")
		}
		if id == "A" {
			startedOnce.Do(func() { close(started) })
			select {
			case <-proceed:
			case <-r.Context().Done():
				return
			}
			w.Header().Set("Retry-After", "60")
			http.Error(w, `{"error":{"message":"synthetic quota rejection"}}`, http.StatusTooManyRequests)
			return
		}
		complete(w, id)
	}))
	t.Cleanup(upstream.Close)
	_, server, out := startTestRuntime(t, s, upstream.URL)
	t.Cleanup(unblock)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	finished := make(chan dynamicOrderHTTPResult1008, 1)
	go func() { finished <- dynamicOrderRequest1008(ctx, s, server.URL) }()
	select {
	case <-started:
	case <-ctx.Done():
		t.Fatal("initial admitted request did not reach the mock upstream")
	}
	denyFutureParticipation1008(b, "B")
	b.setOrder("C", "A")
	unblock()
	select {
	case result := <-finished:
		if result.err != nil || result.status != http.StatusOK || !strings.Contains(result.body, "done-C") {
			t.Fatalf("retry used the removed participant: %+v", result)
		}
	case <-ctx.Done():
		t.Fatal("retry did not finish after participation removal")
	}
	waitEmpty(t, b)
	if got := acquiredSnapshot(b); !reflect.DeepEqual(got, []string{"A", "C"}) || bridgeCommandCount(b, "order") != 1 {
		t.Fatalf("wrong retry admissions or order query count: %v", got)
	}
	assertNoParticipationFailureEvent1008(t, out, "B")
}

func TestParticipationRemovalWithoutRemainingAdmissionNeverReachesUpstream(t *testing.T) {
	for _, tc := range []struct {
		name           string
		remainingQuota bool
		wantMessage    string
	}{
		{"removed_only", false, "account admission unavailable"},
		{"remaining_subscription_exhausted", true, "all eligible account quotas are exhausted"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			b := newFakeBridge(t)
			s := newStartup(t, b)
			s.DesktopFallback = true
			b.creditFallback = true
			b.setOrder("A")
			if tc.remainingQuota {
				b.setOrder("A", "B")
				b.admission = func(_, _ string) bool { return false }
			}
			b.beforeReply = func(q bridgeRequest, reply bridgeReply) bridgeReply {
				if q.Command == "order" {
					// Cancellation occurs after the older membership was captured.
					denyFutureParticipation1008(b, "A")
					if tc.remainingQuota {
						b.setOrder("B")
					} else {
						b.setOrder()
					}
				}
				return reply
			}
			var upstreamCalls atomic.Int32
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				upstreamCalls.Add(1)
				complete(w, "unexpected")
			}))
			t.Cleanup(upstream.Close)
			_, server, out := startTestRuntime(t, s, upstream.URL)
			response := request(t, s, server.URL, false)
			body := consume(t, response)
			if response.StatusCode != http.StatusServiceUnavailable || !strings.Contains(body, tc.wantMessage) || upstreamCalls.Load() != 0 || len(acquiredSnapshot(b)) != 0 {
				t.Fatalf("removal spent quota or corrupted the known result: status=%d body=%s calls=%d", response.StatusCode, body, upstreamCalls.Load())
			}
			for _, command := range admissionCommands(true, true) {
				wantCount := 1
				if tc.remainingQuota {
					wantCount = 2
				}
				if got := bridgeCommandCount(b, command); got != wantCount {
					t.Fatalf("%s did not preserve the frozen membership/stage sequence: %d", command, got)
				}
			}
			assertNoParticipationFailureEvent1008(t, out, "A")
		})
	}
}

func TestParticipationRemovalPreservesAlreadyAdmittedResponse(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	started, proceed := make(chan struct{}), make(chan struct{})
	var startedOnce, proceedOnce sync.Once
	unblock := func() { proceedOnce.Do(func() { close(proceed) }) }
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer fixture-")
		if id == "A" {
			startedOnce.Do(func() { close(started) })
			select {
			case <-proceed:
			case <-r.Context().Done():
				return
			}
		}
		complete(w, id)
	}))
	t.Cleanup(upstream.Close)
	_, server, _ := startTestRuntime(t, s, upstream.URL)
	t.Cleanup(unblock)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	finished := make(chan dynamicOrderHTTPResult1008, 1)
	go func() { finished <- dynamicOrderRequest1008(ctx, s, server.URL) }()
	select {
	case <-started:
	case <-ctx.Done():
		t.Fatal("first request was not admitted")
	}
	denyFutureParticipation1008(b, "A")
	b.setOrder("B")
	next := dynamicOrderRequest1008(ctx, s, server.URL)
	if next.err != nil || next.status != http.StatusOK || !strings.Contains(next.body, "done-B") || !b.hasLease("A") {
		t.Fatalf("removal changed the admitted lease or the next request: %+v", next)
	}
	unblock()
	select {
	case result := <-finished:
		if result.err != nil || result.status != http.StatusOK || !strings.Contains(result.body, "done-A") {
			t.Fatalf("already admitted response was interrupted: %+v", result)
		}
	case <-ctx.Done():
		t.Fatal("admitted response did not finish")
	}
	waitEmpty(t, b)
	if got := acquiredSnapshot(b); !reflect.DeepEqual(got, []string{"A", "B"}) {
		t.Fatalf("wrong admission sequence: %v", got)
	}
}
