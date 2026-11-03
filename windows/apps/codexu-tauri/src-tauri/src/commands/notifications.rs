//! Explicit channel setup/test actions. Real account/quota/task events enter
//! through the Rust-only NotificationService dispatcher, never arbitrary IPC.
use codexu_core::notifications::{
    ChannelKind, ChannelState, DeliveryReceipt, MessageOptions, NotificationService,
    PersonalLoginDto, PublicResetDeliveryState,
};
use std::sync::Arc;
use tauri::{AppHandle, Emitter, State};

pub struct NotificationState(pub Result<Arc<NotificationService>, &'static str>);

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SystemNotificationStateDto {
    enabled: bool,
    permission: codexu_core::notifications::SystemNotificationPermission,
    phase: &'static str,
    last_accepted_at: Option<i64>,
    failure_code: Option<&'static str>,
}
fn local_state(
    manager: &NotificationService,
) -> codexu_core::notifications::Result<SystemNotificationStateDto> {
    let state = manager.channel_state(ChannelKind::System)?;
    let permission = manager.system_permission();
    Ok(SystemNotificationStateDto {
        enabled: state.enabled,
        permission,
        phase: if !state.enabled {
            "disabled"
        } else if permission == codexu_core::notifications::SystemNotificationPermission::Enabled {
            "enabled"
        } else {
            "blocked"
        },
        last_accepted_at: state.last_accepted_at,
        failure_code: state.failure_code,
    })
}
#[tauri::command]
pub async fn get_system_notification_state(
    state: State<'_, NotificationState>,
) -> Result<SystemNotificationStateDto, String> {
    run(state.manager()?, |m| local_state(&m)).await
}
#[tauri::command]
pub async fn set_system_notifications_enabled(
    app: AppHandle,
    state: State<'_, NotificationState>,
    enabled: bool,
) -> Result<SystemNotificationStateDto, String> {
    let result = run(state.manager()?, move |m| {
        m.set_enabled(ChannelKind::System, enabled)?;
        local_state(&m)
    })
    .await;
    changed(&app);
    result
}
#[tauri::command]
pub async fn test_system_notification(
    app: AppHandle,
    state: State<'_, NotificationState>,
) -> Result<DeliveryReceipt, String> {
    let result = run(state.manager()?, |m| m.send_test(ChannelKind::System)).await;
    changed(&app);
    result
}
#[tauri::command]
pub async fn open_system_notification_settings(
    state: State<'_, NotificationState>,
) -> Result<SystemNotificationStateDto, String> {
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
        let verb = "open\0".encode_utf16().collect::<Vec<_>>();
        let target = "ms-settings:notifications\0"
            .encode_utf16()
            .collect::<Vec<_>>();
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
            return Err("system_notification_settings_unavailable".into());
        }
    }
    #[cfg(not(windows))]
    {
        return Err("system_notification_settings_unavailable".into());
    }
    #[cfg(windows)]
    run(state.manager()?, |m| local_state(&m)).await
}
impl NotificationState {
    pub fn manager(&self) -> Result<Arc<NotificationService>, String> {
        self.0
            .as_ref()
            .cloned()
            .map_err(|_| "Notification service unavailable".into())
    }
}
async fn run<T: Send + 'static>(
    manager: Arc<NotificationService>,
    f: impl FnOnce(Arc<NotificationService>) -> codexu_core::notifications::Result<T> + Send + 'static,
) -> Result<T, String> {
    tokio::task::spawn_blocking(move || f(manager).map_err(|e| e.code().to_owned()))
        .await
        .map_err(|_| "notification_operation_failed".to_owned())?
}
fn changed(app: &AppHandle) {
    let _ = app.emit("notification-channels:changed", ());
}
#[tauri::command]
pub async fn get_public_reset_delivery_state(
    state: State<'_, NotificationState>,
) -> Result<PublicResetDeliveryState, String> {
    run(state.manager()?, |m| m.public_reset_delivery_state()).await
}
#[tauri::command]
pub async fn set_public_reset_delivery_enabled(
    app: AppHandle,
    state: State<'_, NotificationState>,
    enabled: bool,
) -> Result<PublicResetDeliveryState, String> {
    let result = run(state.manager()?, move |m| {
        m.set_public_reset_delivery_enabled(enabled)
    })
    .await;
    changed(&app);
    result
}
#[tauri::command]
pub async fn request_public_reset_check(
    app: AppHandle,
    state: State<'_, NotificationState>,
) -> Result<PublicResetDeliveryState, String> {
    let result = run(state.manager()?, |m| m.request_public_reset_check()).await;
    changed(&app);
    result
}

#[tauri::command]
pub async fn get_notification_channels(
    state: State<'_, NotificationState>,
) -> Result<Vec<ChannelState>, String> {
    run(state.manager()?, |m| {
        Ok(m.states()?
            .into_iter()
            .filter(|s| s.channel != ChannelKind::System)
            .collect())
    })
    .await
}
#[tauri::command]
pub async fn set_notification_channel_enabled(
    app: AppHandle,
    state: State<'_, NotificationState>,
    channel: ChannelKind,
    enabled: bool,
) -> Result<ChannelState, String> {
    let result = run(state.manager()?, move |m| m.set_enabled(channel, enabled)).await;
    changed(&app);
    result
}
#[tauri::command]
pub async fn save_notification_channel(
    app: AppHandle,
    state: State<'_, NotificationState>,
    channel: ChannelKind,
    secret: String,
    target: Option<String>,
) -> Result<ChannelState, String> {
    let result = run(state.manager()?, move |m| {
        m.save_channel(channel, secret, target)
    })
    .await;
    changed(&app);
    result
}
#[tauri::command]
pub async fn set_notification_channel_options(
    app: AppHandle,
    state: State<'_, NotificationState>,
    channel: ChannelKind,
    options: MessageOptions,
) -> Result<ChannelState, String> {
    let result = run(state.manager()?, move |m| m.set_options(channel, options)).await;
    changed(&app);
    result
}
#[tauri::command]
pub async fn forget_notification_channel(
    app: AppHandle,
    state: State<'_, NotificationState>,
    channel: ChannelKind,
) -> Result<ChannelState, String> {
    let result = run(state.manager()?, move |m| m.forget_channel(channel)).await;
    changed(&app);
    result
}
#[tauri::command]
pub async fn restore_notification_channels(
    app: AppHandle,
    state: State<'_, NotificationState>,
) -> Result<Vec<ChannelState>, String> {
    let result = run(state.manager()?, |m| {
        Ok(m.restore_saved_connections()?
            .into_iter()
            .filter(|s| s.channel != ChannelKind::System)
            .collect())
    })
    .await;
    changed(&app);
    result
}
#[tauri::command]
pub async fn cancel_notification_channel(
    app: AppHandle,
    state: State<'_, NotificationState>,
    channel: ChannelKind,
) -> Result<ChannelState, String> {
    let result = run(state.manager()?, move |m| m.cancel_channel(channel)).await;
    changed(&app);
    result
}
#[tauri::command]
pub async fn test_notification_channel(
    app: AppHandle,
    state: State<'_, NotificationState>,
    channel: ChannelKind,
) -> Result<DeliveryReceipt, String> {
    let result = run(state.manager()?, move |m| m.send_test(channel)).await;
    changed(&app);
    result
}
#[tauri::command]
pub async fn begin_personal_wechat_login(
    app: AppHandle,
    state: State<'_, NotificationState>,
) -> Result<PersonalLoginDto, String> {
    let result = run(state.manager()?, |m| m.begin_personal_wechat_login()).await;
    changed(&app);
    result
}
#[tauri::command]
pub async fn get_personal_wechat_login(
    state: State<'_, NotificationState>,
    attempt_id: String,
) -> Result<PersonalLoginDto, String> {
    run(state.manager()?, move |m| {
        m.personal_wechat_login(&attempt_id)
    })
    .await
}
#[tauri::command]
pub async fn poll_personal_wechat_login(
    app: AppHandle,
    state: State<'_, NotificationState>,
    attempt_id: String,
    verification_code: Option<String>,
) -> Result<PersonalLoginDto, String> {
    let result = run(state.manager()?, move |m| {
        m.poll_personal_wechat_login(&attempt_id, verification_code)
    })
    .await;
    changed(&app);
    result
}
#[tauri::command]
pub async fn refresh_personal_wechat_context(
    app: AppHandle,
    state: State<'_, NotificationState>,
) -> Result<ChannelState, String> {
    let result = run(state.manager()?, |m| m.refresh_personal_wechat_context()).await;
    changed(&app);
    result
}
