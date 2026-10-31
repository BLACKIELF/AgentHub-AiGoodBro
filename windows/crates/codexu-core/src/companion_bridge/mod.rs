//! App-owned Companion IPC. The launcher is a client, never a task runner.
//! Native backends retain adopted activity guards independently of IPC lifetime.
mod host;
mod journal;
#[cfg(windows)]
pub mod native_windows;
mod protocol;
#[cfg(test)]
mod tests;

pub use host::Bridge;
pub use protocol::{Intent, Method, Reply, Request, Selector, ABI, MAX_FRAME};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
#[error("{code}")]
pub struct Error {
    pub code: &'static str,
}
pub type Result<T> = std::result::Result<T, Error>;
fn fail(code: &'static str) -> Error {
    Error { code }
}
fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn hash_parts(parts: &[&str]) -> String {
    hash(parts.join("\0").as_bytes())
}
fn digest(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn nonce() -> Result<String> {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).map_err(|_| fail("companion_bridge_unavailable"))?;
    Ok(bytes.iter().map(|v| format!("{v:02x}")).collect())
}

/// Constructed by native catalog/identity/policy consumers, never by IPC JSON.
/// `fingerprint` covers canonical project/profile/home/identity/workflow and
/// effective preferences; `epoch` is the actual App-owned Hub session.
#[derive(Clone, PartialEq, Eq)]
pub struct Scope {
    pub fingerprint: String,
    pub epoch: String,
    pub runtime_sha256: String,
    pub alias: String,
    pub valid_until_ms: u64,
}
impl Scope {
    fn valid(&self, now: u64) -> bool {
        digest(&self.fingerprint)
            && digest(&self.epoch)
            && digest(&self.runtime_sha256)
            && !self.alias.is_empty()
            && self.alias.len() <= 64
            && self
                .alias
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
            && now < self.valid_until_ms
    }
}

/// Held OS process/image authentication. The native transport constructs this;
/// it is intentionally not deserializable or supplied by the WebView.
pub trait PeerGuard: Send {
    fn check(&self) -> Result<()>;
}
pub struct Peer {
    actor: String,
    runtime: String,
    guard: Box<dyn PeerGuard>,
}
impl Peer {
    pub(crate) fn from_native(
        actor: String,
        runtime: String,
        guard: Box<dyn PeerGuard>,
    ) -> Result<Self> {
        if !digest(&actor) || !digest(&runtime) {
            return Err(fail("companion_peer_untrusted"));
        }
        guard.check()?;
        Ok(Self {
            actor,
            runtime,
            guard,
        })
    }
    fn check(&self) -> Result<()> {
        self.guard.check()
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskBinding {
    pub task_id: String,
    pub action_hash: String,
    pub scope_sha256: String,
}
impl TaskBinding {
    fn valid(&self) -> bool {
        !self.task_id.is_empty()
            && self.task_id.len() <= 128
            && self
                .task_id
                .bytes()
                .all(|v| v.is_ascii_alphanumeric() || v == b'-' || v == b'_')
            && digest(&self.action_hash)
            && digest(&self.scope_sha256)
    }
}
/// An exact authenticated backend response. No remote error text is retained.
#[derive(Clone)]
pub struct Acknowledgement {
    pub request_id: String,
    pub body_sha256: String,
    pub task: TaskBinding,
    pub state: TaskState,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TaskState {
    AwaitingApproval,
    Starting,
    Running,
    AwaitingAcceptance,
    Failed,
    Cancelled,
    Uncertain,
}
#[derive(Clone, Copy)]
pub enum LookupAction {
    Create,
    Approve,
}

/// Native-only glue to the existing App Hub. Calls execute on an owned blocking
/// worker, not a connection future that cancellation may drop mid-operation.
pub trait Backend: Send + Sync + 'static {
    type Permit: Send + 'static;
    fn now_ms(&self) -> u64;
    /// Refresh is explicit and must occur BEFORE reserve takes the writer gate.
    fn capture(&self, selector: &Selector, refresh: bool) -> Result<Scope>;
    fn reserve(&self, scope: &Scope) -> Result<Self::Permit>;
    /// No task I/O. Success transfers this SAME permit into the App Session.
    /// Errors must mean no adoption/task I/O; after success, IPC disconnects or
    /// caller errors must not release the permit. Session owns recovery.
    fn adopt(&self, lease_id: &str, scope: &Scope, permit: Self::Permit) -> Result<()>;
    fn create(
        &self,
        lease_id: &str,
        scope: &Scope,
        request_id: &str,
        prompt: &str,
    ) -> Result<Acknowledgement>;
    fn approve(
        &self,
        lease_id: &str,
        scope: &Scope,
        request_id: &str,
        task: &TaskBinding,
    ) -> Result<Acknowledgement>;
    /// Read only. Verify action-domain body hash, scope and actual task binding;
    /// never call the old UI pending POST replay or infer a match from prompt.
    fn lookup(
        &self,
        action: LookupAction,
        request_id: &str,
        body_sha256: &str,
        scope_sha256: &str,
        session_epoch: &str,
    ) -> Result<Option<Acknowledgement>>;
}
