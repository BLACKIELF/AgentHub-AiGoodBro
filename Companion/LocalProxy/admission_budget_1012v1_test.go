package main

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	auth "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
	executor "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/executor"
)

// Deadline is consulted when Pick enters its bridge admission context. The
// channel lets fixtures hold all real bridge slots across that exact boundary.
type admissionQueueContext1012 struct {
	context.Context
	entered chan struct{}
	once    sync.Once
}

func (c *admissionQueueContext1012) Deadline() (time.Time, bool) {
	c.once.Do(func() { close(c.entered) })
	return c.Context.Deadline()
}

type admissionPickResult1012 struct {
	account *auth.Auth
	err     error
}

func admissionFixture1012(t *testing.T, b *fakeBridge, budget time.Duration) (*selector, *requestScope, context.Context, func(), <-chan struct{}) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	entered := make(chan struct{})
	scope := &requestScope{
		id: "request-admission-1012", cancel: cancel,
		ctx:    &admissionQueueContext1012{Context: ctx, entered: entered},
		bridge: &bridge{socket: b.socket}, events: &events{out: &synchronizedBuffer{}},
		responseHeader: make(map[string][]string), done: make(chan struct{}), exited: make(chan struct{}),
	}
	sel := &selector{order: []string{"A", "B"}, bridge: scope.bridge, events: scope.events, waitFor: budget, pollEvery: time.Millisecond}
	// Capture the real host order first so capacity pressure below targets the
	// acquire queue, rather than the independent order RPC before its budget.
	reply, err := scope.bridge.call(context.Background(), "order", scope.id, "A", "")
	if err != nil || !reply.OK {
		t.Fatalf("fixture order: %+v, %v", reply, err)
	}
	scope.orderOnce.Do(func() {
		scope.order = reply.Order
		scope.deferredIDs = reply.DeferredIDs
		scope.lastResortIDs = reply.LastResortIDs
		scope.creditFallback = reply.CreditFallback
		scope.orderQueried = true
	})
	go scope.heartbeats()
	var closeOnce sync.Once
	closeScope := func() { closeOnce.Do(scope.close) }
	t.Cleanup(closeScope)
	return sel, scope, context.WithValue(context.Background(), scopeKey{}, scope), closeScope, entered
}

func admissionAccountID1012(account *auth.Auth) string {
	if account == nil {
		return ""
	}
	return account.ID
}

func holdAdmissionCapacity1012(t *testing.T, b *fakeBridge, control *bridge) func() {
	t.Helper()
	if cap(control.normal) != 6 {
		t.Fatalf("fixture expected the unchanged 6-slot admission lane, got %d", cap(control.normal))
	}
	entered, unblock := make(chan struct{}, 6), make(chan struct{})
	var releaseOnce sync.Once
	release := func() { releaseOnce.Do(func() { close(unblock) }) }
	b.mu.Lock()
	b.beforeReply = func(q bridgeRequest, reply bridgeReply) bridgeReply {
		if q.Command == "order" && strings.HasPrefix(q.RequestID, "capacity-1012-") {
			entered <- struct{}{}
			<-unblock
		}
		return reply
	}
	b.mu.Unlock()
	var occupants sync.WaitGroup
	for i := 0; i < 6; i++ {
		occupants.Add(1)
		go func(i int) {
			defer occupants.Done()
			_, _ = control.call(context.Background(), "order", fmt.Sprintf("capacity-1012-%d", i), "A", "")
		}(i)
	}
	t.Cleanup(func() { release(); occupants.Wait() })
	for i := 0; i < 6; i++ {
		awaitBusySignal1012(t, entered, "all original admission slots did not enter the fixture gate")
	}
	return release
}

func pickAdmission1012(sel *selector, ctx context.Context) <-chan admissionPickResult1012 {
	result := make(chan admissionPickResult1012, 1)
	go func() {
		account, err := sel.Pick(ctx, "", "", executor.Options{}, selectorCandidates())
		result <- admissionPickResult1012{account, err}
	}()
	return result
}

func awaitAdmissionPick1012(t *testing.T, result <-chan admissionPickResult1012) admissionPickResult1012 {
	t.Helper()
	select {
	case got := <-result:
		return got
	case <-time.After(3 * time.Second):
		t.Fatal("bounded admission did not finish")
		return admissionPickResult1012{}
	}
}

func TestSelectorAdmissionQueueBudgetPreventsLateSend1012(t *testing.T) {
	b := newFakeBridge(t)
	const budget = 80 * time.Millisecond
	sel, scope, ctx, closeScope, queued := admissionFixture1012(t, b, budget)
	release := holdAdmissionCapacity1012(t, b, scope.bridge)
	result := pickAdmission1012(sel, ctx)
	awaitBusySignal1012(t, queued, "Pick did not enter the occupied admission lane")
	// The gate opens only after the budget, leaving plenty of bridge queue time.
	timer := time.NewTimer(2 * budget)
	<-timer.C
	release()
	got := awaitAdmissionPick1012(t, result)
	defer closeScope()
	attempts := bridgeCommandCount(b, "acquire")
	if attempts != 0 {
		t.Errorf("expired pre-send budget sent %d acquire RPCs, want 0", attempts)
	}
	if ae, ok := got.err.(*auth.Error); !ok || ae.Code != "account_busy" || got.account != nil || scope.responseHeader.Get("Retry-After") != "1" {
		t.Errorf("expired queue budget result: account=%q error=%v retry=%q", admissionAccountID1012(got.account), got.err, scope.responseHeader.Get("Retry-After"))
	}
	if bridgeCommandCount(b, "acquire_resolve") != 0 {
		t.Error("a command never sent must not create ambiguous lease reconciliation")
	}
}

func TestSelectorAdmissionQueueWithinBudgetSucceeds1012(t *testing.T) {
	b := newFakeBridge(t)
	sel, scope, ctx, closeScope, queued := admissionFixture1012(t, b, 2*time.Second)
	release := holdAdmissionCapacity1012(t, b, scope.bridge)
	result := pickAdmission1012(sel, ctx)
	awaitBusySignal1012(t, queued, "Pick did not reach admission while capacity was full")
	release()
	got := awaitAdmissionPick1012(t, result)
	if got.err != nil || got.account == nil || got.account.ID != "A" || bridgeCommandCount(b, "acquire") != 1 {
		t.Fatalf("capacity released inside budget did not admit once: %q, %v", admissionAccountID1012(got.account), got.err)
	}
	closeScope()
	waitEmpty(t, b)
}

func TestSelectorAdmissionQueueCancellationPreventsSend1012(t *testing.T) {
	for _, ending := range []string{"caller", "scope"} {
		t.Run(ending, func(t *testing.T) {
			b := newFakeBridge(t)
			sel, scope, ctx, closeScope, queued := admissionFixture1012(t, b, 2*time.Second)
			release := holdAdmissionCapacity1012(t, b, scope.bridge)
			caller, cancelCaller := context.WithCancel(ctx)
			defer cancelCaller()
			result := pickAdmission1012(sel, caller)
			awaitBusySignal1012(t, queued, "Pick did not enter its pre-send queue")
			if ending == "caller" {
				cancelCaller()
			} else {
				scope.cancel()
			}
			var got admissionPickResult1012
			select {
			case got = <-result:
			case <-time.After(300 * time.Millisecond):
				t.Error("cancelled pre-send admission still waited for bridge capacity")
				release()
				got = awaitAdmissionPick1012(t, result)
			}
			release()
			if !errors.Is(got.err, context.Canceled) || got.account != nil || bridgeCommandCount(b, "acquire") != 0 {
				t.Errorf("cancelled queue sent an acquire: account=%q error=%v attempts=%d", admissionAccountID1012(got.account), got.err, bridgeCommandCount(b, "acquire"))
			}
			if bridgeCommandCount(b, "acquire_resolve") != 0 || b.count() != 0 {
				t.Error("cancelled pre-send queue created lease ownership or uncertainty")
			}
			closeScope()
		})
	}
}

func TestSelectorAdmissionIssuedLateReplyKeepsLeaseSafety1012(t *testing.T) {
	for _, replyMode := range []string{"success", "success_caller_cancel", "unknown"} {
		t.Run(replyMode, func(t *testing.T) {
			b := newFakeBridge(t)
			const budget = 80 * time.Millisecond
			sel, scope, ctx, closeScope, _ := admissionFixture1012(t, b, budget)
			issued, unblock := make(chan struct{}), make(chan struct{})
			var issueOnce, releaseOnce sync.Once
			release := func() { releaseOnce.Do(func() { close(unblock) }) }
			defer release()
			b.beforeReply = func(q bridgeRequest, reply bridgeReply) bridgeReply {
				if q.Command == "acquire" {
					issueOnce.Do(func() { close(issued) })
					<-unblock
				}
				return reply
			}
			if replyMode == "unknown" {
				b.dropCommand = "acquire"
			}
			caller, cancelCaller := context.WithCancel(ctx)
			defer cancelCaller()
			result := pickAdmission1012(sel, caller)
			awaitBusySignal1012(t, issued, "acquire never reached the host fixture")
			if replyMode == "success_caller_cancel" {
				cancelCaller()
			}
			timer := time.NewTimer(2 * budget)
			<-timer.C
			select {
			case got := <-result:
				t.Fatalf("already issued acquire abandoned before reply: %q, %v", admissionAccountID1012(got.account), got.err)
			default:
			}
			release()
			got := awaitAdmissionPick1012(t, result)
			if replyMode == "success" {
				if got.err != nil || got.account == nil || got.account.ID != "A" || !b.hasLease("A") || bridgeCommandCount(b, "acquire_resolve") != 0 {
					t.Fatalf("late success lost its tracked lease: %q, %v", admissionAccountID1012(got.account), got.err)
				}
			} else if replyMode == "success_caller_cancel" {
				if !errors.Is(got.err, context.Canceled) || got.account != nil || !scope.profileUsed("A") || !b.hasLease("A") || bridgeCommandCount(b, "acquire_resolve") != 0 {
					t.Fatalf("cancelled late success was not retained for cleanup: %q, %v", admissionAccountID1012(got.account), got.err)
				}
			} else if ae, ok := got.err.(*auth.Error); !ok || ae.Code != "account_busy" || got.account != nil || bridgeCommandCount(b, "acquire_resolve") != 1 || b.count() != 0 || scope.responseHeader.Get("Retry-After") != "1" {
				t.Fatalf("late unknown admission was not reconciled: %q, %v", admissionAccountID1012(got.account), got.err)
			}
			if bridgeCommandCount(b, "acquire") != 1 {
				t.Error("late admission was replayed against another account")
			}
			closeScope()
			waitEmpty(t, b)
			if replyMode != "unknown" && bridgeCommandCount(b, "release") != 1 {
				t.Error("late success was not released exactly once")
			}
		})
	}
}
