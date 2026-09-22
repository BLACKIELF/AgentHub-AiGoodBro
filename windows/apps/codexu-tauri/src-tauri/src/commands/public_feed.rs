//! Fixed public sources only. No account cookies, credentials or caller-supplied URLs.
use std::{process::Stdio, time::Duration};

#[derive(Clone, Copy, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PublicFeed {
    Forecast,
    History,
    Messages,
}

impl PublicFeed {
    fn url(self) -> &'static str {
        match self {
            Self::Forecast => "https://codex-resets.com/zh-CN",
            Self::History => "https://codex-resets.com/api/v1/resets?limit=100&order=desc",
            Self::Messages => "https://raw.githubusercontent.com/BLACKIELF/AgentHub-AiGoodBro/main/Resources/AppMessages/messages-v1.json",
        }
    }
}

// Windows already ships this HTTP implementation. Keep it independent of profile
// environments, disable redirects/cookies and bound both the body and process.
fn script(feed: PublicFeed) -> String {
    include_str!("public_feed.ps1").replace("__PUBLIC_URL__", feed.url())
}

#[tauri::command]
pub async fn read_public_feed(feed: PublicFeed) -> Result<String, String> {
    #[cfg(not(windows))]
    {
        let _ = feed;
        Err("Public feeds require the Windows desktop runtime".into())
    }
    #[cfg(windows)]
    {
        let system_root = std::env::var_os("SystemRoot")
            .map(std::path::PathBuf::from)
            .ok_or("Windows runtime unavailable")?;
        let exe = system_root.join("System32/WindowsPowerShell/v1.0/powershell.exe");
        let mut command = tokio::process::Command::new(exe);
        command
            .args(["-NoProfile", "-NonInteractive", "-Command", &script(feed)])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .creation_flags(0x0800_0000)
            .kill_on_drop(true);
        let output = tokio::time::timeout(Duration::from_secs(18), command.output())
            .await
            .map_err(|_| "Public source timed out")?
            .map_err(|_| "Public source unavailable")?;
        if !output.status.success() || output.stdout.len() > 1_048_576 {
            return Err("Public response could not be verified".into());
        }
        String::from_utf8(output.stdout)
            .map_err(|_| "Public response encoding is invalid".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_fixed_urls_and_no_redirect_or_cookies() {
        for feed in [PublicFeed::Forecast, PublicFeed::History, PublicFeed::Messages] {
            let source = script(feed);
            assert!(source.contains("AllowAutoRedirect = $false"));
            assert!(source.contains("UseCookies = $false"));
            assert!(source.contains("UseDefaultCredentials = $false"));
            assert!(source.contains("1048576"));
            assert!(source.contains(feed.url()));
        }
        assert!(serde_json::from_str::<PublicFeed>("\"https://example.invalid\"").is_err());
    }
}
