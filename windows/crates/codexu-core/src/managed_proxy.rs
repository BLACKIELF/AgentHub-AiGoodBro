//! Vault-backed proxy admission and account-switch exclusion.
//! The durable journal contains anonymous IDs only, never credentials or requests.
use crate::{accounts, proxy::*};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs::{File, OpenOptions},
    io::Read,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, Weak},
};

const MAX_RECORDS: usize = 2048;
const MAX_JOURNAL: u64 = 1024 * 1024;
const REFRESH_AGE: i64 = 45;

mod automatic;
pub use automatic::AutomaticMaintenanceLease;

fn now_ms() -> u64 {
    chrono::Utc::now().timestamp_millis().max(0) as u64
}
fn opaque_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn random_id() -> Result<String, ProxyFailure> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).map_err(|_| ProxyFailure::RegistryUnavailable)?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}
fn account_error(value: accounts::AccountError) -> ProxyFailure {
    match value.code {
        "evidence_stale" | "official_quota_unverified" => ProxyFailure::QuotaUnknown,
        "credentials_expired" | "login_required" => ProxyFailure::LoginExpired,
        "account_busy" | "account_store_busy" | "switch_in_progress" | "login_in_progress" => {
            ProxyFailure::AccountBusy
        }
        _ => ProxyFailure::Identity,
    }
}

struct Credential {
    evidence: AccountEvidence,
    access_token: String,
    account_id: String,
    expires_at: i64,
}
trait CredentialSource: Send + Sync {
    fn recheck_active_scope(
        &self,
        _scope: &accounts::ActiveSystemScope,
    ) -> accounts::AccountResult<()> {
        Err(accounts::AccountError {
            code: "active_scope_unverified",
        })
    }
    fn managed_ids(&self) -> Result<Vec<String>, ProxyFailure>;
    fn read(&self, id: &str, refresh: bool) -> Result<Credential, ProxyFailure>;
    fn identity(&self, id: &str) -> Result<Option<String>, ProxyFailure> {
        self.read(id, false).map(|c| Some(c.evidence.identity_hash))
    }
    fn read_desktop(
        &self,
        _claim: &DesktopWriterClaim,
        _proof: &DesktopQuotaEvidence,
    ) -> Result<Credential, ProxyFailure> {
        Err(ProxyFailure::QuotaUnknown)
    }
    fn desktop_display(
        &self,
        _claim: &DesktopWriterClaim,
        _proof: &DesktopQuotaEvidence,
    ) -> Result<accounts::CachedQuotaSnapshot, ProxyFailure> {
        Err(ProxyFailure::QuotaUnknown)
    }
    fn display(&self, _id: &str) -> Result<accounts::CachedQuotaSnapshot, ProxyFailure> {
        Err(ProxyFailure::QuotaUnknown)
    }
}
struct ManagedSource(Weak<accounts::AccountManager>);
impl CredentialSource for ManagedSource {
    fn recheck_active_scope(
        &self,
        scope: &accounts::ActiveSystemScope,
    ) -> accounts::AccountResult<()> {
        self.0
            .upgrade()
            .ok_or(accounts::AccountError {
                code: "active_scope_unverified",
            })?
            .recheck_active_system_scope(scope)
    }
    fn managed_ids(&self) -> Result<Vec<String>, ProxyFailure> {
        let manager = self.0.upgrade().ok_or(ProxyFailure::Unavailable)?;
        Ok(manager
            .list_managed_accounts()
            .map_err(account_error)?
            .into_iter()
            .filter(|account| account.platform == "codex")
            .map(|account| account.id)
            .collect())
    }
    fn read(&self, id: &str, refresh: bool) -> Result<Credential, ProxyFailure> {
        let manager = self.0.upgrade().ok_or(ProxyFailure::Unavailable)?;
        let snapshot = if refresh {
            manager.refresh_managed_credential(id)
        } else {
            manager.verified_credential_snapshot(id, REFRESH_AGE)
        }
        .map_err(account_error)?;
        Ok(credential_from_snapshot(id, snapshot, false))
    }
    fn identity(&self, id: &str) -> Result<Option<String>, ProxyFailure> {
        self.0
            .upgrade()
            .ok_or(ProxyFailure::Unavailable)?
            .managed_identity_hash(id)
            .map_err(account_error)
    }
    fn read_desktop(
        &self,
        claim: &DesktopWriterClaim,
        proof: &DesktopQuotaEvidence,
    ) -> Result<Credential, ProxyFailure> {
        let snapshot = self
            .0
            .upgrade()
            .ok_or(ProxyFailure::Unavailable)?
            .read_current_desktop_snapshot(claim, proof)
            .map_err(account_error)?;
        Ok(credential_from_snapshot(&claim.profile_id, snapshot, true))
    }
    fn desktop_display(
        &self,
        claim: &DesktopWriterClaim,
        proof: &DesktopQuotaEvidence,
    ) -> Result<accounts::CachedQuotaSnapshot, ProxyFailure> {
        let snapshot = self
            .0
            .upgrade()
            .ok_or(ProxyFailure::Unavailable)?
            .read_current_desktop_snapshot(claim, proof)
            .map_err(account_error)?;
        Ok(accounts::CachedQuotaSnapshot {
            plan: snapshot.plan,
            official_quota: snapshot.official_quota,
            observed_at: snapshot.observed_at,
        })
    }
    fn display(&self, id: &str) -> Result<accounts::CachedQuotaSnapshot, ProxyFailure> {
        let snapshot = self
            .0
            .upgrade()
            .ok_or(ProxyFailure::Unavailable)?
            .verified_credential_snapshot(id, REFRESH_AGE)
            .map_err(account_error)?;
        Ok(accounts::CachedQuotaSnapshot {
            plan: snapshot.plan,
            official_quota: snapshot.official_quota,
            observed_at: snapshot.observed_at,
        })
    }
}
fn credential_from_snapshot(
    id: &str,
    snapshot: accounts::VerifiedCredentialSnapshot,
    desktop: bool,
) -> Credential {
    let quota = crate::readers::CodexAppServerQuotaSnapshot::from_rate_limit_response(
        &snapshot.official_quota,
    );
    let limits = crate::readers::codex_app_server::selected_rate_limits(&snapshot.official_quota);
    let credits = limits.and_then(|v| v.get("credits"));
    let balance = credits.and_then(|v| v.get("balance")).and_then(|v| {
        let raw = match v {
            serde_json::Value::String(s) => s.trim().to_owned(),
            serde_json::Value::Number(n) => n.to_string(),
            _ => return None,
        };
        let raw = raw
            .strip_suffix(" POINTS")
            .unwrap_or(&raw)
            .trim()
            .to_owned();
        (quota.credit_balance_points.is_some()
            && raw.bytes().all(|b| b.is_ascii_digit() || b == b'.'))
        .then_some(raw)
    });
    let window = |w: Option<crate::RateWindow>| {
        w.and_then(|w| {
            w.resets_at.map(|reset| QuotaWindowEvidence {
                used_percent: w.used_percent,
                resets_at: reset.timestamp_millis() as f64 / 1000.0,
            })
        })
    };
    let evidence = AccountEvidence {
        profile_id: id.to_owned(),
        identity_hash: snapshot.identity_hash.clone(),
        token_generation: snapshot.token_generation.clone(),
        identity_verified: true,
        is_system_home: false,
        is_desktop: desktop,
        plan: snapshot.plan.clone(),
        quota: Some(QuotaEvidence {
            observed_at: snapshot.observed_at as f64,
            read_succeeded: quota.quota_read_succeeded,
            last_failure_at: None,
            identity_hash: snapshot.identity_hash.clone(),
            five_hour: window(quota.five_hour_quota),
            seven_day: window(quota.seven_day_quota),
            monthly: window(quota.monthly_quota),
            credit_balance: balance,
            credit_balance_unlimited: credits
                .and_then(|v| v.get("unlimited"))
                .and_then(|v| v.as_bool()),
        }),
    };
    let (access_token, account_id) =
        snapshot.with_secret(|token, account| (token.to_owned(), account.to_owned()));
    Credential {
        evidence,
        access_token,
        account_id,
        expires_at: snapshot.expires_at,
    }
}

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum Phase {
    Pending,
    Reserved,
    Released,
    Denied,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Reservation {
    request: String,
    profile: String,
    lease: String,
    identity: String,
    generation: String,
    phase: Phase,
    heartbeat_ms: u64,
    request_started_ms: u64,
    forget_after_ms: u64,
}
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum DesktopPhase {
    Preparing,
    AwaitingEvidence,
    Active,
    ExitedPendingImport,
}
/// No token, auth document, account response or quota payload is persisted here.
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct DesktopWriter {
    writer: String,
    profile: String,
    run: String,
    #[serde(default)]
    initial_run: Option<String>,
    identity: String,
    initial_generation: String,
    phase: DesktopPhase,
    prepare_consumed: bool,
    backend: Option<String>,
    observed_at: Option<f64>,
}
impl DesktopWriter {
    fn claim(&self) -> DesktopWriterClaim {
        DesktopWriterClaim {
            writer_id: self.writer.clone(),
            profile_id: self.profile.clone(),
            proxy_run_id: self.run.clone(),
            identity_hash: self.identity.clone(),
            initial_generation: self.initial_generation.clone(),
        }
    }
    fn matches(&self, claim: &DesktopWriterClaim) -> bool {
        self.writer == claim.writer_id
            && self.profile == claim.profile_id
            && self.run == claim.proxy_run_id
            && self.identity == claim.identity_hash
            && self.initial_generation == claim.initial_generation
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Journal {
    version: u32,
    active_run: Option<String>,
    records: Vec<Reservation>,
    #[serde(default)]
    desktop_writers: Vec<DesktopWriter>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    automatic_hold: Option<automatic::DurableReservation>,
}
impl Default for Journal {
    fn default() -> Self {
        Self {
            version: 1,
            active_run: None,
            records: vec![],
            desktop_writers: vec![],
            automatic_hold: None,
        }
    }
}
impl Journal {
    fn validate(&self) -> Result<(), ProxyFailure> {
        if self.version != 1
            || self.records.len() > MAX_RECORDS
            || self.desktop_writers.len() > 100
            || self.active_run.as_ref().is_some_and(|id| !opaque_id(id))
            || (self.active_run.is_none() && !self.records.is_empty())
            || self.automatic_hold.as_ref().is_some_and(|hold| {
                !hold.valid()
                    || self.active_run.is_some()
                    || !self.records.is_empty()
                    || !self.desktop_writers.is_empty()
            })
        {
            return Err(ProxyFailure::RegistryStateInvalid);
        }
        let mut seen = std::collections::BTreeSet::new();
        for r in &self.records {
            if !opaque_id(&r.request)
                || !opaque_id(&r.profile)
                || !opaque_id(&r.lease)
                || !seen.insert((&r.request, &r.profile))
                || (r.phase != Phase::Denied
                    && (r.identity.len() != 64
                        || !r.identity.bytes().all(|b| b.is_ascii_hexdigit())
                        || !opaque_id(&r.generation)))
            {
                return Err(ProxyFailure::RegistryStateInvalid);
            }
        }
        let mut profiles = std::collections::BTreeSet::new();
        let mut writers = std::collections::BTreeSet::new();
        let mut identities = std::collections::BTreeSet::new();
        for w in &self.desktop_writers {
            if !opaque_id(&w.writer)
                || !opaque_id(&w.profile)
                || !opaque_id(&w.run)
                || w.initial_run.as_ref().is_some_and(|run| !opaque_id(run))
                || !opaque_id(&w.initial_generation)
                || !identity_hash(&w.identity)
                || !profiles.insert(&w.profile)
                || !writers.insert(&w.writer)
                || !identities.insert(&w.identity)
                || w.backend.as_ref().is_some_and(|b| !opaque_id(b))
                || w.observed_at.is_some_and(|t| !t.is_finite() || t <= 0.0)
                || w.backend.is_some() != w.observed_at.is_some()
                || (w.phase == DesktopPhase::Active && (!w.prepare_consumed || w.backend.is_none()))
            {
                return Err(ProxyFailure::RegistryStateInvalid);
            }
        }
        Ok(())
    }
}
struct State {
    journal: Journal,
    poisoned: bool,
    maintenance: Option<String>,
    automatic_maintenance: Option<automatic::Reservation>,
    activities: BTreeMap<String, String>,
    credential_writers: BTreeMap<String, CredentialWriter>,
    /// Restarted processes cannot adopt an old ownership claim using its text.
    owned_desktop_writers: std::collections::BTreeSet<String>,
    recovered_desktop_receipts: BTreeMap<String, String>,
    owned_proxy_run: Option<String>,
    desktop_proofs: BTreeMap<String, DesktopQuotaEvidence>,
}
struct Shared {
    state: Mutex<State>,
    path: PathBuf,
    source: Arc<dyn CredentialSource>,
    _owner_lock: OwnerLock,
}

struct OwnerLock(File);
impl Drop for OwnerLock {
    fn drop(&mut self) {
        // A concurrent fork may temporarily inherit a CLOEXEC descriptor before
        // its exec. Explicitly unlock the owning open-file description so that
        // this non-owner child cannot prolong the registry owner's lifetime.
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            unsafe extern "C" {
                fn flock(fd: i32, operation: i32) -> i32;
            }
            let _ = unsafe { flock(self.0.as_raw_fd(), 8) };
        }
    }
}

/// Only one process may own this user's managed dispatch registry. A leftover
/// active run is not cleared by acquiring the process lock after a crash.
pub struct ManagedProxyGate {
    shared: Arc<Shared>,
}
impl ManagedProxyGate {
    pub fn new(
        root: PathBuf,
        accounts: &Arc<accounts::AccountManager>,
    ) -> Result<Arc<Self>, ProxyFailure> {
        Self::with_source(root, Arc::new(ManagedSource(Arc::downgrade(accounts))))
    }
    fn with_source(
        root: PathBuf,
        source: Arc<dyn CredentialSource>,
    ) -> Result<Arc<Self>, ProxyFailure> {
        if !crate::updates::safe_download_directory(&root) {
            return Err(ProxyFailure::RegistryStateInvalid);
        }
        std::fs::create_dir_all(&root).map_err(|_| ProxyFailure::RegistryUnavailable)?;
        if !crate::updates::safe_download_directory(&root) {
            return Err(ProxyFailure::RegistryStateInvalid);
        }
        let lock_path = root.join("dispatch.owner");
        reject_link(&lock_path)?;
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            options.share_mode(0);
        }
        let lock = options
            .open(lock_path)
            .map_err(|_| ProxyFailure::RegistryUnavailable)?;
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            unsafe extern "C" {
                fn flock(fd: i32, operation: i32) -> i32;
            }
            if unsafe { flock(lock.as_raw_fd(), 2 | 4) } != 0 {
                return Err(ProxyFailure::RegistryUnavailable);
            }
        }
        let path = root.join("dispatch-v1.json");
        let journal = match read(&path)? {
            Some(data) => serde_json::from_slice::<Journal>(&data)
                .map_err(|_| ProxyFailure::RegistryStateInvalid)?,
            None => Journal::default(),
        };
        journal.validate()?;
        let recovered_maintenance = journal
            .automatic_hold
            .as_ref()
            .map(|hold| hold.operation.clone());
        Ok(Arc::new(Self {
            shared: Arc::new(Shared {
                state: Mutex::new(State {
                    journal,
                    poisoned: false,
                    maintenance: recovered_maintenance,
                    automatic_maintenance: None,
                    activities: BTreeMap::new(),
                    credential_writers: BTreeMap::new(),
                    owned_desktop_writers: std::collections::BTreeSet::new(),
                    recovered_desktop_receipts: BTreeMap::new(),
                    owned_proxy_run: None,
                    desktop_proofs: BTreeMap::new(),
                }),
                path,
                source,
                _owner_lock: OwnerLock(lock),
            }),
        }))
    }
    fn lock(&self) -> Result<std::sync::MutexGuard<'_, State>, ProxyFailure> {
        let state = self
            .shared
            .state
            .try_lock()
            .map_err(|_| ProxyFailure::ControlBusy)?;
        if state.poisoned {
            return Err(ProxyFailure::RegistryUnavailable);
        }
        Ok(state)
    }
    fn persist(&self, state: &mut State) -> Result<(), ProxyFailure> {
        let result = (|| {
            state.journal.validate()?;
            reject_link(&self.shared.path)?;
            let data = serde_json::to_vec(&state.journal)
                .map_err(|_| ProxyFailure::RegistryStateInvalid)?;
            if data.len() as u64 > MAX_JOURNAL {
                return Err(ProxyFailure::RegistryStateInvalid);
            }
            crate::atomic_settings::write_json(&self.shared.path, &data, |prior| {
                serde_json::from_slice::<Journal>(prior)?.validate()?;
                Ok(())
            })
            .map_err(|_| ProxyFailure::RegistryUnavailable)
        })();
        if result.is_err() {
            state.poisoned = true;
        }
        result
    }
    fn credential(&self, id: &str, refresh: bool) -> Result<Credential, ProxyFailure> {
        let state = self.lock()?;
        if state
            .journal
            .desktop_writers
            .iter()
            .any(|w| w.profile == id)
        {
            return self.credential_locked(&state, id);
        }
        drop(state);
        let c = self.shared.source.read(id, refresh)?;
        let state = self.lock()?;
        if state
            .journal
            .desktop_writers
            .iter()
            .any(|w| w.profile == id)
            || state.credential_writers.contains_key(id)
            || self.write_blocks_identity(&state, &c.evidence.identity_hash)?
            || state
                .journal
                .desktop_writers
                .iter()
                .any(|w| w.identity == c.evidence.identity_hash)
        {
            return Err(ProxyFailure::AccountBusy);
        }
        checked_credential(c, id)
    }
    fn write_blocks_identity(&self, state: &State, identity: &str) -> Result<bool, ProxyFailure> {
        // A first login has no known identity yet and excludes every admission.
        // Known writers retain their identity for the entire write grant; never
        // reenter the account vault while its owner may be committing a write.
        Ok(state.credential_writers.values().any(|writer| {
            writer
                .identity
                .as_deref()
                .is_none_or(|value| value == identity)
        }))
    }
    fn credential_locked(&self, state: &State, id: &str) -> Result<Credential, ProxyFailure> {
        if state.credential_writers.contains_key(id) {
            return Err(ProxyFailure::AccountBusy);
        }
        let c = if let Some(w) = state
            .journal
            .desktop_writers
            .iter()
            .find(|w| w.profile == id)
        {
            if w.phase != DesktopPhase::Active
                || state.journal.active_run.as_deref() != Some(&w.run)
                || !state.owned_desktop_writers.contains(&w.writer)
            {
                return Err(ProxyFailure::QuotaUnknown);
            }
            let proof = state
                .desktop_proofs
                .get(&w.writer)
                .ok_or(ProxyFailure::QuotaUnknown)?;
            validate_desktop_proof(w, proof)?;
            self.shared.source.read_desktop(&w.claim(), proof)?
        } else {
            let c = self.shared.source.read(id, false)?;
            if state
                .journal
                .desktop_writers
                .iter()
                .any(|w| w.identity == c.evidence.identity_hash)
            {
                return Err(ProxyFailure::AccountBusy);
            }
            c
        };
        if self.write_blocks_identity(state, &c.evidence.identity_hash)? {
            return Err(ProxyFailure::AccountBusy);
        }
        checked_credential(c, id)
    }
    /// Display uses the same authenticated live Desktop observation as routing.
    /// Some means Desktop owns this account; errors must not fall back to a
    /// fresh-looking vault copy or trigger another official refresh process.
    pub fn desktop_quota_snapshot(
        &self,
        id: &str,
    ) -> Result<Option<accounts::CachedQuotaSnapshot>, ProxyFailure> {
        let state = self.lock()?;
        let Some(w) = state
            .journal
            .desktop_writers
            .iter()
            .find(|w| w.profile == id)
        else {
            return Ok(None);
        };
        if w.phase != DesktopPhase::Active
            || !state.owned_desktop_writers.contains(&w.writer)
            || state.journal.active_run.as_deref() != Some(&w.run)
        {
            return Err(ProxyFailure::QuotaUnknown);
        }
        let proof = state
            .desktop_proofs
            .get(&w.writer)
            .ok_or(ProxyFailure::QuotaUnknown)?;
        validate_desktop_proof(w, proof)?;
        self.shared
            .source
            .desktop_display(&w.claim(), proof)
            .map(Some)
    }
    /// Selection and pure read share one registry critical section, including
    /// aliases of an official identity. A concurrent claim cannot race the DTO.
    pub fn quota_snapshot(
        &self,
        id: &str,
        refresh: bool,
    ) -> Result<accounts::CachedQuotaSnapshot, ProxyFailure> {
        if refresh {
            self.credential(id, true)?;
        }
        let state = self.lock()?;
        if let Some(w) = state
            .journal
            .desktop_writers
            .iter()
            .find(|w| w.profile == id)
        {
            if w.phase != DesktopPhase::Active
                || !state.owned_desktop_writers.contains(&w.writer)
                || state.journal.active_run.as_deref() != Some(&w.run)
            {
                return Err(ProxyFailure::QuotaUnknown);
            }
            let proof = state
                .desktop_proofs
                .get(&w.writer)
                .ok_or(ProxyFailure::QuotaUnknown)?;
            validate_desktop_proof(w, proof)?;
            return self.shared.source.desktop_display(&w.claim(), proof);
        }
        if state.credential_writers.contains_key(id) {
            return Err(ProxyFailure::AccountBusy);
        }
        if !state.journal.desktop_writers.is_empty() {
            let identity = self
                .shared
                .source
                .identity(id)?
                .ok_or(ProxyFailure::Identity)?;
            if state
                .journal
                .desktop_writers
                .iter()
                .any(|w| w.identity == identity)
            {
                return Err(ProxyFailure::AccountBusy);
            }
        }
        self.shared.source.display(id)
    }
    /// Owned terminal launches and account switches share one exclusion domain.
    /// The caller retains this guard through launch, stop and confirmed exit.
    pub fn reserve_terminal(
        &self,
        identity_hash: &str,
    ) -> Result<ManagedActivityGuard, ProxyFailure> {
        let mut state = self.lock()?;
        if identity_hash.len() != 64 || !identity_hash.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(ProxyFailure::Identity);
        }
        if state.maintenance.is_some()
            || !state.credential_writers.is_empty()
            || state
                .journal
                .desktop_writers
                .iter()
                .any(|w| w.identity == identity_hash)
            || state.journal.records.iter().any(|r| {
                r.identity == identity_hash && matches!(r.phase, Phase::Pending | Phase::Reserved)
            })
            || state.activities.values().any(|hash| hash == identity_hash)
        {
            return Err(ProxyFailure::AccountBusy);
        }
        let id = random_id()?;
        state
            .activities
            .insert(id.clone(), identity_hash.to_owned());
        Ok(ManagedActivityGuard {
            shared: self.shared.clone(),
            id,
        })
    }
}
fn identity_hash(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|b| b.is_ascii_hexdigit())
}
fn checked_credential(c: Credential, id: &str) -> Result<Credential, ProxyFailure> {
    if c.evidence.profile_id != id
        || !c.evidence.identity_verified
        || c.evidence.is_system_home
        || c.access_token.is_empty()
        || c.account_id.is_empty()
        || c.expires_at <= (now_ms() / 1000) as i64 + 10
    {
        return Err(ProxyFailure::Identity);
    }
    Ok(c)
}
fn validate_desktop_proof(
    w: &DesktopWriter,
    proof: &DesktopQuotaEvidence,
) -> Result<(), ProxyFailure> {
    let now = now_ms() as f64 / 1000.0;
    if proof.writer_id != w.writer
        || proof.proxy_run_id != w.run
        || !opaque_id(&proof.backend_id)
        || !identity_hash(&proof.auth_digest)
        || !proof.observed_at.is_finite()
        || proof.observed_at <= 0.0
        || proof.observed_at > now + 5.0
        || now - proof.observed_at > REFRESH_AGE as f64
        || w.backend.as_ref().is_some_and(|b| b != &proof.backend_id)
    {
        return Err(ProxyFailure::QuotaUnknown);
    }
    Ok(())
}
fn writer_index(s: &State, claim: &DesktopWriterClaim) -> Result<usize, ProxyFailure> {
    if !s.owned_desktop_writers.contains(&claim.writer_id) {
        return Err(ProxyFailure::CleanupUnconfirmed);
    }
    s.journal
        .desktop_writers
        .iter()
        .position(|w| w.matches(claim))
        .ok_or(ProxyFailure::Identity)
}
fn read(path: &Path) -> Result<Option<Vec<u8>>, ProxyFailure> {
    reject_link(path)?;
    let meta = match std::fs::symlink_metadata(path) {
        Ok(m) => m,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(ProxyFailure::RegistryUnavailable),
    };
    if !meta.is_file() || meta.len() > MAX_JOURNAL {
        return Err(ProxyFailure::RegistryStateInvalid);
    }
    let mut bytes = vec![];
    File::open(path)
        .map_err(|_| ProxyFailure::RegistryUnavailable)?
        .take(MAX_JOURNAL + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| ProxyFailure::RegistryUnavailable)?;
    if bytes.len() as u64 > MAX_JOURNAL {
        return Err(ProxyFailure::RegistryStateInvalid);
    }
    Ok(Some(bytes))
}
fn reject_link(path: &Path) -> Result<(), ProxyFailure> {
    if let Ok(m) = std::fs::symlink_metadata(path) {
        if m.file_type().is_symlink() {
            return Err(ProxyFailure::RegistryStateInvalid);
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::MetadataExt;
            if m.file_attributes() & 0x400 != 0 {
                return Err(ProxyFailure::RegistryStateInvalid);
            }
        }
    }
    Ok(())
}
fn lease(r: &Reservation, run: &str, c: Credential) -> Result<CredentialLease, ProxyFailure> {
    if c.evidence.identity_hash != r.identity || c.evidence.token_generation != r.generation {
        return Err(ProxyFailure::Identity);
    }
    Ok(CredentialLease {
        tuple: LeaseTuple {
            run_id: run.into(),
            request_id: r.request.clone(),
            profile_id: r.profile.clone(),
            lease_id: r.lease.clone(),
        },
        access_token: c.access_token,
        account_id: c.account_id,
        expires_at: c.expires_at,
        identity_hash: r.identity.clone(),
        token_generation: r.generation.clone(),
    })
}
impl ProxyAccountGate for ManagedProxyGate {
    fn desktop_recovery_candidates(&self) -> Result<Vec<DesktopWriterClaim>, ProxyFailure> {
        let s = self.lock()?;
        Ok(s.journal
            .desktop_writers
            .iter()
            .filter(|w| {
                !s.owned_desktop_writers.contains(&w.writer)
                    || s.recovered_desktop_receipts.contains_key(&w.writer)
            })
            .map(DesktopWriter::claim)
            .collect())
    }
    fn recover_desktop_writer(
        &self,
        proof: &DesktopRecoveryProof,
    ) -> Result<DesktopWriterClaim, ProxyFailure> {
        let mut s = self.lock()?;
        let claim = proof.claim();
        if !identity_hash(proof.receipt_digest())
            || proof.owner_pid() < 2
            || proof.owner_created_at() == 0
        {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
        let i = s
            .journal
            .desktop_writers
            .iter()
            .position(|w| {
                w.writer == claim.writer_id
                    && w.profile == claim.profile_id
                    && w.identity == claim.identity_hash
                    && w.initial_generation == claim.initial_generation
                    && w.initial_run.as_deref().unwrap_or(&w.run) == claim.proxy_run_id
            })
            .ok_or(ProxyFailure::CleanupUnconfirmed)?;
        if s.owned_desktop_writers.contains(&claim.writer_id)
            && s.recovered_desktop_receipts
                .get(&claim.writer_id)
                .map(String::as_str)
                != Some(proof.receipt_digest())
        {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
        if s.maintenance.is_some()
            || !s.credential_writers.is_empty()
            || s.activities.contains_key(&claim.profile_id)
            || s.activities.values().any(|v| v == &claim.identity_hash)
            || s.journal.records.iter().any(|r| {
                (r.profile == claim.profile_id || r.identity == claim.identity_hash)
                    && matches!(r.phase, Phase::Pending | Phase::Reserved)
            })
        {
            return Err(ProxyFailure::AccountBusy);
        }
        let w = &s.journal.desktop_writers[i];
        match proof.kind() {
            DesktopRecoveryKind::Prepared
                if w.backend.is_some() || w.phase == DesktopPhase::Active =>
            {
                return Err(ProxyFailure::CleanupUnconfirmed)
            }
            DesktopRecoveryKind::Exited
                if !w.prepare_consumed || w.phase == DesktopPhase::Preparing =>
            {
                return Err(ProxyFailure::CleanupUnconfirmed)
            }
            _ => {}
        }
        // A private native proof authorizes import/abandon only. It never grants
        // quota authority, starts a process or retires a helper's request leases.
        s.journal.desktop_writers[i].phase = DesktopPhase::ExitedPendingImport;
        self.persist(&mut s)?;
        s.owned_desktop_writers.insert(claim.writer_id.clone());
        s.recovered_desktop_receipts
            .insert(claim.writer_id.clone(), proof.receipt_digest().into());
        s.desktop_proofs.remove(&claim.writer_id);
        Ok(s.journal.desktop_writers[i].claim())
    }
    fn proxy_run_recovery_candidate(&self) -> Result<Option<String>, ProxyFailure> {
        let s = self.lock()?;
        Ok(s.journal
            .active_run
            .as_ref()
            .filter(|run| s.owned_proxy_run.as_ref() != Some(*run))
            .cloned())
    }
    fn recover_proxy_run(&self, proof: &ProxyHelperRecoveryProof) -> Result<(), ProxyFailure> {
        let mut s = self.lock()?;
        if !identity_hash(proof.receipt_digest())
            || proof.owner_pid() < 2
            || proof.owner_created_at() == 0
            || s.journal.active_run.as_deref() != Some(proof.run_id())
            || s.owned_proxy_run.is_some()
        {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
        if s.maintenance.is_some() || !s.credential_writers.is_empty() || !s.activities.is_empty() {
            return Err(ProxyFailure::AccountBusy);
        }
        s.journal.active_run = None;
        s.journal.records.clear();
        // GUI writers require their own proof and credential reconciliation.
        self.persist(&mut s)
    }
    fn registration(&self, id: &str) -> Result<AccountRegistration, ProxyFailure> {
        if !opaque_id(id) {
            return Err(ProxyFailure::Identity);
        }
        let state = self.lock()?;
        if let Some(w) = state
            .journal
            .desktop_writers
            .iter()
            .find(|w| w.profile == id)
        {
            if !state.owned_desktop_writers.contains(&w.writer)
                || w.phase == DesktopPhase::ExitedPendingImport
            {
                return Err(ProxyFailure::CleanupUnconfirmed);
            }
            return Ok(AccountRegistration {
                profile_id: id.into(),
                identity_hash: w.identity.clone(),
            });
        }
        let identity = self
            .shared
            .source
            .identity(id)?
            .ok_or(ProxyFailure::Identity)?;
        if !identity_hash(&identity)
            || state
                .journal
                .desktop_writers
                .iter()
                .any(|w| w.identity == identity)
        {
            return Err(ProxyFailure::Identity);
        }
        Ok(AccountRegistration {
            profile_id: id.into(),
            identity_hash: identity,
        })
    }
    fn claim_desktop_writer(
        &self,
        profile: &str,
        run: &str,
        identity: &str,
        generation: &str,
    ) -> Result<DesktopWriterClaim, ProxyFailure> {
        let mut s = self.lock()?;
        if !opaque_id(profile)
            || !opaque_id(run)
            || !identity_hash(identity)
            || !opaque_id(generation)
            || s.journal.active_run.as_deref() != Some(run)
        {
            return Err(ProxyFailure::Identity);
        }
        if s.maintenance.is_some()
            || !s.credential_writers.is_empty()
            || s.activities.values().any(|hash| hash == identity)
            || s.journal
                .desktop_writers
                .iter()
                .any(|w| w.profile == profile || w.identity == identity)
            || s.journal.records.iter().any(|r| {
                (r.profile == profile || r.identity == identity)
                    && matches!(r.phase, Phase::Pending | Phase::Reserved)
            })
        {
            return Err(ProxyFailure::AccountBusy);
        }
        let credential = self.credential_locked(&s, profile)?;
        if credential.evidence.identity_hash != identity
            || credential.evidence.token_generation != generation
        {
            return Err(ProxyFailure::Identity);
        }
        let w = DesktopWriter {
            writer: random_id()?,
            profile: profile.into(),
            run: run.into(),
            initial_run: Some(run.into()),
            identity: identity.into(),
            initial_generation: generation.into(),
            phase: DesktopPhase::Preparing,
            prepare_consumed: false,
            backend: None,
            observed_at: None,
        };
        let claim = w.claim();
        s.journal.desktop_writers.push(w);
        self.persist(&mut s)?;
        s.owned_desktop_writers.insert(claim.writer_id.clone());
        Ok(claim)
    }
    fn recheck_desktop_writer(&self, claim: &DesktopWriterClaim) -> Result<(), ProxyFailure> {
        let s = self.lock()?;
        let i = writer_index(&s, claim)?;
        if s.journal.desktop_writers[i].phase == DesktopPhase::ExitedPendingImport {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
        Ok(())
    }
    fn rebind_desktop_writer(
        &self,
        claim: &DesktopWriterClaim,
        run: &str,
    ) -> Result<DesktopWriterClaim, ProxyFailure> {
        let mut s = self.lock()?;
        let i = writer_index(&s, claim)?;
        if !opaque_id(run)
            || s.journal.active_run.as_deref() != Some(run)
            || !matches!(
                s.journal.desktop_writers[i].phase,
                DesktopPhase::Active | DesktopPhase::AwaitingEvidence
            )
            || s.credential_writers.contains_key(&claim.profile_id)
        {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
        if claim.proxy_run_id == run {
            return Ok(claim.clone());
        }
        s.journal.desktop_writers[i].run = run.into();
        s.journal.desktop_writers[i].phase = DesktopPhase::AwaitingEvidence;
        s.desktop_proofs.remove(&claim.writer_id);
        self.persist(&mut s)?;
        Ok(s.journal.desktop_writers[i].claim())
    }
    fn accept_desktop_evidence(
        &self,
        claim: &DesktopWriterClaim,
        proof: DesktopQuotaEvidence,
    ) -> Result<(), ProxyFailure> {
        let mut s = self.lock()?;
        let i = writer_index(&s, claim)?;
        let w = &s.journal.desktop_writers[i];
        if s.journal.active_run.as_deref() != Some(&claim.proxy_run_id)
            || !matches!(
                w.phase,
                DesktopPhase::AwaitingEvidence | DesktopPhase::Active
            )
            || !w.prepare_consumed
            || s.credential_writers.contains_key(&claim.profile_id)
        {
            return Err(ProxyFailure::AccountBusy);
        }
        validate_desktop_proof(w, &proof)?;
        if w.observed_at.is_some_and(|old| proof.observed_at <= old) {
            return Err(ProxyFailure::QuotaUnknown);
        }
        let credential = checked_credential(
            self.shared.source.read_desktop(claim, &proof)?,
            &claim.profile_id,
        )?;
        if credential.evidence.identity_hash != claim.identity_hash
            || !credential.evidence.is_desktop
        {
            return Err(ProxyFailure::Identity);
        }
        let w = &mut s.journal.desktop_writers[i];
        w.backend = Some(proof.backend_id.clone());
        w.observed_at = Some(proof.observed_at);
        w.phase = DesktopPhase::Active;
        self.persist(&mut s)?;
        s.desktop_proofs.insert(claim.writer_id.clone(), proof);
        Ok(())
    }
    fn confirm_desktop_exit(&self, claim: &DesktopWriterClaim) -> Result<(), ProxyFailure> {
        let mut s = self.lock()?;
        let i = writer_index(&s, claim)?;
        if s.credential_writers.contains_key(&claim.profile_id)
            || s.journal.records.iter().any(|r| {
                (r.profile == claim.profile_id || r.identity == claim.identity_hash)
                    && matches!(r.phase, Phase::Pending | Phase::Reserved)
            })
        {
            return Err(ProxyFailure::AccountBusy);
        }
        if s.journal.desktop_writers[i].phase != DesktopPhase::ExitedPendingImport {
            s.journal.desktop_writers[i].phase = DesktopPhase::ExitedPendingImport;
            s.desktop_proofs.remove(&claim.writer_id);
            self.persist(&mut s)?;
        }
        Ok(())
    }
    fn release_desktop_writer(&self, claim: &DesktopWriterClaim) -> Result<(), ProxyFailure> {
        let mut s = self.lock()?;
        let i = writer_index(&s, claim)?;
        if s.journal.desktop_writers[i].phase != DesktopPhase::ExitedPendingImport
            || s.credential_writers.contains_key(&claim.profile_id)
        {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
        s.journal.desktop_writers.remove(i);
        self.persist(&mut s)?;
        s.owned_desktop_writers.remove(&claim.writer_id);
        s.recovered_desktop_receipts.remove(&claim.writer_id);
        s.desktop_proofs.remove(&claim.writer_id);
        Ok(())
    }
    fn managed_profile_ids(&self) -> Result<Vec<String>, ProxyFailure> {
        drop(self.lock()?);
        self.shared.source.managed_ids()
    }
    fn activate_run(&self, id: &str) -> Result<(), ProxyFailure> {
        if !opaque_id(id) {
            return Err(ProxyFailure::Identity);
        }
        let mut s = self.lock()?;
        if s.journal.active_run.is_some()
            || !s.journal.records.is_empty()
            || s.maintenance.is_some()
            || s.journal.desktop_writers.iter().any(|w| {
                w.phase == DesktopPhase::ExitedPendingImport
                    || !s.owned_desktop_writers.contains(&w.writer)
            })
        {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
        s.journal.active_run = Some(id.into());
        self.persist(&mut s)?;
        s.owned_proxy_run = Some(id.into());
        Ok(())
    }
    fn evidence(&self, id: &str) -> Result<AccountEvidence, ProxyFailure> {
        if !opaque_id(id) {
            return Err(ProxyFailure::Identity);
        }
        drop(self.lock()?);
        match self.credential(id, false) {
            Ok(c) => Ok(c.evidence),
            Err(ProxyFailure::QuotaUnknown | ProxyFailure::LoginExpired) => {
                Ok(self.credential(id, true)?.evidence)
            }
            Err(e) => Err(e),
        }
    }
    fn reserve(&self, r: &AdmissionRequest) -> Result<CredentialLease, ProxyFailure> {
        let mut s = self.lock()?;
        if s.journal.active_run.as_deref() != Some(&r.run_id)
            || !opaque_id(&r.request_id)
            || !opaque_id(&r.profile_id)
        {
            return Err(ProxyFailure::AcquireAbandoned);
        }
        if s.maintenance.is_some()
            || s.activities
                .values()
                .any(|hash| hash == &r.expected_identity_hash)
        {
            return Err(ProxyFailure::AccountBusy);
        }
        let now = now_ms();
        if r.request_started_at_unix_ms > now
            || now - r.request_started_at_unix_ms >= 16 * 60 * 1000
        {
            return Err(ProxyFailure::AdmissionDeadline);
        }
        if let Some(old) = s
            .journal
            .records
            .iter()
            .find(|v| v.request == r.request_id && v.profile == r.profile_id)
        {
            if old.request_started_ms != r.request_started_at_unix_ms {
                return Err(ProxyFailure::AcquireAbandoned);
            }
            if old.phase != Phase::Reserved {
                return Err(ProxyFailure::AcquireAbandoned);
            }
            return lease(old, &r.run_id, self.credential_locked(&s, &r.profile_id)?);
        }
        if r.deadline_unix_ms <= now_ms() || r.deadline_unix_ms > now_ms() + 30_000 {
            return Err(ProxyFailure::AdmissionDeadline);
        }
        if s.journal.records.iter().any(|v| {
            v.profile == r.profile_id && matches!(v.phase, Phase::Pending | Phase::Reserved)
        }) {
            return Err(ProxyFailure::AccountBusy);
        }
        s.journal.records.retain(|v| {
            matches!(v.phase, Phase::Pending | Phase::Reserved) || v.forget_after_ms > now
        });
        if s.journal.records.len() >= MAX_RECORDS {
            return Err(ProxyFailure::ControlBusy);
        }
        let c = self.credential_locked(&s, &r.profile_id)?;
        if c.evidence.identity_hash != r.expected_identity_hash
            || c.evidence.token_generation != r.expected_generation
            || c.evidence.is_desktop != r.pass.desktop()
        {
            return Err(ProxyFailure::Identity);
        }
        quota_admission(
            &c.evidence,
            &r.policy,
            now_ms() as f64 / 1000.0,
            r.credit_floor,
            r.pass.credit(),
        )?;
        let mut record = Reservation {
            request: r.request_id.clone(),
            profile: r.profile_id.clone(),
            lease: random_id()?,
            identity: r.expected_identity_hash.clone(),
            generation: r.expected_generation.clone(),
            phase: Phase::Pending,
            heartbeat_ms: now_ms(),
            request_started_ms: r.request_started_at_unix_ms,
            forget_after_ms: now_ms() + 17 * 60 * 1000,
        };
        s.journal.records.push(record.clone());
        self.persist(&mut s)?;
        // Durable intent precedes the final generation/deadline check. Failure
        // installs a tombstone before returning; it never returns credentials.
        let current = self.credential_locked(&s, &r.profile_id);
        let checked = current.and_then(|c| {
            if r.deadline_unix_ms <= now_ms() {
                return Err(ProxyFailure::AdmissionDeadline);
            }
            quota_admission(
                &c.evidence,
                &r.policy,
                now_ms() as f64 / 1000.0,
                r.credit_floor,
                r.pass.credit(),
            )?;
            lease(&record, &r.run_id, c)
        });
        record.phase = if checked.is_ok() {
            Phase::Reserved
        } else {
            Phase::Denied
        };
        *s.journal
            .records
            .last_mut()
            .ok_or(ProxyFailure::RegistryStateInvalid)? = record;
        self.persist(&mut s)?;
        checked
    }
    fn resolve(&self, t: &LeaseTuple) -> Result<AdmissionResolution, ProxyFailure> {
        let mut s = self.lock()?;
        if s.journal.active_run.as_deref() != Some(&t.run_id) {
            return Err(ProxyFailure::AcquireAbandoned);
        }
        if let Some(index) = s
            .journal
            .records
            .iter()
            .position(|v| v.request == t.request_id && v.profile == t.profile_id)
        {
            let r = &s.journal.records[index];
            if !t.lease_id.is_empty() && t.lease_id != r.lease {
                return Err(ProxyFailure::Identity);
            }
            if r.phase == Phase::Reserved {
                return Ok(AdmissionResolution::Reserved(lease(
                    r,
                    &t.run_id,
                    self.credential_locked(&s, &t.profile_id)?,
                )?));
            }
            if r.phase == Phase::Released {
                return Ok(AdmissionResolution::RolledBack);
            }
            s.journal.records[index].phase = Phase::Denied;
            self.persist(&mut s)?;
            return Ok(AdmissionResolution::NotReserved);
        }
        if !opaque_id(&t.request_id)
            || !opaque_id(&t.profile_id)
            || s.journal.records.len() >= MAX_RECORDS
        {
            return Err(ProxyFailure::RegistryStateInvalid);
        }
        s.journal.records.push(Reservation {
            request: t.request_id.clone(),
            profile: t.profile_id.clone(),
            lease: random_id()?,
            identity: String::new(),
            generation: String::new(),
            phase: Phase::Denied,
            heartbeat_ms: now_ms(),
            request_started_ms: 0,
            forget_after_ms: now_ms() + 17 * 60 * 1000,
        });
        self.persist(&mut s)?;
        Ok(AdmissionResolution::NotReserved)
    }
    fn heartbeat(&self, t: &LeaseTuple) -> Result<(), ProxyFailure> {
        let mut s = self.lock()?;
        exact(&s, t)?;
        let r = s
            .journal
            .records
            .iter_mut()
            .find(|r| r.lease == t.lease_id)
            .ok_or(ProxyFailure::Identity)?;
        if r.phase != Phase::Reserved {
            return Err(ProxyFailure::AcquireAbandoned);
        }
        r.heartbeat_ms = now_ms();
        self.persist(&mut s)
    }
    fn release(&self, t: &LeaseTuple) -> Result<(), ProxyFailure> {
        let mut s = self.lock()?;
        exact(&s, t)?;
        let r = s
            .journal
            .records
            .iter_mut()
            .find(|r| r.lease == t.lease_id)
            .ok_or(ProxyFailure::Identity)?;
        if r.phase == Phase::Released {
            return Ok(());
        }
        if r.phase != Phase::Reserved {
            return Err(ProxyFailure::AcquireAbandoned);
        }
        r.phase = Phase::Released;
        self.persist(&mut s)
    }
    fn retire_run(&self, id: &str, confirmed: bool) -> Result<(), ProxyFailure> {
        let mut s = self.lock()?;
        if !confirmed || s.journal.active_run.as_deref() != Some(id) {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
        s.journal.active_run = None;
        s.journal.records.clear();
        self.persist(&mut s)?;
        s.owned_proxy_run = None;
        Ok(())
    }
    fn refresh_quota(&self, ids: &[String], deadline: u64) -> Result<(), ProxyFailure> {
        if ids.len() > 100 {
            return Err(ProxyFailure::InvalidSettings);
        }
        for id in ids {
            if now_ms() >= deadline {
                return Err(ProxyFailure::AdmissionDeadline);
            }
            self.credential(id, true)?;
        }
        if now_ms() >= deadline {
            return Err(ProxyFailure::AdmissionDeadline);
        }
        Ok(())
    }
}
fn exact(s: &State, t: &LeaseTuple) -> Result<(), ProxyFailure> {
    if s.journal.active_run.as_deref() != Some(&t.run_id)
        || !s.journal.records.iter().any(|r| {
            r.request == t.request_id && r.profile == t.profile_id && r.lease == t.lease_id
        })
    {
        return Err(ProxyFailure::Identity);
    }
    Ok(())
}

pub struct ManagedActivityGuard {
    shared: Arc<Shared>,
    id: String,
}
impl Drop for ManagedActivityGuard {
    fn drop(&mut self) {
        if let Ok(mut s) = self.shared.state.lock() {
            s.activities.remove(&self.id);
        }
    }
}
struct MaintenanceGuard {
    shared: Arc<Shared>,
    id: String,
}
struct CredentialWriteGuard {
    shared: Arc<Shared>,
    profile: String,
    id: String,
}
struct CredentialWriter {
    id: String,
    purpose: accounts::CredentialWritePurpose,
    identity: Option<String>,
    automatic_operation: Option<String>,
}
fn check_write_purpose(
    s: &State,
    profile: &str,
    purpose: &accounts::CredentialWritePurpose,
) -> accounts::AccountResult<()> {
    use accounts::CredentialWritePurpose;
    let denied = || accounts::AccountError {
        code: "account_busy",
    };
    match purpose {
        CredentialWritePurpose::Managed => {
            if s.journal
                .desktop_writers
                .iter()
                .any(|w| w.profile == profile)
                || !s.activities.is_empty()
                || s.journal.records.iter().any(|r| {
                    r.profile == profile && matches!(r.phase, Phase::Pending | Phase::Reserved)
                })
            {
                return Err(denied());
            }
        }
        CredentialWritePurpose::DesktopPrepare { writer_id }
        | CredentialWritePurpose::DesktopFinalize { writer_id } => {
            let w = s
                .journal
                .desktop_writers
                .iter()
                .find(|w| w.profile == profile && &w.writer == writer_id)
                .ok_or_else(denied)?;
            let expected = if matches!(purpose, CredentialWritePurpose::DesktopPrepare { .. }) {
                DesktopPhase::Preparing
            } else {
                DesktopPhase::ExitedPendingImport
            };
            if w.phase != expected
                || !s.owned_desktop_writers.contains(writer_id)
                || s.journal.records.iter().any(|r| {
                    (r.profile == profile || r.identity == w.identity)
                        && matches!(r.phase, Phase::Pending | Phase::Reserved)
                })
                || s.activities.values().any(|hash| hash == &w.identity)
            {
                return Err(denied());
            }
        }
    }
    Ok(())
}
fn check_managed_write_identity(s: &State, identity: Option<&str>) -> accounts::AccountResult<()> {
    if s.journal.desktop_writers.is_empty()
        && !s
            .journal
            .records
            .iter()
            .any(|r| matches!(r.phase, Phase::Pending | Phase::Reserved))
    {
        return Ok(());
    }
    let unknown = || accounts::AccountError {
        code: "occupancy_unknown",
    };
    let identity = identity.ok_or_else(unknown)?;
    if s.journal
        .desktop_writers
        .iter()
        .any(|w| w.identity == identity)
        || s.journal
            .records
            .iter()
            .any(|r| r.identity == identity && matches!(r.phase, Phase::Pending | Phase::Reserved))
    {
        return Err(accounts::AccountError {
            code: "account_busy",
        });
    }
    Ok(())
}
impl accounts::AccountOccupancyGate for ManagedProxyGate {
    fn adopt_automatic_maintenance(
        &self,
        lease: &AutomaticMaintenanceLease,
        target: &str,
    ) -> accounts::AccountResult<Box<dyn accounts::SwitchMaintenanceLease>> {
        self.adopt_automatic(lease, target)
    }
    fn acquire_automatic_credential_write(
        &self,
        lease: &AutomaticMaintenanceLease,
        target: &str,
    ) -> accounts::AccountResult<Box<dyn accounts::CredentialWriteLease>> {
        self.automatic_credential_write(lease, target)
    }
    fn acquire_switch_maintenance(
        &self,
        _account: &str,
        operation: &str,
    ) -> accounts::AccountResult<Box<dyn accounts::SwitchMaintenanceLease>> {
        let fail = || accounts::AccountError {
            code: "occupancy_unknown",
        };
        let mut s = self.lock().map_err(|_| fail())?;
        // A stopped run with unfinished durable records is still not idle.
        if s.maintenance.is_some()
            || !s.activities.is_empty()
            || s.journal.active_run.is_some()
            || !s.credential_writers.is_empty()
            || !s.journal.desktop_writers.is_empty()
        {
            return Err(accounts::AccountError {
                code: "account_busy",
            });
        }
        s.maintenance = Some(operation.into());
        Ok(Box::new(MaintenanceGuard {
            shared: self.shared.clone(),
            id: operation.into(),
        }))
    }
    fn acquire_credential_write(
        &self,
        profile: &str,
        purpose: accounts::CredentialWritePurpose,
    ) -> accounts::AccountResult<Box<dyn accounts::CredentialWriteLease>> {
        let fail = || accounts::AccountError {
            code: "occupancy_unknown",
        };
        let mut s = self.lock().map_err(|_| fail())?;
        if !opaque_id(profile)
            || !s.credential_writers.is_empty()
            || s.journal.automatic_hold.is_some()
        {
            return Err(accounts::AccountError {
                code: "account_busy",
            });
        }
        check_write_purpose(&s, profile, &purpose)?;
        let identity = match &purpose {
            accounts::CredentialWritePurpose::Managed => {
                // This read happens before AccountManager takes its commit
                // lock. It verifies identity/revision again under that lock;
                // recheck below must only consult this atomic occupancy state.
                let identity = self
                    .shared
                    .source
                    .identity(profile)
                    .ok()
                    .flatten()
                    .filter(|value| identity_hash(value));
                check_managed_write_identity(&s, identity.as_deref())?;
                identity
            }
            accounts::CredentialWritePurpose::DesktopPrepare { writer_id }
            | accounts::CredentialWritePurpose::DesktopFinalize { writer_id } => s
                .journal
                .desktop_writers
                .iter()
                .find(|w| &w.writer == writer_id)
                .map(|w| w.identity.clone()),
        };
        if let accounts::CredentialWritePurpose::DesktopPrepare { writer_id } = &purpose {
            let w = s
                .journal
                .desktop_writers
                .iter_mut()
                .find(|w| &w.writer == writer_id)
                .ok_or_else(fail)?;
            if w.prepare_consumed {
                return Err(accounts::AccountError {
                    code: "account_busy",
                });
            }
            w.prepare_consumed = true;
            self.persist(&mut s).map_err(|_| fail())?;
        }
        let id = random_id().map_err(|_| fail())?;
        s.credential_writers.insert(
            profile.into(),
            CredentialWriter {
                id: id.clone(),
                purpose,
                identity,
                automatic_operation: None,
            },
        );
        Ok(Box::new(CredentialWriteGuard {
            shared: self.shared.clone(),
            profile: profile.into(),
            id,
        }))
    }
}
impl accounts::CredentialWriteLease for CredentialWriteGuard {
    fn recheck(&self) -> accounts::AccountResult<()> {
        let fail = || accounts::AccountError {
            code: "occupancy_unknown",
        };
        let s = self.shared.state.try_lock().map_err(|_| fail())?;
        if s.poisoned {
            return Err(fail());
        }
        let writer = s.credential_writers.get(&self.profile).ok_or_else(fail)?;
        if writer.id != self.id {
            return Err(fail());
        }
        if let Some(operation) = &writer.automatic_operation {
            if s.maintenance.as_ref() != Some(operation)
                || !s
                    .automatic_maintenance
                    .as_ref()
                    .is_some_and(|r| r.target == self.profile)
            {
                return Err(fail());
            }
        } else if s.automatic_maintenance.is_some() {
            return Err(fail());
        }
        check_write_purpose(&s, &self.profile, &writer.purpose)?;
        if matches!(writer.purpose, accounts::CredentialWritePurpose::Managed) {
            check_managed_write_identity(&s, writer.identity.as_deref())?;
        }
        Ok(())
    }
}
impl Drop for CredentialWriteGuard {
    fn drop(&mut self) {
        if let Ok(mut s) = self.shared.state.lock() {
            if s.credential_writers
                .get(&self.profile)
                .is_some_and(|writer| writer.id == self.id)
            {
                let writer = s.credential_writers.remove(&self.profile).unwrap();
                if let accounts::CredentialWritePurpose::DesktopPrepare { writer_id } =
                    writer.purpose
                {
                    if let Some(w) = s
                        .journal
                        .desktop_writers
                        .iter_mut()
                        .find(|w| w.writer == writer_id && w.phase == DesktopPhase::Preparing)
                    {
                        w.phase = DesktopPhase::AwaitingEvidence;
                        let gate = ManagedProxyGate {
                            shared: self.shared.clone(),
                        };
                        let _ = gate.persist(&mut s);
                    }
                }
            }
        }
    }
}
impl accounts::SwitchMaintenanceLease for MaintenanceGuard {
    fn recheck(&self) -> accounts::AccountResult<()> {
        let s = self
            .shared
            .state
            .try_lock()
            .map_err(|_| accounts::AccountError {
                code: "occupancy_unknown",
            })?;
        if s.poisoned
            || s.maintenance.as_deref() != Some(&self.id)
            || !s.activities.is_empty()
            || s.journal.active_run.is_some()
            || !s.journal.desktop_writers.is_empty()
        {
            return Err(accounts::AccountError {
                code: "account_busy",
            });
        }
        Ok(())
    }
}
impl Drop for MaintenanceGuard {
    fn drop(&mut self) {
        if let Ok(mut s) = self.shared.state.lock() {
            if s.maintenance.as_deref() == Some(&self.id) {
                s.maintenance = None;
            }
        }
    }
}

pub struct ManagedProxySecrets(pub Weak<accounts::AccountManager>);
impl ProxySecretStore for ManagedProxySecrets {
    fn load_client_key(&self) -> Result<Option<String>, ProxyFailure> {
        self.0
            .upgrade()
            .ok_or(ProxyFailure::Unavailable)?
            .load_secret("proxy.client_key")
            .map_err(account_error)
    }
    fn save_client_key(&self, key: &str) -> Result<(), ProxyFailure> {
        self.0
            .upgrade()
            .ok_or(ProxyFailure::Unavailable)?
            .save_secret("proxy.client_key", Some(key))
            .map_err(account_error)
    }
    fn load_mihomo_secret(&self) -> Result<Option<String>, ProxyFailure> {
        self.0
            .upgrade()
            .ok_or(ProxyFailure::Unavailable)?
            .load_secret("proxy.mihomo_secret")
            .map_err(account_error)
    }
}

#[cfg(test)]
mod tests;
