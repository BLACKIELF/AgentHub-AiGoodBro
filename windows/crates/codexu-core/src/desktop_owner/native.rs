use super::{client::Connection, *};

#[cfg(not(windows))]
pub(super) async fn connect(_: &Budget) -> OwnerResult<Connection> {
    Err(OwnerError::UnsupportedPlatform)
}

#[cfg(windows)]
pub(super) async fn connect(budget: &Budget) -> OwnerResult<Connection> {
    win::connect_to(r"\\.\pipe\codex-ipc", win::Trust::Official, budget).await
}

#[cfg(windows)]
pub(super) mod win {
    use super::*;
    use crate::desktop_owner::client::Peer;
    use std::{
        ffi::c_void,
        fs::{File, OpenOptions},
        os::windows::{
            fs::{MetadataExt, OpenOptionsExt},
            io::AsRawHandle,
        },
        path::{Path, PathBuf},
        ptr,
    };
    use tokio::net::windows::named_pipe::{ClientOptions, NamedPipeClient};
    type Handle = *mut c_void;
    #[repr(C)]
    struct FileTime {
        low: u32,
        high: u32,
    }
    #[repr(C)]
    struct Acl {
        revision: u8,
        sbz: u8,
        size: u16,
        count: u16,
        sbz2: u16,
    }
    #[repr(C)]
    struct Ace {
        kind: u8,
        flags: u8,
        size: u16,
        mask: u32,
        sid: u32,
    }
    #[repr(C)]
    struct GenericMapping {
        read: u32,
        write: u32,
        execute: u32,
        all: u32,
    }
    #[repr(C)]
    struct PackageId {
        reserved: u32,
        architecture: u32,
        version: u64,
        name: *const u16,
        publisher: *const u16,
        resource: *const u16,
        publisher_id: *const u16,
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn OpenProcess(access: u32, inherit: i32, pid: u32) -> Handle;
        fn GetCurrentProcess() -> Handle;
        fn CloseHandle(h: Handle) -> i32;
        fn LocalFree(h: Handle) -> Handle;
        fn GetNamedPipeServerProcessId(h: Handle, pid: *mut u32) -> i32;
        fn GetProcessTimes(
            h: Handle,
            created: *mut FileTime,
            exited: *mut FileTime,
            kernel: *mut FileTime,
            user: *mut FileTime,
        ) -> i32;
        fn WaitForSingleObject(h: Handle, ms: u32) -> u32;
        fn ProcessIdToSessionId(pid: u32, session: *mut u32) -> i32;
        fn GetCurrentProcessId() -> u32;
        fn QueryFullProcessImageNameW(h: Handle, flags: u32, path: *mut u16, size: *mut u32)
            -> i32;
        fn GetPackageId(h: Handle, size: *mut u32, buffer: *mut u8) -> i32;
        fn GetPackageFullName(h: Handle, size: *mut u32, name: *mut u16) -> i32;
        fn GetPackagePathByFullName(name: *const u16, size: *mut u32, path: *mut u16) -> i32;
    }
    #[link(name = "advapi32")]
    unsafe extern "system" {
        fn OpenProcessToken(h: Handle, access: u32, token: *mut Handle) -> i32;
        fn GetTokenInformation(
            h: Handle,
            class: u32,
            buffer: *mut c_void,
            size: u32,
            needed: *mut u32,
        ) -> i32;
        fn EqualSid(a: *const c_void, b: *const c_void) -> i32;
        fn IsValidSid(sid: *const c_void) -> i32;
        fn IsWellKnownSid(sid: *const c_void, kind: i32) -> i32;
        fn GetLengthSid(sid: *const c_void) -> u32;
        fn GetSecurityInfo(
            h: Handle,
            kind: u32,
            flags: u32,
            owner: *mut *mut c_void,
            group: *mut *mut c_void,
            dacl: *mut *mut Acl,
            sacl: *mut *mut c_void,
            descriptor: *mut *mut c_void,
        ) -> u32;
        fn IsValidAcl(acl: *const Acl) -> i32;
        fn GetAce(acl: *const Acl, index: u32, ace: *mut *mut Ace) -> i32;
        fn MapGenericMask(mask: *mut u32, mapping: *const GenericMapping);
    }
    struct Owned(usize);
    impl Owned {
        fn raw(&self) -> Handle {
            self.0 as Handle
        }
    }
    impl Drop for Owned {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.raw());
            }
        }
    }
    struct Local(Handle);
    impl Drop for Local {
        fn drop(&mut self) {
            unsafe {
                LocalFree(self.0);
            }
        }
    }

    pub(in crate::desktop_owner) enum Trust {
        Official,
        #[cfg(test)]
        Fixture {
            image: PathBuf,
            sha256: String,
        },
    }
    struct Verified {
        process: Owned,
        pid: u32,
        birth: u64,
        session: u32,
        image: File,
        path: PathBuf,
        // Tokio owns the pipe. Rechecks only run while its Connection socket is
        // alive; no detached thread retains this borrowed raw handle.
        pipe: usize,
        package: Option<String>,
    }
    fn token(h: Handle) -> OwnerResult<Owned> {
        let mut t = ptr::null_mut();
        if unsafe { OpenProcessToken(h, 8, &mut t) } == 0 {
            return Err(OwnerError::PeerUntrusted);
        }
        Ok(Owned(t as usize))
    }
    fn user(t: Handle) -> OwnerResult<Vec<u64>> {
        let mut n = 0;
        unsafe {
            GetTokenInformation(t, 1, ptr::null_mut(), 0, &mut n);
        }
        if !(16..=65536).contains(&n) {
            return Err(OwnerError::PeerUntrusted);
        }
        let mut b = vec![0u64; (n as usize).div_ceil(8)];
        if unsafe { GetTokenInformation(t, 1, b.as_mut_ptr().cast(), n, &mut n) } == 0 {
            return Err(OwnerError::PeerUntrusted);
        }
        Ok(b)
    }
    fn sid(b: &[u64]) -> *const c_void {
        unsafe { *(b.as_ptr().cast::<*const c_void>()) }
    }
    fn not_elevated(t: Handle) -> OwnerResult<()> {
        let (mut v, mut n) = (1u32, 0);
        if unsafe { GetTokenInformation(t, 20, (&mut v as *mut u32).cast(), 4, &mut n) } == 0
            || v != 0
        {
            return Err(OwnerError::PeerUntrusted);
        }
        Ok(())
    }
    fn identities(h: Handle, pid: u32) -> OwnerResult<u32> {
        let current = token(unsafe { GetCurrentProcess() })?;
        let other = token(h)?;
        not_elevated(current.raw())?;
        not_elevated(other.raw())?;
        let a = user(current.raw())?;
        let b = user(other.raw())?;
        let (mut cs, mut ps) = (0, 0);
        if unsafe { EqualSid(sid(&a), sid(&b)) } == 0
            || unsafe { ProcessIdToSessionId(GetCurrentProcessId(), &mut cs) } == 0
            || unsafe { ProcessIdToSessionId(pid, &mut ps) } == 0
            || cs != ps
        {
            return Err(OwnerError::PeerUntrusted);
        }
        Ok(ps)
    }
    fn pid(pipe: Handle) -> OwnerResult<u32> {
        let mut p = 0;
        if unsafe { GetNamedPipeServerProcessId(pipe, &mut p) } == 0 || p == 0 {
            return Err(OwnerError::PeerUntrusted);
        }
        Ok(p)
    }
    fn birth(h: Handle) -> OwnerResult<u64> {
        let mut t = [
            FileTime { low: 0, high: 0 },
            FileTime { low: 0, high: 0 },
            FileTime { low: 0, high: 0 },
            FileTime { low: 0, high: 0 },
        ];
        let p = t.as_mut_ptr();
        if unsafe { GetProcessTimes(h, p, p.add(1), p.add(2), p.add(3)) } == 0 {
            return Err(OwnerError::PeerUntrusted);
        }
        Ok((u64::from(t[0].high) << 32) | u64::from(t[0].low))
    }
    fn image_path(h: Handle) -> OwnerResult<PathBuf> {
        let mut b = vec![0u16; 32768];
        let mut n = b.len() as u32;
        if unsafe { QueryFullProcessImageNameW(h, 0, b.as_mut_ptr(), &mut n) } == 0
            || n == 0
            || n as usize >= b.len()
        {
            return Err(OwnerError::PeerUntrusted);
        }
        Ok(PathBuf::from(
            String::from_utf16(&b[..n as usize]).map_err(|_| OwnerError::PeerUntrusted)?,
        ))
    }
    fn same_path(a: &Path, b: &Path) -> bool {
        a.as_os_str()
            .to_string_lossy()
            .trim_start_matches(r"\\?\")
            .eq_ignore_ascii_case(b.as_os_str().to_string_lossy().trim_start_matches(r"\\?\"))
    }
    fn held_image(path: &Path) -> OwnerResult<File> {
        if !path.is_absolute()
            || !crate::updates::safe_download_directory(
                path.parent().ok_or(OwnerError::PeerUntrusted)?,
            )
        {
            return Err(OwnerError::PeerUntrusted);
        }
        let f = OpenOptions::new()
            .read(true)
            .share_mode(1)
            .custom_flags(0x00200000)
            .open(path)
            .map_err(|_| OwnerError::PeerUntrusted)?;
        let m = f.metadata().map_err(|_| OwnerError::PeerUntrusted)?;
        if !m.is_file() || m.file_attributes() & 0x400 != 0 {
            return Err(OwnerError::PeerUntrusted);
        }
        Ok(f)
    }
    fn bounded_string(buffer: &[u64], p: *const u16) -> OwnerResult<String> {
        let start = buffer.as_ptr() as usize;
        let end = start + buffer.len() * 8;
        let pos = p as usize;
        if pos < start || pos >= end || pos % 2 != 0 {
            return Err(OwnerError::UnsupportedInstallation);
        }
        let slice = unsafe { std::slice::from_raw_parts(p, (end - pos) / 2) };
        let n = slice
            .iter()
            .position(|x| *x == 0)
            .ok_or(OwnerError::UnsupportedInstallation)?;
        String::from_utf16(&slice[..n]).map_err(|_| OwnerError::UnsupportedInstallation)
    }
    fn package(h: Handle, path: &Path) -> OwnerResult<String> {
        let mut n = 0;
        if unsafe { GetPackageId(h, &mut n, ptr::null_mut()) } != 122
            || n < std::mem::size_of::<PackageId>() as u32
            || n > 65536
        {
            return Err(OwnerError::UnsupportedInstallation);
        }
        let mut b = vec![0u64; (n as usize).div_ceil(8)];
        if unsafe { GetPackageId(h, &mut n, b.as_mut_ptr().cast()) } != 0 {
            return Err(OwnerError::UnsupportedInstallation);
        }
        let id = unsafe { &*(b.as_ptr().cast::<PackageId>()) };
        if bounded_string(&b, id.name)? != "OpenAI.Codex"
            || bounded_string(&b, id.publisher)? != "CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B"
        {
            return Err(OwnerError::UnsupportedInstallation);
        }
        let mut count = 0;
        if unsafe { GetPackageFullName(h, &mut count, ptr::null_mut()) } != 122
            || count == 0
            || count > 32768
        {
            return Err(OwnerError::UnsupportedInstallation);
        }
        let mut full = vec![0u16; count as usize];
        if unsafe { GetPackageFullName(h, &mut count, full.as_mut_ptr()) } != 0
            || full.last() != Some(&0)
        {
            return Err(OwnerError::UnsupportedInstallation);
        }
        let name = String::from_utf16(&full[..full.len() - 1])
            .map_err(|_| OwnerError::UnsupportedInstallation)?;
        let mut count = 0;
        if unsafe { GetPackagePathByFullName(full.as_ptr(), &mut count, ptr::null_mut()) } != 122
            || count == 0
            || count > 32768
        {
            return Err(OwnerError::UnsupportedInstallation);
        }
        let mut root = vec![0u16; count as usize];
        if unsafe { GetPackagePathByFullName(full.as_ptr(), &mut count, root.as_mut_ptr()) } != 0
            || root.last() != Some(&0)
        {
            return Err(OwnerError::UnsupportedInstallation);
        }
        let expected = PathBuf::from(
            String::from_utf16(&root[..root.len() - 1])
                .map_err(|_| OwnerError::UnsupportedInstallation)?,
        )
        .join("app")
        .join("ChatGPT.exe");
        if !same_path(path, &expected) {
            return Err(OwnerError::UnsupportedInstallation);
        }
        Ok(name)
    }
    pub(in crate::desktop_owner) fn security(pipe: Handle) -> OwnerResult<()> {
        let current = token(unsafe { GetCurrentProcess() })?;
        let own = user(current.raw())?;
        let (mut owner, mut acl, mut descriptor) =
            (ptr::null_mut(), ptr::null_mut(), ptr::null_mut());
        let status = unsafe {
            GetSecurityInfo(
                pipe,
                6,
                1 | 4,
                &mut owner,
                ptr::null_mut(),
                &mut acl,
                ptr::null_mut(),
                &mut descriptor,
            )
        };
        let _descriptor = Local(descriptor);
        if status != 0
            || owner.is_null()
            || acl.is_null()
            || unsafe { IsValidSid(owner) } == 0
            || unsafe { EqualSid(owner, sid(&own)) } == 0
            || unsafe { IsValidAcl(acl) } == 0
        {
            return Err(OwnerError::PeerUntrusted);
        }
        let mapping = GenericMapping {
            read: 0x120089,
            write: 0x120116,
            execute: 0x1200a0,
            all: 0x1f01ff,
        };
        for i in 0..unsafe { (*acl).count } {
            let mut ace = ptr::null_mut();
            if unsafe { GetAce(acl, i as u32, &mut ace) } == 0 || ace.is_null() {
                return Err(OwnerError::PeerUntrusted);
            }
            let a = unsafe { &*ace };
            if a.size < 12 {
                return Err(OwnerError::PeerUntrusted);
            }
            if a.flags & 8 != 0 {
                continue;
            } // inherit-only ACE grants no pipe access
            if a.kind == 1 {
                continue;
            } // deny ACE cannot grant outsider write
            if a.kind != 0 {
                return Err(OwnerError::PeerUntrusted);
            }
            let s = (&a.sid as *const u32).cast::<c_void>();
            if unsafe { IsValidSid(s) } == 0 || 8 + unsafe { GetLengthSid(s) } > a.size as u32 {
                return Err(OwnerError::PeerUntrusted);
            }
            let trusted = unsafe {
                EqualSid(s, sid(&own)) != 0
                    || IsWellKnownSid(s, 22) != 0
                    || IsWellKnownSid(s, 26) != 0
            };
            let mut mask = a.mask;
            unsafe {
                MapGenericMask(&mut mask, &mapping);
            }
            if !trusted && mask & !0x120089 != 0 {
                return Err(OwnerError::PeerUntrusted);
            }
        }
        Ok(())
    }
    impl Peer for Verified {
        fn recheck(&self) -> OwnerResult<()> {
            if unsafe { WaitForSingleObject(self.process.raw(), 0) } != 258
                || birth(self.process.raw())? != self.birth
                || pid(self.pipe as Handle)? != self.pid
                || identities(self.process.raw(), self.pid)? != self.session
                || !same_path(&image_path(self.process.raw())?, &self.path)
            {
                return Err(OwnerError::PeerUntrusted);
            }
            if let Some(expected) = &self.package {
                if package(self.process.raw(), &self.path)? != *expected {
                    return Err(OwnerError::PeerUntrusted);
                }
            }
            let m = self
                .image
                .metadata()
                .map_err(|_| OwnerError::PeerUntrusted)?;
            if !m.is_file() || m.file_attributes() & 0x400 != 0 {
                return Err(OwnerError::PeerUntrusted);
            }
            security(self.pipe as Handle)
        }
    }
    fn authenticate(pipe: NamedPipeClient, trust: Trust) -> OwnerResult<Connection> {
        let raw = pipe.as_raw_handle();
        security(raw)?;
        let pid = pid(raw)?;
        let h = unsafe { OpenProcess(0x00101000, 0, pid) };
        if h.is_null() {
            return Err(OwnerError::PeerUntrusted);
        }
        let process = Owned(h as usize);
        let birth = birth(h)?;
        let session = identities(h, pid)?;
        let path = image_path(h)?;
        let image = held_image(&path)?;
        let package = match trust {
            Trust::Official => {
                let p = package(h, &path)?;
                let publisher = crate::readers::local_cli_quota::antigravity::publisher_of(&path)
                    .ok_or(OwnerError::PeerUntrusted)?;
                let publisher = publisher
                    .chars()
                    .filter(|c| c.is_ascii_alphanumeric())
                    .flat_map(char::to_lowercase)
                    .collect::<String>();
                if !matches!(publisher.as_str(), "openai" | "openaillc" | "openaiinc") {
                    return Err(OwnerError::PeerUntrusted);
                }
                Some(p)
            }
            #[cfg(test)]
            Trust::Fixture {
                image: expected,
                sha256,
            } => {
                use sha2::{Digest, Sha256};
                if !same_path(&path, &expected)
                    || format!(
                        "{:x}",
                        Sha256::digest(
                            std::fs::read(&path).map_err(|_| OwnerError::PeerUntrusted)?
                        )
                    ) != sha256
                {
                    return Err(OwnerError::PeerUntrusted);
                }
                None
            }
        };
        let peer = Verified {
            process,
            pid,
            birth,
            session,
            image,
            path,
            pipe: raw as usize,
            package,
        };
        peer.recheck()?;
        Ok(Connection {
            socket: Box::new(pipe),
            peer: Box::new(peer),
        })
    }
    pub(in crate::desktop_owner) async fn connect_to(
        endpoint: &str,
        trust: Trust,
        budget: &Budget,
    ) -> OwnerResult<Connection> {
        budget.check()?;
        let pipe = ClientOptions::new()
            .open(endpoint)
            .map_err(|_| OwnerError::Unavailable)?;
        // Verification may invoke the platform trust provider. It runs off the
        // async thread, retains the image/pipe and cannot late-send anything.
        let work = tokio::task::spawn_blocking(move || authenticate(pipe, trust));
        budget
            .wait(async { work.await.map_err(|_| OwnerError::PeerUntrusted)? })
            .await
    }
}
