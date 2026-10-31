//! Composition for the existing explicit prepare/confirm installation flow.
//! No Web command, arbitrary path, Hub start, model runner or background monitor.
use super::*;
use codexu_core::companion_setup::{BundlePin, SetupStore, Snapshot, State};
#[cfg(windows)]
use codexu_core::{
    companion_bridge::{
        native_windows::{prepare_private_root, CurrentAppBinding, Receiver},
        Bridge,
    },
    companion_setup::{PlatformAdapter, RuntimeBinding},
    runtime_setup::python::{automatic_candidates, PythonSelection},
};

fn unavailable_snapshot(code: &'static str) -> Snapshot {
    Snapshot {
        state: State::Unavailable,
        issue_code: Some(code),
        files: vec![],
        plan_id: None,
        backup_available: false,
    }
}

fn runtime_fingerprint(
    bundle: &str,
    app_source: &str,
    python_sha256: &str,
    epoch: &str,
    selected_python: &Option<(PathBuf, String)>,
) -> String {
    // An automatic runtime and an explicit selection of the same image have
    // different validity contracts in AppBackend::check_runtime. Preserve that
    // distinction in both receiver reuse and the prepared installation binding.
    let selection = match selected_python {
        None => parts(&["automatic"]),
        Some((path, sha256)) => parts(&["selected", &path.to_string_lossy(), sha256]),
    };
    parts(&[
        "companion-runtime-v1",
        bundle,
        app_source,
        python_sha256,
        epoch,
        &selection,
    ])
}

trait ReceiverControl {
    fn stop(&mut self) -> Result<(), String>;
}
struct ReceiverSlot<R> {
    value: Option<R>,
    suspended: Option<R>,
    normal_exit_pending: bool,
    cleanup_unconfirmed: bool,
}
impl<R> Default for ReceiverSlot<R> {
    fn default() -> Self {
        Self {
            value: None,
            suspended: None,
            normal_exit_pending: false,
            cleanup_unconfirmed: false,
        }
    }
}
impl<R: ReceiverControl> ReceiverSlot<R> {
    fn stop(&mut self) -> Result<(), String> {
        for receiver in [&mut self.value, &mut self.suspended].into_iter().flatten() {
            self.cleanup_unconfirmed = true;
            receiver.stop()?;
        }
        self.value.take();
        self.suspended.take();
        self.normal_exit_pending = false;
        self.cleanup_unconfirmed = false;
        Ok(())
    }
    fn suspend(&mut self) -> Result<(), String> {
        self.normal_exit_pending = true;
        if let Some(receiver) = self.value.as_mut().or(self.suspended.as_mut()) {
            self.cleanup_unconfirmed = true;
            receiver.stop()?;
        }
        self.cleanup_unconfirmed = false;
        if self.value.is_some() {
            self.suspended = self.value.take();
        }
        Ok(())
    }
    fn resume(&mut self, restart: impl FnOnce(&mut R) -> Result<(), String>) -> Result<(), String> {
        if !self.normal_exit_pending {
            return Ok(());
        }
        // A stop that timed out must be confirmed before opening another pipe.
        if self.cleanup_unconfirmed {
            self.suspend()?;
        }
        if let Some(receiver) = &mut self.suspended {
            if let Err(error) = restart(receiver) {
                // restart retains any newly created owner before reporting a
                // readiness error. Confirm its cleanup or keep it suspended.
                self.cleanup_unconfirmed = true;
                receiver.stop()?;
                self.cleanup_unconfirmed = false;
                return Err(error);
            }
        }
        self.value = self.suspended.take();
        self.normal_exit_pending = false;
        Ok(())
    }
}

pub(crate) struct CompanionRuntime {
    application: Arc<AppState>,
    manager: Arc<AccountManager>,
    gate: Arc<ManagedProxyGate>,
    hub: HubState,
    state: Mutex<RuntimeState>,
}
#[derive(Default)]
struct RuntimeState {
    #[cfg(windows)]
    prepared: Option<Prepared>,
    #[cfg(windows)]
    receiver: ReceiverSlot<Running>,
}
#[cfg(windows)]
struct Candidate {
    backend: Arc<AppBackend>,
    app_source: CurrentAppBinding,
    root: PathBuf,
    epoch: String,
    bundle: String,
}
#[cfg(windows)]
impl Candidate {
    fn verify(&self) -> Result<(), String> {
        self.app_source.verify().map_err(|e| e.code.to_owned())?;
        self.backend
            .check_runtime()
            .map_err(|e| e.code.to_owned())?;
        let mut inner = self.backend.lock().map_err(|e| e.code.to_owned())?;
        let session = inner.session.as_mut().ok_or("companion_scope_required")?;
        ensure_live(session).map_err(|e| e.code.to_owned())?;
        if session.companion.epoch != self.epoch {
            return Err("companion_scope_changed".into());
        }
        Ok(())
    }
    fn fingerprint(&self) -> String {
        runtime_fingerprint(
            &self.bundle,
            self.app_source.fingerprint(),
            &self.backend.python_sha256,
            &self.epoch,
            &self.backend.selected_python,
        )
    }
    fn same(&self, other: &Self) -> bool {
        self.fingerprint() == other.fingerprint()
            && self.root == other.root
            && self.backend.python.path == other.backend.python.path
    }
}
#[cfg(windows)]
struct Prepared {
    id: String,
    store_id: Option<String>,
    candidate: Candidate,
}
#[cfg(windows)]
struct Running {
    candidate: Candidate,
    receiver: Receiver,
}
#[cfg(windows)]
impl ReceiverControl for Running {
    fn stop(&mut self) -> Result<(), String> {
        self.receiver.stop().map_err(|e| e.code.to_owned())
    }
}
#[cfg(windows)]
fn start_receiver(candidate: &Candidate) -> Result<(Receiver, Result<(), String>), String> {
    candidate.verify()?;
    candidate
        .app_source
        .verify_bound(&candidate.root)
        .map_err(|e| e.code.to_owned())?;
    let bridge = Arc::new(
        Bridge::new(candidate.root.clone(), candidate.backend.clone())
            .map_err(|e| e.code.to_owned())?,
    );
    let python = PinnedExecutable {
        path: candidate.backend.python.path.clone(),
        guard: candidate
            .backend
            .python
            .guard
            .try_clone()
            .map_err(|_| "companion_runtime_changed")?,
    };
    Receiver::start_owned(candidate.root.clone(), python, bridge)
        .map(|(receiver, ready)| (receiver, ready.map_err(|e| e.code.to_owned())))
        .map_err(|e| e.code.to_owned())
}
#[cfg(windows)]
struct Adapter<'a> {
    candidate: &'a Candidate,
    live: Option<&'a Receiver>,
}
#[cfg(windows)]
impl PlatformAdapter for Adapter<'_> {
    fn verify(
        &self,
        bundle: &str,
        abi: u32,
    ) -> codexu_core::companion_setup::Result<RuntimeBinding> {
        let error = || codexu_core::companion_setup::Error {
            code: "companion_platform_adapter_unavailable",
        };
        if bundle != self.candidate.bundle || abi != 1 {
            return Err(error());
        }
        self.candidate.verify().map_err(|_| error())?;
        if let Some(receiver) = self.live {
            if !receiver.active() {
                return Err(error());
            }
            self.candidate
                .app_source
                .verify_bound(&self.candidate.root)
                .map_err(|_| error())?;
        }
        RuntimeBinding::new(
            self.candidate.fingerprint(),
            &self.candidate.backend.python.path,
            &self.candidate.root,
            abi,
        )
    }
}

impl CompanionRuntime {
    pub(crate) fn new(
        application: Arc<AppState>,
        manager: Arc<AccountManager>,
        gate: Arc<ManagedProxyGate>,
        hub: &HubState,
    ) -> Self {
        Self {
            application,
            manager,
            gate,
            hub: HubState {
                inner: hub.inner.clone(),
                quitting: hub.quitting.clone(),
            },
            state: Mutex::new(RuntimeState::default()),
        }
    }
    fn lock(&self) -> Result<std::sync::MutexGuard<'_, RuntimeState>, String> {
        if self.hub.quitting.load(Ordering::Acquire) {
            return Err("companion_app_quitting".into());
        }
        self.state
            .try_lock()
            .map_err(|_| "companion_runtime_busy".into())
    }
    /// Never probes Python, binds App source, creates a directory or starts IPC.
    pub(crate) fn inspect(&self, setup: &SetupStore, pin: &BundlePin) -> Snapshot {
        #[cfg(not(windows))]
        {
            let _ = (setup, pin);
            unavailable_snapshot("platform_unsupported")
        }
        #[cfg(windows)]
        {
            let Ok(state) = self.lock() else {
                return unavailable_snapshot("companion_runtime_busy");
            };
            if state.receiver.cleanup_unconfirmed {
                return unavailable_snapshot("companion_cleanup_unconfirmed");
            }
            if state.receiver.normal_exit_pending {
                return unavailable_snapshot("companion_exit_in_progress");
            }
            let Some(live) = &state.receiver.value else {
                return unavailable_snapshot("companion_prepare_required");
            };
            setup.inspect(
                pin,
                &Adapter {
                    candidate: &live.candidate,
                    live: Some(&live.receiver),
                },
            )
        }
    }
    #[cfg(windows)]
    fn candidate(&self, pin: &BundlePin) -> Result<Candidate, String> {
        let python = PythonSelection::new(&self.application.app_data_dir)
            .and_then(|s| s.for_companion(&automatic_candidates()))
            .map_err(|e| e.code.to_owned())?;
        let app_source = CurrentAppBinding::inspect().map_err(|e| e.code.to_owned())?;
        let backend = Arc::new(AppBackend::new(
            self.application.clone(),
            self.manager.clone(),
            self.gate.clone(),
            &self.hub,
            python,
        )?);
        let epoch = {
            let mut inner = backend.lock().map_err(|e| e.code.to_owned())?;
            let session = inner.session.as_mut().ok_or("companion_scope_required")?;
            ensure_live(session).map_err(|e| e.code.to_owned())?;
            session.companion.epoch.clone()
        };
        // The only preparation write is under fixed, native App data. It is
        // not an App source binding and never writes the user's Skill target.
        let root = prepare_private_root(&self.application.app_data_dir.join("companion-bridge-v1"))
            .map_err(|e| e.code.to_owned())?;
        Ok(Candidate {
            backend,
            app_source,
            root,
            epoch,
            bundle: pin.sha256().into(),
        })
    }
    pub(crate) fn prepare(&self, setup: &SetupStore, pin: &BundlePin) -> Result<Snapshot, String> {
        #[cfg(not(windows))]
        {
            let _ = (setup, pin);
            Err("platform_unsupported".into())
        }
        #[cfg(windows)]
        {
            let mut state = self.lock()?;
            if state.receiver.cleanup_unconfirmed {
                return Err("companion_cleanup_unconfirmed".into());
            }
            // A fresh explicit prepare may replace a confirmed-stopped stale
            // candidate after a cancelled exit could not restore its binding.
            if state.receiver.normal_exit_pending {
                state.receiver.stop()?;
            }
            state.prepared = None;
            let candidate = self.candidate(pin)?;
            let mut snapshot = setup
                .prepare(
                    pin,
                    &Adapter {
                        candidate: &candidate,
                        live: None,
                    },
                )
                .map_err(|e| e.code.to_owned())?;
            let already_live = state.receiver.value.as_ref().is_some_and(|live| {
                live.candidate.same(&candidate)
                    && live.receiver.active()
                    && live
                        .candidate
                        .app_source
                        .verify_bound(&live.candidate.root)
                        .is_ok()
            });
            if snapshot.state == State::Ready && already_live {
                return Ok(snapshot);
            }
            // Even an unchanged existing layout needs the SAME explicit
            // confirmation before a new App source is bound/receiver starts.
            let store_id = snapshot.plan_id.clone();
            let id = match &store_id {
                Some(id) => id.clone(),
                None => digest(nonce()?.as_bytes()),
            };
            snapshot.plan_id = Some(id.clone());
            if snapshot.state == State::Ready {
                snapshot.state = State::Unavailable;
                snapshot.issue_code = Some("companion_confirmation_required");
            }
            state.prepared = Some(Prepared {
                id,
                store_id,
                candidate,
            });
            Ok(snapshot)
        }
    }
    pub(crate) fn confirm_install(
        &self,
        id: &str,
        setup: &SetupStore,
        pin: &BundlePin,
    ) -> Result<Snapshot, String> {
        #[cfg(not(windows))]
        {
            let _ = (id, setup, pin);
            Err("platform_unsupported".into())
        }
        #[cfg(windows)]
        {
            let mut state = self.lock()?;
            if state.receiver.cleanup_unconfirmed {
                return Err("companion_cleanup_unconfirmed".into());
            }
            let prepared = state
                .prepared
                .as_ref()
                .filter(|p| p.id == id && p.candidate.bundle == pin.sha256())
                .ok_or("companion_plan_stale")?;
            prepared.candidate.verify()?;
            let reuse = state.receiver.value.as_ref().is_some_and(|live| {
                live.candidate.same(&prepared.candidate)
                    && live.receiver.active()
                    && live
                        .candidate
                        .app_source
                        .verify_bound(&live.candidate.root)
                        .is_ok()
            });
            if !reuse {
                state.receiver.stop()?;
            }
            let prepared = state.prepared.take().unwrap();
            if !reuse {
                prepared
                    .candidate
                    .app_source
                    .bind_confirmed(&prepared.candidate.root)
                    .map_err(|e| e.code.to_owned())?;
                prepared.candidate.verify()?;
                let (receiver, ready) = start_receiver(&prepared.candidate)?;
                state.receiver.value = Some(Running {
                    candidate: prepared.candidate,
                    receiver,
                });
                if let Err(error) = ready {
                    state.receiver.stop()?;
                    return Err(error);
                }
            }
            let result = {
                let live = state.receiver.value.as_ref().unwrap();
                let adapter = Adapter {
                    candidate: &live.candidate,
                    live: Some(&live.receiver),
                };
                if let Some(store_id) = &prepared.store_id {
                    setup
                        .confirm_install(store_id, pin, &adapter)
                        .map_err(|e| e.code.to_owned())
                } else {
                    let snapshot = setup.inspect(pin, &adapter);
                    if snapshot.state == State::Ready {
                        Ok(snapshot)
                    } else {
                        Err("companion_plan_stale".into())
                    }
                }
            };
            if result.is_err() && !reuse {
                // A failed installer never releases guards adopted by the Hub.
                // This stops only our new receiver/unclaimed preparations.
                state.receiver.stop()?;
            }
            result
        }
    }
    /// Stop accepting IPC and wait for this receiver before normal exit. The
    /// caller must recheck Hub/task activity after this returns: an operation
    /// already accepted before the stop flag may have adopted a Session guard.
    /// This does not seal the Hub, so cancelling an exit leaves it usable.
    pub(crate) fn prepare_normal_exit(&self) -> Result<(), String> {
        let mut state = self
            .state
            .try_lock()
            .map_err(|_| "companion_runtime_busy")?;
        #[cfg(windows)]
        {
            state.receiver.suspend()
        }
        #[cfg(not(windows))]
        {
            let _ = &mut state;
            Ok(())
        }
    }
    /// Cancelled/late-busy normal exit restores only the prior confirmed App,
    /// Python and Hub binding. No source rebinding, task submission or approval.
    pub(crate) fn resume_normal_exit(&self) -> Result<(), String> {
        let mut state = self.lock()?;
        #[cfg(windows)]
        {
            state.receiver.resume(|running| {
                let (receiver, ready) = start_receiver(&running.candidate)?;
                running.receiver = receiver;
                ready
            })
        }
        #[cfg(not(windows))]
        {
            let _ = &mut state;
            Ok(())
        }
    }
    /// Only the confirmed, non-cancellable force-exit path seals Hub admission.
    pub(crate) fn stop_owned(&self) -> Result<(), String> {
        self.hub.begin_force_quit();
        let mut state = self
            .state
            .try_lock()
            .map_err(|_| "companion_runtime_busy")?;
        #[cfg(windows)]
        {
            state.prepared = None;
            state.receiver.stop()
        }
        #[cfg(not(windows))]
        {
            let _ = &mut state;
            Ok(())
        }
    }
    pub(crate) fn cleanup_unconfirmed(&self) -> bool {
        let Ok(state) = self.state.try_lock() else {
            return true;
        };
        #[cfg(windows)]
        {
            state.receiver.cleanup_unconfirmed
        }
        #[cfg(not(windows))]
        {
            drop(state);
            false
        }
    }
}

#[cfg(test)]
#[path = "companion_bridge_runtime_tests.rs"]
mod tests;
