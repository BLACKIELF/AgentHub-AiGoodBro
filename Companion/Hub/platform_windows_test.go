//go:build windows

package main

import (
	"context"
	"encoding/json"
	"errors"
	"golang.org/x/sys/windows"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
	"unsafe"
)

// Synthetic executables are this test binary. No model, login, account or
// installed application is invoked by these native lifecycle fixtures.
func TestMain(m *testing.M) {
	if len(os.Args) > 1 && os.Args[1] == "--hub-native-idle" {
		time.Sleep(time.Hour)
		os.Exit(0)
	}
	execFixture := false
	for _, argument := range os.Args[1:] {
		if argument == "exec" {
			execFixture = true
		}
	}
	// commandFor emits global Codex flags before its exec subcommand.
	if execFixture {
		child := exec.Command(os.Args[0], "--hub-native-idle")
		if child.Start() != nil {
			os.Exit(22)
		}
		if os.WriteFile("fixture-child-pid.tmp", []byte(strconv.Itoa(child.Process.Pid)), 0600) != nil || os.Rename("fixture-child-pid.tmp", "fixture-child-pid") != nil {
			os.Exit(23)
		}
		if _, err := os.Stat("fixture-parent-exit"); err == nil {
			os.Exit(0)
		}
		time.Sleep(time.Hour)
		os.Exit(0)
	}
	os.Exit(m.Run())
}
func nativePrivateRoot(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "owned")
	if err := ensurePrivateDir(path); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestNativeWindowsUncertainResolutionRequiresEmptyOwnedJob(t *testing.T) {
	root := nativePrivateRoot(t)
	config := testConfig(t, os.Args[0])
	config.DataDir = filepath.Join(root, "state")
	config.Projects["demo"] = root
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	defer hub.shutdown(context.Background())
	hub.managerSnapshotPath = filepath.Join(root, "absent-snapshot")
	created, err := hub.create(CreateRequest{RequestID: "uncertain-create-001", Agent: "codex", Project: "demo", Prompt: "synthetic fixture"})
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(os.Args[0], "exec")
	cmd.Dir = root
	owned, err := startOwnedCommand(cmd)
	if err != nil {
		t.Fatal(err)
	}
	handle := &processHandle{owned: owned, pid: cmd.Process.Pid, process: cmd.Process, done: make(chan struct{}), exitDone: make(chan struct{}), stopDone: make(chan struct{})}
	// Hold the existing automatic session-mismatch stop pending, so resolution
	// is tested against an actually live native tree, never a scheduling guess.
	handle.stopOnce.Do(func() {})
	waited, stopReleased := false, false
	defer func() {
		if !waited {
			windows.TerminateJobObject(owned.job, 1)
			cmd.Wait()
			markExitedAndVerify(handle)
			close(handle.done)
		}
		if !stopReleased {
			close(handle.stopDone)
		}
		releaseOwnedProcess(owned)
	}()
	child := waitNativeChild(t, root)
	defer windows.CloseHandle(child)
	hub.mu.Lock()
	task := hub.tasks[created.ID]
	task.State = stateRunning
	task.SessionID = "original-session-1234"
	task.SessionVerified = true
	task.PID = cmd.Process.Pid
	hub.handles[task.ID] = handle
	hub.ownedTasks[task.ID] = true
	hub.leases[task.Project] = task.ID
	hub.mu.Unlock()
	hub.bindSession(task.ID, "different-session-5678")
	uncertain := taskByID(t, hub, task.ID)
	if uncertain.State != stateUncertain || uncertain.ReasonCode != "session_mismatch" {
		t.Fatal("mismatch did not become uncertain")
	}
	hub.finishOwnedHandle(task.ID, handle)
	if hub.handles[task.ID] != handle || owned.closed {
		t.Fatal("uncertain cleanup lost the owned fence")
	}
	request := ResolveRequest{RequestID: "uncertain-resolve-001", ExpectedVersion: uncertain.Version, ConfirmedStopped: true}
	if _, e := hub.resolve(task.ID, request); e != errConflict {
		t.Fatal("live Job resolved", e)
	}
	if state, e := windows.WaitForSingleObject(child, 0); e != nil || state != uint32(windows.WAIT_TIMEOUT) {
		t.Fatal("resolve killed a live child", state, e)
	}
	hub.mu.Lock()
	delete(hub.handles, task.ID)
	hub.mu.Unlock()
	if _, e := hub.resolve(task.ID, request); e != errConflict {
		t.Fatal("missing session handle counted as stopped", e)
	}
	hub.mu.Lock()
	hub.handles[task.ID] = handle
	hub.mu.Unlock()
	wrong := request
	wrong.ExpectedVersion++
	if _, e := hub.resolve(task.ID, wrong); e != errConflict {
		t.Fatal("stale version resolved", e)
	}
	if hub.leases[task.Project] != task.ID {
		t.Fatal("failed resolution released reservation")
	}
	// Only fixture cleanup stops the synthetic tree; resolve never does so.
	if e := windows.TerminateJobObject(owned.job, 1); e != nil {
		t.Fatal(e)
	}
	cmd.Wait()
	if !markExitedAndVerify(handle) {
		t.Fatal("synthetic Job did not become empty")
	}
	waited = true
	close(handle.done)
	handle.groupStopped = true
	close(handle.stopDone)
	stopReleased = true
	hub.finishOwnedHandle(task.ID, handle)
	if hub.handles[task.ID] != handle || owned.closed {
		t.Fatal("empty uncertain handle was dropped before explicit resolution")
	}
	resolved, e := hub.resolve(task.ID, request)
	if e != nil || resolved.State != stateFailed || resolved.CanResume {
		t.Fatal("empty Job did not resolve safely", e)
	}
	if hub.handles[task.ID] != nil || hub.leases[task.Project] != "" || !owned.closed {
		t.Fatal("successful resolution retained ownership")
	}
	replayed, e := hub.resolve(task.ID, request)
	if e != nil || replayed.Version != resolved.Version {
		t.Fatal("resolve idempotency changed", e)
	}
	if _, e = hub.resolve(task.ID, wrong); e != errConflict {
		t.Fatal("request ID reused with different version", e)
	}
	// Replayed historical uncertainty has no native ownership in this session.
	historical := &Task{ID: "historic-task", Version: 1, Agent: "codex", Project: "demo", State: stateUncertain, PID: 123, ReasonCode: "restart_process_unverified"}
	hub.mu.Lock()
	hub.tasks[historical.ID] = historical
	hub.leases[historical.Project] = historical.ID
	hub.mu.Unlock()
	historyRequest := ResolveRequest{RequestID: "historic-resolve-001", ExpectedVersion: 1}
	if _, e = hub.resolve(historical.ID, historyRequest); e != errInvalid {
		t.Fatal("history missing explicit confirmation", e)
	}
	historyRequest.ConfirmedStopped = true
	if _, e = hub.resolve(historical.ID, historyRequest); e != nil {
		t.Fatal("explicit historical reconciliation changed", e)
	}
	t.Run("actual_runTask_parent_exit_keeps_live_child_fence", func(t *testing.T) { testNativeUncertainParentExit(t, false) })
	t.Run("explicit_shutdown_cleans_retained_uncertain_tree", func(t *testing.T) { testNativeUncertainParentExit(t, true) })
}

func testNativeUncertainParentExit(t *testing.T, shutdown bool) {
	root := nativePrivateRoot(t)
	writeDesktopFixture(t, filepath.Join(root, "fixture-parent-exit"), []byte("synthetic only"))
	config := testConfig(t, os.Args[0])
	config.DataDir = filepath.Join(root, "state")
	config.Projects["demo"] = root
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	defer hub.shutdown(context.Background())
	hub.managerSnapshotPath = filepath.Join(root, "absent-snapshot")
	task, err := hub.create(CreateRequest{RequestID: "parent-exit-create-001", Agent: "codex", Project: "demo", Prompt: "synthetic only"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = hub.approve(task.ID, ApproveRequest{RequestID: "parent-exit-approve-001", ActionHash: task.ActionHash}); err != nil {
		t.Fatal(err)
	}
	uncertain := waitForState(t, hub, task.ID, stateUncertain)
	if uncertain.ReasonCode != "process_group_unverified" {
		t.Fatal("unexpected uncertain path", uncertain.ReasonCode)
	}
	child := waitNativeChild(t, root)
	defer windows.CloseHandle(child)
	hub.mu.Lock()
	handle := hub.handles[task.ID]
	seen := hub.ownedTasks[task.ID]
	hub.mu.Unlock()
	if handle == nil || !seen {
		t.Fatal("runTask dropped live child ownership")
	}
	request := ResolveRequest{RequestID: "parent-exit-resolve-001", ExpectedVersion: uncertain.Version, ConfirmedStopped: true}
	if _, err = hub.resolve(task.ID, request); err != errConflict {
		t.Fatal("live descendant resolved after root exited", err)
	}
	if state, e := windows.WaitForSingleObject(child, 0); e != nil || state != uint32(windows.WAIT_TIMEOUT) {
		t.Fatal("resolution killed descendant", state, e)
	}
	if shutdown {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		hub.shutdown(ctx)
		select {
		case <-handle.stopDone:
		default:
			t.Fatal("shutdown returned before owned stop completed")
		}
		if ctx.Err() != nil || !handle.groupStopped {
			t.Fatal("shutdown did not confirm empty Job within deadline", ctx.Err(), handle.groupStopped)
		}
		deadline, _ := ctx.Deadline()
		remainingMillis := time.Until(deadline).Milliseconds()
		if remainingMillis <= 0 {
			t.Fatal("shutdown exhausted descendant wait budget")
		}
		// TerminateJobObject initiates asynchronous termination. Reuse this
		// same five-second deadline to require the held child to be signaled.
		if state, e := windows.WaitForSingleObject(child, uint32(remainingMillis)); e != nil || state != windows.WAIT_OBJECT_0 {
			t.Fatal("explicit shutdown left retained descendant", state, e)
		}
		hub.mu.Lock()
		remaining := len(hub.handles)
		hub.mu.Unlock()
		if remaining != 0 || !handle.owned.closed {
			t.Fatal("shutdown did not release retained Job")
		}
		return
	}
	if err = windows.TerminateJobObject(handle.owned.job, 1); err != nil {
		t.Fatal(err)
	}
	if !waitOwnedGone(handle.owned, 5*time.Second) {
		t.Fatal("fixture descendant not stopped")
	}
	resolved, err := hub.resolve(task.ID, request)
	if err != nil || resolved.State != stateFailed {
		t.Fatal("empty descendant tree did not resolve", err)
	}
}

func TestNativeWindowsDesktopBindingHoldsInputs(t *testing.T) {
	f := newDesktopBindingFixture(t)
	f.approve(t)
	// Rust canonicalize uses this local-drive prefix. It is not a UNC escape.
	_, closeCanonical, err := openDesktopSource(`\\?\`+filepath.Join(f.home, "auth.json"), true)
	if err != nil {
		t.Fatal("Rust canonical local path rejected", err)
	}
	closeCanonical()
	for _, invalid := range []string{`\\server\share\auth.json`, `\\?\UNC\server\share\auth.json`, `\\.\pipe\auth.json`} {
		if _, closeInvalid, e := openDesktopSource(invalid, true); e == nil {
			closeInvalid()
			t.Fatal("nonlocal source admitted")
		}
	}
	release, err := f.hub.lockDesktopSpawn(f.task)
	if err != nil {
		t.Fatal(err)
	}
	paths := []string{filepath.Join(f.home, "auth.json"), f.hub.config.WorkflowPreferencesPath, f.hub.config.WorkflowCatalogPath, f.hub.managerSnapshotPath}
	for _, path := range paths {
		if writer, e := os.OpenFile(path, os.O_WRONLY, 0600); e == nil {
			writer.Close()
			release()
			t.Fatal("admitted input writable while spawn guard held")
		}
		if e := os.Rename(path, path+".changed"); e == nil {
			release()
			t.Fatal("admitted input replaceable while spawn guard held")
		}
	}
	release()
	for _, path := range paths {
		writer, e := os.OpenFile(path, os.O_WRONLY, 0600)
		if e != nil {
			t.Fatal("guard not released", e)
		}
		writer.Close()
	}
}

func TestNativeWindowsDesktopSourceAllowsReadOnlyACL(t *testing.T) {
	root := nativePrivateRoot(t)
	path := filepath.Join(root, "settings.json")
	writeDesktopFixture(t, path, []byte(`{"profiles":{}}`))
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	setACL := func(otherAccess string) {
		t.Helper()
		sd, e := windows.SecurityDescriptorFromString("D:P(A;;FA;;;" + user.User.Sid.String() + ")(A;;" + otherAccess + ";;;WD)")
		if e != nil {
			t.Fatal(e)
		}
		acl, _, e := sd.DACL()
		if e != nil {
			t.Fatal(e)
		}
		name, _ := windows.UTF16PtrFromString(path)
		h, e := windows.CreateFile(name, windows.WRITE_DAC|windows.READ_CONTROL|windows.FILE_READ_ATTRIBUTES, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
		if e != nil {
			t.Fatal("open ACL fixture", e)
		}
		if _, e = windows.GetSecurityInfo(h, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION); e != nil {
			windows.CloseHandle(h)
			t.Fatal("read ACL fixture", e)
		}
		e = windows.SetSecurityInfo(h, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, acl, nil)
		windows.CloseHandle(h)
		if e != nil {
			t.Fatal("set ACL fixture", e)
		}
	}
	setACL("FR")
	_, release, err := openDesktopSource(path, false)
	if err != nil {
		t.Fatal("readonly settings ACL rejected", err)
	}
	release()
	if _, release, err = openDesktopSource(path, true); err == nil {
		release()
		t.Fatal("credential reader accepted public read")
	}
	setACL("FW")
	if _, release, err = openDesktopSource(path, false); err == nil {
		release()
		t.Fatal("mutable settings ACL accepted")
	}
}
func waitNativeChild(t *testing.T, path string) windows.Handle {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		data, err := os.ReadFile(filepath.Join(path, "fixture-child-pid"))
		if err == nil {
			pid, e := strconv.Atoi(string(data))
			if e != nil {
				t.Fatal(e)
			}
			h, e := windows.OpenProcess(windows.SYNCHRONIZE|windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(pid))
			if e != nil {
				t.Fatal(e)
			}
			return h
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("owned child did not publish readiness")
	return 0
}
func TestNativeWindowsOwnedJobTreeCancellation(t *testing.T) {
	root := nativePrivateRoot(t)
	unrelated := exec.Command(os.Args[0], "--hub-native-idle")
	if err := unrelated.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { unrelated.Process.Kill(); unrelated.Wait() }()
	other, err := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(unrelated.Process.Pid))
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(other)
	cmd := exec.Command(os.Args[0], "exec")
	cmd.Dir = root
	owned, err := startOwnedCommand(cmd)
	if err != nil {
		t.Fatal(err)
	}
	defer releaseOwnedProcess(owned)
	handle := &processHandle{owned: owned, pid: cmd.Process.Pid, process: cmd.Process, exitDone: make(chan struct{}), stopDone: make(chan struct{})}
	waited := make(chan struct{})
	go func() { cmd.Wait(); markExitedAndVerify(handle); close(waited) }()
	child := waitNativeChild(t, root)
	defer windows.CloseHandle(child)
	if empty, err := owned.isEmpty(); err != nil || empty {
		t.Fatal("owned live tree missing", err)
	}
	if !stopHandle(handle) {
		t.Fatal("owned job not empty after cancel")
	}
	select {
	case <-waited:
	case <-time.After(time.Second):
		t.Fatal("parent wait did not finish")
	}
	if state, err := windows.WaitForSingleObject(child, 1000); err != nil || state != windows.WAIT_OBJECT_0 {
		t.Fatal("descendant survived", state, err)
	}
	if state, err := windows.WaitForSingleObject(other, 0); err != nil || state != uint32(windows.WAIT_TIMEOUT) {
		t.Fatal("unrelated process touched", state, err)
	}
	if !stopHandle(handle) {
		t.Fatal("second stop not idempotent")
	}
}
func TestNativeWindowsJobCloseKillsDescendants(t *testing.T) {
	root := nativePrivateRoot(t)
	cmd := exec.Command(os.Args[0], "exec")
	cmd.Dir = root
	owned, err := startOwnedCommand(cmd)
	if err != nil {
		t.Fatal(err)
	}
	defer cmd.Wait()
	defer releaseOwnedProcess(owned)
	child := waitNativeChild(t, root)
	defer windows.CloseHandle(child)
	releaseOwnedProcess(owned)
	if state, err := windows.WaitForSingleObject(child, 2000); err != nil || state != windows.WAIT_OBJECT_0 {
		t.Fatal("job close left child", state, err)
	}
}
func TestNativeWindowsHubApprovalAndCancel(t *testing.T) {
	root := nativePrivateRoot(t)
	config := testConfig(t, os.Args[0])
	config.DataDir = filepath.Join(root, "state")
	config.Projects["demo"] = root
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	defer hub.shutdown(context.Background())
	hub.managerSnapshotPath = filepath.Join(root, "absent-snapshot")
	request := CreateRequest{RequestID: "native-create-001", Agent: "codex", Project: "demo", Prompt: "synthetic native fixture"}
	task, err := hub.create(request)
	if err != nil {
		t.Fatal(err)
	}
	duplicate, err := hub.create(request)
	if err != nil || duplicate.ID != task.ID {
		t.Fatal("idempotency changed", err)
	}
	if _, err := os.Stat(filepath.Join(root, "fixture-child-pid")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("create launched before approval")
	}
	if _, err := hub.approve(task.ID, ApproveRequest{RequestID: "native-approve-wrong", ActionHash: strings.Repeat("0", 64)}); err == nil {
		t.Fatal("wrong action hash admitted")
	}
	if _, err := hub.approve(task.ID, ApproveRequest{RequestID: "native-approve-001", ActionHash: task.ActionHash}); err != nil {
		t.Fatal(err)
	}
	running := waitForState(t, hub, task.ID, stateRunning)
	child := waitNativeChild(t, root)
	defer windows.CloseHandle(child)
	if _, err := hub.cancel(task.ID, CancelRequest{RequestID: "native-cancel-001", ExpectedVersion: running.Version}); err != nil {
		t.Fatal(err)
	}
	waitForState(t, hub, task.ID, stateCancelled)
	if state, err := windows.WaitForSingleObject(child, 1000); err != nil || state != windows.WAIT_OBJECT_0 {
		t.Fatal("cancelled task left child", state, err)
	}
	// Windows byte-range locks also apply to another handle in this process.
	// Inspect through the owning handle without releasing the journal lock.
	hub.mu.Lock()
	info, err := hub.store.file.Stat()
	var journal []byte
	if err == nil {
		journal, err = io.ReadAll(io.NewSectionReader(hub.store.file, 0, info.Size()))
	}
	hub.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	if second, e := openStore(config.DataDir); e == nil {
		second.Close()
		t.Fatal("journal inspection released exclusive ownership")
	}
	if strings.Contains(string(journal), request.Prompt) {
		t.Fatal("prompt persisted")
	}
}
func TestNativeWindowsPrivateStoreAndLocks(t *testing.T) {
	root := nativePrivateRoot(t)
	store, err := openStore(root)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if another, err := openStore(root); err == nil {
		another.Close()
		t.Fatal("journal lock admitted second owner")
	}
	dir := filepath.Join(root, "activity")
	hub := &Hub{activityDirectory: dir}
	release, err := hub.lockDispatchActivity()
	if err != nil {
		t.Fatal(err)
	}
	if second, err := hub.lockDispatchActivity(); err == nil {
		second()
		t.Fatal("activity lock admitted second owner")
	}
	release()
	release, err = hub.lockDispatchActivity()
	if err != nil {
		t.Fatal(err)
	}
	release()
	path := filepath.Join(dir, "dispatch-activity-v1.json")
	f, err := openPrivateFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	f.WriteString(`{"schemaVersion":1,"leases":[]}`)
	f.Close()
	if leases, err := hub.readDispatchActivity(); err != nil || len(leases) != 0 {
		t.Fatal("private activity unreadable", err)
	}
	temporary, err := createPrivateTemp(root)
	if err != nil {
		t.Fatal("private temporary creation", err)
	}
	temporaryPath := temporary.Name()
	if err = privateFilePermissions(temporary); err != nil {
		temporary.Close()
		os.Remove(temporaryPath)
		t.Fatal("private temporary owner/ACL", err)
	}
	temporary.Close()
	if err = os.Remove(temporaryPath); err != nil {
		t.Fatal(err)
	}
	if err := saveThreadRefs(root, map[string]threadRefRecord{}); err != nil {
		t.Fatal(err)
	}
	if err := saveThreadRefs(root, map[string]threadRefRecord{}); err != nil {
		t.Fatal("private replacement", err)
	}
	if _, exists, err := loadThreadRefs(root); err != nil || !exists {
		t.Fatal("thread ref roundtrip", err)
	}
}
func TestNativeWindowsRejectsBroadACLAndHardlink(t *testing.T) {
	root := nativePrivateRoot(t)
	path := filepath.Join(root, "private")
	f, err := openPrivateFile(path, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	f.Close()
	other := filepath.Join(root, "link")
	if err := os.Link(path, other); err != nil {
		t.Fatal(err)
	}
	if f, err := openPrivateFile(path, os.O_RDONLY, 0); err == nil {
		f.Close()
		t.Fatal("hardlinked state admitted")
	}
	if err := os.Remove(other); err != nil {
		t.Fatal(err)
	}
	sd, err := windows.SecurityDescriptorFromString("D:P(A;;FA;;;WD)")
	if err != nil {
		t.Fatal(err)
	}
	acl, _, err := sd.DACL()
	if err != nil {
		t.Fatal(err)
	}
	name, _ := windows.UTF16PtrFromString(path)
	h, err := windows.CreateFile(name, windows.WRITE_DAC|windows.READ_CONTROL|windows.FILE_READ_ATTRIBUTES, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		t.Fatal("open broad ACL fixture", err)
	}
	if _, err = windows.GetSecurityInfo(h, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION); err != nil {
		windows.CloseHandle(h)
		t.Fatal("read broad ACL fixture", err)
	}
	err = windows.SetSecurityInfo(h, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, acl, nil)
	windows.CloseHandle(h)
	if err != nil {
		t.Fatal("set broad ACL fixture", err)
	}
	if f, err := openPrivateFile(path, os.O_RDONLY, 0); err == nil {
		f.Close()
		t.Fatal("world ACL admitted")
	}
}
func TestNativeWindowsReadyAndEnvironment(t *testing.T) {
	root := nativePrivateRoot(t)
	path := filepath.Join(root, "ready.json")
	if err := writeReadyFile(path, "127.0.0.1:23456"); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var receipt struct {
		SchemaVersion int    `json:"schemaVersion"`
		PID           int    `json:"pid"`
		Listen        string `json:"listen"`
	}
	if json.Unmarshal(raw, &receipt) != nil || receipt.SchemaVersion != 1 || receipt.PID != os.Getpid() || receipt.Listen != "127.0.0.1:23456" {
		t.Fatal("invalid ready receipt")
	}
	if writeReadyFile(path, "127.0.0.1:23457") == nil {
		t.Fatal("ready overwrite admitted")
	}
	if writeReadyFile(filepath.Join(root, "unsafe"), "0.0.0.0:23456") == nil {
		t.Fatal("nonlocal ready admitted")
	}
	t.Setenv("CODEX_HOME", "old")
	t.Setenv("OPENAI_API_KEY", "synthetic-secret")
	env := safeEnvironment("codex", root)
	joined := strings.Join(env, "\n")
	if strings.Contains(joined, "synthetic-secret") || !strings.Contains(joined, "CODEX_HOME="+root) {
		t.Fatal("environment isolation")
	}
	if unsafe.Sizeof(jobAccounting{}) != 48 {
		t.Fatal("job accounting ABI")
	}
}

func TestNativeWindowsRejectsReparseAncestors(t *testing.T) {
	root := nativePrivateRoot(t)
	target := filepath.Join(root, "target")
	if err := ensurePrivateDir(target); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(target, "value")
	file, err := openPrivateFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	file.Close()
	link := filepath.Join(root, "junction")
	if err := os.Mkdir(link, 0700); err != nil {
		t.Fatal(err)
	}
	// A real mount-point reparse object needs no symlink privilege on the runner.
	substitute := windows.StringToUTF16("\\??\\" + target)
	printName := windows.StringToUTF16(target)
	dataLength := 8 + 2*(len(substitute)+len(printName))
	raw := make([]byte, 8+dataLength)
	put16 := func(offset int, value uint16) { raw[offset] = byte(value); raw[offset+1] = byte(value >> 8) }
	raw[0] = 3
	raw[3] = 0xa0
	put16(4, uint16(dataLength))
	put16(8, 0)
	put16(10, uint16((len(substitute)-1)*2))
	put16(12, uint16(len(substitute)*2))
	put16(14, uint16((len(printName)-1)*2))
	for i, value := range append(substitute, printName...) {
		put16(16+i*2, value)
	}
	name, _ := windows.UTF16PtrFromString(link)
	h, err := windows.CreateFile(name, windows.GENERIC_WRITE, 0, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OPEN_REPARSE_POINT|windows.FILE_FLAG_BACKUP_SEMANTICS, 0)
	if err != nil {
		t.Fatal(err)
	}
	var returned uint32
	err = windows.DeviceIoControl(h, windows.FSCTL_SET_REPARSE_POINT, &raw[0], uint32(len(raw)), nil, 0, &returned, nil)
	windows.CloseHandle(h)
	if err != nil {
		t.Fatal(err)
	}
	if ensurePrivateDir(link) == nil {
		t.Fatal("junction directory admitted")
	}
	if file, err := openPrivateFile(filepath.Join(link, "value"), os.O_RDONLY, 0); err == nil {
		file.Close()
		t.Fatal("junction ancestor admitted")
	}
}
