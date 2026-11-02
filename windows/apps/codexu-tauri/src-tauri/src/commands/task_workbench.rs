//! Explicit local inventory/decisions. No conversation writer or task runner.
use crate::app_state::AppState;
use codexu_core::task_workbench::{Decision, TaskWorkbenchStore, WorkbenchSnapshot};
use codexu_core::{
    accounts::AccountManager,
    managed_proxy::{ManagedActivityGuard, ManagedProxyGate},
};
use sha2::{Digest, Sha256};
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

fn owner_metadata_digest(
    snapshot: &WorkbenchSnapshot,
    expected_scope: &str,
    thread_id: &str,
) -> Result<String, String> {
    if !snapshot.source_available
        || snapshot.scope_id != expected_scope
        || !codexu_core::task_workbench::valid_thread_id(thread_id)
    {
        return Err("owner_scope_unverified".into());
    }
    let mut matches = snapshot
        .items
        .iter()
        .filter(|item| item.thread_id == thread_id);
    let item = matches.next().ok_or("owner_thread_unavailable")?;
    if item.archived || matches.next().is_some() {
        return Err("owner_thread_unavailable".into());
    }
    // Include the saved inventory and current local metadata, but not the
    // per-read clock. This is a local change fence, not GUI account evidence.
    let bytes = serde_json::to_vec(item).map_err(|_| "owner_scope_unverified")?;
    Ok(format!("{:x}", Sha256::digest(bytes)))
}

/// Native-only context for an explicit original-window action. A managed
/// active scope supplies local concurrency/source evidence, never a claim
/// about the separate GUI owner's account. This function starts no observer.
pub(crate) async fn capture_owner_context(
    state: Arc<AppState>,
    manager: Arc<AccountManager>,
    expected_scope: String,
    thread_id: String,
) -> Result<super::desktop_owner_actions::NativeOwnerContext, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let config = state.config.blocking_read();
        let store = TaskWorkbenchStore::open(&state.app_data_dir, &config.codex_root)
            .map_err(|_| "owner_scope_unverified")?;
        if expected_scope.len() != 64 || store.scope_id() != expected_scope {
            return Err("owner_scope_unverified".into());
        }
        let active = manager
            .verified_active_system_scope()
            .map_err(|_| "owner_scope_unverified")?;
        let root = config
            .codex_root
            .canonicalize()
            .map_err(|_| "owner_scope_unverified")?;
        if root != active.canonical_home() {
            return Err("owner_scope_unverified".into());
        }
        let current = snapshot(store)?;
        let digest = owner_metadata_digest(&current, &expected_scope, &thread_id)?;
        manager
            .recheck_active_system_scope(&active)
            .map_err(|_| "owner_scope_changed")?;
        super::desktop_owner_actions::NativeOwnerContext::from_verified(
            active,
            expected_scope,
            thread_id,
            digest,
        )
    })
    .await
    .map_err(|_| "owner_scope_unverified".to_owned())?
}

pub(crate) async fn capture_owner_context_with_guard(
    state: Arc<AppState>,
    manager: Arc<AccountManager>,
    gate: Arc<ManagedProxyGate>,
    expected_scope: String,
    thread_id: String,
) -> Result<
    (
        super::desktop_owner_actions::NativeOwnerContext,
        ManagedActivityGuard,
    ),
    String,
> {
    tauri::async_runtime::spawn_blocking(move || {
        let config = state.config.blocking_read();
        let store = TaskWorkbenchStore::open(&state.app_data_dir, &config.codex_root)
            .map_err(|_| "owner_scope_unverified")?;
        if expected_scope.len() != 64 || store.scope_id() != expected_scope {
            return Err("owner_scope_unverified".into());
        }
        let active = manager
            .verified_active_system_scope()
            .map_err(|_| "owner_scope_unverified")?;
        let root = config
            .codex_root
            .canonicalize()
            .map_err(|_| "owner_scope_unverified")?;
        if root != active.canonical_home() {
            return Err("owner_scope_unverified".into());
        }
        let current = snapshot(store)?;
        let digest = owner_metadata_digest(&current, &expected_scope, &thread_id)?;
        manager
            .recheck_active_system_scope(&active)
            .map_err(|_| "owner_scope_changed")?;
        let guard = gate
            .reserve_terminal(active.identity_hash())
            .map_err(|_| "owner_busy")?;
        manager
            .recheck_active_system_scope(&active)
            .map_err(|_| "owner_scope_changed")?;
        let context = super::desktop_owner_actions::NativeOwnerContext::from_verified(
            active,
            expected_scope,
            thread_id,
            digest,
        )?;
        Ok((context, guard))
    })
    .await
    .map_err(|_| "owner_scope_unverified".to_owned())?
}

fn owner_preview_epoch(state: &AppState, preview_id: &str) -> Result<Option<u64>, String> {
    state
        .owner_preview_epochs
        .lock()
        .map(|epochs| epochs.get(preview_id).copied())
        .map_err(|_| "owner_unavailable".into())
}

fn remember_owner_preview(state: &AppState, preview_id: &str, epoch: u64) -> Result<(), String> {
    remember_owner_preview_after_epoch_check(state, preview_id, epoch, || {})
}

fn remember_owner_preview_after_epoch_check(
    state: &AppState,
    preview_id: &str,
    epoch: u64,
    after_check: impl FnOnce(),
) -> Result<(), String> {
    if !current_owner_epoch(state, epoch) {
        return Err("owner_window_closed".into());
    }
    // The test seam pauses here to force the close-vs-register interleaving.
    // Production passes a no-op; correctness comes from the locked recheck.
    after_check();
    let mut epochs = state
        .owner_preview_epochs
        .lock()
        .map_err(|_| "owner_unavailable".to_string())?;
    if !current_owner_epoch(state, epoch) {
        return Err("owner_window_closed".into());
    }
    epochs.insert(preview_id.to_owned(), epoch);
    Ok(())
}

pub(crate) fn discard_closed_preview_ids(preview_ids: &[String], mut discard: impl FnMut(&str)) {
    for preview_id in preview_ids {
        discard(preview_id);
    }
}

fn current_owner_epoch(state: &AppState, expected: u64) -> bool {
    state
        .owner_window_epoch
        .load(std::sync::atomic::Ordering::Acquire)
        == expected
}

async fn prepare_owner_action(
    state: Arc<AppState>,
    services: &crate::native_services::NativeServices,
    expected_scope_id: String,
    thread_id: String,
    action: Option<super::desktop_owner_actions::OwnerAction>,
    interrupt: bool,
) -> Result<super::desktop_owner_actions::OwnerPreview, String> {
    use super::desktop_owner_actions::OwnerActions;

    let epoch = state
        .owner_window_epoch
        .load(std::sync::atomic::Ordering::Acquire);
    let manager = services.statistics_accounts()?;
    let gate = services
        .gate
        .as_ref()
        .cloned()
        .map_err(|error| (*error).to_owned())?;
    let (context, guard) = capture_owner_context_with_guard(
        state.clone(),
        manager,
        gate,
        expected_scope_id,
        thread_id,
    )
    .await?;
    if !current_owner_epoch(&state, epoch) {
        return Err("owner_window_closed".into());
    }
    let mut actions = state.owner_actions.lock().await;
    let actions: &mut OwnerActions = actions
        .as_mut()
        .ok_or_else(|| "owner_journal_unavailable".to_string())?;
    if !current_owner_epoch(&state, epoch) {
        return Err("owner_window_closed".into());
    }
    let preview = if interrupt {
        actions
            .prepare_current_interrupt(context, guard.into())
            .await?
    } else {
        actions
            .prepare(
                context,
                action.ok_or_else(|| "owner_invalid_request".to_string())?,
                guard.into(),
            )
            .await?
    };
    if !current_owner_epoch(&state, epoch) {
        actions.discard_preview(&preview.preview_id);
        return Err("owner_window_closed".into());
    }
    if let Err(error) = remember_owner_preview(&state, &preview.preview_id, epoch) {
        actions.discard_preview(&preview.preview_id);
        return Err(error);
    }
    Ok(preview)
}

#[tauri::command]
pub async fn prepare_original_owner_start(
    state: State<'_, Arc<AppState>>,
    services: State<'_, crate::native_services::NativeServices>,
    expected_scope_id: String,
    thread_id: String,
    text: String,
) -> Result<super::desktop_owner_actions::OwnerPreview, String> {
    prepare_owner_action(
        state.inner().clone(),
        services.inner(),
        expected_scope_id,
        thread_id,
        Some(super::desktop_owner_actions::OwnerAction::StartText(text)),
        false,
    )
    .await
}

#[tauri::command]
pub async fn prepare_original_owner_interrupt(
    state: State<'_, Arc<AppState>>,
    services: State<'_, crate::native_services::NativeServices>,
    expected_scope_id: String,
    thread_id: String,
) -> Result<super::desktop_owner_actions::OwnerPreview, String> {
    prepare_owner_action(
        state.inner().clone(),
        services.inner(),
        expected_scope_id,
        thread_id,
        None,
        true,
    )
    .await
}

#[tauri::command]
pub async fn confirm_original_owner_action(
    state: State<'_, Arc<AppState>>,
    services: State<'_, crate::native_services::NativeServices>,
    expected_scope_id: String,
    thread_id: String,
    preview_id: String,
    operation_id: String,
    action_hash: String,
) -> Result<super::desktop_owner_actions::OwnerActionStatus, String> {
    let epoch = owner_preview_epoch(&state, &preview_id)?
        .ok_or_else(|| "owner_preview_expired".to_string())?;
    if !current_owner_epoch(&state, epoch) {
        return Err("owner_window_closed".into());
    }
    let manager = services.statistics_accounts()?;
    let mut actions = state.owner_actions.lock().await;
    let actions = actions
        .as_mut()
        .ok_or_else(|| "owner_journal_unavailable".to_string())?;
    if !current_owner_epoch(&state, epoch) {
        return Err("owner_window_closed".into());
    }
    let result = actions
        .confirm(&preview_id, &operation_id, &action_hash, || {
            capture_owner_context(
                state.inner().clone(),
                manager.clone(),
                expected_scope_id.clone(),
                thread_id.clone(),
            )
        })
        .await;
    if result.is_err() || !current_owner_epoch(&state, epoch) {
        actions.discard_preview(&preview_id);
        if let Ok(mut epochs) = state.owner_preview_epochs.lock() {
            epochs.remove(&preview_id);
        }
        return result.and_then(|_| Err("owner_window_closed".into()));
    }
    if let Ok(mut epochs) = state.owner_preview_epochs.lock() {
        epochs.remove(&preview_id);
    }
    result
}

#[tauri::command]
pub async fn get_original_owner_action_status(
    state: State<'_, Arc<AppState>>,
    operation_id: String,
) -> Result<Option<super::desktop_owner_actions::OwnerActionStatus>, String> {
    let actions = state.owner_actions.lock().await;
    actions
        .as_ref()
        .ok_or_else(|| "owner_journal_unavailable".to_string())?
        .status(&operation_id)
}

#[tauri::command]
pub async fn poll_original_owner_action(
    state: State<'_, Arc<AppState>>,
    services: State<'_, crate::native_services::NativeServices>,
    expected_scope_id: String,
    thread_id: String,
    operation_id: String,
) -> Result<super::desktop_owner_actions::OwnerActionStatus, String> {
    let manager = services.statistics_accounts()?;
    state
        .owner_actions
        .lock()
        .await
        .as_mut()
        .ok_or_else(|| "owner_journal_unavailable".to_string())?
        .poll(&operation_id, || {
            capture_owner_context(
                state.inner().clone(),
                manager.clone(),
                expected_scope_id.clone(),
                thread_id.clone(),
            )
        })
        .await
}

#[tauri::command]
pub async fn discard_original_owner_preview(
    state: State<'_, Arc<AppState>>,
    preview_id: String,
) -> Result<bool, String> {
    if let Ok(mut epochs) = state.owner_preview_epochs.lock() {
        epochs.remove(&preview_id);
    }
    Ok(state
        .owner_actions
        .lock()
        .await
        .as_mut()
        .is_some_and(|actions| actions.discard_preview(&preview_id)))
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
