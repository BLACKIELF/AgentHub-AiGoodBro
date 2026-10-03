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
			b.setOrder("C")
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

func TestLiveMembershipKeepsExistingLeaseAndAllowsEmptyQueue(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b) // A and B are registered, but initially only A participates.
	b.setOrder("A")
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
		t.Fatal("A did not reach upstream")
	}
	b.setOrder("B") // Remove A and add the already registered B for new requests.
	response := request(t, s, server.URL, false)
	body := consume(t, response)
	if response.StatusCode != http.StatusOK || !strings.Contains(body, "done-B") {
		t.Fatalf("new participant B was not selected: %d %s", response.StatusCode, body)
	}
	if !b.hasLease("A") {
		t.Fatal("removing A canceled an existing A lease")
	}
	b.setOrder() // Last account may leave without stopping the helper.
	acquired := len(acquiredSnapshot(b))
	response = request(t, s, server.URL, false)
	body = consume(t, response)
	if response.StatusCode != http.StatusServiceUnavailable || !strings.Contains(body, "no participating accounts") {
		t.Fatalf("empty queue must return explicit 503: %d %s", response.StatusCode, body)
	}
	if len(acquiredSnapshot(b)) != acquired || !b.hasLease("A") {
		t.Fatal("empty queue acquired an account or released the existing lease")
	}
	unblock()
	select {
	case result := <-finished:
		if result.err != nil || result.status != http.StatusOK || !strings.Contains(result.body, "done-A") {
			t.Fatalf("removed participant's request did not finish: %+v", result)
		}
	case <-ctx.Done():
		t.Fatal("removed participant's existing request did not finish")
	}
	waitEmpty(t, b)
	b.setOrder("B", "A") // Re-add a previously removed member in a new order.
	response = request(t, s, server.URL, false)
	body = consume(t, response)
	if response.StatusCode != http.StatusOK || !strings.Contains(body, "done-B") {
		t.Fatalf("re-added pool member did not remain selectable: %d %s", response.StatusCode, body)
	}
	waitEmpty(t, b)
	deadline := time.Now().Add(3 * time.Second)
	for b.snapshotCount() != 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if n := b.snapshotCount(); n != 0 {
		t.Fatalf("completed requests retained %d order snapshots", n)
	}
}

func TestLiveConcurrentMembershipAndOrderUpdates(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer fixture-")
		if id != "A" && id != "B" || !b.hasLease(id) {
			t.Errorf("invalid account lease %q", id)
		}
		complete(w, id)
	}))
	defer upstream.Close()
	_, server, _ := startTestRuntime(t, s, upstream.URL)
	stop := make(chan struct{})
	var writer sync.WaitGroup
	writer.Add(1)
	go func() {
		defer writer.Done()
		for i := 0; ; i++ {
			select {
			case <-stop:
				return
			default:
			}
			switch i % 4 {
			case 0:
				b.setOrder("A", "B")
			case 1:
				b.setOrder("B")
			case 2:
				b.setOrder()
			default:
				b.setOrder("B", "A")
			}
			time.Sleep(time.Millisecond)
		}
	}()
	failures := make(chan string, 32)
	var requests sync.WaitGroup
	for i := 0; i < 4; i++ {
		requests.Add(1)
		go func() {
			defer requests.Done()
			client := &http.Client{Timeout: 10 * time.Second}
			for n := 0; n < 8; n++ {
				req, err := http.NewRequest("POST", server.URL+"/v1/responses", strings.NewReader(`{"model":"fixture-model","input":"synthetic","stream":false}`))
				if err != nil {
					failures <- err.Error()
					return
				}
				req.Header.Set("Authorization", "Bearer "+s.ClientKey)
				req.Header.Set("Content-Type", "application/json")
				resp, err := client.Do(req)
				if err != nil {
					failures <- err.Error()
					return
				}
				body, err := io.ReadAll(resp.Body)
				resp.Body.Close()
				if err != nil {
					failures <- err.Error()
					return
				}
				if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusServiceUnavailable {
					failures <- "unexpected status during membership update"
					return
				}
				if resp.StatusCode == http.StatusOK && !strings.Contains(string(body), "done-A") && !strings.Contains(string(body), "done-B") {
					failures <- "successful response lacked registered account"
					return
				}
			}
		}()
	}
	requests.Wait()
	close(stop)
	writer.Wait()
	close(failures)
	for failure := range failures {
		t.Error(failure)
	}
	waitEmpty(t, b)
	b.setOrder("B")
	response := request(t, s, server.URL, false)
	body := consume(t, response)
	if response.StatusCode != http.StatusOK || !strings.Contains(body, "done-B") {
		t.Fatalf("post-update queue unusable: %d %s", response.StatusCode, body)
	}
	waitEmpty(t, b)
}

func TestLiveOrderRejectsInvalidMembership(t *testing.T) {
	for _, tc := range []struct {
		name  string
		order []string
	}{
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

func acquiredSnapshot(b *fakeBridge) []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]string(nil), b.acquired...)
}
