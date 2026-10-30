//go:build !windows

package main

import (
	"os/exec"
	"runtime"
)

func openCodexDesktopThread(threadID string) error {
	if runtime.GOOS != "darwin" || !canonicalThreadIDPattern.MatchString(threadID) {
		return errInvalid
	}
	return exec.Command("/usr/bin/open", "-b", "com.openai.codex", "codex://threads/"+threadID).Run()
}
