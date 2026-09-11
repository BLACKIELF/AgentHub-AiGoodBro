use crate::models::leadership::LeadershipDashboardSnapshot;
use serde::{Deserialize, Serialize};

/// Supported AI runtimes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeScope {
    Codex,
    ClaudeCode,
}

impl RuntimeScope {
    pub fn runtime_id(&self) -> &'static str {
        match self {
            RuntimeScope::Codex => "codex",
            RuntimeScope::ClaudeCode => "claude-code",
        }
    }

    pub fn display_name(&self) -> &'static str {
        match self {
            RuntimeScope::Codex => "Codex",
            RuntimeScope::ClaudeCode => "Claude Code",
        }
    }
}

/// Status of a runtime in the menu / tray.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeMenuStatus {
    Available,
    LocalOnly,
    SnapshotNeeded,
    Stale,
    Unavailable,
}

impl RuntimeMenuStatus {
    pub fn localized(&self, english: bool) -> &'static str {
        match (self, english) {
            (RuntimeMenuStatus::Available, false) => "可用",
            (RuntimeMenuStatus::Available, true) => "Available",
            (RuntimeMenuStatus::LocalOnly, false) => "本机统计",
            (RuntimeMenuStatus::LocalOnly, true) => "Local only",
            (RuntimeMenuStatus::SnapshotNeeded, false) => "需要快照",
            (RuntimeMenuStatus::SnapshotNeeded, true) => "Snapshot needed",
            (RuntimeMenuStatus::Stale, false) => "快照过期",
            (RuntimeMenuStatus::Stale, true) => "Stale",
            (RuntimeMenuStatus::Unavailable, false) => "暂不可用",
            (RuntimeMenuStatus::Unavailable, true) => "Unavailable",
        }
    }
}

/// A rate limit window.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RateWindow {
    pub used_percent: f64,
    pub window_duration_mins: Option<i64>,
    #[serde(with = "chrono::serde::ts_milliseconds_option")]
    pub resets_at: Option<chrono::DateTime<chrono::Utc>>,
}

impl RateWindow {
    pub fn remaining_percent(&self) -> Option<f64> {
        if !self.used_percent.is_finite() {
            return None;
        }
        Some((100.0 - self.used_percent).clamp(0.0, 100.0))
    }
}

/// Account information.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AccountInfo {
    pub r#type: String,
    pub plan_type: Option<String>,
    pub email_present: bool,
}

/// A full usage snapshot for one runtime.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UsageSnapshot {
    #[serde(with = "chrono::serde::ts_milliseconds")]
    pub refreshed_at: chrono::DateTime<chrono::Utc>,
    pub account: AccountInfo,
    pub limit_id: String,
    pub limit_name: String,
    pub quota_read_succeeded: bool,
    pub five_hour_quota: Option<RateWindow>,
    pub seven_day_quota: Option<RateWindow>,
    pub monthly_quota: Option<RateWindow>,
    pub local: Option<LocalUsage>,
    pub task_board: Option<TaskBoard>,
    pub messages: Vec<String>,
}

/// Snapshot with runtime scope and status.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RuntimeUsageSnapshot {
    pub scope: RuntimeScope,
    pub snapshot: UsageSnapshot,
    pub status: RuntimeMenuStatus,
    pub quota_source_label: String,
    pub usage_source_label: String,
}

/// Aggregated multi-runtime snapshot.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MultiRuntimeUsageSnapshot {
    #[serde(with = "chrono::serde::ts_milliseconds")]
    pub refreshed_at: chrono::DateTime<chrono::Utc>,
    pub runtimes: Vec<RuntimeUsageSnapshot>,
    pub aggregate: UsageSnapshot,
    pub messages: Vec<String>,
}

/// Dashboard-level snapshot returned for Codex-only UI integration.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CodexDashboardSnapshot {
    pub codex: RuntimeUsageSnapshot,
    pub leadership: CodexLeadershipSignal,
    #[serde(with = "chrono::serde::ts_milliseconds")]
    pub refreshed_at: chrono::DateTime<chrono::Utc>,
    pub messages: Vec<String>,
}

/// Independent leadership signal for the dashboard.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CodexLeadershipSignal {
    pub score: Option<i32>,
    pub evidence_coverage: f64,
    pub active_day_count: i64,
    pub period: String,
    pub model_version: String,
    pub report: Option<LeadershipDashboardSnapshot>,
}

// Re-export from usage module for convenience.
pub use super::usage::{LocalUsage, TaskBoard};
