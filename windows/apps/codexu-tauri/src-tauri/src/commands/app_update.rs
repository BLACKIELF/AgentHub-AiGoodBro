//! Explicit update check/download/open; no silent installation or application exit.
use crate::app_state::AppState;
use codexu_core::updates::{self, DownloadPlan, UpdateInfo};
use serde::Serialize;
use std::{path::PathBuf, sync::Arc};
use tauri::{Emitter, State};
use tokio::sync::Mutex;

#[derive(Clone, Debug, Serialize)]
pub struct UpdateStateDto {
    pub phase: &'static str,
    pub info: Option<UpdateInfo>,
    pub error_code: Option<&'static str>,
}

struct CompletedDownload {
    directory: tempfile::TempDir,
    plan: DownloadPlan,
    hash: String,
}

struct Session {
    generation: u64,
    dto: UpdateStateDto,
    plan: Option<DownloadPlan>,
    completed: Option<CompletedDownload>,
    job: Option<tokio::task::AbortHandle>,
}

#[derive(Clone)]
pub struct UpdateRuntime(Arc<Mutex<Session>>);

impl Default for UpdateRuntime {
    fn default() -> Self {
        Self(Arc::new(Mutex::new(Session {
            generation: 0,
            dto: UpdateStateDto {
                phase: "idle",
                info: None,
                error_code: None,
            },
            plan: None,
            completed: None,
            job: None,
        })))
    }
}

fn busy(phase: &str) -> bool {
    matches!(phase, "checking" | "downloading" | "verifying" | "opening")
}

fn emit(app: &tauri::AppHandle, dto: &UpdateStateDto) {
    let _ = app.emit("app-update:changed", dto);
}

#[cfg(windows)]
async fn transfer(
    url: &str,
    maximum_bytes: u64,
    output_path: Option<&std::path::Path>,
) -> Result<Vec<u8>, &'static str> {
    use std::{process::Stdio, time::Duration};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let executable = std::env::var_os("SystemRoot")
        .map(PathBuf::from)
        .ok_or("windows_runtime_unavailable")?
        .join("System32/WindowsPowerShell/v1.0/powershell.exe");
    let payload = serde_json::to_vec(&serde_json::json!({
        "url": url, "maximum_bytes": maximum_bytes, "output_path": output_path
    }))
    .map_err(|_| "invalid_update_input")?;
    let mut child = tokio::process::Command::new(executable)
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            include_str!("app_update.ps1"),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .creation_flags(0x0800_0000)
        .kill_on_drop(true)
        .spawn()
        .map_err(|_| "update_transport_unavailable")?;
    let mut input = child.stdin.take().ok_or("update_transport_unavailable")?;
    input
        .write_all(&payload)
        .await
        .map_err(|_| "update_transport_unavailable")?;
    drop(input);
    let mut output = child.stdout.take().ok_or("update_transport_unavailable")?;
    let maximum_output = if output_path.is_some() {
        1024
    } else {
        maximum_bytes as usize
    };
    let duration = if output_path.is_some() { 920 } else { 25 };
    tokio::time::timeout(Duration::from_secs(duration), async {
        let mut bytes = Vec::new();
        (&mut output)
            .take(maximum_output as u64 + 1)
            .read_to_end(&mut bytes)
            .await
            .map_err(|_| "update_read_failed")?;
        if bytes.len() > maximum_output {
            return Err("update_response_too_large");
        }
        if !child
            .wait()
            .await
            .map_err(|_| "update_transport_failed")?
            .success()
        {
            return Err("update_transport_failed");
        }
        Ok(bytes)
    })
    .await
    .map_err(|_| "update_timed_out")?
}

#[cfg(not(windows))]
async fn transfer(
    _url: &str,
    _maximum_bytes: u64,
    _output_path: Option<&std::path::Path>,
) -> Result<Vec<u8>, &'static str> {
    Err("windows_runtime_required")
}

#[tauri::command]
pub async fn get_app_update_state(
    runtime: State<'_, UpdateRuntime>,
) -> Result<UpdateStateDto, String> {
    Ok(runtime.0.lock().await.dto.clone())
}

#[tauri::command]
pub async fn check_app_update(
    app: tauri::AppHandle,
    runtime: State<'_, UpdateRuntime>,
) -> Result<UpdateStateDto, String> {
    let generation = {
        let mut session = runtime.0.lock().await;
        if busy(session.dto.phase) || session.dto.phase == "installer_opened" {
            return Err("update_busy".into());
        }
        session.generation += 1;
        session.dto.phase = "checking";
        session.dto.error_code = None;
        session.plan = None;
        session.completed = None;
        emit(&app, &session.dto);
        session.generation
    };
    let result = match transfer(updates::RELEASE_API, updates::MAX_RELEASE_SIZE as u64, None).await
    {
        Ok(bytes) => {
            updates::select_update(&bytes, env!("CARGO_PKG_VERSION"), std::env::consts::ARCH)
        }
        Err(code) => Err(code),
    };
    let mut session = runtime.0.lock().await;
    if session.generation != generation {
        return Ok(session.dto.clone());
    }
    match result {
        Ok((info, plan)) => {
            session.dto.phase = if info.available_version.is_some() {
                "available"
            } else {
                "up_to_date"
            };
            session.dto.info = Some(info);
            session.plan = plan;
        }
        Err(code) => {
            session.dto.phase = "failed";
            session.dto.error_code = Some(code);
        }
    }
    emit(&app, &session.dto);
    Ok(session.dto.clone())
}

async fn download(
    plan: DownloadPlan,
    root: PathBuf,
    runtime: UpdateRuntime,
    generation: u64,
    app: tauri::AppHandle,
) -> Result<CompletedDownload, &'static str> {
    let hash = match plan.sha256.clone() {
        Some(hash) => hash,
        None => {
            let checksum = plan.checksum.as_ref().ok_or("checksum_unavailable")?;
            let bytes = transfer(&checksum.browser_download_url, checksum.size, None).await?;
            updates::checksum_hash(&bytes, &plan.asset.name).ok_or("checksum_invalid")?
        }
    };
    let directory = tokio::task::spawn_blocking(move || {
        if !updates::safe_download_directory(&root) {
            return Err("download_directory_changed");
        }
        std::fs::create_dir_all(&root).map_err(|_| "download_directory_unavailable")?;
        if !updates::safe_download_directory(&root) {
            return Err("download_directory_changed");
        }
        tempfile::Builder::new()
            .prefix("verified-update-")
            .tempdir_in(root)
            .map_err(|_| "download_directory_unavailable")
    })
    .await
    .map_err(|_| "download_directory_unavailable")??;
    let path = directory.path().join(&plan.asset.name);
    let response = transfer(
        &plan.asset.browser_download_url,
        plan.asset.size,
        Some(&path),
    )
    .await?;
    let receipt: serde_json::Value =
        serde_json::from_slice(&response).map_err(|_| "download_receipt_invalid")?;
    if receipt.get("received").and_then(|v| v.as_u64()) != Some(plan.asset.size) {
        return Err("package_size_mismatch");
    }
    {
        let mut session = runtime.0.lock().await;
        if session.generation != generation {
            return Err("update_cancelled");
        }
        session.dto.phase = "verifying";
        emit(&app, &session.dto);
    }
    let expected_hash = hash.clone();
    let expected_size = plan.asset.size;
    tokio::task::spawn_blocking(move || updates::verify_file(&path, expected_size, &expected_hash))
        .await
        .map_err(|_| "verification_failed")??;
    Ok(CompletedDownload {
        directory,
        plan,
        hash,
    })
}

#[tauri::command]
pub async fn download_app_update(
    app: tauri::AppHandle,
    state: State<'_, Arc<AppState>>,
    runtime: State<'_, UpdateRuntime>,
) -> Result<UpdateStateDto, String> {
    let mut session = runtime.0.lock().await;
    if busy(session.dto.phase) || session.dto.phase == "installer_opened" {
        return Err("update_busy".into());
    }
    let plan = session.plan.clone().ok_or("update_check_required")?;
    session.generation += 1;
    let generation = session.generation;
    session.completed = None;
    session.dto.phase = "downloading";
    session.dto.error_code = None;
    emit(&app, &session.dto);
    let owned = runtime.inner().clone();
    let root = state.app_data_dir.join("updates");
    let task = tokio::spawn(async move {
        let result = download(plan, root, owned.clone(), generation, app.clone()).await;
        let mut session = owned.0.lock().await;
        if session.generation != generation {
            return;
        }
        session.job = None;
        match result {
            Ok(completed) => {
                session.completed = Some(completed);
                session.dto.phase = "downloaded";
            }
            Err(code) => {
                session.dto.phase = "failed";
                session.dto.error_code = Some(code);
            }
        }
        emit(&app, &session.dto);
    });
    session.job = Some(task.abort_handle());
    Ok(session.dto.clone())
}

#[tauri::command]
pub async fn cancel_app_update(
    app: tauri::AppHandle,
    runtime: State<'_, UpdateRuntime>,
) -> Result<UpdateStateDto, String> {
    let mut session = runtime.0.lock().await;
    if matches!(session.dto.phase, "opening" | "installer_opened") {
        return Err("installer_already_opening".into());
    }
    session.generation += 1;
    if let Some(job) = session.job.take() {
        job.abort();
    }
    session.completed = None;
    session.dto.phase = "cancelled";
    session.dto.error_code = None;
    emit(&app, &session.dto);
    Ok(session.dto.clone())
}

#[tauri::command]
pub async fn open_app_update(
    app: tauri::AppHandle,
    runtime: State<'_, UpdateRuntime>,
) -> Result<UpdateStateDto, String> {
    let mut session = runtime.0.lock().await;
    if session.dto.phase != "downloaded" {
        return Err("verified_download_required".into());
    }
    let completed = session
        .completed
        .as_ref()
        .ok_or("verified_download_required")?;
    let path = completed.directory.path().join(&completed.plan.asset.name);
    let hash = completed.hash.clone();
    let size = completed.plan.asset.size;
    session.dto.phase = "opening";
    emit(&app, &session.dto);
    // Keep the owned download alive while rechecking and opening. This does not
    // close AiGoodBro or pass any silent/restart flags to the installer.
    let result = tokio::task::spawn_blocking(move || -> Result<(), &'static str> {
        updates::verify_file(&path, size, &hash)?;
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            if path.extension().is_some_and(|ext| ext == "msi") {
                let executable = std::env::var_os("SystemRoot")
                    .map(PathBuf::from)
                    .ok_or("windows_runtime_unavailable")?
                    .join("System32/msiexec.exe");
                std::process::Command::new(executable)
                    .arg("/i")
                    .arg(&path)
                    .creation_flags(0x0800_0000)
                    .spawn()
                    .map_err(|_| "installer_open_failed")?;
            } else {
                std::process::Command::new(&path)
                    .spawn()
                    .map_err(|_| "installer_open_failed")?;
            }
            Ok(())
        }
        #[cfg(not(windows))]
        {
            Err("windows_runtime_required")
        }
    })
    .await
    .map_err(|_| "installer_open_failed".to_string())?;
    match result {
        Ok(()) => {
            // The installer may still be reading its source when this App exits.
            // Retain this verified package; a later check must not remove it.
            if let Some(completed) = session.completed.take() {
                let _ = completed.directory.keep();
            }
            session.dto.phase = "installer_opened";
            session.dto.error_code = None;
        }
        Err(code) => {
            session.dto.phase = "failed";
            session.dto.error_code = Some(code);
        }
    }
    emit(&app, &session.dto);
    Ok(session.dto.clone())
}
