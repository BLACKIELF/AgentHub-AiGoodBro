use super::{
    super::{fail, AccountResult},
    identity, ClaudeSubscriptionRuntime, ClaudeUsageResponse, ClaudeVerifiedCredential,
};
use std::{path::Path, sync::atomic::AtomicBool};
pub struct NativeClaudeRuntime;
impl ClaudeSubscriptionRuntime for NativeClaudeRuntime {
    fn available(&self) -> bool {
        native_available()
    }
    fn login(
        &self,
        directory: &Path,
        cancelled: &AtomicBool,
        waiting: &mut dyn FnMut(),
    ) -> AccountResult<ClaudeVerifiedCredential> {
        native_login(directory, cancelled, waiting)
    }
    fn verify(
        &self,
        credential: &[u8],
        account: &serde_json::Value,
    ) -> AccountResult<ClaudeVerifiedCredential> {
        let token = identity::oauth(credential, false)?;
        let response = request(
            false,
            "/api/oauth/profile",
            identity::text(&token["accessToken"], 32768),
            None,
        )?;
        if response.status != 200 {
            return Err(fail("claude_official_identity_unavailable"));
        }
        ClaudeVerifiedCredential::from_official_profile(
            credential.to_vec(),
            account.clone(),
            &identity::object(&response.body)?,
        )
    }
    fn usage(&self, credential: &[u8]) -> AccountResult<ClaudeUsageResponse> {
        let token = identity::oauth(credential, false)?;
        request(
            false,
            "/api/oauth/usage",
            identity::text(&token["accessToken"], 32768),
            None,
        )
    }
    fn refresh(&self, credential: &[u8]) -> AccountResult<Vec<u8>> {
        let mut root = identity::object(credential)?;
        let mut token = identity::oauth(credential, true)?;
        let refresh = identity::text(&token["refreshToken"], 32768)
            .ok_or_else(|| fail("claude_reauthentication_required"))?;
        let body=serde_json::to_vec(&serde_json::json!({"grant_type":"refresh_token","refresh_token":refresh,"client_id":"9d1c250a-e61b-44d9-88ed-5944d1962f5e"})).map_err(|_|fail("claude_credentials_invalid"))?;
        let response = request(true, "/v1/oauth/token", None, Some(&body))?;
        if response.status != 200 {
            return Err(fail("claude_reauthentication_required"));
        }
        let reply = identity::object(&response.body)?;
        let access = identity::text(&reply["access_token"], 32768)
            .ok_or_else(|| fail("claude_reauthentication_required"))?;
        let seconds = reply["expires_in"]
            .as_f64()
            .filter(|s| s.is_finite() && *s > 0.0 && *s <= 365.0 * 86400.0)
            .ok_or_else(|| fail("claude_reauthentication_required"))?;
        token["accessToken"] = access.into();
        token["expiresAt"] = serde_json::json!((super::super::now() as f64 + seconds) * 1000.0);
        if let Some(value) = reply.get("refresh_token").filter(|v| !v.is_null()) {
            let value = value
                .as_str()
                .ok_or_else(|| fail("claude_reauthentication_required"))?;
            if !value.is_empty() {
                if identity::text(&serde_json::json!(value), 32768).is_none() {
                    return Err(fail("claude_reauthentication_required"));
                }
                token["refreshToken"] = value.into();
            }
        }
        if let Some(scope) = reply.get("scope").and_then(|v| identity::text(v, 32768)) {
            token["scopes"] = serde_json::json!(scope.split_whitespace().collect::<Vec<_>>());
        }
        if let Some(seconds) = reply.get("refresh_token_expires_in") {
            let seconds = seconds
                .as_f64()
                .filter(|v| v.is_finite() && *v > 0.0 && *v <= 3650.0 * 86400.0)
                .ok_or_else(|| fail("claude_reauthentication_required"))?;
            token["refreshTokenExpiresAt"] =
                serde_json::json!((super::super::now() as f64 + seconds) * 1000.0);
        }
        root["claudeAiOauth"] = token;
        serde_json::to_vec(&root).map_err(|_| fail("claude_credentials_invalid"))
    }
    fn require_system_idle(&self) -> AccountResult<()> {
        native_idle()
    }
    fn validate_environment(&self) -> AccountResult<()> {
        for name in [
            "CLAUDE_CONFIG_DIR",
            "CLAUDE_SECURESTORAGE_CONFIG_DIR",
            "CLAUDE_CODE_OAUTH_TOKEN",
            "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_PROFILE",
            "ANTHROPIC_FEDERATION_RULE",
            "CLAUDE_CODE_USE_BEDROCK",
            "CLAUDE_CODE_USE_VERTEX",
            "CLAUDE_CODE_USE_FOUNDRY",
            "CLAUDE_CODE_USE_MANTLE",
        ] {
            if std::env::var_os(name).is_some_and(|v| !v.is_empty()) {
                return Err(fail("claude_custom_route_read_only"));
            }
        }
        native_policy()
    }
}
#[cfg(not(windows))]
fn native_available() -> bool {
    false
}
#[cfg(not(windows))]
fn native_idle() -> AccountResult<()> {
    Err(fail("windows_required"))
}
#[cfg(not(windows))]
fn native_policy() -> AccountResult<()> {
    Err(fail("windows_required"))
}
#[cfg(not(windows))]
fn native_login(
    _: &Path,
    _: &AtomicBool,
    _: &mut dyn FnMut(),
) -> AccountResult<ClaudeVerifiedCredential> {
    Err(fail("windows_required"))
}
#[cfg(not(windows))]
fn request(
    _: bool,
    _: &str,
    _: Option<&str>,
    _: Option<&[u8]>,
) -> AccountResult<ClaudeUsageResponse> {
    Err(fail("windows_required"))
}

#[cfg(windows)]
use crate::accounts::native::process;
#[cfg(windows)]
use std::{
    path::PathBuf,
    sync::atomic::Ordering,
    time::{Duration, Instant},
};
#[cfg(windows)]
fn candidates() -> Vec<PathBuf> {
    let mut result = Vec::new();
    if let Some(home) = dirs::home_dir() {
        result.push(home.join(".local/bin/claude.exe"));
    }
    if let Some(path) = std::env::var_os("PATH") {
        for directory in std::env::split_paths(&path) {
            if directory.is_absolute() {
                result.push(directory.join("claude.exe"));
            }
        }
    }
    result
}
#[cfg(windows)]
fn native_available() -> bool {
    candidates().iter().any(|p| p.is_file())
}
#[cfg(windows)]
fn native_idle() -> AccountResult<()> {
    let names: Vec<String> = candidates()
        .iter()
        .filter_map(|p| p.canonicalize().ok())
        .filter_map(|p| {
            p.file_name()
                .map(|n| n.to_string_lossy().to_ascii_lowercase())
        })
        .collect();
    process::require_claude_idle(&names)
}
#[cfg(windows)]
fn native_policy() -> AccountResult<()> {
    // A managed machine needs an effective-policy adapter before mutation. A
    // recognized policy source is read-only instead of silently overridden.
    if let Some(program) = std::env::var_os("ProgramFiles") {
        for name in ["managed-settings.json", "managed-settings.d"] {
            let policy = PathBuf::from(&program).join("ClaudeCode").join(name);
            match std::fs::symlink_metadata(policy) {
                Ok(_) => return Err(fail("claude_managed_policy_read_only")),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
                Err(_) => return Err(fail("claude_policy_unknown")),
            }
        }
    }
    type HKey = *mut std::ffi::c_void;
    #[link(name = "advapi32")]
    unsafe extern "system" {
        fn RegOpenKeyExW(
            key: HKey,
            path: *const u16,
            options: u32,
            access: u32,
            out: *mut HKey,
        ) -> i32;
        fn RegCloseKey(key: HKey) -> i32;
    }
    let path: Vec<u16> = "SOFTWARE\\Policies\\ClaudeCode\0".encode_utf16().collect();
    for root in [0x8000_0002usize, 0x8000_0001usize] {
        let mut key = std::ptr::null_mut();
        let status = unsafe {
            RegOpenKeyExW(
                root as u32 as i32 as isize as HKey,
                path.as_ptr(),
                0,
                0x20119,
                &mut key,
            )
        };
        if status == 0 {
            unsafe { RegCloseKey(key) };
            return Err(fail("claude_managed_policy_read_only"));
        }
        if status != 2 {
            return Err(fail("claude_policy_unknown"));
        }
    }
    Ok(())
}
#[cfg(windows)]
fn executable(directory: &Path) -> AccountResult<(PathBuf, std::fs::File)> {
    use std::os::windows::fs::OpenOptionsExt;
    for candidate in candidates() {
        let Ok(path) = candidate.canonicalize() else {
            continue;
        };
        if super::super::storage::ensure_no_links(&path).is_err() {
            continue;
        }
        let Ok(guard) = std::fs::OpenOptions::new()
            .read(true)
            .share_mode(1)
            .open(&path)
        else {
            continue;
        };
        let publisher =
            crate::readers::local_cli_quota::antigravity::publisher_of(&path).unwrap_or_default();
        let publisher: String = publisher
            .chars()
            .filter(char::is_ascii_alphanumeric)
            .flat_map(char::to_lowercase)
            .collect();
        if !matches!(
            publisher.as_str(),
            "anthropic" | "anthropicpbc" | "anthropicinc"
        ) {
            continue;
        }
        let mut child = process::Child::start_claude(&path, directory, &["--version".into()])?;
        let deadline = Instant::now() + Duration::from_secs(8);
        let mut bytes = Vec::new();
        let result = (|| -> AccountResult<bool> {
            loop {
                bytes.extend(child.read_available()?);
                if bytes.len() > 4096 || Instant::now() > deadline {
                    return Ok(false);
                }
                if let Some(code) = child.exit_code()? {
                    return Ok(
                        code == 0 && String::from_utf8_lossy(&bytes).contains("(Claude Code)")
                    );
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        })();
        child.stop_confirmed()?;
        let valid = result?;
        if valid {
            return Ok((path, guard));
        }
    }
    Err(fail("claude_cli_unavailable"))
}
#[cfg(windows)]
fn native_login(
    directory: &Path,
    cancelled: &AtomicBool,
    waiting: &mut dyn FnMut(),
) -> AccountResult<ClaudeVerifiedCredential> {
    super::super::storage::atomic_write(
        &directory.join("settings.json"),
        br#"{"forceLoginMethod":"claudeai"}"#,
    )?;
    let (executable, _pin) = executable(directory)?;
    let mut child =
        process::Child::start_claude(&executable, directory, &["auth".into(), "login".into()])?;
    waiting();
    let deadline = Instant::now() + Duration::from_secs(900);
    let mut count = 0usize;
    let result = (|| -> AccountResult<u32> {
        loop {
            if cancelled.load(Ordering::SeqCst) {
                return Err(fail("login_cancelled"));
            }
            count = count.saturating_add(child.read_available()?.len());
            if count > 65536 || Instant::now() > deadline {
                return Err(fail("claude_login_timed_out"));
            }
            if let Some(code) = child.exit_code()? {
                return Ok(code);
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    })();
    child.stop_confirmed()?;
    let code = result?;
    if code != 0 {
        return Err(fail("claude_official_login_failed"));
    }
    if cancelled.load(Ordering::SeqCst) {
        return Err(fail("login_cancelled"));
    }
    let paths = super::ClaudeAccountPaths {
        vault_root: directory.join("unused-vault"),
        live_directory: directory.into(),
        global_config: directory.join(".claude.json"),
    };
    let target = super::storage::Target::read(&paths)?;
    target.validate()?;
    NativeClaudeRuntime.verify(
        target
            .credential
            .as_deref()
            .ok_or_else(|| fail("claude_login_required"))?,
        &target.account()?,
    )
}

#[cfg(windows)]
fn request(
    token_host: bool,
    path: &str,
    bearer: Option<&str>,
    body: Option<&[u8]>,
) -> AccountResult<ClaudeUsageResponse> {
    let deadline = Instant::now() + Duration::from_secs(45);
    use std::ffi::c_void;
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
    struct HttpHandle(Handle);
    impl Drop for HttpHandle {
        fn drop(&mut self) {
            unsafe { WinHttpCloseHandle(self.0) };
        }
    }
    let own = |handle: Handle| -> AccountResult<HttpHandle> {
        if handle.is_null() {
            Err(fail("claude_network_unavailable"))
        } else {
            Ok(HttpHandle(handle))
        }
    };
    let wide = |s: &str| s.encode_utf16().chain(Some(0)).collect::<Vec<_>>();
    if (token_host && path != "/v1/oauth/token")
        || (!token_host && !matches!(path, "/api/oauth/profile" | "/api/oauth/usage"))
        || bearer.is_some_and(|v| v.len() > 32768 || v.chars().any(char::is_control))
        || body.is_some_and(|v| v.len() > identity::MAX_BYTES)
    {
        return Err(fail("claude_request_invalid"));
    }
    let agent = wide("AiGoodBro/3.0 ClaudeSubscription");
    let session =
        own(unsafe { WinHttpOpen(agent.as_ptr(), 4, std::ptr::null(), std::ptr::null(), 0) })?;
    if unsafe { WinHttpSetTimeouts(session.0, 15000, 15000, 15000, 15000) } == 0 {
        return Err(fail("claude_network_unavailable"));
    }
    let host = wide(if token_host {
        "platform.claude.com"
    } else {
        "api.anthropic.com"
    });
    let connection = own(unsafe { WinHttpConnect(session.0, host.as_ptr(), 443, 0) })?;
    let verb = wide(if body.is_some() { "POST" } else { "GET" });
    let path = wide(path);
    let request = own(unsafe {
        WinHttpOpenRequest(
            connection.0,
            verb.as_ptr(),
            path.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            0x0080_0000,
        )
    })?;
    let redirect_policy = 0u32;
    if unsafe {
        WinHttpSetOption(
            request.0,
            88,
            &redirect_policy as *const _ as *const c_void,
            4,
        )
    } == 0
    {
        return Err(fail("claude_network_unavailable"));
    }
    let mut headers =
        "Content-Type: application/json\r\nanthropic-beta: oauth-2025-04-20\r\n".to_owned();
    if let Some(token) = bearer {
        headers.push_str("Authorization: Bearer ");
        headers.push_str(token);
        headers.push_str("\r\n");
    }
    let headers = wide(&headers);
    let body = body.unwrap_or_default();
    if unsafe {
        WinHttpSendRequest(
            request.0,
            headers.as_ptr(),
            (headers.len() - 1) as u32,
            body.as_ptr() as *const c_void,
            body.len() as u32,
            body.len() as u32,
            0,
        )
    } == 0
        || unsafe { WinHttpReceiveResponse(request.0, std::ptr::null_mut()) } == 0
    {
        return Err(fail("claude_network_unavailable"));
    }
    let mut status = 0u32;
    let mut length = 4u32;
    if unsafe {
        WinHttpQueryHeaders(
            request.0,
            0x2000_0013,
            std::ptr::null(),
            &mut status as *mut _ as *mut c_void,
            &mut length,
            std::ptr::null_mut(),
        )
    } == 0
    {
        return Err(fail("claude_network_unavailable"));
    }
    let mut retry_buffer = [0u16; 256];
    let mut retry_length = (retry_buffer.len() * 2) as u32;
    let name = wide("Retry-After");
    let retry_after = if unsafe {
        WinHttpQueryHeaders(
            request.0,
            65535,
            name.as_ptr(),
            retry_buffer.as_mut_ptr() as *mut c_void,
            &mut retry_length,
            std::ptr::null_mut(),
        )
    } != 0
    {
        let end = retry_buffer
            .iter()
            .position(|v| *v == 0)
            .unwrap_or(retry_buffer.len());
        String::from_utf16(&retry_buffer[..end]).ok()
    } else {
        None
    };
    let mut response = Vec::new();
    loop {
        if Instant::now() > deadline {
            return Err(fail("claude_network_timeout"));
        }
        let mut buffer = [0u8; 8192];
        let mut count = 0u32;
        if unsafe {
            WinHttpReadData(
                request.0,
                buffer.as_mut_ptr() as *mut c_void,
                buffer.len() as u32,
                &mut count,
            )
        } == 0
        {
            return Err(fail("claude_network_unavailable"));
        }
        if count == 0 {
            break;
        }
        response.extend_from_slice(&buffer[..count as usize]);
        if response.len() > identity::MAX_BYTES {
            return Err(fail("claude_response_too_large"));
        }
    }
    Ok(ClaudeUsageResponse {
        status: u16::try_from(status).map_err(|_| fail("claude_response_invalid"))?,
        body: response,
        retry_after,
    })
}
