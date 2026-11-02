//! Native-only adapter for the existing owned Hub Session. This is a child of
//! task_hub, not a WebView command or a second task runner.
#[path = "companion_bridge_runtime.rs"]
pub(super) mod runtime;
use super::super::cli_workflow::console::{LaunchWindow, OwnedProcess};
use super::*;
use codexu_core::{
    companion_bridge::{
        windows_execution_body_hash, Acknowledgement, Backend, Error, ExecutionAuthority,
        LookupAction, Peer, Scope, Selector, TaskBinding, TaskState, WindowsExecution,
    },
    managed_proxy::ManagedProxyGate,
    profiles::ProfileCatalog,
    runtime_setup::{PinnedExecutable, SelectionStore},
    workflow::{WorkflowPreference, WorkflowPreferences},
    workflow_execution::{resolve_dispatch_code, resolve_execution, ExecutionOverrides},
    workflow_reader::{WorkflowEvidence, WorkflowProbeLaunchFailure},
};
use sha2::{Digest, Sha256};
use std::{fs::File, path::Path, time::Instant};

type BridgeResult<T> = Result<T, Error>;
fn bridge_error(code: &'static str) -> Error {
    Error { code }
}
fn unavailable(_: impl std::fmt::Display) -> Error {
    bridge_error("companion_backend_unavailable")
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn parts(values: &[&str]) -> String {
    digest(values.join("\0").as_bytes())
}
fn is_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn same_scope(left: &Scope, right: &Scope) -> bool {
    left.fingerprint == right.fingerprint
        && left.epoch == right.epoch
        && left.runtime_sha256 == right.runtime_sha256
        && left.alias == right.alias
}
fn file_digest(file: &File) -> BridgeResult<String> {
    let before = file.metadata().map_err(unavailable)?;
    if !before.is_file() || !(64..=512 * 1024 * 1024).contains(&before.len()) {
        return Err(bridge_error("companion_runtime_changed"));
    }
    let mut hash = Sha256::new();
    let mut offset = 0;
    let mut buffer = [0u8; 65536];
    loop {
        #[cfg(windows)]
        let read = std::os::windows::fs::FileExt::seek_read(file, &mut buffer, offset);
        #[cfg(unix)]
        let read = std::os::unix::fs::FileExt::read_at(file, &mut buffer, offset);
        let count = read.map_err(unavailable)?;
        if count == 0 {
            break;
        }
        offset += count as u64;
        if offset > before.len() {
            return Err(bridge_error("companion_runtime_changed"));
        }
        hash.update(&buffer[..count]);
    }
    let after = file.metadata().map_err(unavailable)?;
    if offset != before.len()
        || after.len() != before.len()
        || after.modified().ok() != before.modified().ok()
    {
        return Err(bridge_error("companion_runtime_changed"));
    }
    Ok(format!("{:x}", hash.finalize()))
}

struct Adoption<P> {
    scope: Scope,
    guard: Option<P>,
    task: Option<TaskBinding>,
    completed: bool,
}
#[derive(Clone)]
struct Submitted {
    lease: String,
    action: &'static str,
    body: String,
    scope: String,
    task: Option<TaskBinding>,
}

/// Owned by Session, so a dropped IPC worker/backend cannot drop an adopted
/// activity guard. Unknown creates retain their guard without guessing a task.
pub(crate) struct Claims<P> {
    epoch: String,
    adopted: BTreeMap<String, Adoption<P>>,
    requests: BTreeMap<String, Submitted>,
}
pub(crate) type CompanionSession = Claims<ManagedActivityGuard>;
impl<P> Claims<P> {
    pub(super) fn new() -> Result<Self, String> {
        Ok(Self {
            epoch: digest(nonce()?.as_bytes()),
            adopted: BTreeMap::new(),
            requests: BTreeMap::new(),
        })
    }
    pub(super) fn has_unresolved(&self) -> bool {
        self.adopted.values().any(|entry| !entry.completed)
    }
    /// Ordinary UI leases return None and keep their existing policy. Companion
    /// leases remain bound after their guard moves into Session.leases.
    pub(super) fn retain_known_lease(&self, id: &str, tasks: &[Value]) -> Option<bool> {
        let mut entries = self
            .adopted
            .values()
            .filter(|entry| {
                entry
                    .task
                    .as_ref()
                    .is_some_and(|binding| binding.task_id == id)
            })
            .peekable();
        entries.peek()?;
        Some(!entries.all(|entry| exact_terminal(entry, tasks)))
    }
    pub(super) fn observe_tasks(&mut self, tasks: &[Value]) {
        // A missing row, unknown state, or different action hash is no proof.
        for entry in self.adopted.values_mut() {
            if exact_terminal(entry, tasks) {
                entry.guard.take();
                entry.completed = true;
            }
        }
    }
    fn adopt(&mut self, id: &str, scope: &Scope, guard: P) -> BridgeResult<()> {
        if !is_digest(id)
            || self.adopted.contains_key(id)
            || self.adopted.len() >= 4096
            || self
                .adopted
                .values()
                .filter(|entry| !entry.completed)
                .count()
                >= 128
        {
            return Err(bridge_error("companion_adoption_conflict"));
        }
        self.adopted.insert(
            id.into(),
            Adoption {
                scope: scope.clone(),
                guard: Some(guard),
                task: None,
                completed: false,
            },
        );
        Ok(())
    }
    fn submit(&mut self, id: &str, record: Submitted) -> BridgeResult<()> {
        // Every bridge request is single-use even after a definite rejection.
        // Read-only lookup is the only recovery path, never another POST.
        if !is_digest(id) || self.requests.contains_key(id) || self.requests.len() >= 4096 {
            return Err(bridge_error("companion_request_unavailable"));
        }
        self.requests.insert(id.into(), record);
        Ok(())
    }
    fn bind_task(
        &mut self,
        expected: &Submitted,
        task: &TaskBinding,
        leases: &mut BTreeMap<String, P>,
    ) -> BridgeResult<()> {
        let adopted = self
            .adopted
            .get_mut(&expected.lease)
            .ok_or_else(|| bridge_error("companion_response_unconfirmed"))?;
        if adopted.scope.fingerprint != expected.scope
            || adopted.task.as_ref().is_some_and(|old| old != task)
        {
            return Err(bridge_error("companion_response_unconfirmed"));
        }
        if adopted.guard.is_some() && leases.contains_key(&task.task_id) {
            return Err(bridge_error("companion_response_unconfirmed"));
        }
        adopted.task = Some(task.clone());
        if let Some(guard) = adopted.guard.take() {
            leases.insert(task.task_id.clone(), guard);
        }
        Ok(())
    }
}

fn exact_terminal<P>(entry: &Adoption<P>, tasks: &[Value]) -> bool {
    entry.task.as_ref().is_some_and(|binding| {
        tasks.iter().any(|task| {
            task["id"].as_str() == Some(&binding.task_id)
                && task["actionHash"].as_str() == Some(&binding.action_hash)
                && task["agent"] == "codex"
                && task["project"] == "workspace"
                && task["accountAlias"].as_str() == Some(&entry.scope.alias)
                && task["state"].as_str().is_some_and(terminal)
        })
    })
}

pub(crate) struct Permit {
    guard: ManagedActivityGuard,
    scope: Scope,
}
struct ScopedCapture {
    scope: Scope,
    profile_id: u64,
    workspace: PathBuf,
    home: PathBuf,
    identity: String,
    preference: WorkflowPreference,
    excluded_plan_types: Vec<String>,
    official_plan: Option<String>,
}
impl ScopedCapture {
    fn same_authority_source(&self, other: &Self) -> bool {
        self.scope == other.scope
            && self.profile_id == other.profile_id
            && self.workspace == other.workspace
            && self.home == other.home
            && self.identity == other.identity
            && self.preference == other.preference
            && self.excluded_plan_types == other.excluded_plan_types
            && self.official_plan == other.official_plan
    }
}
pub(crate) struct AppBackend {
    application: Arc<AppState>,
    manager: Arc<AccountManager>,
    gate: Arc<ManagedProxyGate>,
    inner: Arc<Mutex<Inner>>,
    quitting: Arc<AtomicBool>,
    retained_probes: Arc<ProbeOwnerStore>,
    owned_domains: Arc<codexu_core::automatic_switch::live::OwnedProcessDomains>,
    python: PinnedExecutable,
    python_sha256: String,
    selected_python: Option<(PathBuf, String)>,
    request_deadline: std::sync::Mutex<Option<Instant>>,
    request_peer: std::sync::Mutex<Option<Peer>>,
}
impl AppBackend {
    pub(crate) fn new(
        application: Arc<AppState>,
        manager: Arc<AccountManager>,
        gate: Arc<ManagedProxyGate>,
        hub: &HubState,
        owned_domains: Arc<codexu_core::automatic_switch::live::OwnedProcessDomains>,
        python: PinnedExecutable,
    ) -> Result<Self, String> {
        let python_sha256 = file_digest(&python.guard).map_err(|e| e.code.to_owned())?;
        let selected_python =
            selected_python(&application.app_data_dir).map_err(|e| e.code.to_owned())?;
        if selected_python
            .as_ref()
            .is_some_and(|(path, hash)| path != &python.path || hash != &python_sha256)
        {
            return Err("companion_runtime_changed".into());
        }
        Ok(Self {
            application,
            manager,
            gate,
            inner: hub.inner.clone(),
            quitting: hub.quitting.clone(),
            retained_probes: hub.probe_owner_store(),
            owned_domains,
            python,
            python_sha256,
            selected_python,
            request_deadline: std::sync::Mutex::new(None),
            request_peer: std::sync::Mutex::new(None),
        })
    }
    fn lock(&self) -> BridgeResult<std::sync::MutexGuard<'_, Inner>> {
        if self.quitting.load(Ordering::Acquire) {
            return Err(bridge_error("companion_app_quitting"));
        }
        self.inner
            .try_lock()
            .map_err(|_| bridge_error("companion_backend_busy"))
    }
    fn check_runtime(&self) -> BridgeResult<()> {
        let current = lock_executable(&self.python.path).map_err(unavailable)?;
        if file_digest(&current)? != self.python_sha256
            || file_digest(&self.python.guard)? != self.python_sha256
            || selected_python(&self.application.app_data_dir)? != self.selected_python
        {
            return Err(bridge_error("companion_runtime_changed"));
        }
        Ok(())
    }
    fn current_deadline(&self) -> BridgeResult<Instant> {
        self.request_deadline
            .lock()
            .map_err(|_| bridge_error("companion_backend_busy"))?
            .as_ref()
            .copied()
            .ok_or_else(|| bridge_error("companion_ipc_timeout"))
    }
    fn remaining(&self, deadline: Instant) -> BridgeResult<std::time::Duration> {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            Err(bridge_error("companion_ipc_timeout"))
        } else {
            Ok(remaining)
        }
    }
    fn check_request_peer(&self) -> BridgeResult<()> {
        let peer = self
            .request_peer
            .lock()
            .map_err(|_| bridge_error("companion_backend_busy"))?
            .clone()
            .ok_or_else(|| bridge_error("companion_peer_untrusted"))?;
        peer.check()
    }
    fn capture_locked(
        &self,
        session: &mut Session,
        workspace: &Path,
        selector: &Selector,
        refresh: bool,
    ) -> BridgeResult<Scope> {
        self.capture_context_locked(session, workspace, selector, refresh)
            .map(|capture| capture.scope)
    }
    fn capture_context_locked(
        &self,
        session: &mut Session,
        workspace: &Path,
        selector: &Selector,
        refresh: bool,
    ) -> BridgeResult<ScopedCapture> {
        ensure_live(session)?;
        if selector
            .profile_id
            .is_some_and(|id| id != session.profile_id)
            || selector
                .dispatch_code
                .as_deref()
                .is_some_and(|code| code != session.dispatch_code)
            || !project_matches(Path::new(&selector.project), &session.workspace)
            || !project_matches(workspace, &session.workspace)
        {
            return Err(bridge_error("companion_scope_changed"));
        }
        self.check_runtime()?;
        if refresh {
            if !session.leases.is_empty() || session.companion.has_unresolved() {
                return Err(bridge_error("companion_account_busy"));
            }
            self.manager
                .refresh_managed_credential(&session.managed_id)
                .map_err(|_| bridge_error("companion_refresh_failed"))?;
        }
        let preferences = self.current_profile_preferences(session)?;
        let preference = preferences
            .profiles
            .get(&session.profile_id)
            .cloned()
            .unwrap_or_default();
        let (account, manager) = snapshot(
            &self.manager,
            &session.managed_id,
            &session.alias,
            &preference,
        )
        .map_err(|_| bridge_error("companion_admission_unavailable"))?;
        if account.identity_hash != session.identity || account.home != session.home {
            return Err(bridge_error("companion_scope_changed"));
        }
        if refresh {
            // Controlled refresh has finished before reservation. Publish that
            // same validated snapshot through the existing private writer so
            // Go's approval/final-spawn gate sees the identical evidence.
            session.files.write_manager(&manager).map_err(unavailable)?;
        }
        let scope = scope_from_snapshot(
            session.profile_id,
            &session.workspace,
            &session.home,
            &session.companion.epoch,
            &session.alias,
            &self.python_sha256,
            &manager,
            self.now_ms(),
        )?;
        Ok(ScopedCapture {
            scope,
            profile_id: session.profile_id,
            workspace: session.workspace.clone(),
            home: session.home.clone(),
            identity: session.identity.clone(),
            preference,
            excluded_plan_types: preferences.excluded_plan_types,
            official_plan: manager["profiles"][0]["lastSnapshot"]["planType"]
                .as_str()
                .map(str::to_owned),
        })
    }
    fn current_profile_preferences(&self, session: &Session) -> BridgeResult<WorkflowPreferences> {
        let config = self.application.config.blocking_read();
        let profile = config
            .profiles
            .get(session.profile_id)
            .map_err(|_| bridge_error("companion_scope_changed"))?;
        if profile.kind != codexu_core::local_cli::LocalCliKind::Codex
            || !same_directory(&profile.root, &session.home)
        {
            return Err(bridge_error("companion_scope_changed"));
        }
        let preferences = read_preferences(&self.application.app_data_dir).map_err(unavailable)?;
        if preferences
            .profiles
            .get(&session.profile_id)
            .and_then(|preference| preference.dispatch_code.as_deref())
            != Some(session.dispatch_code.as_str())
        {
            return Err(bridge_error("companion_scope_changed"));
        }
        Ok(preferences)
    }
    pub(super) fn validate_session_identity(&self, session: &Session) -> BridgeResult<()> {
        let _ = self.current_profile_preferences(session)?;
        let account = self
            .manager
            .hub_account_snapshot(&session.managed_id)
            .map_err(|_| bridge_error("companion_scope_changed"))?;
        if account.identity_hash != session.identity
            || !same_directory(&account.home, &session.home)
        {
            return Err(bridge_error("companion_scope_changed"));
        }
        Ok(())
    }
    fn capture_context(&self, selector: &Selector, refresh: bool) -> BridgeResult<ScopedCapture> {
        let deadline = self.current_deadline()?;
        self.remaining(deadline)?;
        let mut inner = self.lock()?;
        let preferences = read_preferences(&self.application.app_data_dir).map_err(unavailable)?;
        let config = self.application.config.blocking_read();
        let catalog = config.profiles.clone();
        let profile_id = resolve_selector_profile(selector, &catalog, &preferences)?;
        let home = catalog
            .get(profile_id)
            .map_err(|_| bridge_error("companion_scope_changed"))?
            .root
            .clone();
        let workspace =
            codexu_core::local_cli::launch::checked_directory(Path::new(&selector.project))
                .map_err(unavailable)?;
        let key = inner
            .sessions
            .iter()
            .find(|(key, session)| {
                key.profile_id == profile_id
                    && same_directory(&key.home, &home)
                    && same_directory(&key.workspace, &workspace)
                    && session.profile_id == profile_id
            })
            .map(|(key, _)| key.clone())
            .ok_or_else(|| bridge_error("companion_scope_required"))?;
        let session = inner
            .sessions
            .get_mut(&key)
            .ok_or_else(|| bridge_error("companion_scope_required"))?;
        let capture = self.capture_context_locked(session, &workspace, selector, refresh)?;
        self.remaining(deadline)?;
        Ok(capture)
    }
    fn fresh_execution_evidence(&self, capture: &ScopedCapture) -> BridgeResult<WorkflowEvidence> {
        let deadline = self.current_deadline()?;
        if !self
            .retained_probes
            .ensure_clear(capture.profile_id, &capture.home)
        {
            return Err(bridge_error("companion_backend_busy"));
        }
        let permit = self
            .application
            .profile_quota_slots
            .clone()
            .try_acquire_owned()
            .map_err(|_| bridge_error("companion_backend_busy"))?;
        let selection = SelectionStore::new(&self.application.app_data_dir).map_err(unavailable)?;
        if self.remaining(deadline)? <= std::time::Duration::from_secs(8) {
            return Err(bridge_error("companion_ipc_timeout"));
        }
        let (executable, guard) = selection.resolve_cli().map_err(unavailable)?;
        let original_sha256 = file_digest(&guard)?;
        let guard_check = guard.try_clone().map_err(unavailable)?;
        let remaining = self.remaining(deadline)?;
        let evidence_budget = remaining.saturating_sub(std::time::Duration::from_secs(8));
        let evidence_budget = evidence_budget.min(std::time::Duration::from_secs(20));
        if evidence_budget.is_zero() {
            return Err(bridge_error("companion_ipc_timeout"));
        }
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(unavailable)?;
        let resources: Arc<dyn Send + Sync> = Arc::new(permit);
        let workspace = capture.workspace.clone();
        let probe_workspace = workspace.clone();
        let probe_executable = executable.clone();
        let home = capture.home.clone();
        let domains = self.owned_domains.clone();
        let probe = runtime.block_on(
            codexu_core::workflow_reader::read_evidence_with_owned_process(
                &workspace,
                evidence_budget,
                move |endpoint| {
                    let environment = codexu_core::local_cli::launch::Environment::codex(&home)
                        .map_err(|error| {
                            WorkflowProbeLaunchFailure::before_spawn(anyhow::anyhow!(error))
                        })?;
                    let mut args = codexu_core::workflow::official_arguments();
                    args.extend([
                        "app-server".to_owned(),
                        "--listen".to_owned(),
                        endpoint.to_owned(),
                    ]);
                    match OwnedConsole::start_registered_owned_with_window(
                        &probe_executable,
                        &probe_workspace,
                        &args,
                        guard,
                        &environment,
                        "AiGoodBro - Codex evidence",
                        Some(domains),
                        Some(resources),
                        None,
                        LaunchWindow::NoWindow,
                    ) {
                        Ok(process) => Ok(Box::new(process) as Box<dyn OwnedProcess>),
                        Err(failure) => {
                            let (error, owner) = failure.into_parts();
                            Err(match owner {
                                Some(owner) => {
                                    WorkflowProbeLaunchFailure::after_spawn(error, owner)
                                }
                                None => WorkflowProbeLaunchFailure::before_spawn(error),
                            })
                        }
                    }
                },
            ),
        );
        let evidence = match probe {
            Ok(evidence) => evidence,
            Err(failure) => {
                let (_, owner) = failure.into_parts();
                if let Some(owner) = owner {
                    self.retained_probes
                        .retain(capture.profile_id, capture.home.clone(), owner);
                }
                return Err(bridge_error("companion_execution_unavailable"));
            }
        };
        self.remaining(deadline)?;
        if file_digest(&guard_check)? != original_sha256 {
            return Err(bridge_error("companion_runtime_changed"));
        }
        let (selected, selected_guard) = selection.resolve_cli().map_err(unavailable)?;
        if selected != executable || file_digest(&selected_guard)? != original_sha256 {
            return Err(bridge_error("companion_runtime_changed"));
        }
        self.remaining(deadline)?;
        Ok(evidence)
    }
    fn validate_execution(
        &self,
        execution: &WindowsExecution,
        authority: &ExecutionAuthority,
    ) -> BridgeResult<()> {
        let preferences = WorkflowPreferences {
            profiles: [(authority.profile_id, authority.preference.clone())]
                .into_iter()
                .collect(),
            excluded_plan_types: authority.excluded_plan_types.clone(),
        };
        let now_ms = i64::try_from(self.now_ms())
            .map_err(|_| bridge_error("companion_execution_unavailable"))?;
        let resolved = resolve_execution(
            authority.profile_id,
            &preferences,
            &authority.models,
            &authority.official_plan,
            now_ms,
            &execution.overrides,
        )
        .map_err(|_| bridge_error("companion_execution_unavailable"))?;
        if execution.workflow_revision != resolved.workflow_revision
            || execution.binding_sha256 != resolved.binding_sha256
        {
            return Err(bridge_error("companion_execution_unavailable"));
        }
        Ok(())
    }
    fn validate_current_authority(
        &self,
        inner: &mut Inner,
        scope: &Scope,
        authority: &ExecutionAuthority,
    ) -> BridgeResult<()> {
        let deadline = self.current_deadline()?;
        self.remaining(deadline)?;
        let session = session_by_epoch_mut(inner, &scope.epoch)?;
        let workspace = session.workspace.clone();
        let selector = Selector {
            profile_id: Some(session.profile_id),
            dispatch_code: None,
            project: workspace.to_string_lossy().into_owned(),
        };
        let current = self.capture_context_locked(session, &workspace, &selector, false)?;
        if current.scope != *scope
            || current.profile_id != authority.profile_id
            || current.preference != authority.preference
            || current.excluded_plan_types != authority.excluded_plan_types
            || current.official_plan.as_deref() != Some(authority.official_plan.as_str())
        {
            return Err(bridge_error("companion_scope_changed"));
        }
        self.remaining(deadline)?;
        Ok(())
    }
    fn recheck(&self, inner: &mut Inner, expected: &Scope) -> BridgeResult<()> {
        let session = session_by_epoch_mut(inner, &expected.epoch)?;
        let workspace = session.workspace.clone();
        let selector = Selector {
            profile_id: Some(session.profile_id),
            dispatch_code: None,
            project: workspace.to_string_lossy().into_owned(),
        };
        let actual = self.capture_locked(session, &workspace, &selector, false)?;
        if !same_scope(&actual, expected) || self.now_ms() >= expected.valid_until_ms {
            return Err(bridge_error("companion_scope_changed"));
        }
        Ok(())
    }
}

fn selected_python(data: &Path) -> BridgeResult<Option<(PathBuf, String)>> {
    SelectionStore::new(&data.join("python-runtime-v1"))
        .map_err(unavailable)?
        .selected()
        .map_err(unavailable)?
        .map(|pin| Ok((pin.path, file_digest(&pin.guard)?)))
        .transpose()
}
fn resolve_selector_profile(
    selector: &Selector,
    catalog: &ProfileCatalog,
    preferences: &WorkflowPreferences,
) -> BridgeResult<u64> {
    let profile_id = match (selector.profile_id, selector.dispatch_code.as_deref()) {
        (Some(id), None) => id,
        (None, Some(code)) => resolve_dispatch_code(code, catalog, preferences)
            .map_err(|_| bridge_error("companion_scope_changed"))?,
        _ => return Err(bridge_error("companion_invalid_request")),
    };
    catalog
        .validate()
        .map_err(|_| bridge_error("companion_scope_changed"))?;
    if catalog
        .get(profile_id)
        .map_err(|_| bridge_error("companion_scope_changed"))?
        .kind
        != codexu_core::local_cli::LocalCliKind::Codex
    {
        return Err(bridge_error("companion_scope_changed"));
    }
    Ok(profile_id)
}

fn session_by_epoch_mut<'a>(inner: &'a mut Inner, epoch: &str) -> BridgeResult<&'a mut Session> {
    inner
        .sessions
        .values_mut()
        .find(|session| session.companion.epoch == epoch)
        .ok_or_else(|| bridge_error("companion_scope_required"))
}

fn project_matches(requested: &Path, configured: &Path) -> bool {
    requested.is_absolute()
        && !requested
            .components()
            .any(|part| matches!(part, std::path::Component::ParentDir))
        && codexu_core::local_cli::launch::checked_directory(requested)
            .is_ok_and(|path| same_directory(&path, configured))
}
fn ensure_live(session: &mut Session) -> BridgeResult<()> {
    if session.quitting.load(Ordering::Acquire)
        || session.process.has_exited().map_err(unavailable)?
    {
        Err(bridge_error("companion_scope_required"))
    } else {
        Ok(())
    }
}

fn scope_from_snapshot(
    profile: u64,
    workspace: &Path,
    home: &Path,
    epoch: &str,
    alias: &str,
    runtime: &str,
    manager: &Value,
    now: u64,
) -> BridgeResult<Scope> {
    let profiles = manager["profiles"]
        .as_array()
        .filter(|values| values.len() == 1)
        .ok_or_else(|| bridge_error("companion_admission_unavailable"))?;
    let value = &profiles[0];
    let binding = &value["windowsBinding"];
    let observed = binding["quotaObservedAtMs"].as_u64();
    let expiry = binding["credentialExpiresAtMs"].as_u64();
    let until = observed
        .and_then(|time| time.checked_add(45_000))
        .zip(expiry.and_then(|time| time.checked_sub(30_000)))
        .filter(|_| observed.is_some_and(|time| time <= now))
        .map(|(a, b)| a.min(b))
        .filter(|time| *time > now)
        .ok_or_else(|| bridge_error("companion_evidence_stale"))?;
    let workspace = workspace.canonicalize().map_err(unavailable)?;
    let home = home.canonicalize().map_err(unavailable)?;
    let fingerprint = digest(
        &serde_json::to_vec(&json!({"profile":profile,"workspace":workspace,"home":home,
            "manager":manager,"epoch":epoch,"runtime":runtime}))
        .map_err(unavailable)?,
    );
    Ok(Scope {
        fingerprint,
        epoch: epoch.into(),
        runtime_sha256: runtime.into(),
        alias: alias.into(),
        valid_until_ms: until,
    })
}

fn task_binding(value: &Value, scope: &str, alias: &str) -> BridgeResult<(TaskBinding, TaskState)> {
    if value["agent"] != "codex"
        || value["project"] != "workspace"
        || value["accountAlias"].as_str() != Some(alias)
    {
        return Err(bridge_error("companion_response_unconfirmed"));
    }
    let id = value["id"]
        .as_str()
        .filter(|id| valid_id(id))
        .ok_or_else(|| bridge_error("companion_response_unconfirmed"))?;
    let action = value["actionHash"]
        .as_str()
        .filter(|hash| is_digest(hash))
        .ok_or_else(|| bridge_error("companion_response_unconfirmed"))?;
    let state = match value["state"].as_str() {
        Some("awaiting_approval") => TaskState::AwaitingApproval,
        Some("starting") => TaskState::Starting,
        Some("running") => TaskState::Running,
        // A process exit is not the user's acceptance of the produced work.
        Some("succeeded") => TaskState::AwaitingAcceptance,
        Some("failed" | "blocked_configuration") => TaskState::Failed,
        Some("cancelled") => TaskState::Cancelled,
        Some("uncertain" | "cancel_requested") => TaskState::Uncertain,
        _ => return Err(bridge_error("companion_response_unconfirmed")),
    };
    Ok((
        TaskBinding {
            task_id: id.into(),
            action_hash: action.into(),
            scope_sha256: scope.into(),
        },
        state,
    ))
}

fn read_ack(
    session: &mut Session,
    request_id: &str,
    expected: &Submitted,
) -> BridgeResult<Option<Acknowledgement>> {
    read_ack_until(session, request_id, expected, None)
}
fn read_ack_until(
    session: &mut Session,
    request_id: &str,
    expected: &Submitted,
    deadline: Option<Instant>,
) -> BridgeResult<Option<Acknowledgement>> {
    let request_hash = digest(request_id.as_bytes());
    let response = match super::request_until(
        session,
        &format!("/api/requests/{request_hash}"),
        None,
        deadline,
    ) {
        Ok(value) => value,
        Err(code) if code == "hub_not_found" => return Ok(None),
        Err(_) => return Err(bridge_error("companion_response_unconfirmed")),
    };
    let ack = decode_lookup(&response, request_id, expected, &session.alias)?;
    // Transfer this exact guard, never reserve another one. A lost response
    // retains it here until this authenticated request-to-task proof arrives.
    session
        .companion
        .bind_task(expected, &ack.task, &mut session.leases)?;
    Ok(Some(ack))
}

fn decode_lookup(
    response: &Value,
    request_id: &str,
    expected: &Submitted,
    alias: &str,
) -> BridgeResult<Acknowledgement> {
    let request_hash = digest(request_id.as_bytes());
    if response["requestHash"].as_str() != Some(&request_hash)
        || response["bodyHash"].as_str() != Some(&expected.body)
    {
        return Err(bridge_error("companion_response_unconfirmed"));
    }
    let (task, state) = task_binding(&response["task"], &expected.scope, alias)?;
    if expected.task.as_ref().is_some_and(|old| old != &task) {
        return Err(bridge_error("companion_response_unconfirmed"));
    }
    Ok(Acknowledgement {
        request_id: request_id.into(),
        body_sha256: expected.body.clone(),
        task,
        state,
    })
}

impl Backend for AppBackend {
    type Permit = Permit;
    fn set_request_deadline(&self, deadline: Option<Instant>) {
        if let Ok(mut current) = self.request_deadline.lock() {
            *current = deadline;
        }
    }
    fn set_request_peer(&self, peer: Option<Peer>) {
        if let Ok(mut current) = self.request_peer.lock() {
            *current = peer;
        }
    }
    fn now_ms(&self) -> u64 {
        chrono::Utc::now().timestamp_millis().max(0) as u64
    }
    fn execution_required(&self) -> bool {
        true
    }
    fn capture(&self, selector: &Selector, refresh: bool) -> BridgeResult<Scope> {
        self.capture_context(selector, refresh)
            .map(|capture| capture.scope)
    }
    fn capture_execution(
        &self,
        selector: &Selector,
        refresh: bool,
        overrides: &ExecutionOverrides,
    ) -> BridgeResult<(Scope, Option<ExecutionAuthority>)> {
        let deadline = self.current_deadline()?;
        let captured = self.capture_context(selector, refresh)?;
        self.remaining(deadline)?;
        let evidence = self.fresh_execution_evidence(&captured)?;
        self.remaining(deadline)?;
        let official_plan = evidence
            .official_plan_type()
            .filter(|plan| !plan.is_empty())
            .ok_or_else(|| bridge_error("companion_execution_unavailable"))?
            .to_owned();
        if captured.official_plan.as_deref() != Some(official_plan.as_str()) {
            return Err(bridge_error("companion_scope_changed"));
        }
        let authority = ExecutionAuthority {
            profile_id: captured.profile_id,
            preference: captured.preference.clone(),
            excluded_plan_types: captured.excluded_plan_types.clone(),
            official_plan,
            models: evidence.models,
        };
        let preferences = WorkflowPreferences {
            profiles: [(authority.profile_id, authority.preference.clone())]
                .into_iter()
                .collect(),
            excluded_plan_types: authority.excluded_plan_types.clone(),
        };
        let now_ms = i64::try_from(self.now_ms())
            .map_err(|_| bridge_error("companion_execution_unavailable"))?;
        resolve_execution(
            authority.profile_id,
            &preferences,
            &authority.models,
            &authority.official_plan,
            now_ms,
            overrides,
        )
        .map_err(|_| bridge_error("companion_execution_unavailable"))?;
        let current = self.capture_context(selector, false)?;
        if !captured.same_authority_source(&current) {
            return Err(bridge_error("companion_scope_changed"));
        }
        self.remaining(deadline)?;
        // The Bridge derives the persistent extension from this authority and
        // the one-call overrides; keep the authoritative inputs native-only.
        Ok((captured.scope, Some(authority)))
    }
    fn reserve(&self, scope: &Scope) -> BridgeResult<Permit> {
        let mut inner = self.lock()?;
        self.recheck(&mut inner, scope)?;
        let session = session_by_epoch_mut(&mut inner, &scope.epoch)?;
        let guard = self
            .gate
            .reserve_terminal(&session.identity)
            .map_err(|_| bridge_error("companion_account_busy"))?;
        self.recheck(&mut inner, scope)?;
        Ok(Permit {
            guard,
            scope: scope.clone(),
        })
    }
    fn adopt(&self, lease: &str, scope: &Scope, permit: Permit) -> BridgeResult<()> {
        if !same_scope(scope, &permit.scope) {
            return Err(bridge_error("companion_scope_changed"));
        }
        let mut inner = self.lock()?;
        self.recheck(&mut inner, scope)?;
        let session = session_by_epoch_mut(&mut inner, &scope.epoch)?;
        session.companion.adopt(lease, scope, permit.guard)?;
        session.needs_exit = true;
        Ok(())
    }
    fn create(
        &self,
        lease: &str,
        scope: &Scope,
        request_id: &str,
        prompt: &str,
    ) -> BridgeResult<Acknowledgement> {
        validate_prompt(prompt).map_err(unavailable)?;
        let mut inner = self.lock()?;
        self.recheck(&mut inner, scope)?;
        let session = session_by_epoch_mut(&mut inner, &scope.epoch)?;
        let adopted = session
            .companion
            .adopted
            .get(lease)
            .filter(|entry| same_scope(&entry.scope, scope) && entry.task.is_none())
            .ok_or_else(|| bridge_error("companion_lease_unavailable"))?;
        if adopted.guard.is_none() {
            return Err(bridge_error("companion_lease_unavailable"));
        }
        let submitted = Submitted {
            lease: lease.into(),
            action: "create",
            body: parts(&[
                "create",
                "codex",
                "workspace",
                &scope.alias,
                &digest(prompt.as_bytes()),
                "",
            ]),
            scope: scope.fingerprint.clone(),
            task: None,
        };
        session.companion.submit(request_id, submitted.clone())?;
        let response = request(
            session,
            "/api/tasks",
            Some(&json!({"requestId":request_id,
            "agent":"codex","project":"workspace","accountAlias":scope.alias,"prompt":prompt})),
        )
        .map_err(|_| bridge_error("companion_response_unconfirmed"))?;
        let (direct, _) = task_binding(&response, &scope.fingerprint, &scope.alias)?;
        let ack = read_ack(session, request_id, &submitted)?
            .ok_or_else(|| bridge_error("companion_response_unconfirmed"))?;
        if ack.task != direct {
            return Err(bridge_error("companion_response_unconfirmed"));
        }
        Ok(ack)
    }
    fn create_with_execution(
        &self,
        lease: &str,
        scope: &Scope,
        request_id: &str,
        prompt: &str,
        execution: Option<&WindowsExecution>,
        authority: Option<&ExecutionAuthority>,
    ) -> BridgeResult<Acknowledgement> {
        validate_prompt(prompt).map_err(unavailable)?;
        let deadline = self.current_deadline()?;
        let (execution, authority) = execution
            .zip(authority)
            .ok_or_else(|| bridge_error("companion_execution_unavailable"))?;
        self.validate_execution(execution, authority)?;
        let mut inner = self.lock()?;
        self.recheck(&mut inner, scope)?;
        self.validate_current_authority(&mut inner, scope, authority)?;
        self.remaining(deadline)?;
        let session = session_by_epoch_mut(&mut inner, &scope.epoch)?;
        let adopted = session
            .companion
            .adopted
            .get(lease)
            .filter(|entry| same_scope(&entry.scope, scope) && entry.task.is_none())
            .ok_or_else(|| bridge_error("companion_lease_unavailable"))?;
        if adopted.guard.is_none() {
            return Err(bridge_error("companion_lease_unavailable"));
        }
        let old_body = parts(&[
            "create",
            "codex",
            "workspace",
            &scope.alias,
            &digest(prompt.as_bytes()),
            "",
        ]);
        let submitted = Submitted {
            lease: lease.into(),
            action: "create",
            body: windows_execution_body_hash(&old_body, Some(execution))?,
            scope: scope.fingerprint.clone(),
            task: None,
        };
        session.companion.submit(request_id, submitted.clone())?;
        let response = super::request_until_before_write(
            session,
            "/api/tasks",
            Some(&json!({
                "requestId":request_id,
                "agent":"codex",
                "project":"workspace",
                "accountAlias":scope.alias,
                "prompt":prompt,
                "windowsExecution":execution,
                "windowsExecutionAuthority":authority
            })),
            Some(deadline),
            || self.check_request_peer().map_err(|error| error.to_string()),
        )
        .map_err(|_| bridge_error("companion_response_unconfirmed"))?;
        let (direct, _) = task_binding(&response, &scope.fingerprint, &scope.alias)?;
        let ack = read_ack_until(session, request_id, &submitted, Some(deadline))?
            .ok_or_else(|| bridge_error("companion_response_unconfirmed"))?;
        if ack.task != direct {
            return Err(bridge_error("companion_response_unconfirmed"));
        }
        Ok(ack)
    }
    fn approve(
        &self,
        lease: &str,
        scope: &Scope,
        request_id: &str,
        task: &TaskBinding,
    ) -> BridgeResult<Acknowledgement> {
        let mut inner = self.lock()?;
        self.recheck(&mut inner, scope)?;
        let session = session_by_epoch_mut(&mut inner, &scope.epoch)?;
        let adopted = session
            .companion
            .adopted
            .get(lease)
            .filter(|entry| same_scope(&entry.scope, scope) && entry.task.as_ref() == Some(task))
            .ok_or_else(|| bridge_error("companion_lease_unavailable"))?;
        if adopted.guard.is_some() || !session.leases.contains_key(&task.task_id) {
            return Err(bridge_error("companion_lease_unavailable"));
        }
        let prior = overview(session).map_err(unavailable)?;
        let row = prior["tasks"]
            .as_array()
            .and_then(|rows| {
                rows.iter()
                    .find(|row| row["id"].as_str() == Some(&task.task_id))
            })
            .ok_or_else(|| bridge_error("companion_task_changed"))?;
        let (current, state) = task_binding(row, &scope.fingerprint, &scope.alias)?;
        if current != *task
            || state != TaskState::AwaitingApproval
            || row["approvalExpired"] != false
        {
            return Err(bridge_error("companion_task_changed"));
        }
        // The overview request may consume the remaining freshness budget.
        // Re-read immediately before the only approval POST, without refresh.
        self.recheck(&mut inner, scope)?;
        let session = session_by_epoch_mut(&mut inner, &scope.epoch)?;
        let submitted = Submitted {
            lease: lease.into(),
            action: "approve",
            body: parts(&["approve", &task.task_id, &task.action_hash]),
            scope: scope.fingerprint.clone(),
            task: Some(task.clone()),
        };
        session.companion.submit(request_id, submitted.clone())?;
        request(
            session,
            &format!("/api/tasks/{}/approve", task.task_id),
            Some(&json!({"requestId":request_id,"actionHash":task.action_hash})),
        )
        .map_err(|_| bridge_error("companion_response_unconfirmed"))?;
        read_ack(session, request_id, &submitted)?
            .ok_or_else(|| bridge_error("companion_response_unconfirmed"))
    }
    fn approve_with_execution(
        &self,
        lease: &str,
        scope: &Scope,
        request_id: &str,
        task: &TaskBinding,
        execution: Option<&WindowsExecution>,
        authority: Option<&ExecutionAuthority>,
    ) -> BridgeResult<Acknowledgement> {
        let deadline = self.current_deadline()?;
        let (execution, authority) = execution
            .zip(authority)
            .ok_or_else(|| bridge_error("companion_execution_unavailable"))?;
        self.validate_execution(execution, authority)?;
        let mut inner = self.lock()?;
        self.recheck(&mut inner, scope)?;
        self.validate_current_authority(&mut inner, scope, authority)?;
        self.remaining(deadline)?;
        let session = session_by_epoch_mut(&mut inner, &scope.epoch)?;
        let adopted = session
            .companion
            .adopted
            .get(lease)
            .filter(|entry| same_scope(&entry.scope, scope) && entry.task.as_ref() == Some(task))
            .ok_or_else(|| bridge_error("companion_lease_unavailable"))?;
        if adopted.guard.is_some() || !session.leases.contains_key(&task.task_id) {
            return Err(bridge_error("companion_lease_unavailable"));
        }
        let prior = super::overview_until(session, Some(deadline)).map_err(unavailable)?;
        let row = prior["tasks"]
            .as_array()
            .and_then(|rows| {
                rows.iter()
                    .find(|row| row["id"].as_str() == Some(&task.task_id))
            })
            .ok_or_else(|| bridge_error("companion_task_changed"))?;
        let (current, state) = task_binding(row, &scope.fingerprint, &scope.alias)?;
        if current != *task
            || state != TaskState::AwaitingApproval
            || row["approvalExpired"] != false
        {
            return Err(bridge_error("companion_task_changed"));
        }
        // The overview can consume the remaining freshness budget. Re-read
        // account and preference state immediately before the only approval POST.
        self.validate_current_authority(&mut inner, scope, authority)?;
        self.remaining(deadline)?;
        let session = session_by_epoch_mut(&mut inner, &scope.epoch)?;
        let submitted = Submitted {
            lease: lease.into(),
            action: "approve",
            body: parts(&["approve", &task.task_id, &task.action_hash]),
            scope: scope.fingerprint.clone(),
            task: Some(task.clone()),
        };
        session.companion.submit(request_id, submitted.clone())?;
        super::request_until_before_write(
            session,
            &format!("/api/tasks/{}/approve", task.task_id),
            Some(&json!({
                "requestId":request_id,
                "actionHash":task.action_hash,
                "windowsExecutionAuthority":authority
            })),
            Some(deadline),
            || self.check_request_peer().map_err(|error| error.to_string()),
        )
        .map_err(|_| bridge_error("companion_response_unconfirmed"))?;
        read_ack_until(session, request_id, &submitted, Some(deadline))?
            .ok_or_else(|| bridge_error("companion_response_unconfirmed"))
    }
    fn lookup(
        &self,
        action: LookupAction,
        request_id: &str,
        body: &str,
        scope: &str,
        epoch: &str,
    ) -> BridgeResult<Option<Acknowledgement>> {
        let deadline = self.current_deadline()?;
        let mut inner = self.lock()?;
        let session = session_by_epoch_mut(&mut inner, epoch)
            .map_err(|_| bridge_error("companion_scope_changed"))?;
        let expected = session
            .companion
            .requests
            .get(request_id)
            .cloned()
            .filter(|record| {
                record.body == body
                    && record.scope == scope
                    && record.action
                        == match action {
                            LookupAction::Create => "create",
                            LookupAction::Approve => "approve",
                        }
            })
            .ok_or_else(|| bridge_error("companion_request_changed"))?;
        // No refresh, credential gate or POST on a status operation.
        read_ack_until(session, request_id, &expected, Some(deadline))
    }
}

#[cfg(test)]
#[path = "companion_bridge_backend_tests.rs"]
mod tests;
