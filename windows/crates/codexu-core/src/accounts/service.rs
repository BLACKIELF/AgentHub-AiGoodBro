use super::{
    fail,
    identity::{auth_digest, parse_auth},
    native::DpapiProtector,
    storage::{self, AccountRecord, ActiveProof, StoreGuard, SwitchJournal, TargetSnapshot},
    AccountOccupancyGate, AccountOperationDto, AccountPaths, AccountResult, AccountRuntime,
    CredentialWriteLease, CredentialWritePurpose, LoginAttemptDto, ManagedAccountDto,
    NativeAccountRuntime, PreparedSwitchDto, SecretProtector, SwitchMaintenanceLease,
    VerifiedCredentialSnapshot,
};
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, RwLock,
    },
};
#[path = "browser.rs"]
pub mod browser;
#[path = "hub_snapshot.rs"]
pub mod hub_snapshot;
#[path = "maintenance.rs"]
pub mod maintenance;
#[path = "manual_accounts.rs"]
pub mod manual_accounts;
#[path = "metadata.rs"]
pub mod metadata;
#[path = "registration.rs"]
pub mod registration;

struct Attempt {
    dto: LoginAttemptDto,
    cancelled: Arc<AtomicBool>,
}
struct Ticket {
    account_id: String,
    account_revision: u64,
    generation: String,
    target: TargetSnapshot,
    expires_at: i64,
    lease: Box<dyn SwitchMaintenanceLease>,
    write_lease: Box<dyn CredentialWriteLease>,
}
/// This proof is written only after the matching positive-exit finalize lease,
/// official verification and vault commit. A generic last-import digest does
/// not prove that a particular Desktop writer exited.
#[derive(serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct FinalizedDesktopWriter {
    schema: u32,
    writer: String,
    profile: String,
    identity: String,
    initial_generation: String,
    imported_generation: String,
    marker_digest: String,
    auth_digest: String,
}
const FINALIZED_DESKTOP_CONTEXT: &str = "AiGoodBro.Next.Windows.desktop-finalized-writer.v1";
pub struct AccountManager {
    paths: AccountPaths,
    protector: Arc<dyn SecretProtector>,
    runtime: Arc<dyn AccountRuntime>,
    occupancy: RwLock<Option<Arc<dyn AccountOccupancyGate>>>,
    attempts: Mutex<HashMap<String, Attempt>>,
    tickets: Mutex<HashMap<String, Ticket>>,
    mutation: Mutex<()>,
    login_spawner: Arc<dyn super::AccountLoginSpawner>,
    exiting: AtomicBool,
    cleanup_unconfirmed: AtomicBool,
    first_verified_listener: RwLock<Option<Arc<dyn Fn(&str) + Send + Sync>>>,
}

impl AccountManager {
    /// Pure read evidence, separate from any task/quota or exit authority.
    /// Legacy active records deliberately have no trustworthy establishment
    /// time and are unavailable until a real successful system switch.
    pub fn verified_active_system_scope(&self) -> AccountResult<super::ActiveSystemScope> {
        let _operation = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.active_system_scope_locked()
    }
    fn active_system_scope_locked(&self) -> AccountResult<super::ActiveSystemScope> {
        self.require_accepting()?;
        if self.cleanup_unconfirmed.load(Ordering::Acquire) {
            return Err(fail("cleanup_unconfirmed"));
        }
        {
            let attempts = self
                .attempts
                .try_lock()
                .map_err(|_| fail("account_state_unavailable"))?;
            if attempts
                .values()
                .any(|a| a.dto.error_code == Some("cleanup_unconfirmed"))
            {
                return Err(fail("cleanup_unconfirmed"));
            }
            if attempts.values().any(|a| {
                matches!(
                    a.dto.phase,
                    "starting" | "waiting" | "verifying" | "cancelling"
                )
            }) {
                return Err(fail("login_in_progress"));
            }
        }
        if !self
            .tickets
            .try_lock()
            .map_err(|_| fail("account_state_unavailable"))?
            .is_empty()
        {
            return Err(fail("switch_in_progress"));
        }
        if storage::read_optional(&self.paths.journal(), 16 * 1024 * 1024)?.is_some() {
            return Err(fail("recovery_required"));
        }
        storage::ensure_no_links(&self.paths.system_home)?;
        let target = TargetSnapshot::read(&self.paths.system_home)?;
        self.runtime
            .validate_target_configuration(&self.paths.system_home)?;
        let home = std::fs::canonicalize(&self.paths.system_home)
            .map_err(|_| fail("target_home_unavailable"))?;
        let store = self.store()?;
        let active = store
            .vault
            .active
            .as_ref()
            .ok_or_else(|| fail("active_scope_unverified"))?;
        let established = active
            .established_at_unix_ms
            .filter(|at| {
                *at > 0 && *at <= chrono::Utc::now().timestamp_millis().max(0) as u64 + 300000
            })
            .ok_or_else(|| fail("active_scope_unverified"))?;
        let config = active
            .target_config_digest
            .as_deref()
            .filter(|s| s.len() == 64)
            .ok_or_else(|| fail("active_scope_unverified"))?;
        let record = store.vault.account(&active.account_id)?;
        let credential = record
            .credential
            .as_ref()
            .ok_or_else(|| fail("active_scope_unverified"))?;
        let (identity, expires) = parse_auth(&credential.auth)?;
        if identity != credential.identity
            || expires <= super::now() + 30
            || credential.generation != active.generation
            || auth_digest(&credential.auth) != active.target_digest
            || target
                .auth
                .as_deref()
                .is_none_or(|a| auth_digest(a) != active.target_digest)
            || config != system_config_digest(&target.config)
        {
            return Err(fail("active_scope_changed"));
        }
        storage::ensure_no_links(&self.paths.system_home)?;
        if TargetSnapshot::read(&self.paths.system_home)? != target
            || std::fs::canonicalize(&self.paths.system_home)
                .map_err(|_| fail("target_home_unavailable"))?
                != home
            || storage::read_optional(&self.paths.journal(), 16 * 1024 * 1024)?.is_some()
        {
            return Err(fail("active_scope_changed"));
        }
        self.require_accepting()?;
        if self.cleanup_unconfirmed.load(Ordering::Acquire) {
            return Err(fail("cleanup_unconfirmed"));
        }
        Ok(super::ActiveSystemScope::new(
            home,
            record.id.clone(),
            identity.identity_hash(),
            credential.generation.clone(),
            active.target_digest.clone(),
            config.into(),
            established,
        ))
    }
    pub fn recheck_active_system_scope(
        &self,
        scope: &super::ActiveSystemScope,
    ) -> AccountResult<()> {
        if self.verified_active_system_scope()? != *scope {
            return Err(fail("active_scope_changed"));
        }
        Ok(())
    }
    /// Product constructor. There is no plaintext/fake encryption fallback.
    /// A missing shared maintenance gate intentionally disables switching.
    pub fn native(app_data_dir: PathBuf) -> AccountResult<Arc<Self>> {
        if !cfg!(windows) {
            return Err(fail("windows_required"));
        }
        let home = dirs::home_dir().ok_or_else(|| fail("target_home_unavailable"))?;
        Self::with_components(
            AccountPaths::isolated(
                app_data_dir.join("managed-accounts-v1"),
                home.join(".codex"),
            )?,
            Arc::new(DpapiProtector),
            Arc::new(NativeAccountRuntime::with_selection(
                crate::runtime_setup::SelectionStore::new(&app_data_dir)?,
            )),
            None,
        )
    }
    /// Explicit dependency boundary for isolated tests and native composition.
    pub fn with_components(
        paths: AccountPaths,
        protector: Arc<dyn SecretProtector>,
        runtime: Arc<dyn AccountRuntime>,
        occupancy: Option<Arc<dyn AccountOccupancyGate>>,
    ) -> AccountResult<Arc<Self>> {
        Self::with_components_and_spawner(
            paths,
            protector,
            runtime,
            occupancy,
            Arc::new(super::NativeLoginSpawner),
        )
    }
    pub fn with_components_and_spawner(
        paths: AccountPaths,
        protector: Arc<dyn SecretProtector>,
        runtime: Arc<dyn AccountRuntime>,
        occupancy: Option<Arc<dyn AccountOccupancyGate>>,
        login_spawner: Arc<dyn super::AccountLoginSpawner>,
    ) -> AccountResult<Arc<Self>> {
        let paths = AccountPaths::isolated(paths.vault_root, paths.system_home)?;
        storage::secure_directory(&paths.vault_root)?;
        storage::secure_directory(&paths.staging())?;
        // A corrupt existing vault is not an empty account list.
        let _ = StoreGuard::load(&paths, protector.as_ref())?;
        Ok(Arc::new(Self {
            paths,
            protector,
            runtime,
            occupancy: RwLock::new(occupancy),
            attempts: Mutex::new(HashMap::new()),
            tickets: Mutex::new(HashMap::new()),
            mutation: Mutex::new(()),
            login_spawner,
            exiting: AtomicBool::new(false),
            cleanup_unconfirmed: AtomicBool::new(false),
            first_verified_listener: RwLock::new(None),
        }))
    }
    /// Native composition hook; called once after the first credential commit,
    /// with account/write locks released. Re-login does not reset participation.
    pub fn install_first_verified_listener(
        &self,
        listener: Arc<dyn Fn(&str) + Send + Sync>,
    ) -> AccountResult<()> {
        let mut slot = self
            .first_verified_listener
            .write()
            .map_err(|_| fail("account_state_unavailable"))?;
        if slot.is_some() {
            return Err(fail("account_busy"));
        }
        *slot = Some(listener);
        Ok(())
    }
    pub fn install_occupancy_gate(&self, gate: Arc<dyn AccountOccupancyGate>) -> AccountResult<()> {
        let _operation = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        if !self
            .tickets
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?
            .is_empty()
        {
            return Err(fail("switch_in_progress"));
        }
        *self
            .occupancy
            .write()
            .map_err(|_| fail("occupancy_unknown"))? = Some(gate);
        Ok(())
    }
    fn store(&self) -> AccountResult<StoreGuard<'_>> {
        StoreGuard::load(&self.paths, self.protector.as_ref())
    }
    fn require_recovered(&self) -> AccountResult<()> {
        self.require_accepting()?;
        if self.cleanup_unconfirmed.load(Ordering::SeqCst) {
            return Err(fail("cleanup_unconfirmed"));
        }
        if storage::read_optional(&self.paths.journal(), 16 * 1024 * 1024)?.is_some() {
            return Err(fail("recovery_required"));
        }
        Ok(())
    }
    fn require_accepting(&self) -> AccountResult<()> {
        if self.exiting.load(Ordering::SeqCst) {
            Err(fail("account_service_exiting"))
        } else {
            Ok(())
        }
    }
    fn expire_tickets(&self) -> AccountResult<()> {
        self.tickets
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?
            .retain(|_, ticket| ticket.expires_at > super::now());
        Ok(())
    }
    fn require_no_login(&self) -> AccountResult<()> {
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
        Ok(())
    }
    fn acquire_maintenance(
        &self,
        account: &str,
        operation: &str,
    ) -> AccountResult<Box<dyn SwitchMaintenanceLease>> {
        self.runtime.require_system_idle()?;
        let gate = self
            .occupancy
            .read()
            .map_err(|_| fail("occupancy_unknown"))?
            .clone()
            .ok_or_else(|| fail("occupancy_unknown"))?;
        let lease = gate.acquire_switch_maintenance(account, operation)?;
        lease.recheck()?;
        self.runtime.require_system_idle()?;
        Ok(lease)
    }
    fn credential_write(
        &self,
        id: &str,
        purpose: CredentialWritePurpose,
    ) -> AccountResult<Box<dyn CredentialWriteLease>> {
        let gate = self
            .occupancy
            .read()
            .map_err(|_| fail("occupancy_unknown"))?
            .clone()
            .ok_or_else(|| fail("occupancy_unknown"))?;
        let lease = gate.acquire_credential_write(id, purpose)?;
        lease.recheck()?;
        Ok(lease)
    }
    pub fn list_managed_accounts(&self) -> AccountResult<Vec<ManagedAccountDto>> {
        self.expire_tickets()?;
        let store = self.store()?;
        let recovery_required =
            self.paths.journal().exists() || self.cleanup_unconfirmed.load(Ordering::SeqCst);
        let target = TargetSnapshot::read(&self.paths.system_home).ok();
        let attempts = self
            .attempts
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?;
        let recovery_required = recovery_required
            || attempts
                .values()
                .any(|a| a.dto.error_code == Some("cleanup_unconfirmed"));
        let gate_installed = self
            .occupancy
            .read()
            .map_err(|_| fail("occupancy_unknown"))?
            .is_some();
        Ok(store
            .vault
            .accounts
            .iter()
            .map(|record| {
                let signing_in = attempts.values().any(|a| {
                    a.dto.account_id == record.id
                        && matches!(
                            a.dto.phase,
                            "starting" | "waiting" | "verifying" | "cancelling"
                        )
                });
                let valid = record.credential.as_ref().is_some_and(|c| {
                    parse_auth(&c.auth)
                        .is_ok_and(|(id, expiry)| id == c.identity && expiry > super::now() + 30)
                });
                let active = store.vault.active.as_ref().filter(|proof| {
                    proof.account_id == record.id
                        && record
                            .credential
                            .as_ref()
                            .is_some_and(|c| c.generation == proof.generation)
                });
                let active_state = if recovery_required {
                    "unknown"
                } else if let Some(proof) = active {
                    if target
                        .as_ref()
                        .and_then(|t| t.auth.as_ref())
                        .is_some_and(|a| auth_digest(a) == proof.target_digest)
                    {
                        "verified"
                    } else {
                        "stale"
                    }
                } else {
                    "unknown"
                };
                ManagedAccountDto {
                    registration_pending: store
                        .vault
                        .pending_registrations
                        .contains_key(&record.id),
                    id: record.id.clone(),
                    label: record.display_label().to_owned(),
                    platform: record.platform.clone(),
                    storage_kind: "managed",
                    login_state: if signing_in {
                        "signing_in"
                    } else if valid {
                        "verified"
                    } else if record.credential.is_some() {
                        "needs_reauth"
                    } else {
                        "signed_out"
                    },
                    active_state,
                    masked_identity: record
                        .credential
                        .as_ref()
                        .map(|c| c.identity.masked_identity()),
                    plan_type: record.credential.as_ref().and_then(|c| c.plan.clone()),
                    can_login: self.runtime.available()
                        && gate_installed
                        && !signing_in
                        && !recovery_required,
                    can_switch: valid
                        && !signing_in
                        && !recovery_required
                        && gate_installed
                        && self.runtime.available(),
                    switch_block_reason: if recovery_required {
                        Some("recovery_required")
                    } else if signing_in {
                        Some("login_in_progress")
                    } else if !valid {
                        Some("login_required")
                    } else if !gate_installed {
                        Some("occupancy_unknown")
                    } else if !self.runtime.available() {
                        Some("cli_unavailable")
                    } else {
                        None
                    },
                    revision: record.revision,
                    recovery_required,
                }
            })
            .collect())
    }
    pub fn create_managed_account(
        &self,
        label: String,
        platform: String,
    ) -> AccountResult<ManagedAccountDto> {
        let _operation = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.require_recovered()?;
        if platform != "codex" {
            return Err(fail("platform_not_supported"));
        }
        crate::profiles::validate_label(&label).map_err(|_| fail("invalid_label"))?;
        let id = super::nonce()?;
        {
            let mut store = self.store()?;
            if store.vault.accounts.len() >= 64 {
                return Err(fail("account_limit"));
            }
            if store
                .vault
                .accounts
                .iter()
                .any(|a| a.label.eq_ignore_ascii_case(&label))
            {
                return Err(fail("duplicate_label"));
            }
            store.vault.accounts.push(AccountRecord {
                id: id.clone(),
                label,
                remark: None,
                platform,
                revision: 1,
                credential: None,
                created_at_ms: Some(chrono::Utc::now().timestamp_millis()),
                browser: Default::default(),
            });
            store.save()?;
        }
        self.list_managed_accounts()?
            .into_iter()
            .find(|a| a.id == id)
            .ok_or_else(|| fail("account_not_found"))
    }
    pub fn begin_account_login(
        self: &Arc<Self>,
        account_id: String,
    ) -> AccountResult<LoginAttemptDto> {
        self.retry_pending_recovery()?;
        let _operation = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.require_recovered()?;
        self.require_no_login()?;
        self.expire_tickets()?;
        if !self
            .tickets
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?
            .is_empty()
        {
            return Err(fail("switch_in_progress"));
        }
        if !self.runtime.available() {
            return Err(fail("cli_unavailable"));
        }
        let revision = self.store()?.vault.account(&account_id)?.revision;
        let writer = self.credential_write(&account_id, CredentialWritePurpose::Managed)?;
        let attempt_id = super::nonce()?;
        let dto = LoginAttemptDto {
            attempt_id: attempt_id.clone(),
            account_id: account_id.clone(),
            phase: "starting",
            verification_url: None,
            user_code: None,
            error_code: None,
        };
        let cancelled = Arc::new(AtomicBool::new(false));
        {
            let mut attempts = self
                .attempts
                .lock()
                .map_err(|_| fail("account_state_unavailable"))?;
            if attempts.len() >= 64 {
                attempts.retain(|_, a| {
                    matches!(
                        a.dto.phase,
                        "starting" | "waiting" | "verifying" | "cancelling"
                    )
                });
            }
            attempts.insert(
                attempt_id.clone(),
                Attempt {
                    dto: dto.clone(),
                    cancelled: cancelled.clone(),
                },
            );
        }
        let manager = self.clone();
        let worker_id = attempt_id.clone();
        if self
            .login_spawner
            .spawn(Box::new(move || {
                manager.run_login(&account_id, &worker_id, revision, &cancelled, writer);
            }))
            .is_err()
        {
            self.attempts
                .lock()
                .map_err(|_| fail("account_state_unavailable"))?
                .remove(&attempt_id);
            return Err(fail("login_unavailable"));
        }
        Ok(dto)
    }
    fn update_attempt(&self, attempt_id: &str, update: impl FnOnce(&mut LoginAttemptDto)) {
        if let Ok(mut attempts) = self.attempts.lock() {
            if let Some(attempt) = attempts.get_mut(attempt_id) {
                update(&mut attempt.dto);
            }
        }
    }
    fn run_login(
        &self,
        account_id: &str,
        attempt_id: &str,
        expected_revision: u64,
        cancelled: &AtomicBool,
        writer: Box<dyn CredentialWriteLease>,
    ) {
        let result = (|| {
            self.require_accepting()?;
            let staging = storage::private_tempdir(&self.paths.staging(), "login-")
                .map_err(|_| fail("login_unavailable"))?;
            let mut report = |auth: super::LoginAuthorization| {
                if !cancelled.load(Ordering::SeqCst) {
                    self.update_attempt(attempt_id, |dto| {
                        dto.phase = "waiting";
                        dto.verification_url = Some(auth.verification_url);
                        dto.user_code = Some(auth.user_code);
                    });
                }
            };
            let result = self.runtime.login(staging.path(), cancelled, &mut report);
            if result
                .as_ref()
                .is_err_and(|e| e.code == "cleanup_unconfirmed")
            {
                self.cleanup_unconfirmed.store(true, Ordering::SeqCst);
                let _ = staging.keep();
                return Err(fail("cleanup_unconfirmed"));
            }
            let verified = result?;
            if cancelled.load(Ordering::SeqCst) {
                return Err(fail("login_cancelled"));
            }
            self.update_attempt(attempt_id, |dto| {
                dto.phase = "verifying";
                dto.user_code = None;
                dto.verification_url = None;
            });
            let _operation = self
                .mutation
                .lock()
                .map_err(|_| fail("account_state_unavailable"))?;
            self.require_recovered()?;
            let mut store = self.store()?;
            if store.vault.accounts.iter().any(|record| {
                record.id != account_id
                    && record
                        .credential
                        .as_ref()
                        .is_some_and(|c| c.identity == verified.identity)
            }) {
                return Err(fail("account_already_exists"));
            }
            let record = store.vault.account_mut(account_id)?;
            if record.revision != expected_revision {
                return Err(fail("account_changed"));
            }
            if record
                .credential
                .as_ref()
                .is_some_and(|old| old.identity != verified.identity)
            {
                return Err(fail("identity_mismatch"));
            }
            if cancelled.load(Ordering::SeqCst) {
                return Err(fail("login_cancelled"));
            }
            record.revision = record
                .revision
                .checked_add(1)
                .ok_or_else(|| fail("vault_invalid"))?;
            let first_verified = record.credential.is_none();
            let registration_identity = verified.identity.identity_hash();
            record.credential = Some(verified.into_stored(super::nonce()?));
            if first_verified {
                store.vault.pending_registrations.insert(
                    account_id.to_owned(),
                    storage::RegistrationIntent {
                        identity_hash: registration_identity,
                        planned_profile_id: None,
                    },
                );
            }
            self.require_accepting()?;
            writer.recheck()?;
            store.save()?;
            Ok(first_verified)
        })();
        let first_verified = matches!(result, Ok(true));
        // Registration reads the committed credential through the shared gate;
        // release this writer before invoking the native completion listener.
        drop(writer);
        // Runtime has confirmed child cleanup before returning. TempDir is now gone.
        self.update_attempt(attempt_id, |dto| {
            dto.verification_url = None;
            dto.user_code = None;
            match result {
                Ok(_) => {
                    dto.phase = "verified";
                    dto.error_code = None;
                }
                Err(error) => {
                    dto.phase = if error.code == "login_cancelled" {
                        "cancelled"
                    } else {
                        "failed"
                    };
                    dto.error_code = Some(error.code);
                }
            }
        });
        if first_verified {
            let listener = self
                .first_verified_listener
                .read()
                .ok()
                .and_then(|slot| slot.clone());
            if let Some(listener) = listener {
                listener(account_id);
            }
        }
    }
    pub fn get_login_attempt(&self, id: &str) -> AccountResult<LoginAttemptDto> {
        self.attempts
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?
            .get(id)
            .map(|a| a.dto.clone())
            .ok_or_else(|| fail("login_attempt_not_found"))
    }
    pub fn cancel_account_login(&self, id: &str) -> AccountResult<LoginAttemptDto> {
        let mut attempts = self
            .attempts
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?;
        let attempt = attempts
            .get_mut(id)
            .ok_or_else(|| fail("login_attempt_not_found"))?;
        if matches!(
            attempt.dto.phase,
            "starting" | "waiting" | "verifying" | "cancelling"
        ) {
            attempt.cancelled.store(true, Ordering::SeqCst);
            attempt.dto.phase = "cancelling";
            attempt.dto.user_code = None;
            attempt.dto.verification_url = None;
        }
        Ok(attempt.dto.clone())
    }
    /// Resolve a current pairing attempt to the one supported official page.
    /// The WebView supplies only an opaque attempt ID, never a URL or command.
    pub fn account_login_page(&self, id: &str) -> AccountResult<&'static str> {
        self.require_accepting()?;
        let attempts = self
            .attempts
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?;
        let attempt = attempts
            .get(id)
            .ok_or_else(|| fail("login_attempt_not_found"))?;
        if attempt.cancelled.load(Ordering::SeqCst)
            || attempt.dto.phase != "waiting"
            || attempt.dto.verification_url.as_deref()
                != Some("https://auth.openai.com/codex/device")
            || attempt.dto.user_code.is_none()
        {
            return Err(fail("login_page_unavailable"));
        }
        Ok("https://auth.openai.com/codex/device")
    }
    pub fn prepare_account_switch(
        self: &Arc<Self>,
        account_id: String,
    ) -> AccountResult<PreparedSwitchDto> {
        self.retry_pending_recovery()?;
        let result = self.prepare_switch(&account_id, None, None);
        self.finish_preparation(account_id, result)
    }
    /// Native automatic policy retains its exact shared exclusion reservation
    /// from before graceful close until commit/rollback. It cannot reacquire a
    /// different operation between those phases.
    pub fn prepare_account_switch_in_operation(
        self: &Arc<Self>,
        account_id: &str,
        lease: &crate::managed_proxy::AutomaticMaintenanceLease,
        guard: &dyn super::SwitchCommitGuard,
    ) -> AccountResult<PreparedSwitchDto> {
        lease.recheck()?;
        guard.recheck()?;
        let result = self.prepare_switch(account_id, Some(lease), Some(guard));
        self.finish_preparation(account_id.to_owned(), result)
    }
    fn finish_preparation(
        self: &Arc<Self>,
        account_id: String,
        result: AccountResult<PreparedSwitchDto>,
    ) -> AccountResult<PreparedSwitchDto> {
        match result {
            Ok(dto) => {
                let manager = Arc::downgrade(self);
                let id = dto
                    .ticket
                    .clone()
                    .ok_or_else(|| fail("switch_ticket_invalid"))?;
                if std::thread::Builder::new()
                    .name("managed-switch-expiry".into())
                    .spawn(move || {
                        std::thread::sleep(std::time::Duration::from_secs(31));
                        if let Some(manager) = manager.upgrade() {
                            if let Ok(mut tickets) = manager.tickets.lock() {
                                tickets.remove(&id);
                            }
                        }
                    })
                    .is_err()
                {
                    if let Some(id) = &dto.ticket {
                        self.tickets
                            .lock()
                            .map_err(|_| fail("account_state_unavailable"))?
                            .remove(id);
                    }
                    return Err(fail("switch_unavailable"));
                }
                Ok(dto)
            }
            Err(error) => Ok(PreparedSwitchDto {
                account_id,
                ticket: None,
                phase: "blocked",
                reason_code: Some(error.code),
                expires_at: None,
            }),
        }
    }
    fn prepare_switch(
        &self,
        account_id: &str,
        automatic: Option<&crate::managed_proxy::AutomaticMaintenanceLease>,
        guard: Option<&dyn super::SwitchCommitGuard>,
    ) -> AccountResult<PreparedSwitchDto> {
        let policy = || guard.map_or(Ok(()), |guard| guard.recheck());
        let _operation = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.require_recovered()?;
        self.require_no_login()?;
        self.expire_tickets()?;
        if !self
            .tickets
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?
            .is_empty()
        {
            return Err(fail("switch_in_progress"));
        }
        policy()?;
        let (operation_id, lease, write_lease) = if let Some(automatic) = automatic {
            if self.active_system_scope_locked()? != *automatic.source_scope() {
                return Err(fail("active_scope_changed"));
            }
            self.runtime.require_system_idle()?;
            let gate = self
                .occupancy
                .read()
                .map_err(|_| fail("occupancy_unknown"))?
                .clone()
                .ok_or_else(|| fail("occupancy_unknown"))?;
            let lease = gate.adopt_automatic_maintenance(automatic, account_id)?;
            let writer = gate.acquire_automatic_credential_write(automatic, account_id)?;
            (automatic.operation_id().to_owned(), lease, writer)
        } else {
            let id = super::nonce()?;
            let lease = self.acquire_maintenance(account_id, &id)?;
            let writer = self.credential_write(account_id, CredentialWritePurpose::Managed)?;
            (id, lease, writer)
        };
        let target = TargetSnapshot::read(&self.paths.system_home)?;
        self.runtime
            .validate_target_configuration(&self.paths.system_home)?;
        let (revision, credential) = {
            let store = self.store()?;
            let record = store.vault.account(account_id)?;
            (
                record.revision,
                record
                    .credential
                    .clone()
                    .ok_or_else(|| fail("login_required"))?,
            )
        };
        if automatic.is_some_and(|lease| {
            credential.identity.identity_hash() != lease.target_identity_hash()
        }) {
            return Err(fail("account_changed"));
        }
        policy()?;
        let staging = storage::private_tempdir(&self.paths.staging(), "verify-")
            .map_err(|_| fail("verification_unavailable"))?;
        storage::atomic_write(&staging.path().join("auth.json"), &credential.auth)?;
        let result = if let Some(guard) = guard {
            self.runtime
                .verify_in_operation(staging.path(), &credential.identity, guard)
        } else {
            self.runtime.verify(staging.path(), &credential.identity)
        };
        if result
            .as_ref()
            .is_err_and(|e| e.code == "cleanup_unconfirmed")
        {
            self.cleanup_unconfirmed.store(true, Ordering::SeqCst);
            let _ = staging.keep();
            return Err(fail("cleanup_unconfirmed"));
        }
        let verified = result?;
        if verified.identity != credential.identity {
            return Err(fail("identity_mismatch"));
        }
        lease.recheck()?;
        write_lease.recheck()?;
        policy()?;
        self.runtime.require_system_idle()?;
        if TargetSnapshot::read(&self.paths.system_home)? != target {
            return Err(fail("target_changed"));
        }
        let mut store = self.store()?;
        let record = store.vault.account_mut(account_id)?;
        if record.revision != revision {
            return Err(fail("account_changed"));
        }
        let generation = if credential.auth == verified.auth {
            credential.generation
        } else {
            super::nonce()?
        };
        record.credential = Some(verified.into_stored(generation.clone()));
        record.revision = record
            .revision
            .checked_add(1)
            .ok_or_else(|| fail("vault_invalid"))?;
        let revision = record.revision;
        self.require_accepting()?;
        policy()?;
        store.save()?;
        self.require_accepting()?;
        let expires_at = super::now() + 30;
        self.tickets
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?
            .insert(
                operation_id.clone(),
                Ticket {
                    account_id: account_id.to_owned(),
                    account_revision: revision,
                    generation,
                    target,
                    expires_at,
                    lease,
                    write_lease,
                },
            );
        Ok(PreparedSwitchDto {
            account_id: account_id.to_owned(),
            ticket: Some(operation_id),
            phase: "ready",
            reason_code: None,
            expires_at: Some(expires_at),
        })
    }
    pub fn cancel_account_switch(&self, ticket: &str) -> AccountResult<AccountOperationDto> {
        let value = self
            .tickets
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?
            .remove(ticket)
            .ok_or_else(|| fail("switch_ticket_invalid"))?;
        Ok(AccountOperationDto {
            account_id: value.account_id,
            phase: "cancelled",
            error_code: None,
        })
    }
    pub fn commit_account_switch(&self, ticket: &str) -> AccountResult<AccountOperationDto> {
        struct ManualGuard;
        impl super::SwitchCommitGuard for ManualGuard {
            fn recheck(&self) -> AccountResult<()> {
                Ok(())
            }
        }
        self.commit_account_switch_guarded(ticket, &ManualGuard)
    }
    pub fn commit_account_switch_guarded(
        &self,
        ticket: &str,
        guard: &dyn super::SwitchCommitGuard,
    ) -> AccountResult<AccountOperationDto> {
        let policy = || guard.recheck().map_err(|_| fail("switch_cancelled"));
        let _operation = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.require_recovered()?;
        self.require_no_login()?;
        let ticket = self
            .tickets
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?
            .remove(ticket)
            .ok_or_else(|| fail("switch_ticket_invalid"))?;
        if ticket.expires_at <= super::now() {
            return Err(fail("switch_ticket_expired"));
        }
        policy()?;
        ticket.lease.recheck()?;
        ticket.write_lease.recheck()?;
        self.runtime.require_system_idle()?;
        let mut store = self.store()?;
        let record = store.vault.account(&ticket.account_id)?;
        let record_before = record.clone();
        let credential = record
            .credential
            .clone()
            .ok_or_else(|| fail("login_required"))?;
        if record.revision != ticket.account_revision || credential.generation != ticket.generation
        {
            return Err(fail("account_changed"));
        }
        self.runtime
            .validate_target_configuration(&self.paths.system_home)?;
        if TargetSnapshot::read(&self.paths.system_home)? != ticket.target {
            return Err(fail("target_changed"));
        }
        let mut journal = SwitchJournal {
            schema_version: 1,
            account_id: ticket.account_id.clone(),
            generation: credential.generation.clone(),
            before: ticket.target,
            written_auth: credential.auth.clone(),
            verified_rotation: None,
            verification_started: false,
            expected_revision: Some(record_before.revision),
        };
        let active_before = store.vault.active.clone();
        storage::save_journal(&self.paths, self.protector.as_ref(), &journal)?;
        // A final gate after durable intent, before the first target mutation.
        let prewrite = ticket
            .lease
            .recheck()
            .and_then(|_| ticket.write_lease.recheck())
            .and_then(|_| self.runtime.require_system_idle())
            .and_then(|_| policy());
        if let Err(error) = prewrite {
            if TargetSnapshot::read(&self.paths.system_home)? == journal.before {
                storage::clear_journal(&self.paths)?;
            }
            return Err(error);
        }
        if TargetSnapshot::read(&self.paths.system_home)? != journal.before {
            storage::clear_journal(&self.paths)?;
            return Err(fail("target_changed"));
        }
        let mut rotation_journal_durable = false;
        let result = (|| {
            self.require_accepting()?;
            policy()?;
            storage::atomic_write(&self.paths.system_home.join("auth.json"), &credential.auth)?;
            if TargetSnapshot::read(&self.paths.system_home)?
                .auth
                .as_deref()
                != Some(&credential.auth)
            {
                return Err(fail("target_changed"));
            }
            ticket.lease.recheck()?;
            ticket.write_lease.recheck()?;
            self.runtime.require_system_idle()?;
            journal.verification_started = true;
            storage::save_journal(&self.paths, self.protector.as_ref(), &journal)?;
            let verified = if guard.verification_process_permit().is_some() {
                self.runtime.verify_in_operation(
                    &self.paths.system_home,
                    &credential.identity,
                    guard,
                )?
            } else {
                self.runtime
                    .verify(&self.paths.system_home, &credential.identity)?
            };
            if verified.identity != credential.identity {
                return Err(fail("identity_mismatch"));
            }
            let current = TargetSnapshot::read(&self.paths.system_home)?;
            if current.auth.as_deref() != Some(&verified.auth)
                || current.config != journal.before.config
            {
                return Err(fail("target_changed"));
            }
            let generation = if verified.auth == credential.auth {
                credential.generation.clone()
            } else {
                super::nonce()?
            };
            if verified.auth != journal.written_auth {
                journal.written_auth = verified.auth.clone();
                journal.verified_rotation = Some(storage::VerifiedSwitchRotation {
                    revision: record_before.revision,
                    previous_auth_digest: auth_digest(&credential.auth),
                    credential: super::identity::StoredCredential {
                        auth: verified.auth.clone(),
                        identity: verified.identity.clone(),
                        observed_at: verified.observed_at,
                        quota: verified.quota.clone(),
                        plan: verified.plan.clone(),
                        generation: generation.clone(),
                    },
                });
                storage::save_journal(&self.paths, self.protector.as_ref(), &journal)?;
                rotation_journal_durable = true;
            }
            // Official verification may rotate a grant. Preserve those exact
            // owned bytes in durable intent before a policy cancellation can
            // request rollback; never overwrite an unknown external writer.
            policy()?;
            ticket.lease.recheck()?;
            self.runtime.require_system_idle()?;
            let digest = auth_digest(&verified.auth);
            let record = store.vault.account_mut(&ticket.account_id)?;
            record.credential = Some(verified.into_stored(generation.clone()));
            record.revision = record
                .revision
                .checked_add(1)
                .ok_or_else(|| fail("vault_invalid"))?;
            store.vault.active = Some(ActiveProof {
                account_id: ticket.account_id.clone(),
                generation,
                target_digest: digest,
                established_at_unix_ms: Some(
                    u64::try_from(chrono::Utc::now().timestamp_millis())
                        .map_err(|_| fail("clock_unavailable"))?,
                ),
                target_config_digest: Some(system_config_digest(&journal.before.config)),
            });
            self.require_accepting()?;
            ticket.write_lease.recheck()?;
            policy()?;
            store.save()?;
            Ok(())
        })();
        if let Err(error) = result {
            if error.code == "cleanup_unconfirmed" {
                self.cleanup_unconfirmed.store(true, Ordering::SeqCst);
                return Err(fail("recovery_required"));
            }
            let rotation_preserved = if journal.verified_rotation.is_some() {
                *store.vault.account_mut(&ticket.account_id)? = record_before;
                store.vault.active = active_before;
                ticket
                    .write_lease
                    .recheck()
                    .and_then(|_| Self::preserve_switch_rotation(&mut store, &journal))
                    .is_ok()
            } else {
                true
            };
            // If encryption failed before either durable copy of the verified
            // successor exists, keep it in the owned target; never roll back
            // and discard the only surviving rotating grant.
            if !rotation_preserved && !rotation_journal_durable {
                return Err(fail("recovery_required"));
            }
            // Never restore over an external writer. Retain encrypted intent if
            // rollback cannot be positively confirmed; startup recovery is gated.
            if TargetSnapshot::read(&self.paths.system_home)
                .is_ok_and(|current| current == journal.before)
                || storage::restore_owned(
                    &self.paths.system_home,
                    &journal.written_auth,
                    &journal.before,
                )
                .is_ok()
            {
                if !rotation_preserved {
                    return Err(fail("recovery_required"));
                }
                storage::clear_journal(&self.paths)?;
                return Err(error);
            }
            return Err(fail("recovery_required"));
        }
        storage::clear_journal(&self.paths)?;
        Ok(AccountOperationDto {
            account_id: ticket.account_id,
            phase: "committed",
            error_code: None,
        })
    }
    /// Root calls after registering the shared gate. Unknown/busy leaves intent
    /// intact and makes all mutations fail closed; there is no blind PID cleanup.
    pub fn recover_pending_switch(&self) -> AccountResult<Option<AccountOperationDto>> {
        self.require_accepting()?;
        let _operation = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        let Some(mut journal) = storage::load_journal(&self.paths, self.protector.as_ref())? else {
            return Ok(None);
        };
        let lease = self.acquire_maintenance(&journal.account_id, &super::nonce()?)?;
        let writer = self.credential_write(&journal.account_id, CredentialWritePurpose::Managed)?;
        let mut store = self.store()?;
        let expected_identity = parse_auth(&journal.written_auth)
            .map_err(|_| fail("recovery_required"))?
            .0;
        if store
            .vault
            .account(&journal.account_id)?
            .credential
            .as_ref()
            .is_none_or(|c| c.identity != expected_identity)
        {
            return Err(fail("recovery_required"));
        }
        let mut current = TargetSnapshot::read(&self.paths.system_home)?;
        lease.recheck()?;
        writer.recheck()?;
        let completed = store.vault.active.as_ref().is_some_and(|proof| {
            proof.account_id == journal.account_id
                && current
                    .auth
                    .as_ref()
                    .is_some_and(|bytes| auth_digest(bytes) == proof.target_digest)
                && store
                    .vault
                    .account(&journal.account_id)
                    .ok()
                    .and_then(|a| a.credential.as_ref())
                    .is_some_and(|c| c.generation == proof.generation)
        });
        // Encryption can fail immediately after an official CLI rotation,
        // before the successor journal/vault copy is durable. Its only copy
        // then remains in the target. Recovery must reverify that exact same
        // account under the real maintenance/write gates, never blindly copy it.
        if !completed
            && journal.verification_started
            && journal.verified_rotation.is_none()
            && current != journal.before
            && current.auth.as_deref() != Some(&journal.written_auth)
        {
            let record = store.vault.account(&journal.account_id)?;
            let old = record
                .credential
                .as_ref()
                .ok_or_else(|| fail("recovery_required"))?
                .clone();
            let same = current
                .auth
                .as_deref()
                .and_then(|auth| parse_auth(auth).ok().map(|v| v.0))
                .is_some_and(|identity| identity == old.identity);
            if same {
                if journal.expected_revision != Some(record.revision)
                    || old.generation != journal.generation
                    || old.auth != journal.written_auth
                    || current.config != journal.before.config
                {
                    return Err(fail("recovery_required"));
                }
                self.runtime
                    .validate_target_configuration(&self.paths.system_home)?;
                lease.recheck()?;
                writer.recheck()?;
                self.runtime.require_system_idle()?;
                let verified = self
                    .runtime
                    .verify(&self.paths.system_home, &old.identity)
                    .map_err(|_| fail("recovery_required"))?;
                let after = TargetSnapshot::read(&self.paths.system_home)?;
                if verified.identity != old.identity
                    || after.auth.as_deref() != Some(&verified.auth)
                    || after.config != journal.before.config
                {
                    return Err(fail("recovery_required"));
                }
                journal.written_auth = verified.auth.clone();
                journal.verified_rotation = Some(storage::VerifiedSwitchRotation {
                    revision: record.revision,
                    previous_auth_digest: auth_digest(&old.auth),
                    credential: verified.into_stored(super::nonce()?),
                });
                lease.recheck()?;
                writer.recheck()?;
                storage::save_journal(&self.paths, self.protector.as_ref(), &journal)
                    .map_err(|_| fail("recovery_required"))?;
                current = after;
            }
        }
        let phase = if completed {
            "committed"
        } else if current == journal.before {
            "rolled_back"
        } else if current.auth.as_deref() == Some(&journal.written_auth)
            && current.config == journal.before.config
        {
            storage::restore_owned(
                &self.paths.system_home,
                &journal.written_auth,
                &journal.before,
            )?;
            "rolled_back"
        } else {
            if journal.verification_started && journal.verified_rotation.is_none() {
                let same_or_unknown = current
                    .auth
                    .as_deref()
                    .and_then(|auth| parse_auth(auth).ok().map(|v| v.0))
                    .zip(
                        store
                            .vault
                            .account(&journal.account_id)?
                            .credential
                            .as_ref()
                            .map(|c| c.identity.clone()),
                    )
                    .is_none_or(|(current, expected)| current == expected);
                if same_or_unknown {
                    return Err(fail("recovery_required"));
                }
            }
            "external_change_preserved"
        };
        if !completed && journal.verified_rotation.is_some() {
            writer.recheck()?;
            Self::preserve_switch_rotation(&mut store, &journal)
                .map_err(|_| fail("recovery_required"))?;
        }
        storage::clear_journal(&self.paths)?;
        Ok(Some(AccountOperationDto {
            account_id: journal.account_id,
            phase,
            error_code: None,
        }))
    }
    fn preserve_switch_rotation(
        store: &mut StoreGuard<'_>,
        journal: &SwitchJournal,
    ) -> AccountResult<()> {
        let Some(rotation) = &journal.verified_rotation else {
            return Ok(());
        };
        let record = store.vault.account_mut(&journal.account_id)?;
        let old = record
            .credential
            .as_ref()
            .ok_or_else(|| fail("account_changed"))?;
        let candidate = &rotation.credential;
        if candidate.auth != journal.written_auth
            || parse_auth(&candidate.auth)?.0 != candidate.identity
            || old.identity != candidate.identity
        {
            return Err(fail("identity_mismatch"));
        }
        let already = record.revision
            == rotation
                .revision
                .checked_add(1)
                .ok_or_else(|| fail("account_changed"))?
            && old.generation == candidate.generation
            && old.auth == candidate.auth;
        if !already {
            if record.revision != rotation.revision
                || old.generation != journal.generation
                || auth_digest(&old.auth) != rotation.previous_auth_digest
            {
                return Err(fail("account_changed"));
            }
            record.credential = Some(candidate.clone());
            record.revision = record
                .revision
                .checked_add(1)
                .ok_or_else(|| fail("vault_invalid"))?;
        }
        // Preserve the real rotated grant only. In particular, a cancelled
        // target never becomes the active profile through this recovery save.
        store.save()
    }
    /// User-initiated login/prepare may reconcile an earlier blocked startup
    /// recovery after the real occupancy has become idle. Never clear unknown
    /// intent merely because an earlier startup attempt failed.
    fn retry_pending_recovery(&self) -> AccountResult<()> {
        self.require_accepting()?;
        if self.paths.journal().exists() {
            self.recover_pending_switch()?;
        }
        Ok(())
    }
    /// Admission adapter only. This is not registered as a Tauri command and
    /// grants no lease on its own; caller must atomically reserve/recheck first.
    pub fn verified_credential_snapshot(
        &self,
        account_id: &str,
        maximum_age: i64,
    ) -> AccountResult<VerifiedCredentialSnapshot> {
        self.require_recovered()?;
        let store = self.store()?;
        let credential = store
            .vault
            .account(account_id)?
            .credential
            .as_ref()
            .ok_or_else(|| fail("login_required"))?;
        VerifiedCredentialSnapshot::from_stored(credential, maximum_age)
    }
    /// Keep the last verified display observation without extending the
    /// credential/admission freshness window. Missing proof means no snapshot.
    pub fn cached_quota_snapshot(
        &self,
        account_id: &str,
    ) -> AccountResult<Option<super::CachedQuotaSnapshot>> {
        if self.paths.journal().exists() {
            return Ok(None);
        }
        let store = self.store()?;
        let Some(credential) = store.vault.account(account_id)?.credential.as_ref() else {
            return Ok(None);
        };
        let Ok((identity, _)) = parse_auth(&credential.auth) else {
            return Ok(None);
        };
        if identity != credential.identity
            || credential.observed_at <= 0
            || credential.observed_at > super::now() + 5
            || !crate::readers::CodexAppServerQuotaSnapshot::from_rate_limit_response(
                &credential.quota,
            )
            .quota_read_succeeded
        {
            return Ok(None);
        }
        Ok(Some(super::CachedQuotaSnapshot {
            plan: credential.plan.clone(),
            official_quota: credential.quota.clone(),
            observed_at: credential.observed_at,
        }))
    }
    /// Identity lookup for the shared writer registry. No freshness relaxation
    /// and no write gate: caller may already hold the registry's atomic lock.
    pub fn managed_identity_hash(&self, id: &str) -> AccountResult<Option<String>> {
        let store = self.store()?;
        let Some(credential) = store.vault.account(id)?.credential.as_ref() else {
            return Ok(None);
        };
        let Ok((identity, _)) = parse_auth(&credential.auth) else {
            return Ok(None);
        };
        if identity != credential.identity {
            return Ok(None);
        }
        Ok(Some(identity.identity_hash()))
    }
    /// Prepare a fixed private home only while the durable registry grants the
    /// matching Desktop writer purpose. Never read/write the system auth here.
    pub fn prepare_proxy_desktop_home(
        &self,
        account_id: &str,
        claim: &crate::proxy::DesktopWriterClaim,
    ) -> AccountResult<super::ProxyDesktopHome> {
        let _operation = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.require_recovered()?;
        self.require_no_login()?;
        self.expire_tickets()?;
        if !self
            .tickets
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?
            .is_empty()
        {
            return Err(fail("switch_in_progress"));
        }
        validate_desktop_claim(account_id, claim)?;
        let writer = self.credential_write(
            account_id,
            CredentialWritePurpose::DesktopPrepare {
                writer_id: claim.writer_id.clone(),
            },
        )?;
        let credential = self
            .store()?
            .vault
            .account(account_id)?
            .credential
            .clone()
            .ok_or_else(|| fail("login_required"))?;
        let evidence = VerifiedCredentialSnapshot::from_stored(&credential, 45)?;
        if evidence.identity_hash != claim.identity_hash
            || evidence.token_generation != claim.initial_generation
        {
            return Err(fail("identity_mismatch"));
        }
        let home = self.paths.desktop(account_id)?;
        storage::secure_directory(home.parent().unwrap())?;
        storage::secure_directory(&home)?;
        let marker_path = home.join("writer-claim.dpapi");
        if storage::read_optional(&marker_path, 65536)?.is_some() {
            return Err(fail("desktop_writer_recovery_required"));
        }
        let existing =
            storage::read_optional(&home.join("auth.json"), super::identity::MAX_AUTH_BYTES)?;
        if let Some(auth) = &existing {
            // The exact previously imported grant may be reused. Never replace
            // a changed/uncertain rotating grant with the old vault copy.
            let imported = storage::read_optional(&home.join("last-import.dpapi"), 65536)?
                .map(|b| {
                    self.protector
                        .unseal("AiGoodBro.Next.Windows.desktop-import.v1", &b)
                })
                .transpose()?
                .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok());
            let last_known = imported.is_some_and(|v| {
                v["profile"] == account_id
                    && v["identity"] == claim.identity_hash
                    && v["digest"] == auth_digest(auth)
            });
            if parse_auth(auth)?.0 != credential.identity
                || (auth != &credential.auth && !last_known)
            {
                return Err(fail("desktop_auth_changed"));
            }
        }
        if home.join("config.toml").exists() {
            self.runtime.validate_target_configuration(&home)?;
        }
        writer.recheck()?;
        self.require_accepting()?;
        let marker=serde_json::to_vec(&serde_json::json!({"schema":1,"writer":claim.writer_id,"profile":claim.profile_id,"run":claim.proxy_run_id,
            "identity":claim.identity_hash,"generation":claim.initial_generation})).map_err(|_|fail("desktop_writer_recovery_required"))?;
        storage::atomic_write(
            &marker_path,
            &self
                .protector
                .seal("AiGoodBro.Next.Windows.desktop-writer.v1", &marker)?,
        )?;
        if existing.as_ref() != Some(&credential.auth) {
            storage::atomic_write(&home.join("auth.json"), &credential.auth)?;
        }
        if !home.join("config.toml").exists() {
            storage::atomic_write(
                &home.join("config.toml"),
                b"cli_auth_credentials_store = 'file'\nmodel_provider = 'openai'\n",
            )?;
        }
        writer.recheck()?;
        Ok(super::ProxyDesktopHome::new(
            home,
            account_id.into(),
            evidence.identity_hash,
            evidence.token_generation,
            claim.writer_id.clone(),
        ))
    }
    fn desktop_marker(&self, claim: &crate::proxy::DesktopWriterClaim) -> AccountResult<PathBuf> {
        validate_desktop_claim(&claim.profile_id, claim)?;
        let home = self.paths.desktop(&claim.profile_id)?;
        let bytes = storage::read_optional(&home.join("writer-claim.dpapi"), 65536)?
            .ok_or_else(|| fail("desktop_writer_recovery_required"))?;
        let value: serde_json::Value = serde_json::from_slice(
            &self
                .protector
                .unseal("AiGoodBro.Next.Windows.desktop-writer.v1", &bytes)?,
        )
        .map_err(|_| fail("desktop_writer_recovery_required"))?;
        if value["schema"] != 1
            || value["writer"] != claim.writer_id
            || value["profile"] != claim.profile_id
            || value["identity"] != claim.identity_hash
            || value["generation"] != claim.initial_generation
        {
            return Err(fail("desktop_writer_recovery_required"));
        }
        Ok(home)
    }
    /// Pure read, intentionally independent of the credential-write gate. The
    /// admission registry authenticates/binds the sole backend IPC first and
    /// rechecks its durable writer tuple atomically before issuing a lease.
    pub fn read_current_desktop_snapshot(
        &self,
        claim: &crate::proxy::DesktopWriterClaim,
        proof: &crate::proxy::DesktopQuotaEvidence,
    ) -> AccountResult<VerifiedCredentialSnapshot> {
        self.require_recovered()?;
        if proof.writer_id != claim.writer_id
            || proof.proxy_run_id != claim.proxy_run_id
            || !storage::valid_id(&proof.backend_id)
            || !proof.observed_at.is_finite()
            || proof.observed_at > super::now() as f64 + 5.0
            || super::now() as f64 - proof.observed_at > 45.0
            || proof.observed_at <= 0.0
            || proof.auth_digest.len() != 64
        {
            return Err(fail("evidence_stale"));
        }
        let home = self.desktop_marker(claim)?;
        self.runtime.validate_target_configuration(&home)?;
        let auth =
            storage::read_optional(&home.join("auth.json"), super::identity::MAX_AUTH_BYTES)?
                .ok_or_else(|| fail("credentials_missing"))?;
        if auth_digest(&auth) != proof.auth_digest {
            return Err(fail("desktop_auth_changed"));
        }
        let mut verified = super::VerifiedCredential::from_official_read(
            auth.clone(),
            &proof.account,
            proof.rate_limits.clone(),
        )?;
        if verified.identity.identity_hash() != claim.identity_hash {
            return Err(fail("identity_mismatch"));
        }
        if storage::read_optional(&home.join("auth.json"), super::identity::MAX_AUTH_BYTES)?
            .as_ref()
            != Some(&auth)
        {
            return Err(fail("desktop_auth_changed"));
        }
        verified.observed_at = proof.observed_at.floor() as i64;
        // Stable digest tracks Desktop rotations without mutating the vault.
        let generation = auth_digest(&auth)[..32].to_owned();
        VerifiedCredentialSnapshot::from_stored(&verified.into_stored(generation), 45)
    }
    /// Registry must first positively confirm every owned Job descendant exited
    /// and grant DesktopFinalize. Official verification is then the sole writer.
    pub fn finalize_desktop_after_exit(
        &self,
        home: &mut super::ProxyDesktopHome,
        claim: &crate::proxy::DesktopWriterClaim,
    ) -> AccountResult<super::DesktopHomeCleanup> {
        let _operation = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.require_recovered()?;
        self.require_no_login()?;
        let path = self.desktop_marker(claim)?;
        if home.path() != path
            || home.profile_id() != claim.profile_id
            || home.writer_id() != claim.writer_id
        {
            return Err(fail("identity_mismatch"));
        }
        let writer = self.credential_write(
            &claim.profile_id,
            CredentialWritePurpose::DesktopFinalize {
                writer_id: claim.writer_id.clone(),
            },
        )?;
        if home.finalized {
            writer.recheck()?;
            return home.cleanup_after_confirmed_exit();
        }
        let (revision, old) = {
            let store = self.store()?;
            let record = store.vault.account(&claim.profile_id)?;
            (
                record.revision,
                record
                    .credential
                    .clone()
                    .ok_or_else(|| fail("login_required"))?,
            )
        };
        if old.identity.identity_hash() != claim.identity_hash {
            return Err(fail("account_changed"));
        }
        if old.generation != claim.initial_generation {
            // An earlier finalize may have saved the rotated grant before a
            // later local cleanup failed. Never re-inject the initial grant.
            if storage::read_optional(&path.join("auth.json"), super::identity::MAX_AUTH_BYTES)?
                .as_ref()
                != Some(&old.auth)
            {
                return Err(fail("account_changed"));
            }
        }
        self.runtime.validate_target_configuration(&path)?;
        let result = self.runtime.verify(&path, &old.identity);
        if result
            .as_ref()
            .is_err_and(|e| e.code == "cleanup_unconfirmed")
        {
            self.cleanup_unconfirmed.store(true, Ordering::SeqCst);
            return Err(fail("cleanup_unconfirmed"));
        }
        let verified = result?;
        if verified.identity != old.identity {
            return Err(fail("identity_mismatch"));
        }
        let current =
            storage::read_optional(&path.join("auth.json"), super::identity::MAX_AUTH_BYTES)?
                .ok_or_else(|| fail("credentials_missing"))?;
        if current != verified.auth {
            return Err(fail("desktop_auth_changed"));
        }
        let imported=serde_json::to_vec(&serde_json::json!({"schema":1,"profile":claim.profile_id,"identity":claim.identity_hash,"digest":auth_digest(&current)}))
            .map_err(|_|fail("desktop_writer_recovery_required"))?;
        writer.recheck()?;
        self.require_accepting()?;
        let mut store = self.store()?;
        let record = store.vault.account_mut(&claim.profile_id)?;
        if record.revision != revision {
            return Err(fail("account_changed"));
        }
        let generation = if verified.auth == old.auth {
            old.generation
        } else {
            super::nonce()?
        };
        record.credential = Some(verified.into_stored(generation.clone()));
        record.revision += 1;
        writer.recheck()?;
        store.save()?;
        drop(store);
        storage::atomic_write(
            &path.join("last-import.dpapi"),
            &self
                .protector
                .seal("AiGoodBro.Next.Windows.desktop-import.v1", &imported)?,
        )?;
        let marker = storage::read_optional(&path.join("writer-claim.dpapi"), 65536)?
            .ok_or_else(|| fail("desktop_writer_recovery_required"))?;
        // Bind the exact encrypted marker, not just a grant which a later
        // writer could legitimately reuse without rotating credentials.
        self.desktop_marker(claim)?;
        let finalized = FinalizedDesktopWriter {
            schema: 1,
            writer: claim.writer_id.clone(),
            profile: claim.profile_id.clone(),
            identity: claim.identity_hash.clone(),
            initial_generation: claim.initial_generation.clone(),
            imported_generation: generation,
            marker_digest: auth_digest(&marker),
            auth_digest: auth_digest(&current),
        };
        let finalized =
            serde_json::to_vec(&finalized).map_err(|_| fail("desktop_writer_recovery_required"))?;
        writer.recheck()?;
        storage::atomic_write(
            &path.join("finalized-writer.dpapi"),
            &self.protector.seal(FINALIZED_DESKTOP_CONTEXT, &finalized)?,
        )?;
        home.finalized = true;
        writer.recheck()?;
        home.cleanup_after_confirmed_exit()
    }
    /// Launcher calls only after registry release succeeded. No refresh, no
    /// registry call and no history/auth deletion; safe to retry this exact held
    /// guard after a local marker-cleanup failure.
    pub fn complete_desktop_writer_release(
        &self,
        home: &mut super::ProxyDesktopHome,
        claim: &crate::proxy::DesktopWriterClaim,
    ) -> AccountResult<()> {
        if home.completed {
            return Ok(());
        }
        if !home.finalized
            || home.writer_id() != claim.writer_id
            || home.profile_id() != claim.profile_id
            || home.path() != self.paths.desktop(&claim.profile_id)?
        {
            return Err(fail("desktop_writer_recovery_required"));
        }
        self.cleanup_retired_desktop_writer(&claim.profile_id, Some(claim))?;
        home.completed = true;
        Ok(())
    }
    /// Call before claiming a new Desktop writer. Only a positively granted
    /// ordinary Managed lease plus this exact writer's DPAPI completion proof
    /// can close a crash between registry release and local marker removal.
    /// This never refreshes, changes auth, or deletes user history.
    pub fn complete_retired_desktop_writer(&self, account_id: &str) -> AccountResult<bool> {
        self.cleanup_retired_desktop_writer(account_id, None)
    }
    fn cleanup_retired_desktop_writer(
        &self,
        account_id: &str,
        expected: Option<&crate::proxy::DesktopWriterClaim>,
    ) -> AccountResult<bool> {
        let _operation = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.require_recovered()?;
        self.require_no_login()?;
        let writer = self.credential_write(account_id, CredentialWritePurpose::Managed)?;
        let path = self.paths.desktop(account_id)?;
        let marker_path = path.join("writer-claim.dpapi");
        let receipt_path = path.join("finalized-writer.dpapi");
        let marker = storage::read_optional(&marker_path, 65536)?;
        let receipt = storage::read_optional(&receipt_path, 65536)?;
        if marker.is_none() && receipt.is_none() {
            writer.recheck()?;
            return Ok(false);
        }
        let receipt = receipt.ok_or_else(|| fail("desktop_writer_recovery_required"))?;
        let proof: FinalizedDesktopWriter =
            serde_json::from_slice(&self.protector.unseal(FINALIZED_DESKTOP_CONTEXT, &receipt)?)
                .map_err(|_| fail("desktop_writer_recovery_required"))?;
        let valid_digest = |s: &str| {
            s.len() == 64
                && s.bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        };
        if proof.schema != 1
            || proof.profile != account_id
            || !storage::valid_id(&proof.writer)
            || !storage::valid_id(&proof.initial_generation)
            || !storage::valid_id(&proof.imported_generation)
            || !valid_digest(&proof.identity)
            || !valid_digest(&proof.marker_digest)
            || !valid_digest(&proof.auth_digest)
            || expected.is_some_and(|claim| {
                claim.writer_id != proof.writer
                    || claim.profile_id != proof.profile
                    || claim.identity_hash != proof.identity
                    || claim.initial_generation != proof.initial_generation
            })
        {
            return Err(fail("desktop_writer_recovery_required"));
        }
        if let Some(bytes) = &marker {
            if auth_digest(bytes) != proof.marker_digest {
                return Err(fail("desktop_writer_recovery_required"));
            }
            let value: serde_json::Value = serde_json::from_slice(
                &self
                    .protector
                    .unseal("AiGoodBro.Next.Windows.desktop-writer.v1", bytes)?,
            )
            .map_err(|_| fail("desktop_writer_recovery_required"))?;
            if value["schema"] != 1
                || value["writer"] != proof.writer
                || value["profile"] != proof.profile
                || value["identity"] != proof.identity
                || value["generation"] != proof.initial_generation
            {
                return Err(fail("desktop_writer_recovery_required"));
            }
        }
        // Keep the store's cross-process OS lock through cleanup. The shared
        // credential lease also excludes new claims and same-identity aliases.
        let store = self.store()?;
        let stored = store
            .vault
            .account(account_id)?
            .credential
            .as_ref()
            .ok_or_else(|| fail("login_required"))?;
        let auth =
            storage::read_optional(&path.join("auth.json"), super::identity::MAX_AUTH_BYTES)?
                .ok_or_else(|| fail("credentials_missing"))?;
        if stored.identity.identity_hash() != proof.identity
            || parse_auth(&auth)?.0 != stored.identity
            || stored.generation != proof.imported_generation
            || auth != stored.auth
            || auth_digest(&auth) != proof.auth_digest
        {
            return Err(fail("desktop_auth_changed"));
        }
        let connection_path = path.join("desktop-connection.json");
        let connection = storage::read_optional(&connection_path, 65536)?;
        let unchanged = || -> AccountResult<()> {
            writer.recheck()?;
            self.require_accepting()?;
            if storage::read_optional(&path.join("auth.json"), super::identity::MAX_AUTH_BYTES)?
                .as_ref()
                != Some(&auth)
                || storage::read_optional(&marker_path, 65536)? != marker
                || storage::read_optional(&receipt_path, 65536)?.as_ref() != Some(&receipt)
            {
                return Err(fail("desktop_writer_recovery_required"));
            }
            Ok(())
        };
        unchanged()?;
        if let Some(connection) = connection {
            if storage::read_optional(&connection_path, 65536)?.as_ref() != Some(&connection) {
                return Err(fail("desktop_writer_recovery_required"));
            }
            std::fs::remove_file(&connection_path)
                .map_err(|_| fail("desktop_home_cleanup_failed"))?;
        }
        unchanged()?;
        if marker.is_some() {
            std::fs::remove_file(&marker_path)
                .map_err(|_| fail("desktop_writer_recovery_required"))?;
        }
        // Receipt removal is last. A crash after marker removal leaves an
        // authenticated orphan receipt which the same checks can finish.
        writer.recheck()?;
        if storage::read_optional(&receipt_path, 65536)?.as_ref() != Some(&receipt)
            || storage::read_optional(&marker_path, 65536)?.is_some()
        {
            return Err(fail("desktop_writer_recovery_required"));
        }
        std::fs::remove_file(&receipt_path)
            .map_err(|_| fail("desktop_writer_recovery_required"))?;
        Ok(true)
    }
    /// Native recovery composition only. A verified native recovery proof must
    /// first let the shared registry grant this exact claim ExitedPendingImport.
    /// Merely finding a marker or reconstructing a claim never proves exit.
    pub fn reconstruct_desktop_home_for_recovery(
        &self,
        claim: &crate::proxy::DesktopWriterClaim,
    ) -> AccountResult<super::ProxyDesktopHome> {
        let _operation = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.require_recovered()?;
        self.require_no_login()?;
        self.expire_tickets()?;
        if !self
            .tickets
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?
            .is_empty()
        {
            return Err(fail("switch_in_progress"));
        }
        let writer = self.credential_write(
            &claim.profile_id,
            CredentialWritePurpose::DesktopFinalize {
                writer_id: claim.writer_id.clone(),
            },
        )?;
        let path = self.desktop_marker(claim)?;
        let old = self
            .store()?
            .vault
            .account(&claim.profile_id)?
            .credential
            .clone()
            .ok_or_else(|| fail("login_required"))?;
        if old.identity.identity_hash() != claim.identity_hash {
            return Err(fail("identity_mismatch"));
        }
        let auth =
            storage::read_optional(&path.join("auth.json"), super::identity::MAX_AUTH_BYTES)?
                .ok_or_else(|| fail("credentials_missing"))?;
        if parse_auth(&auth)?.0 != old.identity {
            return Err(fail("identity_mismatch"));
        }
        if old.generation != claim.initial_generation && auth != old.auth {
            return Err(fail("account_changed"));
        }
        self.runtime.validate_target_configuration(&path)?;
        writer.recheck()?;
        self.require_accepting()?;
        Ok(super::ProxyDesktopHome::new(
            path,
            claim.profile_id.clone(),
            claim.identity_hash.clone(),
            claim.initial_generation.clone(),
            claim.writer_id.clone(),
        ))
    }
    /// Only the connector's positively unlaunched/confirmed-exit claim can
    /// obtain DesktopFinalize. This is not a startup crash-recovery shortcut.
    /// Connector retains a successful Rust receipt before retrying release.
    pub fn abandon_unlaunched_desktop_prepare(
        &self,
        claim: &crate::proxy::DesktopWriterClaim,
    ) -> AccountResult<()> {
        let _operation = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.require_accepting()?;
        validate_desktop_claim(&claim.profile_id, claim)?;
        let writer = self.credential_write(
            &claim.profile_id,
            CredentialWritePurpose::DesktopFinalize {
                writer_id: claim.writer_id.clone(),
            },
        )?;
        let home = self.paths.desktop(&claim.profile_id)?;
        let old = self
            .store()?
            .vault
            .account(&claim.profile_id)?
            .credential
            .clone()
            .ok_or_else(|| fail("login_required"))?;
        if old.identity.identity_hash() != claim.identity_hash
            || old.generation != claim.initial_generation
        {
            return Err(fail("account_changed"));
        }
        let marker = storage::read_optional(&home.join("writer-claim.dpapi"), 65536)?;
        if marker.is_some() {
            self.desktop_marker(claim)?;
        }
        if let Some(auth) =
            storage::read_optional(&home.join("auth.json"), super::identity::MAX_AUTH_BYTES)?
        {
            let imported = storage::read_optional(&home.join("last-import.dpapi"), 65536)?
                .map(|b| {
                    self.protector
                        .unseal("AiGoodBro.Next.Windows.desktop-import.v1", &b)
                })
                .transpose()?
                .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok());
            let last_known = imported.is_some_and(|v| {
                v["profile"] == claim.profile_id
                    && v["identity"] == claim.identity_hash
                    && v["digest"] == auth_digest(&auth)
            });
            if parse_auth(&auth)?.0 != old.identity || (auth != old.auth && !last_known) {
                return Err(fail("desktop_auth_changed"));
            }
        }
        if home.join("config.toml").exists() {
            self.runtime.validate_target_configuration(&home)?;
        }
        let connection = home.join("desktop-connection.json");
        if storage::read_optional(&connection, 65536)?.is_some() {
            writer.recheck()?;
            std::fs::remove_file(connection).map_err(|_| fail("desktop_home_cleanup_failed"))?;
        }
        writer.recheck()?;
        if let Some(marker) = marker {
            if storage::read_optional(&home.join("writer-claim.dpapi"), 65536)?.as_ref()
                != Some(&marker)
            {
                return Err(fail("desktop_writer_recovery_required"));
            }
            std::fs::remove_file(home.join("writer-claim.dpapi"))
                .map_err(|_| fail("desktop_writer_recovery_required"))?;
        }
        Ok(())
    }
    /// Conservative native enumeration for the owned Desktop launcher.
    pub fn require_codex_system_idle(&self) -> AccountResult<()> {
        self.runtime.require_system_idle()
    }
    /// Native notification adapter only; ticket lookup does not consume a
    /// switch or expose credentials, and failed/expired tickets have no target.
    pub fn prepared_switch_account(&self, ticket: &str) -> AccountResult<String> {
        self.tickets
            .try_lock()
            .map_err(|_| fail("account_busy"))?
            .get(ticket)
            .filter(|t| t.expires_at > super::now())
            .map(|t| t.account_id.clone())
            .ok_or_else(|| fail("switch_ticket_invalid"))
    }
    /// Native scanner catalogue only. Does not open any auth file and never
    /// includes the vault/staging roots or a caller-selected directory.
    pub fn managed_history_roots(&self) -> AccountResult<Vec<(String, PathBuf)>> {
        let store = self.store()?;
        let mut roots = Vec::new();
        for record in &store.vault.accounts {
            let path = self.paths.desktop(&record.id)?;
            match std::fs::symlink_metadata(&path) {
                Ok(metadata) if metadata.is_dir() => roots.push((record.id.clone(), path)),
                Ok(_) => return Err(fail("account_paths_invalid")),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
                Err(_) => return Err(fail("account_store_unavailable")),
            }
        }
        Ok(roots)
    }
    /// Native automatic-policy metadata only. Preserve Mac email-group opt-out
    /// and workspace exclusion semantics without exposing either raw field.
    pub fn managed_automation_keys(
        &self,
        account_id: &str,
    ) -> AccountResult<Option<(String, String)>> {
        let store = self.store()?;
        let Some(credential) = store.vault.account(account_id)?.credential.as_ref() else {
            return Ok(None);
        };
        let (identity, _) = parse_auth(&credential.auth)?;
        if identity != credential.identity {
            return Err(fail("identity_unverified"));
        }
        Ok(Some((
            auth_digest(format!("AiGoodBro.automation.email.v1\0{}", identity.email).as_bytes()),
            auth_digest(
                format!("AiGoodBro.automation.workspace.v1\0{}", identity.account_id).as_bytes(),
            ),
        )))
    }
    pub fn runtime_selection(&self) -> AccountResult<crate::runtime_setup::SelectionStore> {
        crate::runtime_setup::SelectionStore::new(
            self.paths
                .vault_root
                .parent()
                .ok_or_else(|| fail("runtime_storage_unavailable"))?,
        )
    }
    /// Native launcher composition only. The caller additionally verifies the
    /// publisher and retains the read-share guard through process creation.
    pub fn proxy_codex_executable(
        &self,
        home: &std::path::Path,
    ) -> AccountResult<(PathBuf, std::fs::File)> {
        super::native::proxy_codex_executable(home, &self.runtime_selection()?)
    }
    /// Refresh expired evidence in a private, disposable home, never the active
    /// system home. The caller still must reserve under its shared registry.
    pub fn refresh_managed_credential(
        &self,
        account_id: &str,
    ) -> AccountResult<VerifiedCredentialSnapshot> {
        let _operation = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.require_recovered()?;
        self.require_no_login()?;
        self.expire_tickets()?;
        if !self
            .tickets
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?
            .is_empty()
        {
            return Err(fail("switch_in_progress"));
        }
        let (revision, credential) = {
            let store = self.store()?;
            let record = store.vault.account(account_id)?;
            (
                record.revision,
                record
                    .credential
                    .clone()
                    .ok_or_else(|| fail("login_required"))?,
            )
        };
        let writer = self.credential_write(account_id, CredentialWritePurpose::Managed)?;
        let staging = storage::private_tempdir(&self.paths.staging(), "refresh-")
            .map_err(|_| fail("verification_unavailable"))?;
        storage::atomic_write(&staging.path().join("auth.json"), &credential.auth)?;
        let result = self.runtime.verify(staging.path(), &credential.identity);
        if result
            .as_ref()
            .is_err_and(|e| e.code == "cleanup_unconfirmed")
        {
            self.cleanup_unconfirmed.store(true, Ordering::SeqCst);
            let _ = staging.keep();
            return Err(fail("cleanup_unconfirmed"));
        }
        let verified = result?;
        if verified.identity != credential.identity {
            return Err(fail("identity_mismatch"));
        }
        let mut store = self.store()?;
        let record = store.vault.account_mut(account_id)?;
        if record.revision != revision {
            return Err(fail("account_changed"));
        }
        let generation = if verified.auth == credential.auth {
            credential.generation
        } else {
            super::nonce()?
        };
        record.credential = Some(verified.into_stored(generation));
        record.revision = record
            .revision
            .checked_add(1)
            .ok_or_else(|| fail("vault_invalid"))?;
        let snapshot =
            VerifiedCredentialSnapshot::from_stored(record.credential.as_ref().unwrap(), 45)?;
        self.require_accepting()?;
        writer.recheck()?;
        store.save()?;
        Ok(snapshot)
    }
    /// Rust-only fixed secret slots. Ordinary settings and WebView commands
    /// never contain these values; both share the same DPAPI vault/OS lock.
    pub fn load_secret(&self, name: &str) -> AccountResult<Option<String>> {
        if !matches!(name, "proxy.client_key" | "proxy.mihomo_secret") {
            return Err(fail("secret_slot_invalid"));
        }
        Ok(self.store()?.vault.secrets.get(name).cloned())
    }
    pub fn save_secret(&self, name: &str, value: Option<&str>) -> AccountResult<()> {
        if !matches!(name, "proxy.client_key" | "proxy.mihomo_secret")
            || value
                .is_some_and(|s| s.is_empty() || s.len() > 4096 || s.chars().any(char::is_control))
        {
            return Err(fail("secret_slot_invalid"));
        }
        let _operation = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.require_accepting()?;
        let mut store = self.store()?;
        if let Some(value) = value {
            store
                .vault
                .secrets
                .insert(name.to_owned(), value.to_owned());
        } else {
            store.vault.secrets.remove(name);
        }
        store.save()
    }
    /// Termination integration: cancel only this manager's pending operations.
    /// Owned native children confirm cleanup before each attempt becomes final.
    pub fn cancel_pending_operations(&self) {
        if let Ok(mut attempts) = self.attempts.lock() {
            for attempt in attempts.values_mut() {
                if matches!(
                    attempt.dto.phase,
                    "starting" | "waiting" | "verifying" | "cancelling"
                ) {
                    attempt.cancelled.store(true, Ordering::SeqCst);
                    attempt.dto.phase = "cancelling";
                    attempt.dto.verification_url = None;
                    attempt.dto.user_code = None;
                }
            }
        }
        if let Ok(mut tickets) = self.tickets.lock() {
            tickets.clear();
        }
    }
    /// No filesystem/process I/O and no waiting for another operation. A
    /// contended/poisoned state is conservatively in flight for native Quit.
    pub fn has_inflight_operation(&self) -> bool {
        if self.cleanup_unconfirmed.load(Ordering::SeqCst) {
            return true;
        }
        let Ok(_operation) = self.mutation.try_lock() else {
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
    /// Irreversible for this service instance. Do not clear journals, drop
    /// maintenance leases or wait for owned child cleanup on the UI thread.
    pub fn cancel_inflight_for_exit(&self) {
        self.exiting.store(true, Ordering::SeqCst);
        if let Ok(mut attempts) = self.attempts.try_lock() {
            for attempt in attempts.values_mut() {
                attempt.cancelled.store(true, Ordering::SeqCst);
                if matches!(attempt.dto.phase, "starting" | "waiting" | "verifying") {
                    attempt.dto.phase = "cancelling";
                }
                attempt.dto.verification_url = None;
                attempt.dto.user_code = None;
            }
        }
    }
}
fn system_config_digest(config: &Option<Vec<u8>>) -> String {
    let mut bytes = b"AiGoodBro.system-config.v1\0".to_vec();
    match config {
        None => bytes.push(0),
        Some(value) => {
            bytes.push(1);
            bytes.extend(value);
        }
    }
    auth_digest(&bytes)
}
#[cfg(test)]
#[path = "active_scope_tests.rs"]
mod active_scope_tests;
#[path = "catalog.rs"]
mod catalog;

impl Drop for AccountManager {
    fn drop(&mut self) {
        if let Ok(attempts) = self.attempts.lock() {
            for attempt in attempts.values() {
                attempt.cancelled.store(true, Ordering::SeqCst);
            }
        }
    }
}

fn validate_desktop_claim(id: &str, claim: &crate::proxy::DesktopWriterClaim) -> AccountResult<()> {
    if id != claim.profile_id
        || !storage::valid_id(id)
        || !storage::valid_id(&claim.writer_id)
        || !storage::valid_id(&claim.proxy_run_id)
        || claim.identity_hash.len() != 64
        || claim.initial_generation.is_empty()
    {
        return Err(fail("identity_mismatch"));
    }
    Ok(())
}
