package main

import (
	"path/filepath"
	"testing"
)

func TestDesktopWorkflowReadsFinalAdmissionAndFrozenModel(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "owned")
	if err := ensurePrivateDir(dir); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "workflow.json")
	hub := &Hub{config: Config{WorkflowPreferencesPath: path, WorkflowProfileID: 1}}
	task := &Task{ExecutionPreference: &executionPreference{Model: "gpt-6-sol", ReasoningEffort: "high"}}
	write := func(body string) {
		t.Helper()
		writeDesktopFixture(t, path, []byte(body))
	}
	write(`{"profiles":{"1":{"participating":true,"model":"gpt-6-sol","effort":"high","revision":1}}}`)
	if err := hub.desktopWorkflowAllowed(task); err != nil {
		t.Fatal(err)
	}
	write(`{"profiles":{"1":{"participating":false,"model":"gpt-6-sol","effort":"high","revision":2}}}`)
	if err := hub.desktopWorkflowAllowed(task); err != errDispatchDisabled {
		t.Fatalf("opt-out: %v", err)
	}
	write(`{"profiles":{"1":{"participating":true,"model":"gpt-6-sol","effort":"low","revision":3}}}`)
	if err := hub.desktopWorkflowAllowed(task); err != errDispatchPolicyUnavailable {
		t.Fatalf("model changed: %v", err)
	}
	for _, body := range []string{`{}`, `{"profiles":{"1":{"participating":true,"model":"gpt-6-sol","effort":"high","revision":1,"dispatch_window":{"mode":"onlyWithin","timeZoneIdentifier":"UTC","intervals":[]}}}}`, `{"profiles":{"1":{"participating":true,"model":"gpt-6-sol","effort":"high","revision":1,"dispatch_window":{"mode":"unrestricted","timeZoneIdentifier":"invalid","intervals":[]}}}}`} {
		write(body)
		if hub.desktopWorkflowAllowed(task) == nil {
			t.Fatal("bad/closed policy admitted")
		}
	}
	if (&Hub{}).desktopWorkflowAllowed(task) != nil {
		t.Fatal("legacy Mac defaults changed")
	}
}
