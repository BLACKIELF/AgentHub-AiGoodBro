use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager};

use crate::app_state::ResolvedLanguage;
use crate::commands::token_monitor::{refresh_token_monitor_usage, TokenMonitorAppState};

struct TrayMenu {
    open: MenuItem<tauri::Wry>,
    settings: MenuItem<tauri::Wry>,
    refresh: MenuItem<tauri::Wry>,
    quit: MenuItem<tauri::Wry>,
}

struct TrayLabels {
    open: &'static str,
    settings: &'static str,
    refresh: &'static str,
    quit: &'static str,
}

pub fn setup_tray(app: &AppHandle, language: ResolvedLanguage) -> anyhow::Result<()> {
    let labels = labels_for(language);
    let open_i = MenuItem::with_id(app, "open", labels.open, true, None::<&str>)?;
    let settings_i = MenuItem::with_id(app, "settings", labels.settings, true, None::<&str>)?;
    let refresh_i = MenuItem::with_id(app, "refresh", labels.refresh, true, None::<&str>)?;
    let separator = PredefinedMenuItem::separator(app)?;
    let quit_i = MenuItem::with_id(app, "quit", labels.quit, true, None::<&str>)?;

    let menu = Menu::with_items(
        app,
        &[&open_i, &settings_i, &refresh_i, &separator, &quit_i],
    )?;

    app.manage(TrayMenu {
        open: open_i.clone(),
        settings: settings_i.clone(),
        refresh: refresh_i.clone(),
        quit: quit_i.clone(),
    });

    TrayIconBuilder::new()
        .icon(app.default_window_icon().unwrap().clone())
        .tooltip("AiGoodBro")
        .menu(&menu)
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                ..
            } = event
            {
                show_main_window(tray.app_handle());
            }
        })
        .on_menu_event(|app, event| match event.id.as_ref() {
            "open" => show_main_window(app),
            "settings" => {
                let app = app.clone();
                tauri::async_runtime::spawn(async move {
                    let _ = crate::commands::settings::open_settings_window(app).await;
                });
            }
            "refresh" => {
                let app = app.clone();
                tauri::async_runtime::spawn(async move {
                    let state = app.state::<std::sync::Arc<crate::app_state::AppState>>();
                    let statistics = app.state::<TokenMonitorAppState>();
                    let native = app.state::<crate::native_services::NativeServices>();
                    let _ = refresh_token_monitor_usage(statistics, state, native).await;
                });
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .build(app)?;

    Ok(())
}

pub fn update_labels(app: &AppHandle, language: ResolvedLanguage) {
    let labels = labels_for(language);
    if let Some(menu) = app.try_state::<TrayMenu>() {
        let _ = menu.open.set_text(labels.open);
        let _ = menu.settings.set_text(labels.settings);
        let _ = menu.refresh.set_text(labels.refresh);
        let _ = menu.quit.set_text(labels.quit);
    }
}

fn labels_for(language: ResolvedLanguage) -> TrayLabels {
    match language {
        ResolvedLanguage::ZhHans => TrayLabels {
            open: "打开仪表盘",
            settings: "设置",
            refresh: "刷新",
            quit: "退出",
        },
        ResolvedLanguage::En => TrayLabels {
            open: "Open Dashboard",
            settings: "Settings",
            refresh: "Refresh",
            quit: "Quit",
        },
    }
}

pub fn show_main_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.set_focus();
    } else {
        let _ = tauri::WebviewWindowBuilder::from_config(
            app,
            &app.config()
                .app
                .windows
                .first()
                .cloned()
                .unwrap_or_default(),
        )
        .unwrap_or_else(|_| panic!("Failed to create main window"))
        .build();
    }
}

pub fn hide_to_tray(window: &tauri::WebviewWindow) {
    let _ = window.hide();
}
