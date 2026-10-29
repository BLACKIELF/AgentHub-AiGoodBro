//! One read-only official SystemDaemon connection. These types never cross IPC.
//! The native composition must supply verified AccountManager scope and native
//! activity evidence; no request accepts a path, identity or idle flag from UI.
use super::{is_fresh, valid_hash, valid_id, TaskState, TASK_MAX_AGE_MS};
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc,
    },
};

mod activity;
mod client;
mod owned_domains;
pub use owned_domains::{OwnedDomainPurpose, OwnedDomainRegistration, OwnedProcessDomains};
#[cfg(windows)]
mod native;
#[cfg(windows)]
mod quiescence;
#[cfg(windows)]
pub use quiescence::QuiescedSystemProof;
mod reducer;
pub use client::{SystemDaemonMonitor, SystemDaemonSource};

pub type LiveResult<T> = std::result::Result<T, LiveIssue>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LiveIssue {
    Unavailable,
    ScopeUnverified,
    PeerUntrusted,
    Protocol,
    Incomplete,
    Overflow,
    TimedOut,
    Cancelled,
}
impl LiveIssue {
    pub fn code(self) -> &'static str {
        match self {
            Self::Unavailable => "official_tasks_unavailable",
            Self::ScopeUnverified => "official_tasks_scope_unverified",
            Self::PeerUntrusted => "official_tasks_peer_untrusted",
            Self::Protocol => "official_tasks_protocol_unknown",
            Self::Incomplete => "official_tasks_incomplete",
            Self::Overflow => "official_tasks_overflow",
            Self::TimedOut => "official_tasks_timed_out",
            Self::Cancelled => "official_tasks_cancelled",
        }
    }
}

/// A verified scope is supplied only by the native AccountManager adapter. It
/// is not sufficient by itself: the socket peer, process birth and home must
/// also be verified before this scope can produce a live snapshot.
#[derive(Clone, PartialEq, Eq)]
pub struct SystemDaemonScope {
    pub canonical_home: PathBuf,
    pub profile_id: String,
    pub identity_hash: String,
    pub credential_generation: String,
    pub auth_digest: String,
    /// Actual successful system activation time, never quota observed_at.
    /// Legacy active records without this proof are unavailable.
    pub established_at_unix_ms: u64,
}
impl SystemDaemonScope {
    fn validate(&self, now: u64) -> LiveResult<()> {
        if !self.canonical_home.is_absolute()
            || self
                .canonical_home
                .components()
                .any(|c| matches!(c, std::path::Component::ParentDir))
            || !valid_id(&self.profile_id)
            || !valid_hash(&self.identity_hash)
            || !valid_id(&self.credential_generation)
            || !valid_hash(&self.auth_digest)
            || self.established_at_unix_ms == 0
            || self.established_at_unix_ms > now
        {
            return Err(LiveIssue::ScopeUnverified);
        }
        Ok(())
    }
}

/// Bounded read-only operations on the manager, outside its commit guard.
/// No refresh, second app-server, credential write or authentication replay.
pub trait SystemScopeAuthority: Send + Sync {
    fn current(&self) -> LiveResult<SystemDaemonScope>;
    fn recheck(&self, scope: &SystemDaemonScope) -> LiveResult<()>;
}

#[derive(Clone)]
pub struct SystemActivityEvidence {
    pub observed_at_unix_ms: u64,
    /// Compatibility only. Native peer-bound foreground evidence overrides it.
    pub inactive_since_unix_ms: Option<u64>,
    /// Compatibility only. The complete native process inventory overrides it.
    pub legacy_manager_running: Option<bool>,
    /// The same trusted DispatchActivity/proxy exclusion domain. None is unknown.
    pub dispatch_busy: Option<bool>,
}
pub trait SystemActivitySource: Send + Sync {
    /// Native memory-only observation; never reenter AccountManager/the vault.
    fn current(&self) -> LiveResult<SystemActivityEvidence>;
}

#[derive(Clone)]
pub struct LiveTaskRecord {
    pub thread_id: String,
    /// Official runtime ThreadStatus. Turn history cannot clear this state.
    pub state: TaskState,
    pub turn_id: Option<String>,
    /// Independent Turn status; terminal history is not proof of runtime idle.
    pub turn_state: Option<TaskState>,
    pub turn_started_at_unix_ms: Option<u64>,
    pub turn_completed_at_unix_ms: Option<u64>,
}

/// Always SystemDaemon scope. Managed private Desktop evidence has a different
/// producer and cannot be projected into this global task source.
pub struct LiveTaskSnapshot {
    scope: SystemDaemonScope,
    connection_generation: String,
    revision: u64,
    observed_at_unix_ms: u64,
    records: Vec<LiveTaskRecord>,
    valid: Arc<AtomicBool>,
    current_revision: Arc<AtomicU64>,
}
impl LiveTaskSnapshot {
    pub fn profile_id(&self) -> &str {
        &self.scope.profile_id
    }
    pub fn identity_hash(&self) -> &str {
        &self.scope.identity_hash
    }
    pub fn credential_generation(&self) -> &str {
        &self.scope.credential_generation
    }
    pub fn connection_generation(&self) -> &str {
        &self.connection_generation
    }
    pub fn revision(&self) -> u64 {
        self.revision
    }
    pub fn observed_at_unix_ms(&self) -> u64 {
        self.observed_at_unix_ms
    }
    pub fn records(&self) -> &[LiveTaskRecord] {
        &self.records
    }
    /// Consumers recheck this before acting on a queued event. Cancellation,
    /// disconnect, overflow and a new peer immediately invalidate old values.
    pub fn is_current(&self) -> bool {
        self.valid.load(Ordering::Acquire)
            && self.current_revision.load(Ordering::Acquire) == self.revision
            && is_fresh(self.observed_at_unix_ms, TASK_MAX_AGE_MS, super::now_ms())
    }
}
pub enum LiveTaskEvent {
    Snapshot(Arc<LiveTaskSnapshot>),
    Reset { issue: LiveIssue },
}
pub trait LiveTaskObserver: Send + Sync {
    /// Enqueue bounded native work only. Task/turn IDs stay in process; apply
    /// notification opt-ins/privacy separately. No callback may perform I/O.
    fn record(&self, event: LiveTaskEvent);
}

const MAXIMUM_THREADS: usize = 1_000;
const MAXIMUM_MESSAGE_BYTES: usize = 1 << 20;

fn opaque_id(value: &str) -> bool {
    // Codex IDs are UUIDs. Bound and validate the documented shape, without
    // inventing a version requirement that excludes historical UUID variants.
    value.len() == 36
        && value.bytes().enumerate().all(|(i, b)| {
            if matches!(i, 8 | 13 | 18 | 23) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}

#[cfg(test)]
mod tests;
