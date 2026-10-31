//! Fixed Mac referral wire contract. TLS stays verified; redirects/cookies/auth
//! negotiation are disabled. Only the bounded native owner sees credentials.
use super::super::*;
use std::{
    ffi::c_void,
    ptr::{null, null_mut},
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
        unsafe {
            WinHttpCloseHandle(self.0);
        }
    }
}
fn held(handle: Handle) -> std::result::Result<Http, ()> {
    if handle.is_null() {
        Err(())
    } else {
        Ok(Http(handle))
    }
}
fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(Some(0)).collect()
}

pub(super) fn request(
    credential: &StoredCredential,
    input: &HttpRequest,
    admit: &dyn Fn() -> AccountResult<()>,
) -> AccountResult<HttpResponse> {
    let auth: Value =
        serde_json::from_slice(&credential.auth).map_err(|_| fail("login_required"))?;
    let token = auth["tokens"]["access_token"]
        .as_str()
        .ok_or_else(|| fail("login_required"))?;
    let account = &credential.identity.account_id;
    if [token, account]
        .iter()
        .any(|s| s.is_empty() || s.len() > 32768 || !s.bytes().all(|c| (0x21..=0x7e).contains(&c)))
    {
        return Err(fail("manual_action_identity_changed"));
    }
    let route = input.path.split('?').next().unwrap_or("");
    if ![
        "/wham/profiles/me",
        "/wham/accounts/check",
        "/referrals/invite/eligibility",
        "/referrals/invite",
        "/referrals/invite/tracking",
    ]
    .contains(&route)
        || (input.method == "POST") != (route == "/referrals/invite")
        || !matches!(input.method, "GET" | "POST")
        || !matches!(input.language.as_str(), "zh" | "en")
        || input.path.len() > 8192
        || input.path.chars().any(char::is_control)
    {
        return Err(fail("referral_invalid_request"));
    }
    let result = (|| -> std::result::Result<HttpResponse, ()> {
        let deadline = Instant::now() + Duration::from_secs(30);
        let session =
            held(unsafe { WinHttpOpen(wide("AiGoodBro/3.0.0").as_ptr(), 4, null(), null(), 0) })?;
        if unsafe { WinHttpSetTimeouts(session.0, 5000, 5000, 5000, 5000) } == 0 {
            return Err(());
        }
        let connection =
            held(unsafe { WinHttpConnect(session.0, wide("chatgpt.com").as_ptr(), 443, 0) })?;
        let request = held(unsafe {
            WinHttpOpenRequest(
                connection.0,
                wide(input.method).as_ptr(),
                wide(&format!("/backend-api{}", input.path)).as_ptr(),
                null(),
                null(),
                null(),
                0x00800000,
            )
        })?;
        for (option, value) in [(88u32, 0u32), (63, 7), (77, 2)] {
            if unsafe { WinHttpSetOption(request.0, option, (&value as *const u32).cast(), 4) } == 0
            {
                return Err(());
            }
        }
        let body = input.body.as_deref().unwrap_or(&[]);
        if body.len() > 4096 {
            return Err(());
        }
        let headers=wide(&format!("Authorization: Bearer {token}\r\nChatGPT-Account-Id: {account}\r\nAccept: application/json\r\nContent-Type: application/json\r\noriginator: Codex Desktop\r\nOAI-Product-Sku: CODEX\r\nOAI-Language: {}\r\n",input.language));
        admit().map_err(|_| ())?;
        if unsafe {
            WinHttpSendRequest(
                request.0,
                headers.as_ptr(),
                (headers.len() - 1) as u32,
                if body.is_empty() {
                    null()
                } else {
                    body.as_ptr().cast()
                },
                body.len() as u32,
                body.len() as u32,
                0,
            )
        } == 0
            || unsafe { WinHttpReceiveResponse(request.0, null_mut()) } == 0
        {
            return Err(());
        }
        let mut status = 0u32;
        let mut length = 4u32;
        if unsafe {
            WinHttpQueryHeaders(
                request.0,
                0x20000013,
                null(),
                (&mut status as *mut u32).cast(),
                &mut length,
                null_mut(),
            )
        } == 0
            || status > 599
        {
            return Err(());
        }
        let mut bytes = Vec::new();
        loop {
            admit().map_err(|_| ())?;
            if Instant::now() >= deadline {
                return Err(());
            }
            let mut buffer = [0u8; 8192];
            let mut count = 0;
            if unsafe { WinHttpReadData(request.0, buffer.as_mut_ptr().cast(), 8192, &mut count) }
                == 0
                || count as usize > buffer.len()
            {
                return Err(());
            }
            if count == 0 {
                return Ok(HttpResponse {
                    status: status as u16,
                    body: bytes,
                });
            }
            if bytes.len() + count as usize > 1024 * 1024 {
                return Err(());
            }
            bytes.extend_from_slice(&buffer[..count as usize]);
        }
    })();
    result.map_err(|_| {
        fail(if input.method == "POST" {
            "referral_delivery_uncertain"
        } else {
            "referral_network"
        })
    })
}
