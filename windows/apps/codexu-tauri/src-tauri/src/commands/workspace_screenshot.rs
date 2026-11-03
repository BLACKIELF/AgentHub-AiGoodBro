use serde::Serialize;
use std::path::Path;

#[cfg(any(windows, test))]
use std::{
    fs::File,
    io::{Read, Seek, SeekFrom, Write},
    path::PathBuf,
    sync::Mutex,
};

#[cfg(any(windows, test))]
use std::sync::atomic::{AtomicBool, Ordering};

#[cfg(any(windows, test))]
static WORKSPACE_SCREENSHOT_IN_PROGRESS: AtomicBool = AtomicBool::new(false);

#[cfg(any(windows, test))]
struct NativeWorkspaceScreenshotOrder {
    image_path: PathBuf,
    marker: Mutex<File>,
}

#[cfg(any(windows, test))]
impl NativeWorkspaceScreenshotOrder {
    fn create(image_path: PathBuf, marker_path: PathBuf) -> Result<Self, String> {
        match std::fs::symlink_metadata(&marker_path) {
            Ok(_) => return Err("screenshot_test_order_exists".into()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err("screenshot_test_order_unavailable".into()),
        }
        let marker = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&marker_path)
            .map_err(|_| "screenshot_test_order_unavailable".to_owned())?;
        Ok(Self {
            image_path,
            marker: Mutex::new(marker),
        })
    }

    fn record_restore_complete(&self) -> Result<(), String> {
        self.transition(b"", b"restored")
    }

    fn require_restore_before_save(&self, path: &Path) -> Result<(), String> {
        if path != self.image_path.as_path() {
            return Err("screenshot_test_output_path_invalid".into());
        }
        self.require_state(b"restored")
    }

    fn record_save_complete(&self) -> Result<(), String> {
        self.transition(b"restored", b"restored|saved")
    }

    fn verify_save_complete(&self) -> Result<(), String> {
        self.require_state(b"restored|saved")
    }

    fn require_state(&self, expected: &[u8]) -> Result<(), String> {
        let mut marker = self
            .marker
            .lock()
            .map_err(|_| "screenshot_test_order_unavailable".to_owned())?;
        marker
            .seek(SeekFrom::Start(0))
            .map_err(|_| "screenshot_test_order_unavailable".to_owned())?;
        let mut actual = Vec::new();
        marker
            .read_to_end(&mut actual)
            .map_err(|_| "screenshot_test_order_unavailable".to_owned())?;
        if actual == expected {
            Ok(())
        } else {
            Err("screenshot_test_order_invalid".into())
        }
    }

    fn transition(&self, expected: &[u8], next: &[u8]) -> Result<(), String> {
        let mut marker = self
            .marker
            .lock()
            .map_err(|_| "screenshot_test_order_unavailable".to_owned())?;
        marker
            .seek(SeekFrom::Start(0))
            .map_err(|_| "screenshot_test_order_unavailable".to_owned())?;
        let mut actual = Vec::new();
        marker
            .read_to_end(&mut actual)
            .map_err(|_| "screenshot_test_order_unavailable".to_owned())?;
        if actual != expected {
            return Err("screenshot_test_order_invalid".into());
        }
        marker
            .set_len(0)
            .and_then(|_| marker.seek(SeekFrom::Start(0)).map(|_| ()))
            .and_then(|_| marker.write_all(next))
            .and_then(|_| marker.sync_all())
            .map_err(|_| "screenshot_test_order_unavailable".to_owned())
    }
}

#[cfg(any(windows, test))]
struct WorkspaceScreenshotPermit;

#[cfg(any(windows, test))]
impl WorkspaceScreenshotPermit {
    fn acquire() -> Result<Self, String> {
        WORKSPACE_SCREENSHOT_IN_PROGRESS
            .compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
            .map(|_| Self)
            .map_err(|_| "screenshot_capture_busy".to_owned())
    }
}

#[cfg(any(windows, test))]
impl Drop for WorkspaceScreenshotPermit {
    fn drop(&mut self) {
        WORKSPACE_SCREENSHOT_IN_PROGRESS.store(false, Ordering::Release);
    }
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(tag = "status", rename_all = "camelCase")]
pub enum WorkspaceScreenshotOutcome {
    Saved,
    Cancelled,
}

#[tauri::command]
pub async fn save_workspace_screenshot(
    app: tauri::AppHandle,
) -> Result<WorkspaceScreenshotOutcome, String> {
    #[cfg(windows)]
    {
        save_windows_workspace_screenshot(app).await
    }
    #[cfg(not(windows))]
    {
        let _ = app;
        Err("workspace_screenshot_unavailable".into())
    }
}

const MAX_DIMENSION: u32 = 32_768;
const MAX_RGBA_BYTES: u64 = 128_000_000;
const MAX_PNG_BYTES: usize = 129_000_000;
#[cfg(windows)]
const CAPTURE_DEADLINE: std::time::Duration = std::time::Duration::from_secs(30);
#[cfg(windows)]
const PREPARE_SCRIPT: &str = concat!(
    include_str!("../../../web/src/utils/workspaceScreenshotCapture.js"),
    "\nwindow.__aigoodbroWorkspaceScreenshotCapture.prepare()"
);
#[cfg(windows)]
const RESTORE_SCRIPT: &str = "window.__aigoodbroWorkspaceScreenshotCapture?.restore() ?? false";
#[cfg(windows)]
const NATIVE_WORKSPACE_SCREENSHOT_TEST_ENV: &str = "AIGOODBRO_NATIVE_WORKSPACE_SCREENSHOT_TEST";
#[cfg(windows)]
const NATIVE_WORKSPACE_SCREENSHOT_FIXTURE_SCRIPT: &str =
    "window.__AIGOODBRO_NATIVE_WORKSPACE_SCREENSHOT_FIXTURE__ = true;";

fn validate_dimensions(width: u32, height: u32) -> Result<(), String> {
    if width == 0 || height == 0 || width > MAX_DIMENSION || height > MAX_DIMENSION {
        return Err("screenshot_dimensions_out_of_bounds".into());
    }
    let bytes = u64::from(width)
        .checked_mul(u64::from(height))
        .and_then(|pixels| pixels.checked_mul(4))
        .ok_or_else(|| "screenshot_dimensions_out_of_bounds".to_owned())?;
    if bytes > MAX_RGBA_BYTES {
        return Err("screenshot_dimensions_out_of_bounds".into());
    }
    Ok(())
}

fn validate_png(png: &[u8], width: u32, height: u32) -> Result<(), String> {
    validate_dimensions(width, height)?;
    if png.len() < 45 || png.len() > MAX_PNG_BYTES {
        return Err("screenshot_png_invalid".into());
    }
    let decoder = png::Decoder::new_with_limits(
        std::io::Cursor::new(png),
        png::Limits {
            bytes: MAX_RGBA_BYTES as usize,
        },
    );
    let mut reader = decoder
        .read_info()
        .map_err(|_| "screenshot_png_invalid".to_owned())?;
    if reader.info().width != width || reader.info().height != height {
        return Err("screenshot_png_dimensions_mismatch".into());
    }
    let output_size = reader
        .output_buffer_size()
        .filter(|size| *size <= MAX_RGBA_BYTES as usize)
        .ok_or_else(|| "screenshot_png_invalid".to_owned())?;
    let mut decoded = vec![0; output_size];
    let info = reader
        .next_frame(&mut decoded)
        .map_err(|_| "screenshot_png_invalid".to_owned())?;
    if info.width != width || info.height != height {
        return Err("screenshot_png_dimensions_mismatch".into());
    }
    reader
        .finish()
        .map_err(|_| "screenshot_png_invalid".to_owned())?;
    Ok(())
}

fn require_png_path(path: &Path) -> Result<(), String> {
    if path
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| extension.eq_ignore_ascii_case("png"))
    {
        Ok(())
    } else {
        Err("screenshot_save_path_must_be_png".into())
    }
}

fn finish_screenshot_save(
    path: Option<&Path>,
    save: impl FnOnce(&Path) -> Result<(), String>,
) -> Result<WorkspaceScreenshotOutcome, String> {
    let Some(path) = path else {
        return Ok(WorkspaceScreenshotOutcome::Cancelled);
    };
    save(path)?;
    Ok(WorkspaceScreenshotOutcome::Saved)
}

#[cfg(windows)]
mod windows_capture {
    use super::{
        finish_screenshot_save, require_png_path, validate_dimensions, validate_png,
        NativeWorkspaceScreenshotOrder, WorkspaceScreenshotOutcome, WorkspaceScreenshotPermit,
        CAPTURE_DEADLINE, MAX_PNG_BYTES, NATIVE_WORKSPACE_SCREENSHOT_FIXTURE_SCRIPT,
        NATIVE_WORKSPACE_SCREENSHOT_TEST_ENV, PREPARE_SCRIPT, RESTORE_SCRIPT,
    };
    use base64::{engine::general_purpose::STANDARD, Engine as _};
    use chrono::Local;
    use serde::Deserialize;
    use serde_json::{json, Value};
    use sha2::{Digest, Sha256};
    use std::{
        fs::File,
        io::{Read, Seek, SeekFrom, Write},
        path::{Path, PathBuf},
        sync::{
            atomic::{AtomicBool, Ordering},
            Arc, Mutex,
        },
    };
    use tauri::{AppHandle, Manager, WebviewWindow};
    use tauri_plugin_dialog::DialogExt;
    use tokio::sync::oneshot;
    use webview2_com::CallDevToolsProtocolMethodCompletedHandler;
    use windows::core::PCWSTR;

    #[derive(Debug, Deserialize)]
    struct PreparedWorkspace {
        ok: bool,
        width: Option<u32>,
        height: Option<u32>,
        error: Option<String>,
    }

    struct DomRestoreGuard {
        window: WebviewWindow,
        active: bool,
    }

    struct CancelOutstandingCapture(Arc<AtomicBool>);

    impl Drop for CancelOutstandingCapture {
        fn drop(&mut self) {
            self.0.store(true, Ordering::Release);
        }
    }

    impl DomRestoreGuard {
        fn new(window: WebviewWindow) -> Self {
            Self {
                window,
                active: true,
            }
        }

        async fn restore(&mut self) -> Result<(), String> {
            if !self.active {
                return Ok(());
            }
            let result = eval_script(&self.window, RESTORE_SCRIPT).await?;
            if result.as_bool() != Some(true) {
                return Err("screenshot_dom_restore_failed".into());
            }
            self.active = false;
            Ok(())
        }
    }

    /// Creates private ordering evidence only for the isolated native-visual
    /// harness. The fixed marker advances after DOM restore and is checked by
    /// the shared save path before any PNG bytes are written.
    impl NativeWorkspaceScreenshotOrder {
        fn begin() -> Result<Option<Self>, String> {
            if !native_workspace_screenshot_test_enabled() {
                return Ok(None);
            }
            let image_path = native_workspace_screenshot_test_path()?;
            let marker_path = image_path.with_file_name("workspace-order.txt");
            Ok(Some(NativeWorkspaceScreenshotOrder::create(
                image_path,
                marker_path,
            )?))
        }
    }

    impl Drop for DomRestoreGuard {
        fn drop(&mut self) {
            if self.active {
                let _ = self.window.eval(RESTORE_SCRIPT.to_owned());
            }
        }
    }

    pub(super) async fn save_windows_workspace_screenshot(
        app: AppHandle,
    ) -> Result<WorkspaceScreenshotOutcome, String> {
        let _capture_permit = WorkspaceScreenshotPermit::acquire()?;
        let test_order = NativeWorkspaceScreenshotOrder::begin()?;
        let window = app
            .get_webview_window("main")
            .ok_or_else(|| "main_webview_unavailable".to_owned())?;
        let mut restore_guard = DomRestoreGuard::new(window.clone());
        let capture_result =
            match tokio::time::timeout(CAPTURE_DEADLINE, capture_main_workspace(&window)).await {
                Ok(result) => result,
                Err(_) => Err("screenshot_capture_timeout".into()),
            };
        let restore_result = restore_guard.restore().await;
        restore_result?;
        if let Some(order) = &test_order {
            order.record_restore_complete()?;
        }
        let (width, height, png) = capture_result?;

        let path = choose_save_path(&app, &window, test_order.as_ref()).await?;
        let outcome = finish_screenshot_save(path.as_deref(), |path| {
            save_png(path, &png, width, height, test_order.as_ref())
        })?;
        if let Some(order) = &test_order {
            if outcome == WorkspaceScreenshotOutcome::Saved {
                order.verify_save_complete()?;
            }
        }
        Ok(outcome)
    }

    async fn capture_main_workspace(window: &WebviewWindow) -> Result<(u32, u32, Vec<u8>), String> {
        let prepare_script = if native_workspace_screenshot_test_enabled() {
            format!("{NATIVE_WORKSPACE_SCREENSHOT_FIXTURE_SCRIPT}\n{PREPARE_SCRIPT}")
        } else {
            PREPARE_SCRIPT.to_owned()
        };
        let prepared: PreparedWorkspace =
            eval_script(window, &prepare_script)
                .await
                .and_then(|value| {
                    serde_json::from_value(value).map_err(|_| "screenshot_prepare_invalid".into())
                })?;
        if !prepared.ok {
            return Err(prepared
                .error
                .unwrap_or_else(|| "screenshot_prepare_failed".into()));
        }
        let width = prepared
            .width
            .ok_or_else(|| "screenshot_prepare_invalid".to_owned())?;
        let height = prepared
            .height
            .ok_or_else(|| "screenshot_prepare_invalid".to_owned())?;
        validate_dimensions(width, height)?;

        let response = capture_page_screenshot(
            window,
            json!({
                "format": "png",
                "fromSurface": true,
                "captureBeyondViewport": true,
                "clip": { "x": 0, "y": 0, "width": width, "height": height, "scale": 1 }
            }),
        )
        .await?;
        let encoded = response
            .get("data")
            .and_then(Value::as_str)
            .ok_or_else(|| "screenshot_capture_invalid".to_owned())?;
        if encoded.len() > MAX_PNG_BYTES.saturating_add(2) / 3 * 4 + 4 {
            return Err("screenshot_png_too_large".into());
        }
        let png = STANDARD
            .decode(encoded)
            .map_err(|_| "screenshot_capture_invalid".to_owned())?;
        drop(response);
        validate_png(&png, width, height)?;
        Ok((width, height, png))
    }

    async fn eval_script(window: &WebviewWindow, script: &str) -> Result<Value, String> {
        let (sender, receiver) = oneshot::channel();
        let sender = Mutex::new(Some(sender));
        window
            .eval_with_callback(script.to_owned(), move |result| {
                if let Ok(mut sender) = sender.lock() {
                    if let Some(sender) = sender.take() {
                        let _ = sender.send(result);
                    }
                }
            })
            .map_err(|_| "screenshot_webview_script_failed".to_owned())?;
        let raw = tokio::time::timeout(CAPTURE_DEADLINE, receiver)
            .await
            .map_err(|_| "screenshot_capture_timeout".to_owned())?
            .map_err(|_| "screenshot_webview_callback_dropped".to_owned())?;
        parse_webview_json(&raw)
    }

    fn parse_webview_json(raw: &str) -> Result<Value, String> {
        let value: Value = serde_json::from_str(raw)
            .map_err(|_| "screenshot_webview_result_invalid".to_owned())?;
        match value {
            Value::String(serialized) => serde_json::from_str(&serialized)
                .map_err(|_| "screenshot_webview_result_invalid".to_owned()),
            value => Ok(value),
        }
    }

    async fn capture_page_screenshot(
        window: &WebviewWindow,
        parameters: Value,
    ) -> Result<Value, String> {
        let parameters = serde_json::to_string(&parameters)
            .map_err(|_| "screenshot_capture_invalid".to_owned())?;
        let method = "Page.captureScreenshot";
        let method_wide: Vec<u16> = method.encode_utf16().chain(std::iter::once(0)).collect();
        let parameters_wide: Vec<u16> = parameters
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        let (sender, receiver) = oneshot::channel::<Result<Value, String>>();
        let sender = Arc::new(Mutex::new(Some(sender)));
        let callback_sender = Arc::clone(&sender);
        let dispatch_sender = Arc::clone(&sender);
        let cancelled = Arc::new(AtomicBool::new(false));
        let callback_cancelled = Arc::clone(&cancelled);
        let _cancel_on_drop = CancelOutstandingCapture(Arc::clone(&cancelled));

        let dispatch = window.with_webview(move |platform| {
            let send = |result| {
                if let Ok(mut slot) = dispatch_sender.lock() {
                    if let Some(sender) = slot.take() {
                        let _ = sender.send(result);
                    }
                }
            };
            let core = match unsafe { platform.controller().CoreWebView2() } {
                Ok(core) => core,
                Err(_) => {
                    send(Err("screenshot_webview_unavailable".into()));
                    return;
                }
            };
            let handler =
                CallDevToolsProtocolMethodCompletedHandler::create(Box::new(move |status, raw| {
                    if callback_cancelled.load(Ordering::Acquire) {
                        return Ok(());
                    }
                    let result = status
                        .map_err(|_| "screenshot_capture_failed".to_owned())
                        .and_then(|_| {
                            serde_json::from_str(&raw)
                                .map_err(|_| "screenshot_capture_invalid".to_owned())
                        });
                    if let Ok(mut slot) = callback_sender.lock() {
                        if let Some(sender) = slot.take() {
                            let _ = sender.send(result);
                        }
                    }
                    Ok(())
                }));
            let method_pointer = PCWSTR::from_raw(method_wide.as_ptr());
            let parameters_pointer = PCWSTR::from_raw(parameters_wide.as_ptr());
            if unsafe {
                core.CallDevToolsProtocolMethod(method_pointer, parameters_pointer, &handler)
            }
            .is_err()
            {
                send(Err("screenshot_capture_failed".into()));
            }
        });
        if dispatch.is_err() {
            if let Ok(mut slot) = sender.lock() {
                if let Some(sender) = slot.take() {
                    let _ = sender.send(Err("screenshot_webview_unavailable".into()));
                }
            }
        }

        let result = tokio::time::timeout(CAPTURE_DEADLINE, receiver)
            .await
            .map_err(|_| {
                cancelled.store(true, Ordering::Release);
                "screenshot_capture_timeout".to_owned()
            })?
            .map_err(|_| "screenshot_capture_callback_dropped".to_owned())?;
        result
    }

    async fn choose_save_path(
        app: &AppHandle,
        window: &WebviewWindow,
        test_order: Option<&NativeWorkspaceScreenshotOrder>,
    ) -> Result<Option<PathBuf>, String> {
        if native_workspace_screenshot_test_enabled() {
            return test_order
                .map(|order| Some(order.image_path.clone()))
                .ok_or_else(|| "screenshot_test_order_unavailable".to_owned());
        }
        let (sender, receiver) = oneshot::channel();
        let file_name = format!("Next-workspace-{}.png", Local::now().format("%m%d-%H%M%S"));
        app.dialog()
            .file()
            .set_title("Save full workspace screenshot (PNG)")
            .set_parent(window)
            .set_can_create_directories(true)
            .set_file_name(file_name)
            .add_filter("PNG image", &["png"])
            .save_file(move |path| {
                let _ = sender.send(path);
            });
        let Some(path) = receiver
            .await
            .map_err(|_| "screenshot_save_dialog_failed".to_owned())?
        else {
            return Ok(None);
        };
        path.into_path()
            .map(Some)
            .map_err(|_| "screenshot_save_path_unavailable".into())
    }

    fn native_workspace_screenshot_test_enabled() -> bool {
        std::env::args().any(|argument| argument == "--codexu-native-capture-background")
            && std::env::var_os(NATIVE_WORKSPACE_SCREENSHOT_TEST_ENV)
                .is_some_and(|value| value == std::ffi::OsStr::new("1"))
    }

    fn native_workspace_screenshot_test_path() -> Result<PathBuf, String> {
        let capture_root = std::env::var_os(crate::capture_storage::ROOT_ENV)
            .map(PathBuf::from)
            .ok_or_else(|| "screenshot_test_capture_root_unavailable".to_owned())?
            .canonicalize()
            .map_err(|_| "screenshot_test_capture_root_unavailable".to_owned())?;
        if capture_root
            .file_name()
            .is_none_or(|name| name != "fullscreen")
            || capture_root
                .parent()
                .and_then(Path::file_name)
                .is_none_or(|name| name != "runtime")
        {
            return Err("screenshot_test_capture_root_invalid".into());
        }
        let path = capture_root.join("workspace-full.png");
        match std::fs::symlink_metadata(&path) {
            Ok(_) => return Err("screenshot_test_output_exists".into()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err("screenshot_test_output_unavailable".into()),
        }
        Ok(path)
    }

    fn save_png(
        path: &Path,
        png: &[u8],
        width: u32,
        height: u32,
        test_order: Option<&NativeWorkspaceScreenshotOrder>,
    ) -> Result<(), String> {
        if let Some(order) = test_order {
            order.require_restore_before_save(path)?;
        }
        validate_dimensions(width, height)?;
        require_png_path(path)?;
        if png.len() > MAX_PNG_BYTES {
            return Err("screenshot_png_too_large".into());
        }
        let parent = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .ok_or_else(|| "screenshot_save_path_unavailable".to_owned())?;
        let mut temporary = tempfile::NamedTempFile::new_in(parent)
            .map_err(|_| "screenshot_save_failed".to_owned())?;
        temporary
            .write_all(png)
            .and_then(|_| temporary.as_file().sync_all())
            .map_err(|_| "screenshot_save_failed".to_owned())?;
        temporary
            .persist(path)
            .map_err(|_| "screenshot_save_failed".to_owned())?;
        verify_saved_png(path, png, width, height)?;
        if let Some(order) = test_order {
            order.record_save_complete()?;
        }
        Ok(())
    }

    fn verify_saved_png(
        path: &Path,
        expected: &[u8],
        width: u32,
        height: u32,
    ) -> Result<(), String> {
        let mut file = File::open(path).map_err(|_| "screenshot_readback_failed".to_owned())?;
        if file
            .metadata()
            .map_err(|_| "screenshot_readback_failed".to_owned())?
            .len()
            != expected.len() as u64
        {
            return Err("screenshot_readback_mismatch".into());
        }
        let mut header = [0_u8; 24];
        file.read_exact(&mut header)
            .map_err(|_| "screenshot_readback_failed".to_owned())?;
        let mut tail = [0_u8; 12];
        file.seek(SeekFrom::End(-12))
            .and_then(|_| file.read_exact(&mut tail))
            .map_err(|_| "screenshot_readback_failed".to_owned())?;
        if header[..8] != *b"\x89PNG\r\n\x1a\n"
            || header[12..16] != *b"IHDR"
            || u32::from_be_bytes(
                header[16..20]
                    .try_into()
                    .map_err(|_| "screenshot_readback_failed")?,
            ) != width
            || u32::from_be_bytes(
                header[20..24]
                    .try_into()
                    .map_err(|_| "screenshot_readback_failed")?,
            ) != height
            || tail[4..8] != *b"IEND"
        {
            return Err("screenshot_readback_mismatch".into());
        }
        let expected_digest = Sha256::digest(expected);
        let mut actual_digest = Sha256::new();
        let mut buffer = [0_u8; 64 * 1024];
        file.seek(SeekFrom::Start(0))
            .map_err(|_| "screenshot_readback_failed".to_owned())?;
        loop {
            let count = file
                .read(&mut buffer)
                .map_err(|_| "screenshot_readback_failed".to_owned())?;
            if count == 0 {
                break;
            }
            actual_digest.update(&buffer[..count]);
        }
        if actual_digest.finalize() != expected_digest {
            return Err("screenshot_readback_mismatch".into());
        }
        Ok(())
    }
}

#[cfg(windows)]
use windows_capture::save_windows_workspace_screenshot;

#[cfg(test)]
mod tests {
    use super::{
        finish_screenshot_save, require_png_path, validate_dimensions, validate_png,
        NativeWorkspaceScreenshotOrder, WorkspaceScreenshotOutcome, WorkspaceScreenshotPermit,
        MAX_DIMENSION, MAX_RGBA_BYTES,
    };
    use std::path::Path;

    #[test]
    fn screenshot_dimensions_match_the_native_bounds() {
        assert!(validate_dimensions(1, 1).is_ok());
        assert!(validate_dimensions(MAX_DIMENSION, MAX_DIMENSION).is_err());
        assert!(validate_dimensions(0, 1).is_err());
        assert!(validate_dimensions(1, 0).is_err());
        assert!(u64::from(5_000_u32) * u64::from(6_400_u32) * 4 <= MAX_RGBA_BYTES);
        assert!(validate_dimensions(5_000, 6_400).is_ok());
        assert!(validate_dimensions(5_001, 6_400).is_err());
    }

    #[test]
    fn png_signature_and_full_page_dimensions_are_checked() {
        let width = 2_u32;
        let height = 3_u32;
        let png = {
            let mut bytes = Vec::new();
            {
                let mut encoder = png::Encoder::new(&mut bytes, width, height);
                encoder.set_color(png::ColorType::Rgba);
                encoder.set_depth(png::BitDepth::Eight);
                let mut writer = encoder.write_header().expect("write PNG header");
                writer
                    .write_image_data(&vec![255; (width * height * 4) as usize])
                    .expect("write PNG frame");
            }
            bytes
        };
        assert!(validate_png(&png, width, height).is_ok());
        assert!(validate_png(&png, width, height + 1).is_err());
        let mut invalid = png.clone();
        invalid[0] = 0;
        assert!(validate_png(&invalid, width, height).is_err());

        let without_idat = remove_png_chunk(&png, b"IDAT");
        assert!(validate_png(&without_idat, width, height).is_err());

        let mut bad_crc = png.clone();
        let idat_crc = png_chunk_crc_offset(&bad_crc, b"IDAT").expect("IDAT chunk");
        bad_crc[idat_crc..idat_crc + 4].fill(0);
        assert!(validate_png(&bad_crc, width, height).is_err());

        let without_iend = png[..png.len() - 12].to_vec();
        assert!(validate_png(&without_iend, width, height).is_err());
    }

    #[test]
    fn screenshot_capture_is_single_flight_and_releases_on_drop() {
        let first = WorkspaceScreenshotPermit::acquire().expect("first capture permit");
        assert!(WorkspaceScreenshotPermit::acquire().is_err());
        drop(first);
        assert!(WorkspaceScreenshotPermit::acquire().is_ok());
    }

    #[test]
    fn save_path_must_match_png_filter_selection() {
        assert!(require_png_path(Path::new("workspace.png")).is_ok());
        assert!(require_png_path(Path::new("workspace.PNG")).is_ok());
        assert!(require_png_path(Path::new("workspace")).is_err());
        assert!(require_png_path(Path::new("workspace.jpg")).is_err());
    }

    #[test]
    fn cancelled_save_never_invokes_writer_or_creates_a_file() {
        let temporary = tempfile::tempdir().expect("temporary directory");
        let output = temporary.path().join("workspace.png");
        let called = std::cell::Cell::new(false);
        let outcome = finish_screenshot_save(None, |_| {
            called.set(true);
            std::fs::write(&output, b"unexpected").map_err(|_| "screenshot_save_failed".to_owned())
        })
        .expect("cancellation is successful");
        assert_eq!(outcome, WorkspaceScreenshotOutcome::Cancelled);
        assert!(!called.get());
        assert!(!output.exists());
    }

    #[test]
    fn selected_save_uses_the_exact_confirmed_path() {
        let temporary = tempfile::tempdir().expect("temporary directory");
        let output = temporary.path().join("workspace.png");
        let outcome = finish_screenshot_save(Some(&output), |path| {
            std::fs::write(path, b"verified").map_err(|_| "screenshot_save_failed".to_owned())
        })
        .expect("selected path is saved");
        assert_eq!(outcome, WorkspaceScreenshotOutcome::Saved);
        assert_eq!(std::fs::read(&output).expect("saved path"), b"verified");
    }

    #[test]
    fn native_order_marker_requires_restore_before_save_and_records_both_events() {
        let temporary = tempfile::tempdir().expect("temporary directory");
        let image = temporary.path().join("workspace-full.png");
        let marker = temporary.path().join("workspace-order.txt");
        let order = NativeWorkspaceScreenshotOrder::create(image.clone(), marker.clone())
            .expect("create isolated order marker");

        assert!(order.require_restore_before_save(&image).is_err());
        order
            .record_restore_complete()
            .expect("record completed DOM restoration");
        assert!(order
            .require_restore_before_save(&temporary.path().join("other.png"))
            .is_err());
        order
            .require_restore_before_save(&image)
            .expect("allow the exact screenshot path only after restore");
        order
            .record_save_complete()
            .expect("record verified PNG save");
        order
            .verify_save_complete()
            .expect("verify complete native save order");
        assert_eq!(
            std::fs::read(&marker).expect("read order marker"),
            b"restored|saved"
        );
        assert!(NativeWorkspaceScreenshotOrder::create(image, marker).is_err());
    }

    fn remove_png_chunk(png: &[u8], target: &[u8; 4]) -> Vec<u8> {
        let mut output = png[..8].to_vec();
        let mut offset = 8;
        while offset + 12 <= png.len() {
            let length =
                u32::from_be_bytes(png[offset..offset + 4].try_into().expect("length")) as usize;
            let end = offset + 12 + length;
            assert!(end <= png.len(), "PNG chunk within input");
            let kind = &png[offset + 4..offset + 8];
            if kind != target {
                output.extend_from_slice(&png[offset..end]);
            }
            offset = end;
        }
        assert_eq!(offset, png.len(), "complete PNG chunks");
        output
    }

    fn png_chunk_crc_offset(png: &[u8], target: &[u8; 4]) -> Option<usize> {
        let mut offset = 8;
        while offset + 12 <= png.len() {
            let length = u32::from_be_bytes(png[offset..offset + 4].try_into().ok()?) as usize;
            let end = offset.checked_add(12)?.checked_add(length)?;
            if end > png.len() {
                return None;
            }
            if &png[offset + 4..offset + 8] == target {
                return Some(end - 4);
            }
            offset = end;
        }
        None
    }
}
