use crate::compact_ui::{
    model::{CompactUiState, Surface},
    CompactAppState,
};
use tauri::{AppHandle, State, WebviewWindow};
#[tauri::command]
pub async fn get_compact_ui_state(
    app: AppHandle,
    state: State<'_, CompactAppState>,
) -> Result<CompactUiState, String> {
    crate::compact_projection::refresh(&app).await?;
    let service = state.0.clone();
    tauri::async_runtime::spawn_blocking(move || {
        service.reconcile()?;
        service.state()
    })
    .await
    .map_err(|_| "compact_unavailable".to_owned())?
}
#[tauri::command]
pub async fn set_compact_ui_preferences(
    state: State<'_, CompactAppState>,
    patch: serde_json::Value,
) -> Result<CompactUiState, String> {
    let service = state.0.clone();
    tauri::async_runtime::spawn_blocking(move || service.save(patch))
        .await
        .map_err(|_| "compact_unavailable".to_owned())?
}
#[tauri::command]
pub async fn retry_compact_ui_shortcut(
    state: State<'_, CompactAppState>,
) -> Result<CompactUiState, String> {
    let service = state.0.clone();
    tauri::async_runtime::spawn_blocking(move || service.retry_shortcut())
        .await
        .map_err(|_| "compact_shortcut_unavailable".to_owned())?
}
#[tauri::command]
pub async fn compact_ui_action(
    _app: AppHandle,
    window: WebviewWindow,
    state: State<'_, CompactAppState>,
    action: String,
    item_id: Option<String>,
) -> Result<CompactUiState, String> {
    let surface = Surface::from_label(window.label()).ok_or("compact_action_unavailable")?;
    let service = state.0.clone();
    tauri::async_runtime::spawn_blocking(move || {
        service.action(surface, &action, item_id.as_deref())
    })
    .await
    .map_err(|_| "compact_unavailable".to_owned())?
}
