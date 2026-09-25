use std::collections::VecDeque;

use anyhow::Result;
use codexu_core::readers::codex_app_server::{
    read_installed_codex_quota, read_quota_from_transport, AppServerTransport,
    CodexAppServerQuotaSnapshot,
};
use serde_json::json;

#[test]
fn treats_a_single_weekly_app_server_window_as_an_authoritative_quota() {
    let quota = CodexAppServerQuotaSnapshot::from_rate_limit_response(&json!({
        "rateLimits": {
            "limitId": "codex",
            "limitName": "Codex",
            "primary": {
                "usedPercent": 41,
                "windowDurationMins": 10080,
                "resetsAt": 1_800_000_000
            },
            "secondary": null
        }
    }));

    assert!(quota.quota_read_succeeded);
    assert!(quota.five_hour_quota.is_none());
    assert_eq!(
        quota.seven_day_quota.expect("weekly quota").used_percent,
        41.0
    );
    assert!(quota.monthly_quota.is_none());
}

#[test]
fn parses_only_valid_official_balances_and_reset_counts() {
    let parsed = CodexAppServerQuotaSnapshot::from_rate_limit_response(&json!({
        "rateLimits": {
            "primary": {"usedPercent": 10, "windowDurationMins": 300},
            "secondary": null,
            "credits": {"balance": "USD 12.50"}
        },
        "rateLimitResetCredits": {"availableCount": 3}
    }));
    assert_eq!(parsed.credit_balance_usd, Some(12.5));
    assert_eq!(parsed.credit_balance_points, None);
    assert_eq!(parsed.reset_credit_count, Some(3));

    let points = CodexAppServerQuotaSnapshot::from_rate_limit_response(&json!({
        "rateLimits": {
            "primary": {"usedPercent": 10, "windowDurationMins": 300},
            "credits": {"balance": 42}
        }
    }));
    assert_eq!(points.credit_balance_usd, None);
    assert_eq!(points.credit_balance_points, Some(42.0));
    assert_eq!(points.reset_credit_count, None);

    for bad in [json!("12 EUR"), json!(-1), json!("NaN")] {
        let value = CodexAppServerQuotaSnapshot::from_rate_limit_response(&json!({
            "rateLimits": {
                "primary": {"usedPercent": 10, "windowDurationMins": 300},
                "credits": {"balance": bad}
            },
            "rateLimitResetCredits": {"availableCount": -1}
        }));
        assert_eq!(value.credit_balance_usd, None);
        assert_eq!(value.credit_balance_points, None);
        assert_eq!(value.reset_credit_count, None);
    }
}

struct FixtureTransport {
    responses: VecDeque<serde_json::Value>,
}

impl FixtureTransport {
    fn with_responses(responses: impl IntoIterator<Item = serde_json::Value>) -> Self {
        Self {
            responses: responses.into_iter().collect(),
        }
    }
}

impl AppServerTransport for FixtureTransport {
    async fn request(&mut self, _request: serde_json::Value) -> Result<serde_json::Value> {
        Ok(self.responses.pop_front().expect("fixture response"))
    }

    async fn notify(&mut self, _notification: serde_json::Value) -> Result<()> {
        Ok(())
    }
}

#[tokio::test]
async fn reads_account_metadata_and_weekly_quota_through_the_app_server_protocol() {
    let mut transport = FixtureTransport::with_responses([
        json!({"id": 1, "result": {}}),
        json!({
            "id": 2,
            "result": {"account": {"type": "chatgpt", "planType": "pro", "email": "hidden@example.test"}}
        }),
        json!({
            "id": 3,
            "result": {
                "rateLimits": {
                    "limitId": "codex",
                    "limitName": "Codex",
                    "planType": " PROLITE ",
                    "primary": {"usedPercent": 41, "windowDurationMins": 10080, "resetsAt": 1_800_000_000},
                    "secondary": null,
                    "credits": {"balance": "75 points"}
                },
                "rateLimitResetCredits": {"availableCount": 2}
            }
        }),
    ]);

    let quota = read_quota_from_transport(&mut transport)
        .await
        .expect("official quota response");

    let account = quota.account.expect("account");
    assert_eq!(account.r#type, "chatgpt");
    assert_eq!(account.plan_type.as_deref(), Some("prolite"));
    assert!(account.email_present);
    assert_eq!(quota.limit_id.as_deref(), Some("codex"));
    assert_eq!(quota.limit_name.as_deref(), Some("Codex"));
    assert_eq!(quota.credit_balance_usd, None);
    assert_eq!(quota.credit_balance_points, Some(75.0));
    assert_eq!(quota.reset_credit_count, Some(2));
    assert!(quota.quota_read_succeeded);
    assert_eq!(
        quota.seven_day_quota.expect("weekly quota").used_percent,
        41.0
    );
}

#[cfg(windows)]
#[tokio::test]
#[ignore = "requires the locally installed Codex CLI and authenticated account"]
async fn installed_codex_app_server_returns_at_least_one_authoritative_window() {
    let quota = read_installed_codex_quota()
        .await
        .expect("installed Codex app-server quota response");

    assert!(quota.quota_read_succeeded);
    assert!(
        quota.five_hour_quota.is_some()
            || quota.seven_day_quota.is_some()
            || quota.monthly_quota.is_some()
    );
}
