use super::{
    account_lifecycle::ManagedAccountState, local_proxy::LocalProxyState,
    notifications::NotificationState,
};
use codexu_core::{
    accounts::AccountManager, notifications::NotificationService, proxy::ProxyPreferences,
    readers::CodexAppServerQuotaSnapshot,
};
use serde::Serialize;
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};
use tauri::State;

static REFRESHING: AtomicBool = AtomicBool::new(false);
struct RefreshGuard;
impl Drop for RefreshGuard {
    fn drop(&mut self) {
        REFRESHING.store(false, Ordering::Release);
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaDto {
    five_hour_used_percent: Option<f64>,
    five_hour_resets_at: Option<f64>,
    seven_day_used_percent: Option<f64>,
    seven_day_resets_at: Option<f64>,
    monthly_used_percent: Option<f64>,
    monthly_resets_at: Option<f64>,
    observed_at: i64,
    credit_balance_points: Option<String>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProxyAccountDto {
    id: String,
    label: String,
    plan_type: Option<String>,
    is_last: bool,
    is_priority: bool,
    is_enabled: bool,
    quota: Option<QuotaDto>,
    availability: &'static str,
    reason_code: Option<&'static str>,
}
fn quota_projection(value: &serde_json::Value, observed_at: i64) -> QuotaDto {
    let quota = CodexAppServerQuotaSnapshot::from_rate_limit_response(value);
    let seconds = |window: &Option<codexu_core::RateWindow>| {
        window
            .as_ref()
            .and_then(|w| w.resets_at.as_ref())
            .map(|v| v.timestamp_millis() as f64 / 1000.0)
    };
    QuotaDto {
        five_hour_used_percent: quota.five_hour_quota.as_ref().map(|q| q.used_percent),
        five_hour_resets_at: seconds(&quota.five_hour_quota),
        seven_day_used_percent: quota.seven_day_quota.as_ref().map(|q| q.used_percent),
        seven_day_resets_at: seconds(&quota.seven_day_quota),
        monthly_used_percent: quota.monthly_quota.as_ref().map(|q| q.used_percent),
        monthly_resets_at: seconds(&quota.monthly_quota),
        observed_at,
        credit_balance_points: quota.credit_balance_points.map(|p| p.to_string()),
    }
}
fn project(
    manager: &AccountManager,
    gate: &codexu_core::managed_proxy::ManagedProxyGate,
    prefs: &ProxyPreferences,
    refresh: bool,
    notifications: Option<&NotificationService>,
) -> Result<Vec<ProxyAccountDto>, String> {
    let accounts = manager
        .list_managed_accounts()
        .map_err(|e| e.code.to_owned())?;
    // Each official read is independently bounded by the native runtime. Stop
    // starting further reads after this budget, rather than multiplying that
    // timeout by every stored account or allowing overlapping refresh batches.
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut rows = Vec::new();
    for account in accounts {
        if account.platform != "codex" {
            continue;
        }
        let can_refresh = refresh && Instant::now() < deadline;
        let requested_fresh =
            can_refresh && matches!(account.login_state, "verified" | "needs_reauth");
        let evidence = gate
            .quota_snapshot(&account.id, requested_fresh)
            .map_err(|error| codexu_core::accounts::AccountError { code: error.code() });
        let (plan, quota, reason) = match evidence {
            Ok(e) => {
                // A display-only cached fallback cannot generate official
                // quota/reset events. Desktop-owned evidence must also match
                // the verified vault snapshot before using its identity.
                if requested_fresh {
                    if let Some(service) = notifications {
                        if let Ok(snapshot) = manager.verified_credential_snapshot(&account.id, 45)
                        {
                            if snapshot.observed_at == e.observed_at
                                && snapshot.official_quota == e.official_quota
                            {
                                if let Err(error) =
                                    service.queue_managed_quota(&account.label, &snapshot)
                                {
                                    tracing::warn!(
                                        code = error.code(),
                                        "Quota notification deferred"
                                    );
                                }
                            }
                        }
                    }
                }
                (
                    e.plan,
                    Some(quota_projection(&e.official_quota, e.observed_at)),
                    None,
                )
            }
            Err(e) => {
                // Display-only, identity-checked history cannot grant admission
                // or change the strict 45-second credential requirement.
                let cached = manager.cached_quota_snapshot(&account.id).ok().flatten();
                let plan = cached
                    .as_ref()
                    .and_then(|q| q.plan.clone())
                    .or(account.plan_type.clone());
                let quota = cached.map(|q| quota_projection(&q.official_quota, q.observed_at));
                (
                    plan,
                    quota,
                    Some(if refresh && !can_refresh {
                        "quota_refresh_budget_exhausted"
                    } else {
                        e.code
                    }),
                )
            }
        };
        rows.push(ProxyAccountDto {
            id: account.id.clone(),
            label: account.label,
            is_last: prefs.is_last(&account.id, plan.as_deref()),
            is_priority: prefs.priority_ids.contains(&account.id),
            is_enabled: prefs.enabled_ids.contains(&account.id),
            plan_type: plan,
            quota,
            availability: if reason.is_none() {
                "available"
            } else {
                "unknown"
            },
            reason_code: reason,
        });
    }
    rows.sort_by_key(|r| {
        prefs
            .order
            .iter()
            .position(|id| id == &r.id)
            .unwrap_or(usize::MAX)
    });
    Ok(rows)
}
async fn read(
    manager: Arc<AccountManager>,
    gate: Arc<codexu_core::managed_proxy::ManagedProxyGate>,
    proxy: Arc<codexu_core::proxy::LocalProxyService>,
    refresh: bool,
    notifications: Option<Arc<NotificationService>>,
) -> Result<Vec<ProxyAccountDto>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let _refresh_guard = if refresh {
            REFRESHING
                .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .map_err(|_| "quota_refresh_busy".to_owned())?;
            Some(RefreshGuard)
        } else {
            None
        };
        let preferences = proxy.preferences().map_err(|e| e.code().to_owned())?;
        project(
            &manager,
            &gate,
            &preferences,
            refresh,
            notifications.as_deref(),
        )
    })
    .await
    .map_err(|_| "account_service_unavailable".to_owned())?
}
#[tauri::command]
pub async fn get_local_proxy_accounts(
    accounts: State<'_, ManagedAccountState>,
    proxy: State<'_, LocalProxyState>,
    native: State<'_, crate::native_services::NativeServices>,
    notifications: State<'_, NotificationState>,
) -> Result<Vec<ProxyAccountDto>, String> {
    read(
        accounts.manager()?,
        native.gate.as_ref().map_err(|e| e.to_string())?.clone(),
        proxy.service()?,
        false,
        notifications.manager().ok(),
    )
    .await
}
#[tauri::command]
pub async fn refresh_local_proxy_accounts(
    accounts: State<'_, ManagedAccountState>,
    proxy: State<'_, LocalProxyState>,
    native: State<'_, crate::native_services::NativeServices>,
    notifications: State<'_, NotificationState>,
) -> Result<Vec<ProxyAccountDto>, String> {
    read(
        accounts.manager()?,
        native.gate.as_ref().map_err(|e| e.to_string())?.clone(),
        proxy.service()?,
        true,
        notifications.manager().ok(),
    )
    .await
}
