//! Private child process. A suspended process enters its kill-on-close job
//! before execution, inherits only explicitly listed stdio, and is never found
//! or killed by a caller-supplied PID.
use super::super::{fail, AccountResult};
use std::{
    ffi::{c_void, OsStr, OsString},
    fs::{File, OpenOptions},
    os::windows::{ffi::OsStrExt, fs::OpenOptionsExt},
    path::Path,
    sync::Arc,
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
struct StartupEx {
    startup: StartupInfo,
    attributes: *mut c_void,
}
#[repr(C)]
struct ProcessInfo {
    process: Handle,
    thread: Handle,
    process_id: u32,
    thread_id: u32,
}
#[repr(C)]
struct SecurityAttributes {
    length: u32,
    descriptor: *mut c_void,
    inherit: i32,
}
#[link(name = "kernel32")]
unsafe extern "system" {
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
    fn TerminateJobObject(job: Handle, code: u32) -> i32;
    fn WaitForSingleObject(handle: Handle, milliseconds: u32) -> u32;
    fn CloseHandle(handle: Handle) -> i32;
    fn CreatePipe(
        read: *mut Handle,
        write: *mut Handle,
        attributes: *const SecurityAttributes,
        size: u32,
    ) -> i32;
    fn SetHandleInformation(handle: Handle, mask: u32, flags: u32) -> i32;
    fn CreateFileW(
        path: *const u16,
        access: u32,
        sharing: u32,
        attributes: *const SecurityAttributes,
        disposition: u32,
        flags: u32,
        template: Handle,
    ) -> Handle;
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
    fn CreateProcessW(
        application: *const u16,
        command: *mut u16,
        process_attributes: *const c_void,
        thread_attributes: *const c_void,
        inherit: i32,
        flags: u32,
        environment: *const c_void,
        directory: *const u16,
        startup: *mut StartupInfo,
        information: *mut ProcessInfo,
    ) -> i32;
    fn ResumeThread(thread: Handle) -> u32;
    fn TerminateProcess(process: Handle, code: u32) -> i32;
    fn GetExitCodeProcess(process: Handle, code: *mut u32) -> i32;
    fn PeekNamedPipe(
        pipe: Handle,
        buffer: *mut c_void,
        size: u32,
        read: *mut u32,
        available: *mut u32,
        left: *mut u32,
    ) -> i32;
    fn ReadFile(
        file: Handle,
        buffer: *mut c_void,
        size: u32,
        read: *mut u32,
        overlapped: *mut c_void,
    ) -> i32;
    fn GetLastError() -> u32;
    fn IsProcessInJob(process: Handle, job: Handle, result: *mut i32) -> i32;
    fn CreateToolhelp32Snapshot(flags: u32, pid: u32) -> Handle;
    fn Process32FirstW(snapshot: Handle, entry: *mut ProcessEntry) -> i32;
    fn Process32NextW(snapshot: Handle, entry: *mut ProcessEntry) -> i32;
}
struct OwnedHandle(usize);
impl OwnedHandle {
    fn raw(&self) -> Handle {
        self.0 as Handle
    }
}
pub(in crate::accounts) struct VerificationReceipt {
    pub(super) process: Arc<OwnedHandle>,
    pub(super) job: Arc<OwnedHandle>,
    pub(super) _image: Arc<File>,
    pub(super) created: u64,
}
impl VerificationReceipt {
    pub(in crate::accounts) fn contains_process(
        &self,
        process: usize,
        observed_created: u64,
    ) -> AccountResult<bool> {
        if process == 0
            || observed_created < self.created
            || created(process as Handle)? != observed_created
            || created(self.process.raw())? != self.created
        {
            return Ok(false);
        }
        let mut value = 0;
        if unsafe { IsProcessInJob(process as Handle, self.job.raw(), &mut value) } == 0 {
            return Err(fail("verification_process_unavailable"));
        }
        Ok(value != 0)
    }
    pub(in crate::accounts) fn confirmed_empty(&self) -> AccountResult<bool> {
        let mut accounting = Accounting::default();
        if unsafe {
            QueryInformationJobObject(
                self.job.raw(),
                1,
                &mut accounting as *mut _ as *mut c_void,
                std::mem::size_of::<Accounting>() as u32,
                std::ptr::null_mut(),
            )
        } == 0
        {
            return Err(fail("verification_process_unavailable"));
        }
        Ok(accounting.active == 0 && unsafe { WaitForSingleObject(self.process.raw(), 0) } == 0)
    }
}
fn created(process: Handle) -> AccountResult<u64> {
    #[repr(C)]
    #[derive(Clone, Copy)]
    struct FileTime {
        low: u32,
        high: u32,
    }
    unsafe extern "system" {
        fn GetProcessTimes(
            process: Handle,
            created: *mut FileTime,
            exited: *mut FileTime,
            kernel: *mut FileTime,
            user: *mut FileTime,
        ) -> i32;
    }
    let mut times = [FileTime { low: 0, high: 0 }; 4];
    if unsafe {
        GetProcessTimes(
            process,
            times.as_mut_ptr(),
            times.as_mut_ptr().add(1),
            times.as_mut_ptr().add(2),
            times.as_mut_ptr().add(3),
        )
    } == 0
    {
        return Err(fail("verification_process_unavailable"));
    }
    Ok((u64::from(times[0].high) << 32) | u64::from(times[0].low))
}
impl Drop for OwnedHandle {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.raw());
        }
    }
}
fn handle(raw: Handle) -> AccountResult<OwnedHandle> {
    if raw.is_null() || raw as isize == -1 {
        return Err(fail("native_process_unavailable"));
    }
    Ok(OwnedHandle(raw as usize))
}
struct Attributes {
    _memory: Vec<usize>,
    pointer: *mut c_void,
}
impl Attributes {
    fn new(handles: &mut [Handle]) -> AccountResult<Self> {
        let mut length = 0;
        unsafe {
            InitializeProcThreadAttributeList(std::ptr::null_mut(), 1, 0, &mut length);
        }
        if length == 0 || length > 1024 * 1024 {
            return Err(fail("native_process_unavailable"));
        }
        let mut memory = vec![0usize; length.div_ceil(std::mem::size_of::<usize>())];
        let pointer = memory.as_mut_ptr() as *mut c_void;
        if unsafe { InitializeProcThreadAttributeList(pointer, 1, 0, &mut length) } == 0 {
            return Err(fail("native_process_unavailable"));
        }
        let value = Self {
            _memory: memory,
            pointer,
        };
        if unsafe {
            UpdateProcThreadAttribute(
                pointer,
                0,
                0x0002_0002,
                handles.as_mut_ptr() as *mut c_void,
                std::mem::size_of_val(handles),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        } == 0
        {
            return Err(fail("native_process_unavailable"));
        }
        Ok(value)
    }
}
impl Drop for Attributes {
    fn drop(&mut self) {
        unsafe {
            DeleteProcThreadAttributeList(self.pointer);
        }
    }
}
fn wide(value: &OsStr) -> AccountResult<Vec<u16>> {
    let mut result: Vec<_> = value.encode_wide().collect();
    if result.contains(&0) {
        return Err(fail("native_argument_invalid"));
    }
    result.push(0);
    Ok(result)
}
fn quoted(argument: &[u16]) -> Vec<u16> {
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
fn environment(home: &Path) -> AccountResult<Vec<u16>> {
    let mut entries: Vec<(OsString, OsString)> = std::env::vars_os()
        .filter(|(key, _)| {
            let key = key.to_string_lossy();
            !key.eq_ignore_ascii_case("CODEX_HOME")
                && !key.eq_ignore_ascii_case("RUST_LOG")
                && !crate::workflow::EXTERNAL_API_ENVIRONMENT
                    .iter()
                    .any(|blocked| key.eq_ignore_ascii_case(blocked))
        })
        .collect();
    entries.push(("CODEX_HOME".into(), home.as_os_str().to_owned()));
    entries.push(("RUST_LOG".into(), "off".into()));
    entries.sort_by_key(|(key, _)| key.to_string_lossy().to_uppercase());
    let mut output = Vec::new();
    for (mut key, value) in entries {
        key.push("=");
        key.push(value);
        output.extend(wide(&key)?);
    }
    output.push(0);
    if output.len() > 32767 {
        return Err(fail("native_environment_invalid"));
    }
    Ok(output)
}
pub(in crate::accounts) struct Child {
    process: Arc<OwnedHandle>,
    job: Arc<OwnedHandle>,
    pipe: OwnedHandle,
    _executable: Arc<File>,
    cleaned: bool,
    pid: u32,
    verification: Option<(
        super::super::OwnedVerificationProcess,
        Arc<dyn super::super::VerificationProcessPermit>,
    )>,
}
impl Child {
    pub(in crate::accounts) fn start(
        executable: &Path,
        home: &Path,
        args: &[String],
    ) -> AccountResult<Self> {
        Self::start_with_environment(executable, home, args, environment(home)?, None)
    }
    pub(in crate::accounts) fn start_for_verification(
        executable: &Path,
        home: &Path,
        args: &[String],
        permit: Arc<dyn super::super::VerificationProcessPermit>,
    ) -> AccountResult<Self> {
        permit.recheck()?;
        let publisher = crate::readers::local_cli_quota::antigravity::publisher_of(executable)
            .ok_or_else(|| fail("verification_process_untrusted"))?
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .flat_map(char::to_lowercase)
            .collect::<String>();
        if !matches!(publisher.as_str(), "openai" | "openaillc" | "openaiinc") {
            return Err(fail("verification_process_untrusted"));
        }
        let _spawn = permit.begin_spawn()?;
        Self::start_with_environment(executable, home, args, environment(home)?, Some(permit))
    }
    pub(in crate::accounts) fn start_claude(
        executable: &Path,
        home: &Path,
        args: &[String],
    ) -> AccountResult<Self> {
        let mut entries: Vec<(OsString, OsString)> = std::env::vars_os()
            .filter(|(key, _)| {
                let key = key.to_string_lossy().to_ascii_uppercase();
                !key.starts_with("CLAUDE_")
                    && !key.starts_with("ANTHROPIC_")
                    && !key.starts_with("AWS_")
                    && !key.starts_with("GOOGLE_")
                    && ![
                        "DISABLE_LOGIN_COMMAND",
                        "DISABLE_AUTOUPDATER",
                        "NODE_OPTIONS",
                        "BUN_OPTIONS",
                        "NODE_EXTRA_CA_CERTS",
                        "SSL_CERT_FILE",
                        "SSL_CERT_DIR",
                    ]
                    .contains(&key.as_str())
            })
            .collect();
        entries.extend([
            ("CLAUDE_CONFIG_DIR".into(), home.as_os_str().to_owned()),
            (
                "CLAUDE_SECURESTORAGE_CONFIG_DIR".into(),
                home.as_os_str().to_owned(),
            ),
            ("DISABLE_AUTOUPDATER".into(), "1".into()),
        ]);
        entries.sort_by_key(|(key, _)| key.to_string_lossy().to_uppercase());
        let mut env = Vec::new();
        for (mut key, value) in entries {
            key.push("=");
            key.push(value);
            env.extend(wide(&key)?);
        }
        env.push(0);
        if env.len() > 32767 {
            return Err(fail("native_environment_invalid"));
        }
        Self::start_with_environment(executable, home, args, env, None)
    }
    fn start_with_environment(
        executable: &Path,
        home: &Path,
        args: &[String],
        environment: Vec<u16>,
        permit: Option<Arc<dyn super::super::VerificationProcessPermit>>,
    ) -> AccountResult<Self> {
        let executable_guard = OpenOptions::new()
            .read(true)
            .share_mode(1)
            .open(executable)
            .map_err(|_| fail("cli_unavailable"))?;
        let job = handle(unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) })?;
        let mut limits = ExtendedLimits::default();
        limits.basic.flags = 0x0000_2000;
        if unsafe {
            SetInformationJobObject(
                job.raw(),
                9,
                &limits as *const _ as *const c_void,
                std::mem::size_of_val(&limits) as u32,
            )
        } == 0
        {
            return Err(fail("native_process_unavailable"));
        }
        let attributes = SecurityAttributes {
            length: std::mem::size_of::<SecurityAttributes>() as u32,
            descriptor: std::ptr::null_mut(),
            inherit: 1,
        };
        let mut read = std::ptr::null_mut();
        let mut write = std::ptr::null_mut();
        if unsafe { CreatePipe(&mut read, &mut write, &attributes, 0) } == 0 {
            return Err(fail("native_process_unavailable"));
        }
        let pipe = handle(read)?;
        let output = handle(write)?;
        if unsafe { SetHandleInformation(pipe.raw(), 1, 0) } == 0 {
            return Err(fail("native_process_unavailable"));
        }
        let nul = wide(OsStr::new("NUL"))?;
        let input = handle(unsafe {
            CreateFileW(
                nul.as_ptr(),
                0x8000_0000,
                3,
                &attributes,
                3,
                0x80,
                std::ptr::null_mut(),
            )
        })?;
        let mut inherited = [input.raw(), output.raw()];
        let attributes = Attributes::new(&mut inherited)?;
        let application = wide(executable.as_os_str())?;
        let directory = wide(home.as_os_str())?;
        let mut command = quoted(&application[..application.len() - 1]);
        for argument in args {
            let argument = wide(OsStr::new(argument))?;
            command.push(b' ' as u16);
            command.extend(quoted(&argument[..argument.len() - 1]));
        }
        command.push(0);
        if command.len() > 32767 {
            return Err(fail("native_argument_invalid"));
        }
        let mut startup: StartupEx = unsafe { std::mem::zeroed() };
        startup.startup.size = std::mem::size_of::<StartupEx>() as u32;
        startup.startup.flags = 0x101;
        startup.startup.stdin = input.raw();
        startup.startup.stdout = output.raw();
        startup.startup.stderr = output.raw();
        startup.attributes = attributes.pointer;
        let mut information: ProcessInfo = unsafe { std::mem::zeroed() };
        // CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT | UNICODE_ENV | SUSPENDED.
        if unsafe {
            CreateProcessW(
                application.as_ptr(),
                command.as_mut_ptr(),
                std::ptr::null(),
                std::ptr::null(),
                1,
                0x0808_0404,
                environment.as_ptr() as *const c_void,
                directory.as_ptr(),
                &mut startup.startup,
                &mut information,
            )
        } == 0
        {
            return Err(fail("native_process_unavailable"));
        }
        let process = handle(information.process)?;
        let thread = handle(information.thread)?;
        if unsafe { AssignProcessToJobObject(job.raw(), process.raw()) } == 0 {
            unsafe {
                TerminateProcess(process.raw(), 1);
            }
            if unsafe { WaitForSingleObject(process.raw(), 2000) } != 0 {
                return Err(fail("cleanup_unconfirmed"));
            }
            return Err(fail("native_process_unavailable"));
        }
        let mut child = Self {
            process: Arc::new(process),
            job: Arc::new(job),
            pipe,
            _executable: Arc::new(executable_guard),
            cleaned: false,
            pid: information.process_id,
            verification: None,
        };
        if let Some(permit) = permit {
            let receipt = super::super::OwnedVerificationProcess::native(VerificationReceipt {
                process: child.process.clone(),
                job: child.job.clone(),
                _image: child._executable.clone(),
                created: created(child.process.raw())?,
            });
            // No business instruction executes before this real held job has
            // entered the exact maintenance operation's private permit.
            if let Err(error) = permit.register(receipt.clone()) {
                child.stop_confirmed()?;
                return Err(error);
            }
            child.verification = Some((receipt, permit));
        }
        if unsafe { ResumeThread(thread.raw()) } != 1 {
            child.stop_confirmed()?;
            return Err(fail("native_process_unavailable"));
        }
        Ok(child)
    }
    pub(in crate::accounts) fn read_available(&mut self) -> AccountResult<Vec<u8>> {
        let mut available = 0;
        if unsafe {
            PeekNamedPipe(
                self.pipe.raw(),
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                &mut available,
                std::ptr::null_mut(),
            )
        } == 0
        {
            if unsafe { GetLastError() } == 109 {
                return Ok(Vec::new());
            }
            return Err(fail("native_output_unavailable"));
        }
        let mut bytes = vec![0u8; available.min(65536) as usize];
        if bytes.is_empty() {
            return Ok(bytes);
        }
        let mut read = 0;
        if unsafe {
            ReadFile(
                self.pipe.raw(),
                bytes.as_mut_ptr() as *mut c_void,
                bytes.len() as u32,
                &mut read,
                std::ptr::null_mut(),
            )
        } == 0
        {
            return Err(fail("native_output_unavailable"));
        }
        bytes.truncate(read as usize);
        Ok(bytes)
    }
    pub(in crate::accounts) fn pid(&self) -> u32 {
        self.pid
    }
    pub(in crate::accounts) fn exit_code(&self) -> AccountResult<Option<u32>> {
        match unsafe { WaitForSingleObject(self.process.raw(), 0) } {
            0 => {
                let mut code = 0;
                if unsafe { GetExitCodeProcess(self.process.raw(), &mut code) } == 0 {
                    return Err(fail("native_process_unavailable"));
                }
                Ok(Some(code))
            }
            258 => Ok(None),
            _ => Err(fail("native_process_unavailable")),
        }
    }
    pub(in crate::accounts) fn stop_confirmed(&mut self) -> AccountResult<()> {
        if self.cleaned {
            return Ok(());
        }
        unsafe {
            TerminateJobObject(self.job.raw(), 1);
        }
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            let mut accounting = Accounting::default();
            if unsafe {
                QueryInformationJobObject(
                    self.job.raw(),
                    1,
                    &mut accounting as *mut _ as *mut c_void,
                    std::mem::size_of::<Accounting>() as u32,
                    std::ptr::null_mut(),
                )
            } == 0
            {
                return Err(fail("cleanup_unconfirmed"));
            }
            if accounting.active == 0 && self.exit_code()?.is_some() {
                self.cleaned = true;
                if let Some((receipt, permit)) = &self.verification {
                    permit.completed(receipt)?;
                }
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        Err(fail("cleanup_unconfirmed"))
    }
}
impl Drop for Child {
    fn drop(&mut self) {
        let _ = self.stop_confirmed();
    }
}

#[repr(C)]
struct ProcessEntry {
    size: u32,
    usage: u32,
    pid: u32,
    default_heap: usize,
    module: u32,
    threads: u32,
    parent: u32,
    priority: i32,
    flags: u32,
    name: [u16; 260],
}
pub(in crate::accounts) fn require_codex_idle() -> AccountResult<()> {
    require_named_idle(&[
        "codex.exe",
        "codex-cli.exe",
        "codex-app-server.exe",
        "codex-desktop.exe",
        "codex-daemon.exe",
        "chatgpt.exe",
    ])
}
pub(in crate::accounts) fn require_claude_idle(additional: &[String]) -> AccountResult<()> {
    let mut names = vec![
        "claude.exe",
        "claude-code.exe",
        "cswap.exe",
        "claude-swap.exe",
        "node.exe",
        "bun.exe",
    ];
    names.extend(additional.iter().map(String::as_str));
    require_named_idle(&names)
}
fn require_named_idle(names: &[&str]) -> AccountResult<()> {
    let snapshot =
        handle(unsafe { CreateToolhelp32Snapshot(2, 0) }).map_err(|_| fail("occupancy_unknown"))?;
    let mut entry: ProcessEntry = unsafe { std::mem::zeroed() };
    entry.size = std::mem::size_of::<ProcessEntry>() as u32;
    if unsafe { Process32FirstW(snapshot.raw(), &mut entry) } == 0 {
        return Err(fail("occupancy_unknown"));
    }
    loop {
        let length = entry.name.iter().position(|c| *c == 0).unwrap_or(260);
        let name = String::from_utf16(&entry.name[..length])
            .map_err(|_| fail("occupancy_unknown"))?
            .to_ascii_lowercase();
        if names.contains(&name.as_str()) {
            return Err(fail(if matches!(name.as_str(), "node.exe" | "bun.exe") {
                "occupancy_unknown"
            } else {
                "account_busy"
            }));
        }
        if unsafe { Process32NextW(snapshot.raw(), &mut entry) } == 0 {
            if unsafe { GetLastError() } == 18 {
                return Ok(());
            }
            return Err(fail("occupancy_unknown"));
        }
    }
}

/// Bind the RPC transport to this exact owned CLI, not just an ephemeral port
/// somebody else could win between reservation and listen.
pub(in crate::accounts) fn owns_loopback_listener(pid: u32, port: u16) -> AccountResult<bool> {
    #[link(name = "iphlpapi")]
    unsafe extern "system" {
        fn GetExtendedTcpTable(
            table: *mut c_void,
            size: *mut u32,
            ordered: i32,
            family: u32,
            class: i32,
            reserved: u32,
        ) -> u32;
    }
    let mut size = 0;
    let code = unsafe { GetExtendedTcpTable(std::ptr::null_mut(), &mut size, 0, 2, 3, 0) };
    if code != 122 || !(4..=1024 * 1024).contains(&size) {
        return Err(fail("verification_owner_unknown"));
    }
    let mut data = vec![0u32; (size as usize).div_ceil(4)];
    if unsafe { GetExtendedTcpTable(data.as_mut_ptr() as *mut c_void, &mut size, 0, 2, 3, 0) } != 0
    {
        return Err(fail("verification_owner_unknown"));
    }
    let count = data[0] as usize;
    if count > (size as usize).saturating_sub(4) / 24 {
        return Err(fail("verification_owner_unknown"));
    }
    for row in data[1..1 + count * 6].chunks_exact(6) {
        if u16::from_be(row[2] as u16) == port {
            if row[0] != 2 || row[1].to_ne_bytes() != [127, 0, 0, 1] || row[5] != pid {
                return Err(fail("verification_owner_mismatch"));
            }
            return Ok(true);
        }
    }
    Ok(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn powershell() -> std::path::PathBuf {
        std::path::PathBuf::from(std::env::var_os("SystemRoot").expect("Windows SystemRoot"))
            .join("System32/WindowsPowerShell/v1.0/powershell.exe")
    }
    struct FixtureSpawn;
    impl super::super::super::VerificationSpawnLease for FixtureSpawn {}
    struct FixturePermit(std::sync::Mutex<Vec<super::super::super::OwnedVerificationProcess>>);
    impl super::super::super::VerificationProcessPermit for FixturePermit {
        fn recheck(&self) -> AccountResult<()> {
            Ok(())
        }
        fn begin_spawn(
            &self,
        ) -> AccountResult<Box<dyn super::super::super::VerificationSpawnLease>> {
            Ok(Box::new(FixtureSpawn))
        }
        fn register(
            &self,
            receipt: super::super::super::OwnedVerificationProcess,
        ) -> AccountResult<()> {
            // The root exists in its actual Job and is still suspended here.
            assert!(!receipt.confirmed_empty()?);
            self.0.lock().unwrap().push(receipt);
            Ok(())
        }
        fn completed(
            &self,
            receipt: &super::super::super::OwnedVerificationProcess,
        ) -> AccountResult<()> {
            assert!(receipt.confirmed_empty()?);
            assert!(self
                .0
                .lock()
                .unwrap()
                .iter()
                .any(|known| known.same(receipt)));
            Ok(())
        }
    }
    #[test]
    fn verification_receipt_uses_exact_held_job_and_birth_and_requires_positive_whole_job_exit() {
        let temp = tempfile::tempdir().unwrap();
        let permit = Arc::new(FixturePermit(std::sync::Mutex::new(Vec::new())));
        // This explicitly synthetic native fixture bypasses only the production
        // OpenAI publisher check to run a task-owned Windows PowerShell child.
        let mut child = Child::start_with_environment(
            &powershell(),
            temp.path(),
            &[
                "-NoProfile".into(),
                "-NonInteractive".into(),
                "-Command".into(),
                "Start-Sleep -Seconds 60".into(),
            ],
            environment(temp.path()).unwrap(),
            Some(permit.clone()),
        )
        .unwrap();
        let receipt = permit.0.lock().unwrap()[0].clone();
        let birth = created(child.process.raw()).unwrap();
        assert!(receipt
            .contains_process(child.process.raw() as usize, birth)
            .unwrap());
        assert!(!receipt
            .contains_process(child.process.raw() as usize, birth + 1)
            .unwrap());
        let mut independent = Child::start(
            &powershell(),
            temp.path(),
            &[
                "-NoProfile".into(),
                "-NonInteractive".into(),
                "-Command".into(),
                "Start-Sleep -Seconds 60".into(),
            ],
        )
        .unwrap();
        assert!(!receipt
            .contains_process(
                independent.process.raw() as usize,
                created(independent.process.raw()).unwrap()
            )
            .unwrap());
        assert!(!receipt.confirmed_empty().unwrap());
        child.stop_confirmed().unwrap();
        assert!(receipt.confirmed_empty().unwrap());
        independent.stop_confirmed().unwrap();
    }
    #[test]
    fn owned_process_captures_output_and_confirms_entire_job_exit() {
        let temp = tempfile::tempdir().unwrap();
        let mut child = Child::start(
            &powershell(),
            temp.path(),
            &[
                "-NoProfile".into(),
                "-NonInteractive".into(),
                "-Command".into(),
                "[Console]::WriteLine('SYNTHETIC_JOB_OUTPUT')".into(),
            ],
        )
        .unwrap();
        let start = Instant::now();
        let mut output = Vec::new();
        loop {
            output.extend(child.read_available().unwrap());
            if child.exit_code().unwrap().is_some() {
                output.extend(child.read_available().unwrap());
                break;
            }
            assert!(start.elapsed() < Duration::from_secs(15));
            std::thread::sleep(Duration::from_millis(10));
        }
        child.stop_confirmed().unwrap();
        assert!(String::from_utf8_lossy(&output).contains("SYNTHETIC_JOB_OUTPUT"));
    }
    #[test]
    #[ignore = "child-only fixture invoked by the owned Job cancellation test"]
    fn synthetic_job_tree_fixture() {
        use std::io::{BufRead, Write};
        use std::os::windows::io::AsRawHandle;
        use std::process::{Command, Stdio};
        if std::env::var("AIGOODBRO_NATIVE_JOB_FIXTURE_ROLE").as_deref() == Ok("descendant") {
            println!("\nSYNTHETIC_DESCENDANT_READY");
            std::io::stdout().flush().unwrap();
            std::thread::sleep(Duration::from_secs(60));
            return;
        }
        // Only the outer acceptance test creates this marker in its isolated
        // working directory. A normal --ignored invocation starts no child.
        let marker = std::env::current_dir()
            .unwrap()
            .join("synthetic-owned-job.fixture");
        let marker = match std::fs::read(marker) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return,
            Err(error) => panic!("synthetic fixture marker unavailable: {error}"),
        };
        assert_eq!(marker, b"owned job fixture");
        let mut descendant = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "accounts::native::process::tests::synthetic_job_tree_fixture",
                "--ignored",
                "--nocapture",
            ])
            .env("AIGOODBRO_NATIVE_JOB_FIXTURE_ROLE", "descendant")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("spawn synthetic descendant");
        let mut reader = std::io::BufReader::new(descendant.stdout.take().unwrap());
        loop {
            let mut line = String::new();
            assert!(
                reader.read_line(&mut line).unwrap() > 0,
                "synthetic descendant exited before readiness"
            );
            if line.trim() == "SYNTHETIC_DESCENDANT_READY" {
                break;
            }
        }
        assert!(descendant.try_wait().unwrap().is_none());
        println!(
            "\nSYNTHETIC_CHILD_STARTED {} {}",
            descendant.id(),
            created(descendant.as_raw_handle()).unwrap()
        );
        std::io::stdout().flush().unwrap();
        assert!(descendant.wait().unwrap().success());
    }

    #[test]
    fn cancelling_job_confirms_sleeping_descendants_are_gone_without_pid_kills() {
        #[link(name = "kernel32")]
        unsafe extern "system" {
            fn OpenProcess(access: u32, inherit: i32, pid: u32) -> Handle;
        }
        let temp = tempfile::tempdir().unwrap();
        std::fs::write(
            temp.path().join("synthetic-owned-job.fixture"),
            b"owned job fixture",
        )
        .unwrap();
        let mut child = Child::start(
            &std::env::current_exe().unwrap(),
            temp.path(),
            &[
                "--exact".into(),
                "accounts::native::process::tests::synthetic_job_tree_fixture".into(),
                "--ignored".into(),
                "--nocapture".into(),
            ],
        )
        .unwrap();
        let start = Instant::now();
        let mut output = Vec::new();
        let (pid, birth) = loop {
            output.extend(child.read_available().unwrap());
            assert!(output.len() <= 16384, "unexpected synthetic fixture output");
            if let Some(line) = output.split_inclusive(|b| *b == b'\n').find_map(|line| {
                line.strip_suffix(b"\n")?
                    .strip_prefix(b"SYNTHETIC_CHILD_STARTED ")
            }) {
                let fields: Vec<_> = std::str::from_utf8(line)
                    .unwrap()
                    .split_whitespace()
                    .collect();
                assert_eq!(fields.len(), 2, "invalid synthetic readiness receipt");
                break (
                    fields[0].parse::<u32>().unwrap(),
                    fields[1].parse::<u64>().unwrap(),
                );
            }
            assert!(
                child.exit_code().unwrap().is_none(),
                "fixture root exited before descendant readiness: {}",
                String::from_utf8_lossy(&output)
            );
            assert!(
                start.elapsed() < Duration::from_secs(15),
                "synthetic descendant readiness timeout: {}",
                String::from_utf8_lossy(&output)
            );
            std::thread::sleep(Duration::from_millis(10));
        };
        assert_ne!(pid, child.pid());
        // This read-only handle is pinned to the descendant's birth and the
        // exact owned Job. No process is terminated by an observed PID.
        let descendant = handle(unsafe { OpenProcess(0x0010_1000, 0, pid) }).unwrap();
        assert_eq!(created(descendant.raw()).unwrap(), birth);
        let mut member = 0;
        assert_ne!(
            unsafe { IsProcessInJob(descendant.raw(), child.job.raw(), &mut member) },
            0
        );
        assert_eq!(member, 1);
        assert_eq!(unsafe { WaitForSingleObject(descendant.raw(), 0) }, 258);
        child.stop_confirmed().unwrap();
        assert!(child.exit_code().unwrap().is_some());
        let mut accounting = Accounting::default();
        assert_ne!(
            unsafe {
                QueryInformationJobObject(
                    child.job.raw(),
                    1,
                    &mut accounting as *mut _ as *mut c_void,
                    std::mem::size_of::<Accounting>() as u32,
                    std::ptr::null_mut(),
                )
            },
            0
        );
        assert_eq!(accounting.active, 0);
        assert_eq!(unsafe { WaitForSingleObject(descendant.raw(), 2000) }, 0);
        child.stop_confirmed().unwrap();
        drop(descendant);
        drop(child);
        temp.close().unwrap();
    }
}
