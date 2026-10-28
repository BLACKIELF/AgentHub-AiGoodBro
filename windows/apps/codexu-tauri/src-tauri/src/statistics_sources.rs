//! Mirrors the confirmed Mac statistics-source catalogue, without treating an
//! account login as attribution of a directory's entire history.
use crate::app_state::AppConfig;
use codexu_core::{
    accounts::AccountManager,
    local_cli::{LocalCliKind, PlatformDirectories},
    profiles::same_root,
    token_monitor::{provider_catalog, SourceRole, TokenMonitorSource},
};
use std::path::PathBuf;

pub fn collect(
    config: &AppConfig,
    accounts: &AccountManager,
) -> Result<Vec<TokenMonitorSource>, String> {
    let managed = accounts
        .managed_history_roots()
        .map_err(|e| e.code.to_owned())?;
    from_roots(config, &PlatformDirectories::detect(), &managed)
}

fn from_roots(
    config: &AppConfig,
    directories: &PlatformDirectories,
    managed: &[(String, PathBuf)],
) -> Result<Vec<TokenMonitorSource>, String> {
    config
        .profiles
        .validate()
        .map_err(|_| "invalid_statistics_source".to_owned())?;
    if !directories.home.is_absolute() || !config.codex_root.is_absolute() {
        return Err("invalid_statistics_source".into());
    }
    let providers = provider_catalog().map_err(|e| e.code().to_owned())?;
    let enabled = |id: &str| {
        providers
            .iter()
            .find(|p| p.id == id)
            .is_some_and(|p| p.default_tracked)
    };
    let mut sources: Vec<TokenMonitorSource> = providers
        .iter()
        .filter(|p| p.id != "codex")
        .map(|p| TokenMonitorSource {
            id: format!("default-{}", p.id),
            provider_id: p.id.clone(),
            label: p.label.clone(),
            root: directories.home.clone(),
            path_role: SourceRole::UserHome,
            default_enabled: p.default_tracked,
        })
        .collect();
    sources.push(TokenMonitorSource {
        id: "system-history".into(),
        provider_id: "codex".into(),
        label: "Codex".into(),
        root: config.codex_root.clone(),
        path_role: SourceRole::CodexHome,
        default_enabled: enabled("codex"),
    });
    for profile in &config.profiles.entries {
        let (provider, root, role) = match profile.kind {
            LocalCliKind::Codex if !same_root(&profile.root, &config.codex_root) => {
                ("codex", profile.root.clone(), SourceRole::CodexHome)
            }
            LocalCliKind::ClaudeCode
                if !same_root(&profile.root, &directories.default_directory(profile.kind)) =>
            {
                ("claude", profile.root.join("projects"), SourceRole::LogRoot)
            }
            LocalCliKind::Grok
                if !same_root(&profile.root, &directories.default_directory(profile.kind)) =>
            {
                ("grok", profile.root.join("sessions"), SourceRole::LogRoot)
            }
            _ => continue,
        };
        sources.push(TokenMonitorSource {
            id: format!("local-{}", profile.id),
            provider_id: provider.into(),
            label: profile.label.clone(),
            root,
            path_role: role,
            default_enabled: enabled(provider),
        });
    }
    for (id, root) in managed {
        // History roots are supplied by the real managed catalogue, not by IPC
        // or arbitrary vault traversal. Duplicate root aliases are counted once.
        if sources
            .iter()
            .any(|s| s.provider_id == "codex" && same_root(&s.root, root))
        {
            continue;
        }
        if id.len() != 32 || !id.bytes().all(|b| b.is_ascii_hexdigit()) || !root.is_absolute() {
            return Err("invalid_statistics_source".into());
        }
        sources.push(TokenMonitorSource {
            id: format!("managed-{id}"),
            provider_id: "codex".into(),
            label: format!("Codex {}", &id[..8]),
            root: root.clone(),
            path_role: SourceRole::CodexHome,
            default_enabled: enabled("codex"),
        });
    }
    Ok(sources)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn inputs() -> (tempfile::TempDir, AppConfig, PlatformDirectories) {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("fixture-home");
        let config = AppConfig {
            codex_root: home.join(".codex"),
            ..AppConfig::default()
        };
        let directories = PlatformDirectories {
            home: home.clone(),
            roaming: home.join("AppData/Roaming"),
            local_app_data: home.join("AppData/Local"),
        };
        (dir, config, directories)
    }
    #[test]
    fn pinned_defaults_and_native_directory_roles_match_the_mac_contract() {
        let (_dir, mut config, dirs) = inputs();
        config
            .profiles
            .add(
                LocalCliKind::ClaudeCode,
                "Linked Claude".into(),
                dirs.home.join("claude-alternate"),
            )
            .unwrap();
        config
            .profiles
            .add(
                LocalCliKind::Grok,
                "Linked Grok".into(),
                dirs.home.join("grok-alternate"),
            )
            .unwrap();
        config
            .profiles
            .add(
                LocalCliKind::Kimi,
                "Linked Kimi".into(),
                dirs.home.join("kimi-alternate"),
            )
            .unwrap();
        let sources = from_roots(&config, &dirs, &[]).unwrap();
        assert!(sources.iter().any(|s| s.id == "system-history"
            && s.root == config.codex_root
            && matches!(s.path_role, SourceRole::CodexHome)));
        assert!(sources.iter().any(|s| s.id == "local-1"
            && s.provider_id == "claude"
            && s.root.ends_with("claude-alternate/projects")
            && matches!(s.path_role, SourceRole::LogRoot)));
        assert!(sources
            .iter()
            .any(|s| s.id == "local-2" && s.root.ends_with("grok-alternate/sessions")));
        assert!(!sources.iter().any(|s| s.id == "local-3"));
        assert!(sources
            .iter()
            .any(|s| s.id == "default-qodercn" && !s.default_enabled));
        assert!(!sources.iter().any(|s| s.id == "default-codex"));
    }
    #[test]
    fn duplicate_and_default_roots_are_not_added_as_independent_account_history() {
        let (_dir, mut config, dirs) = inputs();
        config
            .profiles
            .add(
                LocalCliKind::Codex,
                "System directory".into(),
                config.codex_root.clone(),
            )
            .unwrap();
        config
            .profiles
            .add(
                LocalCliKind::ClaudeCode,
                "Default Claude".into(),
                dirs.default_directory(LocalCliKind::ClaudeCode),
            )
            .unwrap();
        let id = "a".repeat(32);
        let sources = from_roots(
            &config,
            &dirs,
            &[
                (id.clone(), config.codex_root.clone()),
                (id, dirs.home.join("managed-desktop")),
            ],
        )
        .unwrap();
        assert!(!sources.iter().any(|s| s.id.starts_with("local-")));
        assert_eq!(
            sources.iter().filter(|s| s.provider_id == "codex").count(),
            2
        );
        assert!(!sources
            .iter()
            .any(|s| s.root.ends_with("auth.json") || s.root.ends_with("managed-accounts-v1")));
    }
}
