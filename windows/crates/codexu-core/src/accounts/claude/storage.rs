use super::{
    super::{fail, storage as shared, AccountResult, SecretProtector},
    identity::{self, Identity, StoredCredential, MAX_BYTES},
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::BTreeMap, path::PathBuf};

pub(super) const CONTEXT: &str = "AiGoodBro.Next.Windows.claude-subscriptions.v1";
const JOURNAL_CONTEXT: &str = "AiGoodBro.Next.Windows.claude-switch.v1";
#[derive(Clone)]
pub struct ClaudeAccountPaths {
    pub vault_root: PathBuf,
    pub live_directory: PathBuf,
    pub global_config: PathBuf,
}
impl ClaudeAccountPaths {
    pub fn isolated(
        vault_root: PathBuf,
        live_directory: PathBuf,
        global_config: PathBuf,
    ) -> AccountResult<Self> {
        if [&vault_root, &live_directory, &global_config]
            .iter()
            .any(|p| !p.is_absolute())
            || vault_root.starts_with(&live_directory)
            || live_directory.starts_with(&vault_root)
            || global_config.starts_with(&vault_root)
            || global_config == live_directory.join(".config.json")
            || global_config.file_name().is_none()
        {
            return Err(fail("account_paths_invalid"));
        }
        for p in [&vault_root, &live_directory, &global_config] {
            shared::ensure_no_links(p)?;
        }
        Ok(Self {
            vault_root,
            live_directory,
            global_config,
        })
    }
    pub(super) fn store(&self) -> PathBuf {
        self.vault_root.join("subscriptions.dpapi")
    }
    pub(super) fn staging(&self) -> PathBuf {
        self.vault_root.join("staging")
    }
    pub(super) fn journal(&self) -> PathBuf {
        self.vault_root.join("switch-journal.dpapi")
    }
}
#[derive(Clone, Serialize, Deserialize)]
pub(super) struct Record {
    pub id: String,
    pub label: String,
    pub revision: u64,
    pub credential: StoredCredential,
}
#[derive(Clone, Serialize, Deserialize)]
pub(super) struct ActiveProof {
    pub id: String,
    pub identity: String,
    pub credential_digest: String,
    pub config_digest: String,
    pub legacy: bool,
}
#[derive(Clone, Serialize, Deserialize)]
pub(super) struct RefreshRecovery {
    pub identity: String,
    pub slot_digest: String,
    pub pending_digest: String,
    pub successor: Option<Vec<u8>>,
}
#[derive(Clone, Serialize, Deserialize)]
pub(super) struct QuotaRetry {
    pub until: i64,
    pub observed_at: i64,
    pub identity: String,
}
#[derive(Clone, Serialize, Deserialize)]
pub(super) struct Vault {
    pub schema: u32,
    pub revision: u64,
    pub records: Vec<Record>,
    pub active: Option<ActiveProof>,
    #[serde(default)]
    pub refresh: BTreeMap<String, RefreshRecovery>,
    #[serde(default)]
    pub quota_retry: BTreeMap<String, QuotaRetry>,
}
impl Default for Vault {
    fn default() -> Self {
        Self {
            schema: 1,
            revision: 0,
            records: vec![],
            active: None,
            refresh: BTreeMap::new(),
            quota_retry: BTreeMap::new(),
        }
    }
}
impl Vault {
    fn validate(&self) -> AccountResult<()> {
        if self.schema != 1
            || self.records.len() > 64
            || self.refresh.len() > 64
            || self.quota_retry.len() > 64
        {
            return Err(fail("claude_vault_invalid"));
        }
        let mut ids = std::collections::HashSet::new();
        let mut identities = std::collections::HashSet::new();
        for record in &self.records {
            if !shared::valid_id(&record.id)
                || !ids.insert(&record.id)
                || crate::profiles::validate_label(&record.label).is_err()
                || !identities.insert(record.credential.identity.fingerprint())
                || !shared::valid_id(&record.credential.generation)
                || Identity::from_account(&record.credential.oauth_account)?.fingerprint()
                    != record.credential.identity.fingerprint()
            {
                return Err(fail("claude_vault_invalid"));
            }
            identity::oauth(&record.credential.bytes, true)?;
        }
        for (id, recovery) in &self.refresh {
            if !ids.contains(id)
                || recovery.identity.len() != 64
                || recovery.slot_digest.len() != 64
                || recovery.pending_digest.len() != 64
                || recovery
                    .successor
                    .as_ref()
                    .is_some_and(|v| v.len() > MAX_BYTES)
            {
                return Err(fail("claude_vault_invalid"));
            }
        }
        for (id, retry) in &self.quota_retry {
            if !ids.contains(id)
                || retry.identity.len() != 64
                || retry.observed_at <= 0
                || retry.until <= retry.observed_at
                || retry.until - retry.observed_at > 7 * 24 * 3600
            {
                return Err(fail("claude_vault_invalid"));
            }
        }
        Ok(())
    }
    pub fn record(&self, id: &str) -> AccountResult<&Record> {
        self.records
            .iter()
            .find(|r| r.id == id)
            .ok_or_else(|| fail("account_not_found"))
    }
    pub fn record_mut(&mut self, id: &str) -> AccountResult<&mut Record> {
        self.records
            .iter_mut()
            .find(|r| r.id == id)
            .ok_or_else(|| fail("account_not_found"))
    }
}
pub(super) struct Store<'a> {
    paths: &'a ClaudeAccountPaths,
    protector: &'a dyn SecretProtector,
    _lock: shared::StoreLock,
    original: Option<Vec<u8>>,
    pub vault: Vault,
}
impl<'a> Store<'a> {
    pub fn load(
        paths: &'a ClaudeAccountPaths,
        protector: &'a dyn SecretProtector,
    ) -> AccountResult<Self> {
        let lock = shared::StoreLock::acquire(&paths.vault_root)?;
        let original = shared::read_optional(&paths.store(), 16 * MAX_BYTES)?;
        let vault = match &original {
            Some(v) => serde_json::from_slice(&protector.unseal(CONTEXT, v)?)
                .map_err(|_| fail("claude_vault_invalid"))?,
            None => Vault::default(),
        };
        vault.validate()?;
        Ok(Self {
            paths,
            protector,
            _lock: lock,
            original,
            vault,
        })
    }
    pub fn save(&mut self) -> AccountResult<()> {
        self.vault.validate()?;
        if shared::read_optional(&self.paths.store(), 16 * MAX_BYTES)? != self.original {
            return Err(fail("account_changed"));
        }
        self.vault.revision = self
            .vault
            .revision
            .checked_add(1)
            .ok_or_else(|| fail("claude_vault_invalid"))?;
        let encoded = serde_json::to_vec(&self.vault).map_err(|_| fail("claude_vault_invalid"))?;
        let sealed = self.protector.seal(CONTEXT, &encoded)?;
        shared::atomic_write(&self.paths.store(), &sealed)?;
        self.original = Some(sealed);
        Ok(())
    }
}
/// Both candidate config files are snapshotted, so a legacy/global selection
/// change cannot silently redirect a prepared switch.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Target {
    pub credential: Option<Vec<u8>>,
    pub legacy_config: Option<Vec<u8>>,
    pub global_config: Option<Vec<u8>>,
    pub settings: Option<Vec<u8>>,
    pub legacy: bool,
}
impl Target {
    pub fn read(paths: &ClaudeAccountPaths) -> AccountResult<Self> {
        let credential =
            shared::read_optional(&paths.live_directory.join(".credentials.json"), MAX_BYTES)?;
        let legacy_path = paths.live_directory.join(".config.json");
        let legacy_config = shared::read_optional(&legacy_path, MAX_BYTES)?;
        let global_config = shared::read_optional(&paths.global_config, MAX_BYTES)?;
        let settings =
            shared::read_optional(&paths.live_directory.join("settings.json"), MAX_BYTES)?;
        let legacy = legacy_config.as_ref().is_some_and(|v| {
            !v.is_empty()
                || (global_config.is_none()
                    && std::fs::metadata(&legacy_path).is_ok_and(|m| !m.permissions().readonly()))
        });
        Ok(Self {
            credential,
            legacy_config,
            global_config,
            settings,
            legacy,
        })
    }
    pub fn config(&self) -> Option<&[u8]> {
        if self.legacy {
            self.legacy_config.as_deref()
        } else {
            self.global_config.as_deref()
        }
    }
    pub fn config_path(&self, paths: &ClaudeAccountPaths) -> PathBuf {
        if self.legacy {
            paths.live_directory.join(".config.json")
        } else {
            paths.global_config.clone()
        }
    }
    pub fn validate(&self) -> AccountResult<()> {
        if let Some(settings) = &self.settings {
            reject_routes(&identity::object(settings)?)?;
        }
        if let Some(config) = self.config() {
            reject_routes(&identity::object(config)?)?;
        }
        Ok(())
    }
    pub fn account(&self) -> AccountResult<Value> {
        self.validate()?;
        identity::object(self.config().ok_or_else(|| fail("claude_login_required"))?)?
            .get("oauthAccount")
            .filter(|v| v.is_object())
            .cloned()
            .ok_or_else(|| fail("claude_identity_unverified"))
    }
    pub fn merged(&self, credential: &StoredCredential) -> AccountResult<Self> {
        let mut next = self.clone();
        let mut raw = identity::object(
            self.credential
                .as_deref()
                .ok_or_else(|| fail("claude_login_required"))?,
        )?;
        raw["claudeAiOauth"] = identity::object(&credential.bytes)?["claudeAiOauth"].clone();
        next.credential =
            Some(serde_json::to_vec(&raw).map_err(|_| fail("claude_credentials_invalid"))?);
        let mut config =
            identity::object(self.config().ok_or_else(|| fail("claude_login_required"))?)?;
        config["oauthAccount"] = credential.oauth_account.clone();
        let encoded =
            Some(serde_json::to_vec(&config).map_err(|_| fail("claude_credentials_invalid"))?);
        if next.legacy {
            next.legacy_config = encoded
        } else {
            next.global_config = encoded
        }
        Ok(next)
    }
}
fn reject_routes(value: &Value) -> AccountResult<()> {
    const BLOCKED: &[&str] = &[
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_PROFILE",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CODE_USE_FOUNDRY",
        "CLAUDE_CODE_USE_MANTLE",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
        "ANTHROPIC_FEDERATION_RULE",
    ];
    if BLOCKED.iter().any(|k| {
        value
            .get("env")
            .and_then(|v| v.get(k))
            .is_some_and(|v| !v.is_null() && v.as_str() != Some(""))
    }) || ["primaryApiKey", "apiKeyHelper", "forceLoginGatewayUrl"]
        .iter()
        .any(|k| {
            value
                .get(k)
                .is_some_and(|v| !v.is_null() && v.as_str() != Some(""))
        })
        || value
            .get("forceLoginMethod")
            .and_then(Value::as_str)
            .is_some_and(|v| v != "claudeai")
    {
        return Err(fail("claude_custom_route_read_only"));
    }
    Ok(())
}
#[derive(Serialize, Deserialize)]
pub(super) struct Journal {
    pub schema: u32,
    pub account_id: String,
    pub before: Target,
    pub written: Target,
    pub identity: String,
}
pub(super) fn read_journal(
    paths: &ClaudeAccountPaths,
    protector: &dyn SecretProtector,
) -> AccountResult<Option<Journal>> {
    let Some(bytes) = shared::read_optional(&paths.journal(), 16 * MAX_BYTES)? else {
        return Ok(None);
    };
    let journal: Journal = serde_json::from_slice(&protector.unseal(JOURNAL_CONTEXT, &bytes)?)
        .map_err(|_| fail("recovery_required"))?;
    if journal.schema != 1 || !shared::valid_id(&journal.account_id) || journal.identity.len() != 64
    {
        return Err(fail("recovery_required"));
    }
    Ok(Some(journal))
}
pub(super) fn save_journal(
    paths: &ClaudeAccountPaths,
    protector: &dyn SecretProtector,
    journal: &Journal,
) -> AccountResult<()> {
    let bytes = serde_json::to_vec(journal).map_err(|_| fail("recovery_required"))?;
    shared::atomic_write(&paths.journal(), &protector.seal(JOURNAL_CONTEXT, &bytes)?)
}
pub(super) fn clear_journal(paths: &ClaudeAccountPaths) -> AccountResult<()> {
    std::fs::remove_file(paths.journal()).map_err(|_| fail("recovery_required"))
}
pub(super) fn restore(
    paths: &ClaudeAccountPaths,
    before: &Target,
    written: &Target,
) -> AccountResult<()> {
    let current = Target::read(paths)?;
    let auth = paths.live_directory.join(".credentials.json");
    let config = before.config_path(paths);
    for (path, actual, ours, old) in [
        (
            &auth,
            current.credential.as_deref(),
            written.credential.as_deref(),
            before.credential.as_deref(),
        ),
        (&config, current.config(), written.config(), before.config()),
    ] {
        if actual == ours && actual != old {
            if let Some(bytes) = old {
                shared::atomic_write(path, bytes)?;
            } else {
                std::fs::remove_file(path).map_err(|_| fail("rollback_failed"))?;
            }
        }
    }
    if Target::read(paths)? != *before {
        return Err(fail("external_change_preserved"));
    }
    Ok(())
}

/// Matching Claude Code/claude-swap proper-lockfile directory locations and
/// acquisition order. Unknown/stale locks are never stolen. Owner marker makes
/// a crashed lock conservative instead of allowing unsafe timestamp takeover.
pub(super) struct MutationLocks {
    locks: Vec<(PathBuf, Vec<u8>)>,
}
impl MutationLocks {
    pub fn acquire(paths: &ClaudeAccountPaths, target: &Target) -> AccountResult<Self> {
        let mut result = Self { locks: vec![] };
        let legacy = paths.live_directory.with_file_name(format!(
            "{}.lock",
            paths
                .live_directory
                .file_name()
                .and_then(|v| v.to_str())
                .ok_or_else(|| fail("account_paths_invalid"))?
        ));
        let config = target.config_path(paths);
        let config_lock = config.with_file_name(format!(
            "{}.lock",
            config
                .file_name()
                .and_then(|v| v.to_str())
                .ok_or_else(|| fail("account_paths_invalid"))?
        ));
        for path in [
            paths.live_directory.join(".oauth_refresh.lock"),
            legacy,
            config_lock,
        ] {
            shared::ensure_no_links(&path)?;
            shared::create_private_directory(&path).map_err(|_| fail("claude_account_busy"))?;
            let marker = super::super::nonce()?.into_bytes();
            result.locks.push((path.clone(), marker.clone()));
            shared::atomic_write(&path.join("aigoodbro-owner"), &marker)?;
        }
        result.verify()?;
        Ok(result)
    }
    pub fn verify(&self) -> AccountResult<()> {
        for (path, marker) in &self.locks {
            if shared::read_optional(&path.join("aigoodbro-owner"), 64)?.as_ref() != Some(marker) {
                return Err(fail("claude_ownership_unknown"));
            }
        }
        Ok(())
    }
}
impl Drop for MutationLocks {
    fn drop(&mut self) {
        for (path, marker) in self.locks.iter().rev() {
            if shared::read_optional(&path.join("aigoodbro-owner"), 64)
                .ok()
                .flatten()
                .as_ref()
                == Some(marker)
            {
                let _ = std::fs::remove_file(path.join("aigoodbro-owner"));
                let _ = std::fs::remove_dir(path);
            }
        }
    }
}
