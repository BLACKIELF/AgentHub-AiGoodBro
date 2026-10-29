//! Managed-account actions. Linked profiles retain their existing metadata-only
//! semantics. No command accepts a credential, arbitrary home or process ID.
use codexu_core::accounts::claude::{
    ClaudeLoginAttemptDto, ClaudeSubscriptionDto, ClaudeSubscriptionManager,
    ClaudeSubscriptionQuotaDto,
};
use codexu_core::accounts::{
    AccountManager, AccountOperationDto, AccountResult, LoginAttemptDto, ManagedAccountDto,
    PreparedSwitchDto,
};
use std::sync::Arc;
use tauri::{AppHandle, Emitter, Manager, State};

/// Initialization errors remain visible to management commands without taking
/// unrelated linked-profile/dashboard functionality down or creating a fake store.
pub struct ManagedAccountState(pub Result<Arc<AccountManager>, &'static str>);
pub struct ClaudeSubscriptionState(pub Result<Arc<ClaudeSubscriptionManager>, &'static str>);
impl ClaudeSubscriptionState {
    pub fn manager(&self) -> Result<Arc<ClaudeSubscriptionManager>, String> {
        self.0.clone().map_err(str::to_owned)
    }
}
impl ManagedAccountState {
    pub fn manager(&self) -> Result<Arc<AccountManager>, String> {
        self.0.clone().map_err(str::to_owned)
    }
}

async fn blocking<T: Send + 'static>(
    manager: Arc<AccountManager>,
    action: impl FnOnce(Arc<AccountManager>) -> AccountResult<T> + Send + 'static,
) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(move || action(manager))
        .await
        .map_err(|_| "account_service_unavailable".to_owned())?
        .map_err(|error| error.code.to_owned())
}

#[tauri::command]
pub async fn list_managed_accounts(
    state: State<'_, ManagedAccountState>,
) -> Result<Vec<ManagedAccountDto>, String> {
    blocking(state.manager()?, |manager| manager.list_managed_accounts()).await
}

#[tauri::command]
pub async fn create_managed_account(
    app: AppHandle,
    state: State<'_, ManagedAccountState>,
    label: String,
    platform: String,
) -> Result<ManagedAccountDto, String> {
    let result = blocking(state.manager()?, move |manager| {
        manager.create_managed_account(label, platform)
    })
    .await?;
    let _ = app.emit("managed-accounts:changed", ());
    Ok(result)
}

#[tauri::command]
pub async fn rename_managed_account(
    app: AppHandle,
    state: State<'_, ManagedAccountState>,
    account_id: String,
    label: String,
) -> Result<AccountOperationDto, String> {
    let result = blocking(state.manager()?, move |manager| {
        manager.rename_managed_account(&account_id, label)
    })
    .await?;
    let _ = app.emit("managed-accounts:changed", ());
    Ok(result)
}

#[tauri::command]
pub async fn remove_managed_account(
    app: AppHandle,
    state: State<'_, ManagedAccountState>,
    account_id: String,
) -> Result<AccountOperationDto, String> {
    let result = blocking(state.manager()?, move |manager| {
        manager.remove_managed_account(&account_id)
    })
    .await?;
    let _ = app.emit("managed-accounts:changed", ());
    Ok(result)
}

#[tauri::command]
pub async fn begin_account_login(
    state: State<'_, ManagedAccountState>,
    account_id: String,
) -> Result<LoginAttemptDto, String> {
    blocking(state.manager()?, move |manager| {
        manager.begin_account_login(account_id)
    })
    .await
}

#[tauri::command]
pub async fn get_login_attempt(
    state: State<'_, ManagedAccountState>,
    attempt_id: String,
) -> Result<LoginAttemptDto, String> {
    blocking(state.manager()?, move |manager| {
        manager.get_login_attempt(&attempt_id)
    })
    .await
}

#[tauri::command]
pub async fn open_account_login_page(
    state: State<'_, ManagedAccountState>,
    attempt_id: String,
) -> Result<(), String> {
    blocking(state.manager()?, move |manager| {
        let url = manager.account_login_page(&attempt_id)?;
        open_official_codex_login_page(url)
    })
    .await
}

fn open_official_codex_login_page(url: &str) -> AccountResult<()> {
    if url != "https://auth.openai.com/codex/device" {
        return Err(codexu_core::accounts::AccountError {
            code: "login_page_unavailable",
        });
    }
    #[cfg(windows)]
    {
        #[link(name = "shell32")]
        unsafe extern "system" {
            fn ShellExecuteW(
                window: *mut std::ffi::c_void,
                operation: *const u16,
                file: *const u16,
                parameters: *const u16,
                directory: *const u16,
                show: i32,
            ) -> isize;
        }
        let verb: Vec<u16> = "open\0".encode_utf16().collect();
        let page: Vec<u16> = url.encode_utf16().chain(std::iter::once(0)).collect();
        let result = unsafe {
            ShellExecuteW(
                std::ptr::null_mut(),
                verb.as_ptr(),
                page.as_ptr(),
                std::ptr::null(),
                std::ptr::null(),
                1,
            )
        };
        if result > 32 {
            return Ok(());
        }
        Err(codexu_core::accounts::AccountError {
            code: "login_browser_unavailable",
        })
    }
    #[cfg(not(windows))]
    Err(codexu_core::accounts::AccountError {
        code: "windows_required",
    })
}

#[tauri::command]
pub async fn cancel_account_login(
    state: State<'_, ManagedAccountState>,
    attempt_id: String,
) -> Result<LoginAttemptDto, String> {
    blocking(state.manager()?, move |manager| {
        manager.cancel_account_login(&attempt_id)
    })
    .await
}

#[tauri::command]
pub async fn prepare_account_switch(
    state: State<'_, ManagedAccountState>,
    account_id: String,
) -> Result<PreparedSwitchDto, String> {
    blocking(state.manager()?, move |manager| {
        manager.prepare_account_switch(account_id)
    })
    .await
}

#[tauri::command]
pub async fn commit_account_switch(
    app: AppHandle,
    state: State<'_, ManagedAccountState>,
    ticket: String,
) -> Result<AccountOperationDto, String> {
    let manager = state.manager()?;
    let event_key = format!("switch:{ticket}");
    let (result, observed) = tauri::async_runtime::spawn_blocking(move || {
        let id = manager.prepared_switch_account(&ticket).ok();
        let label = id.as_ref().and_then(|id| {
            manager
                .list_managed_accounts()
                .ok()?
                .into_iter()
                .find(|a| a.id == *id)
                .map(|a| a.label)
        });
        let result = manager.commit_account_switch(&ticket);
        let quota = if result.is_ok() {
            id.as_ref()
                .and_then(|id| manager.verified_credential_snapshot(id, 45).ok())
        } else {
            None
        };
        (result, label.map(|label| (label, quota)))
    })
    .await
    .map_err(|_| "account_service_unavailable".to_owned())?;
    if let Some((label, quota)) = observed {
        use codexu_core::notifications::{NotificationEvent, SwitchFailure};
        let failure = match &result {
            Ok(dto) if dto.phase == "committed" => None,
            Ok(_) => Some(SwitchFailure::Unknown),
            Err(e) => Some(match e.code {
                "account_busy" | "occupancy_unknown" => SwitchFailure::AppBusy,
                "identity_mismatch" | "verification_failed" | "account_changed" => {
                    SwitchFailure::ValidationFailed
                }
                _ => SwitchFailure::Unknown,
            }),
        };
        if let Some(service) = app
            .try_state::<super::notifications::NotificationState>()
            .and_then(|s| s.manager().ok())
        {
            if let Ok(event) = NotificationEvent::account_switch(
                &event_key,
                &label,
                failure,
                chrono::Utc::now().timestamp(),
            ) {
                let _ = service.queue_event(event);
                if let Some(quota) = quota {
                    let _ = service.queue_managed_quota(&label, &quota);
                }
            }
        }
    }
    let _ = app.emit("managed-accounts:changed", ());
    result.map_err(|e| e.code.to_owned())
}

#[tauri::command]
pub async fn cancel_account_switch(
    state: State<'_, ManagedAccountState>,
    ticket: String,
) -> Result<AccountOperationDto, String> {
    blocking(state.manager()?, move |manager| {
        manager.cancel_account_switch(&ticket)
    })
    .await
}

async fn claude_blocking<T: Send + 'static>(
    manager: Arc<ClaudeSubscriptionManager>,
    action: impl FnOnce(Arc<ClaudeSubscriptionManager>) -> AccountResult<T> + Send + 'static,
) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(move || action(manager))
        .await
        .map_err(|_| "account_service_unavailable".to_owned())?
        .map_err(|error| error.code.to_owned())
}
#[tauri::command]
pub async fn list_claude_subscriptions(
    state: State<'_, ClaudeSubscriptionState>,
) -> Result<Vec<ClaudeSubscriptionDto>, String> {
    claude_blocking(state.manager()?, |manager| {
        manager.list_claude_subscriptions()
    })
    .await
}
#[tauri::command]
pub async fn begin_claude_subscription_login(
    state: State<'_, ClaudeSubscriptionState>,
) -> Result<ClaudeLoginAttemptDto, String> {
    claude_blocking(state.manager()?, |manager| {
        manager.begin_claude_subscription_login()
    })
    .await
}
#[tauri::command]
pub async fn get_claude_subscription_login(
    state: State<'_, ClaudeSubscriptionState>,
    attempt_id: String,
) -> Result<ClaudeLoginAttemptDto, String> {
    claude_blocking(state.manager()?, move |manager| {
        manager.get_claude_subscription_login(&attempt_id)
    })
    .await
}
#[tauri::command]
pub async fn cancel_claude_subscription_login(
    state: State<'_, ClaudeSubscriptionState>,
    attempt_id: String,
) -> Result<ClaudeLoginAttemptDto, String> {
    claude_blocking(state.manager()?, move |manager| {
        manager.cancel_claude_subscription_login(&attempt_id)
    })
    .await
}
#[tauri::command]
pub async fn capture_claude_subscription(
    app: AppHandle,
    state: State<'_, ClaudeSubscriptionState>,
    label: String,
    attempt_id: Option<String>,
) -> Result<ClaudeSubscriptionDto, String> {
    let result = claude_blocking(state.manager()?, move |manager| {
        manager.capture_claude_subscription(label, attempt_id.as_deref())
    })
    .await?;
    let _ = app.emit("claude-subscriptions:changed", ());
    Ok(result)
}

#[tauri::command]
pub async fn rename_claude_subscription(
    app: AppHandle,
    state: State<'_, ClaudeSubscriptionState>,
    account_id: String,
    label: String,
) -> Result<AccountOperationDto, String> {
    let result = claude_blocking(state.manager()?, move |manager| {
        manager.rename_claude_subscription(&account_id, label)
    })
    .await?;
    let _ = app.emit("claude-subscriptions:changed", ());
    Ok(result)
}

#[tauri::command]
pub async fn remove_claude_subscription(
    app: AppHandle,
    state: State<'_, ClaudeSubscriptionState>,
    account_id: String,
) -> Result<AccountOperationDto, String> {
    let result = claude_blocking(state.manager()?, move |manager| {
        manager.remove_claude_subscription(&account_id)
    })
    .await?;
    let _ = app.emit("claude-subscriptions:changed", ());
    Ok(result)
}

#[tauri::command]
pub async fn prepare_claude_subscription_switch(
    state: State<'_, ClaudeSubscriptionState>,
    account_id: String,
) -> Result<PreparedSwitchDto, String> {
    claude_blocking(state.manager()?, move |manager| {
        manager.prepare_claude_subscription_switch(account_id)
    })
    .await
}
#[tauri::command]
pub async fn commit_claude_subscription_switch(
    app: AppHandle,
    state: State<'_, ClaudeSubscriptionState>,
    ticket: String,
) -> Result<AccountOperationDto, String> {
    let result = claude_blocking(state.manager()?, move |manager| {
        manager.commit_claude_subscription_switch(&ticket)
    })
    .await?;
    let _ = app.emit("claude-subscriptions:changed", ());
    Ok(result)
}
#[tauri::command]
pub async fn cancel_claude_subscription_switch(
    state: State<'_, ClaudeSubscriptionState>,
    ticket: String,
) -> Result<AccountOperationDto, String> {
    claude_blocking(state.manager()?, move |manager| {
        manager.cancel_claude_subscription_switch(&ticket)
    })
    .await
}
#[tauri::command]
pub async fn read_claude_subscription_quota(
    app: AppHandle,
    state: State<'_, ClaudeSubscriptionState>,
    account_id: String,
) -> Result<ClaudeSubscriptionQuotaDto, String> {
    let result = claude_blocking(state.manager()?, move |manager| {
        manager.read_claude_subscription_quota(&account_id)
    })
    .await;
    let _ = app.emit("quota-display:changed", ());
    result
}
