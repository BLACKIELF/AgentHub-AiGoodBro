//! Explicit local launch plans. No model prompt, shell, installation or account
//! mutation is performed by discovery or plan construction.
mod catalog;
mod native;

use super::{LocalCliKind, PlatformDirectories};
pub use catalog::PreparedProfile;
pub use native::{discover, VerifiedExecutable};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    ffi::OsString,
    path::{Path, PathBuf},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    Login,
    Open,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Edition {
    #[default]
    Domestic,
    International,
}
impl Edition {
    pub fn directory(self) -> &'static str {
        match self {
            Self::Domestic => ".workbuddy",
            Self::International => ".workbuddy-ai",
        }
    }
}
#[derive(Clone, Copy, Debug, thiserror::Error)]
#[error("{code}")]
pub struct Error {
    pub code: &'static str,
}
pub type Result<T> = std::result::Result<T, Error>;
pub(super) fn fail(code: &'static str) -> Error {
    Error { code }
}
pub fn session_nonce() -> Result<[u8; 16]> {
    let mut bytes = [0; 16];
    getrandom::fill(&mut bytes).map_err(|_| fail("session_unavailable"))?;
    Ok(bytes)
}
pub fn checked_directory(path: &Path) -> Result<PathBuf> {
    check_path(path)?;
    let canonical = path.canonicalize().map_err(|_| fail("source_changed"))?;
    check_path(&canonical)?;
    if !canonical.is_dir() {
        return Err(fail("source_changed"));
    }
    Ok(canonical)
}
pub(super) fn check_path(path: &Path) -> Result<()> {
    if !path.is_absolute()
        || path.as_os_str().len() > 4096
        || path.to_string_lossy().chars().any(char::is_control)
        || path
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return Err(fail("source_changed"));
    }
    crate::accounts::storage::ensure_no_links(path).map_err(|_| fail("source_changed"))
}

/// OpenCode's official roots() reads these on every OS, including Windows.
/// The saved profile points at the actual data/opencode directory.
pub fn opencode_environment(root: &Path) -> Result<Vec<(String, String)>> {
    if root.file_name().and_then(|v| v.to_str()) != Some("opencode") {
        return Err(fail("isolation_unavailable"));
    }
    let data = root.parent().ok_or_else(|| fail("isolation_unavailable"))?;
    if data.file_name().and_then(|v| v.to_str()) != Some("data") {
        return Err(fail("isolation_unavailable"));
    }
    let base = data.parent().ok_or_else(|| fail("isolation_unavailable"))?;
    Ok(vec![
        ("XDG_DATA_HOME".into(), data.to_string_lossy().into()),
        (
            "XDG_CONFIG_HOME".into(),
            base.join("config").to_string_lossy().into(),
        ),
        (
            "XDG_STATE_HOME".into(),
            base.join("state").to_string_lossy().into(),
        ),
        (
            "XDG_CACHE_HOME".into(),
            base.join("cache").to_string_lossy().into(),
        ),
    ])
}
pub fn arguments(kind: LocalCliKind, action: Action) -> Result<Vec<String>> {
    use LocalCliKind::*;
    let args: &[&str] = match (kind, action) {
        (Grok, Action::Login) => &["login", "--oauth"],
        (OpenCode, Action::Login) => &["auth", "login"],
        (Kimi, Action::Login) => &["login"],
        (ClaudeCode, Action::Login) => &["auth", "login"],
        (WorkBuddy | Gemini, _) => &[],
        (Grok | OpenCode | Kimi | ClaudeCode, Action::Open) => &[],
        (ZCode | Antigravity | Trae, Action::Open) => &[],
        _ => return Err(fail("platform_not_supported")),
    };
    Ok(args.iter().map(|s| (*s).into()).collect())
}
pub struct Environment {
    kind: LocalCliKind,
    bindings: Vec<(String, String)>,
    own_codex: bool,
    clean: bool,
}
impl Environment {
    pub fn codex(home: &Path) -> Result<Self> {
        check_path(home)?;
        Ok(Self {
            kind: LocalCliKind::Codex,
            bindings: vec![("CODEX_HOME".into(), home.to_string_lossy().into())],
            own_codex: false,
            clean: false,
        })
    }
    pub fn for_profile(kind: LocalCliKind, root: &Path, default: bool) -> Result<Self> {
        check_path(root)?;
        if kind.requires_default_environment_for_launch() && !default {
            return Err(fail("default_environment_required"));
        }
        let bindings = if default {
            vec![]
        } else {
            kind.isolation_environment(root)
                .ok_or_else(|| fail("isolation_unavailable"))?
        };
        Ok(Self {
            kind,
            bindings,
            own_codex: false,
            clean: false,
        })
    }
    /// Uses this Windows user's current Codex login/environment. No account
    /// directory or approval/model setting is replaced by the setup task.
    pub fn own_codex() -> Self {
        Self {
            kind: LocalCliKind::Codex,
            bindings: vec![],
            own_codex: true,
            clean: false,
        }
    }
    /// The verifier and version probe see synthetic local directories and no
    /// account, Node injection, proxy credential or provider environment.
    pub fn dependency_probe(root: &Path) -> Result<Self> {
        check_path(root)?;
        let mut bindings = vec![];
        for (name, path) in [
            ("HOME", root.to_owned()),
            ("USERPROFILE", root.to_owned()),
            ("APPDATA", root.join("AppData/Roaming")),
            ("LOCALAPPDATA", root.join("AppData/Local")),
            ("TEMP", root.join("tmp")),
            ("TMP", root.join("tmp")),
        ] {
            crate::accounts::storage::secure_directory(&path)
                .map_err(|_| fail("dependency_storage_failed"))?;
            bindings.push((name.into(), path.to_string_lossy().into()));
        }
        bindings.push(("PATH".into(), String::new()));
        Ok(Self {
            kind: LocalCliKind::Codex,
            bindings,
            own_codex: false,
            clean: true,
        })
    }
    pub fn with_verified_product(
        mut self,
        runtime: &super::dependency::VerifiedRuntime,
    ) -> Result<Self> {
        if self.kind == LocalCliKind::WorkBuddy {
            let product = runtime
                .product_config()
                .ok_or_else(|| fail("workbuddy_product_unverified"))?;
            check_path(product)?;
            self.bindings.push((
                "ACC_PRODUCT_CONFIG_PATH".into(),
                product.to_string_lossy().into(),
            ));
        }
        Ok(self)
    }
    /// Only backend-generated provider bindings can be applied. No WebView map
    /// or arbitrary environment key is accepted at the process boundary.
    pub fn apply(
        &self,
        inherited: impl IntoIterator<Item = (OsString, OsString)>,
    ) -> Result<Vec<(OsString, OsString)>> {
        let mut out = Vec::new();
        for (key, value) in inherited {
            let name = key.to_string_lossy();
            if self.clean
                && !matches!(
                    name.to_ascii_uppercase().as_str(),
                    "SYSTEMROOT"
                        | "WINDIR"
                        | "COMSPEC"
                        | "PATHEXT"
                        | "NUMBER_OF_PROCESSORS"
                        | "PROCESSOR_ARCHITECTURE"
                )
            {
                continue;
            }
            if (!self.own_codex
                && (self
                    .kind
                    .inherited_environment_to_clear()
                    .iter()
                    .any(|s| name.eq_ignore_ascii_case(s))
                    || (self.kind == LocalCliKind::Codex
                        && crate::workflow::EXTERNAL_API_ENVIRONMENT
                            .iter()
                            .any(|s| name.eq_ignore_ascii_case(s)))
                    || self
                        .bindings
                        .iter()
                        .any(|(k, _)| name.eq_ignore_ascii_case(k))))
                || matches!(
                    name.to_ascii_uppercase().as_str(),
                    "NODE_OPTIONS" | "NODE_PATH" | "BUN_OPTIONS" | "ELECTRON_RUN_AS_NODE"
                )
            {
                continue;
            }
            if name.is_empty()
                || name.contains('=')
                || name.contains('\0')
                || value.to_string_lossy().contains('\0')
            {
                return Err(fail("environment_invalid"));
            }
            out.push((key, value));
        }
        out.extend(self.bindings.iter().map(|(k, v)| (k.into(), v.into())));
        out.sort_by_key(|(k, _)| k.to_string_lossy().to_uppercase());
        Ok(out)
    }
}
pub fn default_root(
    dirs: &PlatformDirectories,
    kind: LocalCliKind,
    edition: Option<Edition>,
) -> Result<PathBuf> {
    if edition.is_some() && kind != LocalCliKind::WorkBuddy {
        return Err(fail("platform_not_supported"));
    }
    Ok(if kind == LocalCliKind::WorkBuddy {
        dirs.home.join(edition.unwrap_or_default().directory())
    } else {
        dirs.default_directory(kind)
    })
}
pub fn create_default_directory(root: &Path) -> Result<PathBuf> {
    check_path(root)?;
    crate::accounts::storage::secure_directory(root).map_err(|_| fail("source_changed"))?;
    checked_directory(root)
}
/// A namespace-bound local activity key. It is neither quota nor login proof.
pub fn activity_key(kind: LocalCliKind, root: &Path) -> String {
    format!(
        "{:x}",
        Sha256::digest(
            format!(
                "AiGoodBro.local-cli.activity.v1\0{}\0{}",
                kind.id(),
                root.to_string_lossy().to_lowercase()
            )
            .as_bytes()
        )
    )
}
/// Bounded credential-version digest; only the digest is retained. A changed
/// file proves local configuration change, never remote subscription success.
pub fn authentication_version(kind: LocalCliKind, root: &Path) -> Result<String> {
    check_path(root)?;
    let names: &[&str] = match kind {
        LocalCliKind::Grok | LocalCliKind::OpenCode => &["auth.json"],
        LocalCliKind::Kimi => &[
            "credentials/kimi-code.json",
            "credentials.json",
            "config.json",
        ],
        LocalCliKind::Gemini => &["oauth_creds.json", "google_accounts.json", "settings.json"],
        LocalCliKind::WorkBuddy => &[".account.json", "config.json"],
        LocalCliKind::ClaudeCode => &[".credentials.json"],
        _ => &[],
    };
    let mut hash = Sha256::new();
    for name in names {
        hash.update(name.as_bytes());
        match crate::accounts::storage::read_optional(&root.join(name), 1024 * 1024) {
            Ok(Some(bytes)) => {
                hash.update([1]);
                hash.update(bytes);
            }
            Ok(None) => hash.update([0]),
            Err(_) => return Err(fail("authentication_unknown")),
        }
    }
    Ok(format!("{:x}", hash.finalize()))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn own_codex_preserves_its_login_but_probe_has_no_ambient_credentials() {
        let inherited = vec![
            ("CODEX_HOME".into(), "existing-own-home".into()),
            (
                "OPENAI_API_KEY".into(),
                "synthetic-existing-credential".into(),
            ),
            ("NODE_OPTIONS".into(), "--require injected".into()),
            ("SystemRoot".into(), "synthetic-system-root".into()),
        ];
        let own = Environment::own_codex().apply(inherited.clone()).unwrap();
        assert!(own
            .iter()
            .any(|(k, v)| k == "CODEX_HOME" && v == "existing-own-home"));
        assert!(own.iter().any(|(k, _)| k == "OPENAI_API_KEY"));
        assert!(!own.iter().any(|(k, _)| k == "NODE_OPTIONS"));
        let temp = tempfile::tempdir().unwrap();
        let probe = Environment::dependency_probe(temp.path())
            .unwrap()
            .apply(inherited)
            .unwrap();
        assert!(probe
            .iter()
            .all(|(k, _)| k != "CODEX_HOME" && k != "OPENAI_API_KEY" && k != "NODE_OPTIONS"));
        assert!(probe
            .iter()
            .any(|(k, v)| k == "SystemRoot" && v == "synthetic-system-root"));
        assert!(probe.iter().any(|(k, v)| k == "PATH" && v.is_empty()));
    }
    #[test]
    fn prepared_profiles_are_isolated_and_rollback_preserves_foreign_content() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let mut catalog = crate::profiles::ProfileCatalog::default();
        let prepared =
            PreparedProfile::create(&root, LocalCliKind::OpenCode, None, "First", &catalog)
                .unwrap();
        let first = prepared.root().to_owned();
        assert!(LocalCliKind::OpenCode.recognizes_directory(&first));
        let env = opencode_environment(&first).unwrap();
        assert_eq!(env.len(), 4);
        assert!(env.iter().all(|(_, v)| Path::new(v).starts_with(&root)));
        catalog
            .add(LocalCliKind::OpenCode, "First".into(), first.clone())
            .unwrap();
        prepared.keep();
        assert!(
            PreparedProfile::create(&root, LocalCliKind::OpenCode, None, "first", &catalog)
                .is_err()
        );
        let second =
            PreparedProfile::create(&root, LocalCliKind::Grok, None, "Second", &catalog).unwrap();
        let second_root = second.root().to_owned();
        std::fs::write(
            second_root.join("auth.json"),
            b"synthetic concurrent writer",
        )
        .unwrap();
        drop(second);
        assert_eq!(
            std::fs::read(second_root.join("auth.json")).unwrap(),
            b"synthetic concurrent writer"
        );
        assert!(first.is_dir());
    }
    #[test]
    fn empty_uncommitted_profile_and_only_own_marker_are_recoverable() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let catalog = crate::profiles::ProfileCatalog::default();
        let profile =
            PreparedProfile::create(&root, LocalCliKind::Kimi, None, "Fixture", &catalog).unwrap();
        let path = profile.root().to_owned();
        drop(profile);
        assert!(!path.exists());
        let profile = PreparedProfile::create(
            &root,
            LocalCliKind::WorkBuddy,
            Some(Edition::International),
            "Fixture",
            &catalog,
        )
        .unwrap();
        let path = profile.root().to_owned();
        std::fs::write(
            path.join(".aigoodbro-profile.json"),
            b"synthetic replacement",
        )
        .unwrap();
        drop(profile);
        assert_eq!(
            std::fs::read(path.join(".aigoodbro-profile.json")).unwrap(),
            b"synthetic replacement"
        );
    }
    #[test]
    fn environment_scrubs_ambient_auth_and_keeps_literal_argument_arrays() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let spec = Environment::for_profile(LocalCliKind::Grok, &root, false).unwrap();
        let env = spec
            .apply(vec![
                ("gRoK_hOmE".into(), "wrong".into()),
                ("XAI_API_KEY".into(), "synthetic-secret".into()),
                ("NODE_OPTIONS".into(), "--require bad".into()),
                ("PATH".into(), "literal-path".into()),
            ])
            .unwrap();
        assert!(env
            .iter()
            .all(|(key, _)| !key.to_string_lossy().eq_ignore_ascii_case("XAI_API_KEY")));
        assert!(env
            .iter()
            .all(|(key, _)| !key.to_string_lossy().eq_ignore_ascii_case("NODE_OPTIONS")));
        assert_eq!(
            env.iter()
                .filter(|(key, _)| key.to_string_lossy().eq_ignore_ascii_case("GROK_HOME"))
                .count(),
            1
        );
        assert_eq!(
            arguments(LocalCliKind::Grok, Action::Login).unwrap(),
            ["login", "--oauth"]
        );
        assert!(arguments(LocalCliKind::WorkBuddy, Action::Login)
            .unwrap()
            .is_empty());
        assert!(arguments(LocalCliKind::Gemini, Action::Login)
            .unwrap()
            .is_empty());
        assert!(arguments(LocalCliKind::Mimo, Action::Open).is_err());
    }
    #[test]
    fn credential_change_digest_is_private_and_default_only_provider_rejects_alias() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let before = authentication_version(LocalCliKind::Grok, &root).unwrap();
        std::fs::write(root.join("auth.json"), b"synthetic-no-network").unwrap();
        let after = authentication_version(LocalCliKind::Grok, &root).unwrap();
        assert_ne!(before, after);
        assert_eq!(after.len(), 64);
        assert!(!after.contains("synthetic"));
        assert!(Environment::for_profile(LocalCliKind::Gemini, &root, false).is_err());
        assert!(opencode_environment(&root).is_err());
    }
}
