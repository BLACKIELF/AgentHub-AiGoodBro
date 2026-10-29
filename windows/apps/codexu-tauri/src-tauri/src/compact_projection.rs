//! Compact surfaces reuse existing native receipts. They never refresh a quota,
//! start a model request, reread transcripts or infer task activity from history.
use crate::{
    app_state::AppState,
    commands::{
        account_lifecycle::{ClaudeSubscriptionState, ManagedAccountState},
        local_proxy::LocalProxyState,
    },
    compact_ui::cache::{Account, CachedProjection, Proxy, QuotaWindow},
    native_services::NativeServices,
    quota_display::{current, Reading},
};
use codexu_core::{
    accounts::{CachedQuotaSnapshot, ManagedAccountDto},
    readers::{CodexAppServerQuotaSnapshot, LocalCliQuotaResult, LocalCliQuotaState},
};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use tauri::{AppHandle, Listener, Manager};

#[derive(Default)]
struct ProjectionObserver {
    dirty: AtomicBool,
    running: AtomicBool,
    exiting: AtomicBool,
    listeners: Mutex<Vec<tauri::EventId>>,
}
impl ProjectionObserver {
    fn request(self: &Arc<Self>, app: AppHandle) {
        if self.exiting.load(Ordering::Acquire) {
            return;
        }
        self.dirty.store(true, Ordering::Release);
        if self.running.swap(true, Ordering::AcqRel) {
            return;
        }
        let owner = self.clone();
        tauri::async_runtime::spawn(async move {
            loop {
                if owner.exiting.load(Ordering::Acquire) {
                    break;
                }
                owner.dirty.store(false, Ordering::Release);
                if refresh(&app).await.is_err() && !owner.exiting.load(Ordering::Acquire) {
                    // A failed source read cannot leave the previous current
                    // account/connection claim on screen. Statistics retain
                    // their independently dated existing Engine snapshot.
                    let _ = crate::compact_ui::replace_cached_projection(
                        &app,
                        CachedProjection::default(),
                    );
                }
                if owner.dirty.swap(false, Ordering::AcqRel) {
                    continue;
                }
                owner.running.store(false, Ordering::Release);
                // Close the event-arrived-during-release race without a timer
                // or unbounded queue of duplicate composition tasks.
                if owner.dirty.load(Ordering::Acquire)
                    && owner
                        .running
                        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                        .is_ok()
                {
                    continue;
                }
                return;
            }
            owner.running.store(false, Ordering::Release);
        });
    }
}
pub fn install(app: &AppHandle) {
    if app.try_state::<Arc<ProjectionObserver>>().is_some() {
        return;
    }
    let observer = Arc::new(ProjectionObserver::default());
    app.manage(observer.clone());
    for name in [
        "profiles:changed",
        "managed-accounts:changed",
        "claude-subscriptions:changed",
        "quota-display:changed",
        "local-proxy:changed",
    ] {
        let current = observer.clone();
        let handle = app.clone();
        let id = app.listen(name, move |_| current.request(handle.clone()));
        if let Ok(mut ids) = observer.listeners.lock() {
            ids.push(id);
        }
    }
    observer.request(app.clone());
}
pub fn shutdown(app: &AppHandle) {
    let Some(observer) = app.try_state::<Arc<ProjectionObserver>>() else {
        return;
    };
    observer.exiting.store(true, Ordering::Release);
    if let Ok(mut ids) = observer.listeners.lock() {
        for id in ids.drain(..) {
            app.unlisten(id);
        }
    };
}

pub async fn refresh(app: &AppHandle) -> Result<(), String> {
    if app
        .try_state::<Arc<ProjectionObserver>>()
        .is_some_and(|s| s.exiting.load(Ordering::Acquire))
    {
        return Err("compact_unavailable".into());
    }
    let state = app
        .try_state::<Arc<AppState>>()
        .ok_or("compact_unavailable")?
        .inner()
        .clone();
    // Serialize complete publications; a change arriving during composition
    // must get a new snapshot after this one, not lose its only change signal.
    let _guard = state.compact_refresh_lock.lock().await;
    let profiles = state.config.read().await.profiles.entries.clone();
    let linked = state
        .quota_display
        .lock()
        .map_err(|_| "compact_unavailable")?
        .project(&profiles, chrono::Utc::now().timestamp_millis());
    let accounts = app
        .try_state::<ManagedAccountState>()
        .and_then(|s| s.manager().ok());
    let claude = app
        .try_state::<ClaudeSubscriptionState>()
        .and_then(|s| s.manager().ok());
    let gate = app
        .try_state::<NativeServices>()
        .and_then(|s| s.gate.as_ref().ok().cloned());
    let proxy = app
        .try_state::<LocalProxyState>()
        .and_then(|s| s.service().ok());
    let value =
        tauri::async_runtime::spawn_blocking(move || -> Result<CachedProjection, String> {
            let now = chrono::Utc::now().timestamp_millis();
            let mut rows = Vec::new();
            if let Some(manager) = accounts {
                for account in manager
                    .list_managed_accounts()
                    .map_err(|e| e.code.to_owned())?
                {
                    let mut row = account_base(&account, "managed", "codex");
                    let result = gate
                        .as_ref()
                        .ok_or("quota_unavailable")
                        .and_then(|g| g.quota_snapshot(&account.id, false).map_err(|e| e.code()));
                    let (snapshot, reason) = match result {
                        Ok(snapshot) => (Some(snapshot), None),
                        Err(code) => (
                            manager.cached_quota_snapshot(&account.id).ok().flatten(),
                            Some(code.to_owned()),
                        ),
                    };
                    if let Some(snapshot) = snapshot {
                        apply_reading(&mut row, codex_reading(snapshot), reason, now);
                    } else {
                        row.reason_code = reason.or_else(|| Some("quota_not_read".into()));
                    }
                    rows.push(row);
                }
            }
            if let Some(manager) = claude {
                for account in manager
                    .list_claude_subscriptions()
                    .map_err(|e| e.code.to_owned())?
                {
                    let mut row = account_base(&account, "claude", "claude_code");
                    if let Some(snapshot) = manager
                        .cached_claude_subscription_quota(&account.id)
                        .map_err(|e| e.code.to_owned())?
                        .filter(|s| {
                            s.account_id == account.id && s.record_revision == account.revision
                        })
                    {
                        let latest = snapshot.last_attempt.as_ref().map(|v| &v.quota);
                        let reason = latest.and_then(|q| quota_reason(q.state));
                        let reading = latest
                            .filter(|q| q.state == LocalCliQuotaState::Available)
                            .or_else(|| snapshot.last_success.as_ref().map(|v| &v.quota))
                            .or(latest);
                        if let Some(reading) = reading {
                            apply_reading(
                                &mut row,
                                local_reading(reading),
                                reason.map(str::to_owned),
                                now,
                            );
                        }
                    }
                    rows.push(row);
                }
            }
            rows.extend(linked);
            let proxy = proxy
                .map(|service| {
                    let status = service.cached_status().map_err(|e| e.code().to_owned())?;
                    let phase = match status.phase {
                        codexu_core::proxy::ProxyPhase::Stopped => "stopped",
                        codexu_core::proxy::ProxyPhase::Starting => "starting",
                        codexu_core::proxy::ProxyPhase::Running => "running",
                        codexu_core::proxy::ProxyPhase::Stopping => "stopping",
                        codexu_core::proxy::ProxyPhase::Failed => "failed",
                    };
                    Ok::<_, String>(Proxy {
                        phase: phase.into(),
                        egress_state: status.egress.map(|e| e.state),
                        active_requests: None,
                        observed_at: status
                            .last_event_at
                            .filter(|v| v.is_finite() && *v >= 0.)
                            .map(|v| (v * 1000.) as i64),
                    })
                })
                .transpose()?;
            Ok(CachedProjection {
                accounts: rows,
                proxy,
                session_count: None,
            })
        })
        .await
        .map_err(|_| "compact_unavailable".to_owned())??;
    let config = state.config.read().await;
    if config.profiles.entries != profiles {
        return Err("compact_source_changed".into());
    }
    drop(config);
    if app
        .try_state::<Arc<ProjectionObserver>>()
        .is_some_and(|s| s.exiting.load(Ordering::Acquire))
    {
        return Err("compact_unavailable".into());
    }
    crate::compact_ui::replace_cached_projection(app, value)
}

fn account_base(value: &ManagedAccountDto, namespace: &str, provider: &str) -> Account {
    Account {
        id: format!("{namespace}-{}", value.id),
        provider_id: provider.into(),
        label: value.label.clone(),
        logged_in: value.login_state == "verified",
        active: (value.active_state == "verified").then_some(true),
        observed_at: None,
        available: false,
        reason_code: Some("quota_not_read".into()),
        plan_type: value.plan_type.clone(),
        windows: Vec::new(),
        credits_usd: None,
        credit_points: None,
        reset_cards: None,
    }
}
fn apply_reading(row: &mut Account, reading: Reading, reason: Option<String>, now: i64) {
    row.available = reason.is_none() && reading.reason.is_none() && current(&reading, now);
    row.reason_code = reason
        .or(reading.reason)
        .or_else(|| (!row.available).then(|| "quota_stale".into()));
    row.observed_at = Some(reading.observed_at);
    if reading.plan.is_some() {
        row.plan_type = reading.plan;
    }
    row.windows = reading.windows;
    row.credits_usd = reading.usd;
    row.credit_points = reading.points;
    row.reset_cards = reading.reset_cards;
}
fn codex_reading(snapshot: CachedQuotaSnapshot) -> Reading {
    let q = CodexAppServerQuotaSnapshot::from_rate_limit_response(&snapshot.official_quota);
    let windows = [
        ("five_hour", "5h", q.five_hour_quota),
        ("seven_day", "7d", q.seven_day_quota),
        ("monthly", "Monthly", q.monthly_quota),
    ]
    .into_iter()
    .filter_map(|(id, label, window)| {
        window.map(|w| QuotaWindow {
            id: id.into(),
            label: label.into(),
            used_percent: Some(w.used_percent),
            resets_at: w.resets_at.map(|at| at.timestamp_millis()),
        })
    })
    .collect();
    Reading {
        observed_at: snapshot.observed_at.saturating_mul(1000),
        available: q.quota_read_succeeded,
        reason: None,
        plan: snapshot.plan,
        windows,
        usd: q.credit_balance_usd,
        points: q.credit_balance_points.map(|v| v.to_string()),
        reset_cards: q.reset_credit_count,
    }
}
fn quota_reason(state: LocalCliQuotaState) -> Option<&'static str> {
    match state {
        LocalCliQuotaState::Available => None,
        LocalCliQuotaState::Unavailable => Some("quota_unavailable"),
        LocalCliQuotaState::NeedsLogin => Some("needs_login"),
        LocalCliQuotaState::Unsupported => Some("quota_unsupported"),
        LocalCliQuotaState::RateLimited => Some("rate_limited"),
    }
}
fn local_reading(q: &LocalCliQuotaResult) -> Reading {
    Reading {
        observed_at: q.fetched_at.timestamp_millis(),
        available: q.state == LocalCliQuotaState::Available,
        reason: quota_reason(q.state).map(str::to_owned),
        plan: q.plan_label.clone(),
        windows: q
            .windows
            .iter()
            .map(|w| QuotaWindow {
                id: w.id.clone(),
                label: w.label.clone(),
                used_percent: Some(w.used_percent),
                resets_at: w.resets_at.map(|at| at.timestamp_millis()),
            })
            .collect(),
        usd: q.balance.filter(|_| {
            q.balance_currency
                .as_deref()
                .is_some_and(|c| c.eq_ignore_ascii_case("USD"))
        }),
        points: None,
        reset_cards: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn absent_official_windows_remain_absent_and_history_is_not_freshened() {
        let source = CachedQuotaSnapshot {
            plan: Some("pro".into()),
            observed_at: 123,
            official_quota: serde_json::json!({"rateLimits":{"primary":null,"secondary":null}}),
        };
        let reading = codex_reading(source);
        assert!(reading.windows.is_empty());
        assert_eq!(reading.observed_at, 123000);
        assert!(!current(&reading, 423000));
    }
}
