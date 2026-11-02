use codexu_core::proxy::{
    LocalProxyService, ProxyConnection, ProxyDesktopConnector, ProxyDesktopStatus,
    ProxyPreferences, ProxyStatus,
};
use std::sync::Arc;
use tauri::{AppHandle, Emitter};

pub struct LocalProxyState(pub Result<Arc<LocalProxyService>, &'static str>);
impl LocalProxyState {
    pub fn service(&self) -> Result<Arc<LocalProxyService>, String> {
        self.0.as_ref().cloned().map_err(|code| (*code).to_owned())
    }
}
pub struct LocalProxyDesktopState(pub Result<Arc<ProxyDesktopConnector>, &'static str>);
impl LocalProxyDesktopState {
    pub fn connector(&self) -> Result<Arc<ProxyDesktopConnector>, String> {
        self.0.as_ref().cloned().map_err(|e| (*e).to_owned())
    }
}

// The root registers the real account gate/vault-backed service. These commands
// never instantiate a fixture gate or expose the private helper control key.
#[tauri::command]
pub async fn get_local_proxy_status(
    service: tauri::State<'_, LocalProxyState>,
) -> Result<ProxyStatus, String> {
    let service = service.service()?;
    tauri::async_runtime::spawn_blocking(move || service.status().map_err(|e| e.code().into()))
        .await
        .map_err(|_| "unavailable".to_string())?
}
#[tauri::command]
pub async fn get_local_proxy_preferences(
    service: tauri::State<'_, LocalProxyState>,
) -> Result<ProxyPreferences, String> {
    let service = service.service()?;
    tauri::async_runtime::spawn_blocking(move || service.preferences().map_err(|e| e.code().into()))
        .await
        .map_err(|_| "unavailable".to_string())?
}
#[tauri::command]
pub async fn set_local_proxy_preferences(
    app: AppHandle,
    service: tauri::State<'_, LocalProxyState>,
    preferences: ProxyPreferences,
) -> Result<ProxyPreferences, String> {
    let service = service.service()?;
    let saved = tauri::async_runtime::spawn_blocking(move || {
        service
            .save_preferences_preserving_routing(preferences)
            .map_err(|error| error.code().to_owned())
    })
    .await
    .map_err(|_| "unavailable".to_string())??;
    emit_preferences_changed(&app);
    Ok(saved)
}
#[tauri::command]
pub async fn set_local_proxy_account_preference(
    app: AppHandle,
    service: tauri::State<'_, LocalProxyState>,
    account_id: String,
    field: String,
    enabled: bool,
) -> Result<ProxyPreferences, String> {
    let service = service.service()?;
    let saved = tauri::async_runtime::spawn_blocking(move || {
        service
            .update_account_preference(&account_id, &field, enabled)
            .map_err(|error| error.code().to_owned())
    })
    .await
    .map_err(|_| "unavailable".to_string())??;
    emit_preferences_changed(&app);
    Ok(saved)
}
#[tauri::command]
pub async fn move_local_proxy_account(
    app: AppHandle,
    service: tauri::State<'_, LocalProxyState>,
    account_id: String,
    target_id: String,
) -> Result<ProxyPreferences, String> {
    let service = service.service()?;
    let saved = tauri::async_runtime::spawn_blocking(move || {
        service
            .move_account_routing(&account_id, &target_id)
            .map_err(|error| error.code().to_owned())
    })
    .await
    .map_err(|_| "unavailable".to_string())??;
    emit_preferences_changed(&app);
    Ok(saved)
}
fn emit_preferences_changed(app: &AppHandle) {
    let _ = app.emit("local-proxy:changed", ());
    let _ = app.emit("managed-accounts:changed", ());
}
#[tauri::command]
pub async fn start_local_proxy(
    service: tauri::State<'_, LocalProxyState>,
) -> Result<ProxyStatus, String> {
    let service = service.service()?;
    tauri::async_runtime::spawn_blocking(move || service.start().map_err(|e| e.code().into()))
        .await
        .map_err(|_| "unavailable".to_string())?
}
#[tauri::command]
pub async fn stop_local_proxy(
    service: tauri::State<'_, LocalProxyState>,
) -> Result<ProxyStatus, String> {
    let service = service.service()?;
    tauri::async_runtime::spawn_blocking(move || service.stop().map_err(|e| e.code().into()))
        .await
        .map_err(|_| "unavailable".to_string())?
}
#[tauri::command]
pub async fn get_local_proxy_connection(
    service: tauri::State<'_, LocalProxyState>,
) -> Result<ProxyConnection, String> {
    let service = service.service()?;
    tauri::async_runtime::spawn_blocking(move || service.connection().map_err(|e| e.code().into()))
        .await
        .map_err(|_| "unavailable".to_string())?
}
#[tauri::command]
pub async fn local_proxy_network_command(
    service: tauri::State<'_, LocalProxyState>,
    command: String,
    request_id: String,
) -> Result<(), String> {
    let service = service.service()?;
    tauri::async_runtime::spawn_blocking(move || {
        service
            .network_command(&command, &request_id)
            .map_err(|e| e.code().into())
    })
    .await
    .map_err(|_| "unavailable".to_string())?
}
#[tauri::command]
pub async fn set_local_proxy_plus_five_hour_used_limit(
    service: tauri::State<'_, LocalProxyState>,
    limit: f64,
) -> Result<ProxyPreferences, String> {
    let service = service.service()?;
    tauri::async_runtime::spawn_blocking(move || {
        service
            .set_plus_five_hour_used_limit(limit)
            .map_err(|e| e.code().into())
    })
    .await
    .map_err(|_| "unavailable".to_string())?
}

#[tauri::command]
pub async fn set_local_proxy_shared_quota_used_limit(
    service: tauri::State<'_, LocalProxyState>,
    limit: f64,
) -> Result<ProxyPreferences, String> {
    let service = service.service()?;
    tauri::async_runtime::spawn_blocking(move || {
        service
            .set_shared_quota_used_limit(limit)
            .map_err(|e| e.code().into())
    })
    .await
    .map_err(|_| "unavailable".to_string())?
}

#[tauri::command]
pub async fn prepare_local_proxy_desktop(
    desktop: tauri::State<'_, LocalProxyDesktopState>,
    account_id: String,
) -> Result<ProxyDesktopStatus, String> {
    let desktop = desktop.connector()?;
    tauri::async_runtime::spawn_blocking(move || {
        desktop.prepare(&account_id).map_err(|e| e.code().into())
    })
    .await
    .map_err(|_| "desktop_unavailable".to_owned())?
}
#[tauri::command]
pub async fn launch_local_proxy_desktop(
    desktop: tauri::State<'_, LocalProxyDesktopState>,
    ticket: String,
) -> Result<ProxyDesktopStatus, String> {
    let desktop = desktop.connector()?;
    tauri::async_runtime::spawn_blocking(move || {
        desktop.launch(&ticket).map_err(|e| e.code().into())
    })
    .await
    .map_err(|_| "desktop_unavailable".to_owned())?
}
#[tauri::command]
pub async fn connect_local_proxy_desktop(
    desktop: tauri::State<'_, LocalProxyDesktopState>,
    account_id: String,
) -> Result<ProxyDesktopStatus, String> {
    let desktop = desktop.connector()?;
    tauri::async_runtime::spawn_blocking(move || {
        desktop.connect(&account_id).map_err(|e| e.code().into())
    })
    .await
    .map_err(|_| "desktop_unavailable".to_owned())?
}
#[tauri::command]
pub async fn get_local_proxy_desktop_status(
    desktop: tauri::State<'_, LocalProxyDesktopState>,
) -> Result<ProxyDesktopStatus, String> {
    let desktop = desktop.connector()?;
    tauri::async_runtime::spawn_blocking(move || desktop.status().map_err(|e| e.code().into()))
        .await
        .map_err(|_| "desktop_unavailable".to_owned())?
}
#[tauri::command]
pub async fn cancel_local_proxy_desktop(
    desktop: tauri::State<'_, LocalProxyDesktopState>,
) -> Result<ProxyDesktopStatus, String> {
    let desktop = desktop.connector()?;
    tauri::async_runtime::spawn_blocking(move || desktop.cancel().map_err(|e| e.code().into()))
        .await
        .map_err(|_| "desktop_unavailable".to_owned())?
}
