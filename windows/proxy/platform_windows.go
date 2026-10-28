//go:build windows

package main

import (
	"errors"
	"golang.org/x/sys/windows"
	"os"
	"path/filepath"
	"strings"
	"unsafe"
)

func currentSID() (*windows.SID, error) {
	u, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return nil, err
	}
	return u.User.Sid, nil
}
func noReparse(path string) error {
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	attrs, err := windows.GetFileAttributes(p)
	if err != nil {
		return err
	}
	if attrs&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		return errors.New("reparse_point_rejected")
	}
	return nil
}
func windowsPath(path string, create bool) error {
	if strings.HasPrefix(path, `\\?\`) && len(path) > 6 && path[5] == ':' {
		path = strings.TrimPrefix(path, `\\?\`)
	}
	if !filepath.IsAbs(path) || filepath.Clean(path) != path || strings.HasPrefix(path, `\\`) {
		return errors.New("invalid_local_path")
	}
	volume := filepath.VolumeName(path)
	if len(volume) != 2 || volume[1] != ':' {
		return errors.New("invalid_local_path")
	}
	part := volume + `\`
	for _, name := range strings.Split(strings.TrimPrefix(path, part), `\`) {
		if name == "" || name == "." || name == ".." || strings.Contains(name, ":") {
			return errors.New("invalid_local_path")
		}
		part = filepath.Join(part, name)
		if err := noReparse(part); err != nil {
			if !create || !os.IsNotExist(err) {
				return err
			}
			if err = os.Mkdir(part, 0700); err != nil {
				return err
			}
			if err = noReparse(part); err != nil {
				return err
			}
		}
	}
	return nil
}
func privateDescriptor(sd *windows.SECURITY_DESCRIPTOR) bool {
	user, err := currentSID()
	if err != nil {
		return false
	}
	owner, _, err := sd.Owner()
	if err != nil || !owner.Equals(user) {
		return false
	}
	dacl, _, err := sd.DACL()
	if err != nil || dacl == nil || dacl.AceCount == 0 {
		return false
	}
	for i := uint32(0); i < uint32(dacl.AceCount); i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if windows.GetAce(dacl, i, &ace) != nil {
			return false
		}
		if ace.Header.AceType == windows.ACCESS_DENIED_ACE_TYPE {
			continue
		}
		if ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE {
			return false
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart))
		if !sid.Equals(user) && sid.String() != "S-1-5-18" && sid.String() != "S-1-5-32-544" {
			return false
		}
	}
	return true
}
func privateDirectory(path string, set bool) error {
	if err := windowsPath(path, set); err != nil {
		return err
	}
	sd, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return err
	}
	if set {
		user, err := currentSID()
		if err != nil {
			return err
		}
		owner, _, err := sd.Owner()
		if err != nil || !owner.Equals(user) {
			return errors.New("state_owner_rejected")
		}
		restricted, err := windows.SecurityDescriptorFromString("D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;" + user.String() + ")")
		if err != nil {
			return err
		}
		dacl, _, err := restricted.DACL()
		if err != nil {
			return err
		}
		if err = windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, dacl, nil); err != nil {
			return err
		}
		sd, err = windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
		if err != nil {
			return err
		}
	}
	if !privateDescriptor(sd) {
		return errors.New("private_acl_required")
	}
	return nil
}
func platformDesktopOwned(file *os.File, _ os.FileInfo) bool {
	sd, err := windows.GetSecurityInfo(windows.Handle(file.Fd()), windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	return err == nil && privateDescriptor(sd)
}
func desktopOpenFile(path string) (*os.File, error) {
	if err := windowsPath(path, false); err != nil {
		return nil, err
	}
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	handle, err := windows.CreateFile(p, windows.GENERIC_READ|windows.READ_CONTROL, windows.FILE_SHARE_READ, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(handle), path)
	var info windows.ByHandleFileInformation
	if windows.GetFileInformationByHandle(handle, &info) != nil || info.FileAttributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 || !platformDesktopOwned(f, nil) {
		f.Close()
		return nil, errors.New("private_regular_file_required")
	}
	return f, nil
}
func platformCooldownRoot(dir string) (*os.Root, error) {
	if err := privateDirectory(dir, true); err != nil {
		return nil, err
	}
	return os.OpenRoot(dir)
}
func platformCooldownOpen(root *os.Root, name string, flag int, perm os.FileMode) (*os.File, error) {
	// os.Root anchors path resolution; the enclosing directory's protected
	// owner-only DACL excludes cross-user replacement and link creation.
	before, err := root.Lstat(name)
	if err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	if err == nil && (!before.Mode().IsRegular() || before.Mode()&os.ModeSymlink != 0) {
		return nil, errors.New("invalid_cooldown")
	}
	f, err := root.OpenFile(name, flag, perm)
	if err != nil {
		return nil, err
	}
	after, err := root.Lstat(name)
	actual, statErr := f.Stat()
	if err != nil || statErr != nil || !actual.Mode().IsRegular() || after.Mode()&os.ModeSymlink != 0 || !os.SameFile(actual, after) || !platformDesktopOwned(f, actual) {
		f.Close()
		return nil, errors.New("invalid_cooldown")
	}
	return f, nil
}
