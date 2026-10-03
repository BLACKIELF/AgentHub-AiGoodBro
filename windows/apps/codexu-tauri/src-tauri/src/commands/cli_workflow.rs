//! Explicit, directory-scoped interactive terminals. Never submits a prompt.
use crate::app_state::AppState;
use codexu_core::{
    profiles::normalize_root,
    workflow::{
        interactive_arguments, resolve_selection, WorkflowModel, WorkflowPreference,
        WorkflowPreferences,
    },
    workflow_reader::read_evidence,
};
use std::{
    collections::BTreeMap,
    io::Read,
    path::{Path, PathBuf},
    sync::Arc,
};
use tauri::State;
use tokio::sync::Mutex;

#[path = "cli_workflow_console.rs"]
mod console;

#[derive(Clone, Copy, Default, serde::Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum Phase {
    #[default]
    Idle,
    Checking,
    Running,
    Exited,
    Stopped,
    Failed,
}

#[derive(Default)]
struct Session {
    generation: u64,
    phase: Phase,
    started_at: Option<i64>,
    process: Option<console::OwnedConsole>,
    removing: bool,
}

impl Session {
    fn refresh(&mut self) {
        if let Some(process) = &mut self.process {
            match process.has_exited() {
                Ok(true) => {
                    self.process = None;
                    self.phase = Phase::Exited;
                }
                Ok(false) => {}
                // Keep the handle so cancellation remains possible if status inspection fails.
                Err(_) => {}
            }
        }
    }
    fn active(&self) -> bool {
        self.phase == Phase::Checking || self.process.is_some()
    }
}

#[derive(Default)]
pub struct WorkflowState {
    sessions: Mutex<BTreeMap<u64, Session>>,
}

#[derive(serde::Serialize)]
pub struct WorkflowDto {
    profile_id: String,
    preference: WorkflowPreference,
    phase: Phase,
    started_at: Option<i64>,
    supported: bool,
}

fn parse_id(id: &str) -> Result<u64, String> {
    id.parse()
        .ok()
        .filter(|id| *id > 0)
        .ok_or_else(|| "source_changed".into())
}

fn read_preferences(directory: &Path) -> anyhow::Result<WorkflowPreferences> {
    let path = directory.join("workflow-preferences-v1.json");
    let result: WorkflowPreferences = match std::fs::symlink_metadata(&path) {
        Ok(meta) => {
            anyhow::ensure!(
                meta.is_file() && !meta.file_type().is_symlink() && meta.len() <= 1024 * 1024,
                "Invalid workflow settings"
            );
            let mut bytes = Vec::new();
            std::fs::File::open(path)?
                .take(1024 * 1024 + 1)
                .read_to_end(&mut bytes)?;
            anyhow::ensure!(bytes.len() <= 1024 * 1024, "Workflow settings too large");
            serde_json::from_slice(&bytes)?
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            WorkflowPreferences::default()
        }
        Err(error) => return Err(error.into()),
    };
    result.validate()?;
    Ok(result)
}

fn save_preferences(directory: &Path, preferences: &WorkflowPreferences) -> anyhow::Result<()> {
    preferences.validate()?;
    codexu_core::atomic_settings::write_json(
        &directory.join("workflow-preferences-v1.json"),
        &serde_json::to_vec_pretty(preferences)?,
        |prior| {
            let prior: WorkflowPreferences = serde_json::from_slice(prior)?;
            prior.validate()
        },
    )
}

fn project(id: u64, preferences: &WorkflowPreferences, session: &mut Session) -> WorkflowDto {
    session.refresh();
    WorkflowDto {
        profile_id: id.to_string(),
        preference: preferences.profiles.get(&id).cloned().unwrap_or_default(),
        phase: session.phase,
        started_at: session.started_at,
        supported: cfg!(windows),
    }
}

async fn linked_root(state: &AppState, id: u64) -> Result<PathBuf, String> {
    let root = state
        .config
        .read()
        .await
        .profiles
        .get(id)
        .map_err(|_| "source_changed")?
        .root
        .clone();
    if normalize_root(&root).ok().as_ref() != Some(&root) {
        return Err("source_changed".into());
    }
    Ok(root)
}

fn auth_snapshot(root: &Path) -> anyhow::Result<Vec<u8>> {
    let path = root.join("auth.json");
    let metadata = std::fs::symlink_metadata(&path)?;
    anyhow::ensure!(
        metadata.is_file() && !metadata.file_type().is_symlink() && metadata.len() <= 1024 * 1024,
        "Login unavailable"
    );
    let mut bytes = Vec::new();
    std::fs::File::open(path)?
        .take(1024 * 1024 + 1)
        .read_to_end(&mut bytes)?;
    anyhow::ensure!(bytes.len() <= 1024 * 1024, "Login unavailable");
    let _: serde_json::Value = serde_json::from_slice(&bytes)?;
    Ok(bytes)
}

async fn native_executable() -> anyhow::Result<(PathBuf, std::fs::File)> {
    anyhow::ensure!(cfg!(windows), "Windows required");
    let mut candidates = Vec::new();
    let (package, triple) = if cfg!(target_arch = "aarch64") {
        ("codex-win32-arm64", "aarch64-pc-windows-msvc")
    } else {
        ("codex-win32-x64", "x86_64-pc-windows-msvc")
    };
    if let Some(app_data) = std::env::var_os("APPDATA") {
        candidates.push(
            PathBuf::from(app_data)
                .join("npm/node_modules/@openai/codex/node_modules/@openai")
                .join(package)
                .join("vendor")
                .join(triple)
                .join("bin/codex.exe"),
        );
    }
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        candidates.push(PathBuf::from(local).join("Microsoft/WinGet/Links/codex.exe"));
    }
    if let Some(path) = std::env::var_os("PATH") {
        candidates.extend(
            std::env::split_paths(&path)
                .filter(|path| path.is_absolute())
                .map(|path| path.join("codex.exe")),
        );
    }
    let mut checked = std::collections::HashSet::new();
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(6);
    for path in candidates.into_iter().take(100) {
        if tokio::time::Instant::now() >= deadline {
            break;
        }
        let Ok(path) = path.canonicalize() else {
            continue;
        };
        if !path.is_file()
            || !path
                .extension()
                .and_then(|value| value.to_str())
                .is_some_and(|value| value.eq_ignore_ascii_case("exe"))
            || !checked.insert(path.clone())
        {
            continue;
        }
        let Ok(guard) = console::lock_executable(&path) else {
            continue;
        };
        let mut command = tokio::process::Command::new(&path);
        command
            .arg("--version")
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true);
        #[cfg(windows)]
        command.creation_flags(0x0800_0000);
        let remaining = deadline
            .saturating_duration_since(tokio::time::Instant::now())
            .min(std::time::Duration::from_secs(2));
        let Ok(Ok(output)) = tokio::time::timeout(remaining, command.output()).await else {
            continue;
        };
        if output.status.success()
            && output.stdout.len() <= 256
            && std::str::from_utf8(&output.stdout)
                .ok()
                .is_some_and(|text| {
                    text.trim()
                        .strip_prefix("codex-cli ")
                        .is_some_and(|version| {
                            !version.is_empty()
                                && version
                                    .bytes()
                                    .all(|c| c.is_ascii_alphanumeric() || b".-+".contains(&c))
                        })
                })
        {
            return Ok((path, guard));
        }
    }
    anyhow::bail!("Native official CLI unavailable")
}

#[tauri::command]
pub async fn get_account_workflow(
    state: State<'_, Arc<AppState>>,
    workflow: State<'_, WorkflowState>,
    id: String,
) -> Result<WorkflowDto, String> {
    let id = parse_id(&id)?;
    state
        .config
        .read()
        .await
        .profiles
        .get(id)
        .map_err(|_| "source_changed")?;
    let mut sessions = workflow.sessions.lock().await;
    let preferences = read_preferences(&state.app_data_dir).map_err(|_| "settings_unavailable")?;
    Ok(project(id, &preferences, sessions.entry(id).or_default()))
}

#[derive(serde::Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum WorkflowAction {
    Participation {
        value: bool,
    },
    Selection {
        model: Option<String>,
        effort: Option<String>,
    },
}

#[tauri::command]
pub async fn set_account_workflow(
    state: State<'_, Arc<AppState>>,
    workflow: State<'_, WorkflowState>,
    id: String,
    action: WorkflowAction,
) -> Result<WorkflowDto, String> {
    let id = parse_id(&id)?;
    let config = state.config.read().await;
    config.profiles.get(id).map_err(|_| "source_changed")?;
    let mut sessions = workflow.sessions.lock().await;
    let mut preferences =
        read_preferences(&state.app_data_dir).map_err(|_| "settings_unavailable")?;
    match action {
        WorkflowAction::Participation { value } => preferences.set_participating(id, value),
        WorkflowAction::Selection { model, effort } => preferences.set_selection(id, model, effort),
    }
    .map_err(|_| "invalid_selection")?;
    save_preferences(&state.app_data_dir, &preferences).map_err(|_| "save_failed")?;
    // No quota read, identity lookup or process wait can block opt-out.
    Ok(project(id, &preferences, sessions.entry(id).or_default()))
}

#[tauri::command]
pub async fn read_workflow_models(
    state: State<'_, Arc<AppState>>,
    id: String,
) -> Result<Vec<WorkflowModel>, String> {
    let _permit = state
        .profile_quota_slots
        .try_acquire()
        .map_err(|_| "read_busy")?;
    let id = parse_id(&id)?;
    let root = linked_root(&state, id).await?;
    let auth = auth_snapshot(&root).map_err(|_| "login_unavailable")?;
    let (executable, _guard) = native_executable().await.map_err(|_| "cli_unavailable")?;
    let evidence = read_evidence(&executable, &root, &root)
        .await
        .map_err(|_| "models_unavailable")?;
    if linked_root(&state, id).await? != root || auth_snapshot(&root).ok().as_ref() != Some(&auth) {
        return Err("source_changed".into());
    }
    Ok(evidence.models)
}

#[tauri::command]
pub async fn start_account_terminal(
    state: State<'_, Arc<AppState>>,
    workflow: State<'_, WorkflowState>,
    id: String,
    workspace: PathBuf,
) -> Result<WorkflowDto, String> {
    let id = parse_id(&id)?;
    let root = linked_root(&state, id).await?;
    if !workspace.is_absolute() || !workspace.is_dir() {
        return Err("workspace_unavailable".into());
    }
    let workspace = workspace
        .canonicalize()
        .map_err(|_| "workspace_unavailable")?;
    let (executable, guard) = native_executable().await.map_err(|_| "cli_unavailable")?;
    let auth = auth_snapshot(&root).map_err(|_| "login_unavailable")?;
    let (generation, preference) = {
        let mut sessions = workflow.sessions.lock().await;
        let preferences =
            read_preferences(&state.app_data_dir).map_err(|_| "settings_unavailable")?;
        let preference = preferences.profiles.get(&id).cloned().unwrap_or_default();
        if !preference.participating {
            return Err("launch_disabled".into());
        }
        let session = sessions.entry(id).or_default();
        session.refresh();
        if session.active() || session.removing {
            return Err("already_running".into());
        }
        session.generation = session
            .generation
            .checked_add(1)
            .ok_or("session_unavailable")?;
        session.phase = Phase::Checking;
        (session.generation, preference)
    };
    let result = async {
        let _permit = state
            .profile_quota_slots
            .try_acquire()
            .map_err(|_| "read_busy")?;
        let evidence = read_evidence(&executable, &root, &workspace)
            .await
            .map_err(|_| "preflight_unavailable")?;
        evidence
            .validate_startup()
            .map_err(|_| "quota_or_identity_unavailable")?;
        let (model, effort) = resolve_selection(&preference, &evidence.models)
            .map_err(|_| "selection_unavailable")?;
        let args = interactive_arguments(&model, &effort).map_err(|_| "invalid_selection")?;
        let config = state.config.read().await;
        if config.profiles.get(id).map(|profile| &profile.root).ok() != Some(&root)
            || normalize_root(&root).ok().as_ref() != Some(&root)
            || auth_snapshot(&root).ok().as_ref() != Some(&auth)
        {
            return Err("source_changed");
        }
        let mut sessions = workflow.sessions.lock().await;
        let preferences =
            read_preferences(&state.app_data_dir).map_err(|_| "settings_unavailable")?;
        let current = preferences.profiles.get(&id).cloned().unwrap_or_default();
        let session = sessions.entry(id).or_default();
        if session.generation != generation || session.phase != Phase::Checking || session.removing
        {
            return Err("launch_cancelled");
        }
        if !current.participating {
            return Err("launch_disabled");
        }
        if current != preference {
            return Err("selection_changed");
        }
        let process = console::OwnedConsole::start(&executable, &root, &workspace, &args, guard)
            .map_err(|_| "launch_failed")?;
        session.process = Some(process);
        session.phase = Phase::Running;
        session.started_at = Some(chrono::Utc::now().timestamp_millis());
        Ok(project(id, &preferences, session))
    }
    .await;
    if result.is_err() {
        let mut sessions = workflow.sessions.lock().await;
        if let Some(session) = sessions.get_mut(&id) {
            if session.generation == generation && session.phase == Phase::Checking {
                session.phase = Phase::Failed;
            }
        }
    }
    result.map_err(str::to_owned)
}

#[tauri::command]
pub async fn stop_account_terminal(
    state: State<'_, Arc<AppState>>,
    workflow: State<'_, WorkflowState>,
    id: String,
) -> Result<WorkflowDto, String> {
    let id = parse_id(&id)?;
    let mut sessions = workflow.sessions.lock().await;
    // Allow stopping an owned session even if its directory was unlinked or became unavailable.
    let session = sessions.get_mut(&id).ok_or("session_unavailable")?;
    session.refresh();
    if let Some(process) = &mut session.process {
        process.stop().map_err(|_| "stop_failed")?;
    }
    session.process = None;
    session.generation = session
        .generation
        .checked_add(1)
        .ok_or("session_unavailable")?;
    session.phase = Phase::Stopped;
    let preferences = read_preferences(&state.app_data_dir).unwrap_or_default();
    Ok(project(id, &preferences, session))
}

/// Profile removal must call this before unlinking a row, keeping the owned
/// terminal's stop control reachable. Turning participation off stays allowed.
pub async fn has_owned_session(workflow: &WorkflowState, id: u64) -> bool {
    let mut sessions = workflow.sessions.lock().await;
    if let Some(session) = sessions.get_mut(&id) {
        session.refresh();
        session.active()
    } else {
        false
    }
}

pub async fn begin_remove(workflow: &WorkflowState, id: u64) -> Result<(), String> {
    let mut sessions = workflow.sessions.lock().await;
    let session = sessions.entry(id).or_default();
    session.refresh();
    if session.active() || session.removing {
        return Err("Stop this account's terminal before unlinking".into());
    }
    session.removing = true;
    Ok(())
}

pub async fn end_remove(workflow: &WorkflowState, id: u64) {
    if let Some(session) = workflow.sessions.lock().await.get_mut(&id) {
        session.removing = false;
    }
}

/// Use from ExitRequested before allowing a normal app quit. A contended
/// state is conservatively active, so a launch cannot race normal shutdown.
pub fn should_block_exit(workflow: &WorkflowState) -> bool {
    let Ok(mut sessions) = workflow.sessions.try_lock() else {
        return true;
    };
    sessions.values_mut().any(|session| {
        session.refresh();
        session.active()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preferences_are_atomic_and_contain_no_credentials_or_paths() {
        let directory = std::env::temp_dir().join(format!(
            "aigoodbro-workflow-{}-{}",
            std::process::id(),
            chrono::Utc::now().timestamp_nanos_opt().unwrap()
        ));
        let mut preferences = WorkflowPreferences::default();
        preferences.set_participating(1, true).unwrap();
        save_preferences(&directory, &preferences).unwrap();
        assert!(read_preferences(&directory).unwrap().profiles[&1].participating);
        let path = directory.join("workflow-preferences-v1.json");
        std::fs::write(&path, b"corrupt").unwrap();
        assert!(save_preferences(&directory, &preferences).is_err());
        assert_eq!(std::fs::read(path).unwrap(), b"corrupt");
        std::fs::remove_dir_all(directory).unwrap();
    }
    #[tokio::test]
    async fn remove_reservation_and_quit_guard_cover_pending_launches() {
        let workflow = WorkflowState::default();
        begin_remove(&workflow, 1).await.unwrap();
        assert!(workflow.sessions.lock().await[&1].removing);
        assert!(begin_remove(&workflow, 1).await.is_err());
        end_remove(&workflow, 1).await;
        assert!(!workflow.sessions.lock().await[&1].removing);
        workflow.sessions.lock().await.get_mut(&1).unwrap().phase = Phase::Checking;
        assert!(begin_remove(&workflow, 1).await.is_err());
        assert!(should_block_exit(&workflow));
        workflow.sessions.lock().await.get_mut(&1).unwrap().phase = Phase::Stopped;
        assert!(!should_block_exit(&workflow));
    }
}
