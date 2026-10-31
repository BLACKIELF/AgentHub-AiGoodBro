//! Client-only adapter to an existing, authenticated local Codex Desktop owner.
//! Never starts a router/CLI, changes an account, or retries a submitted action.
mod client;
mod journal;
mod native;
mod protocol;

pub use client::DesktopOwnerClient;
pub use journal::{
    JournalAction, JournalError, JournalResult, JournalState, OperationRecord, OwnerJournal,
};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::{Duration, Instant};

/// Fixed, non-sensitive errors. Remote error strings/payloads are never exposed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OwnerError {
    UnsupportedPlatform,
    UnsupportedInstallation,
    Unavailable,
    PeerUntrusted,
    InvalidRequest,
    InvalidFrame,
    UnexpectedResponse,
    OwnerUnavailable,
    Cancelled,
    TimedOut,
    Disconnected,
    StaleTicket,
    AlreadyAttempted,
}
pub type OwnerResult<T> = Result<T, OwnerError>;

#[derive(Clone, Default)]
pub struct Cancellation(Arc<AtomicBool>);
impl Cancellation {
    pub fn cancel(&self) {
        self.0.store(true, Ordering::Release);
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
}

/// Native-only ticket; intentionally neither Deserialize, Serialize nor Clone.
/// It cannot be supplied by a Web caller or reused after reconnecting.
pub struct OwnerTicket {
    conversation: String,
    owner: String,
    epoch: String,
    expires: Instant,
}

impl OwnerTicket {
    /// Compare opaque bindings only. The epoch is randomly minted for each
    /// verified client connection; reconnecting cannot renew an old owner.
    /// This does not extend either ticket's lifetime or authorize an action.
    pub fn same_owner(&self, other: &Self) -> bool {
        self.conversation == other.conversation
            && self.owner == other.owner
            && self.epoch == other.epoch
    }
}

#[cfg(test)]
#[test]
fn owner_ticket_comparison_preserves_connection_and_conversation_boundaries() {
    let ticket = |conversation: &str, owner: &str, epoch: &str, expires| OwnerTicket {
        conversation: conversation.into(),
        owner: owner.into(),
        epoch: epoch.into(),
        expires,
    };
    let expired = Instant::now() - Duration::from_secs(1);
    let old = ticket("thread", "owner", "connection", expired);
    let fresh = ticket(
        "thread",
        "owner",
        "connection",
        Instant::now() + Duration::from_secs(15),
    );
    assert!(old.same_owner(&fresh));
    assert_eq!(old.expires, expired);
    assert!(!old.same_owner(&ticket("other-thread", "owner", "connection", expired)));
    assert!(!old.same_owner(&ticket("thread", "other-owner", "connection", expired)));
    assert!(!old.same_owner(&ticket("thread", "owner", "new-connection", expired)));
}

/// Accepted means the original owner accepted the action, not model completion.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ActionOutcome {
    NotSent(OwnerError),
    Accepted {
        turn_id: String,
    },
    /// May have executed. Caller must retain its durable claim and not replay.
    Unknown,
}

/// Full state stays native/in memory; no automatic persistence or Web exposure.
pub struct OwnerSnapshot {
    pub revision: u64,
    pub state: serde_json::Map<String, serde_json::Value>,
}

struct Budget {
    end: Instant,
    cancel: Cancellation,
}
impl Budget {
    fn new(duration: Duration, cancel: &Cancellation) -> OwnerResult<Self> {
        if duration.is_zero() || duration > Duration::from_secs(30) {
            return Err(OwnerError::InvalidRequest);
        }
        let value = Self {
            end: Instant::now() + duration,
            cancel: cancel.clone(),
        };
        value.check()?;
        Ok(value)
    }
    fn check(&self) -> OwnerResult<()> {
        if self.cancel.is_cancelled() {
            Err(OwnerError::Cancelled)
        } else if Instant::now() >= self.end {
            Err(OwnerError::TimedOut)
        } else {
            Ok(())
        }
    }
    fn millis(&self) -> OwnerResult<u64> {
        self.check()?;
        Ok(self
            .end
            .saturating_duration_since(Instant::now())
            .as_millis()
            .min(30_000) as u64)
    }
    async fn wait<T>(
        &self,
        f: impl std::future::Future<Output = OwnerResult<T>>,
    ) -> OwnerResult<T> {
        tokio::pin!(f);
        loop {
            self.check()?;
            tokio::select! {
                result = &mut f => { self.check()?; return result; }
                _ = tokio::time::sleep(Duration::from_millis(10)) => {}
            }
        }
    }
}

fn random_id() -> OwnerResult<String> {
    let mut b = [0u8; 16];
    getrandom::fill(&mut b).map_err(|_| OwnerError::Unavailable)?;
    b[6] = b[6] & 15 | 64;
    b[8] = b[8] & 63 | 128;
    Ok(format!(
        "{:08x}-{:04x}-{:04x}-{:04x}-{:012x}",
        u32::from_be_bytes(b[..4].try_into().unwrap()),
        u16::from_be_bytes(b[4..6].try_into().unwrap()),
        u16::from_be_bytes(b[6..8].try_into().unwrap()),
        u16::from_be_bytes(b[8..10].try_into().unwrap()),
        u64::from_be_bytes([0, 0, b[10], b[11], b[12], b[13], b[14], b[15]])
    ))
}

#[cfg(all(test, windows))]
mod native_tests;
#[cfg(test)]
mod tests;
