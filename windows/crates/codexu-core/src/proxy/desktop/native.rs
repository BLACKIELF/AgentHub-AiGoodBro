use super::*;
use serde::Deserialize;
use std::{
    collections::BTreeMap,
    ffi::{c_void, OsStr, OsString},
    fs::OpenOptions,
    io::{Read, Seek, SeekFrom},
    os::windows::{ffi::OsStrExt, fs::OpenOptionsExt},
    process::{Command, Stdio},
};
type Handle = *mut c_void;
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
fn handle(value: Handle) -> Result<OwnedHandle, ProxyFailure> {
    if value.is_null() || value as isize == -1 {
        Err(ProxyFailure::DesktopLaunchFailed)
    } else {
        Ok(OwnedHandle(value as usize))
    }
}
#[repr(C)]
#[derive(Default)]
struct Basic {
    process_time: i64,
    job_time: i64,
    flags: u32,
    min_working: usize,
    max_working: usize,
    active: u32,
    affinity: usize,
    priority: u32,
    scheduling: u32,
}
#[repr(C)]
#[derive(Default)]
struct Io {
    a: u64,
    b: u64,
    c: u64,
    d: u64,
    e: u64,
    f: u64,
}
#[repr(C)]
#[derive(Default)]
struct Extended {
    basic: Basic,
    io: Io,
    process_memory: usize,
    job_memory: usize,
    peak_process: usize,
    peak_job: usize,
}
#[repr(C)]
#[derive(Default)]
struct Accounting {
    user: i64,
    kernel: i64,
    period_user: i64,
    period_kernel: i64,
    page_faults: u32,
    total: u32,
    active: u32,
    terminated: u32,
}
const _: [(); 48] = [(); std::mem::size_of::<Accounting>()];
const _: [(); 40] = [(); std::mem::offset_of!(Accounting, active)];
#[repr(C)]
struct Startup {
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
    startup: Startup,
    attributes: *mut c_void,
}
#[repr(C)]
struct ProcessInfo {
    process: Handle,
    thread: Handle,
    pid: u32,
    tid: u32,
}
#[link(name = "kernel32")]
unsafe extern "system" {
    fn SetInformationJobObject(job: Handle, class: i32, info: *const c_void, size: u32) -> i32;
    fn QueryInformationJobObject(
        job: Handle,
        class: i32,
        info: *mut c_void,
        size: u32,
        returned: *mut u32,
    ) -> i32;
    fn TerminateJobObject(job: Handle, code: u32) -> i32;
    fn WaitForSingleObject(handle: Handle, milliseconds: u32) -> u32;
    fn CloseHandle(handle: Handle) -> i32;
    fn CreateProcessW(
        application: *const u16,
        command: *mut u16,
        process_attributes: *const c_void,
        thread_attributes: *const c_void,
        inherit: i32,
        flags: u32,
        environment: *const c_void,
        directory: *const u16,
        startup: *mut Startup,
        information: *mut ProcessInfo,
    ) -> i32;
    fn ResumeThread(thread: Handle) -> u32;
    fn GetSystemDirectoryW(buffer: *mut u16, size: u32) -> u32;
    fn GetLastError() -> u32;
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
struct ProcessAttributes {
    storage: Vec<usize>,
    // UpdateProcThreadAttribute retains this pointer until Delete; a boxed
    // list stays stable even if ProcessAttributes moves before CreateProcess.
    _jobs: Box<[Handle; 1]>,
}
impl ProcessAttributes {
    fn for_job(job: Handle) -> Result<Self, ProxyFailure> {
        let mut size = 0;
        unsafe {
            InitializeProcThreadAttributeList(std::ptr::null_mut(), 1, 0, &mut size);
        }
        if size == 0 || size > 65536 {
            return Err(ProxyFailure::DesktopLaunchFailed);
        }
        let mut storage = vec![0usize; size.div_ceil(std::mem::size_of::<usize>())];
        if unsafe {
            InitializeProcThreadAttributeList(storage.as_mut_ptr() as *mut c_void, 1, 0, &mut size)
        } == 0
        {
            return Err(ProxyFailure::DesktopLaunchFailed);
        }
        let mut attributes = Self {
            storage,
            _jobs: Box::new([job]),
        };
        if unsafe {
            UpdateProcThreadAttribute(
                attributes.raw(),
                0,
                0x0002_000d,
                attributes._jobs.as_mut_ptr() as *mut c_void,
                std::mem::size_of::<Handle>(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        } == 0
        {
            return Err(ProxyFailure::DesktopLaunchFailed);
        }
        Ok(attributes)
    }
    fn raw(&mut self) -> *mut c_void {
        self.storage.as_mut_ptr() as *mut c_void
    }
}
impl Drop for ProcessAttributes {
    fn drop(&mut self) {
        unsafe {
            DeleteProcThreadAttributeList(self.raw());
        }
    }
}
struct OwnedDesktop {
    process: OwnedHandle,
    job: OwnedHandle,
}
impl DesktopProcess for OwnedDesktop {
    fn exited(&mut self) -> Result<bool, ProxyFailure> {
        let active = job_active_processes(self.job.raw())?;
        let wait = unsafe { WaitForSingleObject(self.process.raw(), 0) };
        if wait == u32::MAX {
            return Err(ProxyFailure::DesktopStateUnknown);
        }
        Ok(wait == 0 && active == 0)
    }
    fn terminate(&mut self) -> Result<(), ProxyFailure> {
        if unsafe { TerminateJobObject(self.job.raw(), 1) } == 0 {
            Err(ProxyFailure::CleanupUnconfirmed)
        } else {
            Ok(())
        }
    }
}
fn job_active_processes(job: Handle) -> Result<u32, ProxyFailure> {
    let mut info = Accounting::default();
    if unsafe {
        QueryInformationJobObject(
            job,
            1,
            &mut info as *mut _ as *mut c_void,
            std::mem::size_of_val(&info) as u32,
            std::ptr::null_mut(),
        )
    } == 0
    {
        Err(ProxyFailure::DesktopStateUnknown)
    } else {
        Ok(info.active)
    }
}
fn wide(value: &OsStr) -> Result<Vec<u16>, ProxyFailure> {
    let mut out: Vec<u16> = value.encode_wide().collect();
    if out.contains(&0) {
        return Err(ProxyFailure::Identity);
    }
    out.push(0);
    Ok(out)
}
fn environment(overrides: &[(String, String)]) -> Result<Vec<u16>, ProxyFailure> {
    let mut values: BTreeMap<String, (OsString, OsString)> = BTreeMap::new();
    for (name, value) in std::env::vars_os() {
        let upper = name.to_string_lossy().to_ascii_uppercase();
        if upper.is_empty()
            || upper.contains('=')
            || upper.starts_with("CODEX_APP_SERVER_")
            || matches!(
                upper.as_str(),
                "CODEX_HOME"
                    | "CODEX_CLI_PATH"
                    | "AIGOODBRO_PROXY_KEY"
                    | "AIGOODBRO_PROXY_CONNECTION_FILE"
                    | "OPENAI_API_KEY"
            )
        {
            continue;
        }
        values.insert(upper, (name, value));
    }
    for (name, value) in overrides {
        values.insert(name.to_ascii_uppercase(), (name.into(), value.into()));
    }
    let mut out = vec![];
    for (_, (name, value)) in values {
        let name = wide(&name)?;
        let value = wide(&value)?;
        out.extend_from_slice(&name[..name.len() - 1]);
        out.push('=' as u16);
        out.extend(value);
    }
    out.push(0);
    if out.len() > 32767 {
        return Err(ProxyFailure::DesktopLaunchFailed);
    }
    Ok(out)
}
pub(super) fn native_launch(
    app: &Path,
    overrides: &[(String, String)],
    receipts: &Path,
    claim: &DesktopWriterClaim,
) -> Result<Box<dyn DesktopProcess>, ProxyFailure> {
    launch_arguments(app, overrides, receipts, claim, &[])
}
#[cfg(test)]
pub(crate) fn launch_recovery_test_child(
    app: &Path,
    overrides: &[(String, String)],
    receipts: &Path,
    claim: &DesktopWriterClaim,
) -> Result<Box<dyn DesktopProcess>, ProxyFailure> {
    launch_arguments(
        app,
        overrides,
        receipts,
        claim,
        &[
            "--exact",
            "proxy::recovery::tests::recovery_waiting_child",
            "--ignored",
            "--nocapture",
        ],
    )
}
fn launch_arguments(
    app: &Path,
    overrides: &[(String, String)],
    receipts: &Path,
    claim: &DesktopWriterClaim,
    arguments: &[&str],
) -> Result<Box<dyn DesktopProcess>, ProxyFailure> {
    super::super::recovery::launching(receipts, "desktop", &claim.writer_id)?;
    let application = wide(app.as_os_str())?;
    let directory = wide(app.parent().ok_or(ProxyFailure::Identity)?.as_os_str())?;
    let mut command = vec!['"' as u16];
    command.extend_from_slice(&application[..application.len() - 1]);
    command.push('"' as u16);
    for argument in arguments {
        if !argument
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_-:".contains(&b))
        {
            return Err(ProxyFailure::DesktopLaunchFailed);
        }
        command.push(' ' as u16);
        command.extend(argument.encode_utf16());
    }
    command.push(0);
    let environment = environment(overrides)?;
    let nonce = super::super::recovery::nonce()?;
    let job_name = super::super::recovery::job_name("desktop", &claim.writer_id, &nonce);
    let job = handle(super::super::recovery::create_private_job(&job_name)? as Handle)?;
    let mut limits = Extended::default();
    limits.basic.flags = 0x2000;
    if unsafe {
        SetInformationJobObject(
            job.raw(),
            9,
            &limits as *const _ as *const c_void,
            std::mem::size_of_val(&limits) as u32,
        )
    } == 0
    {
        return Err(ProxyFailure::DesktopLaunchFailed);
    }
    let mut attributes = ProcessAttributes::for_job(job.raw())?;
    let mut startup: StartupEx = unsafe { std::mem::zeroed() };
    startup.startup.size = std::mem::size_of::<StartupEx>() as u32;
    startup.attributes = attributes.raw();
    let mut info: ProcessInfo = unsafe { std::mem::zeroed() };
    // Windows 10+ assigns the private Job during CreateProcess itself. A crash
    // between create and arm cannot leave an unowned suspended process. No
    // handles are inherited, and no app code runs before the receipt is armed.
    if unsafe {
        CreateProcessW(
            application.as_ptr(),
            command.as_mut_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            0,
            0x0008_0404,
            environment.as_ptr() as *const c_void,
            directory.as_ptr(),
            &mut startup.startup,
            &mut info,
        )
    } == 0
    {
        return Err(ProxyFailure::DesktopLaunchFailed);
    }
    let process = handle(info.process)?;
    let thread = handle(info.thread)?;
    let mut owned = OwnedDesktop { process, job };
    let armed = (|| {
        let created = super::super::recovery::process_created(owned.process.raw() as isize)?;
        super::super::recovery::arm(
            receipts,
            "desktop",
            &claim.writer_id,
            job_name,
            nonce,
            info.pid,
            created,
        )
    })();
    if armed.is_err() {
        let _ = owned.terminate();
        if unsafe { WaitForSingleObject(owned.process.raw(), 3000) } != 0 {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
        return Err(ProxyFailure::DesktopLaunchFailed);
    }
    if unsafe { ResumeThread(thread.raw()) } == u32::MAX {
        let _ = owned.terminate();
        let until = Instant::now() + Duration::from_secs(3);
        while Instant::now() < until {
            if owned.exited() == Ok(true) {
                return Err(ProxyFailure::DesktopLaunchFailed);
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        return Err(ProxyFailure::CleanupUnconfirmed);
    }
    Ok(Box::new(owned))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AppxCandidate {
    root: String,
    relative: String,
}
// The package identity is documented by OpenAI's Windows deployment guide.
// The manifest only discovers candidates; Authenticode/catalog verification
// and an executable read lock are required independently before launch.
const DISCOVERY: &str = r#"$ErrorActionPreference='Stop';[Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false);$out=@();$packages=@(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop);if($packages.Count -gt 4){throw 'ambiguous'};foreach($p in $packages){$m=Get-AppxPackageManifest -Package $p.PackageFullName -ErrorAction Stop;foreach($a in @($m.Package.Applications.Application)){if($a.Executable){$out+=@{root=[string]$p.InstallLocation;relative=[string]$a.Executable}}}};if($out.Count -gt 8){throw 'ambiguous'};ConvertTo-Json -InputObject @($out) -Compress -Depth 3"#;
fn powershell() -> Result<PinnedExecutable, ProxyFailure> {
    let mut buffer = vec![0u16; 4096];
    let n = unsafe { GetSystemDirectoryW(buffer.as_mut_ptr(), buffer.len() as u32) } as usize;
    if n == 0 || n >= buffer.len() {
        return Err(ProxyFailure::DesktopUnavailable);
    }
    let root = String::from_utf16(&buffer[..n]).map_err(|_| ProxyFailure::Identity)?;
    let path = Path::new(&root).join("WindowsPowerShell/v1.0/powershell.exe");
    let guard = OpenOptions::new()
        .read(true)
        .share_mode(1)
        .open(&path)
        .map_err(|_| ProxyFailure::DesktopUnavailable)?;
    let publisher = crate::readers::local_cli_quota::antigravity::publisher_of(&path)
        .ok_or(ProxyFailure::DesktopUnavailable)?;
    let publisher: String = publisher
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect();
    if !matches!(
        publisher.as_str(),
        "microsoftwindows" | "microsoftcorporation"
    ) {
        return Err(ProxyFailure::DesktopUnavailable);
    }
    Ok(PinnedExecutable {
        path,
        _guard: guard,
    })
}
pub(super) fn bundled_cli(app: &Path) -> Result<Option<PinnedExecutable>, ProxyFailure> {
    use std::collections::VecDeque;
    let root = app.parent().ok_or(ProxyFailure::DesktopUnavailable)?;
    let mut pending = VecDeque::from([(root.to_owned(), 0u8)]);
    let mut inspected = 0usize;
    let mut verified = vec![];
    while let Some((directory, depth)) = pending.pop_front() {
        if !crate::updates::safe_download_directory(&directory) {
            continue;
        }
        let entries = match std::fs::read_dir(&directory) {
            Ok(v) => v,
            Err(_) => continue,
        };
        for entry in entries {
            inspected += 1;
            if inspected > 8192 {
                return Err(ProxyFailure::DesktopUnavailable);
            }
            let Ok(entry) = entry else { continue };
            let Ok(meta) = entry.metadata() else { continue };
            use std::os::windows::fs::MetadataExt;
            if meta.file_attributes() & 0x400 != 0 {
                continue;
            }
            let path = entry.path();
            if meta.is_dir() {
                if depth < 4 {
                    pending.push_back((path, depth + 1));
                }
                continue;
            }
            if !meta.is_file()
                || path == app
                || !path.file_name().and_then(|v| v.to_str()).is_some_and(|v| {
                    v.eq_ignore_ascii_case("codex.exe") || v.eq_ignore_ascii_case("codex-cli.exe")
                })
            {
                continue;
            }
            let Ok(mut guard) = OpenOptions::new().read(true).share_mode(1).open(&path) else {
                continue;
            };
            let mut header = [0u8; 64];
            if guard.read_exact(&mut header).is_err() || &header[..2] != b"MZ" {
                continue;
            }
            let offset = u32::from_le_bytes(header[60..64].try_into().unwrap()) as u64;
            if offset > 16 * 1024 * 1024 || guard.seek(SeekFrom::Start(offset)).is_err() {
                continue;
            }
            let mut pe = [0u8; 6];
            if guard.read_exact(&mut pe).is_err() || &pe[..4] != b"PE\0\0" {
                continue;
            }
            let machine = u16::from_le_bytes([pe[4], pe[5]]);
            let expected = if cfg!(target_arch = "aarch64") {
                0xaa64
            } else {
                0x8664
            };
            if machine != expected {
                continue;
            }
            if require_official_publisher(&path).is_ok() {
                verified.push(PinnedExecutable {
                    path,
                    _guard: guard,
                });
            }
        }
    }
    if verified.len() > 1 {
        return Err(ProxyFailure::DesktopUnavailable);
    }
    Ok(verified.pop())
}
pub(super) fn native_discover(working: &Path) -> Result<PinnedExecutable, ProxyFailure> {
    use std::os::windows::process::CommandExt;
    let shell = powershell()?;
    let mut output =
        tempfile::NamedTempFile::new_in(working).map_err(|_| ProxyFailure::DesktopUnavailable)?;
    let mut command = Command::new(&shell.path);
    command
        .args(["-NoProfile", "-NonInteractive", "-Command", DISCOVERY])
        .stdin(Stdio::null())
        .stdout(Stdio::from(
            output
                .as_file()
                .try_clone()
                .map_err(|_| ProxyFailure::DesktopUnavailable)?,
        ))
        .stderr(Stdio::null())
        .creation_flags(0x0800_0000);
    if let Some(modules) = shell.path.parent().map(|p| p.join("Modules")) {
        command.env("PSModulePath", modules);
    }
    let mut child = command
        .spawn()
        .map_err(|_| ProxyFailure::DesktopUnavailable)?;
    let until = Instant::now() + Duration::from_secs(8);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                if !status.success() {
                    return Err(ProxyFailure::DesktopUnavailable);
                }
                break;
            }
            Ok(None) => {}
            Err(_) => {
                let _ = child.kill();
                return Err(ProxyFailure::DesktopStateUnknown);
            }
        }
        if Instant::now() >= until {
            let _ = child.kill();
            return Err(ProxyFailure::DesktopStateUnknown);
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    if output
        .as_file()
        .metadata()
        .map_err(|_| ProxyFailure::DesktopUnavailable)?
        .len()
        > 64 * 1024
    {
        return Err(ProxyFailure::DesktopUnavailable);
    }
    let mut data = vec![];
    output
        .as_file_mut()
        .seek(SeekFrom::Start(0))
        .map_err(|_| ProxyFailure::DesktopUnavailable)?;
    output
        .as_file_mut()
        .read_to_end(&mut data)
        .map_err(|_| ProxyFailure::DesktopUnavailable)?;
    if data.starts_with(&[0xef, 0xbb, 0xbf]) {
        data.drain(..3);
    }
    let candidates: Vec<AppxCandidate> =
        serde_json::from_slice(&data).map_err(|_| ProxyFailure::DesktopUnavailable)?;
    if candidates.is_empty() || candidates.len() > 8 {
        return Err(ProxyFailure::DesktopUnavailable);
    }
    let mut verified = vec![];
    for candidate in candidates {
        let root = PathBuf::from(candidate.root);
        let relative = PathBuf::from(candidate.relative);
        if !root.is_absolute()
            || relative.is_absolute()
            || relative
                .components()
                .any(|c| !matches!(c, std::path::Component::Normal(_)))
            || !crate::updates::safe_download_directory(&root)
        {
            continue;
        }
        let path = root.join(relative);
        if !path
            .extension()
            .and_then(|e| e.to_str())
            .is_some_and(|e| e.eq_ignore_ascii_case("exe"))
            || !crate::updates::safe_download_directory(path.parent().unwrap())
        {
            continue;
        }
        let Ok(meta) = std::fs::symlink_metadata(&path) else {
            continue;
        };
        use std::os::windows::fs::MetadataExt;
        if !meta.is_file() || meta.file_type().is_symlink() || meta.file_attributes() & 0x400 != 0 {
            continue;
        }
        let Ok(guard) = OpenOptions::new().read(true).share_mode(1).open(&path) else {
            continue;
        };
        if require_official_publisher(&path).is_err() {
            continue;
        }
        if !verified.iter().any(|p: &PinnedExecutable| p.path == path) {
            verified.push(PinnedExecutable {
                path,
                _guard: guard,
            });
        }
    }
    if verified.len() != 1 {
        return Err(ProxyFailure::DesktopUnavailable);
    }
    Ok(verified.remove(0))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "Windows native Job accounting with one held test child only"]
    fn actual_helper_windows_desktop_accounting_observes_running_then_empty_job() {
        use std::os::windows::io::AsRawHandle;
        #[link(name = "kernel32")]
        unsafe extern "system" {
            fn AssignProcessToJobObject(job: Handle, process: Handle) -> i32;
        }
        let directory = tempfile::tempdir().unwrap();
        let nonce = super::super::super::recovery::nonce().unwrap();
        let name = super::super::super::recovery::job_name("desktop", &"8".repeat(32), &nonce);
        let job =
            handle(super::super::super::recovery::create_private_job(&name).unwrap() as Handle)
                .unwrap();
        let mut limits = Extended::default();
        limits.basic.flags = 0x2000;
        assert_ne!(
            unsafe {
                SetInformationJobObject(
                    job.raw(),
                    9,
                    &limits as *const _ as *const c_void,
                    std::mem::size_of_val(&limits) as u32,
                )
            },
            0
        );
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "proxy::recovery::tests::recovery_waiting_child",
                "--ignored",
                "--nocapture",
            ])
            .env("AIGOODBRO_RECOVERY_TEST_ROLE", "hold")
            .env("AIGOODBRO_RECOVERY_TEST_ROOT", directory.path())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        if unsafe { AssignProcessToJobObject(job.raw(), child.as_raw_handle() as Handle) } == 0 {
            let _ = child.kill();
            let _ = child.wait();
            panic!("test child could not join its held Job");
        }
        assert!(child.try_wait().unwrap().is_none());
        assert_eq!(job_active_processes(job.raw()), Ok(1));
        assert_ne!(unsafe { TerminateJobObject(job.raw(), 1) }, 0);
        let until = Instant::now() + Duration::from_secs(3);
        while child.try_wait().unwrap().is_none() || job_active_processes(job.raw()).unwrap() != 0 {
            assert!(Instant::now() < until);
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(job_active_processes(job.raw()), Ok(0));
    }
    #[test]
    fn desktop_environment_removes_inherited_identity_overrides() {
        let block = environment(&[
            ("CODEX_HOME".into(), "synthetic-home".into()),
            ("CODEX_CLI_PATH".into(), "synthetic-helper".into()),
        ])
        .unwrap();
        let text = String::from_utf16(&block).unwrap();
        assert!(text.split('\0').any(|v| v == "CODEX_HOME=synthetic-home"));
        assert!(!text.split('\0').any(|v| v.starts_with("OPENAI_API_KEY=")));
        assert!(block.ends_with(&[0, 0]));
    }
    #[test]
    #[ignore = "requires freshly built AIGOODBRO_TEST_PROXY_HELPER; no GUI or real credentials"]
    fn actual_helper_desktop_suspended_job_confirms_all_owned_processes_exit() {
        let helper =
            PathBuf::from(std::env::var_os("AIGOODBRO_TEST_PROXY_HELPER").expect("fresh helper"));
        let directory = tempfile::tempdir().unwrap();
        let claim = DesktopWriterClaim {
            writer_id: "1".repeat(32),
            profile_id: "2".repeat(32),
            proxy_run_id: "3".repeat(32),
            identity_hash: "a".repeat(64),
            initial_generation: "4".repeat(32),
        };
        super::super::super::recovery::prepare_desktop(directory.path(), &claim).unwrap();
        let mut owned = native_launch(&helper, &[], directory.path(), &claim).unwrap();
        let until = Instant::now() + Duration::from_secs(5);
        while Instant::now() < until {
            if owned.exited().unwrap() {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        owned.terminate().unwrap();
        let until = Instant::now() + Duration::from_secs(3);
        while Instant::now() < until {
            if owned.exited().unwrap() {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("owned suspended job exit was not confirmed");
    }
}
