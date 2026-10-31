//go:build windows

package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

// A protected DACL for newly created Hub state. Never change the ACL of an
// existing object to make an untrusted path pass validation.
func hubSecurity() (*windows.SecurityAttributes, error) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return nil, err
	}
	sd, err := windows.SecurityDescriptorFromString("O:" + user.User.Sid.String() + "D:P(A;OICI;FA;;;" + user.User.Sid.String() + ")(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)")
	if err != nil {
		return nil, err
	}
	return &windows.SecurityAttributes{Length: uint32(unsafe.Sizeof(windows.SecurityAttributes{})), SecurityDescriptor: sd}, nil
}

func privateHandle(handle windows.Handle, directory bool) error {
	var info windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(handle, &info); err != nil {
		return err
	}
	if info.FileAttributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 || (info.FileAttributes&windows.FILE_ATTRIBUTE_DIRECTORY != 0) != directory || (!directory && info.NumberOfLinks != 1) {
		return fmt.Errorf("file_shape")
	}
	sd, err := windows.GetSecurityInfo(handle, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return err
	}
	owner, _, err := sd.Owner()
	if err != nil {
		return err
	}
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil || owner == nil || !owner.Equals(user.User.Sid) {
		return fmt.Errorf("file_owner")
	}
	acl, _, err := sd.DACL()
	if err != nil || acl == nil || acl.AceCount == 0 {
		return fmt.Errorf("file_acl")
	}
	system, _ := windows.StringToSid("S-1-5-18")
	admins, _ := windows.StringToSid("S-1-5-32-544")
	userAllowed := false
	for i := uint32(0); i < uint32(acl.AceCount); i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(acl, i, &ace); err != nil {
			return err
		}
		if ace.Header.AceFlags&windows.INHERIT_ONLY_ACE != 0 {
			continue
		}
		if ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE {
			return fmt.Errorf("file_acl_type")
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart))
		if !sid.IsValid() || (!sid.Equals(user.User.Sid) && !sid.Equals(system) && !sid.Equals(admins)) {
			return fmt.Errorf("file_acl_scope")
		}
		if sid.Equals(user.User.Sid) {
			userAllowed = true
		}
	}
	if !userAllowed {
		return fmt.Errorf("file_acl_user")
	}
	return nil
}

// Hold every directory component without FILE_SHARE_DELETE while resolving a
// child. This rejects junctions/symlinks and prevents rename/reparse substitution
// between ancestor validation and the final CreateFile.
func holdDirectories(path string, create bool) ([]windows.Handle, error) {
	if !canonicalLocalPrefix(path) {
		return nil, fmt.Errorf("local_path_required")
	}
	path, err := filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	volume := filepath.VolumeName(path)
	drive := volume
	if strings.HasPrefix(drive, `\\?\`) {
		drive = strings.TrimPrefix(drive, `\\?\`)
	}
	if len(drive) != 2 || drive[1] != ':' || !((drive[0] >= 'A' && drive[0] <= 'Z') || (drive[0] >= 'a' && drive[0] <= 'z')) {
		return nil, fmt.Errorf("local_path_required")
	}
	handles := []windows.Handle{}
	fail := func(err error) ([]windows.Handle, error) { closeDirectories(handles); return nil, err }
	current := volume + string(os.PathSeparator)
	parts := strings.Split(strings.TrimPrefix(path, current), string(os.PathSeparator))
	for _, part := range append([]string{""}, parts...) {
		if part != "" {
			current = filepath.Join(current, part)
		}
		name, err := windows.UTF16PtrFromString(current)
		if err != nil {
			return fail(err)
		}
		handle, err := windows.CreateFile(name, windows.FILE_READ_ATTRIBUTES|windows.READ_CONTROL, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_BACKUP_SEMANTICS|windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
		if errors.Is(err, windows.ERROR_FILE_NOT_FOUND) || errors.Is(err, windows.ERROR_PATH_NOT_FOUND) {
			if !create {
				return fail(err)
			}
			sa, e := hubSecurity()
			if e != nil {
				return fail(e)
			}
			if e = windows.CreateDirectory(name, sa); e != nil && !errors.Is(e, windows.ERROR_ALREADY_EXISTS) {
				return fail(e)
			}
			handle, err = windows.CreateFile(name, windows.FILE_READ_ATTRIBUTES|windows.READ_CONTROL, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_BACKUP_SEMANTICS|windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
		}
		if err != nil {
			return fail(err)
		}
		handles = append(handles, handle)
		var info windows.ByHandleFileInformation
		if windows.GetFileInformationByHandle(handle, &info) != nil || info.FileAttributes&windows.FILE_ATTRIBUTE_DIRECTORY == 0 || info.FileAttributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
			return fail(fmt.Errorf("directory_reparse"))
		}
	}
	return handles, nil
}

func canonicalLocalPrefix(path string) bool {
	if !strings.HasPrefix(path, `\\?\`) {
		return true
	}
	if len(path) < 7 || path[5] != ':' || path[6] != '\\' || !((path[4] >= 'A' && path[4] <= 'Z') || (path[4] >= 'a' && path[4] <= 'z')) {
		return false
	}
	for _, part := range strings.Split(path[7:], `\`) {
		if part == "." || part == ".." {
			return false
		}
	}
	return true
}
func closeDirectories(handles []windows.Handle) {
	for i := len(handles) - 1; i >= 0; i-- {
		windows.CloseHandle(handles[i])
	}
}
func ensurePrivateDir(path string) error {
	handles, err := holdDirectories(path, true)
	if err != nil {
		return err
	}
	defer closeDirectories(handles)
	return privateHandle(handles[len(handles)-1], true)
}
func privateDirectoryPermissions(path string) error {
	handles, err := holdDirectories(path, false)
	if err != nil {
		return err
	}
	defer closeDirectories(handles)
	return privateHandle(handles[len(handles)-1], true)
}
func privateFilePermissions(file *os.File) error {
	return privateHandle(windows.Handle(file.Fd()), false)
}
func openPrivateFile(path string, flag int, mode os.FileMode) (*os.File, error) {
	parents, err := holdDirectories(filepath.Dir(path), false)
	if err != nil {
		return nil, err
	}
	defer closeDirectories(parents)
	if err := privateHandle(parents[len(parents)-1], true); err != nil {
		return nil, err
	}
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	access := uint32(windows.GENERIC_READ | windows.READ_CONTROL)
	if flag&os.O_WRONLY != 0 {
		access = windows.GENERIC_WRITE | windows.READ_CONTROL
	}
	if flag&os.O_RDWR != 0 {
		access |= windows.GENERIC_WRITE
	}
	access |= windows.FILE_READ_ATTRIBUTES
	disposition := uint32(windows.OPEN_EXISTING)
	if flag&os.O_CREATE != 0 {
		disposition = windows.OPEN_ALWAYS
	}
	if flag&os.O_EXCL != 0 {
		disposition = windows.CREATE_NEW
	}
	// O_TRUNC is deliberately unsupported: callers replace atomically or append.
	if flag&os.O_TRUNC != 0 {
		return nil, fmt.Errorf("truncate_not_allowed")
	}
	sa, err := hubSecurity()
	if err != nil {
		return nil, err
	}
	handle, err := windows.CreateFile(name, access, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, sa, disposition, windows.FILE_ATTRIBUTE_NORMAL|windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		return nil, err
	}
	if err := privateHandle(handle, false); err != nil {
		windows.CloseHandle(handle)
		return nil, err
	}
	file := os.NewFile(uintptr(handle), path)
	if flag&os.O_APPEND != 0 {
		if _, err := file.Seek(0, 2); err != nil {
			file.Close()
			return nil, err
		}
	}
	return file, nil
}
func lockFile(file *os.File) error {
	return windows.LockFileEx(windows.Handle(file.Fd()), windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &windows.Overlapped{})
}

// An inherited DACL does not inherit the owner SID. In an elevated process,
// os.CreateTemp can select Administrators as owner; create our temporary file
// with the same explicit TokenUser owner and DACL as every other private file.
func createPrivateTemp(directory string) (*os.File, error) {
	id, err := newID()
	if err != nil {
		return nil, err
	}
	return openPrivateFile(filepath.Join(directory, "thread-refs-"+id+".tmp"), os.O_CREATE|os.O_EXCL|os.O_RDWR, 0600)
}
func unlockFile(file *os.File) error {
	return windows.UnlockFileEx(windows.Handle(file.Fd()), 0, 1, 0, &windows.Overlapped{})
}
func (hub *Hub) lockDispatchActivity() (func(), error) {
	if hub.activityDirectory == "" {
		return func() {}, nil
	}
	if ensurePrivateDir(hub.activityDirectory) != nil {
		return nil, errDispatchPolicyUnavailable
	}
	file, err := openPrivateFile(filepath.Join(hub.activityDirectory, ".dispatch-activity.lock"), os.O_RDWR|os.O_CREATE, 0600)
	if err != nil {
		return nil, errDispatchPolicyUnavailable
	}
	if lockFile(file) != nil {
		file.Close()
		return nil, errBusy
	}
	return func() { unlockFile(file); file.Close() }, nil
}
func openDispatchActivity(path string) (*os.File, error) {
	file, err := openPrivateFile(path, os.O_RDONLY, 0)
	if err != nil {
		return nil, err
	}
	info, err := file.Stat()
	if err != nil || info.Size() > 2*1024*1024 {
		file.Close()
		return nil, errDispatchPolicyUnavailable
	}
	return file, nil
}
func replacePrivateFile(from, to string) error {
	parents, err := holdDirectories(filepath.Dir(to), false)
	if err != nil {
		return err
	}
	defer closeDirectories(parents)
	if filepath.Dir(from) != filepath.Dir(to) || privateHandle(parents[len(parents)-1], true) != nil {
		return fmt.Errorf("replace_path")
	}
	source, err := openPrivateFile(from, os.O_RDONLY, 0)
	if err != nil {
		return err
	}
	source.Close()
	a, err := windows.UTF16PtrFromString(from)
	if err != nil {
		return err
	}
	b, err := windows.UTF16PtrFromString(to)
	if err != nil {
		return err
	}
	return windows.MoveFileEx(a, b, windows.MOVEFILE_REPLACE_EXISTING|windows.MOVEFILE_WRITE_THROUGH)
}

// MoveFileEx WRITE_THROUGH above is the Windows durable replacement boundary.
func syncPrivateDirectory(string) error { return nil }
