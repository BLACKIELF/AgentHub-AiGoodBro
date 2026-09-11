use std::{
    collections::BTreeSet,
    env,
    net::Ipv4Addr,
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};

use chrono::{DateTime, TimeZone, Utc};
use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use tokio::{
    net::{TcpListener, TcpStream},
    process::{Child, Command},
    time::{sleep, timeout, Instant},
};
use tokio_tungstenite::{connect_async, tungstenite::Message, MaybeTlsStream, WebSocketStream};

use crate::models::{AccountInfo, RateWindow};

const FIVE_HOUR_DURATION_MINS: i64 = 300;
const SEVEN_DAY_DURATION_MINS: i64 = 10_080;
const MONTHLY_MIN_DURATION_MINS: i64 = 28 * 24 * 60;
const MONTHLY_MAX_DURATION_MINS: i64 = 31 * 24 * 60;
const APP_SERVER_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const APP_SERVER_REQUEST_TIMEOUT: Duration = Duration::from_secs(12);

/// Official rate-limit data read from the local Codex app-server.
#[derive(Debug, Clone, PartialEq)]
pub struct CodexAppServerQuotaSnapshot {
    pub account: Option<AccountInfo>,
    pub limit_id: Option<String>,
    pub limit_name: Option<String>,
    pub quota_read_succeeded: bool,
    pub five_hour_quota: Option<RateWindow>,
    pub seven_day_quota: Option<RateWindow>,
    pub monthly_quota: Option<RateWindow>,
    pub available_reset_credits: Option<u32>,
    pub reset_credit_expiries: Option<Vec<DateTime<Utc>>>,
}

impl CodexAppServerQuotaSnapshot {
    /// Parses an `account/rateLimits/read` result without treating unknown or
    /// malformed topology as an official zero-limit response.
    pub fn from_rate_limit_response(response: &Value) -> Self {
        let Some(limits) = selected_rate_limits(response) else {
            return Self::unavailable();
        };

        let raw_windows = [limits.get("primary"), limits.get("secondary")];
        let has_window_fields = raw_windows.iter().any(|window| window.is_some());
        let parsed_windows = raw_windows.map(|window| window.and_then(parse_rate_window));
        let has_malformed_window =
            raw_windows
                .iter()
                .zip(parsed_windows.iter())
                .any(|(raw, parsed)| {
                    matches!(raw, Some(value) if !value.is_null()) && parsed.is_none()
                });

        let available = parsed_windows.iter().flatten().cloned().collect::<Vec<_>>();
        let five_hour_matches = available
            .iter()
            .filter(|window| window.window_duration_mins == Some(FIVE_HOUR_DURATION_MINS))
            .cloned()
            .collect::<Vec<_>>();
        let seven_day_matches = available
            .iter()
            .filter(|window| window.window_duration_mins == Some(SEVEN_DAY_DURATION_MINS))
            .cloned()
            .collect::<Vec<_>>();
        let monthly_matches = available
            .iter()
            .filter(|window| is_monthly_duration(window.window_duration_mins))
            .cloned()
            .collect::<Vec<_>>();
        let has_unclassified_window = available.iter().any(|window| {
            !matches!(
                window.window_duration_mins,
                Some(FIVE_HOUR_DURATION_MINS | SEVEN_DAY_DURATION_MINS)
            ) && !is_monthly_duration(window.window_duration_mins)
        });

        let quota_read_succeeded = has_window_fields
            && !has_malformed_window
            && five_hour_matches.len() <= 1
            && seven_day_matches.len() <= 1
            && monthly_matches.len() <= 1
            && !has_unclassified_window;

        if !quota_read_succeeded {
            return Self::unavailable();
        }

        let (available_reset_credits, reset_credit_expiries) = parse_reset_credits(limits);

        Self {
            account: None,
            limit_id: limits
                .get("limitId")
                .and_then(Value::as_str)
                .map(str::to_owned),
            limit_name: limits
                .get("limitName")
                .and_then(Value::as_str)
                .map(str::to_owned),
            quota_read_succeeded,
            five_hour_quota: single_window(five_hour_matches),
            seven_day_quota: single_window(seven_day_matches),
            monthly_quota: single_window(monthly_matches),
            available_reset_credits,
            reset_credit_expiries,
        }
    }

    pub fn unavailable() -> Self {
        Self {
            account: None,
            limit_id: None,
            limit_name: None,
            quota_read_succeeded: false,
            five_hour_quota: None,
            seven_day_quota: None,
            monthly_quota: None,
            available_reset_credits: None,
            reset_credit_expiries: None,
        }
    }
}

/// Minimal boundary required to exercise the Codex JSON-RPC request sequence
/// without starting a real app-server in parser tests.
#[allow(async_fn_in_trait)]
pub trait AppServerTransport {
    async fn request(&mut self, request: Value) -> anyhow::Result<Value>;
    async fn notify(&mut self, notification: Value) -> anyhow::Result<()>;
}

/// Reads the installed Codex CLI through a short-lived loopback-only
/// app-server. The API calls themselves are read-only account lookups.
pub async fn read_installed_codex_quota() -> anyhow::Result<CodexAppServerQuotaSnapshot> {
    read_codex_quota(None).await
}

/// Same as [`read_installed_codex_quota`], with an optional `CODEX_HOME`.
///
/// Managed profiles isolate their login under a dedicated directory. Passing
/// that directory here is the only way to read their official quota without
/// guessing or mixing it with the system login.
pub async fn read_codex_quota(
    codex_home: Option<&Path>,
) -> anyhow::Result<CodexAppServerQuotaSnapshot> {
    let port = reserve_loopback_port().await?;
    let mut child = launch_app_server(port, codex_home)?;
    let endpoint = format!("ws://127.0.0.1:{port}");

    let result = timeout(APP_SERVER_REQUEST_TIMEOUT, async {
        let mut transport = connect_loopback_transport(&endpoint).await?;
        read_quota_from_transport(&mut transport).await
    })
    .await
    .map_err(|_| anyhow::anyhow!("Timed out while reading the local Codex app-server quota"));

    stop_child(&mut child).await;
    result?
}

struct WebSocketAppServerTransport {
    socket: WebSocketStream<MaybeTlsStream<TcpStream>>,
}

#[allow(async_fn_in_trait)]
impl AppServerTransport for WebSocketAppServerTransport {
    async fn request(&mut self, request: Value) -> anyhow::Result<Value> {
        let request_id = request
            .get("id")
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("App-server quota request was missing an id"))?;
        self.socket
            .send(Message::Text(request.to_string().into()))
            .await
            .map_err(|_| anyhow::anyhow!("Failed to send a quota request to Codex app-server"))?;

        while let Some(next) = self.socket.next().await {
            let message =
                next.map_err(|_| anyhow::anyhow!("Codex app-server connection failed"))?;
            let payload = match message {
                Message::Text(value) => value.to_string(),
                Message::Binary(value) => String::from_utf8(value.to_vec()).map_err(|_| {
                    anyhow::anyhow!("Codex app-server returned non-UTF-8 quota data")
                })?,
                Message::Close(_) => anyhow::bail!("Codex app-server closed the quota connection"),
                Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => continue,
            };
            let response = serde_json::from_str::<Value>(&payload)
                .map_err(|_| anyhow::anyhow!("Codex app-server returned malformed quota data"))?;
            if response.get("id") == Some(&request_id) {
                return Ok(response);
            }
        }

        anyhow::bail!("Codex app-server ended before responding to the quota request")
    }

    async fn notify(&mut self, notification: Value) -> anyhow::Result<()> {
        self.socket
            .send(Message::Text(notification.to_string().into()))
            .await
            .map_err(|_| anyhow::anyhow!("Failed to complete Codex app-server initialization"))
    }
}

/// Performs the read-only account and rate-limit request sequence after a
/// transport has connected to a local Codex app-server.
pub async fn read_quota_from_transport<T: AppServerTransport>(
    transport: &mut T,
) -> anyhow::Result<CodexAppServerQuotaSnapshot> {
    request_result(
        transport,
        serde_json::json!({
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "aigoodbro",
                    "title": "AiGoodBro",
                    "version": env!("CARGO_PKG_VERSION")
                },
                "capabilities": {
                    "experimentalApi": true,
                    "optOutNotificationMethods": []
                }
            }
        }),
    )
    .await?;
    transport
        .notify(serde_json::json!({ "method": "initialized" }))
        .await?;

    let account_result = request_result(
        transport,
        serde_json::json!({
            "id": 2,
            "method": "account/read",
            "params": { "refreshToken": false }
        }),
    )
    .await?;
    let rate_limits_result = request_result(
        transport,
        serde_json::json!({ "id": 3, "method": "account/rateLimits/read" }),
    )
    .await?;

    let mut quota = CodexAppServerQuotaSnapshot::from_rate_limit_response(&rate_limits_result);
    quota.account = parse_account(&account_result);
    Ok(quota)
}

async fn request_result<T: AppServerTransport>(
    transport: &mut T,
    request: Value,
) -> anyhow::Result<Value> {
    let response = transport.request(request).await?;
    if response.get("error").is_some() {
        anyhow::bail!("Codex app-server rejected a read-only quota request")
    }
    response
        .get("result")
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("Codex app-server returned no result for a quota request"))
}

fn parse_account(value: &Value) -> Option<AccountInfo> {
    let account = value.get("account")?;
    Some(AccountInfo {
        r#type: account.get("type")?.as_str()?.to_owned(),
        plan_type: account
            .get("planType")
            .and_then(Value::as_str)
            .map(str::to_owned),
        email_present: account.get("email").is_some_and(|email| !email.is_null()),
    })
}

fn selected_rate_limits(response: &Value) -> Option<&Value> {
    response
        .get("rateLimitsByLimitId")
        .and_then(|buckets| buckets.get("codex"))
        .or_else(|| response.get("rateLimits"))
        .filter(|value| value.is_object())
}

fn launch_app_server(port: u16, codex_home: Option<&Path>) -> anyhow::Result<Child> {
    let executable = resolve_codex_executable()
        .ok_or_else(|| anyhow::anyhow!("Could not locate the installed Codex CLI executable"))?;
    let mut command = Command::new(executable);
    command
        .args(["app-server", "--listen", &format!("ws://127.0.0.1:{port}")])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    if let Some(home) = codex_home {
        command.env("CODEX_HOME", home);
    }
    command
        .spawn()
        .map_err(|_| anyhow::anyhow!("Could not launch the installed Codex CLI"))
}

fn resolve_codex_executable() -> Option<PathBuf> {
    if let Some(app_data) = env::var_os("APPDATA") {
        let (package, triple) = if cfg!(target_arch = "aarch64") {
            ("codex-win32-arm64", "aarch64-pc-windows-msvc")
        } else {
            ("codex-win32-x64", "x86_64-pc-windows-msvc")
        };
        let candidate = PathBuf::from(app_data)
            .join("npm")
            .join("node_modules")
            .join("@openai")
            .join("codex")
            .join("node_modules")
            .join("@openai")
            .join(package)
            .join("vendor")
            .join(triple)
            .join("bin")
            .join("codex.exe");
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    executable_on_path("codex.exe").or_else(|| executable_on_path("codex"))
}

fn executable_on_path(name: &str) -> Option<PathBuf> {
    let path = env::var_os("PATH")?;
    env::split_paths(&path).find_map(|directory| {
        let candidate = directory.join(name);
        candidate.is_file().then_some(candidate)
    })
}

async fn reserve_loopback_port() -> anyhow::Result<u16> {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
        .await
        .map_err(|_| anyhow::anyhow!("Could not reserve a loopback port for Codex app-server"))?;
    let port = listener
        .local_addr()
        .map_err(|_| anyhow::anyhow!("Could not inspect the Codex app-server loopback port"))?
        .port();
    drop(listener);
    Ok(port)
}

async fn connect_loopback_transport(endpoint: &str) -> anyhow::Result<WebSocketAppServerTransport> {
    let deadline = Instant::now() + APP_SERVER_CONNECT_TIMEOUT;
    loop {
        match connect_async(endpoint).await {
            Ok((socket, _)) => return Ok(WebSocketAppServerTransport { socket }),
            Err(_) if Instant::now() < deadline => sleep(Duration::from_millis(50)).await,
            Err(_) => anyhow::bail!("Could not connect to the local Codex app-server"),
        }
    }
}

async fn stop_child(child: &mut Child) {
    if child.try_wait().ok().flatten().is_none() {
        let _ = child.start_kill();
        let _ = timeout(Duration::from_secs(1), child.wait()).await;
    }
}

fn parse_rate_window(value: &Value) -> Option<RateWindow> {
    let used_percent = value.get("usedPercent")?.as_f64()?;
    if !used_percent.is_finite() {
        return None;
    }
    let resets_at = value
        .get("resetsAt")
        .and_then(Value::as_i64)
        .and_then(|seconds| Utc.timestamp_opt(seconds, 0).single());

    Some(RateWindow {
        used_percent,
        window_duration_mins: value.get("windowDurationMins").and_then(Value::as_i64),
        resets_at,
    })
}

fn is_monthly_duration(duration_mins: Option<i64>) -> bool {
    matches!(duration_mins, Some(duration) if (MONTHLY_MIN_DURATION_MINS..=MONTHLY_MAX_DURATION_MINS).contains(&duration))
}

fn single_window(mut matches: Vec<RateWindow>) -> Option<RateWindow> {
    (matches.len() == 1).then(|| matches.remove(0))
}

/// Port of macOS `CodexUsageReader` reset-credit parsing. Unknown or malformed
/// payloads stay unknown; they are never coerced to zero.
fn parse_reset_credits(limits: &Value) -> (Option<u32>, Option<Vec<DateTime<Utc>>>) {
    let Some(reset) = limits.get("rateLimitResetCredits") else {
        return (None, None);
    };
    if reset.is_null() {
        return (None, None);
    }
    let Some(count) = exact_non_negative_count(reset.get("availableCount")) else {
        return (None, None);
    };

    match reset.get("credits") {
        None | Some(Value::Null) => (Some(count), None),
        Some(Value::Array(rows)) if rows.len() <= 1_024 => {
            let mut seen = BTreeSet::new();
            let mut expiries = Vec::new();
            for row in rows {
                let Some(object) = row.as_object() else {
                    return (None, None);
                };
                let Some(id) = object
                    .get("id")
                    .and_then(Value::as_str)
                    .filter(|value| reset_valid_field(value, 512))
                else {
                    return (None, None);
                };
                if !seen.insert(id.to_string()) {
                    return (None, None);
                }
                let status = object.get("status").and_then(Value::as_str);
                let reset_type = object.get("resetType").and_then(Value::as_str);
                let Some(expiry) = parse_reset_expiry(object.get("expiresAt")) else {
                    return (None, None);
                };
                if status == Some("available") && reset_type == Some("codexRateLimits") {
                    if let Some(at) = expiry {
                        expiries.push(at);
                    }
                }
            }
            expiries.sort();
            (
                Some(count),
                if expiries.is_empty() {
                    None
                } else {
                    Some(expiries)
                },
            )
        }
        _ => (None, None),
    }
}

fn exact_non_negative_count(value: Option<&Value>) -> Option<u32> {
    let value = value?;
    let count = if let Some(number) = value.as_u64() {
        u32::try_from(number).ok()?
    } else if let Some(number) = value.as_i64() {
        u32::try_from(number).ok()?
    } else {
        return None;
    };
    (count <= 1_000_000).then_some(count)
}

fn parse_reset_expiry(value: Option<&Value>) -> Option<Option<DateTime<Utc>>> {
    match value {
        None | Some(Value::Null) => Some(None),
        Some(Value::Number(number)) => {
            let seconds = number.as_i64()?;
            Utc.timestamp_opt(seconds, 0).single().map(Some)
        }
        _ => None,
    }
}

fn reset_valid_field(value: &str, maximum_bytes: usize) -> bool {
    !value.is_empty()
        && value.len() <= maximum_bytes
        && !value.chars().any(|ch| ch.is_control())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reset_credits_follow_the_macos_payload_shape() {
        let quota = CodexAppServerQuotaSnapshot::from_rate_limit_response(&json!({
            "rateLimits": {
                "limitId": "codex",
                "limitName": "Codex",
                "primary": {
                    "usedPercent": 10,
                    "windowDurationMins": 300,
                    "resetsAt": 1_800_000_000
                },
                "secondary": {
                    "usedPercent": 20,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_800_100_000
                },
                "rateLimitResetCredits": {
                    "availableCount": 2,
                    "credits": [
                        {
                            "id": "card-b",
                            "status": "available",
                            "resetType": "codexRateLimits",
                            "expiresAt": 1_800_200_000
                        },
                        {
                            "id": "card-a",
                            "status": "available",
                            "resetType": "codexRateLimits",
                            "expiresAt": 1_800_050_000
                        }
                    ]
                }
            }
        }));

        assert!(quota.quota_read_succeeded);
        assert_eq!(quota.available_reset_credits, Some(2));
        let expiries = quota.reset_credit_expiries.expect("expiries");
        assert_eq!(expiries.len(), 2);
        assert!(expiries[0] < expiries[1]);
    }

    #[test]
    fn malformed_reset_credits_stay_unknown() {
        let quota = CodexAppServerQuotaSnapshot::from_rate_limit_response(&json!({
            "rateLimits": {
                "limitId": "codex",
                "limitName": "Codex",
                "primary": {
                    "usedPercent": 10,
                    "windowDurationMins": 300,
                    "resetsAt": 1_800_000_000
                },
                "rateLimitResetCredits": {
                    "availableCount": -1
                }
            }
        }));

        assert!(quota.quota_read_succeeded);
        assert_eq!(quota.available_reset_credits, None);
        assert_eq!(quota.reset_credit_expiries, None);
    }
}
