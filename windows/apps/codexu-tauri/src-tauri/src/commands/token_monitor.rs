//! WebView can select opaque source IDs, never supply scan paths or credentials.
use crate::{app_state::AppState, native_services::NativeServices};
use codexu_core::token_monitor::{TokenMonitorService, TokenMonitorState};
use std::sync::Arc;
use tauri::State;

pub struct TokenMonitorAppState(pub Result<Arc<TokenMonitorService>, &'static str>);
impl TokenMonitorAppState {
    fn service(&self) -> Result<Arc<TokenMonitorService>, String> {
        self.0.as_ref().cloned().map_err(|code| (*code).to_owned())
    }
}
#[tauri::command]
pub async fn get_token_monitor_state(
    state: State<'_, TokenMonitorAppState>,
) -> Result<TokenMonitorState, String> {
    state.service()?.state().map_err(|e| e.code().to_owned())
}
#[tauri::command]
pub async fn refresh_token_monitor_usage(
    state: State<'_, TokenMonitorAppState>,
    app_state: State<'_, Arc<AppState>>,
    native: State<'_, NativeServices>,
) -> Result<TokenMonitorState, String> {
    let service = state.service()?;
    let config = app_state.config.read().await.clone();
    let accounts = native.statistics_accounts()?;
    tauri::async_runtime::spawn_blocking(move || {
        let sources = crate::statistics_sources::collect(&config, &accounts)?;
        service
            .replace_sources(sources)
            .map_err(|e| e.code().to_owned())?;
        service.refresh().map_err(|e| e.code().to_owned())
    })
    .await
    .map_err(|_| "statistics_unavailable".to_owned())?
}
#[tauri::command]
pub async fn set_token_monitor_sources(
    state: State<'_, TokenMonitorAppState>,
    app_state: State<'_, Arc<AppState>>,
    native: State<'_, NativeServices>,
    source_ids: Vec<String>,
) -> Result<TokenMonitorState, String> {
    let service = state.service()?;
    let config = app_state.config.read().await.clone();
    let accounts = native.statistics_accounts()?;
    tauri::async_runtime::spawn_blocking(move || {
        let sources = crate::statistics_sources::collect(&config, &accounts)?;
        service
            .replace_sources(sources)
            .map_err(|e| e.code().to_owned())?;
        service
            .select_sources(source_ids)
            .map_err(|e| e.code().to_owned())
    })
    .await
    .map_err(|_| "statistics_unavailable".to_owned())?
}
#[tauri::command]
pub async fn cancel_token_monitor_usage(
    state: State<'_, TokenMonitorAppState>,
) -> Result<TokenMonitorState, String> {
    let service = state.service()?;
    tauri::async_runtime::spawn_blocking(move || service.cancel().map_err(|e| e.code().to_owned()))
        .await
        .map_err(|_| "statistics_unavailable".to_owned())?
}
#[tauri::command]
pub async fn set_token_monitor_timezone(
    state: State<'_, TokenMonitorAppState>,
    timezone: String,
) -> Result<TokenMonitorState, String> {
    let service = state.service()?;
    tauri::async_runtime::spawn_blocking(move || {
        service
            .set_timezone(timezone)
            .map_err(|e| e.code().to_owned())
    })
    .await
    .map_err(|_| "statistics_unavailable".to_owned())?
}
