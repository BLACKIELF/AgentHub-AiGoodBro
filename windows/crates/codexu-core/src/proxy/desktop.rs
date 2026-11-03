//! Explicit Windows Desktop launch through an isolated, verified managed home.
//! Preparing a file or spawning a GUI is never reported as verified inference.
use super::*;
use crate::accounts::{AccountManager, ProxyDesktopHome};
use serde::Serialize;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::{
    fs::File,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, Weak},
    time::{Duration, Instant},
};

pub(crate) struct DesktopProxyBinding {
    pub run_id: String,
    pub endpoint: String,
    pub client_key: String,
    pub helper: PathBuf,
    pub network_proxy: String,
    pub identity_hash: String,
    pub generation: String,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ProxyDesktopPhase {
    #[default]
    Stopped,
    Prepared,
    Launched,
    Stopping,
    Failed,
}
#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProxyDesktopStatus {
    pub phase: ProxyDesktopPhase,
    pub launch_id: Option<String>,
    pub account_id: Option<String>,
    pub issue: Option<String>,
    pub routing_verified: Option<bool>,
}
trait Home: Send {
    fn path(&self) -> &Path;
    fn profile(&self) -> &str;
    fn identity(&self) -> &str;
    fn generation(&self) -> &str;
    fn cleanup(&mut self) -> Result<(), ProxyFailure>;
    fn rebind_claim(&mut self, claim: &DesktopWriterClaim) -> Result<(), ProxyFailure>;
    fn mark_launched(&mut self) {}
}
struct ManagedHome {
    home: Option<ProxyDesktopHome>,
    manager: Arc<AccountManager>,
    gate: Arc<dyn ProxyAccountGate>,
    claim: DesktopWriterClaim,
    registry_released: bool,
    launched: bool,
    abandon_confirmed: bool,
}
impl Home for ManagedHome {
    fn mark_launched(&mut self) {
        self.launched = true;
    }
    fn rebind_claim(&mut self, claim: &DesktopWriterClaim) -> Result<(), ProxyFailure> {
        if claim.writer_id != self.claim.writer_id
            || claim.profile_id != self.claim.profile_id
            || claim.identity_hash != self.claim.identity_hash
        {
            return Err(ProxyFailure::Identity);
        }
        self.claim = claim.clone();
        Ok(())
    }
    fn path(&self) -> &Path {
        self.home.as_ref().unwrap().path()
    }
    fn profile(&self) -> &str {
        self.home.as_ref().unwrap().profile_id()
    }
    fn identity(&self) -> &str {
        self.home.as_ref().unwrap().identity_hash()
    }
    fn generation(&self) -> &str {
        self.home.as_ref().unwrap().token_generation()
    }
    fn cleanup(&mut self) -> Result<(), ProxyFailure> {
        if !self.launched {
            if !self.registry_released {
                self.gate.confirm_desktop_exit(&self.claim)?;
                if !self.abandon_confirmed {
                    self.manager
                        .abandon_unlaunched_desktop_prepare(&self.claim)
                        .map_err(|_| ProxyFailure::CleanupUnconfirmed)?;
                    self.abandon_confirmed = true;
                }
                self.gate.release_desktop_writer(&self.claim)?;
                self.registry_released = true;
            }
            return Ok(());
        }
        if !self.registry_released {
            self.gate.confirm_desktop_exit(&self.claim)?;
            self.manager
                .finalize_desktop_after_exit(self.home.as_mut().unwrap(), &self.claim)
                .map_err(|_| ProxyFailure::CleanupUnconfirmed)?;
            self.gate.release_desktop_writer(&self.claim)?;
            self.registry_released = true;
        }
        self.manager
            .complete_desktop_writer_release(self.home.as_mut().unwrap(), &self.claim)
            .map_err(|_| ProxyFailure::CleanupUnconfirmed)
    }
}
trait Accounts: Send + Sync {
    fn idle(&self) -> Result<(), ProxyFailure>;
    /// Reconcile an exact, finalized writer receipt before claiming a new
    /// writer. A plain marker or missing receipt never authorizes cleanup.
    fn complete_retired(&self, _profile: &str) -> Result<bool, ProxyFailure> {
        Ok(false)
    }
    fn home(
        &self,
        id: &str,
        claim: &DesktopWriterClaim,
        gate: Arc<dyn ProxyAccountGate>,
    ) -> Result<Box<dyn Home>, ProxyFailure>;
    fn cli(&self, home: &Path, app: &Path) -> Result<PinnedExecutable, ProxyFailure>;
    fn abandon(&self, claim: &DesktopWriterClaim) -> Result<(), ProxyFailure>;
    fn reconstruct(
        &self,
        claim: &DesktopWriterClaim,
        gate: Arc<dyn ProxyAccountGate>,
    ) -> Result<Box<dyn Home>, ProxyFailure>;
}
struct ManagedAccounts(Arc<AccountManager>);
impl Accounts for ManagedAccounts {
    fn complete_retired(&self, profile: &str) -> Result<bool, ProxyFailure> {
        self.0
            .complete_retired_desktop_writer(profile)
            .map_err(|_| ProxyFailure::CleanupUnconfirmed)
    }
    fn reconstruct(
        &self,
        claim: &DesktopWriterClaim,
        gate: Arc<dyn ProxyAccountGate>,
    ) -> Result<Box<dyn Home>, ProxyFailure> {
        let home = self
            .0
            .reconstruct_desktop_home_for_recovery(claim)
            .map_err(|_| ProxyFailure::CleanupUnconfirmed)?;
        Ok(Box::new(ManagedHome {
            home: Some(home),
            manager: self.0.clone(),
            gate,
            claim: claim.clone(),
            registry_released: false,
            launched: true,
            abandon_confirmed: false,
        }))
    }
    fn abandon(&self, claim: &DesktopWriterClaim) -> Result<(), ProxyFailure> {
        self.0
            .abandon_unlaunched_desktop_prepare(claim)
            .map_err(|_| ProxyFailure::CleanupUnconfirmed)
    }
    fn idle(&self) -> Result<(), ProxyFailure> {
        self.0.require_codex_system_idle().map_err(|e| {
            if e.code == "account_busy" {
                ProxyFailure::DesktopRunning
            } else {
                ProxyFailure::DesktopStateUnknown
            }
        })
    }
    fn home(
        &self,
        id: &str,
        claim: &DesktopWriterClaim,
        gate: Arc<dyn ProxyAccountGate>,
    ) -> Result<Box<dyn Home>, ProxyFailure> {
        self.0
            .prepare_proxy_desktop_home(id, claim)
            .map(|h| {
                Box::new(ManagedHome {
                    home: Some(h),
                    manager: self.0.clone(),
                    gate,
                    claim: claim.clone(),
                    registry_released: false,
                    launched: false,
                    abandon_confirmed: false,
                }) as Box<dyn Home>
            })
            .map_err(|_| ProxyFailure::Identity)
    }
    fn cli(&self, home: &Path, app: &Path) -> Result<PinnedExecutable, ProxyFailure> {
        #[cfg(windows)]
        if let Some(pinned) = native::bundled_cli(app)? {
            return Ok(pinned);
        }
        #[cfg(not(windows))]
        let _ = app;
        let (path, guard) = self
            .0
            .proxy_codex_executable(home)
            .map_err(|_| ProxyFailure::DesktopUnavailable)?;
        require_official_publisher(&path)?;
        Ok(PinnedExecutable {
            path,
            _guard: guard,
        })
    }
}
struct PinnedExecutable {
    path: PathBuf,
    _guard: File,
}
pub(super) trait DesktopProcess: Send {
    fn exited(&mut self) -> Result<bool, ProxyFailure>;
    fn terminate(&mut self) -> Result<(), ProxyFailure>;
}
trait Runtime: Send + Sync {
    fn prepare_owner_receipt(
        &self,
        root: &Path,
        claim: &DesktopWriterClaim,
    ) -> Result<(), ProxyFailure>;
    fn discover(&self, working: &Path) -> Result<PinnedExecutable, ProxyFailure>;
    fn launch(
        &self,
        app: &PinnedExecutable,
        environment: &[(String, String)],
        root: &Path,
        claim: &DesktopWriterClaim,
    ) -> Result<Box<dyn DesktopProcess>, ProxyFailure>;
}
struct NativeRuntime;
impl Runtime for NativeRuntime {
    fn prepare_owner_receipt(
        &self,
        root: &Path,
        claim: &DesktopWriterClaim,
    ) -> Result<(), ProxyFailure> {
        super::recovery::prepare_desktop(root, claim)
    }
    fn discover(&self, working: &Path) -> Result<PinnedExecutable, ProxyFailure> {
        native_discover(working)
    }
    fn launch(
        &self,
        app: &PinnedExecutable,
        environment: &[(String, String)],
        root: &Path,
        claim: &DesktopWriterClaim,
    ) -> Result<Box<dyn DesktopProcess>, ProxyFailure> {
        native_launch(&app.path, environment, root, claim)
    }
}
struct Prepared {
    id: String,
    binding: DesktopProxyBinding,
    home: Box<dyn Home>,
    app: PinnedExecutable,
    _cli: PinnedExecutable,
    prepared_at: Instant,
    intent: usize,
    claim: DesktopWriterClaim,
    gate: Arc<dyn ProxyAccountGate>,
    _evidence: evidence::EvidenceListener,
    connection_pending: bool,
}
struct Launched {
    prepared: Prepared,
    process: Box<dyn DesktopProcess>,
}
#[derive(Default)]
struct State {
    prepared: Option<Prepared>,
    launched: Option<Launched>,
    status: ProxyDesktopStatus,
    cleanup_pending: bool,
    cleanup_home: Option<Box<dyn Home>>,
    unlaunched: Option<UnlaunchedClaim>,
}
struct UnlaunchedClaim {
    claim: DesktopWriterClaim,
    gate: Arc<dyn ProxyAccountGate>,
    abandon_confirmed: bool,
}

pub struct ProxyDesktopConnector {
    proxy: Weak<LocalProxyService>,
    accounts: Arc<dyn Accounts>,
    runtime: Arc<dyn Runtime>,
    receipts: PathBuf,
    state: Mutex<State>,
    operation: Mutex<()>,
    intent: AtomicUsize,
}
impl ProxyDesktopConnector {
    pub fn native(
        proxy: &Arc<LocalProxyService>,
        accounts: Arc<AccountManager>,
        receipts: PathBuf,
    ) -> Result<Arc<Self>, ProxyFailure> {
        if !receipts.is_absolute() {
            return Err(ProxyFailure::InvalidSettings);
        }
        Ok(Arc::new(Self {
            proxy: Arc::downgrade(proxy),
            accounts: Arc::new(ManagedAccounts(accounts)),
            runtime: Arc::new(NativeRuntime),
            receipts,
            state: Mutex::new(State::default()),
            operation: Mutex::new(()),
            intent: AtomicUsize::new(0),
        }))
    }
    pub fn requires_exit_confirmation(&self) -> bool {
        self.state
            .try_lock()
            .map(|s| {
                s.launched.is_some()
                    || s.prepared.is_some()
                    || s.cleanup_pending
                    || s.cleanup_home.is_some()
                    || s.unlaunched.is_some()
            })
            .unwrap_or(true)
    }
    pub fn prepare(&self, profile: &str) -> Result<ProxyDesktopStatus, ProxyFailure> {
        let _operation = self
            .operation
            .try_lock()
            .map_err(|_| ProxyFailure::ControlBusy)?;
        self.prepare_locked(profile)
    }
    fn prepare_locked(&self, profile: &str) -> Result<ProxyDesktopStatus, ProxyFailure> {
        let intent = self.next_intent(true);
        if !super::policy::valid_id(profile) {
            return Err(ProxyFailure::Identity);
        }
        self.status()?;
        let mut state = self.state.lock().map_err(|_| ProxyFailure::Unavailable)?;
        if state.cleanup_pending || state.cleanup_home.is_some() {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
        self.cleanup_unlaunched(&mut state)?;
        if state.launched.is_some() {
            return Err(ProxyFailure::DesktopRunning);
        }
        if let Some(mut old) = state.prepared.take() {
            if let Err(e) = old.home.cleanup() {
                state.prepared = Some(old);
                state.status.phase = ProxyDesktopPhase::Failed;
                state.status.issue = Some(e.code().into());
                return Err(e);
            }
        }
        self.accounts.idle()?;
        let proxy = self.proxy.upgrade().ok_or(ProxyFailure::Unavailable)?;
        let binding = proxy.desktop_binding(profile)?;
        std::fs::create_dir_all(&self.receipts).map_err(|_| ProxyFailure::Unavailable)?;
        if !crate::updates::safe_download_directory(&self.receipts) {
            return Err(ProxyFailure::Identity);
        }
        let app = self.runtime.discover(&self.receipts)?;
        let gate = proxy.desktop_gate()?;
        // This lock/reconciliation must precede the new claim. It closes the
        // crash window after registry release but before marker completion;
        // only Accounts' exact finalized-writer proof may remove leftovers.
        self.accounts.complete_retired(profile)?;
        let claim = gate.claim_desktop_writer(
            profile,
            &binding.run_id,
            &binding.identity_hash,
            &binding.generation,
        )?;
        if let Err(e) = self.runtime.prepare_owner_receipt(&self.receipts, &claim) {
            state.unlaunched = Some(UnlaunchedClaim {
                claim,
                gate,
                abandon_confirmed: false,
            });
            let _ = self.cleanup_unlaunched(&mut state);
            return Err(e);
        }
        let home = match self.accounts.home(profile, &claim, gate.clone()) {
            Ok(h) => h,
            Err(e) => {
                state.unlaunched = Some(UnlaunchedClaim {
                    claim,
                    gate,
                    abandon_confirmed: false,
                });
                let _ = self.cleanup_unlaunched(&mut state);
                return Err(e);
            }
        };
        if home.profile() != profile
            || home.identity() != binding.identity_hash
            || home.generation() != binding.generation
        {
            return Err(discard_unlaunched(home, &mut state, ProxyFailure::Identity));
        }
        let cli = match self.accounts.cli(home.path(), &app.path) {
            Ok(c) => c,
            Err(e) => {
                return Err(discard_unlaunched(home, &mut state, e));
            }
        };
        let id = match opaque_nonce() {
            Ok(v) => v,
            Err(e) => return Err(discard_unlaunched(home, &mut state, e)),
        };
        let cli_path = match path_string(&cli.path) {
            Ok(v) => v,
            Err(e) => return Err(discard_unlaunched(home, &mut state, e)),
        };
        let evidence = match evidence::EvidenceListener::start(gate.clone(), claim.clone()) {
            Ok(s) => s,
            Err(e) => return Err(discard_unlaunched(home, &mut state, e)),
        };
        let connection = serde_json::json!({"schemaVersion":1,"runID":binding.run_id,"endpoint":binding.endpoint,"clientKey":binding.client_key,"codexExecutable":cli_path,"networkProxy":binding.network_proxy,"writerID":claim.writer_id,"evidenceEndpoint":evidence.endpoint,"evidenceKey":evidence.key});
        if let Err(e) = write_connection(home.path(), &connection) {
            return Err(discard_unlaunched(home, &mut state, e));
        }
        if self.intent.load(Ordering::Acquire) != intent {
            return Err(discard_unlaunched(home, &mut state, ProxyFailure::Stopping));
        }
        state.status = ProxyDesktopStatus {
            phase: ProxyDesktopPhase::Prepared,
            launch_id: Some(id.clone()),
            account_id: Some(profile.into()),
            issue: None,
            routing_verified: None,
        };
        state.prepared = Some(Prepared {
            id,
            binding,
            home,
            app,
            _cli: cli,
            prepared_at: Instant::now(),
            intent,
            claim,
            gate,
            _evidence: evidence,
            connection_pending: false,
        });
        Ok(state.status.clone())
    }
    pub fn launch(&self, ticket: &str) -> Result<ProxyDesktopStatus, ProxyFailure> {
        let _operation = self
            .operation
            .try_lock()
            .map_err(|_| ProxyFailure::ControlBusy)?;
        self.launch_locked(ticket)
    }
    fn launch_locked(&self, ticket: &str) -> Result<ProxyDesktopStatus, ProxyFailure> {
        let mut state = self.state.lock().map_err(|_| ProxyFailure::Unavailable)?;
        if state.launched.is_some() {
            return Err(ProxyFailure::DesktopRunning);
        }
        let mut prepared = state
            .prepared
            .take()
            .ok_or(ProxyFailure::DesktopPreparationExpired)?;
        if prepared.id != ticket {
            state.prepared = Some(prepared);
            return Err(ProxyFailure::Identity);
        }
        let preflight = (|| {
            if self.intent.load(Ordering::Acquire) != prepared.intent {
                return Err(ProxyFailure::Stopping);
            }
            if prepared.prepared_at.elapsed() > Duration::from_secs(30) {
                return Err(ProxyFailure::DesktopPreparationExpired);
            }
            self.accounts.idle()?;
            prepared.gate.recheck_desktop_writer(&prepared.claim)?;
            let proxy = self.proxy.upgrade().ok_or(ProxyFailure::Unavailable)?;
            if proxy.desktop_run_matches(&prepared.binding.run_id) != Some(true) {
                return Err(ProxyFailure::Identity);
            }
            let binding = &prepared.binding;
            let environment = vec![
                ("CODEX_HOME".into(), path_string(prepared.home.path())?),
                ("CODEX_CLI_PATH".into(), path_string(&binding.helper)?),
                (
                    "AIGOODBRO_PROXY_CONNECTION_FILE".into(),
                    path_string(&prepared.home.path().join("desktop-connection.json"))?,
                ),
                ("CODEX_APP_SERVER_FORCE_CLI".into(), "1".into()),
                ("CODEX_APP_SERVER_USE_LOCAL_DAEMON".into(), "0".into()),
                ("CODEX_APP_SERVER_WS_URL".into(), String::new()),
            ];
            if self.intent.load(Ordering::Acquire) != prepared.intent {
                return Err(ProxyFailure::Stopping);
            }
            self.runtime
                .launch(&prepared.app, &environment, &self.receipts, &prepared.claim)
        })();
        match preflight {
            Ok(mut process) => {
                // From this point the official process may have refreshed its
                // grant. Even a concurrent cancel must use confirmed-exit
                // finalize/import instead of the no-spawn abandon path.
                prepared.home.mark_launched();
                if self.intent.load(Ordering::Acquire) != prepared.intent {
                    let _ = process.terminate();
                    state.status.phase = ProxyDesktopPhase::Stopping;
                    state.status.issue = Some(ProxyFailure::Stopping.code().into());
                    state.launched = Some(Launched { prepared, process });
                    return Err(ProxyFailure::Stopping);
                }
                state.status.phase = ProxyDesktopPhase::Launched;
                state.status.issue = None;
                state.launched = Some(Launched { prepared, process });
                Ok(state.status.clone())
            }
            Err(e) => {
                if e != ProxyFailure::CleanupUnconfirmed {
                    if prepared.home.cleanup().is_err() {
                        state.prepared = Some(prepared);
                    }
                } else {
                    state.cleanup_pending = true;
                }
                state.status.phase = ProxyDesktopPhase::Failed;
                state.status.issue = Some(e.code().into());
                Err(e)
            }
        }
    }
    pub fn connect(&self, profile: &str) -> Result<ProxyDesktopStatus, ProxyFailure> {
        let _operation = self
            .operation
            .try_lock()
            .map_err(|_| ProxyFailure::ControlBusy)?;
        let prepared = self.prepare_locked(profile)?;
        self.launch_locked(
            prepared
                .launch_id
                .as_deref()
                .ok_or(ProxyFailure::Unavailable)?,
        )
    }
    pub fn status(&self) -> Result<ProxyDesktopStatus, ProxyFailure> {
        let mut state = self.state.lock().map_err(|_| ProxyFailure::Unavailable)?;
        if let Some(owned) = state.launched.as_mut() {
            if owned.process.exited()? {
                owned.prepared._evidence.stop();
                let cleanup = exit_receipt(&self.receipts, &owned.prepared.id)
                    .and_then(|_| owned.prepared.home.cleanup());
                if let Err(e) = cleanup {
                    state.status.phase = ProxyDesktopPhase::Stopping;
                    state.status.issue = Some(e.code().into());
                    return Err(e);
                }
                state.launched.take();
                state.status.phase = ProxyDesktopPhase::Stopped;
                state.status.issue = None;
            } else {
                let matches = self
                    .proxy
                    .upgrade()
                    .map(|p| p.desktop_run_matches(&owned.prepared.binding.run_id))
                    .unwrap_or(Some(false));
                let rebound = if matches == Some(false) || owned.prepared.connection_pending {
                    self.rebind_owned(owned)
                } else {
                    Ok(())
                };
                match matches {
                    Some(false) if rebound.is_ok() => state.status.issue = None,
                    Some(false) => state.status.issue = Some("desktop_connection_stale".into()),
                    None => state.status.issue = Some("desktop_connection_unverified".into()),
                    Some(true) if rebound.is_err() => {
                        state.status.issue = Some("desktop_connection_unverified".into())
                    }
                    Some(true) => {
                        if matches!(
                            state.status.issue.as_deref(),
                            Some("desktop_connection_stale" | "desktop_connection_unverified")
                        ) {
                            state.status.issue = None;
                        }
                    }
                }
            }
        }
        Ok(state.status.clone())
    }
    fn rebind_owned(&self, owned: &mut Launched) -> Result<(), ProxyFailure> {
        // Caller already positively observed this same held Job still active.
        let proxy = self.proxy.upgrade().ok_or(ProxyFailure::Unavailable)?;
        let mut binding = proxy.desktop_connection_binding(&owned.prepared.claim)?;
        if binding.run_id == owned.prepared.binding.run_id && !owned.prepared.connection_pending {
            return Ok(());
        }
        let claim = if binding.run_id == owned.prepared.binding.run_id {
            owned.prepared.claim.clone()
        } else {
            owned
                .prepared
                .gate
                .rebind_desktop_writer(&owned.prepared.claim, &binding.run_id)?
        };
        binding.identity_hash = claim.identity_hash.clone();
        binding.generation = claim.initial_generation.clone();
        owned.prepared._evidence.rebind(claim.clone())?;
        owned.prepared.home.rebind_claim(&claim)?;
        owned.prepared.claim = claim.clone();
        owned.prepared.binding = binding;
        owned.prepared.connection_pending = true;
        let binding = &owned.prepared.binding;
        let value = serde_json::json!({"schemaVersion":1,"runID":binding.run_id,"endpoint":binding.endpoint,"clientKey":binding.client_key,"codexExecutable":path_string(&owned.prepared._cli.path)?,"networkProxy":binding.network_proxy,"writerID":claim.writer_id,"evidenceEndpoint":owned.prepared._evidence.endpoint,"evidenceKey":owned.prepared._evidence.key});
        replace_connection(owned.prepared.home.path(), &value)?;
        owned.prepared.connection_pending = false;
        Ok(())
    }
    pub fn cancel(&self) -> Result<ProxyDesktopStatus, ProxyFailure> {
        self.next_intent(false);
        let _operation = self
            .operation
            .try_lock()
            .map_err(|_| ProxyFailure::ControlBusy)?;
        {
            let mut state = self.state.lock().map_err(|_| ProxyFailure::Unavailable)?;
            self.cleanup_unlaunched(&mut state)?;
            if let Some(mut home) = state.cleanup_home.take() {
                if let Err(e) = home.cleanup() {
                    state.cleanup_home = Some(home);
                    return Err(e);
                }
            }
            if let Some(mut prepared) = state.prepared.take() {
                if let Err(e) = prepared.home.cleanup() {
                    state.prepared = Some(prepared);
                    state.status.phase = ProxyDesktopPhase::Failed;
                    state.status.issue = Some(e.code().into());
                    return Err(e);
                }
                state.status.phase = ProxyDesktopPhase::Stopped;
            }
            if let Some(owned) = state.launched.as_mut() {
                owned.process.terminate()?;
                state.status.phase = ProxyDesktopPhase::Stopping;
            }
            if state.prepared.is_none() && state.launched.is_none() {
                if state.cleanup_pending {
                    return Err(ProxyFailure::CleanupUnconfirmed);
                }
                state.status = ProxyDesktopStatus::default();
            }
        }
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let status = self.status()?;
            if status.phase != ProxyDesktopPhase::Stopping {
                let mut state = self.state.lock().map_err(|_| ProxyFailure::Unavailable)?;
                if state.prepared.is_none() && state.launched.is_none() && !state.cleanup_pending {
                    state.status = ProxyDesktopStatus::default();
                }
                return Ok(state.status.clone());
            }
            if Instant::now() >= deadline {
                return Err(ProxyFailure::CleanupUnconfirmed);
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    fn cleanup_unlaunched(&self, state: &mut State) -> Result<(), ProxyFailure> {
        if let Some(pending) = state.unlaunched.as_mut() {
            if !pending.abandon_confirmed {
                pending.gate.confirm_desktop_exit(&pending.claim)?;
                self.accounts.abandon(&pending.claim)?;
                pending.abandon_confirmed = true;
            }
            pending.gate.release_desktop_writer(&pending.claim)?;
            state.unlaunched = None;
        }
        Ok(())
    }
    pub fn force_stop_owned(&self) -> Result<(), ProxyFailure> {
        self.next_intent(false);
        let mut state = self
            .state
            .try_lock()
            .map_err(|_| ProxyFailure::ControlBusy)?;
        if let Some(owned) = state.launched.as_mut() {
            owned.process.terminate()?;
            state.status.phase = ProxyDesktopPhase::Stopping;
        }
        Ok(())
    }
    fn next_intent(&self, start: bool) -> usize {
        let old = self
            .intent
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |v| {
                Some((v.wrapping_add(2) & !1) | usize::from(start))
            })
            .unwrap();
        (old.wrapping_add(2) & !1) | usize::from(start)
    }
    pub fn recover_stale_owned(&self) -> Result<(), ProxyFailure> {
        let _operation = self
            .operation
            .try_lock()
            .map_err(|_| ProxyFailure::ControlBusy)?;
        let proxy = self.proxy.upgrade().ok_or(ProxyFailure::Unavailable)?;
        let gate = proxy.desktop_gate()?;
        for candidate in gate.desktop_recovery_candidates()? {
            let proof = super::recovery::verify_desktop(&self.receipts, &candidate)?;
            let claim = gate.recover_desktop_writer(&proof)?;
            if proof.kind() == DesktopRecoveryKind::Prepared {
                let mut state = self.state.lock().map_err(|_| ProxyFailure::Unavailable)?;
                state.unlaunched = Some(UnlaunchedClaim {
                    claim,
                    gate: gate.clone(),
                    abandon_confirmed: false,
                });
                self.cleanup_unlaunched(&mut state)?;
            } else {
                let mut home = self.accounts.reconstruct(&claim, gate.clone())?;
                if let Err(e) = home.cleanup() {
                    self.state
                        .lock()
                        .map_err(|_| ProxyFailure::Unavailable)?
                        .cleanup_home = Some(home);
                    return Err(e);
                }
            }
        }
        Ok(())
    }
    pub fn start_lifecycle_monitor(self: &Arc<Self>) -> Result<ProxyDesktopMonitor, ProxyFailure> {
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let stopped = stop.clone();
        let weak = Arc::downgrade(self);
        let thread = std::thread::Builder::new()
            .name("agb-desktop-lifecycle".into())
            .spawn(move || {
                while !stopped.load(Ordering::Acquire) {
                    let Some(connector) = weak.upgrade() else {
                        break;
                    };
                    let _ = connector.status();
                    drop(connector);
                    std::thread::sleep(Duration::from_millis(250));
                }
            })
            .map_err(|_| ProxyFailure::Unavailable)?;
        Ok(ProxyDesktopMonitor {
            stop,
            _thread: Some(thread),
        })
    }
}
pub struct ProxyDesktopMonitor {
    stop: Arc<std::sync::atomic::AtomicBool>,
    _thread: Option<std::thread::JoinHandle<()>>,
}
impl ProxyDesktopMonitor {
    pub fn cancel(&self) {
        self.stop.store(true, Ordering::Release);
    }
}
impl Drop for ProxyDesktopMonitor {
    fn drop(&mut self) {
        self.cancel();
    }
}
impl Drop for ProxyDesktopConnector {
    fn drop(&mut self) {
        if let Ok(state) = self.state.get_mut() {
            if let Some(mut prepared) = state.prepared.take() {
                let _ = prepared.home.cleanup();
            }
            if let Some(mut owned) = state.launched.take() {
                let _ = owned.process.terminate();
                if owned.process.exited() == Ok(true) {
                    let _ = exit_receipt(&self.receipts, &owned.prepared.id);
                    let _ = owned.prepared.home.cleanup();
                }
            }
        }
    }
}
fn path_string(path: &Path) -> Result<String, ProxyFailure> {
    path.to_str()
        .map(str::to_owned)
        .ok_or(ProxyFailure::Identity)
}
fn discard_unlaunched(
    mut home: Box<dyn Home>,
    state: &mut State,
    reason: ProxyFailure,
) -> ProxyFailure {
    if home.cleanup().is_err() {
        state.cleanup_home = Some(home);
        state.status.phase = ProxyDesktopPhase::Failed;
        state.status.issue = Some(ProxyFailure::CleanupUnconfirmed.code().into());
        ProxyFailure::CleanupUnconfirmed
    } else {
        reason
    }
}
fn opaque_nonce() -> Result<String, ProxyFailure> {
    let mut b = [0u8; 24];
    getrandom::fill(&mut b).map_err(|_| ProxyFailure::Unavailable)?;
    Ok(b.iter().map(|b| format!("{b:02x}")).collect())
}
fn write_connection(home: &Path, value: &serde_json::Value) -> Result<(), ProxyFailure> {
    use std::io::Write;
    if !home.is_absolute() || !crate::updates::safe_download_directory(home) {
        return Err(ProxyFailure::Identity);
    }
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(home.join("desktop-connection.json"))
        .map_err(|_| ProxyFailure::Unavailable)?;
    serde_json::to_writer(&mut file, value).map_err(|_| ProxyFailure::Unavailable)?;
    file.write_all(b"\n")
        .and_then(|_| file.sync_all())
        .map_err(|_| ProxyFailure::Unavailable)
}
fn replace_connection(home: &Path, value: &serde_json::Value) -> Result<(), ProxyFailure> {
    use std::io::Write;
    let path = home.join("desktop-connection.json");
    if !crate::updates::safe_download_directory(home)
        || std::fs::symlink_metadata(&path).is_err()
        || std::fs::symlink_metadata(&path).is_ok_and(|m| m.file_type().is_symlink())
    {
        return Err(ProxyFailure::Identity);
    }
    let mut temp = tempfile::NamedTempFile::new_in(home).map_err(|_| ProxyFailure::Unavailable)?;
    serde_json::to_writer(&mut temp, value).map_err(|_| ProxyFailure::Unavailable)?;
    temp.write_all(b"\n")
        .and_then(|_| temp.as_file().sync_all())
        .map_err(|_| ProxyFailure::Unavailable)?;
    temp.persist(path).map_err(|_| ProxyFailure::Unavailable)?;
    Ok(())
}
fn exit_receipt(root: &Path, id: &str) -> Result<(), ProxyFailure> {
    use std::io::Write;
    let value = serde_json::json!({"schemaVersion":1,"launchID":id,"ownedJobExitConfirmed":true,"at":chrono::Utc::now().timestamp()});
    let path = root.join(format!("exit-{id}.json"));
    if path.exists() {
        let meta =
            std::fs::symlink_metadata(&path).map_err(|_| ProxyFailure::CleanupUnconfirmed)?;
        if !meta.is_file() || meta.file_type().is_symlink() || meta.len() > 1024 {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
        let existing: serde_json::Value = serde_json::from_slice(
            &std::fs::read(&path).map_err(|_| ProxyFailure::CleanupUnconfirmed)?,
        )
        .map_err(|_| ProxyFailure::CleanupUnconfirmed)?;
        if existing.get("schemaVersion") == Some(&serde_json::json!(1))
            && existing.get("launchID").and_then(|v| v.as_str()) == Some(id)
            && existing.get("ownedJobExitConfirmed") == Some(&serde_json::json!(true))
            && existing.get("at").and_then(|v| v.as_i64()).is_some()
        {
            return Ok(());
        }
        return Err(ProxyFailure::CleanupUnconfirmed);
    }
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|_| ProxyFailure::CleanupUnconfirmed)?;
    file.write_all(&serde_json::to_vec(&value).map_err(|_| ProxyFailure::Unavailable)?)
        .and_then(|_| file.sync_all())
        .map_err(|_| ProxyFailure::CleanupUnconfirmed)
}
fn require_official_publisher(path: &Path) -> Result<(), ProxyFailure> {
    let publisher = crate::readers::local_cli_quota::antigravity::publisher_of(path)
        .ok_or(ProxyFailure::DesktopUnavailable)?;
    let normalized: String = publisher
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect();
    if !matches!(normalized.as_str(), "openai" | "openaillc" | "openaiinc") {
        return Err(ProxyFailure::DesktopUnavailable);
    }
    Ok(())
}
#[cfg(not(windows))]
fn native_discover(_: &Path) -> Result<PinnedExecutable, ProxyFailure> {
    Err(ProxyFailure::DesktopUnavailable)
}
#[cfg(not(windows))]
fn native_launch(
    _: &Path,
    _: &[(String, String)],
    _: &Path,
    _: &DesktopWriterClaim,
) -> Result<Box<dyn DesktopProcess>, ProxyFailure> {
    Err(ProxyFailure::DesktopUnavailable)
}

#[cfg(windows)]
pub(super) mod native;
#[cfg(windows)]
use native::{native_discover, native_launch};
mod evidence;
#[cfg(test)]
mod tests;
