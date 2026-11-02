//! Short-lived read-only evidence from the same native CLI used for launch.
use crate::workflow::{
    official_arguments, parse_models, validate_official_config, validate_startup, WorkflowModel,
    EXTERNAL_API_ENVIRONMENT,
};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::{net::Ipv4Addr, path::Path, process::Stdio, time::Duration};
use tokio::{
    net::{TcpListener, TcpStream},
    process::Command,
    time::{sleep, timeout, Instant},
};
use tokio_tungstenite::{connect_async, tungstenite::Message, MaybeTlsStream, WebSocketStream};

type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;

pub struct WorkflowEvidence {
    pub models: Vec<WorkflowModel>,
    account: Value,
    rate_limits: Value,
}

/// Lifecycle contract for a native owner which controls both the probe root
/// and its complete Windows Job. A successful stop must be followed by a
/// positive `has_exited` result before the owner can be released.
pub trait WorkflowProbeOwner: Send {
    fn has_exited(&mut self) -> std::io::Result<bool>;
    fn stop(&mut self) -> std::io::Result<()>;
    fn exit_success(&mut self) -> std::io::Result<bool>;
}

pub struct WorkflowProbeLaunchFailure<P> {
    error: anyhow::Error,
    owner: Option<P>,
}
impl<P> WorkflowProbeLaunchFailure<P> {
    pub fn before_spawn(error: impl Into<anyhow::Error>) -> Self {
        Self {
            error: error.into(),
            owner: None,
        }
    }
    pub fn after_spawn(error: impl Into<anyhow::Error>, owner: P) -> Self {
        Self {
            error: error.into(),
            owner: Some(owner),
        }
    }
    fn into_parts(self) -> (anyhow::Error, Option<P>) {
        (self.error, self.owner)
    }
}

pub struct WorkflowReadFailure<P> {
    error: anyhow::Error,
    owner: Option<P>,
}
impl<P> WorkflowReadFailure<P> {
    pub fn into_parts(self) -> (anyhow::Error, Option<P>) {
        (self.error, self.owner)
    }
}

fn cleanup_probe_owner<P: WorkflowProbeOwner>(owner: &mut P) -> std::io::Result<Option<bool>> {
    match owner.has_exited() {
        Ok(true) => owner.exit_success().map(Some),
        Ok(false) | Err(_) => {
            owner.stop()?;
            if owner.has_exited()? {
                // The process was deliberately stopped. Its exit code is not
                // the result of the read-only evidence operation.
                Ok(None)
            } else {
                Err(std::io::Error::other(
                    "Workflow probe owner did not confirm an empty process tree",
                ))
            }
        }
    }
}

impl WorkflowEvidence {
    /// Current official account plan from the same fresh read used for model
    /// discovery. The verified Hub snapshot is checked against this value by
    /// native dispatch before the authority is passed to the Hub.
    pub fn official_plan_type(&self) -> Option<&str> {
        let limits = if let Some(buckets) = self
            .rate_limits
            .get("rateLimitsByLimitId")
            .filter(|value| !value.is_null())
        {
            buckets.get("codex")
        } else {
            self.rate_limits.get("rateLimits")
        }?;
        limits.get("planType").and_then(Value::as_str).or_else(|| {
            self.account
                .pointer("/account/planType")
                .and_then(Value::as_str)
        })
    }

    pub fn validate_startup(&self) -> anyhow::Result<()> {
        validate_startup(
            &self.account,
            &self.rate_limits,
            chrono::Utc::now().timestamp(),
        )
    }
}

async fn request(
    socket: &mut Socket,
    id: u64,
    method: &str,
    params: Value,
) -> anyhow::Result<Value> {
    socket
        .send(Message::Text(
            json!({"id":id,"method":method,"params":params})
                .to_string()
                .into(),
        ))
        .await?;
    while let Some(message) = socket.next().await {
        let payload = match message? {
            Message::Text(value) => value.to_string(),
            Message::Binary(value) => String::from_utf8(value.to_vec())?,
            Message::Close(_) => anyhow::bail!("CLI closed read-only connection"),
            _ => continue,
        };
        anyhow::ensure!(payload.len() <= 1024 * 1024, "CLI response too large");
        let value: Value = serde_json::from_str(&payload)?;
        if value.get("id").and_then(Value::as_u64) != Some(id) {
            continue;
        }
        anyhow::ensure!(
            value.get("error").is_none(),
            "CLI read-only request rejected"
        );
        return value
            .get("result")
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("CLI result missing"));
    }
    anyhow::bail!("CLI connection ended")
}

pub async fn read_evidence(
    executable: &Path,
    home: &Path,
    workspace: &Path,
) -> anyhow::Result<WorkflowEvidence> {
    read_evidence_with_timeout(executable, home, workspace, Duration::from_secs(20)).await
}

pub async fn read_evidence_with_timeout(
    executable: &Path,
    home: &Path,
    workspace: &Path,
    max_duration: Duration,
) -> anyhow::Result<WorkflowEvidence> {
    anyhow::ensure!(!max_duration.is_zero(), "CLI read-only probe timed out");
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await?;
    let endpoint = format!("ws://127.0.0.1:{}", listener.local_addr()?.port());
    drop(listener);
    let mut command = Command::new(executable);
    command
        .args(official_arguments())
        .args(["app-server", "--listen", &endpoint])
        .env("CODEX_HOME", home)
        .current_dir(workspace)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    for key in EXTERNAL_API_ENVIRONMENT {
        command.env_remove(key);
    }
    #[cfg(windows)]
    command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW for the read-only probe only.
    let mut child = command.spawn()?;
    let result = timeout(max_duration, read_protocol(&endpoint, workspace)).await;
    if child.try_wait()?.is_none() {
        child.start_kill()?;
    }
    // Keep the only root handle until the OS reports exit. The Bridge path
    // below uses a Job-backed owner and retains it if whole-tree cleanup is
    // uncertain; this legacy UI read path does not claim Job-tree evidence.
    child.wait().await?;
    result.map_err(|_| anyhow::anyhow!("CLI read-only probe timed out"))?
}

/// Read the official account/model snapshot using a caller-provided native
/// process owner. The owner factory receives the local WebSocket URL and must
/// create the exact CLI process suspended, place it in its kill-on-close Job,
/// retain its image/quota resources, register its process domain, and only then
/// resume it. Any cleanup uncertainty returns the still-owned process object
/// to the caller for retention; it is never silently dropped here.
pub async fn read_evidence_with_owned_process<P, F>(
    workspace: &Path,
    max_duration: Duration,
    launch: F,
) -> Result<WorkflowEvidence, WorkflowReadFailure<P>>
where
    P: WorkflowProbeOwner,
    F: FnOnce(&str) -> Result<P, WorkflowProbeLaunchFailure<P>>,
{
    let early_error = |error: anyhow::Error| WorkflowReadFailure { error, owner: None };
    if max_duration.is_zero() {
        return Err(early_error(anyhow::anyhow!(
            "CLI read-only probe timed out"
        )));
    }
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
        .await
        .map_err(|error| early_error(error.into()))?;
    let endpoint = format!("ws://127.0.0.1:{}", listener.local_addr().unwrap().port());
    drop(listener);
    let mut owner = match launch(&endpoint) {
        Ok(owner) => owner,
        Err(failure) => {
            let (error, owner) = failure.into_parts();
            let Some(mut owner) = owner else {
                return Err(early_error(error));
            };
            return match cleanup_probe_owner(&mut owner) {
                Ok(_) => Err(early_error(error)),
                Err(cleanup_error) => Err(WorkflowReadFailure {
                    error: anyhow::anyhow!(
                        "Workflow probe launch failed and process-tree cleanup is unconfirmed: {cleanup_error}"
                    ),
                    owner: Some(owner),
                }),
            };
        }
    };
    let protocol = match timeout(max_duration, read_protocol(&endpoint, workspace)).await {
        Ok(result) => result,
        Err(_) => Err(anyhow::anyhow!("CLI read-only probe timed out")),
    };
    match cleanup_probe_owner(&mut owner) {
        Ok(Some(false)) => Err(early_error(anyhow::anyhow!(
            "CLI read-only probe exited unsuccessfully"
        ))),
        Ok(Some(true) | None) => protocol.map_err(early_error),
        Err(cleanup_error) => Err(WorkflowReadFailure {
            error: anyhow::anyhow!(
                "Workflow probe process-tree cleanup is unconfirmed: {cleanup_error}"
            ),
            owner: Some(owner),
        }),
    }
}

async fn read_protocol(endpoint: &str, workspace: &Path) -> anyhow::Result<WorkflowEvidence> {
    let connection_deadline = Instant::now() + Duration::from_secs(5);
    let mut socket = loop {
        match connect_async(endpoint).await {
            Ok((socket, _)) => break socket,
            Err(_) if Instant::now() < connection_deadline => {
                sleep(Duration::from_millis(50)).await
            }
            Err(_) => anyhow::bail!("Could not connect to the selected CLI"),
        }
    };
    request(
        &mut socket,
        1,
        "initialize",
        json!({"clientInfo":{"name":"aigoodbro-workflow","version":"0922v4"},"capabilities":{"experimentalApi":true}}),
    )
    .await?;
    socket
        .send(Message::Text(
            json!({"method":"initialized"}).to_string().into(),
        ))
        .await?;
    let config = request(
        &mut socket,
        5,
        "config/read",
        json!({"includeLayers":false,"cwd":workspace}),
    )
    .await?;
    validate_official_config(&config)?;
    let account = request(
        &mut socket,
        2,
        "account/read",
        json!({"refreshToken":false}),
    )
    .await?;
    let rate_limits = request(&mut socket, 3, "account/rateLimits/read", Value::Null).await?;
    let models = parse_models(
        &request(
            &mut socket,
            4,
            "model/list",
            json!({"includeHidden":false,"limit":100}),
        )
        .await?,
    )?;
    Ok(WorkflowEvidence {
        models,
        account,
        rate_limits,
    })
}
