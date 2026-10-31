//! Explicit local inventory/decisions. No conversation writer or task runner.
use crate::app_state::AppState;
use codexu_core::task_workbench::{Decision, TaskWorkbenchStore, WorkbenchSnapshot};
use std::{path::Path, sync::Arc};
use tauri::{AppHandle, Emitter, State};
use tauri_plugin_dialog::DialogExt;

fn failure() -> String {
    "workbench_source_changed".into()
}
fn with_store<T>(
    state: &AppState,
    expected: Option<&str>,
    action: impl FnOnce(TaskWorkbenchStore) -> Result<T, String>,
) -> Result<T, String> {
    // Hold the existing config read lock through the bounded local transaction:
    // a settings change cannot redirect a write after the scope was checked.
    let config = state.config.blocking_read();
    let store = TaskWorkbenchStore::open(&state.app_data_dir, &config.codex_root)
        .map_err(|e| e.to_string())?;
    if expected.is_some_and(|v| v.len() != 64 || v != store.scope_id()) {
        return Err(failure());
    }
    action(store)
}
async fn run<T: Send + 'static>(
    state: Arc<AppState>,
    expected: Option<String>,
    action: impl FnOnce(TaskWorkbenchStore) -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(move || with_store(&state, expected.as_deref(), action))
        .await
        .map_err(|_| "workbench_storage_unavailable".to_string())?
}
fn snapshot(store: TaskWorkbenchStore) -> Result<WorkbenchSnapshot, String> {
    store
        .load(chrono::Utc::now().timestamp_millis())
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn get_task_workbench(
    state: State<'_, Arc<AppState>>,
) -> Result<WorkbenchSnapshot, String> {
    run(state.inner().clone(), None, snapshot).await
}
#[tauri::command]
pub async fn import_task_workbench_inventory(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    expected_scope_id: String,
    thread_id: String,
) -> Result<Option<WorkbenchSnapshot>, String> {
    run(
        state.inner().clone(),
        Some(expected_scope_id.clone()),
        snapshot,
    )
    .await?;
    let picker = app.clone();
    let selected = tauri::async_runtime::spawn_blocking(move || {
        picker
            .dialog()
            .file()
            .add_filter("JSON", &["json"])
            .blocking_pick_file()
    })
    .await
    .map_err(|_| "workbench_invalid".to_string())?;
    let Some(selected) = selected else {
        return Ok(None);
    };
    let path = selected
        .into_path()
        .map_err(|_| "workbench_invalid".to_string())?;
    let result = run(
        state.inner().clone(),
        Some(expected_scope_id),
        move |store| {
            let input = codexu_core::task_workbench::read_inventory_file(&path)
                .map_err(|e| e.to_string())?;
            store
                .import_inventory(&thread_id, &input, chrono::Utc::now().timestamp_millis())
                .map_err(|e| e.to_string())?;
            snapshot(store)
        },
    )
    .await?;
    let _ = app.emit("task-workbench:changed", ());
    Ok(Some(result))
}
#[tauri::command]
pub async fn set_task_workbench_decision(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    expected_scope_id: String,
    thread_id: String,
    decision: Decision,
) -> Result<WorkbenchSnapshot, String> {
    let result = run(
        state.inner().clone(),
        Some(expected_scope_id),
        move |store| {
            store
                .set_decision(&thread_id, decision, chrono::Utc::now().timestamp_millis())
                .map_err(|e| e.to_string())?;
            snapshot(store)
        },
    )
    .await?;
    let _ = app.emit("task-workbench:changed", ());
    Ok(result)
}

fn artifact_target(reference: &str) -> Result<(String, &'static str), String> {
    // The core has already loaded and validated a saved reference. A file is
    // revealed via its containing folder; its file association is never run.
    if reference.starts_with("https://") {
        return Ok((reference.to_owned(), "openedBrowser"));
    }
    let path = Path::new(reference);
    let parent = path
        .parent()
        .ok_or_else(|| "workbench_artifact_unavailable".to_string())?;
    let directory = codexu_core::local_cli::launch::checked_directory(parent)
        .map_err(|_| "workbench_artifact_unavailable".to_string())?;
    let meta = std::fs::symlink_metadata(path)
        .map_err(|_| "workbench_artifact_unavailable".to_string())?;
    if !meta.is_file() || meta.file_type().is_symlink() {
        return Err("workbench_artifact_unavailable".into());
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if meta.file_attributes() & 0x400 != 0 {
            return Err("workbench_artifact_unavailable".into());
        }
    }
    Ok((
        directory
            .to_str()
            .ok_or_else(|| "workbench_artifact_unavailable".to_string())?
            .into(),
        "openedFolder",
    ))
}
fn open_target(target: &str) -> Result<(), String> {
    #[cfg(windows)]
    {
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
        if target.contains('\0') {
            return Err("workbench_artifact_unavailable".into());
        }
        let verb: Vec<u16> = "open\0".encode_utf16().collect();
        let target: Vec<u16> = target.encode_utf16().chain(Some(0)).collect();
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
            return Err("workbench_artifact_unavailable".into());
        }
        Ok(())
    }
    #[cfg(not(windows))]
    {
        let _ = target;
        Err("workbench_artifact_unavailable".into())
    }
}
#[tauri::command]
pub async fn open_task_workbench_artifact(
    state: State<'_, Arc<AppState>>,
    expected_scope_id: String,
    thread_id: String,
    artifact_index: usize,
) -> Result<&'static str, String> {
    run(
        state.inner().clone(),
        Some(expected_scope_id),
        move |store| {
            let reference = store
                .artifact_reference(&thread_id, artifact_index)
                .map_err(|e| e.to_string())?;
            let (target, action) = artifact_target(&reference)?;
            open_target(&target)?;
            Ok(action)
        },
    )
    .await
}

#[cfg(test)]
#[path = "task_workbench_tests.rs"]
mod tests;
