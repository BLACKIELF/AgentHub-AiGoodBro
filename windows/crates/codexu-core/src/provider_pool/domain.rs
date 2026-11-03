use super::{fail, Result};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

pub(super) const MAX_IPC: usize = 1_048_576;
pub(super) const PORT: u16 = 18081;
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    Antigravity,
    Claude,
    Kimi,
    Xai,
}
impl Provider {
    pub fn id(self) -> &'static str {
        match self {
            Self::Antigravity => "antigravity",
            Self::Claude => "claude",
            Self::Kimi => "kimi",
            Self::Xai => "xai",
        }
    }
    fn prefix(self) -> &'static str {
        if self == Self::Antigravity {
            "ag-"
        } else {
            match self {
                Self::Claude => "claude-",
                Self::Kimi => "kimi-",
                _ => "xai-",
            }
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Phase {
    Stopped,
    Starting,
    Running,
    Stopping,
    Failed,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AccountState {
    Checking,
    Ready,
    Busy,
    Cooling,
    Disabled,
    ReauthRequired,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AccountView {
    pub id: String,
    pub provider: Provider,
    pub masked_identity: String,
    pub generation: String,
    pub enabled: bool,
    pub concurrency_limit: u8,
    pub in_flight: u8,
    pub state: AccountState,
    #[serde(default)]
    pub cooldown_until: Option<i64>,
    #[serde(default)]
    pub last_error: Option<String>,
    pub models: Vec<String>,
}
pub(super) fn opaque(s: &str) -> bool {
    (20..=128).contains(&s.len())
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}
pub(super) fn account_id(p: Provider, id: &str) -> bool {
    id.strip_prefix(p.prefix()).is_some_and(|v| {
        v.len() == 32
            && v.bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}
pub(super) fn model(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && s.as_bytes()[0].is_ascii_alphanumeric()
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}
impl AccountView {
    pub(super) fn validate(&self) -> Result<()> {
        if !account_id(self.provider, &self.id)
            || !opaque(&self.generation)
            || self.masked_identity.len() > 160
            || !self.masked_identity.contains("***")
            || self.masked_identity.chars().any(char::is_control)
            || !(1..=8).contains(&self.concurrency_limit)
            || self.in_flight > 8
            || self.models.len() > 512
            || self.models.iter().any(|m| !model(m))
            || self
                .cooldown_until
                .is_some_and(|v| !(0..=253_402_300_799).contains(&v))
            || self.last_error.as_deref().is_some_and(|v| {
                !matches!(
                    v,
                    "" | "reauth_required" | "rate_limited" | "upstream_unavailable"
                )
            })
        {
            return Err(fail("provider_pool_invalid_data"));
        }
        Ok(())
    }
    pub(super) fn stopped(&self) -> Self {
        let mut v = self.clone();
        v.in_flight = 0;
        v.models.clear();
        v.last_error = None;
        v.state = if v.enabled {
            AccountState::Checking
        } else {
            AccountState::Disabled
        };
        v
    }
}
// Secret-bearing IPC and persisted payloads deliberately have no Debug or public Serialize API.
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Credential {
    pub provider: Provider,
    #[serde(rename = "accountID")]
    pub account_id: String,
    pub generation: String,
    pub masked_identity: String,
    pub access_token: String,
    pub refresh_token: String,
    #[serde(rename = "projectID")]
    pub project_id: String,
    pub expires_at: i64,
    #[serde(default)]
    pub id_token: Option<String>,
    #[serde(default, rename = "deviceID")]
    pub device_id: Option<String>,
    #[serde(default)]
    pub account_subject: Option<String>,
    #[serde(default, rename = "organizationID")]
    pub organization_id: Option<String>,
    #[serde(default)]
    pub refresh_expires_at: Option<i64>,
}
impl Credential {
    pub fn view(&self) -> AccountView {
        AccountView {
            id: self.account_id.clone(),
            provider: self.provider,
            masked_identity: self.masked_identity.clone(),
            generation: self.generation.clone(),
            enabled: true,
            concurrency_limit: 1,
            in_flight: 0,
            state: AccountState::Checking,
            cooldown_until: None,
            last_error: None,
            models: vec![],
        }
    }
    pub fn validate(&self) -> Result<()> {
        self.view().validate()?;
        if self.access_token.is_empty()
            || self.refresh_token.is_empty()
            || self.access_token.len() > 16384
            || self.refresh_token.len() > 16384
            || self.expires_at <= 0
            || (self.provider == Provider::Antigravity && self.project_id.is_empty())
            || self.project_id.len() > 1024
            || self.id_token.as_ref().is_some_and(|s| s.len() > 16384)
            || [
                &self.device_id,
                &self.account_subject,
                &self.organization_id,
            ]
            .iter()
            .any(|v| v.as_ref().is_some_and(|s| s.len() > 1024))
        {
            return Err(fail("provider_pool_invalid_credential"));
        }
        Ok(())
    }
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthorizationView {
    pub attempt_id: String,
    pub provider: Provider,
    pub cancelling: bool,
    pub user_code: Option<String>,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PoolSnapshot {
    pub phase: Phase,
    pub run_id: Option<String>,
    pub port: Option<u16>,
    pub accounts: Vec<AccountView>,
    pub providers: Vec<Provider>,
    pub provider_models: BTreeMap<Provider, Vec<String>>,
    pub authorization: Option<AuthorizationView>,
    pub issue_code: Option<&'static str>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Event {
    pub event: String,
    pub provider: Option<Provider>,
    pub providers: Option<Vec<Provider>>,
    pub provider_models: Option<BTreeMap<Provider, Vec<String>>>,
    pub user_code: Option<String>,
    #[serde(rename = "requestID")]
    pub request_id: Option<String>,
    #[serde(rename = "sessionID")]
    pub session_id: Option<String>,
    #[serde(rename = "accountID")]
    pub account_id: Option<String>,
    pub generation: Option<String>,
    pub port: Option<u16>,
    pub url: Option<String>,
    pub code: Option<String>,
    pub purpose: Option<String>,
    pub accounts: Option<Vec<AccountView>>,
    pub models: Option<Vec<String>>,
    pub credential: Option<Credential>,
}
pub(super) fn validate_rows(rows: &[AccountView]) -> Result<()> {
    let mut seen = BTreeSet::new();
    if rows.len() > 100 {
        return Err(fail("provider_pool_invalid_data"));
    }
    for row in rows {
        row.validate()?;
        if !seen.insert(&row.id) {
            return Err(fail("provider_pool_invalid_data"));
        }
    }
    Ok(())
}

pub(super) fn authorization_url(
    text: &str,
    provider: Provider,
    user_code: Option<&str>,
) -> Result<String> {
    let reject = || fail("provider_pool_authorization_url_rejected");
    if text.len() >= 8192 || text.chars().any(char::is_control) {
        return Err(reject());
    }
    let u = url::Url::parse(text).map_err(|_| reject())?;
    if u.scheme() != "https"
        || u.port().is_some()
        || !u.username().is_empty()
        || u.password().is_some()
        || u.fragment().is_some()
    {
        return Err(reject());
    }
    let q: Vec<_> = u.query_pairs().collect();
    let one = |key: &str| {
        let v: Vec<_> = q.iter().filter(|(k, _)| k == key).collect();
        if v.len() == 1 {
            Some(v[0].1.as_ref())
        } else {
            None
        }
    };
    match provider {
        Provider::Kimi | Provider::Xai => {
            let code = user_code
                .filter(|v| {
                    !v.is_empty()
                        && v.len() <= 32
                        && v.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
                })
                .ok_or_else(reject)?;
            let allowed = if provider == Provider::Kimi {
                matches!(u.host_str(), Some("www.kimi.com" | "kimi.com"))
                    && u.path() == "/code/authorize_device"
            } else {
                matches!(u.host_str(), Some("accounts.x.ai" | "auth.x.ai"))
                    && u.path() == "/oauth2/device"
            };
            if !allowed || q.len() != 1 || one("user_code") != Some(code) {
                return Err(reject());
            }
        }
        Provider::Claude | Provider::Antigravity => {
            if user_code.is_some()
                || one("response_type") != Some("code")
                || one("code_challenge_method") != Some("S256")
                || !one("code_challenge").is_some_and(|v| v.len() == 43 && opaque(v))
            {
                return Err(reject());
            }
            if provider == Provider::Claude {
                if u.host_str() != Some("claude.ai")
                    || u.path() != "/oauth/authorize"
                    || one("redirect_uri") != Some("http://localhost:54545/callback")
                    || !one("state").is_some_and(|v| v.len() == 43 && opaque(v))
                {
                    return Err(reject());
                }
            } else {
                let redirect = url::Url::parse(one("redirect_uri").ok_or_else(reject)?)
                    .map_err(|_| reject())?;
                if u.host_str() != Some("accounts.google.com")
                    || u.path() != "/o/oauth2/v2/auth"
                    || !one("state").is_some_and(|v| v.len() >= 32 && opaque(v))
                    || redirect.scheme() != "http"
                    || redirect.host_str() != Some("127.0.0.1")
                    || redirect.port().is_none_or(|p| p == 0)
                    || !redirect.username().is_empty()
                    || redirect.password().is_some()
                    || redirect.path() != "/oauth-callback"
                    || redirect.query().is_some()
                    || redirect.fragment().is_some()
                {
                    return Err(reject());
                }
            }
        }
    }
    Ok(u.into())
}
