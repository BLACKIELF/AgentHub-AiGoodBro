use super::super::{
    fail, nonce, now, AccountOccupancyGate, AccountOperationDto, AccountResult, DpapiProtector,
    PreparedSwitchDto, SecretProtector, SwitchMaintenanceLease,
};
use super::{
    cache::{Attempt as QuotaAttempt, DisplayCache, Scope as QuotaScope},
    identity,
    storage::{
        self, ActiveProof, Journal, MutationLocks, QuotaRetry, Record, RefreshRecovery, Store,
        Target,
    },
    ClaudeAccountPaths, ClaudeLoginAttemptDto, ClaudeSubscriptionDto, ClaudeSubscriptionQuotaDto,
    ClaudeSubscriptionRuntime, ClaudeVerifiedCredential, NativeClaudeRuntime,
};
use crate::readers::local_cli_quota::{LocalCliQuotaResult, LocalCliQuotaState};
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, RwLock,
    },
};

struct Attempt {
    dto: ClaudeLoginAttemptDto,
    cancelled: Arc<AtomicBool>,
    verified: Option<ClaudeVerifiedCredential>,
    expires_at: i64,
}
struct Ticket {
    account_id: String,
    vault_revision: u64,
    record: Record,
    before: Target,
    written: Target,
    lease: Box<dyn SwitchMaintenanceLease>,
    locks: MutationLocks,
    swap_locks: cswap::SwapLocks,
    swap_records: Vec<Record>,
    expires_at: i64,
}
pub struct ClaudeSubscriptionManager {
    paths: ClaudeAccountPaths,
    protector: Arc<dyn SecretProtector>,
    runtime: Arc<dyn ClaudeSubscriptionRuntime>,
    occupancy: RwLock<Option<Arc<dyn AccountOccupancyGate>>>,
    mutation: Mutex<()>,
    attempts: Mutex<HashMap<String, Attempt>>,
    tickets: Mutex<HashMap<String, Ticket>>,
    exiting: AtomicBool,
    cleanup_unconfirmed: AtomicBool,
    quota_cache: DisplayCache,
}
impl ClaudeSubscriptionManager {
    pub fn native(app_data_dir: PathBuf) -> AccountResult<Arc<Self>> {
        if !cfg!(windows) {
            return Err(fail("windows_required"));
        }
        let home = dirs::home_dir().ok_or_else(|| fail("target_home_unavailable"))?;
        Self::with_components(
            ClaudeAccountPaths::isolated(
                app_data_dir.join("claude-subscriptions-v1"),
                home.join(".claude"),
                home.join(".claude.json"),
            )?,
            Arc::new(DpapiProtector),
            Arc::new(NativeClaudeRuntime),
            None,
        )
    }
    pub fn with_components(
        paths: ClaudeAccountPaths,
        protector: Arc<dyn SecretProtector>,
        runtime: Arc<dyn ClaudeSubscriptionRuntime>,
        occupancy: Option<Arc<dyn AccountOccupancyGate>>,
    ) -> AccountResult<Arc<Self>> {
        let paths = ClaudeAccountPaths::isolated(
            paths.vault_root,
            paths.live_directory,
            paths.global_config,
        )?;
        super::super::storage::secure_directory(&paths.vault_root)?;
        super::super::storage::secure_directory(&paths.staging())?;
        let _ = Store::load(&paths, protector.as_ref())?;
        Ok(Arc::new(Self {
            paths,
            protector,
            runtime,
            occupancy: RwLock::new(occupancy),
            mutation: Mutex::new(()),
            attempts: Mutex::new(HashMap::new()),
            tickets: Mutex::new(HashMap::new()),
            exiting: AtomicBool::new(false),
            cleanup_unconfirmed: AtomicBool::new(false),
            quota_cache: DisplayCache::default(),
        }))
    }
    fn store(&self) -> AccountResult<Store<'_>> {
        Store::load(&self.paths, self.protector.as_ref())
    }
    fn accepting(&self) -> AccountResult<()> {
        if self.exiting.load(Ordering::SeqCst) {
            Err(fail("account_service_exiting"))
        } else {
            Ok(())
        }
    }
    fn recovered(&self) -> AccountResult<()> {
        self.accepting()?;
        if self.cleanup_unconfirmed.load(Ordering::SeqCst) {
            self.quota_cache.degrade_all();
            return Err(fail("cleanup_unconfirmed"));
        }
        if self
            .attempts
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?
            .values()
            .any(|a| a.dto.error_code == Some("cleanup_unconfirmed"))
        {
            self.quota_cache.degrade_all();
            return Err(fail("cleanup_unconfirmed"));
        }
        if self.paths.journal().exists() {
            self.quota_cache.degrade_all();
            Err(fail("recovery_required"))
        } else {
            Ok(())
        }
    }
    fn expire(&self) -> AccountResult<()> {
        self.tickets
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?
            .retain(|_, t| t.expires_at > now());
        let mut attempts = self
            .attempts
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?;
        for a in attempts
            .values_mut()
            .filter(|a| a.dto.phase == "verified" && a.expires_at <= now())
        {
            a.verified = None;
            a.dto.phase = "failed";
            a.dto.error_code = Some("claude_login_attempt_expired");
        }
        Ok(())
    }
    fn no_other_operation(&self) -> AccountResult<()> {
        self.expire()?;
        if self
            .attempts
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?
            .values()
            .any(|a| {
                matches!(
                    a.dto.phase,
                    "starting" | "waiting" | "verifying" | "cancelling"
                )
            })
        {
            return Err(fail("login_in_progress"));
        }
        if !self
            .tickets
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?
            .is_empty()
        {
            return Err(fail("switch_in_progress"));
        }
        Ok(())
    }
    pub fn install_occupancy_gate(&self, gate: Arc<dyn AccountOccupancyGate>) -> AccountResult<()> {
        let _op = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.no_other_operation()?;
        *self
            .occupancy
            .write()
            .map_err(|_| fail("occupancy_unknown"))? = Some(gate);
        Ok(())
    }
    fn maintenance(&self, id: &str) -> AccountResult<Box<dyn SwitchMaintenanceLease>> {
        self.runtime.require_system_idle()?;
        let gate = self
            .occupancy
            .read()
            .map_err(|_| fail("occupancy_unknown"))?
            .clone()
            .ok_or_else(|| fail("occupancy_unknown"))?;
        let lease = gate.acquire_switch_maintenance(id, &nonce()?)?;
        lease.recheck()?;
        self.runtime.require_system_idle()?;
        Ok(lease)
    }
    pub fn list_claude_subscriptions(&self) -> AccountResult<Vec<ClaudeSubscriptionDto>> {
        self.expire()?;
        let store = self.store()?;
        let target = Target::read(&self.paths).ok();
        let recovery = self.paths.journal().exists();
        let gate = self
            .occupancy
            .read()
            .map_err(|_| fail("occupancy_unknown"))?
            .is_some();
        let result = store
            .vault
            .records
            .iter()
            .map(|r| {
                let pending = store.vault.refresh.contains_key(&r.id);
                let valid = identity::oauth(&r.credential.bytes, false).is_ok() && !pending;
                let active =
                    store.vault.active.as_ref().filter(|a| {
                        a.id == r.id && a.identity == r.credential.identity.fingerprint()
                    });
                let active_state = if recovery {
                    "unknown"
                } else if let Some(a) = active {
                    if target.as_ref().is_some_and(|t| {
                        t.legacy == a.legacy
                            && t.credential
                                .as_ref()
                                .is_some_and(|v| identity::digest(v) == a.credential_digest)
                            && t.config()
                                .is_some_and(|v| identity::digest(v) == a.config_digest)
                    }) {
                        "verified"
                    } else {
                        "stale"
                    }
                } else {
                    "unknown"
                };
                ClaudeSubscriptionDto {
                    id: r.id.clone(),
                    registration_pending: false,
                    label: r.display_label().to_owned(),
                    platform: "claude".into(),
                    storage_kind: "managed",
                    login_state: if pending {
                        "needs_reauth"
                    } else if valid {
                        "verified"
                    } else {
                        "needs_reauth"
                    },
                    active_state,
                    masked_identity: r.credential.identity.masked(),
                    plan_type: r.credential.plan.clone(),
                    can_login: self.runtime.available() && !recovery,
                    can_switch: valid && gate && !recovery && self.runtime.available(),
                    switch_block_reason: if recovery {
                        Some("recovery_required")
                    } else if let Some(error) = r.source_error {
                        Some(error)
                    } else if pending {
                        Some("claude_reauthentication_required")
                    } else if !valid {
                        Some("claude_credentials_expired")
                    } else if !gate {
                        Some("occupancy_unknown")
                    } else if !self.runtime.available() {
                        Some("claude_cli_unavailable")
                    } else {
                        None
                    },
                    revision: r.revision,
                    recovery_required: recovery,
                }
            })
            .collect();
        let scopes = store
            .vault
            .records
            .iter()
            .map(|r| {
                (
                    quota_scope(r),
                    store.vault.refresh.contains_key(&r.id)
                        || identity::oauth(&r.credential.bytes, false).is_err(),
                )
            })
            .collect::<Vec<_>>();
        drop(store);
        self.quota_cache.sync_catalog(
            &scopes,
            recovery || self.cleanup_unconfirmed.load(Ordering::Acquire),
        );
        Ok(result)
    }
    pub fn begin_claude_subscription_login(
        self: &Arc<Self>,
    ) -> AccountResult<ClaudeLoginAttemptDto> {
        self.retry_pending_recovery()?;
        let _op = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.recovered()?;
        self.no_other_operation()?;
        self.quota_cache.degrade_all();
        self.runtime.validate_environment()?;
        if !self.runtime.available() {
            return Err(fail("claude_cli_unavailable"));
        }
        let id = nonce()?;
        let dto = ClaudeLoginAttemptDto {
            attempt_id: id.clone(),
            phase: "starting",
            error_code: None,
        };
        let cancelled = Arc::new(AtomicBool::new(false));
        {
            let mut attempts = self
                .attempts
                .lock()
                .map_err(|_| fail("account_state_unavailable"))?;
            attempts.retain(|_, a| {
                matches!(
                    a.dto.phase,
                    "starting" | "waiting" | "verifying" | "cancelling"
                ) || a.expires_at > now()
            });
            if attempts.len() >= 64 {
                return Err(fail("login_attempt_limit"));
            }
            attempts.insert(
                id.clone(),
                Attempt {
                    dto: dto.clone(),
                    cancelled: cancelled.clone(),
                    verified: None,
                    expires_at: now() + 900,
                },
            );
        }
        let manager = self.clone();
        let worker_id = id.clone();
        if std::thread::Builder::new()
            .name("claude-official-login".into())
            .spawn(move || manager.run_login(&worker_id, &cancelled))
            .is_err()
        {
            self.attempts
                .lock()
                .map_err(|_| fail("account_state_unavailable"))?
                .remove(&id);
            return Err(fail("login_unavailable"));
        }
        Ok(dto)
    }
    fn run_login(&self, id: &str, cancelled: &AtomicBool) {
        let result = (|| {
            self.accepting()?;
            let directory =
                super::super::storage::private_tempdir(&self.paths.staging(), "claude-login-")
                    .map_err(|_| fail("login_unavailable"))?;
            let mut waiting = || {
                if !cancelled.load(Ordering::SeqCst) {
                    if let Ok(mut attempts) = self.attempts.lock() {
                        if let Some(a) = attempts.get_mut(id) {
                            a.dto.phase = "waiting";
                        }
                    }
                }
            };
            let result = self
                .runtime
                .login(directory.path(), cancelled, &mut waiting);
            if result
                .as_ref()
                .is_err_and(|e| e.code == "cleanup_unconfirmed")
            {
                self.cleanup_unconfirmed.store(true, Ordering::SeqCst);
                self.quota_cache.degrade_all();
                let _ = directory.keep();
                return Err(fail("cleanup_unconfirmed"));
            }
            let verified = result?;
            self.accepting()?;
            if cancelled.load(Ordering::SeqCst) {
                return Err(fail("login_cancelled"));
            }
            Ok(verified)
        })();
        if let Ok(mut attempts) = self.attempts.lock() {
            if let Some(a) = attempts.get_mut(id) {
                match result {
                    Ok(v)
                        if !cancelled.load(Ordering::SeqCst)
                            && !self.exiting.load(Ordering::SeqCst) =>
                    {
                        a.verified = Some(v);
                        a.dto.phase = "verified";
                        a.expires_at = now() + 120;
                    }
                    Ok(_) => {
                        a.dto.phase = "cancelled";
                        a.dto.error_code = Some("login_cancelled");
                    }
                    Err(e) => {
                        a.dto.phase = if cancelled.load(Ordering::SeqCst) {
                            "cancelled"
                        } else {
                            "failed"
                        };
                        a.dto.error_code = Some(e.code);
                    }
                }
            }
        }
    }
    pub fn get_claude_subscription_login(&self, id: &str) -> AccountResult<ClaudeLoginAttemptDto> {
        self.expire()?;
        self.attempts
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?
            .get(id)
            .map(|a| a.dto.clone())
            .ok_or_else(|| fail("login_attempt_not_found"))
    }
    pub fn cancel_claude_subscription_login(
        &self,
        id: &str,
    ) -> AccountResult<ClaudeLoginAttemptDto> {
        let mut attempts = self
            .attempts
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?;
        let a = attempts
            .get_mut(id)
            .ok_or_else(|| fail("login_attempt_not_found"))?;
        a.cancelled.store(true, Ordering::SeqCst);
        a.verified = None;
        if matches!(
            a.dto.phase,
            "starting" | "waiting" | "verifying" | "cancelling"
        ) {
            a.dto.phase = "cancelling"
        } else {
            a.dto.phase = "cancelled"
        }
        Ok(a.dto.clone())
    }
    pub fn capture_claude_subscription(
        &self,
        label: String,
        attempt_id: Option<&str>,
    ) -> AccountResult<ClaudeSubscriptionDto> {
        self.retry_pending_recovery()?;
        let _op = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.recovered()?;
        self.no_other_operation()?;
        self.quota_cache.degrade_all();
        crate::profiles::validate_label(&label).map_err(|_| fail("invalid_label"))?;
        self.runtime.validate_environment()?;
        let lease = self.maintenance("claude-capture")?;
        let target = Target::read(&self.paths)?;
        target.validate()?;
        let locks = if attempt_id.is_none() {
            Some(MutationLocks::acquire(&self.paths, &target)?)
        } else {
            None
        };
        let selected = if let Some(id) = attempt_id {
            self.attempts
                .lock()
                .map_err(|_| fail("account_state_unavailable"))?
                .get(id)
                .filter(|a| {
                    a.dto.phase == "verified"
                        && a.expires_at > now()
                        && !a.cancelled.load(Ordering::SeqCst)
                })
                .and_then(|a| a.verified.clone())
                .ok_or_else(|| fail("claude_login_attempt_unavailable"))?
                .0
        } else {
            self.runtime
                .verify(
                    target
                        .credential
                        .as_deref()
                        .ok_or_else(|| fail("claude_login_required"))?,
                    &target.account()?,
                )?
                .0
        };
        let verified = self
            .runtime
            .verify(&selected.bytes, &selected.oauth_account)?
            .0;
        if verified.identity.fingerprint() != selected.identity.fingerprint() {
            return Err(fail("claude_identity_mismatch"));
        }
        if let Some(locks) = &locks {
            locks.verify()?;
        }
        lease.recheck()?;
        self.runtime.require_system_idle()?;
        self.accepting()?;
        if Target::read(&self.paths)? != target {
            return Err(fail("target_changed"));
        }
        let fingerprint = verified.identity.fingerprint();
        let mut store = self.store()?;
        let existing = store
            .vault
            .records
            .iter()
            .find(|r| r.credential.identity.fingerprint() == fingerprint)
            .map(|r| r.id.clone());
        let id = if let Some(id) = existing {
            if store.vault.record(&id)?.source.is_some() {
                return Err(fail("claude_swap_reference_exists"));
            }
            if let Some(pending) = store.vault.refresh.get(&id) {
                let token = identity::oauth(&verified.bytes, false)?;
                let refresh = token
                    .get("refreshToken")
                    .and_then(|v| identity::text(v, 32768));
                let successor = pending.successor.as_ref().is_some_and(|b| {
                    identity::object(b).ok() == identity::object(&verified.bytes).ok()
                });
                let successor_refresh = pending
                    .successor
                    .as_ref()
                    .and_then(|v| identity::oauth(v, true).ok())
                    .and_then(|v| v["refreshToken"].as_str().map(str::to_owned));
                let independent = refresh.is_some_and(|r| {
                    identity::digest(r.as_bytes()) != pending.pending_digest
                        && Some(r) != successor_refresh.as_deref()
                });
                if !successor && !independent {
                    return Err(fail("claude_reauthentication_required"));
                }
            }
            let record = store.vault.record_mut(&id)?;
            let mut next = verified;
            if next.bytes == record.credential.bytes {
                next.generation = record.credential.generation.clone();
            }
            record.credential = next;
            record.revision += 1;
            store.vault.refresh.remove(&id);
            id
        } else {
            if store.vault.records.len() >= 64 {
                return Err(fail("account_limit"));
            }
            if store
                .vault
                .records
                .iter()
                .any(|r| r.label.eq_ignore_ascii_case(&label))
            {
                return Err(fail("duplicate_label"));
            }
            let id = nonce()?;
            store.vault.records.push(Record {
                id: id.clone(),
                label,
                remark: None,
                revision: 1,
                credential: verified,
                source: None,
                source_snapshot: None,
                source_error: None,
            });
            id
        };
        if attempt_id.is_none() {
            store.vault.active = Some(active_proof(&id, &fingerprint, &target)?);
        }
        self.accepting()?;
        self.quota_cache.invalidate(&id);
        store.save()?;
        drop(store);
        if let Some(attempt) = attempt_id {
            if let Ok(mut attempts) = self.attempts.lock() {
                if let Some(a) = attempts.get_mut(attempt) {
                    a.verified = None;
                    a.dto.phase = "saved";
                }
            }
        }
        self.list_claude_subscriptions()?
            .into_iter()
            .find(|r| r.id == id)
            .ok_or_else(|| fail("account_not_found"))
    }
    /// The pending record is durable before a rotating grant is consumed. A
    /// lost response never permits retrying that old grant on a later attempt.
    fn verified_saved(&self, id: &str, swap_locks: &cswap::SwapLocks) -> AccountResult<Record> {
        self.quota_cache.invalidate(id);
        let (record, pending) = {
            let store = self.store()?;
            (
                store.vault.record(id)?.clone(),
                store.vault.refresh.get(id).cloned(),
            )
        };
        cswap::check(&self.paths, &record)?;
        let expired = identity::oauth(&record.credential.bytes, false).is_err();
        let mut bytes = record.credential.bytes.clone();
        if expired || pending.is_some() {
            let pending = if let Some(p) = pending {
                p
            } else {
                let token = identity::oauth(&bytes, true)?;
                let refresh = identity::text(&token["refreshToken"], 32768)
                    .ok_or_else(|| fail("claude_reauthentication_required"))?;
                let pending = RefreshRecovery {
                    identity: record.credential.identity.fingerprint(),
                    slot_digest: identity::digest(&bytes),
                    pending_digest: identity::digest(refresh.as_bytes()),
                    successor: None,
                };
                {
                    let mut store = self.store()?;
                    if store.vault.record(id)?.revision != record.revision
                        || store.vault.record(id)?.source_snapshot != record.source_snapshot
                    {
                        return Err(fail("account_changed"));
                    }
                    store.vault.refresh.insert(id.into(), pending.clone());
                    self.accepting()?;
                    store.save()?;
                }
                let successor = self
                    .runtime
                    .refresh(&bytes)
                    .map_err(|_| fail("claude_reauthentication_required"))?;
                // Save a successful reply before cancellation or profile checks.
                let mut store = self.store()?;
                let current = store
                    .vault
                    .refresh
                    .get_mut(id)
                    .ok_or_else(|| fail("claude_reauthentication_required"))?;
                if current.pending_digest != pending.pending_digest || current.successor.is_some() {
                    return Err(fail("account_changed"));
                }
                current.successor = Some(successor);
                store.save()?;
                store.vault.refresh.get(id).unwrap().clone()
            };
            if pending.identity != record.credential.identity.fingerprint()
                || (pending.slot_digest != identity::digest(&record.credential.bytes)
                    && !(record.source.is_some()
                        && pending.successor.as_ref() == Some(&record.credential.bytes)))
            {
                return Err(fail("claude_reauthentication_required"));
            }
            bytes = pending
                .successor
                .ok_or_else(|| fail("claude_reauthentication_required"))?;
        }
        let mut verified = self
            .runtime
            .verify(&bytes, &record.credential.oauth_account)?
            .0;
        if verified.identity.fingerprint() != record.credential.identity.fingerprint() {
            return Err(fail("claude_identity_mismatch"));
        }
        if verified.bytes != bytes {
            return Err(fail("claude_credentials_changed"));
        }
        let mut store = self.store()?;
        if store.vault.record(id)?.revision != record.revision
            || store.vault.record(id)?.source_snapshot != record.source_snapshot
        {
            return Err(fail("account_changed"));
        }
        if verified.bytes == record.credential.bytes {
            verified.generation = record.credential.generation;
        }
        let updated = store.vault.record_mut(id)?;
        cswap::write_back(&self.paths, updated, &verified.bytes, swap_locks)?;
        if updated.source.is_some() {
            verified.generation = identity::digest(&verified.bytes)[..32].into();
        }
        updated.credential = verified;
        updated.revision += 1;
        let result = updated.clone();
        store.vault.refresh.remove(id);
        self.accepting()?;
        store.save()?;
        Ok(result)
    }
    pub fn prepare_claude_subscription_switch(
        self: &Arc<Self>,
        account_id: String,
    ) -> AccountResult<PreparedSwitchDto> {
        self.retry_pending_recovery()?;
        let result = self.prepare(&account_id);
        if let Ok(dto) = &result {
            if dto.phase == "ready" {
                let weak = Arc::downgrade(self);
                let ticket = dto.ticket.clone().unwrap();
                if std::thread::Builder::new()
                    .name("claude-switch-expiry".into())
                    .spawn(move || {
                        std::thread::sleep(std::time::Duration::from_secs(31));
                        if let Some(manager) = weak.upgrade() {
                            if let Ok(mut tickets) = manager.tickets.lock() {
                                tickets.remove(&ticket);
                            }
                        }
                    })
                    .is_err()
                {
                    self.tickets
                        .lock()
                        .map_err(|_| fail("account_state_unavailable"))?
                        .remove(dto.ticket.as_ref().unwrap());
                    return Err(fail("switch_unavailable"));
                }
            }
        }
        result
    }
    fn prepare(&self, id: &str) -> AccountResult<PreparedSwitchDto> {
        let _op = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.recovered()?;
        self.no_other_operation()?;
        self.quota_cache.degrade_all();
        self.runtime.validate_environment()?;
        let lease = self.maintenance(id)?;
        let before = Target::read(&self.paths)?;
        before.validate()?;
        let source_identity = identity::Identity::from_account(&before.account()?)?.fingerprint();
        // Same order as claude-swap: consumption locks, its global lock, then
        // the official CLI mutation locks. Keep these through confirmation.
        let swap_locks = {
            let store = self.store()?;
            cswap::SwapLocks::acquire(
                &self.paths,
                store
                    .vault
                    .records
                    .iter()
                    .filter(|r| {
                        r.id == id || r.credential.identity.fingerprint() == source_identity
                    })
                    .filter_map(|r| r.source.clone()),
            )?
        };
        let locks = MutationLocks::acquire(&self.paths, &before)?;
        let source_record = {
            let store = self.store()?;
            store
                .vault
                .records
                .iter()
                .find(|r| r.credential.identity.fingerprint() == source_identity)
                .cloned()
                .ok_or_else(|| fail("claude_current_account_not_saved"))?
        };
        cswap::check(&self.paths, &source_record)?;
        let source = self
            .runtime
            .verify(
                before
                    .credential
                    .as_deref()
                    .ok_or_else(|| fail("claude_login_required"))?,
                &before.account()?,
            )?
            .0;
        if source.identity.fingerprint() != source_record.credential.identity.fingerprint() {
            return Err(fail("claude_identity_mismatch"));
        }
        let source_id = source_record.id.clone();
        if source_id == id {
            return Ok(PreparedSwitchDto {
                account_id: id.into(),
                ticket: None,
                phase: "already_current",
                reason_code: Some("already_current"),
                expires_at: None,
            });
        }
        let record = self.verified_saved(id, &swap_locks)?;
        locks.verify()?;
        lease.recheck()?;
        self.runtime.require_system_idle()?;
        self.accepting()?;
        if Target::read(&self.paths)? != before {
            return Err(fail("target_changed"));
        }
        let vault_revision = {
            let mut store = self.store()?;
            if store.vault.refresh.contains_key(&source_id) {
                return Err(fail("claude_reauthentication_required"));
            }
            let current = store.vault.record_mut(&source_id)?;
            if current.revision != source_record.revision
                || current.source_snapshot != source_record.source_snapshot
            {
                return Err(fail("account_changed"));
            }
            let mut source = source;
            cswap::write_back(&self.paths, current, &source.bytes, &swap_locks)?;
            if current.credential.bytes == source.bytes {
                source.generation = current.credential.generation.clone();
            }
            current.credential = source;
            current.revision += 1;
            self.quota_cache.invalidate(&source_id);
            store.save()?;
            store.vault.revision
        };
        let swap_records = self
            .store()?
            .vault
            .records
            .into_iter()
            .filter(|r| r.source.is_some() && (r.id == id || r.id == source_id))
            .collect();
        let written = before.merged(&record.credential)?;
        let expires_at = now() + 30;
        let ticket = nonce()?;
        self.accepting()?;
        self.tickets
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?
            .insert(
                ticket.clone(),
                Ticket {
                    account_id: id.into(),
                    vault_revision,
                    record,
                    before,
                    written,
                    lease,
                    locks,
                    swap_locks,
                    swap_records,
                    expires_at,
                },
            );
        Ok(PreparedSwitchDto {
            account_id: id.into(),
            ticket: Some(ticket),
            phase: "ready",
            reason_code: None,
            expires_at: Some(expires_at),
        })
    }
    pub fn cancel_claude_subscription_switch(
        &self,
        ticket: &str,
    ) -> AccountResult<AccountOperationDto> {
        let ticket = self
            .tickets
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?
            .remove(ticket)
            .ok_or_else(|| fail("switch_ticket_invalid"))?;
        Ok(AccountOperationDto {
            account_id: ticket.account_id,
            phase: "cancelled",
            error_code: None,
        })
    }
    pub fn commit_claude_subscription_switch(
        &self,
        ticket: &str,
    ) -> AccountResult<AccountOperationDto> {
        let _op = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.recovered()?;
        self.quota_cache.degrade_all();
        let ticket = self
            .tickets
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?
            .remove(ticket)
            .ok_or_else(|| fail("switch_ticket_invalid"))?;
        if ticket.expires_at <= now() {
            return Err(fail("switch_ticket_expired"));
        }
        let validate_sources = || -> AccountResult<()> {
            ticket.swap_locks.verify()?;
            cswap::check(&self.paths, &ticket.record)?;
            for record in &ticket.swap_records {
                cswap::check(&self.paths, record)?;
            }
            Ok(())
        };
        let validate = || -> AccountResult<()> {
            self.accepting()?;
            ticket.lease.recheck()?;
            ticket.locks.verify()?;
            validate_sources()?;
            self.runtime.require_system_idle()?;
            self.runtime.validate_environment()?;
            if Target::read(&self.paths)? != ticket.before {
                return Err(fail("target_changed"));
            }
            Ok(())
        };
        validate()?;
        identity::oauth(&ticket.record.credential.bytes, false)?;
        let mut store = self.store()?;
        if store.vault.revision != ticket.vault_revision
            || store.vault.record(&ticket.account_id)?.revision != ticket.record.revision
        {
            return Err(fail("account_changed"));
        }
        let journal = Journal {
            schema: 1,
            account_id: ticket.account_id.clone(),
            before: ticket.before.clone(),
            written: ticket.written.clone(),
            identity: ticket.record.credential.identity.fingerprint(),
        };
        storage::save_journal(&self.paths, self.protector.as_ref(), &journal)?;
        if let Err(e) = validate() {
            if Target::read(&self.paths)? == ticket.before {
                storage::clear_journal(&self.paths)?;
            }
            return Err(e);
        }
        let result = (|| {
            self.accepting()?;
            super::super::storage::atomic_write(
                &self.paths.live_directory.join(".credentials.json"),
                ticket.written.credential.as_ref().unwrap(),
            )?;
            let mut partial = ticket.before.clone();
            partial.credential = ticket.written.credential.clone();
            if Target::read(&self.paths)? != partial {
                return Err(fail("target_changed"));
            }
            ticket.locks.verify()?;
            validate_sources()?;
            ticket.lease.recheck()?;
            self.runtime.require_system_idle()?;
            self.accepting()?;
            super::super::storage::atomic_write(
                &ticket.before.config_path(&self.paths),
                ticket.written.config().unwrap(),
            )?;
            if Target::read(&self.paths)? != ticket.written {
                return Err(fail("target_changed"));
            }
            let verified = self
                .runtime
                .verify(
                    ticket.written.credential.as_ref().unwrap(),
                    &ticket.record.credential.oauth_account,
                )?
                .0;
            if verified.identity.fingerprint() != journal.identity
                || verified.bytes != *ticket.written.credential.as_ref().unwrap()
            {
                return Err(fail("claude_identity_mismatch"));
            }
            ticket.locks.verify()?;
            validate_sources()?;
            ticket.lease.recheck()?;
            self.runtime.require_system_idle()?;
            self.accepting()?;
            if Target::read(&self.paths)? != ticket.written {
                return Err(fail("target_changed"));
            }
            store.vault.active = Some(active_proof(
                &ticket.account_id,
                &journal.identity,
                &ticket.written,
            )?);
            store
                .vault
                .record_mut(&ticket.account_id)?
                .credential
                .observed_at = now();
            store.save()?;
            Ok(())
        })();
        match result {
            Ok(()) => {
                storage::clear_journal(&self.paths)?;
                Ok(AccountOperationDto {
                    account_id: ticket.account_id,
                    phase: "verified",
                    error_code: None,
                })
            }
            Err(error) => {
                if storage::restore(&self.paths, &ticket.before, &ticket.written).is_ok() {
                    storage::clear_journal(&self.paths)?;
                    Err(fail(if error.code == "account_service_exiting" {
                        "account_service_exiting"
                    } else {
                        "claude_switch_rolled_back"
                    }))
                } else {
                    Err(fail("recovery_required"))
                }
            }
        }
    }
    pub fn recover_pending_switch(&self) -> AccountResult<Option<AccountOperationDto>> {
        let _op = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.accepting()?;
        let Some(journal) = storage::read_journal(&self.paths, self.protector.as_ref())? else {
            return Ok(None);
        };
        self.quota_cache.degrade_all();
        let lease = self.maintenance(&journal.account_id)?;
        let current = Target::read(&self.paths)?;
        current.validate()?;
        let locks = MutationLocks::acquire(&self.paths, &current)?;
        locks.verify()?;
        lease.recheck()?;
        let committed = {
            let store = self.store()?;
            store.vault.active.as_ref().is_some_and(|a| {
                a.id == journal.account_id
                    && a.identity == journal.identity
                    && current == journal.written
                    && current
                        .credential
                        .as_ref()
                        .is_some_and(|v| identity::digest(v) == a.credential_digest)
                    && current
                        .config()
                        .is_some_and(|v| identity::digest(v) == a.config_digest)
            })
        };
        let phase = if committed {
            "verified"
        } else {
            storage::restore(&self.paths, &journal.before, &journal.written)?;
            "rolled_back"
        };
        storage::clear_journal(&self.paths)?;
        self.quota_cache.invalidate_all();
        Ok(Some(AccountOperationDto {
            account_id: journal.account_id,
            phase,
            error_code: None,
        }))
    }
    fn retry_pending_recovery(&self) -> AccountResult<()> {
        self.accepting()?;
        if self.paths.journal().exists() {
            self.recover_pending_switch()?;
        }
        Ok(())
    }
    pub fn read_claude_subscription_quota(
        &self,
        id: &str,
    ) -> AccountResult<ClaudeSubscriptionQuotaDto> {
        let mut attempt = None;
        let result = self.read_quota_inner(id, &mut attempt);
        match (&result, attempt) {
            (Ok(value), Some(attempt)) if !self.exiting.load(Ordering::Acquire) => {
                self.quota_cache.finish(attempt, value)
            }
            (Err(error), _)
                if matches!(
                    error.code,
                    "claude_identity_mismatch"
                        | "claude_credentials_changed"
                        | "account_changed"
                        | "account_not_found"
                        | "claude_vault_invalid"
                        | "claude_credentials_invalid"
                ) =>
            {
                self.quota_cache.invalidate(id)
            }
            (Err(error), _) => self.quota_cache.fail_existing(
                id,
                matches!(
                    error.code,
                    "claude_credentials_expired"
                        | "claude_reauthentication_required"
                        | "claude_login_required"
                ),
            ),
            _ => (),
        }
        result
    }
    /// Memory-only historical display receipt; no I/O, refresh, gate or
    /// admission authority. Pair its record revision with the current list.
    pub fn cached_claude_subscription_quota(
        &self,
        id: &str,
    ) -> AccountResult<Option<super::ClaudeQuotaDisplaySnapshot>> {
        if self.exiting.load(Ordering::Acquire) {
            return Err(fail("account_service_exiting"));
        }
        self.quota_cache.snapshot(id)
    }
    fn read_quota_inner(
        &self,
        id: &str,
        attempt: &mut Option<QuotaAttempt>,
    ) -> AccountResult<ClaudeSubscriptionQuotaDto> {
        let _op = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.recovered()?;
        self.no_other_operation()?;
        let record = {
            let store = self.store()?;
            if store.vault.refresh.contains_key(id) {
                return Err(fail("claude_reauthentication_required"));
            }
            store.vault.record(id)?.clone()
        };
        cswap::check(&self.paths, &record)?;
        *attempt = self.quota_cache.begin(quota_scope(&record));
        if let Some(retry) = self
            .store()?
            .vault
            .quota_retry
            .get(id)
            .cloned()
            .filter(|r| r.until > now() && r.identity == record.credential.identity.fingerprint())
        {
            let mut quota = LocalCliQuotaResult::new(
                LocalCliQuotaState::RateLimited,
                chrono::DateTime::from_timestamp(retry.observed_at, 0)
                    .ok_or_else(|| fail("claude_vault_invalid"))?,
                "Anthropic OAuth usage",
                Some("local_cli_rate_limited"),
            );
            quota.masked_identity = record.credential.identity.masked();
            quota.identity_fingerprint = Some(retry.identity);
            return Ok(ClaudeSubscriptionQuotaDto {
                quota,
                server_retry_at: Some(retry.until),
            });
        }
        identity::oauth(&record.credential.bytes, false)?;
        let before = Target::read(&self.paths)?;
        let verified = self
            .runtime
            .verify(&record.credential.bytes, &record.credential.oauth_account)?
            .0;
        if verified.identity.fingerprint() != record.credential.identity.fingerprint() {
            return Err(fail("claude_identity_mismatch"));
        }
        self.accepting()?;
        let response = self.runtime.usage(&record.credential.bytes)?;
        cswap::check(&self.paths, &record)?;
        if Target::read(&self.paths)? != before
            || self.store()?.vault.record(id)?.revision != record.revision
        {
            return Err(fail("claude_credentials_changed"));
        }
        let mut quota = LocalCliQuotaResult::new(
            if response.status == 200 {
                LocalCliQuotaState::Available
            } else if response.status == 429 {
                LocalCliQuotaState::RateLimited
            } else {
                LocalCliQuotaState::Unavailable
            },
            chrono::Utc::now(),
            "Anthropic OAuth usage",
            if response.status == 429 {
                Some("local_cli_rate_limited")
            } else if response.status != 200 {
                Some("local_cli_unavailable")
            } else {
                None
            },
        );
        if response.status == 200 || response.status == 429 {
            quota.masked_identity = verified.identity.masked();
            quota.identity_fingerprint = Some(verified.identity.fingerprint());
        }
        if response.status == 200 {
            quota.plan_label = verified.plan;
            quota.windows = super::parse_claude_usage(&response.body)?;
        }
        let retry = if response.status == 429 {
            response.retry_after.as_deref().and_then(retry_after)
        } else {
            None
        };
        if response.status == 200 || retry.is_some() {
            let mut store = self.store()?;
            if store.vault.record(id)?.revision != record.revision {
                return Err(fail("claude_credentials_changed"));
            }
            if let Some(until) = retry {
                store.vault.quota_retry.insert(
                    id.into(),
                    QuotaRetry {
                        until,
                        observed_at: now(),
                        identity: record.credential.identity.fingerprint(),
                    },
                );
            } else {
                store.vault.quota_retry.remove(id);
            }
            self.accepting()?;
            store.save()?;
        }
        Ok(ClaudeSubscriptionQuotaDto {
            quota,
            server_retry_at: retry,
        })
    }
    pub fn has_inflight_operation(&self) -> bool {
        if self.cleanup_unconfirmed.load(Ordering::SeqCst) {
            return true;
        }
        let Ok(_op) = self.mutation.try_lock() else {
            return true;
        };
        let Ok(attempts) = self.attempts.try_lock() else {
            return true;
        };
        let Ok(tickets) = self.tickets.try_lock() else {
            return true;
        };
        !tickets.is_empty()
            || attempts
                .values()
                .any(|a| a.dto.error_code == Some("cleanup_unconfirmed"))
            || attempts.values().any(|a| {
                matches!(
                    a.dto.phase,
                    "starting" | "waiting" | "verifying" | "cancelling"
                )
            })
    }
    pub fn cancel_inflight_for_exit(&self) {
        self.exiting.store(true, Ordering::SeqCst);
        self.quota_cache.seal();
        if let Ok(mut attempts) = self.attempts.try_lock() {
            for a in attempts.values_mut() {
                a.cancelled.store(true, Ordering::SeqCst);
                a.verified = None;
                if matches!(a.dto.phase, "starting" | "waiting" | "verifying") {
                    a.dto.phase = "cancelling";
                }
            }
        }
    }
}
#[path = "catalog.rs"]
mod catalog;
#[path = "cswap.rs"]
pub(super) mod cswap;
pub use cswap::ClaudeSwapCandidate;
#[path = "open_scope.rs"]
mod open_scope;
pub use open_scope::ClaudeOpenScope;
fn quota_scope(record: &Record) -> QuotaScope {
    QuotaScope {
        id: record.id.clone(),
        revision: record.revision,
        identity: record.credential.identity.fingerprint(),
        generation: record.credential.generation.clone(),
        masked: record.credential.identity.masked(),
    }
}
fn active_proof(id: &str, identity: &str, target: &Target) -> AccountResult<ActiveProof> {
    Ok(ActiveProof {
        id: id.into(),
        identity: identity.into(),
        legacy: target.legacy,
        credential_digest: identity::digest(
            target
                .credential
                .as_deref()
                .ok_or_else(|| fail("claude_login_required"))?,
        ),
        config_digest: identity::digest(
            target
                .config()
                .ok_or_else(|| fail("claude_login_required"))?,
        ),
    })
}
fn retry_after(value: &str) -> Option<i64> {
    let seconds = value.trim().parse::<f64>().ok().or_else(|| {
        chrono::DateTime::parse_from_rfc2822(value)
            .ok()
            .map(|v| (v.timestamp() - now()) as f64)
    })?;
    (seconds.is_finite() && seconds > 0.0 && seconds <= 7.0 * 24.0 * 3600.0)
        .then(|| now() + seconds.ceil() as i64)
}
