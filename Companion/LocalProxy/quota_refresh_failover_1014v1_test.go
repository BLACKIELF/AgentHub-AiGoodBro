package main

import (
	"testing"
	"time"

	executor "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/executor"
)

func TestSelectorQuotaRefreshRefusalTriesHealthyPeer(t *testing.T) {
	for _, delay := range []time.Duration{0, 100 * time.Millisecond} {
		t.Run(delay.String(), func(t *testing.T) {
			b := newFakeBridge(t)
			b.failures = map[string]string{"acquire\x00A": "quota_unknown"}
			b.beforeReply = func(q bridgeRequest, reply bridgeReply) bridgeReply {
				if q.Command == "acquire" && q.ProfileID == "A" { time.Sleep(delay) }
				return reply
			}
			sel, _, ctx, closeScope := selectorFixture(t, b, time.Second, time.Millisecond)
			defer closeScope()
			selected, err := sel.Pick(ctx, "", "", executor.Options{}, selectorCandidates())
			if err != nil || selected == nil || selected.ID != "B" {
				t.Fatalf("first quota refresh refusal blocked healthy peer: selected=%v error=%v", selected, err)
			}
			if bridgeCommandCount(b, "acquire") != 2 { t.Fatal("selector did not try each candidate once") }
		})
	}
}
