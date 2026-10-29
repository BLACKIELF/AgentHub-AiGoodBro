//! Explicit opt-in only. No card, token, raw identity or native path arguments.
use codexu_core::accounts::maintenance::{
    AccountMaintenancePreferences, AccountMaintenanceService, AccountMaintenanceStatus,
};
use std::sync::Arc;
use tauri::{AppHandle, Emitter, State};
pub struct AccountMaintenanceState(pub Result<Arc<AccountMaintenanceService>, &'static str>);
impl AccountMaintenanceState {
    fn service(&self) -> Result<Arc<AccountMaintenanceService>, String> {
        self.0.clone().map_err(str::to_owned)
    }
}
async fn run<T: Send + 'static>(
    state: Arc<AccountMaintenanceService>,
    work: impl FnOnce(Arc<AccountMaintenanceService>) -> codexu_core::accounts::maintenance::Result<T>
        + Send
        + 'static,
) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(move || work(state))
        .await
        .map_err(|_| "maintenance_unsupported".to_owned())?
        .map_err(|e| e.code().to_owned())
}
#[tauri::command]
pub async fn get_account_maintenance_preferences(
    state: State<'_, AccountMaintenanceState>,
) -> Result<AccountMaintenancePreferences, String> {
    run(state.service()?, |s| s.preferences()).await
}
#[tauri::command]
pub async fn set_account_warmup_selection(
    app: AppHandle,
    state: State<'_, AccountMaintenanceState>,
    five_hour: bool,
    seven_day: bool,
) -> Result<AccountMaintenancePreferences, String> {
    let value = run(state.service()?, move |s| {
        s.set_warmup_selection(five_hour, seven_day)
    })
    .await?;
    let _ = app.emit("account-maintenance:changed", ());
    Ok(value)
}
#[tauri::command]
pub async fn set_reset_credit_auto_options(
    app: AppHandle,
    state: State<'_, AccountMaintenanceState>,
    lead_minutes: u16,
) -> Result<AccountMaintenancePreferences, String> {
    let value = run(state.service()?, move |s| s.set_reset_options(lead_minutes)).await?;
    let _ = app.emit("account-maintenance:changed", ());
    Ok(value)
}
#[tauri::command]
pub async fn set_reset_credit_auto_authorization(
    app: AppHandle,
    state: State<'_, AccountMaintenanceState>,
    profile_id: String,
    enabled: bool,
) -> Result<AccountMaintenancePreferences, String> {
    let value = run(state.service()?, move |s| {
        s.authorize_reset(&profile_id, enabled)
    })
    .await?;
    let _ = app.emit("account-maintenance:changed", ());
    Ok(value)
}
#[tauri::command]
pub async fn get_account_maintenance_status(
    state: State<'_, AccountMaintenanceState>,
) -> Result<AccountMaintenanceStatus, String> {
    run(state.service()?, |s| s.status()).await
}
#[tauri::command]
pub async fn cancel_account_maintenance(
    app: AppHandle,
    state: State<'_, AccountMaintenanceState>,
) -> Result<AccountMaintenanceStatus, String> {
    let value = run(state.service()?, |s| s.cancel()).await?;
    let _ = app.emit("account-maintenance:changed", ());
    Ok(value)
}
