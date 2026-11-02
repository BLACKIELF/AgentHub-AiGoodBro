//! The owned process joins a job while suspended, before it can spawn children.
use codexu_core::automatic_switch::live::OwnedProcessDomains;
#[cfg(windows)]
use codexu_core::automatic_switch::live::{OwnedDomainPurpose, OwnedDomainRegistration};
use std::{fs::File, path::Path, sync::Arc};

/// Native process owner retained when CreateProcess succeeded but the launch
/// transaction did not finish. Implementations must confirm the complete Job
/// (and root process) is empty before reporting successful cleanup.
pub trait OwnedProcess: Send {
    fn has_exited(&mut self) -> std::io::Result<bool>;
    fn stop(&mut self) -> std::io::Result<()>;
    fn exit_success(&mut self) -> std::io::Result<bool>;
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum LaunchWindow {
    Console,
    NoWindow,
}
fn launch_creation_flags(window: LaunchWindow, capture: bool) -> u32 {
    let no_window = window == LaunchWindow::NoWindow || capture;
    0x0000_0404
        | if no_window { 0x0800_0000 } else { 0x0000_0010 }
        | if capture { 0x0008_0000 } else { 0 }
}

/// A launch failure distinguishes pre-create errors from a process that needs
/// continued ownership. Callers can store the returned owner until cleanup is
/// positively confirmed.
pub struct StartFailure {
    error: std::io::Error,
    owner: Option<Box<dyn OwnedProcess>>,
}
impl StartFailure {
    pub(super) fn after_create(error: std::io::Error, owner: Box<dyn OwnedProcess>) -> Self {
        Self {
            error,
            owner: Some(owner),
        }
    }
    pub fn into_parts(self) -> (std::io::Error, Option<Box<dyn OwnedProcess>>) {
        (self.error, self.owner)
    }
}
impl From<std::io::Error> for StartFailure {
    fn from(error: std::io::Error) -> Self {
        Self { error, owner: None }
    }
}

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
        pid: u32,
        process: OwnedHandle,
        job: Job,
        in_job: bool,
        _domain: Option<OwnedDomainRegistration>,
        _resources: Arc<dyn Send + Sync>,
    }
    impl OwnedConsole {
        /// Native-only arguments and resources. Capture permits only these two
        /// explicit inheritable handles; no unrelated handle enters the child.
        pub fn start_registered_owned(
            executable: &Path,
            workspace: &Path,
            args: &[String],
            guard: File,
            spec: &codexu_core::local_cli::launch::Environment,
            title: &str,
            domains: Option<Arc<OwnedProcessDomains>>,
            resources: Option<Arc<dyn Send + Sync>>,
            capture: Option<&File>,
        ) -> Result<Self, StartFailure> {
            let window = if capture.is_some() {
                LaunchWindow::NoWindow
            } else {
                LaunchWindow::Console
            };
            Self::start_registered_owned_with_window(
                executable, workspace, args, guard, spec, title, domains, resources, capture,
                window,
            )
        }
        pub fn start_registered_owned_with_window(
            executable: &Path,
            workspace: &Path,
            args: &[String],
            guard: File,
            spec: &codexu_core::local_cli::launch::Environment,
            title: &str,
            domains: Option<Arc<OwnedProcessDomains>>,
            resources: Option<Arc<dyn Send + Sync>>,
            capture: Option<&File>,
            window: LaunchWindow,
        ) -> Result<Self, StartFailure> {
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
                )
                .into());
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
            // CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT plus one safe
            // visibility mode; capture uses STARTUPINFOEX and is always hidden.
            let creation_flags = launch_creation_flags(window, capture.is_some());
            let success = unsafe {
                CreateProcessW(
                    application.as_ptr(),
                    command_line.as_mut_ptr(),
                    std::ptr::null(),
                    std::ptr::null(),
                    if capture.is_some() { 1 } else { 0 },
                    creation_flags,
                    environment.as_ptr() as *const c_void,
                    directory.as_ptr(),
                    &mut startup.startup,
                    &mut information,
                )
            };
            if success == 0 {
                return Err(std::io::Error::last_os_error().into());
            }
            let process = OwnedHandle(information.process as usize);
            let thread = OwnedHandle(information.thread as usize);
            let mut owned = Self {
                pid: information.process_id,
                process,
                job,
                in_job: false,
                _domain: None,
                _resources: resources,
            };
            if unsafe { AssignProcessToJobObject(owned.job.0.raw(), owned.process.raw()) } == 0 {
                return Err(StartFailure::after_create(
                    std::io::Error::last_os_error(),
                    Box::new(owned),
                ));
            }
            owned.in_job = true;
            let domain = if let Some(domains) = domains {
                let receipt = unsafe {
                    domains.register_native(
                        BorrowedHandle::borrow_raw(owned.process.raw()),
                        BorrowedHandle::borrow_raw(owned.job.0.raw()),
                        owned._resources.clone(),
                        OwnedDomainPurpose::ManagedConsole,
                    )
                };
                match receipt {
                    Ok(value) => Some(value),
                    Err(_) => {
                        return Err(StartFailure::after_create(
                            std::io::Error::other("Owned console registration failed"),
                            Box::new(owned),
                        ));
                    }
                }
            } else {
                None
            };
            owned._domain = domain;
            if unsafe { ResumeThread(thread.raw()) } != 1 {
                return Err(StartFailure::after_create(
                    std::io::Error::other("Could not resume owned terminal"),
                    Box::new(owned),
                ));
            }
            Ok(owned)
        }
        pub fn pid(&self) -> u32 {
            self.pid
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
            if self.has_exited()? {
                return Ok(());
            }
            let terminated = unsafe {
                if self.in_job {
                    TerminateJobObject(self.job.0.raw(), 1)
                } else {
                    TerminateProcess(self.process.raw(), 1)
                }
            };
            if terminated == 0 {
                if self.has_exited()? {
                    return Ok(());
                }
                return Err(std::io::Error::last_os_error());
            }
            let deadline = Instant::now() + Duration::from_secs(2);
            loop {
                if self.has_exited()? {
                    return Ok(());
                }
                if Instant::now() >= deadline {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        "Owned terminal has not exited",
                    ));
                }
                std::thread::sleep(Duration::from_millis(10));
            }
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
    impl OwnedProcess for OwnedConsole {
        fn has_exited(&mut self) -> std::io::Result<bool> {
            Self::has_exited(self)
        }
        fn stop(&mut self) -> std::io::Result<()> {
            Self::stop(self)
        }
        fn exit_success(&mut self) -> std::io::Result<bool> {
            Self::exit_success(self)
        }
    }

    #[cfg(test)]
    mod fake_cli_integration_tests {
        use super::*;
        use codexu_core::{
            automatic_switch::live::OwnedProcessDomains,
            local_cli::launch::Environment,
            workflow::official_arguments,
            workflow_reader::{WorkflowProbeLaunchFailure, WorkflowReadFailure},
        };
        use std::{
            fs, io,
            path::{Path, PathBuf},
            sync::{Arc, Mutex},
            time::{Duration, Instant},
        };

        #[link(name = "kernel32")]
        extern "system" {
            #[link_name = "OpenProcess"]
            fn open_process_raw(access: u32, inherit: i32, process_id: u32) -> Handle;
            #[link_name = "IsProcessInJob"]
            fn is_process_in_job_raw(process: Handle, job: Handle, result: *mut i32) -> i32;
        }

        const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
        const SYNCHRONIZE: u32 = 0x0010_0000;
        static UNCONFIRMED_TEST_OWNERS: std::sync::OnceLock<Mutex<Vec<Box<dyn OwnedProcess>>>> =
            std::sync::OnceLock::new();

        #[derive(Default)]
        struct Observations {
            root_registered_in_job: bool,
            child_registered_in_job: bool,
            job_count_with_both: u32,
            guard_held_with_both: bool,
            root_exited_while_child_active: bool,
            guard_held_after_root_exit: bool,
            job_empty_after_stop: bool,
            guard_held_after_stop: bool,
        }

        struct ProbeOwner {
            inner: OwnedConsole,
            child: Option<OwnedHandle>,
            child_pid: u32,
            control_dir: PathBuf,
            executable: PathBuf,
            observations: Arc<Mutex<Observations>>,
            root_exit_requested: bool,
        }

        fn writable_open_succeeds(path: &Path) -> bool {
            fs::OpenOptions::new().write(true).open(path).is_ok()
        }

        fn retain_unconfirmed_owner(owner: Box<dyn OwnedProcess>) {
            UNCONFIRMED_TEST_OWNERS
                .get_or_init(|| Mutex::new(Vec::new()))
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .push(owner);
        }

        fn open_process(process_id: u32) -> io::Result<OwnedHandle> {
            let handle = unsafe {
                open_process_raw(
                    PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
                    0,
                    process_id,
                )
            };
            if handle.is_null() {
                Err(io::Error::last_os_error())
            } else {
                Ok(OwnedHandle(handle as usize))
            }
        }

        fn is_process_in_job(process: Handle, job: Handle) -> io::Result<bool> {
            let mut member = 0;
            if unsafe { is_process_in_job_raw(process, job, &mut member) } == 0 {
                Err(io::Error::last_os_error())
            } else {
                Ok(member != 0)
            }
        }

        fn wait_for_pid(path: &Path) -> io::Result<u32> {
            let deadline = Instant::now() + Duration::from_secs(10);
            loop {
                if let Ok(value) = fs::read_to_string(path) {
                    if let Ok(process_id) = value.trim().parse() {
                        return Ok(process_id);
                    }
                }
                if Instant::now() >= deadline {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "fake CLI child PID was not written",
                    ));
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        }

        impl ProbeOwner {
            fn observe_initial_job(&mut self, child_pid_file: &Path) -> io::Result<()> {
                self.child_pid = wait_for_pid(child_pid_file)?;
                let child = open_process(self.child_pid)?;
                let root_member =
                    is_process_in_job(self.inner.process.raw(), self.inner.job.0.raw())?;
                let child_member = is_process_in_job(child.raw(), self.inner.job.0.raw())?;
                let count = self.inner.job.active_processes()?;
                let guard_held = !writable_open_succeeds(&self.executable);
                let domain_registered = self.inner._domain.is_some();
                *self
                    .observations
                    .lock()
                    .map_err(|_| io::Error::other("test observation lock poisoned"))? =
                    Observations {
                        root_registered_in_job: root_member && domain_registered,
                        child_registered_in_job: child_member,
                        job_count_with_both: count,
                        guard_held_with_both: guard_held,
                        ..Default::default()
                    };
                self.child = Some(child);
                if !root_member || !child_member || count < 2 || !guard_held || !domain_registered {
                    return Err(io::Error::other(
                        "fake CLI root/child were not retained in the registered Job",
                    ));
                }
                Ok(())
            }

            fn child_is_still_in_job(&self) -> io::Result<bool> {
                let child = self
                    .child
                    .as_ref()
                    .ok_or_else(|| io::Error::other("fake CLI child handle is missing"))?;
                is_process_in_job(child.raw(), self.inner.job.0.raw())
            }
        }

        impl OwnedProcess for ProbeOwner {
            fn has_exited(&mut self) -> io::Result<bool> {
                if !self.root_exit_requested {
                    fs::write(self.control_dir.join("exit-root"), b"exit")?;
                    self.root_exit_requested = true;
                    let deadline = Instant::now() + Duration::from_secs(5);
                    while unsafe { WaitForSingleObject(self.inner.process.raw(), 0) } != 0 {
                        if Instant::now() >= deadline {
                            return Err(io::Error::new(
                                io::ErrorKind::TimedOut,
                                "fake CLI root did not exit after the test marker",
                            ));
                        }
                        std::thread::sleep(Duration::from_millis(10));
                    }
                    // A Job may contain helper descendants; require the known child and a nonempty Job.
                    let child_observation_deadline = Instant::now() + Duration::from_secs(2);
                    loop {
                        let count = self.inner.job.active_processes()?;
                        let child_member = self.child_is_still_in_job()?;
                        let child_running = {
                            let child = self.child.as_ref().ok_or_else(|| {
                                io::Error::other("fake CLI child handle is missing")
                            })?;
                            match unsafe { WaitForSingleObject(child.raw(), 0) } {
                                0 => false,
                                258 => true,
                                _ => return Err(io::Error::last_os_error()),
                            }
                        };
                        let whole_job_empty = self.inner.has_exited()?;
                        let guard_held = !writable_open_succeeds(&self.executable);
                        let child_in_nonempty_job =
                            count > 0 && child_member && child_running && !whole_job_empty;
                        {
                            let mut observed = self
                                .observations
                                .lock()
                                .map_err(|_| io::Error::other("test observation lock poisoned"))?;
                            observed.root_exited_while_child_active = child_in_nonempty_job;
                            observed.guard_held_after_root_exit = guard_held;
                        }
                        if child_in_nonempty_job && guard_held {
                            break;
                        }
                        if !child_member
                            || !child_running
                            || whole_job_empty
                            || !guard_held
                            || Instant::now() >= child_observation_deadline
                        {
                            eprintln!(
                                "fake CLI owned Job root-exit check failed: active_processes={count} child_member={child_member} child_running={child_running} whole_job_empty={whole_job_empty} guard_held={guard_held}"
                            );
                            return Err(io::Error::other(format!(
                                "root exit did not preserve a live child in a nonempty Job; guard held={guard_held}"
                            )));
                        }
                        std::thread::sleep(Duration::from_millis(10));
                    }
                }
                self.inner.has_exited()
            }

            fn stop(&mut self) -> io::Result<()> {
                let guard_held_before = !writable_open_succeeds(&self.executable);
                // Protocol errors and timeouts reach stop while root and child
                // are both live. Terminate the owned Job for any membership
                // count, then require a positive empty-Job observation.
                self.inner.stop()?;
                let empty = self.inner.has_exited()?;
                let count = self.inner.job.active_processes()?;
                let guard_held = !writable_open_succeeds(&self.executable);
                {
                    let mut observed = self
                        .observations
                        .lock()
                        .map_err(|_| io::Error::other("test observation lock poisoned"))?;
                    observed.job_empty_after_stop = empty && count == 0;
                    observed.guard_held_after_stop = guard_held;
                }
                if !guard_held_before || !empty || count != 0 || !guard_held {
                    return Err(io::Error::other(
                        "stop did not confirm an empty Job or preserve the executable guard",
                    ));
                }
                Ok(())
            }

            fn exit_success(&mut self) -> io::Result<bool> {
                self.inner.exit_success()
            }
        }

        #[tokio::test]
        async fn reader_uses_registered_no_window_job_and_retains_guard_until_empty(
        ) -> anyhow::Result<()> {
            let executable = std::env::var_os("AIGB_WINDOWS_FAKECLI_PATH")
                .map(PathBuf::from)
                .ok_or_else(|| anyhow::anyhow!("AIGB_WINDOWS_FAKECLI_PATH is required"))?
                .canonicalize()?;
            anyhow::ensure!(executable.is_file(), "fake CLI executable does not exist");
            anyhow::ensure!(
                writable_open_succeeds(&executable),
                "test needs a writable build artifact for guard lock verification"
            );
            let root = tempfile::tempdir()?;
            let home = root.path().join("home");
            let workspace = root.path().join("workspace");
            let control_dir = root.path().join("control");
            std::fs::create_dir_all(&home)?;
            std::fs::create_dir_all(&workspace)?;
            std::fs::create_dir_all(&control_dir)?;
            let child_pid_file = control_dir.join("child.pid");
            let environment = Environment::codex(&home)?;
            let domains = OwnedProcessDomains::new();
            let observations = Arc::new(Mutex::new(Observations::default()));
            let launch_executable = executable.clone();
            let launch_workspace = workspace.clone();
            let launch_control = control_dir.clone();
            let launch_child_pid = child_pid_file.clone();
            let launch_domains = domains.clone();
            let launch_observations = observations.clone();

            let read = codexu_core::workflow_reader::read_evidence_with_owned_process(
                &workspace,
                Duration::from_secs(12),
                move |endpoint| -> std::result::Result<
                    Box<dyn OwnedProcess>,
                    WorkflowProbeLaunchFailure<Box<dyn OwnedProcess>>,
                > {
                    let guard = lock_executable(&launch_executable)
                        .map_err(WorkflowProbeLaunchFailure::before_spawn)?;
                    let mut args = official_arguments();
                    args.extend([
                        "app-server".into(),
                        "--listen".into(),
                        endpoint.to_owned(),
                        "--fixture-child-pid-file".into(),
                        launch_child_pid.to_string_lossy().into_owned(),
                        "--fixture-control-dir".into(),
                        launch_control.to_string_lossy().into_owned(),
                    ]);
                    let resources: Arc<dyn Send + Sync> = Arc::new(());
                    let inner = match OwnedConsole::start_registered_owned_with_window(
                        &launch_executable,
                        &launch_workspace,
                        &args,
                        guard,
                        &environment,
                        "Windows fake CLI owned-process integration",
                        Some(launch_domains),
                        Some(resources),
                        None,
                        LaunchWindow::NoWindow,
                    ) {
                        Ok(inner) => inner,
                        Err(failure) => {
                            let (error, owner) = failure.into_parts();
                            let Some(mut owner) = owner else {
                                return Err(WorkflowProbeLaunchFailure::before_spawn(error));
                            };
                            if owner.stop().is_ok() && owner.has_exited().unwrap_or(false) {
                                return Err(WorkflowProbeLaunchFailure::before_spawn(error));
                            }
                            return Err(WorkflowProbeLaunchFailure::after_spawn(error, owner));
                        }
                    };
                    let mut owner = ProbeOwner {
                        inner,
                        child: None,
                        child_pid: 0,
                        control_dir: launch_control,
                        executable: launch_executable,
                        observations: launch_observations,
                        root_exit_requested: false,
                    };
                    if let Err(error) = owner.observe_initial_job(&launch_child_pid) {
                        if owner.inner.stop().is_ok() && owner.inner.has_exited().unwrap_or(false) {
                            return Err(WorkflowProbeLaunchFailure::before_spawn(error));
                        }
                        return Err(WorkflowProbeLaunchFailure::after_spawn(
                            error,
                            Box::new(owner),
                        ));
                    }
                    Ok(Box::new(owner))
                },
            )
            .await;

            let evidence = match read {
                Ok(evidence) => evidence,
                Err(failure) => {
                    let (error, owner) = failure.into_parts();
                    if let Some(mut owner) = owner {
                        let stop_error = owner.stop().err();
                        match owner.has_exited() {
                            Ok(true) => {}
                            Ok(false) => {
                                let detail = stop_error.map_or_else(
                                    || "owner still reports a live Job".to_owned(),
                                    |error| format!("stop failed: {error}"),
                                );
                                retain_unconfirmed_owner(owner);
                                return Err(anyhow::anyhow!(
                                    "workflow read failed ({error}); cleanup unconfirmed ({detail}); owner retained"
                                ));
                            }
                            Err(confirm_error) => {
                                retain_unconfirmed_owner(owner);
                                return Err(anyhow::anyhow!(
                                    "workflow read failed ({error}); cleanup confirmation failed ({confirm_error}); owner retained"
                                ));
                            }
                        }
                    }
                    return Err(error.into());
                }
            };
            anyhow::ensure!(evidence.models.len() == 1);
            anyhow::ensure!(evidence.models[0].id == "windows-fake-model");
            anyhow::ensure!(evidence.official_plan_type() == Some("fixture-plan"));

            let observed = observations
                .lock()
                .map_err(|_| anyhow::anyhow!("test observation lock poisoned"))?;
            anyhow::ensure!(observed.root_registered_in_job);
            anyhow::ensure!(observed.child_registered_in_job);
            anyhow::ensure!(observed.job_count_with_both >= 2);
            anyhow::ensure!(observed.guard_held_with_both);
            anyhow::ensure!(observed.root_exited_while_child_active);
            anyhow::ensure!(observed.guard_held_after_root_exit);
            anyhow::ensure!(observed.job_empty_after_stop);
            anyhow::ensure!(observed.guard_held_after_stop);
            drop(observed);
            anyhow::ensure!(
                writable_open_succeeds(&executable),
                "executable guard remained held after the empty owner was dropped"
            );
            Ok(())
        }
    }
}

#[cfg(windows)]
pub use native::OwnedConsole;
#[cfg(not(windows))]
pub struct OwnedConsole;
#[cfg(not(windows))]
impl OwnedConsole {
    pub fn pid(&self) -> u32 {
        0
    }
    pub fn has_exited(&mut self) -> std::io::Result<bool> {
        Ok(true)
    }
    pub fn stop(&mut self) -> std::io::Result<()> {
        Ok(())
    }
    pub fn exit_success(&mut self) -> std::io::Result<bool> {
        Ok(false)
    }
    pub fn start_registered_owned(
        _: &Path,
        _: &Path,
        _: &[String],
        _: File,
        _: &codexu_core::local_cli::launch::Environment,
        _: &str,
        _: Option<Arc<OwnedProcessDomains>>,
        _: Option<Arc<dyn Send + Sync>>,
        _: Option<&File>,
    ) -> Result<Self, StartFailure> {
        Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "Windows required").into())
    }
    pub fn start_registered_owned_with_window(
        _: &Path,
        _: &Path,
        _: &[String],
        _: File,
        _: &codexu_core::local_cli::launch::Environment,
        _: &str,
        _: Option<Arc<OwnedProcessDomains>>,
        _: Option<Arc<dyn Send + Sync>>,
        _: Option<&File>,
        _: LaunchWindow,
    ) -> Result<Self, StartFailure> {
        Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "Windows required").into())
    }
}
#[cfg(not(windows))]
impl OwnedProcess for OwnedConsole {
    fn has_exited(&mut self) -> std::io::Result<bool> {
        OwnedConsole::has_exited(self)
    }
    fn stop(&mut self) -> std::io::Result<()> {
        OwnedConsole::stop(self)
    }
    fn exit_success(&mut self) -> std::io::Result<bool> {
        OwnedConsole::exit_success(self)
    }
}

impl codexu_core::workflow_reader::WorkflowProbeOwner for OwnedConsole {
    fn has_exited(&mut self) -> std::io::Result<bool> {
        OwnedProcess::has_exited(self)
    }
    fn stop(&mut self) -> std::io::Result<()> {
        OwnedProcess::stop(self)
    }
    fn exit_success(&mut self) -> std::io::Result<bool> {
        OwnedProcess::exit_success(self)
    }
}

impl codexu_core::workflow_reader::WorkflowProbeOwner for Box<dyn OwnedProcess> {
    fn has_exited(&mut self) -> std::io::Result<bool> {
        (**self).has_exited()
    }
    fn stop(&mut self) -> std::io::Result<()> {
        (**self).stop()
    }
    fn exit_success(&mut self) -> std::io::Result<bool> {
        (**self).exit_success()
    }
}

#[cfg(test)]
mod tests {
    use super::{launch_creation_flags, quote_argument, LaunchWindow, OwnedProcess, StartFailure};

    struct FakeOwner;
    impl OwnedProcess for FakeOwner {
        fn has_exited(&mut self) -> std::io::Result<bool> {
            Ok(false)
        }
        fn stop(&mut self) -> std::io::Result<()> {
            Err(std::io::Error::other("still owned"))
        }
        fn exit_success(&mut self) -> std::io::Result<bool> {
            Ok(false)
        }
    }

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

    #[test]
    fn launch_window_selects_only_safe_creation_modes_and_capture_stays_hidden() {
        assert_eq!(
            launch_creation_flags(LaunchWindow::Console, false),
            0x0000_0414
        );
        assert_eq!(
            launch_creation_flags(LaunchWindow::NoWindow, false),
            0x0800_0404
        );
        assert_eq!(
            launch_creation_flags(LaunchWindow::Console, true),
            0x0808_0404
        );
        assert_eq!(
            launch_creation_flags(LaunchWindow::NoWindow, true),
            0x0808_0404
        );
    }

    #[test]
    fn start_failure_has_no_owner_before_create_and_transfers_owner_after_create() {
        let before = StartFailure::from(std::io::Error::other("synthetic pre-create failure"));
        let (_, owner) = before.into_parts();
        assert!(owner.is_none());

        let after = StartFailure::after_create(
            std::io::Error::other("synthetic registration failure"),
            Box::new(FakeOwner),
        );
        let (_, owner) = after.into_parts();
        let mut owner = owner.unwrap();
        assert!(!owner.has_exited().unwrap());
        assert!(owner.stop().is_err());
        assert!(!owner.has_exited().unwrap());
    }

    #[test]
    fn boxed_owned_process_implements_workflow_probe_owner_contract() {
        let mut owner: Box<dyn OwnedProcess> = Box::new(FakeOwner);
        assert!(!codexu_core::workflow_reader::WorkflowProbeOwner::has_exited(&mut owner).unwrap());
        assert!(codexu_core::workflow_reader::WorkflowProbeOwner::stop(&mut owner).is_err());
    }
}
