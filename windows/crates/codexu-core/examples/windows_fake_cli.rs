//! Test-only fake Codex app-server for native Windows owned-process checks.
//! It binds only the reader's loopback WebSocket endpoint and returns static
//! evidence; it never reads credentials or calls an upstream model service.

use anyhow::{bail, ensure, Context, Result};
use codexu_core::workflow_reader;
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::{
    env, fs,
    net::Ipv4Addr,
    path::PathBuf,
    process::{Child, Command, Stdio},
    time::Duration,
};
use tokio::{
    net::TcpListener,
    time::{sleep, timeout, Instant},
};
use tokio_tungstenite::{accept_async, tungstenite::Message};
use url::Url;

const CHILD_LIFETIME: Duration = Duration::from_secs(60);
const ACCEPT_TIMEOUT: Duration = Duration::from_secs(15);
const FRAME_TIMEOUT: Duration = Duration::from_secs(15);
const EXIT_MARKER_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Debug)]
struct Options {
    endpoint: String,
    child_pid_file: Option<PathBuf>,
    control_dir: Option<PathBuf>,
}

fn options(args: &[String]) -> Result<Options> {
    if args.first().map(String::as_str) == Some("--child-sleeper") {
        bail!("child mode must be handled before app-server argument parsing");
    }
    let app_server = args
        .iter()
        .position(|arg| arg == "app-server")
        .context("missing app-server argument")?;
    ensure!(
        args.get(app_server + 1).map(String::as_str) == Some("--listen"),
        "app-server must accept --listen"
    );
    let endpoint = args
        .get(app_server + 2)
        .context("missing app-server WebSocket endpoint")?
        .clone();
    let mut child_pid_file = None;
    let mut control_dir = None;
    let mut index = app_server + 3;
    while index < args.len() {
        match args[index].as_str() {
            "--fixture-child-pid-file" => {
                index += 1;
                child_pid_file = Some(PathBuf::from(
                    args.get(index).context("missing child PID file")?,
                ));
            }
            "--fixture-control-dir" => {
                index += 1;
                control_dir = Some(PathBuf::from(
                    args.get(index)
                        .context("missing fixture control directory")?,
                ));
            }
            // The official reader passes --config name=value pairs before
            // app-server; unknown flags after --listen are rejected.
            other => bail!("unexpected fake CLI argument: {other}"),
        }
        index += 1;
    }
    ensure!(
        child_pid_file.is_some() == control_dir.is_some(),
        "child PID file and control directory must be supplied together"
    );
    Ok(Options {
        endpoint,
        child_pid_file,
        control_dir,
    })
}

async fn child_sleeper(pid_file: PathBuf) -> Result<()> {
    if let Some(parent) = pid_file.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(pid_file, std::process::id().to_string())?;
    // A deliberately bounded sleeper. On Windows the owning Job should end
    // it much sooner than this after the root and child membership are checked.
    sleep(CHILD_LIFETIME).await;
    Ok(())
}

fn spawn_child(pid_file: &PathBuf) -> Result<Child> {
    let executable = env::current_exe()?;
    let child = Command::new(executable)
        .arg("--child-sleeper")
        .arg(pid_file)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .context("could not start fake CLI child")?;
    Ok(child)
}

fn endpoint_port(endpoint: &str) -> Result<u16> {
    let parsed = Url::parse(endpoint).context("invalid --listen endpoint")?;
    ensure!(
        parsed.scheme() == "ws"
            && parsed.host_str() == Some("127.0.0.1")
            && parsed.path() == "/"
            && parsed.username().is_empty()
            && parsed.password().is_none()
            && parsed.query().is_none()
            && parsed.fragment().is_none(),
        "fake CLI only accepts a plain loopback WebSocket endpoint"
    );
    parsed.port().context("missing --listen port")
}

fn response(method: &str) -> Result<Value> {
    match method {
        "initialize" => Ok(json!({"userAgent":"windows-fake-cli"})),
        "config/read" => Ok(json!({"config":{
            "model_provider":"openai",
            "openai_base_url":"https://chatgpt.com/backend-api/codex",
            "chatgpt_base_url":"https://chatgpt.com/backend-api/",
            "forced_login_method":"chatgpt",
            "cli_auth_credentials_store":"file"
        }})),
        "account/read" => Ok(json!({"account":{"type":"chatgpt","planType":"fixture-plan"}})),
        "account/rateLimits/read" => {
            Ok(json!({"rateLimitsByLimitId":{"codex":{"planType":"fixture-plan"}}}))
        }
        "model/list" => Ok(json!({
            "data":[{
                "id":"windows-fake-model",
                "model":"windows-fake-model",
                "displayName":"Windows Fake Model",
                "isDefault":true,
                "defaultReasoningEffort":"high",
                "supportedReasoningEfforts":[
                    {"reasoningEffort":"high"},
                    {"reasoningEffort":"low"}
                ]
            }],
            "nextCursor":null
        })),
        other => bail!("unexpected fake CLI method: {other}"),
    }
}

async fn wait_for_root_exit(control_dir: &PathBuf) -> Result<()> {
    let marker = control_dir.join("exit-root");
    let deadline = Instant::now() + EXIT_MARKER_TIMEOUT;
    while !marker.exists() {
        ensure!(
            Instant::now() < deadline,
            "fake CLI root exit marker timed out"
        );
        sleep(Duration::from_millis(10)).await;
    }
    Ok(())
}

async fn run_app_server(options: Options) -> Result<()> {
    let port = endpoint_port(&options.endpoint)?;
    let _child = if let Some(pid_file) = &options.child_pid_file {
        Some(spawn_child(pid_file)?)
    } else {
        None
    };
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, port))
        .await
        .context("could not bind fake CLI loopback endpoint")?;
    let (stream, peer) = timeout(ACCEPT_TIMEOUT, listener.accept())
        .await
        .context("fake CLI accept timed out")??;
    ensure!(
        peer.ip().is_loopback(),
        "fake CLI rejected a non-loopback peer"
    );
    let mut socket = timeout(FRAME_TIMEOUT, accept_async(stream))
        .await
        .context("fake CLI WebSocket handshake timed out")??;
    loop {
        let frame = timeout(FRAME_TIMEOUT, socket.next())
            .await
            .context("fake CLI request timed out")?;
        let Some(frame) = frame else {
            bail!("workflow reader closed the fake CLI connection early");
        };
        let message = frame.context("fake CLI WebSocket receive failed")?;
        let payload = match message {
            Message::Text(value) => value.to_string(),
            Message::Binary(value) => String::from_utf8(value.to_vec())?,
            Message::Close(_) => bail!("workflow reader closed before model/list"),
            _ => continue,
        };
        let request: Value = serde_json::from_str(&payload)?;
        let Some(id) = request.get("id").cloned() else {
            // initialized is a notification and expects no response.
            continue;
        };
        let method = request
            .get("method")
            .and_then(Value::as_str)
            .context("fake CLI request has no method")?;
        let result = response(method)?;
        socket
            .send(Message::Text(
                json!({"id":id,"result":result}).to_string().into(),
            ))
            .await?;
        if method == "model/list" {
            if let Some(control_dir) = &options.control_dir {
                wait_for_root_exit(control_dir).await?;
            }
            return Ok(());
        }
    }
}

async fn protocol_smoke() -> Result<()> {
    let executable = env::current_exe()?;
    let home = tempfile::tempdir()?;
    let workspace = tempfile::tempdir()?;
    let evidence = workflow_reader::read_evidence_with_timeout(
        &executable,
        home.path(),
        workspace.path(),
        Duration::from_secs(10),
    )
    .await?;
    ensure!(
        evidence.models.len() == 1
            && evidence.models[0].id == "windows-fake-model"
            && evidence.official_plan_type() == Some("fixture-plan"),
        "fake CLI protocol smoke returned unexpected evidence"
    );
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = env::args().skip(1).collect::<Vec<_>>();
    if args.first().map(String::as_str) == Some("--protocol-smoke") {
        return protocol_smoke().await;
    }
    if args.first().map(String::as_str) == Some("--child-sleeper") {
        let pid_file = args.get(1).context("child sleeper needs a PID file path")?;
        return child_sleeper(PathBuf::from(pid_file)).await;
    }
    run_app_server(options(&args)?).await
}
