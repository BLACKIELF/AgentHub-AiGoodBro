//! Display-only account facts. Opening details never contacts the provider;
//! only an explicit refresh reads the fixed official profile endpoint.
use super::*;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};

const DETAILS_CONTEXT: &str = "AiGoodBro.Next.Windows.account-details.v1";
const MAX_DETAILS: usize = 128 * 1024;

#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalDetails {
    pub profile_id: String,
    /// Display-only linked-directory evidence, never managed-account authority.
    pub linked_local: bool,
    pub email: Option<String>,
    pub display_name: Option<String>,
    pub username: Option<String>,
    pub masked_account_id: Option<String>,
    pub account_type: Option<String>,
    pub plan_type: Option<String>,
    pub pro_tier_multiplier: Option<u8>,
    pub displayed_pro_tier_multiplier: Option<u8>,
    pub subscription_active_until_ms: Option<i64>,
    pub lifetime_tokens: Option<i64>,
    pub peak_daily_tokens: Option<i64>,
    pub stats_as_of_ms: Option<i64>,
    pub profile_fetched_at_ms: Option<i64>,
    // Legacy slots have no creation timestamp. Never substitute a credential
    // refresh or filesystem mtime for the original creation event.
    pub added_at_ms: Option<i64>,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub participating: Option<bool>,
    pub chrome_profile_name: Option<String>,
    pub available_reset_cards: Option<u32>,
    pub reset_card_expires_at_ms: Vec<i64>,
    pub quota_checked_at_ms: Option<i64>,
    pub quota_fresh: bool,
    pub quota_windows: Vec<DetailsWindow>,
    pub warmup_history: Vec<WarmupRecord>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DetailsWindow {
    pub kind: &'static str,
    pub used_percent: f64,
    pub resets_at_ms: Option<i64>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WarmupRecord {
    pub at_ms: i64,
    pub succeeded: Option<bool>,
    pub failure_code: Option<String>,
    pub phase: String,
}

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct OfficialProfile {
    display_name: Option<String>,
    username: Option<String>,
    lifetime_tokens: Option<i64>,
    peak_daily_tokens: Option<i64>,
    stats_as_of_ms: Option<i64>,
    fetched_at_ms: i64,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CachedDetails {
    schema: u32,
    profile_id: String,
    identity_hash: String,
    official: OfficialProfile,
}

fn text(value: Option<&Value>) -> Option<String> {
    let s = value?.as_str()?.trim();
    (!s.is_empty() && s.chars().count() <= 160 && !s.chars().any(char::is_control))
        .then(|| s.to_owned())
}
fn date(value: Option<&Value>) -> Option<i64> {
    let value = value?.as_str()?;
    (value.len() <= 64)
        .then(|| chrono::DateTime::parse_from_rfc3339(value).ok())
        .flatten()
        .map(|v| v.timestamp_millis())
        .filter(|v| *v > 0)
}
fn count(value: Option<&Value>) -> Option<i64> {
    // Renderer numbers must retain the exact provider count, not a rounded i64.
    value?
        .as_i64()
        .filter(|v| (0..=9_007_199_254_740_991).contains(v))
}
fn subscription(auth: &[u8]) -> (Option<String>, Option<i64>) {
    let parse = || -> Option<Value> {
        let auth: Value = serde_json::from_slice(auth).ok()?;
        let token = auth["tokens"]["id_token"].as_str()?;
        let parts = token.split('.').collect::<Vec<_>>();
        if parts.len() != 3 || parts[1].len() > MAX_DETAILS {
            return None;
        }
        let payload = URL_SAFE_NO_PAD
            .decode(parts[1].trim_end_matches('='))
            .ok()?;
        serde_json::from_slice(&payload).ok()
    };
    let claims = parse().unwrap_or(Value::Null);
    let auth = &claims["https://api.openai.com/auth"];
    (
        text(auth.get("chatgpt_plan_type")),
        date(auth.get("chatgpt_subscription_active_until")),
    )
}
fn masked_id(value: &str) -> String {
    let chars = value.chars().collect::<Vec<_>>();
    if chars.len() <= 8 {
        return "••••".into();
    }
    format!(
        "{}…{}",
        chars[..4].iter().collect::<String>(),
        chars[chars.len() - 4..].iter().collect::<String>()
    )
}

/// Read only the already linked home chosen by the native catalog. An explicit
/// details request may display its identity without importing it into the vault
/// or claiming that its sign-in/allowance is currently usable.
pub fn read_linked_local_details(profile: &str, home: &Path) -> AccountResult<LocalDetails> {
    storage::ensure_no_links(home)?;
    let canonical = home
        .canonicalize()
        .map_err(|_| fail("account_paths_invalid"))?;
    if canonical != home || !canonical.is_dir() {
        return Err(fail("account_paths_invalid"));
    }
    let path = home.join("auth.json");
    let bytes = storage::read_optional(&path, super::super::super::identity::MAX_AUTH_BYTES)?
        .ok_or_else(|| fail("login_required"))?;
    let (identity, _) = parse_auth(&bytes)?;
    let (plan, expiry) = subscription(&bytes);
    if home.canonicalize().ok().as_ref() != Some(&canonical)
        || storage::read_optional(&path, super::super::super::identity::MAX_AUTH_BYTES)?.as_ref()
            != Some(&bytes)
    {
        return Err(fail("manual_action_identity_changed"));
    }
    Ok(LocalDetails {
        profile_id: profile.into(),
        linked_local: true,
        email: Some(identity.email.clone()),
        masked_account_id: Some(masked_id(&identity.account_id)),
        account_type: Some("chatgpt".into()),
        plan_type: plan,
        subscription_active_until_ms: expiry,
        ..LocalDetails::default()
    })
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct LocalMetadata {
    schema: u32,
    identity_hash: String,
    pro_tier_multiplier: Option<u8>,
}
const METADATA_CONTEXT: &str = "AiGoodBro.Next.Windows.account-local-metadata.v1";
fn metadata_path(manager: &AccountManager, identity: &str) -> PathBuf {
    state_root(manager)
        .join("local-metadata")
        .join(format!("{identity}.dpapi"))
}
fn valid_multiplier(value: Option<u8>) -> bool {
    value.is_none_or(|n| [5, 10, 20, 25].contains(&n))
}
fn local_multiplier(manager: &AccountManager, identity: &str) -> AccountResult<Option<u8>> {
    let Some(bytes) = storage::read_optional(&metadata_path(manager, identity), 4096)? else {
        return Ok(None);
    };
    let bytes = manager.protector.unseal(METADATA_CONTEXT, &bytes)?;
    let value: LocalMetadata =
        serde_json::from_slice(&bytes).map_err(|_| fail("account_details_cache_invalid"))?;
    if value.schema != 1
        || value.identity_hash != identity
        || !valid_multiplier(value.pro_tier_multiplier)
    {
        return Err(fail("account_details_cache_invalid"));
    }
    Ok(value.pro_tier_multiplier)
}
fn cache_path(manager: &AccountManager, profile: &str) -> PathBuf {
    state_root(manager)
        .join("details")
        .join(format!("{profile}.dpapi"))
}
fn cached(
    manager: &AccountManager,
    profile: &str,
    identity: &str,
) -> AccountResult<Option<OfficialProfile>> {
    let Some(bytes) = storage::read_optional(&cache_path(manager, profile), MAX_DETAILS)? else {
        return Ok(None);
    };
    let bytes = manager.protector.unseal(DETAILS_CONTEXT, &bytes)?;
    if bytes.len() > MAX_DETAILS {
        return Err(fail("account_details_cache_invalid"));
    }
    let cache: CachedDetails =
        serde_json::from_slice(&bytes).map_err(|_| fail("account_details_cache_invalid"))?;
    if cache.schema != 1 || cache.profile_id != profile || !hash_ok(&cache.identity_hash) {
        return Err(fail("account_details_cache_invalid"));
    }
    // A different login can reuse a slot; never display its previous identity's facts.
    if cache.identity_hash != identity {
        return Ok(None);
    }
    let p = cache.official;
    if p.fetched_at_ms <= 0
        || p.fetched_at_ms > ms() + 5000
        || p.lifetime_tokens.is_some_and(|v| v < 0)
        || p.peak_daily_tokens.is_some_and(|v| v < 0)
        || [&p.display_name, &p.username]
            .into_iter()
            .flatten()
            .any(|s| s.is_empty() || s.chars().count() > 160 || s.chars().any(char::is_control))
    {
        return Err(fail("account_details_cache_invalid"));
    }
    Ok(Some(p))
}
fn parse_official(bytes: &[u8], at: i64) -> AccountResult<OfficialProfile> {
    if bytes.len() > 1024 * 1024 {
        return Err(fail("account_details_invalid_response"));
    }
    let value: Value =
        serde_json::from_slice(bytes).map_err(|_| fail("account_details_invalid_response"))?;
    let p = value
        .get("profile")
        .and_then(Value::as_object)
        .ok_or_else(|| fail("account_details_invalid_response"))?;
    let s = value
        .get("stats")
        .and_then(Value::as_object)
        .ok_or_else(|| fail("account_details_invalid_response"))?;
    Ok(OfficialProfile {
        display_name: text(p.get("display_name")),
        username: text(p.get("username")),
        lifetime_tokens: count(s.get("lifetime_tokens")),
        peak_daily_tokens: count(s.get("peak_daily_tokens")),
        stats_as_of_ms: date(value.get("metadata").and_then(|v| v.get("stats_as_of"))),
        fetched_at_ms: at,
    })
}
fn card_expiries(credential: &StoredCredential) -> Vec<i64> {
    let quota = &credential.quota;
    if quota.get("accountId").and_then(Value::as_str)
        != Some(credential.identity.account_id.as_str())
    {
        return Vec::new();
    }
    let Some(rows) = quota["rateLimitResetCredits"]["credits"]
        .as_array()
        .filter(|v| v.len() <= 1024)
    else {
        return Vec::new();
    };
    let mut expiries = rows
        .iter()
        .filter(|v| v["resetType"] == "codexRateLimits" && v["status"] == "available")
        .filter_map(|v| {
            v["expiresAt"]
                .as_i64()
                .and_then(|n| n.checked_mul(1000))
                .filter(|n| *n > 0)
        })
        .collect::<Vec<_>>();
    expiries.sort_unstable();
    expiries
}

impl ManualAccountService {
    pub fn local_details(&self, profile: &str) -> AccountResult<LocalDetails> {
        if self.exiting.load(Ordering::Acquire) {
            return Err(fail("manual_action_cancelled"));
        }
        self.manager.require_accepting()?;
        if !storage::valid_id(profile) {
            return Err(fail("manual_action_identity_changed"));
        }
        // Read slot, credentials and cache under one vault guard. History is
        // read after releasing it, followed by a final identity check.
        let store = self.manager.store()?;
        let record = store.vault.account(profile)?;
        if record.platform != "codex" {
            return Err(fail("manual_action_unsupported"));
        }
        let mut dto = LocalDetails {
            profile_id: profile.into(),
            added_at_ms: record.created_at_ms,
            chrome_profile_name: match record.browser.mode {
                crate::accounts::browser::BrowserMode::SystemDefault => None,
                crate::accounts::browser::BrowserMode::DedicatedChrome => {
                    Some("Chrome · dedicated".into())
                }
                crate::accounts::browser::BrowserMode::ExistingChrome => {
                    record.browser.profile_directory.clone()
                }
            },
            ..LocalDetails::default()
        };
        let Some(c) = &record.credential else {
            return Ok(dto);
        };
        if parse_auth(&c.auth)?.0 != c.identity {
            return Err(fail("manual_action_identity_changed"));
        }
        dto.email = Some(c.identity.email.clone());
        dto.masked_account_id = Some(masked_id(&c.identity.account_id));
        // StoredCredential is created only by a validated ChatGPT subscription read.
        dto.account_type = Some("chatgpt".into());
        let (plan, expiry) = subscription(&c.auth);
        dto.plan_type = c.plan.clone().or(plan);
        dto.subscription_active_until_ms = expiry;
        dto.pro_tier_multiplier = local_multiplier(&self.manager, &c.identity.identity_hash())?;
        dto.displayed_pro_tier_multiplier = dto
            .pro_tier_multiplier
            .or_else(|| (dto.plan_type.as_deref() == Some("prolite")).then_some(5));
        if let Some(p) = cached(&self.manager, profile, &c.identity.identity_hash())? {
            dto.display_name = p.display_name;
            dto.username = p.username;
            dto.lifetime_tokens = p.lifetime_tokens;
            dto.peak_daily_tokens = p.peak_daily_tokens;
            dto.stats_as_of_ms = p.stats_as_of_ms;
            dto.profile_fetched_at_ms = Some(p.fetched_at_ms);
        }
        let quota = crate::readers::CodexAppServerQuotaSnapshot::from_rate_limit_response(&c.quota);
        dto.quota_checked_at_ms = c.observed_at.checked_mul(1000).filter(|v| *v > 0);
        let age = dto.quota_checked_at_ms.and_then(|at| ms().checked_sub(at));
        dto.quota_fresh =
            quota.quota_read_succeeded && age.is_some_and(|v| (-5000..=900000).contains(&v));
        dto.available_reset_cards = quota.reset_credit_count;
        dto.reset_card_expires_at_ms = card_expiries(c);
        dto.quota_windows = [
            ("five_hour", quota.five_hour_quota),
            ("seven_day", quota.seven_day_quota),
            ("monthly", quota.monthly_quota),
        ]
        .into_iter()
        .filter_map(|(kind, w)| {
            w.map(|w| DetailsWindow {
                kind,
                used_percent: w.used_percent,
                resets_at_ms: w.resets_at.map(|d| d.timestamp_millis()),
            })
        })
        .collect();
        // Maintenance stores a bounded latest record per identity/window. This
        // projection exposes those recorded facts, not invented historical runs.
        let identity = c.identity.clone();
        drop(store);
        if let Some(service) = &self.maintenance {
            dto.warmup_history = service
                .history_for_identity(profile, &identity.identity_hash())
                .map_err(|_| fail("account_details_history_unavailable"))?
                .into_iter()
                .filter_map(|e| {
                    e.last_attempt_at_ms.map(|at_ms| WarmupRecord {
                        at_ms,
                        succeeded: match e.phase.as_str() {
                            "succeeded" => Some(true),
                            "blocked" | "cancelled" => Some(false),
                            _ => None,
                        },
                        failure_code: e.issue_code,
                        phase: e.phase,
                    })
                })
                .collect();
            dto.warmup_history
                .sort_by_key(|e| std::cmp::Reverse(e.at_ms));
        }
        let store = self.manager.store()?;
        if store
            .vault
            .account(profile)?
            .credential
            .as_ref()
            .is_none_or(|v| v.identity != identity)
        {
            return Err(fail("manual_action_identity_changed"));
        }
        Ok(dto)
    }

    /// Same identity's aliases share this local display label. It grants no
    /// subscription, quota, proxy participation or dispatch authority.
    pub fn set_pro_multiplier(
        &self,
        profile: &str,
        multiplier: Option<u8>,
    ) -> AccountResult<LocalDetails> {
        if !valid_multiplier(multiplier) {
            return Err(fail("account_details_invalid_multiplier"));
        }
        if !storage::valid_id(profile) {
            return Err(fail("manual_action_identity_changed"));
        }
        self.manager.require_accepting()?;
        if self.exiting.load(Ordering::Acquire) {
            return Err(fail("manual_action_cancelled"));
        }
        {
            let store = self.manager.store()?;
            let credential = store
                .vault
                .account(profile)?
                .credential
                .as_ref()
                .ok_or_else(|| fail("login_required"))?;
            if parse_auth(&credential.auth)?.0 != credential.identity {
                return Err(fail("manual_action_identity_changed"));
            }
            let identity = credential.identity.identity_hash();
            let value = LocalMetadata {
                schema: 1,
                identity_hash: identity.clone(),
                pro_tier_multiplier: multiplier,
            };
            let path = metadata_path(&self.manager, &identity);
            storage::secure_directory(path.parent().unwrap())?;
            let bytes =
                serde_json::to_vec(&value).map_err(|_| fail("account_details_save_failed"))?;
            let sealed = self.manager.protector.seal(METADATA_CONTEXT, &bytes)?;
            storage::atomic_write(&path, &sealed)
                .map_err(|_| fail("account_details_save_failed"))?;
        }
        self.local_details(profile)
    }

    pub fn refresh_local_details(
        &self,
        profile: &str,
        language: &str,
    ) -> AccountResult<LocalDetails> {
        if !matches!(language, "zh" | "en") {
            return Err(fail("account_details_invalid_request"));
        }
        let c = self.credential(profile)?;
        // Separate from reset/referral operations; unrelated proxy work is never a gate.
        let _flight = storage::StoreLock::acquire(
            &state_root(&self.manager)
                .join("details-flight")
                .join(profile),
        )?;
        let response = self
            .runtime
            .http(
                &c.value,
                &HttpRequest {
                    path: "/wham/profiles/me".into(),
                    method: "GET",
                    body: None,
                    language: language.into(),
                },
                &|| self.recheck(&c),
            )
            .map_err(|error| {
                if error.code == "referral_network" {
                    fail("account_details_network")
                } else {
                    error
                }
            })?;
        self.recheck(&c)?;
        if !(200..300).contains(&response.status) {
            return Err(fail(match response.status {
                401 => "login_required",
                403 => "account_details_permission_denied",
                429 => "account_details_rate_limited",
                _ => "account_details_unavailable",
            }));
        }
        let official = parse_official(&response.body, ms())?;
        let cache = CachedDetails {
            schema: 1,
            profile_id: profile.into(),
            identity_hash: c.value.identity.identity_hash(),
            official,
        };
        let bytes = serde_json::to_vec(&cache).map_err(|_| fail("account_details_save_failed"))?;
        let sealed = self.manager.protector.seal(DETAILS_CONTEXT, &bytes)?;
        // Hold the vault commit lock for the final identity check and cache save.
        // No network call runs under this lock, and no credential is modified.
        {
            let store = self.manager.store()?;
            let current = store
                .vault
                .account(profile)?
                .credential
                .as_ref()
                .ok_or_else(|| fail("manual_action_identity_changed"))?;
            if current.identity != c.value.identity {
                return Err(fail("manual_action_identity_changed"));
            }
            self.manager.require_accepting()?;
            if self.exiting.load(Ordering::Acquire) {
                return Err(fail("manual_action_cancelled"));
            }
            let path = cache_path(&self.manager, profile);
            storage::secure_directory(path.parent().unwrap())?;
            storage::atomic_write(&path, &sealed)
                .map_err(|_| fail("account_details_save_failed"))?;
        }
        self.local_details(profile)
    }
}

#[cfg(test)]
#[path = "details_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "linked_details_tests.rs"]
mod linked_tests;
