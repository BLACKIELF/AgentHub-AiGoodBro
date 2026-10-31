//! A narrow native client for the existing Companion/Hub state machine.
//! No bearer token, command, URL or raw account identity crosses this IPC.
use super::cli_workflow::{
    console::{lock_executable, OwnedConsole},
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
};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    io::{Read, Write},
    net::{SocketAddr, TcpStream},
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};
use tauri::{AppHandle, Manager, State};
use tauri_plugin_dialog::DialogExt;

#[derive(Default)]
pub struct HubState {
    quitting: Arc<AtomicBool>,
    inner: Arc<Mutex<Inner>>,
}
#[derive(Default)]
struct Inner {
    workspace: Option<PathBuf>,
    session: Option<Session>,
}
struct Session {
    quitting: Arc<AtomicBool>,
    process: OwnedConsole,
    files: HubFiles,
    endpoint: SocketAddr,
    token: String,
    needs_exit: bool,
    profile_id: u64,
    managed_id: String,
    alias: String,
    identity: String,
    home: PathBuf,
    leases: BTreeMap<String, ManagedActivityGuard>,
    pending: BTreeMap<String, (Value, String, Value)>,
}
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HubView {
    supported: bool,
    connected: bool,
    workspace: Option<String>,
    profile_id: Option<String>,
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
    let mut stream = TcpStream::connect_timeout(&session.endpoint, Duration::from_secs(2))
        .map_err(|_| fail("hub_request_unconfirmed"))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(12)))
        .map_err(|_| fail("hub_request_unconfirmed"))?;
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .map_err(|_| fail("hub_request_unconfirmed"))?;
    let payload = body
        .map(serde_json::to_vec)
        .transpose()
        .map_err(|_| fail("hub_invalid_request"))?
        .unwrap_or_default();
    if payload.len() > 70 * 1024 {
        return Err(fail("hub_invalid_request"));
    }
    let header=format!("{} {} HTTP/1.0\r\nHost: {}\r\nAuthorization: Bearer {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",if body.is_some(){"POST"}else{"GET"},path,session.endpoint,session.token,payload.len());
    stream
        .write_all(header.as_bytes())
        .and_then(|_| stream.write_all(&payload))
        .map_err(|_| fail("hub_request_unconfirmed"))?;
    let mut response = Vec::new();
    stream
        .take(2 * 1024 * 1024 + 1)
        .read_to_end(&mut response)
        .map_err(|_| fail("hub_request_unconfirmed"))?;
    if response.len() > 2 * 1024 * 1024 {
        return Err(fail("hub_request_unconfirmed"));
    }
    decode_http(&response)
}
fn overview(session: &mut Session) -> Result<Value, String> {
    let value = request(session, "/api/overview", None)?;
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
        !tasks
            .iter()
            .any(|t| t["id"].as_str() == Some(id) && t["state"].as_str().is_some_and(terminal))
    });
    Ok(value)
}
fn view(inner: &mut Inner) -> Result<HubView, String> {
    if let Some(session) = inner.session.as_mut() {
        if session
            .process
            .has_exited()
            .map_err(|_| fail("hub_process_unknown"))?
        {
            inner.session = None;
        }
    }
    let data = inner.session.as_mut().map(overview).transpose()?;
    Ok(HubView {
        supported: cfg!(windows),
        connected: inner.session.is_some(),
        workspace: inner
            .workspace
            .as_ref()
            .and_then(|p| p.file_name())
            .map(|s| s.to_string_lossy().to_string()),
        profile_id: inner.session.as_ref().map(|s| s.profile_id.to_string()),
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
pub async fn get_task_hub(hub: State<'_, HubState>) -> Result<HubView, String> {
    run(&hub, view).await
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
        if inner.session.is_some() {
            return Err(fail("hub_disconnect_required"));
        }
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
    profile_id: String,
) -> Result<HubView, String> {
    if !cfg!(windows) {
        return Err(fail("platform_not_supported"));
    }
    let id = profile_id
        .parse::<u64>()
        .map_err(|_| fail("hub_invalid_account"))?;
    let (_, root, pref) = profile(&state, id).await?;
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
    let work = move |inner: &mut Inner| {
        if inner.session.is_some() {
            return Err(fail("hub_already_connected"));
        }
        let workspace = inner
            .workspace
            .clone()
            .ok_or_else(|| fail("hub_directory_required"))?;
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
        let files = HubFiles::open(&data, &workspace, &managed).map_err(|e| e.code.to_owned())?;
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
        let mut process = OwnedConsole::start_registered(
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
            Some(Arc::new(cli_guard)),
            Some(&sink),
        )
        .map_err(|_| fail("hub_start_failed"))?;
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
                let _ = process.stop();
                return Err(e);
            }
        };
        inner.session = Some(Session {
            quitting,
            process,
            files,
            endpoint,
            token,
            needs_exit: false,
            profile_id: id,
            managed_id: managed,
            alias,
            identity: account.identity_hash,
            home: account.home,
            leases: BTreeMap::new(),
            pending: BTreeMap::new(),
        });
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
    action: HubAction,
) -> Result<HubView, String> {
    let id = {
        let inner = hub.inner.try_lock().map_err(|_| fail("hub_busy"))?;
        inner
            .session
            .as_ref()
            .ok_or_else(|| fail("hub_not_connected"))?
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
        let session = inner
            .session
            .as_mut()
            .ok_or_else(|| fail("hub_not_connected"))?;
        if session.profile_id != id
            || selected
                .as_ref()
                .is_some_and(|(_, root, _)| !same_directory(root, &session.home))
        {
            return Err(fail("source_changed"));
        }
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
                if let Some(s) = inner.session.as_mut() {
                    s.pending.remove(&action_id);
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
            if let Some(s) = inner.session.as_mut() {
                s.pending.remove(&action_id);
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
    task_id: String,
) -> Result<Value, String> {
    if !valid_id(&task_id) {
        return Err(fail("hub_invalid_request"));
    }
    run(&hub, move |inner| {
        let session = inner
            .session
            .as_mut()
            .ok_or_else(|| fail("hub_not_connected"))?;
        request(session, &format!("/api/tasks/{task_id}/messages"), None)
    })
    .await
}
#[tauri::command]
pub async fn disconnect_task_hub(hub: State<'_, HubState>) -> Result<HubView, String> {
    run(&hub, |inner| {
        if let Some(session) = inner.session.as_mut() {
            let v = overview(session)?;
            if v["tasks"].as_array().is_none_or(|ts| {
                ts.iter()
                    .any(|t| !t["state"].as_str().is_some_and(terminal))
            }) {
                return Err(fail("hub_active_tasks"));
            }
            session
                .process
                .stop()
                .map_err(|_| fail("hub_stop_unconfirmed"))?;
        }
        inner.session = None;
        view(inner)
    })
    .await
}
pub fn should_block_exit(hub: &HubState) -> bool {
    hub.inner
        .try_lock()
        .map(|i| i.session.as_ref().is_some_and(|s| s.needs_exit))
        .unwrap_or(true)
}
pub fn force_stop_owned(hub: &HubState) {
    hub.begin_force_quit();
    if let Ok(mut inner) = hub.inner.try_lock() {
        if let Some(s) = inner.session.as_mut() {
            let _ = s.process.stop();
        }
        inner.session = None;
    }
}
#[cfg(test)]
mod tests {
    use super::*;
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
        struct RunningHub(Session);
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
        let files = HubFiles::open(&data, &workspace, "synthetic-managed-id").unwrap();
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
        let process = OwnedConsole::start_registered(
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
            None,
            Some(&sink),
        )
        .unwrap();
        let mut running = RunningHub(Session {
            quitting: Arc::new(AtomicBool::new(false)),
            process,
            files,
            endpoint: "127.0.0.1:1".parse().unwrap(),
            token,
            needs_exit: false,
            profile_id: 1,
            managed_id: "synthetic-managed-id".into(),
            alias: "account-1".into(),
            identity,
            home: home.clone(),
            leases: BTreeMap::new(),
            pending: BTreeMap::new(),
        });
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            assert!(
                !running.0.process.has_exited().unwrap(),
                "isolated Hub exited before ready"
            );
            if let Some(value) = running.0.files.read_ready().unwrap() {
                running.0.endpoint = endpoint(&value, running.0.process.pid()).unwrap();
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
