use super::account_lifecycle::ManagedAccountState;
use crate::app_state::{AppConfig, AppState};
use codexu_core::accounts::AccountManager;
use codexu_core::local_cli::{LocalCliKind, PlatformDirectories};
use codexu_core::profiles::{normalize_root_for, same_root};
use std::path::PathBuf;
use std::sync::Arc;
use tauri::{AppHandle, Emitter, State};

#[derive(serde::Serialize)]
pub struct ProfileDto {
    id: String,
    label: String,
    selected: bool,
    platform: String,
    platform_name: String,
    /// Only Codex directories can become the dashboard data source.
    can_view_usage: bool,
    /// Display metadata is owned by the managed vault, not the linked catalog.
    managed: bool,
}

#[derive(serde::Serialize)]
pub struct PlatformDto {
    id: String,
    name: String,
    command: String,
    default_directory: Option<String>,
    isolation: String,
    quota_supported: bool,
    desktop: bool,
}

fn project(
    config: &AppConfig,
    manager: Option<&AccountManager>,
) -> Result<Vec<ProfileDto>, String> {
    config
        .profiles
        .validate()
        .map_err(|_| "Profile catalog needs recovery".to_string())?;
    let selected = config
        .codex_root
        .canonicalize()
        .unwrap_or_else(|_| config.codex_root.clone());
    let metadata = match manager {
        Some(manager) => manager
            .project_profile_metadata(&config.profiles)
            .map_err(|e| e.code.to_owned())?,
        None => config
            .profiles
            .entries
            .iter()
            .map(|p| codexu_core::accounts::metadata::ProfileMetadata {
                id: p.id,
                label: p.label.clone(),
                managed_id: None,
            })
            .collect(),
    };
    metadata
        .into_iter()
        .map(|row| {
            let p = config
                .profiles
                .get(row.id)
                .map_err(|_| "Profile catalog needs recovery".to_owned())?;
            Ok(ProfileDto {
                id: p.id.to_string(),
                label: row.label,
                selected: same_root(&p.root, &selected),
                platform: p.kind.id().to_string(),
                platform_name: p.kind.display_name().to_string(),
                can_view_usage: p.kind == LocalCliKind::Codex,
                managed: row.managed_id.is_some(),
            })
        })
        .collect()
}

// The caller holds the catalog read lock until this bounded metadata operation
// completes. No settings write occurs for a managed alias or managed move.
fn managed_action(
    config: &AppConfig,
    manager: Option<&AccountManager>,
    action: &ProfileAction,
) -> Result<bool, String> {
    let id = match action {
        ProfileAction::Rename { id, .. } | ProfileAction::Move { id, .. } => {
            parse_id(id).map_err(|_| "Invalid profile ID")?
        }
        _ => return Ok(false),
    };
    let p = config.profiles.get(id).map_err(|_| "Invalid profile ID")?;
    if p.kind != LocalCliKind::Codex {
        return Ok(false);
    }
    let manager = manager.ok_or("account_service_unavailable")?;
    match action {
        ProfileAction::Rename { label, .. } => {
            let rows = manager
                .project_profile_metadata(&config.profiles)
                .map_err(|e| e.code.to_owned())?;
            let row = rows
                .iter()
                .find(|row| row.id == id)
                .ok_or("account_not_found")?;
            if let Some(managed_id) = &row.managed_id {
                manager
                    .rename_managed_account(managed_id, label.clone())
                    .map_err(|e| e.code.to_owned())?;
                Ok(true)
            } else {
                Ok(false)
            }
        }
        ProfileAction::Move { delta, .. } => manager
            .move_projected_managed_profile(&config.profiles, id, *delta)
            .map_err(|e| e.code.to_owned()),
        _ => Ok(false),
    }
}

#[tauri::command]
pub async fn list_platforms() -> Result<Vec<PlatformDto>, String> {
    let directories = PlatformDirectories::detect();
    Ok(LocalCliKind::ALL
        .iter()
        .map(|kind| PlatformDto {
            id: kind.id().to_string(),
            name: kind.display_name().to_string(),
            command: kind.command_name().to_string(),
            default_directory: Some(
                directories
                    .default_directory(*kind)
                    .to_string_lossy()
                    .to_string(),
            ),
            isolation: match kind.isolation_mode() {
                codexu_core::local_cli::IsolationMode::Managed => "managed",
                codexu_core::local_cli::IsolationMode::DefaultOnly => "default_only",
                codexu_core::local_cli::IsolationMode::Unsupported => "unsupported",
            }
            .to_string(),
            quota_supported: matches!(
                kind,
                LocalCliKind::Codex
                    | LocalCliKind::Antigravity
                    | LocalCliKind::Grok
                    | LocalCliKind::Kimi
                    | LocalCliKind::OpenCode
            ),
            desktop: kind.is_desktop_application(),
        })
        .collect())
}

#[tauri::command]
pub async fn list_profiles(
    state: State<'_, Arc<AppState>>,
    managed: State<'_, ManagedAccountState>,
) -> Result<Vec<ProfileDto>, String> {
    let config = state.config.read().await;
    project(&config, managed.manager().ok().as_deref())
}

#[derive(serde::Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum ProfileAction {
    Link {
        label: String,
        root: PathBuf,
        /// Defaults to `codex` for clients that predate multi-platform linking.
        #[serde(default)]
        platform: Option<String>,
    },
    Rename {
        id: String,
        label: String,
    },
    Move {
        id: String,
        delta: i8,
    },
    Remove {
        id: String,
    },
    View {
        id: String,
    },
}

fn parse_platform(value: &Option<String>) -> anyhow::Result<LocalCliKind> {
    let requested = value.as_deref().unwrap_or("codex");
    LocalCliKind::parse(requested).ok_or_else(|| anyhow::anyhow!("Unknown platform"))
}

fn parse_id(id: &str) -> anyhow::Result<u64> {
    id.parse()
        .map_err(|_| anyhow::anyhow!("Invalid profile ID"))
}

#[tauri::command]
pub async fn update_profile(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    workflow: State<'_, crate::commands::cli_workflow::WorkflowState>,
    managed: State<'_, ManagedAccountState>,
    action: ProfileAction,
) -> Result<Vec<ProfileDto>, String> {
    // Canonicalize only explicit user-selected input. Return no path or OS error to the UI.
    let action = if let ProfileAction::Link {
        label,
        root,
        platform,
    } = action
    {
        let kind = parse_platform(&platform).map_err(|_| "Unknown platform".to_string())?;
        let checked = tokio::task::spawn_blocking(move || normalize_root_for(kind, &root))
            .await
            .map_err(|_| "Directory check failed".to_string())?
            .map_err(|_| {
                format!(
                    "Select an existing {} account directory",
                    kind.display_name()
                )
            })?;
        ProfileAction::Link {
            label,
            root: checked,
            platform: Some(kind.id().to_string()),
        }
    } else {
        action
    };
    {
        let config = state.config.read().await;
        let manager = managed.manager().ok();
        if managed_action(&config, manager.as_deref(), &action)? {
            let _ = app.emit("managed-accounts:changed", ());
            let _ = app.emit("profiles:changed", ());
            return project(&config, manager.as_deref());
        }
    }
    let source_changed = matches!(&action, ProfileAction::View { .. });
    let removing = match &action {
        ProfileAction::Remove { id } => Some(id.parse::<u64>().map_err(|_| "Invalid profile ID")?),
        _ => None,
    };
    if let Some(id) = removing {
        crate::commands::cli_workflow::begin_remove(&workflow, id).await?;
    }
    let result = state
        .try_update_config(move |config| {
            match action {
                ProfileAction::Link {
                    label,
                    root,
                    platform,
                } => {
                    let kind = parse_platform(&platform)?;
                    config.profiles.add(kind, label, root)?
                }
                ProfileAction::Rename { id, label } => {
                    config.profiles.rename(parse_id(&id)?, label)?
                }
                ProfileAction::Move { id, delta } => {
                    config.profiles.move_one(parse_id(&id)?, delta)?
                }
                ProfileAction::Remove { id } => config.profiles.remove(parse_id(&id)?)?,
                ProfileAction::View { id } => {
                    let parsed = parse_id(&id)?;
                    let root = config.profiles.get(parsed)?.root.clone();
                    let kind = config
                        .profiles
                        .kind_of(parsed)
                        .unwrap_or(LocalCliKind::Codex);
                    // Only a Codex directory can become the dashboard source.
                    anyhow::ensure!(
                        kind == LocalCliKind::Codex,
                        "Only Codex directories feed the usage dashboard"
                    );
                    anyhow::ensure!(
                        normalize_root_for(kind, &root)? == root,
                        "Linked directory changed"
                    );
                    config.codex_root = root;
                }
            }
            Ok(())
        })
        .await;
    if let Some(id) = removing {
        crate::commands::cli_workflow::end_remove(&workflow, id).await;
    }
    let config = result.map_err(|_| "Could not save: check alias, duplicate directory or stale profile; prior settings retained".to_string())?;
    let _ = app.emit("profiles:changed", ());
    if source_changed {
        let _ = app.emit("usage:source-changed", ());
    }
    project(&config, managed.manager().ok().as_deref())
}

#[cfg(test)]
#[path = "profile_metadata_tests.rs"]
mod metadata_tests;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dto_omits_private_roots_and_ids_are_strings() {
        let mut config = AppConfig::default();
        config
            .profiles
            .add(
                LocalCliKind::Codex,
                "Synthetic".into(),
                std::env::temp_dir().join("synthetic-codex-home"),
            )
            .unwrap();
        let json = serde_json::to_value(project(&config, None).unwrap()).unwrap();
        assert_eq!(json[0]["id"], "1");
        assert_eq!(json[0]["platform"], "codex");
        assert_eq!(json[0]["can_view_usage"], true);
        assert_eq!(json[0].as_object().unwrap().len(), 7);
        assert_eq!(json[0]["managed"], false);
        assert!(json[0].get("root").is_none());
        assert!(
            serde_json::to_string(&json)
                .unwrap()
                .contains("synthetic-codex-home")
                == false
        );
    }

    #[test]
    fn non_codex_platforms_are_exposed_but_cannot_become_the_source() {
        let mut config = AppConfig::default();
        config
            .profiles
            .add(
                LocalCliKind::Antigravity,
                "Gravity".into(),
                std::env::temp_dir().join("synthetic-antigravity"),
            )
            .unwrap();
        let json = serde_json::to_value(project(&config, None).unwrap()).unwrap();
        assert_eq!(json[0]["platform"], "antigravity");
        assert_eq!(json[0]["platform_name"], "Antigravity");
        assert_eq!(json[0]["can_view_usage"], false);
        assert_eq!(json[0]["selected"], false);
    }

    #[test]
    fn unknown_platforms_are_rejected_and_codex_remains_the_default() {
        assert_eq!(parse_platform(&None).unwrap(), LocalCliKind::Codex);
        assert_eq!(
            parse_platform(&Some("antigravity".to_string())).unwrap(),
            LocalCliKind::Antigravity
        );
        assert!(parse_platform(&Some("invented-platform".to_string())).is_err());
    }
}
