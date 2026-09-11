//! Bridges the official Codex quota into the workbench account contract.
//!
//! Two callers produce official quota on Windows:
//!
//! * `CodexAppServerQuotaSnapshot` — a direct read of the local Codex
//!   app-server.
//! * `UsageSnapshot` — the dashboard pipeline, which already read the same
//!   app-server and cached the result.
//!
//! Both are expressed through [`OfficialQuotaInput`] so the conversion and the
//! retention rule exist exactly once.
//!
//! The retention rule mirrors `retain_last_verified_quota` in
//! `codex_dashboard.rs`: when the newest read fails, the last verified windows
//! are kept but labelled `Stale`. They are never relabelled as fresh, and the
//! observation time stays the time the values were actually observed.

use chrono::{DateTime, Duration, Utc};

use crate::models::quota::{
    AccountQuotaSnapshot, QuotaSourceQuality, QuotaWindowSnapshot,
};
use crate::models::{RateWindow, UsageSnapshot};
use crate::readers::CodexAppServerQuotaSnapshot;

/// The official-quota fields shared by every Windows source.
#[derive(Debug, Clone, Default)]
pub struct OfficialQuotaInput<'a> {
    pub limit_id: Option<&'a str>,
    pub limit_name: Option<&'a str>,
    pub quota_read_succeeded: bool,
    pub five_hour: Option<&'a RateWindow>,
    pub seven_day: Option<&'a RateWindow>,
    pub monthly: Option<&'a RateWindow>,
    pub available_reset_credits: Option<u32>,
    pub reset_credit_expiries: Option<Vec<DateTime<Utc>>>,
}

impl<'a> OfficialQuotaInput<'a> {
    pub fn from_app_server(quota: &'a CodexAppServerQuotaSnapshot) -> Self {
        Self {
            limit_id: quota.limit_id.as_deref(),
            limit_name: quota.limit_name.as_deref(),
            quota_read_succeeded: quota.quota_read_succeeded,
            five_hour: quota.five_hour_quota.as_ref(),
            seven_day: quota.seven_day_quota.as_ref(),
            monthly: quota.monthly_quota.as_ref(),
            available_reset_credits: quota.available_reset_credits,
            reset_credit_expiries: quota.reset_credit_expiries.clone(),
        }
    }

    pub fn from_usage_snapshot(snapshot: &'a UsageSnapshot) -> Self {
        Self {
            limit_id: Some(snapshot.limit_id.as_str()),
            limit_name: Some(snapshot.limit_name.as_str()),
            quota_read_succeeded: snapshot.quota_read_succeeded,
            five_hour: snapshot.five_hour_quota.as_ref(),
            seven_day: snapshot.seven_day_quota.as_ref(),
            monthly: snapshot.monthly_quota.as_ref(),
            available_reset_credits: None,
            reset_credit_expiries: None,
        }
    }
}

fn to_window(rate: Option<&RateWindow>) -> Option<QuotaWindowSnapshot> {
    rate.map(|rate| QuotaWindowSnapshot {
        used_percent: rate.used_percent,
        window_duration_mins: rate.window_duration_mins,
        resets_at: rate.resets_at,
    })
}

/// Convert one official read into the workbench contract.
///
/// Quality follows the data, not the attempt:
///
/// * read succeeded → `Official`, with the reported windows.
/// * read failed but windows are present → `Stale`. This is the case where the
///   caller (or the dashboard's own retention step) kept the last verified
///   windows; they are shown, but never as current evidence.
/// * read failed and no window is present → `LocalOnly`, so the workbench shows
///   `—` rather than an official-looking zero.
///
/// A failed read with no previous observation therefore produces no windows;
/// [`retain_last_verified_account_quota`] is available when the caller holds a
/// previous observation of its own.
pub fn quota_snapshot_from_official(
    account_id: &str,
    input: OfficialQuotaInput<'_>,
    fetched_at: DateTime<Utc>,
) -> AccountQuotaSnapshot {
    let has_windows =
        input.five_hour.is_some() || input.seven_day.is_some() || input.monthly.is_some();

    let (quality, carry_windows) = if input.quota_read_succeeded {
        (QuotaSourceQuality::Official, true)
    } else if has_windows {
        (QuotaSourceQuality::Stale, true)
    } else {
        (QuotaSourceQuality::LocalOnly, false)
    };

    AccountQuotaSnapshot {
        account_id: account_id.to_string(),
        limit_id: input.limit_id.map(str::to_owned),
        limit_name: input.limit_name.map(str::to_owned),
        five_hour: carry_windows.then(|| to_window(input.five_hour)).flatten(),
        seven_day: carry_windows.then(|| to_window(input.seven_day)).flatten(),
        monthly: carry_windows.then(|| to_window(input.monthly)).flatten(),
        available_reset_credits: input.available_reset_credits,
        reset_credit_expiries: input.reset_credit_expiries.clone(),
        credit_balance: None,
        credit_balance_unlimited: None,
        fetched_at,
        app_server_version: None,
        quota_read_succeeded: Some(input.quota_read_succeeded),
        quality,
    }
}

/// Keep the last verified windows when the newest read failed.
///
/// `fetched_at` is taken from the retained observation, not from `next`, so the
/// UI reports when the numbers were actually seen. `quality` becomes `Stale`,
/// which also closes the quota gate.
pub fn retain_last_verified_account_quota(
    previous: Option<&AccountQuotaSnapshot>,
    next: AccountQuotaSnapshot,
) -> AccountQuotaSnapshot {
    if next.quota_read_succeeded == Some(true) {
        return next;
    }

    let Some(previous) = previous else {
        return next;
    };
    if !previous.has_any_window() {
        return next;
    }

    AccountQuotaSnapshot {
        five_hour: previous.five_hour.clone(),
        seven_day: previous.seven_day.clone(),
        monthly: previous.monthly.clone(),
        available_reset_credits: previous.available_reset_credits,
        reset_credit_expiries: previous.reset_credit_expiries.clone(),
        limit_id: previous.limit_id.clone(),
        limit_name: previous.limit_name.clone(),
        fetched_at: previous.fetched_at,
        quality: QuotaSourceQuality::Stale,
        ..next
    }
}

/// Downgrade an official snapshot once it ages past the freshness window.
///
/// A stale snapshot keeps its values so the workbench can still show them, but
/// the label stops it from being treated as current evidence.
pub fn degrade_stale_quality(
    snapshot: AccountQuotaSnapshot,
    now: DateTime<Utc>,
    max_age: Duration,
) -> AccountQuotaSnapshot {
    if snapshot.quality != QuotaSourceQuality::Official {
        return snapshot;
    }
    if snapshot.is_fresh(now, max_age) {
        return snapshot;
    }
    AccountQuotaSnapshot {
        quality: QuotaSourceQuality::Stale,
        ..snapshot
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::AccountInfo;
    use chrono::TimeZone;

    fn at(minutes: i64) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 9, 11, 12, 0, 0)
            .single()
            .expect("valid timestamp")
            + Duration::minutes(minutes)
    }

    fn window(used_percent: f64) -> RateWindow {
        RateWindow {
            used_percent,
            window_duration_mins: Some(300),
            resets_at: Some(at(120)),
        }
    }

    fn app_server(five: Option<f64>, seven: Option<f64>, succeeded: bool) -> CodexAppServerQuotaSnapshot {
        CodexAppServerQuotaSnapshot {
            account: Some(AccountInfo {
                r#type: "chatgpt".to_string(),
                plan_type: Some("plus".to_string()),
                email_present: true,
            }),
            limit_id: Some("limit-1".to_string()),
            limit_name: Some("Plus".to_string()),
            quota_read_succeeded: succeeded,
            five_hour_quota: five.map(window),
            seven_day_quota: seven.map(window),
            monthly_quota: None,
            available_reset_credits: None,
            reset_credit_expiries: None,
        }
    }

    #[test]
    fn a_successful_read_maps_every_window_and_is_official() {
        let quota = app_server(Some(25.0), Some(60.0), true);
        let snapshot = quota_snapshot_from_official(
            "system",
            OfficialQuotaInput::from_app_server(&quota),
            at(0),
        );

        assert_eq!(snapshot.account_id, "system");
        assert_eq!(snapshot.quality, QuotaSourceQuality::Official);
        assert_eq!(snapshot.quota_read_succeeded, Some(true));
        assert_eq!(snapshot.limit_id.as_deref(), Some("limit-1"));
        assert_eq!(snapshot.five_hour.as_ref().map(|w| w.used_percent), Some(25.0));
        assert_eq!(snapshot.seven_day.as_ref().map(|w| w.used_percent), Some(60.0));
        assert_eq!(snapshot.monthly, None);
        assert_eq!(snapshot.fetched_at, at(0));
        assert_eq!(snapshot.available_reset_credits, None);
        assert_eq!(snapshot.credit_balance, None);
    }

    #[test]
    fn app_server_reset_credits_are_carried_into_the_workbench_snapshot() {
        let mut quota = app_server(Some(25.0), Some(60.0), true);
        quota.available_reset_credits = Some(2);
        quota.reset_credit_expiries = Some(vec![at(120)]);
        let snapshot = quota_snapshot_from_official(
            "profile-a",
            OfficialQuotaInput::from_app_server(&quota),
            at(0),
        );
        assert_eq!(snapshot.available_reset_credits, Some(2));
        assert_eq!(snapshot.reset_credit_expiries, Some(vec![at(120)]));
    }

    #[test]
    fn a_failed_read_with_no_windows_is_local_only() {
        let quota = app_server(None, None, false);
        let snapshot = quota_snapshot_from_official(
            "system",
            OfficialQuotaInput::from_app_server(&quota),
            at(0),
        );

        assert_eq!(snapshot.quality, QuotaSourceQuality::LocalOnly);
        assert_eq!(snapshot.quota_read_succeeded, Some(false));
        assert!(!snapshot.has_any_window());
        assert_eq!(snapshot.five_hour, None);
    }

    #[test]
    fn windows_kept_without_a_successful_read_are_stale_not_official() {
        // This is the shape the dashboard produces after its own retention step:
        // the read failed, but the last verified windows are still attached.
        let quota = app_server(Some(25.0), Some(60.0), false);
        let snapshot = quota_snapshot_from_official(
            "system",
            OfficialQuotaInput::from_app_server(&quota),
            at(0),
        );

        assert_eq!(snapshot.quality, QuotaSourceQuality::Stale);
        assert_eq!(snapshot.five_hour.as_ref().map(|w| w.used_percent), Some(25.0));
        assert_eq!(snapshot.seven_day.as_ref().map(|w| w.used_percent), Some(60.0));
        assert_eq!(snapshot.quota_read_succeeded, Some(false));
    }

    #[test]
    fn a_read_that_returned_no_window_stays_unknown() {
        let quota = app_server(None, None, true);
        let snapshot = quota_snapshot_from_official(
            "system",
            OfficialQuotaInput::from_app_server(&quota),
            at(0),
        );

        assert_eq!(snapshot.quality, QuotaSourceQuality::Official);
        assert!(!snapshot.has_any_window());
    }

    #[test]
    fn the_dashboard_usage_snapshot_maps_through_the_same_path() {
        let usage = UsageSnapshot {
            refreshed_at: at(5),
            account: AccountInfo {
                r#type: "chatgpt".to_string(),
                plan_type: Some("plus".to_string()),
                email_present: true,
            },
            limit_id: "limit-2".to_string(),
            limit_name: "Pro".to_string(),
            quota_read_succeeded: true,
            five_hour_quota: Some(window(10.0)),
            seven_day_quota: Some(window(80.0)),
            monthly_quota: None,
            local: None,
            task_board: None,
            messages: vec![],
        };

        let snapshot = quota_snapshot_from_official(
            "system",
            OfficialQuotaInput::from_usage_snapshot(&usage),
            usage.refreshed_at,
        );

        assert_eq!(snapshot.quality, QuotaSourceQuality::Official);
        assert_eq!(snapshot.limit_name.as_deref(), Some("Pro"));
        assert_eq!(snapshot.five_hour.as_ref().map(|w| w.used_percent), Some(10.0));
        assert_eq!(snapshot.fetched_at, at(5));
    }

    #[test]
    fn a_dashboard_snapshot_carrying_retained_windows_maps_to_stale() {
        // Mirrors `retain_last_verified_quota`: the dashboard reports a failed
        // read but keeps the previously verified windows attached.
        let usage = UsageSnapshot {
            refreshed_at: at(30),
            account: AccountInfo {
                r#type: "chatgpt".to_string(),
                plan_type: Some("plus".to_string()),
                email_present: true,
            },
            limit_id: "limit-1".to_string(),
            limit_name: "Plus".to_string(),
            quota_read_succeeded: false,
            five_hour_quota: Some(window(25.0)),
            seven_day_quota: Some(window(60.0)),
            monthly_quota: None,
            local: None,
            task_board: None,
            messages: vec![],
        };

        let snapshot = quota_snapshot_from_official(
            "system",
            OfficialQuotaInput::from_usage_snapshot(&usage),
            usage.refreshed_at,
        );

        assert_eq!(snapshot.quality, QuotaSourceQuality::Stale);
        assert!(snapshot.has_any_window());
        assert_eq!(snapshot.five_hour.as_ref().map(|w| w.used_percent), Some(25.0));
    }

    #[test]
    fn a_failed_read_retains_the_last_verified_windows_as_stale() {
        let previous = quota_snapshot_from_official(
            "system",
            OfficialQuotaInput::from_app_server(&app_server(Some(25.0), Some(60.0), true)),
            at(0),
        );
        let failed = quota_snapshot_from_official(
            "system",
            OfficialQuotaInput::from_app_server(&app_server(None, None, false)),
            at(30),
        );

        let retained = retain_last_verified_account_quota(Some(&previous), failed);

        assert_eq!(retained.quality, QuotaSourceQuality::Stale);
        assert_eq!(retained.five_hour.as_ref().map(|w| w.used_percent), Some(25.0));
        assert_eq!(retained.seven_day.as_ref().map(|w| w.used_percent), Some(60.0));
        // The observation time is when the values were seen, not when we retried.
        assert_eq!(retained.fetched_at, at(0));
        // The failed attempt is still recorded as a failed attempt.
        assert_eq!(retained.quota_read_succeeded, Some(false));
    }

    #[test]
    fn retention_keeps_previous_reset_credits() {
        let mut previous_quota = app_server(Some(25.0), Some(60.0), true);
        previous_quota.available_reset_credits = Some(3);
        previous_quota.reset_credit_expiries = Some(vec![at(90)]);
        let previous = quota_snapshot_from_official(
            "system",
            OfficialQuotaInput::from_app_server(&previous_quota),
            at(0),
        );
        let failed = quota_snapshot_from_official(
            "system",
            OfficialQuotaInput::from_app_server(&app_server(None, None, false)),
            at(30),
        );
        let retained = retain_last_verified_account_quota(Some(&previous), failed);
        assert_eq!(retained.available_reset_credits, Some(3));
        assert_eq!(retained.reset_credit_expiries, Some(vec![at(90)]));
    }

    #[test]
    fn retention_does_nothing_without_a_usable_previous_observation() {
        let failed = quota_snapshot_from_official(
            "system",
            OfficialQuotaInput::from_app_server(&app_server(None, None, false)),
            at(30),
        );
        let no_previous = retain_last_verified_account_quota(None, failed.clone());
        assert_eq!(no_previous.quality, QuotaSourceQuality::LocalOnly);

        let empty_previous = quota_snapshot_from_official(
            "system",
            OfficialQuotaInput::from_app_server(&app_server(None, None, true)),
            at(0),
        );
        let retained = retain_last_verified_account_quota(Some(&empty_previous), failed);
        assert_eq!(retained.quality, QuotaSourceQuality::LocalOnly);
    }

    #[test]
    fn a_successful_read_is_never_replaced_by_retention() {
        let previous = quota_snapshot_from_official(
            "system",
            OfficialQuotaInput::from_app_server(&app_server(Some(90.0), Some(90.0), true)),
            at(0),
        );
        let fresh = quota_snapshot_from_official(
            "system",
            OfficialQuotaInput::from_app_server(&app_server(Some(10.0), Some(20.0), true)),
            at(30),
        );

        let result = retain_last_verified_account_quota(Some(&previous), fresh);
        assert_eq!(result.quality, QuotaSourceQuality::Official);
        assert_eq!(result.five_hour.as_ref().map(|w| w.used_percent), Some(10.0));
        assert_eq!(result.fetched_at, at(30));
    }

    #[test]
    fn an_aged_official_snapshot_is_downgraded_to_stale() {
        let snapshot = quota_snapshot_from_official(
            "system",
            OfficialQuotaInput::from_app_server(&app_server(Some(25.0), Some(60.0), true)),
            at(0),
        );

        let fresh = degrade_stale_quality(snapshot.clone(), at(10), Duration::minutes(30));
        assert_eq!(fresh.quality, QuotaSourceQuality::Official);

        let stale = degrade_stale_quality(snapshot, at(45), Duration::minutes(30));
        assert_eq!(stale.quality, QuotaSourceQuality::Stale);
        // Values survive the downgrade so the workbench can still show them.
        assert!(stale.has_any_window());
    }

    #[test]
    fn degradation_never_upgrades_a_non_official_quality() {
        let local_only = quota_snapshot_from_official(
            "system",
            OfficialQuotaInput::from_app_server(&app_server(None, None, false)),
            at(0),
        );
        let degraded = degrade_stale_quality(local_only, at(600), Duration::minutes(30));
        assert_eq!(degraded.quality, QuotaSourceQuality::LocalOnly);
    }

    #[test]
    fn a_retained_stale_snapshot_closes_the_quota_gate() {
        use crate::models::quota::{evaluate_quota_gate, QuotaGate, QuotaGateBlock};

        let previous = quota_snapshot_from_official(
            "system",
            OfficialQuotaInput::from_app_server(&app_server(Some(25.0), Some(60.0), true)),
            at(0),
        );
        let failed = quota_snapshot_from_official(
            "system",
            OfficialQuotaInput::from_app_server(&app_server(None, None, false)),
            at(30),
        );
        let retained = retain_last_verified_account_quota(Some(&previous), failed);

        assert_eq!(
            evaluate_quota_gate(Some(&retained), at(30), Duration::minutes(30), true),
            QuotaGate::Blocked(QuotaGateBlock::StaleEvidence)
        );
    }
}
