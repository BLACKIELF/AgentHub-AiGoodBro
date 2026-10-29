//! No IPC command accepts task evidence, auth, a path or an idle override.
use codexu_core::automatic_switch::{
    AutomaticSwitchPreferences, AutomaticSwitchService, AutomaticSwitchStatus,
};
use std::sync::Arc;
use tauri::{AppHandle, Emitter, State};

pub struct AutomaticSwitchState(pub Result<Arc<AutomaticSwitchService>, &'static str>);
impl AutomaticSwitchState {
    pub fn service(&self) -> Result<Arc<AutomaticSwitchService>, String> {
        self.0.clone().map_err(str::to_owned)
    }
}
async fn blocking<T: Send + 'static>(
    service: Arc<AutomaticSwitchService>,
    action: impl FnOnce(Arc<AutomaticSwitchService>) -> codexu_core::automatic_switch::Result<T>
        + Send
        + 'static,
) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(move || action(service))
        .await
        .map_err(|_| "automatic_switch_unavailable".to_owned())?
        .map_err(|error| error.code().to_owned())
}
#[tauri::command]
pub async fn get_automatic_switch_preferences(
    state: State<'_, AutomaticSwitchState>,
) -> Result<AutomaticSwitchPreferences, String> {
    blocking(state.service()?, |service| service.preferences()).await
}
#[tauri::command]
pub async fn set_automatic_switch_preferences(
    app: AppHandle,
    state: State<'_, AutomaticSwitchState>,
    preferences: AutomaticSwitchPreferences,
) -> Result<AutomaticSwitchPreferences, String> {
    let value = blocking(state.service()?, move |service| {
        service.save_preferences(preferences)
    })
    .await?;
    let _ = app.emit("automatic-switch:changed", ());
    Ok(value)
}
#[tauri::command]
pub async fn get_automatic_switch_status(
    state: State<'_, AutomaticSwitchState>,
) -> Result<AutomaticSwitchStatus, String> {
    blocking(state.service()?, |service| service.status()).await
}
#[tauri::command]
pub async fn evaluate_automatic_switch(
    app: AppHandle,
    state: State<'_, AutomaticSwitchState>,
) -> Result<AutomaticSwitchStatus, String> {
    let result = blocking(state.service()?, |service| service.evaluate_once()).await;
    let _ = app.emit("automatic-switch:changed", ());
    result
}
#[tauri::command]
pub async fn cancel_automatic_switch(
    app: AppHandle,
    state: State<'_, AutomaticSwitchState>,
) -> Result<AutomaticSwitchStatus, String> {
    let result = blocking(state.service()?, |service| service.cancel()).await;
    let _ = app.emit("automatic-switch:changed", ());
    result
}
