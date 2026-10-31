use super::*;
use serde_json::{json, Value};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub(super) const MAX_FRAME: usize = 16 * 1024 * 1024;
pub(super) const START: &str = "thread-follower-start-turn";
pub(super) const INTERRUPT: &str = "thread-follower-interrupt-turn";
pub(super) const DISCOVER: &str = "thread-owner-discovery";
pub(super) trait Socket: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Socket for T {}

pub(super) fn uuid(s: &str) -> bool {
    s.len() == 36
        && s.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}
pub(super) fn frame(value: &Value) -> OwnerResult<Vec<u8>> {
    if !value.is_object() {
        return Err(OwnerError::InvalidFrame);
    }
    let bytes = serde_json::to_vec(value).map_err(|_| OwnerError::InvalidFrame)?;
    if bytes.is_empty() || bytes.len() > MAX_FRAME {
        return Err(OwnerError::InvalidFrame);
    }
    let mut framed = (bytes.len() as u32).to_le_bytes().to_vec();
    framed.extend_from_slice(&bytes);
    Ok(framed)
}
pub(super) async fn read(socket: &mut dyn Socket) -> OwnerResult<Value> {
    let mut header = [0u8; 4];
    socket
        .read_exact(&mut header)
        .await
        .map_err(|_| OwnerError::Disconnected)?;
    let size = u32::from_le_bytes(header) as usize;
    if size == 0 || size > MAX_FRAME {
        return Err(OwnerError::InvalidFrame);
    }
    let mut bytes = vec![0u8; size];
    socket
        .read_exact(&mut bytes)
        .await
        .map_err(|_| OwnerError::Disconnected)?;
    let value: Value = serde_json::from_slice(&bytes).map_err(|_| OwnerError::InvalidFrame)?;
    if !value.is_object() {
        return Err(OwnerError::InvalidFrame);
    }
    Ok(value)
}
pub(super) async fn write(socket: &mut dyn Socket, bytes: &[u8]) -> OwnerResult<()> {
    socket
        .write_all(bytes)
        .await
        .map_err(|_| OwnerError::Disconnected)
}
pub(super) fn request(
    source: &str,
    id: &str,
    method: &str,
    params: Value,
    target: Option<&str>,
    timeout: u64,
) -> Value {
    let version = match method {
        "initialize" => 0,
        DISCOVER => 1,
        START => 2,
        INTERRUPT => 4,
        _ => unreachable!(),
    };
    let mut v = json!({"type":"request","requestId":id,"sourceClientId":source,
        "method":method,"version":version,"params":params,"timeoutMs":timeout});
    if let Some(t) = target {
        v["targetClientId"] = json!(t);
    }
    // A top-level hostId changes follower protocol version. Local means OMIT.
    v
}
pub(super) fn success<'a>(
    v: &'a Value,
    id: &str,
    method: &str,
    owner: Option<&str>,
) -> OwnerResult<&'a Value> {
    if v["type"] != "response"
        || v["requestId"] != id
        || v["method"] != method
        || v["resultType"] != "success"
        || !v["handledByClientId"].as_str().is_some_and(uuid)
        || owner.is_some_and(|o| v["handledByClientId"] != o)
        || !v["result"].is_object()
    {
        return Err(OwnerError::UnexpectedResponse);
    }
    Ok(&v["result"])
}
pub(super) fn following(source: &str, conversation: &str, on: bool) -> Value {
    json!({"type":"broadcast","method":"thread-stream-following-changed","version":1,"sourceClientId":source,
        "params":{"conversationId":conversation,"hostId":"local","following":on}})
}
pub(super) fn snapshot(
    v: &Value,
    client: &str,
    ticket: &OwnerTicket,
    revision: Option<&(u64, String)>,
) -> Option<OwnerSnapshot> {
    let change = &v["params"]["change"];
    let rev = change["revision"].as_u64()?;
    if v["type"] != "broadcast"
        || v["method"] != "thread-stream-state-changed"
        || v["version"] != 11
        || v["sourceClientId"] != ticket.owner
        || v["params"]["conversationId"] != ticket.conversation
        || v["params"]["hostId"] != "local"
        || !v["targetClientIds"].as_array()?.iter().any(|x| x == client)
        || change["type"] != "snapshot"
        || revision.is_some_and(|(r, _)| rev < *r)
    {
        return None;
    }
    let state = change["conversationState"].as_object()?;
    // A new follow may legitimately return an unchanged full snapshot. Equal
    // revision is valid only for identical state from this same owner/thread.
    if revision.is_some_and(|(r, digest)| rev == *r && state_digest(state) != *digest) {
        return None;
    }
    Some(OwnerSnapshot {
        revision: rev,
        state: state.clone(),
    })
}

pub(super) fn state_digest(state: &serde_json::Map<String, Value>) -> String {
    use sha2::{Digest, Sha256};
    format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(state).expect("JSON map serializes"))
    )
}
