//! Explicit native-only source discovery. No paths or credentials enter WebView.
use super::account_lifecycle::ClaudeSubscriptionState;
use codexu_core::accounts::claude::{ClaudeSubscriptionDto, ClaudeSwapCandidate};
use tauri::{AppHandle, Emitter, State};

#[tauri::command]
pub async fn scan_claude_swap_candidates(
    state: State<'_, ClaudeSubscriptionState>,
) -> Result<Vec<ClaudeSwapCandidate>, String> {
    let manager = state.manager()?;
    tauri::async_runtime::spawn_blocking(move || manager.scan_claude_swap_candidates())
        .await
        .map_err(|_| "account_service_unavailable".to_owned())?
        .map_err(|e| e.code.to_owned())
}

#[tauri::command]
pub async fn import_claude_swap_candidate(
    app: AppHandle,
    state: State<'_, ClaudeSubscriptionState>,
    candidate_id: String,
) -> Result<ClaudeSubscriptionDto, String> {
    let manager = state.manager()?;
    let result = tauri::async_runtime::spawn_blocking(move || {
        manager.import_claude_swap_candidate(&candidate_id)
    })
    .await
    .map_err(|_| "account_service_unavailable".to_owned())?
    .map_err(|e| e.code.to_owned())?;
    let _ = app.emit("claude-subscriptions:changed", ());
    Ok(result)
}
