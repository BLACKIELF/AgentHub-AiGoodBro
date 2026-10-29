use super::{
    fail, storage, AccountIdentity, AccountResult, AccountRuntime, LoginAuthorization,
    SecretProtector, VerifiedCredential,
};
use std::{path::Path, sync::atomic::AtomicBool};
#[cfg(windows)]
use std::{
    path::PathBuf,
    sync::atomic::Ordering,
    time::{Duration, Instant},
};

#[cfg(windows)]
#[path = "private_windows.rs"]
pub(in crate::accounts) mod private;
#[cfg(windows)]
#[path = "process_windows.rs"]
pub(in crate::accounts) mod process;

pub struct DpapiProtector;
impl SecretProtector for DpapiProtector {
    fn seal(&self, context: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
        protect(context, bytes, false)
    }
    fn unseal(&self, context: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
        protect(context, bytes, true)
    }
}
#[cfg(not(windows))]
fn protect(_: &str, _: &[u8], _: bool) -> AccountResult<Vec<u8>> {
    Err(fail("windows_required"))
}

#[cfg(windows)]
fn protect(context: &str, bytes: &[u8], decrypt: bool) -> AccountResult<Vec<u8>> {
    use std::ffi::c_void;
    #[repr(C)]
    struct Blob {
        size: u32,
        data: *mut u8,
    }
    #[link(name = "crypt32")]
    unsafe extern "system" {
        fn CryptProtectData(
            input: *const Blob,
            description: *const u16,
            entropy: *const Blob,
            reserved: *const c_void,
            prompt: *const c_void,
            flags: u32,
            output: *mut Blob,
        ) -> i32;
        fn CryptUnprotectData(
            input: *const Blob,
            description: *mut *mut u16,
            entropy: *const Blob,
            reserved: *const c_void,
            prompt: *const c_void,
            flags: u32,
            output: *mut Blob,
        ) -> i32;
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn LocalFree(memory: *mut c_void) -> *mut c_void;
    }
    if bytes.len() > 16 * 1024 * 1024 || context.len() > 256 {
        return Err(fail("vault_invalid"));
    }
    let input = Blob {
        size: bytes.len() as u32,
        data: bytes.as_ptr() as *mut u8,
    };
    let entropy = Blob {
        size: context.len() as u32,
        data: context.as_ptr() as *mut u8,
    };
    let mut output = Blob {
        size: 0,
        data: std::ptr::null_mut(),
    };
    let ok = unsafe {
        if decrypt {
            CryptUnprotectData(
                &input,
                std::ptr::null_mut(),
                &entropy,
                std::ptr::null(),
                std::ptr::null(),
                1,
                &mut output,
            )
        } else {
            CryptProtectData(
                &input,
                std::ptr::null(),
                &entropy,
                std::ptr::null(),
                std::ptr::null(),
                1,
                &mut output,
            )
        }
    };
    if ok == 0 {
        return Err(fail(if decrypt {
            "vault_decryption_failed"
        } else {
            "vault_encryption_failed"
        }));
    }
    if output.data.is_null() {
        return Err(fail("vault_encryption_failed"));
    }
    let result = if output.size as usize > 16 * 1024 * 1024 {
        Err(fail("vault_invalid"))
    } else {
        Ok(unsafe { std::slice::from_raw_parts(output.data, output.size as usize) }.to_vec())
    };
    unsafe {
        std::ptr::write_bytes(output.data, 0, output.size as usize);
        LocalFree(output.data as *mut c_void);
    }
    result
}

#[cfg(windows)]
pub(crate) fn restrict_access(path: &Path) -> AccountResult<()> {
    private::restrict(path)
}

pub struct NativeAccountRuntime;

pub(super) fn proxy_codex_executable(
    home: &Path,
) -> AccountResult<(std::path::PathBuf, std::fs::File)> {
    #[cfg(windows)]
    {
        resolve_executable(home)
    }
    #[cfg(not(windows))]
    {
        let _ = home;
        Err(fail("windows_required"))
    }
}
impl AccountRuntime for NativeAccountRuntime {
    fn available(&self) -> bool {
        cfg!(windows)
    }
    fn login(
        &self,
        home: &Path,
        cancelled: &AtomicBool,
        report: &mut dyn FnMut(LoginAuthorization),
    ) -> AccountResult<VerifiedCredential> {
        #[cfg(not(windows))]
        {
            let _ = (home, cancelled, report);
            Err(fail("windows_required"))
        }
        #[cfg(windows)]
        {
            let (executable, _executable_guard) = resolve_executable(home)?;
            let mut args = crate::workflow::official_arguments();
            args.extend(["login".into(), "--device-auth".into()]);
            let mut child = process::Child::start(&executable, home, &args)?;
            let started = Instant::now();
            let mut bytes = Vec::new();
            let mut prompted = false;
            let result = (|| loop {
                if cancelled.load(Ordering::SeqCst) {
                    return Err(fail("login_cancelled"));
                }
                if started.elapsed() > Duration::from_secs(if prompted { 15 * 60 } else { 120 }) {
                    return Err(fail("login_expired"));
                }
                bytes.extend(child.read_available()?);
                if bytes.len() > 64 * 1024 {
                    return Err(fail("login_response_invalid"));
                }
                if !prompted {
                    if let Some(auth) = parse_authorization(&bytes)? {
                        report(auth);
                        prompted = true;
                    }
                }
                if let Some(code) = child.exit_code()? {
                    if code != 0 || !prompted {
                        return Err(fail("login_rejected"));
                    }
                    return Ok(());
                }
                std::thread::sleep(Duration::from_millis(25));
            })();
            child.stop_confirmed()?;
            result?;
            if cancelled.load(Ordering::SeqCst) {
                return Err(fail("login_cancelled"));
            }
            let auth =
                storage::read_optional(&home.join("auth.json"), super::identity::MAX_AUTH_BYTES)?
                    .ok_or_else(|| fail("credentials_missing"))?;
            let identity = AccountIdentity::from_auth(&auth)?;
            self.verify(home, &identity)
        }
    }
    fn verify(&self, home: &Path, expected: &AccountIdentity) -> AccountResult<VerifiedCredential> {
        #[cfg(not(windows))]
        {
            let _ = (home, expected);
            Err(fail("windows_required"))
        }
        #[cfg(windows)]
        {
            let (executable, _executable_guard) = resolve_executable(home)?;
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .map_err(|_| fail("verification_unavailable"))?;
            runtime.block_on(verify_official(&executable, home, expected, None))
        }
    }
    fn verify_in_operation(
        &self,
        home: &Path,
        expected: &AccountIdentity,
        guard: &dyn super::SwitchCommitGuard,
    ) -> AccountResult<VerifiedCredential> {
        #[cfg(not(windows))]
        {
            let _ = (home, expected, guard);
            Err(fail("windows_required"))
        }
        #[cfg(windows)]
        {
            guard.recheck()?;
            let permit = guard
                .verification_process_permit()
                .ok_or_else(|| fail("verification_process_authority_unavailable"))?;
            let (executable, _executable_guard) =
                resolve_executable_with_permit(home, Some(permit.clone()))?;
            permit.recheck()?;
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .map_err(|_| fail("verification_unavailable"))?;
            let result = runtime.block_on(verify_official(
                &executable,
                home,
                expected,
                Some(permit.clone()),
            ));
            // The exact child/job has already reached stop_confirmed before
            // result is observed. A cancelled guard cannot skip that cleanup.
            result
        }
    }
    fn require_system_idle(&self) -> AccountResult<()> {
        #[cfg(not(windows))]
        {
            Err(fail("windows_required"))
        }
        #[cfg(windows)]
        {
            process::require_codex_idle()
        }
    }
    fn validate_target_configuration(&self, home: &Path) -> AccountResult<()> {
        #[cfg(windows)]
        {
            for key in [
                "OPENAI_API_KEY",
                "CODEX_API_KEY",
                "CODEX_ACCESS_TOKEN",
                "OPENAI_BASE_URL",
                "CODEX_BASE_URL",
            ] {
                if std::env::var_os(key).is_some_and(|value| !value.is_empty()) {
                    return Err(fail("target_auth_route_unsupported"));
                }
            }
            if let Some(selected) = std::env::var_os("CODEX_HOME") {
                if Path::new(&selected).canonicalize().ok() != home.canonicalize().ok() {
                    return Err(fail("target_home_override"));
                }
            }
        }
        validate_target_configuration(home)
    }
}

/// Parse real TOML before mutation. Child overrides must not hide the target's
/// custom provider/keyring route and then falsely certify a Desktop switch.
pub fn validate_target_configuration(home: &Path) -> AccountResult<()> {
    let Some(bytes) =
        storage::read_optional(&home.join("config.toml"), super::identity::MAX_AUTH_BYTES)?
    else {
        return Ok(());
    };
    let text = std::str::from_utf8(&bytes).map_err(|_| fail("target_configuration_invalid"))?;
    let value: toml::Value = text
        .parse()
        .map_err(|_| fail("target_configuration_invalid"))?;
    let object = value
        .as_table()
        .ok_or_else(|| fail("target_configuration_invalid"))?;
    if object.contains_key("profile") {
        // A selected CLI profile can override the route for the real Desktop.
        // First batch leaves it untouched and requires an explicit route fix.
        return Err(fail("target_auth_route_unsupported"));
    }
    for (key, allowed) in [
        ("model_provider", "openai"),
        ("cli_auth_credentials_store", "file"),
        ("forced_login_method", "chatgpt"),
    ] {
        if let Some(value) = object.get(key) {
            if value.as_str() != Some(allowed) {
                return Err(fail("target_auth_route_unsupported"));
            }
        }
    }
    if object
        .get("model_providers")
        .and_then(toml::Value::as_table)
        .is_some_and(|table| table.contains_key("openai"))
    {
        return Err(fail("target_auth_route_unsupported"));
    }
    for (key, allowed) in [
        ("openai_base_url", "https://chatgpt.com/backend-api/codex"),
        ("chatgpt_base_url", "https://chatgpt.com/backend-api/"),
    ] {
        if let Some(value) = object.get(key) {
            if value.as_str() != Some(allowed) {
                return Err(fail("target_auth_route_unsupported"));
            }
        }
    }
    Ok(())
}

/// Same allowlisted URL and bounded code grammar as the confirmed Mac parser.
pub fn parse_authorization(bytes: &[u8]) -> AccountResult<Option<LoginAuthorization>> {
    if bytes.len() > 64 * 1024 {
        return Err(fail("login_response_invalid"));
    }
    let text = String::from_utf8_lossy(bytes);
    let mut cleaned = String::new();
    let mut state = 0;
    for c in text.chars() {
        match state {
            0 if c == '\u{1b}' => state = 1,
            1 if c == '[' => state = 2,
            1 if c == ']' => state = 3,
            1 => state = 0,
            2 if ('@'..='~').contains(&c) => state = 0,
            2 => {}
            3 if c == '\u{7}' => state = 0,
            3 => {}
            _ => {
                if !c.is_control() || c == '\n' || c == '\r' {
                    cleaned.push(c);
                }
            }
        }
    }
    let mut url = None;
    let mut code = None;
    for word in cleaned.split_whitespace() {
        let word = word.trim_matches(|c: char| "<>[](),\"'".contains(c));
        if word.starts_with("https://") {
            let parsed = url::Url::parse(word).map_err(|_| fail("login_response_invalid"))?;
            if parsed.host_str() == Some("auth.openai.com")
                && parsed.path() == "/codex/device"
                && parsed.port().is_none()
                && parsed.query().is_none()
                && parsed.fragment().is_none()
                && parsed.username().is_empty()
                && parsed.password().is_none()
            {
                url = Some("https://auth.openai.com/codex/device".to_owned());
            }
        }
        let groups: Vec<&str> = word.split('-').collect();
        if (2..=4).contains(&groups.len())
            && groups.iter().all(|group| {
                (2..=12).contains(&group.len())
                    && group
                        .bytes()
                        .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
            })
        {
            code = Some(word.to_owned());
        }
    }
    Ok(match (url, code) {
        (Some(verification_url), Some(user_code)) => Some(LoginAuthorization {
            verification_url,
            user_code,
        }),
        _ => None,
    })
}

#[cfg(windows)]
fn resolve_executable(home: &Path) -> AccountResult<(PathBuf, std::fs::File)> {
    resolve_executable_with_permit(home, None)
}
#[cfg(windows)]
fn resolve_executable_with_permit(
    home: &Path,
    permit: Option<std::sync::Arc<dyn super::VerificationProcessPermit>>,
) -> AccountResult<(PathBuf, std::fs::File)> {
    use std::os::windows::fs::OpenOptionsExt;
    let (package, triple) = if cfg!(target_arch = "aarch64") {
        ("codex-win32-arm64", "aarch64-pc-windows-msvc")
    } else {
        ("codex-win32-x64", "x86_64-pc-windows-msvc")
    };
    let mut candidates = Vec::new();
    if let Some(roaming) = std::env::var_os("APPDATA") {
        candidates.push(
            PathBuf::from(roaming)
                .join("npm/node_modules/@openai/codex/node_modules/@openai")
                .join(package)
                .join("vendor")
                .join(triple)
                .join("bin/codex.exe"),
        );
    }
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        candidates.push(PathBuf::from(local).join("Microsoft/WinGet/Links/codex.exe"));
    }
    if let Some(path) = std::env::var_os("PATH") {
        candidates.extend(
            std::env::split_paths(&path)
                .filter(|p| p.is_absolute())
                .map(|p| p.join("codex.exe")),
        );
    }
    let deadline = Instant::now() + Duration::from_secs(6);
    for candidate in candidates.into_iter().take(100) {
        if Instant::now() >= deadline {
            break;
        }
        let Ok(candidate) = candidate.canonicalize() else {
            continue;
        };
        if !candidate.is_file()
            || !candidate
                .extension()
                .and_then(|v| v.to_str())
                .is_some_and(|v| v.eq_ignore_ascii_case("exe"))
        {
            continue;
        }
        let Ok(guard) = std::fs::OpenOptions::new()
            .read(true)
            .share_mode(1)
            .open(&candidate)
        else {
            continue;
        };
        let start = if let Some(permit) = &permit {
            process::Child::start_for_verification(
                &candidate,
                home,
                &["--version".into()],
                permit.clone(),
            )
        } else {
            process::Child::start(&candidate, home, &["--version".into()])
        };
        let mut child = match start {
            Ok(child) => child,
            Err(error) if error.code == "cleanup_unconfirmed" => return Err(error),
            Err(_) => continue,
        };
        let start = Instant::now();
        let mut output = Vec::new();
        let mut successful = false;
        let result = (|| -> AccountResult<()> {
            while start.elapsed() < Duration::from_secs(2) && Instant::now() < deadline {
                output.extend(child.read_available()?);
                if output.len() > 256 {
                    break;
                }
                if let Some(code) = child.exit_code()? {
                    successful = code == 0;
                    output.extend(child.read_available()?);
                    break;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            Ok(())
        })();
        child.stop_confirmed()?;
        result?;
        if successful
            && output.len() <= 256
            && std::str::from_utf8(&output).ok().is_some_and(|text| {
                text.trim()
                    .strip_prefix("codex-cli ")
                    .is_some_and(|version| {
                        !version.is_empty()
                            && version
                                .bytes()
                                .all(|b| b.is_ascii_alphanumeric() || b".-+".contains(&b))
                    })
            })
        {
            return Ok((candidate, guard));
        }
    }
    Err(fail("cli_unavailable"))
}

#[cfg(windows)]
async fn verify_official(
    executable: &Path,
    home: &Path,
    expected: &AccountIdentity,
    permit: Option<std::sync::Arc<dyn super::VerificationProcessPermit>>,
) -> AccountResult<VerifiedCredential> {
    use futures_util::{SinkExt, StreamExt};
    use serde_json::{json, Value};
    use tokio::{
        net::TcpListener,
        time::{sleep, timeout},
    };
    use tokio_tungstenite::{connect_async, tungstenite::Message};
    let auth = storage::read_optional(&home.join("auth.json"), super::identity::MAX_AUTH_BYTES)?
        .ok_or_else(|| fail("credentials_missing"))?;
    let (identity, _) = super::identity::parse_auth(&auth)?;
    if &identity != expected {
        return Err(fail("identity_unverified"));
    }
    let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
        .await
        .map_err(|_| fail("verification_unavailable"))?;
    let port = listener
        .local_addr()
        .map_err(|_| fail("verification_unavailable"))?
        .port();
    let endpoint = format!("ws://127.0.0.1:{}", port);
    drop(listener);
    let mut args = crate::workflow::official_arguments();
    args.extend(["app-server".into(), "--listen".into(), endpoint.clone()]);
    let mut child = if let Some(permit) = permit {
        process::Child::start_for_verification(executable, home, &args, permit)?
    } else {
        process::Child::start(executable, home, &args)?
    };
    let result = timeout(Duration::from_secs(20),async {
        let deadline = tokio::time::Instant::now()+Duration::from_secs(5);
        let mut socket = loop {
            if !process::owns_loopback_listener(child.pid(), port)? {
                if child.exit_code()?.is_some() || tokio::time::Instant::now() >= deadline { return Err(fail("verification_unavailable")); }
                sleep(Duration::from_millis(25)).await; continue;
            }
            match connect_async(&endpoint).await { Ok((socket,_)) => break socket,
            Err(_) if tokio::time::Instant::now()<deadline => sleep(Duration::from_millis(25)).await,
            Err(_) => return Err(fail("verification_unavailable")) } };
        let mut results=Vec::new();
        let requests=[(1,"initialize",json!({"clientInfo":{"name":"aigoodbro-account-lifecycle","version":"1029v1"},"capabilities":{"experimentalApi":true}})),
            (2,"config/read",json!({"includeLayers":false,"cwd":home})),
            (3,"account/read",json!({"refreshToken":false})),(4,"account/rateLimits/read",Value::Null)];
        for (id,method,params) in requests {
            socket.send(Message::Text(json!({"id":id,"method":method,"params":params}).to_string().into())).await.map_err(|_|fail("verification_unavailable"))?;
            loop {
                let message=socket.next().await.ok_or_else(||fail("verification_unavailable"))?.map_err(|_|fail("verification_unavailable"))?;
                let text=match message { Message::Text(value)=>value.to_string(),Message::Binary(value)=>String::from_utf8(value.to_vec()).map_err(|_|fail("verification_invalid"))?,Message::Close(_)=>return Err(fail("verification_unavailable")),_=>continue };
                if text.len()>1024*1024 { return Err(fail("verification_invalid")); }
                let value:Value=serde_json::from_str(&text).map_err(|_|fail("verification_invalid"))?;
                if value.get("id").and_then(Value::as_i64)!=Some(id) { continue; }
                if value.get("error").is_some() { return Err(fail("verification_rejected")); }
                let result=value.get("result").cloned().ok_or_else(||fail("verification_invalid"))?;
                if id==2 { crate::workflow::validate_official_config(&result).map_err(|_|fail("verification_route_invalid"))?; }
                results.push(result);break;
            }
            if id==1 { socket.send(Message::Text(json!({"method":"initialized"}).to_string().into())).await.map_err(|_|fail("verification_unavailable"))?; }
        }
        Ok::<_,super::AccountError>((results.remove(2),results.remove(2)))
    }).await.map_err(|_|fail("verification_timeout"));
    child.stop_confirmed()?;
    let (account, quota) = result??;
    let after = storage::read_optional(&home.join("auth.json"), super::identity::MAX_AUTH_BYTES)?
        .ok_or_else(|| fail("credentials_missing"))?;
    let verified = VerifiedCredential::from_official_read(after, &account, quota)?;
    if &verified.identity != expected {
        return Err(fail("identity_mismatch"));
    }
    Ok(verified)
}
