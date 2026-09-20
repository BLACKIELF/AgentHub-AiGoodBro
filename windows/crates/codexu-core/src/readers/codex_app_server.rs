use std::{env, net::Ipv4Addr, path::PathBuf, process::Stdio, time::Duration};

use chrono::{TimeZone, Utc};
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
    read_quota_with_home(None).await
}

pub async fn read_codex_quota_for_home(
    home: &std::path::Path,
) -> anyhow::Result<CodexAppServerQuotaSnapshot> {
    anyhow::ensure!(
        home.is_absolute() && home.is_dir(),
        "Codex directory unavailable"
    );
    read_quota_with_home(Some(home)).await
}

async fn read_quota_with_home(
    home: Option<&std::path::Path>,
) -> anyhow::Result<CodexAppServerQuotaSnapshot> {
    let port = reserve_loopback_port().await?;
    let mut child = launch_app_server(port, home)?;
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
                    "name": "codex-account-manager-next",
                    "title": "Codex Account Manager Next",
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

fn launch_app_server(port: u16, home: Option<&std::path::Path>) -> anyhow::Result<Child> {
    let executable = resolve_codex_executable()
        .ok_or_else(|| anyhow::anyhow!("Could not locate the installed Codex CLI executable"))?;
    app_server_command(&executable, port, home)
        .spawn()
        .map_err(|_| anyhow::anyhow!("Could not launch the installed Codex CLI"))
}

fn app_server_command(
    executable: &std::path::Path,
    port: u16,
    home: Option<&std::path::Path>,
) -> Command {
    let mut command = Command::new(executable);
    if let Some(home) = home {
        command.env("CODEX_HOME", home);
    }
    command
        .args(["app-server", "--listen", &format!("ws://127.0.0.1:{port}")])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    command
}

#[cfg(test)]
mod command_tests {
    use super::*;

    #[test]
    fn selected_home_is_child_only_and_listener_is_loopback() {
        let prior = env::var_os("CODEX_HOME");
        let home = env::temp_dir().join("synthetic-selected-codex");
        let command = app_server_command(
            std::path::Path::new("synthetic-codex.exe"),
            12345,
            Some(&home),
        );
        let envs: Vec<_> = command.as_std().get_envs().collect();
        assert_eq!(
            envs,
            vec![(std::ffi::OsStr::new("CODEX_HOME"), Some(home.as_os_str()))]
        );
        let args: Vec<_> = command
            .as_std()
            .get_args()
            .map(|arg| arg.to_str().unwrap())
            .collect();
        assert_eq!(args, ["app-server", "--listen", "ws://127.0.0.1:12345"]);
        assert_eq!(env::var_os("CODEX_HOME"), prior);
        let default = app_server_command(std::path::Path::new("synthetic-codex.exe"), 12345, None);
        assert_eq!(default.as_std().get_envs().count(), 0);
    }
}

fn resolve_codex_executable() -> Option<PathBuf> {
    let app_data = env::var_os("APPDATA")?;
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
    candidate.is_file().then_some(candidate)
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
