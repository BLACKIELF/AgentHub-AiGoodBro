//! One explicitly confirmed text to the already paired personal-WeChat target.
//! This endpoint cannot select a URL, recipient, channel or credential.
use super::notifications::NotificationState;
use codexu_core::notifications::PersonalTextReceipt;
use tauri::{AppHandle, Emitter, State};

#[tauri::command]
pub async fn send_personal_wechat_text(
    app: AppHandle,
    state: State<'_, NotificationState>,
    request_id: String,
    expected_revision: u64,
    text: String,
    confirmed: bool,
) -> Result<PersonalTextReceipt, String> {
    let manager = state.manager()?;
    let result = tauri::async_runtime::spawn_blocking(move || {
        manager.send_personal_wechat_text(&request_id, expected_revision, &text, confirmed)
    })
    .await
    .map_err(|_| "notification_unavailable".to_owned())?
    .map_err(|error| error.code().to_owned());
    let _ = app.emit("notification-channels:changed", ());
    result
}
