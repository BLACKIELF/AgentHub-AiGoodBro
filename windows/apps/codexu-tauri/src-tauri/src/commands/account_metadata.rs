//! Explicit display-order changes only; never proxy/dispatch scheduling policy.
use super::account_lifecycle::ManagedAccountState;
use tauri::{AppHandle, Emitter, State};
#[tauri::command]
pub async fn reorder_managed_accounts(
    app: AppHandle,
    state: State<'_, ManagedAccountState>,
    ordered_ids: Vec<String>,
    expected_order: Vec<String>,
) -> Result<Vec<String>, String> {
    let manager = state.manager()?;
    let result = tauri::async_runtime::spawn_blocking(move || {
        manager.reorder_managed_accounts(&ordered_ids, &expected_order)
    })
    .await
    .map_err(|_| "account_service_unavailable".to_owned())?
    .map_err(|e| e.code.to_owned())?;
    let _ = app.emit("managed-accounts:changed", ());
    let _ = app.emit("profiles:changed", ());
    Ok(result)
}
