use super::*;
use std::{
    io::{BufRead, BufReader, Read, Write},
    process::{Child, ChildStdin, ChildStdout, Command, Stdio},
    time::{Duration, Instant},
};

const SERVICE: &[u8] = include_bytes!("../../../../token-monitor/service.cjs");
const SOURCE: &[u8] = include_bytes!("../../../../../Companion/TokenMonitorEngine/SOURCE.json");
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Manifest {
    schema_version: u32,
    platform: String,
    #[serde(rename = "nodeSHA256")]
    node_sha256: String,
    #[serde(rename = "scannerSHA256")]
    scanner_sha256: String,
    #[serde(rename = "scannerPatchSHA256")]
    scanner_patch_sha256: String,
    #[serde(rename = "engineSourceSHA256")]
    engine_source_sha256: String,
    files: BTreeMap<String, String>,
}
fn safe_relative(value: &str) -> bool {
    !value.is_empty()
        && !value.contains(['\\', ':'])
        && !value.starts_with('/')
        && value
            .split('/')
            .all(|part| !part.is_empty() && part != "." && part != "..")
}
pub(super) struct HeldResources {
    _files: Vec<fs::File>,
}
fn reparse(meta: &fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        meta.file_attributes() & 0x400 != 0
    }
    #[cfg(not(windows))]
    {
        meta.file_type().is_symlink()
    }
}
fn hold(path: &Path, directory: bool) -> Result<fs::File> {
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options
            .share_mode(1)
            .custom_flags(0x00200000 | if directory { 0x02000000 } else { 0 });
    }
    let file = options
        .open(path)
        .map_err(|_| Failure("statistics_resources_unavailable"))?;
    let meta = file
        .metadata()
        .map_err(|_| Failure("statistics_resources_invalid"))?;
    if reparse(&meta) || directory && !meta.is_dir() || !directory && !meta.is_file() {
        return fail("statistics_resources_invalid");
    }
    Ok(file)
}
fn read_held(file: &mut fs::File, limit: u64) -> Result<Vec<u8>> {
    let meta = file
        .metadata()
        .map_err(|_| Failure("statistics_resources_invalid"))?;
    if !meta.is_file() || reparse(&meta) || meta.len() > limit {
        return fail("statistics_resources_invalid");
    }
    let mut bytes = Vec::new();
    file.take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Failure("statistics_resources_unavailable"))?;
    if bytes.len() as u64 > limit {
        return fail("statistics_resources_invalid");
    }
    Ok(bytes)
}
pub(super) fn verify_resources(root: &Path) -> Result<HeldResources> {
    for ancestor in root.ancestors() {
        let meta =
            fs::symlink_metadata(ancestor).map_err(|_| Failure("statistics_resources_invalid"))?;
        if reparse(&meta) {
            return fail("statistics_resources_invalid");
        }
    }
    let mut files = vec![hold(root, true)?];
    let mut manifest_file = hold(&root.join("WINDOWS-RESOURCES.json"), false)?;
    let bytes = read_held(&mut manifest_file, 2 * 1024 * 1024)?;
    files.push(manifest_file);
    // A manifest next to an executable cannot authenticate that executable.
    // The build embeds the digest only after the fixed-input stager succeeds.
    let trusted = option_env!("AIGOODBRO_TOKEN_MONITOR_RESOURCE_SHA256")
        .ok_or(Failure("statistics_resources_untrusted"))?;
    if trusted.len() != 64 || hash(&bytes) != trusted {
        return fail("statistics_resources_invalid");
    }
    let manifest: Manifest =
        serde_json::from_slice(&bytes).map_err(|_| Failure("statistics_resources_invalid"))?;
    let (platform, node) = if cfg!(target_arch = "aarch64") {
        (
            "win32-arm64",
            "97cce5301a815d2dce07ac5bfd1e6039eae88185ec1d10ae4f8cb712f1732878",
        )
    } else {
        (
            "win32-x64",
            "0d0f5e39f9f3d9587bc19f73eab3c2c9c4903fd02d6dbf9c853dd81b3d95fad4",
        )
    };
    if manifest.schema_version != 1
        || manifest.platform != platform
        || manifest.node_sha256 != node
        || manifest.scanner_patch_sha256 != SCANNER_PATCH
        || manifest.engine_source_sha256 != hash(SOURCE)
        || manifest.scanner_sha256.len() != 64
        || manifest.files.is_empty()
    {
        return fail("statistics_resources_invalid");
    }
    let frozen: Value =
        serde_json::from_slice(SOURCE).map_err(|_| Failure("statistics_resources_invalid"))?;
    let root_canon = root
        .canonicalize()
        .map_err(|_| Failure("statistics_resources_invalid"))?;
    let mut directories = BTreeSet::new();
    for rel in manifest.files.keys() {
        if !safe_relative(rel) {
            return fail("statistics_resources_invalid");
        }
        let mut parent = Path::new(rel).parent();
        while let Some(value) = parent {
            if !value.as_os_str().is_empty() {
                directories.insert(value.to_owned());
            }
            parent = value.parent();
        }
    }
    for directory in directories {
        files.push(hold(&root.join(directory), true)?);
    }
    for (rel, digest) in &manifest.files {
        if !safe_relative(rel)
            || digest.len() != 64
            || !digest.bytes().all(|b| b.is_ascii_hexdigit())
        {
            return fail("statistics_resources_invalid");
        }
        let path = root.join(rel);
        let resolved = path
            .canonicalize()
            .map_err(|_| Failure("statistics_resources_invalid"))?;
        let mut held = hold(&path, false)?;
        if !resolved.starts_with(&root_canon)
            || hash(&read_held(&mut held, 256 * 1024 * 1024)?) != *digest
        {
            return fail("statistics_resources_invalid");
        }
        files.push(held);
        if let Some(source_rel) = rel.strip_prefix("engine/") {
            if !source_rel.starts_with("vendor/")
                && source_rel != "SOURCE.json"
                && frozen["finalSource"]["files"][source_rel] != *digest
            {
                return fail("statistics_resources_invalid");
            }
        }
    }
    let scanner = format!(
        "engine/vendor/node_modules/@tokscale/cli-{}/bin/tokscale.exe",
        if platform == "win32-x64" {
            "win32-x64-msvc"
        } else {
            "win32-arm64-msvc"
        }
    );
    if manifest.files.get("runtime/node.exe") != Some(&manifest.node_sha256)
        || manifest.files.get(&scanner) != Some(&manifest.scanner_sha256)
        || manifest.files.get("service.cjs") != Some(&hash(SERVICE))
        || manifest.files.get("engine/SOURCE.json") != Some(&hash(SOURCE))
    {
        return fail("statistics_resources_invalid");
    }
    for required in [
        "engine/lib/handler.cjs",
        "engine/lib/collect.cjs",
        "engine/upstream/src/electron/renderer/tokenRatePresentation.js",
    ] {
        if !manifest.files.contains_key(required) {
            return fail("statistics_resources_invalid");
        }
    }
    Ok(HeldResources { _files: files })
}

#[derive(Clone)]
pub(super) struct CancelHandle {
    #[cfg(windows)]
    job: Arc<Job>,
}
impl CancelHandle {
    pub fn terminate(&self) {
        #[cfg(windows)]
        self.job.terminate();
    }
}
pub(super) struct OwnedRuntime {
    child: Child,
    stdin: Option<ChildStdin>,
    stdout: Option<ChildStdout>,
    _resources: Arc<HeldResources>,
    #[cfg(windows)]
    job: Arc<Job>,
}
impl OwnedRuntime {
    pub fn spawn(resources: &Path, data: &Path) -> Result<Self> {
        cleanup_unassigned(Duration::from_secs(2))?;
        let resources_held = Arc::new(verify_resources(resources)?);
        let home = data.join("runtime-home");
        let temp = data.join("tmp");
        for dir in [
            &home,
            &temp,
            &data.join("cache"),
            &home.join("AppData/Roaming"),
            &home.join("AppData/Local"),
        ] {
            fs::create_dir_all(dir).map_err(|_| Failure("statistics_cache_unavailable"))?;
        }
        let mut command = Command::new(resources.join("runtime/node.exe"));
        command
            .arg(resources.join("service.cjs"))
            .current_dir(&home)
            .env_clear()
            .env("HOME", &home)
            .env("USERPROFILE", &home)
            .env("APPDATA", home.join("AppData/Roaming"))
            .env("LOCALAPPDATA", home.join("AppData/Local"))
            .env("TEMP", &temp)
            .env("TMP", &temp)
            .env("TMPDIR", &temp)
            .env("PATH", "")
            .env("LANG", "en_US.UTF-8")
            .env("NODE_NO_WARNINGS", "1");
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            let system_root =
                std::env::var_os("SystemRoot").ok_or(Failure("statistics_unavailable"))?;
            command
                .env("SystemRoot", &system_root)
                .env("WINDIR", &system_root)
                .creation_flags(0x08000000);
        }
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let mut child = command
            .spawn()
            .map_err(|_| Failure("statistics_runtime_unavailable"))?;
        // The adapter cannot scan until the configure frame is sent. Assign its
        // owned Job before that frame, so no scanner can escape by racing spawn.
        #[cfg(windows)]
        let job = match Job::assign(&child) {
            Ok(job) => Arc::new(job),
            Err(error) => {
                let _ = child.kill();
                if !matches!(
                    bounded_child_exit(&mut child, Duration::from_secs(2)),
                    Ok(true)
                ) {
                    child.stdin.take();
                    child.stdout.take();
                    child.stderr.take();
                    retain_pending(Pending::Unassigned {
                        child,
                        _resources: resources_held,
                    });
                    return fail("statistics_cleanup_unconfirmed");
                }
                return Err(error);
            }
        };
        let stdin = child.stdin.take();
        let stdout = child.stdout.take();
        Ok(Self {
            child,
            stdin,
            stdout,
            _resources: resources_held,
            #[cfg(windows)]
            job,
        })
    }
    pub fn cancellation(&self) -> CancelHandle {
        CancelHandle {
            #[cfg(windows)]
            job: self.job.clone(),
        }
    }
    pub fn send(&mut self, request: &Value) -> Result<()> {
        let bytes =
            serde_json::to_vec(request).map_err(|_| Failure("invalid_statistics_settings"))?;
        if bytes.len() > 1024 * 1024 {
            return fail("invalid_statistics_settings");
        }
        let stdin = self
            .stdin
            .as_mut()
            .ok_or(Failure("statistics_runtime_exited"))?;
        stdin
            .write_all(&bytes)
            .and_then(|_| stdin.write_all(b"\n"))
            .and_then(|_| stdin.flush())
            .map_err(|_| Failure("statistics_runtime_exited"))
    }
    pub fn take_stdout(&mut self) -> Result<ChildStdout> {
        self.stdout
            .take()
            .ok_or(Failure("statistics_runtime_exited"))
    }
    pub fn exited(&mut self) -> Result<bool> {
        self.child
            .try_wait()
            .map(|s| s.is_some())
            .map_err(|_| Failure("statistics_unavailable"))
    }
    pub fn terminate_now(&mut self) {
        self.stdin.take();
        #[cfg(windows)]
        self.job.terminate();
        let _ = self.child.kill();
    }
    pub fn stop(&mut self) -> Result<()> {
        self.stdin.take();
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            if self.exited()? {
                #[cfg(windows)]
                {
                    self.job.terminate();
                    if !self.job.empty()? {
                        std::thread::sleep(Duration::from_millis(10));
                        continue;
                    }
                }
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        self.terminate_now();
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if self.exited()? {
                #[cfg(windows)]
                if !self.job.empty()? {
                    std::thread::sleep(Duration::from_millis(10));
                    continue;
                }
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        fail("statistics_cleanup_unconfirmed")
    }
}
impl Drop for OwnedRuntime {
    fn drop(&mut self) {
        self.terminate_now();
        let exited = matches!(
            bounded_child_exit(&mut self.child, Duration::from_secs(2)),
            Ok(true)
        );
        #[cfg(windows)]
        if !exited || !self.job.empty().unwrap_or(false) {
            retain_pending(Pending::Assigned {
                job: self.job.clone(),
                _resources: self._resources.clone(),
            });
        }
        #[cfg(not(windows))]
        let _ = exited;
    }
}
#[cfg(windows)]
enum Pending {
    Unassigned {
        child: Child,
        _resources: Arc<HeldResources>,
    },
    Assigned {
        job: Arc<Job>,
        _resources: Arc<HeldResources>,
    },
}
#[cfg(windows)]
static PENDING: Mutex<Vec<Pending>> = Mutex::new(Vec::new());
#[cfg(windows)]
fn retain_pending(pending: Pending) {
    PENDING
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .push(pending);
}
pub(super) fn has_pending() -> bool {
    #[cfg(windows)]
    {
        PENDING
            .lock()
            .map(|pending| !pending.is_empty())
            .unwrap_or(true)
    }
    #[cfg(not(windows))]
    {
        false
    }
}
pub(super) fn cleanup_unassigned(budget: Duration) -> Result<()> {
    #[cfg(windows)]
    {
        let deadline = Instant::now() + budget;
        loop {
            let mut pending = PENDING
                .lock()
                .map_err(|_| Failure("statistics_cleanup_unconfirmed"))?;
            pending.retain_mut(|entry| match entry {
                Pending::Unassigned { child, .. } => {
                    let _ = child.kill();
                    !child.try_wait().ok().flatten().is_some()
                }
                Pending::Assigned { job, .. } => {
                    job.terminate();
                    !job.empty().unwrap_or(false)
                }
            });
            if pending.is_empty() {
                return Ok(());
            }
            drop(pending);
            if Instant::now() >= deadline {
                return fail("statistics_cleanup_unconfirmed");
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    #[cfg(not(windows))]
    {
        let _ = budget;
        Ok(())
    }
}
fn bounded_child_exit(child: &mut Child, budget: Duration) -> Result<bool> {
    let deadline = Instant::now() + budget;
    loop {
        if child
            .try_wait()
            .map_err(|_| Failure("statistics_cleanup_unconfirmed"))?
            .is_some()
        {
            return Ok(true);
        }
        if Instant::now() >= deadline {
            return Ok(false);
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}
pub(super) fn read_events(
    stdout: impl Read,
    mut accept: impl FnMut(&[u8]) -> Result<()>,
) -> Result<()> {
    let mut reader = BufReader::new(stdout);
    loop {
        let mut line = Vec::new();
        let count = reader
            .by_ref()
            .take(MAX_RESPONSE as u64 + 1)
            .read_until(b'\n', &mut line)
            .map_err(|_| Failure("statistics_runtime_exited"))?;
        if count == 0 {
            return Ok(());
        }
        if line.len() > MAX_RESPONSE || line.last() != Some(&b'\n') {
            return fail("statistics_output_too_large");
        }
        accept(&line)?;
    }
}

#[cfg(windows)]
struct Job(isize);
#[cfg(windows)]
impl Job {
    fn assign(child: &Child) -> Result<Self> {
        use std::os::windows::io::AsRawHandle;
        #[repr(C)]
        #[derive(Default)]
        struct Basic {
            i: i64,
            j: i64,
            flags: u32,
            min: usize,
            max: usize,
            active: u32,
            affinity: usize,
            priority: u32,
            scheduling: u32,
        }
        #[repr(C)]
        #[derive(Default)]
        struct Extended {
            basic: Basic,
            io: [u64; 6],
            process_memory: usize,
            job_memory: usize,
            peak_process: usize,
            peak_job: usize,
        }
        #[link(name = "kernel32")]
        extern "system" {
            fn CreateJobObjectW(a: *const std::ffi::c_void, n: *const u16) -> isize;
            fn SetInformationJobObject(h: isize, c: i32, p: *const std::ffi::c_void, n: u32)
                -> i32;
            fn AssignProcessToJobObject(h: isize, p: isize) -> i32;
        }
        unsafe {
            let handle = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            if handle == 0 {
                return fail("statistics_job_unavailable");
            }
            let job = Self(handle);
            let mut info = Extended::default();
            info.basic.flags = 0x2000;
            if SetInformationJobObject(
                handle,
                9,
                &info as *const _ as _,
                std::mem::size_of::<Extended>() as u32,
            ) == 0
                || AssignProcessToJobObject(handle, child.as_raw_handle() as isize) == 0
            {
                return fail("statistics_job_unavailable");
            }
            Ok(job)
        }
    }
    fn terminate(&self) {
        #[link(name = "kernel32")]
        extern "system" {
            fn TerminateJobObject(h: isize, c: u32) -> i32;
        }
        unsafe {
            TerminateJobObject(self.0, 1);
        }
    }
    fn empty(&self) -> Result<bool> {
        #[repr(C)]
        #[derive(Default)]
        struct Accounting {
            a: i64,
            b: i64,
            c: i64,
            d: i64,
            faults: u32,
            total: u32,
            active: u32,
            terminated: u32,
        }
        // JOBOBJECT_BASIC_ACCOUNTING_INFORMATION has four LARGE_INTEGER and
        // four DWORD fields; ActiveProcesses is the third DWORD.
        const _: [(); 48] = [(); std::mem::size_of::<Accounting>()];
        #[link(name = "kernel32")]
        extern "system" {
            fn QueryInformationJobObject(
                h: isize,
                c: i32,
                p: *mut std::ffi::c_void,
                n: u32,
                r: *mut u32,
            ) -> i32;
        }
        let mut info = Accounting::default();
        unsafe {
            if QueryInformationJobObject(
                self.0,
                1,
                &mut info as *mut _ as _,
                std::mem::size_of::<Accounting>() as u32,
                std::ptr::null_mut(),
            ) == 0
            {
                return fail("statistics_cleanup_unconfirmed");
            }
        }
        Ok(info.active == 0)
    }
}
#[cfg(windows)]
impl Drop for Job {
    fn drop(&mut self) {
        #[link(name = "kernel32")]
        extern "system" {
            fn CloseHandle(h: isize) -> i32;
        }
        unsafe {
            CloseHandle(self.0);
        }
    }
}
#[cfg(windows)]
unsafe impl Send for Job {}
#[cfg(windows)]
unsafe impl Sync for Job {}

#[cfg(all(test, windows))]
mod native_tests {
    use super::*;
    use std::sync::mpsc;
    const FIXTURE: &str = "token_monitor::process::native_tests::child_fixture";
    #[test]
    #[ignore = "Owned child fixture; does nothing without its test-only marker"]
    fn child_fixture() {
        match std::env::var("AIGOODBRO_TM_TEST_CHILD").as_deref() {
            Ok("root") => {
                let mut gate = String::new();
                std::io::stdin().read_line(&mut gate).unwrap();
                if gate != "start\n" {
                    return;
                }
                let _child = Command::new(std::env::current_exe().unwrap())
                    .args(["--exact", FIXTURE, "--ignored", "--nocapture"])
                    .env("AIGOODBRO_TM_TEST_CHILD", "leaf")
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                    .unwrap();
                println!("owned-descendant-started");
                std::io::stdout().flush().unwrap();
            }
            Ok("leaf") => {}
            _ => return,
        }
        loop {
            std::thread::sleep(Duration::from_secs(1));
        }
    }
    struct ChildGuard(Child);
    impl Drop for ChildGuard {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = bounded_child_exit(&mut self.0, Duration::from_secs(2));
        }
    }
    #[test]
    #[ignore = "Windows owned Job/descendant fixture only; never controls an app"]
    fn owned_job_ends_its_descendants_and_leaves_unrelated_child_alive() {
        let mut unrelated = ChildGuard(
            Command::new(std::env::current_exe().unwrap())
                .args(["--exact", FIXTURE, "--ignored", "--nocapture"])
                .env("AIGOODBRO_TM_TEST_CHILD", "leaf")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
        );
        let mut owned = ChildGuard(
            Command::new(std::env::current_exe().unwrap())
                .args(["--exact", FIXTURE, "--ignored", "--nocapture"])
                .env("AIGOODBRO_TM_TEST_CHILD", "root")
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
        );
        let job = Job::assign(&owned.0).unwrap();
        owned
            .0
            .stdin
            .as_mut()
            .unwrap()
            .write_all(b"start\n")
            .unwrap();
        let stdout = owned.0.stdout.take().unwrap();
        let (send, receive) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                if line
                    .ok()
                    .is_some_and(|line| line.contains("owned-descendant-started"))
                {
                    let _ = send.send(());
                    return;
                }
            }
        });
        receive.recv_timeout(Duration::from_secs(10)).unwrap();
        assert!(!job.empty().unwrap());
        job.terminate();
        assert!(bounded_child_exit(&mut owned.0, Duration::from_secs(3)).unwrap());
        let deadline = Instant::now() + Duration::from_secs(3);
        while !job.empty().unwrap() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(job.empty().unwrap());
        assert!(unrelated.0.try_wait().unwrap().is_none());
    }
    #[test]
    #[ignore = "Windows file sharing fixture only"]
    fn held_resource_blocks_write_delete_and_replace_until_release() {
        let home = tempfile::tempdir().unwrap();
        let path = home.path().join("verified.cjs");
        fs::write(&path, b"verified bytes").unwrap();
        let directory = hold(home.path(), true).unwrap();
        let mut file = hold(&path, false).unwrap();
        assert_eq!(read_held(&mut file, 128).unwrap(), b"verified bytes");
        assert!(fs::OpenOptions::new().write(true).open(&path).is_err());
        assert!(fs::remove_file(&path).is_err());
        assert!(fs::rename(&path, home.path().join("replaced.cjs")).is_err());
        drop(file);
        drop(directory);
        fs::write(&path, b"released").unwrap();
    }
}
