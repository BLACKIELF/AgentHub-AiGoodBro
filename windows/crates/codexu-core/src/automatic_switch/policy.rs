//! The current Mac CodexAutomaticSwitchPolicy, expressed without UI evidence.
use super::{AutomaticSwitchPreferences, Failure, Result};
use serde::Serialize;

pub const QUOTA_MAX_AGE_MS: u64 = 45_000;
pub const TASK_MAX_AGE_MS: u64 = 45_000;
pub const INACTIVE_MS: u64 = 120_000;
pub const FAILURE_RETRY_MS: u64 = 3_600_000;
pub const SUCCESS_COOLDOWN_MS: u64 = 1_800_000;
pub const CANDIDATE_REFRESH_BACKOFF_MS: u64 = 60_000;
pub const MINIMUM_CANDIDATE_PERCENT: f64 = 30.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum QuotaWindow {
    FiveHour,
    SevenDay,
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Quota {
    pub five_hour_remaining: Option<f64>,
    pub seven_day_remaining: Option<f64>,
    pub five_hour_not_applicable: bool,
}
impl Quota {
    pub fn from_official(plan: Option<&str>, value: &serde_json::Value) -> Result<Self> {
        let snapshot = crate::readers::CodexAppServerQuotaSnapshot::from_rate_limit_response(value);
        if !snapshot.quota_read_succeeded {
            return Err(Failure::QuotaUnknown);
        }
        let had_five = snapshot.five_hour_quota.is_some();
        let valid = |used: f64| used.is_finite() && (0.0..=100.0).contains(&used);
        let five = snapshot
            .five_hour_quota
            .and_then(|w| valid(w.used_percent).then_some(100.0 - w.used_percent));
        let seven = snapshot
            .seven_day_quota
            .and_then(|w| valid(w.used_percent).then_some(100.0 - w.used_percent));
        let pro = plan
            .is_some_and(|p| matches!(p.trim().to_ascii_lowercase().as_str(), "pro" | "prolite"));
        Ok(Self {
            five_hour_remaining: five,
            seven_day_remaining: seven,
            five_hour_not_applicable: !had_five && pro,
        })
    }
    pub fn complete(&self) -> bool {
        self.seven_day_remaining.is_some_and(valid_remaining)
            && (self.five_hour_remaining.is_some_and(valid_remaining)
                || (self.five_hour_remaining.is_none() && self.five_hour_not_applicable))
    }
    pub fn positive(&self) -> bool {
        self.complete()
            && self.seven_day_remaining.is_some_and(|v| v > 0.0)
            && ((self.five_hour_not_applicable && self.five_hour_remaining.is_none())
                || self.five_hour_remaining.is_some_and(|v| v > 0.0))
    }
    pub fn triggered(&self, prefs: &AutomaticSwitchPreferences) -> Vec<QuotaWindow> {
        let (five, seven) = prefs.effective_thresholds();
        let mut out = vec![];
        if self
            .five_hour_remaining
            .is_some_and(|v| valid_remaining(v) && v <= five as f64)
        {
            out.push(QuotaWindow::FiveHour);
        }
        if self.seven_day_remaining.is_some_and(|v| {
            valid_remaining(v)
                && if seven == 1 {
                    v <= 1.0
                } else {
                    v < seven as f64
                }
        }) {
            out.push(QuotaWindow::SevenDay);
        }
        out
    }
    pub fn candidate_score(&self, windows: &[QuotaWindow]) -> Option<f64> {
        if windows.is_empty() || !self.positive() {
            return None;
        }
        let mut score: f64 = 100.0;
        for window in windows {
            let remaining = match window {
                QuotaWindow::FiveHour
                    if self.five_hour_not_applicable && self.five_hour_remaining.is_none() =>
                {
                    self.seven_day_remaining?
                }
                QuotaWindow::FiveHour => self.five_hour_remaining?,
                QuotaWindow::SevenDay => self.seven_day_remaining?,
            };
            score = score.min(remaining);
        }
        (score >= MINIMUM_CANDIDATE_PERCENT).then_some(score)
    }
}
fn valid_remaining(value: f64) -> bool {
    value.is_finite() && (0.0..=100.0).contains(&value)
}
pub fn is_fresh(captured_at_ms: u64, maximum_age_ms: u64, now_ms: u64) -> bool {
    captured_at_ms > 0
        && captured_at_ms <= now_ms.saturating_add(5_000)
        && now_ms.saturating_sub(captured_at_ms) <= maximum_age_ms
}
pub fn cooldown_until(last_attempt: Option<u64>, last_success: Option<u64>) -> Option<u64> {
    [
        last_attempt.map(|v| v.saturating_add(FAILURE_RETRY_MS)),
        last_success.map(|v| v.saturating_add(SUCCESS_COOLDOWN_MS)),
    ]
    .into_iter()
    .flatten()
    .max()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConnectionMode {
    Disconnected,
    Isolated,
    SharedDaemon,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TaskState {
    Idle,
    Running,
    WaitingInput,
    Recorded,
    Disconnected,
    Failed,
    Completed,
    Interrupted,
}

/// Rust-only evidence from one authenticated official turn connection. There is
/// no Deserialize and no command accepts these fields from the WebView.
#[derive(Clone)]
pub struct SafetySnapshot {
    pub identity_hash: String,
    pub credential_generation: String,
    pub connection_generation: String,
    pub captured_at_ms: u64,
    pub connection: ConnectionMode,
    pub tasks: Vec<TaskState>,
    pub inactive_since_ms: Option<u64>,
    /// None means that native legacy-owner enumeration is unavailable.
    pub legacy_manager_running: Option<bool>,
}
impl SafetySnapshot {
    pub fn validate_idle(
        &self,
        identity: &str,
        credential_generation: &str,
        generation: Option<&str>,
        now: u64,
    ) -> Result<()> {
        if self.identity_hash != identity
            || !super::valid_hash(identity)
            || self.credential_generation != credential_generation
            || !super::valid_id(credential_generation)
            || self.connection_generation.is_empty()
            || generation.is_some_and(|g| g != self.connection_generation)
        {
            return Err(Failure::IdentityChanged);
        }
        // A private isolated backend proves only its own tasks, never the
        // current system daemon's complete roster for global switching.
        if self.connection != ConnectionMode::SharedDaemon
            || !is_fresh(self.captured_at_ms, TASK_MAX_AGE_MS, now)
            || self.tasks.len() > 4096
        {
            return Err(Failure::TaskUnknown);
        }
        match self.legacy_manager_running {
            Some(false) => {}
            Some(true) => return Err(Failure::LegacyRunning),
            None => return Err(Failure::TaskUnknown),
        }
        if self.tasks.iter().any(|state| {
            matches!(
                state,
                TaskState::Running
                    | TaskState::WaitingInput
                    | TaskState::Recorded
                    | TaskState::Disconnected
            )
        }) {
            return Err(Failure::TaskBusy);
        }
        if !self
            .inactive_since_ms
            .is_some_and(|since| since <= now && now - since >= INACTIVE_MS)
        {
            return Err(Failure::Foreground);
        }
        Ok(())
    }
}

/// snapshot() is a bounded, memory-only read. The commit guard can call it while
/// AccountManager owns its vault lock; it must never reopen auth/SQLite/vault or
/// create a process. The native connector publishes only authenticated snapshots.
pub trait AutomaticSwitchSafetySource: Send + Sync {
    fn live_available(&self) -> bool;
    /// Real native observers require continuous same-domain maintenance and
    /// positive exit authority. Explicit test safety sources retain injection.
    fn requires_native_quiescence(&self) -> bool {
        false
    }
    fn pause_resume_available(&self) -> bool {
        false
    }
    fn snapshot(&self) -> Result<SafetySnapshot>;
}
/// Explicit capability failure until a real official live connector is wired.
/// It cannot authorize opt-in or mutation and is not an idle fixture.
pub struct UnavailableSafetySource;
impl AutomaticSwitchSafetySource for UnavailableSafetySource {
    fn live_available(&self) -> bool {
        false
    }
    fn snapshot(&self) -> Result<SafetySnapshot> {
        Err(Failure::LiveTasksUnavailable)
    }
}
