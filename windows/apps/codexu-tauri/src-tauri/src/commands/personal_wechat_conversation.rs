//! Explicit consent to relay paired WeChat messages through one selected
//! original Codex chat. Only binding state crosses the WebView boundary.
use super::notifications::NotificationState;
use codexu_core::notifications::{PersonalConversationTarget, PersonalWeChatConversationState};
use tauri::{AppHandle, Emitter, State};

#[tauri::command]
pub async fn get_personal_wechat_conversation_state(
    state: State<'_, NotificationState>,
) -> Result<PersonalWeChatConversationState, String> {
    let manager = state.manager()?;
    tauri::async_runtime::spawn_blocking(move || manager.personal_conversation_state())
        .await
        .map_err(|_| "notification_unavailable".to_owned())?
        .map_err(|error| error.code().to_owned())
}

#[tauri::command]
pub async fn bind_personal_wechat_conversation(
    app: AppHandle,
    state: State<'_, NotificationState>,
    expected_revision: u64,
    expected_scope_id: String,
    thread_id: String,
    confirmed: bool,
) -> Result<PersonalWeChatConversationState, String> {
    let manager = state.manager()?;
    let result = manager
        .bind_personal_conversation(
            expected_revision,
            PersonalConversationTarget {
                expected_scope_id,
                thread_id,
            },
            confirmed,
        )
        .await
        .map_err(|error| error.code().to_owned());
    let _ = app.emit("notification-channels:changed", ());
    result
}

#[tauri::command]
pub async fn set_personal_wechat_conversation_enabled(
    app: AppHandle,
    state: State<'_, NotificationState>,
    expected_revision: u64,
    enabled: bool,
) -> Result<PersonalWeChatConversationState, String> {
    let manager = state.manager()?;
    let result = tauri::async_runtime::spawn_blocking(move || {
        manager.set_personal_conversation_enabled(expected_revision, enabled)
    })
    .await
    .map_err(|_| "notification_unavailable".to_owned())?
    .map_err(|error| error.code().to_owned());
    let _ = app.emit("notification-channels:changed", ());
    result
}

#[tauri::command]
pub async fn unbind_personal_wechat_conversation(
    app: AppHandle,
    state: State<'_, NotificationState>,
    expected_revision: u64,
) -> Result<PersonalWeChatConversationState, String> {
    let manager = state.manager()?;
    let result = tauri::async_runtime::spawn_blocking(move || {
        manager.unbind_personal_conversation(expected_revision)
    })
    .await
    .map_err(|_| "notification_unavailable".to_owned())?
    .map_err(|error| error.code().to_owned());
    let _ = app.emit("notification-channels:changed", ());
    result
}
