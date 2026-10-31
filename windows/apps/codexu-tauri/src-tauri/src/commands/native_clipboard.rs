//! Native-only explicit copy; this module has no WebView command.
use tauri::AppHandle;
#[cfg(windows)]
use tauri::Manager;

pub(super) fn copy_text(app: &AppHandle, value: &str) -> Result<(), &'static str> {
    write(value, owner(app)?)
}

#[cfg(windows)]
pub(super) fn owner(app: &AppHandle) -> Result<usize, &'static str> {
    let window = app
        .get_webview_window("main")
        .ok_or("clipboard_unavailable")?;
    let handle = window.hwnd().map_err(|_| "clipboard_unavailable")?.0 as usize;
    if handle == 0 {
        return Err("clipboard_unavailable".into());
    }
    Ok(handle)
}
#[cfg(not(windows))]
pub(super) fn owner(_: &AppHandle) -> Result<usize, &'static str> {
    Err("clipboard_unavailable".into())
}
#[cfg(windows)]
pub(super) fn write(value: &str, owner: usize) -> Result<(), &'static str> {
    use std::ffi::c_void;
    #[link(name = "user32")]
    unsafe extern "system" {
        fn OpenClipboard(window: *mut c_void) -> i32;
        fn CloseClipboard() -> i32;
        fn EmptyClipboard() -> i32;
        fn SetClipboardData(format: u32, memory: *mut c_void) -> *mut c_void;
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GlobalAlloc(flags: u32, bytes: usize) -> *mut c_void;
        fn GlobalFree(memory: *mut c_void) -> *mut c_void;
        fn GlobalLock(memory: *mut c_void) -> *mut c_void;
        fn GlobalUnlock(memory: *mut c_void) -> i32;
    }
    let error = || "clipboard_unavailable";
    if value.len() > 65536 || value.contains('\0') || owner == 0 {
        return Err(error());
    }
    let encoded: Vec<u16> = value.encode_utf16().chain(Some(0)).collect();
    // Allocate and fill before EmptyClipboard so allocation errors preserve it.
    unsafe {
        let memory = GlobalAlloc(0x0002, encoded.len() * 2);
        if memory.is_null() {
            return Err(error());
        }
        let data = GlobalLock(memory);
        if data.is_null() {
            GlobalFree(memory);
            return Err(error());
        }
        std::ptr::copy_nonoverlapping(encoded.as_ptr(), data.cast::<u16>(), encoded.len());
        GlobalUnlock(memory);
        if OpenClipboard(owner as *mut c_void) == 0 {
            GlobalFree(memory);
            return Err(error());
        }
        let ok = EmptyClipboard() != 0 && !SetClipboardData(13, memory).is_null();
        CloseClipboard();
        if !ok {
            GlobalFree(memory);
            return Err(error());
        }
    }
    Ok(())
}
#[cfg(not(windows))]
pub(super) fn write(_: &str, _: usize) -> Result<(), &'static str> {
    Err("clipboard_unavailable")
}
