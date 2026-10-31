//! Windows receiver inside the current App. No helper/model process is started.
//! An explicit native enable action binds this unsigned App's held executable;
//! runtime locator files never establish that trust by themselves.
use super::*;
use crate::{accounts::storage, runtime_setup::PinnedExecutable};
use std::{
    ffi::c_void,
    fs::{File, OpenOptions},
    io::{Read, Seek, SeekFrom},
    os::windows::{fs::OpenOptionsExt, io::AsRawHandle},
    path::{Path, PathBuf},
    ptr,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc,
    },
    thread::JoinHandle,
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::windows::named_pipe::{NamedPipeServer, ServerOptions},
};
type Handle = *mut c_void;
const SOURCE_FILE: &str = "app-source-v1.json";
const LOCATOR_FILE: &str = "receiver-v1.json";
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct FileTime {
    low: u32,
    high: u32,
}
#[repr(C)]
#[derive(Default)]
struct FileInfo {
    attributes: u32,
    created: FileTime,
    accessed: FileTime,
    written: FileTime,
    volume: u32,
    size_high: u32,
    size_low: u32,
    links: u32,
    index_high: u32,
    index_low: u32,
}
#[repr(C)]
struct Attributes {
    size: u32,
    descriptor: Handle,
    inherit: i32,
}
#[repr(C)]
struct Acl {
    revision: u8,
    reserved: u8,
    size: u16,
    count: u16,
    reserved2: u16,
}
#[repr(C)]
struct Ace {
    kind: u8,
    flags: u8,
    size: u16,
    mask: u32,
    sid: u32,
}
#[link(name = "kernel32")]
unsafe extern "system" {
    fn GetCurrentProcess() -> Handle;
    fn GetCurrentProcessId() -> u32;
    fn CloseHandle(handle: Handle) -> i32;
    fn LocalFree(handle: Handle) -> Handle;
    fn OpenProcess(access: u32, inherit: i32, pid: u32) -> Handle;
    fn GetProcessTimes(
        handle: Handle,
        created: *mut FileTime,
        exited: *mut FileTime,
        kernel: *mut FileTime,
        user: *mut FileTime,
    ) -> i32;
    fn WaitForSingleObject(handle: Handle, millis: u32) -> u32;
    fn ProcessIdToSessionId(pid: u32, session: *mut u32) -> i32;
    fn QueryFullProcessImageNameW(
        handle: Handle,
        flags: u32,
        path: *mut u16,
        size: *mut u32,
    ) -> i32;
    fn GetNamedPipeClientProcessId(pipe: Handle, pid: *mut u32) -> i32;
    fn GetFileInformationByHandle(file: Handle, info: *mut FileInfo) -> i32;
}
#[link(name = "advapi32")]
unsafe extern "system" {
    fn OpenProcessToken(handle: Handle, access: u32, token: *mut Handle) -> i32;
    fn GetTokenInformation(
        token: Handle,
        class: u32,
        buffer: *mut c_void,
        size: u32,
        needed: *mut u32,
    ) -> i32;
    fn EqualSid(a: *const c_void, b: *const c_void) -> i32;
    fn IsValidSid(sid: *const c_void) -> i32;
    fn ConvertSidToStringSidW(sid: *const c_void, text: *mut *mut u16) -> i32;
    fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
        text: *const u16,
        revision: u32,
        descriptor: *mut Handle,
        size: *mut u32,
    ) -> i32;
    fn GetSecurityInfo(
        object: Handle,
        kind: u32,
        info: u32,
        owner: *mut Handle,
        group: *mut Handle,
        dacl: *mut *mut Acl,
        sacl: *mut Handle,
        descriptor: *mut Handle,
    ) -> u32;
    fn IsValidAcl(acl: *const Acl) -> i32;
    fn GetAce(acl: *const Acl, index: u32, ace: *mut *mut Ace) -> i32;
    fn GetLengthSid(sid: *const c_void) -> u32;
    fn IsWellKnownSid(sid: *const c_void, kind: u32) -> i32;
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
struct Local(usize);
impl Drop for Local {
    fn drop(&mut self) {
        unsafe {
            LocalFree(self.0 as Handle);
        }
    }
}
fn unavailable() -> Error {
    fail("companion_native_unavailable")
}
fn untrusted() -> Error {
    fail("companion_peer_untrusted")
}
fn token(process: Handle) -> Result<Owned> {
    let mut h = ptr::null_mut();
    if unsafe { OpenProcessToken(process, 8, &mut h) } == 0 {
        return Err(untrusted());
    }
    Ok(Owned(h as usize))
}
fn user(token: Handle) -> Result<Vec<u64>> {
    let mut n = 0;
    unsafe {
        GetTokenInformation(token, 1, ptr::null_mut(), 0, &mut n);
    }
    if !(16..=65_536).contains(&n) {
        return Err(untrusted());
    }
    let mut b = vec![0u64; (n as usize).div_ceil(8)];
    if unsafe { GetTokenInformation(token, 1, b.as_mut_ptr().cast(), n, &mut n) } == 0 {
        return Err(untrusted());
    }
    if unsafe { IsValidSid(sid(&b)) } == 0 {
        return Err(untrusted());
    }
    Ok(b)
}
fn sid(user: &[u64]) -> *const c_void {
    unsafe { *(user.as_ptr().cast::<*const c_void>()) }
}
fn sid_text(user: &[u64]) -> Result<String> {
    let mut text = ptr::null_mut();
    if unsafe { ConvertSidToStringSidW(sid(user), &mut text) } == 0 {
        return Err(untrusted());
    }
    let _owner = Local(text as usize);
    let mut length = 0;
    while length < 184 && unsafe { *text.add(length) } != 0 {
        length += 1;
    }
    if length == 184 {
        return Err(untrusted());
    }
    String::from_utf16(unsafe { std::slice::from_raw_parts(text, length) }).map_err(|_| untrusted())
}
fn unelevated(token: Handle) -> Result<()> {
    let (mut value, mut n) = (1u32, 0);
    if unsafe { GetTokenInformation(token, 20, (&mut value as *mut u32).cast(), 4, &mut n) } == 0
        || value != 0
    {
        return Err(untrusted());
    }
    Ok(())
}
fn identity(process: Handle, pid: u32) -> Result<(String, u32)> {
    let current = token(unsafe { GetCurrentProcess() })?;
    let other = token(process)?;
    unelevated(current.raw())?;
    unelevated(other.raw())?;
    let a = user(current.raw())?;
    let b = user(other.raw())?;
    let (mut cs, mut ps) = (0, 0);
    if unsafe { EqualSid(sid(&a), sid(&b)) } == 0
        || unsafe { ProcessIdToSessionId(GetCurrentProcessId(), &mut cs) } == 0
        || unsafe { ProcessIdToSessionId(pid, &mut ps) } == 0
        || cs != ps
    {
        return Err(untrusted());
    }
    Ok((sid_text(&a)?, ps))
}
fn private_pipe(pipe: Handle) -> Result<()> {
    let token = token(unsafe { GetCurrentProcess() })?;
    let current = user(token.raw())?;
    let (mut owner, mut descriptor) = (ptr::null_mut(), ptr::null_mut());
    let mut acl = ptr::null_mut();
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
    let _descriptor = Local(descriptor as usize);
    if status != 0
        || owner.is_null()
        || acl.is_null()
        || unsafe { IsValidSid(owner) } == 0
        || unsafe { EqualSid(owner, sid(&current)) } == 0
        || unsafe { IsValidAcl(acl) } == 0
    {
        return Err(untrusted());
    }
    for index in 0..unsafe { (*acl).count } {
        let mut ace = ptr::null_mut();
        if unsafe { GetAce(acl, u32::from(index), &mut ace) } == 0 || ace.is_null() {
            return Err(untrusted());
        }
        let a = unsafe { &*ace };
        if a.size < 12 {
            return Err(untrusted());
        }
        if a.flags & 8 != 0 || a.kind == 1 {
            continue;
        }
        if a.kind != 0 {
            return Err(untrusted());
        }
        let s = (&a.sid as *const u32).cast();
        if unsafe { IsValidSid(s) } == 0 || 8 + unsafe { GetLengthSid(s) } > u32::from(a.size) {
            return Err(untrusted());
        }
        if a.mask != 0
            && unsafe { EqualSid(s, sid(&current)) } == 0
            && unsafe { IsWellKnownSid(s, 22) } == 0
        {
            return Err(untrusted());
        }
    }
    Ok(())
}
fn birth(process: Handle) -> Result<u64> {
    let mut times = [FileTime::default(); 4];
    let p = times.as_mut_ptr();
    if unsafe { GetProcessTimes(process, p, p.add(1), p.add(2), p.add(3)) } == 0 {
        return Err(untrusted());
    }
    Ok((u64::from(times[0].high) << 32) | u64::from(times[0].low))
}
fn image_path(process: Handle) -> Result<PathBuf> {
    let mut b = vec![0u16; 32768];
    let mut n = b.len() as u32;
    if unsafe { QueryFullProcessImageNameW(process, 0, b.as_mut_ptr(), &mut n) } == 0
        || n == 0
        || n as usize >= b.len()
    {
        return Err(untrusted());
    }
    let p = PathBuf::from(String::from_utf16(&b[..n as usize]).map_err(|_| untrusted())?);
    p.canonicalize().map_err(|_| untrusted())
}
fn local_image(path: &Path) -> Result<()> {
    let p = path.to_str().ok_or_else(untrusted)?;
    let p = p.strip_prefix(r"\\?\").unwrap_or(p);
    if p.len() < 3
        || !p.as_bytes()[0].is_ascii_alphabetic()
        || &p.as_bytes()[1..3] != b":\\"
        || path
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return Err(untrusted());
    }
    storage::ensure_no_links(path).map_err(|_| untrusted())
}
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Stamp {
    path: PathBuf,
    volume: u32,
    index: u64,
    length: u64,
    written: u64,
    sha256: String,
}
fn metadata(file: &File) -> Result<(u32, u64, u64, u64)> {
    let mut info = FileInfo::default();
    if unsafe { GetFileInformationByHandle(file.as_raw_handle().cast(), &mut info) } == 0
        || info.attributes & (0x400 | 0x10) != 0
        || info.links != 1
    {
        return Err(untrusted());
    }
    Ok((
        info.volume,
        (u64::from(info.index_high) << 32) | u64::from(info.index_low),
        (u64::from(info.size_high) << 32) | u64::from(info.size_low),
        (u64::from(info.written.high) << 32) | u64::from(info.written.low),
    ))
}
fn stamp(path: &Path, file: &mut File) -> Result<Stamp> {
    local_image(path)?;
    let before = metadata(file)?;
    if before.2 < 64 || before.2 > 512 * 1024 * 1024 {
        return Err(untrusted());
    }
    file.seek(SeekFrom::Start(0)).map_err(|_| untrusted())?;
    let mut header = [0; 2];
    file.read_exact(&mut header).map_err(|_| untrusted())?;
    if &header != b"MZ" {
        return Err(untrusted());
    }
    file.seek(SeekFrom::Start(0)).map_err(|_| untrusted())?;
    let mut sha = Sha256::new();
    let mut bytes = [0u8; 65536];
    let mut length = 0;
    loop {
        let n = file.read(&mut bytes).map_err(|_| untrusted())?;
        if n == 0 {
            break;
        }
        length += n;
        if length > 512 * 1024 * 1024 {
            return Err(untrusted());
        }
        sha.update(&bytes[..n]);
    }
    if length as u64 != before.2 || metadata(file)? != before {
        return Err(untrusted());
    }
    Ok(Stamp {
        path: path.into(),
        volume: before.0,
        index: before.1,
        length: before.2,
        written: before.3,
        sha256: format!("{:x}", sha.finalize()),
    })
}
fn hold_image(path: &Path) -> Result<File> {
    local_image(path)?;
    OpenOptions::new()
        .read(true)
        .share_mode(1)
        .custom_flags(0x00200000)
        .open(path)
        .map_err(|_| untrusted())
}
fn current_image() -> Result<(Stamp, File)> {
    let path = image_path(unsafe { GetCurrentProcess() })?;
    let mut file = hold_image(&path)?;
    let stamp = stamp(&path, &mut file)?;
    Ok((stamp, file))
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Source {
    schema: u32,
    role: String,
    abi: u32,
    image: Stamp,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Locator {
    schema: u32,
    role: String,
    abi: u32,
    pid: u32,
    birth: u64,
    session: u32,
    pipe: String,
    source_sha256: String,
    epoch: String,
}
fn write_private(path: &Path, value: &impl Serialize) -> Result<()> {
    let bytes = serde_json::to_vec(value).map_err(|_| unavailable())?;
    storage::atomic_write(path, &bytes).map_err(|_| unavailable())?;
    if storage::read_bound_optional(path, 16 * 1024, true)
        .map_err(|_| unavailable())?
        .as_deref()
        != Some(&bytes)
    {
        return Err(unavailable());
    }
    Ok(())
}

/// Native preparation only. The caller supplies its fixed App-data child;
/// no WebView path or caller-provided App identity is accepted upstream.
pub fn prepare_private_root(root: &Path) -> Result<PathBuf> {
    if !root.is_absolute()
        || root
            .components()
            .any(|p| matches!(p, std::path::Component::ParentDir))
    {
        return Err(unavailable());
    }
    if root.exists() {
        storage::check_existing_owned_path(root).map_err(|_| unavailable())?;
    }
    storage::secure_directory(root).map_err(|_| unavailable())?;
    let canonical = root.canonicalize().map_err(|_| unavailable())?;
    storage::check_existing_owned_path(&canonical).map_err(|_| unavailable())?;
    Ok(canonical)
}

/// Opaque proof of this running App's actual held executable, never serialized
/// to IPC. Merely inspecting it neither binds a source nor opens a receiver.
pub struct CurrentAppBinding {
    source: Source,
    image: File,
    fingerprint: String,
}
impl CurrentAppBinding {
    pub fn inspect() -> Result<Self> {
        identity(unsafe { GetCurrentProcess() }, unsafe {
            GetCurrentProcessId()
        })?;
        let (image, held) = current_image()?;
        let source = Source {
            schema: 1,
            role: "appSource".into(),
            abi: ABI,
            image,
        };
        let fingerprint = hash(&serde_json::to_vec(&source).map_err(|_| unavailable())?);
        Ok(Self {
            source,
            image: held,
            fingerprint,
        })
    }
    pub fn fingerprint(&self) -> &str {
        &self.fingerprint
    }
    pub fn verify(&self) -> Result<()> {
        let mut held = self.image.try_clone().map_err(|_| untrusted())?;
        if stamp(&self.source.image.path, &mut held)? != self.source.image
            || current_image()?.0 != self.source.image
        {
            return Err(fail("companion_source_changed"));
        }
        Ok(())
    }
    pub fn verify_bound(&self, root: &Path) -> Result<()> {
        self.verify()?;
        if source(root)?.1 != self.fingerprint {
            return Err(fail("companion_source_changed"));
        }
        Ok(())
    }
    /// Called only after the existing explicit install confirmation. Reuse the
    /// original native-current-image binding writer; no claimed image enters it.
    pub fn bind_confirmed(&self, root: &Path) -> Result<()> {
        self.verify()?;
        bind_current_app(root)?;
        self.verify_bound(root)
    }
}
/// Call only from the explicit local native enable/install confirmation. The
/// running App derives its own source; no caller path/hash is accepted.
pub fn bind_current_app(private_root: &Path) -> Result<()> {
    identity(unsafe { GetCurrentProcess() }, unsafe {
        GetCurrentProcessId()
    })?;
    let _lock = storage::StoreLock::acquire(private_root).map_err(|_| unavailable())?;
    let (image, _held) = current_image()?;
    write_private(
        &private_root.join(SOURCE_FILE),
        &Source {
            schema: 1,
            role: "appSource".into(),
            abi: ABI,
            image,
        },
    )
}
fn source(private_root: &Path) -> Result<(Source, String)> {
    let bytes = storage::read_bound_optional(&private_root.join(SOURCE_FILE), 16 * 1024, true)
        .map_err(|_| unavailable())?
        .ok_or_else(|| fail("companion_enable_required"))?;
    let s: Source = serde_json::from_slice(&bytes).map_err(|_| untrusted())?;
    if s.schema != 1 || s.abi != ABI || s.role != "appSource" || !digest(&s.image.sha256) {
        return Err(untrusted());
    }
    Ok((s, hash(&bytes)))
}
struct ProcessPin {
    process: Owned,
    image: File,
    stamp: Stamp,
    pid: u32,
    born: u64,
    session: u32,
    pipe: usize,
    deadline: Instant,
}
impl PeerGuard for ProcessPin {
    fn check(&self) -> Result<()> {
        private_pipe(self.pipe as Handle)?;
        let mut pid = 0;
        if Instant::now() >= self.deadline
            || unsafe { WaitForSingleObject(self.process.raw(), 0) } != 258
            || birth(self.process.raw())? != self.born
            || unsafe { GetNamedPipeClientProcessId(self.pipe as Handle, &mut pid) } == 0
            || pid != self.pid
            || identity(self.process.raw(), self.pid)?.1 != self.session
            || image_path(self.process.raw())? != self.stamp.path
            || metadata(&self.image)?
                != (
                    self.stamp.volume,
                    self.stamp.index,
                    self.stamp.length,
                    self.stamp.written,
                )
        {
            return Err(untrusted());
        }
        Ok(())
    }
}
fn authenticate(pipe: Handle, expected: &Stamp, deadline: Instant) -> Result<Peer> {
    private_pipe(pipe)?;
    let mut pid = 0;
    if unsafe { GetNamedPipeClientProcessId(pipe, &mut pid) } == 0 || pid == 0 {
        return Err(untrusted());
    }
    let h = unsafe { OpenProcess(0x00101000, 0, pid) };
    if h.is_null() {
        return Err(untrusted());
    }
    let process = Owned(h as usize);
    let (sid, session) = identity(process.raw(), pid)?;
    let born = birth(process.raw())?;
    let path = image_path(process.raw())?;
    if path != expected.path {
        return Err(untrusted());
    }
    // The expected selected interpreter file remains held without write/delete
    // sharing for the entire receiver lifetime. Matching file identity and
    // metadata therefore binds to its previously checked full digest.
    let image = hold_image(&path)?;
    if metadata(&image)?
        != (
            expected.volume,
            expected.index,
            expected.length,
            expected.written,
        )
    {
        return Err(untrusted());
    }
    let actor = hash_parts(&[
        "companion-local-actor",
        &sid,
        &session.to_string(),
        &expected.sha256,
    ]);
    Peer::from_native(
        actor,
        expected.sha256.clone(),
        Box::new(ProcessPin {
            process,
            image,
            stamp: expected.clone(),
            pid,
            born,
            session,
            pipe: pipe as usize,
            deadline,
        }),
    )
}
fn create_pipe(name: &str, sid: &str) -> Result<NamedPipeServer> {
    let text = format!("O:{sid}D:P(A;;GA;;;SY)(A;;GA;;;{sid})\0")
        .encode_utf16()
        .collect::<Vec<_>>();
    let mut descriptor = ptr::null_mut();
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            text.as_ptr(),
            1,
            &mut descriptor,
            ptr::null_mut(),
        )
    } == 0
    {
        return Err(unavailable());
    }
    let _descriptor = Local(descriptor as usize);
    let mut attrs = Attributes {
        size: std::mem::size_of::<Attributes>() as u32,
        descriptor,
        inherit: 0,
    };
    let pipe = unsafe {
        ServerOptions::new()
            .first_pipe_instance(true)
            .reject_remote_clients(true)
            .max_instances(1)
            .in_buffer_size(MAX_FRAME as u32 + 4)
            .out_buffer_size(MAX_FRAME as u32 + 4)
            .create_with_security_attributes_raw(name, (&mut attrs as *mut Attributes).cast())
    }
    .map_err(|_| fail("companion_receiver_busy"))?;
    private_pipe(pipe.as_raw_handle().cast())?;
    Ok(pipe)
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Response {
    abi: u32,
    request_id: String,
    result: Option<Reply>,
    issue_code: Option<&'static str>,
}
async fn one<B: Backend>(
    pipe: &mut NamedPipeServer,
    python: &Stamp,
    bridge: &Bridge<B>,
    stop: &AtomicBool,
) -> Result<()> {
    let end = tokio::time::Instant::now() + Duration::from_secs(10);
    let mut length = [0u8; 4];
    tokio::time::timeout_at(end, pipe.read_exact(&mut length))
        .await
        .map_err(|_| unavailable())?
        .map_err(|_| unavailable())?;
    let n = u32::from_le_bytes(length) as usize;
    if n == 0 || n > MAX_FRAME {
        return Err(fail("companion_invalid_frame"));
    }
    let mut frame = Vec::with_capacity(n + 4);
    frame.extend(length);
    frame.resize(n + 4, 0);
    tokio::time::timeout_at(end, pipe.read_exact(&mut frame[4..]))
        .await
        .map_err(|_| unavailable())?
        .map_err(|_| unavailable())?;
    let request = Request::decode(&frame)?;
    let id = request.request_id.clone();
    let deadline = Instant::now() + Duration::from_secs(30);
    let peer = authenticate(pipe.as_raw_handle().cast(), python, deadline)?;
    if stop.load(Ordering::Acquire) || Instant::now() >= deadline {
        return Err(unavailable());
    }
    // Synchronous on the receiver's OWN worker. A client disconnect or dropped
    // Tokio I/O future cannot cancel a partially submitted backend operation.
    let result = bridge.handle(&peer, request);
    let response = match result {
        Ok(v) => Response {
            abi: ABI,
            request_id: id,
            result: Some(v),
            issue_code: None,
        },
        Err(e) => Response {
            abi: ABI,
            request_id: id,
            result: None,
            issue_code: Some(e.code),
        },
    };
    let bytes = serde_json::to_vec(&response).map_err(|_| unavailable())?;
    if bytes.len() > MAX_FRAME {
        return Err(unavailable());
    }
    let mut frame = (bytes.len() as u32).to_le_bytes().to_vec();
    frame.extend(bytes);
    tokio::time::timeout(Duration::from_secs(3), pipe.write_all(&frame))
        .await
        .map_err(|_| unavailable())?
        .map_err(|_| unavailable())?;
    Ok(())
}
pub struct Receiver {
    stop: Arc<AtomicBool>,
    active: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
    #[cfg(test)]
    connected: Arc<AtomicBool>,
}
impl Receiver {
    // Test-only convenience. Production must retain the receiver even when its
    // readiness acknowledgement fails, through start_owned below.
    #[cfg(test)]
    pub fn start<B: Backend>(
        private_root: PathBuf,
        python: PinnedExecutable,
        bridge: Arc<Bridge<B>>,
    ) -> Result<Self> {
        Self::start_inner(private_root, python, bridge, None)
    }
    #[cfg(test)]
    fn start_inner<B: Backend>(
        private_root: PathBuf,
        python: PinnedExecutable,
        bridge: Arc<Bridge<B>>,
        fixture_name: Option<String>,
    ) -> Result<Self> {
        let (mut receiver, ready) =
            Self::start_owned_inner(private_root, python, bridge, fixture_name)?;
        if let Err(error) = ready {
            receiver.stop()?;
            return Err(error);
        }
        Ok(receiver)
    }
    /// Once a worker exists, always returns its owner alongside readiness.
    /// The caller must retain it until stop confirms the owned thread exited.
    /// Does not start the App, a Hub helper, a CLI, or any model process.
    pub fn start_owned<B: Backend>(
        private_root: PathBuf,
        python: PinnedExecutable,
        bridge: Arc<Bridge<B>>,
    ) -> Result<(Self, Result<()>)> {
        Self::start_owned_inner(private_root, python, bridge, None)
    }
    fn start_owned_inner<B: Backend>(
        private_root: PathBuf,
        mut python: PinnedExecutable,
        bridge: Arc<Bridge<B>>,
        fixture_name: Option<String>,
    ) -> Result<(Self, Result<()>)> {
        let (sid, session) = identity(unsafe { GetCurrentProcess() }, unsafe {
            GetCurrentProcessId()
        })?;
        let (source, source_hash) = source(&private_root)?;
        let (actual, app_image) = current_image()?;
        if source.image != actual {
            return Err(fail("companion_source_changed"));
        }
        let python_stamp = stamp(&python.path, &mut python.guard)?;
        let owner = storage::StoreLock::acquire(&private_root.join("receiver-owner"))
            .map_err(|_| fail("companion_receiver_busy"))?;
        let pid = unsafe { GetCurrentProcessId() };
        let born = birth(unsafe { GetCurrentProcess() })?;
        // The private locator is the only discovery mechanism. A fresh name
        // avoids ever probing/adopting a prior or unrelated App instance.
        let name = format!(r"\\.\pipe\AiGoodBro-companion-v1-{}", &nonce()?[..32]);
        #[cfg(not(test))]
        if fixture_name.is_some() {
            return Err(untrusted());
        }
        #[cfg(test)]
        let name = match fixture_name {
            Some(n)
                if n.starts_with(r"\\.\pipe\AiGoodBro-companion-v1-")
                    && n.rsplit('-').next().is_some_and(|s| {
                        s.len() == 32 && s.bytes().all(|b| b.is_ascii_hexdigit())
                    }) =>
            {
                n
            }
            Some(_) => return Err(untrusted()),
            None => name,
        };
        let stop = Arc::new(AtomicBool::new(false));
        let active = Arc::new(AtomicBool::new(true));
        #[cfg(test)]
        let connected = Arc::new(AtomicBool::new(false));
        #[cfg(test)]
        let entered = connected.clone();
        let (tx, rx) = mpsc::sync_channel(1);
        let cancel = stop.clone();
        let alive = active.clone();
        let worker = std::thread::spawn(move || {
            let _owner = owner;
            let _app = app_image;
            let _python = python;
            let result = (|| {
                let runtime = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .map_err(|_| unavailable())?;
                runtime.block_on(async {
                    let mut pipe = create_pipe(&name, &sid)?;
                    let locator = Locator {
                        schema: 1,
                        role: "runtimeLocator".into(),
                        abi: ABI,
                        pid,
                        birth: born,
                        session,
                        pipe: name.clone(),
                        source_sha256: source_hash,
                        epoch: nonce()?,
                    };
                    write_private(&private_root.join(LOCATOR_FILE), &locator)?;
                    if cancel.load(Ordering::Acquire) {
                        return Err(unavailable());
                    }
                    let _ = tx.send(Ok(()));
                    while !cancel.load(Ordering::Acquire) {
                        let _ = bridge.expire_unclaimed();
                        match tokio::time::timeout(Duration::from_millis(100), pipe.connect()).await
                        {
                            Err(_) => continue,
                            Ok(Err(_)) => return Err(unavailable()),
                            Ok(Ok(())) => {}
                        }
                        #[cfg(test)]
                        entered.store(true, Ordering::Release);
                        let _ = one(&mut pipe, &python_stamp, &bridge, &cancel).await;
                        #[cfg(test)]
                        entered.store(false, Ordering::Release);
                        // Disconnect only our pipe instance. Adopted task guards
                        // live in the App Hub and are unaffected by this handle.
                        pipe.disconnect().map_err(|_| unavailable())?;
                    }
                    Ok(())
                })
            })();
            let _ = bridge.close_preparing();
            if let Err(e) = result {
                let _ = tx.try_send(Err(e));
            }
            alive.store(false, Ordering::Release);
            // Stale locator is safe: client requires exact live PID/birth and
            // image binding. Never unlink a possibly replaced path on shutdown.
        });
        let ready = rx
            .recv_timeout(Duration::from_secs(3))
            .unwrap_or_else(|_| Err(unavailable()));
        if ready.is_err() {
            stop.store(true, Ordering::Release);
        }
        Ok((
            Self {
                stop,
                active,
                worker: Some(worker),
                #[cfg(test)]
                connected,
            },
            ready,
        ))
    }
    pub fn active(&self) -> bool {
        self.active.load(Ordering::Acquire)
    }
    pub fn stop(&mut self) -> Result<()> {
        self.stop.store(true, Ordering::Release);
        let end = Instant::now() + Duration::from_secs(3);
        if let Some(worker) = &self.worker {
            while !worker.is_finished() && Instant::now() < end {
                std::thread::sleep(Duration::from_millis(10));
            }
            if !worker.is_finished() {
                return Err(fail("companion_cleanup_unconfirmed"));
            }
        }
        if let Some(worker) = self.worker.take() {
            worker
                .join()
                .map_err(|_| fail("companion_cleanup_unconfirmed"))?;
        }
        Ok(())
    }
}
impl Drop for Receiver {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
    }
}

#[cfg(test)]
#[path = "native_tests.rs"]
pub(crate) mod native_tests;
