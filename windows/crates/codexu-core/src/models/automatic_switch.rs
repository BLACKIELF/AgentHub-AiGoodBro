//! Automatic account switch policy.
//!
//! Faithful port of `Domain/AutomaticAccountSwitch.swift`.
//!
//! This is the gate in front of any *automatic* account switch. Every
//! precondition is fail-closed: a missing or stale quota observation, a missing
//! or stale task snapshot, an unknown connection state, a running legacy manager
//! or an unfinished Codex session all block the mutation rather than being
//! approximated.
//!
//! Manual and automatic switching must share the same identity, lock,
//! graceful-exit, atomic-write, verification, rollback and recovery path. This
//! module owns the *decision*; the transaction mechanics belong to the layer
//! that performs the write.

use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Selectable low-quota alert thresholds, in remaining percent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct LowQuotaAlertThresholds {
    pub five_hour: i64,
    pub seven_day: i64,
}

impl LowQuotaAlertThresholds {
    pub const CHOICES: [i64; 5] = [5, 10, 15, 20, 25];
    pub const STANDARD: Self = Self {
        five_hour: 5,
        seven_day: 10,
    };

    /// Clamp to the offered choices. An unrecognised value falls back to the
    /// standard rather than being honoured, because a threshold is a safety
    /// setting and a silent widening would fire switches the user did not ask
    /// for.
    pub fn new(five_hour: i64, seven_day: i64) -> Self {
        Self {
            five_hour: if Self::CHOICES.contains(&five_hour) {
                five_hour
            } else {
                5
            },
            seven_day: if Self::CHOICES.contains(&seven_day) {
                seven_day
            } else {
                10
            },
        }
    }

    /// Read from a settings map, falling back per key.
    ///
    /// Only a whole number that is one of the offered choices is accepted.
    pub fn from_settings(settings: &BTreeMap<String, SettingsValue>) -> Self {
        fn value(
            settings: &BTreeMap<String, SettingsValue>,
            key: &str,
            fallback: i64,
        ) -> i64 {
            match settings.get(key) {
                Some(SettingsValue::Number(number)) if number.fract() == 0.0 => {
                    let whole = *number as i64;
                    if LowQuotaAlertThresholds::CHOICES.contains(&whole) {
                        whole
                    } else {
                        fallback
                    }
                }
                _ => fallback,
            }
        }
        Self {
            five_hour: value(settings, Self::FIVE_HOUR_KEY, 5),
            seven_day: value(settings, Self::SEVEN_DAY_KEY, 10),
        }
    }

    pub const FIVE_HOUR_KEY: &'static str = "lowQuotaAlerts.fiveHourThreshold";
    pub const SEVEN_DAY_KEY: &'static str = "lowQuotaAlerts.sevenDayThreshold";
}

impl Default for LowQuotaAlertThresholds {
    fn default() -> Self {
        Self::STANDARD
    }
}

/// A setting value, mirroring the launch-override domain the macOS build reads.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SettingsValue {
    Text(String),
    Number(f64),
}

/// Automation features that a launch override can pause.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PausedAutomationFeature {
    /// 5h warm-up.
    FiveHour,
    /// Weekly warm-up.
    SevenDay,
    /// Low-quota alerts.
    LowQuota,
    /// Feishu notifications.
    Feishu,
    /// System notifications.
    LocalNotification,
}

impl PausedAutomationFeature {
    pub const ALL: [PausedAutomationFeature; 5] = [
        PausedAutomationFeature::FiveHour,
        PausedAutomationFeature::SevenDay,
        PausedAutomationFeature::LowQuota,
        PausedAutomationFeature::Feishu,
        PausedAutomationFeature::LocalNotification,
    ];

    pub fn settings_key(self) -> &'static str {
        match self {
            PausedAutomationFeature::FiveHour => "automaticWarmUp.fiveHour",
            PausedAutomationFeature::SevenDay => "automaticWarmUp.sevenDay",
            PausedAutomationFeature::LowQuota => "automaticAccountSwitch.enabled",
            PausedAutomationFeature::Feishu => "feishuNotifications.enabled",
            PausedAutomationFeature::LocalNotification => "localNotifications.enabled",
        }
    }

    /// Which features an override map pauses.
    ///
    /// Only an explicit `no` / `false` / `0` pauses a feature. Anything missing
    /// or unrecognised leaves it alone, so a typo cannot silently disable the
    /// safety net.
    pub fn paused_from(settings: &BTreeMap<String, SettingsValue>) -> Vec<PausedAutomationFeature> {
        Self::ALL
            .into_iter()
            .filter(|feature| match settings.get(feature.settings_key()) {
                Some(SettingsValue::Text(text)) => matches!(
                    text.trim().to_ascii_lowercase().as_str(),
                    "no" | "false" | "0"
                ),
                Some(SettingsValue::Number(number)) => *number == 0.0,
                None => false,
            })
            .collect()
    }
}

/// The two quota windows an automatic switch can react to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AutomaticQuotaWindow {
    FiveHour,
    SevenDay,
}

impl AutomaticQuotaWindow {
    pub const ALL: [AutomaticQuotaWindow; 2] =
        [AutomaticQuotaWindow::FiveHour, AutomaticQuotaWindow::SevenDay];
}

/// Remaining quota per window, clamped into range.
///
/// A non-finite value becomes `None`, so an unknown window can never trigger a
/// switch.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct AutomaticSwitchQuotaState {
    pub five_hour_remaining: Option<f64>,
    pub seven_day_remaining: Option<f64>,
}

impl AutomaticSwitchQuotaState {
    pub fn new(five_hour_remaining: Option<f64>, seven_day_remaining: Option<f64>) -> Self {
        Self {
            five_hour_remaining: Self::valid(five_hour_remaining),
            seven_day_remaining: Self::valid(seven_day_remaining),
        }
    }

    pub fn remaining(&self, window: AutomaticQuotaWindow) -> Option<f64> {
        match window {
            AutomaticQuotaWindow::FiveHour => self.five_hour_remaining,
            AutomaticQuotaWindow::SevenDay => self.seven_day_remaining,
        }
    }

    /// Windows currently at or below their alert threshold.
    ///
    /// The 5h rule is inclusive and the 7d rule is exclusive, matching the
    /// warm-up thresholds elsewhere in the product.
    pub fn triggered_windows(
        &self,
        thresholds: LowQuotaAlertThresholds,
    ) -> Vec<AutomaticQuotaWindow> {
        AutomaticQuotaWindow::ALL
            .into_iter()
            .filter(|window| match self.remaining(*window) {
                Some(remaining) => match window {
                    AutomaticQuotaWindow::FiveHour => remaining <= thresholds.five_hour as f64,
                    AutomaticQuotaWindow::SevenDay => remaining < thresholds.seven_day as f64,
                },
                None => false,
            })
            .collect()
    }

    fn valid(value: Option<f64>) -> Option<f64> {
        value
            .filter(|value| value.is_finite())
            .map(|value| value.clamp(0.0, 100.0))
    }
}

/// How the workbench is attached to live task state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SwitchConnectionMode {
    SharedDaemon,
    Disconnected,
}

/// One live task record.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskLiveState {
    Running,
    WaitingInput,
    Recorded,
    Disconnected,
    Idle,
    Failed,
    Completed,
    Interrupted,
}

impl TaskLiveState {
    /// Whether this state must block an account switch.
    ///
    /// `recorded` and `disconnected` block on purpose: an unfinished or
    /// unverified task is not evidence that the account is free.
    pub fn blocks_switch(self) -> bool {
        matches!(
            self,
            TaskLiveState::Running
                | TaskLiveState::WaitingInput
                | TaskLiveState::Recorded
                | TaskLiveState::Disconnected
        )
    }
}

/// A bounded view of live task state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SwitchTaskSnapshot {
    pub connection_mode: SwitchConnectionMode,
    /// Task id to state.
    pub records: BTreeMap<String, TaskLiveState>,
    pub refreshed_at: DateTime<Utc>,
}

impl SwitchTaskSnapshot {
    pub fn disconnected(now: DateTime<Utc>) -> Self {
        Self {
            connection_mode: SwitchConnectionMode::Disconnected,
            records: BTreeMap::new(),
            refreshed_at: now,
        }
    }
}

/// Why an automatic switch may be started.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SwitchTrigger {
    /// The user asked for it.
    Manual,
    /// The policy decided it.
    Automatic,
}

/// What made the policy decide.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct SwitchReason {
    pub window: AutomaticQuotaWindow,
    pub remaining_percent: f64,
}

pub struct AutomaticSwitchPolicy;

impl AutomaticSwitchPolicy {
    pub const FIVE_HOUR_TRIGGER_REMAINING_PERCENT: f64 = 5.0;
    pub const SEVEN_DAY_TRIGGER_REMAINING_PERCENT: f64 = 10.0;
    /// A candidate must still have this much left in every triggered window.
    pub const MINIMUM_CANDIDATE_REMAINING_PERCENT: f64 = 30.0;
    pub const FAILURE_RETRY_INTERVAL_SECS: i64 = 60 * 60;
    pub const SUCCESS_COOLDOWN_SECS: i64 = 30 * 60;
    pub const QUOTA_SNAPSHOT_MAXIMUM_AGE_SECS: i64 = 45;
    pub const TASK_SNAPSHOT_MAXIMUM_AGE_SECS: i64 = 45;
    /// Codex must have been idle this long before a switch is considered.
    pub const CODEX_INACTIVE_PERIOD_SECS: i64 = 2 * 60;
    /// Clock-skew allowance when judging freshness.
    pub const FUTURE_SKEW_ALLOWANCE_SECS: i64 = 5;

    /// Whether no task would be disturbed by a switch.
    ///
    /// A disconnected snapshot is unknown, not empty, so it blocks.
    pub fn has_no_active_tasks(
        snapshot: &SwitchTaskSnapshot,
        legacy_manager_running: bool,
        now: DateTime<Utc>,
    ) -> bool {
        if legacy_manager_running || snapshot.connection_mode == SwitchConnectionMode::Disconnected {
            return false;
        }
        let age = (now - snapshot.refreshed_at).num_seconds();
        if age < -Self::FUTURE_SKEW_ALLOWANCE_SECS || age > Self::TASK_SNAPSHOT_MAXIMUM_AGE_SECS {
            return false;
        }
        !snapshot.records.values().any(|state| state.blocks_switch())
    }

    /// Whether Codex has been idle long enough *and* no task is active.
    pub fn has_safe_task_state(
        snapshot: &SwitchTaskSnapshot,
        codex_inactive_since: Option<DateTime<Utc>>,
        legacy_manager_running: bool,
        now: DateTime<Utc>,
    ) -> bool {
        let Some(inactive_since) = codex_inactive_since else {
            return false;
        };
        if (now - inactive_since).num_seconds() < Self::CODEX_INACTIVE_PERIOD_SECS {
            return false;
        }
        Self::has_no_active_tasks(snapshot, legacy_manager_running, now)
    }

    /// Whether the policy should even consider a switch right now.
    pub fn should_evaluate(
        enabled: bool,
        source_quota: &AutomaticSwitchQuotaState,
        source_refreshed_at: DateTime<Utc>,
        task_snapshot: &SwitchTaskSnapshot,
        codex_inactive_since: Option<DateTime<Utc>>,
        legacy_manager_running: bool,
        last_attempt_at: Option<DateTime<Utc>>,
        last_succeeded_at: Option<DateTime<Utc>>,
        thresholds: LowQuotaAlertThresholds,
        now: DateTime<Utc>,
    ) -> bool {
        let quota_age = (now - source_refreshed_at).num_seconds();
        if !enabled
            || quota_age < -Self::FUTURE_SKEW_ALLOWANCE_SECS
            || quota_age > Self::QUOTA_SNAPSHOT_MAXIMUM_AGE_SECS
            || source_quota.triggered_windows(thresholds).is_empty()
            || !Self::has_safe_task_state(
                task_snapshot,
                codex_inactive_since,
                legacy_manager_running,
                now,
            )
        {
            return false;
        }
        if let Some(last_succeeded_at) = last_succeeded_at {
            if (now - last_succeeded_at).num_seconds() < Self::SUCCESS_COOLDOWN_SECS {
                return false;
            }
        }
        if let Some(last_attempt_at) = last_attempt_at {
            if (now - last_attempt_at).num_seconds() < Self::FAILURE_RETRY_INTERVAL_SECS {
                return false;
            }
        }
        true
    }

    /// Pick the healthiest candidate.
    ///
    /// A candidate must report *every* triggered window; a missing value means
    /// unknown and disqualifies it. Ties break on the smaller profile id so the
    /// choice is deterministic.
    pub fn preferred_candidate<'a>(
        candidates: &'a [SwitchCandidate],
        triggered: &[AutomaticQuotaWindow],
    ) -> Option<&'a SwitchCandidate> {
        if triggered.is_empty() {
            return None;
        }
        let mut best: Option<(&'a SwitchCandidate, f64)> = None;
        for candidate in candidates {
            let mut remaining = Vec::new();
            for window in triggered {
                match candidate.quota.remaining(*window) {
                    Some(value) => remaining.push(value),
                    None => break,
                }
            }
            if remaining.len() != triggered.len() {
                continue;
            }
            let score = remaining.iter().copied().fold(f64::INFINITY, f64::min);
            if score < Self::MINIMUM_CANDIDATE_REMAINING_PERCENT {
                continue;
            }
            match best {
                None => best = Some((candidate, score)),
                Some((current, current_score)) => {
                    let better = if score == current_score {
                        candidate.profile_id < current.profile_id
                    } else {
                        score > current_score
                    };
                    if better {
                        best = Some((candidate, score));
                    }
                }
            }
        }
        best.map(|(candidate, _)| candidate)
    }

    /// The scarcest triggered window, which is what the switch is reacting to.
    pub fn lowest_trigger(source_quota: &AutomaticSwitchQuotaState) -> Option<SwitchReason> {
        source_quota
            .triggered_windows(LowQuotaAlertThresholds::STANDARD)
            .into_iter()
            .filter_map(|window| {
                source_quota
                    .remaining(window)
                    .map(|remaining| SwitchReason {
                        window,
                        remaining_percent: remaining,
                    })
            })
            .min_by(|a, b| {
                a.remaining_percent
                    .partial_cmp(&b.remaining_percent)
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
    }
}

/// A switch destination.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SwitchCandidate {
    pub profile_id: String,
    pub quota: AutomaticSwitchQuotaState,
}

/// A validated switch request, shared by manual and automatic paths.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SwitchRequest {
    pub trigger: SwitchTrigger,
    pub source_profile_id: String,
    pub target_profile_id: String,
    pub reason: Option<SwitchReason>,
}

impl SwitchRequest {
    pub fn manual(source: &str, target: &str) -> Self {
        Self {
            trigger: SwitchTrigger::Manual,
            source_profile_id: source.to_string(),
            target_profile_id: target.to_string(),
            reason: None,
        }
    }

    pub fn automatic(source: &str, target: &str, reason: SwitchReason) -> Self {
        Self {
            trigger: SwitchTrigger::Automatic,
            source_profile_id: source.to_string(),
            target_profile_id: target.to_string(),
            reason: Some(reason),
        }
    }

    /// Both endpoints must be reserved before any write happens.
    ///
    /// Reserving them separately would let the second reservation fail after the
    /// first account was already taken, leaving an orphaned preparation state.
    pub fn validate(&self) -> Result<(), SwitchValidationError> {
        if self.source_profile_id.trim().is_empty() {
            return Err(SwitchValidationError::MissingSource);
        }
        if self.target_profile_id.trim().is_empty() {
            return Err(SwitchValidationError::MissingTarget);
        }
        if self.source_profile_id == self.target_profile_id {
            return Err(SwitchValidationError::SameEndpoint);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SwitchValidationError {
    #[error("a switch needs a source account")]
    MissingSource,
    #[error("a switch needs a target account")]
    MissingTarget,
    #[error("a switch cannot target the account it is leaving")]
    SameEndpoint,
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn at(seconds: i64) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 9, 11, 12, 0, 0)
            .single()
            .expect("valid timestamp")
            + chrono::Duration::seconds(seconds)
    }

    fn quota(five: Option<f64>, seven: Option<f64>) -> AutomaticSwitchQuotaState {
        AutomaticSwitchQuotaState::new(five, seven)
    }

    fn idle(now: DateTime<Utc>) -> SwitchTaskSnapshot {
        SwitchTaskSnapshot {
            connection_mode: SwitchConnectionMode::SharedDaemon,
            records: BTreeMap::new(),
            refreshed_at: now,
        }
    }

    fn active(now: DateTime<Utc>) -> SwitchTaskSnapshot {
        let mut records = BTreeMap::new();
        records.insert("task".to_string(), TaskLiveState::Running);
        SwitchTaskSnapshot {
            connection_mode: SwitchConnectionMode::SharedDaemon,
            records,
            refreshed_at: now,
        }
    }

    fn safe_since(now: DateTime<Utc>) -> DateTime<Utc> {
        now - chrono::Duration::seconds(AutomaticSwitchPolicy::CODEX_INACTIVE_PERIOD_SECS)
    }

    fn candidate(id: &str, five: f64, seven: f64) -> SwitchCandidate {
        SwitchCandidate {
            profile_id: id.to_string(),
            quota: quota(Some(five), Some(seven)),
        }
    }

    #[test]
    fn thresholds_clamp_to_the_offered_choices() {
        assert_eq!(LowQuotaAlertThresholds::new(20, 15), LowQuotaAlertThresholds { five_hour: 20, seven_day: 15 });
        // An unrecognised value falls back rather than widening the trigger.
        assert_eq!(LowQuotaAlertThresholds::new(-1, 100), LowQuotaAlertThresholds::STANDARD);
        assert_eq!(LowQuotaAlertThresholds::new(7, 10), LowQuotaAlertThresholds::STANDARD);
    }

    #[test]
    fn thresholds_read_only_whole_offered_values() {
        let mut settings = BTreeMap::new();
        settings.insert(
            LowQuotaAlertThresholds::FIVE_HOUR_KEY.to_string(),
            SettingsValue::Number(20.0),
        );
        settings.insert(
            LowQuotaAlertThresholds::SEVEN_DAY_KEY.to_string(),
            SettingsValue::Number(15.0),
        );
        assert_eq!(
            LowQuotaAlertThresholds::from_settings(&settings),
            LowQuotaAlertThresholds { five_hour: 20, seven_day: 15 }
        );

        // A fractional or out-of-range value is not honoured.
        settings.insert(
            LowQuotaAlertThresholds::FIVE_HOUR_KEY.to_string(),
            SettingsValue::Number(5.5),
        );
        settings.insert(
            LowQuotaAlertThresholds::SEVEN_DAY_KEY.to_string(),
            SettingsValue::Number(100.0),
        );
        assert_eq!(
            LowQuotaAlertThresholds::from_settings(&settings),
            LowQuotaAlertThresholds::STANDARD
        );

        // A missing map falls back entirely.
        assert_eq!(
            LowQuotaAlertThresholds::from_settings(&BTreeMap::new()),
            LowQuotaAlertThresholds::STANDARD
        );
    }

    #[test]
    fn only_an_explicit_negative_pauses_a_feature() {
        let mut settings = BTreeMap::new();
        settings.insert(
            PausedAutomationFeature::FiveHour.settings_key().to_string(),
            SettingsValue::Text("NO".to_string()),
        );
        settings.insert(
            PausedAutomationFeature::SevenDay.settings_key().to_string(),
            SettingsValue::Number(0.0),
        );
        // An affirmative string is not a pause.
        settings.insert(
            PausedAutomationFeature::LowQuota.settings_key().to_string(),
            SettingsValue::Text("YES".to_string()),
        );
        assert_eq!(
            PausedAutomationFeature::paused_from(&settings),
            vec![
                PausedAutomationFeature::FiveHour,
                PausedAutomationFeature::SevenDay
            ]
        );

        assert!(PausedAutomationFeature::paused_from(&BTreeMap::new()).is_empty());
    }

    #[test]
    fn an_unknown_window_never_triggers_a_switch() {
        assert!(quota(None, Some(f64::NAN))
            .triggered_windows(LowQuotaAlertThresholds::STANDARD)
            .is_empty());
        assert!(quota(Some(f64::INFINITY), None)
            .triggered_windows(LowQuotaAlertThresholds::STANDARD)
            .is_empty());
    }

    #[test]
    fn the_five_hour_rule_is_inclusive_and_the_seven_day_rule_is_exclusive() {
        let custom = LowQuotaAlertThresholds::new(20, 15);
        assert_eq!(
            quota(Some(20.0), Some(15.0)).triggered_windows(custom),
            vec![AutomaticQuotaWindow::FiveHour]
        );
        assert_eq!(
            quota(Some(20.01), Some(14.99)).triggered_windows(custom),
            vec![AutomaticQuotaWindow::SevenDay]
        );
    }

    #[test]
    fn remaining_values_are_clamped_into_range() {
        assert_eq!(quota(Some(-5.0), Some(140.0)), quota(Some(0.0), Some(100.0)));
    }

    #[test]
    fn a_disconnected_snapshot_blocks_because_it_is_unknown_not_empty() {
        assert!(!AutomaticSwitchPolicy::has_no_active_tasks(
            &SwitchTaskSnapshot::disconnected(at(0)),
            false,
            at(0)
        ));
        assert!(AutomaticSwitchPolicy::has_no_active_tasks(&idle(at(0)), false, at(0)));
    }

    #[test]
    fn only_the_blocking_task_states_count() {
        for state in [
            TaskLiveState::Running,
            TaskLiveState::WaitingInput,
            TaskLiveState::Recorded,
            TaskLiveState::Disconnected,
        ] {
            assert!(state.blocks_switch(), "{state:?}");
        }
        for state in [
            TaskLiveState::Idle,
            TaskLiveState::Failed,
            TaskLiveState::Completed,
            TaskLiveState::Interrupted,
        ] {
            assert!(!state.blocks_switch(), "{state:?}");
        }
    }

    #[test]
    fn a_stale_task_snapshot_blocks() {
        assert!(!AutomaticSwitchPolicy::has_no_active_tasks(
            &idle(at(-46)),
            false,
            at(0)
        ));
        // A slightly future timestamp is tolerated as clock skew.
        assert!(AutomaticSwitchPolicy::has_no_active_tasks(&idle(at(3)), false, at(0)));
        assert!(!AutomaticSwitchPolicy::has_no_active_tasks(&idle(at(46)), false, at(0)));
    }

    #[test]
    fn a_running_legacy_manager_blocks() {
        assert!(!AutomaticSwitchPolicy::has_no_active_tasks(&idle(at(0)), true, at(0)));
    }

    #[test]
    fn codex_must_have_been_idle_long_enough() {
        assert!(AutomaticSwitchPolicy::has_safe_task_state(
            &idle(at(0)),
            Some(safe_since(at(0))),
            false,
            at(0)
        ));
        // Not idle long enough.
        assert!(!AutomaticSwitchPolicy::has_safe_task_state(
            &idle(at(0)),
            Some(at(0) - chrono::Duration::seconds(60)),
            false,
            at(0)
        ));
        // Never observed as inactive.
        assert!(!AutomaticSwitchPolicy::has_safe_task_state(&idle(at(0)), None, false, at(0)));
    }

    #[test]
    fn evaluation_requires_a_triggered_window_and_a_safe_task_state() {
        let low = quota(Some(5.0), Some(55.0));
        assert!(AutomaticSwitchPolicy::should_evaluate(
            true,
            &low,
            at(0),
            &idle(at(0)),
            Some(safe_since(at(0))),
            false,
            None,
            None,
            LowQuotaAlertThresholds::STANDARD,
            at(0)
        ));

        // Just above the 5h threshold.
        assert!(!AutomaticSwitchPolicy::should_evaluate(
            true,
            &quota(Some(5.01), Some(55.0)),
            at(0),
            &idle(at(0)),
            Some(safe_since(at(0))),
            false,
            None,
            None,
            LowQuotaAlertThresholds::STANDARD,
            at(0)
        ));

        // Disabled.
        assert!(!AutomaticSwitchPolicy::should_evaluate(
            false,
            &low,
            at(0),
            &idle(at(0)),
            Some(safe_since(at(0))),
            false,
            None,
            None,
            LowQuotaAlertThresholds::STANDARD,
            at(0)
        ));

        // Active task, disconnected snapshot, legacy manager, stale quota.
        assert!(!AutomaticSwitchPolicy::should_evaluate(
            true, &low, at(0), &active(at(0)), Some(safe_since(at(0))), false, None, None,
            LowQuotaAlertThresholds::STANDARD, at(0)
        ));
        assert!(!AutomaticSwitchPolicy::should_evaluate(
            true, &low, at(0), &SwitchTaskSnapshot::disconnected(at(0)),
            Some(safe_since(at(0))), false, None, None,
            LowQuotaAlertThresholds::STANDARD, at(0)
        ));
        assert!(!AutomaticSwitchPolicy::should_evaluate(
            true, &low, at(0), &idle(at(0)), Some(safe_since(at(0))), true, None, None,
            LowQuotaAlertThresholds::STANDARD, at(0)
        ));
        assert!(!AutomaticSwitchPolicy::should_evaluate(
            true, &low, at(-46), &idle(at(0)), Some(safe_since(at(0))), false, None, None,
            LowQuotaAlertThresholds::STANDARD, at(0)
        ));
    }

    #[test]
    fn a_recent_failure_or_success_suppresses_evaluation() {
        let low = quota(Some(5.0), Some(55.0));
        // Failed 5 minutes ago: inside the 1h retry interval.
        assert!(!AutomaticSwitchPolicy::should_evaluate(
            true, &low, at(0), &idle(at(0)), Some(safe_since(at(0))), false,
            Some(at(-300)), None, LowQuotaAlertThresholds::STANDARD, at(0)
        ));
        // Succeeded 5 minutes ago: inside the 30m cooldown.
        assert!(!AutomaticSwitchPolicy::should_evaluate(
            true, &low, at(0), &idle(at(0)), Some(safe_since(at(0))), false,
            None, Some(at(-300)), LowQuotaAlertThresholds::STANDARD, at(0)
        ));
        // Long enough ago.
        assert!(AutomaticSwitchPolicy::should_evaluate(
            true, &low, at(0), &idle(at(0)), Some(safe_since(at(0))), false,
            Some(at(-3601)), Some(at(-1801)), LowQuotaAlertThresholds::STANDARD, at(0)
        ));
    }

    #[test]
    fn the_healthiest_candidate_wins_and_ties_break_deterministically() {
        let candidates = vec![
            candidate("first", 65.0, 80.0),
            candidate("second", 90.0, 45.0),
            candidate("third", 20.0, 99.0),
        ];
        let picked = AutomaticSwitchPolicy::preferred_candidate(&candidates, &[AutomaticQuotaWindow::FiveHour]);
        assert_eq!(picked.map(|c| c.profile_id.as_str()), Some("second"));

        // Equal scores pick the smaller profile id.
        let tied = vec![candidate("b", 50.0, 50.0), candidate("a", 50.0, 50.0)];
        assert_eq!(
            AutomaticSwitchPolicy::preferred_candidate(&tied, &[AutomaticQuotaWindow::FiveHour])
                .map(|c| c.profile_id.as_str()),
            Some("a")
        );
    }

    #[test]
    fn a_candidate_must_report_every_triggered_window() {
        let candidates = vec![candidate("missing", 99.0, 90.0)];
        // Triggered on both windows, but the candidate only reports 5h here via
        // a 7d value, so a genuinely missing window must disqualify it.
        let partial = vec![SwitchCandidate {
            profile_id: "partial".to_string(),
            quota: quota(Some(99.0), None),
        }];
        assert!(AutomaticSwitchPolicy::preferred_candidate(
            &partial,
            &[AutomaticQuotaWindow::FiveHour, AutomaticQuotaWindow::SevenDay]
        )
        .is_none());
        assert!(AutomaticSwitchPolicy::preferred_candidate(&candidates, &[]).is_none());
    }

    #[test]
    fn a_candidate_below_the_floor_is_rejected() {
        let candidates = vec![candidate("weak", 10.0, 80.0)];
        assert!(AutomaticSwitchPolicy::preferred_candidate(
            &candidates,
            &[AutomaticQuotaWindow::FiveHour]
        )
        .is_none());
    }

    #[test]
    fn the_lowest_trigger_is_the_scarcest_window() {
        let state = quota(Some(3.0), Some(8.0));
        let trigger = AutomaticSwitchPolicy::lowest_trigger(&state).expect("a trigger");
        assert_eq!(trigger.window, AutomaticQuotaWindow::FiveHour);
        assert_eq!(trigger.remaining_percent, 3.0);

        assert!(AutomaticSwitchPolicy::lowest_trigger(&quota(Some(90.0), Some(90.0))).is_none());
    }

    #[test]
    fn a_switch_request_must_name_two_different_endpoints() {
        assert!(SwitchRequest::manual("a", "b").validate().is_ok());
        assert_eq!(
            SwitchRequest::manual("  ", "b").validate(),
            Err(SwitchValidationError::MissingSource)
        );
        assert_eq!(
            SwitchRequest::manual("a", "").validate(),
            Err(SwitchValidationError::MissingTarget)
        );
        assert_eq!(
            SwitchRequest::manual("a", "a").validate(),
            Err(SwitchValidationError::SameEndpoint)
        );
    }

    #[test]
    fn manual_and_automatic_requests_share_one_shape() {
        let reason = SwitchReason {
            window: AutomaticQuotaWindow::FiveHour,
            remaining_percent: 2.0,
        };
        let automatic = SwitchRequest::automatic("a", "b", reason);
        assert_eq!(automatic.trigger, SwitchTrigger::Automatic);
        assert_eq!(automatic.reason, Some(reason));

        let manual = SwitchRequest::manual("a", "b");
        assert_eq!(manual.trigger, SwitchTrigger::Manual);
        assert_eq!(manual.reason, None);
        // Same validation, same downstream path.
        assert!(manual.validate().is_ok());
        assert!(automatic.validate().is_ok());
    }
}
