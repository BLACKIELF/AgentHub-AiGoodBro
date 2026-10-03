package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestTaskDTOIncludesExpiredApprovalTime(t *testing.T) {
	expiresAt := time.Now().UTC().Add(-time.Minute)
	task := &Task{
		State:             stateAwaitingApproval,
		ApprovalExpiresAt: expiresAt,
	}

	encoded, err := json.Marshal(task.dto())
	if err != nil {
		t.Fatal(err)
	}
	var payload map[string]json.RawMessage
	if err := json.Unmarshal(encoded, &payload); err != nil {
		t.Fatal(err)
	}
	raw, ok := payload["approvalExpiresAt"]
	if !ok {
		t.Fatal("TaskDTO JSON omitted approvalExpiresAt")
	}
	var got time.Time
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	if !got.Before(time.Now().UTC()) {
		t.Fatalf("approvalExpiresAt is not in the past: %s", got)
	}
	if expired := task.dtoAt(expiresAt.Add(time.Second)); !expired.ApprovalExpired {
		t.Fatal("expired awaiting approval task was still classified as actionable")
	}
	if current := task.dtoAt(expiresAt.Add(-time.Second)); current.ApprovalExpired {
		t.Fatal("unexpired awaiting approval task was classified as expired")
	}
	task.State = stateCancelled
	if cancelled := task.dtoAt(expiresAt.Add(time.Second)); cancelled.ApprovalExpired {
		t.Fatal("non-awaiting task was classified as an expired approval")
	}
}

func TestCanonicalProjectLeaseRejectsDuplicateCWDAtApproval(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	config.Projects["alias"] = config.Projects["demo"]
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	task, err := hub.create(CreateRequest{RequestID: "canonical-cwd-create-0001", Agent: "codex", Project: "demo", Prompt: "fixture"})
	if err != nil {
		t.Fatal(err)
	}
	hub.mu.Lock()
	hub.leases["alias"] = "other-active-task"
	hub.mu.Unlock()
	if _, err := hub.approve(task.ID, ApproveRequest{RequestID: "canonical-cwd-approve-0001", ActionHash: task.ActionHash}); !errors.Is(err, errBusy) {
		t.Fatalf("same CWD under another alias was not treated as busy: %v", err)
	}
	hub.mu.Lock()
	defer hub.mu.Unlock()
	if current := hub.tasks[task.ID]; current.State != stateAwaitingApproval || hub.leases["alias"] != "other-active-task" {
		t.Fatalf("conflicted approval changed task or existing lease: %#v %#v", current, hub.leases)
	}
}

func TestCreationDoesNotCommitRoundRobinWhenJournalFails(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	config.AccountStrategy = "round_robin"
	config.Accounts = []AccountConfig{
		testAccountConfig(t, t.TempDir(), "acct-a"),
		testAccountConfig(t, t.TempDir(), "acct-b"),
	}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.managerSnapshotPath = writeQuotaSnapshots(t, config.Accounts, []string{"20", "20"})
	hub.mu.Lock()
	hub.store.failed = true
	hub.mu.Unlock()
	if _, err := hub.create(CreateRequest{RequestID: "selection-journal-failed-0001", Agent: "codex", Project: "demo", Prompt: "fixture"}); err == nil {
		t.Fatal("journal failure unexpectedly created a task")
	}
	hub.mu.Lock()
	defer hub.mu.Unlock()
	if hub.accountCursor != 0 || hub.accountTick != 0 || len(hub.accountUsed) != 0 {
		t.Fatalf("failed create consumed account selection: cursor=%d tick=%d used=%v", hub.accountCursor, hub.accountTick, hub.accountUsed)
	}
}

func TestCreationRejectsKnownQuotaReadFailure(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	account := testAccountConfig(t, t.TempDir(), "acct-a")
	config.Accounts = []AccountConfig{account}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.managerSnapshotPath = writeRawManagerSnapshot(t, fmt.Sprintf(`{"profiles":[{"name":%q,"codexHomePath":%q,"lastSnapshot":{"quotaReadSucceeded":false,"fiveHour":{"usedPercent":20},"sevenDay":{"usedPercent":20}}}]}`, account.Alias, account.Home))
	if _, err := hub.create(CreateRequest{RequestID: "quota-read-failed-0001", Agent: "codex", Project: "demo", AccountAlias: account.Alias, Prompt: "fixture"}); !errors.Is(err, errAccountQuotaReserve) {
		t.Fatalf("known failed quota read was allowed to create a draft: %v", err)
	}
}

func writeRawManagerSnapshot(t *testing.T, contents string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "manager-snapshot.json")
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestIdempotentCreateApproveAndNoPromptPersistence(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })

	request := CreateRequest{RequestID: "create-0001", Agent: "codex", Project: "demo", Prompt: "private prompt marker"}
	first, err := hub.create(request)
	if err != nil {
		t.Fatal(err)
	}
	second, err := hub.create(request)
	if err != nil || second.ID != first.ID {
		t.Fatalf("duplicate create did not return original task: %#v %v", second, err)
	}
	request.Prompt = "different body"
	if _, err := hub.create(request); !errors.Is(err, errConflict) {
		t.Fatalf("same request id with different body must conflict: %v", err)
	}

	approved, err := hub.approve(first.ID, ApproveRequest{RequestID: "approve-0001", ActionHash: first.ActionHash})
	if err != nil || approved.State != stateStarting {
		t.Fatalf("approve failed: %#v %v", approved, err)
	}
	finished := waitForState(t, hub, first.ID, stateSucceeded)
	if finished.ReasonCode != "process_exit_zero" {
		t.Fatalf("unexpected completion: %#v", finished)
	}
	journal, err := os.ReadFile(filepath.Join(config.DataDir, "events.ndjson"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(journal, []byte("private prompt marker")) || bytes.Contains(journal, []byte(config.Projects["demo"])) {
		t.Fatal("journal persisted a prompt or private project path")
	}
}

func TestCancelStopsAgentProcess(t *testing.T) {
	root := t.TempDir()
	script := filepath.Join(root, "fake-agent")
	if err := os.WriteFile(script, []byte("#!/bin/sh\ntrap 'exit 0' INT TERM\nwhile :; do :; done\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	config := testConfig(t, script)
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })

	task, err := hub.create(CreateRequest{RequestID: "create-0002", Agent: "codex", Project: "demo", Prompt: "wait"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := hub.approve(task.ID, ApproveRequest{RequestID: "approve-0002", ActionHash: task.ActionHash}); err != nil {
		t.Fatal(err)
	}
	running := waitForState(t, hub, task.ID, stateRunning)
	if _, err := hub.cancel(task.ID, CancelRequest{RequestID: "cancel-0002", ExpectedVersion: running.Version}); err != nil {
		t.Fatal(err)
	}
	waitForState(t, hub, task.ID, stateCancelled)
}

func TestRestartFailsClosedWithoutPromptOrProcessEvidence(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	firstHub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	task, err := firstHub.create(CreateRequest{RequestID: "create-0003", Agent: "codex", Project: "demo", Prompt: "not persisted"})
	if err != nil {
		t.Fatal(err)
	}
	if err := firstHub.store.Close(); err != nil {
		t.Fatal(err)
	}

	secondHub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { secondHub.shutdown(context.Background()) })
	recovered := taskByID(t, secondHub, task.ID)
	if recovered.State != stateBlockedConfiguration || recovered.ReasonCode != "restart_prompt_unavailable" {
		t.Fatalf("restart did not fail closed: %#v", recovered)
	}
	cancelled, err := secondHub.cancel(task.ID, CancelRequest{RequestID: "cancel-recovered-0001", ExpectedVersion: recovered.Version})
	if err != nil {
		t.Fatal(err)
	}
	if cancelled.State != stateCancelled || cancelled.ReasonCode != "cancelled_blocked_configuration" {
		t.Fatalf("recovered blocked task was not cancelled: %#v", cancelled)
	}
}

func TestRestartTruncatesIncompleteJournalTail(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	firstHub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	task, err := firstHub.create(CreateRequest{RequestID: "create-tail-0001", Agent: "codex", Project: "demo", Prompt: "not persisted"})
	if err != nil {
		t.Fatal(err)
	}
	if err := firstHub.store.Close(); err != nil {
		t.Fatal(err)
	}
	journalPath := filepath.Join(config.DataDir, "events.ndjson")
	journal, err := os.OpenFile(journalPath, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := journal.WriteString(`{"partial":`); err != nil {
		journal.Close()
		t.Fatal(err)
	}
	if err := journal.Close(); err != nil {
		t.Fatal(err)
	}

	secondHub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { secondHub.shutdown(context.Background()) })
	recovered := taskByID(t, secondHub, task.ID)
	if recovered.State != stateBlockedConfiguration {
		t.Fatalf("incomplete tail recovery was not fail-closed: %#v", recovered)
	}
}

func TestSessionExtraction(t *testing.T) {
	codex := extractSessionID("codex", `{"type":"thread.started","thread_id":"019d1234-abcd-7000-acde-1234567890ab"}`)
	if codex != "019d1234-abcd-7000-acde-1234567890ab" {
		t.Fatalf("codex session not extracted: %q", codex)
	}
	claude := extractSessionID("claude", `{"type":"system","subtype":"init","session_id":"12345678-abcd-4000-acde-1234567890ab"}`)
	if claude != "12345678-abcd-4000-acde-1234567890ab" {
		t.Fatalf("claude session not extracted: %q", claude)
	}
	kimi := extractSessionID("kimi", `{"role":"meta","type":"session.resume_hint","session_id":"22345678-abcd-4000-acde-1234567890ab","command":"kimi -r 22345678-abcd-4000-acde-1234567890ab"}`)
	if kimi != "22345678-abcd-4000-acde-1234567890ab" {
		t.Fatalf("kimi session not extracted: %q", kimi)
	}
	if extractSessionID("kimi", `{"role":"assistant","session_id":"22345678-abcd-4000-acde-1234567890ab"}`) != "" {
		t.Fatal("kimi session extracted from a non-resume-hint event")
	}
	if extractSessionID("codex", `{"type":"message","thread_id":"too-short"}`) != "" {
		t.Fatal("unexpected session extraction")
	}
}

func TestResultNoteExtraction(t *testing.T) {
	hub, err := newHub(testConfig(t, "/usr/bin/true"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	task, err := hub.create(CreateRequest{RequestID: "result-note-0001", Agent: "codex", Project: "demo", Prompt: "test"})
	if err != nil {
		t.Fatal(err)
	}
	stream := strings.Join([]string{
		`{"type":"item.completed","item":{"type":"agent_message","text":"earlier"}}`,
		`{"type":"item.completed","item":{"type":"command_execution","text":"ignored"}}`,
		`{"type":"item.completed","item":{"type":"agent_message","text":"first line\nlast line"}}`,
	}, "\n")
	hub.scanOutput(task.ID, "codex", "stdout", strings.NewReader(stream))
	if note := taskByID(t, hub, task.ID).ResultNote; note != "first line last line" {
		t.Fatalf("last codex result note not recorded: %q", note)
	}

	long := strings.Repeat("界", 201)
	truncated := extractResultNote("codex", fmt.Sprintf(`{"type":"item.completed","item":{"type":"agent_message","text":%q}}`, long))
	if len([]rune(truncated)) != 200 || truncated != strings.Repeat("界", 200) {
		t.Fatalf("result note was not truncated to 200 characters: %d", len([]rune(truncated)))
	}

	if note := extractResultNote("codex", `{"type":"item.completed","item":{"type":"command_execution","text":"ignored"}}`); note != "" {
		t.Fatalf("non-message event produced result note: %q", note)
	}
	if note := extractResultNote("claude", `{"type":"result","result":"done"}`); note != "" {
		t.Fatalf("stream without assistant message produced result note: %q", note)
	}
	claude := extractResultNote("claude", `{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}`)
	if claude != "done" {
		t.Fatalf("claude result note not extracted: %q", claude)
	}
	kimi := extractResultNote("kimi", `{"role":"assistant","content":"done from kimi"}`)
	if kimi != "done from kimi" {
		t.Fatalf("kimi result note not extracted: %q", kimi)
	}
	if note := extractResultNote("kimi", `{"role":"tool","content":"ignored"}`); note != "" {
		t.Fatalf("kimi tool event produced result note: %q", note)
	}

	stream = strings.Join([]string{
		`{"role":"assistant","content":"first kimi block"}`,
		`{"role":"tool","tool_call_id":"tool-12345678","content":"tool output"}`,
		`{"role":"assistant","content":"final kimi block"}`,
		`{"role":"meta","type":"session.resume_hint","session_id":"32345678-abcd-4000-acde-1234567890ab"}`,
	}, "\n")
	kimiTask, err := hub.create(CreateRequest{RequestID: "result-note-kimi-0001", Agent: "kimi", Project: "demo", Prompt: "test"})
	if err != nil {
		t.Fatal(err)
	}
	hub.scanOutput(kimiTask.ID, "kimi", "stdout", strings.NewReader(stream))
	hub.mu.Lock()
	stored := *hub.tasks[kimiTask.ID]
	hub.mu.Unlock()
	if stored.ResultNote != "final kimi block" || stored.SessionID != "32345678-abcd-4000-acde-1234567890ab" || !stored.SessionVerified {
		t.Fatalf("kimi NDJSON stream was not mapped: %#v", stored)
	}
}

func TestKimiOutputExtraction(t *testing.T) {
	tests := []struct {
		line       string
		want       string
		recognized bool
	}{
		{line: `{"role":"assistant","content":"answer chunk"}`, want: "answer chunk", recognized: true},
		{line: `{"role":"assistant","tool_calls":[{"type":"function"}]}`, recognized: true},
		{line: `{"role":"tool","tool_call_id":"call-12345678","content":"result"}`, want: "[tool] result", recognized: true},
		{line: `{"role":"meta","type":"turn.step.retrying","error_message":"retry me"}`, want: "[retry] retry me", recognized: true},
		{line: `{"role":"meta","type":"session.resume_hint","session_id":"42345678-abcd-4000-acde-1234567890ab"}`, recognized: true},
		{line: `not json`},
	}
	for _, test := range tests {
		got, recognized := extractKimiOutput(test.line)
		if got != test.want || recognized != test.recognized {
			t.Fatalf("extractKimiOutput(%q) = %q, %v; want %q, %v", test.line, got, recognized, test.want, test.recognized)
		}
	}
}

func TestSessionMismatchBecomesUncertain(t *testing.T) {
	hub, err := newHub(testConfig(t, "/usr/bin/true"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	dto, err := hub.create(CreateRequest{RequestID: "create-session-0001", Agent: "codex", Project: "demo", Prompt: "resume"})
	if err != nil {
		t.Fatal(err)
	}
	hub.mu.Lock()
	task := hub.tasks[dto.ID]
	task.State = stateRunning
	task.SessionID = "parent-session-1234"
	task.SessionVerified = true
	hub.leases[task.Project] = task.ID
	hub.mu.Unlock()

	hub.bindSession(task.ID, "different-session-5678")
	result := taskByID(t, hub, task.ID)
	if result.State != stateUncertain || result.ReasonCode != "session_mismatch" {
		t.Fatalf("session mismatch did not fail closed: %#v", result)
	}
	resolved, err := hub.resolve(task.ID, ResolveRequest{RequestID: "resolve-session-0001", ExpectedVersion: result.Version, ConfirmedStopped: true})
	if err != nil {
		t.Fatal(err)
	}
	if resolved.CanResume {
		t.Fatal("mismatched session remained resumable")
	}
}

func TestAPIRequiresTokenAndSameOrigin(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	token := []byte("01234567890123456789012345678901")
	handler := (&API{hub: hub, token: token}).routes()

	missing := httptest.NewRecorder()
	handler.ServeHTTP(missing, httptest.NewRequest(http.MethodGet, "/api/overview", nil))
	if missing.Code != http.StatusUnauthorized {
		t.Fatalf("missing token returned %d", missing.Code)
	}

	payload, _ := json.Marshal(CreateRequest{RequestID: "create-0004", Agent: "codex", Project: "demo", Prompt: "secret"})
	crossOriginRequest := httptest.NewRequest(http.MethodPost, "/api/tasks", bytes.NewReader(payload))
	crossOriginRequest.Header.Set("Authorization", "Bearer "+string(token))
	crossOriginRequest.Header.Set("Origin", "https://evil.example")
	crossOriginRequest.Host = "hub.test"
	crossOrigin := httptest.NewRecorder()
	handler.ServeHTTP(crossOrigin, crossOriginRequest)
	if crossOrigin.Code != http.StatusForbidden {
		t.Fatalf("cross-origin mutation returned %d", crossOrigin.Code)
	}

	sameOriginRequest := httptest.NewRequest(http.MethodPost, "/api/tasks", bytes.NewReader(payload))
	sameOriginRequest.Header.Set("Authorization", "Bearer "+string(token))
	sameOriginRequest.Header.Set("Origin", "http://hub.test")
	sameOriginRequest.Host = "hub.test"
	sameOrigin := httptest.NewRecorder()
	handler.ServeHTTP(sameOrigin, sameOriginRequest)
	if sameOrigin.Code != http.StatusCreated {
		t.Fatalf("same-origin mutation returned %d: %s", sameOrigin.Code, sameOrigin.Body.String())
	}
}

func TestTokenlessConfigDoesNotReadTokenFile(t *testing.T) {
	requireToken := false
	config := Config{TokenFile: filepath.Join(t.TempDir(), "missing-token"), RequireToken: &requireToken}
	token, err := readConfiguredToken(config)
	if err != nil || len(token) != 0 {
		t.Fatalf("tokenless config still required token file: %q %v", token, err)
	}

	hub, err := newHub(testConfig(t, "/usr/bin/true"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	handler := (&API{hub: hub, requireToken: false, requireTokenSet: true}).routes()
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/api/overview", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("tokenless intranet request returned %d: %s", response.Code, response.Body.String())
	}
}

func TestLoadConfigSupportsOnlyBundledCodex(t *testing.T) {
	requireToken := false
	config := testConfig(t, "/usr/bin/true")
	config.RequireToken = &requireToken
	config.ApprovalQuotaMaxAgeSeconds = 0
	delete(config.Commands, "kimi")
	delete(config.Commands, "claude")
	data, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	loaded, err := loadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(loaded.Commands) != 1 || loaded.Commands["codex"] != "/usr/bin/true" {
		t.Fatalf("unconfigured optional adapters must remain unavailable: %#v", loaded.Commands)
	}
	if loaded.ApprovalQuotaMaxAgeSeconds != defaultApprovalQuotaMaxAgeSeconds {
		t.Fatalf("approval quota max age default = %d", loaded.ApprovalQuotaMaxAgeSeconds)
	}
}

func TestManagerOverviewParsesAliasesFreshnessAndPrivacy(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	matchedHome := filepath.Join(t.TempDir(), "matched-home")
	config.Accounts = []AccountConfig{{Alias: "axuanzai0917", Home: matchedHome}}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })

	path := filepath.Join(t.TempDir(), "snapshot.json")
	now := time.Date(2026, 8, 29, 21, 40, 0, 0, time.UTC)
	fetchedApple := now.Add(-10*time.Minute).Unix() - appleEpochUnixOffset
	contents := fmt.Sprintf(`{"profiles":[{"name":"profile fallback","codexHomePath":%q,"accountID":"must-not-leak","lastSnapshot":{"email":"alice@example.invalid","planType":"plus","fetchedAt":%d,"fiveHour":{"usedPercent":14,"resetsAt":%d,"windowDurationMins":300},"sevenDay":{"usedPercent":3,"resetsAt":%d,"windowDurationMins":10080}}}]}`, matchedHome, fetchedApple, fetchedApple+1800, fetchedApple+345600)
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	handler := (&API{hub: hub, token: []byte("test-token"), managerSnapshotPath: path, now: func() time.Time { return now }}).routes()
	request := httptest.NewRequest(http.MethodGet, "/api/manager/overview", nil)
	request.Header.Set("Authorization", "Bearer test-token")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("manager overview returned %d: %s", response.Code, response.Body.String())
	}
	var overview managerOverview
	if err := json.Unmarshal(response.Body.Bytes(), &overview); err != nil {
		t.Fatal(err)
	}
	if len(overview.Accounts) != 1 {
		t.Fatalf("expected one account, got %#v", overview)
	}
	account := overview.Accounts[0]
	if account.Alias != "axuanzai0917" || account.Source != "matched_alias" || account.Plan != "plus" || account.Email != "a***@example.invalid" {
		t.Fatalf("manager account mismatch: %#v", account)
	}
	if account.FiveHourUsedPercent == nil || *account.FiveHourUsedPercent != 14 || account.SevenDayUsedPercent == nil || *account.SevenDayUsedPercent != 3 || !account.Fresh {
		t.Fatalf("manager usage mismatch: %#v", account)
	}
	body := response.Body.String()
	if strings.Contains(body, matchedHome) || strings.Contains(body, "must-not-leak") || strings.Contains(body, "alice@example.invalid") {
		t.Fatalf("private manager data leaked: %s", body)
	}
}

func TestManagerOverviewConvertsAppleEpochToUTC(t *testing.T) {
	zero := float64(0)
	converted := appleReferenceTime(&zero)
	want := time.Date(2001, 1, 1, 0, 0, 0, 0, time.UTC)
	if converted == nil || !converted.Equal(want) || converted.Location() != time.UTC {
		t.Fatalf("Apple epoch converted to %#v, want %s UTC", converted, want)
	}
}

func TestExecutionPreferenceValidation(t *testing.T) {
	got, err := normalizedExecutionPreference(nil)
	if err != nil || !executionPreferencesEqual(got, defaultExecutionPreference) {
		t.Fatalf("missing legacy preference did not use the default: %#v %v", got, err)
	}
	if got.Model != "gpt-6-astra" || got.ReasoningEffort != "low" || got.ServiceTier != "default" || got.SubagentMode != "standard" {
		t.Fatalf("missing preference did not align with native/Python defaults: %#v", got)
	}
	standardPreset := defaultPreset("standard")
	if defaultExecutionPreference.Model != "gpt-6-astra" || !standardPreset.UseSavedModel ||
		standardPreset.Model != "gpt-6-sol" || standardPreset.SubagentModel != "gpt-6-luna" {
		t.Fatalf("standard preset did not preserve saved-model defaults: %#v", standardPreset)
	}

	valid := []executionPreference{
		{Model: "gpt-6-astra", ReasoningEffort: "low", ServiceTier: "default"},
		{Model: "gpt-6-astra", ReasoningEffort: "high", ServiceTier: "default"},
		{Model: "gpt-6-astra", ReasoningEffort: "ultra", ServiceTier: "fast"},
		{Model: "gpt-6-sol", ReasoningEffort: "ultra", ServiceTier: "default"},
		{Model: "gpt-6-luna", ReasoningEffort: "max", ServiceTier: "fast"},
		{Model: "gpt-6-sol", ReasoningEffort: "ultra", ServiceTier: "default", SubagentMode: "sol_luna",
			CustomPresets: map[string]executionPreset{"sol_luna": {Model: "gpt-6-sol", ReasoningEffort: "high",
				SubagentsEnabled: true, SubagentModel: "gpt-6-luna", SubagentReasoningEffort: "max"}}},
		{Model: "gpt-5.6-sol", ReasoningEffort: "ultra", ServiceTier: "fast"},
		{Model: "gpt-5.6-terra", ReasoningEffort: "ultra", ServiceTier: "default"},
		{Model: "gpt-5.6-luna", ReasoningEffort: "max", ServiceTier: "fast"},
		{Model: "gpt-5.5", ReasoningEffort: "xhigh", ServiceTier: "default"},
		{Model: "gpt-5.2", ReasoningEffort: "xhigh", ServiceTier: "default"},
		{Model: "gpt-6-astra", ReasoningEffort: "low", ServiceTier: "fast", SubagentMode: "sol_luna"},
		{Model: "gpt-5.5", ReasoningEffort: "xhigh", ServiceTier: "default", SubagentMode: "luna_direct"},
	}
	for _, preference := range valid {
		expected := preference
		if expected.SubagentMode == "" {
			expected.SubagentMode = "standard"
		}
		if got, err := normalizedExecutionPreference(&preference); err != nil || !executionPreferencesEqual(got, expected) {
			t.Fatalf("valid preference rejected: %#v %#v %v", preference, got, err)
		}
	}

	invalid := []executionPreference{
		{Model: "gpt-6-astra", ReasoningEffort: "minimal", ServiceTier: "default"},
		{Model: "gpt-6-astra", ReasoningEffort: "high", ServiceTier: "priority"},
		{Model: "gpt-6-luna", ReasoningEffort: "ultra", ServiceTier: "default"},
		{Model: "gpt-6-sol", ReasoningEffort: "high", ServiceTier: "default", SubagentMode: "sol_luna",
			CustomPresets: map[string]executionPreset{"sol_luna": {Model: "gpt-6-sol", ReasoningEffort: "high",
				SubagentsEnabled: true, SubagentModel: "gpt-6-luna", SubagentReasoningEffort: "ultra"}}},
		{Model: "gpt-5.6-luna", ReasoningEffort: "ultra", ServiceTier: "default"},
		{Model: "gpt-5.5", ReasoningEffort: "max", ServiceTier: "default"},
		{Model: "gpt-5.2", ReasoningEffort: "high", ServiceTier: "fast"},
		{Model: "gpt-5.6-sol", ReasoningEffort: "minimal", ServiceTier: "default"},
		{Model: "gpt-5.6-sol", ReasoningEffort: "high", ServiceTier: "priority"},
		{Model: "unknown", ReasoningEffort: "high", ServiceTier: "default"},
		{Model: "gpt-5.6-sol", ReasoningEffort: "medium", ServiceTier: "default", SubagentMode: "unknown"},
		{},
	}
	for _, preference := range invalid {
		if _, err := normalizedExecutionPreference(&preference); !errors.Is(err, errInvalid) {
			t.Fatalf("invalid preference accepted: %#v %v", preference, err)
		}
	}
	legacyTask := &Task{ID: "legacy-task", Agent: "codex", Project: "demo", AccountAlias: "pool-a",
		PromptHash: hashText("brief"), ExecutionPreference: &executionPreference{
			Model: "gpt-5.6-sol", ReasoningEffort: "medium", ServiceTier: "default",
		}}
	expectedLegacyHash := hashParts(legacyTask.ID, legacyTask.Agent, legacyTask.Project, legacyTask.AccountAlias,
		legacyTask.PromptHash, legacyTask.ResumeOf, "gpt-5.6-sol", "medium", "default")
	if taskActionHash(legacyTask) != expectedLegacyHash {
		t.Fatal("legacy task action hash compatibility changed")
	}
	saved := executionPreference{Model: "gpt-6-astra", ReasoningEffort: "low", ServiceTier: "fast", SubagentMode: "sol_luna"}
	if got := derivedExecutionPreference(saved); got.Model != "gpt-6-sol" || got.ReasoningEffort != "high" || got.ServiceTier != "fast" {
		t.Fatalf("sol_luna effective strategy mismatch: %#v", got)
	}
	saved.SubagentMode = "luna_direct"
	if got := derivedExecutionPreference(saved); got.Model != "gpt-6-luna" || got.ReasoningEffort != "max" || got.ServiceTier != "fast" {
		t.Fatalf("luna_direct effective strategy mismatch: %#v", got)
	}
	fastSavedUnsupported := executionPreference{Model: "gpt-5.2", ReasoningEffort: "xhigh", ServiceTier: "fast", SubagentMode: "sol_luna"}
	if got, err := normalizedExecutionPreference(&fastSavedUnsupported); err != nil || derivedExecutionPreference(got).Model != "gpt-6-sol" {
		t.Fatalf("inactive saved model incorrectly blocked effective Fast strategy: %#v %v", got, err)
	}
	name := "自定义中蹬"
	saved.SubagentMode = "sol_luna"
	saved.CustomPresets = map[string]executionPreset{"sol_luna": {Name: &name, Model: "gpt-5.6-terra",
		ReasoningEffort: "xhigh", SubagentsEnabled: true, SubagentModel: "gpt-5.5", SubagentReasoningEffort: "high"}}
	if normalized, err := normalizedExecutionPreference(&saved); err != nil {
		t.Fatalf("valid custom preset rejected: %v", err)
	} else if strategy := derivedExecutionStrategy(normalized); strategy.Main.Model != "gpt-5.6-terra" || strategy.Main.ReasoningEffort != "xhigh" || strategy.SubagentModel != "gpt-5.5" || strategy.SubagentReasoningEffort != "high" || strategy.MaximumConcurrentSubagents != 1 {
		t.Fatalf("custom effective strategy mismatch: %#v", strategy)
	}
	badName := " bad"
	saved.CustomPresets["sol_luna"] = executionPreset{Name: &badName, Model: "gpt-5.6-sol", ReasoningEffort: "high", SubagentModel: "gpt-5.6-luna", SubagentReasoningEffort: "max"}
	if _, err := normalizedExecutionPreference(&saved); !errors.Is(err, errInvalid) {
		t.Fatal("invalid custom name accepted")
	}
}

func TestFrozenTaskExecutionStrategySupportsExactLegacyDefaults(t *testing.T) {
	makeTask := func(preference, effective executionPreference, childModel, childEffort string) *Task {
		savedPreference, frozenPreference := preference, effective
		task := &Task{ID: "legacy-frozen-task", Agent: "codex", Project: "demo", AccountAlias: "pool-a",
			ExecutionPreference: &savedPreference, EffectiveExecutionPreference: &frozenPreference}
		if childModel != "" {
			roleSHA := hashText(string(generatedPresetRole(childModel, childEffort)))
			task.SubagentExecution = &subagentExecution{RequestedMode: preference.SubagentMode, RequestedRole: presetRoleName,
				RequestedModel: childModel, RequestedEffort: childEffort, ConcurrentThreads: 1, RoleSHA256: roleSHA}
		}
		return task
	}

	saved := executionPreference{Model: "gpt-6-astra", ReasoningEffort: "low", ServiceTier: "default", SubagentMode: "sol_luna"}
	normalized, err := normalizedExecutionPreference(&saved)
	if err != nil {
		t.Fatal(err)
	}
	legacyEffective := saved
	legacyEffective.Model, legacyEffective.ReasoningEffort = "gpt-5.6-sol", "high"
	legacyTask := makeTask(saved, legacyEffective, "gpt-5.6-luna", "max")
	legacyTask.ActionHash = taskActionHash(legacyTask)
	legacyHash := legacyTask.ActionHash
	legacyStrategy, err := frozenTaskExecutionStrategy(legacyTask, normalized)
	if err != nil || legacyStrategy.Main.Model != "gpt-5.6-sol" || legacyStrategy.SubagentModel != "gpt-5.6-luna" ||
		legacyStrategy.SubagentReasoningEffort != "max" || taskActionHash(legacyTask) != legacyHash {
		t.Fatalf("legacy frozen preset did not remain executable without changing its action hash: %#v %v", legacyStrategy, err)
	}

	currentEffective := derivedExecutionStrategy(normalized).Main
	currentTask := makeTask(saved, currentEffective, "gpt-6-luna", "max")
	currentStrategy, err := frozenTaskExecutionStrategy(currentTask, normalized)
	if err != nil || currentStrategy.Main.Model != "gpt-6-sol" || currentStrategy.SubagentModel != "gpt-6-luna" {
		t.Fatalf("current frozen preset did not retain the new defaults: %#v %v", currentStrategy, err)
	}

	badEffective := legacyEffective
	badEffective.Model = "gpt-5.6-terra"
	if _, err := frozenTaskExecutionStrategy(makeTask(saved, badEffective, "gpt-5.6-luna", "max"), normalized); !errors.Is(err, errInvalid) {
		t.Fatalf("unknown frozen default was accepted: %v", err)
	}
	badRoleTask := makeTask(saved, legacyEffective, "gpt-5.6-luna", "max")
	badRoleTask.SubagentExecution.RequestedModel = "gpt-6-luna"
	if _, err := frozenTaskExecutionStrategy(badRoleTask, normalized); !errors.Is(err, errInvalid) {
		t.Fatalf("mismatched frozen role metadata was accepted: %v", err)
	}

	custom := saved
	custom.CustomPresets = map[string]executionPreset{"sol_luna": {
		Model: "gpt-5.6-terra", ReasoningEffort: "xhigh", SubagentsEnabled: true,
		SubagentModel: "gpt-5.5", SubagentReasoningEffort: "high",
	}}
	normalizedCustom, err := normalizedExecutionPreference(&custom)
	if err != nil {
		t.Fatal(err)
	}
	customEffective := derivedExecutionStrategy(normalizedCustom).Main
	customTask := makeTask(custom, customEffective, "gpt-5.5", "high")
	customStrategy, err := frozenTaskExecutionStrategy(customTask, normalizedCustom)
	if err != nil || customStrategy.Main.Model != "gpt-5.6-terra" || customStrategy.SubagentModel != "gpt-5.5" {
		t.Fatalf("saved custom preset did not remain intact: %#v %v", customStrategy, err)
	}
	if _, err := frozenTaskExecutionStrategy(makeTask(custom, legacyEffective, "gpt-5.6-luna", "max"), normalizedCustom); !errors.Is(err, errInvalid) {
		t.Fatalf("legacy builtin fallback overrode a saved custom preset: %v", err)
	}
}

func TestManagerOverviewCollapsesManagedCopyOfSystemAccount(t *testing.T) {
	managedHome := filepath.Join(t.TempDir(), "managed-home")
	snapshot := managerSnapshotFile{Profiles: []managerProfile{
		{
			Name: "system@example.com", CodexHomePath: "/tmp/system", IsSystemProfile: true,
			LastSnapshot: &managerAccountSnapshot{Email: "system@example.com", AccountID: "acct-same", PlanType: "pro"},
		},
		{
			Name: "system@example.com", CodexHomePath: managedHome,
			LastSnapshot: &managerAccountSnapshot{Email: "system@example.com", AccountID: "acct-same", PlanType: "pro"},
		},
	}}
	data, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "snapshot.json")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	overview, err := readManagerOverview(
		path,
		[]AccountConfig{{Alias: "yjc99889988", Home: managedHome}},
		time.Now(),
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(overview.Accounts) != 1 || overview.Accounts[0].Alias != "yjc99889988" || overview.Accounts[0].Source != "matched_alias" {
		t.Fatalf("system account was not collapsed into managed alias: %#v", overview.Accounts)
	}
}

func TestEmbeddedWebShowsReadOnlyQuotaPanelAndPollsIt(t *testing.T) {
	html := string(indexHTML)
	for _, required := range []string{
		`id="quota-panel"`,
		`await request("/api/manager/overview")`,
		`setInterval(refreshManager, 15000)`,
		`这里只查看，不发送暖号请求`,
	} {
		if !strings.Contains(html, required) {
			t.Fatalf("embedded web quota panel is missing %q", required)
		}
	}
	quota := strings.Index(html, `id="quota-panel"`)
	cli := strings.Index(html, `id="cli-panel"`)
	desktop := strings.Index(html, `<details id="desktop-panel">`)
	kimi := strings.Index(html, `<details id="kimi-panel">`)
	past := strings.Index(html, `<details id="past">`)
	if quota < 0 || !(quota < cli && cli < desktop && desktop < kimi && kimi < past) {
		t.Fatalf("embedded web is not in quota, pending, desktop, Kimi, past order")
	}
}

func TestEmbeddedWebOffersKimiCLIConversations(t *testing.T) {
	html := string(indexHTML)
	for _, required := range []string{
		`id="task-agent"`,
		`id="task-project"`,
		`id="task-account"`,
		`agent === "kimi" ? "system"`,
		`Codex 权限与模型胶囊在这里隐藏`,
		`if (event.type === "agent.output") {`,
		`state.taskOutput.set(event.taskId, lines)`,
	} {
		if !strings.Contains(html, required) {
			t.Fatalf("embedded web Kimi conversation UI is missing %q", required)
		}
	}
}

func TestManagerOverviewMissingFileReturnsServiceUnavailable(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	handler := (&API{hub: hub, token: []byte("test-token"), managerSnapshotPath: filepath.Join(t.TempDir(), "missing.json")}).routes()
	request := httptest.NewRequest(http.MethodGet, "/api/manager/overview", nil)
	request.Header.Set("Authorization", "Bearer test-token")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusServiceUnavailable || strings.TrimSpace(response.Body.String()) != `{"error":"manager_snapshot_unavailable"}` {
		t.Fatalf("missing snapshot returned %d: %s", response.Code, response.Body.String())
	}
}

func TestManagerOverviewMissingSnapshotUsesNullNotZero(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	path := filepath.Join(t.TempDir(), "snapshot.json")
	if err := os.WriteFile(path, []byte(`{"profiles":[{"name":"fallback","codexHomePath":"/unmatched"}]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	handler := (&API{hub: hub, token: []byte("test-token"), managerSnapshotPath: path}).routes()
	request := httptest.NewRequest(http.MethodGet, "/api/manager/overview", nil)
	request.Header.Set("Authorization", "Bearer test-token")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	var overview managerOverview
	if err := json.Unmarshal(response.Body.Bytes(), &overview); err != nil {
		t.Fatal(err)
	}
	account := overview.Accounts[0]
	if account.Alias != "fallback" || account.Source != "profile_name" || account.Status != "暂无数据" || account.FiveHourUsedPercent != nil || account.SevenDayUsedPercent != nil {
		t.Fatalf("missing snapshot was not represented as unavailable: %#v", account)
	}
}

func TestCodexBoardFiltersSpawnAggregatesPersistsRefsAndOpensRoot(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	board, err := newCodexBoard(config, hub)
	if err != nil {
		t.Fatal(err)
	}
	rootID := "11111111-1111-4111-8111-111111111111"
	childID := "22222222-2222-4222-8222-222222222222"
	grandchildID := "33333333-3333-4333-8333-333333333333"
	guardianID := "44444444-4444-4444-8444-444444444444"
	now := time.Now().Unix()
	rootName, childName, grandchildName := "zcode多agent远程控制", "观察器", "静态审查"
	raw := []appThreadWire{
		{ID: rootID, Name: &rootName, Cwd: config.Projects["demo"], Source: json.RawMessage(`"cli"`), Status: appThreadStatus{Type: "idle"}, CreatedAt: now, UpdatedAt: now},
		{ID: childID, Name: &childName, Cwd: config.Projects["demo"], ParentThreadID: &rootID, Source: spawnSource(t, rootID, "observer", 1), Status: appThreadStatus{Type: "idle"}, CreatedAt: now, UpdatedAt: now},
		{ID: grandchildID, Name: &grandchildName, Cwd: config.Projects["demo"], ParentThreadID: &childID, Source: spawnSource(t, childID, "reviewer", 2), Status: appThreadStatus{Type: "systemError"}, CreatedAt: now, UpdatedAt: now},
		{ID: guardianID, Name: &childName, Cwd: config.Projects["demo"], ParentThreadID: &rootID, Source: json.RawMessage(`{"subAgent":{"review":{}}}`), Status: appThreadStatus{Type: "active"}, CreatedAt: now, UpdatedAt: now},
	}
	loaded := map[string]bool{rootID: true, childID: true, grandchildID: true, guardianID: true}
	if err := board.replaceAppThreads(raw, loaded, observerSharedLive, time.Now().Add(-time.Second)); err != nil {
		t.Fatal(err)
	}
	overview := board.overview()
	if len(overview.Threads) != 3 {
		t.Fatalf("expected root plus two thread_spawn descendants, got %d", len(overview.Threads))
	}
	root := observedByTitle(t, overview.Threads, rootName)
	if root.RuntimeState != runtimeReady || root.AggregateState != runtimeError || root.LatestTurnState != turnUnknown || root.ReviewState != reviewUnreviewed {
		t.Fatalf("three-axis or descendant aggregation mismatch: %#v", root)
	}
	if root.SourceKind != "cli" {
		t.Fatalf("expected cli source kind for exec/cli root, got %#v", root)
	}
	encoded, err := json.Marshal(overview)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(encoded, []byte(rootID)) || bytes.Contains(encoded, []byte(config.Projects["demo"])) {
		t.Fatal("Codex overview leaked an internal thread id or project path")
	}
	info, err := os.Stat(filepath.Join(config.DataDir, "thread-refs.json"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("thread ref mapping is not private: %#o", info.Mode().Perm())
	}
	if err := board.setReview(root.PublicRef, reviewAccepted); err != nil {
		t.Fatal(err)
	}
	second, err := newCodexBoard(config, hub)
	if err != nil {
		t.Fatal(err)
	}
	if err := second.replaceAppThreads(raw, loaded, observerSharedLive, time.Now().Add(-time.Second)); err != nil {
		t.Fatal(err)
	}
	stable := observedByTitle(t, second.overview().Threads, rootName)
	if stable.PublicRef != root.PublicRef || stable.ReviewState != reviewAccepted {
		t.Fatalf("public ref or review state did not survive reload: %#v", stable)
	}
	opened := ""
	second.opener = func(threadID string) error { opened = threadID; return nil }
	child := observedByTitle(t, second.overview().Threads, childName)
	token := []byte("01234567890123456789012345678901")
	handler := (&API{hub: hub, board: second, token: token}).routes()
	get := httptest.NewRequest(http.MethodGet, "/api/codex/overview", nil)
	get.Header.Set("Authorization", "Bearer "+string(token))
	getResponse := httptest.NewRecorder()
	handler.ServeHTTP(getResponse, get)
	if getResponse.Code != http.StatusOK || strings.Contains(getResponse.Body.String(), rootID) || strings.Contains(getResponse.Body.String(), config.Projects["demo"]) {
		t.Fatalf("Codex API leaked internal state: %d %s", getResponse.Code, getResponse.Body.String())
	}
	openRequest := httptest.NewRequest(http.MethodPost, "/api/codex/threads/"+child.PublicRef+"/open", nil)
	openRequest.Header.Set("Authorization", "Bearer "+string(token))
	openResponse := httptest.NewRecorder()
	handler.ServeHTTP(openResponse, openRequest)
	if openResponse.Code != http.StatusOK || opened != rootID {
		t.Fatalf("subagent API open did not safely fall back to root: %d %q", openResponse.Code, opened)
	}
	rawRequest := httptest.NewRequest(http.MethodPost, "/api/codex/threads/"+rootID+"/open", nil)
	rawRequest.Header.Set("Authorization", "Bearer "+string(token))
	rawResponse := httptest.NewRecorder()
	handler.ServeHTTP(rawResponse, rawRequest)
	if rawResponse.Code != http.StatusNotFound {
		t.Fatalf("raw internal thread id was accepted by API: %d", rawResponse.Code)
	}
}

func TestCodexThreadContentReadsPagedItemsAndRedactsPrivateData(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	hub, err := newHub(config, "sensitive-marker-123")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	board, err := newCodexBoard(config, hub)
	if err != nil {
		t.Fatal(err)
	}
	threadID := "11111111-1111-4111-8111-111111111111"
	name := "读取真实内容"
	if err := board.replaceAppThreads([]appThreadWire{{
		ID: threadID, Name: &name, Cwd: config.Projects["demo"], Source: json.RawMessage(`"appServer"`),
		Status: appThreadStatus{Type: "idle"}, CreatedAt: time.Now().Unix(), UpdatedAt: time.Now().Unix(),
	}}, map[string]bool{threadID: true}, observerSharedLive, time.Now()); err != nil {
		t.Fatal(err)
	}
	publicRef := observedByTitle(t, board.overview().Threads, name).PublicRef

	server, connection := net.Pipe()
	client := &appServerClient{
		encoder: json.NewEncoder(connection), input: connection, pending: make(map[int64]chan appRPCResult), nextID: 2,
		done: make(chan struct{}), cancel: func() {}, board: board, mode: observerSharedLive,
	}
	go client.readLoop(connection)
	board.publishClient(client)
	responseSent := make(chan error, 1)
	go func() {
		defer server.Close()
		decoder, encoder := json.NewDecoder(server), json.NewEncoder(server)
		var request struct {
			ID     int64  `json:"id"`
			Method string `json:"method"`
			Params struct {
				ThreadID      string `json:"threadId"`
				TurnID        string `json:"turnId"`
				Limit         int    `json:"limit"`
				SortDirection string `json:"sortDirection"`
				ItemsView     string `json:"itemsView"`
			} `json:"params"`
		}
		if err := decoder.Decode(&request); err != nil {
			responseSent <- err
			return
		}
		if request.Method != "thread/turns/list" || request.Params.ThreadID != threadID || request.Params.Limit != 8 || request.Params.SortDirection != "desc" || request.Params.ItemsView != "summary" {
			responseSent <- fmt.Errorf("unexpected content request: %#v", request)
			return
		}
		turnID := "22222222-2222-4222-8222-222222222222"
		if err := encoder.Encode(map[string]any{
			"id": request.ID,
			"result": map[string]any{
				"nextCursor": "older",
				"data": []any{map[string]any{
					"id":     turnID,
					"status": "completed", "startedAt": int64(1_725_000_000), "completedAt": int64(1_725_000_002),
					"items": []any{},
				}},
			},
		}); err != nil {
			responseSent <- err
			return
		}
		if err := decoder.Decode(&request); err != nil {
			responseSent <- err
			return
		}
		if request.Method != "thread/items/list" || request.Params.ThreadID != threadID || request.Params.TurnID != turnID || request.Params.Limit != 16 || request.Params.SortDirection != "desc" {
			responseSent <- fmt.Errorf("unexpected item page request: %#v", request)
			return
		}
		content := []any{
			map[string]any{"type": "commandExecution", "command": "ls /Users/private/work", "aggregatedOutput": "sk-" + "abcdefghijklmnopqrstuvwxyz sensitive-marker-123", "status": "completed"},
			map[string]any{"type": "agentMessage", "text": "已经读到真实回复"},
			map[string]any{"type": "reasoning", "summary": []string{"绝不能下发的推理"}},
			map[string]any{"type": "userMessage", "content": []any{map[string]any{"type": "text", "text": "真实问题 user@example.com " + threadID}}},
		}
		entries := make([]any, 0, len(content))
		for _, item := range content {
			entries = append(entries, map[string]any{"turnId": turnID, "item": item})
		}
		responseSent <- encoder.Encode(map[string]any{"id": request.ID, "result": map[string]any{"data": entries}})
	}()

	token := []byte("01234567890123456789012345678901")
	handler := (&API{hub: hub, board: board, token: token}).routes()
	request := httptest.NewRequest(http.MethodGet, "/api/codex/threads/"+publicRef, nil)
	request.Header.Set("Authorization", "Bearer "+string(token))
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if err := <-responseSent; err != nil {
		t.Fatal(err)
	}
	body := response.Body.String()
	if response.Code != http.StatusOK || !strings.Contains(body, "真实问题") || !strings.Contains(body, "已经读到真实回复") || !strings.Contains(body, `"hasMore":true`) {
		t.Fatalf("thread content missing: %d %s", response.Code, body)
	}
	for _, private := range []string{threadID, "user@example.com", "/Users/private/work", "abcdefghijklmnopqrstuvwxyz", "sensitive-marker-123", "绝不能下发的推理"} {
		if strings.Contains(body, private) {
			t.Fatalf("thread content leaked private data %q: %s", private, body)
		}
	}
	board.retireClient(client)

	unavailableRequest := httptest.NewRequest(http.MethodGet, "/api/codex/threads/"+publicRef, nil)
	unavailableRequest.Header.Set("Authorization", "Bearer "+string(token))
	unavailable := httptest.NewRecorder()
	handler.ServeHTTP(unavailable, unavailableRequest)
	if unavailable.Code != http.StatusServiceUnavailable || !strings.Contains(unavailable.Body.String(), "codex_content_unavailable") {
		t.Fatalf("missing observer did not fail closed: %d %s", unavailable.Code, unavailable.Body.String())
	}
	rawRequest := httptest.NewRequest(http.MethodGet, "/api/codex/threads/"+threadID, nil)
	rawRequest.Header.Set("Authorization", "Bearer "+string(token))
	rawResponse := httptest.NewRecorder()
	handler.ServeHTTP(rawResponse, rawRequest)
	if rawResponse.Code != http.StatusNotFound {
		t.Fatalf("raw internal thread id was accepted for content: %d", rawResponse.Code)
	}
}

func TestCodexBoardPreservesKnownCwdWhenSharedDaemonUnloadsThread(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	board, err := newCodexBoard(config, hub)
	if err != nil {
		t.Fatal(err)
	}
	threadID := "11111111-1111-4111-8111-111111111111"
	name := "卸载后仍可恢复"
	now := time.Now().Unix()
	item := appThreadWire{
		ID: threadID, Name: &name, Cwd: config.Projects["demo"], Source: json.RawMessage(`"appServer"`),
		Status: appThreadStatus{Type: "idle"}, CreatedAt: now, UpdatedAt: now,
	}
	if err := board.replaceAppThreads([]appThreadWire{item}, map[string]bool{threadID: true}, observerSharedLive, time.Now()); err != nil {
		t.Fatal(err)
	}
	item.Cwd = ""
	if err := board.replaceAppThreads([]appThreadWire{item}, map[string]bool{}, observerSharedLive, time.Now()); err != nil {
		t.Fatal(err)
	}
	thread := board.threads[threadID]
	if thread.Cwd != config.Projects["demo"] || thread.ProjectAlias != "demo" {
		t.Fatalf("shared daemon unload lost known project routing: %#v", thread)
	}
	if _, allowed := board.desktopControlCwd(thread); !allowed {
		t.Fatal("preserved project routing did not pass the existing control boundary")
	}
}

func TestCodexDesktopControlUsesCurrentSharedClientAndExactTurns(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	board, err := newCodexBoard(config, hub)
	if err != nil {
		t.Fatal(err)
	}
	cwd := filepath.Join(config.Projects["demo"], "nested")
	if err := os.Mkdir(cwd, 0o700); err != nil {
		t.Fatal(err)
	}
	resolvedCwd, err := filepath.EvalSymlinks(cwd)
	if err != nil {
		t.Fatal(err)
	}
	threadID := "11111111-1111-4111-8111-111111111111"
	turnID := "22222222-2222-4222-8222-222222222222"
	staleTurnID := "33333333-3333-4333-8333-333333333333"
	name := "桌面对话"
	if err := board.replaceAppThreads([]appThreadWire{{
		ID: threadID, Name: &name, Cwd: cwd, Source: json.RawMessage(`"appServer"`),
		Status: appThreadStatus{Type: "idle"}, CreatedAt: time.Now().Unix(), UpdatedAt: time.Now().Unix(),
	}}, map[string]bool{threadID: true}, observerSharedLive, time.Now()); err != nil {
		t.Fatal(err)
	}
	publicRef := observedByTitle(t, board.overview().Threads, name).PublicRef
	token := []byte("01234567890123456789012345678901")
	handler := (&API{hub: hub, board: board, token: token}).routes()
	post := func(path, body string) *httptest.ResponseRecorder {
		t.Helper()
		request := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
		request.Header.Set("Authorization", "Bearer "+string(token))
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		return response
	}
	type rpcRequest struct {
		ID     int64          `json:"id"`
		Method string         `json:"method"`
		Params map[string]any `json:"params"`
	}
	replyFreshRead := func(decoder *json.Decoder, encoder *json.Encoder, state string) error {
		var request rpcRequest
		if err := decoder.Decode(&request); err != nil {
			return err
		}
		if request.Method != "thread/read" || request.Params["threadId"] != threadID || request.Params["includeTurns"] != false {
			return fmt.Errorf("expected fresh thread metadata before control: %#v", request)
		}
		return encoder.Encode(map[string]any{"id": request.ID, "result": map[string]any{"thread": map[string]any{
			"id": threadID, "cwd": resolvedCwd, "status": map[string]any{"type": state},
		}}})
	}
	inputText := func(params map[string]any) (string, bool) {
		inputs, ok := params["input"].([]any)
		if !ok || len(inputs) != 1 {
			return "", false
		}
		input, ok := inputs[0].(map[string]any)
		if !ok || len(input) != 3 || input["type"] != "text" {
			return "", false
		}
		if elements, ok := input["text_elements"].([]any); !ok || len(elements) != 0 {
			return "", false
		}
		text, ok := input["text"].(string)
		return text, ok
	}
	newClient := func() (net.Conn, *appServerClient) {
		server, connection := net.Pipe()
		client := &appServerClient{
			encoder: json.NewEncoder(connection), input: connection, pending: make(map[int64]chan appRPCResult), nextID: 2,
			done: make(chan struct{}), cancel: func() {}, board: board, mode: observerSharedLive,
		}
		go client.readLoop(connection)
		board.publishClient(client)
		return server, client
	}

	startServer, startClient := newClient()
	startDone := make(chan error, 1)
	startRelease := make(chan struct{})
	go func() {
		defer startServer.Close()
		decoder, encoder := json.NewDecoder(startServer), json.NewEncoder(startServer)
		if err := replyFreshRead(decoder, encoder, "idle"); err != nil {
			startDone <- err
			return
		}
		var resume rpcRequest
		if err := decoder.Decode(&resume); err != nil {
			startDone <- err
			return
		}
		if resume.Method != "thread/resume" || len(resume.Params) != 4 || resume.Params["threadId"] != threadID || resume.Params["cwd"] != resolvedCwd || resume.Params["excludeTurns"] != true || resume.Params["sandbox"] != "read-only" {
			startDone <- fmt.Errorf("unexpected resume request: %#v", resume)
			return
		}
		if err := encoder.Encode(map[string]any{"id": resume.ID, "result": map[string]any{"thread": map[string]any{"id": threadID}}}); err != nil {
			startDone <- err
			return
		}
		var start rpcRequest
		if err := decoder.Decode(&start); err != nil {
			startDone <- err
			return
		}
		text, validInput := inputText(start.Params)
		sandboxPolicy, validSandbox := start.Params["sandboxPolicy"].(map[string]any)
		if start.Method != "turn/start" || len(start.Params) != 5 || start.Params["threadId"] != threadID || start.Params["cwd"] != resolvedCwd || start.Params["clientUserMessageId"] != "desktop-start-0001" || !validInput || text != "第一条消息" || !validSandbox || sandboxPolicy["type"] != "readOnly" || sandboxPolicy["networkAccess"] != false {
			startDone <- fmt.Errorf("unexpected start request: %#v", start)
			return
		}
		if err := encoder.Encode(map[string]any{
			"id": 77, "method": "item/commandExecution/requestApproval", "params": map[string]any{"command": "private command"},
		}); err != nil {
			startDone <- err
			return
		}
		var rejected map[string]json.RawMessage
		if err := decoder.Decode(&rejected); err != nil {
			startDone <- err
			return
		}
		var rejectedID int64
		var rejection struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		}
		if len(rejected) != 2 || json.Unmarshal(rejected["id"], &rejectedID) != nil || rejectedID != 77 || json.Unmarshal(rejected["error"], &rejection) != nil || rejection.Code != -32601 || rejection.Message != "unsupported_server_request" {
			startDone <- fmt.Errorf("server request was not rejected safely: %s", rejected)
			return
		}
		if err := encoder.Encode(map[string]any{
			"method": "turn/started", "params": map[string]any{"threadId": threadID, "turn": map[string]any{"id": turnID, "status": "inProgress"}},
		}); err != nil {
			startDone <- err
			return
		}
		if err := encoder.Encode(map[string]any{"id": start.ID, "result": map[string]any{"turn": map[string]any{"id": turnID}}}); err != nil {
			startDone <- err
			return
		}
		startDone <- nil
		<-startRelease
	}()

	started := post("/api/codex/threads/"+publicRef+"/messages", `{"requestId":"desktop-start-0001","text":"第一条消息"}`)
	if started.Code != http.StatusOK {
		board.retireClient(startClient)
		t.Fatalf("desktop start failed before RPC completion: %d %s server=%v", started.Code, started.Body.String(), <-startDone)
	}
	if err := <-startDone; err != nil {
		t.Fatal(err)
	}
	if started.Code != http.StatusOK || !strings.Contains(started.Body.String(), `"status":"started"`) || strings.Contains(started.Body.String(), threadID) || strings.Contains(started.Body.String(), turnID) {
		t.Fatalf("desktop start failed or leaked internal ids: %d %s", started.Code, started.Body.String())
	}
	active := observedByTitle(t, board.overview().Threads, name)
	if !active.CanMessage || !active.CanInterrupt || active.LatestTurnState != turnInProgress {
		t.Fatalf("started turn capabilities were not published safely: %#v", active)
	}
	close(startRelease)
	board.retireClient(startClient)

	activeServer, activeClient := newClient()
	activeDone := make(chan error, 1)
	activeRelease := make(chan struct{})
	go func() {
		defer activeServer.Close()
		decoder, encoder := json.NewDecoder(activeServer), json.NewEncoder(activeServer)
		if err := replyFreshRead(decoder, encoder, "active"); err != nil {
			activeDone <- err
			return
		}
		var steer rpcRequest
		if err := decoder.Decode(&steer); err != nil {
			activeDone <- err
			return
		}
		text, validInput := inputText(steer.Params)
		if steer.Method != "turn/steer" || len(steer.Params) != 4 || steer.Params["threadId"] != threadID || steer.Params["expectedTurnId"] != turnID || steer.Params["clientUserMessageId"] != "desktop-steer-0001" || !validInput || text != "补充信息" {
			activeDone <- fmt.Errorf("unexpected steer request: %#v", steer)
			return
		}
		if err := encoder.Encode(map[string]any{"id": steer.ID, "result": map[string]any{}}); err != nil {
			activeDone <- err
			return
		}
		var interrupt rpcRequest
		if err := replyFreshRead(decoder, encoder, "active"); err != nil {
			activeDone <- err
			return
		}
		if err := decoder.Decode(&interrupt); err != nil {
			activeDone <- err
			return
		}
		if interrupt.Method != "turn/interrupt" || len(interrupt.Params) != 2 || interrupt.Params["threadId"] != threadID || interrupt.Params["turnId"] != turnID {
			activeDone <- fmt.Errorf("unexpected interrupt request: %#v", interrupt)
			return
		}
		if err := encoder.Encode(map[string]any{"id": interrupt.ID, "result": map[string]any{}}); err != nil {
			activeDone <- err
			return
		}
		activeDone <- nil
		<-activeRelease
	}()

	steered := post("/api/codex/threads/"+publicRef+"/messages", `{"requestId":"desktop-steer-0001","text":"补充信息"}`)
	if steered.Code != http.StatusOK {
		board.retireClient(activeClient)
		t.Fatalf("desktop steer failed before RPC completion: %d %s server=%v", steered.Code, steered.Body.String(), <-activeDone)
	}
	if steered.Code != http.StatusOK || !strings.Contains(steered.Body.String(), `"status":"steered"`) {
		t.Fatalf("desktop steer failed: %d %s", steered.Code, steered.Body.String())
	}
	interrupted := post("/api/codex/threads/"+publicRef+"/interrupt", `{}`)
	if interrupted.Code != http.StatusOK {
		board.retireClient(activeClient)
		t.Fatalf("desktop interrupt failed before RPC completion: %d %s server=%v", interrupted.Code, interrupted.Body.String(), <-activeDone)
	}
	if err := <-activeDone; err != nil {
		t.Fatal(err)
	}
	if interrupted.Code != http.StatusOK || !strings.Contains(interrupted.Body.String(), `"status":"interrupt_requested"`) {
		t.Fatalf("desktop interrupt failed: %d %s", interrupted.Code, interrupted.Body.String())
	}
	board.mu.RLock()
	gotActiveTurn := board.threads[threadID].ActiveTurnID
	board.mu.RUnlock()
	if gotActiveTurn != turnID {
		t.Fatal("interrupt RPC acknowledgement cleared the active turn before terminal evidence")
	}
	board.handleNotification(observerSharedLive, "turn/completed", json.RawMessage(`{"threadId":"`+threadID+`","turn":{"id":"`+staleTurnID+`","status":"completed"}}`))
	board.mu.RLock()
	gotActiveTurn = board.threads[threadID].ActiveTurnID
	board.mu.RUnlock()
	if gotActiveTurn != turnID {
		t.Fatal("stale terminal notification cleared a newer active turn")
	}
	board.handleNotification(observerSharedLive, "turn/completed", json.RawMessage(`{"threadId":"`+threadID+`","turn":{"id":"`+turnID+`","status":"interrupted"}}`))
	completed := observedByTitle(t, board.overview().Threads, name)
	if !completed.CanMessage || completed.CanInterrupt || completed.LatestTurnState != turnInterrupted {
		t.Fatalf("matching terminal notification did not clear the active turn: %#v", completed)
	}
	board.mu.Lock()
	board.threads[threadID].SourceKind = "desktop"
	board.threads[threadID].RuntimeState = runtimeWorking
	board.threads[threadID].LatestTurnState = turnInProgress
	board.threads[threadID].ActiveTurnID = ""
	board.mode = observerSharedLive
	board.mu.Unlock()
	missingTurn := post("/api/codex/threads/"+publicRef+"/messages", `{"requestId":"desktop-missing-0001","text":"不能盲发"}`)
	if missingTurn.Code != http.StatusConflict {
		t.Fatalf("active thread without an exact turn id did not fail closed: %d %s", missingTurn.Code, missingTurn.Body.String())
	}
	board.mu.Lock()
	board.mode = observerHistoryOnly
	board.mu.Unlock()
	historyOnly := post("/api/codex/threads/"+publicRef+"/messages", `{"requestId":"desktop-history-0001","text":"不能写历史连接"}`)
	if historyOnly.Code != http.StatusServiceUnavailable || !strings.Contains(historyOnly.Body.String(), "codex_control_unavailable") {
		t.Fatalf("history-only client accepted a write: %d %s", historyOnly.Code, historyOnly.Body.String())
	}
	board.mu.Lock()
	board.mode = observerSharedLive
	board.threads[threadID].SourceKind = "cli"
	board.threads[threadID].RuntimeState = runtimeReady
	board.threads[threadID].LatestTurnState = turnCompleted
	board.threads[threadID].ActiveTurnID = ""
	board.mu.Unlock()
	cli := post("/api/codex/threads/"+publicRef+"/messages", `{"requestId":"desktop-cli-0001","text":"不能写 CLI"}`)
	if cli.Code != http.StatusConflict {
		t.Fatalf("CLI thread accepted a Desktop write: %d %s", cli.Code, cli.Body.String())
	}
	escape := filepath.Join(config.Projects["demo"], "escape")
	if err := os.Symlink(t.TempDir(), escape); err != nil {
		t.Fatal(err)
	}
	board.mu.Lock()
	board.threads[threadID].SourceKind = "desktop"
	board.threads[threadID].Cwd = escape
	board.mu.Unlock()
	escaped := post("/api/codex/threads/"+publicRef+"/messages", `{"requestId":"desktop-escape-0001","text":"不能越界"}`)
	if escaped.Code != http.StatusConflict || observedByTitle(t, board.overview().Threads, name).CanMessage {
		t.Fatalf("symlink cwd escaped the project allowlist: %d %s", escaped.Code, escaped.Body.String())
	}
	empty := post("/api/codex/threads/"+publicRef+"/messages", `{"requestId":"desktop-empty-0001","text":"   "}`)
	if empty.Code != http.StatusBadRequest {
		t.Fatalf("blank Desktop message was accepted: %d %s", empty.Code, empty.Body.String())
	}
	close(activeRelease)
	board.retireClient(activeClient)
}

func TestCodexLatestTurnSnapshotCarriesExactActiveID(t *testing.T) {
	threadID := "11111111-1111-4111-8111-111111111111"
	turnID := "22222222-2222-4222-8222-222222222222"
	board := &CodexBoard{threads: map[string]*ObservedThread{
		threadID: {InternalID: threadID, LatestTurnState: turnUnknown},
	}}
	server, connection := net.Pipe()
	client := &appServerClient{
		encoder: json.NewEncoder(connection), input: connection, pending: make(map[int64]chan appRPCResult), nextID: 2,
		done: make(chan struct{}), cancel: func() {}, board: board, mode: observerSharedLive,
	}
	go client.readLoop(connection)
	serverDone := make(chan error, 1)
	go func() {
		defer server.Close()
		var request struct {
			ID     int64  `json:"id"`
			Method string `json:"method"`
			Params struct {
				ThreadID      string `json:"threadId"`
				Limit         int    `json:"limit"`
				SortDirection string `json:"sortDirection"`
				ItemsView     string `json:"itemsView"`
			} `json:"params"`
		}
		if err := json.NewDecoder(server).Decode(&request); err != nil {
			serverDone <- err
			return
		}
		if request.Method != "thread/turns/list" || request.Params.ThreadID != threadID || request.Params.Limit != 1 || request.Params.SortDirection != "desc" || request.Params.ItemsView != "notLoaded" {
			serverDone <- fmt.Errorf("unexpected latest turn request: %#v", request)
			return
		}
		serverDone <- json.NewEncoder(server).Encode(map[string]any{
			"id": request.ID, "result": map[string]any{"data": []any{map[string]any{"id": turnID, "status": "inProgress"}}},
		})
	}()
	latest := client.latestTurn(context.Background(), threadID)
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
	queryStarted := time.Now().UTC()
	board.mergeLatestTurns(map[string]appTurnWire{threadID: latest}, queryStarted)
	board.mu.RLock()
	got := board.threads[threadID]
	board.mu.RUnlock()
	if got.LatestTurnState != turnInProgress || got.ActiveTurnID != turnID {
		t.Fatalf("latest turn snapshot lost the exact active id: %#v", got)
	}
	client.close()
}

func TestCodexStartAckCannotReviveCompletedTurn(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	board, err := newCodexBoard(config, hub)
	if err != nil {
		t.Fatal(err)
	}
	threadID := "11111111-1111-4111-8111-111111111111"
	turnID := "22222222-2222-4222-8222-222222222222"
	name := "快速完成对话"
	if err := board.replaceAppThreads([]appThreadWire{{
		ID: threadID, Name: &name, Cwd: config.Projects["demo"], Source: json.RawMessage(`"appServer"`),
		Status: appThreadStatus{Type: "idle"}, CreatedAt: time.Now().Unix(), UpdatedAt: time.Now().Unix(),
	}}, map[string]bool{threadID: true}, observerSharedLive, time.Now()); err != nil {
		t.Fatal(err)
	}
	requestStarted := time.Now().UTC()
	board.handleNotification(observerSharedLive, "turn/started", json.RawMessage(`{"threadId":"`+threadID+`","turn":{"id":"`+turnID+`","status":"inProgress"}}`))
	board.handleNotification(observerSharedLive, "turn/completed", json.RawMessage(`{"threadId":"`+threadID+`","turn":{"id":"`+turnID+`","status":"completed"}}`))
	board.recordStartedTurn(threadID, turnID, requestStarted)
	thread := observedByTitle(t, board.overview().Threads, name)
	if thread.LatestTurnState != turnCompleted || thread.RuntimeState != runtimeReady || thread.CanInterrupt {
		t.Fatalf("late start acknowledgement revived a completed turn: %#v", thread)
	}
	board.mu.RLock()
	activeTurnID := board.threads[threadID].ActiveTurnID
	board.mu.RUnlock()
	if activeTurnID != "" {
		t.Fatalf("late start acknowledgement restored active turn %q", activeTurnID)
	}
}

func TestCodexBoardThreadStartedRequestsOneRefresh(t *testing.T) {
	board := &CodexBoard{
		threads:        make(map[string]*ObservedThread),
		pendingRuntime: make(map[string]pendingRuntimeUpdate),
		pendingTurns:   make(map[string]pendingTurnUpdate),
		refreshNow:     make(chan struct{}, 1),
		mode:           observerSharedLive,
	}
	board.handleNotification(observerSharedLive, "thread/started", json.RawMessage(`{}`))
	board.handleNotification(observerSharedLive, "thread/started", json.RawMessage(`{}`))
	select {
	case <-board.refreshNow:
	default:
		t.Fatal("thread/started did not request a refresh")
	}
	select {
	case <-board.refreshNow:
		t.Fatal("thread/started refresh requests did not coalesce")
	default:
	}
}

func TestCodexBoardPromotesHistoryOnlyAfterSuccessfulSharedRefresh(t *testing.T) {
	board := &CodexBoard{
		threads: map[string]*ObservedThread{
			"history": {InternalID: "history", Title: "历史任务"},
		},
		mode: observerHistoryOnly,
	}
	history := &appServerClient{done: make(chan struct{}), pending: make(map[int64]chan appRPCResult), cancel: func() {}, mode: observerHistoryOnly}
	board.publishClient(history)

	failed := &appServerClient{done: make(chan struct{}), pending: make(map[int64]chan appRPCResult), cancel: func() {}, mode: observerSharedLive}
	got, promoted := promoteHistoryClient(context.Background(), board, history,
		func(context.Context, *CodexBoard) (*appServerClient, error) { return failed, nil },
		func(context.Context, *appServerClient) error { return errors.New("first refresh failed") },
	)
	if promoted || got != history {
		t.Fatal("failed shared probe replaced the history client")
	}
	board.clientMu.RLock()
	published := board.client
	board.clientMu.RUnlock()
	if published != history || board.threads["history"] == nil || board.mode != observerHistoryOnly {
		t.Fatal("failed shared probe discarded the history snapshot")
	}

	shared := &appServerClient{done: make(chan struct{}), pending: make(map[int64]chan appRPCResult), cancel: func() {}, mode: observerSharedLive}
	got, promoted = promoteHistoryClient(context.Background(), board, history,
		func(context.Context, *CodexBoard) (*appServerClient, error) { return shared, nil },
		func(context.Context, *appServerClient) error {
			board.mu.Lock()
			board.threads["live"] = &ObservedThread{InternalID: "live", Title: "实时任务"}
			board.mode = observerSharedLive
			board.mu.Unlock()
			return nil
		},
	)
	if !promoted || got != shared {
		t.Fatal("successful shared probe did not promote the client")
	}
	board.clientMu.RLock()
	published = board.client
	board.clientMu.RUnlock()
	if published != shared || board.threads["live"] == nil || board.mode != observerSharedLive {
		t.Fatal("shared client was published before its refreshed snapshot became available")
	}
	select {
	case <-history.done:
	default:
		t.Fatal("history client was not retired after promotion")
	}
	board.retireClient(shared)
}

func TestSharedAppServerSocketRejectsMissingAndInvalidSockets(t *testing.T) {
	codexHome := t.TempDir()
	if _, err := sharedAppServerSocket(codexHome); err == nil || err.Error() != "app_server_socket_unavailable" {
		t.Fatalf("missing socket: %v", err)
	}

	controlDir := filepath.Join(codexHome, "app-server-control")
	if err := os.MkdirAll(controlDir, 0o700); err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(controlDir, "app-server-control.sock")
	if err := os.WriteFile(socket, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := sharedAppServerSocket(codexHome); err == nil || err.Error() != "app_server_socket_invalid" {
		t.Fatalf("regular file: %v", err)
	}

	if err := os.Remove(socket); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(controlDir, "missing"), socket); err != nil {
		t.Fatal(err)
	}
	if _, err := sharedAppServerSocket(codexHome); err == nil || err.Error() != "app_server_socket_invalid" {
		t.Fatalf("symlink: %v", err)
	}
}

func TestObserverDoesNotSpawnAppServerWithoutSharedSocket(t *testing.T) {
	home := t.TempDir()
	bin := t.TempDir()
	marker := filepath.Join(t.TempDir(), "spawned")
	script := filepath.Join(bin, "codex")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf spawned > "+marker+"\nexec cat\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))

	board := &CodexBoard{config: Config{Commands: map[string]string{"codex": "codex"}}}
	client, err := startSharedAppServerClientFromHome(context.Background(), board, home)
	if client != nil {
		client.close()
		t.Fatal("started an observer without a shared socket")
	}
	if err == nil || err.Error() != "app_server_socket_unavailable" {
		t.Fatalf("missing socket: %v", err)
	}
	time.Sleep(50 * time.Millisecond)
	if _, statErr := os.Stat(marker); statErr == nil {
		t.Fatal("spawned a competing codex app-server")
	}
}

func TestCodexRuntimeStateMapping(t *testing.T) {
	cases := []struct {
		status appThreadStatus
		want   CodexRuntimeState
	}{
		{appThreadStatus{Type: "active", ActiveFlags: []string{"waitingOnUserInput"}}, runtimeNeedsInput},
		{appThreadStatus{Type: "active", ActiveFlags: []string{"waitingOnApproval"}}, runtimeNeedsInput},
		{appThreadStatus{Type: "active"}, runtimeWorking},
		{appThreadStatus{Type: "idle"}, runtimeReady},
		{appThreadStatus{Type: "systemError"}, runtimeError},
		{appThreadStatus{Type: "notLoaded"}, runtimeNotLoaded},
	}
	for _, item := range cases {
		if got := runtimeStateFromApp(item.status); got != item.want {
			t.Fatalf("runtime mapping %q: got %q want %q", item.status.Type, got, item.want)
		}
	}
}

func TestFindingLifecycleReplaysAndRejectsUnverifiedSuccess(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	sensitiveMarker := "sensitive-marker-123"
	hub, err := newHub(config, sensitiveMarker)
	if err != nil {
		t.Fatal(err)
	}
	threadRef := "55555555-5555-4555-8555-555555555555"
	if _, err := hub.createFinding(CreateFindingRequest{RequestID: "finding-private-0001", ThreadPublicRef: threadRef, Title: "/Users/private/secret"}); !errors.Is(err, errInvalid) {
		t.Fatalf("private path finding title was accepted: %v", err)
	}
	finding, err := hub.createFinding(CreateFindingRequest{RequestID: "finding-create-0001", ThreadPublicRef: threadRef, Title: "状态聚合错误"})
	if err != nil {
		t.Fatal(err)
	}
	future := time.Now().UTC().Add(time.Hour)
	hub.mu.Lock()
	hub.findings[finding.ID].UpdatedAt = future
	hub.mu.Unlock()
	finding, err = hub.changeFinding(finding.ID, ChangeFindingRequest{RequestID: "finding-start-0001", ExpectedVersion: finding.Version, EventType: "started"})
	if err != nil || finding.WorkState != findingInProgress || !finding.UpdatedAt.After(future) {
		t.Fatalf("start failed: %#v %v", finding, err)
	}
	finding, err = hub.changeFinding(finding.ID, ChangeFindingRequest{RequestID: "finding-resolve-0001", ExpectedVersion: finding.Version, EventType: "resolved", Resolution: resolutionFixed})
	if err != nil || finding.WorkState != findingResolved || finding.FixVerification != verificationUnverified {
		t.Fatalf("resolve failed: %#v %v", finding, err)
	}
	if _, err := hub.changeFinding(finding.ID, ChangeFindingRequest{RequestID: "finding-verify-bad", ExpectedVersion: finding.Version, EventType: "verified"}); !errors.Is(err, errConflict) {
		t.Fatalf("verification without evidence was accepted: %v", err)
	}
	if _, err := hub.changeFinding(finding.ID, ChangeFindingRequest{RequestID: "finding-verify-secret", ExpectedVersion: finding.Version, EventType: "verified", EvidenceKind: "test", EvidenceRef: sensitiveMarker}); !errors.Is(err, errInvalid) {
		t.Fatalf("secret evidence was accepted: %v", err)
	}
	finding, err = hub.changeFinding(finding.ID, ChangeFindingRequest{RequestID: "finding-verify-0001", ExpectedVersion: finding.Version, EventType: "verified", EvidenceKind: "test", EvidenceRef: "go-test"})
	if err != nil || finding.FixVerification != verificationVerified {
		t.Fatalf("verification failed: %#v %v", finding, err)
	}
	finding, err = hub.changeFinding(finding.ID, ChangeFindingRequest{RequestID: "finding-reopen-0001", ExpectedVersion: finding.Version, EventType: "reopened", Reason: "reproduced"})
	if err != nil || finding.WorkState != findingActive || finding.FixVerification != verificationFailed {
		t.Fatalf("reopen failed: %#v %v", finding, err)
	}
	if err := hub.store.Close(); err != nil {
		t.Fatal(err)
	}
	replayed, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { replayed.shutdown(context.Background()) })
	details, err := replayed.findingDetails(finding.ID)
	if err != nil || len(details.Events) != 5 || details.Finding.FixVerification != verificationFailed {
		t.Fatalf("finding replay mismatch: %#v %v", details, err)
	}
}

func TestInvalidFindingJournalFailsClosed(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	if err := os.Mkdir(config.DataDir, 0o700); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	finding := Finding{ID: "66666666-6666-4666-8666-666666666666", Version: 1, ThreadPublicRef: "77777777-7777-4777-8777-777777777777", Title: "非法首条事件", WorkState: findingInProgress, FixVerification: verificationUnverified, CreatedAt: now, UpdatedAt: now}
	change := FindingEvent{FindingID: finding.ID, EventType: "started", ToState: findingInProgress, Actor: "operator", Timestamp: now}
	dto := finding.dto()
	entry := journalEvent{RecordKind: "finding", Event: PublicEvent{Seq: 1, Version: 1, FindingID: finding.ID, Type: "finding.started", OccurredAt: now, Finding: &dto, FindingChange: &change}, Finding: &finding, FindingEvent: &change}
	line, err := json.Marshal(entry)
	if err != nil {
		t.Fatal(err)
	}
	line = append(line, '\n')
	if err := os.WriteFile(filepath.Join(config.DataDir, "events.ndjson"), line, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := newHub(config); err == nil {
		t.Fatal("illegal first finding transition did not fail closed")
	}
}

func TestLegacyTaskJournalWithoutRecordKindReplays(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	task, err := hub.create(CreateRequest{RequestID: "legacy-create-0001", Agent: "codex", Project: "demo", Prompt: "not persisted"})
	if err != nil {
		t.Fatal(err)
	}
	if err := hub.store.Close(); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(config.DataDir, "events.ndjson")
	line, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var legacy map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(line), &legacy); err != nil {
		t.Fatal(err)
	}
	delete(legacy, "recordKind")
	line, err = json.Marshal(legacy)
	if err != nil {
		t.Fatal(err)
	}
	line = append(line, '\n')
	if err := os.WriteFile(path, line, 0o600); err != nil {
		t.Fatal(err)
	}
	replayed, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { replayed.shutdown(context.Background()) })
	if recovered := taskByID(t, replayed, task.ID); recovered.State != stateBlockedConfiguration {
		t.Fatalf("legacy task did not replay through fail-closed recovery: %#v", recovered)
	}
}

func TestTaskJournalWithOlderEventSnapshotReplays(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	task, err := hub.create(CreateRequest{RequestID: "old-snapshot-create-0001", Agent: "codex", Project: "demo", Prompt: "not persisted"})
	if err != nil {
		t.Fatal(err)
	}
	if err := hub.store.Close(); err != nil {
		t.Fatal(err)
	}

	path := filepath.Join(config.DataDir, "events.ndjson")
	line, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var entry map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(line), &entry); err != nil {
		t.Fatal(err)
	}
	event := entry["event"].(map[string]any)
	snapshot := event["task"].(map[string]any)
	delete(snapshot, "approvalExpiresAt")
	line, err = json.Marshal(entry)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, append(line, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}

	replayed, err := newHub(config)
	if err != nil {
		t.Fatalf("older event.task snapshot did not replay: %v", err)
	}
	t.Cleanup(func() { replayed.shutdown(context.Background()) })
	if recovered := taskByID(t, replayed, task.ID); recovered.ID != task.ID {
		t.Fatalf("replayed wrong task: %#v", recovered)
	}
}

func TestTaskJournalStateMismatchFailsClosed(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := hub.create(CreateRequest{RequestID: "state-mismatch-create-0001", Agent: "codex", Project: "demo", Prompt: "not persisted"}); err != nil {
		t.Fatal(err)
	}
	if err := hub.store.Close(); err != nil {
		t.Fatal(err)
	}

	path := filepath.Join(config.DataDir, "events.ndjson")
	line, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var entry map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(line), &entry); err != nil {
		t.Fatal(err)
	}
	entry["record"].(map[string]any)["state"] = string(stateRunning)
	line, err = json.Marshal(entry)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, append(line, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}

	if _, err := newHub(config); err == nil {
		t.Fatal("journal with event.to and record.state mismatch replayed")
	}
}

func spawnSource(t *testing.T, parent, nickname string, depth int) json.RawMessage {
	t.Helper()
	value, err := json.Marshal(map[string]any{"subAgent": map[string]any{"thread_spawn": map[string]any{"parent_thread_id": parent, "agent_nickname": nickname, "agent_role": "worker", "depth": depth}}})
	if err != nil {
		t.Fatal(err)
	}
	return value
}

func observedByTitle(t *testing.T, threads []ObservedThreadDTO, title string) ObservedThreadDTO {
	t.Helper()
	for _, thread := range threads {
		if thread.Title == title {
			return thread
		}
	}
	t.Fatalf("observed thread %q missing", title)
	return ObservedThreadDTO{}
}

func testConfig(t *testing.T, command string) Config {
	t.Helper()
	root := t.TempDir()
	// Isolate default quota snapshot reads from the operator's real account data.
	t.Setenv("HOME", root)
	project := filepath.Join(root, "project")
	if err := os.Mkdir(project, 0o700); err != nil {
		t.Fatal(err)
	}
	return Config{
		Listen:                     "127.0.0.1:8787",
		DataDir:                    filepath.Join(root, "data"),
		TokenFile:                  filepath.Join(root, "token"),
		ApprovalTTLSeconds:         300,
		ApprovalQuotaMaxAgeSeconds: defaultApprovalQuotaMaxAgeSeconds,
		Mode:                       "read-only",
		ClaudeMaxBudgetUSD:         0.25,
		AccountStrategy:            "system",
		Commands:                   map[string]string{"codex": command, "claude": command, "kimi": command},
		Projects:                   map[string]string{"demo": project},
	}
}

func testAccountConfig(t *testing.T, root, alias string) AccountConfig {
	t.Helper()
	if err := os.WriteFile(filepath.Join(root, "auth.json"), []byte(`{"ok":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	return AccountConfig{Alias: alias, Home: root}
}

func writeQuotaSnapshot(t *testing.T, account AccountConfig, sevenDayUsed string) string {
	t.Helper()
	return writeQuotaSnapshots(t, []AccountConfig{account}, []string{sevenDayUsed})
}

func writeQuotaSnapshots(t *testing.T, accounts []AccountConfig, sevenDayUsed []string) string {
	t.Helper()
	profiles := make([]string, 0, len(accounts))
	for index, account := range accounts {
		profiles = append(profiles, fmt.Sprintf(`{"name":%q,"codexHomePath":%q,"lastSnapshot":{"fiveHour":{"usedPercent":0},"sevenDay":{"usedPercent":%s}}}`, account.Alias, account.Home, sevenDayUsed[index]))
	}
	path := filepath.Join(t.TempDir(), "manager-snapshot.json")
	contents := `{"profiles":[` + strings.Join(profiles, ",") + `]}`
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func writeApprovalQuotaSnapshot(t *testing.T, account AccountConfig, fetchedAt time.Time, fiveHourUsed, sevenDayUsed float64) string {
	t.Helper()
	fetched := float64(fetchedAt.Unix() - appleEpochUnixOffset)
	fiveReset := float64(fetchedAt.Add(4*time.Hour).Unix() - appleEpochUnixOffset)
	sevenReset := float64(fetchedAt.Add(24*time.Hour).Unix() - appleEpochUnixOffset)
	quotaReadSucceeded := true
	snapshot := managerSnapshotFile{Profiles: []managerProfile{{
		Name: account.Alias, CodexHomePath: account.Home,
		LastSnapshot: &managerAccountSnapshot{
			PlanType: "plus", FetchedAt: &fetched, QuotaReadSucceeded: &quotaReadSucceeded,
			FiveHour: managerUsageWindow{UsedPercent: &fiveHourUsed, ResetsAt: &fiveReset},
			SevenDay: managerUsageWindow{UsedPercent: &sevenDayUsed, ResetsAt: &sevenReset},
		},
	}}}
	contents, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "approval-quota.json")
	if err := os.WriteFile(path, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

type rawFrame struct {
	opcode  byte
	masked  bool
	payload []byte
}

func readRawFrame(reader io.Reader) (rawFrame, error) {
	var header [2]byte
	if _, err := io.ReadFull(reader, header[:]); err != nil {
		return rawFrame{}, err
	}
	length := int(header[1] & 0x7f)
	if length == 126 {
		var extended [2]byte
		if _, err := io.ReadFull(reader, extended[:]); err != nil {
			return rawFrame{}, err
		}
		length = int(binary.BigEndian.Uint16(extended[:]))
	}
	mask := make([]byte, 0)
	masked := header[1]&0x80 != 0
	if masked {
		mask = make([]byte, 4)
		if _, err := io.ReadFull(reader, mask); err != nil {
			return rawFrame{}, err
		}
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(reader, payload); err != nil {
		return rawFrame{}, err
	}
	if masked {
		for index := range payload {
			payload[index] ^= mask[index%4]
		}
	}
	return rawFrame{opcode: header[0] & 0x0f, masked: masked, payload: payload}, nil
}

func writeServerFrame(writer io.Writer, fin bool, opcode byte, payload []byte) error {
	first := opcode & 0x0f
	if fin {
		first |= 0x80
	}
	header := []byte{first}
	switch {
	case len(payload) < 126:
		header = append(header, byte(len(payload)))
	case len(payload) <= 65535:
		header = append(header, 126, 0, 0)
		binary.BigEndian.PutUint16(header[len(header)-2:], uint16(len(payload)))
	default:
		header = append(header, 127, 0, 0, 0, 0, 0, 0, 0, 0)
		binary.BigEndian.PutUint64(header[len(header)-8:], uint64(len(payload)))
	}
	if _, err := writer.Write(header); err != nil {
		return err
	}
	_, err := writer.Write(payload)
	return err
}

func waitForState(t *testing.T, hub *Hub, taskID string, state TaskState) TaskDTO {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		task := taskByID(t, hub, taskID)
		if task.State == state {
			return task
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("task %s did not reach %s", taskID, state)
	return TaskDTO{}
}

func taskByID(t *testing.T, hub *Hub, taskID string) TaskDTO {
	t.Helper()
	overview := hub.overview()
	for _, task := range overview.Tasks {
		if task.ID == taskID {
			return task
		}
	}
	t.Fatalf("task %s missing", taskID)
	return TaskDTO{}
}

func TestMaskOutput(t *testing.T) {
	gateway := strings.Repeat("a", 64)
	privatePath := "/opt/Project With Space"
	values := []string{"abcdef", "token-value", "session-value-1234", "basic-value", gateway, privatePath}
	structured := `{"nested":{"access_token":"token-value","session_id":"session-value-1234","authorization":"Basic basic-value"}}`
	malformed := `{"thread_id":"session-value-1234","payload":"` + strings.Repeat("x", 300*1024)
	masked := strings.Join([]string{
		maskOutputWith("Bearer abcdef", nil),
		maskOutputWith(structured, nil),
		maskOutputWith(malformed, nil),
		maskOutputWith(gateway+" '"+privatePath+"/file.txt'", []string{gateway, privatePath}),
	}, "\n")
	for _, value := range values {
		if strings.Contains(masked, value) {
			t.Fatalf("output retained %q", value)
		}
	}
}

func TestClaudeAdapterIsReadOnlyAndIsolatedFromCustomizations(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	config.ClaudeMaxBudgetUSD = 0.001
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	task := &Task{Agent: "claude", Project: "demo", SessionID: "12345678-abcd-4000-acde-1234567890ab"}
	command, err := hub.commandFor(task, "read only")
	if err != nil {
		t.Fatal(err)
	}
	args := strings.Join(command.Args, " ")
	for _, required := range []string{"--safe-mode", "--strict-mcp-config", "--disable-slash-commands", "--no-chrome", "Read,Glob,Grep", "0.001"} {
		if !strings.Contains(args, required) {
			t.Fatalf("Claude args missing %s: %s", required, args)
		}
	}
	if strings.Contains(args, "Bash") || strings.Contains(args, "Edit") || strings.Contains(args, "Write") {
		t.Fatalf("Claude received write tools: %s", args)
	}
	hub.config.Mode = "workspace-write"
	if _, err := hub.commandFor(task, "write"); err == nil {
		t.Fatal("Claude workspace-write must fail closed")
	}
}

func TestKimiAdapterCommandConstructionAndResume(t *testing.T) {
	t.Setenv("CODEX_HOME", "/private/codex-profile-must-not-leak")
	config := testConfig(t, "/usr/bin/true")
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })

	fresh := &Task{Agent: "kimi", Project: "demo", AccountAlias: "system"}
	command, err := hub.commandFor(fresh, "reply with: ok")
	if err != nil {
		t.Fatal(err)
	}
	if command.Dir != config.Projects["demo"] || command.Stdin != nil {
		t.Fatalf("kimi command did not use project prompt mode: dir=%q stdin=%T", command.Dir, command.Stdin)
	}
	args := strings.Join(command.Args[1:], "\x00")
	for _, required := range []string{"--output-format\x00stream-json", "--prompt\x00reply with: ok"} {
		if !strings.Contains(args, required) {
			t.Fatalf("kimi args missing %q: %q", required, command.Args)
		}
	}
	for _, forbidden := range []string{"--session", "--continue", "--auto", "--yolo", "CODEX_HOME"} {
		if strings.Contains(args, forbidden) {
			t.Fatalf("fresh kimi command unexpectedly contained %q: %q", forbidden, command.Args)
		}
	}
	for _, value := range command.Env {
		if strings.HasPrefix(value, "CODEX_HOME=") {
			t.Fatalf("kimi inherited CODEX_HOME: %q", value)
		}
	}

	resumed := &Task{
		Agent: "kimi", Project: "demo", AccountAlias: "system", ResumeOf: "parent-task",
		SessionID: "52345678-abcd-4000-acde-1234567890ab", SessionVerified: true,
	}
	resumeCommand, err := hub.commandFor(resumed, "reply with: ok2")
	if err != nil {
		t.Fatal(err)
	}
	resumeArgs := strings.Join(resumeCommand.Args[1:], "\x00")
	for _, required := range []string{"--session\x0052345678-abcd-4000-acde-1234567890ab", "--prompt\x00reply with: ok2"} {
		if !strings.Contains(resumeArgs, required) {
			t.Fatalf("kimi resume args missing %q: %q", required, resumeCommand.Args)
		}
	}
	resumed.SessionID = ""
	if _, err := hub.commandFor(resumed, "missing session"); !errors.Is(err, errConflict) {
		t.Fatalf("kimi resume without session did not fail closed: %v", err)
	}
}

func TestKimiCreateForcesSystemAccount(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	config.AccountStrategy = "round_robin"
	config.Accounts = []AccountConfig{{Alias: "pool-a", Home: t.TempDir()}}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })

	created, err := hub.create(CreateRequest{
		RequestID: "create-kimi-system-0001", Agent: "kimi", Project: "demo", Prompt: "test",
	})
	if err != nil || created.Account != "system" {
		t.Fatalf("kimi did not force system account: %#v %v", created, err)
	}
	if _, err := hub.create(CreateRequest{
		RequestID: "create-kimi-pool-0001", Agent: "kimi", Project: "demo", AccountAlias: "pool-a", Prompt: "test",
	}); !errors.Is(err, errInvalid) {
		t.Fatalf("kimi accepted a Codex pool account: %v", err)
	}
}

func TestCodexPoolAdapterPinsModelAndSubagentPolicy(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	account := testAccountConfig(t, t.TempDir(), "pool-a")
	config.Accounts = []AccountConfig{account}
	writeSnapshot := func(t *testing.T, plan string) string {
		t.Helper()
		path := filepath.Join(t.TempDir(), "manager-snapshot.json")
		contents := fmt.Sprintf(`{"profiles":[{"name":"pool profile","codexHomePath":%q,"lastSnapshot":{"planType":%q}}]}`, account.Home, plan)
		if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}

	tests := []struct {
		name    string
		plan    string
		missing bool
	}{
		{name: "plus", plan: "Plus"},
		{name: "pro", plan: "Pro"},
		{name: "unknown plan", plan: "Team"},
		{name: "missing snapshot", missing: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			hub, err := newHub(config)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { hub.shutdown(context.Background()) })
			if test.missing {
				hub.managerSnapshotPath = filepath.Join(t.TempDir(), "missing.json")
			} else {
				hub.managerSnapshotPath = writeSnapshot(t, test.plan)
			}

			command, err := hub.commandFor(&Task{Agent: "codex", Project: "demo", AccountAlias: account.Alias}, "implement the change")
			if err != nil {
				t.Fatal(err)
			}
			args := strings.Join(command.Args, "\x00")
			for _, required := range []string{
				"-m\x00" + defaultExecutionPreference.Model,
				"-c\x00model_reasoning_effort=\"" + defaultExecutionPreference.ReasoningEffort + "\"",
				"-c\x00agents.enabled=false",
				"-c\x00features.multi_agent_v2=false",
				"-c\x00service_tier=\"default\"",
				"--disable\x00fast_mode",
				"exec\x00--ignore-user-config",
			} {
				if !strings.Contains(args, required) {
					t.Fatalf("Codex pool args missing %q: %q", required, command.Args)
				}
			}
			hasFast := strings.Contains(args, "--enable\x00fast_mode")
			if hasFast {
				t.Fatalf("default pool command unexpectedly enabled fast: args=%q", command.Args)
			}
			prompt, err := io.ReadAll(command.Stdin)
			if err != nil {
				t.Fatal(err)
			}
			if string(prompt) != "implement the change" {
				t.Fatalf("standard prompt changed: %q", prompt)
			}
		})
	}

	fastHub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	fastPreference := executionPreference{Model: "gpt-5.6-terra", ReasoningEffort: "ultra", ServiceTier: "fast"}
	fastCommand, err := fastHub.commandFor(&Task{
		Agent: "codex", Project: "demo", AccountAlias: account.Alias, ExecutionPreference: &fastPreference,
	}, "fast task")
	if err != nil {
		t.Fatal(err)
	}
	fastArgs := strings.Join(fastCommand.Args, "\x00")
	for _, required := range []string{
		"-m\x00gpt-5.6-terra",
		"-c\x00model_reasoning_effort=\"ultra\"",
		"-c\x00agents.enabled=false",
		"-c\x00features.multi_agent_v2=false",
		"-c\x00service_tier=\"fast\"",
		"--enable\x00fast_mode",
	} {
		if !strings.Contains(fastArgs, required) {
			t.Fatalf("fast Codex args missing %q: %q", required, fastCommand.Args)
		}
	}
	fastHub.shutdown(context.Background())

	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.managerSnapshotPath = writeSnapshot(t, "Plus")
	systemCommand, err := hub.commandFor(&Task{Agent: "codex", Project: "demo", AccountAlias: "system"}, "system prompt")
	if err != nil {
		t.Fatal(err)
	}
	systemArgs := strings.Join(systemCommand.Args, "\x00")
	for _, poolOnly := range []string{defaultExecutionPreference.Model, "model_reasoning_effort", "service_tier", "fast_mode", "agents.enabled", "multi_agent_v2"} {
		if strings.Contains(systemArgs, poolOnly) {
			t.Fatalf("system Codex run inherited pool policy %q: %q", poolOnly, systemCommand.Args)
		}
	}
	systemPrompt, err := io.ReadAll(systemCommand.Stdin)
	if err != nil {
		t.Fatal(err)
	}
	if string(systemPrompt) != "system prompt" {
		t.Fatalf("system prompt was changed: %q", systemPrompt)
	}
}

func TestCodexCreateFreezesManagerExecutionPreference(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	account := testAccountConfig(t, t.TempDir(), "pool-a")
	config.Accounts = []AccountConfig{account}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })

	path := filepath.Join(t.TempDir(), "manager-snapshot.json")
	writeSnapshot := func(preference *executionPreference) {
		t.Helper()
		contents, err := json.Marshal(managerSnapshotFile{Profiles: []managerProfile{{
			Name: account.Alias, CodexHomePath: account.Home, ExecutionPreference: preference,
		}}})
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, contents, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	hub.managerSnapshotPath = path
	fast := executionPreference{Model: "gpt-5.6-terra", ReasoningEffort: "ultra", ServiceTier: "fast", SubagentMode: "standard"}
	writeSnapshot(&fast)
	created, err := hub.create(CreateRequest{
		RequestID: "create-preference-fast-0001", Agent: "codex", Project: "demo", AccountAlias: account.Alias, Prompt: "run fast",
	})
	if err != nil || created.ExecutionPreference == nil || !executionPreferencesEqual(*created.ExecutionPreference, fast) ||
		created.EffectiveExecutionPreference == nil || !executionPreferencesEqual(*created.EffectiveExecutionPreference, fast) {
		t.Fatalf("manager preference was not frozen: %#v %v", created, err)
	}
	hub.mu.Lock()
	frozen := hub.tasks[created.ID]
	hub.mu.Unlock()
	changed := *frozen
	changed.ExecutionPreference = &defaultExecutionPreference
	if taskActionHash(&changed) == frozen.ActionHash {
		t.Fatal("approval action hash did not bind the frozen execution preference")
	}

	writeSnapshot(&defaultExecutionPreference)
	command, err := hub.commandFor(frozen, "run fast")
	if err != nil {
		t.Fatal(err)
	}
	args := strings.Join(command.Args, "\x00")
	for _, required := range []string{"-m\x00gpt-5.6-terra", "model_reasoning_effort=\"ultra\"", "service_tier=\"fast\"", "--enable\x00fast_mode"} {
		if !strings.Contains(args, required) {
			t.Fatalf("command did not use frozen preference %q: %q", required, command.Args)
		}
	}

	hub.mu.Lock()
	hub.tasks[created.ID].ApprovalExpiresAt = time.Now().UTC().Add(-time.Second)
	hub.mu.Unlock()
	writeSnapshot(nil)
	legacy, err := hub.create(CreateRequest{
		RequestID: "create-preference-default-0001", Agent: "codex", Project: "demo", AccountAlias: account.Alias, Prompt: "run default",
	})
	if err != nil || legacy.ExecutionPreference == nil || !executionPreferencesEqual(*legacy.ExecutionPreference, defaultExecutionPreference) {
		t.Fatalf("missing legacy preference did not freeze defaults: %#v %v", legacy, err)
	}

	hub.mu.Lock()
	hub.tasks[legacy.ID].ApprovalExpiresAt = time.Now().UTC().Add(-time.Second)
	hub.mu.Unlock()
	invalid := executionPreference{Model: "gpt-5.2", ReasoningEffort: "high", ServiceTier: "fast"}
	writeSnapshot(&invalid)
	if _, err := hub.create(CreateRequest{
		RequestID: "create-preference-invalid-0001", Agent: "codex", Project: "demo", AccountAlias: account.Alias, Prompt: "reject",
	}); !errors.Is(err, errInvalid) {
		t.Fatalf("invalid manager preference did not fail closed: %v", err)
	}
}

func TestCustomPresetFreezesRoleCapabilityAndExactCommand(t *testing.T) {
	for _, test := range []struct {
		mode    string
		ceiling int
	}{{"sol_luna", 1}} {
		t.Run(test.mode, func(t *testing.T) {
			config := testConfig(t, "/usr/bin/true")
			account := testAccountConfig(t, t.TempDir(), "pool-a")
			config.Accounts = []AccountConfig{account}
			hub, err := newHub(config)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { hub.shutdown(context.Background()) })
			roleBytes := generatedPresetRole("gpt-5.5", "high")
			name := "Display only custom worker"
			preference := executionPreference{Model: "gpt-5.6-sol", ReasoningEffort: "medium", ServiceTier: "fast", SubagentMode: test.mode,
				CustomPresets: map[string]executionPreset{test.mode: {Name: &name, Model: "gpt-5.6-terra", ReasoningEffort: "xhigh",
					SubagentsEnabled: true, SubagentModel: "gpt-5.5", SubagentReasoningEffort: "high"}}}
			snapshotPath := filepath.Join(t.TempDir(), "manager.json")
			contents, _ := json.Marshal(managerSnapshotFile{Profiles: []managerProfile{{
				Name: account.Alias, CodexHomePath: account.Home, ExecutionPreference: &preference,
			}}})
			if err := os.WriteFile(snapshotPath, contents, 0o600); err != nil {
				t.Fatal(err)
			}
			hub.managerSnapshotPath = snapshotPath
			cliSHA, err := hashRegularFile("/usr/bin/true")
			if err != nil {
				t.Fatal(err)
			}
			capability, _ := json.Marshal(codexCapabilityReport{Status: "passed", CheckedAt: time.Now().UTC(),
				CLISHA256: cliSHA, WorkerRoleSHA256: hashText(string(roleBytes)),
				SupportedSubagentModes: []string{"sol_luna"}})
			if err := os.WriteFile(filepath.Join(config.DataDir, "codex-capability.json"), capability, 0o600); err != nil {
				t.Fatal(err)
			}
			created, err := hub.create(CreateRequest{RequestID: "create-" + test.mode + "-0001", Agent: "codex",
				Project: "demo", AccountAlias: account.Alias, Prompt: "frozen brief"})
			if err != nil {
				t.Fatal(err)
			}
			if created.ExecutionPreference == nil || !executionPreferencesEqual(*created.ExecutionPreference, preference) || created.SubagentExecution == nil || created.SubagentExecution.ConcurrentThreads != test.ceiling {
				t.Fatalf("mode was not frozen exactly: %#v", created)
			}
			if created.SubagentExecution.RequestedModel != "gpt-5.5" || created.SubagentExecution.RequestedEffort != "high" || created.SubagentExecution.Observed != nil {
				t.Fatalf("configured and observed child evidence was not kept distinct: %#v", created.SubagentExecution)
			}
			if created.InputHashes == nil || created.InputHashes.OriginalBriefSHA256 != hashText("frozen brief") || created.InputHashes.EffectiveInputSHA256 != hashText(presetCollaborationPolicy(test.mode, true)+"frozen brief") {
				t.Fatalf("input hashes were not frozen: %#v", created.InputHashes)
			}
			hub.mu.Lock()
			task := hub.tasks[created.ID]
			hub.mu.Unlock()
			command, err := hub.commandFor(task, "frozen brief")
			if err != nil {
				t.Fatal(err)
			}
			args := strings.Join(command.Args, "\x00")
			for _, required := range []string{"-m\x00gpt-5.6-terra", "model_reasoning_effort=\"xhigh\"", "service_tier=\"fast\"",
				"agents.enabled=true", "features.multi_agent_v2=true",
				fmt.Sprintf("agents.max_concurrent_threads_per_session=%d", test.ceiling),
				"agents.default_subagent_model=\"gpt-5.5\"", "agents.default_subagent_reasoning_effort=\"high\"",
				"agents.next_preset_worker.config_file=", "--enable\x00fast_mode"} {
				if !strings.Contains(args, required) {
					t.Fatalf("Luna command missing %q: %q", required, command.Args)
				}
			}
			stdin, _ := io.ReadAll(command.Stdin)
			if string(stdin) != presetCollaborationPolicy(test.mode, true)+"frozen brief" {
				t.Fatalf("effective input mismatch: %q", stdin)
			}
			if !strings.Contains(string(stdin), "do not specify model or reasoning-effort overrides in spawn requests") {
				t.Fatalf("spawn override policy missing: %q", stdin)
			}
			if strings.Contains(string(stdin), name) {
				t.Fatalf("display-only preset name entered the prompt: %q", stdin)
			}
		})
	}
}

func TestPresetModeFailsClosedWithoutCapability(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	account := testAccountConfig(t, t.TempDir(), "pool-a")
	config.Accounts = []AccountConfig{account}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	preference := executionPreference{Model: "gpt-5.6-sol", ReasoningEffort: "medium", ServiceTier: "default", SubagentMode: "sol_luna"}
	path := filepath.Join(t.TempDir(), "manager.json")
	contents, _ := json.Marshal(managerSnapshotFile{Profiles: []managerProfile{{Name: account.Alias, CodexHomePath: account.Home, ExecutionPreference: &preference}}})
	if err := os.WriteFile(path, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	hub.managerSnapshotPath = path
	if _, err := hub.create(CreateRequest{RequestID: "create-luna-no-capability", Agent: "codex", Project: "demo", AccountAlias: account.Alias, Prompt: "reject"}); !errors.Is(err, errInvalid) {
		t.Fatalf("missing/old capability did not fail closed: %v", err)
	}
}

func TestLunaDirectDerivesMainAndDisablesSubagents(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	account := testAccountConfig(t, t.TempDir(), "pool-a")
	config.Accounts = []AccountConfig{account}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	saved := executionPreference{Model: "gpt-6-astra", ReasoningEffort: "low", ServiceTier: "fast", SubagentMode: "luna_direct"}
	path := filepath.Join(t.TempDir(), "manager.json")
	contents, _ := json.Marshal(managerSnapshotFile{Profiles: []managerProfile{{Name: account.Alias, CodexHomePath: account.Home, ExecutionPreference: &saved}}})
	if err := os.WriteFile(path, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	hub.managerSnapshotPath = path
	created, err := hub.create(CreateRequest{RequestID: "create-luna-direct-0001", Agent: "codex", Project: "demo", AccountAlias: account.Alias, Prompt: "direct brief"})
	if err != nil {
		t.Fatal(err)
	}
	expected := executionPreference{Model: "gpt-6-luna", ReasoningEffort: "max", ServiceTier: "fast", SubagentMode: "luna_direct"}
	if created.ExecutionPreference == nil || !executionPreferencesEqual(*created.ExecutionPreference, saved) || created.EffectiveExecutionPreference == nil || !executionPreferencesEqual(*created.EffectiveExecutionPreference, expected) {
		t.Fatalf("saved/effective preferences were not distinct: %#v", created)
	}
	hub.mu.Lock()
	task := hub.tasks[created.ID]
	hub.mu.Unlock()
	command, err := hub.commandFor(task, "direct brief")
	if err != nil {
		t.Fatal(err)
	}
	args := strings.Join(command.Args, "\x00")
	for _, required := range []string{"-m\x00gpt-6-luna", "model_reasoning_effort=\"max\"", "agents.enabled=false", "features.multi_agent_v2=false", "--enable\x00fast_mode"} {
		if !strings.Contains(args, required) {
			t.Fatalf("direct command missing %q: %q", required, command.Args)
		}
	}
	if strings.Contains(args, "next_preset_worker") {
		t.Fatalf("direct mode configured a child role: %q", command.Args)
	}
	stdin, _ := io.ReadAll(command.Stdin)
	if string(stdin) != "direct brief" {
		t.Fatalf("direct prompt changed: %q", stdin)
	}

	legacySaved := executionPreference{Model: "gpt-6-astra", ReasoningEffort: "low", ServiceTier: "default", SubagentMode: "sol_luna"}
	legacyEffective := legacySaved
	legacyEffective.Model, legacyEffective.ReasoningEffort = "gpt-5.6-sol", "high"
	legacyRole := generatedPresetRole("gpt-5.6-luna", "max")
	legacyRoleSHA := hashText(string(legacyRole))
	legacyCLISHA, err := hashRegularFile("/usr/bin/true")
	if err != nil {
		t.Fatal(err)
	}
	legacyTask := &Task{ID: "legacy-frozen-sol-luna-0001", Agent: "codex", Project: "demo", AccountAlias: account.Alias,
		ExecutionPreference: &legacySaved, EffectiveExecutionPreference: &legacyEffective,
		InputHashes: &inputHashes{EffectiveInputSHA256: hashText(presetCollaborationPolicy("sol_luna", true) + "legacy brief")},
		SubagentExecution: &subagentExecution{RequestedMode: "sol_luna", RequestedRole: presetRoleName,
			RequestedModel: "gpt-5.6-luna", RequestedEffort: "max", ConcurrentThreads: 1,
			RoleSHA256: legacyRoleSHA, CLISHA256: legacyCLISHA},
	}
	legacyTask.ActionHash = taskActionHash(legacyTask)
	legacyHash := legacyTask.ActionHash
	if err := hub.freezePresetRole(legacyTask.ID, legacyRole); err != nil {
		t.Fatal(err)
	}
	legacyCommand, err := hub.commandFor(legacyTask, "legacy brief")
	if err != nil {
		t.Fatal(err)
	}
	legacyArgs := strings.Join(legacyCommand.Args, "\x00")
	for _, required := range []string{"-m\x00gpt-5.6-sol", "agents.default_subagent_model=\"gpt-5.6-luna\"",
		"agents.default_subagent_reasoning_effort=\"max\"", "agents.enabled=true"} {
		if !strings.Contains(legacyArgs, required) {
			t.Fatalf("legacy frozen command missing %q: %q", required, legacyCommand.Args)
		}
	}
	if legacyTask.ActionHash != legacyHash || taskActionHash(legacyTask) != legacyHash {
		t.Fatal("legacy frozen command changed its action hash")
	}
}

func TestApproveRejectsInvalidFrozenExecutionPreference(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	account := testAccountConfig(t, t.TempDir(), "pool-a")
	config.Accounts = []AccountConfig{account}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.managerSnapshotPath = writeQuotaSnapshot(t, account, `20`)

	created, err := hub.create(CreateRequest{
		RequestID: "create-invalid-frozen-0001", Agent: "codex", Project: "demo", AccountAlias: account.Alias, Prompt: "reject",
	})
	if err != nil {
		t.Fatal(err)
	}
	hub.mu.Lock()
	task := hub.tasks[created.ID]
	invalid := executionPreference{Model: "gpt-5.6-luna", ReasoningEffort: "ultra", ServiceTier: "default"}
	task.ExecutionPreference = &invalid
	task.ActionHash = taskActionHash(task)
	version := task.Version
	actionHash := task.ActionHash
	hub.mu.Unlock()

	if _, err := hub.approve(task.ID, ApproveRequest{RequestID: "approve-invalid-frozen-0001", ActionHash: actionHash}); !errors.Is(err, errInvalid) {
		t.Fatalf("invalid frozen preference was approved: %v", err)
	}
	hub.mu.Lock()
	defer hub.mu.Unlock()
	if task.State != stateAwaitingApproval || task.Version != version {
		t.Fatalf("failed approval mutated task: %#v", task)
	}
}

func TestApproveRejectsChangedFrozenExecutionPreference(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	account := testAccountConfig(t, t.TempDir(), "pool-a")
	config.Accounts = []AccountConfig{account}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.managerSnapshotPath = writeQuotaSnapshot(t, account, `20`)

	created, err := hub.create(CreateRequest{
		RequestID: "create-changed-frozen-0001", Agent: "codex", Project: "demo", AccountAlias: account.Alias, Prompt: "reject",
	})
	if err != nil {
		t.Fatal(err)
	}
	hub.mu.Lock()
	task := hub.tasks[created.ID]
	changed := executionPreference{Model: "gpt-5.6-terra", ReasoningEffort: "ultra", ServiceTier: "fast"}
	task.ExecutionPreference = &changed
	version := task.Version
	hub.mu.Unlock()

	if _, err := hub.approve(task.ID, ApproveRequest{RequestID: "approve-changed-frozen-0001", ActionHash: created.ActionHash}); !errors.Is(err, errConflict) {
		t.Fatalf("changed frozen preference was accepted with its old action hash: %v", err)
	}
	hub.mu.Lock()
	defer hub.mu.Unlock()
	if task.State != stateAwaitingApproval || task.Version != version {
		t.Fatalf("failed approval mutated task: %#v", task)
	}
}

func TestRoundRobinAccountSelection(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	config.AccountStrategy = "round_robin"
	config.Accounts = []AccountConfig{
		testAccountConfig(t, t.TempDir(), "acct-a"),
		testAccountConfig(t, t.TempDir(), "acct-b"),
	}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.managerSnapshotPath = writeQuotaSnapshots(t, config.Accounts, []string{`20`, `20`})

	hub.mu.Lock()
	first, reason := hub.selectAccountLocked(&Task{Agent: "codex", Project: "demo"})
	second, reason2 := hub.selectAccountLocked(&Task{Agent: "codex", Project: "demo"})
	hub.mu.Unlock()
	if reason != "" || reason2 != "" {
		t.Fatalf("unexpected selection failure: %q %q", reason, reason2)
	}
	if first != "acct-a" || second != "acct-b" {
		t.Fatalf("round robin did not rotate: %q %q", first, second)
	}
}

func TestAccountLeaseStateLifecycle(t *testing.T) {
	now := time.Now().UTC()
	for _, test := range []struct {
		state TaskState
		want  bool
	}{
		{stateAwaitingApproval, true},
		{stateStarting, true},
		{stateRunning, true},
		{stateCancelRequested, true},
		{stateUncertain, true},
		{stateSucceeded, false},
		{stateFailed, false},
		{stateCancelled, false},
		{stateBlockedConfiguration, false},
	} {
		task := &Task{
			AccountAlias:      "acct-a",
			State:             test.state,
			ApprovalExpiresAt: now.Add(time.Minute),
		}
		if got := task.holdsAccountLeaseAt(now); got != test.want {
			t.Fatalf("state %s account lease = %v, want %v", test.state, got, test.want)
		}
	}
	expired := &Task{
		AccountAlias:      "acct-a",
		State:             stateAwaitingApproval,
		ApprovalExpiresAt: now.Add(-time.Second),
	}
	if expired.holdsAccountLeaseAt(now) {
		t.Fatal("expired approval kept the account lease")
	}
	system := &Task{AccountAlias: "system", State: stateRunning}
	if system.holdsAccountLeaseAt(now) {
		t.Fatal("system identity unexpectedly entered the pool account lease")
	}
}

func TestAccountLeaseRejectsDuplicateCreateAcrossProjectsAndExpires(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	config.Projects["other"] = config.Projects["demo"]
	account := testAccountConfig(t, t.TempDir(), "acct-a")
	config.Accounts = []AccountConfig{account}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.managerSnapshotPath = writeQuotaSnapshot(t, account, `20`)

	first, err := hub.create(CreateRequest{
		RequestID: "account-lease-first-0001", Agent: "codex", Project: "demo",
		AccountAlias: account.Alias, Prompt: "first",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := hub.create(CreateRequest{
		RequestID: "account-lease-duplicate-0001", Agent: "codex", Project: "other",
		AccountAlias: account.Alias, Prompt: "duplicate",
	}); !errors.Is(err, errAccountBusy) {
		t.Fatalf("duplicate account dispatch was not rejected: %v", err)
	}

	hub.mu.Lock()
	hub.tasks[first.ID].ApprovalExpiresAt = time.Now().UTC().Add(-time.Second)
	hub.mu.Unlock()
	second, err := hub.create(CreateRequest{
		RequestID: "account-lease-after-expiry-0001", Agent: "codex", Project: "other",
		AccountAlias: account.Alias, Prompt: "after expiry",
	})
	if err != nil || second.Account != account.Alias {
		t.Fatalf("expired account lease did not release: %#v %v", second, err)
	}
}

func TestConcurrentCreatesCannotLeaseTheSameAccount(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	config.Projects["other"] = config.Projects["demo"]
	account := testAccountConfig(t, t.TempDir(), "acct-a")
	config.Accounts = []AccountConfig{account}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.managerSnapshotPath = writeQuotaSnapshot(t, account, `20`)

	start := make(chan struct{})
	results := make(chan error, 2)
	for index, project := range []string{"demo", "other"} {
		go func(index int, project string) {
			<-start
			_, err := hub.create(CreateRequest{
				RequestID: fmt.Sprintf("concurrent-account-lease-%04d", index),
				Agent:     "codex", Project: project, AccountAlias: account.Alias, Prompt: "run",
			})
			results <- err
		}(index, project)
	}
	close(start)
	succeeded := 0
	busy := 0
	for range 2 {
		switch err := <-results; {
		case err == nil:
			succeeded++
		case errors.Is(err, errAccountBusy):
			busy++
		default:
			t.Fatalf("concurrent create returned unexpected error: %v", err)
		}
	}
	if succeeded != 1 || busy != 1 {
		t.Fatalf("concurrent account lease results: succeeded=%d busy=%d", succeeded, busy)
	}
}

func TestRoundRobinSkipsBusyAccount(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	config.AccountStrategy = "round_robin"
	config.Accounts = []AccountConfig{
		testAccountConfig(t, t.TempDir(), "acct-a"),
		testAccountConfig(t, t.TempDir(), "acct-b"),
	}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.managerSnapshotPath = writeQuotaSnapshots(t, config.Accounts, []string{`20`, `20`})
	hub.mu.Lock()
	hub.tasks["busy-task"] = &Task{
		ID: "busy-task", Project: "other", AccountAlias: "acct-a", State: stateRunning,
	}
	selected, reason := hub.selectAccountLocked(&Task{Agent: "codex", Project: "demo"})
	hub.mu.Unlock()
	if reason != "" || selected != "acct-b" {
		t.Fatalf("round robin did not skip busy account: alias=%q reason=%q", selected, reason)
	}
}

func TestApproveRechecksAccountLeaseWithoutMutatingTask(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	config.Projects["other"] = config.Projects["demo"]
	account := testAccountConfig(t, t.TempDir(), "acct-a")
	config.Accounts = []AccountConfig{account}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.managerSnapshotPath = writeApprovalQuotaSnapshot(t, account, time.Now().UTC(), 10, 20)
	created, err := hub.create(CreateRequest{
		RequestID: "account-lease-approve-create-0001", Agent: "codex", Project: "demo",
		AccountAlias: account.Alias, Prompt: "run",
	})
	if err != nil {
		t.Fatal(err)
	}
	hub.mu.Lock()
	hub.tasks["competing-task"] = &Task{
		ID: "competing-task", Project: "other", AccountAlias: account.Alias, State: stateRunning,
	}
	hub.mu.Unlock()

	if _, err := hub.approve(created.ID, ApproveRequest{
		RequestID: "account-lease-approve-0001", ActionHash: created.ActionHash,
	}); !errors.Is(err, errAccountBusy) {
		t.Fatalf("approval did not recheck the account lease: %v", err)
	}
	hub.mu.Lock()
	unchanged := hub.tasks[created.ID].dto()
	hub.mu.Unlock()
	if unchanged.State != stateAwaitingApproval || unchanged.Version != created.Version {
		t.Fatalf("busy approval mutated task: %#v", unchanged)
	}

	response := httptest.NewRecorder()
	writeTaskResult(response, TaskDTO{}, errAccountBusy, http.StatusOK)
	if response.Code != http.StatusConflict || strings.TrimSpace(response.Body.String()) != `{"error":"account_busy"}` {
		t.Fatalf("account busy API response = %d %s", response.Code, response.Body.String())
	}
}

func TestDispatchDisabledAccountRemainsVisibleButCannotBeSelected(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	config.AccountStrategy = "round_robin"
	disabled := testAccountConfig(t, t.TempDir(), "central")
	disabled.DispatchDisabled = true
	available := testAccountConfig(t, t.TempDir(), "pool-a")
	config.Accounts = []AccountConfig{disabled, available}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.managerSnapshotPath = writeQuotaSnapshots(t, config.Accounts, []string{`20`, `20`})

	if accounts := hub.overview().Accounts; !slices.Contains(accounts, disabled.Alias) {
		t.Fatalf("disabled account disappeared from overview: %v", accounts)
	}
	hub.mu.Lock()
	selected, reason := hub.selectAccountLocked(&Task{Agent: "codex", Project: "demo"})
	hub.mu.Unlock()
	if reason != "" || selected != available.Alias {
		t.Fatalf("round robin did not skip disabled account: alias=%q reason=%q", selected, reason)
	}
	_, err = hub.create(CreateRequest{RequestID: "disabled-explicit-0001", Agent: "codex", Project: "demo", AccountAlias: disabled.Alias, Prompt: "run"})
	if !errors.Is(err, errDispatchDisabled) {
		t.Fatalf("explicit disabled account did not fail closed: %v", err)
	}
}

func TestPoolStrategiesWithoutEligibleAccountsDoNotFallbackToSystem(t *testing.T) {
	for _, strategy := range []string{"round_robin", "least_recently_used"} {
		t.Run(strategy, func(t *testing.T) {
			config := testConfig(t, "/usr/bin/true")
			config.AccountStrategy = strategy
			disabled := testAccountConfig(t, t.TempDir(), "central")
			disabled.DispatchDisabled = true
			config.Accounts = []AccountConfig{disabled}
			hub, err := newHub(config)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { hub.shutdown(context.Background()) })

			_, err = hub.create(CreateRequest{RequestID: "no-eligible-0001", Agent: "codex", Project: "demo", Prompt: "run"})
			if !errors.Is(err, errAccountQuotaReserve) {
				t.Fatalf("pool strategy did not fail closed: %v", err)
			}
		})
	}
}

func TestCreateRejectsAccountAboveQuotaReserve(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	config.AccountStrategy = "round_robin"
	account := testAccountConfig(t, t.TempDir(), "acct-a")
	config.Accounts = []AccountConfig{account}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.managerSnapshotPath = writeQuotaSnapshot(t, account, `86`)
	handler := (&API{hub: hub, token: []byte("test-token")}).routes()
	body := []byte(`{"requestId":"quota-auto-0001","agent":"codex","project":"demo","prompt":"run"}`)
	request := httptest.NewRequest(http.MethodPost, "/api/tasks", bytes.NewReader(body))
	request.Header.Set("Authorization", "Bearer test-token")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusConflict || strings.TrimSpace(response.Body.String()) != `{"error":"account_quota_reserve"}` {
		t.Fatalf("quota reserve returned %d: %s", response.Code, response.Body.String())
	}
}

func TestCreateRejectsExplicitAccountAboveQuotaReserve(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	account := testAccountConfig(t, t.TempDir(), "acct-a")
	config.Accounts = []AccountConfig{account}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.managerSnapshotPath = writeQuotaSnapshot(t, account, `86`)
	_, err = hub.create(CreateRequest{RequestID: "quota-explicit-0001", Agent: "codex", Project: "demo", AccountAlias: "acct-a", Prompt: "run"})
	if !errors.Is(err, errAccountQuotaReserve) {
		t.Fatalf("explicit over-reserve account was allowed: %v", err)
	}
}

func TestCreateAllowsUnknownSevenDayQuota(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	account := testAccountConfig(t, t.TempDir(), "acct-a")
	config.Accounts = []AccountConfig{account}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.managerSnapshotPath = writeQuotaSnapshot(t, account, `null`)
	task, err := hub.create(CreateRequest{RequestID: "quota-unknown-0001", Agent: "codex", Project: "demo", AccountAlias: "acct-a", Prompt: "run"})
	if err != nil || task.Account != "acct-a" {
		t.Fatalf("unknown quota draft was rejected: %#v %v", task, err)
	}
	if task.State != stateAwaitingApproval {
		t.Fatal("unknown quota must remain an approval draft")
	}
	if _, err := hub.approve(task.ID, ApproveRequest{RequestID: "quota-unknown-approve", ActionHash: task.ActionHash}); !errors.Is(err, errAccountQuotaReserve) {
		t.Fatalf("unknown quota approval was not rejected: %v", err)
	}
}

func TestRoundRobinSkipsAccountAboveQuotaReserve(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	config.AccountStrategy = "round_robin"
	over := testAccountConfig(t, t.TempDir(), "acct-over")
	available := testAccountConfig(t, t.TempDir(), "acct-available")
	config.Accounts = []AccountConfig{over, available}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.managerSnapshotPath = writeQuotaSnapshots(t, []AccountConfig{over, available}, []string{`86`, `85`})
	hub.mu.Lock()
	alias, reason := hub.selectAccountLocked(&Task{Agent: "codex", Project: "demo"})
	hub.mu.Unlock()
	if reason != "" || alias != "acct-available" {
		t.Fatalf("round robin selected over-reserve account: alias=%q reason=%q", alias, reason)
	}
}

func TestLeastRecentlyUsedAccountSelection(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	config.AccountStrategy = "least_recently_used"
	config.Accounts = []AccountConfig{
		testAccountConfig(t, t.TempDir(), "acct-a"),
		testAccountConfig(t, t.TempDir(), "acct-b"),
	}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.managerSnapshotPath = writeQuotaSnapshots(t, config.Accounts, []string{`20`, `20`})

	hub.mu.Lock()
	_, _ = hub.selectAccountLocked(&Task{Agent: "codex", Project: "demo"})
	second, reason := hub.selectAccountLocked(&Task{Agent: "codex", Project: "demo"})
	third, reason2 := hub.selectAccountLocked(&Task{Agent: "codex", Project: "demo"})
	hub.mu.Unlock()
	if reason != "" || reason2 != "" {
		t.Fatalf("unexpected selection failure: %q %q", reason, reason2)
	}
	if second != "acct-b" || third != "acct-a" {
		t.Fatalf("least recently used did not prefer oldest alias: %q %q", second, third)
	}
}

func TestApprovedEventPersistsOnlyAccountAlias(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	accountRoot := t.TempDir()
	config.Accounts = []AccountConfig{testAccountConfig(t, accountRoot, "acct-a")}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.managerSnapshotPath = writeApprovalQuotaSnapshot(t, config.Accounts[0], time.Now().UTC(), 10, 20)

	task, err := hub.create(CreateRequest{RequestID: "create-account-0001", Agent: "codex", Project: "demo", AccountAlias: "acct-a", Prompt: "run"})
	if err != nil {
		t.Fatal(err)
	}
	approved, err := hub.approve(task.ID, ApproveRequest{RequestID: "approve-account-0001", ActionHash: task.ActionHash})
	if err != nil {
		t.Fatal(err)
	}
	if approved.Account != "acct-a" {
		t.Fatalf("approved task lost account alias: %#v", approved)
	}
	finished := waitForState(t, hub, task.ID, stateSucceeded)
	if finished.Account != "acct-a" {
		t.Fatalf("finished task lost account alias: %#v", finished)
	}
	journal, err := os.ReadFile(filepath.Join(config.DataDir, "events.ndjson"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(journal)
	if !strings.Contains(text, `"accountAlias":"acct-a"`) {
		t.Fatal("journal did not persist account alias")
	}
	if strings.Contains(text, accountRoot) {
		t.Fatal("journal persisted account home path")
	}
}

func TestApproveFailsClosedWhenAccountAuthMissing(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	accountRoot := t.TempDir()
	config.Accounts = []AccountConfig{{Alias: "acct-a", Home: accountRoot}}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.managerSnapshotPath = writeApprovalQuotaSnapshot(t, config.Accounts[0], time.Now().UTC(), 10, 20)

	task, err := hub.create(CreateRequest{RequestID: "create-account-0002", Agent: "codex", Project: "demo", AccountAlias: "acct-a", Prompt: "run"})
	if err != nil {
		t.Fatal(err)
	}
	blocked, err := hub.approve(task.ID, ApproveRequest{RequestID: "approve-account-0002", ActionHash: task.ActionHash})
	if err != nil {
		t.Fatal(err)
	}
	if blocked.State != stateBlockedConfiguration || blocked.ReasonCode != "account_auth_unavailable" {
		t.Fatalf("missing auth.json did not fail closed: %#v", blocked)
	}
}

func TestApproveRequiresFreshQualifiedQuotaWithoutMutatingTask(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	accountRoot := t.TempDir()
	config.Accounts = []AccountConfig{testAccountConfig(t, accountRoot, "acct-a")}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.managerSnapshotPath = writeApprovalQuotaSnapshot(t, config.Accounts[0], time.Now().UTC(), 10, 20)

	task, err := hub.create(CreateRequest{RequestID: "create-quota-approval-0001", Agent: "codex", Project: "demo", AccountAlias: "acct-a", Prompt: "run"})
	if err != nil {
		t.Fatal(err)
	}
	hub.managerSnapshotPath = filepath.Join(t.TempDir(), "missing.json")
	handler := (&API{hub: hub, token: []byte("test-token")}).routes()
	request := httptest.NewRequest(http.MethodPost, "/api/tasks/"+task.ID+"/approve", strings.NewReader(
		`{"requestId":"approve-quota-missing-0001","actionHash":"`+task.ActionHash+`"}`,
	))
	request.Header.Set("Authorization", "Bearer test-token")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusConflict || !strings.Contains(response.Body.String(), errAccountQuotaReserve.Error()) {
		t.Fatalf("direct approval bypassed missing quota: %d %s", response.Code, response.Body.String())
	}
	hub.managerSnapshotPath = writeApprovalQuotaSnapshot(t, config.Accounts[0], time.Now().UTC().Add(-301*time.Second), 10, 20)
	if _, err := hub.approve(task.ID, ApproveRequest{RequestID: "approve-quota-stale-0001", ActionHash: task.ActionHash}); !errors.Is(err, errAccountQuotaReserve) {
		t.Fatalf("stale approval quota did not fail closed: %v", err)
	}
	hub.managerSnapshotPath = writeApprovalQuotaSnapshot(t, config.Accounts[0], time.Now().UTC(), 71, 20)
	if _, err := hub.approve(task.ID, ApproveRequest{RequestID: "approve-quota-low-0001", ActionHash: task.ActionHash}); !errors.Is(err, errAccountQuotaReserve) {
		t.Fatalf("insufficient approval quota did not fail closed: %v", err)
	}
	hub.mu.Lock()
	unchanged := hub.tasks[task.ID].dto()
	hub.mu.Unlock()
	if unchanged.State != stateAwaitingApproval || unchanged.Version != task.Version {
		t.Fatalf("failed approval mutated the task: %#v", unchanged)
	}

	hub.managerSnapshotPath = writeApprovalQuotaSnapshot(t, config.Accounts[0], time.Now().UTC().Add(-4*time.Minute), 10, 20)
	approved, err := hub.approve(task.ID, ApproveRequest{RequestID: "approve-quota-fresh-0001", ActionHash: task.ActionHash})
	if err != nil || approved.State != stateStarting {
		t.Fatalf("qualified approval within configured max age was rejected: %#v %v", approved, err)
	}
	waitForState(t, hub, task.ID, stateSucceeded)
}

func TestWebSocketAcceptAndUpgradeHandshake(t *testing.T) {
	server, client := net.Pipe()
	defer client.Close()
	done := make(chan error, 1)
	go func() {
		defer server.Close()
		reader := bufio.NewReader(server)
		status, headers, err := readWebSocketUpgrade(reader)
		if err != nil {
			done <- err
			return
		}
		if !strings.Contains(status, "HTTP/1.1") || headers["sec-websocket-key"] == "" {
			done <- errors.New("missing client handshake data")
			return
		}
		response := "HTTP/1.1 101 Switching Protocols\r\n" +
			"Upgrade: websocket\r\n" +
			"Connection: Upgrade\r\n" +
			"Sec-WebSocket-Accept: " + websocketAccept(headers["sec-websocket-key"]) + "\r\n\r\n"
		_, err = io.WriteString(server, response)
		done <- err
	}()
	ws := &wsOverUnixSocket{conn: client, reader: bufio.NewReader(client)}
	if err := ws.handshake(); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestWebSocketClientMasksFrames(t *testing.T) {
	server, client := net.Pipe()
	defer client.Close()
	done := make(chan error, 1)
	go func() {
		defer server.Close()
		frame, err := readRawFrame(server)
		if err != nil {
			done <- err
			return
		}
		if !frame.masked || frame.opcode != 0x1 || string(frame.payload) != "hello" {
			done <- errors.New("unexpected client frame")
			return
		}
		done <- nil
	}()
	ws := &wsOverUnixSocket{conn: client, reader: bufio.NewReader(client)}
	if err := ws.writeTextMessage([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestWebSocketReadFragmentedMessageAndPingPong(t *testing.T) {
	server, client := net.Pipe()
	defer client.Close()
	done := make(chan error, 1)
	go func() {
		defer server.Close()
		pongResult := make(chan error, 1)
		go func() {
			frame, err := readRawFrame(server)
			if err != nil {
				pongResult <- err
				return
			}
			if !frame.masked || frame.opcode != 0xA || string(frame.payload) != "hi" {
				pongResult <- errors.New("client did not answer ping with pong")
				return
			}
			pongResult <- nil
		}()
		if err := writeServerFrame(server, false, 0x1, []byte(`{"id":1,`)); err != nil {
			done <- err
			return
		}
		if err := writeServerFrame(server, true, 0x9, []byte("hi")); err != nil {
			done <- err
			return
		}
		if err := writeServerFrame(server, true, 0x0, []byte(`"result":{}}`)); err != nil {
			done <- err
			return
		}
		done <- <-pongResult
	}()
	ws := &wsOverUnixSocket{conn: client, reader: bufio.NewReader(client)}
	payload, err := ws.readTextMessage()
	if err != nil {
		t.Fatal(err)
	}
	if string(payload) != `{"id":1,"result":{}}` {
		t.Fatalf("unexpected fragmented payload: %s", payload)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestListenRequiresLoopbackIPLiteral(t *testing.T) {
	for _, address := range []string{"127.0.0.1:8787", "[::1]:8787"} {
		if err := validateLoopback(address); err != nil {
			t.Fatalf("loopback address %s rejected: %v", address, err)
		}
	}
	for _, address := range []string{"localhost:8787", "0.0.0.0:8787", "127.0.0.1:0"} {
		if err := validateLoopback(address); err == nil {
			t.Fatalf("unsafe address %s accepted", address)
		}
	}
}

func TestCodexBoardAggregateEscalationPriorities(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	board, err := newCodexBoard(config, hub)
	if err != nil {
		t.Fatal(err)
	}
	rootID := "aaaaaaaa-1111-4111-8111-111111111111"
	workingID := "aaaaaaaa-1111-4111-8111-111111111112"
	errorID := "aaaaaaaa-1111-4111-8111-111111111113"
	now := time.Now().Unix()
	name := "上卷优先级fixture"
	raw := []appThreadWire{
		{ID: rootID, Name: &name, Cwd: config.Projects["demo"], Source: json.RawMessage(`"cli"`), Status: appThreadStatus{Type: "idle"}, CreatedAt: now, UpdatedAt: now},
		{ID: workingID, Name: &name, Cwd: config.Projects["demo"], ParentThreadID: &rootID, Source: spawnSource(t, rootID, "worker", 1), Status: appThreadStatus{Type: "active"}, CreatedAt: now, UpdatedAt: now},
		{ID: errorID, Name: &name, Cwd: config.Projects["demo"], ParentThreadID: &rootID, Source: spawnSource(t, rootID, "reviewer", 1), Status: appThreadStatus{Type: "systemError"}, CreatedAt: now, UpdatedAt: now},
	}
	loaded := map[string]bool{rootID: true, workingID: true, errorID: true}
	if err := board.replaceAppThreads(raw, loaded, observerSharedLive, time.Now().Add(-time.Second)); err != nil {
		t.Fatal(err)
	}
	// needs_input 必须压过 error，error 必须压过 working/ready。
	needInputID := "aaaaaaaa-1111-4111-8111-111111111114"
	raw = append(raw, appThreadWire{ID: needInputID, Name: &name, Cwd: config.Projects["demo"], ParentThreadID: &rootID, Source: spawnSource(t, rootID, "gate", 1), Status: appThreadStatus{Type: "active", ActiveFlags: []string{"waitingOnUserInput"}}, CreatedAt: now, UpdatedAt: now})
	loaded[needInputID] = true
	if err := board.replaceAppThreads(raw, loaded, observerSharedLive, time.Now().Add(-time.Second)); err != nil {
		t.Fatal(err)
	}
	threads := board.overview().Threads
	if len(threads) != 4 {
		t.Fatalf("expected root plus three spawns, got %d", len(threads))
	}
	root := observedByTitle(t, threads, name)
	if root.RuntimeState != runtimeReady {
		t.Fatalf("root runtime state should stay ready, got %q", root.RuntimeState)
	}
	if root.AggregateState != runtimeNeedsInput {
		t.Fatalf("aggregate escalation should surface needs_input first, got %q", root.AggregateState)
	}
}

func TestCodexBoardCompletedThreadStaysUnreviewedAndSurvivesRecovery(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	board, err := newCodexBoard(config, hub)
	if err != nil {
		t.Fatal(err)
	}
	rootID := "bbbbbbbb-1111-4111-8111-111111111111"
	now := time.Now().Unix()
	name := "idle完成未验收fixture"
	raw := []appThreadWire{
		{ID: rootID, Name: &name, Cwd: config.Projects["demo"], Source: json.RawMessage(`"exec"`), Status: appThreadStatus{Type: "idle"}, CreatedAt: now, UpdatedAt: now},
	}
	loaded := map[string]bool{rootID: true}
	if err := board.replaceAppThreads(raw, loaded, observerSharedLive, time.Now().Add(-time.Second)); err != nil {
		t.Fatal(err)
	}
	threads := board.overview().Threads
	root := observedByTitle(t, threads, name)
	if root.RuntimeState != runtimeReady || root.LatestTurnState != turnUnknown || root.ReviewState != reviewUnreviewed {
		t.Fatalf("idle thread must be ready/unknown/unreviewed without invented evidence: %#v", root)
	}
	if root.AggregateState != runtimeReady {
		t.Fatalf("completed thread without verification must not look accepted: %q", root.AggregateState)
	}
	// 恢复（进程重启后重建 board）必须保住 publicRef 与验收状态，不依赖内存。
	if err := board.setReview(root.PublicRef, reviewAccepted); err != nil {
		t.Fatal(err)
	}
	recovered, err := newCodexBoard(config, hub)
	if err != nil {
		t.Fatal(err)
	}
	if err := recovered.replaceAppThreads(raw, loaded, observerSharedLive, time.Now().Add(-time.Second)); err != nil {
		t.Fatal(err)
	}
	stable := observedByTitle(t, recovered.overview().Threads, name)
	if stable.PublicRef != root.PublicRef || stable.ReviewState != reviewAccepted {
		t.Fatalf("recovery lost ref continuity or review state: %#v", stable)
	}
	// Finding envelope 必须仍在事件流中重放，恢复后的 overview 不能丢历史 finding。
	if recovered.hub.findingCount() != hub.findingCount() {
		t.Fatalf("finding journal was not replayed after recovery: %d vs %d", recovered.hub.findingCount(), hub.findingCount())
	}
}

func TestCodexBoardCliThreadWithoutNameUsesCommandLineFallback(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	board, err := newCodexBoard(config, hub)
	if err != nil {
		t.Fatal(err)
	}
	rootID := "cccccccc-1111-4111-8111-111111111111"
	now := time.Now().Unix()
	raw := []appThreadWire{
		{ID: rootID, Name: nil, Cwd: config.Projects["demo"], Source: json.RawMessage(`"exec"`), Status: appThreadStatus{Type: "idle"}, CreatedAt: now, UpdatedAt: now},
	}
	loaded := map[string]bool{rootID: true}
	if err := board.replaceAppThreads(raw, loaded, observerSharedLive, time.Now().Add(-time.Second)); err != nil {
		t.Fatal(err)
	}
	threads := board.overview().Threads
	if len(threads) != 1 {
		t.Fatalf("expected one thread, got %d", len(threads))
	}
	root := threads[0]
	if root.Title != "命令行任务" {
		t.Fatalf("expected cli fallback title, got %#v", root)
	}
	if root.SourceKind != "cli" {
		t.Fatalf("expected cli source kind, got %#v", root)
	}
}

func TestCodexObserverNoticeLifecycle(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	board := &CodexBoard{
		threads:        make(map[string]*ObservedThread),
		pendingRuntime: make(map[string]pendingRuntimeUpdate),
		pendingTurns:   make(map[string]pendingTurnUpdate),
		refreshNow:     make(chan struct{}, 1),
		mode:           observerSharedLive,
		code:           "ok",
		hub:            hub,
	}
	board.setObserverNotice([]string{noticeSubAgentQueryDegraded, noticeThreadsTruncated, noticeSubAgentQueryDegraded})
	if board.overview().Observer.Notice != noticeSubAgentQueryDegraded+","+noticeThreadsTruncated {
		t.Fatalf("notice not normalized: %q", board.overview().Observer.Notice)
	}
	board.setObserverNotice(nil)
	if board.overview().Observer.Notice != "" {
		t.Fatalf("notice should clear on a clean refresh, got %q", board.overview().Observer.Notice)
	}
}

func TestSubAgentUnsupportedErrorClassification(t *testing.T) {
	unsupported := []string{
		"app_server_response: unknown method thread/list",
		"app_server_response: invalid sourceKinds value",
		"app_server_response: unsupported source kind subAgentThreadSpawn",
	}
	for _, text := range unsupported {
		if !subAgentUnsupportedError(errors.New(text)) {
			t.Fatalf("expected unsupported classification for %q", text)
		}
	}
	transient := []string{
		"app_server_timeout",
		"app_server_disconnected",
		"app_server_response",
	}
	for _, text := range transient {
		if subAgentUnsupportedError(errors.New(text)) {
			t.Fatalf("expected degraded classification for %q", text)
		}
	}
}

// These expectations enforce reserve policy, unlike the audit's observation probe.
func TestD2QuotaBoundaries(t *testing.T) {
	now := time.Unix(1800000000, 0).UTC()
	for _, tc := range d2QuotaCases() {
		t.Run(tc.name, func(t *testing.T) {
			account := AccountConfig{Alias: "synthetic", Home: filepath.Join(t.TempDir(), "account")}
			hub := &Hub{config: Config{Accounts: []AccountConfig{account}, ApprovalQuotaMaxAgeSeconds: 300},
				managerSnapshotPath: d2QuotaSnapshot(t, account, now, tc)}
			if got := hub.approvalQuotaReadyLocked(account.Alias, now); got != tc.ready {
				t.Errorf("approval ready = %v, want %v", got, tc.ready)
			}
			if got := hub.quotaExceededAliasesLocked()[account.Alias]; got != tc.excluded {
				t.Errorf("creation excluded = %v, want %v", got, tc.excluded)
			}
		})
	}
}

type d2QuotaCase struct {
	name, five, seven, fiveReset, sevenReset, plan, raw string
	age                                                 int
	ready, excluded                                     bool
}

func d2QuotaCases() []d2QuotaCase {
	cases := []d2QuotaCase{
		{name: "remaining_30_15", ready: true},
		{name: "remaining_29", five: "71", excluded: true},
		{name: "remaining_14", seven: "86", excluded: true},
		{name: "zero_used", five: "0", seven: "0", ready: true},
		{name: "seven_value_missing", seven: "null"},
		{name: "seven_reset_missing", sevenReset: "null"},
		{name: "five_reset_now", fiveReset: "now"},
		{name: "seven_reset_now", sevenReset: "now"},
		{name: "five_reset_past", fiveReset: "past"},
		{name: "seven_reset_past", sevenReset: "past"},
		{name: "age_46", age: 46, ready: true},
		{name: "age_300", age: 300, ready: true},
		{name: "age_301", age: 301},
		{name: "future_5", age: -5, ready: true},
		{name: "future_6", age: -6},
		{name: "five_negative", five: "-1", excluded: true},
		{name: "seven_negative", seven: "-1", excluded: true},
		{name: "five_over100", five: "101", excluded: true},
		{name: "seven_over100", seven: "101", excluded: true},
		{name: "five_string", five: `"70"`, excluded: true},
		{name: "seven_string", seven: `"85"`, excluded: true},
		{name: "nan", five: "NaN", excluded: true},
		{name: "infinity", five: "Infinity", excluded: true},
		{name: "overflow", five: "1e999", excluded: true},
		{name: "five_reset_string", fiveReset: `"bad"`, excluded: true},
		{name: "seven_reset_string", sevenReset: `"bad"`, excluded: true},
		{name: "invalid_json", raw: "{", excluded: true},
		{name: "malformed_profiles", raw: `{"profiles":"bad"}`, excluded: true},
		{name: "no_profiles", raw: `{"profiles":[]}`},
		{name: "free_plan", plan: " FREE "},
		{name: "empty_plan", plan: " "},
		{name: "fetched_missing"},
		{name: "duplicate_match"},
		{name: "unmatched_alias"},
		{name: "window_missing"},
	}
	for _, plan := range []string{"plus", "pro"} {
		cases = append(cases,
			d2QuotaCase{name: plan + "_five_value_missing", plan: plan, five: "null"},
			d2QuotaCase{name: plan + "_five_reset_missing", plan: plan, fiveReset: "null"},
			d2QuotaCase{name: plan + "_five_both_missing", plan: plan, five: "null", fiveReset: "null"})
	}
	return cases
}

func d2QuotaSnapshot(t *testing.T, account AccountConfig, now time.Time, tc d2QuotaCase) string {
	t.Helper()
	five, seven, plan := tc.five, tc.seven, tc.plan
	if five == "" {
		five = "70"
	}
	if seven == "" {
		seven = "85"
	}
	if plan == "" {
		plan = "plus"
	}
	reset := func(value string) string {
		switch value {
		case "":
			return fmt.Sprint(now.Add(time.Hour).Unix() - appleEpochUnixOffset)
		case "now":
			return fmt.Sprint(now.Unix() - appleEpochUnixOffset)
		case "past":
			return fmt.Sprint(now.Add(-time.Second).Unix() - appleEpochUnixOffset)
		default:
			return value
		}
	}
	profile := fmt.Sprintf(`{"name":%q,"codexHomePath":%q,"lastSnapshot":{"planType":%q,"fetchedAt":%d,"quotaReadSucceeded":true,"fiveHour":{"usedPercent":%s,"resetsAt":%s},"sevenDay":{"usedPercent":%s,"resetsAt":%s}}}`,
		account.Alias, account.Home, plan, now.Unix()-appleEpochUnixOffset-int64(tc.age), five, reset(tc.fiveReset), seven, reset(tc.sevenReset))
	switch tc.name {
	case "fetched_missing":
		profile = strings.Replace(profile, fmt.Sprintf(`"fetchedAt":%d`, now.Unix()-appleEpochUnixOffset), `"fetchedAt":null`, 1)
	case "duplicate_match":
		profile += "," + profile
	case "unmatched_alias":
		profile = strings.Replace(profile, fmt.Sprintf(`"codexHomePath":%q`, account.Home), `"codexHomePath":"/synthetic/unmatched"`, 1)
	case "window_missing":
		profile = fmt.Sprintf(`{"name":%q,"codexHomePath":%q,"lastSnapshot":{"planType":"plus","fetchedAt":%d}}`, account.Alias, account.Home, now.Unix()-appleEpochUnixOffset)
	}
	raw := `{"profiles":[` + profile + `]}`
	if tc.raw != "" {
		raw = tc.raw
	}
	path := filepath.Join(t.TempDir(), "quota.json")
	if err := os.WriteFile(path, []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestD2RejectedApprovalPreservesTaskAndLeases(t *testing.T) {
	for _, tc := range d2QuotaCases() {
		if tc.ready {
			continue
		}
		t.Run(tc.name, func(t *testing.T) {
			config := testConfig(t, "/usr/bin/true")
			account := testAccountConfig(t, t.TempDir(), "synthetic")
			config.Accounts = []AccountConfig{account}
			hub, err := newHub(config)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { hub.shutdown(context.Background()) })
			hub.managerSnapshotPath = writeApprovalQuotaSnapshot(t, account, time.Now(), 70, 85)
			task, err := hub.create(CreateRequest{RequestID: "d2-create-approval", Agent: "codex", Project: "demo", AccountAlias: account.Alias, Prompt: "fixture"})
			if err != nil {
				t.Fatal(err)
			}
			hub.managerSnapshotPath = d2QuotaSnapshot(t, account, time.Now().UTC().Truncate(time.Second), tc)
			hub.mu.Lock()
			// Preserve both an existing own-project lease and another project's lease.
			hub.leases[task.Project] = task.ID
			hub.leases["other"] = "existing-owner"
			seq, requests := hub.store.lastSeq, len(hub.requests)
			hub.mu.Unlock()
			_, err = hub.approve(task.ID, ApproveRequest{RequestID: "d2-reject-approval", ActionHash: task.ActionHash})
			if !errors.Is(err, errAccountQuotaReserve) {
				t.Fatalf("approval error = %v", err)
			}
			hub.mu.Lock()
			defer hub.mu.Unlock()
			current := hub.tasks[task.ID]
			if current.State != stateAwaitingApproval || current.Version != task.Version || current.ActionHash != task.ActionHash || taskActionHash(current) != task.ActionHash {
				t.Error("rejected approval changed state/version/action hash")
			}
			if len(hub.leases) != 2 || hub.leases[task.Project] != task.ID || hub.leases["other"] != "existing-owner" || !current.holdsAccountLeaseAt(time.Now()) {
				t.Error("rejected approval changed existing leases")
			}
			if current.PID != 0 || len(hub.handles) != 0 || hub.pendingPrompts[task.ID] != "fixture" || hub.store.lastSeq != seq || len(hub.requests) != requests {
				t.Error("rejected approval started execution or changed pending data/journal")
			}
		})
	}
}

func TestD2CreationReserveAcrossStrategies(t *testing.T) {
	for _, strategy := range []string{"explicit", "round_robin", "least_recently_used"} {
		for _, tc := range []d2QuotaCase{
			{name: "remaining_30_15", ready: true},
			{name: "remaining_29", five: "71", excluded: true},
			{name: "remaining_14", seven: "86", excluded: true},
			{name: "five_negative", five: "-1", excluded: true},
			{name: "seven_over100", seven: "101", excluded: true},
			{name: "seven_missing", seven: "null"},
			{name: "string", five: `"bad"`, excluded: true},
			{name: "invalid_json", raw: "{", excluded: true},
		} {
			t.Run(strategy+"/"+tc.name, func(t *testing.T) {
				config := testConfig(t, "/usr/bin/true")
				account := testAccountConfig(t, t.TempDir(), "candidate")
				config.Accounts = []AccountConfig{account}
				requested := account.Alias
				if strategy != "explicit" {
					config.AccountStrategy, requested = strategy, ""
				}
				hub, err := newHub(config)
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { hub.shutdown(context.Background()) })
				hub.managerSnapshotPath = d2QuotaSnapshot(t, account, time.Now(), tc)
				task, err := hub.create(CreateRequest{RequestID: "d2-create-strategy", Agent: "codex", Project: "demo", AccountAlias: requested, Prompt: "fixture"})
				if tc.excluded {
					if !errors.Is(err, errAccountQuotaReserve) {
						t.Fatalf("creation error = %v", err)
					}
				} else if err != nil || task.State != stateAwaitingApproval || task.Account != account.Alias {
					t.Fatalf("creation did not produce expected draft: %v", err)
				}
			})
		}
		if strategy == "explicit" {
			continue
		}
		for _, five := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/skips_five_%t", strategy, five), func(t *testing.T) {
				config := testConfig(t, "/usr/bin/true")
				config.AccountStrategy = strategy
				config.Accounts = []AccountConfig{testAccountConfig(t, t.TempDir(), "low"), testAccountConfig(t, t.TempDir(), "eligible")}
				hub, err := newHub(config)
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { hub.shutdown(context.Background()) })
				hub.managerSnapshotPath = writeQuotaSnapshots(t, config.Accounts, []string{"86", "85"})
				if five {
					data, err := os.ReadFile(hub.managerSnapshotPath)
					if err != nil {
						t.Fatal(err)
					}
					data = bytes.Replace(data, []byte(`"fiveHour":{"usedPercent":0},"sevenDay":{"usedPercent":86}`), []byte(`"fiveHour":{"usedPercent":71},"sevenDay":{"usedPercent":20}`), 1)
					if err := os.WriteFile(hub.managerSnapshotPath, data, 0o600); err != nil {
						t.Fatal(err)
					}
				}
				// The quota check must beat even a strong LRU preference for the low account.
				hub.accountUsed["eligible"] = 99
				task, err := hub.create(CreateRequest{RequestID: "d2-create-skip", Agent: "codex", Project: "demo", Prompt: "fixture"})
				if err != nil || task.Account != "eligible" {
					t.Fatalf("strategy did not skip low account: %v", err)
				}
			})
		}
	}
}

func TestCanonicalProjectLeaseRecoveryRejectsDuplicateCWD(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	config.Projects["alias"] = config.Projects["demo"]
	first, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	firstTask, err := first.create(CreateRequest{RequestID: "canonical-recovery-first-0001", Agent: "codex", Project: "demo", Prompt: "first"})
	if err != nil {
		t.Fatal(err)
	}
	secondTask, err := first.create(CreateRequest{RequestID: "canonical-recovery-second-0001", Agent: "codex", Project: "alias", Prompt: "second"})
	if err != nil {
		t.Fatal(err)
	}
	first.mu.Lock()
	for _, taskID := range []string{firstTask.ID, secondTask.ID} {
		task := first.tasks[taskID]
		if err := first.transitionLocked(task, stateStarting, "fixture", "task.approved", nil); err != nil {
			first.mu.Unlock()
			t.Fatal(err)
		}
		first.leases[task.Project] = task.ID
	}
	first.mu.Unlock()
	if err := first.store.Close(); err != nil {
		t.Fatal(err)
	}
	if err := first.messageStore.Close(); err != nil {
		t.Fatal(err)
	}
	if recovered, err := newHub(config); err == nil {
		recovered.shutdown(context.Background())
		t.Fatal("recovery accepted two active aliases for one canonical project")
	}
}

func TestApprovalExpiresAtExactBoundary(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	task, err := hub.create(CreateRequest{RequestID: "approval-equality-create-0001", Agent: "codex", Project: "demo", Prompt: "fixture"})
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1800000000, 0).UTC()
	hub.mu.Lock()
	hub.tasks[task.ID].ApprovalExpiresAt = now
	hub.mu.Unlock()
	result, err := hub.approveAt(task.ID, ApproveRequest{RequestID: "approval-equality-approve-0001", ActionHash: task.ActionHash}, now)
	if err != nil || result.State != stateBlockedConfiguration || result.ReasonCode != "approval_expired" {
		t.Fatalf("approval at expiry boundary was not blocked: %#v %v", result, err)
	}
}

func TestCreationDoesNotCommitSelectionWhenPreferenceInvalid(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	config.AccountStrategy = "round_robin"
	account := testAccountConfig(t, t.TempDir(), "acct-a")
	config.Accounts = []AccountConfig{account}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.managerSnapshotPath = writeRawManagerSnapshot(t, fmt.Sprintf(`{"profiles":[{"name":%q,"codexHomePath":%q,"executionPreference":{"model":"unsupported","reasoningEffort":"high","serviceTier":"default"},"lastSnapshot":{"quotaReadSucceeded":true}}]}`, account.Alias, account.Home))
	if _, err := hub.create(CreateRequest{RequestID: "selection-preference-invalid-0001", Agent: "codex", Project: "demo", Prompt: "fixture"}); !errors.Is(err, errInvalid) {
		t.Fatalf("invalid preference did not reject creation: %v", err)
	}
	hub.mu.Lock()
	defer hub.mu.Unlock()
	if hub.accountCursor != 0 || hub.accountTick != 0 || len(hub.accountUsed) != 0 {
		t.Fatalf("invalid preference consumed account selection: cursor=%d tick=%d used=%v", hub.accountCursor, hub.accountTick, hub.accountUsed)
	}
}

func TestApprovalDoesNotCommitAccountUseTwice(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	config.AccountStrategy = "least_recently_used"
	account := testAccountConfig(t, t.TempDir(), "acct-a")
	config.Accounts = []AccountConfig{account}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.managerSnapshotPath = writeApprovalQuotaSnapshot(t, account, time.Now().UTC(), 20, 20)
	task, err := hub.create(CreateRequest{RequestID: "lru-single-commit-create-0001", Agent: "codex", Project: "demo", Prompt: "fixture"})
	if err != nil {
		t.Fatal(err)
	}
	hub.mu.Lock()
	tick, used := hub.accountTick, hub.accountUsed[account.Alias]
	hub.mu.Unlock()
	if tick != 1 || used != 1 {
		t.Fatalf("successful create did not commit exactly once: tick=%d used=%d", tick, used)
	}
	if _, err := hub.approve(task.ID, ApproveRequest{RequestID: "lru-single-commit-approve-0001", ActionHash: task.ActionHash}); err != nil {
		t.Fatal(err)
	}
	hub.mu.Lock()
	defer hub.mu.Unlock()
	if hub.accountTick != tick || hub.accountUsed[account.Alias] != used {
		t.Fatalf("approval committed a second account use: tick=%d used=%d", hub.accountTick, hub.accountUsed[account.Alias])
	}
}

func TestCreationRejectsAutomaticSwitchOptOut(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	account := testAccountConfig(t, t.TempDir(), "acct-a")
	config.Accounts = []AccountConfig{account}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.managerSnapshotPath = writeQuotaSignalSnapshot(t, account, time.Now().UTC(), true, nil, boolPointer(false))
	if _, err := hub.create(CreateRequest{RequestID: "automatic-switch-optout-0001", Agent: "codex", Project: "demo", AccountAlias: account.Alias, Prompt: "fixture"}); !errors.Is(err, errAccountQuotaReserve) {
		t.Fatalf("automatic switch opt-out was allowed to create a draft: %v", err)
	}
}

func TestApprovalRejectsFailedOrNewerQuotaSignal(t *testing.T) {
	for _, test := range []struct {
		name       string
		succeeded  bool
		failureNow bool
	}{
		{name: "read_failed", succeeded: false},
		{name: "failure_at_fetched_at", succeeded: true, failureNow: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			config := testConfig(t, "/usr/bin/true")
			account := testAccountConfig(t, t.TempDir(), "acct-a")
			config.Accounts = []AccountConfig{account}
			hub, err := newHub(config)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { hub.shutdown(context.Background()) })
			now := time.Now().UTC().Truncate(time.Second)
			hub.managerSnapshotPath = writeApprovalQuotaSnapshot(t, account, now, 20, 20)
			task, err := hub.create(CreateRequest{RequestID: "quota-signal-create-0001", Agent: "codex", Project: "demo", AccountAlias: account.Alias, Prompt: "fixture"})
			if err != nil {
				t.Fatal(err)
			}
			var failureAt *time.Time
			if test.failureNow {
				failureAt = &now
			}
			hub.managerSnapshotPath = writeQuotaSignalSnapshot(t, account, now, test.succeeded, failureAt, nil)
			if _, err := hub.approve(task.ID, ApproveRequest{RequestID: "quota-signal-approve-0001", ActionHash: task.ActionHash}); !errors.Is(err, errAccountQuotaReserve) {
				t.Fatalf("invalid quota signal approved execution: %v", err)
			}
			hub.mu.Lock()
			current := hub.tasks[task.ID]
			hub.mu.Unlock()
			if current.State != stateAwaitingApproval {
				t.Fatalf("quota rejection mutated the approval draft: %#v", current)
			}
		})
	}
}

func TestDispatchPolicyHotReadBlocksNewApprovalAndPreStart(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	account := testAccountConfig(t, t.TempDir(), "acct-a")
	config.Accounts = []AccountConfig{account}
	policyPath := filepath.Join(t.TempDir(), "config.json")
	writeDispatchPolicy(t, policyPath, config)
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.dispatchPolicyPath = policyPath
	hub.managerSnapshotPath = writeApprovalQuotaSnapshot(t, account, time.Now().UTC(), 20, 20)
	task, err := hub.create(CreateRequest{RequestID: "policy-hot-create-0001", Agent: "codex", Project: "demo", AccountAlias: account.Alias, Prompt: "fixture"})
	if err != nil {
		t.Fatal(err)
	}
	config.Accounts[0].DispatchDisabled = true
	writeDispatchPolicy(t, policyPath, config)
	if _, err := hub.approve(task.ID, ApproveRequest{RequestID: "policy-hot-approve-0001", ActionHash: task.ActionHash}); !errors.Is(err, errDispatchDisabled) {
		t.Fatalf("hot dispatch policy did not reject approval: %v", err)
	}
	hub.mu.Lock()
	if current := hub.tasks[task.ID]; current.State != stateAwaitingApproval {
		hub.mu.Unlock()
		t.Fatalf("policy rejection changed approval draft: %#v", current)
	}
	manual := &Task{ID: "policy-prestart-task", Agent: "codex", Project: "demo", AccountAlias: account.Alias, State: stateStarting}
	hub.tasks[manual.ID] = manual
	hub.pendingPrompts[manual.ID] = "fixture"
	hub.leases[manual.Project] = manual.ID
	hub.mu.Unlock()
	hub.runTask(manual.ID)
	hub.mu.Lock()
	defer hub.mu.Unlock()
	if current := hub.tasks[manual.ID]; current.State != stateBlockedConfiguration || current.ReasonCode != errDispatchDisabled.Error() || current.PID != 0 || hub.leases[manual.Project] != "" {
		t.Fatalf("pre-start policy block was incomplete: %#v leases=%v", current, hub.leases)
	}
}

func TestDispatchPolicyUnavailableFailsClosedWithoutMutatingDraft(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	account := testAccountConfig(t, t.TempDir(), "acct-a")
	config.Accounts = []AccountConfig{account}
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.dispatchPolicyPath = filepath.Join(t.TempDir(), "missing-config.json")
	if _, err := hub.create(CreateRequest{RequestID: "policy-missing-create-0001", Agent: "codex", Project: "demo", AccountAlias: account.Alias, Prompt: "fixture"}); !errors.Is(err, errDispatchPolicyUnavailable) {
		t.Fatalf("missing dispatch policy did not fail closed: %v", err)
	}
	response := httptest.NewRecorder()
	writeTaskResult(response, TaskDTO{}, errDispatchPolicyUnavailable, http.StatusOK)
	if response.Code != http.StatusServiceUnavailable || strings.TrimSpace(response.Body.String()) != `{"error":"dispatch_policy_unavailable"}` {
		t.Fatalf("dispatch policy API response = %d %s", response.Code, response.Body.String())
	}
}

func TestDispatchPolicyUnavailableAtApprovalPreservesDraft(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	account := testAccountConfig(t, t.TempDir(), "acct-a")
	config.Accounts = []AccountConfig{account}
	policyPath := filepath.Join(t.TempDir(), "config.json")
	writeDispatchPolicy(t, policyPath, config)
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.dispatchPolicyPath = policyPath
	hub.managerSnapshotPath = writeApprovalQuotaSnapshot(t, account, time.Now().UTC(), 20, 20)
	task, err := hub.create(CreateRequest{RequestID: "policy-unavailable-approve-create-0001", Agent: "codex", Project: "demo", AccountAlias: account.Alias, Prompt: "fixture"})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(policyPath); err != nil {
		t.Fatal(err)
	}
	if _, err := hub.approve(task.ID, ApproveRequest{RequestID: "policy-unavailable-approve-0001", ActionHash: task.ActionHash}); !errors.Is(err, errDispatchPolicyUnavailable) {
		t.Fatalf("missing policy did not reject approval: %v", err)
	}
	hub.mu.Lock()
	defer hub.mu.Unlock()
	if current := hub.tasks[task.ID]; current.State != stateAwaitingApproval || current.PID != 0 || hub.leases[task.Project] != "" {
		t.Fatalf("unavailable policy mutated approval draft: %#v leases=%v", current, hub.leases)
	}
}

func TestDispatchPolicyReadsOnlyDispatchDisabled(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	account := testAccountConfig(t, t.TempDir(), "acct-a")
	config.Accounts = []AccountConfig{account}
	policyPath := filepath.Join(t.TempDir(), "config.json")
	candidate := config
	candidate.Commands = map[string]string{"codex": "/definitely/missing", "claude": "/definitely/missing", "kimi": "/definitely/missing"}
	candidate.Mode = "workspace-write"
	candidate.AccountStrategy = "system"
	writeDispatchPolicy(t, policyPath, candidate)
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.dispatchPolicyPath = policyPath
	hub.managerSnapshotPath = writeApprovalQuotaSnapshot(t, account, time.Now().UTC(), 20, 20)
	task, err := hub.create(CreateRequest{RequestID: "policy-flags-only-create-0001", Agent: "codex", Project: "demo", AccountAlias: account.Alias, Prompt: "fixture"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := hub.approve(task.ID, ApproveRequest{RequestID: "policy-flags-only-approve-0001", ActionHash: task.ActionHash}); err != nil {
		t.Fatal(err)
	}
	if completed := waitForState(t, hub, task.ID, stateSucceeded); completed.ReasonCode != "process_exit_zero" {
		t.Fatalf("non-policy hot config leaked into execution: %#v", completed)
	}
}

func TestDispatchPolicyRejectsAliasHomeDrift(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	account := testAccountConfig(t, t.TempDir(), "acct-a")
	config.Accounts = []AccountConfig{account}
	policyPath := filepath.Join(t.TempDir(), "config.json")
	candidate := config
	candidate.Accounts = append([]AccountConfig(nil), config.Accounts...)
	candidate.Accounts[0].Home = t.TempDir()
	writeDispatchPolicy(t, policyPath, candidate)
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	hub.dispatchPolicyPath = policyPath
	if _, err := hub.create(CreateRequest{RequestID: "policy-home-drift-0001", Agent: "codex", Project: "demo", AccountAlias: account.Alias, Prompt: "fixture"}); !errors.Is(err, errDispatchPolicyUnavailable) {
		t.Fatalf("alias/home drift did not fail closed: %v", err)
	}
}

func writeQuotaSignalSnapshot(t *testing.T, account AccountConfig, fetchedAt time.Time, succeeded bool, failureAt *time.Time, participation *bool) string {
	t.Helper()
	fetched := fetchedAt.Unix() - appleEpochUnixOffset
	fiveReset := fetchedAt.Add(time.Hour).Unix() - appleEpochUnixOffset
	sevenReset := fetchedAt.Add(2*time.Hour).Unix() - appleEpochUnixOffset
	failure := "null"
	if failureAt != nil {
		failure = fmt.Sprint(failureAt.Unix() - appleEpochUnixOffset)
	}
	optIn := "null"
	if participation != nil {
		optIn = fmt.Sprint(*participation)
	}
	return writeRawManagerSnapshot(t, fmt.Sprintf(`{"profiles":[{"name":%q,"codexHomePath":%q,"lastQuotaReadFailureAt":%s,"automaticSwitchParticipation":%s,"lastSnapshot":{"planType":"plus","fetchedAt":%d,"quotaReadSucceeded":%t,"fiveHour":{"usedPercent":20,"resetsAt":%d},"sevenDay":{"usedPercent":20,"resetsAt":%d}}}]}`,
		account.Alias, account.Home, failure, optIn, fetched, succeeded, fiveReset, sevenReset))
}

func boolPointer(value bool) *bool { return &value }

func writeDispatchPolicy(t *testing.T, path string, config Config) {
	t.Helper()
	contents, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, contents, 0o600); err != nil {
		t.Fatal(err)
	}
}
