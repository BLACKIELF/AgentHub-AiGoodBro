use super::{
    AccountPolicy, DesktopRecoveryProof, ProxyFailure, ProxyHelperRecoveryProof, QuotaEvidence,
};
use serde::Deserialize;

/// Native-only ownership token, never a WebView DTO or a credential container.
#[derive(Clone)]
pub struct DesktopWriterClaim {
    pub writer_id: String,
    pub profile_id: String,
    pub proxy_run_id: String,
    pub identity_hash: String,
    pub initial_generation: String,
}
/// Received only on the connector's authenticated evidence listener. Raw
/// official account JSON is never rendered/logged/persisted in proxy settings.
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DesktopQuotaEvidence {
    #[serde(rename = "writerID")]
    pub writer_id: String,
    #[serde(rename = "proxyRunID")]
    pub proxy_run_id: String,
    #[serde(rename = "backendID")]
    pub backend_id: String,
    pub observed_at: f64,
    pub auth_digest: String,
    pub account: serde_json::Value,
    pub rate_limits: serde_json::Value,
}

/// Safe evidence supplied by the account lifecycle owner. Never infer identity
/// or an official quota from a directory label or an absent error.
#[derive(Clone)]
pub struct AccountEvidence {
    pub profile_id: String,
    pub identity_hash: String,
    pub token_generation: String,
    pub identity_verified: bool,
    pub is_system_home: bool,
    pub is_desktop: bool,
    pub plan: Option<String>,
    pub quota: Option<QuotaEvidence>,
}
pub struct AccountRegistration {
    pub profile_id: String,
    pub identity_hash: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LeaseTuple {
    pub run_id: String,
    pub request_id: String,
    pub profile_id: String,
    pub lease_id: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AdmissionPass {
    Subscription,
    DesktopSubscription,
    CreditPrimary,
    CreditSecondary,
    DesktopCreditPrimary,
    DesktopCreditSecondary,
}
impl AdmissionPass {
    pub fn desktop(self) -> bool {
        matches!(
            self,
            Self::DesktopSubscription | Self::DesktopCreditPrimary | Self::DesktopCreditSecondary
        )
    }
    pub fn credit(self) -> bool {
        !matches!(self, Self::Subscription | Self::DesktopSubscription)
    }
}

#[derive(Clone)]
pub struct AdmissionRequest {
    pub run_id: String,
    pub request_id: String,
    pub profile_id: String,
    pub expected_identity_hash: String,
    pub expected_generation: String,
    pub pass: AdmissionPass,
    pub policy: AccountPolicy,
    pub credit_floor: Option<u64>,
    /// Frozen host membership time, never supplied by the helper peer.
    pub request_started_at_unix_ms: u64,
    pub deadline_unix_ms: u64,
}

/// Intentionally not Debug/Serialize: tokens may only enter the authenticated
/// control reply, never UI state, diagnostics or a persisted preference.
pub struct CredentialLease {
    pub tuple: LeaseTuple,
    pub access_token: String,
    pub account_id: String,
    pub expires_at: i64,
    pub identity_hash: String,
    pub token_generation: String,
}

pub enum AdmissionResolution {
    Reserved(CredentialLease),
    NotReserved,
    RolledBack,
    Unknown,
}

/// Implemented by the real account/dispatch owner, shared with terminal and
/// switch transactions. reserve MUST atomically recheck identity, generation,
/// quota/policy, deadline and the cross-process lock before returning a token.
/// No synthetic implementation is registered by the product.
pub trait ProxyAccountGate: Send + Sync {
    fn desktop_recovery_candidates(&self) -> Result<Vec<DesktopWriterClaim>, ProxyFailure> {
        Ok(vec![])
    }
    fn recover_desktop_writer(
        &self,
        _proof: &DesktopRecoveryProof,
    ) -> Result<DesktopWriterClaim, ProxyFailure> {
        Err(ProxyFailure::CleanupUnconfirmed)
    }
    fn proxy_run_recovery_candidate(&self) -> Result<Option<String>, ProxyFailure> {
        Ok(None)
    }
    fn recover_proxy_run(&self, _proof: &ProxyHelperRecoveryProof) -> Result<(), ProxyFailure> {
        Err(ProxyFailure::CleanupUnconfirmed)
    }
    /// Startup enrollment only, with no quota/token authority. An already-owned
    /// Desktop writer may remain registered while its proxy run is being rebound.
    fn registration(&self, id: &str) -> Result<AccountRegistration, ProxyFailure> {
        let e = self.evidence(id)?;
        if !e.identity_verified || e.is_system_home {
            return Err(ProxyFailure::Identity);
        }
        Ok(AccountRegistration {
            profile_id: e.profile_id,
            identity_hash: e.identity_hash,
        })
    }
    fn claim_desktop_writer(
        &self,
        _profile: &str,
        _run: &str,
        _identity: &str,
        _generation: &str,
    ) -> Result<DesktopWriterClaim, ProxyFailure> {
        Err(ProxyFailure::Unavailable)
    }
    fn recheck_desktop_writer(&self, _claim: &DesktopWriterClaim) -> Result<(), ProxyFailure> {
        Err(ProxyFailure::Unavailable)
    }
    fn rebind_desktop_writer(
        &self,
        _claim: &DesktopWriterClaim,
        _new_run: &str,
    ) -> Result<DesktopWriterClaim, ProxyFailure> {
        Err(ProxyFailure::Unavailable)
    }
    /// First evidence binds the per-launch backend ID durably; another backend
    /// under the same writer is rejected. Replays never advance observed time.
    fn accept_desktop_evidence(
        &self,
        _claim: &DesktopWriterClaim,
        _proof: DesktopQuotaEvidence,
    ) -> Result<(), ProxyFailure> {
        Err(ProxyFailure::Unavailable)
    }
    fn confirm_desktop_exit(&self, _claim: &DesktopWriterClaim) -> Result<(), ProxyFailure> {
        Err(ProxyFailure::CleanupUnconfirmed)
    }
    fn release_desktop_writer(&self, _claim: &DesktopWriterClaim) -> Result<(), ProxyFailure> {
        Err(ProxyFailure::CleanupUnconfirmed)
    }
    /// Authoritative managed catalog; UI knownIds is never identity evidence.
    fn managed_profile_ids(&self) -> Result<Vec<String>, ProxyFailure> {
        Err(ProxyFailure::Identity)
    }
    /// Bind one native run durably before its helper can be spawned. The real
    /// gate rejects an unreconciled prior run; default supports isolated tests.
    fn activate_run(&self, _run_id: &str) -> Result<(), ProxyFailure> {
        Ok(())
    }
    fn evidence(&self, profile_id: &str) -> Result<AccountEvidence, ProxyFailure>;
    fn reserve(&self, request: &AdmissionRequest) -> Result<CredentialLease, ProxyFailure>;
    /// Atomically tombstone the exact (run, request, profile) before resolving;
    /// no late reserve may commit after NotReserved/RolledBack is returned.
    fn resolve(&self, tuple: &LeaseTuple) -> Result<AdmissionResolution, ProxyFailure>;
    fn heartbeat(&self, tuple: &LeaseTuple) -> Result<(), ProxyFailure>;
    fn release(&self, tuple: &LeaseTuple) -> Result<(), ProxyFailure>;
    /// Reclaim only exact reservations for a positively confirmed owned exit.
    fn retire_run(&self, run_id: &str, confirmed_exit: bool) -> Result<(), ProxyFailure>;
    /// A bounded official read may refresh evidence; default remains unknown.
    fn refresh_quota(
        &self,
        _profile_ids: &[String],
        _deadline_unix_ms: u64,
    ) -> Result<(), ProxyFailure> {
        Err(ProxyFailure::QuotaUnknown)
    }
    fn egress_probe(&self, _profile_id: &str) -> Result<EgressProof, ProxyFailure> {
        Err(ProxyFailure::Unavailable)
    }
}

pub struct EgressProof {
    pub status: String,
    pub observed_at: f64,
    pub identity_hash: String,
}

/// Persistent loopback keys belong in the native encrypted vault. Implementors
/// must not serialize these values in ordinary application preferences.
pub trait ProxySecretStore: Send + Sync {
    fn load_client_key(&self) -> Result<Option<String>, ProxyFailure>;
    fn save_client_key(&self, key: &str) -> Result<(), ProxyFailure>;
    fn load_mihomo_secret(&self) -> Result<Option<String>, ProxyFailure> {
        Ok(None)
    }
}
