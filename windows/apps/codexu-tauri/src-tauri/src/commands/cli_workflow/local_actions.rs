//! Local provider actions share the existing profile catalog and owned Job.
use super::*;
use crate::commands::account_lifecycle::ClaudeSubscriptionState;
use codexu_core::{
    accounts::claude::{ClaudeOpenScope, ClaudeSubscriptionManager},
    local_cli::{
        self,
        launch::{self, Action, Edition, Environment, PreparedProfile},
        LocalCliKind, PlatformDirectories,
    },
};
use tauri::{AppHandle, Emitter};

pub(super) enum Executable {
    Native(launch::VerifiedExecutable),
    Package(Arc<local_cli::dependency::VerifiedRuntime>),
}
pub(super) async fn discover(
    app: &AppHandle,
    state: &Arc<AppState>,
    workflow: &WorkflowState,
    kind: LocalCliKind,
) -> Result<Executable, String> {
    if matches!(
        kind,
        LocalCliKind::Grok
            | LocalCliKind::OpenCode
            | LocalCliKind::Kimi
            | LocalCliKind::Gemini
            | LocalCliKind::WorkBuddy
    ) {
        let node = super::dependency_actions::trusted_node(app, workflow).await?;
        let directory = state.app_data_dir.clone();
        let runtime = tauri::async_runtime::spawn_blocking(move || {
            local_cli::dependency::load_runtime(&directory, kind, node)
        })
        .await
        .map_err(|_| "dependency_verification_failed")?;
        return Ok(Executable::Package(Arc::new(reason(runtime)?)));
    }
    Ok(Executable::Native(reason(
        tauri::async_runtime::spawn_blocking(move || {
            launch::discover(kind, &PlatformDirectories::detect())
        })
        .await
        .map_err(|_| "cli_unavailable")?,
    )?))
}

#[derive(Clone, serde::Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum LocalCliTarget {
    Profile {
        #[serde(rename = "profileId")]
        profile_id: String,
    },
    Default {
        platform: String,
        edition: Option<Edition>,
    },
    ClaudeSubscription {
        #[serde(rename = "accountId")]
        account_id: String,
    },
}
#[derive(serde::Serialize)]
pub struct LocalCliActionsDto {
    platform: String,
    can_login: bool,
    can_open: bool,
    reason_code: Option<String>,
    phase: &'static str,
}
#[derive(Clone, serde::Serialize)]
pub struct LocalCliSessionDto {
    session_id: String,
    platform: String,
    phase: &'static str,
    authentication_state: &'static str,
    reason_code: Option<&'static str>,
}
#[derive(serde::Serialize)]
pub struct LocalCliCreatedDto {
    profile_id: String,
    platform: String,
    phase: &'static str,
}
struct Target {
    key: String,
    profile: Option<u64>,
    kind: LocalCliKind,
    root: PathBuf,
    default: bool,
    claude: Option<(Arc<ClaudeSubscriptionManager>, ClaudeOpenScope)>,
}
struct LocalSession {
    dto: LocalCliSessionDto,
    key: String,
    profile: Option<u64>,
    kind: LocalCliKind,
    root: PathBuf,
    version: String,
    process: Option<console::OwnedConsole>,
    activity: Option<codexu_core::managed_proxy::ManagedActivityGuard>,
}
impl LocalSession {
    fn refresh(&mut self) {
        if let Some(process) = &mut self.process {
            if process.has_exited().unwrap_or(false) {
                self.process = None;
                self.activity = None;
                self.dto.phase = "exited";
            }
        }
        if let Ok(version) = launch::authentication_version(self.kind, &self.root) {
            if version != self.version {
                self.dto.authentication_state = "configuration_changed";
            }
        }
    }
    fn active(&self) -> bool {
        self.dto.phase == "checking" || self.process.is_some()
    }
}
#[derive(Default)]
pub(super) struct LocalState {
    sessions: Mutex<BTreeMap<String, LocalSession>>,
}

async fn resolve(
    state: &Arc<AppState>,
    claude: &ClaudeSubscriptionState,
    target: LocalCliTarget,
) -> Result<Target, String> {
    let dirs = PlatformDirectories::detect();
    match target {
        LocalCliTarget::Profile { profile_id } => {
            let id = parse_id(&profile_id)?;
            let profile = state
                .config
                .read()
                .await
                .profiles
                .get(id)
                .map_err(|_| "source_changed")?
                .clone();
            let kind = profile.kind;
            let root = launch::checked_directory(&profile.root).map_err(|e| e.code)?;
            if kind.requires_default_environment_for_launch() {
                return Err("default_environment_required".into());
            }
            Ok(Target {
                key: format!("profile-{id}"),
                profile: Some(id),
                kind,
                root,
                default: false,
                claude: None,
            })
        }
        LocalCliTarget::Default { platform, edition } => {
            let kind = LocalCliKind::parse(&platform).ok_or("platform_not_supported")?;
            if kind == LocalCliKind::ClaudeCode {
                return claude_target(claude, None);
            }
            let root = launch::default_root(&dirs, kind, edition).map_err(|e| e.code)?;
            Ok(Target {
                key: format!(
                    "default-{}-{}",
                    kind.id(),
                    edition.unwrap_or_default().directory()
                ),
                profile: None,
                kind,
                root,
                default: true,
                claude: None,
            })
        }
        LocalCliTarget::ClaudeSubscription { account_id } => {
            claude_target(claude, Some(&account_id))
        }
    }
}
fn claude_target(state: &ClaudeSubscriptionState, id: Option<&str>) -> Result<Target, String> {
    let manager = state.manager()?;
    let scope = manager
        .current_open_scope(id)
        .map_err(|e| e.code.to_owned())?;
    Ok(Target {
        key: format!("claude-{}", scope.account_id()),
        profile: None,
        kind: LocalCliKind::ClaudeCode,
        root: scope.canonical_home().into(),
        default: true,
        claude: Some((manager, scope)),
    })
}
fn reason<T>(result: launch::Result<T>) -> Result<T, String> {
    result.map_err(|e| e.code.to_owned())
}

#[tauri::command]
pub async fn get_local_cli_actions(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    workflow: State<'_, WorkflowState>,
    claude: State<'_, ClaudeSubscriptionState>,
    target: LocalCliTarget,
) -> Result<LocalCliActionsDto, String> {
    let target = resolve(&state, &claude, target).await?;
    let kind = target.kind;
    let found = discover(&app, &state, &workflow, kind).await;
    let code = found.err();
    Ok(LocalCliActionsDto {
        platform: kind.id().into(),
        can_login: code.is_none()
            && kind.supports_terminal_sign_in()
            && kind != LocalCliKind::ClaudeCode,
        can_open: code.is_none(),
        reason_code: code,
        phase: "idle",
    })
}

#[tauri::command]
pub async fn create_local_cli_profile(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    workflow: State<'_, WorkflowState>,
    platform: String,
    label: String,
    edition: Option<Edition>,
) -> Result<LocalCliCreatedDto, String> {
    let kind = LocalCliKind::parse(&platform).ok_or("platform_not_supported")?;
    // Verify support/install before writing a candidate directory. No CLI runs.
    discover(&app, &state, &workflow, kind).await?;
    let catalog = state.config.read().await.profiles.clone();
    let app_data = state.app_data_dir.clone();
    let label_for_create = label.clone();
    let prepared = reason(
        tauri::async_runtime::spawn_blocking(move || {
            PreparedProfile::create(&app_data, kind, edition, &label_for_create, &catalog)
        })
        .await
        .map_err(|_| "profile_create_failed")?,
    )?;
    let root = prepared.root().to_owned();
    let root_for_save = root.clone();
    let saved = state
        .try_update_config(move |config| {
            anyhow::ensure!(
                !config
                    .profiles
                    .entries
                    .iter()
                    .any(|p| p.kind == kind && p.label.eq_ignore_ascii_case(&label)),
                "duplicate label"
            );
            config.profiles.add(kind, label, root_for_save)
        })
        .await
        .map_err(|_| "profile_save_failed")?;
    let profile = saved
        .profiles
        .entries
        .iter()
        .find(|p| p.root == root)
        .ok_or("profile_save_failed")?;
    prepared.keep();
    let _ = app.emit("profiles:changed", ());
    Ok(LocalCliCreatedDto {
        profile_id: profile.id.to_string(),
        platform: kind.id().into(),
        phase: "created",
    })
}

#[tauri::command]
pub async fn start_local_cli(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    workflow: State<'_, WorkflowState>,
    claude: State<'_, ClaudeSubscriptionState>,
    services: State<'_, crate::native_services::NativeServices>,
    target: LocalCliTarget,
    action: Action,
    workspace: PathBuf,
) -> Result<LocalCliSessionDto, String> {
    if workflow.quitting.load(Ordering::Acquire) {
        return Err("launch_cancelled".into());
    }
    let target = resolve(&state, &claude, target).await?;
    if target.kind == LocalCliKind::ClaudeCode && action == Action::Login {
        return Err("use_subscription_login".into());
    }
    let mut args = reason(launch::arguments(target.kind, action))?;
    let workspace = reason(launch::checked_directory(&workspace))?;
    let kind = target.kind;
    let executable = discover(&app, &state, &workflow, kind).await?;
    let root = if target.default {
        reason(launch::create_default_directory(&target.root))?
    } else {
        reason(launch::checked_directory(&target.root))?
    };
    let mut environment = reason(Environment::for_profile(target.kind, &root, target.default))?;
    let (path, guard, resources): (PathBuf, std::fs::File, Option<Arc<dyn Send + Sync>>) =
        match executable {
            Executable::Native(value) => {
                let (path, guard) = value.into_parts();
                (path, guard, None)
            }
            Executable::Package(runtime) => {
                environment = reason(environment.with_verified_product(&runtime))?;
                let mut prefixed = runtime.prefix().to_vec();
                prefixed.extend(args);
                args = prefixed;
                (
                    runtime.executable().to_owned(),
                    reason(runtime.executable_guard())?,
                    Some(runtime),
                )
            }
        };
    let version = reason(launch::authentication_version(kind, &root))?;
    let identity = target
        .claude
        .as_ref()
        .map(|(_, s)| s.identity_hash().to_owned())
        .unwrap_or_else(|| launch::activity_key(kind, &root));
    let activity = services
        .gate
        .as_ref()
        .map_err(|e| (*e).to_owned())?
        .reserve_terminal(&identity)
        .map_err(|e| e.code().to_owned())?;
    if let Some((manager, scope)) = &target.claude {
        manager
            .recheck_open_scope(scope)
            .map_err(|e| e.code.to_owned())?;
    }
    let config = state.config.read().await;
    let codex_sessions = workflow.sessions.lock().await;
    if let Some(id) = target.profile {
        if config.profiles.get(id).map(|p| (&p.root, p.kind)).ok() != Some((&root, kind)) {
            return Err("source_changed".into());
        }
        if codex_sessions
            .get(&id)
            .is_some_and(|s| s.active() || s.removing)
        {
            return Err("already_running".into());
        }
    }
    let mut sessions = workflow.local.sessions.lock().await;
    for session in sessions.values_mut() {
        session.refresh();
    }
    if workflow.quitting.load(Ordering::Acquire) {
        return Err("launch_cancelled".into());
    }
    if sessions.values().any(|s| s.key == target.key && s.active()) {
        return Err("already_running".into());
    }
    sessions.retain(|_, s| s.active());
    if sessions.len() >= 16 {
        return Err("session_limit".into());
    }
    let mut nonce = [0; 16];
    getrandom_nonce(&mut nonce)?;
    let id = nonce.iter().map(|b| format!("{b:02x}")).collect::<String>();
    let process = console::OwnedConsole::start_registered(
        &path,
        &workspace,
        &args,
        guard,
        &environment,
        &format!("AiGoodBro - {}", kind.display_name()),
        Some(services.owned_domains.clone()),
        resources,
        None,
    )
    .map_err(|_| "launch_failed")?;
    let mut session = LocalSession {
        dto: LocalCliSessionDto {
            session_id: id.clone(),
            platform: kind.id().into(),
            phase: "running",
            authentication_state: "unknown",
            reason_code: None,
        },
        key: target.key,
        profile: target.profile,
        kind,
        root,
        version,
        process: Some(process),
        activity: Some(activity),
    };
    if let Some((manager, scope)) = &target.claude {
        if manager.recheck_open_scope(scope).is_err() {
            session.dto.reason_code = Some("account_identity_unverified");
            if session.process.as_mut().unwrap().stop().is_ok() {
                session.process = None;
                session.activity = None;
                session.dto.phase = "failed";
            } else {
                session.dto.reason_code = Some("cleanup_unconfirmed");
            }
        }
    }
    let dto = session.dto.clone();
    sessions.insert(id, session);
    Ok(dto)
}
fn getrandom_nonce(bytes: &mut [u8; 16]) -> Result<(), String> {
    // Reuse opaque randomness already available in the core dependency graph.
    let value = codexu_core::local_cli::launch::session_nonce().map_err(|e| e.code.to_owned())?;
    *bytes = value;
    Ok(())
}

#[tauri::command]
pub async fn get_local_cli_session(
    workflow: State<'_, WorkflowState>,
    session_id: String,
) -> Result<LocalCliSessionDto, String> {
    let mut sessions = workflow.local.sessions.lock().await;
    let session = sessions.get_mut(&session_id).ok_or("session_unavailable")?;
    session.refresh();
    Ok(session.dto.clone())
}
#[tauri::command]
pub async fn stop_local_cli_session(
    workflow: State<'_, WorkflowState>,
    session_id: String,
) -> Result<LocalCliSessionDto, String> {
    let mut sessions = workflow.local.sessions.lock().await;
    let session = sessions.get_mut(&session_id).ok_or("session_unavailable")?;
    if let Some(process) = &mut session.process {
        process.stop().map_err(|_| "cleanup_unconfirmed")?;
    }
    session.process = None;
    session.activity = None;
    session.dto.phase = "stopped";
    Ok(session.dto.clone())
}
pub(super) async fn profile_active(workflow: &WorkflowState, id: u64) -> bool {
    let mut sessions = workflow.local.sessions.lock().await;
    sessions.values_mut().any(|s| {
        s.refresh();
        s.profile == Some(id) && s.active()
    })
}
pub(super) fn blocks_exit(workflow: &WorkflowState) -> bool {
    let Ok(mut sessions) = workflow.local.sessions.try_lock() else {
        return true;
    };
    sessions.values_mut().any(|s| {
        s.refresh();
        s.active()
    })
}
pub(super) fn force_stop(workflow: &WorkflowState) {
    let Ok(mut sessions) = workflow.local.sessions.try_lock() else {
        return;
    };
    for session in sessions.values_mut() {
        if session.process.as_mut().is_some_and(|p| p.stop().is_ok()) {
            session.process = None;
            session.activity = None;
            session.dto.phase = "stopped";
        }
    }
}
