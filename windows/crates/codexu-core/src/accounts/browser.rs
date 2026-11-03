//! Per-slot browser routing. No cookies, credentials or arbitrary URLs cross IPC.
use super::*;
use serde::{Deserialize, Serialize};
use std::{ffi::OsString, path::Path};
const LOGIN_URL: &str = "https://auth.openai.com/codex/device";
#[derive(Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BrowserMode {
    #[default]
    SystemDefault,
    DedicatedChrome,
    ExistingChrome,
}
#[derive(Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BrowserPreference {
    pub mode: BrowserMode,
    pub profile_directory: Option<String>,
}
impl BrowserPreference {
    pub(crate) fn valid(&self) -> bool {
        match self.mode {
            BrowserMode::ExistingChrome => self
                .profile_directory
                .as_deref()
                .is_some_and(valid_directory),
            _ => self.profile_directory.is_none(),
        }
    }
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChromeProfile {
    pub directory_name: String,
    pub display_name: String,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserSettings {
    pub profile_id: String,
    pub mode: BrowserMode,
    pub profile_directory: Option<String>,
    pub chrome_available: bool,
    pub profiles: Vec<ChromeProfile>,
    pub profile_scan_issue: Option<&'static str>,
}
fn valid_directory(s: &str) -> bool {
    s == "Default"
        || s.strip_prefix("Profile ").is_some_and(|v| {
            !v.is_empty() && v.len() <= 10 && v.bytes().all(|b| b.is_ascii_digit())
        })
}
fn profiles_at(root: &Path) -> AccountResult<Vec<ChromeProfile>> {
    let Some(bytes) = storage::read_optional(&root.join("Local State"), 2 * 1024 * 1024)? else {
        return Ok(Vec::new());
    };
    let value: serde_json::Value =
        serde_json::from_slice(&bytes).map_err(|_| fail("browser_profiles_unavailable"))?;
    let cache = value["profile"]["info_cache"]
        .as_object()
        .filter(|v| v.len() <= 256)
        .ok_or_else(|| fail("browser_profiles_unavailable"))?;
    let mut result = Vec::new();
    for (directory, row) in cache {
        if !valid_directory(directory) {
            continue;
        }
        let path = root.join(directory);
        storage::ensure_no_links(&path)?;
        if !path.is_dir() {
            continue;
        }
        let name = row["name"].as_str().unwrap_or(directory).trim();
        let display = if name.is_empty()
            || name.contains(['@', '/', '\\'])
            || name.chars().any(char::is_control)
        {
            directory.to_owned()
        } else {
            name.chars().take(60).collect()
        };
        result.push(ChromeProfile {
            directory_name: directory.clone(),
            display_name: display,
        });
    }
    result.sort_by(|a, b| a.directory_name.cmp(&b.directory_name));
    Ok(result)
}
trait BrowserRuntime {
    fn profiles(&self) -> AccountResult<Vec<ChromeProfile>>;
    fn available(&self) -> bool;
    fn open(&self, plan: &Plan, admit: &dyn Fn() -> AccountResult<()>) -> AccountResult<()>;
}
fn scan_profiles(
    runtime: &dyn BrowserRuntime,
    required: bool,
) -> AccountResult<(Vec<ChromeProfile>, Option<&'static str>)> {
    match runtime.profiles() {
        Ok(profiles) => Ok((profiles, None)),
        Err(error) if required => Err(error),
        Err(_) => Ok((Vec::new(), Some("browser_profiles_unavailable"))),
    }
}
enum Plan {
    SystemDefault,
    Chrome(Vec<OsString>),
}
#[path = "browser/native.rs"]
mod native;
impl AccountManager {
    fn browser_preference(&self, profile: &str) -> AccountResult<BrowserPreference> {
        self.require_accepting()?;
        let store = self.store()?;
        let r = store.vault.account(profile)?;
        if r.platform != "codex" {
            return Err(fail("platform_not_supported"));
        }
        Ok(r.browser.clone())
    }
    fn browser_settings_with(
        &self,
        profile: &str,
        runtime: &dyn BrowserRuntime,
    ) -> AccountResult<BrowserSettings> {
        let preference = self.browser_preference(profile)?;
        // Metadata errors must not prevent switching away from an existing profile.
        let (profiles, profile_scan_issue) = scan_profiles(runtime, false)?;
        Ok(BrowserSettings {
            profile_id: profile.into(),
            mode: preference.mode,
            profile_directory: preference.profile_directory,
            chrome_available: runtime.available(),
            profiles,
            profile_scan_issue,
        })
    }
    pub fn browser_settings(&self, profile: &str) -> AccountResult<BrowserSettings> {
        self.browser_settings_with(profile, &native::NativeBrowser)
    }
    fn set_browser_with(
        &self,
        profile: &str,
        preference: BrowserPreference,
        runtime: &dyn BrowserRuntime,
    ) -> AccountResult<BrowserSettings> {
        self.require_accepting()?;
        if !preference.valid() {
            return Err(fail("browser_invalid_selection"));
        }
        if preference.mode != BrowserMode::SystemDefault && !runtime.available() {
            return Err(fail("browser_chrome_unavailable"));
        }
        let (profiles, profile_scan_issue) =
            scan_profiles(runtime, preference.mode == BrowserMode::ExistingChrome)?;
        if preference.mode == BrowserMode::ExistingChrome
            && !profiles
                .iter()
                .any(|p| Some(&p.directory_name) == preference.profile_directory.as_ref())
        {
            return Err(fail("browser_profile_unavailable"));
        }
        let available = runtime.available();
        {
            let mut store = self.store()?;
            let r = store.vault.account_mut(profile)?;
            if r.platform != "codex" {
                return Err(fail("platform_not_supported"));
            }
            r.browser = preference.clone();
            store.save()?;
        }
        Ok(BrowserSettings {
            profile_id: profile.into(),
            mode: preference.mode,
            profile_directory: preference.profile_directory,
            chrome_available: available,
            profiles,
            profile_scan_issue,
        })
    }
    pub fn set_browser_settings(
        &self,
        profile: &str,
        mode: BrowserMode,
        profile_directory: Option<String>,
    ) -> AccountResult<BrowserSettings> {
        self.set_browser_with(
            profile,
            BrowserPreference {
                mode,
                profile_directory,
            },
            &native::NativeBrowser,
        )
    }
    pub fn browser_display_name(&self, profile: &str) -> AccountResult<Option<String>> {
        let preference = self.browser_preference(profile)?;
        Ok(match preference.mode {
            BrowserMode::SystemDefault => None,
            BrowserMode::DedicatedChrome => Some("Chrome · dedicated".into()),
            BrowserMode::ExistingChrome => Some(preference.profile_directory.unwrap()),
        })
    }
    fn browser_plan(
        &self,
        profile: &str,
        p: &BrowserPreference,
        runtime: &dyn BrowserRuntime,
    ) -> AccountResult<Plan> {
        if !p.valid() {
            return Err(fail("browser_invalid_selection"));
        }
        if p.mode == BrowserMode::SystemDefault {
            return Ok(Plan::SystemDefault);
        }
        if !runtime.available() {
            return Err(fail("browser_chrome_unavailable"));
        }
        let mut args = Vec::new();
        match p.mode {
            BrowserMode::DedicatedChrome => {
                if !storage::valid_id(profile) {
                    return Err(fail("account_not_found"));
                }
                let home = self.paths.vault_root.join("browser").join(profile);
                storage::secure_directory(&home)?;
                let mut flag = OsString::from("--user-data-dir=");
                flag.push(home);
                args.push(flag);
                args.push("--profile-directory=Default".into());
                args.push("--no-first-run".into());
            }
            BrowserMode::ExistingChrome => {
                let directory = p.profile_directory.as_ref().unwrap();
                if !runtime
                    .profiles()?
                    .iter()
                    .any(|row| &row.directory_name == directory)
                {
                    return Err(fail("browser_profile_unavailable"));
                }
                args.push(format!("--profile-directory={directory}").into());
            }
            BrowserMode::SystemDefault => unreachable!(),
        }
        args.push("--new-window".into());
        args.push(LOGIN_URL.into());
        Ok(Plan::Chrome(args))
    }
    fn open_login_browser_with(
        &self,
        attempt_id: &str,
        runtime: &dyn BrowserRuntime,
    ) -> AccountResult<()> {
        self.account_login_page(attempt_id)?;
        let profile = self
            .attempts
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?
            .get(attempt_id)
            .ok_or_else(|| fail("login_attempt_not_found"))?
            .dto
            .account_id
            .clone();
        let preference = self.browser_preference(&profile)?;
        let plan = self.browser_plan(&profile, &preference, runtime)?;
        runtime.open(&plan, &|| {
            self.account_login_page(attempt_id)?;
            if self.browser_preference(&profile)? != preference {
                return Err(fail("browser_selection_changed"));
            }
            Ok(())
        })
    }
    /// Opens only the still-current native pairing attempt, using its saved slot
    /// preference. A missing Chrome/profile never falls back to a shared browser.
    pub fn open_account_login_browser(&self, attempt_id: &str) -> AccountResult<()> {
        self.open_login_browser_with(attempt_id, &native::NativeBrowser)
    }
}
#[cfg(test)]
#[path = "browser/tests.rs"]
mod tests;
