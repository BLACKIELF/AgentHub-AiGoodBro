//! Explicit user actions. No token, raw account ID, card ID, home or idempotency
//! key is accepted from the renderer. Unknown outcomes are never auto-replayed.
use crate::app_state::AppState;
use codexu_core::accounts::manual_accounts::{
    LocalDetails, ManualAccountService, ReferralBatch, ReferralPage, ReferralReview, ResetResult,
    ResetReview,
};
use codexu_core::accounts::AccountResult;
use codexu_core::local_cli::LocalCliKind;
use std::sync::Arc;
use tauri::{AppHandle, Emitter, State};
pub struct ManualAccountState(pub Result<Arc<ManualAccountService>, &'static str>);
impl ManualAccountState {
    fn service(&self) -> Result<Arc<ManualAccountService>, String> {
        self.0.clone().map_err(str::to_owned)
    }
}
async fn run<T: Send + 'static>(
    service: Arc<ManualAccountService>,
    work: impl FnOnce(Arc<ManualAccountService>) -> AccountResult<T> + Send + 'static,
) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(move || work(service))
        .await
        .map_err(|_| "manual_action_unavailable".to_owned())?
        .map_err(|e| e.code.to_owned())
}
async fn resolve(
    state: &Arc<AppState>,
    service: Arc<ManualAccountService>,
    profile_id: String,
) -> Result<String, String> {
    if profile_id.len() == 32
        && profile_id
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
    {
        return Ok(profile_id);
    }
    let id = profile_id
        .parse::<u64>()
        .map_err(|_| "manual_action_registration_required")?;
    let profile = {
        let config = state.config.read().await;
        config
            .profiles
            .get(id)
            .map_err(|_| "manual_action_registration_required")?
            .clone()
    };
    if profile.kind != LocalCliKind::Codex {
        return Err("manual_action_unsupported".into());
    }
    let root = profile.root.clone();
    let result = run(service, move |s| s.resolve_managed_root(&root)).await?;
    let config = state.config.read().await;
    if config.profiles.get(id).is_err()
        || config
            .profiles
            .get(id)
            .ok()
            .is_none_or(|p| p.kind != profile.kind || p.root != profile.root)
    {
        return Err("manual_action_identity_changed".into());
    }
    Ok(result)
}
#[tauri::command]
pub async fn get_account_local_details(
    state: State<'_, Arc<AppState>>,
    actions: State<'_, ManualAccountState>,
    profile_id: String,
) -> Result<LocalDetails, String> {
    let s = actions.service()?;
    let id = resolve(&state, s.clone(), profile_id.clone()).await?;
    let result = run(s, move |s| s.local_details(&id)).await?;
    Ok(project_details(&state, &profile_id, result).await)
}
#[tauri::command]
pub async fn begin_manual_reset_review(
    state: State<'_, Arc<AppState>>,
    actions: State<'_, ManualAccountState>,
    profile_id: String,
) -> Result<ResetReview, String> {
    let s = actions.service()?;
    let id = resolve(&state, s.clone(), profile_id.clone()).await?;
    let mut result = run(s, move |s| s.begin_reset_review(&id)).await?;
    result.profile_id = profile_id;
    Ok(result)
}
#[tauri::command]
pub async fn confirm_manual_reset_review(
    state: State<'_, Arc<AppState>>,
    actions: State<'_, ManualAccountState>,
    profile_id: String,
    review_id: String,
) -> Result<ResetReview, String> {
    let s = actions.service()?;
    let id = resolve(&state, s.clone(), profile_id.clone()).await?;
    let mut result = run(s, move |s| s.confirm_reset_review(&id, &review_id)).await?;
    result.profile_id = profile_id;
    Ok(result)
}
#[tauri::command]
pub async fn cancel_manual_reset_review(
    state: State<'_, Arc<AppState>>,
    actions: State<'_, ManualAccountState>,
    profile_id: String,
    review_id: String,
) -> Result<(), String> {
    let s = actions.service()?;
    let id = resolve(&state, s.clone(), profile_id.clone()).await?;
    run(s, move |s| s.cancel_reset_review(&id, &review_id)).await
}
#[tauri::command]
pub async fn consume_manual_reset_credit(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    actions: State<'_, ManualAccountState>,
    profile_id: String,
    review_id: String,
) -> Result<ResetResult, String> {
    let s = actions.service()?;
    let id = resolve(&state, s.clone(), profile_id.clone()).await?;
    let mut result = run(s, move |s| s.consume_reset(&id, &review_id)).await?;
    result.profile_id = profile_id.clone();
    if let Some(e) = result.manual_confirmation.as_mut() {
        e.profile_id = profile_id;
    }
    let _ = app.emit("manual-account:changed", ());
    Ok(result)
}
#[tauri::command]
pub async fn get_account_referral_eligibility(
    state: State<'_, Arc<AppState>>,
    actions: State<'_, ManualAccountState>,
    profile_id: String,
    language: String,
) -> Result<ReferralReview, String> {
    let s = actions.service()?;
    let id = resolve(&state, s.clone(), profile_id.clone()).await?;
    let mut result = run(s, move |s| s.referral_eligibility(&id, &language)).await?;
    result.profile_id = profile_id;
    Ok(result)
}
#[tauri::command]
pub async fn send_account_referral_invites(
    state: State<'_, Arc<AppState>>,
    actions: State<'_, ManualAccountState>,
    profile_id: String,
    review_id: String,
    emails: Vec<String>,
    consent: bool,
    language: String,
) -> Result<ReferralBatch, String> {
    let s = actions.service()?;
    let id = resolve(&state, s.clone(), profile_id.clone()).await?;
    let mut result = run(s, move |s| {
        s.send_referrals(&id, &review_id, emails, consent, &language)
    })
    .await?;
    result.profile_id = profile_id;
    Ok(result)
}
#[tauri::command]
pub async fn get_account_referral_tracking(
    state: State<'_, Arc<AppState>>,
    actions: State<'_, ManualAccountState>,
    profile_id: String,
    period: String,
    cursor: Option<String>,
    language: String,
) -> Result<ReferralPage, String> {
    let s = actions.service()?;
    let id = resolve(&state, s.clone(), profile_id.clone()).await?;
    let mut result = run(s, move |s| {
        s.referral_tracking(&id, &period, cursor.as_deref(), &language)
    })
    .await?;
    result.profile_id = profile_id;
    Ok(result)
}
#[tauri::command]
pub async fn check_account_referral_outcome(
    state: State<'_, Arc<AppState>>,
    actions: State<'_, ManualAccountState>,
    profile_id: String,
    review_id: String,
    language: String,
) -> Result<ReferralBatch, String> {
    let s = actions.service()?;
    let id = resolve(&state, s.clone(), profile_id.clone()).await?;
    let mut result = run(s, move |s| {
        s.check_referral_outcome(&id, &review_id, &language)
    })
    .await?;
    result.profile_id = profile_id;
    Ok(result)
}

#[tauri::command]
pub async fn refresh_account_local_details(
    state: State<'_, Arc<AppState>>,
    actions: State<'_, ManualAccountState>,
    profile_id: String,
    language: String,
) -> Result<LocalDetails, String> {
    let s = actions.service()?;
    let id = resolve(&state, s.clone(), profile_id.clone()).await?;
    let result = run(s, move |s| s.refresh_local_details(&id, &language)).await?;
    Ok(project_details(&state, &profile_id, result).await)
}

async fn project_details(state: &Arc<AppState>, id: &str, mut dto: LocalDetails) -> LocalDetails {
    dto.profile_id = id.into();
    if let Ok(id) = id.parse::<u64>() {
        let config = state.config.read().await;
        if config
            .profiles
            .get(id)
            .is_ok_and(|p| p.kind == LocalCliKind::Codex)
        {
            if let Ok(prefs) = super::cli_workflow::read_preferences(&state.app_data_dir) {
                let pref = prefs.profiles.get(&id).cloned().unwrap_or_default();
                dto.model = pref.model;
                dto.effort = pref.effort;
                dto.participating = Some(pref.participating);
            }
        }
    }
    dto
}
#[tauri::command]
pub async fn set_account_pro_multiplier(
    state: State<'_, Arc<AppState>>,
    actions: State<'_, ManualAccountState>,
    profile_id: String,
    multiplier: Option<u8>,
) -> Result<LocalDetails, String> {
    let s = actions.service()?;
    let id = resolve(&state, s.clone(), profile_id.clone()).await?;
    let result = run(s, move |s| s.set_pro_multiplier(&id, multiplier)).await?;
    Ok(project_details(&state, &profile_id, result).await)
}

#[tauri::command]
pub async fn get_account_browser_settings(
    state: State<'_, Arc<AppState>>,
    actions: State<'_, ManualAccountState>,
    profile_id: String,
) -> Result<codexu_core::accounts::browser::BrowserSettings, String> {
    let s = actions.service()?;
    let id = resolve(&state, s.clone(), profile_id.clone()).await?;
    let mut dto = run(s, move |s| s.browser_settings(&id)).await?;
    dto.profile_id = profile_id;
    Ok(dto)
}
#[tauri::command]
pub async fn set_account_browser_settings(
    state: State<'_, Arc<AppState>>,
    actions: State<'_, ManualAccountState>,
    profile_id: String,
    mode: codexu_core::accounts::browser::BrowserMode,
    profile_directory: Option<String>,
) -> Result<codexu_core::accounts::browser::BrowserSettings, String> {
    let s = actions.service()?;
    let id = resolve(&state, s.clone(), profile_id.clone()).await?;
    let mut dto = run(s, move |s| {
        s.set_browser_settings(&id, mode, profile_directory)
    })
    .await?;
    dto.profile_id = profile_id;
    Ok(dto)
}
