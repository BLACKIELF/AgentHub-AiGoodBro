//! Read-only adapters for the official endpoints already used by the Mac app.
//! Only the explicitly selected directory supplies credentials. Responses never
//! write credentials, infer quota from tokens, or follow an endpoint from JSON.
use super::{valid_windows, LocalCliQuotaResult, LocalCliQuotaState, LocalCliQuotaWindow};
use crate::local_cli::{bounded_label, LocalCliKind};
use chrono::{DateTime, Duration, Utc};
use serde_json::Value;
use std::{
    fs,
    io::Read,
    path::{Path, PathBuf},
};

mod native;
const MAX_BYTES: usize = 1_048_576;
type Result<T> = std::result::Result<T, Failure>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Failure {
    Missing,
    Expired,
    Credentials,
    Response,
    Unauthorized,
    Limited,
    Unavailable,
    Changed,
    RefreshRequired,
    GoNotConnected,
}
impl Failure {
    fn projection(self) -> (LocalCliQuotaState, &'static str) {
        use LocalCliQuotaState::*;
        match self {
            Self::Missing | Self::Expired => (NeedsLogin, "local_cli_needs_login"),
            Self::Credentials => (Unavailable, "local_cli_invalid_credentials"),
            Self::Response => (Unavailable, "local_cli_invalid_response"),
            Self::Unauthorized => (Unavailable, "local_cli_authorization_unverified"),
            Self::Limited => (RateLimited, "local_cli_rate_limited"),
            Self::Unavailable => (Unavailable, "local_cli_unavailable"),
            Self::Changed => (Unavailable, "local_cli_credentials_changed"),
            Self::RefreshRequired => (Unavailable, "local_cli_kimi_token_refresh_required"),
            Self::GoNotConnected => (Unsupported, "local_cli_opencode_go_not_connected"),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Endpoint {
    Grok,
    Kimi,
    OpenCode,
}
impl Endpoint {
    fn location(self) -> (&'static str, &'static str) {
        match self {
            Self::Grok => ("cli-chat-proxy.grok.com", "/v1/billing?format=credits"),
            Self::Kimi => ("api.kimi.com", "/coding/v1/usages"),
            Self::OpenCode => ("opencode.ai", "/zen/go/v1/usage"),
        }
    }
}
// No Debug/Serialize implementation: this value carries request-local secrets.
struct Request {
    endpoint: Endpoint,
    token: String,
    headers: Vec<(&'static str, String)>,
}
struct Response {
    status: u32,
    body: Vec<u8>,
}
trait Transport {
    fn get(&self, request: &Request) -> Result<Response>;
}
struct Prepared {
    request: Request,
    identity: Option<String>,
    files: Vec<(PathBuf, Vec<u8>)>,
    canonical_root: PathBuf,
}

fn no_reparse(metadata: &fs::Metadata) -> bool {
    if metadata.file_type().is_symlink() {
        return false;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return false;
        }
    }
    true
}
fn file(root: &Path, relative: &str) -> Result<Vec<u8>> {
    // All callers use constant paths; rejecting links also prevents a credential
    // path from silently referring to a different linked profile.
    let mut path = root.to_path_buf();
    if !fs::symlink_metadata(&path).is_ok_and(|m| m.is_dir() && no_reparse(&m)) {
        return Err(Failure::Credentials);
    }
    for part in Path::new(relative).components() {
        if !matches!(part, std::path::Component::Normal(_)) {
            return Err(Failure::Credentials);
        }
        path.push(part);
        let metadata = fs::symlink_metadata(&path).map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                Failure::Missing
            } else {
                Failure::Credentials
            }
        })?;
        if !no_reparse(&metadata) {
            return Err(Failure::Credentials);
        }
    }
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        // Do not follow a final-component reparse point, or share a credential
        // file with a writer while taking this bounded snapshot.
        options.custom_flags(0x0020_0000).share_mode(1);
    }
    let handle = options.open(&path).map_err(|_| Failure::Credentials)?;
    let metadata = handle.metadata().map_err(|_| Failure::Credentials)?;
    if !metadata.is_file() || !no_reparse(&metadata) || metadata.len() > MAX_BYTES as u64 {
        return Err(Failure::Credentials);
    }
    let mut bytes = Vec::new();
    handle
        .take(MAX_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Failure::Credentials)?;
    if bytes.len() > MAX_BYTES || path.canonicalize().ok().as_ref() != Some(&path) {
        return Err(Failure::Credentials);
    }
    Ok(bytes)
}
fn text(v: &Value) -> Option<&str> {
    v.as_str().map(str::trim).filter(|s| !s.is_empty())
}
fn header(s: &str) -> Option<String> {
    (!s.is_empty() && s.len() <= 32_768 && s.bytes().all(|c| (0x21..=0x7e).contains(&c)))
        .then(|| s.to_owned())
}
fn object(bytes: &[u8]) -> Result<Value> {
    if bytes.len() > MAX_BYTES {
        return Err(Failure::Response);
    }
    let v: Value = serde_json::from_slice(bytes).map_err(|_| Failure::Response)?;
    if !v.is_object() {
        return Err(Failure::Response);
    }
    Ok(v)
}
fn number(v: &Value, strings: bool) -> Option<f64> {
    v.as_f64()
        .or_else(|| {
            if strings {
                text(v).and_then(|s| s.parse().ok())
            } else {
                None
            }
        })
        .filter(|v| v.is_finite())
}
fn percent(v: &Value) -> Result<f64> {
    number(v, false)
        .filter(|n| (0.0..=100.0).contains(n))
        .ok_or(Failure::Response)
}
fn date(v: &Value) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(text(v)?)
        .ok()
        .map(|d| d.with_timezone(&Utc))
}
fn plan(v: &Value) -> Option<String> {
    bounded_label(text(v)?, 128).filter(|s| !s.contains(['@', '/', '\\', ':']))
}
fn jwt_identity(token: &str) -> Option<String> {
    use base64::Engine;
    let encoded = token.split('.').nth(1)?.trim_end_matches('=');
    let decoded = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(encoded)
        .ok()?;
    let v = object(&decoded).ok()?;
    text(&v["user_id"])
        .or_else(|| text(&v["sub"]))
        .map(str::to_owned)
}

fn prepare(kind: LocalCliKind, root: &Path, now: DateTime<Utc>) -> Result<Prepared> {
    let canonical_root = root.canonicalize().map_err(|_| Failure::Missing)?;
    let relative = if kind == LocalCliKind::Kimi {
        "credentials/kimi-code.json"
    } else {
        "auth.json"
    };
    let bytes = file(&canonical_root, relative)?;
    let v = object(&bytes).map_err(|_| Failure::Credentials)?;
    let mut files = vec![(PathBuf::from(relative), bytes)];
    let (endpoint, token, identity, headers) = match kind {
        LocalCliKind::Grok => {
            let entries: Vec<_> = v
                .as_object()
                .ok_or(Failure::Credentials)?
                .iter()
                .filter(|(key, val)| {
                    (key.starts_with("https://auth.x.ai::")
                        || key.as_str() == "https://accounts.x.ai/sign-in")
                        && val.is_object()
                        && text(&val["key"]).is_some()
                })
                .collect();
            if entries.len() != 1 {
                return Err(Failure::Credentials);
            }
            let entry = entries[0].1;
            let expiry = if !entry["expires_at"].is_null() {
                date(&entry["expires_at"])
            } else {
                date(&entry["create_time"]).and_then(|d| d.checked_add_signed(Duration::days(30)))
            };
            if expiry.is_none_or(|d| d <= now) {
                return Err(Failure::Expired);
            }
            let token = text(&entry["key"])
                .and_then(header)
                .ok_or(Failure::Credentials)?;
            let identity = text(&entry["user_id"])
                .and_then(header)
                .ok_or(Failure::Credentials)?;
            (
                Endpoint::Grok,
                token,
                Some(identity.clone()),
                vec![
                    ("x-xai-token-auth", "xai-grok-cli".into()),
                    ("x-grok-client-mode", "cli".into()),
                    ("x-userid", identity),
                ],
            )
        }
        LocalCliKind::Kimi => {
            let renewable = text(&v["refresh_token"]).is_some();
            let token = text(&v["access_token"])
                .and_then(header)
                .ok_or(if renewable {
                    Failure::RefreshRequired
                } else {
                    Failure::Missing
                })?;
            let expiry = number(&v["expires_at"], true).ok_or(Failure::Credentials)?;
            if expiry <= now.timestamp() as f64 {
                return Err(if renewable {
                    Failure::RefreshRequired
                } else {
                    Failure::Expired
                });
            }
            let device_bytes = file(&canonical_root, "device_id")?;
            let device = std::str::from_utf8(&device_bytes)
                .ok()
                .map(str::trim)
                .and_then(header)
                .ok_or(Failure::Credentials)?;
            files.push((PathBuf::from("device_id"), device_bytes));
            let identity = text(&v["user_id"])
                .map(str::to_owned)
                .or_else(|| jwt_identity(&token));
            (
                Endpoint::Kimi,
                token,
                identity,
                vec![
                    ("X-Msh-Platform", "kimi_code_cli".into()),
                    ("X-Msh-Version", env!("CARGO_PKG_VERSION").into()),
                    ("X-Msh-Device-Id", device),
                ],
            )
        }
        LocalCliKind::OpenCode => {
            let Some(entry) = v.get("opencode-go") else {
                return Err(if v.as_object().is_some_and(|m| m.is_empty()) {
                    Failure::Missing
                } else {
                    Failure::GoNotConnected
                });
            };
            if !text(&entry["type"]).is_some_and(|s| s.eq_ignore_ascii_case("api")) {
                return Err(Failure::Credentials);
            }
            (
                Endpoint::OpenCode,
                text(&entry["key"])
                    .and_then(header)
                    .ok_or(Failure::Credentials)?,
                None,
                vec![],
            )
        }
        _ => return Err(Failure::Unavailable),
    };
    Ok(Prepared {
        request: Request {
            endpoint,
            token,
            headers,
        },
        identity,
        files,
        canonical_root,
    })
}

fn source(kind: LocalCliKind) -> &'static str {
    match kind {
        LocalCliKind::Grok => "Grok CLI billing API",
        LocalCliKind::Kimi => "Kimi Code usage API",
        _ => "OpenCode Go API",
    }
}
pub(super) fn load(kind: LocalCliKind, root: &Path, now: DateTime<Utc>) -> LocalCliQuotaResult {
    load_with(kind, root, now, &native::NativeTransport)
}
fn load_with(
    kind: LocalCliKind,
    root: &Path,
    now: DateTime<Utc>,
    transport: &dyn Transport,
) -> LocalCliQuotaResult {
    let read = || -> Result<LocalCliQuotaResult> {
        let prepared = prepare(kind, root, now)?;
        let response = transport.get(&prepared.request)?;
        // This check precedes every result, including a rejection. A reply to an
        // old identity must not mark the new identity signed out or rate-limited.
        if root.canonicalize().ok().as_ref() != Some(&prepared.canonical_root)
            || prepared.files.iter().any(|(path, bytes)| {
                file(&prepared.canonical_root, path.to_str().unwrap_or(""))
                    .ok()
                    .as_ref()
                    != Some(bytes)
            })
        {
            return Err(Failure::Changed);
        }
        match response.status {
            200 => (),
            401 | 403 => return Err(Failure::Unauthorized),
            429 => return Err(Failure::Limited),
            _ => return Err(Failure::Unavailable),
        }
        let mut result = parse(kind, &response.body, now)?;
        result = result.with_identity(prepared.identity.as_deref(), kind);
        Ok(result)
    };
    read().unwrap_or_else(|error| {
        let (state, code) = error.projection();
        LocalCliQuotaResult::new(state, now, source(kind), Some(code))
    })
}

fn window(id: &str, label: &str, used: f64, resets: Option<DateTime<Utc>>) -> LocalCliQuotaWindow {
    LocalCliQuotaWindow {
        id: id.into(),
        label: label.into(),
        used_percent: used,
        resets_at: resets,
    }
}
fn cents(v: &Value) -> Result<Option<f64>> {
    if v.is_null() {
        return Ok(None);
    }
    let object = v.as_object().ok_or(Failure::Response)?;
    let Some(raw) = object.get("val") else {
        return Ok(Some(0.0));
    };
    number(raw, false)
        .filter(|n| n.fract() == 0.0 && n.abs() <= 9_007_199_254_740_991.0)
        .map(Some)
        .ok_or(Failure::Response)
}
fn legacy_window(id: &str, label: &str, v: &Value) -> Result<LocalCliQuotaWindow> {
    let limit = number(&v["limit"], true)
        .filter(|n| *n > 0.0)
        .ok_or(Failure::Response)?;
    let used = if let Some(used) = number(&v["used"], true).filter(|n| *n >= 0.0) {
        used
    } else {
        limit
            - number(&v["remaining"], true)
                .filter(|n| *n >= 0.0 && *n <= limit)
                .ok_or(Failure::Response)?
    };
    let resets = ["resetTime", "resetAt", "reset_time", "reset_at"]
        .iter()
        .find_map(|k| date(&v[k]));
    Ok(window(id, label, (used / limit * 100.0).min(100.0), resets))
}
fn merge_legacy(
    windows: &mut Vec<LocalCliQuotaWindow>,
    ratio_pools: &[LocalCliQuotaWindow],
    id: &str,
    label: &str,
    v: &Value,
) -> Result<()> {
    if let Some(existing) = windows.iter_mut().find(|w| w.id == id) {
        if let (Some(original), Ok(candidate)) = (
            ratio_pools
                .iter()
                .find(|w| w.id == id)
                .and_then(|w| w.resets_at),
            legacy_window(id, label, v),
        ) {
            if candidate
                .resets_at
                .is_some_and(|d| (d - original).num_milliseconds().abs() <= 2000)
                && candidate.used_percent > existing.used_percent
            {
                *existing = candidate;
            }
        }
    } else {
        windows.push(legacy_window(id, label, v)?);
    }
    Ok(())
}
fn kimi_minutes(v: Option<&Value>) -> Result<Option<i64>> {
    let Some(v) = v else {
        return Ok(None);
    };
    if !v.is_object() {
        return Err(Failure::Response);
    }
    let duration = number(&v["duration"], true)
        .filter(|n| *n > 0.0 && n.fract() == 0.0)
        .ok_or(Failure::Response)?;
    let factor = match text(&v["timeUnit"]).unwrap_or("") {
        s if s.contains("MINUTE") => 1.0,
        s if s.contains("HOUR") => 60.0,
        s if s.contains("DAY") => 1440.0,
        "" => 1.0,
        _ => return Err(Failure::Response),
    };
    let total = duration * factor;
    if !total.is_finite() || total >= i64::MAX as f64 {
        return Err(Failure::Response);
    }
    Ok(Some(total as i64))
}
fn parse(kind: LocalCliKind, bytes: &[u8], now: DateTime<Utc>) -> Result<LocalCliQuotaResult> {
    let v = object(bytes)?;
    let mut result =
        LocalCliQuotaResult::new(LocalCliQuotaState::Available, now, source(kind), None);
    match kind {
        LocalCliKind::Grok => {
            let c = v
                .get("config")
                .filter(|v| v.is_object())
                .ok_or(Failure::Response)?;
            result.plan_label =
                plan(&c["subscriptionTier"]).or_else(|| plan(&v["subscriptionTier"]));
            let reset = date(&c["currentPeriod"]["end"]).or_else(|| date(&c["billingPeriodEnd"]));
            result.period_resets_at = reset;
            let used = if !c["creditUsagePercent"].is_null() {
                Some(percent(&c["creditUsagePercent"])?)
            } else if let (Some(limit), Some(used)) =
                (cents(&c["monthlyLimit"])?, cents(&c["used"])?)
            {
                if limit > 0.0 && used >= 0.0 {
                    Some(percent(&serde_json::json!(used / limit * 100.0))?)
                } else {
                    None
                }
            } else {
                None
            };
            if let Some(used) = used {
                let label = match text(&c["currentPeriod"]["type"]) {
                    Some("USAGE_PERIOD_TYPE_WEEKLY") => "7-day",
                    Some("USAGE_PERIOD_TYPE_MONTHLY") => "Monthly",
                    _ => "Credits",
                };
                result.windows.push(window("credits", label, used, reset));
            } else {
                result.message_code = Some("local_cli_usage_not_reported".into());
            }
            result.balance = cents(&c["prepaidBalance"])?.map(|n| n.abs() / 100.0);
            result.balance_currency = result.balance.map(|_| "USD".into());
        }
        LocalCliKind::Kimi => {
            result.plan_label = plan(&v["planName"]).or_else(|| plan(&v["plan_name"]));
            if !v["usages"].is_null() {
                let pools = v["usages"].as_object().ok_or(Failure::Response)?;
                for (key, id, label) in [
                    ("limit_5h", "session", "5-hour"),
                    ("limit_7d", "weekly", "7-day"),
                    ("limit_month_total", "monthly", "Monthly"),
                    ("limit_month_code", "monthly-code", "Monthly Code"),
                ] {
                    if let Some(pool) = pools.get(key).filter(|v| !v.is_null()) {
                        if !pool.is_object() {
                            return Err(Failure::Response);
                        }
                        if !pool["used_ratio"].is_null() {
                            let used = number(&pool["used_ratio"], true)
                                .filter(|n| *n >= 0.0)
                                .ok_or(Failure::Response)?;
                            result.windows.push(window(
                                id,
                                label,
                                used.min(1.0) * 100.0,
                                date(&pool["reset_time"]),
                            ));
                        }
                    }
                }
            }
            let ratio_pools = result.windows.clone();
            if v["usage"].is_object() {
                merge_legacy(
                    &mut result.windows,
                    &ratio_pools,
                    "weekly",
                    "7-day",
                    &v["usage"],
                )?;
            } else if !v["usage"].is_null() && !result.windows.iter().any(|w| w.id == "weekly") {
                return Err(Failure::Response);
            }
            if !v["limits"].is_null() {
                let limits = v["limits"]
                    .as_array()
                    .filter(|a| a.len() <= 256)
                    .ok_or(Failure::Response)?;
                for (index, item) in limits.iter().enumerate() {
                    if !item.is_object() {
                        return Err(Failure::Response);
                    }
                    let minutes = kimi_minutes(item.get("window"))?;
                    let (id, label) = match minutes {
                        Some(300) => ("session".into(), "5-hour"),
                        Some(10080) => ("weekly".into(), "7-day"),
                        _ => (format!("limit-{index}-{}", minutes.unwrap_or(0)), "Usage"),
                    };
                    let detail = item.get("detail").filter(|v| v.is_object()).unwrap_or(item);
                    merge_legacy(&mut result.windows, &ratio_pools, &id, label, detail)?;
                }
            }
            if result.windows.is_empty() {
                return Err(Failure::Response);
            }
        }
        LocalCliKind::OpenCode => {
            let usage = v
                .get("usage")
                .filter(|v| v.is_object())
                .ok_or(Failure::Response)?;
            for (key, label) in [
                ("rolling", "Rolling"),
                ("weekly", "7-day"),
                ("monthly", "Monthly"),
            ] {
                let Some(value) = usage.get(key).filter(|v| !v.is_null()) else {
                    continue;
                };
                if !value.is_object() {
                    return Err(Failure::Response);
                }
                let used = if text(&value["status"]) == Some("rate-limited") {
                    if let Some(value) = value.get("percent") {
                        percent(value)?;
                    }
                    100.0
                } else {
                    percent(&value["percent"])?
                };
                result
                    .windows
                    .push(window(key, label, used, date(&value["resetsAt"])));
            }
        }
        _ => return Err(Failure::Unavailable),
    }
    if !valid_windows(&result.windows) {
        return Err(Failure::Response);
    }
    Ok(result)
}

#[cfg(test)]
mod tests;
