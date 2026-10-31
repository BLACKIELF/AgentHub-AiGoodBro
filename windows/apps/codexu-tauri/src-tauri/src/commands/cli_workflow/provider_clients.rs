//! Explicit clients use a private pool home and a registered owned console.
//! The gateway key never crosses IPC or enters argv. Request IDs are retained
//! for this app lifetime, including failed/unknown starts, and never replayed.
use super::{console, local_actions, native_executable, AppState, WorkflowState};
use crate::commands::provider_pool::ProviderPoolState;
use crate::native_services::NativeServices;
use codexu_core::{
    local_cli::{dependency::VerifiedRuntime, launch, LocalCliKind},
    provider_pool::{
        self,
        client::{self, ClientKind, ClientPlan},
        Provider,
    },
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
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
    process: Option<console::OwnedConsole>,
    // A failed spawn does not prove cleanup. Retain the home/runtime lease
    // conservatively; never reuse it or tell the caller that cleanup succeeded.
    uncertain_resources: Option<Arc<LaunchResources>>,
}
impl Session {
    fn refresh(&mut self) {
        if let Some(p) = self.process.as_mut() {
            match p.has_exited() {
                Ok(true) => {
                    self.process = None;
                    self.dto.state = "exited";
                    self.dto.issue_code = None;
                }
                Ok(false) => {}
                Err(_) => {
                    self.dto.state = "cleanupUnconfirmed";
                    self.dto.issue_code = Some("provider_pool_client_cleanup_unconfirmed");
                }
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
fn kind_name(kind: ClientKind) -> &'static str {
    if kind == ClientKind::Codex {
        "codex"
    } else {
        "native"
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
        || r.model.is_empty()
        || r.model.len() > 128
        || !r
            .model
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
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
                client::confirm_model(&connection, request.provider, &request.model)?;
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
                let mut args = executable.prefix;
                args.extend(plan.arguments.clone());
                let resources = Arc::new(LaunchResources {
                    plan,
                    _runtime: executable.runtime,
                });
                if clients.quitting.load(Ordering::Acquire)
                    || launch::checked_directory(&request.workspace).ok().as_ref()
                        != Some(&request.workspace)
                {
                    return Err(provider_pool::Error {
                        code: "launch_cancelled",
                    });
                }
                match console::OwnedConsole::start_registered(
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
                    Err(_) => {
                        session.uncertain_resources = Some(resources);
                        Err(provider_pool::Error {
                            code: "provider_pool_client_cleanup_unconfirmed",
                        })
                    }
                }
            },
        );
        match result {
            Ok(process) => {
                session.process = Some(process);
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
        s.refresh();
        if let Some(p) = s.process.as_mut() {
            match p.stop() {
                Ok(()) => {
                    s.process = None;
                    s.dto.state = "stopped";
                    s.dto.issue_code = None;
                }
                Err(_) => {
                    s.dto.state = "cleanupUnconfirmed";
                    s.dto.issue_code = Some("provider_pool_client_cleanup_unconfirmed");
                }
            }
        }
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
        if s.process.as_mut().is_some_and(|p| p.stop().is_ok()) {
            s.process = None;
            s.dto.state = "stopped";
            s.dto.issue_code = None;
        }
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
}
