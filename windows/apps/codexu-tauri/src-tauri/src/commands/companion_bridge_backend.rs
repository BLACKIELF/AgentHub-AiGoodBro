//! Native-only adapter for the existing owned Hub Session. This is a child of
//! task_hub, not a WebView command or a second task runner.
#[path = "companion_bridge_runtime.rs"]
pub(super) mod runtime;
use super::*;
use codexu_core::{
    companion_bridge::{
        Acknowledgement, Backend, Error, LookupAction, Scope, Selector, TaskBinding, TaskState,
    },
    managed_proxy::ManagedProxyGate,
    runtime_setup::{PinnedExecutable, SelectionStore},
};
use sha2::{Digest, Sha256};
use std::{fs::File, path::Path};

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
pub(crate) struct AppBackend {
    application: Arc<AppState>,
    manager: Arc<AccountManager>,
    gate: Arc<ManagedProxyGate>,
    inner: Arc<Mutex<Inner>>,
    quitting: Arc<AtomicBool>,
    python: PinnedExecutable,
    python_sha256: String,
    selected_python: Option<(PathBuf, String)>,
}
impl AppBackend {
    pub(crate) fn new(
        application: Arc<AppState>,
        manager: Arc<AccountManager>,
        gate: Arc<ManagedProxyGate>,
        hub: &HubState,
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
            python,
            python_sha256,
            selected_python,
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
    fn capture_locked(
        &self,
        session: &mut Session,
        workspace: &Path,
        selector: &Selector,
        refresh: bool,
    ) -> BridgeResult<Scope> {
        ensure_live(session)?;
        if selector.profile_id != session.profile_id
            || !project_matches(Path::new(&selector.project), workspace)
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
        let preference = read_preferences(&self.application.app_data_dir)
            .map_err(unavailable)?
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
        scope_from_snapshot(
            session.profile_id,
            workspace,
            &session.home,
            &session.companion.epoch,
            &session.alias,
            &self.python_sha256,
            &manager,
            self.now_ms(),
        )
    }
    fn recheck(&self, inner: &mut Inner, expected: &Scope) -> BridgeResult<()> {
        let workspace = inner
            .workspace
            .clone()
            .ok_or_else(|| bridge_error("companion_scope_required"))?;
        let session = inner
            .session
            .as_mut()
            .ok_or_else(|| bridge_error("companion_scope_required"))?;
        let selector = Selector {
            profile_id: session.profile_id,
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
    let request_hash = digest(request_id.as_bytes());
    let response = match request(session, &format!("/api/requests/{request_hash}"), None) {
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
    fn now_ms(&self) -> u64 {
        chrono::Utc::now().timestamp_millis().max(0) as u64
    }
    fn capture(&self, selector: &Selector, refresh: bool) -> BridgeResult<Scope> {
        let mut inner = self.lock()?;
        let workspace = inner
            .workspace
            .clone()
            .ok_or_else(|| bridge_error("companion_scope_required"))?;
        let session = inner
            .session
            .as_mut()
            .ok_or_else(|| bridge_error("companion_scope_required"))?;
        self.capture_locked(session, &workspace, selector, refresh)
    }
    fn reserve(&self, scope: &Scope) -> BridgeResult<Permit> {
        let mut inner = self.lock()?;
        self.recheck(&mut inner, scope)?;
        let session = inner.session.as_mut().unwrap();
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
        let session = inner.session.as_mut().unwrap();
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
        let session = inner.session.as_mut().unwrap();
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
    fn approve(
        &self,
        lease: &str,
        scope: &Scope,
        request_id: &str,
        task: &TaskBinding,
    ) -> BridgeResult<Acknowledgement> {
        let mut inner = self.lock()?;
        self.recheck(&mut inner, scope)?;
        let session = inner.session.as_mut().unwrap();
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
        let session = inner.session.as_mut().unwrap();
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
    fn lookup(
        &self,
        action: LookupAction,
        request_id: &str,
        body: &str,
        scope: &str,
        epoch: &str,
    ) -> BridgeResult<Option<Acknowledgement>> {
        let mut inner = self.lock()?;
        let session = inner
            .session
            .as_mut()
            .filter(|session| session.companion.epoch == epoch)
            .ok_or_else(|| bridge_error("companion_scope_changed"))?;
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
        read_ack(session, request_id, &expected)
    }
}

#[cfg(test)]
#[path = "companion_bridge_backend_tests.rs"]
mod tests;
