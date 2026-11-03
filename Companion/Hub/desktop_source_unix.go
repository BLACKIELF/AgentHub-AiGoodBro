//go:build !windows

package main

import (
	"os"
	"syscall"
)

// The desktop adapter is only configured by Windows. This equivalent reader
// lets its pure binding fixtures run on Unix without changing Mac admission.
func openDesktopSource(path string, private bool) (*os.File, func(), error) {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, nil, errDispatchPolicyUnavailable
	}
	file := os.NewFile(uintptr(fd), path)
	release := func() { file.Close() }
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > 2*1024*1024 {
		release()
		return nil, nil, errDispatchPolicyUnavailable
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	mask := os.FileMode(0022)
	if private {
		mask = 0077
	}
	if !ok || st.Uid != uint32(os.Geteuid()) || st.Nlink != 1 || info.Mode().Perm()&mask != 0 {
		release()
		return nil, nil, errDispatchPolicyUnavailable
	}
	return file, release, nil
}
