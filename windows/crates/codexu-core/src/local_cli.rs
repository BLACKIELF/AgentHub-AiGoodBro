//! Multi-platform local CLI account catalog for Windows.
//!
//! This mirrors the macOS `LocalCLIKind` / `LocalCLIProfile` contract in
//! `Sources/CodexUsageWidget/Domain/LocalCLIAccount.swift` so both platforms agree
//! on which platforms exist, where their account directory lives by default, and
//! how one account is kept separate from another.
//!
//! Hard rules carried over from the macOS implementation:
//! - A linked directory is metadata only. Nothing here reads, copies or rewrites
//!   credentials, and no token value ever leaves this module.
//! - Isolation is achieved by pointing the platform at its own configuration
//!   directory. It is never achieved by rewriting a shared/global credential.
//! - A platform that does not expose an account-home override is reported as such
//!   instead of being silently "isolated" with an environment variable that the
//!   platform ignores.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// Bounded read used by every marker and evidence check in this module.
const MAX_EVIDENCE_BYTES: u64 = 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LocalCliKind {
    Codex,
    ClaudeCode,
    Grok,
    OpenCode,
    Trae,
    WorkBuddy,
    Kimi,
    Mimo,
    ZCode,
    Gemini,
    Antigravity,
}

impl Default for LocalCliKind {
    fn default() -> Self {
        Self::Codex
    }
}

impl LocalCliKind {
    pub const ALL: [LocalCliKind; 11] = [
        LocalCliKind::Codex,
        LocalCliKind::ClaudeCode,
        LocalCliKind::Grok,
        LocalCliKind::OpenCode,
        LocalCliKind::Trae,
        LocalCliKind::WorkBuddy,
        LocalCliKind::Kimi,
        LocalCliKind::Mimo,
        LocalCliKind::ZCode,
        LocalCliKind::Gemini,
        LocalCliKind::Antigravity,
    ];

    pub fn id(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::ClaudeCode => "claude_code",
            Self::Grok => "grok",
            Self::OpenCode => "open_code",
            Self::Trae => "trae",
            Self::WorkBuddy => "work_buddy",
            Self::Kimi => "kimi",
            Self::Mimo => "mimo",
            Self::ZCode => "zcode",
            Self::Gemini => "gemini",
            Self::Antigravity => "antigravity",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|kind| kind.id() == value)
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Codex => "Codex",
            Self::ClaudeCode => "Claude Code",
            Self::Grok => "Grok",
            Self::OpenCode => "OpenCode",
            Self::Trae => "TRAE",
            Self::WorkBuddy => "WorkBuddy",
            Self::Kimi => "Kimi Code",
            Self::Mimo => "MiMo",
            Self::ZCode => "ZCode",
            Self::Gemini => "Gemini CLI",
            Self::Antigravity => "Antigravity",
        }
    }

    pub fn command_name(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::ClaudeCode => "claude",
            Self::Grok => "grok",
            Self::OpenCode => "opencode",
            Self::Trae => "traecli",
            Self::WorkBuddy => "codebuddy",
            Self::Kimi => "kimi",
            Self::Mimo => "mimo",
            Self::ZCode => "zcode",
            Self::Gemini => "gemini",
            Self::Antigravity => "antigravity",
        }
    }

    /// Account directory the platform uses when the user never relocated it.
    ///
    /// `home` is `%USERPROFILE%`, `roaming` is `%APPDATA%` and `local_app_data`
    /// is `%LOCALAPPDATA%`. These are the Windows equivalents of the macOS
    /// `defaultConfigDirectory(home:)` mapping.
    pub fn default_config_directory(
        self,
        home: &Path,
        roaming: &Path,
        local_app_data: &Path,
    ) -> PathBuf {
        match self {
            Self::Codex => home.join(".codex"),
            Self::ClaudeCode => home.join(".claude"),
            Self::Grok => home.join(".grok"),
            Self::OpenCode => local_app_data.join("opencode"),
            Self::Trae => home.join(".trae-cn"),
            Self::WorkBuddy => home.join(".workbuddy"),
            Self::Kimi => home.join(".kimi-code"),
            Self::Mimo => local_app_data.join("mimocode"),
            Self::ZCode => home.join(".zcode"),
            Self::Gemini => home.join(".gemini"),
            Self::Antigravity => roaming.join("Antigravity"),
        }
    }

    /// Alternate account directory a platform may also use, e.g. the
    /// international WorkBuddy edition.
    pub fn alternate_config_directory(
        self,
        home: &Path,
        _roaming: &Path,
        _local_app_data: &Path,
    ) -> Option<PathBuf> {
        match self {
            Self::WorkBuddy => Some(home.join(".workbuddy-ai")),
            _ => None,
        }
    }

    /// Files or folders that let the app recognise a real account directory.
    ///
    /// These are discovery markers only; their contents are never surfaced.
    pub fn directory_markers(self) -> &'static [&'static str] {
        match self {
            Self::Codex => &["auth.json", "sessions", "state_5.sqlite"],
            Self::ClaudeCode => &[
                ".credentials.json",
                "settings.json",
                "projects",
                "statsig",
                ".claude.json",
            ],
            Self::Grok => &["auth.json", "settings.json", "config.json", "sessions"],
            Self::OpenCode => &["auth.json", "config.json", "storage", "data"],
            Self::Trae => &["User", "user.json", "config.json", "machine-id.json"],
            Self::WorkBuddy => &["settings.json", "skills", "config.json", "MEMORY.md"],
            Self::Kimi => &["credentials", "config.json", "settings.json", "auth.json"],
            Self::Mimo => &["auth.json", "config.json", "settings.json"],
            Self::ZCode => &["config.json", "settings.json", "auth.json"],
            Self::Gemini => &[
                "settings.json",
                "oauth_creds.json",
                "google_accounts.json",
                ".env",
            ],
            Self::Antigravity => &["User", "User/globalStorage"],
        }
    }

    pub fn supports_terminal_sign_in(self) -> bool {
        matches!(
            self,
            Self::ClaudeCode | Self::Grok | Self::OpenCode | Self::WorkBuddy | Self::Kimi
        )
    }

    pub fn is_desktop_application(self) -> bool {
        matches!(self, Self::ZCode | Self::Trae | Self::Antigravity)
    }

    pub fn supports_linked_environments(self) -> bool {
        !matches!(self, Self::Trae)
    }

    /// Platforms that keep part of their authentication outside the account
    /// directory, so only their default environment may be launched.
    pub fn requires_default_environment_for_launch(self) -> bool {
        matches!(
            self,
            Self::ClaudeCode | Self::Gemini | Self::ZCode | Self::Trae | Self::Antigravity
        )
    }
}

/// How one account of this platform can be kept separate from another on Windows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum IsolationMode {
    /// The platform honours an account-home override, so each account gets its own
    /// directory without touching a shared credential.
    Managed,
    /// Only the platform default directory can be used; extra accounts cannot be
    /// isolated by this app.
    DefaultOnly,
    /// No supported isolation on Windows.
    Unsupported,
}

impl LocalCliKind {
    pub fn isolation_mode(self) -> IsolationMode {
        match self {
            Self::Codex => IsolationMode::Managed,
            Self::ClaudeCode => IsolationMode::Managed,
            Self::Grok => IsolationMode::Managed,
            Self::Kimi => IsolationMode::Managed,
            Self::WorkBuddy => IsolationMode::Managed,
            Self::Gemini => IsolationMode::DefaultOnly,
            // OpenCode's documented isolation is the POSIX XDG set, which a
            // Windows build of the CLI does not read. Report it instead of
            // pretending the variables take effect.
            Self::OpenCode => IsolationMode::Unsupported,
            Self::Trae | Self::ZCode | Self::Antigravity | Self::Mimo => IsolationMode::Unsupported,
        }
    }

    /// Environment bindings that point this platform at one account directory.
    ///
    /// `None` means the platform cannot be isolated on Windows, so the app must
    /// not launch it with a directory it would silently ignore.
    pub fn isolation_environment(self, directory: &Path) -> Option<Vec<(String, String)>> {
        if self.isolation_mode() != IsolationMode::Managed {
            return None;
        }
        let value = directory.to_string_lossy().to_string();
        Some(match self {
            Self::Codex => vec![("CODEX_HOME".to_string(), value)],
            Self::ClaudeCode => vec![
                ("CLAUDE_CONFIG_DIR".to_string(), value),
                ("DISABLE_AUTOUPDATER".to_string(), "1".to_string()),
            ],
            Self::Grok => vec![
                ("GROK_HOME".to_string(), value.clone()),
                (
                    "GROK_AUTH_PATH".to_string(),
                    directory.join("auth.json").to_string_lossy().to_string(),
                ),
                ("GROK_DISABLE_AUTOUPDATER".to_string(), "1".to_string()),
            ],
            Self::Kimi => vec![
                ("KIMI_CODE_HOME".to_string(), value.clone()),
                ("KIMI_SHARE_DIR".to_string(), value),
                ("KIMI_CLI_NO_AUTO_UPDATE".to_string(), "1".to_string()),
            ],
            Self::WorkBuddy => vec![
                ("ELECTRON_RUN_AS_NODE".to_string(), "1".to_string()),
                ("CODEBUDDY_CONFIG_DIR".to_string(), value.clone()),
                ("WORKBUDDY_CONFIG_DIR".to_string(), value),
                (
                    "WORKBUDDY_DATA_FOLDER_NAME".to_string(),
                    directory
                        .file_name()
                        .map(|name| name.to_string_lossy().to_string())
                        .unwrap_or_else(|| ".workbuddy".to_string()),
                ),
                ("DISABLE_AUTOUPDATER".to_string(), "1".to_string()),
            ],
            _ => return None,
        })
    }

    /// Variables that must be cleared so an inherited global credential cannot
    /// override the directory this account was launched with.
    pub fn inherited_environment_to_clear(self) -> &'static [&'static str] {
        match self {
            Self::Codex => &["CODEX_HOME"],
            Self::ClaudeCode => &[
                "CLAUDE_CONFIG_DIR",
                "CLAUDE_CODE_OAUTH_TOKEN",
                "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
                "ANTHROPIC_API_KEY",
                "ANTHROPIC_AUTH_TOKEN",
                "ANTHROPIC_BASE_URL",
            ],
            Self::Grok => &[
                "GROK_HOME",
                "GROK_AUTH_PATH",
                "XAI_API_KEY",
                "GROK_API_KEY",
                "GROK_OAUTH_TOKEN",
            ],
            Self::Kimi => &[
                "KIMI_CODE_HOME",
                "KIMI_SHARE_DIR",
                "KIMI_API_KEY",
                "KIMI_CODE_API_KEY",
                "KIMI_BASE_URL",
                "OPENAI_API_KEY",
                "ANTHROPIC_API_KEY",
            ],
            Self::WorkBuddy => &[
                "ACC_PRODUCT_CONFIG",
                "ACC_PRODUCT_CONFIG_PATH",
                "CODEBUDDY_CONFIG_DIR",
                "WORKBUDDY_CONFIG_DIR",
                "CODEBUDDY_API_KEY",
                "CODEBUDDY_AUTH_TOKEN",
                "ELECTRON_RUN_AS_NODE",
            ],
            Self::Gemini => &[
                "GEMINI_CLI_HOME",
                "GEMINI_API_KEY",
                "GOOGLE_API_KEY",
                "GOOGLE_APPLICATION_CREDENTIALS",
            ],
            Self::OpenCode => &[
                "OPENCODE_AUTH_JSON",
                "OPENCODE_CONFIG",
                "OPENCODE_CONFIG_DIR",
                "OPENCODE_CONFIG_CONTENT",
                "OPENAI_API_KEY",
                "ANTHROPIC_API_KEY",
            ],
            Self::Mimo => &["OPENAI_API_KEY", "ANTHROPIC_API_KEY"],
            _ => &[],
        }
    }

    /// True when the directory looks like a real account directory for this
    /// platform. Directories are only accepted through explicit user selection.
    pub fn recognizes_directory(self, directory: &Path) -> bool {
        if !directory.is_dir() {
            return false;
        }
        let markers = self.directory_markers();
        if markers.is_empty() {
            return true;
        }
        markers.iter().any(|marker| directory.join(marker).exists())
    }

    /// Canonicalize an explicitly user-selected account directory for this
    /// platform. Returns the canonical path, never its contents.
    pub fn normalize_directory(self, directory: &Path) -> anyhow::Result<PathBuf> {
        anyhow::ensure!(directory.is_absolute(), "Select an absolute directory");
        let canonical = directory
            .canonicalize()
            .map_err(|_| anyhow::anyhow!("Directory unavailable"))?;
        anyhow::ensure!(canonical.is_dir(), "Select a directory");
        anyhow::ensure!(
            self.recognizes_directory(&canonical),
            "Directory does not contain recognized {} data",
            self.display_name()
        );
        Ok(canonical)
    }
}

/// Sign-in evidence read from local configuration files only.
///
/// This never reads a token value into memory beyond a presence check and never
/// reports "signed in" as if it were a successful quota read.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuthenticationEvidence {
    Unknown,
    OAuth,
    ApiKey,
    Providers(u32),
}

impl AuthenticationEvidence {
    pub fn is_configured(&self) -> bool {
        !matches!(self, Self::Unknown)
    }
}

fn read_object(root: &Path, relative: &str) -> Option<serde_json::Value> {
    let path = root.join(relative);
    let metadata = std::fs::metadata(&path).ok()?;
    if !metadata.is_file() || metadata.len() > MAX_EVIDENCE_BYTES {
        return None;
    }
    let bytes = std::fs::read(&path).ok()?;
    serde_json::from_slice::<serde_json::Value>(&bytes)
        .ok()
        .filter(|value| value.is_object())
}

fn nonempty_string(value: Option<&serde_json::Value>) -> bool {
    value
        .and_then(|value| value.as_str())
        .map(|text| !text.trim().is_empty())
        .unwrap_or(false)
}

/// Read sign-in evidence for one account directory.
///
/// Windows has no macOS Keychain equivalent in this code path, so only files that
/// the platform writes inside the account directory are inspected. A platform that
/// keeps its credentials elsewhere simply reports `Unknown`.
pub fn read_authentication_evidence(kind: LocalCliKind, root: &Path) -> AuthenticationEvidence {
    let object = |relative: &str| read_object(root, relative).unwrap_or(serde_json::Value::Null);
    match kind {
        LocalCliKind::ClaudeCode => {
            let credentials = object(".credentials.json");
            if let Some(oauth) = credentials.get("claudeAiOauth") {
                if nonempty_string(oauth.get("refreshToken"))
                    || nonempty_string(oauth.get("accessToken"))
                {
                    return AuthenticationEvidence::OAuth;
                }
            }
            if let Some(env) = object("settings.json").get("env").cloned() {
                if nonempty_string(env.get("ANTHROPIC_API_KEY"))
                    || nonempty_string(env.get("ANTHROPIC_AUTH_TOKEN"))
                {
                    return AuthenticationEvidence::ApiKey;
                }
            }
        }
        LocalCliKind::Grok => {
            if let Some(entries) = object("auth.json").as_object() {
                let configured = entries.iter().any(|(key, value)| {
                    key.starts_with("https://auth.x.ai::") && nonempty_string(value.get("key"))
                });
                if configured {
                    return AuthenticationEvidence::OAuth;
                }
            }
        }
        LocalCliKind::OpenCode | LocalCliKind::Mimo => {
            if let Some(entries) = object("auth.json").as_object() {
                let configured = entries
                    .values()
                    .filter(|entry| {
                        let kind = entry.get("type").and_then(|value| value.as_str());
                        match kind {
                            Some("api") => nonempty_string(entry.get("key")),
                            Some("oauth") => {
                                nonempty_string(entry.get("refresh"))
                                    || nonempty_string(entry.get("access"))
                            }
                            _ => false,
                        }
                    })
                    .count();
                if configured > 0 {
                    return AuthenticationEvidence::Providers(configured as u32);
                }
            }
        }
        LocalCliKind::Kimi => {
            let credentials = object("credentials/kimi-code.json");
            if nonempty_string(credentials.get("refresh_token"))
                || nonempty_string(credentials.get("access_token"))
            {
                return AuthenticationEvidence::OAuth;
            }
        }
        LocalCliKind::Gemini => {
            let settings = object("settings.json");
            let selected = settings
                .get("security")
                .and_then(|security| security.get("auth"))
                .and_then(|auth| auth.get("selectedType"))
                .and_then(|value| value.as_str());
            match selected {
                Some("gemini-api-key") => {
                    if let Some(text) = std::fs::read_to_string(root.join(".env")).ok() {
                        if has_environment_value(&text, &["GEMINI_API_KEY", "GOOGLE_API_KEY"]) {
                            return AuthenticationEvidence::ApiKey;
                        }
                    }
                }
                Some("oauth-personal") | None => {
                    let credentials = object("oauth_creds.json");
                    if nonempty_string(credentials.get("refresh_token"))
                        || nonempty_string(credentials.get("access_token"))
                    {
                        return AuthenticationEvidence::OAuth;
                    }
                }
                _ => {}
            }
        }
        // Codex keeps its official login state in the directory the Codex reader
        // already validates; WorkBuddy, ZCode, TRAE and Antigravity keep theirs
        // outside any file this app is willing to open.
        _ => {}
    }
    AuthenticationEvidence::Unknown
}

fn has_environment_value(text: &str, names: &[&str]) -> bool {
    text.lines().any(|line| {
        let trimmed = line.trim();
        let trimmed = trimmed.strip_prefix("export ").unwrap_or(trimmed).trim();
        let Some(equal) = trimmed.find('=') else {
            return false;
        };
        let name = trimmed[..equal].trim();
        if !names.contains(&name) {
            return false;
        }
        let content = trimmed[equal + 1..].trim();
        !content.is_empty() && !content.starts_with('#') && content != "\"\"" && content != "''"
    })
}

/// Bounded, printable label used for every string that reaches the WebView.
pub fn bounded_label(value: &str, maximum_bytes: usize) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || value.len() > maximum_bytes
        || value.chars().any(|character| character.is_control())
    {
        return None;
    }
    Some(trimmed.to_string())
}

/// Identity values are only ever kept in masked form.
pub fn valid_identity(value: &str) -> Option<String> {
    let value = bounded_label(value, 254)?;
    if let Some((local, domain)) = value.split_once('@') {
        if local.is_empty() {
            return None;
        }
        let domain = bounded_label(domain, 128)?;
        if !domain
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || matches!(character, '.' | '-'))
        {
            return None;
        }
    }
    Some(value)
}

pub fn masked_identity(value: &str) -> String {
    if let Some((local, domain)) = value.split_once('@') {
        let first: String = local.chars().take(1).collect();
        return format!("{}***@{}", first, domain);
    }
    let characters: Vec<char> = value.chars().collect();
    if characters.len() > 4 {
        let head: String = characters[..2].iter().collect();
        let tail: String = characters[characters.len() - 2..].iter().collect();
        return format!("{}***{}", head, tail);
    }
    "*".repeat(value.chars().count().max(3))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_kind_round_trips_its_wire_identifier() {
        for kind in LocalCliKind::ALL {
            assert_eq!(LocalCliKind::parse(kind.id()), Some(kind));
            assert!(!kind.display_name().is_empty());
            assert!(!kind.command_name().is_empty());
        }
        assert_eq!(LocalCliKind::parse("codex"), Some(LocalCliKind::Codex));
        assert_eq!(
            LocalCliKind::parse("antigravity"),
            Some(LocalCliKind::Antigravity)
        );
        assert_eq!(LocalCliKind::parse("unknown-platform"), None);
        assert_eq!(
            serde_json::to_string(&LocalCliKind::ClaudeCode).unwrap(),
            "\"claude_code\""
        );
    }

    #[test]
    fn windows_default_directories_follow_the_platform_layout() {
        let home = Path::new(r"C:\Users\example");
        let roaming = Path::new(r"C:\Users\example\AppData\Roaming");
        let local = Path::new(r"C:\Users\example\AppData\Local");
        assert_eq!(
            LocalCliKind::Codex.default_config_directory(home, roaming, local),
            PathBuf::from(r"C:\Users\example\.codex")
        );
        assert_eq!(
            LocalCliKind::Antigravity.default_config_directory(home, roaming, local),
            PathBuf::from(r"C:\Users\example\AppData\Roaming\Antigravity")
        );
        assert_eq!(
            LocalCliKind::OpenCode.default_config_directory(home, roaming, local),
            PathBuf::from(r"C:\Users\example\AppData\Local\opencode")
        );
        assert_eq!(
            LocalCliKind::WorkBuddy.alternate_config_directory(home, roaming, local),
            Some(PathBuf::from(r"C:\Users\example\.workbuddy-ai"))
        );
    }

    #[test]
    fn isolation_never_pretends_an_ignored_variable_works() {
        let directory = Path::new(r"C:\accounts\one");
        for kind in [
            LocalCliKind::Codex,
            LocalCliKind::ClaudeCode,
            LocalCliKind::Grok,
            LocalCliKind::Kimi,
            LocalCliKind::WorkBuddy,
        ] {
            let environment = kind
                .isolation_environment(directory)
                .expect("managed platforms bind their own directory");
            assert!(environment
                .iter()
                .any(|(_, value)| value == &directory.to_string_lossy().to_string()));
        }
        assert_eq!(
            LocalCliKind::OpenCode.isolation_mode(),
            IsolationMode::Unsupported
        );
        assert!(LocalCliKind::OpenCode
            .isolation_environment(directory)
            .is_none());
        assert_eq!(
            LocalCliKind::Gemini.isolation_mode(),
            IsolationMode::DefaultOnly
        );
        assert!(LocalCliKind::Gemini
            .isolation_environment(directory)
            .is_none());
    }

    #[test]
    fn markers_reject_unrelated_directories_and_accept_real_ones() {
        let temp = tempfile::tempdir().unwrap();
        let claude = temp.path().join(".claude");
        std::fs::create_dir(&claude).unwrap();
        assert!(!LocalCliKind::ClaudeCode.recognizes_directory(&claude));
        std::fs::write(claude.join(".credentials.json"), b"{}").unwrap();
        assert!(LocalCliKind::ClaudeCode.recognizes_directory(&claude));
        assert!(!LocalCliKind::Grok.recognizes_directory(&claude));
        assert!(!LocalCliKind::Grok.recognizes_directory(&temp.path().join("missing")));

        let grok = temp.path().join(".grok");
        std::fs::create_dir(&grok).unwrap();
        std::fs::write(grok.join("auth.json"), b"{}").unwrap();
        assert_eq!(
            LocalCliKind::Grok
                .normalize_directory(&grok)
                .unwrap()
                .file_name()
                .unwrap(),
            ".grok"
        );
        assert!(LocalCliKind::Grok
            .normalize_directory(Path::new("relative"))
            .is_err());
        assert!(LocalCliKind::Antigravity
            .normalize_directory(&claude)
            .is_err());
    }

    #[test]
    fn evidence_never_reports_sign_in_without_a_file_and_never_leaks_values() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("grok");
        std::fs::create_dir(&root).unwrap();
        assert_eq!(
            read_authentication_evidence(LocalCliKind::Grok, &root),
            AuthenticationEvidence::Unknown
        );
        std::fs::write(
            root.join("auth.json"),
            br#"{"https://auth.x.ai::acct":{"type":"oauth","key":"synthetic-secret"}}"#,
        )
        .unwrap();
        let evidence = read_authentication_evidence(LocalCliKind::Grok, &root);
        assert_eq!(evidence, AuthenticationEvidence::OAuth);
        assert!(evidence.is_configured());
        assert!(!serde_json::to_string(&evidence)
            .unwrap()
            .contains("synthetic-secret"));

        let claude = temp.path().join("claude");
        std::fs::create_dir(&claude).unwrap();
        std::fs::write(
            claude.join(".credentials.json"),
            br#"{"claudeAiOauth":{"refreshToken":"   "}}"#,
        )
        .unwrap();
        assert_eq!(
            read_authentication_evidence(LocalCliKind::ClaudeCode, &claude),
            AuthenticationEvidence::Unknown
        );
    }

    #[test]
    fn env_evidence_requires_a_real_value() {
        assert!(has_environment_value(
            "GEMINI_API_KEY=abc",
            &["GEMINI_API_KEY"]
        ));
        assert!(has_environment_value(
            "export GEMINI_API_KEY=abc",
            &["GEMINI_API_KEY"]
        ));
        assert!(!has_environment_value(
            "GEMINI_API_KEY=",
            &["GEMINI_API_KEY"]
        ));
        assert!(!has_environment_value(
            "GEMINI_API_KEY=\"\"",
            &["GEMINI_API_KEY"]
        ));
        assert!(!has_environment_value("OTHER=1", &["GEMINI_API_KEY"]));
    }

    #[test]
    fn identity_helpers_mask_and_reject_unsafe_values() {
        assert_eq!(masked_identity("user@example.com"), "u***@example.com");
        assert_eq!(masked_identity("alice"), "al***ce");
        assert_eq!(masked_identity("abc"), "***");
        assert!(valid_identity("user@example.com").is_some());
        assert!(valid_identity("@example.com").is_none());
        assert!(valid_identity("user@exa mple").is_none());
        assert!(bounded_label("  trimmed  ", 64).unwrap() == "trimmed");
        assert!(bounded_label("a\nb", 64).is_none());
    }

    #[test]
    fn desktop_and_default_environment_flags_match_the_macos_contract() {
        assert!(LocalCliKind::Antigravity.is_desktop_application());
        assert!(LocalCliKind::Antigravity.requires_default_environment_for_launch());
        assert!(!LocalCliKind::Antigravity.supports_terminal_sign_in());
        assert!(LocalCliKind::ClaudeCode.supports_terminal_sign_in());
        assert!(!LocalCliKind::Trae.supports_linked_environments());
        assert!(LocalCliKind::Kimi.supports_linked_environments());
    }
}
