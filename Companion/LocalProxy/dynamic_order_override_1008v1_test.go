package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

// These fields are the host's order RPC result, not a second implementation of
// persisted preferences. Every request below passes through newRuntime's real
// HTTP router, Unix bridge, selector and mock upstream on one running instance.
func setDynamicOrderPolicy1008(b *fakeBridge, order, deferred, fallback []string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.order = append([]string(nil), order...)
	b.deferredIDs = append([]string(nil), deferred...)
	b.lastResortIDs = append([]string(nil), fallback...)
}

func dynamicOrderStartup1008(t *testing.T, b *fakeBridge, ids ...string) startup {
	t.Helper()
	s := newStartup(t, b)
	s.Accounts = nil
	for _, id := range ids {
		s.Accounts = append(s.Accounts, struct {
			ID string `json:"id"`
		}{id})
	}
	return s
}

type dynamicOrderHTTPResult1008 struct {
	status int
	body   string
	err    error
}

func dynamicOrderRequest1008(ctx context.Context, s startup, url string) dynamicOrderHTTPResult1008 {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url+"/v1/responses", strings.NewReader(`{"model":"fixture-model","input":"synthetic","stream":false}`))
	if err != nil {
		return dynamicOrderHTTPResult1008{err: err}
	}
	req.Header.Set("Authorization", "Bearer "+s.ClientKey)
	req.Header.Set("Content-Type", "application/json")
	response, err := (&http.Client{Timeout: 5 * time.Second}).Do(req)
	if err != nil {
		return dynamicOrderHTTPResult1008{err: err}
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	return dynamicOrderHTTPResult1008{status: response.StatusCode, body: string(body), err: err}
}

func TestDynamicOrderOverridesKeepRunningHTTPRuntime(t *testing.T) {
	b := newFakeBridge(t)
	s := dynamicOrderStartup1008(t, b, "Pro", "A", "B")
	setDynamicOrderPolicy1008(b, []string{"Pro", "A", "B"}, []string{"Pro"}, nil)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer fixture-")
		if !b.hasLease(id) {
			t.Error("mock upstream received an account without a lease")
		}
		complete(w, id)
	}))
	t.Cleanup(upstream.Close)
	rt, server, _ := startTestRuntime(t, s, upstream.URL)
	registered := append([]string(nil), rt.selector.order...)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	var expectedAcquired []string
	for index, tc := range []struct {
		name                      string
		order, deferred, fallback []string
		want                      string
	}{
		{"pro_default_last", []string{"Pro", "A", "B"}, []string{"Pro"}, nil, "A"},
		{"pro_priority_override", []string{"Pro", "A", "B"}, nil, nil, "Pro"},
		{"pro_manual_last", []string{"Pro", "A", "B"}, []string{"Pro"}, nil, "A"},
		{"mixed_last_group_moves_pro_first", []string{"Pro", "B"}, []string{"Pro", "B"}, nil, "Pro"},
		{"mixed_last_group_moves_other_first", []string{"B", "Pro"}, []string{"B", "Pro"}, nil, "B"},
		{"ordinary_priority", []string{"B", "A", "Pro"}, []string{"Pro"}, nil, "B"},
		{"priority_changed_to_last", []string{"B", "A", "Pro"}, []string{"B", "Pro"}, nil, "A"},
		{"remove_ordinary_participant", []string{"B", "Pro"}, []string{"B", "Pro"}, nil, "B"},
		{"leave_default_last_only", []string{"Pro"}, []string{"Pro"}, nil, "Pro"},
		{"remove_all_participants", nil, nil, nil, ""},
		{"rejoin_with_pro_priority", []string{"Pro", "B", "A"}, nil, nil, "Pro"},
	} {
		if !t.Run(tc.name, func(t *testing.T) {
			setDynamicOrderPolicy1008(b, tc.order, tc.deferred, tc.fallback)
			result := dynamicOrderRequest1008(ctx, s, server.URL)
			if result.err != nil {
				t.Fatal(result.err)
			}
			if tc.want == "" {
				if result.status != http.StatusServiceUnavailable || !strings.Contains(result.body, "no participating accounts") {
					t.Fatalf("empty participation admitted a request: %+v", result)
				}
			} else {
				if result.status != http.StatusOK || !strings.Contains(result.body, "done-"+tc.want) {
					t.Fatalf("policy update did not choose %s: %+v", tc.want, result)
				}
				expectedAcquired = append(expectedAcquired, tc.want)
			}
			waitEmpty(t, b)
			waitForBridgeCommandCount(t, b, "order_end", index+1)
			if got := acquiredSnapshot(b); !reflect.DeepEqual(got, expectedAcquired) {
				t.Fatalf("unexpected account admission after update: got %v want %v", got, expectedAcquired)
			}
			if got := bridgeCommandCount(b, "order"); got != index+1 {
				t.Fatalf("request must query exactly one current order, got %d want %d", got, index+1)
			}
			if b.snapshotCount() != 0 || !reflect.DeepEqual(rt.selector.order, registered) {
				t.Fatal("request leaked a snapshot or mutated the registered runtime pool")
			}
		}) {
			return
		}
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, command := range b.commands {
		if strings.Contains(command, "credit") {
			t.Fatal("ordering changes enabled an unrequested paid admission")
		}
	}
}

func TestDynamicOrderMutationFreezesInflightHTTPRetry(t *testing.T) {
	b := newFakeBridge(t)
	s := dynamicOrderStartup1008(t, b, "A", "Pro", "B")
	setDynamicOrderPolicy1008(b, []string{"A", "Pro", "B"}, []string{"B"}, []string{"Pro"})
	started, release := make(chan struct{}), make(chan struct{})
	var startedOnce, releaseOnce sync.Once
	unblock := func() { releaseOnce.Do(func() { close(release) }) }
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer fixture-")
		if !b.hasLease(id) {
			t.Error("mock upstream received an account without a lease")
		}
		if id == "A" {
			startedOnce.Do(func() { close(started) })
			select {
			case <-release:
			case <-r.Context().Done():
				return
			}
			w.Header().Set("Retry-After", "60")
			http.Error(w, `{"error":{"message":"fixture quota","type":"rate_limit_error"}}`, http.StatusTooManyRequests)
			return
		}
		complete(w, id)
	}))
	t.Cleanup(upstream.Close)
	rt, server, _ := startTestRuntime(t, s, upstream.URL)
	t.Cleanup(unblock) // Unblock before the fixture HTTP servers close on failure.
	registered := append([]string(nil), rt.selector.order...)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	finished := make(chan dynamicOrderHTTPResult1008, 1)
	go func() { finished <- dynamicOrderRequest1008(ctx, s, server.URL) }()
	select {
	case <-started:
	case <-ctx.Done():
		t.Fatal("old request did not reach mock upstream")
	}
	// Remove A/B and promote Pro for new requests while A's old lease is live.
	// Refreshing either order or group metadata on retry would wrongly choose Pro.
	setDynamicOrderPolicy1008(b, []string{"Pro"}, nil, nil)
	next := dynamicOrderRequest1008(ctx, s, server.URL)
	if next.err != nil || next.status != http.StatusOK || !strings.Contains(next.body, "done-Pro") {
		t.Fatalf("new request ignored membership/priority override: %+v", next)
	}
	waitForBridgeCommandCount(t, b, "order_end", 1)
	if !b.hasLease("A") || b.snapshotCount() != 1 {
		t.Fatal("updating participation released the old lease or its order snapshot")
	}
	unblock()
	select {
	case old := <-finished:
		if old.err != nil || old.status != http.StatusOK || !strings.Contains(old.body, "done-B") {
			t.Fatalf("old retry did not keep its original membership and groups: %+v", old)
		}
	case <-ctx.Done():
		t.Fatal("old request failed to complete after policy update")
	}
	waitEmpty(t, b)
	waitForBridgeCommandCount(t, b, "order_end", 2)
	if got := acquiredSnapshot(b); !reflect.DeepEqual(got, []string{"A", "Pro", "B"}) {
		t.Fatalf("unexpected old/new request admission sequence: %v", got)
	}
	if bridgeCommandCount(b, "order") != 2 || b.snapshotCount() != 0 || !reflect.DeepEqual(rt.selector.order, registered) {
		t.Fatal("old retry requeried live policy, leaked a snapshot, or replaced the runtime pool")
	}
	t.Log(fmt.Sprintf("one runtime, two HTTP requests, old retry A->B, new override Pro, 2 order RPCs, 0 retained snapshots"))
}
