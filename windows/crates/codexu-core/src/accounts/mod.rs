//! Managed credentials are distinct from the metadata-only linked-profile catalog.
//! No credential-bearing type in this module is a WebView DTO.
mod active_scope;
pub mod claude;
mod desktop;
mod identity;
mod native;
mod service;
pub(crate) mod storage;
mod verification;

pub use active_scope::ActiveSystemScope;
pub use desktop::{DesktopHomeCleanup, ProxyDesktopHome};
pub use identity::{AccountIdentity, VerifiedCredential, VerifiedCredentialSnapshot};
pub use native::{
    parse_authorization, validate_target_configuration, DpapiProtector, NativeAccountRuntime,
};
pub use service::AccountManager;
pub use service::{browser, hub_snapshot, maintenance, manual_accounts};
pub use storage::{AccountPaths, SecretProtector};
pub use verification::{
    OwnedVerificationProcess, VerificationProcessPermit, VerificationSpawnLease,
};

use serde::Serialize;
use std::sync::atomic::AtomicBool;

pub type AccountResult<T> = Result<T, AccountError>;

/// Fixed, localizable codes only. Never include OS errors, CLI output or paths.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, thiserror::Error)]
#[error("{code}")]
pub struct AccountError {
    pub code: &'static str,
}
pub(crate) fn fail(code: &'static str) -> AccountError {
    AccountError { code }
}

#[derive(Clone, Debug, Serialize)]
pub struct ManagedAccountDto {
    pub id: String,
    pub label: String,
    pub platform: String,
    pub storage_kind: &'static str,
    pub login_state: &'static str,
    pub active_state: &'static str,
    pub masked_identity: Option<String>,
    /// Last verified display value only; never an admission freshness proof.
    pub plan_type: Option<String>,
    pub can_login: bool,
    pub can_switch: bool,
    /// Availability of prepare only; every switch still rechecks occupancy.
    pub switch_block_reason: Option<&'static str>,
    pub revision: u64,
    pub recovery_required: bool,
}

/// Display provenance only. No auth document/token is exposed. This snapshot
/// has no admission authority regardless of its timestamp or quota values.
#[derive(Clone)]
pub struct CachedQuotaSnapshot {
    pub plan: Option<String>,
    pub official_quota: serde_json::Value,
    pub observed_at: i64,
}

#[derive(Clone, Serialize)]
pub struct LoginAttemptDto {
    pub attempt_id: String,
    pub account_id: String,
    pub phase: &'static str,
    pub verification_url: Option<String>,
    pub user_code: Option<String>,
    pub error_code: Option<&'static str>,
}
impl std::fmt::Debug for LoginAttemptDto {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LoginAttemptDto")
            .field("attempt_id", &self.attempt_id)
            .field("account_id", &self.account_id)
            .field("phase", &self.phase)
            .field("authorization", &"[redacted]")
            .field("error_code", &self.error_code)
            .finish()
    }
}

#[derive(Clone, Serialize)]
pub struct PreparedSwitchDto {
    pub account_id: String,
    pub ticket: Option<String>,
    pub phase: &'static str,
    pub reason_code: Option<&'static str>,
    pub expires_at: Option<i64>,
}
impl std::fmt::Debug for PreparedSwitchDto {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PreparedSwitchDto")
            .field("account_id", &self.account_id)
            .field("phase", &self.phase)
            .field("ticket", &self.ticket.as_ref().map(|_| "[redacted]"))
            .field("reason_code", &self.reason_code)
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct AccountOperationDto {
    pub account_id: String,
    pub phase: &'static str,
    pub error_code: Option<&'static str>,
}

/// A validated, short-lived official pairing prompt, never an auth token.
#[derive(Clone)]
pub struct LoginAuthorization {
    pub verification_url: String,
    pub user_code: String,
}

pub trait AccountRuntime: Send + Sync {
    fn available(&self) -> bool;
    /// Return only after every owned child has exited, including cancellation.
    fn login(
        &self,
        staging_home: &std::path::Path,
        cancelled: &AtomicBool,
        report: &mut dyn FnMut(LoginAuthorization),
    ) -> AccountResult<VerifiedCredential>;
    /// Perform an official read in the supplied isolated/maintenance-owned home.
    fn verify(
        &self,
        home: &std::path::Path,
        expected: &AccountIdentity,
    ) -> AccountResult<VerifiedCredential>;
    fn verify_in_operation(
        &self,
        _home: &std::path::Path,
        _expected: &AccountIdentity,
        _guard: &dyn SwitchCommitGuard,
    ) -> AccountResult<VerifiedCredential> {
        Err(fail("verification_process_authority_unavailable"))
    }
    /// No process evidence is not the same as positively established idle.
    fn require_system_idle(&self) -> AccountResult<()>;
    fn validate_target_configuration(&self, home: &std::path::Path) -> AccountResult<()>;
}

/// Automatic policy adds only a cancellation/epoch fence to the same manual
/// transaction. Implementations must read cached native state, never I/O or
/// reenter this manager/vault while commit holds its OS lock.
pub trait SwitchCommitGuard: Send + Sync {
    fn recheck(&self) -> AccountResult<()>;
    fn verification_process_permit(&self) -> Option<std::sync::Arc<dyn VerificationProcessPermit>> {
        None
    }
}

/// Production uses a real owned worker; the explicit boundary lets failure-to-
/// spawn be tested without exhausting host threads or touching a real account.
pub trait AccountLoginSpawner: Send + Sync {
    fn spawn(&self, work: Box<dyn FnOnce() + Send>) -> AccountResult<()>;
}
pub(crate) struct NativeLoginSpawner;
impl AccountLoginSpawner for NativeLoginSpawner {
    fn spawn(&self, work: Box<dyn FnOnce() + Send>) -> AccountResult<()> {
        std::thread::Builder::new()
            .name("managed-account-login".into())
            .spawn(work)
            .map(|_| ())
            .map_err(|_| fail("login_unavailable"))
    }
}

/// Integrator must supply the real shared proxy/dispatch maintenance reservation.
/// Absence is Unknown, never Idle. The guard outlives the target mutation/rollback.
pub trait AccountOccupancyGate: Send + Sync {
    fn acquire_switch_maintenance(
        &self,
        account_id: &str,
        operation_id: &str,
    ) -> AccountResult<Box<dyn SwitchMaintenanceLease>>;
    /// Adopt an already-held native reservation, never a renderer-supplied ID.
    /// Other gate implementations cannot accidentally turn this into a new lock.
    fn adopt_automatic_maintenance(
        &self,
        _lease: &crate::managed_proxy::AutomaticMaintenanceLease,
        _target: &str,
    ) -> AccountResult<Box<dyn SwitchMaintenanceLease>> {
        Err(fail("occupancy_unknown"))
    }
    fn acquire_automatic_credential_write(
        &self,
        _lease: &crate::managed_proxy::AutomaticMaintenanceLease,
        _target: &str,
    ) -> AccountResult<Box<dyn CredentialWriteLease>> {
        Err(fail("occupancy_unknown"))
    }
    /// Native writer fence, shared with durable Desktop ownership. Absence is
    /// never permission to refresh or overwrite an active Desktop grant.
    fn acquire_credential_write(
        &self,
        _profile_id: &str,
        _purpose: CredentialWritePurpose,
    ) -> AccountResult<Box<dyn CredentialWriteLease>> {
        Err(fail("occupancy_unknown"))
    }
}
#[derive(Clone)]
pub enum CredentialWritePurpose {
    Managed,
    DesktopPrepare { writer_id: String },
    DesktopFinalize { writer_id: String },
}
pub trait CredentialWriteLease: Send {
    fn recheck(&self) -> AccountResult<()>;
}
pub trait SwitchMaintenanceLease: Send {
    fn recheck(&self) -> AccountResult<()>;
}

pub(crate) fn now() -> i64 {
    chrono::Utc::now().timestamp()
}
pub(crate) fn nonce() -> AccountResult<String> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).map_err(|_| fail("entropy_unavailable"))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}
