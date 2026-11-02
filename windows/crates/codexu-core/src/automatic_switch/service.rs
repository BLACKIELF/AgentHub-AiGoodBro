use super::*;
use std::{io::Read, time::Instant};

const COMMIT_IDLE: u64 = 0;
const COMMIT_ACTIVE: u64 = 1;
const COMMIT_CANCELLED: u64 = 2;
const COMMIT_CLAIMED: u64 = 3;
const COMMIT_DURABLE: u64 = 4;
const COMMIT_FINISHED: u64 = 5;

struct CommitPoint(AtomicU64);

impl Default for CommitPoint {
    fn default() -> Self {
        Self(AtomicU64::new(COMMIT_IDLE))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CancelTransition {
    Cancelled,
    AlreadyCancelled,
    TooLate,
    Inactive,
}

impl CommitPoint {
    fn begin(&self) {
        self.0.store(COMMIT_ACTIVE, Ordering::Release);
    }

    fn cancel(&self) -> CancelTransition {
        loop {
            match self.0.load(Ordering::Acquire) {
                COMMIT_ACTIVE => {
                    if self
                        .0
                        .compare_exchange(
                            COMMIT_ACTIVE,
                            COMMIT_CANCELLED,
                            Ordering::AcqRel,
                            Ordering::Acquire,
                        )
                        .is_ok()
                    {
                        return CancelTransition::Cancelled;
                    }
                }
                COMMIT_CANCELLED => return CancelTransition::AlreadyCancelled,
                COMMIT_CLAIMED | COMMIT_DURABLE => return CancelTransition::TooLate,
                _ => return CancelTransition::Inactive,
            }
        }
    }

    fn claim(&self) -> bool {
        self.0
            .compare_exchange(
                COMMIT_ACTIVE,
                COMMIT_CLAIMED,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_ok()
    }

    fn mark_durable(&self) {
        let _ = self.0.compare_exchange(
            COMMIT_CLAIMED,
            COMMIT_DURABLE,
            Ordering::AcqRel,
            Ordering::Acquire,
        );
    }

    fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Acquire) == COMMIT_CANCELLED
    }

    fn is_durable(&self) -> bool {
        self.0.load(Ordering::Acquire) == COMMIT_DURABLE
    }

    fn finish(&self) {
        if !self.is_durable() {
            self.0.store(COMMIT_FINISHED, Ordering::Release);
        }
    }
}

struct State {
    saved: Stored,
    phase: &'static str,
    issue: Option<Failure>,
    source: Option<String>,
    target: Option<String>,
    ticket: Option<String>,
    candidate_refresh_at: Option<u64>,
    inflight_epoch: Option<u64>,
    suspended: bool,
}
pub struct AutomaticSwitchService {
    path: PathBuf,
    manager: Arc<AccountManager>,
    safety: Arc<dyn AutomaticSwitchSafetySource>,
    observer: Option<Arc<dyn AutomaticSwitchObserver>>,
    state: Mutex<State>,
    operation: Mutex<()>,
    epoch: AtomicU64,
    commit_point: CommitPoint,
    exiting: AtomicBool,
    monitor_active: AtomicBool,
    native_controller: Option<NativeController>,
    pause_controller: Mutex<Option<Arc<dyn QuotaPauseController>>>,
}
struct NativeController {
    gate: Arc<crate::managed_proxy::ManagedProxyGate>,
    source: Arc<live::SystemDaemonSource>,
}
#[derive(Clone)]
struct Evidence {
    identity: String,
    generation: String,
    observed_at: u64,
    quota: Quota,
}
struct Account {
    id: String,
    group: String,
    workspace: String,
    identity: String,
    active: bool,
    eligible: bool,
    fresh: Option<Evidence>,
}
impl AutomaticSwitchService {
    pub fn new(
        path: PathBuf,
        manager: Arc<AccountManager>,
        safety: Arc<dyn AutomaticSwitchSafetySource>,
    ) -> Result<Arc<Self>> {
        Self::new_with_observer(path, manager, safety, None)
    }
    pub fn new_with_observer(
        path: PathBuf,
        manager: Arc<AccountManager>,
        safety: Arc<dyn AutomaticSwitchSafetySource>,
        observer: Option<Arc<dyn AutomaticSwitchObserver>>,
    ) -> Result<Arc<Self>> {
        Self::new_inner(path, manager, safety, observer, None)
    }
    /// Production Windows composition. The caller owns and retains the source
    /// monitor separately; this constructor never starts a business process.
    pub fn new_with_native_controller(
        path: PathBuf,
        manager: Arc<AccountManager>,
        gate: Arc<crate::managed_proxy::ManagedProxyGate>,
        source: Arc<live::SystemDaemonSource>,
        observer: Option<Arc<dyn AutomaticSwitchObserver>>,
    ) -> Result<Arc<Self>> {
        if !cfg!(windows) {
            return Err(Failure::Unavailable);
        }
        Self::new_inner(
            path,
            manager,
            source.clone(),
            observer,
            Some(NativeController { gate, source }),
        )
    }
    fn new_inner(
        path: PathBuf,
        manager: Arc<AccountManager>,
        safety: Arc<dyn AutomaticSwitchSafetySource>,
        observer: Option<Arc<dyn AutomaticSwitchObserver>>,
        native_controller: Option<NativeController>,
    ) -> Result<Arc<Self>> {
        check_path(&path)?;
        let saved = read_saved(&path)?;
        let phase = if saved.preferences.enabled {
            "idle"
        } else {
            "disabled"
        };
        Ok(Arc::new(Self {
            path,
            manager,
            safety,
            observer,
            state: Mutex::new(State {
                saved,
                phase,
                issue: None,
                source: None,
                target: None,
                ticket: None,
                candidate_refresh_at: None,
                inflight_epoch: None,
                suspended: false,
            }),
            operation: Mutex::new(()),
            epoch: AtomicU64::new(0),
            commit_point: CommitPoint::default(),
            exiting: AtomicBool::new(false),
            monitor_active: AtomicBool::new(false),
            native_controller,
            pause_controller: Mutex::new(None),
        }))
    }
    /// Inject the real original-owner adapter once, before the monitor starts.
    pub fn set_quota_pause_controller(
        &self,
        controller: Arc<dyn QuotaPauseController>,
    ) -> Result<()> {
        if !cfg!(windows) || self.monitor_active.load(Ordering::Acquire) {
            return Err(Failure::Unavailable);
        }
        let mut slot = self
            .pause_controller
            .lock()
            .map_err(|_| Failure::Unavailable)?;
        if slot.is_some() {
            return Err(Failure::Unavailable);
        }
        *slot = Some(controller);
        Ok(())
    }
    fn pause_controller(&self) -> Result<Option<Arc<dyn QuotaPauseController>>> {
        Ok(self
            .pause_controller
            .lock()
            .map_err(|_| Failure::Unavailable)?
            .clone())
    }
    pub fn preferences(&self) -> Result<AutomaticSwitchPreferences> {
        Ok(self
            .state
            .lock()
            .map_err(|_| Failure::Unavailable)?
            .saved
            .preferences
            .clone())
    }
    pub fn status(&self) -> Result<AutomaticSwitchStatus> {
        let pause_available =
            self.native_controller.is_some() && self.pause_controller()?.is_some();
        let state = self.state.lock().map_err(|_| Failure::Unavailable)?;
        let unavailable = state.saved.preferences.enabled && !self.safety.live_available();
        Ok(AutomaticSwitchStatus {
            phase: if unavailable {
                "unsupported"
            } else {
                state.phase
            },
            issue_code: if unavailable {
                Some(Failure::LiveTasksUnavailable.code())
            } else {
                state.issue.map(Failure::code)
            },
            source_account_id: state.source.clone(),
            target_account_id: state.target.clone(),
            last_attempt_at_ms: state.saved.last_attempt_at_ms,
            last_succeeded_at_ms: state.saved.last_succeeded_at_ms,
            next_eligible_at_ms: cooldown_until(
                state.saved.last_attempt_at_ms,
                state.saved.last_succeeded_at_ms,
            ),
            live_tasks_available: self.safety.live_available(),
            pause_resume_available: pause_available,
            resume_after_switch_available: false,
            last_switch_restored: state.saved.last_succeeded_at_ms.map(|_| false),
        })
    }
    pub fn save_preferences(
        &self,
        mut preferences: AutomaticSwitchPreferences,
    ) -> Result<AutomaticSwitchPreferences> {
        preferences.validate()?;
        let prior = self.preferences()?;
        if preferences.pause_at_one_percent && !prior.pause_at_one_percent {
            preferences.enabled = true;
        }
        if preferences.enabled && !self.safety.live_available() {
            return Err(Failure::LiveTasksUnavailable);
        }
        if preferences.enabled
            && self.safety.requires_native_quiescence()
            && self.native_controller.is_none()
        {
            return Err(Failure::LiveTasksUnavailable);
        }
        if preferences.enabled
            && preferences.pause_at_one_percent
            && self.pause_controller()?.is_none()
        {
            return Err(Failure::PauseResumeUnavailable);
        }
        if preferences.enabled {
            let catalog = self
                .manager
                .list_managed_accounts()
                .map_err(account_failure)?;
            let ids: BTreeSet<_> = catalog
                .iter()
                .filter(|a| a.platform == "codex")
                .map(|a| a.id.clone())
                .collect();
            if preferences
                .excluded_profile_ids
                .iter()
                .any(|id| !ids.contains(id))
            {
                return Err(Failure::InvalidSettings);
            }
        }
        let mut state = self.state.lock().map_err(|_| Failure::Unavailable)?;
        // A preference update wins the same short atomic race as the final
        // commit point. Once that point is claimed, this only updates the next
        // run's settings; the in-flight commit is no longer cancellable.
        let transition = self.commit_point.cancel();
        if transition == CancelTransition::Inactive {
            self.epoch.fetch_add(1, Ordering::AcqRel);
        }
        let mut next = state.saved.clone();
        next.preferences = preferences.clone();
        if let Err(error) = persist(&self.path, &next) {
            // A failed disable still fences current and future writes in this
            // process. Do not silently resume from the old persisted setting.
            state.suspended = true;
            state.phase = "blocked";
            state.issue = Some(error);
            return Err(error);
        }
        state.saved = next;
        state.suspended = false;
        state.phase = if preferences.enabled {
            "idle"
        } else {
            "disabled"
        };
        state.issue = None;
        Ok(preferences)
    }
    /// Cancels only this automatic attempt; manual login/switch state is never
    /// globally cancelled. Once the native commit point is claimed, report the
    /// in-flight commit instead of claiming cancellation succeeded.
    pub fn cancel(&self) -> Result<AutomaticSwitchStatus> {
        let transition = self.commit_point.cancel();
        if transition == CancelTransition::TooLate {
            if !self.commit_point.is_durable() {
                let mut state = self.state.lock().map_err(|_| Failure::Unavailable)?;
                state.phase = "committing";
                state.issue = None;
            }
            return self.status();
        }
        if transition == CancelTransition::Inactive {
            self.epoch.fetch_add(1, Ordering::AcqRel);
        }
        let ticket = {
            let mut state = self.state.lock().map_err(|_| Failure::Unavailable)?;
            state.phase = "cancelled";
            state.issue = Some(Failure::Cancelled);
            state.ticket.take()
        };
        if let Some(ticket) = ticket {
            let _ = self.manager.cancel_account_switch(&ticket);
        }
        self.status()
    }
    /// UI quit preflight has no file/process I/O and never blocks on a worker.
    pub fn has_inflight_operation(&self) -> bool {
        self.state
            .try_lock()
            .map(|s| s.inflight_epoch.is_some())
            .unwrap_or(true)
    }
    pub fn cancel_for_exit(&self) {
        self.exiting.store(true, Ordering::Release);
        if self.commit_point.cancel() == CancelTransition::Inactive {
            self.epoch.fetch_add(1, Ordering::AcqRel);
        }
    }
    pub fn evaluate_once(self: &Arc<Self>) -> Result<AutomaticSwitchStatus> {
        let _operation = self
            .operation
            .try_lock()
            .map_err(|_| Failure::AccountBusy)?;
        let epoch = self.epoch.load(Ordering::Acquire);
        let prefs = {
            let mut s = self.state.lock().map_err(|_| Failure::Unavailable)?;
            if self.exiting.load(Ordering::Acquire) {
                return Err(Failure::Cancelled);
            }
            if s.suspended {
                return Err(Failure::SaveFailed);
            }
            if !s.saved.preferences.enabled {
                s.phase = "disabled";
                s.issue = None;
                drop(s);
                return self.status();
            }
            if !self.safety.live_available() {
                s.phase = "unsupported";
                s.issue = Some(Failure::LiveTasksUnavailable);
                return Err(Failure::LiveTasksUnavailable);
            }
            if s.saved.preferences.pause_at_one_percent && self.pause_controller()?.is_none() {
                s.phase = "unsupported";
                s.issue = Some(Failure::PauseResumeUnavailable);
                return Err(Failure::PauseResumeUnavailable);
            }
            if cooldown_until(s.saved.last_attempt_at_ms, s.saved.last_succeeded_at_ms)
                .is_some_and(|until| until > now_ms())
            {
                s.phase = "cooldown";
                s.issue = Some(Failure::Cooldown);
                drop(s);
                return self.status();
            }
            s.phase = "checking";
            s.issue = None;
            s.source = None;
            s.target = None;
            self.commit_point.begin();
            s.inflight_epoch = Some(epoch);
            s.saved.preferences.clone()
        };
        let result = self.evaluate(epoch, &prefs, Instant::now() + Duration::from_secs(120));
        let mut state = self.state.lock().map_err(|_| Failure::Unavailable)?;
        if self.commit_point.is_cancelled() {
            self.epoch.fetch_add(1, Ordering::AcqRel);
        }
        if state.inflight_epoch == Some(epoch) {
            state.inflight_epoch = None;
            state.ticket = None;
            if self.epoch.load(Ordering::Acquire) != epoch
                && matches!(
                    state.phase,
                    "checking" | "checking_candidates" | "preparing" | "committing"
                )
            {
                state.phase = "cancelled";
                state.issue = Some(Failure::Cancelled);
            }
        }
        if self.epoch.load(Ordering::Acquire) == epoch && !self.exiting.load(Ordering::Acquire) {
            if let Err(error) = result {
                state.phase = if error == Failure::Cancelled {
                    "cancelled"
                } else {
                    "blocked"
                };
                state.issue = Some(error);
            }
        }
        self.commit_point.finish();
        drop(state);
        result?;
        self.status()
    }
    fn current(
        &self,
        epoch: u64,
        prefs: &AutomaticSwitchPreferences,
        deadline: Instant,
    ) -> Result<()> {
        if self.exiting.load(Ordering::Acquire)
            || self.epoch.load(Ordering::Acquire) != epoch
            || self.commit_point.is_cancelled()
        {
            return Err(Failure::Cancelled);
        }
        if Instant::now() >= deadline {
            return Err(Failure::QuotaUnknown);
        }
        let state = self.state.try_lock().map_err(|_| Failure::AccountBusy)?;
        if state.suspended || state.saved.preferences != *prefs || !prefs.enabled {
            return Err(Failure::Cancelled);
        }
        Ok(())
    }
    fn record_committed_switch(&self) -> Result<()> {
        let mut state = self.state.lock().map_err(|_| Failure::Unavailable)?;
        let next = committed_state(&state.saved, now_ms());
        if persist(&self.path, &next).is_err() {
            // The account transaction is already durable. Keep the fact in
            // memory, suspend further policy writes, and surface recovery.
            state.saved = next;
            state.suspended = true;
            state.phase = "blocked";
            state.issue = Some(Failure::RecoveryRequired);
            return Err(Failure::RecoveryRequired);
        }
        state.saved = next;
        state.phase = "switched";
        state.issue = state
            .saved
            .preferences
            .resume_after_switch
            .then_some(Failure::PauseResumeUnavailable);
        Ok(())
    }
    fn mark_committed_recovery_required(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.phase = "blocked";
            state.issue = Some(Failure::RecoveryRequired);
        }
    }
    fn catalog(&self) -> Result<Vec<Account>> {
        let records = self
            .manager
            .list_managed_accounts()
            .map_err(account_failure)?;
        if records.len() > 100 {
            return Err(Failure::SourceUnknown);
        }
        let mut out = vec![];
        for record in records.into_iter().filter(|a| a.platform == "codex") {
            if !valid_id(&record.id) {
                return Err(Failure::SourceUnknown);
            }
            let Some((group, workspace)) = self
                .manager
                .managed_automation_keys(&record.id)
                .map_err(account_failure)?
            else {
                continue;
            };
            let Some(identity) = self
                .manager
                .managed_identity_hash(&record.id)
                .map_err(account_failure)?
            else {
                continue;
            };
            if !valid_hash(&identity) || !valid_hash(&group) || !valid_hash(&workspace) {
                return Err(Failure::SourceUnknown);
            }
            let fresh = self.evidence(&record.id).ok();
            out.push(Account {
                id: record.id,
                group,
                workspace,
                identity,
                active: record.active_state == "verified",
                eligible: !record.recovery_required
                    && !matches!(record.login_state, "signing_in" | "signed_out"),
                fresh,
            });
        }
        Ok(out)
    }
    fn evidence(&self, id: &str) -> Result<Evidence> {
        let value = self
            .manager
            .verified_credential_snapshot(id, 45)
            .map_err(account_failure)?;
        let quota = Quota::from_official(value.plan.as_deref(), &value.official_quota)?;
        let observed_at = value
            .observed_at
            .try_into()
            .ok()
            .and_then(|v: u64| v.checked_mul(1000))
            .ok_or(Failure::QuotaUnknown)?;
        if !is_fresh(observed_at, QUOTA_MAX_AGE_MS, now_ms()) || !valid_hash(&value.identity_hash) {
            return Err(Failure::QuotaUnknown);
        }
        Ok(Evidence {
            identity: value.identity_hash,
            generation: value.token_generation,
            observed_at,
            quota,
        })
    }
    fn participating(
        account: &Account,
        catalog: &[Account],
        prefs: &AutomaticSwitchPreferences,
    ) -> bool {
        !catalog
            .iter()
            .any(|a| a.group == account.group && prefs.excluded_profile_ids.contains(&a.id))
    }
    fn evaluate(
        self: &Arc<Self>,
        epoch: u64,
        prefs: &AutomaticSwitchPreferences,
        deadline: Instant,
    ) -> Result<()> {
        self.current(epoch, prefs, deadline)?;
        if let Some(controller) = self.pause_controller()? {
            if controller.has_unresolved()? {
                return Err(Failure::RecoveryRequired);
            }
        }
        let mut catalog = self.catalog()?;
        let source = catalog
            .iter()
            .find(|a| a.active)
            .ok_or(Failure::SourceUnknown)?;
        if catalog.iter().filter(|a| a.active).count() != 1
            || !Self::participating(source, &catalog, prefs)
        {
            return Err(Failure::SourceUnknown);
        }
        let source_id = source.id.clone();
        let source_workspace = source.workspace.clone();
        let source_identity = source.identity.clone();
        let original = source.fresh.clone().ok_or(Failure::QuotaUnknown)?;
        if original.identity != source_identity || !original.quota.complete() {
            return Err(Failure::QuotaUnknown);
        }
        let windows = original.quota.triggered(prefs);
        if windows.is_empty() {
            self.stage(epoch, "idle", None, None)?;
            return Ok(());
        }
        let safety = self.safety.snapshot()?;
        self.validate_activity(&safety, prefs, &source_identity, &original.generation, None)?;
        let stale: Vec<_> = catalog
            .iter()
            .filter(|a| {
                a.eligible
                    && a.workspace != source_workspace
                    && Self::participating(a, &catalog, prefs)
                    && a.fresh.is_none()
            })
            .map(|a| a.id.clone())
            .collect();
        if !stale.is_empty() {
            let refresh = {
                let mut s = self.state.lock().map_err(|_| Failure::Unavailable)?;
                if s.candidate_refresh_at
                    .is_none_or(|at| now_ms().saturating_sub(at) >= CANDIDATE_REFRESH_BACKOFF_MS)
                {
                    s.candidate_refresh_at = Some(now_ms());
                    true
                } else {
                    false
                }
            };
            if refresh {
                self.stage(epoch, "checking_candidates", Some(&source_id), None)?;
                for id in &stale {
                    self.current(epoch, prefs, deadline)?;
                    self.validate_activity(
                        &self.safety.snapshot()?,
                        prefs,
                        &source_identity,
                        &original.generation,
                        Some(&safety.connection_generation),
                    )?;
                    // This is the existing official quota-only verification;
                    // it sends no inference prompt and owns its own bounded CLI.
                    let _ = self.manager.refresh_managed_credential(id);
                }
                catalog = self.catalog()?;
            }
        }
        self.current(epoch, prefs, deadline)?;
        let source = catalog
            .iter()
            .find(|a| a.id == source_id && a.active && a.identity == source_identity)
            .ok_or(Failure::IdentityChanged)?;
        let source_fresh = source.fresh.clone().ok_or(Failure::QuotaUnknown)?;
        if source_fresh.generation != original.generation
            || !Self::participating(source, &catalog, prefs)
        {
            return Err(Failure::IdentityChanged);
        }
        let windows = source_fresh.quota.triggered(prefs);
        if !source_fresh.quota.complete() || windows.is_empty() {
            return Err(Failure::QuotaUnknown);
        }
        let mut eligible: Vec<_> = catalog
            .iter()
            .filter(|a| {
                a.eligible
                    && a.workspace != source_workspace
                    && Self::participating(a, &catalog, prefs)
            })
            .filter_map(|a| Some((a, a.fresh.as_ref()?.quota.candidate_score(&windows)?)))
            .collect();
        eligible.sort_by(|(a, x), (b, y)| y.total_cmp(x).then_with(|| a.id.cmp(&b.id)));
        let target = eligible.first().map(|(a, _)| *a);
        // Failed/stale reads do not consume the one-hour transaction retry.
        if target.is_none()
            && catalog.iter().any(|a| {
                a.eligible
                    && a.workspace != source_workspace
                    && Self::participating(a, &catalog, prefs)
                    && a.fresh.is_none()
            })
        {
            return Err(Failure::QuotaUnknown);
        }
        let target_id = target.map(|a| a.id.clone());
        #[cfg(windows)]
        let selected_target = target.and_then(|a| a.fresh.clone());
        {
            let mut state = self.state.lock().map_err(|_| Failure::Unavailable)?;
            if self.epoch.load(Ordering::Acquire) != epoch {
                return Err(Failure::Cancelled);
            }
            let mut next = state.saved.clone();
            next.last_attempt_at_ms = Some(now_ms());
            if let Err(e) = persist(&self.path, &next) {
                state.suspended = true;
                return Err(e);
            }
            state.saved = next;
        }
        self.emit(
            epoch,
            AutomaticSwitchEvent::LowQuota {
                source_id: source_id.clone(),
                target_id: target_id.clone(),
                quota: source_fresh.quota,
                at_ms: now_ms(),
            },
        );
        let target_id = target_id.ok_or(Failure::NoEligibleCandidate)?;
        self.stage(epoch, "preparing", Some(&source_id), Some(&target_id))?;
        self.current(epoch, prefs, deadline)?;
        // A real system-daemon source never falls back to the injected prepare
        // path. Its concrete lease is held continuously before close, through
        // preparation and the guarded commit/rollback below.
        #[cfg(windows)]
        let mut pause_receipt: Option<(Arc<dyn QuotaPauseController>, QuotaPauseReceipt)> = None;
        #[cfg(windows)]
        let native_authority = if self.safety.requires_native_quiescence() {
            let controller = self
                .native_controller
                .as_ref()
                .ok_or(Failure::LiveTasksUnavailable)?;
            let scope = self
                .manager
                .verified_active_system_scope()
                .map_err(account_failure)?;
            if scope.profile_id() != source_id
                || scope.identity_hash() != source_identity
                || scope.credential_generation() != original.generation
            {
                return Err(Failure::IdentityChanged);
            }
            let lease = controller
                .gate
                .reserve_automatic_maintenance(&scope, &target_id)
                .map_err(account_failure)?;
            let policy = Arc::new(PolicyOnlyGuard(CommitGuard {
                service: Arc::downgrade(self),
                epoch,
                preferences: prefs.clone(),
                identity: source_identity.clone(),
                connection_generation: safety.connection_generation.clone(),
                source: source_fresh.clone(),
                target: selected_target.clone().ok_or(Failure::QuotaUnknown)?,
                deadline,
                quiesced: None,
            }));
            if prefs.pause_at_one_percent {
                let controller_adapter = self
                    .pause_controller()?
                    .ok_or(Failure::PauseResumeUnavailable)?;
                let snapshot = controller.source.latest().map_err(live_failure)?;
                if !snapshot.matches_scope(&scope) || !snapshot.is_current() {
                    return Err(Failure::IdentityChanged);
                }
                let target = selected_target.as_ref().ok_or(Failure::QuotaUnknown)?;
                let admission_policy = policy.clone();
                let receipt = controller_adapter.pause(QuotaPauseRequest {
                    snapshot,
                    source: scope.clone(),
                    target_profile_id: target_id.clone(),
                    target_identity_hash: target.identity.clone(),
                    target_credential_generation: target.generation.clone(),
                    lease: lease.clone(),
                    admission: Arc::new(move || admission_policy.recheck().is_ok()),
                })?;
                if let Some(receipt) = receipt {
                    pause_receipt = Some((controller_adapter, receipt));
                }
                self.safety.snapshot()?.validate_idle(
                    &source_identity,
                    &original.generation,
                    Some(&safety.connection_generation),
                    now_ms(),
                )?;
            }
            let proof = controller
                .source
                .quiesce_for_switch(lease.clone(), epoch, policy)
                .map_err(live_failure)?;
            Some((lease, proof))
        } else {
            None
        };
        #[cfg(not(windows))]
        if self.safety.requires_native_quiescence() {
            return Err(Failure::LiveTasksUnavailable);
        }
        #[cfg(windows)]
        let prepared = if let Some((lease, proof)) = &native_authority {
            self.manager
                .prepare_account_switch_in_operation(
                    &target_id,
                    lease,
                    &QuiescedPreparationGuard(proof.clone()),
                )
                .map_err(account_failure)?
        } else {
            self.manager
                .prepare_account_switch(target_id.clone())
                .map_err(account_failure)?
        };
        #[cfg(not(windows))]
        let prepared = self
            .manager
            .prepare_account_switch(target_id.clone())
            .map_err(account_failure)?;
        let ticket = prepared.ticket.ok_or_else(|| {
            account_failure(AccountError {
                code: prepared.reason_code.unwrap_or("switch_unavailable"),
            })
        })?;
        let result = (|| {
            self.current(epoch, prefs, deadline)?;
            {
                self.state.lock().map_err(|_| Failure::Unavailable)?.ticket = Some(ticket.clone());
            }
            let final_catalog = self.catalog()?;
            let source = final_catalog
                .iter()
                .find(|a| a.id == source_id && a.active && a.identity == source_identity)
                .ok_or(Failure::IdentityChanged)?;
            let target = final_catalog
                .iter()
                .find(|a| a.id == target_id && a.workspace != source.workspace)
                .ok_or(Failure::IdentityChanged)?;
            if !Self::participating(source, &final_catalog, prefs)
                || !Self::participating(target, &final_catalog, prefs)
            {
                return Err(Failure::IdentityChanged);
            }
            let src = source.fresh.clone().ok_or(Failure::QuotaUnknown)?;
            let dst = target.fresh.clone().ok_or(Failure::QuotaUnknown)?;
            if src.generation != original.generation
                || !src.quota.complete()
                || dst
                    .quota
                    .candidate_score(&src.quota.triggered(prefs))
                    .is_none()
            {
                return Err(Failure::QuotaUnknown);
            }
            let guard = CommitGuard {
                service: Arc::downgrade(self),
                epoch,
                preferences: prefs.clone(),
                identity: source_identity.clone(),
                connection_generation: safety.connection_generation.clone(),
                source: src,
                target: dst,
                deadline,
                #[cfg(windows)]
                quiesced: native_authority.as_ref().map(|(_, proof)| proof.clone()),
            };
            guard.check()?;
            #[cfg(windows)]
            if let Some((_, proof)) = &native_authority {
                proof.claim_for_commit().map_err(live_failure)?;
            }
            self.stage(epoch, "committing", Some(&source_id), Some(&target_id))?;
            let outcome = self.manager.commit_account_switch_guarded(&ticket, &guard);
            if !self.commit_point.is_durable() {
                let outcome = outcome.map_err(account_failure)?;
                if outcome.phase != "committed" {
                    return Err(Failure::TransactionFailed);
                }
                return Err(Failure::TransactionFailed);
            }

            // Do not recheck the old settings epoch after the durable commit:
            // a concurrent disable/cancel is ordered after this point and must
            // not relabel the committed account switch as an uncommitted one.
            let mut recovery_required = self.record_committed_switch().is_err();
            if outcome.is_err()
                || outcome
                    .as_ref()
                    .is_ok_and(|operation| operation.phase != "committed")
            {
                // The vault save succeeded but transaction-journal cleanup did
                // not. Keep the staged quota journal and require recovery.
                recovery_required = true;
            } else {
                #[cfg(windows)]
                if let Some((controller, receipt)) = &pause_receipt {
                    let armed = (|| {
                        let target = self
                            .manager
                            .verified_active_system_scope()
                            .map_err(account_failure)?;
                        let (lease, _) =
                            native_authority.as_ref().ok_or(Failure::RecoveryRequired)?;
                        controller.switch_verified(receipt, &target, lease)
                    })();
                    if armed.is_err() {
                        recovery_required = true;
                    }
                }
            }
            if recovery_required {
                self.mark_committed_recovery_required();
                return Err(Failure::RecoveryRequired);
            }
            Ok(())
        })();
        // Before commit this drops only the exact prepared reservation. Once
        // consumed, cancellation/rollback belongs to the guarded transaction.
        if self.commit_point.is_durable() {
            if result.is_err() {
                self.mark_committed_recovery_required();
            }
            self.emit(
                epoch,
                AutomaticSwitchEvent::Succeeded {
                    source_id,
                    target_id,
                    at_ms: now_ms(),
                },
            );
        } else if let Err(error) = result {
            let _ = self.manager.cancel_account_switch(&ticket);
            self.emit(
                epoch,
                AutomaticSwitchEvent::Failed {
                    source_id,
                    target_id,
                    failure: error,
                    at_ms: now_ms(),
                },
            );
        }
        result
    }
    fn validate_activity(
        &self,
        safety: &SafetySnapshot,
        prefs: &AutomaticSwitchPreferences,
        identity: &str,
        generation: &str,
        connection: Option<&str>,
    ) -> Result<()> {
        if prefs.pause_at_one_percent {
            safety.validate_pause(identity, generation, connection, now_ms())
        } else {
            safety.validate_idle(identity, generation, connection, now_ms())
        }
    }
    fn emit(&self, epoch: u64, event: AutomaticSwitchEvent) {
        if !self.exiting.load(Ordering::Acquire)
            && !self.commit_point.is_cancelled()
            && self.epoch.load(Ordering::Acquire) == epoch
        {
            if let Some(observer) = &self.observer {
                observer.record(event)
            }
        }
    }
    fn stage(
        &self,
        epoch: u64,
        phase: &'static str,
        source: Option<&str>,
        target: Option<&str>,
    ) -> Result<()> {
        if self.epoch.load(Ordering::Acquire) != epoch || self.exiting.load(Ordering::Acquire) {
            return Err(Failure::Cancelled);
        }
        let mut state = self.state.lock().map_err(|_| Failure::Unavailable)?;
        state.phase = phase;
        state.issue = None;
        state.source = source.map(str::to_owned);
        state.target = target.map(str::to_owned);
        Ok(())
    }
    pub fn start_monitor(self: &Arc<Self>) -> Result<AutomaticSwitchMonitor> {
        if self
            .monitor_active
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(Failure::AccountBusy);
        }
        let stop = Arc::new(AtomicBool::new(false));
        let worker_stop = stop.clone();
        let weak = Arc::downgrade(self);
        let thread = std::thread::Builder::new()
            .name("agb-automatic-switch".into())
            .spawn(move || {
                let mut next = Instant::now();
                while !worker_stop.load(Ordering::Acquire) {
                    let Some(service) = weak.upgrade() else { break };
                    if service.exiting.load(Ordering::Acquire) {
                        break;
                    }
                    if Instant::now() >= next {
                        let _ = service.evaluate_once();
                        next = Instant::now() + Duration::from_secs(180);
                    }
                    drop(service);
                    std::thread::sleep(Duration::from_millis(100));
                }
                if let Some(service) = weak.upgrade() {
                    service.monitor_active.store(false, Ordering::Release);
                }
            })
            .map_err(|_| {
                self.monitor_active.store(false, Ordering::Release);
                Failure::MonitorUnavailable
            })?;
        Ok(AutomaticSwitchMonitor {
            stop,
            service: Arc::downgrade(self),
            _thread: Some(thread),
        })
    }
}
#[derive(Clone)]
struct CommitGuard {
    service: Weak<AutomaticSwitchService>,
    epoch: u64,
    preferences: AutomaticSwitchPreferences,
    identity: String,
    connection_generation: String,
    source: Evidence,
    target: Evidence,
    deadline: Instant,
    #[cfg(windows)]
    quiesced: Option<Arc<live::QuiescedSystemProof>>,
}
impl CommitGuard {
    fn check_policy(&self) -> Result<()> {
        let service = self.service.upgrade().ok_or(Failure::Cancelled)?;
        service.current(self.epoch, &self.preferences, self.deadline)?;
        if !is_fresh(self.source.observed_at, QUOTA_MAX_AGE_MS, now_ms())
            || !is_fresh(self.target.observed_at, QUOTA_MAX_AGE_MS, now_ms())
            || !self.source.quota.complete()
            || self
                .target
                .quota
                .candidate_score(&self.source.quota.triggered(&self.preferences))
                .is_none()
        {
            return Err(Failure::QuotaUnknown);
        }
        Ok(())
    }
    fn check(&self) -> Result<()> {
        self.check_policy()?;
        #[cfg(windows)]
        if let Some(proof) = &self.quiesced {
            if proof.automatic_epoch() != self.epoch
                || proof.source_identity_hash() != self.identity
                || proof.source_credential_generation() != self.source.generation
                || proof.previous_peer_generation() != self.connection_generation
            {
                return Err(Failure::IdentityChanged);
            }
            return proof.recheck_cached().map_err(live_failure);
        }
        let service = self.service.upgrade().ok_or(Failure::Cancelled)?;
        if service.safety.requires_native_quiescence() {
            return Err(Failure::LiveTasksUnavailable);
        }
        service.safety.snapshot()?.validate_idle(
            &self.identity,
            &self.source.generation,
            Some(&self.connection_generation),
            now_ms(),
        )
    }
}
#[cfg(windows)]
struct PolicyOnlyGuard(CommitGuard);
#[cfg(windows)]
impl SwitchCommitGuard for PolicyOnlyGuard {
    fn recheck(&self) -> crate::accounts::AccountResult<()> {
        self.0.check_policy().map_err(|_| AccountError {
            code: "switch_cancelled",
        })
    }
}
#[cfg(windows)]
struct QuiescedPreparationGuard(Arc<live::QuiescedSystemProof>);
#[cfg(windows)]
impl SwitchCommitGuard for QuiescedPreparationGuard {
    fn recheck(&self) -> crate::accounts::AccountResult<()> {
        self.0.recheck_cached().map_err(|_| AccountError {
            code: "switch_cancelled",
        })
    }
    fn verification_process_permit(
        &self,
    ) -> Option<Arc<dyn crate::accounts::VerificationProcessPermit>> {
        Some(self.0.verification_process_permit())
    }
}
#[cfg(windows)]
fn live_failure(issue: live::LiveIssue) -> Failure {
    match issue {
        live::LiveIssue::Cancelled => Failure::Cancelled,
        live::LiveIssue::ScopeUnverified | live::LiveIssue::PeerUntrusted => {
            Failure::IdentityChanged
        }
        live::LiveIssue::Unavailable => Failure::LiveTasksUnavailable,
        _ => Failure::TaskUnknown,
    }
}
impl SwitchCommitGuard for CommitGuard {
    fn recheck(&self) -> crate::accounts::AccountResult<()> {
        self.check().map_err(|_| AccountError {
            code: "switch_cancelled",
        })
    }
    fn claim_commit_point(&self) -> crate::accounts::AccountResult<()> {
        self.check().map_err(|_| AccountError {
            code: "switch_cancelled",
        })?;
        let service = self.service.upgrade().ok_or(AccountError {
            code: "switch_cancelled",
        })?;
        if service.commit_point.claim() {
            Ok(())
        } else {
            Err(AccountError {
                code: "switch_cancelled",
            })
        }
    }
    fn commit_succeeded(&self) {
        if let Some(service) = self.service.upgrade() {
            service.commit_point.mark_durable();
        }
    }
    fn verification_process_permit(
        &self,
    ) -> Option<Arc<dyn crate::accounts::VerificationProcessPermit>> {
        #[cfg(windows)]
        {
            self.quiesced
                .as_ref()
                .map(|proof| proof.verification_process_permit())
        }
        #[cfg(not(windows))]
        {
            None
        }
    }
}
pub struct AutomaticSwitchMonitor {
    stop: Arc<AtomicBool>,
    service: Weak<AutomaticSwitchService>,
    _thread: Option<std::thread::JoinHandle<()>>,
}
impl AutomaticSwitchMonitor {
    pub fn is_finished(&self) -> bool {
        self._thread
            .as_ref()
            .is_none_or(|thread| thread.is_finished())
    }
    pub fn cancel(&self) {
        self.stop.store(true, Ordering::Release);
        if let Some(service) = self.service.upgrade() {
            if service.commit_point.cancel() == CancelTransition::Inactive {
                service.epoch.fetch_add(1, Ordering::AcqRel);
            }
        }
    }
}
impl Drop for AutomaticSwitchMonitor {
    fn drop(&mut self) {
        self.cancel()
    }
}

fn check_path(path: &Path) -> Result<()> {
    let parent = path.parent().ok_or(Failure::InvalidSettings)?;
    if !crate::updates::safe_download_directory(parent) || !path.is_absolute() {
        return Err(Failure::InvalidSettings);
    }
    match std::fs::symlink_metadata(path) {
        Ok(meta) => {
            if !meta.is_file() || meta.file_type().is_symlink() || meta.len() > 1024 * 1024 {
                return Err(Failure::SaveFailed);
            }
            #[cfg(windows)]
            {
                use std::os::windows::fs::MetadataExt;
                if meta.file_attributes() & 0x400 != 0 {
                    return Err(Failure::SaveFailed);
                }
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err(Failure::SaveFailed),
    }
    Ok(())
}
fn read_saved(path: &Path) -> Result<Stored> {
    match std::fs::symlink_metadata(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Stored::default()),
        Err(_) => return Err(Failure::SaveFailed),
        Ok(_) => {}
    }
    let mut bytes = vec![];
    std::fs::File::open(path)
        .and_then(|f| f.take(1024 * 1024 + 1).read_to_end(&mut bytes))
        .map_err(|_| Failure::SaveFailed)?;
    if bytes.len() > 1024 * 1024 {
        return Err(Failure::SaveFailed);
    }
    let saved: Stored = serde_json::from_slice(&bytes).map_err(|_| Failure::SaveFailed)?;
    if saved.version != 1 {
        return Err(Failure::InvalidSettings);
    }
    saved.preferences.validate()?;
    Ok(saved)
}
fn persist(path: &Path, saved: &Stored) -> Result<()> {
    check_path(path)?;
    let bytes = serde_json::to_vec(saved).map_err(|_| Failure::SaveFailed)?;
    crate::atomic_settings::write_json(path, &bytes, |old| {
        let prior: Stored = serde_json::from_slice(old)?;
        anyhow::ensure!(prior.version == 1, "Unsupported schema");
        prior.preferences.validate()?;
        Ok(())
    })
    .map_err(|_| Failure::SaveFailed)
}

fn committed_state(saved: &Stored, at_ms: u64) -> Stored {
    let mut next = saved.clone();
    next.last_succeeded_at_ms = Some(at_ms);
    next.last_attempt_at_ms = None;
    next
}

#[cfg(test)]
mod commit_point_tests {
    use super::*;
    use std::sync::Barrier;

    #[test]
    fn cancellation_and_commit_point_have_one_linearization_winner() {
        let point = Arc::new(CommitPoint::default());
        point.begin();
        let start = Arc::new(Barrier::new(3));
        let cancel_point = point.clone();
        let cancel_start = start.clone();
        let cancel = std::thread::spawn(move || {
            cancel_start.wait();
            cancel_point.cancel()
        });
        let claim_point = point.clone();
        let claim_start = start.clone();
        let claim = std::thread::spawn(move || {
            claim_start.wait();
            claim_point.claim()
        });
        start.wait();

        match (cancel.join().unwrap(), claim.join().unwrap()) {
            (CancelTransition::Cancelled, false) => {
                assert!(!point.is_durable());
            }
            (CancelTransition::TooLate, true) => {
                point.mark_durable();
                assert!(point.is_durable());
            }
            other => panic!("invalid commit/cancel ordering: {other:?}"),
        }
    }

    #[test]
    fn durable_commit_ignores_later_cancel_and_success_keeps_new_preferences() {
        let point = CommitPoint::default();
        point.begin();
        assert!(point.claim());
        point.mark_durable();
        assert_eq!(point.cancel(), CancelTransition::TooLate);

        let mut saved = Stored::default();
        saved.preferences.enabled = false;
        saved.preferences.five_hour_remaining_threshold = 12;
        let committed = committed_state(&saved, 1234);
        assert_eq!(committed.preferences, saved.preferences);
        assert_eq!(committed.last_succeeded_at_ms, Some(1234));
        assert_eq!(committed.last_attempt_at_ms, None);
    }
}
