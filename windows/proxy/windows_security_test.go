//go:build windows

package main

import (
	"context"
	auth "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

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
func TestWindowsPrivateStateRejectsFileAndReparsePath(t *testing.T) {
	parent := t.TempDir()
	file := filepath.Join(parent, "file")
	if err := os.WriteFile(file, []byte("synthetic"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := newCooldownStore(file); err == nil {
		t.Fatal("accepted a regular file as state directory")
	}
	real := filepath.Join(parent, "real")
	if err := os.Mkdir(real, 0700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(parent, "link")
	if err := os.Symlink(real, link); err != nil {
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
	if err = cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill(); _ = cmd.Wait() })
	closeJob, err := ownWindowsBackend(cmd.Process)
	if err != nil {
		t.Fatal(err)
	}
	closeJob()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("job close did not terminate the owned fixture")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("job close did not confirm fixture exit")
	}
}
func TestWindowsBackendJobFixture(t *testing.T) {
	if os.Getenv("AIGOODBRO_JOB_FIXTURE") != "1" {
		return
	}
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
