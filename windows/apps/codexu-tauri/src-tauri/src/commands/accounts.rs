//! Account workbench IPC.
//!
//! This layer is a thin shell: the domain rules live in `codexu-core` where they
//! are unit tested. The command only resolves paths, moves blocking file IO off
//! the async runtime, and persists validated overrides atomically.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use chrono::{Duration, Utc};
use tauri::State;

use codexu_core::models::account::{AccountRecord, ExecutionPreference, PreferenceOverrides};
use codexu_core::models::quota::AccountQuotaSnapshot;
use codexu_core::readers::codex_accounts::{CodexAccountReader, SYSTEM_ACCOUNT_ID};
use codexu_core::readers::{
    degrade_stale_quality, quota_snapshot_from_official, read_codex_quota, OfficialQuotaInput,
};

use crate::app_state::AppState;

/// File name of the persisted preference overrides, inside the app data dir.
const PREFERENCES_FILE_NAME: &str = "account-preferences.json";

/// Managed profile root, relative to the app data directory.
///
/// This is the Next namespace: it must not reuse a legacy `codexu` directory or
/// the macOS `.codex-account-manager-next` layout.
const PROFILES_DIRECTORY_NAME: &str = "profiles";

/// How long an official quota observation stays usable as current evidence.
const QUOTA_EVIDENCE_MAX_AGE_MINUTES: i64 = 30;

#[derive(Debug, serde::Serialize)]
pub struct AccountsDto {
    pub accounts: Vec<AccountRecord>,
    /// Official quota keyed by account id. A missing key means "not read yet",
    /// which the UI renders as unknown rather than as zero.
    pub quotas: BTreeMap<String, AccountQuotaSnapshot>,
    /// Basename of the managed profile root. The absolute path is never sent.
    pub profiles_root_label: String,
    pub messages: Vec<String>,
}

/// List the system login and every managed profile.
///
/// The system account is always reported, even when signed out, so the UI can
/// show an explicit state instead of an empty list.
#[tauri::command]
pub async fn list_accounts(state: State<'_, Arc<AppState>>) -> Result<AccountsDto, String> {
    let (codex_root, app_data_dir) = {
        let config = state.config.read().await;
        (config.codex_root.clone(), state.app_data_dir.clone())
    };

    let profiles_root = profiles_root(&app_data_dir);
    let reader = CodexAccountReader::new(codex_root, profiles_root.clone());

    let mut accounts = tokio::task::spawn_blocking(move || reader.read_all())
        .await
        .map_err(|error| format!("Account reader task failed: {error}"))?;

    let mut messages = Vec::new();
    match load_overrides(&preferences_path(&app_data_dir)) {
        Ok(mut overrides) => {
            let dropped = overrides.sanitize();
            if dropped > 0 {
                messages.push(format!(
                    "Ignored {dropped} saved execution preference(s) that no longer validate."
                ));
            }
            overrides.apply(&mut accounts);
        }
        Err(error) => {
            // Fail closed: keep the defaults rather than applying a file that
            // could not be parsed cleanly.
            messages.push(format!("Saved execution preferences were ignored: {error}"));
        }
    }

    let quotas = system_account_quotas(&state).await;

    Ok(AccountsDto {
        accounts,
        quotas,
        profiles_root_label: directory_label(&profiles_root),
        messages,
    })
}

/// Derive the workbench quota for the system login from the cached dashboard.
///
/// The dashboard pipeline already reads the official app-server quota and
/// applies its own retention rule, so this reuses that observation instead of
/// spawning a second app-server. Managed profiles have no read path yet and are
/// therefore absent from the map, which the UI renders as unknown.
async fn system_account_quotas(state: &State<'_, Arc<AppState>>) -> BTreeMap<String, AccountQuotaSnapshot> {
    let mut quotas = BTreeMap::new();

    let usage = {
        let cached = state.snapshot.read().await;
        cached
            .as_ref()
            .and_then(|cached| cached.dashboard.as_ref())
            .map(|dashboard| dashboard.codex.snapshot.clone())
    };

    let Some(usage) = usage else {
        return quotas;
    };

    let built = quota_snapshot_from_official(
        SYSTEM_ACCOUNT_ID,
        OfficialQuotaInput::from_usage_snapshot(&usage),
        usage.refreshed_at,
    );
    let degraded = degrade_stale_quality(
        built,
        Utc::now(),
        Duration::minutes(QUOTA_EVIDENCE_MAX_AGE_MINUTES),
    );

    quotas.insert(SYSTEM_ACCOUNT_ID.to_string(), degraded);
    quotas
}

#[derive(Debug, serde::Deserialize)]
pub struct SetPreferenceRequest {
    pub account_id: String,
    pub preference: ExecutionPreference,
}

/// Read official quota for one account.
///
/// The system login uses the default Codex home. Managed profiles pass their
/// isolated directory as `CODEX_HOME`. The absolute path never leaves this
/// command: the UI only sees the account id and the reduced quota snapshot.
#[tauri::command]
pub async fn refresh_account_quota(
    state: State<'_, Arc<AppState>>,
    account_id: String,
) -> Result<AccountQuotaSnapshot, String> {
    let app_data_dir = state.app_data_dir.clone();
    let home = if account_id == SYSTEM_ACCOUNT_ID {
        None
    } else {
        Some(managed_codex_home(&profiles_root(&app_data_dir), &account_id)?)
    };

    let quota = read_codex_quota(home.as_deref())
        .await
        .map_err(|error| error.to_string())?;
    let built = quota_snapshot_from_official(
        &account_id,
        OfficialQuotaInput::from_app_server(&quota),
        Utc::now(),
    );
    Ok(degrade_stale_quality(
        built,
        Utc::now(),
        Duration::minutes(QUOTA_EVIDENCE_MAX_AGE_MINUTES),
    ))
}

fn managed_codex_home(profiles_root: &Path, account_id: &str) -> Result<PathBuf, String> {
    if account_id.is_empty()
        || account_id == "."
        || account_id == ".."
        || account_id == SYSTEM_ACCOUNT_ID
        || account_id.contains('/')
        || account_id.contains('\\')
        || account_id.contains('\0')
    {
        return Err("account id is not a managed profile".to_string());
    }
    let home = profiles_root.join(account_id);
    if !home.is_dir() {
        return Err("managed profile directory was not found".to_string());
    }
    Ok(home)
}

/// Persist an execution preference for one account.
///
/// Rejects an unusable preference instead of storing it, because a task that
/// starts with unusable parameters has already reserved the account.
#[tauri::command]
pub async fn set_account_preference(
    state: State<'_, Arc<AppState>>,
    req: SetPreferenceRequest,
) -> Result<ExecutionPreference, String> {
    let app_data_dir = state.app_data_dir.clone();
    let path = preferences_path(&app_data_dir);

    let mut overrides = load_overrides(&path)?;
    overrides
        .set(&req.account_id, req.preference.clone())
        .map_err(|error| error.to_string())?;
    save_overrides(&path, &overrides)?;

    Ok(req.preference)
}

fn profiles_root(app_data_dir: &Path) -> PathBuf {
    app_data_dir.join(PROFILES_DIRECTORY_NAME)
}

fn preferences_path(app_data_dir: &Path) -> PathBuf {
    app_data_dir.join(PREFERENCES_FILE_NAME)
}

fn directory_label(path: &Path) -> String {
    path.file_name()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_else(|| PROFILES_DIRECTORY_NAME.to_string())
}

/// Read the override file. A missing file is an empty set, not an error.
fn load_overrides(path: &Path) -> Result<PreferenceOverrides, String> {
    match std::fs::read_to_string(path) {
        Ok(raw) if raw.trim().is_empty() => Ok(PreferenceOverrides::default()),
        Ok(raw) => serde_json::from_str(&raw)
            .map_err(|error| format!("preferences file is not valid JSON: {error}")),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            Ok(PreferenceOverrides::default())
        }
        Err(error) => Err(format!("preferences file could not be read: {error}")),
    }
}

/// Write the override file atomically so an interrupted write cannot leave a
/// truncated file behind.
fn save_overrides(path: &Path, overrides: &PreferenceOverrides) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|error| format!("preferences directory could not be created: {error}"))?;
    }

    let encoded = serde_json::to_vec_pretty(overrides)
        .map_err(|error| format!("preferences could not be encoded: {error}"))?;

    let temporary = path.with_extension("json.tmp");
    std::fs::write(&temporary, &encoded)
        .map_err(|error| format!("preferences could not be written: {error}"))?;
    std::fs::rename(&temporary, path)
        .map_err(|error| format!("preferences could not be committed: {error}"))?;

    Ok(())
}
