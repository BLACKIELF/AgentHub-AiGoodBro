use std::path::PathBuf;

use tauri::{AppHandle, Emitter, Manager, State};

use crate::app_state::{
    AppConfig, AppState, InterfaceLanguage, ResolvedLanguage, ThemeMode, TrayDensity,
};

#[derive(Debug, Clone, serde::Serialize)]
pub struct SettingsDto {
    /// Only expose presence to the WebView; the selected local paths stay in
    /// the Rust state and settings file rather than crossing the UI boundary.
    pub codex_root_configured: bool,
    pub cache_dir_configured: bool,
    pub theme: ThemeMode,
    pub palette_id: String,
    pub refresh_interval_secs: u64,
    pub tray_density: TrayDensity,
    pub language: InterfaceLanguage,
}

impl SettingsDto {
    fn from_config(config: &AppConfig) -> Self {
        Self {
            codex_root_configured: !config.codex_root.as_os_str().is_empty(),
            cache_dir_configured: !config.cache_dir.as_os_str().is_empty(),
            theme: config.theme,
            palette_id: config.palette_id.clone(),
            refresh_interval_secs: config.refresh_interval_secs,
            tray_density: config.tray_density,
            language: config.language,
        }
    }
}

#[tauri::command]
pub async fn open_settings_window(app: AppHandle) -> Result<(), String> {
    let app_state = app.state::<std::sync::Arc<AppState>>();
    let runtime_language = *app_state.runtime_language.read().await;

    if let Some(window) = app.get_webview_window("settings") {
        let _ = window.set_title(settings_window_title(runtime_language));
        let _ = window.show();
        let _ = window.set_focus();
        return Ok(());
    }

    let window =
        tauri::WebviewWindowBuilder::new(&app, "settings", tauri::WebviewUrl::App("/".into()))
            .title(settings_window_title(runtime_language))
            .inner_size(540.0, 680.0)
            .resizable(false)
            .maximizable(false)
            .minimizable(false)
            .center()
            .build()
            .map_err(|e| format!("Failed to create settings window: {}", e))?;

    let theme = {
        let config = app_state.config.read().await;
        config.theme
    };
    apply_theme(&app, theme);
    let _ = window.show();
    Ok(())
}

#[tauri::command]
pub async fn get_settings(
    state: State<'_, std::sync::Arc<AppState>>,
) -> Result<SettingsDto, String> {
    let config = state.config.read().await.clone();
    Ok(SettingsDto::from_config(&config))
}

#[derive(Debug, serde::Deserialize)]
pub struct UpdateSettingsRequest {
    pub codex_root: Option<PathBuf>,
    pub cache_dir: Option<PathBuf>,
    pub theme: Option<ThemeMode>,
    pub palette_id: Option<String>,
    pub refresh_interval_secs: Option<u64>,
    pub tray_density: Option<TrayDensity>,
    pub language: Option<InterfaceLanguage>,
}

#[tauri::command]
pub async fn set_settings(
    app: AppHandle,
    state: State<'_, std::sync::Arc<AppState>>,
    req: UpdateSettingsRequest,
) -> Result<SettingsDto, String> {
    if let Some(path) = req.codex_root.as_ref() {
        validate_settings_path("Codex data root", path)?;
    }
    if let Some(path) = req.cache_dir.as_ref() {
        validate_settings_path("Cache directory", path)?;
    }
    let source_changed = req.codex_root.is_some() || req.cache_dir.is_some();

    let config = state
        .update_config(|config| {
            if let Some(path) = req.codex_root {
                config.codex_root = path;
            }
            if let Some(path) = req.cache_dir {
                config.cache_dir = path;
            }
            if let Some(theme) = req.theme {
                config.theme = theme;
            }
            if let Some(palette_id) = req.palette_id {
                let palette_id = palette_id.trim();
                if !palette_id.is_empty() {
                    config.palette_id = palette_id.to_string();
                }
            }
            if let Some(interval) = req.refresh_interval_secs {
                config.refresh_interval_secs = interval.clamp(10, 3600);
            }
            if let Some(density) = req.tray_density {
                config.tray_density = density;
            }
            if let Some(language) = req.language {
                config.language = language;
            }
        })
        .await
        .map_err(|_| "Failed to save settings; prior settings retained".to_string())?;

    apply_theme(&app, config.theme);
    if config.language != InterfaceLanguage::Auto {
        let language = config.language.resolved(ResolvedLanguage::En);
        state.inner().set_runtime_language(language).await;
        apply_language(&app, language);
    }
    let dto = SettingsDto::from_config(&config);
    let _ = app.emit("settings:changed", dto.clone());
    if source_changed {
        let _ = app.emit("profiles:changed", ());
        let _ = app.emit("usage:source-changed", ());
    }
    Ok(dto)
}

fn validate_settings_path(label: &str, path: &PathBuf) -> Result<(), String> {
    if path.as_os_str().is_empty() {
        return Err(format!("{label} must not be empty"));
    }
    if !path.is_absolute() {
        return Err(format!("{label} must be an absolute path"));
    }
    Ok(())
}

#[tauri::command]
pub async fn sync_runtime_language(
    app: AppHandle,
    state: State<'_, std::sync::Arc<AppState>>,
    language: ResolvedLanguage,
) -> Result<(), String> {
    state.inner().set_runtime_language(language).await;
    apply_language(&app, language);
    Ok(())
}

pub fn apply_language(app: &AppHandle, language: ResolvedLanguage) {
    crate::tray::update_labels(app, language);
    update_window_titles(app, language);
}

pub fn update_window_titles(app: &AppHandle, language: ResolvedLanguage) {
    if let Some(window) = app.get_webview_window("settings") {
        let _ = window.set_title(settings_window_title(language));
    }
}

fn settings_window_title(language: ResolvedLanguage) -> &'static str {
    match language {
        ResolvedLanguage::ZhHans => "设置 — Codex Account Manager Next",
        ResolvedLanguage::En => "Settings — Codex Account Manager Next",
    }
}

fn apply_theme(app: &AppHandle, theme: ThemeMode) {
    let windows = app.webview_windows();
    let dark = match theme {
        ThemeMode::System => {
            // Frontend will detect system preference on load.
            return;
        }
        ThemeMode::Light => false,
        ThemeMode::Dark => true,
    };
    for (_, window) in windows {
        let _ = window.eval(&format!(
            "document.documentElement.classList.remove('dark'); if ({}) document.documentElement.classList.add('dark');",
            dark
        ));
        let _ = window.eval(&format!(
            "window.__CODEXU_THEME__ = '{}'",
            if dark { "dark" } else { "light" }
        ));
    }
}
