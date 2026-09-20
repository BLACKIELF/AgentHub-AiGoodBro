use crate::app_state::{AppConfig, AppState};
use codexu_core::profiles::{normalize_root, same_root};
use std::path::PathBuf;
use std::sync::Arc;
use tauri::{AppHandle, Emitter, State};

#[derive(serde::Serialize)]
pub struct ProfileDto {
    id: String,
    label: String,
    selected: bool,
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
    Link { label: String, root: PathBuf },
    Rename { id: String, label: String },
    Move { id: String, delta: i8 },
    Remove { id: String },
    View { id: String },
}

fn parse_id(id: &str) -> anyhow::Result<u64> {
    id.parse()
        .map_err(|_| anyhow::anyhow!("Invalid profile ID"))
}

#[tauri::command]
pub async fn update_profile(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    action: ProfileAction,
) -> Result<Vec<ProfileDto>, String> {
    // Canonicalize only explicit user-selected input. Return no path or OS error to the UI.
    let action = if let ProfileAction::Link { label, root } = action {
        let root = tokio::task::spawn_blocking(move || normalize_root(&root))
            .await
            .map_err(|_| "Directory check failed".to_string())?
            .map_err(|_| "Select an existing Codex data directory".to_string())?;
        ProfileAction::Link { label, root }
    } else {
        action
    };
    let source_changed = matches!(&action, ProfileAction::View { .. });
    let config = state.try_update_config(move |config| {
        match action {
            ProfileAction::Link { label, root } => config.profiles.add(label, root)?,
            ProfileAction::Rename { id, label } => config.profiles.rename(parse_id(&id)?, label)?,
            ProfileAction::Move { id, delta } => config.profiles.move_one(parse_id(&id)?, delta)?,
            ProfileAction::Remove { id } => config.profiles.remove(parse_id(&id)?)?,
            ProfileAction::View { id } => {
                let root = config.profiles.get(parse_id(&id)?)?.root.clone();
                anyhow::ensure!(normalize_root(&root)? == root, "Linked directory changed");
                config.codex_root = root;
            }
        }
        Ok(())
    }).await.map_err(|_| "Could not save: check alias, duplicate directory or stale profile; prior settings retained".to_string())?;
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
                "Synthetic".into(),
                std::env::temp_dir().join("synthetic-codex-home"),
            )
            .unwrap();
        let json = serde_json::to_value(project(&config).unwrap()).unwrap();
        assert_eq!(json[0]["id"], "1");
        assert_eq!(json[0].as_object().unwrap().len(), 3);
        assert!(json[0].get("root").is_none());
    }
}
