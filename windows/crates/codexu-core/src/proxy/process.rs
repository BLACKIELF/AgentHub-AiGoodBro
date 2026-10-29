use super::{host::unix_now, *};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, PipeWriter, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

#[path = "command_pipe.rs"]
mod command_pipe;
#[path = "registration.rs"]
mod registration;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProxyPhase {
    #[default]
    Stopped,
    Starting,
    Running,
    Stopping,
    Failed,
}
#[derive(Clone, Default, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProxyAccountState {
    pub state: String,
    pub cooldown_until: Option<i64>,
    pub cooldown_kind: Option<String>,
    pub probe_state: Option<String>,
}
#[derive(Clone, Default, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProxyStatus {
    pub phase: ProxyPhase,
    pub port: Option<u16>,
    pub issue: Option<String>,
    pub accounts: BTreeMap<String, ProxyAccountState>,
    pub last_event_at: Option<f64>,
    pub egress: Option<ProxyEgressState>,
}
#[derive(Clone, Default, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProxyEgressState {
    pub state: String,
    pub request_id: Option<String>,
    pub latency_ms: Option<u32>,
}
/// Returned only by the explicit Copy connection action.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProxyConnection {
    pub endpoint: String,
    pub client_key: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProxyEvent {
    pub event: String,
    pub port: Option<u16>,
    #[serde(rename = "profileID")]
    pub profile_id: Option<String>,
    pub state: Option<String>,
    pub cooldown_until: Option<i64>,
    pub cooldown_kind: Option<String>,
    pub probe_state: Option<String>,
    pub error_code: Option<String>,
    #[serde(rename = "requestID")]
    pub request_id: Option<String>,
    #[serde(rename = "latencyMS")]
    pub latency_ms: Option<u32>,
    #[serde(rename = "runID")]
    pub run_id: Option<String>,
    pub identity_hash: Option<String>,
}

pub struct LocalProxyService {
    host: Arc<Mutex<ProxyHost>>,
    inner: Mutex<ServiceInner>,
    lifecycle: Mutex<()>,
    status: Arc<Mutex<ProxyStatus>>,
    preferences_path: PathBuf,
    state_directory: PathBuf,
    helper_path: PathBuf,
    models: Vec<String>,
    secrets: Arc<dyn ProxySecretStore>,
    event_generation: Arc<AtomicUsize>,
    command_generation: AtomicUsize,
    recoverable_exit: AtomicBool,
    monitor_active: Arc<AtomicBool>,
    registration: Arc<Mutex<Option<registration::PendingRegistration>>>,
}
struct ServiceInner {
    child: Option<OwnedHelper>,
    client_key: Option<String>,
}
struct OwnedHelper {
    child: Child,
    stdin: Option<PipeWriter>,
    control_stop: Arc<AtomicBool>,
    control_thread: Option<JoinHandle<()>>,
    command_generation: usize,
    #[cfg(windows)]
    _job: WindowsJob,
}
impl LocalProxyService {
    fn owner_receipts(&self) -> Result<PathBuf, ProxyFailure> {
        Ok(self
            .preferences_path
            .parent()
            .ok_or(ProxyFailure::Unavailable)?
            .join("owned-process-receipts"))
    }
    pub fn recover_stale_owned_run(&self) -> Result<(), ProxyFailure> {
        let _lifecycle = self
            .lifecycle
            .try_lock()
            .map_err(|_| ProxyFailure::ControlBusy)?;
        if self
            .inner
            .try_lock()
            .map_err(|_| ProxyFailure::ControlBusy)?
            .child
            .is_some()
        {
            return Err(ProxyFailure::AccountBusy);
        }
        let gate = self.desktop_gate()?;
        if let Some(run) = gate.proxy_run_recovery_candidate()? {
            let proof = super::recovery::verify_helper(&self.owner_receipts()?, &run)?;
            gate.recover_proxy_run(&proof)?;
        }
        Ok(())
    }
    pub(crate) fn desktop_gate(&self) -> Result<Arc<dyn ProxyAccountGate>, ProxyFailure> {
        Ok(self
            .host
            .lock()
            .map_err(|_| ProxyFailure::Unavailable)?
            .gate
            .clone())
    }
    pub(crate) fn desktop_binding(
        &self,
        profile: &str,
    ) -> Result<super::desktop::DesktopProxyBinding, ProxyFailure> {
        let status = self.status()?;
        if status.phase != ProxyPhase::Running {
            return Err(ProxyFailure::Unavailable);
        }
        let inner = self.inner.lock().map_err(|_| ProxyFailure::Unavailable)?;
        let host = self.host.lock().map_err(|_| ProxyFailure::Unavailable)?;
        let (run_id, identity_hash, generation) = host.desktop_identity(profile)?;
        Ok(super::desktop::DesktopProxyBinding {
            run_id,
            identity_hash,
            generation,
            endpoint: format!(
                "http://127.0.0.1:{}/v1",
                status.port.ok_or(ProxyFailure::Unavailable)?
            ),
            client_key: inner.client_key.clone().ok_or(ProxyFailure::Unavailable)?,
            helper: self.helper_path.clone(),
            network_proxy: host.preferences().network_proxy,
        })
    }
    pub(crate) fn desktop_run_matches(&self, run: &str) -> Option<bool> {
        self.host.try_lock().ok().map(|h| h.run_matches(run))
    }
    pub(crate) fn desktop_connection_binding(
        &self,
        claim: &DesktopWriterClaim,
    ) -> Result<super::desktop::DesktopProxyBinding, ProxyFailure> {
        let status = self.status()?;
        if status.phase != ProxyPhase::Running {
            return Err(ProxyFailure::Unavailable);
        }
        let inner = self.inner.lock().map_err(|_| ProxyFailure::Unavailable)?;
        let host = self.host.lock().map_err(|_| ProxyFailure::Unavailable)?;
        let run_id = host.running_id().ok_or(ProxyFailure::Unavailable)?;
        Ok(super::desktop::DesktopProxyBinding {
            run_id,
            identity_hash: claim.identity_hash.clone(),
            generation: claim.initial_generation.clone(),
            endpoint: format!(
                "http://127.0.0.1:{}/v1",
                status.port.ok_or(ProxyFailure::Unavailable)?
            ),
            client_key: inner.client_key.clone().ok_or(ProxyFailure::Unavailable)?,
            helper: self.helper_path.clone(),
            network_proxy: host.preferences().network_proxy,
        })
    }
    /// UI-thread quit preflight: no process query, wait, file access or cleanup.
    /// Contention/unknown state conservatively retains the existing warning.
    pub fn requires_exit_confirmation(&self) -> bool {
        let Ok(inner) = self.inner.try_lock() else {
            return true;
        };
        let Ok(status) = self.status.try_lock() else {
            return true;
        };
        let Ok(host) = self.host.try_lock() else {
            return true;
        };
        inner.child.is_some()
            || host.has_unretired_run()
            || matches!(
                status.phase,
                ProxyPhase::Starting | ProxyPhase::Running | ProxyPhase::Stopping
            )
    }
    pub fn new(
        preferences_path: PathBuf,
        state_directory: PathBuf,
        helper_path: PathBuf,
        models: Vec<String>,
        gate: Arc<dyn ProxyAccountGate>,
        secrets: Arc<dyn ProxySecretStore>,
    ) -> Result<Self, ProxyFailure> {
        if !preferences_path.is_absolute()
            || !state_directory.is_absolute()
            || !helper_path.is_absolute()
            || models.is_empty()
            || models.len() > 100
            || models.iter().any(|m| {
                m.is_empty()
                    || m.len() > 128
                    || m.trim() != m
                    || m.contains(['/', '\\', '\r', '\n', '\0'])
            })
        {
            return Err(ProxyFailure::InvalidSettings);
        }
        let preferences = match std::fs::read(&preferences_path) {
            Ok(bytes) if bytes.len() <= 1 << 20 => {
                serde_json::from_slice::<ProxyPreferences>(&bytes)
                    .map_err(|_| ProxyFailure::InvalidSettings)?
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => ProxyPreferences::default(),
            _ => return Err(ProxyFailure::InvalidSettings),
        };
        Ok(Self {
            host: Arc::new(Mutex::new(ProxyHost::new(preferences, gate)?)),
            inner: Mutex::new(ServiceInner {
                child: None,
                client_key: None,
            }),
            lifecycle: Mutex::new(()),
            status: Arc::new(Mutex::new(ProxyStatus::default())),
            preferences_path,
            state_directory,
            helper_path,
            models,
            secrets,
            event_generation: Arc::new(AtomicUsize::new(0)),
            command_generation: AtomicUsize::new(0),
            recoverable_exit: AtomicBool::new(false),
            monitor_active: Arc::new(AtomicBool::new(false)),
            registration: Arc::new(Mutex::new(None)),
        })
    }
    pub fn preferences(&self) -> Result<ProxyPreferences, ProxyFailure> {
        let host = self.host.lock().map_err(|_| ProxyFailure::Unavailable)?;
        host.normalize_preferences(host.preferences())
    }
    pub fn save_preferences(
        &self,
        next: ProxyPreferences,
    ) -> Result<ProxyPreferences, ProxyFailure> {
        let _lifecycle = self
            .lifecycle
            .try_lock()
            .map_err(|_| ProxyFailure::ControlBusy)?;
        self.save_preferences_with_registration(next)
    }
    fn save_preferences_with_registration(
        &self,
        next: ProxyPreferences,
    ) -> Result<ProxyPreferences, ProxyFailure> {
        next.validate()?;
        let generation = self.command_generation.load(Ordering::Acquire);
        {
            let host = self.host.lock().map_err(|_| ProxyFailure::Unavailable)?;
            let trusted = host.trusted_ids()?;
            if next.enabled_ids.iter().any(|id| !trusted.contains(id)) {
                return Err(ProxyFailure::Identity);
            }
            if host.running_id().is_some()
                && (!next.is_enabled || !host.preferences().network_equal(&next))
            {
                return Err(ProxyFailure::InvalidSettings);
            }
        }
        // Register only accounts the caller is actually enabling. This retains
        // manual opt-outs and never restarts a running helper.
        for id in &next.enabled_ids {
            self.register_running_account(id)?;
        }
        let mut host = self.host.lock().map_err(|_| ProxyFailure::Unavailable)?;
        if self.command_generation.load(Ordering::Acquire) != generation {
            return Err(ProxyFailure::Stopping);
        }
        // Validate and persist while the admission mutex is held. A failed save
        // never publishes a half-applied rule or a synthetic success state.
        let next = host.normalize_preferences(next)?;
        persist_preferences(&self.preferences_path, &next)?;
        host.update_preferences(next.clone())?;
        if let Ok(mut status) = self.status.lock() {
            status.accounts.retain(|id, state| {
                !(next.enabled_ids.contains(id) && state.state == "registration_failed")
            });
        }
        Ok(next)
    }
    pub fn set_plus_five_hour_used_limit(
        &self,
        limit: f64,
    ) -> Result<ProxyPreferences, ProxyFailure> {
        let mut host = self.host.lock().map_err(|_| ProxyFailure::Unavailable)?;
        let next = host.plus_policy(limit)?;
        persist_preferences(&self.preferences_path, &next)?;
        host.update_preferences(next.clone())?;
        Ok(next)
    }
    pub fn set_shared_quota_used_limit(
        &self,
        limit: f64,
    ) -> Result<ProxyPreferences, ProxyFailure> {
        let mut host = self.host.lock().map_err(|_| ProxyFailure::Unavailable)?;
        let next = host.shared_quota_policy(limit)?;
        persist_preferences(&self.preferences_path, &next)?;
        host.update_preferences(next.clone())?;
        Ok(next)
    }
    /// Presentation-only snapshot. Unlike status(), this cannot reconcile or
    /// stop a helper; compact windows only observe the existing lifecycle owner.
    pub fn cached_status(&self) -> Result<ProxyStatus, ProxyFailure> {
        self.status
            .lock()
            .map(|value| value.clone())
            .map_err(|_| ProxyFailure::Unavailable)
    }
    pub fn status(&self) -> Result<ProxyStatus, ProxyFailure> {
        let mut inner = self.inner.lock().map_err(|_| ProxyFailure::Unavailable)?;
        let fatal = self
            .status
            .lock()
            .map_err(|_| ProxyFailure::Unavailable)?
            .issue
            .clone()
            .filter(|s| fatal_lease_error(s));
        if let (Some(code), Some(child)) = (fatal, inner.child.as_mut()) {
            self.host
                .lock()
                .map_err(|_| ProxyFailure::Unavailable)?
                .stopping();
            let confirmed = child.stop();
            let cleanup = self
                .host
                .lock()
                .map_err(|_| ProxyFailure::Unavailable)?
                .retire(confirmed);
            self.recoverable_exit.store(
                confirmed
                    && cleanup.is_ok()
                    && self.command_generation.load(Ordering::Acquire) & 1 == 1,
                Ordering::Release,
            );
            if confirmed {
                inner.child = None;
                inner.client_key = None;
                self.event_generation.fetch_add(1, Ordering::AcqRel);
            }
            let mut state = self.status.lock().map_err(|_| ProxyFailure::Unavailable)?;
            state.phase = ProxyPhase::Failed;
            state.port = None;
            state.issue = Some(cleanup.err().map(|e| e.code().to_owned()).unwrap_or(code));
        }
        if let Some(child) = &mut inner.child {
            if child
                .child
                .try_wait()
                .map_err(|_| ProxyFailure::Unavailable)?
                .is_some()
            {
                #[cfg(test)]
                eprintln!(
                    "proxy_startup_fixture child_exit={:?}",
                    child
                        .child
                        .try_wait()
                        .ok()
                        .flatten()
                        .and_then(|exit| exit.code())
                );
                self.host
                    .lock()
                    .map_err(|_| ProxyFailure::Unavailable)?
                    .stopping();
                let confirmed = child.stop();
                let cleanup = self
                    .host
                    .lock()
                    .map_err(|_| ProxyFailure::Unavailable)?
                    .retire(confirmed);
                let stopped = self.command_generation.load(Ordering::Acquire) & 1 == 0;
                self.recoverable_exit
                    .store(confirmed && cleanup.is_ok() && !stopped, Ordering::Release);
                if confirmed {
                    inner.child = None;
                    inner.client_key = None;
                    self.event_generation.fetch_add(1, Ordering::AcqRel);
                }
                let mut status = self.status.lock().map_err(|_| ProxyFailure::Unavailable)?;
                status.phase = if confirmed && stopped && cleanup.is_ok() {
                    ProxyPhase::Stopped
                } else {
                    ProxyPhase::Failed
                };
                status.port = None;
                status.issue = match cleanup {
                    _ if !confirmed => Some(ProxyFailure::CleanupUnconfirmed.code().into()),
                    Err(e) => Some(e.code().into()),
                    Ok(()) if !stopped => Some(ProxyFailure::Unavailable.code().into()),
                    _ => None,
                };
            }
        }
        Ok(self
            .status
            .lock()
            .map_err(|_| ProxyFailure::Unavailable)?
            .clone())
    }
    pub fn start(&self) -> Result<ProxyStatus, ProxyFailure> {
        let _lifecycle = self
            .lifecycle
            .lock()
            .map_err(|_| ProxyFailure::Unavailable)?;
        if matches!(
            self.status()?.phase,
            ProxyPhase::Running | ProxyPhase::Starting | ProxyPhase::Stopping
        ) {
            return Err(ProxyFailure::AccountBusy);
        }
        let generation = self.next_command(true);
        self.start_generation_locked(generation, None)
    }
    fn start_generation(
        &self,
        generation: usize,
        cancel: Option<&AtomicBool>,
    ) -> Result<ProxyStatus, ProxyFailure> {
        let _lifecycle = self
            .lifecycle
            .lock()
            .map_err(|_| ProxyFailure::Unavailable)?;
        self.start_generation_locked(generation, cancel)
    }
    fn start_generation_locked(
        &self,
        generation: usize,
        cancel: Option<&AtomicBool>,
    ) -> Result<ProxyStatus, ProxyFailure> {
        let _ = self.status()?;
        let mut inner = self.inner.lock().map_err(|_| ProxyFailure::Unavailable)?;
        if inner.child.is_some() {
            return Err(ProxyFailure::AccountBusy);
        }
        if self.command_generation.load(Ordering::Acquire) != generation
            || generation & 1 == 0
            || cancel.is_some_and(|c| c.load(Ordering::Acquire))
        {
            return Err(ProxyFailure::Stopping);
        }
        self.recoverable_exit.store(false, Ordering::Release);
        if !self.helper_path.is_file()
            || std::fs::symlink_metadata(&self.helper_path)
                .map_err(|_| ProxyFailure::HelperUnavailable)?
                .file_type()
                .is_symlink()
        {
            return Err(ProxyFailure::HelperUnavailable);
        }
        let mut host = self.host.lock().map_err(|_| ProxyFailure::Unavailable)?;
        let prefs = host.preferences();
        if !prefs.is_enabled || (cancel.is_some() && !prefs.automatic_recovery_enabled) {
            return Err(ProxyFailure::InvalidSettings);
        }
        let client_key = match prefs.client_key_mode {
            ClientKeyMode::PerRun => random_key()?,
            ClientKeyMode::Persistent => match self.secrets.load_client_key()? {
                Some(key) if valid_key(&key) => key,
                Some(_) => return Err(ProxyFailure::Identity),
                None => {
                    let key = random_key()?;
                    self.secrets.save_client_key(&key)?;
                    key
                }
            },
        };
        let mihomo_secret = if prefs.egress.enabled {
            self.secrets.load_mihomo_secret()?.unwrap_or_default()
        } else {
            String::new()
        };
        if mihomo_secret.len() > 4096 || mihomo_secret.contains(['\r', '\n', '\0']) {
            return Err(ProxyFailure::Identity);
        }
        let run_id = random_run_id()?;
        let control_key = random_key()?;
        let accounts = host.begin(run_id.clone(), control_key.clone())?;
        #[cfg(windows)]
        let owner_receipts = self.owner_receipts()?;
        #[cfg(windows)]
        if let Err(e) = super::recovery::prepare_helper(&owner_receipts, &run_id) {
            let _ = host.retire(true);
            return Err(e);
        }
        if self.command_generation.load(Ordering::Acquire) != generation
            || cancel.is_some_and(|c| c.load(Ordering::Acquire))
        {
            let _ = host.retire(true);
            return Err(ProxyFailure::Stopping);
        }
        let listener = match TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)) {
            Ok(v) => v,
            Err(_) => {
                let _ = host.retire(true);
                return Err(ProxyFailure::StartupFailed);
            }
        };
        let address = match listener.local_addr() {
            Ok(a) => a,
            Err(_) => {
                let _ = host.retire(true);
                return Err(ProxyFailure::StartupFailed);
            }
        };
        if listener.set_nonblocking(true).is_err() {
            let _ = host.retire(true);
            return Err(ProxyFailure::StartupFailed);
        }
        let startup = serde_json::json!({"schemaVersion":1,"runID":run_id,"controlSocket":format!("tcp:{address}"),"controlKey":control_key,"clientKey":client_key,
            "port":prefs.listen_port,"stateDirectory":self.state_directory,"networkProxy":prefs.network_proxy,"desktopFallback":prefs.desktop_fallback,
            "accounts":accounts.iter().map(|(id,_)| serde_json::json!({"id":id})).collect::<Vec<_>>(),"models":self.models,
            "accountIdentityHashes":accounts.into_iter().collect::<BTreeMap<_,_>>(),"egress":{"enabled":prefs.egress.enabled,"mihomoAPI":prefs.egress.mihomo_api,"mihomoSecret":mihomo_secret,"group":prefs.egress.group,"whitelist":prefs.egress.whitelist}});
        // std::io::pipe uses synchronous CreatePipe handles on Windows.
        // ChildStdin from Stdio::piped() instead uses an overlapped handle,
        // which cannot safely use our synchronous nonblocking frame writer.
        let (input, mut stdin) = match std::io::pipe() {
            Ok(pipe) => pipe,
            Err(_) => {
                let _ = host.retire(true);
                return Err(ProxyFailure::StartupFailed);
            }
        };
        let mut command = Command::new(&self.helper_path);
        command
            .stdin(Stdio::from(input))
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        // The helper receives no credential/key through argv or proxy env.
        command
            .env_remove("AIGOODBRO_PROXY_CONNECTION_FILE")
            .env_remove("AIGOODBRO_PROXY_KEY");
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x0800_0000);
        }
        if self.command_generation.load(Ordering::Acquire) != generation
            || cancel.is_some_and(|c| c.load(Ordering::Acquire))
        {
            let _ = host.retire(true);
            return Err(ProxyFailure::Stopping);
        }
        #[cfg(windows)]
        if let Err(e) = super::recovery::launching(&owner_receipts, "helper", &run_id) {
            let _ = host.retire(true);
            return Err(e);
        }
        let mut child = match command.spawn() {
            Ok(c) => c,
            Err(_) => {
                let _ = host.retire(true);
                return Err(ProxyFailure::HelperUnavailable);
            }
        };
        // Command retains its configured Stdio after spawn. Close the extra
        // parent reader so a dead helper cannot keep our pipe falsely alive.
        drop(command);
        #[cfg(windows)]
        let job = match WindowsJob::assign(&child, &run_id, &owner_receipts) {
            Ok(j) => j,
            Err(e) => {
                let confirmed = terminate_spawned(&mut child, None);
                let _ = host.retire(confirmed);
                return Err(e);
            }
        };
        let startup_result = serde_json::to_vec(&startup)
            .map_err(|_| ProxyFailure::StartupFailed)
            .and_then(|mut bytes| {
                bytes.push(b'\n');
                write_startup(
                    &mut stdin,
                    &bytes,
                    &self.command_generation,
                    generation,
                    cancel,
                    Instant::now() + Duration::from_secs(10),
                )
            });
        if let Err(error) = startup_result {
            drop(stdin);
            let confirmed = terminate_spawned(
                &mut child,
                #[cfg(windows)]
                Some(&job),
            );
            let _ = host.retire(confirmed);
            return Err(error);
        }
        let stdout = match child.stdout.take() {
            Some(v) => v,
            None => {
                let confirmed = terminate_spawned(
                    &mut child,
                    #[cfg(windows)]
                    Some(&job),
                );
                let _ = host.retire(confirmed);
                return Err(ProxyFailure::StartupFailed);
            }
        };
        *self.status.lock().map_err(|_| ProxyFailure::Unavailable)? = ProxyStatus {
            phase: ProxyPhase::Starting,
            ..ProxyStatus::default()
        };
        let control_stop = Arc::new(AtomicBool::new(false));
        let control_thread =
            match control_listener(listener, self.host.clone(), control_stop.clone()) {
                Ok(t) => Some(t),
                Err(e) => {
                    drop(stdin);
                    let confirmed = terminate_spawned(
                        &mut child,
                        #[cfg(windows)]
                        Some(&job),
                    );
                    let _ = host.retire(confirmed);
                    return Err(e);
                }
            };
        let status = self.status.clone();
        let event_host = self.host.clone();
        let registration = self.registration.clone();
        let generations = self.event_generation.clone();
        let event_generation = generations.fetch_add(1, Ordering::AcqRel) + 1;
        if thread::Builder::new()
            .name("agb-proxy-events".into())
            .spawn(move || {
                let mut reader = BufReader::new(stdout);
                loop {
                    let line = match bounded_line(&mut reader, 64 << 10) {
                        Ok(Some(v)) => v,
                        _ => break,
                    };
                    if let Ok(event) = serde_json::from_slice::<ProxyEvent>(&line) {
                        #[cfg(test)]
                        if event.event == "error" {
                            eprintln!(
                                "proxy_startup_fixture helper_error={}",
                                event
                                    .error_code
                                    .as_deref()
                                    .filter(|code| safe_error(code))
                                    .unwrap_or("unclassified")
                            );
                        }
                        if event.event == "account_registered" {
                            if generations.load(Ordering::Acquire) == event_generation {
                                registration::accept_event(&registration, &event);
                            }
                            continue;
                        }
                        if event.error_code.as_deref().is_some_and(fatal_lease_error) {
                            if let Ok(mut host) = event_host.lock() {
                                if generations.load(Ordering::Acquire) == event_generation {
                                    host.stopping();
                                }
                            }
                        }
                        if let Ok(mut state) = status.lock() {
                            if generations.load(Ordering::Acquire) == event_generation {
                                apply_event(&mut state, event);
                            }
                        }
                    }
                }
            })
            .is_err()
        {
            drop(stdin);
            let confirmed = terminate_spawned(
                &mut child,
                #[cfg(windows)]
                Some(&job),
            );
            control_stop.store(true, Ordering::Release);
            if let Some(t) = control_thread {
                let _ = t.join();
            }
            let _ = host.retire(confirmed);
            return Err(ProxyFailure::Unavailable);
        }
        inner.child = Some(OwnedHelper {
            child,
            stdin: Some(stdin),
            control_stop,
            control_thread,
            command_generation: generation,
            #[cfg(windows)]
            _job: job,
        });
        inner.client_key = Some(client_key);
        drop(host);
        drop(inner);
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if self.command_generation.load(Ordering::Acquire) != generation
                || generation & 1 == 0
                || cancel.is_some_and(|c| c.load(Ordering::Acquire))
            {
                let _ = self.stop_generation(Some(generation));
                return Err(ProxyFailure::Stopping);
            }
            let status = self.status()?;
            if status.phase == ProxyPhase::Running {
                return Ok(status);
            }
            if status.phase == ProxyPhase::Failed || Instant::now() >= deadline {
                #[cfg(test)]
                eprintln!(
                    "proxy_startup_fixture ready_wait phase={:?} safe_issue={} deadline={}",
                    status.phase,
                    status
                        .issue
                        .as_deref()
                        .filter(|code| safe_error(code))
                        .unwrap_or("none_or_unclassified"),
                    Instant::now() >= deadline
                );
                let cleanup = self.stop_generation(Some(generation));
                let recoverable = cleanup.is_ok()
                    && self.command_generation.load(Ordering::Acquire) == generation
                    && generation & 1 == 1;
                self.recoverable_exit.store(recoverable, Ordering::Release);
                if recoverable {
                    if let Ok(mut state) = self.status.lock() {
                        state.phase = ProxyPhase::Failed;
                        state.issue = Some(ProxyFailure::StartupFailed.code().into());
                    }
                }
                return Err(ProxyFailure::StartupFailed);
            }
            thread::sleep(Duration::from_millis(10));
        }
    }
    pub fn stop(&self) -> Result<ProxyStatus, ProxyFailure> {
        // Invalidate pending recovery before waiting for any process/host lock.
        let generation = self.next_command(false);
        self.recoverable_exit.store(false, Ordering::Release);
        let _lifecycle = self
            .lifecycle
            .lock()
            .map_err(|_| ProxyFailure::Unavailable)?;
        self.stop_generation(Some(generation))
    }
    fn stop_generation(&self, expected: Option<usize>) -> Result<ProxyStatus, ProxyFailure> {
        let mut inner = self.inner.lock().map_err(|_| ProxyFailure::Unavailable)?;
        if expected.is_some_and(|g| {
            inner
                .child
                .as_ref()
                .is_some_and(|c| c.command_generation > g)
        }) {
            return Ok(self
                .status
                .lock()
                .map_err(|_| ProxyFailure::Unavailable)?
                .clone());
        }
        self.host
            .lock()
            .map_err(|_| ProxyFailure::Unavailable)?
            .stopping();
        self.status
            .lock()
            .map_err(|_| ProxyFailure::Unavailable)?
            .phase = ProxyPhase::Stopping;
        let confirmed = if let Some(child) = &mut inner.child {
            child.stop()
        } else {
            true
        };
        let cleanup = self
            .host
            .lock()
            .map_err(|_| ProxyFailure::Unavailable)?
            .retire(confirmed);
        if confirmed {
            inner.child = None;
            inner.client_key = None;
            self.event_generation.fetch_add(1, Ordering::AcqRel);
        }
        let mut status = self.status.lock().map_err(|_| ProxyFailure::Unavailable)?;
        status.port = None;
        status.phase = if confirmed && cleanup.is_ok() {
            ProxyPhase::Stopped
        } else {
            ProxyPhase::Failed
        };
        status.issue = cleanup.err().map(|e| e.code().into());
        if !confirmed {
            status.issue = Some(ProxyFailure::CleanupUnconfirmed.code().into());
        }
        if status.phase == ProxyPhase::Failed {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
        Ok(status.clone())
    }
    pub fn connection(&self) -> Result<ProxyConnection, ProxyFailure> {
        let status = self.status()?;
        if status.phase != ProxyPhase::Running {
            return Err(ProxyFailure::Unavailable);
        }
        let inner = self.inner.lock().map_err(|_| ProxyFailure::Unavailable)?;
        Ok(ProxyConnection {
            endpoint: format!(
                "http://127.0.0.1:{}/v1",
                status.port.ok_or(ProxyFailure::Unavailable)?
            ),
            client_key: inner.client_key.clone().ok_or(ProxyFailure::Unavailable)?,
        })
    }
    /// Confirmed user force quit may kill only this service's held child handle.
    /// It does not retire unknown reservations or report cleanup success.
    pub fn force_stop_owned(&self) -> Result<(), ProxyFailure> {
        let generation = self.next_command(false);
        self.recoverable_exit.store(false, Ordering::Release);
        let mut inner = self
            .inner
            .try_lock()
            .map_err(|_| ProxyFailure::ControlBusy)?;
        if let Some(child) = inner.child.as_mut() {
            if child.command_generation > generation {
                return Ok(());
            }
            child.stdin.take();
            child.control_stop.store(true, Ordering::Release);
            #[cfg(windows)]
            child._job.terminate()?;
            if child.child.kill().is_err() && child.child.try_wait().ok().flatten().is_none() {
                return Err(ProxyFailure::CleanupUnconfirmed);
            }
        }
        if let Ok(mut host) = self.host.try_lock() {
            host.stopping();
        }
        if let Ok(mut state) = self.status.try_lock() {
            state.phase = ProxyPhase::Stopping;
            state.issue = Some(ProxyFailure::CleanupUnconfirmed.code().into());
        }
        Ok(())
    }
    #[cfg(test)]
    pub(super) fn terminate_owned_fixture_child(&self) {
        let mut inner = self.inner.lock().unwrap();
        inner.child.as_mut().unwrap().child.kill().unwrap();
    }
    #[cfg(test)]
    pub(super) fn owned_fixture_pid(&self) -> Option<u32> {
        self.inner
            .lock()
            .unwrap()
            .child
            .as_ref()
            .map(|c| c.child.id())
    }
    #[cfg(test)]
    pub(super) fn fixture_user_stopped(&self) -> bool {
        self.command_generation.load(Ordering::Acquire) & 1 == 0
    }
    #[cfg(test)]
    pub(super) fn inject_fixture_lease_failure(&self) {
        self.host.lock().unwrap().stopping();
        self.status.lock().unwrap().issue = Some("lease_acquire_unknown".into());
    }
    /// Safe helper commands only; no arbitrary process input or target URL.
    pub fn network_command(&self, command: &str, request_id: &str) -> Result<(), ProxyFailure> {
        if !matches!(command, "self_check" | "probe")
            || (command == "self_check" && !super::host::valid_request_id(request_id))
        {
            return Err(ProxyFailure::InvalidSettings);
        }
        let mut inner = self.inner.lock().map_err(|_| ProxyFailure::Unavailable)?;
        let child = inner.child.as_mut().ok_or(ProxyFailure::Unavailable)?;
        let mut frame =
            serde_json::to_vec(&serde_json::json!({"command":command,"requestID":request_id}))
                .map_err(|_| ProxyFailure::Unavailable)?;
        frame.push(b'\n');
        self.send_owned_command(child, &frame)
            .map_err(|_| ProxyFailure::Unavailable)
    }
    fn send_owned_command(
        &self,
        child: &mut OwnedHelper,
        frame: &[u8],
    ) -> Result<(), ProxyFailure> {
        let stdin = child.stdin.as_mut().ok_or(ProxyFailure::Unavailable)?;
        if let Err(error) = command_pipe::send(stdin, frame) {
            if error == command_pipe::FrameFailure::Poisoned {
                // Never append a later command to an incomplete frame. EOF
                // leaves the held process available to the normal stop owner.
                child.stdin.take();
                self.host
                    .lock()
                    .map_err(|_| ProxyFailure::Unavailable)?
                    .stopping();
            }
            return Err(ProxyFailure::RegistrationFailed);
        }
        Ok(())
    }
    /// Explicitly owned by the product lifecycle. A saved enabled preference
    /// does not autostart a proxy on launch; only a started run can recover.
    pub fn start_recovery_monitor(self: &Arc<Self>) -> Result<ProxyRecoveryMonitor, ProxyFailure> {
        self.start_recovery_monitor_with_listener(Arc::new(|_| {}))
    }
    /// One existing lifecycle worker publishes changes outside all service
    /// locks. Observers cannot create a second timer or helper owner.
    pub fn start_recovery_monitor_with_listener(
        self: &Arc<Self>,
        listener: Arc<dyn Fn(Option<ProxyStatus>) + Send + Sync>,
    ) -> Result<ProxyRecoveryMonitor, ProxyFailure> {
        if self
            .monitor_active
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(ProxyFailure::ControlBusy);
        }
        let weak = Arc::downgrade(self);
        let stop = Arc::new(AtomicBool::new(false));
        let worker_stop = stop.clone();
        let active = self.monitor_active.clone();
        let thread = match thread::Builder::new()
            .name("agb-proxy-lifecycle".into())
            .spawn(move || {
                let mut attempts = 0u32;
                let mut next = Instant::now();
                let mut generation = usize::MAX;
                let mut healthy_since = None;
                let mut delivered = None;
                while !worker_stop.load(Ordering::Acquire) {
                    let Some(service) = weak.upgrade() else {
                        break;
                    };
                    let current = service.command_generation.load(Ordering::Acquire);
                    if current != generation {
                        generation = current;
                        attempts = 0;
                        next = Instant::now();
                        healthy_since = None;
                    }
                    let status = service.status();
                    let current_status = status.as_ref().ok().cloned();
                    if delivered.as_ref() != Some(&current_status) {
                        delivered = Some(current_status.clone());
                        if !worker_stop.load(Ordering::Acquire) {
                            listener(current_status);
                        }
                    }
                    let prefs = service.preferences();
                    if matches!(
                        status,
                        Ok(ProxyStatus {
                            phase: ProxyPhase::Running,
                            ..
                        })
                    ) {
                        let since = healthy_since.get_or_insert_with(Instant::now);
                        if since.elapsed() >= Duration::from_secs(60) {
                            attempts = 0;
                        }
                    } else {
                        healthy_since = None;
                    }
                    let eligible = matches!(
                        (status, prefs),
                        (
                            Ok(ProxyStatus {
                                phase: ProxyPhase::Failed,
                                ..
                            }),
                            Ok(ProxyPreferences {
                                is_enabled: true,
                                automatic_recovery_enabled: true,
                                ..
                            })
                        )
                    ) && service.recoverable_exit.load(Ordering::Acquire)
                        && generation & 1 == 1;
                    if eligible && attempts < 3 && Instant::now() >= next {
                        attempts += 1;
                        let result = service.start_generation(generation, Some(&worker_stop));
                        next = Instant::now() + Duration::from_secs(1u64 << attempts);
                        if result.is_err() && attempts >= 3 {
                            service.recoverable_exit.store(false, Ordering::Release);
                        }
                    }
                    drop(service);
                    thread::sleep(Duration::from_millis(100));
                }
                active.store(false, Ordering::Release);
            }) {
            Ok(t) => t,
            Err(_) => {
                self.monitor_active.store(false, Ordering::Release);
                return Err(ProxyFailure::Unavailable);
            }
        };
        Ok(ProxyRecoveryMonitor {
            stop,
            thread: Some(thread),
        })
    }
    fn next_command(&self, start: bool) -> usize {
        // One atomic value binds both intent and epoch, so a late start cannot
        // overwrite a newer user-stop flag in a second independent atomic.
        let old = self
            .command_generation
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |v| {
                Some((v.wrapping_add(2) & !1) | usize::from(start))
            })
            .unwrap();
        (old.wrapping_add(2) & !1) | usize::from(start)
    }
}
pub struct ProxyRecoveryMonitor {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}
impl ProxyRecoveryMonitor {
    pub fn cancel(&self) {
        self.stop.store(true, Ordering::Release);
    }
    pub fn join(mut self) {
        self.cancel();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}
impl Drop for ProxyRecoveryMonitor {
    fn drop(&mut self) {
        self.cancel();
    }
}
impl Drop for LocalProxyService {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}
impl OwnedHelper {
    fn exited(&mut self) -> bool {
        if self.child.try_wait().ok().flatten().is_none() {
            return false;
        }
        #[cfg(windows)]
        if self._job.exited() != Ok(true) {
            return false;
        }
        true
    }
    fn close_control(&mut self) {
        self.control_stop.store(true, Ordering::Release);
        if let Some(t) = self.control_thread.take() {
            let _ = t.join();
        }
    }
    fn stop(&mut self) -> bool {
        // EOF is the shared helper's verified nonblocking shutdown protocol.
        self.stdin.take();
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if self.exited() {
                self.close_control();
                return true;
            }
            if Instant::now() >= deadline {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        let confirmed = terminate_spawned(
            &mut self.child,
            #[cfg(windows)]
            Some(&self._job),
        );
        if confirmed {
            self.close_control();
        }
        confirmed
    }
}
fn terminate_spawned(child: &mut Child, #[cfg(windows)] job: Option<&WindowsJob>) -> bool {
    child.stdin.take();
    #[cfg(windows)]
    if let Some(job) = job {
        let _ = job.terminate();
    }
    let _ = child.kill();
    let until = Instant::now() + Duration::from_secs(2);
    loop {
        let root_exited = child.try_wait().ok().flatten().is_some();
        #[cfg(windows)]
        let group_exited = job.is_none_or(|job| job.exited() == Ok(true));
        #[cfg(not(windows))]
        let group_exited = true;
        if root_exited && group_exited {
            return true;
        }
        if Instant::now() >= until {
            return false;
        }
        thread::sleep(Duration::from_millis(10));
    }
}
impl Drop for OwnedHelper {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

fn control_listener(
    listener: TcpListener,
    host: Arc<Mutex<ProxyHost>>,
    stop: Arc<AtomicBool>,
) -> Result<JoinHandle<()>, ProxyFailure> {
    thread::Builder::new()
        .name("agb-proxy-control".into())
        .spawn(move || {
            let pending = Arc::new(AtomicUsize::new(0));
            while !stop.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((stream, address)) => {
                        if !address.ip().is_loopback() {
                            continue;
                        }
                        if pending.fetch_add(1, Ordering::AcqRel) >= 16 {
                            pending.fetch_sub(1, Ordering::AcqRel);
                            continue;
                        }
                        let host = host.clone();
                        let worker_pending = pending.clone();
                        let stop = stop.clone();
                        if thread::Builder::new()
                            .name("agb-proxy-exchange".into())
                            .spawn(move || {
                                serve_control(stream, host, stop);
                                worker_pending.fetch_sub(1, Ordering::AcqRel);
                            })
                            .is_err()
                        {
                            pending.fetch_sub(1, Ordering::AcqRel);
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(10))
                    }
                    Err(_) => break,
                }
            }
        })
        .map_err(|_| ProxyFailure::Unavailable)
}
fn serve_control(mut stream: TcpStream, host: Arc<Mutex<ProxyHost>>, stop: Arc<AtomicBool>) {
    if stream.set_nonblocking(false).is_err() {
        return;
    }
    let _ = stream.set_read_timeout(Some(Duration::from_secs(25)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(25)));
    let request = {
        let mut reader = BufReader::new(&mut stream);
        bounded_line(&mut reader, 64 << 10)
            .ok()
            .flatten()
            .and_then(|line| serde_json::from_slice::<BridgeRequest>(&line).ok())
    };
    let Some(request) = request else {
        return;
    };
    let reply = if stop.load(Ordering::Acquire) {
        BridgeReply::failure(ProxyFailure::Stopping)
    } else {
        match host.lock() {
            Ok(mut host) => host.handle(request),
            Err(_) => BridgeReply::failure(ProxyFailure::Unavailable),
        }
    };
    let _ = serde_json::to_writer(&mut stream, &reply);
    let _ = stream.write_all(b"\n");
}
fn bounded_line(reader: &mut impl BufRead, limit: u64) -> std::io::Result<Option<Vec<u8>>> {
    let mut bytes = Vec::new();
    let n = reader.take(limit + 1).read_until(b'\n', &mut bytes)?;
    if n == 0 {
        return Ok(None);
    }
    if bytes.len() as u64 > limit || !bytes.ends_with(b"\n") {
        return Err(std::io::ErrorKind::InvalidData.into());
    }
    Ok(Some(bytes))
}
fn write_startup(
    stdin: &mut PipeWriter,
    frame: &[u8],
    commands: &AtomicUsize,
    generation: usize,
    cancel: Option<&AtomicBool>,
    deadline: Instant,
) -> Result<(), ProxyFailure> {
    if frame.is_empty() || frame.len() > 1 << 20 {
        return Err(ProxyFailure::StartupFailed);
    }
    for (_chunk_index, chunk) in frame.chunks(512).enumerate() {
        loop {
            if commands.load(Ordering::Acquire) != generation
                || cancel.is_some_and(|c| c.load(Ordering::Acquire))
            {
                return Err(ProxyFailure::Stopping);
            }
            if Instant::now() >= deadline {
                #[cfg(test)]
                eprintln!(
                    "proxy_startup_fixture write_deadline total_bytes={} accepted_bytes={}",
                    frame.len(),
                    _chunk_index * 512
                );
                return Err(ProxyFailure::StartupFailed);
            }
            match command_pipe::send_chunk(stdin, chunk) {
                Ok(()) => break,
                Err(command_pipe::FrameFailure::Poisoned) => {
                    #[cfg(test)]
                    eprintln!(
                        "proxy_startup_fixture write_poisoned total_bytes={} accepted_bytes={}",
                        frame.len(),
                        _chunk_index * 512
                    );
                    return Err(ProxyFailure::StartupFailed);
                }
                Err(command_pipe::FrameFailure::Unchanged) => {
                    thread::sleep(Duration::from_millis(5))
                }
            }
        }
    }
    #[cfg(test)]
    eprintln!(
        "proxy_startup_fixture write_complete total_bytes={}",
        frame.len()
    );
    Ok(())
}
fn apply_event(status: &mut ProxyStatus, event: ProxyEvent) {
    status.last_event_at = Some(unix_now());
    match event.event.as_str() {
        "ready" if event.port.is_some_and(|p| p > 0) => {
            status.phase = ProxyPhase::Running;
            status.port = event.port;
            status.issue = None;
        }
        "stopped" => {
            status.phase = ProxyPhase::Stopped;
            status.port = None;
        }
        "error" => {
            if let Some(code) = event.error_code.filter(|s| safe_error(s)) {
                status.issue = Some(code);
            }
        }
        "account" => {
            if let (Some(id), Some(state)) = (
                event.profile_id.filter(|s| policy::valid_id(s)),
                event.state.filter(|s| safe_state(s)),
            ) {
                status.accounts.insert(
                    id,
                    ProxyAccountState {
                        state,
                        cooldown_until: event.cooldown_until,
                        cooldown_kind: event
                            .cooldown_kind
                            .filter(|s| matches!(s.as_str(), "account" | "egress")),
                        probe_state: event.probe_state.filter(|s| {
                            matches!(s.as_str(), "pending" | "reachable" | "forbidden" | "failed")
                        }),
                    },
                );
            }
        }
        "egress" => {
            if let Some(state) = event.state.filter(|s| {
                matches!(
                    s.as_str(),
                    "unavailable"
                        | "disabled"
                        | "unconfigured"
                        | "dead"
                        | "healthy"
                        | "changed"
                        | "switched"
                )
            }) {
                status.egress = Some(ProxyEgressState {
                    state,
                    request_id: event
                        .request_id
                        .filter(|s| super::host::valid_request_id(s)),
                    latency_ms: event.latency_ms,
                });
            }
        }
        _ => {}
    }
}
fn fatal_lease_error(s: &str) -> bool {
    matches!(
        s,
        "lease_acquire_unknown" | "lease_release_unknown" | "lease_heartbeat_failed"
    )
}
fn safe_state(s: &str) -> bool {
    matches!(
        s,
        "ready"
            | "active"
            | "busy"
            | "credentials_busy"
            | "quota"
            | "quota_unknown"
            | "usage_limit"
            | "subscription_pending"
            | "unauthorized"
            | "login_expired"
            | "forbidden"
            | "temporary_error"
            | "cooldown"
            | "unavailable"
            | "identity"
            | "not_participating"
    )
}
fn safe_error(s: &str) -> bool {
    matches!(
        s,
        "invalid_startup"
            | "startup_failed"
            | "listen_failed"
            | "listen_port_occupied"
            | "lease_acquire_unknown"
            | "lease_acquire_reconciled"
            | "lease_release_unknown"
            | "lease_heartbeat_failed"
            | "network_unavailable"
            | "egress_unavailable"
    )
}
fn persist_preferences(path: &Path, value: &ProxyPreferences) -> Result<(), ProxyFailure> {
    let parent = path.parent().ok_or(ProxyFailure::SaveFailed)?;
    std::fs::create_dir_all(parent).map_err(|_| ProxyFailure::SaveFailed)?;
    if std::fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_symlink()) {
        return Err(ProxyFailure::SaveFailed);
    }
    let mut temporary =
        tempfile::NamedTempFile::new_in(parent).map_err(|_| ProxyFailure::SaveFailed)?;
    serde_json::to_writer_pretty(&mut temporary, value).map_err(|_| ProxyFailure::SaveFailed)?;
    temporary
        .write_all(b"\n")
        .and_then(|_| temporary.as_file().sync_all())
        .map_err(|_| ProxyFailure::SaveFailed)?;
    temporary
        .persist(path)
        .map_err(|_| ProxyFailure::SaveFailed)?;
    Ok(())
}
fn valid_key(key: &str) -> bool {
    key.len() == 64 && key.bytes().all(|b| b.is_ascii_hexdigit())
}
fn random_key() -> Result<String, ProxyFailure> {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).map_err(|_| ProxyFailure::Unavailable)?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}
fn random_run_id() -> Result<String, ProxyFailure> {
    // The persistent Desktop writer contract uses an opaque UUID-sized hex ID;
    // bearer/control secrets retain their independent 256-bit key contract.
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).map_err(|_| ProxyFailure::Unavailable)?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

#[cfg(windows)]
struct WindowsJob(isize);
#[cfg(windows)]
unsafe impl Send for WindowsJob {}
#[cfg(windows)]
impl WindowsJob {
    fn terminate(&self) -> Result<(), ProxyFailure> {
        #[link(name = "kernel32")]
        extern "system" {
            fn TerminateJobObject(job: isize, code: u32) -> i32;
        }
        if unsafe { TerminateJobObject(self.0, 1) } == 0 {
            Err(ProxyFailure::CleanupUnconfirmed)
        } else {
            Ok(())
        }
    }
    fn exited(&self) -> Result<bool, ProxyFailure> {
        #[repr(C)]
        #[derive(Default)]
        struct Accounting {
            user: i64,
            kernel: i64,
            period_user: i64,
            period_kernel: i64,
            page_faults: u32,
            total: u32,
            active: u32,
            terminated: u32,
        }
        const _: [(); 48] = [(); std::mem::size_of::<Accounting>()];
        const _: [(); 40] = [(); std::mem::offset_of!(Accounting, active)];
        #[link(name = "kernel32")]
        extern "system" {
            fn QueryInformationJobObject(
                job: isize,
                class: i32,
                info: *mut std::ffi::c_void,
                size: u32,
                returned: *mut u32,
            ) -> i32;
        }
        let mut info = Accounting::default();
        if unsafe {
            QueryInformationJobObject(
                self.0,
                1,
                &mut info as *mut _ as *mut _,
                std::mem::size_of::<Accounting>() as u32,
                std::ptr::null_mut(),
            )
        } == 0
        {
            Err(ProxyFailure::CleanupUnconfirmed)
        } else {
            Ok(info.active == 0)
        }
    }
    fn assign(child: &Child, run: &str, receipts: &Path) -> Result<Self, ProxyFailure> {
        use std::os::windows::io::AsRawHandle;
        #[repr(C)]
        #[derive(Default)]
        struct Basic {
            process_time: i64,
            job_time: i64,
            flags: u32,
            min_working: usize,
            max_working: usize,
            active: u32,
            affinity: usize,
            priority: u32,
            scheduling: u32,
        }
        #[repr(C)]
        #[derive(Default)]
        struct Io {
            a: u64,
            b: u64,
            c: u64,
            d: u64,
            e: u64,
            f: u64,
        }
        #[repr(C)]
        #[derive(Default)]
        struct Extended {
            basic: Basic,
            io: Io,
            process_memory: usize,
            job_memory: usize,
            peak_process: usize,
            peak_job: usize,
        }
        #[link(name = "kernel32")]
        extern "system" {
            fn SetInformationJobObject(
                job: isize,
                class: i32,
                info: *const std::ffi::c_void,
                size: u32,
            ) -> i32;
            fn AssignProcessToJobObject(job: isize, process: isize) -> i32;
        }
        unsafe {
            let nonce = super::recovery::nonce()?;
            let name = super::recovery::job_name("helper", run, &nonce);
            let handle = super::recovery::create_private_job(&name)?;
            let job = Self(handle);
            let mut info = Extended::default();
            info.basic.flags = 0x2000;
            if SetInformationJobObject(
                handle,
                9,
                &info as *const _ as *const _,
                std::mem::size_of::<Extended>() as u32,
            ) == 0
                || AssignProcessToJobObject(handle, child.as_raw_handle() as isize) == 0
            {
                return Err(ProxyFailure::Unavailable);
            }
            let created = super::recovery::process_created(child.as_raw_handle() as isize)?;
            super::recovery::arm(receipts, "helper", run, name, nonce, child.id(), created)?;
            Ok(job)
        }
    }
}
#[cfg(windows)]
impl Drop for WindowsJob {
    fn drop(&mut self) {
        #[link(name = "kernel32")]
        extern "system" {
            fn CloseHandle(handle: isize) -> i32;
        }
        unsafe {
            CloseHandle(self.0);
        }
    }
}

#[cfg(all(windows, test))]
pub(crate) fn recovery_test_helper_job(
    child: &Child,
    run: &str,
    receipts: &Path,
) -> Result<Box<dyn Send>, ProxyFailure> {
    Ok(Box::new(WindowsJob::assign(child, run, receipts)?))
}

#[cfg(all(windows, test))]
mod native_tests {
    use super::*;
    #[test]
    #[ignore = "Windows child-only fixture verifies the complete held helper Job"]
    fn actual_helper_windows_stop_waits_for_descendants_after_root_exit() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path();
        let receipts = root.join("receipts");
        let run = "7".repeat(32);
        crate::proxy::recovery::prepare_helper(&receipts, &run).unwrap();
        crate::proxy::recovery::launching(&receipts, "helper", &run).unwrap();
        let (input, stdin) = std::io::pipe().unwrap();
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "proxy::recovery::tests::recovery_waiting_child",
                "--ignored",
                "--nocapture",
            ])
            .env("AIGOODBRO_RECOVERY_TEST_ROLE", "hold")
            .env("AIGOODBRO_RECOVERY_TEST_ROOT", root)
            .stdin(Stdio::from(input))
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let job = WindowsJob::assign(&child, &run, &receipts).unwrap();
        std::fs::write(root.join("child-continue"), b"owned").unwrap();
        let mut owned = OwnedHelper {
            stdin: Some(stdin),
            child,
            control_stop: Arc::new(AtomicBool::new(false)),
            control_thread: None,
            command_generation: 1,
            _job: job,
        };
        let until = Instant::now() + Duration::from_secs(8);
        while !root.join("grandchild-ready.json").exists() {
            assert!(Instant::now() < until);
            thread::sleep(Duration::from_millis(20));
        }
        assert!(owned.child.try_wait().unwrap().is_none());
        assert_eq!(
            owned._job.exited(),
            Ok(false),
            "a running Job must not be empty"
        );
        owned.child.kill().unwrap();
        let until = Instant::now() + Duration::from_secs(3);
        while owned.child.try_wait().unwrap().is_none() {
            assert!(Instant::now() < until);
            thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(owned._job.exited(), Ok(false));
        assert!(
            !owned.exited(),
            "root exit must not retire a live descendant"
        );
        let start = Instant::now();
        assert!(owned.stop());
        assert!(start.elapsed() < Duration::from_secs(8));
        assert_eq!(owned._job.exited(), Ok(true));
    }
}
