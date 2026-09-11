use chrono::Utc;
use codexu_core::{
    readers::{apply_official_quota, retain_last_verified_quota, CodexAppServerQuotaSnapshot},
    AccountInfo, CodexDashboardSnapshot, CodexLeadershipSignal, RateWindow, RuntimeMenuStatus,
    RuntimeScope, RuntimeUsageSnapshot, UsageSnapshot,
};

fn local_dashboard() -> CodexDashboardSnapshot {
    let now = Utc::now();
    CodexDashboardSnapshot {
        codex: RuntimeUsageSnapshot {
            scope: RuntimeScope::Codex,
            snapshot: UsageSnapshot {
                refreshed_at: now,
                account: AccountInfo {
                    r#type: "codex-local".to_string(),
                    plan_type: None,
                    email_present: false,
                },
                limit_id: "codex-local".to_string(),
                limit_name: "Codex local snapshot".to_string(),
                quota_read_succeeded: false,
                five_hour_quota: None,
                seven_day_quota: None,
                monthly_quota: None,
                local: None,
                task_board: None,
                messages: vec![],
            },
            status: RuntimeMenuStatus::LocalOnly,
            quota_source_label: "Checking official Codex quota".to_string(),
            usage_source_label: "Local Codex transcript data".to_string(),
        },
        leadership: CodexLeadershipSignal {
            score: None,
            evidence_coverage: 0.0,
            active_day_count: 0,
            period: "twentyEightDays".to_string(),
            model_version: "1.3-codex-interval".to_string(),
            report: None,
        },
        refreshed_at: now,
        messages: vec![],
    }
}

#[test]
fn applies_a_weekly_official_quota_without_inventing_a_five_hour_window() {
    let dashboard = apply_official_quota(
        local_dashboard(),
        CodexAppServerQuotaSnapshot {
            account: Some(AccountInfo {
                r#type: "chatgpt".to_string(),
                plan_type: Some("pro".to_string()),
                email_present: true,
            }),
            limit_id: Some("codex".to_string()),
            limit_name: Some("Codex".to_string()),
            quota_read_succeeded: true,
            five_hour_quota: None,
            seven_day_quota: Some(RateWindow {
                used_percent: 41.0,
                window_duration_mins: Some(10_080),
                resets_at: None,
            }),
            monthly_quota: None,
            available_reset_credits: None,
            reset_credit_expiries: None,
        },
    );

    assert_eq!(dashboard.codex.status, RuntimeMenuStatus::Available);
    assert!(dashboard.codex.snapshot.quota_read_succeeded);
    assert!(dashboard.codex.snapshot.five_hour_quota.is_none());
    assert_eq!(
        dashboard
            .codex
            .snapshot
            .seven_day_quota
            .expect("weekly quota")
            .used_percent,
        41.0
    );
    assert_eq!(dashboard.codex.quota_source_label, "Official Codex quota");
}

#[test]
fn keeps_a_previous_official_window_visible_as_stale_after_a_refresh_failure() {
    let previous = apply_official_quota(
        local_dashboard(),
        CodexAppServerQuotaSnapshot {
            account: None,
            limit_id: Some("codex".to_string()),
            limit_name: Some("Codex".to_string()),
            quota_read_succeeded: true,
            five_hour_quota: None,
            seven_day_quota: Some(RateWindow {
                used_percent: 41.0,
                window_duration_mins: Some(10_080),
                resets_at: None,
            }),
            monthly_quota: None,
            available_reset_credits: None,
            reset_credit_expiries: None,
        },
    );

    let refreshed = retain_last_verified_quota(Some(&previous), local_dashboard());

    assert_eq!(refreshed.codex.status, RuntimeMenuStatus::Stale);
    assert!(!refreshed.codex.snapshot.quota_read_succeeded);
    assert_eq!(
        refreshed
            .codex
            .snapshot
            .seven_day_quota
            .expect("retained weekly quota")
            .used_percent,
        41.0
    );
    assert_eq!(
        refreshed.codex.quota_source_label,
        "Official Codex quota - last verified"
    );
}
