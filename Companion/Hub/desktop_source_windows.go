//go:build windows

package main

import (
	"golang.org/x/sys/windows"
	"os"
	"path/filepath"
	"unsafe"
)

// Desktop settings use inherited read ACLs, unlike the private credential
// vault. Other principals may read these settings but may not change them.
func desktopSourceHandle(handle windows.Handle, directory bool) error {
	var info windows.ByHandleFileInformation
	if windows.GetFileInformationByHandle(handle, &info) != nil || info.FileAttributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 || (info.FileAttributes&windows.FILE_ATTRIBUTE_DIRECTORY != 0) != directory || (!directory && info.NumberOfLinks != 1) {
		return errDispatchPolicyUnavailable
	}
	sd, err := windows.GetSecurityInfo(handle, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return errDispatchPolicyUnavailable
	}
	owner, _, err := sd.Owner()
	user, userErr := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil || userErr != nil || owner == nil || !owner.Equals(user.User.Sid) {
		return errDispatchPolicyUnavailable
	}
	acl, _, err := sd.DACL()
	if err != nil || acl == nil || acl.AceCount == 0 {
		return errDispatchPolicyUnavailable
	}
	system, _ := windows.StringToSid("S-1-5-18")
	admins, _ := windows.StringToSid("S-1-5-32-544")
	const mutable = windows.GENERIC_ALL | windows.GENERIC_WRITE | windows.DELETE | windows.WRITE_DAC | windows.WRITE_OWNER | windows.FILE_WRITE_DATA | windows.FILE_APPEND_DATA | windows.FILE_WRITE_EA | windows.FILE_WRITE_ATTRIBUTES | 0x0040 // FILE_DELETE_CHILD
	for i := uint32(0); i < uint32(acl.AceCount); i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if windows.GetAce(acl, i, &ace) != nil {
			return errDispatchPolicyUnavailable
		}
		if ace.Header.AceFlags&windows.INHERIT_ONLY_ACE != 0 {
			continue
		}
		if ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE {
			return errDispatchPolicyUnavailable
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart))
		if !sid.IsValid() {
			return errDispatchPolicyUnavailable
		}
		if !sid.Equals(user.User.Sid) && !sid.Equals(system) && !sid.Equals(admins) && ace.Mask&mutable != 0 {
			return errDispatchPolicyUnavailable
		}
	}
	return nil
}

func openDesktopSource(path string, private bool) (*os.File, func(), error) {
	if !canonicalLocalPrefix(path) {
		return nil, nil, errDispatchPolicyUnavailable
	}
	parents, err := holdDirectories(filepath.Dir(path), false)
	if err != nil {
		return nil, nil, errDispatchPolicyUnavailable
	}
	fail := func() (*os.File, func(), error) {
		closeDirectories(parents)
		return nil, nil, errDispatchPolicyUnavailable
	}
	validate := desktopSourceHandle
	if private {
		validate = privateHandle
	}
	if validate(parents[len(parents)-1], true) != nil {
		return fail()
	}
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return fail()
	}
	// No shared write/delete: auth, catalog and workflow bytes cannot change
	// between validation and resuming the suspended owned child.
	handle, err := windows.CreateFile(name, windows.GENERIC_READ|windows.READ_CONTROL|windows.FILE_READ_ATTRIBUTES, windows.FILE_SHARE_READ, nil, windows.OPEN_EXISTING, windows.FILE_ATTRIBUTE_NORMAL|windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		return fail()
	}
	if validate(handle, false) != nil {
		windows.CloseHandle(handle)
		return fail()
	}
	file := os.NewFile(uintptr(handle), path)
	release := func() { file.Close(); closeDirectories(parents) }
	info, err := file.Stat()
	if err != nil || info.Size() > 2*1024*1024 {
		release()
		return nil, nil, errDispatchPolicyUnavailable
	}
	return file, release, nil
}
