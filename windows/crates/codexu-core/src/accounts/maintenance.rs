//! Explicit, default-off quota-window maintenance. No UI credential/card input.
use super::*;
use crate::accounts::AccountError;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::BTreeMap,
    path::Path,
    sync::{atomic::AtomicU64, Weak},
    time::{Duration, Instant},
};
#[path = "maintenance/native.rs"]
mod native;
#[path = "maintenance/policy.rs"]
mod policy;
use policy::*;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    Unavailable,
    InvalidSettings,
    SaveFailed,
    Busy,
    QuotaUnknown,
    Unauthorized,
    IdentityChanged,
    Cancelled,
    ProtocolUnknown,
    OutcomeUnknown,
    RecoveryRequired,
}
impl Failure {
    pub fn code(self) -> &'static str {
        match self {
            Self::Unavailable => "maintenance_unsupported",
            Self::InvalidSettings => "maintenance_invalid_settings",
            Self::SaveFailed => "maintenance_save_failed",
            Self::Busy => "maintenance_busy",
            Self::QuotaUnknown => "maintenance_quota_unknown",
            Self::Unauthorized => "maintenance_unauthorized",
            Self::IdentityChanged => "maintenance_identity_changed",
            Self::Cancelled => "maintenance_cancelled",
            Self::ProtocolUnknown => "maintenance_protocol_unknown",
            Self::OutcomeUnknown => "maintenance_outcome_unknown",
            Self::RecoveryRequired => "maintenance_recovery_required",
        }
    }
}
impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.code())
    }
}
impl std::error::Error for Failure {}
pub type Result<T> = std::result::Result<T, Failure>;
fn account_error(error: AccountError) -> Failure {
    match error.code {
        "account_busy" | "account_store_busy" | "occupancy_unknown" | "switch_in_progress"
        | "login_in_progress" => Failure::Busy,
        "identity_mismatch" | "account_changed" | "active_scope_changed" => {
            Failure::IdentityChanged
        }
        "credentials_expired" | "evidence_stale" | "official_quota_unverified" => {
            Failure::QuotaUnknown
        }
        "account_service_exiting" | "switch_cancelled" => Failure::Cancelled,
        "recovery_required" | "cleanup_unconfirmed" => Failure::RecoveryRequired,
        _ => Failure::Unavailable,
    }
}
fn now() -> i64 {
    chrono::Utc::now().timestamp_millis()
}
fn opaque(value: &str) -> bool {
    value.len() == 32
        && value
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}
fn hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResetAuthorization {
    pub profile_id: String,
    pub authorized: bool,
    pub identity_current: bool,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountMaintenancePreferences {
    pub five_hour_warmup: bool,
    pub seven_day_warmup: bool,
    pub reset_lead_minutes: u16,
    pub reset_authorizations: Vec<ResetAuthorization>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Settings {
    five_hour_warmup: bool,
    seven_day_warmup: bool,
    reset_lead_minutes: u16,
    reset_authorizations: BTreeMap<String, String>,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            five_hour_warmup: false,
            seven_day_warmup: false,
            reset_lead_minutes: 30,
            reset_authorizations: BTreeMap::new(),
        }
    }
}
impl Settings {
    fn validate(&self) -> Result<()> {
        if !(1..=1440).contains(&self.reset_lead_minutes)
            || self.reset_authorizations.len() > 1000
            || self
                .reset_authorizations
                .iter()
                .any(|(p, i)| !opaque(p) || !hash(i))
        {
            Err(Failure::InvalidSettings)
        } else {
            Ok(())
        }
    }
    fn enabled(&self) -> bool {
        self.five_hour_warmup || self.seven_day_warmup || !self.reset_authorizations.is_empty()
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MaintenanceEntry {
    pub profile_id: String,
    pub kind: String,
    pub phase: String,
    pub issue_code: Option<String>,
    pub last_attempt_at_ms: Option<i64>,
    pub last_succeeded_at_ms: Option<i64>,
    pub next_eligible_at_ms: Option<i64>,
    identity: String,
    generation: String,
    window_baseline: Vec<Window>,
    card_hash: Option<String>,
    idempotency_key: Option<String>,
    quota_fingerprint: Option<String>,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MaintenanceEntryDto {
    pub profile_id: String,
    pub kind: String,
    pub phase: String,
    pub issue_code: Option<String>,
    pub last_attempt_at_ms: Option<i64>,
    pub last_succeeded_at_ms: Option<i64>,
    pub next_eligible_at_ms: Option<i64>,
}
impl From<&MaintenanceEntry> for MaintenanceEntryDto {
    fn from(e: &MaintenanceEntry) -> Self {
        Self {
            profile_id: e.profile_id.clone(),
            kind: e.kind.clone(),
            phase: e.phase.clone(),
            issue_code: e.issue_code.clone(),
            last_attempt_at_ms: e.last_attempt_at_ms,
            last_succeeded_at_ms: e.last_succeeded_at_ms,
            next_eligible_at_ms: e.next_eligible_at_ms,
        }
    }
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountMaintenanceStatus {
    pub phase: &'static str,
    pub issue_code: Option<&'static str>,
    pub running_profile_id: Option<String>,
    pub entries: Vec<MaintenanceEntryDto>,
    pub native_implementation_available: bool,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Stored {
    version: u32,
    settings: Settings,
    entries: Vec<MaintenanceEntry>,
}
impl Default for Stored {
    fn default() -> Self {
        Self {
            version: 1,
            settings: Settings::default(),
            entries: Vec::new(),
        }
    }
}
impl Stored {
    fn validate(&self) -> Result<()> {
        self.settings.validate()?;
        if self.version != 1
            || self.entries.len() > 512
            || self.entries.iter().any(|e| {
                !opaque(&e.profile_id)
                    || !hash(&e.identity)
                    || !opaque(&e.generation)
                    || !matches!(e.kind.as_str(), "warmup" | "reset_credit")
                    || !matches!(
                        e.phase.as_str(),
                        "running"
                            | "succeeded"
                            | "deferred"
                            | "uncertain"
                            | "blocked"
                            | "cancelled"
                    )
                    || e.card_hash.as_ref().is_some_and(|h| !hash(h))
                    || e.window_baseline.len() > 3
            })
        {
            return Err(Failure::RecoveryRequired);
        }
        Ok(())
    }
}
struct State {
    saved: Stored,
    running: Option<String>,
    issue: Option<Failure>,
    suspended: bool,
}
/// Runtime state must be cleared even when a disk or credential check exits early.
/// Durable running/uncertain entries remain intact so recovery cannot replay them.
struct RunningStateReset<'a>(&'a Mutex<State>);
impl Drop for RunningStateReset<'_> {
    fn drop(&mut self) {
        if let Ok(mut state) = self.0.lock() {
            state.running = None;
        }
    }
}
struct Credential {
    record: storage::AccountRecord,
    value: super::super::identity::StoredCredential,
    windows: Vec<Window>,
    active_identity: bool,
}
#[derive(Clone, Debug, PartialEq)]
pub(super) enum Outcome {
    Succeeded,
    Reset,
    NothingToReset,
    NoCredit,
    AlreadyRedeemed,
    NotSent,
    Unknown,
}
pub(super) struct Execution {
    pub(super) outcome: Outcome,
    pub(super) verified: Option<super::super::VerifiedCredential>,
}
pub(super) struct Card {
    pub(super) id: String,
    pub(super) expires_at_ms: i64,
    pub(super) fingerprint: String,
}
pub(super) fn manual_card(value: &Value, expected: &str, time: i64) -> Result<Card> {
    card(value, expected, time)
}
pub(super) fn manual_consume(
    home: &Path,
    credential: &super::super::identity::StoredCredential,
    claim: &dyn Fn(&Card) -> Result<String>,
    admit: &dyn Fn() -> Result<()>,
) -> Execution {
    native::manual_reset(home, credential, claim, admit)
}

trait Runtime: Send + Sync {
    fn available(&self) -> bool;
    fn warmup(
        &self,
        credential: &super::super::identity::StoredCredential,
        admit: &dyn Fn() -> Result<()>,
    ) -> Execution;
    fn reset(
        &self,
        home: &Path,
        credential: &super::super::identity::StoredCredential,
        claim: &dyn Fn(&Card) -> Result<String>,
        admit: &dyn Fn() -> Result<()>,
    ) -> Execution;
}
pub struct AccountMaintenanceService {
    path: PathBuf,
    manager: Arc<AccountManager>,
    runtime: Arc<dyn Runtime>,
    state: Mutex<State>,
    operation: Mutex<()>,
    epoch: AtomicU64,
    exiting: AtomicBool,
    monitor_active: AtomicBool,
}
impl AccountMaintenanceService {
    pub fn new(path: PathBuf, manager: Arc<AccountManager>) -> Result<Arc<Self>> {
        Self::with_runtime(path, manager, Arc::new(native::NativeRuntime))
    }
    fn with_runtime(
        path: PathBuf,
        manager: Arc<AccountManager>,
        runtime: Arc<dyn Runtime>,
    ) -> Result<Arc<Self>> {
        let saved = read(&path)?;
        Ok(Arc::new(Self {
            path,
            manager,
            runtime,
            state: Mutex::new(State {
                saved,
                running: None,
                issue: None,
                suspended: false,
            }),
            operation: Mutex::new(()),
            epoch: AtomicU64::new(0),
            exiting: AtomicBool::new(false),
            monitor_active: AtomicBool::new(false),
        }))
    }
    /// Manual actions share only identity-specific reset reconciliation, never
    /// the automatic occupancy/idle policy. The shared reset-flight lock is
    /// held by the caller, so a durable automatic claim cannot race this read.
    pub(super) fn manual_reset_admission(&self, identity: &str) -> Result<()> {
        let saved = read(&self.path)?;
        if saved.entries.iter().any(|e| {
            e.identity == identity
                && e.kind == "reset_credit"
                && e.card_hash.is_some()
                && matches!(e.phase.as_str(), "running" | "uncertain")
        }) {
            return Err(Failure::RecoveryRequired);
        }
        Ok(())
    }
    pub fn preferences(&self) -> Result<AccountMaintenancePreferences> {
        let settings = self
            .state
            .lock()
            .map_err(|_| Failure::Unavailable)?
            .saved
            .settings
            .clone();
        let reset_authorizations = settings
            .reset_authorizations
            .iter()
            .map(|(p, i)| ResetAuthorization {
                profile_id: p.clone(),
                authorized: true,
                identity_current: self
                    .manager
                    .managed_identity_hash(p)
                    .ok()
                    .flatten()
                    .as_ref()
                    == Some(i),
            })
            .collect();
        Ok(AccountMaintenancePreferences {
            five_hour_warmup: settings.five_hour_warmup,
            seven_day_warmup: settings.seven_day_warmup,
            reset_lead_minutes: settings.reset_lead_minutes,
            reset_authorizations,
        })
    }
    fn edit(&self, change: impl FnOnce(&mut Settings)) -> Result<AccountMaintenancePreferences> {
        if self.exiting.load(Ordering::Acquire) {
            return Err(Failure::Cancelled);
        }
        self.epoch.fetch_add(1, Ordering::AcqRel);
        let mut state = self.state.lock().map_err(|_| Failure::Unavailable)?;
        if self.exiting.load(Ordering::Acquire) {
            return Err(Failure::Cancelled);
        }
        let mut next = state.saved.clone();
        change(&mut next.settings);
        next.validate()?;
        if let Err(error) = save(&self.path, &next) {
            state.suspended = true;
            state.issue = Some(error);
            return Err(error);
        }
        state.saved = next;
        state.suspended = false;
        drop(state);
        self.preferences()
    }
    pub fn set_warmup_selection(
        &self,
        five_hour: bool,
        seven_day: bool,
    ) -> Result<AccountMaintenancePreferences> {
        self.edit(|s| {
            s.five_hour_warmup = five_hour;
            s.seven_day_warmup = seven_day
        })
    }
    pub fn set_reset_options(&self, lead_minutes: u16) -> Result<AccountMaintenancePreferences> {
        if !(1..=1440).contains(&lead_minutes) {
            return Err(Failure::InvalidSettings);
        }
        self.edit(|s| s.reset_lead_minutes = lead_minutes)
    }
    pub fn authorize_reset(
        &self,
        profile_id: &str,
        enabled: bool,
    ) -> Result<AccountMaintenancePreferences> {
        if !opaque(profile_id) {
            return Err(Failure::InvalidSettings);
        }
        let identity = if enabled {
            Some(
                self.manager
                    .managed_identity_hash(profile_id)
                    .map_err(account_error)?
                    .ok_or(Failure::Unauthorized)?,
            )
        } else {
            None
        };
        self.edit(|s| {
            if let Some(identity) = identity {
                s.reset_authorizations.insert(profile_id.into(), identity);
            } else {
                s.reset_authorizations.remove(profile_id);
            }
        })
    }
    /// Display only: never project another identity's saved history after a slot relogin.
    pub(super) fn history_for_identity(
        &self,
        profile: &str,
        identity: &str,
    ) -> Result<Vec<MaintenanceEntryDto>> {
        let state = self.state.lock().map_err(|_| Failure::Unavailable)?;
        Ok(state
            .saved
            .entries
            .iter()
            .filter(|entry| {
                entry.profile_id == profile && entry.identity == identity && entry.kind == "warmup"
            })
            .map(Into::into)
            .collect())
    }
    pub fn status(&self) -> Result<AccountMaintenanceStatus> {
        let s = self.state.lock().map_err(|_| Failure::Unavailable)?;
        Ok(AccountMaintenanceStatus {
            phase: if s.running.is_some() {
                "running"
            } else if s.suspended {
                "blocked"
            } else if s.saved.settings.enabled() {
                "idle"
            } else {
                "disabled"
            },
            issue_code: s.issue.map(Failure::code),
            running_profile_id: s.running.clone(),
            entries: s.saved.entries.iter().map(Into::into).collect(),
            native_implementation_available: self.runtime.available(),
        })
    }
    pub fn cancel(&self) -> Result<AccountMaintenanceStatus> {
        self.epoch.fetch_add(1, Ordering::AcqRel);
        self.state.lock().map_err(|_| Failure::Unavailable)?.issue = Some(Failure::Cancelled);
        self.status()
    }
    pub fn cancel_for_exit(&self) {
        self.exiting.store(true, Ordering::Release);
        self.epoch.fetch_add(1, Ordering::AcqRel);
    }
    pub fn has_inflight_operation(&self) -> bool {
        self.operation.try_lock().is_err()
    }
    fn current(&self, epoch: u64) -> Result<()> {
        if self.exiting.load(Ordering::Acquire) || self.epoch.load(Ordering::Acquire) != epoch {
            return Err(Failure::Cancelled);
        }
        let s = self.state.try_lock().map_err(|_| Failure::Busy)?;
        if s.suspended {
            return Err(Failure::RecoveryRequired);
        }
        Ok(())
    }
    pub fn evaluate_once(self: &Arc<Self>) -> Result<AccountMaintenanceStatus> {
        let _operation = self.operation.try_lock().map_err(|_| Failure::Busy)?;
        let running = RunningStateReset(&self.state);
        let epoch = self.epoch.load(Ordering::Acquire);
        self.current(epoch)?;
        let settings = self
            .state
            .lock()
            .map_err(|_| Failure::Unavailable)?
            .saved
            .settings
            .clone();
        if !settings.enabled() {
            return self.status();
        }
        if !self.runtime.available() {
            return Err(Failure::Unavailable);
        }
        let catalog = self
            .manager
            .list_managed_accounts()
            .map_err(account_error)?;
        for profile in catalog.into_iter().filter(|p| p.platform == "codex") {
            self.current(epoch)?;
            let credential = match self.credential(&profile.id) {
                Ok(c) => c,
                Err(error) => {
                    self.state.lock().map_err(|_| Failure::Unavailable)?.issue = Some(error);
                    continue;
                }
            };
            if settings.five_hour_warmup || settings.seven_day_warmup {
                if let Err(error) = self.run_one(epoch, &settings, &credential, false) {
                    self.state.lock().map_err(|_| Failure::Unavailable)?.issue = Some(error);
                }
            }
            if settings.reset_authorizations.get(&profile.id)
                == Some(&credential.value.identity.identity_hash())
            {
                if let Err(error) = self.run_one(epoch, &settings, &credential, true) {
                    self.state.lock().map_err(|_| Failure::Unavailable)?.issue = Some(error);
                }
            }
        }
        drop(running);
        self.status()
    }
    fn credential(&self, id: &str) -> Result<Credential> {
        let store = self.manager.store().map_err(account_error)?;
        let record = store.vault.account(id).map_err(account_error)?.clone();
        let value = record.credential.clone().ok_or(Failure::Unauthorized)?;
        let (identity, expires) = parse_auth(&value.auth).map_err(account_error)?;
        if identity != value.identity || expires <= super::super::now() + 30 {
            return Err(Failure::QuotaUnknown);
        }
        let windows = windows(&value.quota, value.observed_at * 1000, now())?;
        let active_identity = store
            .vault
            .active
            .as_ref()
            .and_then(|p| store.vault.account(&p.account_id).ok())
            .and_then(|r| r.credential.as_ref())
            .is_some_and(|c| c.identity == identity);
        Ok(Credential {
            record,
            value,
            windows,
            active_identity,
        })
    }
    fn run_one(
        &self,
        epoch: u64,
        settings: &Settings,
        credential: &Credential,
        reset: bool,
    ) -> Result<()> {
        let id = &credential.record.id;
        let identity = credential.value.identity.identity_hash();
        let kind = if reset { "reset_credit" } else { "warmup" };
        let prior = self
            .state
            .lock()
            .map_err(|_| Failure::Unavailable)?
            .saved
            .entries
            .iter()
            .rev()
            .find(|e| e.identity == identity && e.kind == kind)
            .cloned();
        if !reset && !warmup_due(settings, &credential.windows, prior.as_ref(), now()) {
            return Ok(());
        }
        if reset
            && prior
                .as_ref()
                .is_some_and(|e| matches!(e.phase.as_str(), "running" | "uncertain"))
        {
            return Err(Failure::RecoveryRequired);
        }
        // Share only the reset operation fence with explicit manual redemption.
        // This does not hold the account vault/proxy/task reservation.
        let _manual_reset_guard = if reset {
            Some(
                super::manual_accounts::automatic_reset_guard(&self.manager, &identity)
                    .map_err(account_error)?,
            )
        } else {
            None
        };
        let _mutation = self
            .manager
            .mutation
            .try_lock()
            .map_err(|_| Failure::Busy)?;
        self.manager.require_recovered().map_err(account_error)?;
        self.manager.require_no_login().map_err(account_error)?;
        self.manager.expire_tickets().map_err(account_error)?;
        if !self
            .manager
            .tickets
            .lock()
            .map_err(|_| Failure::Busy)?
            .is_empty()
        {
            return Err(Failure::Busy);
        }
        self.current(epoch)?;
        if credential.active_identity {
            self.manager
                .runtime
                .require_system_idle()
                .map_err(account_error)?;
        }
        let writer = self
            .manager
            .credential_write(id, CredentialWritePurpose::Managed)
            .map_err(account_error)?;
        {
            let store = self.manager.store().map_err(account_error)?;
            let actual = store.vault.account(id).map_err(account_error)?;
            if actual.revision != credential.record.revision
                || actual.credential.as_ref().is_none_or(|c| {
                    c.generation != credential.value.generation || c.auth != credential.value.auth
                })
            {
                return Err(Failure::IdentityChanged);
            }
        }
        let entry = MaintenanceEntry {
            profile_id: id.clone(),
            kind: kind.into(),
            phase: "running".into(),
            issue_code: None,
            last_attempt_at_ms: Some(now()),
            last_succeeded_at_ms: prior.as_ref().and_then(|e| e.last_succeeded_at_ms),
            next_eligible_at_ms: None,
            identity: identity.clone(),
            generation: credential.value.generation.clone(),
            window_baseline: credential.windows.clone(),
            card_hash: None,
            idempotency_key: None,
            quota_fingerprint: None,
        };
        if !reset {
            self.record(entry.clone())?;
        }
        self.state.lock().map_err(|_| Failure::Unavailable)?.running = Some(id.clone());
        let claimed = AtomicBool::new(false);
        let claim_failure = Mutex::new(None);
        let claim = |card: &Card| -> Result<String> {
            let result = (|| {
                self.current(epoch)?;
                if settings.reset_authorizations.get(id) != Some(&identity) {
                    return Err(Failure::Unauthorized);
                }
                let time = now();
                if card.expires_at_ms <= time
                    || card.expires_at_ms - time > i64::from(settings.reset_lead_minutes) * 60000
                {
                    return Err(Failure::QuotaUnknown);
                }
                let card_hash = auth_digest(card.id.as_bytes());
                if prior.as_ref().is_some_and(|e| {
                    e.card_hash.as_ref() == Some(&card_hash)
                        && (e.phase != "deferred"
                            || e.next_eligible_at_ms.is_none_or(|at| at > time)
                            || e.quota_fingerprint.as_ref() == Some(&card.fingerprint))
                }) {
                    return Err(Failure::RecoveryRequired);
                }
                let nonce = super::super::nonce().map_err(account_error)?;
                let key = format!(
                    "{}-{}-{}-{}-{}",
                    &nonce[..8],
                    &nonce[8..12],
                    &nonce[12..16],
                    &nonce[16..20],
                    &nonce[20..]
                );
                let mut next = entry.clone();
                next.card_hash = Some(card_hash);
                next.idempotency_key = Some(key.clone());
                next.quota_fingerprint = Some(card.fingerprint.clone());
                self.record(next)?;
                claimed.store(true, Ordering::Release);
                Ok(key)
            })();
            if let Err(error) = result {
                *claim_failure.lock().map_err(|_| Failure::Unavailable)? = Some(error);
            }
            result
        };
        let admit = || -> Result<()> {
            self.current(epoch)?;
            writer.recheck().map_err(account_error)?;
            if credential.active_identity {
                self.manager
                    .runtime
                    .require_system_idle()
                    .map_err(account_error)?;
            }
            Ok(())
        };
        let staging = storage::private_tempdir(&self.manager.paths.staging(), "maintenance-")
            .map_err(account_error)?;
        storage::atomic_write(&staging.path().join("auth.json"), &credential.value.auth)
            .map_err(account_error)?;
        let execution = if reset {
            self.runtime
                .reset(staging.path(), &credential.value, &claim, &admit)
        } else {
            self.runtime.warmup(&credential.value, &admit)
        };
        let mut failure = None;
        let has_verified = execution.verified.is_some();
        if let Some(verified) = execution.verified {
            if verified.identity != credential.value.identity {
                failure = Some(Failure::IdentityChanged);
            } else {
                let mut store = self.manager.store().map_err(account_error)?;
                let record = store.vault.account_mut(id).map_err(account_error)?;
                if record.revision != credential.record.revision {
                    failure = Some(Failure::IdentityChanged);
                } else {
                    let generation = if verified.auth == credential.value.auth {
                        credential.value.generation.clone()
                    } else {
                        super::super::nonce().map_err(account_error)?
                    };
                    record.credential = Some(verified.into_stored(generation));
                    record.revision = record
                        .revision
                        .checked_add(1)
                        .ok_or(Failure::RecoveryRequired)?;
                    if writer.recheck().is_err() || store.save().is_err() {
                        failure = Some(Failure::RecoveryRequired);
                    }
                }
            }
        }
        let after = storage::read_optional(
            &staging.path().join("auth.json"),
            super::super::identity::MAX_AUTH_BYTES,
        )
        .map_err(account_error)?;
        if failure.is_some()
            || (after.as_deref() != Some(credential.value.auth.as_slice()) && !has_verified)
        {
            let kept = staging.keep();
            storage::atomic_write(
                &self
                    .manager
                    .paths
                    .vault_root
                    .join("maintenance-recovery.dpapi"),
                &self
                    .manager
                    .protector
                    .seal(
                        "AiGoodBro.Next.Windows.maintenance-recovery.v1",
                        kept.to_string_lossy().as_bytes(),
                    )
                    .map_err(account_error)?,
            )
            .map_err(account_error)?;
            failure = Some(Failure::RecoveryRequired);
        }
        if reset && !claimed.load(Ordering::Acquire) {
            // A preflight rejection has no consume intent. Preserve any prior
            // card receipt, including a completed card's durable replay fence.
            let issue = failure
                .or(*claim_failure.lock().map_err(|_| Failure::Unavailable)?)
                .unwrap_or_else(|| {
                    if matches!(self.current(epoch), Err(Failure::Cancelled)) {
                        Failure::Cancelled
                    } else {
                        Failure::ProtocolUnknown
                    }
                });
            let mut state = self.state.lock().map_err(|_| Failure::Unavailable)?;
            state.running = None;
            state.issue = Some(issue);
            return Ok(());
        }
        let mut final_entry = self
            .state
            .lock()
            .map_err(|_| Failure::Unavailable)?
            .saved
            .entries
            .iter()
            .rev()
            .find(|e| e.identity == identity && e.kind == kind)
            .cloned()
            .unwrap_or(entry);
        let at = now();
        let cancelled = matches!(self.current(epoch), Err(Failure::Cancelled));
        let issue = failure.or(match &execution.outcome {
            Outcome::NotSent if cancelled => Some(Failure::Cancelled),
            Outcome::NotSent => Some(Failure::ProtocolUnknown),
            Outcome::Unknown => Some(Failure::OutcomeUnknown),
            _ => None,
        });
        final_entry.phase = match execution.outcome {
            Outcome::Succeeded | Outcome::Reset | Outcome::NoCredit | Outcome::AlreadyRedeemed => {
                final_entry.last_succeeded_at_ms = Some(at);
                "succeeded"
            }
            Outcome::NothingToReset => {
                final_entry.next_eligible_at_ms = Some(at + 60000);
                "deferred"
            }
            Outcome::NotSent if cancelled => "cancelled",
            Outcome::NotSent => "blocked",
            Outcome::Unknown => "uncertain",
        }
        .into();
        final_entry.issue_code = issue.map(|e| e.code().into());
        if failure.is_some() {
            final_entry.phase = "uncertain".into();
        }
        self.record(final_entry)?;
        let mut state = self.state.lock().map_err(|_| Failure::Unavailable)?;
        state.running = None;
        state.issue = issue;
        Ok(())
    }
    fn record(&self, entry: MaintenanceEntry) -> Result<()> {
        let mut state = self.state.lock().map_err(|_| Failure::Unavailable)?;
        let mut next = state.saved.clone();
        next.entries
            .retain(|e| e.identity != entry.identity || e.kind != entry.kind);
        next.entries.push(entry);
        if next.entries.len() > 512 {
            return Err(Failure::RecoveryRequired);
        }
        if let Err(error) = save(&self.path, &next) {
            state.suspended = true;
            state.issue = Some(error);
            return Err(error);
        }
        state.saved = next;
        Ok(())
    }
    pub fn start_monitor(self: &Arc<Self>) -> Result<AccountMaintenanceMonitor> {
        self.start_monitor_with_listener(Arc::new(|| {}))
    }
    pub fn start_monitor_with_listener(
        self: &Arc<Self>,
        listener: Arc<dyn Fn() + Send + Sync>,
    ) -> Result<AccountMaintenanceMonitor> {
        if self.exiting.load(Ordering::Acquire) {
            return Err(Failure::Cancelled);
        }
        if self.monitor_active.swap(true, Ordering::AcqRel) {
            return Err(Failure::Busy);
        }
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = stop.clone();
        let service = Arc::downgrade(self);
        let worker = std::thread::Builder::new()
            .name("agb-account-maintenance".into())
            .spawn(move || {
                let mut next = Instant::now();
                while !thread_stop.load(Ordering::Acquire) {
                    let Some(service) = service.upgrade() else {
                        break;
                    };
                    if service.exiting.load(Ordering::Acquire) {
                        break;
                    }
                    if Instant::now() >= next {
                        if let Err(error) = service.evaluate_once() {
                            if let Ok(mut state) = service.state.lock() {
                                state.issue = Some(error);
                            }
                        }
                        listener();
                        next = Instant::now() + Duration::from_secs(60);
                    }
                    drop(service);
                    std::thread::sleep(Duration::from_millis(100));
                }
                if let Some(service) = service.upgrade() {
                    service.monitor_active.store(false, Ordering::Release);
                }
            })
            .map_err(|_| {
                self.monitor_active.store(false, Ordering::Release);
                Failure::Unavailable
            })?;
        Ok(AccountMaintenanceMonitor {
            service: Arc::downgrade(self),
            stop,
            _worker: worker,
        })
    }
}

#[cfg(test)]
#[path = "maintenance/tests.rs"]
mod tests;
pub struct AccountMaintenanceMonitor {
    service: Weak<AccountMaintenanceService>,
    stop: Arc<AtomicBool>,
    _worker: std::thread::JoinHandle<()>,
}
impl AccountMaintenanceMonitor {
    pub fn cancel(&self) {
        self.stop.store(true, Ordering::Release);
        if let Some(s) = self.service.upgrade() {
            let _ = s.cancel();
        }
    }
}
impl Drop for AccountMaintenanceMonitor {
    fn drop(&mut self) {
        self.cancel();
    }
}
fn read(path: &Path) -> Result<Stored> {
    let parent = path.parent().ok_or(Failure::InvalidSettings)?;
    if !path.is_absolute() || !crate::updates::safe_download_directory(parent) {
        return Err(Failure::InvalidSettings);
    }
    let Some(bytes) = storage::read_optional(path, 1024 * 1024).map_err(|_| Failure::SaveFailed)?
    else {
        return Ok(Stored::default());
    };
    let value: Stored = serde_json::from_slice(&bytes).map_err(|_| Failure::SaveFailed)?;
    value.validate()?;
    Ok(value)
}
fn save(path: &Path, value: &Stored) -> Result<()> {
    value.validate()?;
    let bytes = serde_json::to_vec(value).map_err(|_| Failure::SaveFailed)?;
    crate::atomic_settings::write_json(path, &bytes, |old| {
        let old: Stored = serde_json::from_slice(old)?;
        old.validate()?;
        Ok(())
    })
    .map_err(|_| Failure::SaveFailed)
}
