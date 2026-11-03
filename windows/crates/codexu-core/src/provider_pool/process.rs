use super::{domain::MAX_IPC, fail, Result};
use crate::accounts::storage as fs;
use sha2::{Digest, Sha256};
use std::{
    fs::File,
    path::{Path, PathBuf},
    sync::atomic::AtomicBool,
    time::Duration,
};

/// Native build-time resource pins, never populated from WebView input.
#[derive(Clone)]
pub struct HelperResource {
    path: PathBuf,
    binary_sha256: String,
    source_sha256: String,
}
impl HelperResource {
    pub fn new(path: PathBuf, binary_sha256: String, source_sha256: String) -> Result<Self> {
        let digest = |s: &str| {
            s.len() == 64
                && s.bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        };
        if !path.is_absolute()
            || path.file_name().and_then(|s| s.to_str()) != Some("aigoodbro-antigravity-proxy.exe")
            || !digest(&binary_sha256)
            || !digest(&source_sha256)
        {
            return Err(fail("provider_pool_resource_invalid"));
        }
        fs::ensure_no_links(&path).map_err(|_| fail("provider_pool_resource_invalid"))?;
        Ok(Self {
            path,
            binary_sha256,
            source_sha256,
        })
    }
    pub(super) fn verified(&self) -> Result<File> {
        let bytes = fs::read_bound_optional(&self.path, 64 * 1024 * 1024, false)
            .map_err(|_| fail("provider_pool_resource_invalid"))?
            .ok_or_else(|| fail("provider_pool_resource_missing"))?;
        if format!("{:x}", Sha256::digest(&bytes)) != self.binary_sha256 || !amd64_pe(&bytes) {
            return Err(fail("provider_pool_resource_invalid"));
        }
        let source = self
            .path
            .parent()
            .ok_or_else(|| fail("provider_pool_resource_invalid"))?
            .join("SOURCE.json");
        let b = fs::read_bound_optional(&source, MAX_IPC, false)
            .map_err(|_| fail("provider_pool_resource_invalid"))?
            .ok_or_else(|| fail("provider_pool_resource_missing"))?;
        if format!("{:x}", Sha256::digest(&b)) != self.source_sha256 {
            return Err(fail("provider_pool_resource_invalid"));
        }
        let mut options = std::fs::OpenOptions::new();
        options.read(true);
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            options.share_mode(1).custom_flags(0x0020_0000);
        }
        let mut file = options
            .open(&self.path)
            .map_err(|_| fail("provider_pool_resource_invalid"))?;
        use std::io::Read;
        let mut held = Vec::new();
        file.by_ref()
            .take(64 * 1024 * 1024 + 1)
            .read_to_end(&mut held)
            .map_err(|_| fail("provider_pool_resource_invalid"))?;
        fs::ensure_no_links(&self.path).map_err(|_| fail("provider_pool_resource_invalid"))?;
        if format!("{:x}", Sha256::digest(&held)) != self.binary_sha256 {
            return Err(fail("provider_pool_resource_invalid"));
        }
        Ok(file)
    }
}
fn amd64_pe(b: &[u8]) -> bool {
    if b.len() < 64 || &b[..2] != b"MZ" {
        return false;
    }
    let at = u32::from_le_bytes(b[60..64].try_into().unwrap()) as usize;
    at.checked_add(26).is_some_and(|end| {
        end <= b.len()
            && &b[at..at + 4] == b"PE\0\0"
            && b[at + 4..at + 6] == [0x64, 0x86]
            && b[at + 24..at + 26] == [0x0b, 0x02]
    })
}

pub(super) trait Helper: Send {
    fn bootstrap(&mut self, bytes: &[u8], cancel: &AtomicBool) -> Result<()>;
    fn frame(&mut self, bytes: &[u8]) -> Result<()>;
    fn output(&mut self) -> Result<Vec<u8>>;
    fn exited(&mut self) -> Result<bool>;
    fn stop(&mut self) -> Result<()>;
}
pub(super) trait Runtime: Send + Sync {
    fn launch(
        &self,
        resource: &HelperResource,
        root: &Path,
        cancel: &AtomicBool,
    ) -> Result<Box<dyn Helper>>;
}
pub(super) struct NativeRuntime;
impl Runtime for NativeRuntime {
    fn launch(
        &self,
        resource: &HelperResource,
        root: &Path,
        cancel: &AtomicBool,
    ) -> Result<Box<dyn Helper>> {
        #[cfg(windows)]
        {
            native::Child::launch(resource, root, cancel).map(|p| Box::new(p) as Box<dyn Helper>)
        }
        #[cfg(not(windows))]
        {
            let _ = (resource, root, cancel);
            Err(fail("provider_pool_windows_required"))
        }
    }
}

#[cfg(windows)]
mod native {
    use super::*;
    use crate::proxy::provider_wire;
    use std::{
        io::{PipeReader, PipeWriter, Read},
        os::windows::{io::AsRawHandle, process::CommandExt},
        process::{Child as StdChild, Command, Stdio},
        sync::atomic::Ordering,
        time::Instant,
    };
    type Handle = *mut std::ffi::c_void;
    #[repr(C)]
    #[derive(Default)]
    struct Basic {
        a: i64,
        b: i64,
        flags: u32,
        min: usize,
        max: usize,
        active: u32,
        affinity: usize,
        priority: u32,
        schedule: u32,
    }
    #[repr(C)]
    #[derive(Default)]
    struct Extended {
        basic: Basic,
        io: [u64; 6],
        process: usize,
        job: usize,
        peak_process: usize,
        peak_job: usize,
    }
    #[repr(C)]
    #[derive(Default)]
    struct Accounting {
        times: [i64; 4],
        faults: u32,
        total: u32,
        active: u32,
        terminated: u32,
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn CreateJobObjectW(attributes: Handle, name: *const u16) -> Handle;
        fn SetInformationJobObject(job: Handle, class: i32, value: Handle, size: u32) -> i32;
        fn QueryInformationJobObject(
            job: Handle,
            class: i32,
            value: Handle,
            size: u32,
            returned: *mut u32,
        ) -> i32;
        fn AssignProcessToJobObject(job: Handle, process: Handle) -> i32;
        fn TerminateJobObject(job: Handle, code: u32) -> i32;
        fn CloseHandle(handle: Handle) -> i32;
        fn PeekNamedPipe(
            pipe: Handle,
            buffer: Handle,
            size: u32,
            read: *mut u32,
            available: *mut u32,
            left: *mut u32,
        ) -> i32;
    }
    #[link(name = "ntdll")]
    unsafe extern "system" {
        fn NtResumeProcess(process: Handle) -> i32;
    }
    struct Job(usize);
    impl Job {
        fn assign(child: &StdChild) -> Result<Self> {
            let handle = unsafe { CreateJobObjectW(std::ptr::null_mut(), std::ptr::null()) };
            if handle.is_null() {
                return Err(fail("provider_pool_process_unavailable"));
            }
            let job = Self(handle as usize);
            let mut limits = Extended::default();
            limits.basic.flags = 0x2000;
            if unsafe {
                SetInformationJobObject(
                    handle,
                    9,
                    (&mut limits as *mut Extended).cast(),
                    std::mem::size_of::<Extended>() as u32,
                )
            } == 0
                || unsafe { AssignProcessToJobObject(handle, child.as_raw_handle()) } == 0
            {
                return Err(fail("provider_pool_process_unavailable"));
            }
            Ok(job)
        }
        fn empty(&self) -> Result<bool> {
            let mut a = Accounting::default();
            if unsafe {
                QueryInformationJobObject(
                    self.0 as Handle,
                    1,
                    (&mut a as *mut Accounting).cast(),
                    std::mem::size_of::<Accounting>() as u32,
                    std::ptr::null_mut(),
                )
            } == 0
            {
                return Err(fail("provider_pool_cleanup_unconfirmed"));
            }
            Ok(a.active == 0)
        }
        fn terminate(&self) -> Result<()> {
            if unsafe { TerminateJobObject(self.0 as Handle, 1) } == 0 {
                return Err(fail("provider_pool_cleanup_unconfirmed"));
            }
            Ok(())
        }
    }
    impl Drop for Job {
        fn drop(&mut self) {
            unsafe { CloseHandle(self.0 as Handle) };
        }
    }
    pub(super) struct Child {
        child: StdChild,
        // None exists only after assignment failure while the exact root is
        // still suspended. Such a child is never resumed and cannot spawn.
        job: Option<Job>,
        input: Option<PipeWriter>,
        output: PipeReader,
        _image: File,
        clean: bool,
    }
    impl Child {
        pub fn launch(resource: &HelperResource, root: &Path, cancel: &AtomicBool) -> Result<Self> {
            let image = resource.verified()?;
            fs::ensure_no_links(root).map_err(|_| fail("provider_pool_storage_invalid"))?;
            let (input, writer) =
                provider_wire::pipe().map_err(|_| fail("provider_pool_process_unavailable"))?;
            let (reader, output) =
                std::io::pipe().map_err(|_| fail("provider_pool_process_unavailable"))?;
            let mut command = Command::new(&resource.path);
            command
                .current_dir(root)
                .env_clear()
                .stdin(Stdio::from(input))
                .stdout(Stdio::from(output))
                .stderr(Stdio::null())
                .creation_flags(0x0800_0000 | 0x4);
            // Go needs only OS plumbing. Never inherit user API/proxy/CLI variables.
            for key in ["SystemRoot", "WINDIR", "TEMP", "TMP"] {
                if let Some(value) = std::env::var_os(key) {
                    command.env(key, value);
                }
            }
            if cancel.load(Ordering::Acquire) {
                return Err(fail("provider_pool_cancelled"));
            }
            let child = command
                .spawn()
                .map_err(|_| fail("provider_pool_process_unavailable"))?;
            drop(command);
            // Keep the suspended root handle on an assignment error. The
            // worker owns bounded cleanup and its fence, including failures.
            let job = Job::assign(&child).ok();
            Ok(Self {
                child,
                job,
                input: Some(writer),
                output: reader,
                _image: image,
                clean: false,
            })
        }
    }
    impl Helper for Child {
        fn bootstrap(&mut self, bootstrap: &[u8], cancel: &AtomicBool) -> Result<()> {
            if bootstrap.len() > MAX_IPC || bootstrap.last() != Some(&b'\n') {
                return Err(fail("provider_pool_capacity"));
            }
            if self.job.is_none()
                || cancel.load(Ordering::Acquire)
                || unsafe { NtResumeProcess(self.child.as_raw_handle()) } < 0
            {
                return Err(fail("provider_pool_process_unavailable"));
            }
            let deadline = Instant::now() + Duration::from_secs(10);
            for chunk in bootstrap.chunks(512) {
                loop {
                    if cancel.load(Ordering::Acquire) || Instant::now() >= deadline {
                        return Err(fail("provider_pool_startup_failed"));
                    }
                    match provider_wire::chunk(
                        self.input
                            .as_mut()
                            .ok_or_else(|| fail("provider_pool_pipe_failed"))?,
                        chunk,
                    ) {
                        Ok(()) => break,
                        Err(provider_wire::Failure::Unchanged) => {
                            std::thread::sleep(Duration::from_millis(5))
                        }
                        Err(provider_wire::Failure::Poisoned) => {
                            self.input.take();
                            return Err(fail("provider_pool_pipe_failed"));
                        }
                    }
                }
            }
            Ok(())
        }
        fn frame(&mut self, bytes: &[u8]) -> Result<()> {
            provider_wire::frame(&mut self.input, bytes)
                .map_err(|_| fail("provider_pool_pipe_failed"))
        }
        fn output(&mut self) -> Result<Vec<u8>> {
            let mut available = 0;
            if unsafe {
                PeekNamedPipe(
                    self.output.as_raw_handle(),
                    std::ptr::null_mut(),
                    0,
                    std::ptr::null_mut(),
                    &mut available,
                    std::ptr::null_mut(),
                )
            } == 0
            {
                if self.exited()? {
                    return Ok(vec![]);
                }
                return Err(fail("provider_pool_pipe_failed"));
            }
            if available == 0 {
                return Ok(vec![]);
            }
            let mut bytes = vec![0; (available as usize).min(65536)];
            let count = self
                .output
                .read(&mut bytes)
                .map_err(|_| fail("provider_pool_pipe_failed"))?;
            bytes.truncate(count);
            Ok(bytes)
        }
        fn exited(&mut self) -> Result<bool> {
            self.child
                .try_wait()
                .map(|v| v.is_some())
                .map_err(|_| fail("provider_pool_cleanup_unconfirmed"))
        }
        fn stop(&mut self) -> Result<()> {
            self.input.take();
            if self.clean {
                return Ok(());
            }
            if let Some(job) = &self.job {
                job.terminate()?;
            } else if !self.exited()? {
                self.child
                    .kill()
                    .map_err(|_| fail("provider_pool_cleanup_unconfirmed"))?;
            }
            let deadline = Instant::now() + Duration::from_secs(3);
            loop {
                if self.exited()?
                    && self
                        .job
                        .as_ref()
                        .map(Job::empty)
                        .transpose()?
                        .unwrap_or(true)
                {
                    self.clean = true;
                    return Ok(());
                }
                if Instant::now() >= deadline {
                    return Err(fail("provider_pool_cleanup_unconfirmed"));
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        }
    }
    impl Drop for Child {
        fn drop(&mut self) {
            if !self.clean {
                let _ = self.stop();
            }
        }
    }
}
