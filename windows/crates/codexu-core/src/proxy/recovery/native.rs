use super::*;
use std::{ffi::c_void, os::windows::ffi::OsStrExt};
type Handle = *mut c_void;
#[repr(C)]
#[derive(Default)]
struct Time {
    low: u32,
    high: u32,
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
#[derive(Default)]
struct Basic {
    process_time: i64,
    job_time: i64,
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
#[link(name = "kernel32")]
unsafe extern "system" {
    fn GetCurrentProcess() -> Handle;
    fn GetCurrentProcessId() -> u32;
    fn GetProcessTimes(
        process: Handle,
        created: *mut Time,
        exit: *mut Time,
        kernel: *mut Time,
        user: *mut Time,
    ) -> i32;
    fn OpenProcess(access: u32, inherit: i32, pid: u32) -> Handle;
    fn CloseHandle(h: Handle) -> i32;
    fn WaitForSingleObject(h: Handle, timeout: u32) -> u32;
    fn GetLastError() -> u32;
    fn OpenJobObjectW(access: u32, inherit: i32, name: *const u16) -> Handle;
    fn QueryInformationJobObject(
        job: Handle,
        class: i32,
        info: *mut c_void,
        length: u32,
        returned: *mut u32,
    ) -> i32;
    fn CreateJobObjectW(attributes: *const c_void, name: *const u16) -> Handle;
    fn LocalFree(memory: *mut c_void) -> *mut c_void;
    fn SetLastError(error: u32);
    fn ProcessIdToSessionId(pid: u32, session: *mut u32) -> i32;
}
struct Held(Handle);
impl Drop for Held {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}
pub(crate) fn create_private_job(name: &str) -> Result<isize, ProxyFailure> {
    #[repr(C)]
    struct Security {
        length: u32,
        descriptor: *mut c_void,
        inherit: i32,
    }
    #[link(name = "advapi32")]
    unsafe extern "system" {
        fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
            text: *const u16,
            revision: u32,
            descriptor: *mut *mut c_void,
            size: *mut u32,
        ) -> i32;
        fn ConvertSidToStringSidW(sid: *const c_void, text: *mut *mut u16) -> i32;
    }
    let encoded = sid()?;
    let mut sid_bytes = vec![];
    for pair in encoded.as_bytes().chunks_exact(2) {
        sid_bytes.push(
            u8::from_str_radix(
                std::str::from_utf8(pair).map_err(|_| ProxyFailure::Unavailable)?,
                16,
            )
            .map_err(|_| ProxyFailure::Unavailable)?,
        );
    }
    let mut text = std::ptr::null_mut();
    if unsafe { ConvertSidToStringSidW(sid_bytes.as_ptr() as *const c_void, &mut text) } == 0 {
        return Err(ProxyFailure::Unavailable);
    }
    let mut length = 0;
    unsafe {
        while *text.add(length) != 0 && length < 1024 {
            length += 1;
        }
    }
    let current_sid = String::from_utf16(unsafe { std::slice::from_raw_parts(text, length) })
        .map_err(|_| ProxyFailure::Unavailable);
    unsafe {
        LocalFree(text as *mut c_void);
    }
    let sddl = format!("D:P(A;;GA;;;SY)(A;;GA;;;{})", current_sid?);
    let wide: Vec<u16> = sddl.encode_utf16().chain(Some(0)).collect();
    let mut descriptor = std::ptr::null_mut();
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            wide.as_ptr(),
            1,
            &mut descriptor,
            std::ptr::null_mut(),
        )
    } == 0
    {
        return Err(ProxyFailure::Unavailable);
    }
    let attributes = Security {
        length: std::mem::size_of::<Security>() as u32,
        descriptor,
        inherit: 0,
    };
    let name: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
    unsafe {
        SetLastError(0);
    }
    let raw = unsafe { CreateJobObjectW(&attributes as *const _ as *const c_void, name.as_ptr()) };
    let error = unsafe { GetLastError() };
    unsafe {
        LocalFree(descriptor);
    }
    if raw.is_null() {
        return Err(ProxyFailure::Unavailable);
    }
    if error == 183 {
        unsafe {
            CloseHandle(raw);
        }
        return Err(ProxyFailure::CleanupUnconfirmed);
    }
    Ok(raw as isize)
}
pub(crate) fn process_created(handle: isize) -> Result<u64, ProxyFailure> {
    let (mut created, mut exited, mut kernel, mut user) = (
        Time::default(),
        Time::default(),
        Time::default(),
        Time::default(),
    );
    if unsafe {
        GetProcessTimes(
            handle as Handle,
            &mut created,
            &mut exited,
            &mut kernel,
            &mut user,
        )
    } == 0
    {
        return Err(ProxyFailure::CleanupUnconfirmed);
    }
    Ok(((created.high as u64) << 32) | created.low as u64)
}
fn sid() -> Result<String, ProxyFailure> {
    #[link(name = "advapi32")]
    unsafe extern "system" {
        fn OpenProcessToken(process: Handle, access: u32, token: *mut Handle) -> i32;
        fn GetTokenInformation(
            token: Handle,
            class: i32,
            information: *mut c_void,
            length: u32,
            returned: *mut u32,
        ) -> i32;
        fn GetLengthSid(sid: *const c_void) -> u32;
        fn IsValidSid(sid: *const c_void) -> i32;
    }
    unsafe {
        let mut raw = std::ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), 8, &mut raw) == 0 {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
        let token = Held(raw);
        let mut size = 0;
        GetTokenInformation(token.0, 1, std::ptr::null_mut(), 0, &mut size);
        if size == 0 || size > 65536 {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
        let mut storage = vec![0usize; (size as usize).div_ceil(std::mem::size_of::<usize>())];
        if GetTokenInformation(
            token.0,
            1,
            storage.as_mut_ptr() as *mut c_void,
            size,
            &mut size,
        ) == 0
        {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
        let raw = *(storage.as_ptr() as *const *const c_void);
        if IsValidSid(raw) == 0 {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
        let length = GetLengthSid(raw) as usize;
        if !(8..=256).contains(&length) {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
        let bytes = std::slice::from_raw_parts(raw as *const u8, length);
        Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
    }
}
pub(super) fn current_owner() -> Result<Owner, ProxyFailure> {
    let path = std::env::current_exe().map_err(|_| ProxyFailure::Unavailable)?;
    let mut executable = std::fs::File::open(path).map_err(|_| ProxyFailure::Unavailable)?;
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        let count = executable
            .read(&mut buffer)
            .map_err(|_| ProxyFailure::Unavailable)?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    Ok(Owner {
        pid: unsafe { GetCurrentProcessId() },
        created: process_created(unsafe { GetCurrentProcess() } as isize)?,
        sid: sid()?,
        image_hash: format!("{:x}", hash.finalize()),
        session: current_session()?,
    })
}
pub(super) fn same_owner(owner: &Owner) -> Result<bool, ProxyFailure> {
    let now = current_owner()?;
    Ok(owner.pid == now.pid
        && owner.created == now.created
        && owner.sid == now.sid
        && owner.image_hash == now.image_hash
        && owner.session == now.session)
}
fn current_session() -> Result<u32, ProxyFailure> {
    let mut session = 0;
    if unsafe { ProcessIdToSessionId(GetCurrentProcessId(), &mut session) } == 0 {
        Err(ProxyFailure::CleanupUnconfirmed)
    } else {
        Ok(session)
    }
}
pub(super) fn process_gone(pid: u32, created: u64) -> Result<bool, ProxyFailure> {
    let raw = unsafe { OpenProcess(0x0010_1000, 0, pid) };
    if raw.is_null() {
        return if unsafe { GetLastError() } == 87 {
            Ok(true)
        } else {
            Err(ProxyFailure::CleanupUnconfirmed)
        };
    }
    let held = Held(raw);
    let current = process_created(held.0 as isize)?;
    if current != created {
        return Ok(true);
    }
    let wait = unsafe { WaitForSingleObject(held.0, 0) };
    match wait {
        0 => Ok(true),
        258 => Ok(false),
        _ => Err(ProxyFailure::CleanupUnconfirmed),
    }
}
pub(super) fn verify_exit(r: &Receipt) -> Result<(), ProxyFailure> {
    // Local\\ Job names belong to a Windows session namespace. "Not found"
    // in a different session cannot establish that the original Job died.
    if r.owner.sid != sid()?
        || r.owner.session != current_session()?
        || !process_gone(r.owner.pid, r.owner.created)?
    {
        return Err(ProxyFailure::CleanupUnconfirmed);
    }
    if matches!(r.stage, Stage::Prepared) {
        return Ok(());
    }
    if !matches!(r.stage, Stage::Armed) {
        return Err(ProxyFailure::CleanupUnconfirmed);
    }
    if !process_gone(
        r.child_pid.ok_or(ProxyFailure::CleanupUnconfirmed)?,
        r.child_created.ok_or(ProxyFailure::CleanupUnconfirmed)?,
    )? {
        return Err(ProxyFailure::CleanupUnconfirmed);
    }
    let name: Vec<u16> =
        std::ffi::OsStr::new(r.job.as_deref().ok_or(ProxyFailure::CleanupUnconfirmed)?)
            .encode_wide()
            .chain(Some(0))
            .collect();
    let raw = unsafe { OpenJobObjectW(4, 0, name.as_ptr()) };
    if raw.is_null() {
        return if unsafe { GetLastError() } == 2 {
            Ok(())
        } else {
            Err(ProxyFailure::CleanupUnconfirmed)
        };
    }
    let job = Held(raw);
    let mut limits = Extended::default();
    let mut accounting = Accounting::default();
    if unsafe {
        QueryInformationJobObject(
            job.0,
            9,
            &mut limits as *mut _ as *mut c_void,
            std::mem::size_of_val(&limits) as u32,
            std::ptr::null_mut(),
        )
    } == 0
        || unsafe {
            QueryInformationJobObject(
                job.0,
                1,
                &mut accounting as *mut _ as *mut c_void,
                std::mem::size_of_val(&accounting) as u32,
                std::ptr::null_mut(),
            )
        } == 0
    {
        return Err(ProxyFailure::CleanupUnconfirmed);
    }
    if limits.basic.flags & 0x2000 == 0
        || limits.basic.flags & (0x800 | 0x1000) != 0
        || accounting.active != 0
    {
        return Err(ProxyFailure::CleanupUnconfirmed);
    }
    Ok(())
}
