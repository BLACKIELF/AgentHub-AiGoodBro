use super::super::{fail, now, AccountResult};
use crate::readers::local_cli_quota::{valid_windows, LocalCliQuotaWindow};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

pub(super) const MAX_BYTES: usize = 1_048_576;
pub(super) fn object(bytes: &[u8]) -> AccountResult<Value> {
    if bytes.len() > MAX_BYTES {
        return Err(fail("claude_credentials_invalid"));
    }
    let value: Value =
        serde_json::from_slice(bytes).map_err(|_| fail("claude_credentials_invalid"))?;
    if !value.is_object() {
        return Err(fail("claude_credentials_invalid"));
    }
    Ok(value)
}
pub(super) fn text(value: &Value, limit: usize) -> Option<&str> {
    value
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= limit && !s.chars().any(char::is_control))
}
pub(super) fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
pub(super) fn oauth(bytes: &[u8], allow_expired: bool) -> AccountResult<Value> {
    let root = object(bytes)?;
    let value = root
        .get("claudeAiOauth")
        .filter(|v| v.is_object())
        .ok_or_else(|| fail("claude_subscription_required"))?;
    if text(&value["accessToken"], 32768).is_none()
        || value["expiresAt"].as_f64().is_none_or(|v| !v.is_finite())
        || value
            .get("refreshToken")
            .is_some_and(|v| text(v, 32768).is_none())
    {
        return Err(fail("claude_credentials_invalid"));
    }
    if !allow_expired && value["expiresAt"].as_f64().unwrap() <= (now() + 30) as f64 * 1000.0 {
        return Err(fail("claude_credentials_expired"));
    }
    Ok(value.clone())
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Identity {
    pub uuid: String,
    pub organization: String,
    pub email: Option<String>,
}
impl Identity {
    pub fn from_account(value: &Value) -> AccountResult<Self> {
        Ok(Self {
            uuid: text(&value["accountUuid"], 128)
                .ok_or_else(|| fail("claude_identity_unverified"))?
                .into(),
            organization: value
                .get("organizationUuid")
                .and_then(|v| text(v, 128))
                .unwrap_or_default()
                .into(),
            email: value
                .get("emailAddress")
                .and_then(|v| v.as_str())
                .and_then(crate::local_cli::valid_identity),
        })
    }
    pub fn fingerprint(&self) -> String {
        digest(format!("claude-subscription\0{}\0{}", self.uuid, self.organization).as_bytes())
    }
    pub fn masked(&self) -> Option<String> {
        self.email.as_deref().map(crate::local_cli::masked_identity)
    }
}
#[derive(Clone, Serialize, Deserialize)]
pub(super) struct StoredCredential {
    pub bytes: Vec<u8>,
    pub oauth_account: Value,
    pub identity: Identity,
    pub generation: String,
    pub observed_at: i64,
    pub plan: Option<String>,
}
#[derive(Clone)]
pub struct ClaudeVerifiedCredential(pub(super) StoredCredential);
impl ClaudeVerifiedCredential {
    /// Binds the official profile's stable UUID/organization to the exact
    /// account metadata produced by the official CLI. No email-only identity.
    pub fn from_official_profile(
        bytes: Vec<u8>,
        oauth_account: Value,
        profile: &Value,
    ) -> AccountResult<Self> {
        let token = oauth(&bytes, false)?;
        let declared = Identity::from_account(&oauth_account)?;
        let account = profile
            .get("account")
            .ok_or_else(|| fail("claude_identity_unverified"))?;
        let official = Identity {
            uuid: text(&account["uuid"], 128)
                .ok_or_else(|| fail("claude_identity_unverified"))?
                .into(),
            organization: profile
                .get("organization")
                .and_then(|v| text(&v["uuid"], 128))
                .unwrap_or_default()
                .into(),
            email: account
                .get("email")
                .and_then(Value::as_str)
                .and_then(crate::local_cli::valid_identity),
        };
        if declared.fingerprint() != official.fingerprint()
            || declared
                .email
                .as_ref()
                .zip(official.email.as_ref())
                .is_some_and(|(a, b)| a != b)
        {
            return Err(fail("claude_identity_mismatch"));
        }
        let plan = token
            .get("subscriptionType")
            .or_else(|| token.get("rateLimitTier"))
            .and_then(|v| text(v, 64))
            .map(str::to_owned);
        Ok(Self(StoredCredential {
            bytes,
            oauth_account,
            identity: official,
            generation: super::super::nonce()?,
            observed_at: now(),
            plan,
        }))
    }
}

/// Same observed fields as Mac LocalCLIQuotaReader.parseClaude. Missing/null
/// fields stay absent; model windows require a returned scoped model label.
pub fn parse_claude_usage(bytes: &[u8]) -> AccountResult<Vec<LocalCliQuotaWindow>> {
    let root = object(bytes)?;
    let mut windows = Vec::new();
    let percent = |value: &Value| -> AccountResult<f64> {
        value
            .as_f64()
            .filter(|v| v.is_finite() && (0.0..=100.0).contains(v))
            .ok_or_else(|| fail("claude_quota_invalid"))
    };
    let reset = |value: &Value| -> Option<DateTime<Utc>> {
        value
            .as_str()
            .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
            .map(|v| v.with_timezone(&Utc))
    };
    for (key, label) in [
        ("five_hour", "5-hour"),
        ("seven_day", "7-day"),
        ("seven_day_oauth_apps", "7-day OAuth apps"),
        ("seven_day_opus", "7-day Opus"),
        ("seven_day_sonnet", "7-day Sonnet"),
    ] {
        let Some(value) = root.get(key).filter(|v| !v.is_null()) else {
            continue;
        };
        if !value.is_object() {
            return Err(fail("claude_quota_invalid"));
        }
        let Some(used) = value.get("utilization").filter(|v| !v.is_null()) else {
            continue;
        };
        windows.push(LocalCliQuotaWindow {
            id: key.into(),
            label: label.into(),
            used_percent: percent(used)?,
            resets_at: reset(&value["resets_at"]),
        });
    }
    if let Some(limits) = root.get("limits").filter(|v| !v.is_null()) {
        let limits = limits
            .as_array()
            .ok_or_else(|| fail("claude_quota_invalid"))?;
        if limits.len() > 256 {
            return Err(fail("claude_quota_invalid"));
        }
        for (index, limit) in limits.iter().enumerate() {
            if let Some(active) = limit.get("is_active") {
                let active = active
                    .as_bool()
                    .ok_or_else(|| fail("claude_quota_invalid"))?;
                if !active {
                    continue;
                }
            }
            let Some(label) = limit
                .get("scope")
                .and_then(|v| v.get("model"))
                .and_then(|v| text(&v["display_name"], 128))
            else {
                continue;
            };
            if limit
                .get("kind")
                .and_then(Value::as_str)
                .is_some_and(|v| !v.is_empty() && v != "weekly_scoped")
                || limit
                    .get("group")
                    .and_then(Value::as_str)
                    .is_some_and(|v| !v.is_empty() && v != "weekly")
            {
                continue;
            }
            let Some(used) = limit.get("percent").filter(|v| !v.is_null()) else {
                continue;
            };
            windows.push(LocalCliQuotaWindow {
                id: format!("limit-{index}"),
                label: label.into(),
                used_percent: percent(used)?,
                resets_at: reset(&limit["resets_at"]),
            });
        }
    }
    if !valid_windows(&windows) {
        return Err(fail("claude_quota_invalid"));
    }
    Ok(windows)
}
