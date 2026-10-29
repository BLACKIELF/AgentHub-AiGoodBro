//! Opt-in low-quota switching through the exact managed-account transaction.
//! Source contract: AutomaticAccountSwitch.swift and UsageStore.swift, 1029v1.
#[path = "automatic_switch/policy.rs"]
mod policy;
pub use policy::*;
#[path = "automatic_switch/live/mod.rs"]
pub mod live;
#[path = "automatic_switch/service.rs"]
mod service;
use crate::accounts::{AccountError, AccountManager, SwitchCommitGuard};
use serde::{Deserialize, Serialize};
pub use service::{AutomaticSwitchMonitor, AutomaticSwitchService};
use std::{
    collections::BTreeSet,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex, Weak,
    },
    time::Duration,
};

pub type Result<T> = std::result::Result<T, Failure>;
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Failure {
    InvalidSettings,
    SaveFailed,
    Unavailable,
    MonitorUnavailable,
    LiveTasksUnavailable,
    PauseResumeUnavailable,
    SourceUnknown,
    IdentityChanged,
    QuotaUnknown,
    TaskUnknown,
    TaskBusy,
    Foreground,
    LegacyRunning,
    Cooldown,
    NoEligibleCandidate,
    AccountBusy,
    Cancelled,
    TransactionFailed,
    RecoveryRequired,
}
impl Failure {
    pub fn code(self) -> &'static str {
        match self {
            Self::InvalidSettings => "automatic_switch_invalid_settings",
            Self::SaveFailed => "automatic_switch_save_failed",
            Self::Unavailable => "automatic_switch_unavailable",
            Self::MonitorUnavailable => "automatic_switch_monitor_unavailable",
            Self::LiveTasksUnavailable => "automatic_switch_live_tasks_unavailable",
            Self::PauseResumeUnavailable => "automatic_switch_pause_resume_unavailable",
            Self::SourceUnknown => "automatic_switch_source_unknown",
            Self::IdentityChanged => "automatic_switch_identity_changed",
            Self::QuotaUnknown => "automatic_switch_quota_unknown",
            Self::TaskUnknown => "automatic_switch_task_unknown",
            Self::TaskBusy => "automatic_switch_task_busy",
            Self::Foreground => "automatic_switch_foreground",
            Self::LegacyRunning => "automatic_switch_legacy_running",
            Self::Cooldown => "automatic_switch_cooldown",
            Self::NoEligibleCandidate => "automatic_switch_no_eligible_candidate",
            Self::AccountBusy => "automatic_switch_account_busy",
            Self::Cancelled => "switch_cancelled",
            Self::TransactionFailed => "automatic_switch_transaction_failed",
            Self::RecoveryRequired => "recovery_required",
        }
    }
}
impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.code())
    }
}
impl std::error::Error for Failure {}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub struct AutomaticSwitchPreferences {
    pub enabled: bool,
    pub five_hour_remaining_threshold: u8,
    pub seven_day_remaining_threshold: u8,
    pub excluded_profile_ids: BTreeSet<String>,
    pub pause_at_one_percent: bool,
    pub resume_after_switch: bool,
}
impl Default for AutomaticSwitchPreferences {
    fn default() -> Self {
        Self {
            enabled: false,
            five_hour_remaining_threshold: 5,
            seven_day_remaining_threshold: 10,
            excluded_profile_ids: BTreeSet::new(),
            pause_at_one_percent: false,
            resume_after_switch: true,
        }
    }
}
impl AutomaticSwitchPreferences {
    pub fn validate(&self) -> Result<()> {
        const CHOICES: [u8; 6] = [1, 5, 10, 15, 20, 25];
        if !CHOICES.contains(&self.five_hour_remaining_threshold)
            || !CHOICES.contains(&self.seven_day_remaining_threshold)
            || self.excluded_profile_ids.len() > 100
            || self.excluded_profile_ids.iter().any(|id| !valid_id(id))
        {
            return Err(Failure::InvalidSettings);
        }
        Ok(())
    }
    pub fn effective_thresholds(&self) -> (u8, u8) {
        if self.pause_at_one_percent {
            (1, 1)
        } else {
            (
                self.five_hour_remaining_threshold,
                self.seven_day_remaining_threshold,
            )
        }
    }
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AutomaticSwitchStatus {
    pub phase: &'static str,
    pub issue_code: Option<&'static str>,
    pub source_account_id: Option<String>,
    pub target_account_id: Option<String>,
    pub last_attempt_at_ms: Option<u64>,
    pub last_succeeded_at_ms: Option<u64>,
    pub next_eligible_at_ms: Option<u64>,
    pub live_tasks_available: bool,
    pub pause_resume_available: bool,
    /// Account commit never implies private GUI owner/history restoration.
    pub resume_after_switch_available: bool,
    pub last_switch_restored: Option<bool>,
}
/// Native producer events only. The observer must enqueue bounded work without
/// blocking, and apply the existing notification opt-ins/privacy projection.
pub enum AutomaticSwitchEvent {
    LowQuota {
        source_id: String,
        target_id: Option<String>,
        quota: Quota,
        at_ms: u64,
    },
    Succeeded {
        source_id: String,
        target_id: String,
        at_ms: u64,
    },
    Failed {
        source_id: String,
        target_id: String,
        failure: Failure,
        at_ms: u64,
    },
}
pub trait AutomaticSwitchObserver: Send + Sync {
    fn record(&self, event: AutomaticSwitchEvent);
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Stored {
    version: u32,
    preferences: AutomaticSwitchPreferences,
    last_attempt_at_ms: Option<u64>,
    last_succeeded_at_ms: Option<u64>,
}
impl Default for Stored {
    fn default() -> Self {
        Self {
            version: 1,
            preferences: AutomaticSwitchPreferences::default(),
            last_attempt_at_ms: None,
            last_succeeded_at_ms: None,
        }
    }
}
fn valid_id(id: &str) -> bool {
    id.len() == 32
        && id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn valid_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn now_ms() -> u64 {
    chrono::Utc::now().timestamp_millis().max(0) as u64
}
fn account_failure(e: AccountError) -> Failure {
    match e.code {
        "switch_cancelled" | "account_service_exiting" => Failure::Cancelled,
        "recovery_required" | "cleanup_unconfirmed" => Failure::RecoveryRequired,
        "evidence_stale" | "official_quota_unverified" => Failure::QuotaUnknown,
        "account_busy" | "account_store_busy" | "switch_in_progress" | "login_in_progress"
        | "occupancy_unknown" => Failure::AccountBusy,
        "identity_mismatch" | "target_changed" | "account_changed" => Failure::IdentityChanged,
        _ => Failure::TransactionFailed,
    }
}
