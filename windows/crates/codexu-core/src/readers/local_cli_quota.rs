//! Local CLI quota contract shared by every non-Codex platform on Windows.
//!
//! The shape mirrors `LocalCLIQuotaResult` from
//! `Sources/CodexUsageWidget/Domain/LocalCLIAccount.swift`. The important part is
//! what this module refuses to do:
//! - It never converts token consumption into a plan balance.
//! - A platform that does not expose its balance reports `Unsupported` or
//!   `Unavailable`; a saved sign-in is never reported as a successful quota read.
//! - Missing windows stay missing. They are not turned into 0% or 100%.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::local_cli::{read_authentication_evidence, LocalCliKind};

pub mod antigravity;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LocalCliQuotaState {
    Available,
    Unavailable,
    NeedsLogin,
    Unsupported,
    RateLimited,
}

/// One observed quota window, e.g. a model bucket in Antigravity.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LocalCliQuotaWindow {
    pub id: String,
    pub label: String,
    pub used_percent: f64,
    #[serde(with = "chrono::serde::ts_milliseconds_option")]
    pub resets_at: Option<DateTime<Utc>>,
}

impl LocalCliQuotaWindow {
    pub fn remaining_percent(&self) -> f64 {
        (100.0 - self.used_percent).clamp(0.0, 100.0)
    }
}

/// A read-only observation of one non-Codex account.
///
/// Every field here is safe to hand to the WebView: identities are masked, no
/// token, e-mail body, cookie or local path is present.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LocalCliQuotaResult {
    pub state: LocalCliQuotaState,
    #[serde(with = "chrono::serde::ts_milliseconds")]
    pub fetched_at: DateTime<Utc>,
    pub masked_identity: Option<String>,
    pub identity_fingerprint: Option<String>,
    pub plan_label: Option<String>,
    pub windows: Vec<LocalCliQuotaWindow>,
    pub balance: Option<f64>,
    pub balance_currency: Option<String>,
    pub source_label: String,
    pub message_code: Option<String>,
    /// A billing-period boundary without a usage percentage. It is not a
    /// reset-card expiry and must never be rendered as one.
    #[serde(with = "chrono::serde::ts_milliseconds_option")]
    pub period_resets_at: Option<DateTime<Utc>>,
}

impl LocalCliQuotaResult {
    pub fn new(
        state: LocalCliQuotaState,
        fetched_at: DateTime<Utc>,
        source_label: &str,
        message_code: Option<&str>,
    ) -> Self {
        Self {
            state,
            fetched_at,
            masked_identity: None,
            identity_fingerprint: None,
            plan_label: None,
            windows: Vec::new(),
            balance: None,
            balance_currency: None,
            source_label: source_label.to_string(),
            message_code: message_code.map(|value| value.to_string()),
            period_resets_at: None,
        }
    }

    pub fn with_identity(mut self, identity: Option<&str>, kind: LocalCliKind) -> Self {
        let identity = identity.and_then(crate::local_cli::valid_identity);
        self.identity_fingerprint = identity.as_deref().map(|value| fingerprint(kind, value));
        self.masked_identity = identity.as_deref().map(crate::local_cli::masked_identity);
        self
    }

    pub fn with_plan(mut self, plan: Option<String>) -> Self {
        self.plan_label = plan;
        self
    }

    pub fn with_windows(mut self, windows: Vec<LocalCliQuotaWindow>) -> Self {
        self.windows = windows;
        self
    }

    pub fn has_any_quota(&self) -> bool {
        !self.windows.is_empty() || self.balance.is_some()
    }
}

/// Stable anonymous fingerprint so two accounts can be told apart without an
/// identity ever being stored or rendered.
pub fn fingerprint(kind: LocalCliKind, identity: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(b"next-local-cli:v1:");
    hasher.update(kind.id().as_bytes());
    hasher.update(b":");
    hasher.update(identity.to_lowercase().as_bytes());
    let digest = hasher.finalize();
    let mut text = String::with_capacity(digest.len() * 2);
    for byte in digest {
        text.push_str(&format!("{:02x}", byte));
    }
    text
}

pub fn valid_windows(windows: &[LocalCliQuotaWindow]) -> bool {
    windows.len() <= 256
        && windows.iter().all(|window| {
            crate::local_cli::bounded_label(&window.id, 128).is_some()
                && crate::local_cli::bounded_label(&window.label, 128).is_some()
                && window.used_percent.is_finite()
                && (0.0..=100.0).contains(&window.used_percent)
        })
        && {
            let mut seen = std::collections::BTreeSet::new();
            windows.iter().all(|window| seen.insert(window.id.clone()))
        }
}

/// Read the quota of one non-Codex account directory.
///
/// `is_shared` marks the platform default directory, which is the only place a
/// desktop platform may be queried live.
pub fn read_local_cli_quota(
    kind: LocalCliKind,
    root: &std::path::Path,
    is_shared: bool,
    now: DateTime<Utc>,
) -> LocalCliQuotaResult {
    if !kind.recognizes_directory(root) {
        return LocalCliQuotaResult::new(
            LocalCliQuotaState::Unavailable,
            now,
            &format!("{} · linked directory", kind.display_name()),
            Some("local_cli_directory_not_recognized"),
        );
    }
    match kind {
        LocalCliKind::Codex => LocalCliQuotaResult::new(
            LocalCliQuotaState::Unsupported,
            now,
            "Codex · official app-server quota",
            Some("local_cli_codex_uses_official_reader"),
        ),
        LocalCliKind::Antigravity => antigravity::load_default(root, is_shared, now),
        _ => {
            let evidence = read_authentication_evidence(kind, root);
            if !evidence.is_configured() {
                return LocalCliQuotaResult::new(
                    LocalCliQuotaState::NeedsLogin,
                    now,
                    &format!("{} · local sign-in configuration", kind.display_name()),
                    Some("local_cli_sign_in_evidence_missing"),
                );
            }
            LocalCliQuotaResult::new(
                LocalCliQuotaState::Unsupported,
                now,
                &format!("{} · quota not exposed locally", kind.display_name()),
                Some("local_cli_quota_not_exposed_by_platform"),
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn window(id: &str, used: f64) -> LocalCliQuotaWindow {
        LocalCliQuotaWindow {
            id: id.to_string(),
            label: id.to_string(),
            used_percent: used,
            resets_at: None,
        }
    }

    #[test]
    fn unsupported_platforms_never_masquerade_as_a_successful_read() {
        let now = Utc::now();
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join(".claude");
        std::fs::create_dir(&root).unwrap();
        // A directory marker is required; evidence files alone are not a directory.
        std::fs::write(root.join("settings.json"), b"{}").unwrap();

        let missing = read_local_cli_quota(LocalCliKind::ClaudeCode, &root, true, now);
        assert_eq!(missing.state, LocalCliQuotaState::NeedsLogin);
        assert_eq!(
            missing.message_code.as_deref(),
            Some("local_cli_sign_in_evidence_missing")
        );
        assert!(!missing.has_any_quota());

        std::fs::write(
            root.join(".credentials.json"),
            br#"{"claudeAiOauth":{"refreshToken":"synthetic"}}"#,
        )
        .unwrap();
        let configured = read_local_cli_quota(LocalCliKind::ClaudeCode, &root, true, now);
        assert_eq!(configured.state, LocalCliQuotaState::Unsupported);
        assert_eq!(
            configured.message_code.as_deref(),
            Some("local_cli_quota_not_exposed_by_platform")
        );
        // A saved sign-in is explicitly not a quota success.
        assert_ne!(configured.state, LocalCliQuotaState::Available);
        assert!(configured.windows.is_empty());
        assert!(configured.balance.is_none());
    }

    #[test]
    fn unrecognized_directory_is_reported_instead_of_guessed() {
        let now = Utc::now();
        let temp = tempfile::tempdir().unwrap();
        let result =
            read_local_cli_quota(LocalCliKind::Grok, &temp.path().join("empty"), false, now);
        assert_eq!(result.state, LocalCliQuotaState::Unavailable);
        assert_eq!(
            result.message_code.as_deref(),
            Some("local_cli_directory_not_recognized")
        );
    }

    #[test]
    fn codex_keeps_using_its_official_reader() {
        let now = Utc::now();
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join(".codex");
        std::fs::create_dir(&root).unwrap();
        std::fs::write(root.join("auth.json"), b"{}").unwrap();
        let result = read_local_cli_quota(LocalCliKind::Codex, &root, true, now);
        assert_eq!(result.state, LocalCliQuotaState::Unsupported);
        assert_eq!(
            result.message_code.as_deref(),
            Some("local_cli_codex_uses_official_reader")
        );
    }

    #[test]
    fn window_validation_rejects_malformed_or_duplicate_windows() {
        assert!(valid_windows(&[window("a", 10.0), window("b", 20.0)]));
        assert!(!valid_windows(&[window("a", 10.0), window("a", 20.0)]));
        assert!(!valid_windows(&[window("a", f64::NAN)]));
        assert!(!valid_windows(&[window("a", 101.0)]));
        assert!(!valid_windows(&[window("a", -1.0)]));
        assert!(!valid_windows(&[window("", 10.0)]));
        assert_eq!(window("a", 25.0).remaining_percent(), 75.0);
        assert_eq!(window("a", 250.0).remaining_percent(), 0.0);
    }

    #[test]
    fn fingerprints_are_stable_anonymous_and_platform_scoped() {
        let one = fingerprint(LocalCliKind::Antigravity, "User@Example.com");
        let two = fingerprint(LocalCliKind::Antigravity, "user@example.com");
        assert_eq!(one, two);
        assert_eq!(one.len(), 64);
        assert!(!one.contains('@'));
        assert_ne!(one, fingerprint(LocalCliKind::Grok, "user@example.com"));
    }

    #[test]
    fn result_helpers_attach_only_masked_identities() {
        let now = Utc::now();
        let result = LocalCliQuotaResult::new(
            LocalCliQuotaState::Available,
            now,
            "Antigravity · official desktop quota",
            None,
        )
        .with_identity(Some("user@example.com"), LocalCliKind::Antigravity)
        .with_plan(Some("Pro".to_string()))
        .with_windows(vec![window("model-0", 12.5)]);
        assert_eq!(result.masked_identity.as_deref(), Some("u***@example.com"));
        assert_eq!(result.plan_label.as_deref(), Some("Pro"));
        assert!(result.has_any_quota());
        assert!(!serde_json::to_string(&result)
            .unwrap()
            .contains("user@example.com"));
        let _ = PathBuf::from("unused");
    }

    #[test]
    fn invalid_identities_are_dropped_rather_than_masked() {
        let now = Utc::now();
        let result = LocalCliQuotaResult::new(LocalCliQuotaState::Available, now, "source", None)
            .with_identity(Some("@example.com"), LocalCliKind::Grok);
        assert_eq!(result.masked_identity, None);
        assert_eq!(result.identity_fingerprint, None);
    }
}
