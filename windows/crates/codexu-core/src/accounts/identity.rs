use super::{fail, now, AccountResult};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

pub const MAX_AUTH_BYTES: usize = 1024 * 1024;

/// Backend-only identity. Deliberately not Debug; raw identity never reaches UI.
#[derive(Clone, PartialEq, Eq)]
pub struct AccountIdentity {
    pub(crate) email: String,
    pub(crate) account_id: String,
}
impl AccountIdentity {
    pub fn from_auth(bytes: &[u8]) -> AccountResult<Self> {
        Ok(parse_auth(bytes)?.0)
    }
    pub fn identity_hash(&self) -> String {
        let mut hash = Sha256::new();
        hash.update(self.email.as_bytes());
        hash.update([0]);
        hash.update(self.account_id.as_bytes());
        format!("{:x}", hash.finalize())
    }
    pub fn masked_identity(&self) -> String {
        crate::local_cli::masked_identity(&self.email)
    }
    pub(crate) fn matches_official_email(&self, email: &str) -> bool {
        normalize_email(email).as_ref() == Some(&self.email)
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct StoredCredential {
    pub auth: Vec<u8>,
    #[serde(with = "encrypted_identity_wire")]
    pub identity: AccountIdentity,
    pub generation: String,
    pub observed_at: i64,
    pub quota: Value,
    pub plan: Option<String>,
}

// Serialization is available only at this explicit encrypted-storage field.
// AccountIdentity itself cannot accidentally become a WebView return value.
mod encrypted_identity_wire {
    use super::*;
    pub fn serialize<S: serde::Serializer>(
        identity: &AccountIdentity,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        (&identity.email, &identity.account_id).serialize(serializer)
    }
    pub fn deserialize<'de, D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> Result<AccountIdentity, D::Error> {
        let (email, account_id) = <(String, String)>::deserialize(deserializer)?;
        Ok(AccountIdentity { email, account_id })
    }
}

/// Result of a real runtime verification or an explicitly injected test runtime.
/// Construction still validates auth identity, expiry and official quota shape.
pub struct VerifiedCredential {
    pub(crate) auth: Vec<u8>,
    pub(crate) identity: AccountIdentity,
    pub(crate) observed_at: i64,
    pub(crate) quota: Value,
    pub(crate) plan: Option<String>,
}
impl VerifiedCredential {
    pub fn from_official_read(
        auth: Vec<u8>,
        official_account: &Value,
        official_rate_limits: Value,
    ) -> AccountResult<Self> {
        let (identity, expires_at) = parse_auth(&auth)?;
        if expires_at <= now() + 30 {
            return Err(super::fail("credentials_expired"));
        }
        let account = official_account
            .get("account")
            .ok_or_else(|| fail("identity_unverified"))?;
        if account.get("type").and_then(Value::as_str) != Some("chatgpt")
            || !account
                .get("email")
                .and_then(Value::as_str)
                .is_some_and(|email| identity.matches_official_email(email))
        {
            return Err(fail("identity_mismatch"));
        }
        let quota = crate::readers::CodexAppServerQuotaSnapshot::from_rate_limit_response(
            &official_rate_limits,
        );
        if !quota.quota_read_succeeded {
            return Err(fail("official_quota_unverified"));
        }
        let plan = official_rate_limits
            .get("rateLimits")
            .and_then(|v| v.get("planType"))
            .or_else(|| account.get("planType"))
            .and_then(Value::as_str)
            .filter(|v| {
                !v.is_empty()
                    && v.len() <= 32
                    && v.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
            })
            .map(str::to_owned);
        Ok(Self {
            auth,
            identity,
            observed_at: now(),
            quota: official_rate_limits,
            plan,
        })
    }
    pub(crate) fn into_stored(self, generation: String) -> StoredCredential {
        StoredCredential {
            auth: self.auth,
            identity: self.identity,
            observed_at: self.observed_at,
            quota: self.quota,
            plan: self.plan,
            generation,
        }
    }
}

/// Rust-only short-lived data for the admission owner. Never Debug/Serialize.
pub struct VerifiedCredentialSnapshot {
    pub identity_hash: String,
    pub token_generation: String,
    pub observed_at: i64,
    pub expires_at: i64,
    pub plan: Option<String>,
    pub official_quota: Value,
    access_token: String,
    account_id: String,
}
impl VerifiedCredentialSnapshot {
    pub(crate) fn from_stored(value: &StoredCredential, maximum_age: i64) -> AccountResult<Self> {
        if maximum_age <= 0
            || maximum_age > 45
            || value.observed_at > now() + 5
            || now() - value.observed_at > maximum_age
        {
            return Err(fail("evidence_stale"));
        }
        let (identity, expires_at) = parse_auth(&value.auth)?;
        if identity != value.identity {
            return Err(fail("identity_unverified"));
        }
        if expires_at <= now() + 30 {
            return Err(fail("credentials_expired"));
        }
        let object: Value =
            serde_json::from_slice(&value.auth).map_err(|_| fail("credentials_invalid"))?;
        Ok(Self {
            identity_hash: identity.identity_hash(),
            token_generation: value.generation.clone(),
            observed_at: value.observed_at,
            expires_at,
            plan: value.plan.clone(),
            official_quota: value.quota.clone(),
            access_token: object["tokens"]["access_token"]
                .as_str()
                .unwrap_or_default()
                .to_owned(),
            account_id: identity.account_id,
        })
    }
    pub fn with_secret<T>(&self, consume: impl FnOnce(&str, &str) -> T) -> T {
        consume(&self.access_token, &self.account_id)
    }
}

pub(crate) fn auth_digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn nonempty(value: Option<&Value>) -> Option<&str> {
    value
        .and_then(Value::as_str)
        .filter(|v| !v.trim().is_empty() && !v.chars().any(char::is_control))
}
fn normalize_email(value: &str) -> Option<String> {
    let value = value.trim().to_lowercase();
    (value.len() <= 320 && value.contains('@') && !value.chars().any(char::is_whitespace))
        .then_some(value)
}
fn claims(token: &str) -> AccountResult<Value> {
    let mut parts = token.split('.');
    let _ = parts.next().ok_or_else(|| fail("credentials_invalid"))?;
    let payload = parts.next().ok_or_else(|| fail("credentials_invalid"))?;
    if parts.next().is_none() || parts.next().is_some() || payload.len() > MAX_AUTH_BYTES {
        return Err(fail("credentials_invalid"));
    }
    let bytes = URL_SAFE_NO_PAD
        .decode(payload.trim_end_matches('='))
        .map_err(|_| fail("credentials_invalid"))?;
    serde_json::from_slice(&bytes).map_err(|_| fail("credentials_invalid"))
}
fn account_claim(value: &Value) -> Option<&str> {
    nonempty(
        value
            .get("https://api.openai.com/auth")
            .and_then(|v| v.get("chatgpt_account_id")),
    )
    .or_else(|| nonempty(value.get("account_id")))
}
fn account_claims(value: &Value) -> [Option<&str>; 3] {
    [
        nonempty(
            value
                .get("https://api.openai.com/auth")
                .and_then(|v| v.get("chatgpt_account_id")),
        ),
        nonempty(
            value
                .get("https://api.openai.com/auth")
                .and_then(|v| v.get("account_id")),
        ),
        nonempty(value.get("account_id")),
    ]
}
pub(crate) fn parse_auth(bytes: &[u8]) -> AccountResult<(AccountIdentity, i64)> {
    if bytes.is_empty() || bytes.len() > MAX_AUTH_BYTES {
        return Err(fail("credentials_invalid"));
    }
    let object: Value = serde_json::from_slice(bytes).map_err(|_| fail("credentials_invalid"))?;
    if nonempty(object.get("OPENAI_API_KEY")).is_some() {
        return Err(fail("subscription_required"));
    }
    let tokens = object
        .get("tokens")
        .and_then(Value::as_object)
        .ok_or_else(|| fail("credentials_invalid"))?;
    let access = nonempty(tokens.get("access_token")).ok_or_else(|| fail("credentials_invalid"))?;
    let id = nonempty(tokens.get("id_token")).ok_or_else(|| fail("credentials_invalid"))?;
    nonempty(tokens.get("refresh_token")).ok_or_else(|| fail("credentials_invalid"))?;
    let id = claims(id)?;
    let access = claims(access)?;
    let email = nonempty(id.get("email"))
        .and_then(normalize_email)
        .ok_or_else(|| fail("identity_unverified"))?;
    for value in [&id, &access] {
        for raw in [
            value.get("email"),
            value
                .get("https://api.openai.com/profile")
                .and_then(|v| v.get("email")),
        ]
        .into_iter()
        .flatten()
        {
            if nonempty(Some(raw)).and_then(normalize_email).as_ref() != Some(&email) {
                return Err(fail("identity_mismatch"));
            }
        }
    }
    let account_id = nonempty(tokens.get("account_id"))
        .or_else(|| account_claim(&id))
        .or_else(|| account_claim(&access))
        .ok_or_else(|| fail("identity_unverified"))?
        .to_owned();
    if account_id.len() > 256
        || account_claims(&id)
            .into_iter()
            .chain(account_claims(&access))
            .flatten()
            .any(|other| other != account_id)
    {
        return Err(fail("identity_mismatch"));
    }
    let expires_at = access
        .get("exp")
        .and_then(Value::as_i64)
        .ok_or_else(|| fail("credentials_expired"))?;
    Ok((AccountIdentity { email, account_id }, expires_at))
}
