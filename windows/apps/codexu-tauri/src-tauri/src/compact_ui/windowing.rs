use super::{
    geometry::Rect,
    model::{Display, Surface},
};
use tauri::{AppHandle, Manager, PhysicalPosition, PhysicalSize, WebviewWindow};
#[derive(Clone)]
pub struct Screen {
    pub display: Display,
    pub bounds: Rect,
    pub work: Rect,
    pub dpi: f64,
}
fn display_id(value: &str) -> String {
    let mut hash = 0xcbf29ce484222325u64;
    for byte in value.bytes() {
        hash ^= byte as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("display-{hash:016x}")
}
pub fn screens(app: &AppHandle) -> Result<Vec<Screen>, &'static str> {
    let primary = app
        .primary_monitor()
        .map_err(|_| "compact_display_unavailable")?;
    let monitors = app
        .available_monitors()
        .map_err(|_| "compact_display_unavailable")?;
    let mut result = vec![];
    let mut ids = std::collections::BTreeSet::new();
    for (index, monitor) in monitors.into_iter().enumerate() {
        let name = monitor.name().cloned().unwrap_or_else(|| {
            format!("unnamed-{}-{}", monitor.position().x, monitor.position().y)
        });
        let id = display_id(&monitor_identity(&name)?);
        if !ids.insert(id.clone()) {
            return Err("compact_display_identity_unknown");
        }
        let area = monitor.work_area();
        let dpi = monitor.scale_factor();
        if !dpi.is_finite() || dpi <= 0. || area.size.width == 0 || area.size.height == 0 {
            return Err("compact_display_unavailable");
        }
        let is_primary = primary.as_ref().is_some_and(|value| {
            value.position() == monitor.position() && value.size() == monitor.size()
        });
        result.push(Screen {
            display: Display {
                id,
                label: format!(
                    "{} · {}×{}",
                    index + 1,
                    monitor.size().width,
                    monitor.size().height
                ),
                is_primary,
                available: true,
            },
            bounds: Rect {
                x: monitor.position().x as f64,
                y: monitor.position().y as f64,
                width: monitor.size().width as f64,
                height: monitor.size().height as f64,
            },
            work: Rect {
                x: area.position.x as f64,
                y: area.position.y as f64,
                width: area.size.width as f64,
                height: area.size.height as f64,
            },
            dpi,
        });
    }
    Ok(result)
}
pub fn ensure(app: &AppHandle, surface: Surface) -> Result<(WebviewWindow, bool), &'static str> {
    if let Some(window) = app.get_webview_window(surface.label()) {
        return Ok((window, false));
    }
    #[cfg(not(windows))]
    {
        let _ = surface;
        return Err("windows_required");
    }
    #[cfg(windows)]
    {
        let window = tauri::WebviewWindowBuilder::new(
            app,
            surface.label(),
            tauri::WebviewUrl::App("/".into()),
        )
        .title("AiGoodBro · Token Monitor")
        .inner_size(420., 640.)
        .visible(false)
        .focused(false)
        .focusable(surface == Surface::Popover)
        .decorations(false)
        .transparent(true)
        .skip_taskbar(true)
        .resizable(false)
        .maximizable(false)
        .minimizable(false)
        .always_on_top(surface != Surface::Popover)
        .shadow(matches!(surface, Surface::Popover | Surface::EdgeCard))
        .build()
        .map_err(|_| "compact_window_unavailable")?;
        Ok((window, true))
    }
}
pub fn place(window: &WebviewWindow, rect: Rect) -> Result<(), &'static str> {
    if ![rect.x, rect.y, rect.width, rect.height]
        .into_iter()
        .all(f64::is_finite)
        || rect.width < 1.
        || rect.height < 1.
    {
        return Err("compact_geometry_invalid");
    }
    let position = PhysicalPosition::new(rect.x.round() as i32, rect.y.round() as i32);
    let size = PhysicalSize::new(rect.width.round() as u32, rect.height.round() as u32);
    // Avoid producing another WM_DPICHANGED/resize cycle for an unchanged plan.
    if window
        .outer_position()
        .map_err(|_| "compact_window_unavailable")?
        != position
    {
        window
            .set_position(position)
            .map_err(|_| "compact_window_unavailable")?;
    }
    if window
        .inner_size()
        .map_err(|_| "compact_window_unavailable")?
        != size
    {
        window
            .set_size(size)
            .map_err(|_| "compact_window_unavailable")?;
    }
    if window
        .outer_position()
        .map_err(|_| "compact_window_unavailable")?
        != position
        || window
            .inner_size()
            .map_err(|_| "compact_window_unavailable")?
            != size
    {
        return Err("compact_geometry_unconfirmed");
    }
    Ok(())
}
pub fn set_visible(window: &WebviewWindow, visible: bool) -> Result<bool, &'static str> {
    let before = window
        .is_visible()
        .map_err(|_| "compact_window_unavailable")?;
    if before != visible {
        if visible {
            show_without_activation(window)?;
        } else {
            window.hide().map_err(|_| "compact_window_unavailable")?;
        }
    }
    let actual = window
        .is_visible()
        .map_err(|_| "compact_window_unavailable")?;
    if actual != visible {
        return Err("compact_visibility_unconfirmed");
    }
    Ok(actual)
}

fn show_without_activation(window: &WebviewWindow) -> Result<(), &'static str> {
    #[cfg(windows)]
    if Surface::from_label(window.label()).is_some_and(|surface| surface != Surface::Popover) {
        #[link(name = "user32")]
        extern "system" {
            fn ShowWindow(window: *mut std::ffi::c_void, command: i32) -> i32;
        }
        let hwnd = window.hwnd().map_err(|_| "compact_window_unavailable")?.0;
        // SW_SHOWNOACTIVATE; edge windows must not steal the foreground app.
        unsafe {
            ShowWindow(hwnd as *mut std::ffi::c_void, 4);
        }
        return Ok(());
    }
    window.show().map_err(|_| "compact_window_unavailable")
}

fn monitor_identity(name: &str) -> Result<String, &'static str> {
    #[cfg(not(windows))]
    {
        Ok(name.to_owned())
    }
    #[cfg(windows)]
    {
        #[repr(C)]
        struct Device {
            size: u32,
            name: [u16; 32],
            description: [u16; 128],
            flags: u32,
            id: [u16; 128],
            key: [u16; 128],
        }
        #[link(name = "user32")]
        extern "system" {
            fn EnumDisplayDevicesW(
                name: *const u16,
                index: u32,
                device: *mut Device,
                flags: u32,
            ) -> i32;
        }
        let name = name.encode_utf16().chain(Some(0)).collect::<Vec<_>>();
        let mut device: Device = unsafe { std::mem::zeroed() };
        device.size = std::mem::size_of::<Device>() as u32;
        // EDD_GET_DEVICE_INTERFACE_NAME: preserve the physical monitor identity
        // across reconnects instead of trusting the reassignable DISPLAY1 name.
        if unsafe { EnumDisplayDevicesW(name.as_ptr(), 0, &mut device, 1) } == 0 {
            return Err("compact_display_identity_unknown");
        }
        let length = device
            .id
            .iter()
            .position(|value| *value == 0)
            .unwrap_or(device.id.len());
        let identity = String::from_utf16(&device.id[..length])
            .map_err(|_| "compact_display_identity_unknown")?;
        if identity.is_empty() {
            return Err("compact_display_identity_unknown");
        }
        Ok(identity.to_ascii_lowercase())
    }
}
pub fn left_button_down() -> bool {
    #[cfg(windows)]
    {
        #[link(name = "user32")]
        extern "system" {
            fn GetAsyncKeyState(key: i32) -> i16;
        }
        unsafe { GetAsyncKeyState(1) < 0 }
    }
    #[cfg(not(windows))]
    {
        false
    }
}

/// Event-driven reconnection while the saved target display is absent. This
/// subclasses only our own window and schedules work outside the UI callback.
pub fn install_display_listener(
    window: &WebviewWindow,
    callback: std::sync::Arc<dyn Fn() + Send + Sync>,
) -> Result<(), &'static str> {
    #[cfg(not(windows))]
    {
        let _ = (window, callback);
        Err("windows_required")
    }
    #[cfg(windows)]
    {
        let hwnd = window
            .hwnd()
            .map_err(|_| "compact_display_events_unavailable")?
            .0 as usize;
        let (sent, received) = std::sync::mpsc::sync_channel(1);
        window
            .run_on_main_thread(move || {
                type Callback = std::sync::Arc<dyn Fn() + Send + Sync>;
                let pointer = Box::into_raw(Box::new(callback));
                let success = unsafe {
                    display_messages::SetWindowSubclass(
                        hwnd as *mut std::ffi::c_void,
                        Some(display_messages::callback),
                        display_messages::ID,
                        pointer as usize,
                    )
                } != 0;
                if !success {
                    unsafe {
                        drop(Box::from_raw(pointer as *mut Callback));
                    }
                }
                let _ = sent.send(success);
            })
            .map_err(|_| "compact_display_events_unavailable")?;
        match received.recv_timeout(std::time::Duration::from_secs(2)) {
            Ok(true) => Ok(()),
            _ => Err("compact_display_events_unavailable"),
        }
    }
}
#[cfg(windows)]
mod display_messages {
    use std::{ffi::c_void, sync::Arc};
    pub const ID: usize = 0x41474231;
    type Proc = unsafe extern "system" fn(*mut c_void, u32, usize, isize, usize, usize) -> isize;
    #[link(name = "comctl32")]
    extern "system" {
        pub fn SetWindowSubclass(
            window: *mut c_void,
            proc: Option<Proc>,
            id: usize,
            data: usize,
        ) -> i32;
        fn RemoveWindowSubclass(window: *mut c_void, proc: Option<Proc>, id: usize) -> i32;
        fn DefSubclassProc(
            window: *mut c_void,
            message: u32,
            wparam: usize,
            lparam: isize,
        ) -> isize;
    }
    pub unsafe extern "system" fn callback(
        window: *mut c_void,
        message: u32,
        wparam: usize,
        lparam: isize,
        id: usize,
        data: usize,
    ) -> isize {
        if message == 0x0082 {
            // WM_NCDESTROY: release only this registration's callback.
            RemoveWindowSubclass(window, Some(callback), id);
            drop(Box::from_raw(data as *mut Arc<dyn Fn() + Send + Sync>));
        } else if matches!(message, 0x007e | 0x02e0 | 0x001a) {
            // WM_DISPLAYCHANGE / WM_DPICHANGED / WM_SETTINGCHANGE. The last
            // includes work-area/taskbar changes even without a resolution change.
            let notify = Arc::clone(&*(data as *const Arc<dyn Fn() + Send + Sync>));
            // Let Tao apply the DPI message's suggested rectangle first. A
            // worker racing that default handler could otherwise be undone by it.
            let result = DefSubclassProc(window, message, wparam, lparam);
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| notify()));
            return result;
        }
        DefSubclassProc(window, message, wparam, lparam)
    }
}
