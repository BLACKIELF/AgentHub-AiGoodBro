package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type desktopBindingFixture struct {
	hub        *Hub
	task       *Task
	root, home string
	manager    map[string]any
	binding    map[string]any
}

func newDesktopBindingFixture(t *testing.T) desktopBindingFixture {
	t.Helper()
	root := filepath.Join(t.TempDir(), "owned")
	home := filepath.Join(root, "home")
	if ensurePrivateDir(root) != nil || ensurePrivateDir(home) != nil {
		t.Fatal("private fixture")
	}
	hash := sha256.Sum256([]byte("synthetic-auth"))
	identity := sha256.Sum256([]byte("fixture@example.invalid\x00synthetic-account"))
	now := time.Now().Unix() * 1000
	binding := map[string]any{"authSha256": hex.EncodeToString(hash[:]), "credentialExpiresAtMs": now + 600000, "quotaObservedAtMs": now, "identityHash": hex.EncodeToString(identity[:]), "workflowRevision": uint64(1)}
	profile := map[string]any{"name": "account-1", "codexHomePath": home, "isSystemProfile": false, "windowsBinding": binding, "automaticSwitchParticipation": true, "executionPreference": map[string]any{"model": "gpt-6-sol", "reasoningEffort": "high", "serviceTier": "default", "subagentMode": "standard"}, "lastSnapshot": map[string]any{"email": "fixture@example.invalid", "accountID": "synthetic-account", "planType": "plus", "quotaReadSucceeded": true, "fetchedAt": float64(now)/1000 - 978307200, "fiveHour": map[string]any{"usedPercent": 1, "resetsAt": float64(now)/1000 - 978307200 + 3600}, "sevenDay": map[string]any{"usedPercent": 1, "resetsAt": float64(now)/1000 - 978307200 + 604800}}}
	f := desktopBindingFixture{root: root, home: home, manager: map[string]any{"profiles": []any{profile}}, binding: binding}
	f.hub = &Hub{config: Config{WorkflowPreferencesPath: filepath.Join(root, "workflow.json"), WorkflowCatalogPath: filepath.Join(root, "settings.json"), WorkflowProfileID: 1, ApprovalQuotaMaxAgeSeconds: 60, Accounts: []AccountConfig{{Alias: "account-1", Home: home}}}, managerSnapshotPath: filepath.Join(root, "manager.json")}
	f.task = &Task{ID: "fixture-task", Agent: "codex", AccountAlias: "account-1", ExecutionPreference: &executionPreference{Model: "gpt-6-sol", ReasoningEffort: "high"}}
	writeDesktopFixture(t, filepath.Join(home, "auth.json"), []byte("synthetic-auth"))
	f.workflow(t, true, 1)
	f.catalog(t, home, "codex")
	f.saveManager(t)
	return f
}
func writeDesktopFixture(t *testing.T, path string, body []byte) {
	t.Helper()
	if err := os.WriteFile(path, body, 0600); err != nil {
		t.Fatal(err)
	}
}
func (f desktopBindingFixture) json(t *testing.T, path string, v any) {
	t.Helper()
	b, e := json.Marshal(v)
	if e != nil {
		t.Fatal(e)
	}
	writeDesktopFixture(t, path, b)
}
func (f desktopBindingFixture) saveManager(t *testing.T) {
	f.json(t, f.hub.managerSnapshotPath, f.manager)
}
func (f desktopBindingFixture) workflow(t *testing.T, on bool, revision uint64) {
	f.json(t, f.hub.config.WorkflowPreferencesPath, map[string]any{"profiles": map[string]any{"1": map[string]any{"participating": on, "model": "gpt-6-sol", "effort": "high", "revision": revision}}})
}
func (f desktopBindingFixture) catalog(t *testing.T, home, kind string) {
	f.json(t, f.hub.config.WorkflowCatalogPath, map[string]any{"profiles": map[string]any{"next_id": 2, "entries": []any{map[string]any{"id": 1, "kind": kind, "root": home}}}})
}
func (f desktopBindingFixture) approve(t *testing.T) {
	t.Helper()
	if e := f.hub.freezeDesktopTask(f.task); e != nil {
		t.Fatal(e)
	}
	if e := f.hub.approveDesktopTask(f.task); e != nil {
		t.Fatal(e)
	}
}

func TestDesktopWorkflowBindingFinalInputs(t *testing.T) {
	f := newDesktopBindingFixture(t)
	f.approve(t)
	release, err := f.hub.lockDesktopSpawn(f.task)
	if err != nil {
		t.Fatal(err)
	}
	release()
	dto, _ := json.Marshal(f.task.dto())
	if strings.Contains(string(dto), "windows") || strings.Contains(string(dto), f.binding["authSha256"].(string)) || strings.Contains(string(dto), f.binding["identityHash"].(string)) {
		t.Fatal("native binding leaked to DTO")
	}
	old := taskActionHash(f.task)
	f.task.DesktopBinding.WorkflowRevision++
	if taskActionHash(f.task) == old {
		t.Fatal("approval fingerprint omitted binding")
	}
}

func TestDesktopWorkflowBindingNativeIdentityVector(t *testing.T) {
	f := newDesktopBindingFixture(t)
	// Fixed AccountIdentity::identity_hash vector: normalized email, NUL, ID.
	if f.binding["identityHash"] != "caa23099cb86f29450e1d34c2265c9829143b02b1f798dd779cc23178b1b119e" {
		t.Fatal("native identity vector drift")
	}
	f.approve(t)
	f.manager["profiles"].([]any)[0].(map[string]any)["lastSnapshot"].(map[string]any)["accountID"] = "other-workspace"
	f.saveManager(t)
	if release, err := f.hub.lockDesktopSpawn(f.task); err == nil {
		release()
		t.Fatal("same email different workspace admitted")
	}
}

func TestDesktopWorkflowBindingFinalQuotaRechecked(t *testing.T) {
	for _, change := range []string{"five used", "seven used", "reset passed", "quota failed"} {
		t.Run(change, func(t *testing.T) {
			f := newDesktopBindingFixture(t)
			f.approve(t)
			snapshot := f.manager["profiles"].([]any)[0].(map[string]any)["lastSnapshot"].(map[string]any)
			switch change {
			case "five used":
				snapshot["fiveHour"].(map[string]any)["usedPercent"] = 100
			case "seven used":
				snapshot["sevenDay"].(map[string]any)["usedPercent"] = 100
			case "reset passed":
				snapshot["fiveHour"].(map[string]any)["resetsAt"] = float64(time.Now().Unix()-1) - 978307200
			case "quota failed":
				snapshot["quotaReadSucceeded"] = false
			}
			f.saveManager(t) // All approval binding fields remain exactly unchanged.
			if release, err := f.hub.lockDesktopSpawn(f.task); err == nil {
				release()
				t.Fatal("invalid final quota admitted")
			}
		})
	}
}

func TestDesktopWorkflowBindingRejectsChangedAdmission(t *testing.T) {
	cases := map[string]func(*testing.T, desktopBindingFixture){
		"auth replacement": func(t *testing.T, f desktopBindingFixture) {
			writeDesktopFixture(t, filepath.Join(f.home, "auth.json"), []byte("changed"))
		},
		"root remap": func(t *testing.T, f desktopBindingFixture) {
			other := filepath.Join(f.root, "other")
			if ensurePrivateDir(other) != nil {
				t.Fatal("mkdir")
			}
			f.catalog(t, other, "codex")
		},
		"provider changed": func(t *testing.T, f desktopBindingFixture) { f.catalog(t, f.home, "claude") },
		"opt out":          func(t *testing.T, f desktopBindingFixture) { f.workflow(t, false, 2) },
		"off on revision": func(t *testing.T, f desktopBindingFixture) {
			f.workflow(t, true, 3)
			f.binding["workflowRevision"] = uint64(3)
			f.saveManager(t)
		},
		"stale quota": func(t *testing.T, f desktopBindingFixture) {
			f.binding["quotaObservedAtMs"] = time.Now().UnixMilli() - 45001
			f.saveManager(t)
		},
		"future quota": func(t *testing.T, f desktopBindingFixture) {
			f.binding["quotaObservedAtMs"] = time.Now().UnixMilli() + 60000
			f.saveManager(t)
		},
		"expired auth": func(t *testing.T, f desktopBindingFixture) {
			f.binding["credentialExpiresAtMs"] = time.Now().UnixMilli() + 29000
			f.saveManager(t)
		},
		"manager rebind": func(t *testing.T, f desktopBindingFixture) {
			f.binding["identityHash"] = strings.Repeat("a", 64)
			f.saveManager(t)
		},
		"manager quota rebind": func(t *testing.T, f desktopBindingFixture) {
			f.binding["quotaObservedAtMs"] = time.Now().UnixMilli() - 1000
			f.saveManager(t)
		},
		"ambiguous catalog": func(t *testing.T, f desktopBindingFixture) {
			f.json(t, f.hub.config.WorkflowCatalogPath, map[string]any{"profiles": map[string]any{"entries": []any{map[string]any{"id": 1, "root": f.home}, map[string]any{"id": 1, "root": f.home}}}})
		},
		"missing manager binding": func(t *testing.T, f desktopBindingFixture) {
			delete(f.manager["profiles"].([]any)[0].(map[string]any), "windowsBinding")
			f.saveManager(t)
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			f := newDesktopBindingFixture(t)
			f.approve(t)
			mutate(t, f)
			if release, e := f.hub.lockDesktopSpawn(f.task); e == nil {
				release()
				t.Fatal("changed inputs admitted")
			}
		})
	}
}

func TestDesktopWorkflowBindingRefreshBeforeApprovalOnly(t *testing.T) {
	f := newDesktopBindingFixture(t)
	if e := f.hub.freezeDesktopTask(f.task); e != nil {
		t.Fatal(e)
	}
	hashBefore := taskActionHash(f.task)
	newAuth := []byte("same identity verified native refreshed auth")
	hash := sha256.Sum256(newAuth)
	writeDesktopFixture(t, filepath.Join(f.home, "auth.json"), newAuth)
	f.binding["authSha256"] = hex.EncodeToString(hash[:])
	f.saveManager(t)
	if e := f.hub.approveDesktopTask(f.task); e != nil {
		t.Fatal(e)
	}
	if taskActionHash(f.task) != hashBefore {
		t.Fatal("fresh same-identity auth changed user approval identity")
	}
	release, e := f.hub.lockDesktopSpawn(f.task)
	if e != nil {
		t.Fatal(e)
	}
	release()
	newAuth = []byte("another refresh after approval")
	hash = sha256.Sum256(newAuth)
	writeDesktopFixture(t, filepath.Join(f.home, "auth.json"), newAuth)
	f.binding["authSha256"] = hex.EncodeToString(hash[:])
	f.saveManager(t)
	if release, e = f.hub.lockDesktopSpawn(f.task); e == nil {
		release()
		t.Fatal("post-approval replacement admitted")
	}
}

func TestDesktopWorkflowBindingLegacyAndIncomplete(t *testing.T) {
	h := &Hub{}
	task := &Task{}
	if h.freezeDesktopTask(task) != nil || h.approveDesktopTask(task) != nil {
		t.Fatal("legacy changed")
	}
	release, e := h.lockDesktopSpawn(task)
	if e != nil {
		t.Fatal(e)
	}
	release()
	h.config.WorkflowProfileID = 1
	if h.freezeDesktopTask(task) == nil {
		t.Fatal("incomplete adapter admitted")
	}
}

func TestDesktopWorkflowBindingRunTaskRejectsPostApprovalAuth(t *testing.T) {
	f := newDesktopBindingFixture(t)
	config := testConfig(t, os.Args[0]) // Only this synthetic test executable.
	config.DataDir = filepath.Join(f.root, "state")
	config.Projects["demo"] = f.root
	config.Accounts = f.hub.config.Accounts
	config.WorkflowProfileID = f.hub.config.WorkflowProfileID
	config.WorkflowPreferencesPath = f.hub.config.WorkflowPreferencesPath
	config.WorkflowCatalogPath = f.hub.config.WorkflowCatalogPath
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	defer hub.shutdown(context.Background())
	hub.managerSnapshotPath = f.hub.managerSnapshotPath
	created, err := hub.create(CreateRequest{RequestID: "desktop-binding-create", Agent: "codex", Project: "demo", AccountAlias: "account-1", Prompt: "synthetic never executed"})
	if err != nil {
		t.Fatal(err)
	}
	task := hub.tasks[created.ID]
	if err = hub.approveDesktopTask(task); err != nil {
		t.Fatal(err)
	}
	// Enter the real final-spawn path after its approved inputs have changed.
	task.State = stateStarting
	hub.leases[task.Project] = task.ID
	writeDesktopFixture(t, filepath.Join(f.home, "auth.json"), []byte("changed after approval"))
	hub.runTask(task.ID)
	if task.State != stateBlockedConfiguration || task.ReasonCode != errDispatchPolicyUnavailable.Error() || task.PID != 0 || hub.leases[task.Project] != "" {
		t.Fatalf("final admission did not reject before spawn: state=%s reason=%s pid=%d", task.State, task.ReasonCode, task.PID)
	}
}
