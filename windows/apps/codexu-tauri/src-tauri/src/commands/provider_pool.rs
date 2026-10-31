//! Masked provider-pool actions. No OAuth credential or gateway key is returned
//! to the WebView, and reading state never starts a helper or browser.
use codexu_core::provider_pool::{AuthorizationBrowser, PoolSnapshot, Provider, ProviderPool};
use std::sync::Arc;
use tauri::{AppHandle, Emitter, State};

pub struct ProviderPoolState(pub Result<Arc<ProviderPool>, &'static str>);
impl ProviderPoolState {
    fn service(&self) -> Result<Arc<ProviderPool>, String> {
        self.0.as_ref().cloned().map_err(|e| (*e).to_owned())
    }
}
async fn run(
    app: AppHandle,
    service: Arc<ProviderPool>,
    action: impl FnOnce(&Arc<ProviderPool>) -> codexu_core::provider_pool::Result<PoolSnapshot>
        + Send
        + 'static,
) -> Result<PoolSnapshot, String> {
    let result = tauri::async_runtime::spawn_blocking(move || action(&service))
        .await
        .map_err(|_| "provider_pool_unavailable".to_owned())?
        .map_err(|e| e.code.to_owned());
    let _ = app.emit("provider-pool:changed", ());
    result
}
#[tauri::command]
pub async fn get_provider_pool(
    state: State<'_, ProviderPoolState>,
) -> Result<PoolSnapshot, String> {
    let service = state.service()?;
    tauri::async_runtime::spawn_blocking(move || service.snapshot())
        .await
        .map_err(|_| "provider_pool_unavailable".to_owned())?
        .map_err(|e| e.code.to_owned())
}
#[tauri::command]
pub async fn start_provider_pool(
    app: AppHandle,
    state: State<'_, ProviderPoolState>,
    proxy: State<'_, super::local_proxy::LocalProxyState>,
    network_proxy: Option<String>,
) -> Result<PoolSnapshot, String> {
    // None means reuse the existing proxy network preference, not silently
    // bypassing the user's configured egress. No new global setting is written.
    let configured = if network_proxy.is_none() {
        Some(proxy.service()?)
    } else {
        None
    };
    run(app, state.service()?, move |s| {
        let network_proxy = match configured {
            Some(proxy) => Some(
                proxy
                    .preferences()
                    .map_err(|_| codexu_core::provider_pool::Error {
                        code: "provider_pool_network_settings_unavailable",
                    })?
                    .network_proxy,
            ),
            None => network_proxy,
        };
        s.start(network_proxy)
    })
    .await
}
#[tauri::command]
pub async fn stop_provider_pool(
    app: AppHandle,
    state: State<'_, ProviderPoolState>,
    run_id: String,
    confirmed: bool,
) -> Result<PoolSnapshot, String> {
    run(app, state.service()?, move |s| s.stop(&run_id, confirmed)).await
}
#[tauri::command]
pub async fn begin_provider_pool_authorization(
    app: AppHandle,
    state: State<'_, ProviderPoolState>,
    run_id: String,
    provider: Provider,
) -> Result<PoolSnapshot, String> {
    run(app, state.service()?, move |s| {
        s.begin_authorization(&run_id, provider)
    })
    .await
}
#[tauri::command]
pub async fn cancel_provider_pool_authorization(
    app: AppHandle,
    state: State<'_, ProviderPoolState>,
    run_id: String,
    attempt_id: String,
) -> Result<PoolSnapshot, String> {
    run(app, state.service()?, move |s| {
        s.cancel_authorization(&run_id, &attempt_id)
    })
    .await
}
#[tauri::command]
pub async fn set_provider_pool_enabled(
    app: AppHandle,
    state: State<'_, ProviderPoolState>,
    run_id: Option<String>,
    account_id: String,
    generation: String,
    enabled: bool,
) -> Result<PoolSnapshot, String> {
    run(app, state.service()?, move |s| {
        s.set_enabled(run_id.as_deref(), &account_id, &generation, enabled)
    })
    .await
}
#[tauri::command]
pub async fn remove_provider_pool_account(
    app: AppHandle,
    state: State<'_, ProviderPoolState>,
    run_id: Option<String>,
    account_id: String,
    generation: String,
    confirmed: bool,
) -> Result<PoolSnapshot, String> {
    run(app, state.service()?, move |s| {
        s.remove_account(run_id.as_deref(), &account_id, &generation, confirmed)
    })
    .await
}
#[tauri::command]
pub async fn refresh_provider_pool_models(
    app: AppHandle,
    state: State<'_, ProviderPoolState>,
    run_id: String,
) -> Result<PoolSnapshot, String> {
    run(app, state.service()?, move |s| s.refresh_models(&run_id)).await
}
fn connection_text(provider: Provider, endpoint: &str, key: &str) -> String {
    if provider == Provider::Antigravity {
        format!("GOOGLE_GEMINI_BASE_URL={endpoint}\nGEMINI_API_KEY={key}")
    } else {
        format!("OPENAI_BASE_URL={endpoint}/v1\nOPENAI_API_KEY={key}")
    }
}
#[tauri::command]
pub async fn copy_provider_pool_connection(
    app: AppHandle,
    state: State<'_, ProviderPoolState>,
    run_id: String,
    provider: Provider,
) -> Result<(), String> {
    let service = state.service()?;
    let owner =
        super::native_clipboard::owner(&app).map_err(|_| "provider_pool_clipboard_unavailable")?;
    tauri::async_runtime::spawn_blocking(move || {
        service.with_connection(&run_id, provider, None, |connection| {
            super::native_clipboard::write(
                &connection_text(provider, &connection.endpoint, connection.client_key),
                owner,
            )
            .map_err(|_| codexu_core::provider_pool::Error {
                code: "provider_pool_clipboard_unavailable",
            })
        })
    })
    .await
    .map_err(|_| "provider_pool_unavailable".to_owned())?
    .map_err(|e| e.code.to_owned())
}

pub struct NativeAuthorizationBrowser;
impl AuthorizationBrowser for NativeAuthorizationBrowser {
    fn open(&self, url: &str) -> codexu_core::provider_pool::Result<()> {
        // The host performs the provider-specific URL/session validation before
        // invoking this native-only trait. No WebView command accepts a URL.
        if !url.starts_with("https://") || url.len() > 16384 || url.chars().any(char::is_control) {
            return Err(codexu_core::provider_pool::Error {
                code: "provider_pool_authorization_url_invalid",
            });
        }
        open_authorization_url(url)
    }
}
#[cfg(windows)]
fn open_authorization_url(url: &str) -> codexu_core::provider_pool::Result<()> {
    #[link(name = "shell32")]
    unsafe extern "system" {
        fn ShellExecuteW(
            window: *mut std::ffi::c_void,
            verb: *const u16,
            file: *const u16,
            arguments: *const u16,
            directory: *const u16,
            show: i32,
        ) -> isize;
    }
    let verb: Vec<u16> = "open\0".encode_utf16().collect();
    let target: Vec<u16> = url.encode_utf16().chain(Some(0)).collect();
    let result = unsafe {
        ShellExecuteW(
            std::ptr::null_mut(),
            verb.as_ptr(),
            target.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            1,
        )
    };
    if result <= 32 {
        return Err(codexu_core::provider_pool::Error {
            code: "provider_pool_browser_unavailable",
        });
    }
    Ok(())
}
#[cfg(not(windows))]
fn open_authorization_url(_: &str) -> codexu_core::provider_pool::Result<()> {
    Err(codexu_core::provider_pool::Error {
        code: "provider_pool_browser_unavailable",
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn clipboard_payload_follows_fixed_mac_provider_contract_without_serialized_key() {
        assert_eq!(connection_text(Provider::Antigravity, "http://127.0.0.1:18081/providers/antigravity", "synthetic"), "GOOGLE_GEMINI_BASE_URL=http://127.0.0.1:18081/providers/antigravity\nGEMINI_API_KEY=synthetic");
        for provider in [Provider::Claude, Provider::Kimi, Provider::Xai] {
            let endpoint = format!("http://127.0.0.1:18081/providers/{}", provider.id());
            assert_eq!(
                connection_text(provider, &endpoint, "synthetic"),
                format!("OPENAI_BASE_URL={endpoint}/v1\nOPENAI_API_KEY=synthetic")
            );
        }
    }
    #[test]
    fn browser_rejects_unchecked_transport_and_control_characters_without_opening() {
        for value in [
            "file:///tmp/test",
            "http://127.0.0.1",
            "https://example.invalid/\n",
        ] {
            assert_eq!(
                NativeAuthorizationBrowser.open(value).unwrap_err().code,
                "provider_pool_authorization_url_invalid"
            );
        }
    }
}
