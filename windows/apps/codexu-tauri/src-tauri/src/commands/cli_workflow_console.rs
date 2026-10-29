//! The owned process joins a job while suspended, before it can spawn children.
use codexu_core::automatic_switch::live::{
    OwnedDomainPurpose, OwnedDomainRegistration, OwnedProcessDomains,
};
use std::{fs::File, path::Path, sync::Arc};

pub fn lock_executable(path: &Path) -> std::io::Result<File> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.share_mode(1); // FILE_SHARE_READ: reject replacement while probing/running.
    }
    options.open(path)
}

/// Windows C-runtime argv quoting, not shell escaping. Always quote each
/// argument and double trailing slashes so spaces/quotes remain literal.
#[cfg(any(windows, test))]
fn quote_argument(argument: &[u16]) -> Vec<u16> {
    let mut result = vec![b'"' as u16];
    let mut slashes = 0;
    for unit in argument {
        if *unit == b'\\' as u16 {
            slashes += 1;
            continue;
        }
        let count = if *unit == b'"' as u16 {
            slashes * 2 + 1
        } else {
            slashes
        };
        result.extend(std::iter::repeat_n(b'\\' as u16, count));
        result.push(*unit);
        slashes = 0;
    }
    result.extend(std::iter::repeat_n(b'\\' as u16, slashes * 2));
    result.push(b'"' as u16);
    result
}

#[cfg(windows)]
mod native {
    use super::*;
    use std::{
        ffi::{c_void, OsStr, OsString},
        os::windows::ffi::OsStrExt,
        os::windows::io::{AsRawHandle, BorrowedHandle},
        time::{Duration, Instant},
    };
    type Handle = *mut c_void;
    #[repr(C)]
    #[derive(Default)]
    struct BasicLimits {
        process_time: i64,
        job_time: i64,
        flags: u32,
        min_working_set: usize,
        max_working_set: usize,
        active_processes: u32,
        affinity: usize,
        priority: u32,
        scheduling: u32,
    }
    #[repr(C)]
    #[derive(Default)]
    struct IoCounters {
        read_operations: u64,
        write_operations: u64,
        other_operations: u64,
        read_bytes: u64,
        write_bytes: u64,
        other_bytes: u64,
    }
    #[repr(C)]
    #[derive(Default)]
    struct ExtendedLimits {
        basic: BasicLimits,
        io: IoCounters,
        process_memory: usize,
        job_memory: usize,
        peak_process_memory: usize,
        peak_job_memory: usize,
    }
    #[repr(C)]
    #[derive(Default)]
    struct Accounting {
        user_time: i64,
        kernel_time: i64,
        period_user: i64,
        period_kernel: i64,
        page_faults: u32,
        total: u32,
        active: u32,
        terminated: u32,
    }
    #[repr(C)]
    struct StartupInfo {
        size: u32,
        reserved: *mut u16,
        desktop: *mut u16,
        title: *mut u16,
        x: u32,
        y: u32,
        x_size: u32,
        y_size: u32,
        x_chars: u32,
        y_chars: u32,
        fill: u32,
        flags: u32,
        show: u16,
        reserved_size: u16,
        reserved_bytes: *mut u8,
        stdin: Handle,
        stdout: Handle,
        stderr: Handle,
    }
    #[repr(C)]
    struct ProcessInfo {
        process: Handle,
        thread: Handle,
        process_id: u32,
        thread_id: u32,
    }
    #[repr(C)]
    struct StartupInfoEx {
        startup: StartupInfo,
        attributes: *mut c_void,
    }
    #[link(name = "kernel32")]
    extern "system" {
        fn CreateJobObjectW(attributes: *const c_void, name: *const u16) -> Handle;
        fn SetInformationJobObject(
            job: Handle,
            class: i32,
            information: *const c_void,
            length: u32,
        ) -> i32;
        fn QueryInformationJobObject(
            job: Handle,
            class: i32,
            information: *mut c_void,
            length: u32,
            returned: *mut u32,
        ) -> i32;
        fn AssignProcessToJobObject(job: Handle, process: Handle) -> i32;
        fn TerminateJobObject(job: Handle, exit_code: u32) -> i32;
        fn WaitForSingleObject(handle: Handle, milliseconds: u32) -> u32;
        fn CloseHandle(handle: Handle) -> i32;
        fn CreateProcessW(
            application: *const u16,
            command_line: *mut u16,
            process_attributes: *const c_void,
            thread_attributes: *const c_void,
            inherit_handles: i32,
            creation_flags: u32,
            environment: *const c_void,
            directory: *const u16,
            startup: *mut StartupInfo,
            information: *mut ProcessInfo,
        ) -> i32;
        fn ResumeThread(thread: Handle) -> u32;
        fn TerminateProcess(process: Handle, code: u32) -> i32;
        fn GetExitCodeProcess(process: Handle, code: *mut u32) -> i32;
        fn GetCurrentProcess() -> Handle;
        fn DuplicateHandle(
            source: Handle,
            handle: Handle,
            target: Handle,
            copy: *mut Handle,
            access: u32,
            inherit: i32,
            options: u32,
        ) -> i32;
        fn InitializeProcThreadAttributeList(
            list: *mut c_void,
            count: u32,
            flags: u32,
            size: *mut usize,
        ) -> i32;
        fn UpdateProcThreadAttribute(
            list: *mut c_void,
            flags: u32,
            attribute: usize,
            value: *mut c_void,
            size: usize,
            previous: *mut c_void,
            returned: *mut usize,
        ) -> i32;
        fn DeleteProcThreadAttributeList(list: *mut c_void);
    }
    // Owned handles, never caller-supplied PIDs. Integers permit Send for the
    // job/process handles, whose Win32 APIs support calls from other threads.
    struct OwnedHandle(usize);
    impl OwnedHandle {
        fn raw(&self) -> Handle {
            self.0 as Handle
        }
    }
    impl Drop for OwnedHandle {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.raw());
            }
        }
    }
    struct HandleList {
        storage: Vec<usize>,
        initialized: bool,
    }
    impl HandleList {
        fn new(handles: &mut [Handle]) -> std::io::Result<Self> {
            let mut bytes = 0;
            unsafe {
                InitializeProcThreadAttributeList(std::ptr::null_mut(), 1, 0, &mut bytes);
            }
            if bytes == 0 || bytes > 65536 {
                return Err(std::io::Error::other("Invalid inherited handle list"));
            }
            let mut result = Self {
                storage: vec![0; bytes.div_ceil(std::mem::size_of::<usize>())],
                initialized: false,
            };
            if unsafe { InitializeProcThreadAttributeList(result.raw(), 1, 0, &mut bytes) } == 0 {
                return Err(std::io::Error::last_os_error());
            }
            result.initialized = true;
            if unsafe {
                UpdateProcThreadAttribute(
                    result.raw(),
                    0,
                    0x0002_0002,
                    handles.as_mut_ptr().cast(),
                    std::mem::size_of_val(handles),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                )
            } == 0
            {
                return Err(std::io::Error::last_os_error());
            }
            Ok(result)
        }
        fn raw(&mut self) -> *mut c_void {
            self.storage.as_mut_ptr().cast()
        }
    }
    impl Drop for HandleList {
        fn drop(&mut self) {
            if self.initialized {
                unsafe {
                    DeleteProcThreadAttributeList(self.raw());
                }
            }
        }
    }
    fn inheritable(file: &File) -> std::io::Result<OwnedHandle> {
        let mut copy = std::ptr::null_mut();
        let current = unsafe { GetCurrentProcess() };
        if unsafe {
            DuplicateHandle(
                current,
                file.as_raw_handle().cast(),
                current,
                &mut copy,
                0,
                1,
                2,
            )
        } == 0
        {
            return Err(std::io::Error::last_os_error());
        }
        Ok(OwnedHandle(copy as usize))
    }
    struct Job(OwnedHandle);
    impl Job {
        fn create() -> std::io::Result<Self> {
            let handle = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
            if handle.is_null() {
                return Err(std::io::Error::last_os_error());
            }
            let job = Self(OwnedHandle(handle as usize));
            let mut limits = ExtendedLimits::default();
            limits.basic.flags = 0x0000_2000; // KILL_ON_JOB_CLOSE: crash/forced-exit cleanup.
            let success = unsafe {
                SetInformationJobObject(
                    handle,
                    9,
                    &limits as *const _ as *const c_void,
                    std::mem::size_of::<ExtendedLimits>() as u32,
                )
            };
            if success == 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(job)
        }
        fn active_processes(&self) -> std::io::Result<u32> {
            let mut accounting = Accounting::default();
            let success = unsafe {
                QueryInformationJobObject(
                    self.0.raw(),
                    1,
                    &mut accounting as *mut _ as *mut c_void,
                    std::mem::size_of::<Accounting>() as u32,
                    std::ptr::null_mut(),
                )
            };
            if success == 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(accounting.active)
        }
    }
    fn wide(value: &OsStr) -> std::io::Result<Vec<u16>> {
        let mut result: Vec<u16> = value.encode_wide().collect();
        if result.contains(&0) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "NUL in process argument",
            ));
        }
        result.push(0);
        Ok(result)
    }
    fn environment(
        spec: &codexu_core::local_cli::launch::Environment,
    ) -> std::io::Result<Vec<u16>> {
        let entries = spec
            .apply(std::env::vars_os())
            .map_err(|_| std::io::Error::other("Invalid provider environment"))?;
        let mut result = Vec::new();
        for (key, value) in entries {
            let mut item = key;
            item.push("=");
            item.push(value);
            result.extend(wide(&item)?);
        }
        result.push(0);
        if result.len() > 32767 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "Environment exceeds Windows limit",
            ));
        }
        Ok(result)
    }
    pub struct OwnedConsole {
        process: OwnedHandle,
        job: Job,
        _domain: Option<OwnedDomainRegistration>,
        _resources: Arc<dyn Send + Sync>,
    }
    impl OwnedConsole {
        pub fn start(
            executable: &Path,
            home: &Path,
            workspace: &Path,
            args: &[String],
            guard: File,
        ) -> std::io::Result<Self> {
            let spec = codexu_core::local_cli::launch::Environment::codex(home)
                .map_err(|_| std::io::Error::other("Invalid Codex environment"))?;
            Self::start_provider(
                executable,
                workspace,
                args,
                guard,
                &spec,
                "AiGoodBro - Codex",
            )
        }
        pub fn start_provider(
            executable: &Path,
            workspace: &Path,
            args: &[String],
            guard: File,
            spec: &codexu_core::local_cli::launch::Environment,
            title: &str,
        ) -> std::io::Result<Self> {
            Self::start_registered(
                executable, workspace, args, guard, spec, title, None, None, None,
            )
        }
        /// Native-only arguments and resources. Capture permits only these two
        /// explicit inheritable handles; no unrelated handle enters the child.
        pub fn start_registered(
            executable: &Path,
            workspace: &Path,
            args: &[String],
            guard: File,
            spec: &codexu_core::local_cli::launch::Environment,
            title: &str,
            domains: Option<Arc<OwnedProcessDomains>>,
            resources: Option<Arc<dyn Send + Sync>>,
            capture: Option<&File>,
        ) -> std::io::Result<Self> {
            let resources: Arc<dyn Send + Sync> = Arc::new((Arc::new(guard), resources));
            let job = Job::create()?;
            let application = wide(executable.as_os_str())?;
            let directory = wide(workspace.as_os_str())?;
            let environment = environment(spec)?;
            let mut command_line = quote_argument(&application[..application.len() - 1]);
            for argument in args {
                let argument = wide(OsStr::new(argument))?;
                command_line.push(b' ' as u16);
                command_line.extend(quote_argument(&argument[..argument.len() - 1]));
            }
            command_line.push(0);
            if command_line.len() > 32767 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "Command exceeds Windows limit",
                ));
            }
            let mut title = wide(OsStr::new(title))?;
            let mut startup: StartupInfoEx = unsafe { std::mem::zeroed() };
            startup.startup.size = std::mem::size_of::<StartupInfo>() as u32;
            startup.startup.title = title.as_mut_ptr();
            let output = capture.map(inheritable).transpose()?;
            let null = if capture.is_some() {
                Some(inheritable(
                    &std::fs::OpenOptions::new()
                        .read(true)
                        .write(true)
                        .open("NUL")?,
                )?)
            } else {
                None
            };
            let mut handles = output
                .as_ref()
                .zip(null.as_ref())
                .map(|(o, n)| [o.raw(), n.raw()]);
            let mut handle_list = handles.as_mut().map(|h| HandleList::new(h)).transpose()?;
            if let Some(list) = &mut handle_list {
                startup.startup.size = std::mem::size_of::<StartupInfoEx>() as u32;
                startup.startup.flags = 0x100;
                startup.startup.stdout = output.as_ref().unwrap().raw();
                startup.startup.stdin = null.as_ref().unwrap().raw();
                startup.startup.stderr = null.as_ref().unwrap().raw();
                startup.attributes = list.raw();
            }
            let mut information: ProcessInfo = unsafe { std::mem::zeroed() };
            // No inherited handles. New console supplies its own stdin/out.
            // CREATE_SUSPENDED | CREATE_NEW_CONSOLE | CREATE_UNICODE_ENVIRONMENT.
            let success = unsafe {
                CreateProcessW(
                    application.as_ptr(),
                    command_line.as_mut_ptr(),
                    std::ptr::null(),
                    std::ptr::null(),
                    if capture.is_some() { 1 } else { 0 },
                    if capture.is_some() {
                        0x0808_0404
                    } else {
                        0x0000_0414
                    },
                    environment.as_ptr() as *const c_void,
                    directory.as_ptr(),
                    &mut startup.startup,
                    &mut information,
                )
            };
            if success == 0 {
                return Err(std::io::Error::last_os_error());
            }
            let process = OwnedHandle(information.process as usize);
            let thread = OwnedHandle(information.thread as usize);
            if unsafe { AssignProcessToJobObject(job.0.raw(), process.raw()) } == 0 {
                let error = std::io::Error::last_os_error();
                unsafe {
                    TerminateProcess(process.raw(), 1);
                    WaitForSingleObject(process.raw(), 2000);
                }
                return Err(error);
            }
            let domain = if let Some(domains) = domains {
                let receipt = unsafe {
                    domains.register_native(
                        BorrowedHandle::borrow_raw(process.raw()),
                        BorrowedHandle::borrow_raw(job.0.raw()),
                        resources.clone(),
                        OwnedDomainPurpose::ManagedConsole,
                    )
                };
                match receipt {
                    Ok(value) => Some(value),
                    Err(_) => {
                        unsafe {
                            TerminateJobObject(job.0.raw(), 1);
                            WaitForSingleObject(process.raw(), 2000);
                        }
                        return Err(std::io::Error::other("Owned console registration failed"));
                    }
                }
            } else {
                None
            };
            if unsafe { ResumeThread(thread.raw()) } != 1 {
                let error = std::io::Error::other("Could not resume owned terminal");
                unsafe {
                    TerminateJobObject(job.0.raw(), 1);
                    WaitForSingleObject(process.raw(), 2000);
                }
                return Err(error);
            }
            Ok(Self {
                process,
                job,
                _domain: domain,
                _resources: resources,
            })
        }
        pub fn has_exited(&mut self) -> std::io::Result<bool> {
            match unsafe { WaitForSingleObject(self.process.raw(), 0) } {
                // The original root process can hand work to a descendant.
                // Keep the reservation until every Job member has exited.
                0 => Ok(self.job.active_processes()? == 0),
                258 => Ok(false),
                _ => Err(std::io::Error::last_os_error()),
            }
        }
        pub fn stop(&mut self) -> std::io::Result<()> {
            if unsafe { TerminateJobObject(self.job.0.raw(), 1) } == 0 {
                return Err(std::io::Error::last_os_error());
            }
            let deadline = Instant::now() + Duration::from_secs(2);
            while self.job.active_processes()? != 0 {
                if Instant::now() >= deadline {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        "Owned terminal has not exited",
                    ));
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            Ok(())
        }
        pub fn exit_success(&mut self) -> std::io::Result<bool> {
            if !self.has_exited()? {
                return Ok(false);
            }
            let mut code = 0;
            if unsafe { GetExitCodeProcess(self.process.raw(), &mut code) } == 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(code == 0)
        }
    }
}

#[cfg(windows)]
pub use native::OwnedConsole;
#[cfg(not(windows))]
pub struct OwnedConsole;
#[cfg(not(windows))]
impl OwnedConsole {
    pub fn start(_: &Path, _: &Path, _: &Path, _: &[String], _: File) -> std::io::Result<Self> {
        Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "Windows required",
        ))
    }
    pub fn has_exited(&mut self) -> std::io::Result<bool> {
        Ok(true)
    }
    pub fn start_provider(
        _: &Path,
        _: &Path,
        _: &[String],
        _: File,
        _: &codexu_core::local_cli::launch::Environment,
        _: &str,
    ) -> std::io::Result<Self> {
        Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "Windows required",
        ))
    }
    pub fn stop(&mut self) -> std::io::Result<()> {
        Ok(())
    }
    pub fn exit_success(&mut self) -> std::io::Result<bool> {
        Ok(false)
    }
    pub fn start_registered(
        _: &Path,
        _: &Path,
        _: &[String],
        _: File,
        _: &codexu_core::local_cli::launch::Environment,
        _: &str,
        _: Option<Arc<OwnedProcessDomains>>,
        _: Option<Arc<dyn Send + Sync>>,
        _: Option<&File>,
    ) -> std::io::Result<Self> {
        Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "Windows required",
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::quote_argument;
    #[test]
    fn windows_arguments_keep_spaces_quotes_and_trailing_slashes_literal() {
        let quote = |value: &str| {
            String::from_utf16(&quote_argument(&value.encode_utf16().collect::<Vec<_>>())).unwrap()
        };
        assert_eq!(quote(""), "\"\"");
        assert_eq!(quote("two words"), "\"two words\"");
        assert_eq!(quote("a\"b"), "\"a\\\"b\"");
        assert_eq!(quote("tail\\"), "\"tail\\\\\"");
        assert_eq!(quote("x; & echo"), "\"x; & echo\"");
        assert_eq!(quote("目录"), "\"目录\"");
    }
}
