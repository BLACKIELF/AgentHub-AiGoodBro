use super::{Failure, Request, Response, Result, Transport};

pub(super) struct NativeTransport;
impl Transport for NativeTransport {
    fn get(&self, request: &Request) -> Result<Response> {
        get(request)
    }
}
#[cfg(not(windows))]
fn get(_: &Request) -> Result<Response> {
    Err(Failure::Unavailable)
}

#[cfg(windows)]
fn get(input: &Request) -> Result<Response> {
    use std::{
        ffi::c_void,
        ptr::{null, null_mut},
        time::{Duration, Instant},
    };
    type Handle = *mut c_void;
    #[link(name = "winhttp")]
    unsafe extern "system" {
        fn WinHttpOpen(
            agent: *const u16,
            access: u32,
            proxy: *const u16,
            bypass: *const u16,
            flags: u32,
        ) -> Handle;
        fn WinHttpConnect(session: Handle, host: *const u16, port: u16, reserved: u32) -> Handle;
        fn WinHttpOpenRequest(
            connect: Handle,
            verb: *const u16,
            path: *const u16,
            version: *const u16,
            referrer: *const u16,
            types: *const *const u16,
            flags: u32,
        ) -> Handle;
        fn WinHttpSetTimeouts(
            session: Handle,
            resolve: i32,
            connect: i32,
            send: i32,
            receive: i32,
        ) -> i32;
        fn WinHttpSetOption(handle: Handle, option: u32, value: *const c_void, length: u32) -> i32;
        fn WinHttpSendRequest(
            request: Handle,
            headers: *const u16,
            length: u32,
            optional: *const c_void,
            optional_length: u32,
            total: u32,
            context: usize,
        ) -> i32;
        fn WinHttpReceiveResponse(request: Handle, reserved: *mut c_void) -> i32;
        fn WinHttpQueryHeaders(
            request: Handle,
            level: u32,
            name: *const u16,
            buffer: *mut c_void,
            length: *mut u32,
            index: *mut u32,
        ) -> i32;
        fn WinHttpReadData(request: Handle, buffer: *mut c_void, size: u32, read: *mut u32) -> i32;
        fn WinHttpCloseHandle(handle: Handle) -> i32;
    }
    struct Http(Handle);
    impl Drop for Http {
        fn drop(&mut self) {
            unsafe { WinHttpCloseHandle(self.0) };
        }
    }
    let own = |h: Handle| {
        if h.is_null() {
            Err(Failure::Unavailable)
        } else {
            Ok(Http(h))
        }
    };
    let wide = |s: &str| s.encode_utf16().chain(Some(0)).collect::<Vec<_>>();
    if super::header(&input.token).as_deref() != Some(input.token.as_str()) {
        return Err(Failure::Credentials);
    }
    let deadline = Instant::now() + Duration::from_secs(30);
    let session =
        own(unsafe { WinHttpOpen(wide("CodexUsageWidget-Next").as_ptr(), 4, null(), null(), 0) })?;
    if unsafe { WinHttpSetTimeouts(session.0, 5000, 5000, 5000, 5000) } == 0 {
        return Err(Failure::Unavailable);
    }
    let (host, path) = input.endpoint.location();
    let connection = own(unsafe { WinHttpConnect(session.0, wide(host).as_ptr(), 443, 0) })?;
    let request = own(unsafe {
        WinHttpOpenRequest(
            connection.0,
            wide("GET").as_ptr(),
            wide(path).as_ptr(),
            null(),
            null(),
            null(),
            0x0080_0000,
        )
    })?;
    // Do not forward credentials to a redirect, ambient cookies or an automatic
    // Windows authentication challenge. TLS certificate checks stay enabled.
    for (option, value) in [(88u32, 0u32), (63, 7), (77, 2)] {
        if unsafe { WinHttpSetOption(request.0, option, &value as *const _ as *const c_void, 4) }
            == 0
        {
            return Err(Failure::Unavailable);
        }
    }
    let mut headers = format!(
        "Accept: application/json\r\nAuthorization: Bearer {}\r\n",
        input.token
    );
    let mut extra = input.headers.clone();
    if input.endpoint == super::Endpoint::Kimi {
        extra.extend(device_headers()?);
    }
    for (name, value) in extra {
        if value.is_empty()
            || value.len() > 1024
            || !value.bytes().all(|c| (0x20..=0x7e).contains(&c))
        {
            return Err(Failure::Credentials);
        }
        headers.push_str(name);
        headers.push_str(": ");
        headers.push_str(&value);
        headers.push_str("\r\n");
    }
    let headers = wide(&headers);
    if unsafe {
        WinHttpSendRequest(
            request.0,
            headers.as_ptr(),
            (headers.len() - 1) as u32,
            null(),
            0,
            0,
            0,
        )
    } == 0
        || Instant::now() >= deadline
        || unsafe { WinHttpReceiveResponse(request.0, null_mut()) } == 0
    {
        return Err(Failure::Unavailable);
    }
    let mut status = 0u32;
    let mut length = 4u32;
    if unsafe {
        WinHttpQueryHeaders(
            request.0,
            0x2000_0013,
            null(),
            &mut status as *mut _ as *mut c_void,
            &mut length,
            null_mut(),
        )
    } == 0
    {
        return Err(Failure::Unavailable);
    }
    let mut body = Vec::new();
    // Non-200 bodies can contain private upstream diagnostics; never retain them.
    if status == 200 {
        loop {
            if Instant::now() >= deadline {
                return Err(Failure::Unavailable);
            }
            let mut chunk = [0u8; 8192];
            let mut read = 0u32;
            if unsafe {
                WinHttpReadData(
                    request.0,
                    chunk.as_mut_ptr() as *mut c_void,
                    chunk.len() as u32,
                    &mut read,
                )
            } == 0
            {
                return Err(Failure::Unavailable);
            }
            if read == 0 {
                break;
            }
            if read as usize > chunk.len() || body.len() + read as usize > super::MAX_BYTES {
                return Err(Failure::Response);
            }
            body.extend_from_slice(&chunk[..read as usize]);
        }
    }
    Ok(Response { status, body })
}

#[cfg(windows)]
fn device_headers() -> Result<Vec<(&'static str, String)>> {
    // Same Kimi metadata fields as Mac, using actual Windows values rather than
    // claiming a Mac host or sending a fabricated OS version.
    #[repr(C)]
    struct Version {
        size: u32,
        major: u32,
        minor: u32,
        build: u32,
        platform: u32,
        service_pack: [u16; 128],
    }
    #[link(name = "ntdll")]
    unsafe extern "system" {
        fn RtlGetVersion(version: *mut Version) -> i32;
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetComputerNameW(buffer: *mut u16, size: *mut u32) -> i32;
    }
    let mut version = Version {
        size: std::mem::size_of::<Version>() as u32,
        major: 0,
        minor: 0,
        build: 0,
        platform: 0,
        service_pack: [0; 128],
    };
    let mut name = [0u16; 256];
    let mut length = name.len() as u32;
    if unsafe { RtlGetVersion(&mut version) } < 0
        || unsafe { GetComputerNameW(name.as_mut_ptr(), &mut length) } == 0
        || length as usize > name.len()
    {
        return Err(Failure::Unavailable);
    }
    let name: String = String::from_utf16_lossy(&name[..length as usize])
        .chars()
        .filter(|c| c.is_ascii() && !c.is_ascii_control())
        .collect();
    if name.trim().is_empty() {
        return Err(Failure::Unavailable);
    }
    let os = format!("{}.{}.{}", version.major, version.minor, version.build);
    Ok(vec![
        ("X-Msh-Device-Name", name),
        ("X-Msh-Os-Version", os.clone()),
        (
            "X-Msh-Device-Model",
            format!("Windows {os} {}", std::env::consts::ARCH),
        ),
    ])
}
