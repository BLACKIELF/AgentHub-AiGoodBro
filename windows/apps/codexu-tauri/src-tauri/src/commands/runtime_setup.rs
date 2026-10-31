//! Explicit local runtime checks. Neither endpoint logs in, installs or starts Hub.
use crate::app_state::AppState;
use codexu_core::runtime_setup::{automatic_candidates, NativeProbe, RuntimeView, SelectionStore};
use std::{path::PathBuf, sync::Arc};
use tauri::{AppHandle, Manager, State};
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeSetupView {
    codex: RuntimeView,
    hub_verified: bool,
}
fn hub_verified(path: PathBuf) -> bool {
    let Ok(mut image) = super::cli_workflow::console::lock_executable(&path) else {
        return false;
    };
    codexu_core::accounts::hub_snapshot::verify_helper(
        &mut image,
        option_env!("AIGOODBRO_HUB_BINARY_SHA256"),
    )
    .is_ok()
}
#[tauri::command]
pub async fn inspect_runtime_setup(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
) -> Result<RuntimeSetupView, String> {
    let store = SelectionStore::new(&state.app_data_dir).map_err(|e| e.code.to_owned())?;
    let helper = app
        .path()
        .resource_dir()
        .map_err(|_| "runtime_resources_unavailable")?
        .join("companion-hub/aigoodbro-hub.exe");
    tauri::async_runtime::spawn_blocking(move || RuntimeSetupView {
        codex: store.inspect(&automatic_candidates(), &NativeProbe),
        hub_verified: hub_verified(helper),
    })
    .await
    .map_err(|_| "runtime_probe_failed".to_owned())
}
#[tauri::command]
pub async fn select_runtime_codex(
    state: State<'_, Arc<AppState>>,
    path: PathBuf,
) -> Result<RuntimeView, String> {
    let store = SelectionStore::new(&state.app_data_dir).map_err(|e| e.code.to_owned())?;
    tauri::async_runtime::spawn_blocking(move || store.choose(&path, &NativeProbe))
        .await
        .map_err(|_| "runtime_probe_failed".to_owned())?
        .map_err(|e| e.code.to_owned())
}
#[tauri::command]
pub async fn open_codex_installation_guide() -> Result<(), String> {
    // Fixed official destination only; caller cannot supply URL, shell args or
    // an installer. This opens documentation, never executes installation.
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        #[link(name = "shell32")]
        unsafe extern "system" {
            fn ShellExecuteW(
                window: *mut std::ffi::c_void,
                verb: *const u16,
                file: *const u16,
                args: *const u16,
                dir: *const u16,
                show: i32,
            ) -> isize;
        }
        let wide = |s: &str| {
            std::ffi::OsStr::new(s)
                .encode_wide()
                .chain(Some(0))
                .collect::<Vec<_>>()
        };
        let verb = wide("open");
        let url = wide("https://github.com/openai/codex#installing-and-running-codex-cli");
        let result = unsafe {
            ShellExecuteW(
                std::ptr::null_mut(),
                verb.as_ptr(),
                url.as_ptr(),
                std::ptr::null(),
                std::ptr::null(),
                1,
            )
        };
        if result <= 32 {
            return Err("runtime_guide_unavailable".into());
        }
        Ok(())
    }
    #[cfg(not(windows))]
    {
        Err("windows_required".into())
    }
}
