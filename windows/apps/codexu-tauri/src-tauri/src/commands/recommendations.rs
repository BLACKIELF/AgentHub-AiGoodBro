//! Fixed bundled recommendation actions. No installer or arbitrary shell target.
use crate::app_state::AppState;
use codexu_core::recommendations::{RecommendationStore, Snapshot};
use std::sync::Arc;
use tauri::{AppHandle, Emitter, Manager, State};
fn store(app: &AppHandle, state: &AppState) -> Result<RecommendationStore, String> {
    let resources = app
        .path()
        .resource_dir()
        .map_err(|_| "recommendation_package_unavailable")?
        .join("skill-library");
    let home = app
        .path()
        .home_dir()
        .map_err(|_| "recommendation_home_unavailable")?;
    RecommendationStore::new(&state.app_data_dir, &resources, &home).map_err(|e| e.code.to_owned())
}
async fn run(
    app: AppHandle,
    state: Arc<AppState>,
    changed: bool,
    action: impl FnOnce(RecommendationStore) -> codexu_core::recommendations::Result<Snapshot>
        + Send
        + 'static,
) -> Result<Snapshot, String> {
    let service = store(&app, &state)?;
    let result = tauri::async_runtime::spawn_blocking(move || action(service))
        .await
        .map_err(|_| "recommendation_unavailable")?
        .map_err(|e| e.code.to_owned());
    if changed {
        let _ = app.emit("recommendations:changed", ());
    }
    result
}
#[tauri::command]
pub async fn get_recommendations(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
) -> Result<Snapshot, String> {
    run(app, state.inner().clone(), false, |s| s.snapshot()).await
}
#[tauri::command]
pub async fn recheck_recommendations(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
) -> Result<Snapshot, String> {
    run(app, state.inner().clone(), true, |s| {
        s.recheck(chrono::Utc::now().timestamp_millis())
    })
    .await
}
#[tauri::command]
pub async fn set_recommendation_hidden(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    id: String,
    hidden: bool,
) -> Result<Snapshot, String> {
    run(app, state.inner().clone(), true, move |s| {
        s.set_hidden(&id, hidden)
    })
    .await
}
#[tauri::command]
pub async fn restore_recommendations(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
) -> Result<Snapshot, String> {
    run(app, state.inner().clone(), true, |s| s.restore_hidden()).await
}
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Action {
    CopyInstructions,
    OpenCodex,
    ShowPackage,
    OpenProject,
}
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionReceipt {
    status: &'static str,
}
// These targets are constructed only after the core verifies a fixed catalog ID
// and package bytes. They are not Deserialize/Serialize or WebView arguments.
enum Target {
    Copy(String),
    Codex(String),
    Package(std::path::PathBuf),
    Project(String),
}
fn target(service: &RecommendationStore, id: &str, action: Action) -> Result<Target, String> {
    match action {
        Action::CopyInstructions => service.install_prompt(id).map(Target::Copy),
        Action::OpenCodex => service.install_prompt(id).map(Target::Codex),
        Action::ShowPackage => service.package_directory(id).map(Target::Package),
        Action::OpenProject => service.project_url(id).map(Target::Project),
    }
    .map_err(|e| e.code.to_owned())
}
fn codex_url(prompt: &str) -> String {
    let mut url = tauri::Url::parse("codex://threads/new").expect("fixed URL");
    url.query_pairs_mut()
        .append_pair("prompt", prompt)
        .append_pair("mode", "codex");
    url.to_string()
}
#[cfg(windows)]
fn open(target: &std::ffi::OsStr) -> Result<(), String> {
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
    let path = target.encode_wide().collect::<Vec<_>>();
    if path.is_empty() || path.len() > 65536 || path.contains(&0) {
        return Err("recommendation_open_failed".into());
    }
    let verb = "open\0".encode_utf16().collect::<Vec<_>>();
    let path = path.into_iter().chain(Some(0)).collect::<Vec<_>>();
    if unsafe {
        ShellExecuteW(
            std::ptr::null_mut(),
            verb.as_ptr(),
            path.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            1,
        )
    } <= 32
    {
        return Err("recommendation_open_failed".into());
    }
    Ok(())
}
#[cfg(not(windows))]
fn open(_: &std::ffi::OsStr) -> Result<(), String> {
    Err("recommendation_windows_required".into())
}
#[tauri::command]
pub async fn recommendation_action(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    id: String,
    action: Action,
) -> Result<ActionReceipt, String> {
    let service = store(&app, &state)?;
    let target = tauri::async_runtime::spawn_blocking(move || target(&service, &id, action))
        .await
        .map_err(|_| "recommendation_unavailable")??;
    let status = match target {
        Target::Copy(text) => {
            super::native_clipboard::copy_text(&app, &text)
                .map_err(|_| "recommendation_copy_failed")?;
            "copied"
        }
        Target::Codex(text) => {
            super::native_clipboard::copy_text(&app, &text)
                .map_err(|_| "recommendation_copy_failed")?;
            if open(std::ffi::OsStr::new(&codex_url(&text))).is_ok() {
                "codexRequested"
            } else {
                "copiedCodexUnavailable"
            }
        }
        Target::Package(path) => {
            let path = codexu_core::local_cli::launch::checked_directory(&path)
                .map_err(|_| "recommendation_package_changed")?;
            open(path.as_os_str())?;
            "packageShown"
        }
        Target::Project(url) => {
            open(std::ffi::OsStr::new(&url))?;
            "projectRequested"
        }
    };
    Ok(ActionReceipt { status })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn codex_link_has_only_fixed_scheme_route_and_encoded_prompt() {
        let prompt = "fixture # & ? % 中文\nC:\\fixture\\package";
        let url = tauri::Url::parse(&codex_url(prompt)).unwrap();
        assert_eq!(url.scheme(), "codex");
        assert_eq!(url.host_str(), Some("threads"));
        assert_eq!(url.path(), "/new");
        assert_eq!(
            url.query_pairs().collect::<Vec<_>>(),
            vec![
                ("prompt".into(), prompt.into()),
                ("mode".into(), "codex".into())
            ]
        );
    }
    #[test]
    fn action_input_does_not_accept_any_raw_url_path_or_shell_command() {
        for input in [
            "\"execute\"",
            "\"https://other.invalid\"",
            "{\"openProject\":\"cmd.exe\"}",
        ] {
            assert!(serde_json::from_str::<Action>(input).is_err());
        }
    }
}
