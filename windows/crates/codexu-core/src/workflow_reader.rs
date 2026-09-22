//! Short-lived read-only evidence from the same native CLI used for launch.
use crate::workflow::{parse_models, validate_startup, official_arguments, WorkflowModel, EXTERNAL_API_ENVIRONMENT};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::{net::Ipv4Addr, path::Path, process::Stdio, time::Duration};
use tokio::{net::{TcpListener, TcpStream}, process::Command, time::{timeout, sleep, Instant}};
use tokio_tungstenite::{connect_async, tungstenite::Message, MaybeTlsStream, WebSocketStream};

type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;

pub struct WorkflowEvidence {
    pub models: Vec<WorkflowModel>,
    account: Value,
    rate_limits: Value,
}

impl WorkflowEvidence {
    pub fn validate_startup(&self) -> anyhow::Result<()> {
        validate_startup(&self.account, &self.rate_limits, chrono::Utc::now().timestamp())
    }
}

async fn request(socket: &mut Socket, id: u64, method: &str, params: Value) -> anyhow::Result<Value> {
    socket.send(Message::Text(json!({"id":id,"method":method,"params":params}).to_string().into())).await?;
    while let Some(message) = socket.next().await {
        let payload = match message? {
            Message::Text(value) => value.to_string(),
            Message::Binary(value) => String::from_utf8(value.to_vec())?,
            Message::Close(_) => anyhow::bail!("CLI closed read-only connection"),
            _ => continue,
        };
        anyhow::ensure!(payload.len() <= 1024 * 1024, "CLI response too large");
        let value: Value = serde_json::from_str(&payload)?;
        if value.get("id").and_then(Value::as_u64) != Some(id) { continue; }
        anyhow::ensure!(value.get("error").is_none(), "CLI read-only request rejected");
        return value.get("result").cloned().ok_or_else(|| anyhow::anyhow!("CLI result missing"));
    }
    anyhow::bail!("CLI connection ended")
}

pub async fn read_evidence(executable: &Path, home: &Path) -> anyhow::Result<WorkflowEvidence> {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await?;
    let endpoint = format!("ws://127.0.0.1:{}", listener.local_addr()?.port());
    drop(listener);
    let mut command = Command::new(executable);
    command.args(official_arguments()).args(["app-server", "--listen", &endpoint])
        .env("CODEX_HOME", home)
        .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).kill_on_drop(true);
    for key in EXTERNAL_API_ENVIRONMENT { command.env_remove(key); }
    #[cfg(windows)]
    command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW for the read-only probe only.
    let mut child = command.spawn()?;
    let result = timeout(Duration::from_secs(20), async {
        let connection_deadline = Instant::now() + Duration::from_secs(5);
        let mut socket = loop {
            match connect_async(&endpoint).await {
                Ok((socket, _)) => break socket,
                Err(_) if Instant::now() < connection_deadline => sleep(Duration::from_millis(50)).await,
                Err(_) => anyhow::bail!("Could not connect to the selected CLI"),
            }
        };
        request(&mut socket, 1, "initialize", json!({"clientInfo":{"name":"aigoodbro-workflow","version":"0922v4"},"capabilities":{"experimentalApi":true}})).await?;
        socket.send(Message::Text(json!({"method":"initialized"}).to_string().into())).await?;
        let account = request(&mut socket, 2, "account/read", json!({"refreshToken":false})).await?;
        let rate_limits = request(&mut socket, 3, "account/rateLimits/read", Value::Null).await?;
        let models = parse_models(&request(&mut socket, 4, "model/list", json!({"includeHidden":false,"limit":100})).await?)?;
        Ok::<_, anyhow::Error>(WorkflowEvidence { models, account, rate_limits })
    }).await;
    if child.try_wait().ok().flatten().is_none() { let _ = child.start_kill(); }
    let _ = timeout(Duration::from_secs(2), child.wait()).await;
    result.map_err(|_| anyhow::anyhow!("CLI read-only probe timed out"))?
}
