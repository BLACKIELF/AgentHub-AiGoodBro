use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProxyFailure {
    Identity,
    Quota,
    QuotaUnknown,
    SubscriptionPending,
    LoginExpired,
    AccountBusy,
    ControlBusy,
    RegistryStateInvalid,
    RegistryUnavailable,
    Stopping,
    Unavailable,
    NotParticipating,
    AdmissionUnknown,
    AcquireAbandoned,
    AdmissionDeadline,
    UsageLimit,
    PolicyChanged,
    StageNotApplicable,
    InvalidSettings,
    SaveFailed,
    HelperUnavailable,
    StartupFailed,
    CleanupUnconfirmed,
    DesktopRunning,
    DesktopUnavailable,
    DesktopStateUnknown,
    DesktopPreparationExpired,
    DesktopLaunchFailed,
    RegistrationFailed,
}
impl ProxyFailure {
    pub fn code(self) -> &'static str {
        match self {
            Self::Identity => "identity",
            Self::Quota => "quota",
            Self::QuotaUnknown => "quota_unknown",
            Self::SubscriptionPending => "subscription_pending",
            Self::LoginExpired => "login_expired",
            Self::AccountBusy => "account_busy",
            Self::ControlBusy => "control_busy",
            Self::RegistryStateInvalid => "registry_state_invalid",
            Self::RegistryUnavailable => "registry_unavailable",
            Self::Stopping => "stopping",
            Self::Unavailable => "unavailable",
            Self::NotParticipating => "not_participating",
            Self::AdmissionUnknown => "admission_unknown",
            Self::AcquireAbandoned => "acquire_abandoned",
            Self::AdmissionDeadline => "admission_deadline",
            Self::UsageLimit => "usage_limit",
            Self::PolicyChanged => "policy_changed",
            Self::StageNotApplicable => "stage_not_applicable",
            Self::InvalidSettings => "invalid_settings",
            Self::SaveFailed => "save_failed",
            Self::HelperUnavailable => "helper_unavailable",
            Self::StartupFailed => "startup_failed",
            Self::CleanupUnconfirmed => "lease_cleanup_unconfirmed",
            Self::DesktopRunning => "desktop_running",
            Self::DesktopUnavailable => "desktop_unavailable",
            Self::DesktopStateUnknown => "desktop_state_unknown",
            Self::DesktopPreparationExpired => "desktop_preparation_expired",
            Self::DesktopLaunchFailed => "desktop_launch_failed",
            Self::RegistrationFailed => "registration_failed",
        }
    }
}
impl std::fmt::Display for ProxyFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.code())
    }
}
impl std::error::Error for ProxyFailure {}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct AccountPolicy {
    pub five_hour_used_limit: f64,
    pub allows_credits: bool,
    pub credit_primary_floor: Option<u64>,
    pub credit_secondary_floor: Option<u64>,
}
impl Default for AccountPolicy {
    fn default() -> Self {
        Self {
            five_hour_used_limit: 100.0,
            allows_credits: true,
            credit_primary_floor: None,
            credit_secondary_floor: None,
        }
    }
}
impl AccountPolicy {
    pub fn valid(&self) -> bool {
        self.five_hour_used_limit.is_finite()
            && (0.0..=100.0).contains(&self.five_hour_used_limit)
            && match (self.credit_primary_floor, self.credit_secondary_floor) {
                (None, None) => true,
                (Some(a), Some(b)) => a > b,
                _ => false,
            }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ClientKeyMode {
    #[default]
    Persistent,
    PerRun,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct EgressSettings {
    pub enabled: bool,
    pub mihomo_api: String,
    pub group: String,
    pub whitelist: Vec<String>,
}
impl Default for EgressSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            mihomo_api: String::new(),
            group: String::new(),
            whitelist: vec![],
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct ResetStopRule {
    pub identity_hash: String,
    pub armed_at: f64,
    pub paused_at: Option<f64>,
    pub previous_reset_at: Option<f64>,
}
impl Default for ResetStopRule {
    fn default() -> Self {
        Self {
            identity_hash: String::new(),
            armed_at: 0.0,
            paused_at: None,
            previous_reset_at: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct ProxyPreferences {
    pub schema_version: u32,
    pub is_enabled: bool,
    pub automatic_recovery_enabled: bool,
    pub order: Vec<String>,
    pub enabled_ids: BTreeSet<String>,
    pub known_ids: BTreeSet<String>,
    pub priority_ids: BTreeSet<String>,
    pub last_ids: BTreeSet<String>,
    pub last_overrides: BTreeMap<String, bool>,
    pub credit_fallback: bool,
    pub credit_primary_floor: u64,
    pub credit_secondary_floor: u64,
    pub account_policies: BTreeMap<String, AccountPolicy>,
    pub reset_stop_rules: BTreeMap<String, ResetStopRule>,
    pub listen_port: u16,
    pub client_key_mode: ClientKeyMode,
    pub desktop_fallback: bool,
    pub network_proxy: String,
    pub egress: EgressSettings,
}
impl Default for ProxyPreferences {
    fn default() -> Self {
        Self {
            schema_version: 1,
            is_enabled: false,
            automatic_recovery_enabled: false,
            order: vec![],
            enabled_ids: BTreeSet::new(),
            known_ids: BTreeSet::new(),
            priority_ids: BTreeSet::new(),
            last_ids: BTreeSet::new(),
            last_overrides: BTreeMap::new(),
            credit_fallback: false,
            credit_primary_floor: 2000,
            credit_secondary_floor: 1500,
            account_policies: BTreeMap::new(),
            reset_stop_rules: BTreeMap::new(),
            listen_port: 18080,
            client_key_mode: ClientKeyMode::Persistent,
            desktop_fallback: true,
            network_proxy: String::new(),
            egress: EgressSettings::default(),
        }
    }
}
pub(crate) fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}
pub(crate) fn valid_hash(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit())
}
impl ProxyPreferences {
    pub fn validate(&self) -> Result<(), ProxyFailure> {
        let sets = [
            &self.enabled_ids,
            &self.known_ids,
            &self.priority_ids,
            &self.last_ids,
        ];
        if self.schema_version != 1
            || (self.listen_port != 0 && self.listen_port < 1024)
            || self.credit_primary_floor <= self.credit_secondary_floor
            || self.order.len() > 100
            || self.order.iter().collect::<BTreeSet<_>>().len() != self.order.len()
            || !self.order.iter().all(|id| valid_id(id))
            || sets
                .iter()
                .any(|s| s.len() > 100 || s.iter().any(|id| !valid_id(id)))
            || self.last_overrides.len() > 100
            || self.last_overrides.keys().any(|id| !valid_id(id))
            || self.account_policies.len() > 100
            || self
                .account_policies
                .iter()
                .any(|(id, p)| !valid_id(id) || !p.valid())
            || self.reset_stop_rules.len() > 100
            || self.reset_stop_rules.iter().any(|(id, r)| {
                !valid_id(id)
                    || !valid_hash(&r.identity_hash)
                    || !r.armed_at.is_finite()
                    || r.paused_at
                        .is_some_and(|p| !p.is_finite() || p < r.armed_at)
                    || r.previous_reset_at.is_some_and(|p| !p.is_finite())
            })
            || !valid_proxy_url(&self.network_proxy)
            || !valid_egress(&self.egress)
        {
            return Err(ProxyFailure::InvalidSettings);
        }
        Ok(())
    }
    pub fn policy(&self, id: &str) -> AccountPolicy {
        let mut p = self.account_policies.get(id).cloned().unwrap_or_default();
        p.credit_primary_floor
            .get_or_insert(self.credit_primary_floor);
        p.credit_secondary_floor
            .get_or_insert(self.credit_secondary_floor);
        p
    }
    pub fn is_last(&self, id: &str, plan: Option<&str>) -> bool {
        self.last_overrides.get(id).copied().unwrap_or_else(|| {
            self.last_ids.contains(id) || matches!(plan, Some("pro" | "prolite"))
        })
    }
    pub(crate) fn network_equal(&self, other: &Self) -> bool {
        self.listen_port == other.listen_port
            && self.client_key_mode == other.client_key_mode
            && self.desktop_fallback == other.desktop_fallback
            && self.network_proxy == other.network_proxy
            && self.egress == other.egress
    }
}

fn valid_proxy_url(raw: &str) -> bool {
    if raw.is_empty() {
        return true;
    }
    let address = raw
        .strip_prefix("http://")
        .or_else(|| raw.strip_prefix("socks5://"));
    let Some(address) = address else {
        return false;
    };
    if address.contains(['/', '?', '#', '@', '\\', '\r', '\n', '\0']) {
        return false;
    }
    let Some((host, port)) = address.rsplit_once(':') else {
        return false;
    };
    !host.is_empty()
        && !host.chars().any(char::is_whitespace)
        && port.parse::<u16>().is_ok_and(|p| p > 0)
}
fn valid_egress(s: &EgressSettings) -> bool {
    let clean =
        |v: &str, max: usize| v.len() <= max && v.trim() == v && !v.contains(['\r', '\n', '\0']);
    if !clean(&s.group, 256)
        || s.whitelist.len() > 64
        || s.whitelist.iter().collect::<BTreeSet<_>>().len() != s.whitelist.len()
        || s.whitelist.iter().any(|v| v.is_empty() || !clean(v, 512))
    {
        return false;
    }
    if s.enabled && s.group.is_empty() {
        return false;
    }
    if s.mihomo_api.is_empty() {
        return !s.enabled;
    }
    s.mihomo_api.strip_prefix("http://").is_some_and(|v| {
        v.parse::<std::net::SocketAddr>()
            .is_ok_and(|a| a.ip().is_loopback() && a.port() > 0)
    })
}

#[derive(Clone)]
pub struct QuotaWindowEvidence {
    pub used_percent: f64,
    pub resets_at: f64,
}
#[derive(Clone)]
pub struct QuotaEvidence {
    pub observed_at: f64,
    pub read_succeeded: bool,
    pub last_failure_at: Option<f64>,
    pub identity_hash: String,
    pub five_hour: Option<QuotaWindowEvidence>,
    pub seven_day: Option<QuotaWindowEvidence>,
    pub monthly: Option<QuotaWindowEvidence>,
    pub credit_balance: Option<String>,
    pub credit_balance_unlimited: Option<bool>,
}

/// The used-percentage semantics and freshness bound match the native host.
pub fn quota_admission(
    e: &super::AccountEvidence,
    policy: &AccountPolicy,
    now: f64,
    credit_floor: Option<u64>,
    allow_credits: bool,
) -> Result<(), ProxyFailure> {
    if !policy.valid()
        || !e.identity_verified
        || e.is_system_home
        || !valid_hash(&e.identity_hash)
        || e.token_generation.is_empty()
    {
        return Err(ProxyFailure::Identity);
    }
    let q = e.quota.as_ref().ok_or(ProxyFailure::QuotaUnknown)?;
    if !q.read_succeeded
        || q.identity_hash != e.identity_hash
        || !q.observed_at.is_finite()
        || !(0.0..=120.0).contains(&(now - q.observed_at))
        || q.last_failure_at
            .is_some_and(|f| !f.is_finite() || f >= q.observed_at)
    {
        return Err(ProxyFailure::QuotaUnknown);
    }
    let pro = matches!(e.plan.as_deref(), Some("pro" | "prolite"));
    let seven = q.seven_day.as_ref().ok_or(ProxyFailure::QuotaUnknown)?;
    let mut windows = vec![seven];
    if !pro {
        windows.push(q.five_hour.as_ref().ok_or(ProxyFailure::QuotaUnknown)?);
        if let Some(m) = &q.monthly {
            windows.push(m);
        }
    }
    if windows.iter().any(|w| {
        !w.used_percent.is_finite()
            || !(0.0..=100.0).contains(&w.used_percent)
            || !w.resets_at.is_finite()
            || w.resets_at <= now
    }) {
        return Err(ProxyFailure::QuotaUnknown);
    }
    let extra_exhausted = pro
        && [&q.five_hour, &q.monthly]
            .into_iter()
            .flatten()
            .any(|w| w.used_percent == 100.0 && w.resets_at.is_finite() && w.resets_at > now);
    if !pro
        && policy.five_hour_used_limit < 100.0
        && q.five_hour
            .as_ref()
            .is_some_and(|w| w.used_percent >= policy.five_hour_used_limit)
    {
        return Err(ProxyFailure::UsageLimit);
    }
    let exhausted = windows.iter().any(|w| w.used_percent >= 100.0) || extra_exhausted;
    if extra_exhausted {
        return Err(ProxyFailure::Quota);
    }
    let Some(floor) = credit_floor else {
        return if exhausted {
            Err(ProxyFailure::Quota)
        } else {
            Ok(())
        };
    };
    if !allow_credits
        || !policy.allows_credits
        || !exhausted
        || q.credit_balance_unlimited != Some(false)
    {
        return Err(ProxyFailure::Quota);
    }
    if !decimal_above(q.credit_balance.as_deref().unwrap_or(""), floor) {
        return Err(ProxyFailure::Quota);
    }
    Ok(())
}
fn decimal_above(raw: &str, floor: u64) -> bool {
    let raw = raw.trim();
    let mut parts = raw.split('.');
    let whole = parts.next().unwrap_or("");
    let fraction = parts.next();
    if whole.is_empty()
        || !whole.bytes().all(|b| b.is_ascii_digit())
        || parts.next().is_some()
        || fraction.is_some_and(|s| s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()))
    {
        return false;
    }
    let digits = whole.trim_start_matches('0');
    let canonical = if digits.is_empty() { "0" } else { digits };
    let floor = floor.to_string();
    canonical.len() > floor.len()
        || (canonical.len() == floor.len()
            && (canonical > floor.as_str()
                || (canonical == floor && fraction.is_some_and(|s| s.bytes().any(|b| b != b'0')))))
}
