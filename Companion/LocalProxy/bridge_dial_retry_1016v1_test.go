package main

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func missingControlSocket(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp(os.TempDir(), "lp-dial-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return filepath.Join(dir, "b.sock")
}

func TestControlDialRetryRecoversBeforeSend(t *testing.T) {
	for _, command := range []string{"acquire", "release"} {
		t.Run(command, func(t *testing.T) {
			b := &bridge{socket: missingControlSocket(t), exchangeTimeout: time.Second}
			type result struct {
				reply bridgeReply
				err   error
			}
			completed := make(chan result, 1)
			go func() {
				reply, err := b.call(context.Background(), command, "request", "profile", "lease")
				completed <- result{reply, err}
			}()
			// The listener is absent throughout the first retry interval. No
			// request can have reached a host before it becomes available.
			select {
			case result := <-completed:
				t.Fatalf("pre-send failure was not retried: %+v %v", result.reply, result.err)
			case <-time.After(20 * time.Millisecond):
			}
			listener, err := net.Listen("unix", b.socket)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = listener.Close() })
			var calls atomic.Int32
			go func() {
				for {
					conn, err := listener.Accept()
					if err != nil {
						return
					}
					var request bridgeRequest
					if json.NewDecoder(conn).Decode(&request) == nil {
						calls.Add(1)
						if request.Command != command || request.RequestID != "request" || request.ProfileID != "profile" || request.LeaseID != "lease" {
							t.Error("retry changed the ownership tuple")
						}
						_ = json.NewEncoder(conn).Encode(bridgeReply{OK: true})
					}
					_ = conn.Close()
				}
			}()
			select {
			case result := <-completed:
				if result.err != nil || !result.reply.OK || calls.Load() != 1 {
					t.Fatalf("recovery duplicated or failed command: %+v %v calls=%d", result.reply, result.err, calls.Load())
				}
			case <-time.After(2 * time.Second):
				t.Fatal("pre-send recovery exceeded its budget")
			}
		})
	}
}

func TestControlDialRetryIsBounded(t *testing.T) {
	b := &bridge{socket: missingControlSocket(t), exchangeTimeout: time.Second}
	start := time.Now()
	reply, err := b.call(context.Background(), "release", "request", "profile", "lease")
	elapsed := time.Since(start)
	if err == nil || err.Error() != "bridge_unavailable" || reply.OK || elapsed < 140*time.Millisecond || elapsed > 800*time.Millisecond {
		t.Fatalf("expected three bounded pre-send attempts: reply=%+v err=%v elapsed=%v", reply, err, elapsed)
	}
}

func TestControlDialRetryDoesNotExtendExchangeBudget(t *testing.T) {
	b := &bridge{socket: missingControlSocket(t), exchangeTimeout: 70 * time.Millisecond}
	start := time.Now()
	reply, err := b.call(context.Background(), "release", "request", "profile", "lease")
	if err != nil || reply.Error != "control_busy" || time.Since(start) > 250*time.Millisecond {
		t.Fatalf("pre-send retry extended its exchange budget: %+v %v elapsed=%v", reply, err, time.Since(start))
	}
}

func TestControlIssuedFailuresAreNotDialRetried(t *testing.T) {
	for _, mode := range []string{"eof", "timeout", "unavailable", "registry_unavailable", "registry_state_invalid"} {
		t.Run(mode, func(t *testing.T) {
			var calls atomic.Int32
			b := controlTestBridge(t, func(conn net.Conn, _ bridgeRequest) {
				calls.Add(1)
				switch mode {
				case "eof":
					return
				case "timeout":
					time.Sleep(150 * time.Millisecond)
				default:
					_ = json.NewEncoder(conn).Encode(bridgeReply{Error: mode})
				}
			})
			b.exchangeTimeout = 80 * time.Millisecond
			reply, err := b.call(context.Background(), "release", "request", "profile", "lease")
			if calls.Load() != 1 || reply.OK {
				t.Fatalf("issued release was retried: reply=%+v err=%v calls=%d", reply, err, calls.Load())
			}
			if mode == "eof" || mode == "timeout" {
				if err == nil || err.Error() != "bridge_"+mode {
					t.Fatalf("lost issued failure detail: %+v %v", reply, err)
				}
			} else if err != nil || reply.Error != mode {
				t.Fatalf("host refusal was altered: %+v %v", reply, err)
			}
		})
	}
}

func TestControlFailureDetailSeparatesTransportAndRegistry(t *testing.T) {
	for _, tc := range []struct {
		name  string
		reply bridgeReply
		err   error
		want  string
	}{
		{"transport", bridgeReply{}, errors.New("bridge_unavailable"), "transport_unavailable"},
		{"registry", bridgeReply{Error: "registry_unavailable"}, nil, "registry_unavailable"},
		{"state", bridgeReply{Error: "registry_state_invalid"}, nil, "registry_state_invalid"},
		{"legacy", bridgeReply{Error: "unavailable"}, nil, "unavailable"},
		{"untrusted suffix", bridgeReply{Error: "registry_unavailable: private detail"}, nil, "rejected"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := controlFailureDetail(tc.reply, tc.err); got != tc.want {
				t.Fatalf("detail=%q want=%q", got, tc.want)
			}
		})
	}
}
