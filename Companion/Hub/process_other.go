//go:build !darwin && !linux && !windows

package main

import (
	"errors"
	"os"
	"os/exec"
)

func configureProcessGroup(cmd *exec.Cmd) {}

func processGroupAlive(pid int) (bool, error) {
	return true, errors.New("process groups are supported only on macOS and Linux")
}

func lockFile(file *os.File) error {
	return errors.New("single-instance locking is supported only on macOS and Linux")
}

func unlockFile(file *os.File) error { return nil }
