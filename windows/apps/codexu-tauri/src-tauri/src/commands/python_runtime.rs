//! Explicit local interpreter checks; no download, installation or task execution.
use crate::app_state::AppState;
use codexu_core::runtime_setup::{
    python::{automatic_candidates, PythonSelection},
    RuntimeView,
};
use std::{path::PathBuf, sync::Arc};
use tauri::State;

#[tauri::command]
pub async fn inspect_python_runtime(
    state: State<'_, Arc<AppState>>,
) -> Result<RuntimeView, String> {
    let selection = PythonSelection::new(&state.app_data_dir).map_err(|e| e.code.to_owned())?;
    tauri::async_runtime::spawn_blocking(move || selection.inspect(&automatic_candidates()))
        .await
        .map_err(|_| "python_operation_unconfirmed".to_owned())
}

#[tauri::command]
pub async fn select_python_runtime(
    state: State<'_, Arc<AppState>>,
    path: PathBuf,
) -> Result<RuntimeView, String> {
    let selection = PythonSelection::new(&state.app_data_dir).map_err(|e| e.code.to_owned())?;
    tauri::async_runtime::spawn_blocking(move || selection.choose(&path))
        .await
        .map_err(|_| "python_operation_unconfirmed".to_owned())?
        .map_err(|e| e.code.to_owned())
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PythonGuide {
    Windows,
    Timezone,
}

#[tauri::command]
pub async fn open_python_installation_guide(topic: Option<PythonGuide>) -> Result<(), String> {
    let destination = match topic.unwrap_or(PythonGuide::Windows) {
        PythonGuide::Windows => "https://docs.python.org/3/using/windows.html",
        PythonGuide::Timezone => "https://docs.python.org/3/library/zoneinfo.html#data-sources",
    };
    super::runtime_setup::open_official_guide(destination)
}
