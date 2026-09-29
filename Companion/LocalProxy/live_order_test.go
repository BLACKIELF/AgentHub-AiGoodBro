package main

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func (b *fakeBridge) setOrder(order ...string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.order = append([]string(nil), order...)
}

func TestLiveOrderKeepsActiveRequestAndChangesNextRequest(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	started, release := make(chan struct{}), make(chan struct{})
	var startedOnce, releaseOnce sync.Once
	unblock := func() { releaseOnce.Do(func() { close(release) }) }
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer fixture-")
		if !b.hasLease(id) {
			t.Error("upstream without an account lease")
		}
		if id == "A" {
			startedOnce.Do(func() { close(started) })
			select {
			case <-release:
			case <-r.Context().Done():
				return
			}
		}
		complete(w, id)
	}))
	t.Cleanup(upstream.Close)
	_, server, _ := startTestRuntime(t, s, upstream.URL)
	// Unblock before either HTTP server is closed, including on a failed assertion.
	t.Cleanup(unblock)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "POST", server.URL+"/v1/responses", strings.NewReader(`{"model":"fixture-model","input":"synthetic","stream":false}`))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+s.ClientKey)
	req.Header.Set("Content-Type", "application/json")
	type result struct {
		status int
		body   string
		err    error
	}
	finished := make(chan result, 1)
	go func() {
		response, err := http.DefaultClient.Do(req)
		if err != nil {
			finished <- result{err: err}
			return
		}
		defer response.Body.Close()
		body, err := io.ReadAll(response.Body)
		finished <- result{status: response.StatusCode, body: string(body), err: err}
	}()
	select {
	case <-started:
	case <-ctx.Done():
		t.Fatal("first request did not reach upstream")
	}
	b.setOrder("B", "A")
	response := request(t, s, server.URL, false)
	body := consume(t, response)
	if response.StatusCode != http.StatusOK || !strings.Contains(body, "done-B") {
		t.Fatalf("new request did not use B: %d %s", response.StatusCode, body)
	}
	if !b.hasLease("A") {
		t.Fatal("reorder released the active A lease")
	}
	unblock()
	select {
	case result := <-finished:
		if result.err != nil || result.status != http.StatusOK || !strings.Contains(result.body, "done-A") {
			t.Fatalf("active request did not finish on A: %+v", result)
		}
	case <-ctx.Done():
		t.Fatal("active request failed to finish after reorder")
	}
	waitEmpty(t, b)
	b.mu.Lock()
	defer b.mu.Unlock()
	orders := 0
	for _, command := range b.commands {
		if command == "order" {
			orders++
		}
	}
	if orders != 2 {
		t.Fatalf("expected one order snapshot per request, got %d", orders)
	}
}

func TestLiveOrderFreezesRetrySequence(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	s.Accounts = append(s.Accounts, struct {
		ID string `json:"id"`
	}{"C"})
	b.setOrder("A", "B", "C")
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer fixture-")
		if id == "A" {
			b.setOrder("C", "B", "A")
			w.Header().Set("Retry-After", "60")
			http.Error(w, `{"error":{"message":"fixture quota","type":"rate_limit_error"}}`, http.StatusTooManyRequests)
			return
		}
		complete(w, id)
	}))
	defer upstream.Close()
	_, server, _ := startTestRuntime(t, s, upstream.URL)
	for _, want := range []string{"B", "C"} {
		response := request(t, s, server.URL, false)
		body := consume(t, response)
		if response.StatusCode != http.StatusOK || !strings.Contains(body, "done-"+want) {
			t.Fatalf("want %s, got %d %s", want, response.StatusCode, body)
		}
		waitEmpty(t, b)
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if strings.Join(b.acquired, ",") != "A,B,C" {
		t.Fatalf("retry order changed mid-request: %v", b.acquired)
	}
	orders := 0
	for _, command := range b.commands {
		if command == "order" {
			orders++
		}
	}
	if orders != 2 {
		t.Fatalf("retries must reuse the first order snapshot, got %d queries", orders)
	}
}

func TestLiveOrderRejectsChangedMembership(t *testing.T) {
	for _, tc := range []struct {
		name  string
		order []string
	}{
		{"missing", []string{"A"}},
		{"empty", nil},
		{"duplicate", []string{"A", "A"}},
		{"foreign", []string{"A", "C"}},
		{"extra", []string{"A", "B", "C"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			b := newFakeBridge(t)
			s := newStartup(t, b)
			b.setOrder(tc.order...)
			var called atomic.Bool
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				called.Store(true)
				complete(w, "unexpected")
			}))
			defer upstream.Close()
			_, server, _ := startTestRuntime(t, s, upstream.URL)
			response := request(t, s, server.URL, false)
			consume(t, response)
			if response.StatusCode != http.StatusServiceUnavailable || called.Load() || b.count() != 0 {
				t.Fatalf("invalid order reached admission/upstream: status=%d", response.StatusCode)
			}
			b.mu.Lock()
			defer b.mu.Unlock()
			if len(b.acquired) != 0 {
				t.Fatal("invalid order acquired an account")
			}
		})
	}
}
