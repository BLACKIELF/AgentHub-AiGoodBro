//! Explicit channel setup/test actions. Real account/quota/task events enter
//! through the Rust-only NotificationService dispatcher, never arbitrary IPC.
use codexu_core::notifications::{
    ChannelKind, ChannelState, DeliveryReceipt, MessageOptions, NotificationService,
    PersonalLoginDto, PublicResetDeliveryState,
};
use std::sync::Arc;
use tauri::{AppHandle, Emitter, State};

pub struct NotificationState(pub Result<Arc<NotificationService>, &'static str>);
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
    run(state.manager()?, |m| m.states()).await
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
    let result = run(state.manager()?, |m| m.restore_saved_connections()).await;
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
