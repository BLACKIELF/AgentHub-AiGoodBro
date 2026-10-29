//! Synthetic fixture creation only. No existing object may be re-owned.
//! An elevated runner's default owner is not necessarily its TokenUser.
use std::{
    io,
    path::{Path, PathBuf},
};

pub fn fixture_root(parent: &Path) -> PathBuf {
    let root = parent.join("synthetic-private-fixture");
    create_private_dir(&root).expect("exclusive synthetic fixture root");
    root.canonicalize().expect("synthetic fixture root")
}
pub fn create_private_dir(path: &Path) -> io::Result<()> {
    #[cfg(windows)]
    {
        native::create_dir(path)
    }
    #[cfg(not(windows))]
    {
        std::fs::create_dir(path)
    }
}
pub fn write_private_file_new(path: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::io::Write;
    #[cfg(windows)]
    let mut file = native::create_file(path)?;
    #[cfg(not(windows))]
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

#[cfg(windows)]
mod native {
    use super::*;
    use std::{
        ffi::c_void,
        fs::File,
        os::windows::{ffi::OsStrExt, io::FromRawHandle},
    };
    type Handle = *mut c_void;
    #[repr(C)]
    struct Attributes {
        size: u32,
        descriptor: *mut c_void,
        inherit: i32,
    }
    #[link(name = "advapi32")]
    unsafe extern "system" {
        fn OpenProcessToken(process: Handle, access: u32, token: *mut Handle) -> i32;
        fn GetTokenInformation(
            token: Handle,
            class: u32,
            data: *mut c_void,
            size: u32,
            needed: *mut u32,
        ) -> i32;
        fn ConvertSidToStringSidW(sid: *const c_void, text: *mut *mut u16) -> i32;
        fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
            text: *const u16,
            revision: u32,
            descriptor: *mut *mut c_void,
            size: *mut u32,
        ) -> i32;
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetCurrentProcess() -> Handle;
        fn CloseHandle(handle: Handle) -> i32;
        fn LocalFree(memory: *mut c_void) -> *mut c_void;
        fn CreateDirectoryW(path: *const u16, attributes: *const Attributes) -> i32;
        fn CreateFileW(
            path: *const u16,
            access: u32,
            share: u32,
            attributes: *const Attributes,
            creation: u32,
            flags: u32,
            template: Handle,
        ) -> Handle;
    }
    struct Token(Handle);
    impl Drop for Token {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }
    struct Local(*mut c_void);
    impl Drop for Local {
        fn drop(&mut self) {
            unsafe {
                LocalFree(self.0);
            }
        }
    }
    fn descriptor() -> io::Result<Local> {
        let mut token = std::ptr::null_mut();
        if unsafe { OpenProcessToken(GetCurrentProcess(), 8, &mut token) } == 0 {
            return Err(io::Error::last_os_error());
        }
        let token = Token(token);
        let mut needed = 0;
        unsafe {
            GetTokenInformation(token.0, 1, std::ptr::null_mut(), 0, &mut needed);
        }
        if needed < 8 || needed > 65536 {
            return Err(io::Error::other("invalid synthetic token user size"));
        }
        let mut user = vec![0u64; (needed as usize).div_ceil(8)];
        if unsafe { GetTokenInformation(token.0, 1, user.as_mut_ptr().cast(), needed, &mut needed) }
            == 0
        {
            return Err(io::Error::last_os_error());
        }
        let sid = unsafe { *(user.as_ptr().cast::<*const c_void>()) };
        let mut text = std::ptr::null_mut();
        if sid.is_null() || unsafe { ConvertSidToStringSidW(sid, &mut text) } == 0 {
            return Err(io::Error::last_os_error());
        }
        let _text = Local(text.cast());
        let mut length = 0;
        while length < 184 && unsafe { *text.add(length) } != 0 {
            length += 1;
        }
        if length == 184 {
            return Err(io::Error::other("invalid synthetic SID length"));
        }
        let sid = String::from_utf16(unsafe { std::slice::from_raw_parts(text, length) })
            .map_err(|_| io::Error::other("invalid synthetic SID"))?;
        let sddl = format!("O:{sid}D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;{sid})\0")
            .encode_utf16()
            .collect::<Vec<_>>();
        let mut descriptor = std::ptr::null_mut();
        if unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl.as_ptr(),
                1,
                &mut descriptor,
                std::ptr::null_mut(),
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok(Local(descriptor))
    }
    pub(super) fn create_dir(path: &Path) -> io::Result<()> {
        let sd = descriptor()?;
        let attributes = Attributes {
            size: std::mem::size_of::<Attributes>() as u32,
            descriptor: sd.0,
            inherit: 0,
        };
        let path = path
            .as_os_str()
            .encode_wide()
            .chain(Some(0))
            .collect::<Vec<_>>();
        if unsafe { CreateDirectoryW(path.as_ptr(), &attributes) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
    pub(super) fn create_file(path: &Path) -> io::Result<File> {
        let sd = descriptor()?;
        let attributes = Attributes {
            size: std::mem::size_of::<Attributes>() as u32,
            descriptor: sd.0,
            inherit: 0,
        };
        let path = path
            .as_os_str()
            .encode_wide()
            .chain(Some(0))
            .collect::<Vec<_>>();
        let handle = unsafe {
            CreateFileW(
                path.as_ptr(),
                0x4000_0000,
                0,
                &attributes,
                1,
                0x0020_0080,
                std::ptr::null_mut(),
            )
        };
        if handle as isize == -1 {
            return Err(io::Error::last_os_error());
        }
        Ok(unsafe { File::from_raw_handle(handle.cast()) })
    }
}
