//go:build !windows

package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

type desktopConnectionContext struct{}

func desktopEvidenceRun(c desktopEvidenceConfig) (string, error)              { return c.RunID, nil }
func desktopCurrentConnection(c desktopConnection) (desktopConnection, error) { return c, nil }
func desktopRequestConnection(ctx context.Context, c desktopConnection) desktopConnection {
	if current, ok := ctx.Value(desktopConnectionContext{}).(desktopConnection); ok {
		return current
	}
	return c
}

func desktopOpenFile(path string) (*os.File, error) {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), path), nil
}
func platformDesktopOwned(_ *os.File, info os.FileInfo) bool { return desktopOwned(info) }
func platformCooldownRoot(dir string) (*os.Root, error) {
	if !filepath.IsAbs(dir) || filepath.Clean(dir) != dir {
		return nil, errors.New("invalid_state_directory")
	}
	part := string(filepath.Separator)
	for _, name := range strings.Split(strings.TrimPrefix(dir, part), part) {
		part = filepath.Join(part, name)
		info, err := os.Lstat(part)
		if os.IsNotExist(err) {
			if err = os.Mkdir(part, 0700); err != nil {
				return nil, err
			}
			info, err = os.Lstat(part)
		}
		if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return nil, errors.New("invalid_state_directory")
		}
	}
	return os.OpenRoot(dir)
}
func platformCooldownOpen(root *os.Root, name string, flag int, perm os.FileMode) (*os.File, error) {
	return root.OpenFile(name, flag|syscall.O_NOFOLLOW, perm)
}
