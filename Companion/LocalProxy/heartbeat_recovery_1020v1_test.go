package main

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Join the accept loop before waiting for handlers: adding to a zero WaitGroup
// inside the handler itself can race test teardown after a client-side timeout.
func heartbeatTestBridge1020(t *testing.T, handler func(net.Conn, bridgeRequest)) *bridge {
	t.Helper()
	dir, err := os.MkdirTemp(os.TempDir(), "lp-heartbeat-")
	if err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(dir, "b.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		os.RemoveAll(dir)
		t.Fatal(err)
	}
	var connectionsMu sync.Mutex
	connections := map[net.Conn]struct{}{}
	var handlers sync.WaitGroup
	acceptDone := make(chan struct{})
	go func() {
		defer close(acceptDone)
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			connectionsMu.Lock()
			connections[conn] = struct{}{}
			connectionsMu.Unlock()
			handlers.Add(1)
			go func() {
				defer handlers.Done()
				defer func() { conn.Close(); connectionsMu.Lock(); delete(connections, conn); connectionsMu.Unlock() }()
				var request bridgeRequest
				if json.NewDecoder(conn).Decode(&request) == nil {
					handler(conn, request)
				}
			}()
		}
	}()
	t.Cleanup(func() {
		listener.Close()
		<-acceptDone // No future handlers.Add can race Wait.
		connectionsMu.Lock()
		for conn := range connections {
			conn.Close()
		}
		connectionsMu.Unlock()
		handlers.Wait()
		os.RemoveAll(dir)
	})
	return &bridge{socket: socket, key: "synthetic-key", runID: "synthetic-run"}
}

func closeHeartbeatGate1020(gate chan struct{}) {
	select {
	case <-gate:
	default:
		close(gate)
	}
}

func assertHeartbeatTuple1020(t *testing.T, q bridgeRequest, profile, lease string) {
	t.Helper()
	if q.SchemaVersion != 1 || q.RunID != "synthetic-run" || q.Key != "synthetic-key" || q.RequestID != "request-heartbeat" || q.ProfileID != profile || q.LeaseID != lease {
		t.Error("heartbeat retry or release changed the exact ownership tuple")
	}
}

func TestHeartbeat1020LostReplyRenewsOnlyTheSameLease(t *testing.T) {
	var calls, renewals atomic.Int32
	b := heartbeatTestBridge1020(t, func(conn net.Conn, q bridgeRequest) {
		assertHeartbeatTuple1020(t, q, "profile-A", "lease-A")
		if q.Command != "heartbeat" {
			t.Error("unexpected lease operation")
			return
		}
		n := calls.Add(1)
		renewals.Add(1) // Commit the existing lease before losing the first reply.
		if n == 1 {
			return
		}
		_ = json.NewEncoder(conn).Encode(bridgeReply{OK: true})
	})
	b.exchangeTimeout = 180 * time.Millisecond
	start := time.Now()
	reply, err := b.call(context.Background(), "heartbeat", "request-heartbeat", "profile-A", "lease-A")
	if err != nil || !reply.OK || calls.Load() != 2 || renewals.Load() != 2 {
		t.Fatalf("lost heartbeat reply was not recovered on the exact lease: ok=%v err=%v calls=%d renewals=%d", reply.OK, err, calls.Load(), renewals.Load())
	}
	if time.Since(start) > 230*time.Millisecond {
		t.Fatal("heartbeat retry enlarged the original total exchange budget")
	}
}

func TestHeartbeat1020CancelledUnknownReplyUsesCompleteRelease(t *testing.T) {
	for _, mode := range []string{"eof", "timeout", "release-failure", "release-eof", "release-timeout", "hard-rejection", "malformed-reply"} {
		t.Run(mode, func(t *testing.T) {
			entered, finishReply := make(chan struct{}), make(chan struct{})
			defer closeHeartbeatGate1020(finishReply)
			finishRelease := make(chan struct{})
			defer closeHeartbeatGate1020(finishRelease)
			var mu sync.Mutex
			owned := map[string]string{"profile-A": "lease-A", "profile-B": "lease-B"}
			var heartbeats, releases int
			b := heartbeatTestBridge1020(t, func(conn net.Conn, q bridgeRequest) {
				assertHeartbeatTuple1020(t, q, q.ProfileID, q.LeaseID)
				mu.Lock()
				expected, exists := owned[q.ProfileID]
				valid := exists && expected == q.LeaseID
				if q.Command == "heartbeat" {
					heartbeats++
					mu.Unlock()
					if q.ProfileID != "profile-A" || !valid {
						t.Error("cancelled heartbeat reached a later or unowned lease")
					}
					close(entered)
					<-finishReply
					if mode == "hard-rejection" {
						_ = json.NewEncoder(conn).Encode(bridgeReply{Error: "registry_state_invalid"})
					} else if mode == "malformed-reply" {
						_, _ = conn.Write([]byte("invalid-json\n"))
					}
					return
				}
				if q.Command == "release" {
					releases++
					reject := mode == "release-failure" && q.ProfileID == "profile-B"
					if valid && !reject {
						delete(owned, q.ProfileID)
					}
					mu.Unlock()
					if q.ProfileID == "profile-B" && (mode == "release-eof" || mode == "release-timeout") {
						if mode == "release-timeout" {
							<-finishRelease
						}
						return // Terminal write committed, but its reply is unknown.
					}
					reply := bridgeReply{OK: valid && !reject}
					if reject {
						reply.Error = "registry_unavailable"
					}
					_ = json.NewEncoder(conn).Encode(reply)
					return
				}
				mu.Unlock()
				t.Error("unexpected operation")
			})
			b.exchangeTimeout = 90 * time.Millisecond
			ctx, cancel := context.WithCancel(context.Background())
			out := &synchronizedBuffer{}
			scope := &requestScope{id: "request-heartbeat", ctx: ctx, cancel: cancel, bridge: b, events: &events{out: out}, done: make(chan struct{}), exited: make(chan struct{}), heartbeatPeriod: time.Millisecond}
			scope.add(lease{"profile-A", "lease-A"})
			scope.add(lease{"profile-B", "lease-B"})
			go scope.heartbeats()
			<-entered
			cancel()
			if mode != "timeout" {
				close(finishReply)
			}
			select {
			case <-scope.exited:
			case <-time.After(time.Second):
				t.Fatal("cancelled heartbeat did not finish")
			}
			if mode == "timeout" {
				close(finishReply)
			}
			scope.close() // Production cleanup waits for heartbeat and releases the full snapshot.
			close(finishRelease)
			mu.Lock()
			sent, released, remaining := heartbeats, releases, len(owned)
			mu.Unlock()
			if sent != 1 || released != 2 {
				t.Fatalf("cleanup skipped or replayed an operation: heartbeat=%d release=%d", sent, released)
			}
			if mode != "release-failure" && remaining != 0 {
				t.Fatal("cleanup left a failover lease occupied")
			}
			if mode == "release-failure" && remaining != 1 {
				t.Fatal("a failed release changed the unknown lease or skipped the other lease")
			}
			heartbeatFatal := strings.Contains(out.String(), "lease_heartbeat_failed")
			if mode == "hard-rejection" || mode == "malformed-reply" {
				if !heartbeatFatal {
					t.Fatal("hard registry rejection was hidden by cancellation")
				}
			} else if heartbeatFatal {
				t.Fatal("cancelled transport uncertainty stopped the pool before exact release could settle it")
			}
			failedRelease := strings.HasPrefix(mode, "release-")
			if failedRelease != strings.Contains(out.String(), "lease_release_unknown") {
				t.Fatal("unknown release did not preserve fail-closed escalation")
			}
			if failedRelease && strings.Count(out.String(), "lease_release_unknown") != 1 {
				t.Fatal("one uncertain release must remain one fatal cleanup result")
			}
		})
	}
}

func TestHeartbeat1020ActiveUnconfirmedReplyCancelsThenProvesAllLeasesReleased(t *testing.T) {
	for _, mode := range []string{"timeout", "eof", "control-busy", "eof-then-busy"} {
		for _, releaseMode := range []string{"ok", "reject", "eof", "timeout", "control-busy"} {
			t.Run(mode+"/release-"+releaseMode, func(t *testing.T) {
				finishHeartbeat, finishRelease := make(chan struct{}), make(chan struct{})
				defer closeHeartbeatGate1020(finishHeartbeat)
				defer closeHeartbeatGate1020(finishRelease)
				var mu sync.Mutex
				owned := map[string]string{"profile-A": "lease-A", "profile-B": "lease-B"}
				heartbeats, releases := 0, 0
				b := heartbeatTestBridge1020(t, func(conn net.Conn, q bridgeRequest) {
					assertHeartbeatTuple1020(t, q, q.ProfileID, q.LeaseID)
					mu.Lock()
					valid := owned[q.ProfileID] == q.LeaseID
					if q.Command == "heartbeat" {
						heartbeats++
						count := heartbeats
						mu.Unlock()
						if !valid || q.ProfileID != "profile-A" {
							t.Error("unconfirmed request continued to another lease")
						}
						switch mode {
						case "timeout":
							<-finishHeartbeat
						case "control-busy":
							_ = json.NewEncoder(conn).Encode(bridgeReply{Error: "control_busy"})
						case "eof-then-busy":
							if count > 1 {
								_ = json.NewEncoder(conn).Encode(bridgeReply{Error: "control_busy"})
							}
						}
						return
					}
					if q.Command == "release" {
						releases++
						fail := q.ProfileID == "profile-B" && releaseMode != "ok"
						if valid && (!fail || releaseMode == "eof" || releaseMode == "timeout") {
							delete(owned, q.ProfileID)
						}
						mu.Unlock()
						if fail {
							switch releaseMode {
							case "reject":
								_ = json.NewEncoder(conn).Encode(bridgeReply{Error: "registry_unavailable"})
							case "control-busy":
								_ = json.NewEncoder(conn).Encode(bridgeReply{Error: "control_busy"})
							case "timeout":
								<-finishRelease
							}
							return
						}
						_ = json.NewEncoder(conn).Encode(bridgeReply{OK: valid})
						return
					}
					mu.Unlock()
					t.Error("unexpected operation")
				})
				b.exchangeTimeout = 120 * time.Millisecond
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				out := &synchronizedBuffer{}
				scope := &requestScope{id: "request-heartbeat", ctx: ctx, cancel: cancel, bridge: b, events: &events{out: out}, done: make(chan struct{}), exited: make(chan struct{}), heartbeatPeriod: time.Millisecond}
				scope.add(lease{"profile-A", "lease-A"})
				scope.add(lease{"profile-B", "lease-B"})
				start := time.Now()
				go scope.heartbeats()
				select {
				case <-ctx.Done():
				case <-time.After(time.Second):
					t.Fatal("unconfirmed heartbeat did not cancel its active request")
				}
				<-scope.exited
				elapsed := time.Since(start)
				mu.Lock()
				beforeRelease, stillOwned, sent := releases, len(owned), heartbeats
				mu.Unlock()
				if beforeRelease != 0 || stillOwned != 2 {
					t.Fatal("heartbeat released ownership before the HTTP handler could finish")
				}
				if elapsed > 220*time.Millisecond {
					t.Fatalf("heartbeat enlarged original total exchange budget: %v", elapsed)
				}
				if mode == "eof" && sent != 3 {
					t.Fatalf("EOF retries were not bounded to three attempts: %d", sent)
				}
				if mode == "timeout" && (sent != 1 || elapsed < 100*time.Millisecond) {
					t.Fatal("heartbeat shortened the original wait or replayed full-budget timeout")
				}
				close(finishHeartbeat)
				scope.close() // Simulate the handler's deferred cleanup after it has stopped.
				close(finishRelease)
				mu.Lock()
				remaining := len(owned)
				mu.Unlock()
				if strings.Contains(out.String(), "lease_heartbeat_failed") {
					t.Fatal("transport uncertainty escalated before exact cleanup")
				}
				failureCount := strings.Count(out.String(), "lease_release_unknown")
				if releaseMode == "ok" {
					if remaining != 0 || failureCount != 0 {
						t.Fatal("confirmed complete release did not settle heartbeat uncertainty")
					}
				} else if failureCount != 1 {
					t.Fatal("one unconfirmed cleanup did not preserve fatal escalation")
				}
				if (releaseMode == "reject" || releaseMode == "control-busy") && remaining != 1 {
					t.Fatal("failed cleanup released an unconfirmed owned lease")
				}
			})
		}
	}
}

func TestHeartbeat1020AuthoritativeOrMalformedReplyDoesNotReplay(t *testing.T) {
	for _, code := range []string{"identity", "registry_state_invalid", "registry_unavailable", "stopping", "malformed"} {
		t.Run(code, func(t *testing.T) {
			var calls atomic.Int32
			b := heartbeatTestBridge1020(t, func(conn net.Conn, q bridgeRequest) {
				assertHeartbeatTuple1020(t, q, "profile-A", "lease-A")
				calls.Add(1)
				if code == "malformed" {
					_, _ = conn.Write([]byte("invalid-json\n"))
					return
				}
				_ = json.NewEncoder(conn).Encode(bridgeReply{Error: code})
			})
			reply, err := b.call(context.Background(), "heartbeat", "request-heartbeat", "profile-A", "lease-A")
			if calls.Load() != 1 || reply.OK {
				t.Fatal("authoritative or malformed heartbeat was replayed or accepted")
			}
			if code == "malformed" {
				if err == nil || err.Error() != "bridge_decode" {
					t.Fatal("malformed reply lost its failure classification")
				}
			} else if err != nil || reply.Error != code {
				t.Fatal("explicit host rejection was changed")
			}
		})
	}
}

func TestHeartbeat1020OtherLeaseCommandsRemainNonReplayable(t *testing.T) {
	for _, command := range []string{"acquire", "release"} {
		for _, mode := range []string{"eof", "timeout"} {
			t.Run(command+"/"+mode, func(t *testing.T) {
				var calls atomic.Int32
				finish := make(chan struct{})
				defer closeHeartbeatGate1020(finish)
				b := heartbeatTestBridge1020(t, func(conn net.Conn, q bridgeRequest) {
					calls.Add(1)
					if q.Command != command {
						t.Error("retry changed the lease command")
					}
					if mode == "timeout" {
						<-finish
					}
				})
				b.exchangeTimeout = 90 * time.Millisecond
				_, err := b.call(context.Background(), command, "request-heartbeat", "profile-A", "lease-A")
				close(finish)
				if calls.Load() != 1 || err == nil || (err.Error() != "bridge_eof" && err.Error() != "bridge_timeout") {
					t.Fatalf("non-heartbeat ambiguous operation was replayed: calls=%d err=%v", calls.Load(), err)
				}
			})
		}
	}
}

func TestHeartbeat1020ActiveHardRejectionStillFailsClosed(t *testing.T) {
	for _, code := range []string{"identity", "registry_state_invalid", "registry_unavailable", "malformed"} {
		t.Run(code, func(t *testing.T) {
			var heartbeats, releases atomic.Int32
			b := heartbeatTestBridge1020(t, func(conn net.Conn, q bridgeRequest) {
				assertHeartbeatTuple1020(t, q, "profile-A", "lease-A")
				if q.Command == "release" {
					releases.Add(1)
					_ = json.NewEncoder(conn).Encode(bridgeReply{OK: true})
					return
				}
				if q.Command != "heartbeat" {
					t.Error("unexpected operation")
					return
				}
				heartbeats.Add(1)
				if code == "malformed" {
					_, _ = conn.Write([]byte("invalid-json\n"))
					return
				}
				_ = json.NewEncoder(conn).Encode(bridgeReply{Error: code})
			})
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			out := &synchronizedBuffer{}
			scope := &requestScope{id: "request-heartbeat", ctx: ctx, cancel: cancel, bridge: b, events: &events{out: out}, done: make(chan struct{}), exited: make(chan struct{}), heartbeatPeriod: time.Millisecond}
			scope.add(lease{"profile-A", "lease-A"})
			go scope.heartbeats()
			select {
			case <-ctx.Done():
			case <-time.After(time.Second):
				t.Fatal("hard heartbeat rejection did not cancel active request")
			}
			scope.close()
			if heartbeats.Load() != 1 || releases.Load() != 1 || !strings.Contains(out.String(), "lease_heartbeat_failed") {
				t.Fatal("hard heartbeat failure was retried or silently accepted")
			}
		})
	}
}

func TestHeartbeat1020SlowValidReplyRetainsFullBudget(t *testing.T) {
	var calls atomic.Int32
	b := heartbeatTestBridge1020(t, func(conn net.Conn, q bridgeRequest) {
		assertHeartbeatTuple1020(t, q, "profile-A", "lease-A")
		calls.Add(1)
		time.Sleep(90 * time.Millisecond)
		_ = json.NewEncoder(conn).Encode(bridgeReply{OK: true})
	})
	b.exchangeTimeout = 180 * time.Millisecond
	start := time.Now()
	reply, err := b.call(context.Background(), "heartbeat", "request-heartbeat", "profile-A", "lease-A")
	elapsed := time.Since(start)
	if err != nil || !reply.OK || calls.Load() != 1 || elapsed > 230*time.Millisecond {
		t.Fatalf("legal slow heartbeat lost its original wait budget: ok=%v err=%v calls=%d elapsed=%v", reply.OK, err, calls.Load(), elapsed)
	}
}

func TestHeartbeat1020MissingOwnershipDoesNotReplay(t *testing.T) {
	for _, missing := range []string{"run", "key", "request", "profile", "lease"} {
		t.Run(missing, func(t *testing.T) {
			var calls atomic.Int32
			b := heartbeatTestBridge1020(t, func(conn net.Conn, q bridgeRequest) { calls.Add(1) })
			request, profile, lease := "request-heartbeat", "profile-A", "lease-A"
			switch missing {
			case "run":
				b.runID = ""
			case "key":
				b.key = ""
			case "request":
				request = ""
			case "profile":
				profile = ""
			case "lease":
				lease = ""
			}
			_, err := b.call(context.Background(), "heartbeat", request, profile, lease)
			if calls.Load() != 1 || err == nil || err.Error() != "bridge_eof" {
				t.Fatal("incomplete ownership authorized heartbeat replay")
			}
		})
	}
}

func TestHeartbeat1020MaintenanceQueueExpiryCancelsUntilExactCleanup(t *testing.T) {
	entered, unblock := make(chan struct{}, 2), make(chan struct{})
	defer closeHeartbeatGate1020(unblock)
	var blockers sync.WaitGroup
	var heartbeats, releases atomic.Int32
	b := heartbeatTestBridge1020(t, func(conn net.Conn, q bridgeRequest) {
		if q.ProfileID == "blocking" {
			entered <- struct{}{}
			<-unblock
			_ = json.NewEncoder(conn).Encode(bridgeReply{OK: true})
			return
		}
		assertHeartbeatTuple1020(t, q, q.ProfileID, q.LeaseID)
		if q.Command == "heartbeat" {
			heartbeats.Add(1)
		}
		if q.Command == "release" {
			releases.Add(1)
		}
		_ = json.NewEncoder(conn).Encode(bridgeReply{OK: true})
	})
	b.queueTimeout = 90 * time.Millisecond
	b.exchangeTimeout = 500 * time.Millisecond
	for i := 0; i < 2; i++ {
		blockers.Add(1)
		go func() {
			defer blockers.Done()
			_, _ = b.call(context.Background(), "release", "blocking-request", "blocking", "blocking-lease")
		}()
	}
	for i := 0; i < 2; i++ {
		select {
		case <-entered:
		case <-time.After(time.Second):
			t.Fatal("maintenance lanes did not fill")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	out := &synchronizedBuffer{}
	scope := &requestScope{id: "request-heartbeat", ctx: ctx, cancel: cancel, bridge: b, events: &events{out: out}, done: make(chan struct{}), exited: make(chan struct{}), heartbeatPeriod: time.Millisecond}
	scope.add(lease{"profile-A", "lease-A"})
	scope.add(lease{"profile-B", "lease-B"})
	go scope.heartbeats()
	select {
	case <-ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("maintenance queue timeout did not cancel request")
	}
	<-scope.exited
	if heartbeats.Load() != 0 || releases.Load() != 0 {
		t.Fatal("queue expiry sent a heartbeat or prematurely released ownership")
	}
	close(unblock)
	blockers.Wait()
	scope.close()
	if releases.Load() != 2 || strings.Contains(out.String(), "lease_heartbeat_failed") || strings.Contains(out.String(), "lease_release_unknown") {
		t.Fatal("maintenance queue exhaustion did not settle by confirmed exact cleanup")
	}
}

func TestHeartbeat1020BlockedEventOutputCannotDelayCancellationAndCleanup(t *testing.T) {
	var releases atomic.Int32
	b := heartbeatTestBridge1020(t, func(conn net.Conn, q bridgeRequest) {
		assertHeartbeatTuple1020(t, q, q.ProfileID, q.LeaseID)
		if q.Command == "heartbeat" {
			return
		} // Unknown EOF after the host handled the exact tuple.
		if q.Command != "release" {
			t.Error("unexpected operation")
			return
		}
		releases.Add(1)
		_ = json.NewEncoder(conn).Encode(bridgeReply{OK: true})
	})
	b.exchangeTimeout = 90 * time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	output := &events{out: &synchronizedBuffer{}}
	scope := &requestScope{id: "request-heartbeat", ctx: ctx, cancel: cancel, bridge: b, events: output, done: make(chan struct{}), exited: make(chan struct{}), heartbeatPeriod: time.Millisecond}
	scope.add(lease{"profile-A", "lease-A"})
	scope.add(lease{"profile-B", "lease-B"})
	output.mu.Lock()
	locked := true
	defer func() {
		if locked {
			output.mu.Unlock()
		}
	}()
	go scope.heartbeats()
	blocked := false
	select {
	case <-ctx.Done():
	case <-time.After(300 * time.Millisecond):
		blocked = true
	}
	if blocked {
		output.mu.Unlock()
		locked = false
		select {
		case <-scope.exited:
		case <-time.After(time.Second):
			t.Fatal("fixture heartbeat failed to join after output unblocked")
		}
		scope.close()
		t.Fatal("blocked event output prevented current request cancellation")
	}
	<-scope.exited
	cleaned := make(chan struct{})
	go func() { scope.close(); close(cleaned) }()
	select {
	case <-cleaned:
	case <-time.After(300 * time.Millisecond):
		output.mu.Unlock()
		locked = false
		<-cleaned
		t.Fatal("confirmed exact cleanup waited for event output")
	}
	output.mu.Unlock()
	locked = false
	if releases.Load() != 2 {
		t.Fatal("blocked output skipped a failover lease release")
	}
}
