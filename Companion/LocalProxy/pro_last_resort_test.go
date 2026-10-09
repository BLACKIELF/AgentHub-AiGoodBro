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

func TestProLastResortHTTPAdmissionPhases(t *testing.T) {
	for _, tc := range []struct {
		name                           string
		order, lastResort              []string
		credits, desktop, busyOrdinary bool
		admission                      func(string, string) bool
		want                           string
	}{
		{name: "priority_order_first", order: []string{"Pro", "Ordinary"}, lastResort: []string{"Pro"}, admission: func(command, id string) bool { return command == "acquire" }, want: "Ordinary"},
		{name: "ordinary_desktop_before_pro", order: []string{"Pro", "Desktop"}, lastResort: []string{"Pro"}, desktop: true, admission: func(command, id string) bool {
			return command == "acquire" && id == "Pro" || command == "acquire_desktop" && id == "Desktop"
		}, want: "Desktop"},
		{name: "ordinary_quota_falls_back", order: []string{"Pro", "Ordinary"}, lastResort: []string{"Pro"}, admission: func(command, id string) bool { return command == "acquire" && id == "Pro" }, want: "Pro"},
		{name: "ordinary_busy_falls_back", order: []string{"Pro", "Ordinary"}, lastResort: []string{"Pro"}, busyOrdinary: true, admission: func(command, id string) bool { return command == "acquire" }, want: "Pro"},
		{name: "pro_subscription_before_ordinary_credits", order: []string{"Pro", "Ordinary"}, lastResort: []string{"Pro"}, credits: true, admission: func(command, id string) bool {
			return command == "acquire" && id == "Pro" || command == "acquire_credit_primary" && id == "Ordinary"
		}, want: "Pro"},
		{name: "ordinary_secondary_before_pro_primary_credits", order: []string{"Pro", "Ordinary"}, lastResort: []string{"Pro"}, credits: true, admission: func(command, id string) bool {
			return command == "acquire_credit_primary" && id == "Pro" || command == "acquire_credit_secondary" && id == "Ordinary"
		}, want: "Ordinary"},
		{name: "ordinary_desktop_credits_before_pro", order: []string{"Pro", "Desktop"}, lastResort: []string{"Pro"}, credits: true, desktop: true, admission: func(command, id string) bool {
			return command == "acquire_credit_primary" && id == "Pro" || command == "acquire_desktop_credit_primary" && id == "Desktop"
		}, want: "Desktop"},
		{name: "absent_metadata_preserves_priority", order: []string{"Pro", "Ordinary"}, admission: func(command, id string) bool { return command == "acquire" }, want: "Pro"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			b := newFakeBridge(t)
			s := newStartup(t, b)
			b.order = tc.order
			b.lastResortIDs = tc.lastResort
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
					t.Error("mock upstream without owned lease")
				}
				calls.Add(1)
				complete(w, id)
			}))
			defer upstream.Close()
			_, server, _ := startTestRuntime(t, s, upstream.URL)
			response := request(t, s, server.URL, false)
			body := consume(t, response)
			if response.StatusCode != 200 || !strings.Contains(body, "done-"+tc.want) || calls.Load() != 1 {
				t.Fatalf("want=%s status=%d calls=%d body=%s", tc.want, response.StatusCode, calls.Load(), body)
			}
			waitEmpty(t, b)
			if (tc.name == "ordinary_quota_falls_back" || tc.name == "ordinary_busy_falls_back") && firstAdmission.Load() != "Ordinary" {
				t.Fatal("fallback was selected before ordinary admission was attempted")
			}
		})
	}
}

func TestProLastResortMalformedMetadataFailsBeforeAdmission(t *testing.T) {
	for _, tc := range []struct {
		name          string
		order, marked []string
	}{
		{"duplicate", []string{"A", "B"}, []string{"B", "B"}},
		{"unknown", []string{"A", "B"}, []string{"outside"}},
		{"registered_but_not_participating", []string{"A"}, []string{"B"}},
		{"empty_id", []string{"A", "B"}, []string{""}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			b := newFakeBridge(t)
			s := newStartup(t, b)
			b.order = tc.order
			b.lastResortIDs = tc.marked
			var calls atomic.Int32
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls.Add(1); complete(w, "unexpected") }))
			defer upstream.Close()
			_, server, _ := startTestRuntime(t, s, upstream.URL)
			response := request(t, s, server.URL, false)
			_ = consume(t, response)
			if response.StatusCode != 503 || calls.Load() != 0 || bridgeCommandCount(b, "acquire") != 0 {
				t.Fatalf("malformed order admitted: status=%d calls=%d", response.StatusCode, calls.Load())
			}
		})
	}
}

func TestProLastResortRequestSnapshotFrozenAcrossPicks(t *testing.T) {
	b := newFakeBridge(t)
	b.order = []string{"A", "B", "C"}
	b.lastResortIDs = []string{"C"}
	sel, scope, ctx, closeScope := selectorFixture(t, b, time.Second, time.Millisecond)
	sel.order = []string{"A", "B", "C"}
	candidates := append(selectorCandidates(), &auth.Auth{ID: "C", Attributes: map[string]string{}, Metadata: map[string]any{}})
	first, err := sel.Pick(ctx, "", "", executor.Options{}, candidates)
	if err != nil || first.ID != "A" {
		t.Fatalf("initial Pick: %v %v", first, err)
	}
	b.mu.Lock()
	b.lastResortIDs = []string{"B"}
	b.mu.Unlock()
	second, err := sel.Pick(ctx, "", "", executor.Options{}, candidates)
	if err != nil || second.ID != "B" || !b.hasLease("A") || !reflect.DeepEqual(scope.lastResortIDs, []string{"C"}) || bridgeCommandCount(b, "order") != 1 {
		t.Fatalf("snapshot changed or held lease disturbed: second=%v err=%v snapshot=%v", second, err, scope.lastResortIDs)
	}
	closeScope()
	waitEmpty(t, b)
	next, nextScope, nextCtx, _ := selectorFixture(t, b, time.Second, time.Millisecond)
	next.order = []string{"A", "B", "C"}
	_, err = next.Pick(nextCtx, "", "", executor.Options{}, candidates)
	if err != nil || !reflect.DeepEqual(nextScope.lastResortIDs, []string{"B"}) || bridgeCommandCount(b, "order") != 2 {
		t.Fatalf("new request did not capture new metadata: %v %v", nextScope.lastResortIDs, err)
	}
}

func TestProLastResortControlMetadataNeverAuthorizesReplay(t *testing.T) {
	var calls atomic.Int32
	b := controlTestBridge(t, func(conn net.Conn, q bridgeRequest) {
		calls.Add(1)
		_ = json.NewEncoder(conn).Encode(bridgeReply{Error: "control_busy", LastResortIDs: []string{"A"}})
	})
	_, err := b.call(context.Background(), "acquire", "request", "A", "")
	if err == nil || err.Error() != "bridge_invalid" || calls.Load() != 1 {
		t.Fatalf("busy metadata replayed: err=%v calls=%d", err, calls.Load())
	}
}

func TestProLastResortControlMalformedJSONTypeFailsClosed(t *testing.T) {
	for _, value := range []any{"A", []any{"A", 1}} {
		t.Run(fmt.Sprintf("%T", value), func(t *testing.T) {
			b := controlTestBridge(t, func(conn net.Conn, q bridgeRequest) {
				_ = json.NewEncoder(conn).Encode(map[string]any{"ok": true, "order": []string{"A"}, "lastResortIDs": value})
			})
			reply, err := b.call(context.Background(), "order", "request", "A", "")
			if err == nil || err.Error() != "bridge_decode" || reply.OK {
				t.Fatalf("invalid metadata type accepted: %+v %v", reply, err)
			}
		})
	}
}

func TestProLastResortReconciliationMetadataCannotAuthorizeResolution(t *testing.T) {
	b := newFakeBridge(t)
	b.corruptCommand = "acquire"
	b.beforeReply = func(q bridgeRequest, reply bridgeReply) bridgeReply {
		if q.Command == "acquire_resolve" {
			reply.LastResortIDs = []string{"A"}
		}
		return reply
	}
	sel, scope, ctx, _ := selectorFixture(t, b, time.Second, time.Millisecond)
	_, err := sel.Pick(ctx, "", "", executor.Options{}, selectorCandidates())
	output := scope.events.out.(*synchronizedBuffer).String()
	if err == nil || scope.ctx.Err() == nil || bridgeCommandCount(b, "acquire") != 1 || !strings.Contains(output, "lease_acquire_unknown") || strings.Contains(output, "lease_acquire_reconciled") {
		t.Fatalf("invalid reconciliation accepted or replayed: err=%v output=%s", err, output)
	}
}
