//! Installation events are bound to native file identities, never version or
//! a successful guide render. No account credentials are inspected here.
use crate::app_state::AppState;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tauri::{AppHandle, Emitter, State};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SetupAudience {
    New,
    Returning,
}
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SetupOutcome {
    #[default]
    Pending,
    Completed,
    Deferred,
}
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct InstallationOnboarding {
    event_id: Option<String>,
    status: SetupOutcome,
    audience: Option<SetupAudience>,
}
impl InstallationOnboarding {
    fn valid(&self) -> bool {
        self.event_id.as_ref().is_none_or(|id| {
            id.starts_with("files:v1:")
                && id.len() <= 192
                && id
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b':')
        }) && (self.status != SetupOutcome::Completed || self.audience.is_some())
    }
    fn observe(&mut self, id: &str) {
        if self.event_id.as_deref() != Some(id) {
            *self = Self {
                event_id: Some(id.into()),
                ..Default::default()
            };
        }
    }
    fn update(
        &mut self,
        event_id: &str,
        audience: Option<SetupAudience>,
        outcome: Option<SetupOutcome>,
    ) -> Result<(), &'static str> {
        if self.event_id.as_deref() != Some(event_id) || self.status != SetupOutcome::Pending {
            return Err("setup_event_changed");
        }
        if let Some(audience) = audience {
            if self.audience.is_some_and(|prior| prior != audience) {
                return Err("setup_audience_already_selected");
            }
            self.audience = Some(audience);
        }
        if let Some(outcome) = outcome {
            if outcome == SetupOutcome::Pending
                || outcome == SetupOutcome::Completed && self.audience.is_none()
            {
                return Err("setup_audience_required");
            }
            self.status = outcome;
        }
        Ok(())
    }
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SetupContextDto {
    version: String,
    event_id: Option<String>,
    status: &'static str,
    audience: Option<SetupAudience>,
    should_present: bool,
    failure_code: Option<&'static str>,
}
fn unavailable(app: &AppHandle, code: &'static str) -> SetupContextDto {
    SetupContextDto {
        version: app.package_info().version.to_string(),
        event_id: None,
        status: "unavailable",
        audience: None,
        should_present: false,
        failure_code: Some(code),
    }
}
async fn context(
    app: &AppHandle,
    state: &AppState,
    update: Option<(&str, Option<SetupAudience>, Option<SetupOutcome>)>,
) -> Result<SetupContextDto, String> {
    let identity = match current_identity() {
        Ok(id) => id,
        Err(code) if update.is_none() => return Ok(unavailable(app, code)),
        Err(code) => return Err(code.into()),
    };
    let mut config = state.config.write().await;
    if !config.installation_onboarding.valid() {
        return Err("setup_state_invalid".into());
    }
    let mut candidate = config.clone();
    candidate.installation_onboarding.observe(&identity);
    if let Some((event_id, audience, outcome)) = update {
        candidate
            .installation_onboarding
            .update(event_id, audience, outcome)
            .map_err(str::to_owned)?;
    }
    if candidate.installation_onboarding != config.installation_onboarding {
        candidate
            .save(&state.app_data_dir)
            .map_err(|_| "setup_state_save_failed".to_owned())?;
        *config = candidate;
    }
    let saved = &config.installation_onboarding;
    Ok(SetupContextDto {
        version: app.package_info().version.to_string(),
        event_id: saved.event_id.clone(),
        status: match saved.status {
            SetupOutcome::Pending => "pending",
            SetupOutcome::Completed => "completed",
            SetupOutcome::Deferred => "deferred",
        },
        audience: saved.audience,
        should_present: saved.status == SetupOutcome::Pending,
        failure_code: None,
    })
}
#[tauri::command]
pub async fn get_setup_context(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
) -> Result<SetupContextDto, String> {
    context(&app, &state, None).await
}
#[tauri::command]
pub async fn update_setup_onboarding(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    event_id: String,
    audience: Option<SetupAudience>,
    outcome: Option<SetupOutcome>,
) -> Result<SetupContextDto, String> {
    let result = context(&app, &state, Some((&event_id, audience, outcome))).await;
    if result.is_ok() {
        let _ = app.emit("setup-context:changed", ());
    }
    result
}
#[cfg(not(windows))]
fn current_identity() -> Result<String, &'static str> {
    Err("installation_identity_unavailable")
}
#[cfg(windows)]
fn current_identity() -> Result<String, &'static str> {
    use std::{
        fs::OpenOptions,
        os::windows::{fs::OpenOptionsExt, io::AsRawHandle},
        path::Path,
    };
    #[repr(C)]
    #[derive(Default)]
    struct Info {
        attributes: u32,
        created: [u32; 2],
        accessed: [u32; 2],
        written: [u32; 2],
        volume: u32,
        size: [u32; 2],
        links: u32,
        index: [u32; 2],
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetFileInformationByHandle(file: *mut std::ffi::c_void, info: *mut Info) -> i32;
    }
    fn identity(path: &Path, directory: bool) -> Result<(u32, u64, u64), &'static str> {
        let file = OpenOptions::new()
            .read(true)
            .share_mode(7)
            .custom_flags(0x00200000 | if directory { 0x02000000 } else { 0 })
            .open(path)
            .map_err(|_| "installation_identity_unavailable")?;
        let mut info = Info::default();
        if unsafe { GetFileInformationByHandle(file.as_raw_handle(), &mut info) } == 0
            || info.attributes & 0x400 != 0
            || (info.attributes & 0x10 != 0) != directory
        {
            return Err("installation_identity_unavailable");
        }
        let index = (u64::from(info.index[0]) << 32) | u64::from(info.index[1]);
        let birth = (u64::from(info.created[1]) << 32) | u64::from(info.created[0]);
        if index == 0 || birth == 0 {
            return Err("installation_identity_unavailable");
        }
        Ok((info.volume, index, birth))
    }
    let exe = std::env::current_exe().map_err(|_| "installation_identity_unavailable")?;
    let parent = exe.parent().ok_or("installation_identity_unavailable")?;
    let (dv, di, db) = identity(parent, true)?;
    let (ev, ei, eb) = identity(&exe, false)?;
    Ok(format!(
        "files:v1:{dv:x}:{di:016x}:{db:016x}:{ev:x}:{ei:016x}:{eb:016x}"
    ))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn same_files_do_not_repeat_and_stale_guide_cannot_complete_replacement() {
        let mut state = InstallationOnboarding::default();
        state.observe("files:v1:1:2:3:4:5:6");
        state
            .update(
                "files:v1:1:2:3:4:5:6",
                Some(SetupAudience::Returning),
                Some(SetupOutcome::Completed),
            )
            .unwrap();
        state.observe("files:v1:1:2:3:4:5:6");
        assert_eq!(state.status, SetupOutcome::Completed);
        state.observe("files:v1:1:2:3:4:7:8");
        assert_eq!(state.status, SetupOutcome::Pending);
        assert!(state.audience.is_none());
        assert!(state
            .update("files:v1:1:2:3:4:5:6", None, Some(SetupOutcome::Completed))
            .is_err());
        assert!(state
            .update("files:v1:1:2:3:4:7:8", None, Some(SetupOutcome::Completed))
            .is_err());
        state
            .update("files:v1:1:2:3:4:7:8", None, Some(SetupOutcome::Deferred))
            .unwrap();
        assert_eq!(state.status, SetupOutcome::Deferred);
    }
}
