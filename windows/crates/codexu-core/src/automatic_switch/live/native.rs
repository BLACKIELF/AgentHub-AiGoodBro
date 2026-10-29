//! Read-only Windows AF_UNIX peer authentication adapted from OpenAI Codex
//! f276b82185f021e7b8d532a3851413bc79a67594 codex-rs/uds. Apache-2.0,
//! see LICENSE.OpenAI-Codex and UPSTREAM.md. No daemon startup or ACL repair.
use super::{
    client::{self, Connection, Socket, VerifiedPeer},
    *,
};
use std::{
    ffi::c_void,
    fs::{File, OpenOptions},
    io,
    os::windows::{
        ffi::OsStrExt,
        fs::{MetadataExt, OpenOptionsExt},
        io::{AsRawHandle, AsRawSocket, AsSocket, BorrowedSocket, FromRawSocket, OwnedSocket},
    },
    path::{Path, PathBuf},
    ptr,
    sync::OnceLock,
    time::Duration,
};
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_util::compat::FuturesAsyncReadCompatExt;
#[path = "native_close.rs"]
mod close;
#[path = "native_inventory.rs"]
mod inventory;

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
    sid_start: u32,
}
#[repr(C)]
struct SockaddrUnix {
    family: u16,
    path: [u8; 108],
}
#[repr(C)]
struct PollFd {
    socket: usize,
    events: i16,
    returned: i16,
}
const _: [(); 110] = [(); std::mem::size_of::<SockaddrUnix>()];
const _: [(); 16] = [(); std::mem::size_of::<PollFd>()];
#[link(name = "ws2_32")]
unsafe extern "system" {
    fn WSAStartup(version: u16, data: *mut c_void) -> i32;
    fn WSASocketW(
        af: i32,
        kind: i32,
        protocol: i32,
        info: *const c_void,
        group: u32,
        flags: u32,
    ) -> usize;
    fn ioctlsocket(socket: usize, command: i32, argument: *mut u32) -> i32;
    #[link_name = "connect"]
    fn connect_socket(socket: usize, address: *const SockaddrUnix, length: i32) -> i32;
    fn WSAPoll(array: *mut PollFd, count: u32, timeout: i32) -> i32;
    fn getsockopt(socket: usize, level: i32, name: i32, value: *mut u8, length: *mut i32) -> i32;
    fn WSAGetLastError() -> i32;
    fn WSAIoctl(
        socket: usize,
        code: u32,
        input: *const c_void,
        input_length: u32,
        output: *mut c_void,
        output_length: u32,
        returned: *mut u32,
        overlapped: *mut c_void,
        callback: *const c_void,
    ) -> i32;
}
#[link(name = "kernel32")]
unsafe extern "system" {
    fn OpenProcess(access: u32, inherit: i32, pid: u32) -> Handle;
    fn GetCurrentProcess() -> Handle;
    fn GetSystemTimePreciseAsFileTime(time: *mut FileTime);
    fn CloseHandle(handle: Handle) -> i32;
    fn LocalFree(memory: *mut c_void) -> *mut c_void;
    fn GetProcessTimes(
        process: Handle,
        created: *mut FileTime,
        exited: *mut FileTime,
        kernel: *mut FileTime,
        user: *mut FileTime,
    ) -> i32;
    fn QueryFullProcessImageNameW(
        process: Handle,
        flags: u32,
        name: *mut u16,
        length: *mut u32,
    ) -> i32;
    fn WaitForSingleObject(process: Handle, timeout: u32) -> u32;
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
    fn EqualSid(a: *const c_void, b: *const c_void) -> i32;
    fn GetSecurityInfo(
        handle: Handle,
        kind: u32,
        info: u32,
        owner: *mut *mut c_void,
        group: *mut *mut c_void,
        dacl: *mut *mut Acl,
        sacl: *mut *mut Acl,
        descriptor: *mut *mut c_void,
    ) -> u32;
    fn GetSecurityDescriptorControl(
        descriptor: *const c_void,
        control: *mut u16,
        revision: *mut u32,
    ) -> i32;
    fn GetAce(acl: *const Acl, index: u32, ace: *mut *mut Ace) -> i32;
}
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
struct Local(*mut c_void);
impl Drop for Local {
    fn drop(&mut self) {
        unsafe {
            LocalFree(self.0);
        }
    }
}
fn token(process: Handle) -> LiveResult<OwnedHandle> {
    let mut handle = ptr::null_mut();
    if unsafe { OpenProcessToken(process, 8, &mut handle) } == 0 {
        return Err(LiveIssue::PeerUntrusted);
    }
    Ok(OwnedHandle(handle as usize))
}
fn token_user(token: Handle) -> LiveResult<Vec<u64>> {
    let mut needed = 0;
    unsafe {
        GetTokenInformation(token, 1, ptr::null_mut(), 0, &mut needed);
    }
    if needed < 8 || needed > 65_536 {
        return Err(LiveIssue::PeerUntrusted);
    }
    let mut user = vec![0u64; (needed as usize).div_ceil(8)];
    if unsafe { GetTokenInformation(token, 1, user.as_mut_ptr().cast(), needed, &mut needed) } == 0
    {
        return Err(LiveIssue::PeerUntrusted);
    }
    Ok(user)
}
fn sid(user: &[u64]) -> *const c_void {
    unsafe { *(user.as_ptr().cast::<*const c_void>()) }
}
fn not_elevated(token: Handle) -> LiveResult<()> {
    let mut elevated = 1u32;
    let mut needed = 0;
    if unsafe {
        GetTokenInformation(
            token,
            20,
            (&mut elevated as *mut u32).cast(),
            4,
            &mut needed,
        )
    } == 0
        || elevated != 0
    {
        return Err(LiveIssue::PeerUntrusted);
    }
    Ok(())
}
fn private_socket_directory(home: &Path) -> LiveResult<(PathBuf, File)> {
    // Do not create a missing directory and do not repair its permissions.
    let home = std::fs::canonicalize(home).map_err(|_| LiveIssue::Unavailable)?;
    let directory = home.join("app-server-control");
    let guard = OpenOptions::new()
        .read(true)
        .access_mode(0x0002_0081)
        .share_mode(1 | 2)
        .custom_flags(0x0220_0000)
        .open(&directory)
        .map_err(|_| LiveIssue::Unavailable)?;
    let metadata = guard.metadata().map_err(|_| LiveIssue::PeerUntrusted)?;
    if !metadata.is_dir() || metadata.file_attributes() & 0x400 != 0 {
        return Err(LiveIssue::PeerUntrusted);
    }
    let current = token(unsafe { GetCurrentProcess() })?;
    not_elevated(current.raw())?;
    let user = token_user(current.raw())?;
    let mut owner = ptr::null_mut();
    let mut dacl = ptr::null_mut();
    let mut descriptor = ptr::null_mut();
    if unsafe {
        GetSecurityInfo(
            guard.as_raw_handle().cast(),
            1,
            5,
            &mut owner,
            ptr::null_mut(),
            &mut dacl,
            ptr::null_mut(),
            &mut descriptor,
        )
    } != 0
    {
        return Err(LiveIssue::PeerUntrusted);
    }
    let _descriptor = Local(descriptor);
    let mut control = 0;
    let mut revision = 0;
    let mut ace = ptr::null_mut();
    let trusted = unsafe {
        !owner.is_null()
            && EqualSid(owner, sid(&user)) != 0
            && GetSecurityDescriptorControl(descriptor, &mut control, &mut revision) != 0
            && control & 0x1000 != 0
            && !dacl.is_null()
            && (*dacl).count == 1
            && GetAce(dacl, 0, &mut ace) != 0
            && !ace.is_null()
            && (*ace).kind == 0
            && (*ace).flags == 3
            && (*ace).mask == 0x001f_01ff
            && EqualSid(ptr::addr_of!((*ace).sid_start).cast(), sid(&user)) != 0
    };
    if !trusted {
        return Err(LiveIssue::PeerUntrusted);
    }
    Ok((directory.join("app-server-control.sock"), guard))
}
fn process_created(process: Handle) -> LiveResult<u64> {
    let mut times = [
        FileTime { low: 0, high: 0 },
        FileTime { low: 0, high: 0 },
        FileTime { low: 0, high: 0 },
        FileTime { low: 0, high: 0 },
    ];
    let p = times.as_mut_ptr();
    if unsafe { GetProcessTimes(process, p, p.add(1), p.add(2), p.add(3)) } == 0 {
        return Err(LiveIssue::PeerUntrusted);
    }
    Ok((u64::from(times[0].high) << 32) | u64::from(times[0].low))
}
fn peer_pid(socket: usize) -> LiveResult<u32> {
    let mut pid = 0u32;
    let mut returned = 0;
    if unsafe {
        WSAIoctl(
            socket,
            1_476_395_264,
            ptr::null(),
            0,
            (&mut pid as *mut u32).cast(),
            4,
            &mut returned,
            ptr::null_mut(),
            ptr::null(),
        )
    } == -1
        || pid == 0
    {
        return Err(LiveIssue::PeerUntrusted);
    }
    Ok(pid)
}
struct Peer {
    _directory: File,
    _image: File,
    process: OwnedHandle,
    created: u64,
    pid: u32,
    foreground: inventory::Foreground,
    inventory: inventory::Inventory,
}
fn recheck_process(process: Handle, created: u64) -> LiveResult<()> {
    if unsafe { WaitForSingleObject(process, 0) } != 258 || process_created(process)? != created {
        return Err(LiveIssue::PeerUntrusted);
    }
    Ok(())
}
impl VerifiedPeer for Peer {
    fn recheck(&self) -> LiveResult<()> {
        recheck_process(self.process.raw(), self.created)
    }
    fn activity(&self) -> LiveResult<super::activity::PeerActivity> {
        inventory::activity(self)
    }
    fn close_target(&self) -> LiveResult<Arc<dyn super::quiescence::CloseTarget>> {
        close::capture(self)
    }
}
fn process_image(process: Handle) -> LiveResult<PathBuf> {
    let mut name = vec![0u16; 32_768];
    let mut length = name.len() as u32;
    if unsafe { QueryFullProcessImageNameW(process, 0, name.as_mut_ptr(), &mut length) } == 0
        || length == 0
        || length as usize >= name.len()
    {
        return Err(LiveIssue::PeerUntrusted);
    }
    Ok(PathBuf::from(
        String::from_utf16(&name[..length as usize]).map_err(|_| LiveIssue::PeerUntrusted)?,
    ))
}
fn authenticate(
    socket: usize,
    directory: File,
    scope: &SystemDaemonScope,
    connect_started: u64,
) -> LiveResult<Peer> {
    let pid = peer_pid(socket)?;
    let process = unsafe { OpenProcess(0x0010_1000, 0, pid) };
    if process.is_null() {
        return Err(LiveIssue::PeerUntrusted);
    }
    let process = OwnedHandle(process as usize);
    let created = process_created(process.raw())?;
    let created_ms = created
        .checked_sub(116_444_736_000_000_000)
        .ok_or(LiveIssue::PeerUntrusted)?
        / 10_000;
    if created_ms < scope.established_at_unix_ms || created > connect_started {
        return Err(LiveIssue::ScopeUnverified);
    }
    let current = token(unsafe { GetCurrentProcess() })?;
    let remote = token(process.raw())?;
    not_elevated(current.raw())?;
    not_elevated(remote.raw())?;
    let a = token_user(current.raw())?;
    let b = token_user(remote.raw())?;
    if unsafe { EqualSid(sid(&a), sid(&b)) } == 0 {
        return Err(LiveIssue::PeerUntrusted);
    }
    let path = process_image(process.raw())?;
    if !crate::updates::safe_download_directory(path.parent().ok_or(LiveIssue::PeerUntrusted)?) {
        return Err(LiveIssue::PeerUntrusted);
    }
    let image = OpenOptions::new()
        .read(true)
        .share_mode(1)
        .custom_flags(0x0020_0000)
        .open(&path)
        .map_err(|_| LiveIssue::PeerUntrusted)?;
    let metadata = image.metadata().map_err(|_| LiveIssue::PeerUntrusted)?;
    if !metadata.is_file() || metadata.file_attributes() & 0x400 != 0 {
        return Err(LiveIssue::PeerUntrusted);
    }
    let publisher = crate::readers::local_cli_quota::antigravity::publisher_of(&path)
        .ok_or(LiveIssue::PeerUntrusted)?;
    let publisher = publisher
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect::<String>();
    if !matches!(publisher.as_str(), "openai" | "openaillc" | "openaiinc")
        || peer_pid(socket)? != pid
    {
        return Err(LiveIssue::PeerUntrusted);
    }
    let peer = Peer {
        _directory: directory,
        _image: image,
        process,
        created,
        pid,
        foreground: inventory::Foreground::new(pid)?,
        inventory: inventory::Inventory::default(),
    };
    peer.recheck()?;
    Ok(peer)
}
struct LocalStream(uds_windows::UnixStream);
impl AsSocket for LocalStream {
    fn as_socket(&self) -> BorrowedSocket<'_> {
        unsafe { BorrowedSocket::borrow_raw(self.0.as_raw_socket()) }
    }
}
impl io::Read for LocalStream {
    fn read(&mut self, b: &mut [u8]) -> io::Result<usize> {
        io::Read::read(&mut self.0, b)
    }
}
impl io::Write for LocalStream {
    fn write(&mut self, b: &[u8]) -> io::Result<usize> {
        io::Write::write(&mut self.0, b)
    }
    fn flush(&mut self) -> io::Result<()> {
        io::Write::flush(&mut self.0)
    }
}
unsafe impl async_io::IoSafe for LocalStream {}

async fn socket_connect(path: &Path, stop: &AtomicBool) -> LiveResult<uds_windows::UnixStream> {
    static STARTED: OnceLock<bool> = OnceLock::new();
    if !*STARTED.get_or_init(|| {
        let mut data = [0u64; 64];
        unsafe { WSAStartup(0x0202, data.as_mut_ptr().cast()) == 0 }
    }) {
        return Err(LiveIssue::Unavailable);
    }
    let text = path.to_str().ok_or(LiveIssue::Unavailable)?.as_bytes();
    if text.is_empty() || text.len() >= 108 || text.contains(&0) {
        return Err(LiveIssue::Unavailable);
    }
    let mut address = SockaddrUnix {
        family: 1,
        path: [0; 108],
    };
    address.path[..text.len()].copy_from_slice(text);
    // Match uds_windows' overlapped-capable socket for async-io/IOCP, while
    // retaining the local no-inherit restriction.
    let raw = unsafe { WSASocketW(1, 1, 0, ptr::null(), 0, 0x01 | 0x80) };
    if raw == usize::MAX {
        return Err(LiveIssue::Unavailable);
    }
    let socket = unsafe { OwnedSocket::from_raw_socket(raw as _) };
    let mut nonblocking = 1;
    if unsafe { ioctlsocket(raw, -2_147_195_266, &mut nonblocking) } != 0 {
        return Err(LiveIssue::Unavailable);
    }
    let result =
        unsafe { connect_socket(raw, &address, std::mem::size_of::<SockaddrUnix>() as i32) };
    if result != 0 && !matches!(unsafe { WSAGetLastError() }, 10_035 | 10_036 | 10_037) {
        return Err(LiveIssue::Unavailable);
    }
    if result != 0 {
        client::cancellable(stop, Duration::from_secs(5), async {
            loop {
                let mut descriptor = PollFd {
                    socket: raw,
                    events: 16,
                    returned: 0,
                };
                let ready = unsafe { WSAPoll(&mut descriptor, 1, 0) };
                if ready < 0 || descriptor.returned & 7 != 0 {
                    return Err(LiveIssue::Unavailable);
                }
                if ready > 0 && descriptor.returned & 16 != 0 {
                    let mut error = 1i32;
                    let mut length = 4;
                    if unsafe {
                        getsockopt(
                            raw,
                            65535,
                            4103,
                            (&mut error as *mut i32).cast(),
                            &mut length,
                        )
                    } != 0
                        || error != 0
                    {
                        return Err(LiveIssue::Unavailable);
                    }
                    break Ok(());
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await?;
    }
    use std::os::windows::io::IntoRawSocket;
    Ok(unsafe { uds_windows::UnixStream::from_raw_socket(socket.into_raw_socket()) })
}
pub(super) async fn connect(
    scope: &SystemDaemonScope,
    stop: Arc<AtomicBool>,
) -> LiveResult<Connection> {
    let (path, directory) = private_socket_directory(&scope.canonical_home)?;
    let mut started = FileTime { low: 0, high: 0 };
    unsafe {
        GetSystemTimePreciseAsFileTime(&mut started);
    }
    let started = (u64::from(started.high) << 32) | u64::from(started.low);
    let stream = socket_connect(&path, &stop).await?;
    let peer = authenticate(stream.as_raw_socket() as usize, directory, scope, started)?;
    // Nothing has been sent to the peer before kernel/token/image verification.
    let stream = async_io::Async::new(LocalStream(stream))
        .map_err(|_| LiveIssue::Unavailable)?
        .compat();
    let config = WebSocketConfig::default()
        .max_message_size(Some(MAXIMUM_MESSAGE_BYTES))
        .max_frame_size(Some(MAXIMUM_MESSAGE_BYTES));
    let (socket, response) = client::cancellable(&stop, Duration::from_secs(5), async {
        tokio_tungstenite::client_async_with_config(
            "ws://localhost/",
            Box::new(stream) as Socket,
            Some(config),
        )
        .await
        .map_err(|_| LiveIssue::Protocol)
    })
    .await?;
    if response
        .headers()
        .get("x-codex-app-server-compression")
        .is_some()
    {
        return Err(LiveIssue::Protocol);
    }
    let peer: Box<dyn VerifiedPeer> = Box::new(peer);
    peer.recheck()?;
    Ok(Connection { socket, peer })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::Read,
        process::{Child, Command, Stdio},
        time::Instant,
    };

    // An ordinary test invocation returns immediately. Only this test's own
    // child receives the private environment marker and waits for stdin EOF.
    #[test]
    fn native_process_exit_helper() {
        if std::env::var_os("AGB_OFFICIAL_LIVE_TEST_CHILD").is_none() {
            return;
        }
        std::io::stdin().read_to_end(&mut Vec::new()).unwrap();
    }

    struct OwnedTestChild(Child);
    impl Drop for OwnedTestChild {
        fn drop(&mut self) {
            // Only a child created by this fixture can reach this guard.
            if self.0.try_wait().ok().flatten().is_none() {
                let _ = self.0.kill();
            }
            let _ = self.0.wait();
        }
    }

    #[test]
    fn native_held_process_birth_and_positive_kernel_exit_are_distinct_from_disconnect() {
        let mut child = OwnedTestChild(
            Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "automatic_switch::live::native::tests::native_process_exit_helper",
                    "--test-threads=1",
                ])
                .env("AGB_OFFICIAL_LIVE_TEST_CHILD", "1")
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
        );
        let raw = unsafe { OpenProcess(0x0010_1000, 0, child.0.id()) };
        assert!(!raw.is_null());
        let process = OwnedHandle(raw as usize);
        let created = process_created(process.raw()).unwrap();
        assert!(created > 0);
        std::thread::sleep(Duration::from_millis(100));
        assert!(child.0.try_wait().unwrap().is_none());
        assert_eq!(unsafe { WaitForSingleObject(process.raw(), 0) }, 258);
        assert!(recheck_process(process.raw(), created).is_ok());
        assert_eq!(
            recheck_process(process.raw(), created + 1),
            Err(LiveIssue::PeerUntrusted)
        );

        drop(child.0.stdin.take());
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let result = unsafe { WaitForSingleObject(process.raw(), 0) };
            if result == 0 {
                break;
            }
            assert_eq!(result, 258);
            assert!(Instant::now() < deadline, "owned test child did not exit");
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(child.0.wait().unwrap().success());
        assert_eq!(process_created(process.raw()).unwrap(), created);
        assert_eq!(
            recheck_process(process.raw(), created),
            Err(LiveIssue::PeerUntrusted)
        );
    }

    #[test]
    fn native_missing_or_inherited_socket_directory_is_never_repaired_or_trusted() {
        let root = tempfile::tempdir().unwrap();
        assert!(private_socket_directory(root.path()).is_err());
        let directory = root.path().join("app-server-control");
        assert!(!directory.exists());
        std::fs::create_dir(&directory).unwrap();
        let before = std::fs::read_dir(&directory).unwrap().count();
        assert!(private_socket_directory(root.path()).is_err());
        assert_eq!(std::fs::read_dir(&directory).unwrap().count(), before);
        assert!(!directory.join("app-server-control.sock").exists());
    }
}
