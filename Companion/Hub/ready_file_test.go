package main

import (
	"path/filepath"
	"testing"
)

func TestOwnedReadyEndpointRequiresAuthenticatedReceipt(t *testing.T) {
	yes, no := true, false
	for _, config := range []Config{{Listen: "127.0.0.1:0"}, {Listen: "127.0.0.1:0", ReadyFile: "ready", RequireToken: &no}, {Listen: "0.0.0.0:0", ReadyFile: "ready", RequireToken: &yes}} {
		if validateConfiguredListen(config) == nil {
			t.Fatal("unowned dynamic listen admitted")
		}
	}
	if validateConfiguredListen(Config{Listen: "127.0.0.1:0", ReadyFile: "ready", RequireToken: &yes}) != nil {
		t.Fatal("authenticated owned listen rejected")
	}
	root := filepath.Join(t.TempDir(), "private")
	if err := ensurePrivateDir(root); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "ready.json")
	if writeReadyFile(path, "127.0.0.1:0") == nil {
		t.Fatal("unbound port written")
	}
	if err := writeReadyFile(path, "127.0.0.1:12345"); err != nil {
		t.Fatal("ready write failed", err)
	}
	if writeReadyFile(path, "127.0.0.1:12346") == nil {
		t.Fatal("existing run receipt overwritten")
	}
}
