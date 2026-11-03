//go:build !windows

package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func writeActivityFixture(t *testing.T, hub *Hub, route, state, leaseID, hubTaskID string) {
	t.Helper()
	root, err := filepath.EvalSymlinks(hub.config.Projects["demo"])
	if err != nil {
		t.Fatal(err)
	}
	now := float64(time.Now().UnixNano()) / 1e9
	data, err := json.Marshal(map[string]any{"schemaVersion": 1, "leases": []any{map[string]any{
		"leaseId": leaseID, "ownerThreadId": "fixture-owner", "taskId": "fixture-task", "hubTaskId": hubTaskID,
		"accountKey": activityHash("fixture-account"), "aliasKey": activityHash("system"), "projectKey": activityHash(root),
		"route": route, "state": state, "createdAt": now, "updatedAt": now, "heartbeatDueAt": now + 600,
	}}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(hub.activityDirectory, "dispatch-activity-v1.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
}

func newActivityTestHub(t *testing.T) *Hub {
	t.Helper()
	hub, err := newHub(testConfig(t, "/usr/bin/true"))
	if err != nil {
		t.Fatal(err)
	}
	hub.activityDirectory = t.TempDir()
	if err := os.Chmod(hub.activityDirectory, 0700); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	return hub
}

func TestExternalActivityBlocksCreateAndApproval(t *testing.T) {
	for _, route := range []string{"terminal", "warmup", "maintenance", "direct"} {
		t.Run(route, func(t *testing.T) {
			hub := newActivityTestHub(t)
			writeActivityFixture(t, hub, route, "preparing", "other-lease", "")
			request := CreateRequest{RequestID: "activity-create-001", Agent: "codex", Project: "demo", Prompt: "fixture"}
			if _, err := hub.create(request); !errors.Is(err, errAccountBusy) {
				t.Fatalf("create admitted external activity: %v", err)
			}
			writeActivityFixture(t, hub, route, "accepted", "other-lease", "")
			task, err := hub.create(request)
			if err != nil {
				t.Fatal(err)
			}
			writeActivityFixture(t, hub, route, "uncertain", "other-lease", "")
			if _, err := hub.approve(task.ID, ApproveRequest{RequestID: "activity-approve-001", ActionHash: task.ActionHash}); !errors.Is(err, errAccountBusy) {
				t.Fatalf("approval admitted uncertain activity: %v", err)
			}
			if hub.tasks[task.ID].State != stateAwaitingApproval {
				t.Fatal("blocked approval changed task state")
			}
		})
	}
}

func TestHubReservationRequiresExactFreshBinding(t *testing.T) {
	hub := newActivityTestHub(t)
	writeActivityFixture(t, hub, "hub", "preparing", "own-lease", "")
	task, err := hub.create(CreateRequest{RequestID: "own-reservation-001", Agent: "codex", Project: "demo", Prompt: "fixture", DispatchLeaseID: "own-lease"})
	if err != nil {
		t.Fatal(err)
	}
	if err := hub.dispatchActivityAllowed("system", "demo", "own-lease", task.ID, time.Now()); !errors.Is(err, errAccountBusy) {
		t.Fatal("unbound reservation admitted approval")
	}
	writeActivityFixture(t, hub, "hub", "preparing", "own-lease", task.ID)
	if err := hub.dispatchActivityAllowed("system", "demo", "own-lease", task.ID, time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := hub.dispatchActivityAllowed("system", "demo", "own-lease", task.ID, time.Now().Add(11*time.Minute)); !errors.Is(err, errAccountBusy) {
		t.Fatal("expired lease admitted")
	}
	writeActivityFixture(t, hub, "terminal", "preparing", "own-lease", task.ID)
	if err := hub.dispatchActivityAllowed("system", "demo", "own-lease", task.ID, time.Now()); !errors.Is(err, errAccountBusy) {
		t.Fatal("terminal lease impersonated Hub lease")
	}
	writeActivityFixture(t, hub, "hub", "cancel_requested", "own-lease", task.ID)
	if err := hub.dispatchActivityAllowed("system", "demo", "own-lease", task.ID, time.Now()); !errors.Is(err, errAccountBusy) {
		t.Fatal("cancelled reservation admitted approval")
	}
}

func TestActivityFileAndLockFailClosed(t *testing.T) {
	hub := newActivityTestHub(t)
	writeActivityFixture(t, hub, "terminal", "running", "other-lease", "")
	path := filepath.Join(hub.activityDirectory, "dispatch-activity-v1.json")
	if err := os.Chmod(path, 0666); err != nil {
		t.Fatal(err)
	}
	if _, err := hub.readDispatchActivity(); !errors.Is(err, errDispatchPolicyUnavailable) {
		t.Fatal("unprotected registry admitted")
	}
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	unlock, err := hub.lockDispatchActivity()
	if err != nil {
		t.Fatal(err)
	}
	fd, err := syscall.Open(filepath.Join(hub.activityDirectory, ".dispatch-activity.lock"), syscall.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer syscall.Close(fd)
	if syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB) == nil {
		t.Fatal("shared activity lock was not held")
	}
	unlock()
	if err := syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	syscall.Flock(fd, syscall.LOCK_UN)
	if err := os.WriteFile(path, []byte(`{"schemaVersion":1,"leases":[{}]}`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := hub.readDispatchActivity(); !errors.Is(err, errDispatchPolicyUnavailable) {
		t.Fatal("malformed registry admitted")
	}
	for _, mode := range []os.FileMode{0770, 0777} {
		if err := os.Chmod(hub.activityDirectory, mode); err != nil {
			t.Fatal(err)
		}
		if release, err := hub.lockDispatchActivity(); err == nil {
			release()
			t.Fatal("writable activity directory admitted")
		}
	}
}

func TestActivitySharesIdentityAcrossDifferentAliases(t *testing.T) {
	hub := newActivityTestHub(t)
	account := testAccountConfig(t, t.TempDir(), "second-alias")
	hub.config.Accounts = []AccountConfig{account}
	data, err := json.Marshal(managerSnapshotFile{Profiles: []managerProfile{{
		CodexHomePath: account.Home, LastSnapshot: &managerAccountSnapshot{Email: "fixture-account"},
	}}})
	if err != nil {
		t.Fatal(err)
	}
	hub.managerSnapshotPath = filepath.Join(t.TempDir(), "manager.json")
	if err := os.WriteFile(hub.managerSnapshotPath, data, 0600); err != nil {
		t.Fatal(err)
	}
	writeActivityFixture(t, hub, "terminal", "running", "other-lease", "")
	// The fixture uses alias "system"; this alias has the same account identity.
	busy, err := hub.activityBusyAliases("")
	if err != nil || !busy[account.Alias] {
		t.Fatalf("same identity admitted selection: %v", err)
	}
	other := t.TempDir()
	hub.config.Projects["different-project"] = other
	if err := hub.dispatchActivityAllowed(account.Alias, "different-project", "", "", time.Now()); !errors.Is(err, errAccountBusy) {
		t.Fatalf("same identity admitted a different project: %v", err)
	}
}
