use crate::app_state::{AppConfig, AppState};
use codexu_core::local_cli::LocalCliKind;
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

fn project(config: &AppConfig) -> Result<Vec<ProfileDto>, String> {
    config
        .profiles
        .validate()
        .map_err(|_| "Profile catalog needs recovery".to_string())?;
    let selected = config
        .codex_root
        .canonicalize()
        .unwrap_or_else(|_| config.codex_root.clone());
    Ok(config
        .profiles
        .entries
        .iter()
        .map(|p| ProfileDto {
            id: p.id.to_string(),
            label: p.label.clone(),
            selected: same_root(&p.root, &selected),
            platform: p.kind.id().to_string(),
            platform_name: p.kind.display_name().to_string(),
            can_view_usage: p.kind == LocalCliKind::Codex,
        })
        .collect())
}

fn home_directories() -> (PathBuf, PathBuf, PathBuf) {
    let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
    let roaming = dirs::config_dir().unwrap_or_else(|| home.join("AppData").join("Roaming"));
    let local = dirs::data_local_dir().unwrap_or_else(|| home.join("AppData").join("Local"));
    (home, roaming, local)
}

#[tauri::command]
pub async fn list_platforms() -> Result<Vec<PlatformDto>, String> {
    let (home, roaming, local) = home_directories();
    Ok(LocalCliKind::ALL
        .iter()
        .map(|kind| PlatformDto {
            id: kind.id().to_string(),
            name: kind.display_name().to_string(),
            command: kind.command_name().to_string(),
            default_directory: Some(
                kind.default_config_directory(&home, &roaming, &local)
                    .to_string_lossy()
                    .to_string(),
            ),
            isolation: match kind.isolation_mode() {
                codexu_core::local_cli::IsolationMode::Managed => "managed",
                codexu_core::local_cli::IsolationMode::DefaultOnly => "default_only",
                codexu_core::local_cli::IsolationMode::Unsupported => "unsupported",
            }
            .to_string(),
            quota_supported: *kind == LocalCliKind::Codex || *kind == LocalCliKind::Antigravity,
            desktop: kind.is_desktop_application(),
        })
        .collect())
}

#[tauri::command]
pub async fn list_profiles(state: State<'_, Arc<AppState>>) -> Result<Vec<ProfileDto>, String> {
    let config = state.config.read().await;
    project(&config)
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
    project(&config)
}

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
        let json = serde_json::to_value(project(&config).unwrap()).unwrap();
        assert_eq!(json[0]["id"], "1");
        assert_eq!(json[0]["platform"], "codex");
        assert_eq!(json[0]["can_view_usage"], true);
        assert_eq!(json[0].as_object().unwrap().len(), 6);
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
        let json = serde_json::to_value(project(&config).unwrap()).unwrap();
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
