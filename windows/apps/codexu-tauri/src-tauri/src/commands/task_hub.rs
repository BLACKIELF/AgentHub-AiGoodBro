//! A narrow native client for the existing Companion/Hub state machine.
//! No bearer token, command, URL or raw account identity crosses this IPC.
use super::cli_workflow::{
    console::{lock_executable, OwnedConsole, OwnedProcess},
    read_preferences,
};
use crate::{app_state::AppState, native_services::NativeServices};
use codexu_core::{
    accounts::{
        hub_snapshot::{HubFiles, VerifiedHubAccount},
        AccountManager,
    },
    managed_proxy::ManagedActivityGuard,
    workflow::WorkflowPreference,
    workflow_reader::WorkflowProbeOwner,
};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    io::{Read, Write},
    net::{SocketAddr, TcpStream},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};
use tauri::{AppHandle, Manager, State};
use tauri_plugin_dialog::DialogExt;

const MAX_HUB_SESSIONS: usize = 26;

#[path = "companion_bridge_backend.rs"]
pub(super) mod companion_bridge_backend;
pub(crate) use companion_bridge_backend::runtime::CompanionRuntime;

#[derive(Default)]
pub struct HubState {
    quitting: Arc<AtomicBool>,
    inner: Arc<Mutex<Inner>>,
    retained_probes: Arc<ProbeOwnerStore>,
}
struct RetainedProbeOwner {
    profile_id: u64,
    home: PathBuf,
    owner: Box<dyn WorkflowProbeOwner>,
}
#[derive(Default)]
pub(super) struct ProbeOwnerStore {
    owners: Mutex<Vec<RetainedProbeOwner>>,
}
impl ProbeOwnerStore {
    pub(super) fn retain<P: WorkflowProbeOwner + 'static>(
        &self,
        profile_id: u64,
        home: PathBuf,
        owner: P,
    ) {
        self.owners
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .push(RetainedProbeOwner {
                profile_id,
                home,
                owner: Box::new(owner),
            });
    }

    pub(super) fn ensure_clear(&self, profile_id: u64, home: &Path) -> bool {
        let mut owners = self
            .owners
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        owners.retain_mut(|entry| {
            if entry.profile_id != profile_id
                || !(entry.home == home || same_directory(&entry.home, home))
            {
                return true;
            }
            if entry.owner.has_exited().is_ok_and(|exited| exited) {
                return false;
            }
            entry.owner.stop().is_err() || !entry.owner.has_exited().is_ok_and(|exited| exited)
        });
        !owners.iter().any(|entry| {
            entry.profile_id == profile_id
                && (entry.home == home || same_directory(&entry.home, home))
        })
    }

    pub(super) fn blocks_exit(&self) -> bool {
        let mut owners = match self.owners.try_lock() {
            Ok(owners) => owners,
            Err(std::sync::TryLockError::Poisoned(error)) => error.into_inner(),
            Err(std::sync::TryLockError::WouldBlock) => return true,
        };
        owners.retain_mut(|entry| !entry.owner.has_exited().is_ok_and(|exited| exited));
        !owners.is_empty()
    }

    pub(super) fn stop_profile(&self, profile_id: u64, home: &Path) -> bool {
        let mut owners = self
            .owners
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        owners.retain_mut(|entry| {
            if entry.profile_id != profile_id
                || !(entry.home == home || same_directory(&entry.home, home))
            {
                return true;
            }
            entry.owner.stop().is_err() || !entry.owner.has_exited().is_ok_and(|exited| exited)
        });
        !owners.iter().any(|entry| {
            entry.profile_id == profile_id
                && (entry.home == home || same_directory(&entry.home, home))
        })
    }

    pub(super) fn stop_all(&self) {
        let mut owners = self
            .owners
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        owners.retain_mut(|entry| {
            entry.owner.stop().is_err() || !entry.owner.has_exited().is_ok_and(|exited| exited)
        });
    }
}
#[derive(Default)]
struct Inner {
    workspace: Option<PathBuf>,
    sessions: BTreeMap<SessionKey, Session>,
    active_session_id: Option<String>,
}
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct SessionKey {
    profile_id: u64,
    home: PathBuf,
    workspace: PathBuf,
}
impl SessionKey {
    fn new(profile_id: u64, home: &Path, workspace: &Path) -> Result<Self, String> {
        if profile_id == 0 {
            return Err(fail("hub_invalid_account"));
        }
        Ok(Self {
            profile_id,
            home: home
                .canonicalize()
                .map_err(|_| fail("hub_directory_unavailable"))?,
            workspace: workspace
                .canonicalize()
                .map_err(|_| fail("hub_directory_unavailable"))?,
        })
    }
}
struct Session {
    session_id: String,
    quitting: Arc<AtomicBool>,
    process: Box<dyn OwnedProcess>,
    files: Arc<HubFiles>,
    endpoint: SocketAddr,
    token: String,
    needs_exit: bool,
    profile_id: u64,
    dispatch_code: String,
    managed_id: String,
    alias: String,
    identity: String,
    home: PathBuf,
    workspace: PathBuf,
    leases: BTreeMap<String, ManagedActivityGuard>,
    pending: BTreeMap<String, (Value, String, Value)>,
    companion: companion_bridge_backend::CompanionSession,
}
impl Session {
    fn key(&self) -> SessionKey {
        SessionKey {
            profile_id: self.profile_id,
            home: self.home.clone(),
            workspace: self.workspace.clone(),
        }
    }
    fn has_unresolved_ownership(&self) -> bool {
        self.needs_exit
            || self.companion.has_unresolved()
            || !self.leases.is_empty()
            || !self.pending.is_empty()
    }
    fn blocks_disconnect(&self, overview: &Value) -> bool {
        self.has_unresolved_ownership()
            || overview["tasks"].as_array().is_none_or(|tasks| {
                tasks
                    .iter()
                    .any(|task| !task["state"].as_str().is_some_and(terminal))
            })
    }
}
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct HubSessionView {
    session_id: String,
    profile_id: String,
    dispatch_code: String,
    workspace: Option<String>,
}
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HubView {
    supported: bool,
    connected: bool,
    session_id: Option<String>,
    workspace: Option<String>,
    selected_workspace: Option<String>,
    profile_id: Option<String>,
    dispatch_code: Option<String>,
    sessions: Vec<HubSessionView>,
    overview: Option<Value>,
}
fn definite_rejection(code: &str) -> bool {
    matches!(
        code,
        "hub_invalid_request"
            | "hub_not_found"
            | "hub_project_busy"
            | "hub_account_busy"
            | "hub_account_quota_reserve"
            | "hub_account_dispatch_disabled"
            | "hub_dispatch_policy_unavailable"
            | "hub_conflict"
    )
}
impl HubState {
    pub fn begin_force_quit(&self) {
        self.quitting.store(true, Ordering::Release);
    }
    pub(super) fn ensure_probe_clear(&self, profile_id: u64, home: &Path) -> bool {
        self.retained_probes.ensure_clear(profile_id, home)
    }
    pub(super) fn retain_probe_owner<P: WorkflowProbeOwner + 'static>(
        &self,
        profile_id: u64,
        home: PathBuf,
        owner: P,
    ) {
        self.retained_probes.retain(profile_id, home, owner);
    }
    pub(super) fn probe_owner_store(&self) -> Arc<ProbeOwnerStore> {
        self.retained_probes.clone()
    }

    #[cfg(test)]
    pub(crate) fn insert_session_for_test(
        &self,
        input: TestSessionInput,
        active: bool,
    ) -> Result<String, String> {
        if !codexu_core::workflow_execution::valid_dispatch_code(&input.dispatch_code) {
            return Err(fail("hub_invalid_account"));
        }
        let key = SessionKey::new(input.profile_id, &input.home, &input.workspace)?;
        let session_id = nonce()?;
        let session = Session {
            session_id: session_id.clone(),
            quitting: self.quitting.clone(),
            process: input.process,
            files: input.files,
            endpoint: input.endpoint,
            token: input.token,
            needs_exit: false,
            profile_id: input.profile_id,
            dispatch_code: input.dispatch_code,
            managed_id: input.managed_id,
            alias: input.alias,
            identity: input.identity,
            home: key.home.clone(),
            workspace: key.workspace.clone(),
            leases: BTreeMap::new(),
            pending: BTreeMap::new(),
            companion: companion_bridge_backend::CompanionSession::new()?,
        };
        let mut inner = self.inner.lock().map_err(|_| fail("hub_busy"))?;
        if inner.sessions.contains_key(&key) {
            return Err(fail("hub_session_conflict"));
        }
        ensure_session_capacity(&inner)?;
        inner.sessions.insert(key, session);
        if active {
            inner.active_session_id = Some(session_id.clone());
        }
        Ok(session_id)
    }
}

#[cfg(test)]
pub(crate) struct TestSessionInput {
    pub profile_id: u64,
    pub dispatch_code: String,
    pub managed_id: String,
    pub alias: String,
    pub identity: String,
    pub home: PathBuf,
    pub workspace: PathBuf,
    pub files: Arc<HubFiles>,
    pub endpoint: SocketAddr,
    pub token: String,
    pub process: Box<dyn OwnedProcess>,
}
fn fail(code: &str) -> String {
    code.to_owned()
}
fn nonce() -> Result<String, String> {
    Ok(codexu_core::local_cli::launch::session_nonce()
        .map_err(|_| fail("hub_unavailable"))?
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect())
}
fn same_directory(left: &std::path::Path, right: &std::path::Path) -> bool {
    match (left.canonicalize(), right.canonicalize()) {
        (Ok(a), Ok(b)) => codexu_core::profiles::same_root(&a, &b),
        _ => false,
    }
}
fn terminal(state: &str) -> bool {
    matches!(
        state,
        "succeeded" | "failed" | "cancelled" | "blocked_configuration"
    )
}
fn valid_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
}
fn is_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn endpoint(value: &Value, pid: u32) -> Result<SocketAddr, String> {
    if value["schemaVersion"] != 1 || value["pid"].as_u64() != Some(pid as u64) {
        return Err(fail("hub_invalid_ready"));
    }
    let address = value["listen"]
        .as_str()
        .ok_or_else(|| fail("hub_invalid_ready"))?
        .parse::<SocketAddr>()
        .map_err(|_| fail("hub_invalid_ready"))?;
    if address.ip() != std::net::IpAddr::V4(std::net::Ipv4Addr::LOCALHOST) || address.port() == 0 {
        return Err(fail("hub_invalid_ready"));
    }
    Ok(address)
}
fn decode_http(bytes: &[u8]) -> Result<Value, String> {
    let split = bytes
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .ok_or_else(|| fail("hub_request_unconfirmed"))?;
    if split > 8192 {
        return Err(fail("hub_request_unconfirmed"));
    }
    let head = std::str::from_utf8(&bytes[..split]).map_err(|_| fail("hub_request_unconfirmed"))?;
    let status = head
        .lines()
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|s| s.parse::<u16>().ok())
        .ok_or_else(|| fail("hub_request_unconfirmed"))?;
    for line in head.lines().skip(1) {
        let (key, value) = line
            .split_once(':')
            .ok_or_else(|| fail("hub_request_unconfirmed"))?;
        if key.eq_ignore_ascii_case("transfer-encoding") {
            return Err(fail("hub_request_unconfirmed"));
        }
        if key.eq_ignore_ascii_case("content-length")
            && value.trim().parse::<usize>().ok() != Some(bytes.len() - split - 4)
        {
            return Err(fail("hub_request_unconfirmed"));
        }
    }
    let value: Value =
        serde_json::from_slice(&bytes[split + 4..]).map_err(|_| fail("hub_request_unconfirmed"))?;
    if !(200..300).contains(&status) {
        let code = value["error"].as_str().unwrap_or("hub_request_failed");
        return Err(if valid_id(code) {
            format!("hub_{code}")
        } else {
            fail("hub_request_failed")
        });
    }
    Ok(value)
}
fn request(session: &mut Session, path: &str, body: Option<&Value>) -> Result<Value, String> {
    request_until(session, path, body, None)
}
fn request_timeout(deadline: Option<Instant>, limit: Duration) -> Result<Duration, String> {
    let Some(deadline) = deadline else {
        return Ok(limit);
    };
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        Err(fail("hub_request_unconfirmed"))
    } else {
        Ok(remaining.min(limit))
    }
}
fn write_all_until(stream: &mut TcpStream, data: &[u8], deadline: Instant) -> std::io::Result<()> {
    let mut offset = 0;
    while offset < data.len() {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "request deadline elapsed",
            ));
        }
        stream.set_write_timeout(Some(remaining.min(Duration::from_secs(5))))?;
        let written = stream.write(&data[offset..])?;
        if written == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::WriteZero,
                "request write ended",
            ));
        }
        offset += written;
    }
    Ok(())
}
fn read_to_end_until(
    stream: &mut TcpStream,
    response: &mut Vec<u8>,
    deadline: Instant,
    max_bytes: usize,
) -> Result<(), String> {
    let mut buffer = [0u8; 16 * 1024];
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(fail("hub_request_unconfirmed"));
        }
        stream
            .set_read_timeout(Some(remaining.min(Duration::from_secs(12))))
            .map_err(|_| fail("hub_request_unconfirmed"))?;
        let count = stream
            .read(&mut buffer)
            .map_err(|_| fail("hub_request_unconfirmed"))?;
        if count == 0 {
            return Ok(());
        }
        if response.len().saturating_add(count) > max_bytes {
            return Err(fail("hub_request_unconfirmed"));
        }
        response.extend_from_slice(&buffer[..count]);
    }
}
fn request_until(
    session: &mut Session,
    path: &str,
    body: Option<&Value>,
    deadline: Option<Instant>,
) -> Result<Value, String> {
    request_until_before_write(session, path, body, deadline, || Ok(()))
}
fn request_until_before_write(
    session: &mut Session,
    path: &str,
    body: Option<&Value>,
    deadline: Option<Instant>,
    before_write: impl FnOnce() -> Result<(), String>,
) -> Result<Value, String> {
    if session.quitting.load(Ordering::Acquire) {
        return Err(fail("app_quitting"));
    }
    if session
        .process
        .has_exited()
        .map_err(|_| fail("hub_process_unknown"))?
    {
        return Err(fail("hub_stopped"));
    }
    request_http_until_before_write(
        &session.endpoint,
        &session.token,
        path,
        body,
        deadline,
        before_write,
    )
}
fn request_http_until(
    endpoint: &SocketAddr,
    token: &str,
    path: &str,
    body: Option<&Value>,
    deadline: Option<Instant>,
) -> Result<Value, String> {
    request_http_until_before_write(endpoint, token, path, body, deadline, || Ok(()))
}
fn request_http_until_before_write(
    endpoint: &SocketAddr,
    token: &str,
    path: &str,
    body: Option<&Value>,
    deadline: Option<Instant>,
    before_write: impl FnOnce() -> Result<(), String>,
) -> Result<Value, String> {
    let mut stream =
        TcpStream::connect_timeout(endpoint, request_timeout(deadline, Duration::from_secs(2))?)
            .map_err(|_| fail("hub_request_unconfirmed"))?;
    let payload = body
        .map(serde_json::to_vec)
        .transpose()
        .map_err(|_| fail("hub_invalid_request"))?
        .unwrap_or_default();
    if payload.len() > 70 * 1024 {
        return Err(fail("hub_invalid_request"));
    }
    let header = format!(
        "{} {} HTTP/1.0\r\nHost: {}\r\nAuthorization: Bearer {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        if body.is_some() { "POST" } else { "GET" },
        path,
        endpoint,
        token,
        payload.len()
    );
    let mut response = Vec::new();
    before_write()?;
    if let Some(deadline) = deadline {
        write_all_until(&mut stream, header.as_bytes(), deadline)
            .and_then(|_| write_all_until(&mut stream, &payload, deadline))
            .map_err(|_| fail("hub_request_unconfirmed"))?;
        read_to_end_until(&mut stream, &mut response, deadline, 2 * 1024 * 1024 + 1)?;
    } else {
        stream
            .set_read_timeout(Some(Duration::from_secs(12)))
            .map_err(|_| fail("hub_request_unconfirmed"))?;
        stream
            .set_write_timeout(Some(Duration::from_secs(5)))
            .map_err(|_| fail("hub_request_unconfirmed"))?;
        stream
            .write_all(header.as_bytes())
            .and_then(|_| stream.write_all(&payload))
            .map_err(|_| fail("hub_request_unconfirmed"))?;
        stream
            .take(2 * 1024 * 1024 + 1)
            .read_to_end(&mut response)
            .map_err(|_| fail("hub_request_unconfirmed"))?;
    }
    if response.len() > 2 * 1024 * 1024 {
        return Err(fail("hub_request_unconfirmed"));
    }
    decode_http(&response)
}
fn overview(session: &mut Session) -> Result<Value, String> {
    overview_until(session, None)
}
fn overview_until(session: &mut Session, deadline: Option<Instant>) -> Result<Value, String> {
    let value = request_until(session, "/api/overview", None, deadline)?;
    let tasks = value["tasks"]
        .as_array()
        .filter(|t| t.len() <= 10000)
        .ok_or_else(|| fail("hub_invalid_response"))?;
    // Uncertain/missing records retain the native reservation. Only a positive
    // terminal state from this owned Hub releases the cross-feature guard.
    session.needs_exit = tasks
        .iter()
        .any(|t| !t["state"].as_str().is_some_and(terminal));
    session.leases.retain(|id, _| {
        if let Some(retain) = session.companion.retain_known_lease(id, tasks) {
            return retain;
        }
        !tasks
            .iter()
            .any(|t| t["id"].as_str() == Some(id) && t["state"].as_str().is_some_and(terminal))
    });
    session.companion.observe_tasks(tasks);
    session.needs_exit |= session.companion.has_unresolved();
    Ok(value)
}

fn session_key_by_id(inner: &Inner, session_id: &str) -> Option<SessionKey> {
    inner
        .sessions
        .iter()
        .find(|(_, session)| session.session_id == session_id)
        .map(|(key, _)| key.clone())
}

fn session_by_id_mut<'a>(
    inner: &'a mut Inner,
    session_id: &str,
) -> Result<&'a mut Session, String> {
    if !is_digest(session_id) {
        return Err(fail("hub_session_unavailable"));
    }
    inner
        .sessions
        .values_mut()
        .find(|session| session.session_id == session_id)
        .ok_or_else(|| fail("hub_session_unavailable"))
}

fn ensure_session_capacity(inner: &Inner) -> Result<(), String> {
    if inner.sessions.len() >= MAX_HUB_SESSIONS {
        Err(fail("hub_session_limit"))
    } else {
        Ok(())
    }
}

fn reap_confirmed_exited_sessions(inner: &mut Inner) {
    let exited: Vec<_> = inner
        .sessions
        .iter_mut()
        .filter_map(|(key, session)| {
            (session
                .process
                .has_exited()
                .is_ok_and(|has_exited| has_exited)
                && !session.has_unresolved_ownership())
            .then(|| key.clone())
        })
        .collect();
    for key in exited {
        inner.sessions.remove(&key);
    }
    if inner
        .active_session_id
        .as_deref()
        .is_some_and(|id| session_key_by_id(inner, id).is_none())
    {
        inner.active_session_id = None;
    }
}

fn view(inner: &mut Inner) -> Result<HubView, String> {
    reap_confirmed_exited_sessions(inner);
    let mut active_id = inner.active_session_id.clone();
    let active_key = active_id
        .as_deref()
        .and_then(|session_id| session_key_by_id(inner, session_id));
    if active_id.is_some() && active_key.is_none() {
        inner.active_session_id = None;
        active_id = None;
    }
    if let Some(key) = active_key.as_ref() {
        let remove_exited = {
            let session = inner
                .sessions
                .get_mut(key)
                .ok_or_else(|| fail("hub_session_unavailable"))?;
            if !session
                .process
                .has_exited()
                .map_err(|_| fail("hub_process_unknown"))?
            {
                false
            } else if session.has_unresolved_ownership() {
                return Err(fail("hub_process_unknown"));
            } else {
                true
            }
        };
        if remove_exited {
            inner.sessions.remove(key);
            inner.active_session_id = None;
            active_id = None;
        }
    }
    let data = if let Some(session_id) = active_id.as_deref() {
        Some(overview(session_by_id_mut(inner, session_id)?)?)
    } else {
        None
    };
    let active = active_id.as_deref().and_then(|session_id| {
        inner
            .sessions
            .values()
            .find(|session| session.session_id == session_id)
    });
    let sessions = inner
        .sessions
        .values()
        .map(|session| HubSessionView {
            session_id: session.session_id.clone(),
            profile_id: session.profile_id.to_string(),
            dispatch_code: session.dispatch_code.clone(),
            workspace: session
                .workspace
                .file_name()
                .map(|name| name.to_string_lossy().to_string()),
        })
        .collect();
    Ok(HubView {
        supported: cfg!(windows),
        connected: active.is_some(),
        session_id: active.map(|session| session.session_id.clone()),
        workspace: active
            .and_then(|session| session.workspace.file_name())
            .or_else(|| inner.workspace.as_ref().and_then(|path| path.file_name()))
            .map(|name| name.to_string_lossy().to_string()),
        selected_workspace: inner
            .workspace
            .as_ref()
            .and_then(|path| path.file_name())
            .map(|name| name.to_string_lossy().to_string()),
        profile_id: active.map(|session| session.profile_id.to_string()),
        dispatch_code: active.map(|session| session.dispatch_code.clone()),
        sessions,
        overview: data,
    })
}
async fn run<T: Send + 'static>(
    hub: &HubState,
    f: impl FnOnce(&mut Inner) -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    let inner = hub.inner.clone();
    let quitting = hub.quitting.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let mut inner = inner.lock().map_err(|_| fail("hub_busy"))?;
        if quitting.load(Ordering::Acquire) {
            return Err(fail("app_quitting"));
        }
        f(&mut inner)
    })
    .await
    .map_err(|_| fail("hub_unavailable"))?
}
async fn profile(
    state: &AppState,
    id: u64,
) -> Result<(String, PathBuf, WorkflowPreference), String> {
    let config = state.config.read().await;
    let profile = config
        .profiles
        .get(id)
        .map_err(|_| fail("source_changed"))?;
    if profile.kind != codexu_core::local_cli::LocalCliKind::Codex {
        return Err(fail("hub_codex_required"));
    }
    let preferences =
        read_preferences(&state.app_data_dir).map_err(|_| fail("settings_unavailable"))?;
    Ok((
        profile.label.clone(),
        profile.root.clone(),
        preferences.profiles.get(&id).cloned().unwrap_or_default(),
    ))
}
fn snapshot(
    manager: &AccountManager,
    managed: &str,
    alias: &str,
    pref: &WorkflowPreference,
) -> Result<(VerifiedHubAccount, Value), String> {
    if !pref.allows_new_work_at_ms(chrono::Utc::now().timestamp_millis()) {
        return Err(fail("hub_dispatch_disabled"));
    }
    let account = manager
        .hub_account_snapshot(managed)
        .map_err(|e| e.code.to_owned())?;
    let value =
        json!({"profiles":[account.manager_profile(alias,pref).map_err(|e|e.code.to_owned())?]});
    Ok((account, value))
}
#[tauri::command]
pub async fn get_task_hub(
    hub: State<'_, HubState>,
    session_id: Option<String>,
) -> Result<HubView, String> {
    run(&hub, move |inner| {
        if let Some(session_id) = session_id {
            if session_key_by_id(inner, &session_id).is_none() {
                return Err(fail("hub_session_unavailable"));
            }
            inner.active_session_id = Some(session_id);
        }
        view(inner)
    })
    .await
}
#[tauri::command]
pub async fn select_task_hub_workspace(
    app: AppHandle,
    hub: State<'_, HubState>,
) -> Result<HubView, String> {
    let selected =
        tauri::async_runtime::spawn_blocking(move || app.dialog().file().blocking_pick_folder())
            .await
            .map_err(|_| fail("hub_directory_unavailable"))?;
    let Some(selected) = selected else {
        return run(&hub, view).await;
    };
    let path = selected
        .into_path()
        .map_err(|_| fail("hub_directory_unavailable"))?;
    let path = codexu_core::local_cli::launch::checked_directory(&path)
        .map_err(|_| fail("hub_directory_unavailable"))?;
    run(&hub, move |inner| {
        inner.workspace = Some(path);
        view(inner)
    })
    .await
}
#[tauri::command]
pub async fn connect_task_hub(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    services: State<'_, NativeServices>,
    hub: State<'_, HubState>,
    workflow: State<'_, super::cli_workflow::WorkflowState>,
    profile_id: String,
) -> Result<HubView, String> {
    if !cfg!(windows) {
        return Err(fail("platform_not_supported"));
    }
    let id = profile_id
        .parse::<u64>()
        .map_err(|_| fail("hub_invalid_account"))?;
    let dispatch_code =
        super::cli_workflow::assign_dispatch_code_for_connect(&state, &workflow, id).await?;
    let (_, root, pref) = profile(&state, id).await?;
    if pref.dispatch_code.as_deref() != Some(dispatch_code.as_str()) {
        return Err(fail("hub_dispatch_code_unavailable"));
    }
    let manager = services.statistics_accounts()?;
    let roots = manager
        .managed_history_roots()
        .map_err(|e| e.code.to_owned())?;
    let matching: Vec<_> = roots
        .into_iter()
        .filter(|(_, r)| same_directory(r, &root))
        .collect();
    if matching.len() != 1 {
        return Err(fail("hub_registration_required"));
    }
    let managed = matching[0].0.clone();
    let (cli, cli_guard) = super::cli_workflow::native_executable(&state.app_data_dir)
        .await
        .map_err(|_| fail("cli_unavailable"))?;
    let helper = app
        .path()
        .resource_dir()
        .map_err(|_| fail("hub_helper_unavailable"))?
        .join("companion-hub/aigoodbro-hub.exe");
    let mut guard = lock_executable(&helper).map_err(|_| fail("hub_helper_unavailable"))?;
    codexu_core::accounts::hub_snapshot::verify_helper(
        &mut guard,
        option_env!("AIGOODBRO_HUB_BINARY_SHA256"),
    )
    .map_err(|e| e.code.to_owned())?;
    let data = state.app_data_dir.clone();
    let domains = services.owned_domains.clone();
    let quitting = hub.quitting.clone();
    let retained_probes = hub.retained_probes.clone();
    let work = move |inner: &mut Inner| {
        let workspace = inner
            .workspace
            .clone()
            .ok_or_else(|| fail("hub_directory_required"))?;
        let key = SessionKey::new(id, &root, &workspace)?;
        if let Some(session) = inner.sessions.get_mut(&key) {
            match session.process.has_exited() {
                Ok(false) => {
                    let session_id = session.session_id.clone();
                    inner.active_session_id = Some(session_id);
                    return view(inner);
                }
                Ok(true) if session.has_unresolved_ownership() => {
                    return Err(fail("hub_process_unknown"));
                }
                Err(_) => return Err(fail("hub_process_unknown")),
                Ok(true) => {}
            }
            inner.sessions.remove(&key);
        }
        reap_confirmed_exited_sessions(inner);
        ensure_session_capacity(inner)?;
        if !retained_probes.ensure_clear(id, &root) {
            return Err(fail("hub_start_unconfirmed"));
        }
        // Explicit Connect is allowed to refresh official quota in an isolated
        // verification home; no model request and no account switch is made.
        manager
            .refresh_managed_credential(&managed)
            .map_err(|e| e.code.to_owned())?;
        let alias = format!("account-{id}");
        let (account, manager_value) = snapshot(&manager, &managed, &alias, &pref)?;
        if !same_directory(&account.home, &root) {
            return Err(fail("source_changed"));
        }
        let files =
            Arc::new(HubFiles::open(&data, &workspace, &managed).map_err(|e| e.code.to_owned())?);
        let token = format!("{}{}", nonce()?, nonce()?);
        let config = json!({"listen":"127.0.0.1:0","requireToken":true,"tokenFile":files.token_file(),"dataDir":files.data(),"readyFile":files.ready(),"managerSnapshotPath":files.manager(),"activityDirectory":files.activity(),"workflowPreferencesPath":data.join("workflow-preferences-v1.json"),"workflowCatalogPath":data.join("settings.json"),"workflowProfileId":id,"approvalTTLSeconds":300,"approvalQuotaMaxAgeSeconds":60,"mode":"workspace-write","claudeMaxBudgetUSD":1,"accountStrategy":"system","accounts":[{"alias":alias,"home":account.home}],"commands":{"codex":cli},"projects":{"workspace":workspace}});
        files
            .write_inputs(&config, &manager_value, &token)
            .map_err(|e| e.code.to_owned())?;
        let environment = codexu_core::local_cli::launch::Environment::codex(&account.home)
            .map_err(|_| fail("hub_environment_invalid"))?;
        let sink = std::fs::OpenOptions::new()
            .write(true)
            .open("NUL")
            .map_err(|_| fail("hub_unavailable"))?;
        if quitting.load(Ordering::Acquire) {
            return Err(fail("app_quitting"));
        }
        let companion = companion_bridge_backend::CompanionSession::new()?;
        let session_id = nonce()?;
        let resources: Arc<dyn Send + Sync> = Arc::new((Arc::new(cli_guard), files.clone()));
        let mut process = match OwnedConsole::start_registered_owned(
            &helper,
            &workspace,
            &[
                "--config".into(),
                files.config().to_string_lossy().to_string(),
            ],
            guard,
            &environment,
            "AiGoodBro Hub",
            Some(domains),
            Some(resources),
            Some(&sink),
        ) {
            Ok(process) => process,
            Err(failure) => {
                let (_, owner) = failure.into_parts();
                if let Some(owner) = owner {
                    retained_probes.retain(id, account.home.clone(), owner);
                    return Err(fail("hub_start_unconfirmed"));
                }
                return Err(fail("hub_start_failed"));
            }
        };
        let deadline = Instant::now() + Duration::from_secs(5);
        let ready = (|| loop {
            if process.has_exited().map_err(|_| fail("hub_start_failed"))? {
                return Err(fail("hub_start_failed"));
            }
            if let Some(value) = files.read_ready().map_err(|e| e.code.to_owned())? {
                break endpoint(&value, process.pid());
            }
            if Instant::now() >= deadline {
                return Err(fail("hub_ready_timeout"));
            }
            std::thread::sleep(Duration::from_millis(25));
        })();
        let endpoint = match ready {
            Ok(v) => v,
            Err(e) => {
                if process.stop().is_err() || !process.has_exited().is_ok_and(|exited| exited) {
                    retained_probes.retain(id, account.home.clone(), process);
                    return Err(fail("hub_stop_unconfirmed"));
                }
                return Err(e);
            }
        };
        inner.sessions.insert(
            key.clone(),
            Session {
                session_id: session_id.clone(),
                quitting,
                process: Box::new(process),
                files,
                endpoint,
                token,
                needs_exit: false,
                profile_id: id,
                dispatch_code,
                managed_id: managed,
                alias,
                identity: account.identity_hash,
                home: key.home.clone(),
                workspace: key.workspace.clone(),
                leases: BTreeMap::new(),
                pending: BTreeMap::new(),
                companion,
            },
        );
        inner.active_session_id = Some(session_id);
        view(inner)
    };
    run(&hub, work).await
}
#[derive(serde::Deserialize, serde::Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum HubAction {
    Create {
        request_id: String,
        prompt: String,
    },
    Approve {
        request_id: String,
        task_id: String,
        action_hash: String,
    },
    Cancel {
        request_id: String,
        task_id: String,
        expected_version: u64,
    },
    Resume {
        request_id: String,
        task_id: String,
        prompt: String,
    },
    Resolve {
        request_id: String,
        task_id: String,
        expected_version: u64,
        confirmed_stopped: bool,
    },
}
#[tauri::command]
pub async fn task_hub_action(
    state: State<'_, Arc<AppState>>,
    services: State<'_, NativeServices>,
    hub: State<'_, HubState>,
    session_id: String,
    action: HubAction,
) -> Result<HubView, String> {
    if !is_digest(&session_id) {
        return Err(fail("hub_session_unavailable"));
    }
    let id = {
        let inner = hub.inner.try_lock().map_err(|_| fail("hub_busy"))?;
        inner
            .sessions
            .values()
            .find(|session| session.session_id == session_id)
            .ok_or_else(|| fail("hub_session_unavailable"))?
            .profile_id
    };
    // Cancellation and a confirmed-stopped resolution remain available even
    // when admission identity, quota or dispatch preferences have changed.
    let cancels = matches!(
        &action,
        HubAction::Cancel { .. } | HubAction::Resolve { .. }
    );
    let selected = if cancels {
        None
    } else {
        Some(profile(&state, id).await?)
    };
    let manager = if cancels {
        None
    } else {
        Some(services.statistics_accounts()?)
    };
    let gate = if matches!(&action, HubAction::Approve { .. }) {
        Some(services.gate.as_ref().cloned().map_err(|e| e.to_string())?)
    } else {
        None
    };
    let application = state.inner().clone();
    let work = move |inner: &mut Inner| {
        let key =
            session_key_by_id(inner, &session_id).ok_or_else(|| fail("hub_session_unavailable"))?;
        let session = inner
            .sessions
            .get_mut(&key)
            .ok_or_else(|| fail("hub_session_unavailable"))?;
        if session.profile_id != id
            || selected.as_ref().is_some_and(|(_, root, preference)| {
                !same_directory(root, &session.home)
                    || preference.dispatch_code.as_deref() != Some(&session.dispatch_code)
            })
        {
            return Err(fail("source_changed"));
        }
        inner.active_session_id = Some(session_id.clone());
        let wire = serde_json::to_value(&action).map_err(|_| fail("hub_invalid_request"))?;
        let action_id = wire["request_id"]
            .as_str()
            .filter(|v| valid_id(v))
            .ok_or_else(|| fail("hub_invalid_request"))?
            .to_owned();
        if let Some((old, path, body)) = session.pending.get(&action_id).cloned() {
            if old != wire {
                return Err(fail("hub_request_changed"));
            }
            let result = request(session, &path, Some(&body));
            if result.as_ref().is_err_and(|e| definite_rejection(e)) {
                session.pending.remove(&action_id);
            }
            result?;
            let view_result = view(inner);
            if view_result.is_ok() {
                if let Ok(session) = session_by_id_mut(inner, &session_id) {
                    session.pending.remove(&action_id);
                }
            }
            return view_result;
        }
        let prior = overview(session)?;
        let (request_id, task_id) = match &action {
            HubAction::Create { request_id, .. } => (request_id, None),
            HubAction::Approve {
                request_id,
                task_id,
                ..
            }
            | HubAction::Cancel {
                request_id,
                task_id,
                ..
            }
            | HubAction::Resume {
                request_id,
                task_id,
                ..
            }
            | HubAction::Resolve {
                request_id,
                task_id,
                ..
            } => (request_id, Some(task_id)),
        };
        if !valid_id(request_id) || task_id.is_some_and(|t| !valid_id(t)) {
            return Err(fail("hub_invalid_request"));
        }
        let creates = matches!(&action, HubAction::Create { .. } | HubAction::Resume { .. });
        if creates || matches!(&action, HubAction::Approve { .. }) {
            // Refresh only before admission and before acquiring the shared
            // reservation; this does not switch the current system identity.
            let manager = manager.as_ref().ok_or_else(|| fail("hub_unavailable"))?;
            if session.leases.is_empty() {
                manager
                    .refresh_managed_credential(&session.managed_id)
                    .map_err(|e| e.code.to_owned())?;
            }
            let config = application.config.blocking_read();
            let current = config
                .profiles
                .get(id)
                .map_err(|_| fail("source_changed"))?;
            if current.kind != codexu_core::local_cli::LocalCliKind::Codex
                || !same_directory(&current.root, &session.home)
            {
                return Err(fail("source_changed"));
            }
            let pref = read_preferences(&application.app_data_dir)
                .map_err(|_| fail("settings_unavailable"))?
                .profiles
                .get(&id)
                .cloned()
                .unwrap_or_default();
            let (account, value) = snapshot(manager, &session.managed_id, &session.alias, &pref)?;
            if account.identity_hash != session.identity || account.home != session.home {
                return Err(fail("source_changed"));
            }
            session
                .files
                .write_manager(&value)
                .map_err(|e| e.code.to_owned())?;
        }
        let (path, body) = match action {
            HubAction::Create { request_id, prompt } => {
                validate_prompt(&prompt)?;
                (
                    "/api/tasks".to_owned(),
                    json!({"requestId":request_id,"agent":"codex","project":"workspace","accountAlias":session.alias,"prompt":prompt}),
                )
            }
            HubAction::Resume {
                request_id,
                task_id,
                prompt,
            } => {
                validate_prompt(&prompt)?;
                (
                    format!("/api/tasks/{task_id}/resume"),
                    json!({"requestId":request_id,"agent":"codex","project":"workspace","accountAlias":session.alias,"prompt":prompt}),
                )
            }
            HubAction::Approve {
                request_id,
                task_id,
                action_hash,
            } => {
                let task = prior["tasks"]
                    .as_array()
                    .and_then(|v| v.iter().find(|t| t["id"].as_str() == Some(&task_id)))
                    .ok_or_else(|| fail("hub_task_changed"))?;
                if task["actionHash"].as_str() != Some(&action_hash)
                    || task["accountAlias"].as_str() != Some(&session.alias)
                    || task["state"] != "awaiting_approval"
                    || task["approvalExpired"] != false
                {
                    return Err(fail("hub_task_changed"));
                }
                if !session.leases.contains_key(&task_id) {
                    let lease = gate
                        .as_ref()
                        .ok_or_else(|| fail("hub_unavailable"))?
                        .reserve_terminal(&session.identity)
                        .map_err(|e| e.code().to_owned())?;
                    let rechecked = manager
                        .as_ref()
                        .ok_or_else(|| fail("hub_unavailable"))?
                        .hub_account_snapshot(&session.managed_id)
                        .map_err(|e| e.code.to_owned())?;
                    if rechecked.identity_hash != session.identity || rechecked.home != session.home
                    {
                        return Err(fail("source_changed"));
                    }
                    session.leases.insert(task_id.clone(), lease);
                }
                (
                    format!("/api/tasks/{task_id}/approve"),
                    json!({"requestId":request_id,"actionHash":action_hash}),
                )
            }
            HubAction::Cancel {
                request_id,
                task_id,
                expected_version,
            } => {
                if expected_version == 0 {
                    return Err(fail("hub_invalid_request"));
                }
                (
                    format!("/api/tasks/{task_id}/cancel"),
                    json!({"requestId":request_id,"expectedVersion":expected_version}),
                )
            }
            HubAction::Resolve {
                request_id,
                task_id,
                expected_version,
                confirmed_stopped,
            } => {
                let task = prior["tasks"]
                    .as_array()
                    .and_then(|rows| rows.iter().find(|t| t["id"].as_str() == Some(&task_id)))
                    .ok_or_else(|| fail("hub_task_changed"))?;
                (
                    format!("/api/tasks/{task_id}/resolve"),
                    resolution_body(task, &request_id, expected_version, confirmed_stopped)?,
                )
            }
        };
        if session.pending.len() >= 128 {
            return Err(fail("hub_pending_limit"));
        }
        session
            .pending
            .insert(action_id.clone(), (wire, path.clone(), body.clone()));
        let result = request(session, &path, Some(&body));
        if result.as_ref().is_err_and(|e| definite_rejection(e)) {
            session.pending.remove(&action_id);
        }
        result?;
        let view_result = view(inner);
        if view_result.is_ok() {
            if let Ok(session) = session_by_id_mut(inner, &session_id) {
                session.pending.remove(&action_id);
            }
        }
        view_result
    };
    run(&hub, work).await
}
fn resolution_body(
    task: &Value,
    request_id: &str,
    expected_version: u64,
    confirmed_stopped: bool,
) -> Result<Value, String> {
    if expected_version == 0 || !confirmed_stopped {
        return Err(fail("hub_invalid_request"));
    }
    if task["state"] != "uncertain" || task["version"].as_u64() != Some(expected_version) {
        return Err(fail("hub_task_changed"));
    }
    Ok(json!({"requestId":request_id,"expectedVersion":expected_version,"confirmedStopped":true}))
}
fn validate_prompt(prompt: &str) -> Result<(), String> {
    if prompt.trim().is_empty() || prompt.len() > 64 * 1024 || prompt.contains('\0') {
        Err(fail("hub_invalid_prompt"))
    } else {
        Ok(())
    }
}
#[tauri::command]
pub async fn get_task_hub_messages(
    hub: State<'_, HubState>,
    session_id: String,
    task_id: String,
) -> Result<Value, String> {
    if !is_digest(&session_id) || !valid_id(&task_id) {
        return Err(fail("hub_invalid_request"));
    }
    run(&hub, move |inner| {
        let session = session_by_id_mut(inner, &session_id)?;
        request(session, &format!("/api/tasks/{task_id}/messages"), None)
    })
    .await
}
#[tauri::command]
pub async fn disconnect_task_hub(
    hub: State<'_, HubState>,
    session_id: String,
) -> Result<HubView, String> {
    if !is_digest(&session_id) {
        return Err(fail("hub_session_unavailable"));
    }
    let retained_probes = hub.retained_probes.clone();
    run(&hub, move |inner| {
        let key =
            session_key_by_id(inner, &session_id).ok_or_else(|| fail("hub_session_unavailable"))?;
        {
            let session = inner
                .sessions
                .get_mut(&key)
                .ok_or_else(|| fail("hub_session_unavailable"))?;
            let v = overview(session)?;
            if session.blocks_disconnect(&v) {
                return Err(fail("hub_active_tasks"));
            }
            if !retained_probes.stop_profile(session.profile_id, &session.home) {
                return Err(fail("hub_stop_unconfirmed"));
            }
            session
                .process
                .stop()
                .map_err(|_| fail("hub_stop_unconfirmed"))?;
            if !session.process.has_exited().is_ok_and(|exited| exited) {
                return Err(fail("hub_stop_unconfirmed"));
            }
        }
        inner.sessions.remove(&key);
        if inner.active_session_id.as_deref() == Some(&session_id) {
            inner.active_session_id = None;
        }
        view(inner)
    })
    .await
}
pub fn should_block_exit(hub: &HubState) -> bool {
    hub.retained_probes.blocks_exit()
        || hub
            .inner
            .try_lock()
            .map(|i| i.sessions.values().any(Session::has_unresolved_ownership))
            .unwrap_or(true)
}
pub fn force_stop_owned(hub: &HubState) {
    hub.begin_force_quit();
    hub.retained_probes.stop_all();
    if let Ok(mut inner) = hub.inner.try_lock() {
        let stopped: Vec<_> = inner
            .sessions
            .iter_mut()
            .filter_map(|(key, session)| {
                let _ = session.process.stop();
                session
                    .process
                    .has_exited()
                    .is_ok_and(|exited| exited)
                    .then(|| key.clone())
            })
            .collect();
        for key in stopped {
            inner.sessions.remove(&key);
        }
        if inner
            .active_session_id
            .as_deref()
            .is_some_and(|id| session_key_by_id(&inner, id).is_none())
        {
            inner.active_session_id = None;
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn disconnect_keeps_empty_overview_session_with_unconfirmed_post_receipt() {
        struct LiveOwner;
        impl OwnedProcess for LiveOwner {
            fn has_exited(&mut self) -> std::io::Result<bool> {
                Ok(false)
            }
            fn stop(&mut self) -> std::io::Result<()> {
                Ok(())
            }
            fn exit_success(&mut self) -> std::io::Result<bool> {
                Ok(false)
            }
        }

        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let home = root.join("profile-home");
        let workspace = root.join("workspace");
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(&workspace).unwrap();
        let files = Arc::new(HubFiles::open(&root, &workspace, "managed-1").unwrap());
        let mut session = Session {
            session_id: "a".repeat(64),
            quitting: Arc::new(AtomicBool::new(false)),
            process: Box::new(LiveOwner),
            files,
            endpoint: "127.0.0.1:1".parse().unwrap(),
            token: "synthetic-token".into(),
            needs_exit: false,
            profile_id: 1,
            dispatch_code: "A".into(),
            managed_id: "managed-1".into(),
            alias: "account-1".into(),
            identity: "synthetic-identity".into(),
            home,
            workspace,
            leases: BTreeMap::new(),
            pending: BTreeMap::new(),
            companion: companion_bridge_backend::CompanionSession::new().unwrap(),
        };
        session.pending.insert(
            "request-1".into(),
            (
                json!({"kind":"create","requestId":"request-1"}),
                "/api/tasks".into(),
                json!({"requestId":"request-1"}),
            ),
        );
        let empty_overview = json!({"tasks":[]});
        assert!(
            session.blocks_disconnect(&empty_overview),
            "an empty overview cannot erase a POST whose receipt is unknown"
        );
        session.pending.clear();
        assert!(
            !session.blocks_disconnect(&empty_overview),
            "the empty session becomes disconnectable after its pending request resolves"
        );
    }

    #[test]
    fn retained_probe_owner_blocks_same_scope_and_exit_until_job_empty() {
        use std::sync::atomic::AtomicUsize;

        struct FakeOwner {
            exited: Arc<AtomicBool>,
            stop_calls: Arc<AtomicUsize>,
        }
        impl WorkflowProbeOwner for FakeOwner {
            fn has_exited(&mut self) -> std::io::Result<bool> {
                Ok(self.exited.load(Ordering::Acquire))
            }
            fn stop(&mut self) -> std::io::Result<()> {
                self.stop_calls.fetch_add(1, Ordering::AcqRel);
                Ok(())
            }
            fn exit_success(&mut self) -> std::io::Result<bool> {
                Ok(false)
            }
        }

        let store = ProbeOwnerStore::default();
        let home = PathBuf::from("synthetic-profile-home");
        let unrelated_home = PathBuf::from("another-profile-home");
        let exited = Arc::new(AtomicBool::new(false));
        let stop_calls = Arc::new(AtomicUsize::new(0));
        store.retain(
            7,
            home.clone(),
            FakeOwner {
                exited: exited.clone(),
                stop_calls: stop_calls.clone(),
            },
        );

        assert!(store.blocks_exit());
        assert!(store.ensure_clear(8, &unrelated_home));
        assert_eq!(stop_calls.load(Ordering::Acquire), 0);
        assert!(!store.ensure_clear(7, &home));
        assert_eq!(stop_calls.load(Ordering::Acquire), 1);
        assert!(store.blocks_exit());

        exited.store(true, Ordering::Release);
        assert!(!store.blocks_exit());
        assert!(store.ensure_clear(7, &home));
    }

    #[test]
    #[cfg_attr(
        not(windows),
        ignore = "requires the prepared Windows Hub and owned Job Object"
    )]
    fn windows_settings_roundtrip_through_pinned_hub() {
        use crate::app_state::AppConfig;
        use codexu_core::{local_cli::LocalCliKind, workflow::WorkflowPreferences};
        use sha2::{Digest, Sha256};

        // Exercise the real Rust writers and the staged, hash-pinned Go reader.
        // Every identity, credential and quota is synthetic. Draft/cancel only:
        // this test never approves a task or starts a model command.
        struct RunningHub(Session, u32);
        impl Drop for RunningHub {
            fn drop(&mut self) {
                if !self.0.process.has_exited().unwrap_or(false) {
                    let _ = self.0.process.stop();
                }
            }
        }
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap();
        let data = root.join("app-data");
        let home = root.join("synthetic-home");
        let workspace = root.join("workspace");
        std::fs::create_dir(&workspace).unwrap();
        let files = Arc::new(HubFiles::open(&data, &workspace, "synthetic-managed-id").unwrap());
        let auth = br#"{"fixture":"synthetic-credential-not-for-login"}"#;
        codexu_core::atomic_settings::write_json(&home.join("auth.json"), auth, |_| Ok(()))
            .unwrap();
        let mut settings = AppConfig {
            codex_root: home.clone(),
            cache_dir: root.join("cache"),
            ..Default::default()
        };
        settings
            .profiles
            .add(
                LocalCliKind::Codex,
                "synthetic-account".into(),
                home.clone(),
            )
            .unwrap();
        settings.save(&data).unwrap();
        let mut preferences = WorkflowPreferences::default();
        preferences.profiles.insert(
            1,
            WorkflowPreference {
                participating: true,
                model: Some("gpt-6-sol".into()),
                effort: Some("high".into()),
                revision: 1,
                dispatch_window: None,
                dispatch_code: Some("A".into()),
                ..Default::default()
            },
        );
        super::super::cli_workflow::save_preferences(&data, &preferences).unwrap();
        let now = chrono::Utc::now().timestamp();
        let identity = format!(
            "{:x}",
            Sha256::digest(b"fixture@example.invalid\0synthetic-account")
        );
        let manager = json!({"profiles":[{
            "name":"account-1", "codexHomePath":home, "isSystemProfile":false,
            "automaticSwitchParticipation":true,
            "executionPreference":{"model":"gpt-6-sol","reasoningEffort":"high","serviceTier":"default","subagentMode":"standard"},
            "windowsBinding":{"authSha256":format!("{:x}",Sha256::digest(auth)),"credentialExpiresAtMs":(now+600)*1000,"quotaObservedAtMs":now*1000,"identityHash":identity,"workflowRevision":1},
            "lastSnapshot":{"email":"fixture@example.invalid","accountID":"synthetic-account","planType":"plus","quotaReadSucceeded":true,"fetchedAt":now-978307200,
                "fiveHour":{"usedPercent":1,"resetsAt":now-978307200+3600},
                "sevenDay":{"usedPercent":1,"resetsAt":now-978307200+604800}}
        }]});
        let token = format!("{}{}", nonce().unwrap(), nonce().unwrap());
        let helper = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("resources/companion-hub/aigoodbro-hub.exe");
        let mut guard = lock_executable(&helper).unwrap();
        codexu_core::accounts::hub_snapshot::verify_helper(
            &mut guard,
            option_env!("AIGOODBRO_HUB_BINARY_SHA256"),
        )
        .unwrap();
        let config = json!({"listen":"127.0.0.1:0","requireToken":true,"tokenFile":files.token_file(),"dataDir":files.data(),"readyFile":files.ready(),"managerSnapshotPath":files.manager(),"activityDirectory":files.activity(),"workflowPreferencesPath":data.join("workflow-preferences-v1.json"),"workflowCatalogPath":data.join("settings.json"),"workflowProfileId":1,"approvalTTLSeconds":300,"approvalQuotaMaxAgeSeconds":60,"mode":"workspace-write","claudeMaxBudgetUSD":1,"accountStrategy":"system","accounts":[{"alias":"account-1","home":home}],"commands":{"codex":std::env::current_exe().unwrap()},"projects":{"workspace":workspace}});
        files.write_inputs(&config, &manager, &token).unwrap();
        let environment = codexu_core::local_cli::launch::Environment::codex(&home).unwrap();
        let sink = std::fs::OpenOptions::new().write(true).open("NUL").unwrap();
        let resources: Arc<dyn Send + Sync> = Arc::new(files.clone());
        let process = match OwnedConsole::start_registered_owned(
            &helper,
            &workspace,
            &[
                "--config".into(),
                files.config().to_string_lossy().into_owned(),
            ],
            guard,
            &environment,
            "AiGoodBro isolated Hub fixture",
            None,
            Some(resources),
            Some(&sink),
        ) {
            Ok(process) => process,
            Err(failure) => {
                let (error, owner) = failure.into_parts();
                if let Some(mut owner) = owner {
                    let _ = owner.stop();
                    assert!(owner.has_exited().unwrap_or(false));
                }
                panic!("could not start isolated Hub fixture: {error}");
            }
        };
        let process_id = process.pid();
        let mut running = RunningHub(
            Session {
                session_id: nonce().unwrap(),
                quitting: Arc::new(AtomicBool::new(false)),
                process: Box::new(process),
                files,
                endpoint: "127.0.0.1:1".parse().unwrap(),
                token,
                needs_exit: false,
                profile_id: 1,
                dispatch_code: "A".into(),
                managed_id: "synthetic-managed-id".into(),
                alias: "account-1".into(),
                identity,
                home: home.clone(),
                workspace: workspace.clone(),
                leases: BTreeMap::new(),
                pending: BTreeMap::new(),
                companion: companion_bridge_backend::CompanionSession::new().unwrap(),
            },
            process_id,
        );
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            assert!(
                !running.0.process.has_exited().unwrap(),
                "isolated Hub exited before ready"
            );
            if let Some(value) = running.0.files.read_ready().unwrap() {
                running.0.endpoint = endpoint(&value, running.1).unwrap();
                break;
            }
            assert!(Instant::now() < deadline, "isolated Hub ready deadline");
            std::thread::sleep(Duration::from_millis(25));
        }
        let create = |session: &mut Session, id: &str| {
            request(
                session,
                "/api/tasks",
                Some(
                    &json!({"requestId":id,"agent":"codex","project":"workspace","accountAlias":"account-1","prompt":"Synthetic draft only; never approve or execute."}),
                ),
            )
        };
        let cancel = |session: &mut Session, task: &Value, id: &str| {
            assert_eq!(task["state"], "awaiting_approval");
            let task_id = task["id"].as_str().unwrap();
            assert!(valid_id(task_id));
            let result = request(
                session,
                &format!("/api/tasks/{task_id}/cancel"),
                Some(&json!({"requestId":id,"expectedVersion":task["version"]})),
            )
            .unwrap();
            assert_eq!(result["state"], "cancelled");
        };
        let first = create(&mut running.0, "fixture-first").unwrap();
        cancel(&mut running.0, &first, "fixture-cancel-first");

        // Atomic replacements must remain readable, and policy changes must
        // take effect immediately instead of admitting a stale snapshot.
        preferences.profiles.get_mut(&1).unwrap().participating = false;
        super::super::cli_workflow::save_preferences(&data, &preferences).unwrap();
        assert_eq!(
            create(&mut running.0, "fixture-disabled").unwrap_err(),
            "hub_account_dispatch_disabled"
        );
        preferences.profiles.get_mut(&1).unwrap().participating = true;
        preferences.profiles.get_mut(&1).unwrap().revision = 2;
        super::super::cli_workflow::save_preferences(&data, &preferences).unwrap();
        assert_eq!(
            create(&mut running.0, "fixture-revision").unwrap_err(),
            "hub_dispatch_policy_unavailable"
        );
        preferences.profiles.get_mut(&1).unwrap().revision = 1;
        super::super::cli_workflow::save_preferences(&data, &preferences).unwrap();

        settings.profiles.entries[0].root = workspace.clone();
        settings.save(&data).unwrap();
        assert_eq!(
            create(&mut running.0, "fixture-remapped").unwrap_err(),
            "hub_dispatch_policy_unavailable"
        );
        settings.profiles.entries[0].root = home.clone();
        settings.save(&data).unwrap();
        codexu_core::atomic_settings::write_json(
            &home.join("auth.json"),
            br#"{"fixture":"changed"}"#,
            |_| Ok(()),
        )
        .unwrap();
        assert_eq!(
            create(&mut running.0, "fixture-auth-changed").unwrap_err(),
            "hub_dispatch_policy_unavailable"
        );
        codexu_core::atomic_settings::write_json(&home.join("auth.json"), auth, |_| Ok(()))
            .unwrap();
        let last = create(&mut running.0, "fixture-final").unwrap();
        cancel(&mut running.0, &last, "fixture-cancel-final");
        let overview = request(&mut running.0, "/api/overview", None).unwrap();
        let tasks = overview["tasks"].as_array().unwrap();
        assert_eq!(tasks.len(), 2);
        assert!(tasks.iter().all(|task| task["state"] == "cancelled"));
        running.0.process.stop().unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        while !running.0.process.has_exited().unwrap() {
            assert!(Instant::now() < deadline, "isolated Hub did not exit");
            std::thread::sleep(Duration::from_millis(10));
        }
        drop(running);
        drop(sink);
        temporary.close().unwrap();
    }
    #[test]
    fn endpoint_binds_pid_loopback_and_schema() {
        assert!(endpoint(
            &json!({"schemaVersion":1,"pid":7,"listen":"127.0.0.1:5000"}),
            7
        )
        .is_ok());
        for v in [
            json!({"schemaVersion":1,"pid":8,"listen":"127.0.0.1:5000"}),
            json!({"schemaVersion":1,"pid":7,"listen":"0.0.0.0:5000"}),
            json!({"schemaVersion":1,"pid":7,"listen":"127.0.0.1:0"}),
        ] {
            assert!(endpoint(&v, 7).is_err());
        }
    }
    #[test]
    fn fixed_http_reader_rejects_partial_chunked_and_non_json() {
        assert_eq!(
            decode_http(b"HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\n{}").unwrap(),
            json!({})
        );
        for b in [
            b"HTTP/1.0 200 OK\r\nContent-Length: 3\r\n\r\n{}".as_slice(),
            b"HTTP/1.0 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n{}",
            b"HTTP/1.0 200 OK\r\n\r\nsecret",
        ] {
            assert!(decode_http(b).is_err());
        }
    }
    #[test]
    fn slow_http_after_post_deadline_returns_unconfirmed_without_retry() {
        use std::{io::Read, net::TcpListener, sync::mpsc, thread};

        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let endpoint = listener.local_addr().unwrap();
        let (request_tx, request_rx) = mpsc::channel();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(1)))
                .unwrap();
            let mut bytes = Vec::new();
            Read::by_ref(&mut stream)
                .take(72 * 1024)
                .read_to_end(&mut bytes)
                .unwrap();
            request_tx.send(String::from_utf8(bytes).unwrap()).unwrap();
            thread::sleep(Duration::from_millis(250));
            let _ = stream
                .write_all(b"HTTP/1.0 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}");
        });

        let deadline = Instant::now() + Duration::from_millis(100);
        let result = request_http_until(
            &endpoint,
            "synthetic-token",
            "/api/tasks",
            Some(&json!({"requestId":"synthetic-request","prompt":"fixture"})),
            Some(deadline),
        );
        assert_eq!(result.unwrap_err(), "hub_request_unconfirmed");
        let request = request_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(request.starts_with("POST /api/tasks HTTP/1.0"));
        assert!(request.contains("synthetic-request"));
        assert_eq!(request.matches("POST ").count(), 1);
        server.join().unwrap();
    }
    #[test]
    fn post_rechecks_peer_after_overview_and_sends_nothing_when_peer_is_lost() {
        use std::{
            io::{BufRead, BufReader, Read},
            net::TcpListener,
            sync::{
                atomic::{AtomicBool, Ordering},
                mpsc, Arc,
            },
            thread,
        };

        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let endpoint = listener.local_addr().unwrap();
        let (post_tx, post_rx) = mpsc::channel();
        let server = thread::spawn(move || {
            let (overview, _) = listener.accept().unwrap();
            let mut overview = BufReader::new(overview);
            let mut line = String::new();
            loop {
                line.clear();
                overview.read_line(&mut line).unwrap();
                if line == "\r\n" {
                    break;
                }
            }
            overview
                .get_mut()
                .write_all(b"HTTP/1.0 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
                .unwrap();
            drop(overview);

            let (mut post, _) = listener.accept().unwrap();
            post.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
            let mut bytes = Vec::new();
            post.read_to_end(&mut bytes).unwrap();
            post_tx.send(bytes).unwrap();
        });

        let deadline = Instant::now() + Duration::from_secs(1);
        let overview = request_http_until(
            &endpoint,
            "synthetic-token",
            "/api/overview",
            None,
            Some(deadline),
        )
        .unwrap();
        assert_eq!(overview, json!({}));
        let peer_live = Arc::new(AtomicBool::new(true));
        // The native peer was valid before the read-only overview and was lost
        // while that request was in flight.
        peer_live.store(false, Ordering::SeqCst);
        let before_write_peer = peer_live.clone();
        let result = request_http_until_before_write(
            &endpoint,
            "synthetic-token",
            "/api/tasks",
            Some(&json!({"requestId":"synthetic-request","prompt":"fixture"})),
            Some(deadline),
            || {
                if before_write_peer.load(Ordering::SeqCst) {
                    Ok(())
                } else {
                    Err("companion_peer_untrusted".into())
                }
            },
        );
        assert_eq!(result.unwrap_err(), "companion_peer_untrusted");
        assert!(post_rx
            .recv_timeout(Duration::from_secs(1))
            .unwrap()
            .is_empty());
        server.join().unwrap();
    }
    #[test]
    fn native_boundary_never_accepts_routes_or_unknown_actions() {
        for id in ["../task", "task/approve", "hello\r\nheader", ""] {
            assert!(!valid_id(id));
        }
        assert!(serde_json::from_value::<HubAction>(
            json!({"kind":"request","url":"https://example.invalid"})
        )
        .is_err());
        assert!(!terminal("uncertain"));
        assert!(!terminal("running"));
        assert!(terminal("cancelled"));
    }
    #[test]
    fn resolution_requires_explicit_confirmation_and_current_uncertain_version() {
        let task = json!({"state":"uncertain","version":7});
        assert_eq!(
            resolution_body(&task, "same-request", 7, true).unwrap(),
            json!({"requestId":"same-request","expectedVersion":7,"confirmedStopped":true})
        );
        assert_eq!(
            resolution_body(&task, "same-request", 7, false).unwrap_err(),
            "hub_invalid_request"
        );
        assert_eq!(
            resolution_body(&task, "same-request", 0, true).unwrap_err(),
            "hub_invalid_request"
        );
        assert_eq!(
            resolution_body(&task, "same-request", 6, true).unwrap_err(),
            "hub_task_changed"
        );
        for state in ["running", "starting", "failed", "succeeded"] {
            assert_eq!(
                resolution_body(&json!({"state":state,"version":7}), "same-request", 7, true)
                    .unwrap_err(),
                "hub_task_changed"
            );
        }
        assert!(serde_json::from_value::<HubAction>(
            json!({"kind":"resolve","request_id":"r","task_id":"t","expected_version":7})
        )
        .is_err());
        assert!(serde_json::from_value::<HubAction>(json!({"kind":"resolve","request_id":"r","task_id":"t","expected_version":7,"confirmed_stopped":true,"url":"/other"})).is_err());
        assert!(!terminal("uncertain"));
        assert!(terminal("failed"));
    }
}

#[cfg(all(test, windows))]
#[path = "companion_bridge_integration_tests.rs"]
mod companion_bridge_integration_tests;
