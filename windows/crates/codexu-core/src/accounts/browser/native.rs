use super::*;
pub(super) struct NativeBrowser;
fn user_data() -> Option<PathBuf> {
    if cfg!(windows) {
        dirs::data_local_dir().map(|p| p.join("Google/Chrome/User Data"))
    } else {
        None
    }
}
#[cfg(windows)]
fn executable() -> Option<(PathBuf, std::fs::File)> {
    use std::os::windows::fs::OpenOptionsExt;
    let mut candidates = Vec::new();
    for name in ["ProgramFiles", "ProgramFiles(x86)"] {
        if let Some(root) = std::env::var_os(name) {
            candidates.push(PathBuf::from(root).join("Google/Chrome/Application/chrome.exe"));
        }
    }
    if let Some(root) = dirs::data_local_dir() {
        candidates.push(root.join("Google/Chrome/Application/chrome.exe"));
    }
    for path in candidates {
        if storage::ensure_no_links(&path).is_err() {
            continue;
        }
        let Ok(file) = std::fs::OpenOptions::new()
            .read(true)
            .share_mode(1)
            .open(&path)
        else {
            continue;
        };
        if !file.metadata().ok().is_some_and(|m| m.is_file()) {
            continue;
        }
        let Some(publisher) = crate::readers::local_cli_quota::antigravity::publisher_of(&path)
        else {
            continue;
        };
        let publisher: String = publisher
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .flat_map(char::to_lowercase)
            .collect();
        if matches!(publisher.as_str(), "googlellc" | "googleinc") {
            return Some((path, file));
        }
    }
    None
}
impl BrowserRuntime for NativeBrowser {
    fn profiles(&self) -> AccountResult<Vec<ChromeProfile>> {
        match user_data() {
            Some(path) => profiles_at(&path),
            None => Ok(Vec::new()),
        }
    }
    fn available(&self) -> bool {
        #[cfg(windows)]
        {
            executable().is_some()
        }
        #[cfg(not(windows))]
        {
            false
        }
    }
    fn open(&self, plan: &Plan, admit: &dyn Fn() -> AccountResult<()>) -> AccountResult<()> {
        #[cfg(windows)]
        {
            match plan {
                Plan::Chrome(args) => {
                    let (path, _image) =
                        executable().ok_or_else(|| fail("browser_chrome_unavailable"))?;
                    admit()?;
                    std::process::Command::new(path)
                        .args(args)
                        .stdin(std::process::Stdio::null())
                        .stdout(std::process::Stdio::null())
                        .stderr(std::process::Stdio::null())
                        .spawn()
                        .map_err(|_| fail("login_browser_unavailable"))?;
                    Ok(())
                }
                Plan::SystemDefault => {
                    #[link(name = "shell32")]
                    unsafe extern "system" {
                        fn ShellExecuteW(
                            window: *mut std::ffi::c_void,
                            operation: *const u16,
                            file: *const u16,
                            parameters: *const u16,
                            directory: *const u16,
                            show: i32,
                        ) -> isize;
                    }
                    let verb: Vec<u16> = "open\0".encode_utf16().collect();
                    let page: Vec<u16> = LOGIN_URL.encode_utf16().chain(Some(0)).collect();
                    admit()?;
                    let code = unsafe {
                        ShellExecuteW(
                            std::ptr::null_mut(),
                            verb.as_ptr(),
                            page.as_ptr(),
                            std::ptr::null(),
                            std::ptr::null(),
                            1,
                        )
                    };
                    if code > 32 {
                        Ok(())
                    } else {
                        Err(fail("login_browser_unavailable"))
                    }
                }
            }
        }
        #[cfg(not(windows))]
        {
            let _ = (plan, admit);
            Err(fail("windows_required"))
        }
    }
}
