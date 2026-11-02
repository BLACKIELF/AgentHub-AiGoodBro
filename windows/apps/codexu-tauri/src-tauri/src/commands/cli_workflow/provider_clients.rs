//! Explicit clients use a private pool home and a registered owned console.
//! The gateway key never crosses IPC or enters argv. Request IDs are retained
//! for this app lifetime, including failed/unknown starts, and never replayed.
use super::{console, local_actions, native_executable, AppState, WorkflowState};
use crate::commands::provider_pool::ProviderPoolState;
use crate::native_services::NativeServices;
use codexu_core::{
    local_cli::{dependency::VerifiedRuntime, launch, LocalCliKind, PlatformDirectories},
    provider_pool::{
        self,
        client::{self, ClientKind, ClientPlan},
        Provider,
    },
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
#[cfg(windows)]
use std::io::{Read, Seek, SeekFrom};
use std::{
    collections::BTreeMap,
    fs::File,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
};
use tauri::{AppHandle, Emitter, State};

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StartRequest {
    request_id: String,
    run_id: String,
    provider: Provider,
    kind: ClientKind,
    model: String,
    workspace: PathBuf,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientDto {
    request_id: String,
    run_id: String,
    provider: Provider,
    kind: &'static str,
    model: String,
    state: &'static str,
    issue_code: Option<&'static str>,
}
struct Session {
    dto: ClientDto,
    digest: [u8; 32],
    process: Option<Box<dyn console::OwnedProcess>>,
    // A failed spawn does not prove cleanup. Retain the home/runtime lease
    // conservatively; never reuse it or tell the caller that cleanup succeeded.
    uncertain_resources: Option<Arc<dyn Send + Sync>>,
    failure_after_cleanup: Option<&'static str>,
    probe_output: Option<ProbeOutput>,
}
impl Session {
    fn refresh(&mut self) {
        if let Some(p) = self.process.as_mut() {
            match p.has_exited() {
                Ok(true) => {
                    if let Some(issue) = self.failure_after_cleanup.take() {
                        self.clear_process("failed", Some(issue));
                        return;
                    }
                    match if self.dto.kind == "agy" {
                        p.exit_success()
                    } else {
                        Ok(true)
                    } {
                        Ok(true) => {
                            (self.dto.state, self.dto.issue_code) =
                                exit_outcome(self.dto.kind, true);
                            self.clear_process(self.dto.state, self.dto.issue_code);
                        }
                        Ok(false) => {
                            (self.dto.state, self.dto.issue_code) =
                                exit_outcome(self.dto.kind, false);
                            self.clear_process(self.dto.state, self.dto.issue_code);
                        }
                        Err(_) => {
                            self.dto.state = "cleanupUnconfirmed";
                            self.dto.issue_code = Some("provider_pool_client_cleanup_unconfirmed");
                        }
                    }
                }
                Ok(false) => {}
                Err(_) => {
                    self.dto.state = "cleanupUnconfirmed";
                    self.dto.issue_code = Some("provider_pool_client_cleanup_unconfirmed");
                }
            }
        }
    }
    fn retain_uncertain_process(
        &mut self,
        process: Box<dyn console::OwnedProcess>,
        resources: Arc<dyn Send + Sync>,
        output: Option<ProbeOutput>,
        issue_after_cleanup: &'static str,
    ) {
        self.process = Some(process);
        self.uncertain_resources = Some(resources);
        self.probe_output = output;
        self.failure_after_cleanup = Some(issue_after_cleanup);
        self.dto.state = "cleanupUnconfirmed";
        self.dto.issue_code = Some("provider_pool_client_cleanup_unconfirmed");
    }
    fn clear_process(&mut self, state: &'static str, issue: Option<&'static str>) {
        self.process = None;
        self.uncertain_resources = None;
        self.probe_output = None;
        self.failure_after_cleanup = None;
        self.dto.state = state;
        self.dto.issue_code = issue;
    }
    fn stop_owned(&mut self) {
        self.refresh();
        let Some(process) = self.process.as_mut() else {
            return;
        };
        match process.stop() {
            Ok(()) => {
                if let Some(issue) = self.failure_after_cleanup.take() {
                    self.clear_process("failed", Some(issue));
                } else {
                    self.clear_process("stopped", None);
                }
            }
            Err(_) => {
                self.dto.state = "cleanupUnconfirmed";
                self.dto.issue_code = Some("provider_pool_client_cleanup_unconfirmed");
            }
        }
    }
    fn active(&self) -> bool {
        self.dto.state == "checking" || self.process.is_some() || self.uncertain_resources.is_some()
    }
}
#[derive(Clone, Default)]
pub(super) struct ClientState {
    sessions: Arc<Mutex<BTreeMap<String, Session>>>,
    quitting: Arc<AtomicBool>,
}
impl ClientState {
    pub(super) fn begin_quit(&self) {
        self.quitting.store(true, Ordering::Release);
    }
}
struct Executable {
    path: PathBuf,
    guard: File,
    prefix: Vec<String>,
    runtime: Option<Arc<VerifiedRuntime>>,
}
struct LaunchResources {
    plan: ClientPlan,
    _runtime: Option<Arc<VerifiedRuntime>>,
}
struct ProbeOutput {
    path: PathBuf,
    file: File,
}
impl Drop for ProbeOutput {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}
struct ProbeFailure {
    issue: &'static str,
    process: Option<Box<dyn console::OwnedProcess>>,
    output: Option<ProbeOutput>,
}
impl ProbeFailure {
    fn clean(issue: &'static str) -> Self {
        Self {
            issue,
            process: None,
            output: None,
        }
    }
    fn uncertain(
        issue: &'static str,
        process: Box<dyn console::OwnedProcess>,
        output: ProbeOutput,
    ) -> Self {
        Self {
            issue,
            process: Some(process),
            output: Some(output),
        }
    }
}
fn agy_identity_probe_arguments(home: &std::path::Path) -> Vec<String> {
    vec![
        format!("--gemini_dir={}", home.to_string_lossy()),
        "--help".into(),
    ]
}
fn agy_help_identifies_cli(bytes: &[u8]) -> bool {
    if bytes.is_empty() || bytes.len() > 64 * 1024 {
        return false;
    }
    let Ok(text) = std::str::from_utf8(bytes) else {
        return false;
    };
    let text = text.to_ascii_lowercase();
    text.contains("antigravity") && text.contains("usage")
        || text.contains("usage: agy")
        || text.contains("agy cli")
}
fn provider_error(code: &'static str) -> provider_pool::Error {
    provider_pool::Error { code }
}
fn finish_start_failure(
    session: &mut Session,
    failure: console::StartFailure,
    resources: Arc<dyn Send + Sync>,
    output: Option<ProbeOutput>,
    issue_after_cleanup: &'static str,
) -> provider_pool::Error {
    let (_, owner) = failure.into_parts();
    if let Some(mut owner) = owner {
        if owner.stop().is_err() {
            session.retain_uncertain_process(owner, resources, output, issue_after_cleanup);
            return provider_error("provider_pool_client_cleanup_unconfirmed");
        }
    }
    provider_error(issue_after_cleanup)
}
fn agy_identity_probe_environment(
    home: &std::path::Path,
) -> Result<launch::Environment, provider_pool::Error> {
    // This is an identity/self-check only. The help handler may ignore unknown
    // options; Windows native evidence must still confirm --gemini_dir use.
    // It runs with the dependency-probe allowlist, never inherited credentials.
    launch::Environment::dependency_probe(home)
        .map_err(|_| provider_error("provider_pool_client_cli_contract_unverified"))
}
#[cfg(windows)]
fn probe_agy_cli_identity(
    executable: &Executable,
    home: &std::path::Path,
    quitting: &AtomicBool,
    resources: Arc<LaunchResources>,
    domains: Arc<codexu_core::automatic_switch::live::OwnedProcessDomains>,
) -> Result<(), ProbeFailure> {
    const CONTRACT_UNVERIFIED: &str = "provider_pool_client_cli_contract_unverified";
    const LAUNCH_CANCELLED: &str = "launch_cancelled";
    const OUTPUT_LIMIT: u64 = 64 * 1024;
    let home =
        launch::checked_directory(home).map_err(|_| ProbeFailure::clean(CONTRACT_UNVERIFIED))?;
    let nonce = launch::session_nonce().map_err(|_| ProbeFailure::clean(CONTRACT_UNVERIFIED))?;
    let suffix: String = nonce.iter().map(|b| format!("{b:02x}")).collect();
    let path = home.join(format!(".agy-contract-{suffix}.out"));
    let file = std::fs::OpenOptions::new()
        .create_new(true)
        .read(true)
        .write(true)
        .open(&path)
        .map_err(|_| ProbeFailure::clean(CONTRACT_UNVERIFIED))?;
    let output = ProbeOutput { path, file };
    let environment = agy_identity_probe_environment(&home)
        .map_err(|_| ProbeFailure::clean(CONTRACT_UNVERIFIED))?;
    let arguments = agy_identity_probe_arguments(&home);
    let guard = executable
        .guard
        .try_clone()
        .map_err(|_| ProbeFailure::clean(CONTRACT_UNVERIFIED))?;
    let mut probe = match console::OwnedConsole::start_registered_owned(
        &executable.path,
        &home,
        &arguments,
        guard,
        &environment,
        "AiGoodBro - Agy CLI check",
        Some(domains),
        Some(resources),
        Some(&output.file),
    ) {
        Ok(probe) => probe,
        Err(failure) => {
            let (_, owner) = failure.into_parts();
            if let Some(mut owner) = owner {
                if owner.stop().is_err() {
                    return Err(ProbeFailure::uncertain(CONTRACT_UNVERIFIED, owner, output));
                }
            }
            return Err(ProbeFailure::clean(CONTRACT_UNVERIFIED));
        }
    };
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    let successful = loop {
        if quitting.load(Ordering::Acquire) {
            if probe.stop().is_err() {
                return Err(ProbeFailure::uncertain(
                    LAUNCH_CANCELLED,
                    Box::new(probe),
                    output,
                ));
            }
            return Err(ProbeFailure::clean(LAUNCH_CANCELLED));
        }
        let output_length = match output.file.metadata() {
            Ok(metadata) => metadata.len(),
            Err(_) => {
                if probe.stop().is_err() {
                    return Err(ProbeFailure::uncertain(
                        CONTRACT_UNVERIFIED,
                        Box::new(probe),
                        output,
                    ));
                }
                return Err(ProbeFailure::clean(CONTRACT_UNVERIFIED));
            }
        };
        if output_length > OUTPUT_LIMIT {
            if probe.stop().is_err() {
                return Err(ProbeFailure::uncertain(
                    CONTRACT_UNVERIFIED,
                    Box::new(probe),
                    output,
                ));
            }
            return Err(ProbeFailure::clean(CONTRACT_UNVERIFIED));
        }
        match probe.has_exited() {
            Ok(true) => {
                break match probe.exit_success() {
                    Ok(success) => success,
                    // `has_exited` already observed both the root and whole
                    // Job empty; an exit-code query failure does not require
                    // retaining an otherwise confirmed-empty process.
                    Err(_) => return Err(ProbeFailure::clean(CONTRACT_UNVERIFIED)),
                };
            }
            Ok(false) if std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            Ok(false) => {
                if probe.stop().is_err() {
                    return Err(ProbeFailure::uncertain(
                        CONTRACT_UNVERIFIED,
                        Box::new(probe),
                        output,
                    ));
                }
                return Err(ProbeFailure::clean(CONTRACT_UNVERIFIED));
            }
            Err(_) => {
                if probe.stop().is_err() {
                    return Err(ProbeFailure::uncertain(
                        CONTRACT_UNVERIFIED,
                        Box::new(probe),
                        output,
                    ));
                }
                return Err(ProbeFailure::clean(CONTRACT_UNVERIFIED));
            }
        }
    };
    drop(probe); // Releasing the Job is safe only after has_exited saw it empty.
    if !successful {
        return Err(ProbeFailure::clean(CONTRACT_UNVERIFIED));
    }
    let length = output
        .file
        .metadata()
        .map_err(|_| ProbeFailure::clean(CONTRACT_UNVERIFIED))?
        .len();
    if length > OUTPUT_LIMIT {
        return Err(ProbeFailure::clean(CONTRACT_UNVERIFIED));
    }
    let mut file = &output.file;
    file.seek(SeekFrom::Start(0))
        .map_err(|_| ProbeFailure::clean(CONTRACT_UNVERIFIED))?;
    let mut bytes = Vec::with_capacity(length as usize);
    file.take(OUTPUT_LIMIT + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| ProbeFailure::clean(CONTRACT_UNVERIFIED))?;
    if !agy_help_identifies_cli(&bytes) {
        return Err(ProbeFailure::clean(CONTRACT_UNVERIFIED));
    }
    Ok(())
}
#[cfg(not(windows))]
fn probe_agy_cli_identity(
    _: &Executable,
    _: &std::path::Path,
    _: &AtomicBool,
    _: Arc<LaunchResources>,
    _: Arc<codexu_core::automatic_switch::live::OwnedProcessDomains>,
) -> Result<(), ProbeFailure> {
    Err(ProbeFailure::clean(
        "provider_pool_client_cli_contract_unverified",
    ))
}
fn kind_name(kind: ClientKind) -> &'static str {
    match kind {
        ClientKind::Codex => "codex",
        ClientKind::Native => "native",
        ClientKind::Agy => "agy",
    }
}
fn exit_outcome(kind: &str, success: bool) -> (&'static str, Option<&'static str>) {
    if kind == "agy" && !success {
        ("failed", Some("provider_pool_client_cli_failed"))
    } else {
        ("exited", None)
    }
}
fn request_digest(r: &StartRequest) -> Result<[u8; 32], String> {
    if r.request_id.len() != 32
        || !r
            .request_id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        || !(20..=128).contains(&r.run_id.len())
        || !r
            .run_id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
        || match r.kind {
            ClientKind::Agy => r.provider != Provider::Antigravity || !r.model.is_empty(),
            ClientKind::Codex | ClientKind::Native => {
                r.model.is_empty()
                    || r.model.len() > 128
                    || !r
                        .model
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
            }
        }
    {
        return Err("provider_pool_client_request_invalid".into());
    }
    let body = serde_json::to_vec(&(
        r.run_id.as_str(),
        r.provider,
        kind_name(r.kind),
        r.model.as_str(),
        &r.workspace,
    ))
    .map_err(|_| "provider_pool_client_request_invalid")?;
    Ok(Sha256::digest(body).into())
}
fn previous(
    sessions: &mut BTreeMap<String, Session>,
    id: &str,
    digest: &[u8; 32],
) -> Result<Option<ClientDto>, String> {
    match sessions.get_mut(id) {
        Some(s) if &s.digest == digest => {
            s.refresh();
            Ok(Some(s.dto.clone()))
        }
        Some(_) => Err("provider_pool_client_request_conflict".into()),
        None => Ok(None),
    }
}
async fn executable(
    app: &AppHandle,
    state: &Arc<AppState>,
    workflow: &WorkflowState,
    r: &StartRequest,
) -> Result<Executable, String> {
    if r.kind == ClientKind::Codex {
        let (path, guard) = native_executable(&state.app_data_dir)
            .await
            .map_err(|_| "provider_pool_client_runtime_unavailable")?;
        return Ok(Executable {
            path,
            guard,
            prefix: vec![],
            runtime: None,
        });
    }
    if r.kind == ClientKind::Agy {
        if r.provider != Provider::Antigravity {
            return Err("provider_pool_client_unavailable".into());
        }
        let (path, guard) = launch::discover_agy(&PlatformDirectories::detect())
            .map_err(|_| "provider_pool_client_runtime_unavailable")?
            .into_parts();
        return Ok(Executable {
            path,
            guard,
            prefix: vec![],
            runtime: None,
        });
    }
    let kind = match r.provider {
        Provider::Claude => LocalCliKind::ClaudeCode,
        Provider::Kimi => LocalCliKind::Kimi,
        Provider::Xai => LocalCliKind::Grok,
        Provider::Antigravity => return Err("provider_pool_native_client_unavailable".into()),
    };
    match local_actions::discover(app, state, workflow, kind)
        .await
        .map_err(|_| "provider_pool_client_runtime_unavailable")?
    {
        local_actions::Executable::Native(v) => {
            let (path, guard) = v.into_parts();
            Ok(Executable {
                path,
                guard,
                prefix: vec![],
                runtime: None,
            })
        }
        local_actions::Executable::Package(v) => Ok(Executable {
            path: v.executable().to_owned(),
            guard: v
                .executable_guard()
                .map_err(|_| "provider_pool_client_runtime_unavailable")?,
            prefix: v.prefix().to_vec(),
            runtime: Some(v),
        }),
    }
}

#[tauri::command]
pub async fn start_provider_pool_client(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    workflow: State<'_, WorkflowState>,
    pool: State<'_, ProviderPoolState>,
    services: State<'_, NativeServices>,
    mut request: StartRequest,
) -> Result<ClientDto, String> {
    request.workspace = launch::checked_directory(&request.workspace)
        .map_err(|_| "provider_pool_client_workspace_unavailable")?;
    let digest = request_digest(&request)?;
    let clients = workflow.pool_clients.clone();
    {
        let mut sessions = clients
            .sessions
            .lock()
            .map_err(|_| "provider_pool_client_state_unavailable")?;
        if let Some(value) = previous(&mut sessions, &request.request_id, &digest)? {
            return Ok(value);
        }
    }
    if workflow.quitting.load(Ordering::Acquire) || clients.quitting.load(Ordering::Acquire) {
        return Err("launch_cancelled".into());
    }
    let executable = executable(&app, &state, &workflow, &request).await?;
    let pool = pool.service()?;
    let domains = services.owned_domains.clone();
    let directory = state.app_data_dir.clone();
    {
        let mut sessions = clients
            .sessions
            .lock()
            .map_err(|_| "provider_pool_client_state_unavailable")?;
        if let Some(value) = previous(&mut sessions, &request.request_id, &digest)? {
            return Ok(value);
        }
        if clients.quitting.load(Ordering::Acquire) {
            return Err("launch_cancelled".into());
        }
        if sessions.len() >= 256 {
            return Err("provider_pool_client_session_limit".into());
        }
        sessions.insert(
            request.request_id.clone(),
            Session {
                dto: ClientDto {
                    request_id: request.request_id.clone(),
                    run_id: request.run_id.clone(),
                    provider: request.provider,
                    kind: kind_name(request.kind),
                    model: request.model.clone(),
                    state: "checking",
                    issue_code: None,
                },
                digest,
                process: None,
                uncertain_resources: None,
                failure_after_cleanup: None,
                probe_output: None,
            },
        );
    }
    // This owner worker completes and publishes state even if the invoking
    // WebView closes. It does not borrow the IPC future or its cancellation.
    tauri::async_runtime::spawn_blocking(move || {
        let mut sessions = clients
            .sessions
            .lock()
            .map_err(|_| "provider_pool_client_state_unavailable".to_owned())?;
        let session = sessions
            .get_mut(&request.request_id)
            .ok_or("provider_pool_client_state_unavailable")?;
        let result = pool.with_connection(
            &request.run_id,
            request.provider,
            Some(&request.model),
            |connection| {
                if clients.quitting.load(Ordering::Acquire) {
                    return Err(provider_pool::Error {
                        code: "launch_cancelled",
                    });
                }
                if request.kind == ClientKind::Agy {
                    client::confirm_agy_available(&connection)?;
                } else {
                    client::confirm_model(&connection, request.provider, &request.model)?;
                }
                let mut plan = client::prepare(
                    &directory,
                    &connection,
                    request.provider,
                    request.kind,
                    &request.model,
                )?;
                if let Some(runtime) = &executable.runtime {
                    plan.environment =
                        plan.environment
                            .with_verified_product(runtime)
                            .map_err(|_| provider_pool::Error {
                                code: "provider_pool_client_runtime_unavailable",
                            })?;
                }
                let resources = Arc::new(LaunchResources {
                    plan,
                    _runtime: executable.runtime.clone(),
                });
                if request.kind == ClientKind::Agy {
                    if let Err(failure) = probe_agy_cli_identity(
                        &executable,
                        &resources.plan.home,
                        &clients.quitting,
                        resources.clone(),
                        domains.clone(),
                    ) {
                        if let Some(process) = failure.process {
                            session.retain_uncertain_process(
                                process,
                                resources.clone(),
                                failure.output,
                                failure.issue,
                            );
                            return Err(provider_error("provider_pool_client_cleanup_unconfirmed"));
                        }
                        return Err(provider_error(failure.issue));
                    }
                }
                let mut args = executable.prefix;
                args.extend(resources.plan.arguments.clone());
                if clients.quitting.load(Ordering::Acquire)
                    || launch::checked_directory(&request.workspace).ok().as_ref()
                        != Some(&request.workspace)
                {
                    return Err(provider_pool::Error {
                        code: "launch_cancelled",
                    });
                }
                if request.kind == ClientKind::Agy {
                    match console::OwnedConsole::start_registered_owned(
                        &executable.path,
                        &request.workspace,
                        &args,
                        executable.guard,
                        &resources.plan.environment,
                        "AiGoodBro - Provider client",
                        Some(domains),
                        Some(resources.clone()),
                        None,
                    ) {
                        Ok(process) => Ok(process),
                        Err(failure) => Err(finish_start_failure(
                            session,
                            failure,
                            resources.clone(),
                            None,
                            "provider_pool_client_runtime_unavailable",
                        )),
                    }
                } else {
                    match console::OwnedConsole::start_registered_owned(
                        &executable.path,
                        &request.workspace,
                        &args,
                        executable.guard,
                        &resources.plan.environment,
                        "AiGoodBro - Provider client",
                        Some(domains),
                        Some(resources.clone()),
                        None,
                    ) {
                        Ok(process) => Ok(process),
                        Err(failure) => Err(finish_start_failure(
                            session,
                            failure,
                            resources.clone(),
                            None,
                            "provider_pool_client_runtime_unavailable",
                        )),
                    }
                }
            },
        );
        match result {
            Ok(process) => {
                session.process = Some(Box::new(process));
                session.dto.state = "running";
                session.refresh();
            }
            Err(e) => {
                session.dto.state = if session.uncertain_resources.is_some() {
                    "cleanupUnconfirmed"
                } else {
                    "failed"
                };
                session.dto.issue_code = Some(e.code);
            }
        }
        let dto = session.dto.clone();
        drop(sessions);
        let _ = app.emit("provider-pool-clients:changed", ());
        Ok(dto)
    })
    .await
    .map_err(|_| "provider_pool_client_state_unavailable".to_owned())?
}
#[tauri::command]
pub async fn get_provider_pool_clients(
    workflow: State<'_, WorkflowState>,
) -> Result<Vec<ClientDto>, String> {
    let clients = workflow.pool_clients.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let mut sessions = clients
            .sessions
            .lock()
            .map_err(|_| "provider_pool_client_state_unavailable".to_owned())?;
        Ok(sessions
            .values_mut()
            .map(|s| {
                s.refresh();
                s.dto.clone()
            })
            .collect())
    })
    .await
    .map_err(|_| "provider_pool_client_state_unavailable".to_owned())?
}
#[tauri::command]
pub async fn stop_provider_pool_client(
    app: AppHandle,
    workflow: State<'_, WorkflowState>,
    request_id: String,
    confirmed: bool,
) -> Result<ClientDto, String> {
    if !confirmed {
        return Err("provider_pool_client_confirmation_required".into());
    }
    let clients = workflow.pool_clients.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let mut sessions = clients
            .sessions
            .lock()
            .map_err(|_| "provider_pool_client_state_unavailable".to_owned())?;
        let s = sessions
            .get_mut(&request_id)
            .ok_or("provider_pool_client_unknown")?;
        s.stop_owned();
        let dto = s.dto.clone();
        drop(sessions);
        let _ = app.emit("provider-pool-clients:changed", ());
        Ok(dto)
    })
    .await
    .map_err(|_| "provider_pool_client_state_unavailable".to_owned())?
}
pub(super) fn blocks_exit(workflow: &WorkflowState) -> bool {
    let Ok(mut sessions) = workflow.pool_clients.sessions.try_lock() else {
        return true;
    };
    sessions.values_mut().any(|s| {
        s.refresh();
        s.active()
    })
}
pub(super) fn force_stop(workflow: &WorkflowState) {
    workflow.pool_clients.begin_quit();
    let Ok(mut sessions) = workflow.pool_clients.sessions.try_lock() else {
        return;
    };
    for s in sessions.values_mut() {
        s.stop_owned();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request() -> StartRequest {
        StartRequest {
            request_id: "a".repeat(32),
            run_id: "b".repeat(32),
            provider: Provider::Claude,
            kind: ClientKind::Codex,
            model: "synthetic-model".into(),
            workspace: PathBuf::from("/synthetic-project"),
        }
    }
    #[test]
    fn client_request_digest_binds_every_launch_input_and_rejects_arbitrary_fields() {
        let r = request();
        let baseline = request_digest(&r).unwrap();
        let mut changed = r.clone();
        changed.model = "different".into();
        assert_ne!(baseline, request_digest(&changed).unwrap());
        changed = r.clone();
        changed.workspace = PathBuf::from("/other");
        assert_ne!(baseline, request_digest(&changed).unwrap());
        changed = r.clone();
        changed.kind = ClientKind::Native;
        assert_ne!(baseline, request_digest(&changed).unwrap());
        changed = r.clone();
        changed.run_id = "c".repeat(32);
        assert_ne!(baseline, request_digest(&changed).unwrap());
        changed = r.clone();
        changed.request_id = "not-an-id".into();
        assert!(request_digest(&changed).is_err());
        assert!(serde_json::from_value::<StartRequest>(serde_json::json!({"requestId":"a".repeat(32),"runId":"b".repeat(32),"provider":"claude","kind":"codex","model":"m","workspace":"/synthetic","environment":{}})).is_err());
    }
    #[test]
    fn agy_request_has_no_guessed_model_and_is_antigravity_only() {
        let mut r = request();
        r.provider = Provider::Antigravity;
        r.kind = ClientKind::Agy;
        r.model.clear();
        assert!(request_digest(&r).is_ok());

        r.model = "gemini-3.1-pro".into();
        assert!(request_digest(&r).is_err());
        r.model.clear();
        r.provider = Provider::Claude;
        assert!(request_digest(&r).is_err());
    }
    #[test]
    fn agy_nonzero_exit_is_reported_as_failure_after_owned_job_cleanup() {
        assert_eq!(
            exit_outcome("agy", false),
            ("failed", Some("provider_pool_client_cli_failed"))
        );
        assert_eq!(exit_outcome("agy", true), ("exited", None));
        assert_eq!(exit_outcome("native", false), ("exited", None));
    }
    #[test]
    fn agy_identity_probe_uses_expected_arguments_and_rejects_other_cli_output() {
        assert_eq!(
            agy_identity_probe_arguments(std::path::Path::new(r"C:\private Agy home")),
            [r"--gemini_dir=C:\private Agy home", "--help"]
        );
        assert!(agy_help_identifies_cli(
            b"Antigravity CLI\nUsage: agy [options]\n"
        ));
        assert!(!agy_help_identifies_cli(
            b"Google Chrome\nUsage: chrome.exe [options]\n"
        ));
        assert!(!agy_help_identifies_cli(&vec![b'a'; 64 * 1024 + 1]));
    }
    #[test]
    fn agy_identity_probe_environment_drops_all_inherited_provider_credentials() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().canonicalize().unwrap();
        let environment = agy_identity_probe_environment(&home).unwrap();
        let applied = environment
            .apply([
                ("GEMINI_API_KEY".into(), "ambient-gemini".into()),
                ("GOOGLE_API_KEY".into(), "ambient-google".into()),
                (
                    "GOOGLE_GEMINI_BASE_URL".into(),
                    "https://ambient.invalid".into(),
                ),
                ("ANTHROPIC_API_KEY".into(), "ambient-anthropic".into()),
                ("ANTHROPIC_AUTH_TOKEN".into(), "ambient-auth".into()),
                ("OPENAI_API_KEY".into(), "ambient-openai".into()),
            ])
            .unwrap();
        let names: Vec<_> = applied
            .iter()
            .map(|(key, _)| key.to_string_lossy().to_ascii_uppercase())
            .collect();
        for forbidden in [
            "GEMINI_API_KEY",
            "GOOGLE_API_KEY",
            "GOOGLE_GEMINI_BASE_URL",
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "OPENAI_API_KEY",
        ] {
            assert!(!names.iter().any(|name| name == forbidden), "{forbidden}");
        }
    }
    #[test]
    fn repeated_requests_return_retained_result_and_changed_body_is_rejected() {
        let r = request();
        let digest = request_digest(&r).unwrap();
        let mut sessions = BTreeMap::new();
        sessions.insert(
            r.request_id.clone(),
            Session {
                dto: ClientDto {
                    request_id: r.request_id.clone(),
                    run_id: r.run_id,
                    provider: r.provider,
                    kind: "codex",
                    model: r.model,
                    state: "failed",
                    issue_code: Some("provider_pool_client_runtime_unavailable"),
                },
                digest,
                process: None,
                uncertain_resources: None,
                failure_after_cleanup: None,
                probe_output: None,
            },
        );
        assert_eq!(
            previous(&mut sessions, &r.request_id, &digest)
                .unwrap()
                .unwrap()
                .state,
            "failed"
        );
        assert!(previous(&mut sessions, &r.request_id, &[0; 32]).is_err());
        assert_eq!(sessions.len(), 1);
        let dto = serde_json::to_string(&sessions[&r.request_id].dto).unwrap();
        assert!(!dto.contains("workspace") && !dto.contains("environment") && !dto.contains("key"));
    }
    #[test]
    fn checking_and_contended_state_block_exit_and_quit_revokes_future_launches() {
        let workflow = WorkflowState::default();
        assert!(!blocks_exit(&workflow));
        let guard = workflow.pool_clients.sessions.lock().unwrap();
        assert!(blocks_exit(&workflow));
        drop(guard);
        workflow.begin_force_quit();
        assert!(workflow.pool_clients.quitting.load(Ordering::Acquire));
    }

    #[derive(Default)]
    struct FakeJob {
        root_exited: bool,
        job_members: u32,
        query_error: bool,
        stop_error: bool,
        exit_success: bool,
        stop_calls: usize,
    }
    struct DropOnce(Arc<std::sync::atomic::AtomicUsize>);
    impl Drop for DropOnce {
        fn drop(&mut self) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }
    struct FakeOwnedProcess {
        state: Arc<Mutex<FakeJob>>,
        _resource: Arc<DropOnce>,
    }
    impl console::OwnedProcess for FakeOwnedProcess {
        fn has_exited(&mut self) -> std::io::Result<bool> {
            let state = self.state.lock().unwrap();
            if state.query_error {
                return Err(std::io::Error::other("synthetic wait/query unknown"));
            }
            Ok(state.root_exited && state.job_members == 0)
        }
        fn stop(&mut self) -> std::io::Result<()> {
            let mut state = self.state.lock().unwrap();
            state.stop_calls += 1;
            if state.stop_error {
                return Err(std::io::Error::other("synthetic Job stop unknown"));
            }
            state.root_exited = true;
            state.job_members = 0;
            Ok(())
        }
        fn exit_success(&mut self) -> std::io::Result<bool> {
            Ok(self.state.lock().unwrap().exit_success)
        }
    }
    fn agy_session() -> Session {
        Session {
            dto: ClientDto {
                request_id: "a".repeat(32),
                run_id: "b".repeat(32),
                provider: Provider::Antigravity,
                kind: "agy",
                model: String::new(),
                state: "checking",
                issue_code: None,
            },
            digest: [0; 32],
            process: None,
            uncertain_resources: None,
            failure_after_cleanup: None,
            probe_output: None,
        }
    }
    fn resource(counter: &Arc<std::sync::atomic::AtomicUsize>) -> Arc<DropOnce> {
        Arc::new(DropOnce(counter.clone()))
    }
    fn probe_output(directory: &std::path::Path) -> ProbeOutput {
        let path = directory.join("probe.out");
        let file = std::fs::OpenOptions::new()
            .create_new(true)
            .read(true)
            .write(true)
            .open(&path)
            .unwrap();
        ProbeOutput { path, file }
    }

    #[test]
    fn unknown_probe_cleanup_retains_job_home_and_capture_until_whole_job_empty() {
        let directory = tempfile::tempdir().unwrap();
        let output_path = directory.path().join("probe.out");
        let output = probe_output(directory.path());
        let drops = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let held = resource(&drops);
        let weak = Arc::downgrade(&held);
        let state = Arc::new(Mutex::new(FakeJob {
            job_members: 1,
            query_error: true,
            stop_error: true,
            ..Default::default()
        }));
        let mut session = agy_session();
        let resources: Arc<dyn Send + Sync> = held.clone();
        session.retain_uncertain_process(
            Box::new(FakeOwnedProcess {
                state: state.clone(),
                _resource: held.clone(),
            }),
            resources,
            Some(output),
            "provider_pool_client_cli_contract_unverified",
        );

        session.stop_owned();
        assert_eq!(session.dto.state, "cleanupUnconfirmed");
        assert!(session.active());
        assert!(weak.upgrade().is_some());
        assert!(output_path.exists());
        assert_eq!(state.lock().unwrap().stop_calls, 1);

        {
            let mut job = state.lock().unwrap();
            job.query_error = false;
            job.root_exited = true;
            // A signaled root is not enough while a descendant remains.
            job.job_members = 1;
        }
        session.stop_owned();
        assert_eq!(session.dto.state, "cleanupUnconfirmed");
        assert!(session.active());
        assert!(weak.upgrade().is_some());
        assert!(output_path.exists());
        assert_eq!(state.lock().unwrap().stop_calls, 2);

        session.refresh();
        assert_eq!(session.dto.state, "cleanupUnconfirmed");
        assert!(session.active());
        assert!(output_path.exists());

        state.lock().unwrap().job_members = 0;
        session.refresh();
        assert_eq!(session.dto.state, "failed");
        assert_eq!(
            session.dto.issue_code,
            Some("provider_pool_client_cli_contract_unverified")
        );
        assert!(!session.active());
        assert!(!output_path.exists());
        drop(held);
        assert!(weak.upgrade().is_none());
        assert_eq!(drops.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn post_create_registration_failure_transfers_owner_until_job_is_confirmed_empty() {
        let directory = tempfile::tempdir().unwrap();
        let output_path = directory.path().join("probe.out");
        let output = probe_output(directory.path());
        let drops = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let held = resource(&drops);
        let weak = Arc::downgrade(&held);
        let state = Arc::new(Mutex::new(FakeJob {
            job_members: 1,
            query_error: true,
            stop_error: true,
            ..Default::default()
        }));
        // This mirrors a native post-CreateProcess registration/resume error:
        // StartFailure must transfer the partial owner to the session.
        let failure = console::StartFailure::after_create(
            std::io::Error::other("synthetic registration failed"),
            Box::new(FakeOwnedProcess {
                state: state.clone(),
                _resource: held.clone(),
            }),
        );
        let mut session = agy_session();
        let resources: Arc<dyn Send + Sync> = held.clone();
        let error = finish_start_failure(
            &mut session,
            failure,
            resources,
            Some(output),
            "provider_pool_client_runtime_unavailable",
        );
        assert_eq!(error.code, "provider_pool_client_cleanup_unconfirmed");
        assert_eq!(session.dto.state, "cleanupUnconfirmed");
        assert!(session.active());
        assert!(output_path.exists());
        assert_eq!(state.lock().unwrap().stop_calls, 1);

        {
            let mut job = state.lock().unwrap();
            job.query_error = false;
            job.root_exited = true;
            job.job_members = 1;
        }
        session.refresh();
        assert!(session.active());
        {
            let mut job = state.lock().unwrap();
            job.stop_error = false;
            job.job_members = 0;
        }
        session.stop_owned();
        assert_eq!(session.dto.state, "failed");
        assert_eq!(
            session.dto.issue_code,
            Some("provider_pool_client_runtime_unavailable")
        );
        assert!(!output_path.exists());
        assert!(!session.active());
        drop(held);
        assert!(weak.upgrade().is_none());
        assert_eq!(drops.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn normal_launch_waits_for_root_and_all_job_members_before_releasing_lease() {
        let drops = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let held = resource(&drops);
        let weak = Arc::downgrade(&held);
        let state = Arc::new(Mutex::new(FakeJob {
            job_members: 1,
            exit_success: false,
            ..Default::default()
        }));
        let mut session = agy_session();
        session.dto.state = "running";
        session.process = Some(Box::new(FakeOwnedProcess {
            state: state.clone(),
            _resource: held.clone(),
        }));

        state.lock().unwrap().root_exited = true;
        session.refresh();
        assert_eq!(session.dto.state, "running");
        assert!(session.active());
        assert!(weak.upgrade().is_some());

        state.lock().unwrap().job_members = 0;
        session.refresh();
        assert_eq!(session.dto.state, "failed");
        assert_eq!(
            session.dto.issue_code,
            Some("provider_pool_client_cli_failed")
        );
        assert!(!session.active());
        drop(held);
        assert!(weak.upgrade().is_none());
        assert_eq!(drops.load(Ordering::SeqCst), 1);
    }
}
