package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func controlTestBridge(t *testing.T, handler func(net.Conn, bridgeRequest)) *bridge {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "lp-control-")
	if err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(dir, "b.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close(); os.RemoveAll(dir) })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				var request bridgeRequest
				if json.NewDecoder(conn).Decode(&request) == nil {
					handler(conn, request)
				}
			}()
		}
	}()
	return &bridge{socket: socket, key: "synthetic-key", runID: "synthetic-run"}
}

func TestControlBusyRetriesOnlyConfirmedRejection(t *testing.T) {
	for _, command := range []string{"acquire", "heartbeat", "release"} {
		t.Run(command, func(t *testing.T) {
			var calls atomic.Int32
			b := controlTestBridge(t, func(conn net.Conn, q bridgeRequest) {
				if q.Command != command || q.RequestID != "request" || q.ProfileID != "profile" || q.LeaseID != "lease" || q.RunID != "synthetic-run" {
					t.Error("retry changed ownership tuple")
				}
				if calls.Add(1) <= 3 {
					_ = json.NewEncoder(conn).Encode(bridgeReply{Error: "control_busy"})
					return
				}
				_ = json.NewEncoder(conn).Encode(bridgeReply{OK: true})
			})
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			reply, err := b.call(ctx, command, "request", "profile", "lease")
			if err != nil || !reply.OK || calls.Load() != 4 {
				t.Fatalf("reply=%+v err=%v calls=%d", reply, err, calls.Load())
			}
		})
	}
}

func TestControlUnknownRepliesAreNeverReplayed(t *testing.T) {
	for _, reply := range []string{"", "not-json\n", "{\"ok\":false,\"error\":\"control_busy\",\"leaseID\":\"owned\"}\n"} {
		t.Run(reply, func(t *testing.T) {
			var calls atomic.Int32
			b := controlTestBridge(t, func(conn net.Conn, _ bridgeRequest) { calls.Add(1); _, _ = conn.Write([]byte(reply)) })
			_, err := b.call(context.Background(), "acquire", "request", "profile", "")
			if err == nil || calls.Load() != 1 {
				t.Fatalf("unknown reply was retried or accepted: err=%v calls=%d", err, calls.Load())
			}
		})
	}
}

func TestControlUnterminatedSuccessCannotExposeRolledBackLease(t *testing.T) {
	b := controlTestBridge(t, func(conn net.Conn, _ bridgeRequest) {
		// The writer produced a complete JSON object, then failed before its
		// newline. That failure causes Swift to abandon this exact lease.
		_, _ = conn.Write([]byte(`{"ok":true,"leaseID":"lease","accessToken":"fixture-token","accountID":"fixture-account","expiresAt":42}`))
	})
	reply, err := b.call(context.Background(), "acquire", "request", "profile", "")
	if err == nil || err.Error() != "bridge_eof" || reply.OK || reply.AccessToken != "" {
		t.Fatalf("unterminated reply was accepted after rollback: reply=%+v err=%v", reply, err)
	}
}

func TestControlBusyHonorsCancellationWithoutUnknownAdmission(t *testing.T) {
	var calls atomic.Int32
	b := controlTestBridge(t, func(conn net.Conn, _ bridgeRequest) {
		calls.Add(1)
		_ = json.NewEncoder(conn).Encode(bridgeReply{Error: "control_busy"})
	})
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Millisecond)
	defer cancel()
	start := time.Now()
	reply, err := b.call(ctx, "acquire", "request", "profile", "")
	if err != nil || reply.Error != "control_busy" || calls.Load() > 3 || time.Since(start) > time.Second {
		t.Fatalf("unbounded or ambiguous safe rejection: %+v %v %d", reply, err, calls.Load())
	}
}

func TestControlMaintenanceHasReservedCapacity(t *testing.T) {
	entered, unblock := make(chan struct{}, 6), make(chan struct{})
	var wg sync.WaitGroup
	b := controlTestBridge(t, func(conn net.Conn, q bridgeRequest) {
		if q.Command == "acquire" {
			entered <- struct{}{}
			<-unblock
		}
		_ = json.NewEncoder(conn).Encode(bridgeReply{OK: true})
	})
	defer func() { close(unblock); wg.Wait() }()
	for i := 0; i < 6; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, _ = b.call(context.Background(), "acquire", "request", "profile", "") }()
	}
	for i := 0; i < 6; i++ {
		select {
		case <-entered:
		case <-time.After(time.Second):
			t.Fatal("admission did not enter")
		}
	}
	for _, command := range []string{"heartbeat", "release", "acquire_resolve"} {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		reply, err := b.call(ctx, command, "request", "profile", "lease")
		cancel()
		if err != nil || !reply.OK {
			t.Fatalf("maintenance blocked by admission: %+v %v", reply, err)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	reply, err := b.call(ctx, "acquire", "cancelled", "profile", "")
	if err != nil || reply.Error != "control_busy" {
		t.Fatal("cancelled pre-send wait became ambiguous")
	}
	select {
	case <-entered:
		t.Fatal("cancelled wait sent a new acquire")
	default:
	}
}

func TestControlReconciliationHasReservedCapacity(t *testing.T) {
	entered, unblock := make(chan struct{}, 2), make(chan struct{})
	var wg sync.WaitGroup
	var resolutions atomic.Int32
	b := controlTestBridge(t, func(conn net.Conn, q bridgeRequest) {
		if q.Command == "heartbeat" || q.Command == "release" {
			entered <- struct{}{}
			<-unblock
		}
		if q.Command == "acquire_resolve" {
			resolutions.Add(1)
		}
		_ = json.NewEncoder(conn).Encode(bridgeReply{OK: true, Resolution: "not_reserved"})
	})
	b.resolveTimeout = 100 * time.Millisecond
	defer func() { close(unblock); wg.Wait() }()
	for _, command := range []string{"heartbeat", "release"} {
		wg.Add(1)
		go func(command string) {
			defer wg.Done()
			_, _ = b.call(context.Background(), command, "request", "profile", "lease")
		}(command)
	}
	for i := 0; i < 2; i++ {
		select {
		case <-entered:
		case <-time.After(time.Second):
			t.Fatal("maintenance lanes did not fill")
		}
	}
	start := time.Now()
	reply, err := b.call(context.Background(), "acquire_resolve", "request", "profile", "")
	if err != nil || !reply.OK || reply.Resolution != "not_reserved" || resolutions.Load() != 1 {
		t.Fatalf("reconciliation blocked by maintenance: reply=%+v err=%v sent=%d elapsed=%v", reply, err, resolutions.Load(), time.Since(start))
	}
}

func TestControlReconciliationCapacityIsBoundedAndCancellable(t *testing.T) {
	entered, unblock := make(chan struct{}, 3), make(chan struct{})
	var wg sync.WaitGroup
	b := controlTestBridge(t, func(conn net.Conn, q bridgeRequest) {
		entered <- struct{}{}
		<-unblock
		_ = json.NewEncoder(conn).Encode(bridgeReply{OK: true, Resolution: "not_reserved"})
	})
	defer func() { close(unblock); wg.Wait() }()
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, _ = b.call(context.Background(), "acquire_resolve", "request", "profile", "")
		}()
	}
	for i := 0; i < 2; i++ {
		select {
		case <-entered:
		case <-time.After(time.Second):
			t.Fatal("reconciliation lanes did not fill")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	reply, err := b.call(ctx, "acquire_resolve", "cancelled", "profile", "")
	if err != nil || reply.Error != "control_busy" {
		t.Fatalf("cancelled resolver queue became ambiguous: %+v %v", reply, err)
	}
	select {
	case <-entered:
		t.Fatal("cancelled resolver exceeded bounded capacity")
	default:
	}
}

func TestControlExchangeReceivesFullDeadlineAfterQueue(t *testing.T) {
	entered := make(chan struct{}, 6)
	release := make(chan struct{})
	b := controlTestBridge(t, func(conn net.Conn, q bridgeRequest) {
		if q.ProfileID == "queued" {
			time.Sleep(90 * time.Millisecond)
		} else {
			entered <- struct{}{}
			<-release
		}
		_ = json.NewEncoder(conn).Encode(bridgeReply{OK: true})
	})
	b.queueTimeout = 250 * time.Millisecond
	b.exchangeTimeout = 150 * time.Millisecond
	var wg sync.WaitGroup
	for i := 0; i < 6; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, _ = b.call(context.Background(), "acquire", "request", "occupied", "") }()
	}
	for i := 0; i < 6; i++ {
		select {
		case <-entered:
		case <-time.After(time.Second):
			t.Fatal("slots did not fill")
		}
	}
	go func() { time.Sleep(80 * time.Millisecond); close(release) }()
	start := time.Now()
	reply, err := b.call(context.Background(), "acquire", "request", "queued", "")
	wg.Wait()
	if err != nil || !reply.OK || time.Since(start) < 160*time.Millisecond {
		t.Fatalf("queue consumed exchange deadline: %+v %v %v", reply, err, time.Since(start))
	}
}

func TestRealSwiftControlPressure(t *testing.T) {
	socket := os.Getenv("AIGOODBRO_CONTROL_PRESSURE_SOCKET")
	if socket == "" {
		t.Skip("isolated Swift fixture only")
	}
	b := &bridge{socket: socket, runID: "cross-language", key: "kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk"}
	requestID := "7322adcc-6313-4a86-9e52-778070c18f6c"
	preflight, cancelPreflight := context.WithTimeout(context.Background(), 3*time.Second)
	reply, err := b.exchange(preflight, "acquire", requestID, "preflight", "")
	cancelPreflight()
	if err != nil || reply.Error != "control_busy" {
		t.Fatalf("fixture not saturated: %+v %v", reply, err)
	}
	gate := os.Getenv("AIGOODBRO_CONTROL_PRESSURE_GATE")
	go func() { time.Sleep(250 * time.Millisecond); _ = os.WriteFile(gate, nil, 0600) }()
	var wg sync.WaitGroup
	for i := 0; i < 32; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
			defer cancel()
			profile := fmt.Sprintf("retry-%d", i)
			r, err := b.call(ctx, "acquire", requestID, profile, "")
			if err != nil || !r.OK || r.LeaseID == "" {
				t.Errorf("acquire: %+v %v", r, err)
				return
			}
			r, err = b.call(ctx, "release", requestID, profile, r.LeaseID)
			if err != nil || !r.OK {
				t.Errorf("release: %+v %v", r, err)
			}
		}(i)
	}
	wg.Wait()
}
