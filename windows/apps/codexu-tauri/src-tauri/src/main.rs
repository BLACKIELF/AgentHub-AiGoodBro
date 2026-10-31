// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::sync::Arc;

use tauri::Manager;
use tracing::info;

mod app_state;
mod capture_storage;
mod commands;
mod compact_projection;
mod compact_ui;
mod live_tasks;
mod managed_registration;
mod native_services;
mod quit;
mod quota_display;
mod statistics_sources;
mod tray;

use app_state::AppState;

const BACKGROUND_CAPTURE_ARGUMENT: &str = "--codexu-native-capture-background";

fn is_background_capture() -> bool {
    std::env::args().any(|argument| argument == BACKGROUND_CAPTURE_ARGUMENT)
}

#[cfg(windows)]
fn prepare_background_capture_window(window: &tauri::WebviewWindow) {
    use std::ffi::c_void;

    #[link(name = "user32")]
    extern "system" {
        fn GetWindowLongPtrW(hwnd: *mut c_void, index: i32) -> isize;
        fn SetWindowLongPtrW(hwnd: *mut c_void, index: i32, value: isize) -> isize;
    }

    const GWL_EXSTYLE: i32 = -20;
    const WS_EX_TOOLWINDOW: isize = 0x0000_0080;
    const WS_EX_NOACTIVATE: isize = 0x0800_0000;
    const WS_EX_APPWINDOW: isize = 0x0004_0000;

    let Ok(hwnd) = window.hwnd() else {
        return;
    };

    unsafe {
        let current = GetWindowLongPtrW(hwnd.0, GWL_EXSTYLE);
        let updated = (current | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE) & !WS_EX_APPWINDOW;
        let _ = SetWindowLongPtrW(hwnd.0, GWL_EXSTYLE, updated);
    }
}

#[cfg(windows)]
fn show_background_capture_window(window: &tauri::WebviewWindow) {
    use std::ffi::c_void;

    #[link(name = "user32")]
    extern "system" {
        fn SetWindowPos(
            hwnd: *mut c_void,
            insert_after: *mut c_void,
            x: i32,
            y: i32,
            width: i32,
            height: i32,
            flags: u32,
        ) -> i32;
        fn ShowWindow(hwnd: *mut c_void, command: i32) -> i32;
    }

    const HWND_BOTTOM: isize = -2;
    const SW_SHOWNOACTIVATE: i32 = 4;
    const SWP_NOSIZE: u32 = 0x0001;
    const SWP_NOMOVE: u32 = 0x0002;
    const SWP_NOACTIVATE: u32 = 0x0010;
    const SWP_NOOWNERZORDER: u32 = 0x0200;
    const SWP_FRAMECHANGED: u32 = 0x0020;
    const SWP_SHOWWINDOW: u32 = 0x0040;

    let Ok(hwnd) = window.hwnd() else {
        return;
    };

    unsafe {
        let insert_after = HWND_BOTTOM as *mut c_void;
        let flags = SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_FRAMECHANGED;
        let _ = SetWindowPos(hwnd.0, insert_after, 0, 0, 0, 0, flags);
        let _ = ShowWindow(hwnd.0, SW_SHOWNOACTIVATE);
        let _ = SetWindowPos(
            hwnd.0,
            insert_after,
            0,
            0,
            0,
            0,
            SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_SHOWWINDOW,
        );
    }
}

#[cfg(not(windows))]
fn prepare_background_capture_window(_window: &tauri::WebviewWindow) {}

#[cfg(not(windows))]
fn show_background_capture_window(_window: &tauri::WebviewWindow) {}

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    tauri::Builder::default()
        .manage(commands::app_update::UpdateRuntime::default())
        .manage(commands::cli_workflow::WorkflowState::default())
        .manage(commands::task_hub::HubState::default())
        .manage(quit::QuitState::default())
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let app_data_dir = match capture_storage::initialize(
                is_background_capture(),
                std::env::var_os(capture_storage::ROOT_ENV),
            )
            .map_err(std::io::Error::other)?
            {
                Some(root) => root,
                None => app.path().app_data_dir().map_err(|e| {
                    eprintln!("Failed to resolve app data dir: {}", e);
                    e
                })?,
            };
            // Keep user-specific storage locations out of runtime logs.
            info!("Next app data directory initialized");

            native_services::install(app, app_data_dir.clone())?;
            let state = Arc::new(AppState::new(app_data_dir.clone()));
            let initial_language = state
                .config
                .try_read()
                .map(|config| config.language.resolved(app_state::ResolvedLanguage::En))
                .unwrap_or(app_state::ResolvedLanguage::En);
            app.manage(state.clone());
            if let Err(code) = compact_ui::install(app.handle(), app_data_dir) {
                tracing::warn!(code, "Compact interface unavailable");
            } else {
                compact_projection::install(app.handle());
            }

            let background_capture = is_background_capture();

            // Hide main window to tray on close instead of quitting.
            if let Some(window) = app.get_webview_window("main") {
                if background_capture {
                    // Keep the capture window non-activating before revealing it.
                    // Calling Tauri's asynchronous `show` here can use an
                    // activating Win32 show path before z-order correction.
                    prepare_background_capture_window(&window);
                    show_background_capture_window(&window);
                } else {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
                let window_clone = window.clone();
                window.on_window_event(move |event| {
                    if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                        tray::hide_to_tray(&window_clone);
                        api.prevent_close();
                    }
                });
            }

            tray::setup_tray(app.handle(), initial_language)?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            live_tasks::get_live_task_state,
            live_tasks::reconnect_live_tasks,
            commands::automatic_switch::get_automatic_switch_preferences,
            commands::automatic_switch::set_automatic_switch_preferences,
            commands::automatic_switch::get_automatic_switch_status,
            commands::automatic_switch::evaluate_automatic_switch,
            commands::automatic_switch::cancel_automatic_switch,
            commands::cli_workflow::local_actions::get_local_cli_actions,
            commands::cli_workflow::local_actions::create_local_cli_profile,
            commands::cli_workflow::local_actions::start_local_cli,
            commands::cli_workflow::local_actions::get_local_cli_session,
            commands::cli_workflow::local_actions::stop_local_cli_session,
            commands::compact_ui::get_compact_ui_state,
            commands::compact_ui::retry_compact_ui_shortcut,
            commands::compact_ui::set_compact_ui_preferences,
            commands::compact_ui::compact_ui_action,
            commands::account_actions::get_account_local_details,
            commands::account_actions::get_account_browser_settings,
            commands::account_actions::set_account_browser_settings,
            commands::account_actions::refresh_account_local_details,
            commands::account_actions::set_account_pro_multiplier,
            commands::account_actions::begin_manual_reset_review,
            commands::account_actions::confirm_manual_reset_review,
            commands::account_actions::cancel_manual_reset_review,
            commands::account_actions::consume_manual_reset_credit,
            commands::account_actions::get_account_referral_eligibility,
            commands::account_actions::send_account_referral_invites,
            commands::account_actions::get_account_referral_tracking,
            commands::account_actions::check_account_referral_outcome,
            commands::account_lifecycle::list_managed_accounts,
            managed_registration::register_managed_account,
            commands::account_maintenance::get_account_maintenance_preferences,
            commands::account_maintenance::set_account_warmup_selection,
            commands::account_maintenance::set_reset_credit_auto_options,
            commands::account_maintenance::set_reset_credit_auto_authorization,
            commands::account_maintenance::get_account_maintenance_status,
            commands::account_maintenance::cancel_account_maintenance,
            commands::account_lifecycle::create_managed_account,
            commands::account_lifecycle::rename_managed_account,
            commands::account_metadata::reorder_managed_accounts,
            commands::account_lifecycle::remove_managed_account,
            commands::account_lifecycle::begin_account_login,
            commands::account_lifecycle::get_login_attempt,
            commands::account_lifecycle::open_account_login_page,
            commands::account_lifecycle::cancel_account_login,
            commands::account_lifecycle::prepare_account_switch,
            commands::account_lifecycle::commit_account_switch,
            commands::account_lifecycle::cancel_account_switch,
            commands::claude_swap::scan_claude_swap_candidates,
            commands::claude_swap::import_claude_swap_candidate,
            commands::account_lifecycle::list_claude_subscriptions,
            commands::account_lifecycle::rename_claude_subscription,
            commands::account_lifecycle::remove_claude_subscription,
            commands::account_lifecycle::begin_claude_subscription_login,
            commands::account_lifecycle::get_claude_subscription_login,
            commands::account_lifecycle::cancel_claude_subscription_login,
            commands::account_lifecycle::capture_claude_subscription,
            commands::account_lifecycle::prepare_claude_subscription_switch,
            commands::account_lifecycle::commit_claude_subscription_switch,
            commands::account_lifecycle::cancel_claude_subscription_switch,
            commands::account_lifecycle::read_claude_subscription_quota,
            commands::provider_pool::get_provider_pool,
            commands::provider_pool::start_provider_pool,
            commands::provider_pool::stop_provider_pool,
            commands::provider_pool::begin_provider_pool_authorization,
            commands::provider_pool::cancel_provider_pool_authorization,
            commands::provider_pool::set_provider_pool_enabled,
            commands::provider_pool::remove_provider_pool_account,
            commands::provider_pool::refresh_provider_pool_models,
            commands::provider_pool::copy_provider_pool_connection,
            commands::recommendations::get_recommendations,
            commands::recommendations::recheck_recommendations,
            commands::recommendations::set_recommendation_hidden,
            commands::recommendations::restore_recommendations,
            commands::recommendations::recommendation_action,
            commands::runtime_setup::inspect_runtime_setup,
            commands::runtime_setup::select_runtime_codex,
            commands::runtime_setup::open_codex_installation_guide,
            commands::local_proxy::get_local_proxy_status,
            commands::local_proxy::get_local_proxy_preferences,
            commands::local_proxy::set_local_proxy_preferences,
            commands::local_proxy::start_local_proxy,
            commands::local_proxy::stop_local_proxy,
            commands::local_proxy::get_local_proxy_connection,
            commands::local_proxy::local_proxy_network_command,
            commands::local_proxy::set_local_proxy_plus_five_hour_used_limit,
            commands::local_proxy::set_local_proxy_shared_quota_used_limit,
            commands::local_proxy::prepare_local_proxy_desktop,
            commands::local_proxy::launch_local_proxy_desktop,
            commands::local_proxy::connect_local_proxy_desktop,
            commands::local_proxy::get_local_proxy_desktop_status,
            commands::local_proxy::cancel_local_proxy_desktop,
            commands::proxy_accounts::get_local_proxy_accounts,
            commands::proxy_accounts::refresh_local_proxy_accounts,
            commands::token_monitor::get_token_monitor_state,
            commands::token_monitor::refresh_token_monitor_usage,
            commands::token_monitor::set_token_monitor_sources,
            commands::token_monitor::set_token_monitor_timezone,
            commands::token_monitor::cancel_token_monitor_usage,
            commands::notifications::get_notification_channels,
            commands::notifications::get_system_notification_state,
            commands::notifications::set_system_notifications_enabled,
            commands::notifications::open_system_notification_settings,
            commands::notifications::test_system_notification,
            commands::notifications::set_notification_channel_enabled,
            commands::notifications::save_notification_channel,
            commands::notifications::set_notification_channel_options,
            commands::notifications::forget_notification_channel,
            commands::notifications::restore_notification_channels,
            commands::notifications::cancel_notification_channel,
            commands::notifications::test_notification_channel,
            commands::notifications::begin_personal_wechat_login,
            commands::notifications::get_personal_wechat_login,
            commands::notifications::poll_personal_wechat_login,
            commands::notifications::refresh_personal_wechat_context,
            commands::notifications::get_public_reset_delivery_state,
            commands::notifications::set_public_reset_delivery_enabled,
            commands::notifications::request_public_reset_check,
            commands::app_update::get_app_update_state,
            commands::app_update::check_app_update,
            commands::app_update::download_app_update,
            commands::app_update::cancel_app_update,
            commands::app_update::open_app_update,
            commands::cli_workflow::get_account_workflow,
            commands::cli_workflow::dependency_actions::prepare_local_cli_dependency,
            commands::cli_workflow::dependency_actions::begin_local_cli_dependency,
            commands::cli_workflow::dependency_actions::get_local_cli_dependency,
            commands::cli_workflow::dependency_actions::cancel_local_cli_dependency,
            commands::cli_workflow::set_account_workflow,
            commands::cli_workflow::read_workflow_models,
            commands::cli_workflow::start_account_terminal,
            commands::cli_workflow::stop_account_terminal,
            commands::profiles::list_profiles,
            commands::profiles::list_platforms,
            commands::public_feed::read_public_feed,
            commands::profiles::update_profile,
            commands::profile_quota::read_profile_quota,
            commands::profile_quota::read_profile_local_quota,
            commands::usage::get_local_usage,
            commands::usage::refresh_usage,
            commands::usage::clear_cache,
            commands::settings::get_settings,
            commands::setup_context::get_setup_context,
            commands::setup_context::update_setup_onboarding,
            commands::settings::set_settings,
            commands::settings::open_settings_window,
            commands::settings::sync_runtime_language,
            commands::task_workbench::get_task_workbench,
            commands::task_workbench::import_task_workbench_inventory,
            commands::task_workbench::set_task_workbench_decision,
            commands::task_workbench::open_task_workbench_artifact,
            commands::personal_wechat_text::send_personal_wechat_text,
            commands::task_hub::get_task_hub,
            commands::task_hub::get_task_hub_messages,
            commands::task_hub::select_task_hub_workspace,
            commands::task_hub::connect_task_hub,
            commands::task_hub::task_hub_action,
            commands::task_hub::disconnect_task_hub,
            tray_show_main_window,
        ])
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app, event| {
            if let tauri::RunEvent::ExitRequested { api, .. } = event {
                if !app.state::<quit::QuitState>().confirmed()
                    && (commands::cli_workflow::should_block_exit(
                        &app.state::<commands::cli_workflow::WorkflowState>(),
                    ) || commands::task_hub::should_block_exit(
                        &app.state::<commands::task_hub::HubState>(),
                    ) || app
                        .state::<native_services::NativeServices>()
                        .proxy_blocks_normal_exit())
                {
                    api.prevent_exit();
                    if let Some(window) = app.get_webview_window("main") {
                        let _ = window.show();
                        let _ = window.set_focus();
                    }
                    quit::ask(app);
                }
            } else if let tauri::RunEvent::Exit = event {
                commands::task_hub::force_stop_owned(&app.state::<commands::task_hub::HubState>());
                compact_projection::shutdown(app);
                compact_ui::shutdown(app);
                app.state::<native_services::NativeServices>()
                    .cancel_monitor();
                app.state::<native_services::NativeServices>()
                    .stop_passive_services();
            }
        });
}

#[tauri::command]
fn tray_show_main_window(app: tauri::AppHandle) {
    tray::show_main_window(&app);
}
