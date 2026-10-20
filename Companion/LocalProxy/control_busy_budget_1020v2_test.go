package main

import (
	"context"
	"encoding/json"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestControlBusyTail1020NeverCreatesUnknownExchange(t *testing.T) {
	for _, command := range []string{"acquire", "acquire_resolve"} {
		t.Run(command, func(t *testing.T) {
			const budget = 650 * time.Millisecond
			const hostDelay = 200 * time.Millisecond
			var mu sync.Mutex
			var arrivals []time.Duration
			started := time.Now()
			b := heartbeatTestBridge1020(t, func(conn net.Conn, request bridgeRequest) {
				if request.Command != command || request.RunID != "synthetic-run" || request.Key != "synthetic-key" || request.RequestID != "request-busy" || request.ProfileID != "profile-busy" || request.LeaseID != "" {
					t.Error("busy retry changed command or ownership tuple")
				}
				mu.Lock()
				arrivals = append(arrivals, time.Since(started))
				mu.Unlock()
				// Every real Unix exchange gets the same fixed reply gate. The
				// host neither drops a reply nor returns malformed/unknown data.
				gate := time.NewTimer(hostDelay)
				<-gate.C
				_ = json.NewEncoder(conn).Encode(bridgeReply{Error: "control_busy"})
			})
			b.exchangeTimeout = budget
			b.resolveTimeout = budget
			reply, err := b.call(context.Background(), command, "request-busy", "profile-busy", "")
			elapsed := time.Since(started)
			mu.Lock()
			observed := append([]time.Duration(nil), arrivals...)
			mu.Unlock()
			t.Logf("command=%s shared_budget=%s fixed_host_delay=%s arrivals=%v elapsed=%s error=%v reply_error=%s", command, budget, hostDelay, observed, elapsed, err, reply.Error)
			if len(observed) < 2 {
				t.Fatal("fixture did not receive two real authoritative busy replies")
			}
			if err != nil || reply.Error != "control_busy" || reply.OK {
				t.Fatalf("only authoritative busy replies became unknown: error=%v reply_error=%s requests=%d", err, reply.Error, len(observed))
			}
			if len(observed) != 2 {
				t.Fatalf("sent an exchange without enough remaining budget for its observed RTT: requests=%d", len(observed))
			}
		})
	}
}

func TestControlBusyTail1020DefaultExchangeBoundWithCallerDeadline(t *testing.T) {
	// Order retains its caller deadline. Leave production bounds at zero and
	// exercise their shorter inherited shared deadline without a clock hook.
	var calls atomic.Int32
	b := heartbeatTestBridge1020(t, func(conn net.Conn, request bridgeRequest) {
		if request.Command != "order" {
			t.Error("unexpected operation")
		}
		calls.Add(1)
		time.Sleep(200 * time.Millisecond)
		_ = json.NewEncoder(conn).Encode(bridgeReply{Error: "control_busy"})
	})
	ctx, cancel := context.WithTimeout(context.Background(), 650*time.Millisecond)
	defer cancel()
	started := time.Now()
	reply, err := b.call(ctx, "order", "request-busy", "profile-busy", "")
	t.Logf("production_exchange_bound=25s caller_deadline=650ms calls=%d elapsed=%s error=%v reply_error=%s", calls.Load(), time.Since(started), err, reply.Error)
	if b.exchangeTimeout != 0 || b.resolveTimeout != 0 || err != nil || reply.Error != "control_busy" || calls.Load() != 2 {
		t.Fatalf("default exchange path did not retain its authoritative reply: error=%v reply_error=%s requests=%d", err, reply.Error, calls.Load())
	}
}

func TestControlBusyTail1020IssuedUnknownIsNeverDowngraded(t *testing.T) {
	for _, command := range []string{"acquire", "acquire_resolve", "release"} {
		for _, mode := range []string{"eof", "timeout"} {
			t.Run(command+"/"+mode, func(t *testing.T) {
				leaseID := ""
				if command == "release" {
					leaseID = "lease-busy"
				}
				var calls, commits atomic.Int32
				finish := make(chan struct{})
				defer close(finish)
				b := heartbeatTestBridge1020(t, func(conn net.Conn, request bridgeRequest) {
					if request.Command != command || request.LeaseID != leaseID {
						t.Error("retry changed operation or lease")
					}
					if calls.Add(1) == 1 {
						_ = json.NewEncoder(conn).Encode(bridgeReply{Error: "control_busy"})
						return
					}
					commits.Add(1) // A new exchange may have mutated the host.
					if mode == "timeout" {
						<-finish
					}
				})
				b.exchangeTimeout = 250 * time.Millisecond
				b.resolveTimeout = 250 * time.Millisecond
				reply, err := b.call(context.Background(), command, "request-busy", "profile-busy", leaseID)
				if err == nil || err.Error() != "bridge_"+mode || reply.Error == "control_busy" || calls.Load() != 2 || commits.Load() != 1 {
					t.Fatalf("issued unknown exchange was replayed or hidden: error=%v reply_error=%s requests=%d commits=%d", err, reply.Error, calls.Load(), commits.Load())
				}
			})
		}
	}
}

func TestControlBusyTail1020KnownRetryCanStillSucceed(t *testing.T) {
	for _, command := range []string{"acquire", "acquire_resolve"} {
		t.Run(command, func(t *testing.T) {
			var calls atomic.Int32
			b := heartbeatTestBridge1020(t, func(conn net.Conn, _ bridgeRequest) {
				if calls.Add(1) == 1 {
					_ = json.NewEncoder(conn).Encode(bridgeReply{Error: "control_busy"})
					return
				}
				time.Sleep(120 * time.Millisecond)
				reply := bridgeReply{OK: true, Resolution: "not_reserved"}
				if command == "acquire" {
					reply = bridgeReply{OK: true, LeaseID: "fixture-lease", AccessToken: "fixture-token", AccountID: "fixture-account", ExpiresAt: time.Now().Add(time.Hour).Unix()}
				}
				_ = json.NewEncoder(conn).Encode(reply)
			})
			b.exchangeTimeout = 300 * time.Millisecond
			b.resolveTimeout = 300 * time.Millisecond
			reply, err := b.call(context.Background(), command, "request-busy", "profile-busy", "")
			if err != nil || !reply.OK || calls.Load() != 2 {
				t.Fatalf("known safe retry lost remaining full deadline: error=%v ok=%v requests=%d", err, reply.OK, calls.Load())
			}
		})
	}
}

func TestControlBusyTail1020PayloadIsNotAuthoritativeBusy(t *testing.T) {
	for _, payload := range []struct {
		name  string
		reply bridgeReply
	}{
		{"credit-fallback", bridgeReply{CreditFallback: true}},
		{"resolution", bridgeReply{Resolution: "abandoned"}},
		{"retry-at", bridgeReply{RetryAt: 1}},
		{"quota-observed-at", bridgeReply{QuotaObservedAt: 1}},
	} {
		t.Run(payload.name, func(t *testing.T) {
			var calls atomic.Int32
			b := heartbeatTestBridge1020(t, func(conn net.Conn, _ bridgeRequest) {
				calls.Add(1)
				reply := payload.reply
				reply.Error = "control_busy"
				_ = json.NewEncoder(conn).Encode(reply)
			})
			b.exchangeTimeout = 250 * time.Millisecond
			reply, err := b.call(context.Background(), "acquire", "request-busy", "profile-busy", "")
			if err == nil || err.Error() != "bridge_invalid" || reply.Error == "control_busy" || calls.Load() != 1 {
				t.Fatalf("payload-bearing rejection was treated as pure busy: error=%v reply_error=%s requests=%d", err, reply.Error, calls.Load())
			}
		})
	}
}
