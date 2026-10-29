//! Fixed Mac warm-up wire contract. TLS stays verified; redirects/cookies/auth
//! negotiation are disabled. Only the bounded native owner sees credentials.
use super::*;
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
pub(super) fn warmup(token: &str, account: &str, admit: &dyn Fn() -> Result<()>) -> Outcome {
    if [token, account]
        .iter()
        .any(|s| s.is_empty() || s.len() > 16384 || !s.bytes().all(|c| (0x21..=0x7e).contains(&c)))
    {
        return Outcome::NotSent;
    }
    let mut sent = false;
    let result = (|| -> std::result::Result<bool, ()> {
        let deadline = Instant::now() + Duration::from_secs(45);
        let session = held(unsafe {
            WinHttpOpen(wide("codex_cli_rs/0.153.0").as_ptr(), 4, null(), null(), 0)
        })?;
        if unsafe { WinHttpSetTimeouts(session.0, 5000, 5000, 5000, 5000) } == 0 {
            return Err(());
        }
        let connection =
            held(unsafe { WinHttpConnect(session.0, wide("chatgpt.com").as_ptr(), 443, 0) })?;
        let request = held(unsafe {
            WinHttpOpenRequest(
                connection.0,
                wide("POST").as_ptr(),
                wide("/backend-api/codex/responses").as_ptr(),
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
        let body=serde_json::to_vec(&serde_json::json!({"model":"gpt-5.6-luna","instructions":"","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}],"stream":true,"store":false})).map_err(|_|())?;
        let headers=wide(&format!("Authorization: Bearer {token}\r\nChatGPT-Account-Id: {account}\r\nAccept: text/event-stream\r\nContent-Type: application/json\r\noriginator: codex_cli_rs\r\n"));
        admit().map_err(|_| ())?;
        sent = true;
        if unsafe {
            WinHttpSendRequest(
                request.0,
                headers.as_ptr(),
                (headers.len() - 1) as u32,
                body.as_ptr().cast(),
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
            || status != 200
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
                return Ok(sse_completed(&bytes));
            }
            if bytes.len() + count as usize > 1024 * 1024 {
                return Err(());
            }
            bytes.extend_from_slice(&buffer[..count as usize]);
            if sse_completed(&bytes) {
                return Ok(true);
            }
        }
    })();
    match result {
        Ok(true) => Outcome::Succeeded,
        _ if sent => Outcome::Unknown,
        _ => Outcome::NotSent,
    }
}
