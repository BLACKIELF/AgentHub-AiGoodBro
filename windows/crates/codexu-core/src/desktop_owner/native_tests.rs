//! Real Windows pipes only under unpredictable fixture names. No production
//! endpoint, official App, account environment or model operation is touched.
use super::{
    native::win,
    protocol,
    tests::{discovery, handshake, ok, reply},
    *,
};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    ffi::c_void,
    os::windows::{ffi::OsStrExt, io::AsRawHandle},
    path::PathBuf,
    ptr,
};
use tokio::{
    io::AsyncWriteExt,
    net::windows::named_pipe::{ClientOptions, NamedPipeServer, ServerOptions},
};
const THREAD: &str = "00000000-0000-4000-8000-000000000001";
const CLIENT: &str = "00000000-0000-4000-8000-000000000002";
const OWNER: &str = "00000000-0000-4000-8000-000000000003";
const TURN: &str = "00000000-0000-4000-8000-000000000004";
const OP: &str = "00000000-0000-4000-8000-000000000005";
const TIME: Duration = Duration::from_secs(3);
type Handle = *mut c_void;
#[repr(C)]
struct SA {
    size: u32,
    descriptor: *mut c_void,
    inherit: i32,
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
    fn ConvertSidToStringSidW(sid: *const c_void, text: *mut *mut u16) -> i32;
    fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
        text: *const u16,
        revision: u32,
        descriptor: *mut *mut c_void,
        size: *mut u32,
    ) -> i32;
    fn CreateRestrictedToken(
        token: Handle,
        flags: u32,
        disable_count: u32,
        disable: *const c_void,
        delete_count: u32,
        delete: *const c_void,
        restrict_count: u32,
        restrict: *const c_void,
        result: *mut Handle,
    ) -> i32;
    fn CreateProcessWithTokenW(
        token: Handle,
        logon: u32,
        application: *const u16,
        command: *mut u16,
        flags: u32,
        environment: *const c_void,
        directory: *const u16,
        startup: *mut Startup,
        info: *mut ProcessInfo,
    ) -> i32;
}
#[link(name = "kernel32")]
unsafe extern "system" {
    fn GetCurrentProcess() -> Handle;
    fn CloseHandle(h: Handle) -> i32;
    fn LocalFree(p: *mut c_void) -> *mut c_void;
    fn WaitForSingleObject(h: Handle, ms: u32) -> u32;
    fn GetExitCodeProcess(h: Handle, code: *mut u32) -> i32;
    fn TerminateProcess(h: Handle, code: u32) -> i32;
    fn CreateJobObjectW(sa: *const c_void, name: *const u16) -> Handle;
    fn SetInformationJobObject(h: Handle, class: i32, data: *const c_void, size: u32) -> i32;
    fn AssignProcessToJobObject(job: Handle, process: Handle) -> i32;
    fn QueryInformationJobObject(
        job: Handle,
        class: i32,
        data: *mut c_void,
        size: u32,
        returned: *mut u32,
    ) -> i32;
    fn ResumeThread(thread: Handle) -> u32;
}
struct Owned(Handle);
impl Drop for Owned {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}
fn token() -> Owned {
    let mut h = ptr::null_mut();
    assert_ne!(
        unsafe { OpenProcessToken(GetCurrentProcess(), 0x000b, &mut h) },
        0,
        "open fixture token: {}",
        std::io::Error::last_os_error()
    );
    Owned(h)
}
fn elevated(h: Handle) -> bool {
    let (mut v, mut n) = (1u32, 0);
    assert_ne!(
        unsafe { GetTokenInformation(h, 20, (&mut v as *mut u32).cast(), 4, &mut n) },
        0
    );
    v != 0
}
fn sid_string() -> String {
    let t = token();
    let mut n = 0;
    unsafe {
        GetTokenInformation(t.0, 1, ptr::null_mut(), 0, &mut n);
    };
    assert!((16..65536).contains(&n));
    let mut b = vec![0u64; (n as usize).div_ceil(8)];
    assert_ne!(
        unsafe { GetTokenInformation(t.0, 1, b.as_mut_ptr().cast(), n, &mut n) },
        0
    );
    let sid = unsafe { *(b.as_ptr().cast::<*const c_void>()) };
    let mut p = ptr::null_mut();
    assert_ne!(unsafe { ConvertSidToStringSidW(sid, &mut p) }, 0);
    let mut n = 0;
    while unsafe { *p.add(n) } != 0 {
        n += 1;
        assert!(n < 256);
    }
    let s = String::from_utf16(unsafe { std::slice::from_raw_parts(p, n) }).unwrap();
    unsafe {
        LocalFree(p.cast());
    }
    s
}
fn new_server(extra: &str) -> (String, NamedPipeServer) {
    let name = format!(r"\\.\pipe\aigoodbro-owner-fixture-{}", random_id().unwrap());
    let sid = sid_string();
    let sddl = format!("O:{sid}D:P(A;;GA;;;{sid})(A;;GA;;;SY){extra}");
    let wide: Vec<u16> = sddl.encode_utf16().chain(Some(0)).collect();
    let mut descriptor = ptr::null_mut();
    assert_ne!(
        unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                wide.as_ptr(),
                1,
                &mut descriptor,
                ptr::null_mut(),
            )
        },
        0
    );
    let mut sa = SA {
        size: std::mem::size_of::<SA>() as u32,
        descriptor,
        inherit: 0,
    };
    let result = unsafe {
        ServerOptions::new()
            .first_pipe_instance(true)
            .reject_remote_clients(true)
            .create_with_security_attributes_raw(&name, (&mut sa as *mut SA).cast())
    };
    unsafe {
        LocalFree(descriptor);
    }
    (name, result.unwrap())
}
fn trust() -> win::Trust {
    let image = std::env::current_exe().unwrap();
    let sha256 = format!("{:x}", Sha256::digest(std::fs::read(&image).unwrap()));
    win::Trust::Fixture { image, sha256 }
}
async fn connect(name: &str) -> DesktopOwnerClient {
    let budget = Budget::new(TIME, &Cancellation::default()).unwrap();
    let c = win::connect_to(name, trust(), &budget).await.unwrap();
    DesktopOwnerClient::initialize(c, &budget).await.unwrap()
}

async fn cases() {
    assert!(
        !elevated(token().0),
        "positive fixture must actually run non-elevated"
    );
    // Actual OS PID/SID/session/owner/DACL checks, plus strictly test-only image
    // substitution. The production policy must reject this unpackaged binary.
    let (name, server) = new_server("");
    let budget = Budget::new(TIME, &Cancellation::default()).unwrap();
    let result = win::connect_to(&name, win::Trust::Official, &budget).await;
    assert!(matches!(result, Err(OwnerError::UnsupportedInstallation)));
    drop(server);
    let (name, server) = new_server("");
    let image = std::env::current_exe().unwrap();
    assert!(matches!(
        win::connect_to(
            &name,
            win::Trust::Fixture {
                image,
                sha256: "0".repeat(64)
            },
            &budget
        )
        .await,
        Err(OwnerError::PeerUntrusted)
    ));
    drop(server);
    // A public read-only ACE is allowed; public write/create-instance is not.
    for (ace, allowed) in [("(A;;GR;;;WD)", true), ("(A;;GW;;;WD)", false)] {
        let (name, server) = new_server(ace);
        let c = ClientOptions::new().open(&name).unwrap();
        assert_eq!(win::security(c.as_raw_handle()).is_ok(), allowed);
        drop(c);
        drop(server);
    }
    assert!(win::security(ptr::null_mut()).is_err());
    // Real overlapped pipe, split output, exact owner versions and a snapshot.
    let (name, mut pipe) = new_server("(A;;GR;;;WD)");
    let task = tokio::spawn(async move {
        pipe.connect().await.unwrap();
        handshake(&mut pipe).await;
        discovery(&mut pipe, false).await;
        let f = protocol::read(&mut pipe).await.unwrap();
        assert_eq!(f["params"]["following"], true);
        let state = json!({"type":"broadcast","method":"thread-stream-state-changed","version":11,"sourceClientId":OWNER,"targetClientIds":[CLIENT],"params":{"hostId":"local","conversationId":THREAD,"change":{"type":"snapshot","revision":1,"conversationState":{"synthetic":true}}}});
        for field in ["owner", "version", "thread", "targets"] {
            let mut wrong = state.clone();
            match field {
                "owner" => wrong["sourceClientId"] = json!(CLIENT),
                "version" => wrong["version"] = json!(10),
                "thread" => wrong["params"]["conversationId"] = json!(TURN),
                _ => wrong["targetClientIds"] = json!([]),
            }
            reply(&mut pipe, &wrong).await;
        }
        for b in protocol::frame(&state).unwrap().chunks(3) {
            pipe.write_all(b).await.unwrap();
        }
        assert_eq!(
            protocol::read(&mut pipe).await.unwrap()["params"]["following"],
            false
        );
        discovery(&mut pipe, true).await;
        let req = protocol::read(&mut pipe).await.unwrap();
        assert_eq!(req["method"], protocol::START);
        assert_eq!(req["version"], 2);
        assert!(req.get("hostId").is_none());
        reply(
            &mut pipe,
            &ok(&req, OWNER, json!({"result":{"turn":{"id":TURN}}})),
        )
        .await;
        discovery(&mut pipe, true).await;
        let req = protocol::read(&mut pipe).await.unwrap();
        assert_eq!(req["version"], 4);
        assert_eq!(req["params"]["expectedTurnId"], TURN);
        reply(
            &mut pipe,
            &ok(&req, OWNER, json!({"ok":true,"interruptedTurnId":TURN})),
        )
        .await;
        assert_eq!(
            protocol::read(&mut pipe).await.err(),
            Some(OwnerError::Disconnected)
        );
    });
    let mut c = connect(&name).await;
    let mut ticket = c
        .discover(THREAD, TIME, &Cancellation::default())
        .await
        .unwrap();
    let expires = ticket.expires;
    ticket.expires = Instant::now();
    assert_eq!(
        c.start_text(&ticket, OP, "synthetic", TIME, &Cancellation::default())
            .await,
        ActionOutcome::NotSent(OwnerError::StaleTicket)
    );
    ticket.expires = expires;
    let epoch = ticket.epoch.clone();
    ticket.epoch = "stale".into();
    assert_eq!(
        c.start_text(&ticket, OP, "synthetic", TIME, &Cancellation::default())
            .await,
        ActionOutcome::NotSent(OwnerError::StaleTicket)
    );
    ticket.epoch = epoch;
    let cancel = Cancellation::default();
    cancel.cancel();
    assert_eq!(
        c.start_text(&ticket, OP, "synthetic", TIME, &cancel).await,
        ActionOutcome::NotSent(OwnerError::Cancelled)
    );
    assert_eq!(
        c.snapshot(&ticket, TIME, &Cancellation::default())
            .await
            .unwrap()
            .revision,
        1
    );
    assert!(matches!(
        c.start_text(
            &ticket,
            OP,
            "synthetic only",
            TIME,
            &Cancellation::default()
        )
        .await,
        ActionOutcome::Accepted { .. }
    ));
    assert!(matches!(
        c.interrupt(
            &ticket,
            &random_id().unwrap(),
            TURN,
            TIME,
            &Cancellation::default()
        )
        .await,
        ActionOutcome::Accepted { .. }
    ));
    c.close();
    task.await.unwrap();
    // Mutating action runs ONCE in synthetic peer, then error/loss/timeout/wrong
    // envelope. No text allowlist admits a second write.
    for mode in [
        "error",
        "no-client-found",
        "lost",
        "timeout",
        "wrong-owner",
        "wrong-id",
    ] {
        let (name, mut pipe) = new_server("");
        let mode = mode.to_owned();
        let task = tokio::spawn(async move {
            pipe.connect().await.unwrap();
            handshake(&mut pipe).await;
            discovery(&mut pipe, false).await;
            discovery(&mut pipe, true).await;
            let req = protocol::read(&mut pipe).await.unwrap();
            assert_eq!(req["method"], protocol::START);
            if mode == "lost" {
                return 1;
            }
            if mode != "timeout" {
                let mut v = json!({"type":"response","requestId":req["requestId"],"resultType":"error","error":mode});
                if mode == "wrong-owner" {
                    v = ok(&req, CLIENT, json!({"result":{"turn":{"id":TURN}}}));
                }
                if mode == "wrong-id" {
                    v["requestId"] = json!(TURN);
                }
                reply(&mut pipe, &v).await;
            }
            assert_eq!(
                protocol::read(&mut pipe).await.err(),
                Some(OwnerError::Disconnected)
            );
            1
        });
        let mut c = connect(&name).await;
        let ticket = c
            .discover(THREAD, TIME, &Cancellation::default())
            .await
            .unwrap();
        assert_eq!(
            c.start_text(
                &ticket,
                OP,
                "synthetic",
                Duration::from_millis(100),
                &Cancellation::default()
            )
            .await,
            ActionOutcome::Unknown
        );
        assert!(matches!(
            c.start_text(&ticket, OP, "synthetic", TIME, &Cancellation::default())
                .await,
            ActionOutcome::NotSent(OwnerError::AlreadyAttempted)
        ));
        assert_eq!(task.await.unwrap(), 1);
    }
    // Native frame overflow is rejected before allocating or waiting for body.
    let (name, mut pipe) = new_server("");
    let task = tokio::spawn(async move {
        pipe.connect().await.unwrap();
        pipe.write_all(&((protocol::MAX_FRAME + 1) as u32).to_le_bytes())
            .await
            .unwrap();
    });
    let mut c = ClientOptions::new().open(&name).unwrap();
    assert_eq!(
        protocol::read(&mut c).await.err(),
        Some(OwnerError::InvalidFrame)
    );
    task.await.unwrap();
}

#[test]
fn windows_original_owner_pipe_contract_and_no_replay() {
    if elevated(token().0) {
        run_restricted_fixture();
    } else {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(cases());
    }
}

#[test]
fn restricted_owner_fixture_entry() {
    let Some(path) = std::env::var_os("AIGOODBRO_OWNER_PIPE_FIXTURE_PROOF") else {
        return;
    };
    let path = PathBuf::from(path);
    assert!(path.is_absolute() && !path.exists());
    assert_eq!(path.file_name().unwrap(), "owner-pipe-proof.txt");
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap()
        .block_on(cases());
    std::fs::write(path, b"synthetic-owner-native-pass\n").unwrap();
}

#[repr(C)]
struct Startup {
    size: u32,
    reserved: *mut u16,
    desktop: *mut u16,
    title: *mut u16,
    x: u32,
    y: u32,
    xsize: u32,
    ysize: u32,
    xchars: u32,
    ychars: u32,
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
    pid: u32,
    tid: u32,
}
#[repr(C)]
#[derive(Default)]
struct BasicLimits {
    process_time: i64,
    job_time: i64,
    flags: u32,
    min_working_set: usize,
    max_working_set: usize,
    active: u32,
    affinity: usize,
    priority: u32,
    scheduling: u32,
}
#[repr(C)]
#[derive(Default)]
struct Limits {
    basic: BasicLimits,
    io: [u64; 6],
    process_mem: usize,
    job_mem: usize,
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
struct Child {
    process: Owned,
    _thread: Owned,
    _job: Owned,
}
impl Drop for Child {
    fn drop(&mut self) {
        if unsafe { WaitForSingleObject(self.process.0, 0) } == 258 {
            unsafe {
                TerminateProcess(self.process.0, 1);
                WaitForSingleObject(self.process.0, 3000);
            }
        }
    }
}
fn run_restricted_fixture() {
    let original = token();
    let mut h = ptr::null_mut();
    assert_ne!(
        unsafe {
            CreateRestrictedToken(
                original.0,
                5,
                0,
                ptr::null(),
                0,
                ptr::null(),
                0,
                ptr::null(),
                &mut h,
            )
        },
        0,
        "restricted token: {}",
        std::io::Error::last_os_error()
    );
    let restricted = Owned(h);
    assert!(!elevated(restricted.0));
    let dir = tempfile::tempdir().unwrap();
    let proof = dir.path().join("owner-pipe-proof.txt");
    let exe = std::env::current_exe().unwrap();
    let app: Vec<u16> = exe.as_os_str().encode_wide().chain(Some(0)).collect();
    let mut cmd: Vec<u16> = format!(
        "\"{}\" --exact desktop_owner::native_tests::restricted_owner_fixture_entry --nocapture",
        exe.display()
    )
    .encode_utf16()
    .chain(Some(0))
    .collect();
    // Explicit OS-only environment; no account/model/auth variables inherited.
    let mut entries = vec![(
        "AIGOODBRO_OWNER_PIPE_FIXTURE_PROOF".to_owned(),
        proof.as_os_str().to_owned(),
    )];
    for key in ["SystemRoot", "WINDIR", "TEMP", "TMP"] {
        if let Some(v) = std::env::var_os(key) {
            entries.push((key.into(), v));
        }
    }
    entries.sort_by(|a, b| a.0.to_lowercase().cmp(&b.0.to_lowercase()));
    let mut env = Vec::<u16>::new();
    for (k, v) in entries {
        env.extend(k.encode_utf16());
        env.push(b'=' as u16);
        env.extend(v.encode_wide());
        env.push(0);
    }
    env.push(0);
    let job = Owned(unsafe { CreateJobObjectW(ptr::null(), ptr::null()) });
    assert!(!job.0.is_null());
    let mut limits = Limits::default();
    limits.basic.flags = 0x2000;
    assert_ne!(
        unsafe {
            SetInformationJobObject(
                job.0,
                9,
                (&limits as *const Limits).cast(),
                std::mem::size_of::<Limits>() as u32,
            )
        },
        0
    );
    let mut startup: Startup = unsafe { std::mem::zeroed() };
    startup.size = std::mem::size_of::<Startup>() as u32;
    let mut info: ProcessInfo = unsafe { std::mem::zeroed() };
    assert_ne!(
        unsafe {
            CreateProcessWithTokenW(
                restricted.0,
                0,
                app.as_ptr(),
                cmd.as_mut_ptr(),
                4 | 0x400,
                env.as_ptr().cast(),
                ptr::null(),
                &mut startup,
                &mut info,
            )
        },
        0,
        "fixture restricted spawn: {}",
        std::io::Error::last_os_error()
    );
    let child = Child {
        process: Owned(info.process),
        _thread: Owned(info.thread),
        _job: job,
    };
    assert_ne!(
        unsafe { AssignProcessToJobObject(child._job.0, child.process.0) },
        0
    );
    assert_ne!(unsafe { ResumeThread(child._thread.0) }, u32::MAX);
    assert_eq!(
        unsafe { WaitForSingleObject(child.process.0, 30000) },
        0,
        "synthetic fixture must exit in its original 30s budget"
    );
    let mut code = 1;
    assert_ne!(unsafe { GetExitCodeProcess(child.process.0, &mut code) }, 0);
    assert_eq!(code, 0);
    assert_eq!(
        std::fs::read(&proof).unwrap(),
        b"synthetic-owner-native-pass\n"
    );
    let end = Instant::now() + Duration::from_secs(3);
    loop {
        let mut a = Accounting::default();
        assert_ne!(
            unsafe {
                QueryInformationJobObject(
                    child._job.0,
                    1,
                    (&mut a as *mut Accounting).cast(),
                    std::mem::size_of::<Accounting>() as u32,
                    ptr::null_mut(),
                )
            },
            0
        );
        if a.active == 0 {
            break;
        }
        assert!(Instant::now() < end);
        std::thread::sleep(Duration::from_millis(5));
    }
}
