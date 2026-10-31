//! App composition only. Construction does not inspect Python, bind a source,
//! start a receiver/Hub, or install a Skill. The explicit setup flow owns those actions.
use super::task_hub::{CompanionRuntime, HubState};
use crate::{app_state::AppState, native_services::NativeServices};
use codexu_core::companion_setup::{BundlePin, SetupStore, Snapshot};
use std::sync::Arc;
use tauri::{AppHandle, Emitter, Manager, State};

pub struct CompanionState(Result<Arc<CompanionRuntime>, String>);

impl CompanionState {
    pub fn new(application: Arc<AppState>, services: &NativeServices, hub: &HubState) -> Self {
        let runtime = (|| {
            // Use the same account manager and admission gate as the existing Hub.
            let manager = services.statistics_accounts()?;
            let gate = services
                .gate
                .as_ref()
                .cloned()
                .map_err(|code| (*code).to_owned())?;
            Ok(Arc::new(CompanionRuntime::new(
                application,
                manager,
                gate,
                hub,
            )))
        })();
        Self(runtime)
    }

    pub(crate) fn runtime(&self) -> Result<Arc<CompanionRuntime>, String> {
        self.0.clone()
    }

    /// A failed constructor owns no receiver. Only actual cleanup uncertainty
    /// may participate in the exit decision; missing setup never adds a prompt.
    pub fn cleanup_unconfirmed(&self) -> bool {
        self.0
            .as_ref()
            .is_ok_and(|runtime| runtime.cleanup_unconfirmed())
    }
}

// A constructor error owns no receiver, so an unconfigured installation never
// adds an exit prompt. Each actual transition invalidates the UI's ready view.
pub(crate) fn prepare_normal_exit(app: &AppHandle) -> Result<(), String> {
    let result = match app.state::<CompanionState>().runtime() {
        Ok(runtime) => runtime.prepare_normal_exit(),
        Err(_) => Ok(()),
    };
    let _ = app.emit("companion-setup:changed", ());
    result
}

pub(crate) fn resume_normal_exit(app: &AppHandle) {
    if let Ok(runtime) = app.state::<CompanionState>().runtime() {
        // Failure remains represented by the retained owner / unavailable state.
        // It does not authorize rebinding or another request.
        let _ = runtime.resume_normal_exit();
    }
    let _ = app.emit("companion-setup:changed", ());
}

pub(crate) fn force_stop_owned(app: &AppHandle) {
    if let Ok(runtime) = app.state::<CompanionState>().runtime() {
        let _ = runtime.stop_owned();
    }
}

fn setup(app: &AppHandle, state: &AppState) -> Result<(SetupStore, BundlePin), String> {
    let home = app
        .path()
        .home_dir()
        .map_err(|_| "companion_home_unavailable")?;
    let target = home
        .join(".codex")
        .join("skills")
        .join("multi-agent-management");
    let resources = app
        .path()
        .resource_dir()
        .map_err(|_| "companion_bundle_missing")?
        .join("companion-setup");
    let pin = option_env!("AIGOODBRO_COMPANION_SETUP_MANIFEST_SHA256")
        .ok_or("companion_bundle_unverified")?;
    Ok((
        SetupStore::new(&state.app_data_dir, target).map_err(|e| e.code.to_owned())?,
        BundlePin::new(resources, pin.into()).map_err(|e| e.code.to_owned())?,
    ))
}

#[tauri::command]
pub async fn inspect_companion_setup(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    companion: State<'_, CompanionState>,
) -> Result<Snapshot, String> {
    let (setup, pin) = setup(&app, &state)?;
    let runtime = companion.runtime()?;
    tauri::async_runtime::spawn_blocking(move || runtime.inspect(&setup, &pin))
        .await
        .map_err(|_| "companion_operation_unconfirmed".into())
}

#[tauri::command]
pub async fn prepare_companion_setup(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    companion: State<'_, CompanionState>,
) -> Result<Snapshot, String> {
    let (setup, pin) = setup(&app, &state)?;
    let runtime = companion.runtime()?;
    tauri::async_runtime::spawn_blocking(move || runtime.prepare(&setup, &pin))
        .await
        .map_err(|_| "companion_operation_unconfirmed".to_owned())?
}

#[tauri::command]
pub async fn confirm_companion_setup(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    companion: State<'_, CompanionState>,
    plan_id: String,
) -> Result<Snapshot, String> {
    if plan_id.len() != 64
        || !plan_id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err("companion_plan_invalid".into());
    }
    let (setup, pin) = setup(&app, &state)?;
    let runtime = companion.runtime()?;
    let result = tauri::async_runtime::spawn_blocking(move || {
        runtime.confirm_install(&plan_id, &setup, &pin)
    })
    .await
    .map_err(|_| "companion_operation_unconfirmed".to_owned())
    .and_then(|value| value);
    let _ = app.emit("companion-setup:changed", ());
    result
}
