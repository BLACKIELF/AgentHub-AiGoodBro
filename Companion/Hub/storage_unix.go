//go:build !windows

package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

func ensurePrivateDir(path string) error {
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		if err := os.MkdirAll(path, 0o700); err != nil {
			return fmt.Errorf("data_dir_create")
		}
		return nil
	}
	if err != nil || !info.IsDir() || info.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("data_dir_permissions")
	}
	return nil
}

func openPrivateFile(path string, flag int, mode os.FileMode) (*os.File, error) {
	return os.OpenFile(path, flag, mode)
}
func createPrivateTemp(directory string) (*os.File, error) {
	return os.CreateTemp(directory, "thread-refs-*.tmp")
}
func privateFilePermissions(file *os.File) error {
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return fmt.Errorf("file_permissions")
	}
	return nil
}
func privateDirectoryPermissions(path string) error {
	info, err := os.Lstat(path)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0077 != 0 {
		return fmt.Errorf("directory_permissions")
	}
	return nil
}
func replacePrivateFile(from, to string) error { return os.Rename(from, to) }
func syncPrivateDirectory(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}
func (hub *Hub) lockDispatchActivity() (func(), error) {
	if hub.activityDirectory == "" {
		return func() {}, nil
	}
	if err := os.MkdirAll(hub.activityDirectory, 0700); err != nil {
		return nil, errDispatchPolicyUnavailable
	}
	info, err := os.Lstat(hub.activityDirectory)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0077 != 0 {
		return nil, errDispatchPolicyUnavailable
	}
	if st, ok := info.Sys().(*syscall.Stat_t); !ok || st.Uid != uint32(os.Geteuid()) {
		return nil, errDispatchPolicyUnavailable
	}
	fd, err := syscall.Open(filepath.Join(hub.activityDirectory, ".dispatch-activity.lock"), syscall.O_RDWR|syscall.O_CREAT|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0600)
	if err != nil {
		return nil, errDispatchPolicyUnavailable
	}
	var st syscall.Stat_t
	if syscall.Fstat(fd, &st) != nil || st.Mode&syscall.S_IFMT != syscall.S_IFREG || st.Uid != uint32(os.Geteuid()) || st.Nlink != 1 || st.Mode&0077 != 0 {
		syscall.Close(fd)
		return nil, errDispatchPolicyUnavailable
	}
	if syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		syscall.Close(fd)
		return nil, errBusy
	}
	return func() { syscall.Flock(fd, syscall.LOCK_UN); syscall.Close(fd) }, nil
}

func openDispatchActivity(path string) (*os.File, error) {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err == syscall.ENOENT {
		return nil, os.ErrNotExist
	}
	if err != nil {
		return nil, errDispatchPolicyUnavailable
	}
	f := os.NewFile(uintptr(fd), "dispatch-activity")
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > 2*1024*1024 {
		f.Close()
		return nil, errDispatchPolicyUnavailable
	}
	if st, ok := info.Sys().(*syscall.Stat_t); !ok || st.Uid != uint32(os.Geteuid()) || st.Nlink != 1 || info.Mode().Perm()&0077 != 0 {
		f.Close()
		return nil, errDispatchPolicyUnavailable
	}
	return f, nil
}
