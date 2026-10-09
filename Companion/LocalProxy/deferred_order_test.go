package main

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/executor"
	"net"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestDeferredOrderHTTPGroupsAndPhases(t *testing.T) {
	for _, tc := range []struct {
		name                           string
		order, deferred, forced        []string
		credits, desktop, busyOrdinary bool
		admission                      func(string, string) bool
		want                           string
	}{
		{name: "priority_source_order_cannot_cross_groups", order: []string{"Forced", "Manual", "Ordinary"}, deferred: []string{"Manual"}, forced: []string{"Forced"}, admission: func(command, id string) bool { return command == "acquire" }, want: "Ordinary"},
		{name: "manual_before_forced", order: []string{"Forced", "Manual"}, deferred: []string{"Manual"}, forced: []string{"Forced"}, admission: func(command, id string) bool { return command == "acquire" }, want: "Manual"},
		{name: "manual_group_keeps_source_order", order: []string{"Forced", "ManualB", "ManualA"}, deferred: []string{"ManualA", "ManualB"}, forced: []string{"Forced"}, admission: func(command, id string) bool { return command == "acquire" }, want: "ManualB"},
		{name: "manual_desktop_before_nondesktop_forced", order: []string{"Forced", "Desktop"}, deferred: []string{"Desktop"}, forced: []string{"Forced"}, desktop: true, admission: func(command, id string) bool {
			return command == "acquire" && id == "Forced" || command == "acquire_desktop" && id == "Desktop"
		}, want: "Desktop"},
		{name: "ordinary_quota_then_manual", order: []string{"Manual", "Ordinary"}, deferred: []string{"Manual"}, admission: func(command, id string) bool { return command == "acquire" && id == "Manual" }, want: "Manual"},
		{name: "ordinary_busy_then_manual", order: []string{"Manual", "Ordinary"}, deferred: []string{"Manual"}, busyOrdinary: true, admission: func(command, id string) bool { return command == "acquire" }, want: "Manual"},
		{name: "ordinary_secondary_credits_before_manual_primary", order: []string{"Manual", "Ordinary"}, deferred: []string{"Manual"}, credits: true, admission: func(command, id string) bool {
			return command == "acquire_credit_secondary" && id == "Ordinary" || command == "acquire_credit_primary" && id == "Manual"
		}, want: "Ordinary"},
		{name: "manual_desktop_credits_before_forced_primary", order: []string{"Forced", "Desktop"}, deferred: []string{"Desktop"}, forced: []string{"Forced"}, credits: true, desktop: true, admission: func(command, id string) bool {
			return command == "acquire_credit_primary" && id == "Forced" || command == "acquire_desktop_credit_primary" && id == "Desktop"
		}, want: "Desktop"},
		{name: "forced_subscription_before_ordinary_paid", order: []string{"Forced", "Manual", "Ordinary"}, deferred: []string{"Manual"}, forced: []string{"Forced"}, credits: true, admission: func(command, id string) bool {
			return command == "acquire" && id == "Forced" || command == "acquire_credit_primary" && id == "Ordinary"
		}, want: "Forced"},
		{name: "absent_deferred_preserves_forced_last", order: []string{"Forced", "Ordinary"}, forced: []string{"Forced"}, admission: func(command, id string) bool { return command == "acquire" }, want: "Ordinary"},
		{name: "absent_all_metadata_preserves_source_order", order: []string{"Manual", "Ordinary"}, admission: func(command, id string) bool { return command == "acquire" }, want: "Manual"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			b := newFakeBridge(t)
			s := newStartup(t, b)
			b.order = tc.order
			b.deferredIDs = tc.deferred
			b.lastResortIDs = tc.forced
			b.creditFallback = tc.credits
			b.admission = tc.admission
			b.busy["Ordinary"] = tc.busyOrdinary
			var firstAdmission atomic.Value
			var firstAdmissionOnce sync.Once
			b.beforeReply = func(q bridgeRequest, reply bridgeReply) bridgeReply {
				if strings.HasPrefix(q.Command, "acquire") {
					firstAdmissionOnce.Do(func() { firstAdmission.Store(q.ProfileID) })
				}
				return reply
			}
			s.DesktopFallback = tc.desktop
			s.Accounts = nil
			for _, id := range tc.order {
				s.Accounts = append(s.Accounts, struct {
					ID string `json:"id"`
				}{id})
			}
			var calls atomic.Int32
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				id := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer fixture-")
				if !b.hasLease(id) {
					t.Error("mock upstream without lease")
				}
				calls.Add(1)
				complete(w, id)
			}))
			defer upstream.Close()
			_, server, _ := startTestRuntime(t, s, upstream.URL)
			response := request(t, s, server.URL, false)
			body := consume(t, response)
			if response.StatusCode != 200 || calls.Load() != 1 || !strings.Contains(body, "done-"+tc.want) {
				t.Fatalf("want=%s status=%d calls=%d body=%s", tc.want, response.StatusCode, calls.Load(), body)
			}
			waitEmpty(t, b)
			if (tc.name == "ordinary_quota_then_manual" || tc.name == "ordinary_busy_then_manual") && firstAdmission.Load() != "Ordinary" {
				t.Fatal("manual-last selected before ordinary admission attempt")
			}
		})
	}
}

func TestDeferredOrderMalformedMetadataFailsBeforeAdmission(t *testing.T) {
	for _, tc := range []struct {
		name                    string
		order, deferred, forced []string
	}{
		{"duplicate", []string{"A", "B"}, []string{"B", "B"}, nil},
		{"unknown", []string{"A", "B"}, []string{"outside"}, nil},
		{"registered_not_participating", []string{"A"}, []string{"B"}, nil},
		{"overlap_with_forced", []string{"A", "B"}, []string{"B"}, []string{"B"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			b := newFakeBridge(t)
			s := newStartup(t, b)
			b.order = tc.order
			b.deferredIDs = tc.deferred
			b.lastResortIDs = tc.forced
			var calls atomic.Int32
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls.Add(1); complete(w, "unexpected") }))
			defer upstream.Close()
			_, server, _ := startTestRuntime(t, s, upstream.URL)
			response := request(t, s, server.URL, false)
			_ = consume(t, response)
			if response.StatusCode != 503 || calls.Load() != 0 || bridgeCommandCount(b, "acquire") != 0 {
				t.Fatalf("malformed groups reached admission: status=%d calls=%d", response.StatusCode, calls.Load())
			}
		})
	}
}

func TestDeferredOrderRequestSnapshotAndHeldLeaseRemainFrozen(t *testing.T) {
	b := newFakeBridge(t)
	b.order = []string{"A", "B", "C", "D"}
	b.deferredIDs = []string{"C"}
	b.lastResortIDs = []string{"D"}
	sel, scope, ctx, closeScope := selectorFixture(t, b, time.Second, time.Millisecond)
	sel.order = b.order
	candidates := append(selectorCandidates(), &auth.Auth{ID: "C", Attributes: map[string]string{}, Metadata: map[string]any{}}, &auth.Auth{ID: "D", Attributes: map[string]string{}, Metadata: map[string]any{}})
	first, err := sel.Pick(ctx, "", "", executor.Options{}, candidates)
	if err != nil || first.ID != "A" {
		t.Fatalf("initial Pick: %v %v", first, err)
	}
	b.mu.Lock()
	b.deferredIDs = []string{"A", "B"}
	b.mu.Unlock()
	second, err := sel.Pick(ctx, "", "", executor.Options{}, candidates)
	if err != nil || second.ID != "B" || !b.hasLease("A") || !reflect.DeepEqual(scope.deferredIDs, []string{"C"}) || !reflect.DeepEqual(scope.lastResortIDs, []string{"D"}) || bridgeCommandCount(b, "order") != 1 {
		t.Fatalf("old scope changed: second=%v err=%v deferred=%v forced=%v", second, err, scope.deferredIDs, scope.lastResortIDs)
	}
	closeScope()
	waitEmpty(t, b)
	next, nextScope, nextCtx, _ := selectorFixture(t, b, time.Second, time.Millisecond)
	next.order = []string{"A", "B", "C", "D"}
	chosen, err := next.Pick(nextCtx, "", "", executor.Options{}, candidates)
	if err != nil || chosen.ID != "C" || !reflect.DeepEqual(nextScope.deferredIDs, []string{"A", "B"}) || bridgeCommandCount(b, "order") != 2 {
		t.Fatalf("new scope ignored changed option: %v %v deferred=%v", chosen, err, nextScope.deferredIDs)
	}
}

func TestDeferredOrderDisabledCreditsNeverReachPaidAdmission(t *testing.T) {
	b := newFakeBridge(t)
	s := newStartup(t, b)
	b.deferredIDs = []string{"A"}
	b.lastResortIDs = []string{"B"}
	b.admission = func(command, id string) bool { return strings.Contains(command, "credit") }
	var calls atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls.Add(1); complete(w, "unexpected") }))
	defer upstream.Close()
	_, server, _ := startTestRuntime(t, s, upstream.URL)
	response := request(t, s, server.URL, false)
	_ = consume(t, response)
	if response.StatusCode == 200 || calls.Load() != 0 {
		t.Fatal("disabled credits reached upstream")
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, command := range b.commands {
		if strings.Contains(command, "credit") {
			t.Fatalf("paid command without opt-in: %s", command)
		}
	}
}

func TestDeferredOrderControlMetadataNeverAuthorizesReplay(t *testing.T) {
	var calls atomic.Int32
	b := controlTestBridge(t, func(conn net.Conn, q bridgeRequest) {
		calls.Add(1)
		_ = json.NewEncoder(conn).Encode(bridgeReply{Error: "control_busy", DeferredIDs: []string{"A"}})
	})
	_, err := b.call(context.Background(), "acquire", "request", "A", "")
	if err == nil || err.Error() != "bridge_invalid" || calls.Load() != 1 {
		t.Fatalf("busy deferred metadata replayed: err=%v calls=%d", err, calls.Load())
	}
}

func TestDeferredOrderReconciliationMetadataFailsClosed(t *testing.T) {
	b := newFakeBridge(t)
	b.corruptCommand = "acquire"
	b.beforeReply = func(q bridgeRequest, reply bridgeReply) bridgeReply {
		if q.Command == "acquire_resolve" {
			reply.DeferredIDs = []string{"A"}
		}
		return reply
	}
	sel, scope, ctx, _ := selectorFixture(t, b, time.Second, time.Millisecond)
	_, err := sel.Pick(ctx, "", "", executor.Options{}, selectorCandidates())
	output := scope.events.out.(*synchronizedBuffer).String()
	if err == nil || scope.ctx.Err() == nil || bridgeCommandCount(b, "acquire") != 1 || !strings.Contains(output, "lease_acquire_unknown") || strings.Contains(output, "lease_acquire_reconciled") {
		t.Fatalf("invalid resolver payload accepted: err=%v output=%s", err, output)
	}
}

func TestDeferredOrderMalformedJSONTypeFailsClosed(t *testing.T) {
	for _, value := range []any{"A", []any{"A", 1}} {
		t.Run(fmt.Sprintf("%T", value), func(t *testing.T) {
			b := controlTestBridge(t, func(conn net.Conn, q bridgeRequest) {
				_ = json.NewEncoder(conn).Encode(map[string]any{"ok": true, "order": []string{"A"}, "deferredIDs": value})
			})
			reply, err := b.call(context.Background(), "order", "request", "A", "")
			if err == nil || err.Error() != "bridge_decode" || reply.OK {
				t.Fatalf("invalid deferred metadata type accepted: %+v %v", reply, err)
			}
		})
	}
}
