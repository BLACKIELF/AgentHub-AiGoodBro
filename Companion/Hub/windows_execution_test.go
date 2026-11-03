package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func windowsExecutionFixture(now time.Time) windowsExecutionAuthority {
	revision := uint64(7)
	model := "gpt-6-astra"
	effort := "high"
	code := "C"
	notAfter := now.Add(100 * time.Second).UnixMilli()
	return windowsExecutionAuthority{
		ProfileID: 11,
		Preference: windowsExecutionPreference{
			Participating: true, Model: &model, Effort: &effort,
			DispatchCode: &code, NotAfterMS: &notAfter, Revision: revision,
		},
		ExcludedPlanTypes: []string{"PRO", "企业"},
		OfficialPlan:      "plus",
		Models: []windowsModelCapability{
			{ID: "gpt-6-astra", Efforts: []string{"low", "high", "ultra"}, DefaultEffort: "low", IsDefault: true},
			{ID: "gpt-5.5", Efforts: []string{"low", "high", "xhigh"}, DefaultEffort: "low"},
			{ID: "gpt-5.2", Efforts: []string{"low", "high"}, DefaultEffort: "low"},
		},
	}
}

func TestWindowsExecutionBodyHashExtension(t *testing.T) {
	old := hashParts("create", "codex", "workspace")
	if got, err := windowsExecutionBodyHash(old, nil); err != nil || got != old {
		t.Fatalf("legacy create hash changed: %q, %v", got, err)
	}
	binding := hashText("fresh native binding")
	got, err := windowsExecutionBodyHash(old, &windowsExecutionRequest{BindingSHA256: binding})
	if err != nil || got != hashParts(old, "windows-execution-v1", binding) {
		t.Fatalf("extension hash mismatch: %q, %v", got, err)
	}
	if _, err := windowsExecutionBodyHash(old, &windowsExecutionRequest{BindingSHA256: "BAD"}); err == nil {
		t.Fatal("invalid extension digest accepted")
	}
}

func TestWindowsExecutionFreshResolverRejectsChangedEvidence(t *testing.T) {
	now := time.UnixMilli(1_800_000_000_000)
	authority := windowsExecutionFixture(now)
	model, effort, tier := "gpt-5.5", "xhigh", "fast"
	overrides := windowsExecutionOverrides{Model: &model, Effort: &effort, ServiceTier: &tier}
	req := windowsExecutionRequest{
		WorkflowRevision: authority.Preference.Revision,
		BindingSHA256:    windowsExecutionBinding(authority, overrides, "gpt-5.5", "xhigh", "fast"),
		Overrides:        overrides,
	}
	resolved, err := resolveWindowsExecution(req, authority, now)
	if err != nil {
		t.Fatal(err)
	}
	if resolved.Model != "gpt-5.5" || resolved.Effort != "xhigh" || resolved.ServiceTier != "fast" {
		t.Fatalf("wrong effective execution: %#v", resolved)
	}
	if got, want := resolved.codexArguments(), []string{"-m", "gpt-5.5", "-c", `model_reasoning_effort="xhigh"`, "-c", `service_tier="fast"`, "--enable", "fast_mode"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("spawn args %q, want %q", got, want)
	}

	changedRevision := authority
	changedRevision.Preference.Revision++
	changedPreferences := authority
	changedModel := "gpt-5.2"
	changedPreferences.Preference.Model = &changedModel
	changedModels := authority
	changedModels.Models = append(append([]windowsModelCapability(nil), authority.Models...), windowsModelCapability{
		ID: "gpt-5.6", Efforts: []string{"low"}, DefaultEffort: "low",
	})
	for name, changed := range map[string]windowsExecutionAuthority{
		"revision":        changedRevision,
		"preference":      changedPreferences,
		"model inventory": changedModels,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := resolveWindowsExecution(req, changed, now); err == nil {
				t.Fatal("stale binding accepted")
			}
		})
	}
}

func TestWindowsExecutionSavedTierAndModelOnlyOverrideMatchMac(t *testing.T) {
	now := time.UnixMilli(1_800_000_000_000)
	authority := windowsExecutionFixture(now)
	modelOnly := "gpt-5.5"
	overrides := windowsExecutionOverrides{Model: &modelOnly}
	request := windowsExecutionRequest{
		WorkflowRevision: authority.Preference.Revision,
		BindingSHA256:    windowsExecutionBinding(authority, overrides, "gpt-5.5", "high", "default"),
		Overrides:        overrides,
	}
	resolved, err := resolveWindowsExecution(request, authority, now)
	if err != nil || resolved.Effort != "high" {
		t.Fatalf("model-only override must preserve saved effort: %#v, %v", resolved, err)
	}

	savedFast := "fast"
	authority.Preference.ServiceTier = &savedFast
	request.BindingSHA256 = windowsExecutionBinding(authority, overrides, "gpt-5.5", "high", "fast")
	resolved, err = resolveWindowsExecution(request, authority, now)
	if err != nil || resolved.ServiceTier != "fast" {
		t.Fatalf("saved fast tier not inherited: %#v, %v", resolved, err)
	}
	defaultTier := "default"
	explicitDefault := windowsExecutionOverrides{Model: &modelOnly, ServiceTier: &defaultTier}
	request.Overrides = explicitDefault
	request.BindingSHA256 = windowsExecutionBinding(authority, explicitDefault, "gpt-5.5", "high", "default")
	resolved, err = resolveWindowsExecution(request, authority, now)
	if err != nil || resolved.ServiceTier != "default" {
		t.Fatalf("explicit default override not respected: %#v, %v", resolved, err)
	}
}

func TestWindowsExecutionSpawnBoundaryRechecksNotAfter(t *testing.T) {
	now := time.Now()
	authority := windowsExecutionFixture(now)
	deadline := now.Add(time.Second).UnixMilli()
	authority.Preference.NotAfterMS = &deadline
	overrides := windowsExecutionOverrides{}
	execution := &windowsExecutionRequest{
		WorkflowRevision: authority.Preference.Revision,
		Overrides:        overrides,
	}
	execution.BindingSHA256 = windowsExecutionBinding(authority, overrides, "gpt-6-astra", "high", "default")
	effective, err := resolveWindowsExecution(*execution, authority, now)
	if err != nil {
		t.Fatal(err)
	}
	task := &Task{
		WindowsExecution:                  execution,
		windowsExecutionAuthority:         &authority,
		windowsEffectiveExecution:         &effective,
		windowsExecutionAuthorityAt:       now,
		windowsExecutionAuthorityConsumed: true,
	}
	if err := validateWindowsExecutionAtSpawn(task, time.UnixMilli(deadline)); !errors.Is(err, errDispatchDisabled) {
		t.Fatalf("spawn accepted expired workflow deadline: %v", err)
	}
}

func setupWindowsExecutionHub(t *testing.T, command string) (desktopBindingFixture, *Hub, *windowsExecutionAuthority, *windowsExecutionRequest) {
	t.Helper()
	f := newDesktopBindingFixture(t)
	config := testConfig(t, command)
	config.Accounts = []AccountConfig{{Alias: "account-1", Home: f.home}}
	config.WorkflowPreferencesPath = f.hub.config.WorkflowPreferencesPath
	config.WorkflowCatalogPath = f.hub.config.WorkflowCatalogPath
	config.WorkflowProfileID = 1
	config.ApprovalQuotaMaxAgeSeconds = 60
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	hub.managerSnapshotPath = f.hub.managerSnapshotPath
	f.hub = hub
	t.Cleanup(func() { hub.shutdown(context.Background()) })

	model := "gpt-6-sol"
	effort := "high"
	authority := &windowsExecutionAuthority{
		ProfileID: 1,
		Preference: windowsExecutionPreference{
			Participating: true,
			Model:         &model,
			Effort:        &effort,
			Revision:      1,
		},
		OfficialPlan: "plus",
		Models: []windowsModelCapability{
			{ID: "gpt-6-sol", Efforts: []string{"low", "high"}, DefaultEffort: "low", IsDefault: true},
			{ID: "gpt-5.5", Efforts: []string{"low", "high", "xhigh"}, DefaultEffort: "low"},
		},
	}
	overrides := windowsExecutionOverrides{}
	execution := &windowsExecutionRequest{
		WorkflowRevision: 1,
		Overrides:        overrides,
	}
	execution.BindingSHA256 = windowsExecutionBinding(*authority, overrides, model, effort, "default")
	return f, hub, authority, execution
}

func newWindowsExecutionTask(t *testing.T, hub *Hub, authority *windowsExecutionAuthority, execution *windowsExecutionRequest) *Task {
	t.Helper()
	task := &Task{
		ID:                "windows-execution-fixture",
		Version:           1,
		Agent:             "codex",
		Project:           "demo",
		AccountAlias:      "account-1",
		State:             stateStarting,
		PromptHash:        hashText("prompt"),
		WindowsExecution:  cloneWindowsExecutionRequest(execution),
		CreatedAt:         time.Now().UTC(),
		UpdatedAt:         time.Now().UTC(),
		ApprovalExpiresAt: time.Now().UTC().Add(time.Minute),
	}
	task.windowsExecutionAuthority = cloneWindowsExecutionAuthority(authority)
	task.windowsExecutionAuthorityAt = time.Now()
	if err := hub.freezeDesktopTask(task); err != nil {
		t.Fatal(err)
	}
	if err := hub.approveDesktopTask(task); err != nil {
		t.Fatal(err)
	}
	task.ActionHash = taskActionHash(task)
	hub.mu.Lock()
	hub.tasks[task.ID] = task
	hub.pendingPrompts[task.ID] = "prompt"
	hub.leases[task.Project] = task.ID
	hub.mu.Unlock()
	return task
}

func TestWindowsExecutionCreatePersistsExtensionAndBindsBodyHash(t *testing.T) {
	f, hub, authority, execution := setupWindowsExecutionHub(t, "/usr/bin/true")
	request := CreateRequest{
		RequestID:                 "windows-execution-create-0001",
		Agent:                     "codex",
		Project:                   "demo",
		AccountAlias:              "account-1",
		Prompt:                    "synthetic prompt",
		WindowsExecution:          execution,
		WindowsExecutionAuthority: authority,
	}
	created, err := hub.create(request)
	if err != nil {
		t.Fatal(err)
	}
	hub.mu.Lock()
	task := hub.tasks[created.ID]
	record := hub.requests[hashText(request.RequestID)]
	hub.mu.Unlock()
	if task == nil || task.WindowsExecution == nil || task.WindowsExecution.BindingSHA256 != execution.BindingSHA256 {
		t.Fatalf("created task omitted Windows execution extension: %#v", task)
	}
	if task.windowsExecutionAuthority != nil || !task.windowsExecutionAuthorityAt.IsZero() {
		t.Fatal("creation authority was retained after the create check")
	}
	base := hashParts("create", request.Agent, request.Project, request.AccountAlias, hashText(request.Prompt), "")
	wantBody, err := windowsExecutionBodyHash(base, execution)
	if err != nil || record.BodyHash != wantBody {
		t.Fatalf("request body hash = %q, want %q (%v)", record.BodyHash, wantBody, err)
	}
	journal, err := os.ReadFile(filepath.Join(hub.config.DataDir, "events.ndjson"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(journal), `"windowsExecution"`) || strings.Contains(string(journal), `"windowsExecutionAuthority"`) {
		t.Fatal("journal did not persist only the execution extension")
	}

	var replayed Task
	encoded, err := json.Marshal(task)
	if err != nil || json.Unmarshal(encoded, &replayed) != nil {
		t.Fatalf("task persistence roundtrip failed: %v", err)
	}
	if replayed.WindowsExecution == nil || replayed.ActionHash != task.ActionHash || taskActionHash(&replayed) != task.ActionHash {
		t.Fatalf("replayed task lost its bound extension: %#v", replayed)
	}
	if replayed.windowsExecutionAuthority != nil || !replayed.windowsExecutionAuthorityAt.IsZero() {
		t.Fatal("ephemeral authority survived task persistence")
	}
	_ = f
}

func TestWindowsExecutionCommandConsumesFreshAuthorityOnce(t *testing.T) {
	_, hub, authority, execution := setupWindowsExecutionHub(t, "/usr/bin/true")
	task := newWindowsExecutionTask(t, hub, authority, execution)
	command, err := hub.commandFor(task, "synthetic prompt")
	if err != nil {
		t.Fatal(err)
	}
	args := strings.Join(command.Args, "\x00")
	for _, expected := range []string{"-m\x00gpt-6-sol", "-c\x00model_reasoning_effort=\"high\"", "-c\x00service_tier=\"default\"", "--disable\x00fast_mode"} {
		if !strings.Contains(args, expected) {
			t.Fatalf("resolved Windows execution args missing %q: %q", expected, command.Args)
		}
	}
	if strings.Contains(args, "agents.enabled") || !task.windowsExecutionAuthorityConsumed {
		t.Fatalf("execution used legacy subagent args or did not consume its authority: %q", command.Args)
	}
	if _, err := hub.commandFor(task, "synthetic prompt"); err == nil {
		t.Fatal("one-shot authority was accepted by a second final consumer")
	}
	encoded, err := json.Marshal(task)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "windowsExecutionAuthority") {
		t.Fatal("ephemeral authority leaked into the Task record")
	}
}

func TestWindowsExecutionQueuedAuthorityExpiryBlocksBeforeSpawn(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "started")
	script := filepath.Join(t.TempDir(), "fake-codex.sh")
	if err := os.WriteFile(script, []byte("#!/bin/sh\n: > \""+marker+"\"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	_, hub, authority, execution := setupWindowsExecutionHub(t, script)
	task := newWindowsExecutionTask(t, hub, authority, execution)
	task.windowsExecutionAuthorityAt = time.Now().Add(-windowsExecutionAuthorityMaxAge - time.Second)
	hub.runTask(task.ID)
	if task.State != stateBlockedConfiguration || task.ReasonCode != "execution_evidence_stale" {
		t.Fatalf("expired queue did not block at spawn boundary: state=%s reason=%s", task.State, task.ReasonCode)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("expired authority launched the command; marker stat: %v", err)
	}
}

func TestWindowsExecutionFinalDiskRecheckBlocksBeforeSpawn(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "started")
	script := filepath.Join(t.TempDir(), "fake-codex.sh")
	if err := os.WriteFile(script, []byte("#!/bin/sh\n: > \""+marker+"\"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	f, hub, authority, execution := setupWindowsExecutionHub(t, script)
	task := newWindowsExecutionTask(t, hub, authority, execution)
	snapshot := f.manager["profiles"].([]any)[0].(map[string]any)["lastSnapshot"].(map[string]any)
	snapshot["planType"] = "pro"
	f.saveManager(t)
	hub.runTask(task.ID)
	if task.State != stateBlockedConfiguration || task.ReasonCode != errDispatchPolicyUnavailable.Error() {
		t.Fatalf("changed final plan evidence did not block spawn: state=%s reason=%s", task.State, task.ReasonCode)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("changed final evidence launched the command; marker stat: %v", err)
	}
}
