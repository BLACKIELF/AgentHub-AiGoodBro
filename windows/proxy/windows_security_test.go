//go:build windows

package main

import (
	"bufio"
	"context"
	auth "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
	"golang.org/x/sys/windows"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
	"unsafe"
)

// These are isolated fixture inputs. Creation uses the product's explicit user
// owner contract even when the native runner token's default owner is a group.
func writeWindowsPrivateFixture(t *testing.T, path string, data []byte) {
	t.Helper()
	if _, err := os.Stat(path); err == nil {
		file, err := desktopOpenFile(path)
		if err != nil {
			t.Fatal(err)
		}
		file.Close()
		if err = os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
		return
	}
	root, err := os.OpenRoot(filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	file, err := createPrivateFileAt(root, filepath.Base(path))
	if err != nil {
		t.Fatal(err)
	}
	if _, err = file.Write(data); err != nil {
		file.Close()
		t.Fatal(err)
	}
	if err = file.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestWindowsPrivateCreationHasExactUserOwnerWithoutAdoptingExistingFiles(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "private-state")
	if err := privateDirectory(dir, true); err != nil {
		t.Fatal(err)
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	file, err := createPrivateFileAt(root, "owned.txt")
	if err != nil {
		t.Fatal(err)
	}
	file.Close()
	user, err := currentSID()
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{dir, filepath.Join(dir, "owned.txt")} {
		sd, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
		if err != nil {
			t.Fatal(err)
		}
		owner, _, err := sd.Owner()
		if err != nil || !owner.Equals(user) || !privateDescriptor(sd) {
			t.Fatal("new object did not have the exact user owner and private ACL")
		}
		control, _, err := sd.Control()
		if err != nil || control&windows.SE_DACL_PROTECTED == 0 {
			t.Fatal("new object did not retain its protected DACL")
		}
	}
	for _, name := range []string{"owned.txt", "../other.txt", "owned.txt:stream", `sub\other.txt`} {
		if file, err := createPrivateFileAt(root, name); err == nil {
			file.Close()
			t.Fatal("exclusive creation adopted an existing object or escaped its root")
		}
	}
}

func TestWindowsPrivateStateRejectsExistingForeignOwnerWithoutChangingACL(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "foreign-owned")
	user, err := currentSID()
	if err != nil {
		t.Fatal(err)
	}
	sd, err := windows.SecurityDescriptorFromString("O:BAD:P(A;OICI;FA;;;" + user.String() + ")")
	if err != nil {
		t.Fatal(err)
	}
	path, err := windows.UTF16PtrFromString(dir)
	if err != nil {
		t.Fatal(err)
	}
	sa := windows.SecurityAttributes{Length: uint32(unsafe.Sizeof(windows.SecurityAttributes{})), SecurityDescriptor: sd}
	if err = windows.CreateDirectory(path, &sa); err != nil {
		if os.Getenv("GITHUB_ACTIONS") == "true" {
			t.Fatal("CI requires the administrator foreign-owner fixture to execute")
		}
		t.Skip("creating the foreign group-owner fixture requires an administrator token")
	}
	before, err := windows.GetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		t.Fatal(err)
	}
	if err = privateDirectory(dir, true); err == nil {
		t.Fatal("adopted a preexisting foreign-owner directory")
	}
	after, err := windows.GetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil || before.String() != after.String() {
		t.Fatal("rejection changed the preexisting owner or ACL")
	}
}

func TestWindowsPrivateCooldownHasProtectedOwnerACLAndRoundtrips(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "private-state")
	s, err := newCooldownStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer s.root.Close()
	if err = privateDirectory(dir, false); err != nil {
		t.Fatal("state directory ACL was not protected")
	}
	record := auth.CooldownStateRecord{Provider: "codex", AuthID: "synthetic-A", Model: "synthetic-model", NextRetryAfter: time.Now().Add(time.Minute), Reason: "quota", UpdatedAt: time.Now(), LastError: &auth.Error{HTTPStatus: 429}}
	if err = s.Save(context.Background(), []auth.CooldownStateRecord{record}); err != nil {
		t.Fatal(err)
	}
	rows, err := s.Load(context.Background())
	if err != nil || len(rows) != 1 || rows[0].AuthID != "synthetic-A" {
		t.Fatal("private Windows cooldown did not roundtrip")
	}
	f, err := desktopOpenFile(filepath.Join(dir, "cooldown.json"))
	if err != nil {
		t.Fatal("saved cooldown did not retain a private ACL")
	}
	f.Close()
}

func TestWindowsPrivateWriteHandleSupportsRequiredIdentityChecks(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "private-state")
	if err := privateDirectory(dir, true); err != nil {
		t.Fatal(err)
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	file, err := createPrivateFileAt(root, "owned-write-only.json")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	actual, err := file.Stat()
	if err != nil {
		t.Fatalf("new write handle cannot supply required metadata: %v", err)
	}
	entry, err := root.Lstat("owned-write-only.json")
	if err != nil {
		t.Fatalf("new write handle prevents anchored metadata check: %v", err)
	}
	if !actual.Mode().IsRegular() || !os.SameFile(actual, entry) || !platformDesktopOwned(file, actual) {
		t.Fatal("new write handle failed exact regular-file/identity/owner checks before any payload write")
	}
	if _, err := file.Write([]byte("synthetic-not-a-credential")); err != nil {
		t.Fatal(err)
	}
	if err := file.Sync(); err != nil {
		t.Fatal(err)
	}
}
func TestWindowsPrivateStateRejectsFileAndReparsePath(t *testing.T) {
	parent := t.TempDir()
	file := filepath.Join(parent, "file")
	if err := os.WriteFile(file, []byte("synthetic"), 0600); err != nil {
		t.Fatal(err)
	}
	before, err := windows.GetNamedSecurityInfo(file, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := newCooldownStore(file); err == nil {
		t.Fatal("accepted a regular file as state directory")
	}
	after, err := windows.GetNamedSecurityInfo(file, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil || before.String() != after.String() {
		t.Fatal("regular-file rejection changed its owner or ACL")
	}
	real := filepath.Join(parent, "real")
	if err := os.Mkdir(real, 0700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(parent, "link")
	if err := os.Symlink(real, link); err != nil {
		if os.Getenv("GITHUB_ACTIONS") == "true" {
			t.Fatal("CI requires the reparse rejection fixture to execute")
		}
		t.Skip("Windows symlink privilege unavailable; regular-file rejection was exercised")
	}
	if _, err := newCooldownStore(link); err == nil {
		t.Fatal("accepted a reparse state root")
	}
}

func TestWindowsBackendJobUsesHeldProcessHandle(t *testing.T) {
	cmd := exec.Command(os.Args[0], "-test.run=^TestWindowsBackendJobFixture$")
	cmd.Env = append(os.Environ(), "AIGOODBRO_JOB_FIXTURE=1")
	input, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	defer input.Close()
	output, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err = cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill(); _ = cmd.Wait() })
	job, err := attachWindowsBackend(cmd.Process)
	if err != nil {
		t.Fatal(err)
	}
	defer job.close()
	ready := make(chan string, 1)
	go func() { line, _ := bufio.NewReader(output).ReadString('\n'); ready <- line }()
	select {
	case line := <-ready:
		if line != "held-job-ready\n" {
			t.Fatal("fixture did not enter its held-input wait")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("fixture ready timeout")
	}
	var pinned windows.Handle
	var pinError error
	err = cmd.Process.WithHandle(func(handle uintptr) {
		pinError = windows.DuplicateHandle(windows.CurrentProcess(), windows.Handle(handle), windows.CurrentProcess(), &pinned, windows.SYNCHRONIZE|windows.PROCESS_QUERY_LIMITED_INFORMATION, false, 0)
	})
	if err != nil || pinError != nil {
		t.Fatal("could not pin the actual owned process handle")
	}
	defer windows.CloseHandle(pinned)
	if state, err := windows.WaitForSingleObject(pinned, 0); err != nil || state != uint32(windows.WAIT_TIMEOUT) {
		t.Fatal("fixture was not alive before closing its job")
	}
	// Four LARGE_INTEGERs and four DWORDs; ActiveProcesses is at byte 40.
	accounting := struct {
		User, Kernel, PeriodUser, PeriodKernel int64
		Faults, Total, Active, Terminated      uint32
	}{}
	if unsafe.Sizeof(accounting) != 48 || unsafe.Offsetof(accounting.Active) != 40 {
		t.Fatal("invalid job accounting ABI")
	}
	if err := windows.QueryInformationJobObject(job.handle, windows.JobObjectBasicAccountingInformation, uintptr(unsafe.Pointer(&accounting)), uint32(unsafe.Sizeof(accounting)), nil); err != nil || accounting.Active != 1 {
		t.Fatal("fixture was not in the exact owned job")
	}
	job.close()
	if state, err := windows.WaitForSingleObject(pinned, 5000); err != nil || state != uint32(windows.WAIT_OBJECT_0) {
		t.Fatal("job close did not positively signal the held owned process exit")
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case <-done:
		// Kill-on-close guarantees termination, not a nonzero exit status.
	case <-time.After(5 * time.Second):
		t.Fatal("job close did not confirm fixture exit")
	}
}
func TestWindowsBackendJobFixture(t *testing.T) {
	if os.Getenv("AIGOODBRO_JOB_FIXTURE") != "1" {
		return
	}
	_, _ = io.WriteString(os.Stdout, "held-job-ready\n")
	_, _ = io.Copy(io.Discard, os.Stdin)
	os.Exit(0)
}

func TestWindowsVerbatimDrivePathsPreserveLocalOnlyBoundary(t *testing.T) {
	dir := t.TempDir()
	if err := windowsPath(`\\?\`+dir, false); err != nil {
		t.Fatal("valid native canonical drive path rejected")
	}
	for _, path := range []string{`\\server\share\state`, `\\?\UNC\server\share\state`} {
		if err := windowsPath(path, false); err == nil {
			t.Fatal("remote state path accepted")
		}
	}
}
