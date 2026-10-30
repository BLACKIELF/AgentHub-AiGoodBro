//! Explicit manual account actions. Tokens/card IDs stay in the native process;
//! proxy leases and unrelated login/switch work are not admission conditions.
use super::super::identity::StoredCredential;
use super::*;
use crate::accounts::AccountError;
use crate::notifications::ManualResetAuthorization;
use serde::{Deserialize, Serialize};
use serde_json::Value;
#[cfg(windows)]
use std::time::{Duration, Instant};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::Path,
};
#[path = "manual_accounts/native.rs"]
mod native;
#[path = "manual_accounts/referral.rs"]
mod referral;
pub use referral::{ReferralBatch, ReferralPage, ReferralReview};
#[path = "manual_accounts/monitor.rs"]
mod monitor;
pub use monitor::ManualAccountMonitor;

const CONTEXT: &str = "AiGoodBro.Next.Windows.manual-account-actions.v1";
const MAX_STATE: usize = 1024 * 1024;
fn ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}
fn hash_ok(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}
fn safe_label(s: &str) -> String {
    let s = s.trim();
    if !s.is_empty()
        && s.chars().count() <= 64
        && s.chars()
            .all(|c| c.is_alphanumeric() || " .-_·()（）•*".contains(c))
    {
        s.into()
    } else {
        "Account".into()
    }
}
#[path = "manual_accounts/details.rs"]
mod details;
pub use details::LocalDetails;
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResetReview {
    pub review_id: String,
    pub profile_id: String,
    pub checked_at_ms: i64,
    pub expires_at_ms: i64,
    pub available_count: u32,
    pub card_expires_at_ms: i64,
    pub remaining5h_percent: Option<f64>,
    pub remaining7d_percent: Option<f64>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ManualResetConfirmation {
    pub event_id: String,
    pub profile_id: String,
    /// Already hashed: exactly AccountIdentity::identity_hash(), not the raw account ID.
    pub account_key: String,
    pub masked_label: String,
    pub confirmed_at_ms: i64,
    pub available_cards: Option<u32>,
    #[serde(default)]
    pub authorization: ManualResetAuthorization,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResetResult {
    pub profile_id: String,
    pub outcome: &'static str,
    pub manual_confirmation: Option<ManualResetSummary>,
    pub issue_code: Option<&'static str>,
}
/// Safe renderer receipt: notification authorization is native-only.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ManualResetSummary {
    pub event_id: String,
    pub profile_id: String,
    pub account_key: String,
    pub masked_label: String,
    pub confirmed_at_ms: i64,
    pub available_cards: Option<u32>,
}
impl From<&ManualResetConfirmation> for ManualResetSummary {
    fn from(e: &ManualResetConfirmation) -> Self {
        Self {
            event_id: e.event_id.clone(),
            profile_id: e.profile_id.clone(),
            account_key: e.account_key.clone(),
            masked_label: e.masked_label.clone(),
            confirmed_at_ms: e.confirmed_at_ms,
            available_cards: e.available_cards,
        }
    }
}
#[derive(Clone)]
struct ResetTicket {
    dto: ResetReview,
    identity: String,
    card_id: String,
    confirmed: bool,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PendingReset {
    profile: String,
    identity: String,
    card: String,
    card_expiry: i64,
    key: String,
}
#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Journal {
    #[serde(default)]
    pending: BTreeMap<String, PendingReset>,
    #[serde(default)]
    confirmations: BTreeMap<String, ManualResetConfirmation>,
    #[serde(default)]
    delivered: BTreeSet<String>,
    // Hash(identity + recipient), never recipient addresses. Unknown sends stay blocked.
    #[serde(default)]
    referral_attempts: BTreeSet<String>,
}
impl Journal {
    fn validate(&self) -> AccountResult<()> {
        if self.confirmations.len() > 1024
            || self.delivered.len() > 1024
            || self.referral_attempts.len() > 4096
            || self.pending.len() > 1024
            || self.pending.iter().any(|(k, p)| {
                k != &p.identity
                    || !storage::valid_id(&p.profile)
                    || !hash_ok(&p.identity)
                    || !hash_ok(&p.card)
                    || !storage::valid_id(&p.key)
                    || p.card_expiry <= 0
            })
            || self.referral_attempts.iter().any(|v| !hash_ok(v))
            || self
                .delivered
                .iter()
                .any(|v| !v.starts_with("manual-reset-") || !hash_ok(&v[13..]))
            || self.confirmations.iter().any(|(k, v)| {
                k != &v.event_id
                    || !k.starts_with("manual-reset-")
                    || !hash_ok(&k[13..])
                    || !storage::valid_id(&v.profile_id)
                    || !hash_ok(&v.account_key)
                    || v.confirmed_at_ms <= 0
                    || safe_label(&v.masked_label) != v.masked_label
            })
        {
            return Err(fail("manual_action_recovery_required"));
        }
        Ok(())
    }
}
fn state_root(manager: &AccountManager) -> PathBuf {
    manager.paths.vault_root.join("manual-actions")
}
fn read_journal(manager: &AccountManager) -> AccountResult<Journal> {
    let path = state_root(manager).join("journal.dpapi");
    let Some(bytes) = storage::read_optional(&path, MAX_STATE)? else {
        return Ok(Journal::default());
    };
    let bytes = manager.protector.unseal(CONTEXT, &bytes)?;
    if bytes.len() > MAX_STATE {
        return Err(fail("manual_action_recovery_required"));
    }
    let value: Journal =
        serde_json::from_slice(&bytes).map_err(|_| fail("manual_action_recovery_required"))?;
    value.validate()?;
    Ok(value)
}
fn edit_journal<T>(
    manager: &AccountManager,
    edit: impl FnOnce(&mut Journal) -> AccountResult<T>,
) -> AccountResult<T> {
    let root = state_root(manager);
    let _lock = storage::StoreLock::acquire(&root)?;
    let mut j = read_journal(manager)?;
    let result = edit(&mut j)?;
    j.validate()?;
    let bytes = serde_json::to_vec(&j).map_err(|_| fail("manual_action_save_failed"))?;
    if bytes.len() > MAX_STATE {
        return Err(fail("manual_action_save_failed"));
    }
    let bytes = manager.protector.seal(CONTEXT, &bytes)?;
    storage::atomic_write(&root.join("journal.dpapi"), &bytes)
        .map_err(|_| fail("manual_action_save_failed"))?;
    Ok(result)
}
pub(super) fn automatic_reset_guard(
    manager: &AccountManager,
    identity: &str,
) -> AccountResult<storage::StoreLock> {
    let guard =
        storage::StoreLock::acquire(&state_root(manager).join("reset-flight").join(identity))?;
    let _state = storage::StoreLock::acquire(&state_root(manager))?;
    if read_journal(manager)?.pending.contains_key(identity) {
        return Err(fail("recovery_required"));
    }
    Ok(guard)
}
struct Credential {
    profile: String,
    label: String,
    value: StoredCredential,
}
struct HttpRequest {
    path: String,
    method: &'static str,
    body: Option<Vec<u8>>,
    language: String,
}
struct HttpResponse {
    status: u16,
    body: Vec<u8>,
}
trait ActionRuntime: Send + Sync {
    fn review(
        &self,
        home: &Path,
        credential: &StoredCredential,
        admit: &dyn Fn() -> AccountResult<()>,
    ) -> AccountResult<Value>;
    fn consume(
        &self,
        home: &Path,
        credential: &StoredCredential,
        card: &str,
        expiry: i64,
        key: &str,
        admit: &dyn Fn() -> AccountResult<()>,
    ) -> AccountResult<&'static str>;
    fn http(
        &self,
        credential: &StoredCredential,
        request: &HttpRequest,
        admit: &dyn Fn() -> AccountResult<()>,
    ) -> AccountResult<HttpResponse>;
}
struct OperationGuard {
    active: Arc<Mutex<BTreeSet<String>>>,
    key: String,
}
impl Drop for OperationGuard {
    fn drop(&mut self) {
        if let Ok(mut active) = self.active.lock() {
            active.remove(&self.key);
        }
    }
}
fn reserve_operation(
    active: &Arc<Mutex<BTreeSet<String>>>,
    key: &str,
) -> AccountResult<OperationGuard> {
    let mut keys = active.lock().map_err(|_| fail("manual_action_busy"))?;
    if keys.len() >= 32 || !keys.insert(key.into()) {
        return Err(fail("manual_action_busy"));
    }
    Ok(OperationGuard {
        active: active.clone(),
        key: key.into(),
    })
}
pub struct ManualAccountService {
    manager: Arc<AccountManager>,
    runtime: Arc<dyn ActionRuntime>,
    authorization: Arc<dyn Fn() -> ManualResetAuthorization + Send + Sync>,
    maintenance: Option<Arc<maintenance::AccountMaintenanceService>>,
    reset_tickets: Mutex<HashMap<String, ResetTicket>>,
    confirmed_in_session: Mutex<BTreeSet<String>>,
    referrals: Mutex<HashMap<String, referral::Ticket>>,
    reset_operation: Arc<Mutex<BTreeSet<String>>>,
    referral_operation: Arc<Mutex<BTreeSet<String>>>,
    exiting: AtomicBool,
}
impl ManualAccountService {
    pub fn new(
        manager: Arc<AccountManager>,
        maintenance: Arc<maintenance::AccountMaintenanceService>,
        authorization: Arc<dyn Fn() -> ManualResetAuthorization + Send + Sync>,
    ) -> AccountResult<Arc<Self>> {
        Self::with_runtime_authorization(
            manager,
            Arc::new(native::NativeRuntime),
            Some(maintenance),
            authorization,
        )
    }
    fn with_runtime(
        manager: Arc<AccountManager>,
        runtime: Arc<dyn ActionRuntime>,
        maintenance: Option<Arc<maintenance::AccountMaintenanceService>>,
    ) -> AccountResult<Arc<Self>> {
        Self::with_runtime_authorization(
            manager,
            runtime,
            maintenance,
            Arc::new(ManualResetAuthorization::default),
        )
    }
    fn with_runtime_authorization(
        manager: Arc<AccountManager>,
        runtime: Arc<dyn ActionRuntime>,
        maintenance: Option<Arc<maintenance::AccountMaintenanceService>>,
        authorization: Arc<dyn Fn() -> ManualResetAuthorization + Send + Sync>,
    ) -> AccountResult<Arc<Self>> {
        {
            let _lock = storage::StoreLock::acquire(&state_root(&manager))?;
            read_journal(&manager)?;
        }
        Ok(Arc::new(Self {
            manager,
            runtime,
            authorization,
            maintenance,
            reset_tickets: Mutex::new(HashMap::new()),
            confirmed_in_session: Mutex::new(BTreeSet::new()),
            referrals: Mutex::new(HashMap::new()),
            reset_operation: Arc::new(Mutex::new(BTreeSet::new())),
            referral_operation: Arc::new(Mutex::new(BTreeSet::new())),
            exiting: AtomicBool::new(false),
        }))
    }
    fn credential(&self, profile: &str) -> AccountResult<Credential> {
        if self.exiting.load(Ordering::Acquire) {
            return Err(fail("manual_action_cancelled"));
        }
        self.manager.require_accepting()?;
        if !storage::valid_id(profile) {
            return Err(fail("manual_action_identity_changed"));
        }
        let store = self.manager.store()?;
        let r = store.vault.account(profile)?;
        if r.platform != "codex" {
            return Err(fail("manual_action_unsupported"));
        }
        let value = r.credential.clone().ok_or_else(|| fail("login_required"))?;
        let (identity, expires) = parse_auth(&value.auth)?;
        if identity != value.identity || expires <= super::super::now() + 60 {
            return Err(fail("manual_action_identity_changed"));
        }
        Ok(Credential {
            profile: r.id.clone(),
            label: safe_label(&r.label),
            value,
        })
    }
    fn recheck(&self, c: &Credential) -> AccountResult<()> {
        if self.credential(&c.profile)?.value.identity != c.value.identity {
            return Err(fail("manual_action_identity_changed"));
        }
        Ok(())
    }
    pub fn resolve_managed_root(&self, root: &Path) -> AccountResult<String> {
        storage::ensure_no_links(root)?;
        let canonical = root.canonicalize().map_err(action_error_io)?;
        let matches = self
            .manager
            .managed_history_roots()?
            .into_iter()
            .filter(|(_, p)| p.canonicalize().ok().as_ref() == Some(&canonical))
            .map(|(id, _)| id)
            .collect::<Vec<_>>();
        if matches.len() != 1 {
            return Err(fail("manual_action_registration_required"));
        }
        self.manager.require_accepting()?;
        Ok(matches[0].clone())
    }
    pub fn browser_settings(
        &self,
        profile: &str,
    ) -> AccountResult<super::browser::BrowserSettings> {
        self.manager.browser_settings(profile)
    }
    pub fn set_browser_settings(
        &self,
        profile: &str,
        mode: super::browser::BrowserMode,
        directory: Option<String>,
    ) -> AccountResult<super::browser::BrowserSettings> {
        self.manager.set_browser_settings(profile, mode, directory)
    }
    pub fn begin_reset_review(&self, profile: &str) -> AccountResult<ResetReview> {
        let _operation = reserve_operation(&self.reset_operation, profile)?;
        let c = self.credential(profile)?;
        let staging = storage::private_tempdir(&self.manager.paths.staging(), "manual-review-")?;
        storage::atomic_write(&staging.path().join("auth.json"), &c.value.auth)?;
        let q = self
            .runtime
            .review(staging.path(), &c.value, &|| self.recheck(&c))?;
        self.recheck(&c)?;
        let card = maintenance::manual_card(&q, &c.value.identity.account_id, ms())
            .map_err(|_| fail("reset_card_unavailable"))?;
        let identity = c.value.identity.identity_hash();
        {
            let _lock = storage::StoreLock::acquire(&state_root(&self.manager))?;
            if read_journal(&self.manager)?
                .pending
                .get(&identity)
                .is_some_and(|p| {
                    p.profile != profile
                        || p.card != auth_digest(card.id.as_bytes())
                        || p.card_expiry != card.expires_at_ms
                })
            {
                return Err(fail("reset_reconciliation_required"));
            }
        }
        let checked = ms();
        let parsed = crate::readers::CodexAppServerQuotaSnapshot::from_rate_limit_response(&q);
        let dto = ResetReview {
            review_id: super::super::nonce()?,
            profile_id: profile.into(),
            checked_at_ms: checked,
            expires_at_ms: checked + 120000,
            available_count: parsed
                .reset_credit_count
                .ok_or_else(|| fail("reset_card_unavailable"))?,
            card_expires_at_ms: card.expires_at_ms,
            remaining5h_percent: parsed.five_hour_quota.map(|w| 100.0 - w.used_percent),
            remaining7d_percent: parsed.seven_day_quota.map(|w| 100.0 - w.used_percent),
        };
        let mut tickets = self
            .reset_tickets
            .lock()
            .map_err(|_| fail("manual_action_busy"))?;
        tickets.retain(|_, t| t.dto.expires_at_ms > checked && t.dto.profile_id != profile);
        if tickets.len() >= 32 {
            return Err(fail("manual_action_busy"));
        }
        tickets.insert(
            dto.review_id.clone(),
            ResetTicket {
                dto: dto.clone(),
                identity,
                card_id: card.id,
                confirmed: false,
            },
        );
        Ok(dto)
    }
    pub fn confirm_reset_review(&self, profile: &str, id: &str) -> AccountResult<ResetReview> {
        let c = self.credential(profile)?;
        let mut tickets = self
            .reset_tickets
            .lock()
            .map_err(|_| fail("manual_action_busy"))?;
        let t = tickets
            .get_mut(id)
            .ok_or_else(|| fail("reset_confirmation_required"))?;
        validate_ticket(t, profile, &c.value.identity.identity_hash())?;
        if t.confirmed {
            return Err(fail("reset_confirmation_required"));
        }
        t.confirmed = true;
        Ok(t.dto.clone())
    }
    pub fn cancel_reset_review(&self, profile: &str, id: &str) -> AccountResult<()> {
        let mut ts = self
            .reset_tickets
            .lock()
            .map_err(|_| fail("manual_action_busy"))?;
        if ts.get(id).is_some_and(|t| t.dto.profile_id == profile) {
            ts.remove(id);
        }
        Ok(())
    }
    pub fn consume_reset(&self, profile: &str, id: &str) -> AccountResult<ResetResult> {
        let _operation = reserve_operation(&self.reset_operation, profile)?;
        let c = self.credential(profile)?;
        let identity = c.value.identity.identity_hash();
        if self
            .confirmed_in_session
            .lock()
            .map_err(|_| fail("manual_action_busy"))?
            .contains(&identity)
        {
            return Err(fail("reset_reconciliation_required"));
        }
        let _flight = storage::StoreLock::acquire(
            &state_root(&self.manager)
                .join("reset-flight")
                .join(&identity),
        )?;
        if let Some(m) = &self.maintenance {
            m.manual_reset_admission(&identity)
                .map_err(|_| fail("reset_reconciliation_required"))?;
        }
        let t = {
            let mut ts = self
                .reset_tickets
                .lock()
                .map_err(|_| fail("manual_action_busy"))?;
            let t = ts
                .get(id)
                .ok_or_else(|| fail("reset_confirmation_required"))?;
            validate_ticket(t, profile, &c.value.identity.identity_hash())?;
            if !t.confirmed {
                return Err(fail("reset_confirmation_required"));
            }
            ts.remove(id).unwrap()
        };
        let pending = edit_journal(&self.manager, |j| {
            if let Some(p) = j.pending.get(&t.identity) {
                if p.profile != profile
                    || p.card != auth_digest(t.card_id.as_bytes())
                    || p.card_expiry != t.dto.card_expires_at_ms
                {
                    return Err(fail("reset_reconciliation_required"));
                }
                return Ok(p.clone());
            }
            let p = PendingReset {
                profile: profile.into(),
                identity: t.identity.clone(),
                card: auth_digest(t.card_id.as_bytes()),
                card_expiry: t.dto.card_expires_at_ms,
                key: super::super::nonce()?,
            };
            j.pending.insert(t.identity.clone(), p.clone());
            Ok(p)
        })?;
        let staging = storage::private_tempdir(&self.manager.paths.staging(), "manual-consume-")?;
        storage::atomic_write(&staging.path().join("auth.json"), &c.value.auth)?;
        // Once claimed, any exception retains the same key; never synthesize a new send.
        let outcome = self
            .runtime
            .consume(
                staging.path(),
                &c.value,
                &t.card_id,
                t.dto.card_expires_at_ms,
                &pending.key,
                &|| self.recheck(&c),
            )
            .unwrap_or("unknown");
        let outcome = if matches!(
            outcome,
            "reset" | "nothingToReset" | "noCredit" | "alreadyRedeemed"
        ) {
            outcome
        } else {
            "unknown"
        };
        let confirmation = (outcome == "reset").then(|| ManualResetConfirmation {
            event_id: format!("manual-reset-{}", auth_digest(pending.key.as_bytes())),
            profile_id: profile.into(),
            account_key: t.identity.clone(),
            masked_label: c.label,
            confirmed_at_ms: ms(),
            available_cards: None,
            authorization: (self.authorization)(),
        });
        let mut issue_code = None;
        if outcome != "unknown" {
            let saved = edit_journal(&self.manager, |j| {
                if j.pending.get(&t.identity).map(|p| p.key.as_str()) != Some(pending.key.as_str())
                {
                    return Err(fail("reset_reconciliation_required"));
                }
                if let Some(e) = &confirmation {
                    j.confirmations
                        .entry(e.event_id.clone())
                        .or_insert_with(|| e.clone());
                }
                j.pending.remove(&t.identity);
                Ok(())
            });
            if let Err(error) = saved {
                if outcome == "reset" {
                    if let Ok(mut known) = self.confirmed_in_session.lock() {
                        known.insert(identity.clone());
                    }
                    issue_code = Some("notification_receipt_save_failed");
                } else {
                    return Err(error);
                }
            }
        }
        Ok(ResetResult {
            profile_id: profile.into(),
            outcome,
            manual_confirmation: if issue_code.is_none() {
                confirmation.as_ref().map(ManualResetSummary::from)
            } else {
                None
            },
            issue_code,
        })
    }
    /// Native-only outbox. A successful callback means the notification vault
    /// durably accepted the event; process interruption safely retries the same ID.
    pub fn drain_confirmed(
        &self,
        record: impl Fn(&ManualResetConfirmation) -> AccountResult<()>,
    ) -> AccountResult<()> {
        let pending = {
            let _lock = storage::StoreLock::acquire(&state_root(&self.manager))?;
            let j = read_journal(&self.manager)?;
            j.confirmations
                .into_iter()
                .filter(|(id, _)| !j.delivered.contains(id))
                .map(|(_, e)| e)
                .collect::<Vec<_>>()
        };
        for event in pending {
            if self.exiting.load(Ordering::Acquire) {
                break;
            }
            record(&event)?;
            edit_journal(&self.manager, |j| {
                j.delivered.insert(event.event_id.clone());
                Ok(())
            })?;
        }
        Ok(())
    }
    pub fn has_inflight_operation(&self) -> bool {
        self.reset_operation.lock().map_or(true, |s| !s.is_empty())
            || self
                .referral_operation
                .lock()
                .map_or(true, |s| !s.is_empty())
    }
    pub fn cancel_for_exit(&self) {
        self.exiting.store(true, Ordering::Release);
    }
}
fn action_error_io(_: std::io::Error) -> AccountError {
    fail("manual_action_registration_required")
}
fn validate_ticket(t: &ResetTicket, profile: &str, identity: &str) -> AccountResult<()> {
    if t.dto.profile_id != profile || t.identity != identity {
        return Err(fail("manual_action_identity_changed"));
    }
    if ms() > t.dto.expires_at_ms || ms() < t.dto.checked_at_ms || ms() >= t.dto.card_expires_at_ms
    {
        return Err(fail("reset_review_expired"));
    }
    Ok(())
}
#[cfg(test)]
#[path = "manual_accounts/tests.rs"]
mod tests;
