#[cfg(windows)]
use super::Failure;
use super::{fail, Result};
use serde_json::Value;
use std::sync::atomic::{AtomicBool, Ordering};
use url::Url;

/// Deliberately not Debug/Serialize: endpoints, headers and bodies can contain
/// credentials. A transport collaborator receives them only in native memory.
pub struct TransportRequest {
    pub(crate) method: &'static str,
    pub(crate) url: Url,
    pub(crate) body: Vec<u8>,
    pub(crate) headers: Vec<(String, String)>,
    pub(crate) timeout_secs: u32,
}
impl TransportRequest {
    pub(crate) fn json(method: &'static str, url: Url, body: Value, timeout_secs: u32) -> Self {
        Self {
            method,
            url,
            body: body.to_string().into_bytes(),
            headers: vec![
                (
                    "Content-Type".into(),
                    "application/json; charset=utf-8".into(),
                ),
                ("Accept".into(), "application/json".into()),
            ],
            timeout_secs,
        }
    }
    /// Rust-only transport/test inspection; never exposed by a Tauri command.
    pub fn endpoint(&self) -> &Url {
        &self.url
    }
    pub fn body(&self) -> &[u8] {
        &self.body
    }
    pub fn method(&self) -> &str {
        self.method
    }
    pub fn headers(&self) -> &[(String, String)] {
        &self.headers
    }
}
pub struct TransportResponse {
    pub status: u16,
    pub body: Vec<u8>,
}
pub trait NotificationTransport: Send + Sync {
    fn send(&self, request: &TransportRequest, cancelled: &AtomicBool)
        -> Result<TransportResponse>;
}
pub struct NativeNotificationTransport;
impl NotificationTransport for NativeNotificationTransport {
    fn send(&self, r: &TransportRequest, cancelled: &AtomicBool) -> Result<TransportResponse> {
        validate(r)?;
        if cancelled.load(Ordering::Acquire) {
            return fail("cancelled");
        }
        #[cfg(not(windows))]
        {
            let _ = r;
            fail("windows_required")
        }
        #[cfg(windows)]
        {
            windows_send(r, cancelled)
        }
    }
}
fn validate(r: &TransportRequest) -> Result<()> {
    if r.url.scheme() != "https"
        || !r.url.username().is_empty()
        || r.url.password().is_some()
        || r.url.port_or_known_default() != Some(443)
        || r.url.fragment().is_some()
        || r.body.len() > 65536
        || !matches!(r.method, "GET" | "POST")
        || r.timeout_secs > 40
        || r.headers
            .iter()
            .any(|(k, v)| k.chars().any(char::is_control) || v.chars().any(char::is_control))
    {
        return fail("invalid_notification_request");
    }
    let h = r.url.host_str().unwrap_or("");
    let p = r.url.path();
    let allowed = match h {
        "open.feishu.cn" | "open.larksuite.com" => {
            p.starts_with("/open-apis/bot/v2/hook/") && r.url.query().is_none()
        }
        "api.telegram.org" => {
            p.starts_with("/bot") && p.ends_with("/sendMessage") && r.url.query().is_none()
        }
        "qyapi.weixin.qq.com" => {
            p == "/cgi-bin/webhook/send"
                && r.url.query_pairs().count() == 1
                && r.url.query_pairs().next().is_some_and(|(k, _)| k == "key")
        }
        _ => {
            super::protocol::ilink_base(&format!("https://{h}")).is_ok()
                && matches!(
                    p,
                    "/ilink/bot/get_bot_qrcode"
                        | "/ilink/bot/get_qrcode_status"
                        | "/ilink/bot/getupdates"
                        | "/ilink/bot/sendmessage"
                )
        }
    };
    if !allowed {
        return fail("invalid_notification_request");
    }
    Ok(())
}

#[cfg(windows)]
fn windows_send(r: &TransportRequest, cancelled: &AtomicBool) -> Result<TransportResponse> {
    use std::{
        ffi::c_void,
        time::{Duration, Instant},
    };
    type H = *mut c_void;
    #[link(name = "winhttp")]
    unsafe extern "system" {
        fn WinHttpOpen(
            agent: *const u16,
            access: u32,
            proxy: *const u16,
            bypass: *const u16,
            flags: u32,
        ) -> H;
        fn WinHttpConnect(session: H, host: *const u16, port: u16, reserved: u32) -> H;
        fn WinHttpOpenRequest(
            connect: H,
            verb: *const u16,
            path: *const u16,
            version: *const u16,
            referrer: *const u16,
            types: *const *const u16,
            flags: u32,
        ) -> H;
        fn WinHttpSetTimeouts(h: H, resolve: i32, connect: i32, send: i32, receive: i32) -> i32;
        fn WinHttpSetOption(h: H, option: u32, value: *const c_void, length: u32) -> i32;
        fn WinHttpSendRequest(
            h: H,
            headers: *const u16,
            length: u32,
            body: *const c_void,
            body_length: u32,
            total: u32,
            context: usize,
        ) -> i32;
        fn WinHttpReceiveResponse(h: H, reserved: *mut c_void) -> i32;
        fn WinHttpQueryHeaders(
            h: H,
            level: u32,
            name: *const u16,
            buffer: *mut c_void,
            length: *mut u32,
            index: *mut u32,
        ) -> i32;
        fn WinHttpReadData(h: H, buffer: *mut c_void, size: u32, read: *mut u32) -> i32;
        fn WinHttpCloseHandle(h: H) -> i32;
    }
    struct Owned(H);
    impl Drop for Owned {
        fn drop(&mut self) {
            unsafe { WinHttpCloseHandle(self.0) };
        }
    }
    let own = |h: H| {
        if h.is_null() {
            Err(Failure("transport_failed"))
        } else {
            Ok(Owned(h))
        }
    };
    let wide = |s: &str| s.encode_utf16().chain(Some(0)).collect::<Vec<_>>();
    let deadline = Instant::now() + Duration::from_secs(u64::from(r.timeout_secs) + 15);
    let check = || {
        if cancelled.load(Ordering::Acquire) {
            fail("cancelled")
        } else if Instant::now() > deadline {
            fail("transport_timeout")
        } else {
            Ok(())
        }
    };
    let agent = wide("AiGoodBro/3.0 MessageChannels");
    let session =
        own(unsafe { WinHttpOpen(agent.as_ptr(), 4, std::ptr::null(), std::ptr::null(), 0) })?;
    if unsafe {
        WinHttpSetTimeouts(
            session.0,
            12000,
            12000,
            12000,
            (r.timeout_secs * 1000) as i32,
        )
    } == 0
    {
        return fail("transport_failed");
    }
    let host = wide(
        r.url
            .host_str()
            .ok_or(Failure("invalid_notification_request"))?,
    );
    let connection = own(unsafe { WinHttpConnect(session.0, host.as_ptr(), 443, 0) })?;
    check()?;
    let verb = wide(r.method);
    let mut route = r.url.path().to_owned();
    if let Some(q) = r.url.query() {
        route.push('?');
        route.push_str(q);
    }
    let path = wide(&route);
    let request = own(unsafe {
        WinHttpOpenRequest(
            connection.0,
            verb.as_ptr(),
            path.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            0x00800000,
        )
    })?;
    let redirects = 0u32;
    let disabled = 0x00000001u32 | 0x00000004u32;
    let autologon = 2u32;
    // Never follow redirects, persist cookies, retry authentication, or send the
    // logged-in Windows identity to a message endpoint. TLS checks stay default.
    for (option, value) in [(88, redirects), (63, disabled), (77, autologon)] {
        if unsafe { WinHttpSetOption(request.0, option, &value as *const _ as *const c_void, 4) }
            == 0
        {
            return fail("transport_failed");
        }
    }
    let headers = wide(
        &r.headers
            .iter()
            .map(|(k, v)| format!("{k}: {v}\r\n"))
            .collect::<String>(),
    );
    check()?;
    if unsafe {
        WinHttpSendRequest(
            request.0,
            headers.as_ptr(),
            (headers.len() - 1) as u32,
            r.body.as_ptr() as *const c_void,
            r.body.len() as u32,
            r.body.len() as u32,
            0,
        )
    } == 0
    {
        return fail("transport_failed");
    }
    check()?;
    if unsafe { WinHttpReceiveResponse(request.0, std::ptr::null_mut()) } == 0 {
        return fail("transport_failed");
    }
    check()?;
    let mut status = 0u32;
    let mut len = 4u32;
    if unsafe {
        WinHttpQueryHeaders(
            request.0,
            0x20000013,
            std::ptr::null(),
            &mut status as *mut _ as *mut c_void,
            &mut len,
            std::ptr::null_mut(),
        )
    } == 0
    {
        return fail("invalid_response");
    }
    let mut body = Vec::new();
    loop {
        check()?;
        let mut buf = [0u8; 8192];
        let mut count = 0u32;
        if unsafe {
            WinHttpReadData(
                request.0,
                buf.as_mut_ptr() as *mut c_void,
                buf.len() as u32,
                &mut count,
            )
        } == 0
        {
            return fail("transport_failed");
        }
        if count == 0 {
            break;
        }
        body.extend_from_slice(&buf[..count as usize]);
        if body.len() > 65536 {
            return fail("response_too_large");
        }
    }
    check()?;
    Ok(TransportResponse {
        status: u16::try_from(status).map_err(|_| Failure("invalid_response"))?,
        body,
    })
}
