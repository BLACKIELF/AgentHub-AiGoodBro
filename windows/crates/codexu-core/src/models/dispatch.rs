//! Dispatch coordination contract.
//!
//! Faithful port of `DispatchActivityStore` in
//! `Sources/CodexUsageWidget/Services/DispatchActivityStore.swift`, which is the
//! versioned local contract shared with `next_dispatch_activity.py` and the Hub.
//! Field names, key derivation, state sets and validation must match byte for
//! byte or the two sides silently stop seeing each other's reservations.
//!
//! This module is the *contract* only: types, validation, state transitions,
//! conflict rules and history bounding. The platform layer that owns the file
//! lock, the atomic replace and process liveness is a separate concern.
//!
//! Privacy rules that must not be relaxed:
//!
//! * A lease carries identity and directory *hashes*, never the raw account,
//!   alias or path.
//! * The issue journal is append-only and must never carry a raw path, URL or
//!   email; [`validate_issue_summary`] enforces that before a record is built.

use std::cmp::Ordering;
use std::collections::BTreeSet;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// Shared state file, next to the Python tooling's own file.
pub const STATE_FILE_NAME: &str = "dispatch-activity-v1.json";
/// Advisory lock file guarding every read-modify-write of the state file.
pub const LOCK_FILE_NAME: &str = ".dispatch-activity.lock";
/// Append-only incident journal.
pub const ISSUE_FILE_NAME: &str = "operations-issues-v1.jsonl";

pub const SCHEMA_VERSION: i64 = 1;
/// Refuse to load a state file above this size.
pub const MAX_STATE_BYTES: usize = 2 * 1024 * 1024;
/// Refuse to load a state file with more leases than this.
pub const MAX_LEASES: usize = 2000;
/// Terminal leases retained as status history.
pub const RETAINED_ENDED_LEASES: usize = 100;

/// Heartbeat window for account-scoped routes.
pub const ACCOUNT_HEARTBEAT_SECS: i64 = 600;
/// Heartbeat window for a terminal session.
pub const TERMINAL_HEARTBEAT_SECS: i64 = 120;
/// A lease whose `updated_at` is this far ahead of the clock is untrustworthy.
pub const FUTURE_UPDATED_AT_TOLERANCE_SECS: i64 = 5;

pub const ROUTE_WARMUP: &str = "warmup";
pub const ROUTE_MAINTENANCE: &str = "maintenance";
pub const ROUTE_TERMINAL: &str = "terminal";

/// Journal records are written by Next.
pub const ISSUE_COMPONENT: &str = "next";

/// Lifecycle state of one reservation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DispatchLeaseState {
    Preparing,
    Starting,
    Running,
    CancelRequested,
    Uncertain,
    AwaitingAcceptance,
    Accepted,
    Rejected,
    Failed,
    Cancelled,
}

impl DispatchLeaseState {
    pub const ALL: [DispatchLeaseState; 10] = [
        DispatchLeaseState::Preparing,
        DispatchLeaseState::Starting,
        DispatchLeaseState::Running,
        DispatchLeaseState::CancelRequested,
        DispatchLeaseState::Uncertain,
        DispatchLeaseState::AwaitingAcceptance,
        DispatchLeaseState::Accepted,
        DispatchLeaseState::Rejected,
        DispatchLeaseState::Failed,
        DispatchLeaseState::Cancelled,
    ];

    pub fn id(self) -> &'static str {
        match self {
            DispatchLeaseState::Preparing => "preparing",
            DispatchLeaseState::Starting => "starting",
            DispatchLeaseState::Running => "running",
            DispatchLeaseState::CancelRequested => "cancel_requested",
            DispatchLeaseState::Uncertain => "uncertain",
            DispatchLeaseState::AwaitingAcceptance => "awaiting_acceptance",
            DispatchLeaseState::Accepted => "accepted",
            DispatchLeaseState::Rejected => "rejected",
            DispatchLeaseState::Failed => "failed",
            DispatchLeaseState::Cancelled => "cancelled",
        }
    }

    pub fn from_id(value: &str) -> Option<Self> {
        DispatchLeaseState::ALL
            .into_iter()
            .find(|state| state.id() == value)
    }

    /// A state that still holds the reservation.
    ///
    /// `uncertain` is active on purpose: an expired heartbeat is never proof of
    /// idleness, so it keeps blocking until something releases it.
    pub fn is_active(self) -> bool {
        matches!(
            self,
            DispatchLeaseState::Preparing
                | DispatchLeaseState::Starting
                | DispatchLeaseState::Running
                | DispatchLeaseState::CancelRequested
                | DispatchLeaseState::Uncertain
        )
    }

    pub fn is_terminal(self) -> bool {
        !self.is_active()
    }
}

fn epoch_seconds(at: DateTime<Utc>) -> f64 {
    at.timestamp() as f64 + f64::from(at.timestamp_subsec_nanos()) / 1_000_000_000.0
}

fn heartbeat_secs(route: &str) -> i64 {
    if route == ROUTE_TERMINAL {
        TERMINAL_HEARTBEAT_SECS
    } else {
        ACCOUNT_HEARTBEAT_SECS
    }
}

/// SHA-256 as lower-case hex.
///
/// The two other implementations hash the same bytes; a hand-rolled digest here
/// would risk a silent interop break, so the standard crate is used.
pub fn hash_key(value: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(value.as_bytes());
    hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// Key for a raw account identity.
pub fn account_key(account: &str) -> String {
    hash_key(account)
}

/// Key for a user-facing alias. Trimmed and lower-cased before hashing.
pub fn alias_key(alias: &str) -> String {
    hash_key(alias.trim().to_lowercase().as_str())
}

/// Project key for an account-scoped route: `hash("<route>:<accountKey>")`.
pub fn route_project_key(route: &str, account_key: &str) -> String {
    hash_key(&format!("{route}:{account_key}"))
}

/// Project key for a desktop-switch maintenance pair.
pub fn maintenance_project_key(account_key: &str) -> String {
    hash_key(&format!("{ROUTE_MAINTENANCE}:{account_key}"))
}

/// Project key for a terminal session.
///
/// The caller must pass an already resolved, canonical path; symlink resolution
/// is platform IO and belongs to the layer that owns the working directory.
pub fn terminal_project_key(resolved_path: &str) -> String {
    hash_key(resolved_path)
}

/// One reservation.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DispatchLease {
    pub lease_id: String,
    pub owner_thread_id: String,
    pub task_id: String,
    pub account_key: String,
    pub alias_key: String,
    pub project_key: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    pub route: String,
    pub state: DispatchLeaseState,
    pub created_at: f64,
    pub updated_at: f64,
    pub heartbeat_due_at: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pid: Option<i64>,
}

impl DispatchLease {
    /// Whether this lease still holds its reservation, judged by the *recorded*
    /// state rather than by the clock.
    pub fn occupied(&self) -> bool {
        self.state.is_active()
    }

    /// The state an observer should act on.
    ///
    /// An expired heartbeat, or a record written noticeably in the future, makes
    /// the lease `uncertain`. It stays active, so the reservation is kept.
    pub fn effective_state(&self, now: DateTime<Utc>) -> DispatchLeaseState {
        let current = epoch_seconds(now);
        if self.occupied()
            && (self.heartbeat_due_at < current
                || self.updated_at > current + FUTURE_UPDATED_AT_TOLERANCE_SECS as f64)
        {
            DispatchLeaseState::Uncertain
        } else {
            self.state
        }
    }

    /// A lease in the past that an observer may act on.
    pub fn updated_at_utc(&self) -> Option<DateTime<Utc>> {
        chrono::DateTime::from_timestamp(self.updated_at.trunc() as i64, 0)
    }
}

/// The whole shared state file.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DispatchSnapshot {
    pub schema_version: i64,
    pub leases: Vec<DispatchLease>,
}

impl Default for DispatchSnapshot {
    fn default() -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            leases: Vec::new(),
        }
    }
}

impl DispatchSnapshot {
    /// Validate exactly what the Swift and Python readers validate.
    ///
    /// A file that fails any of these is treated as unreadable rather than
    /// partially trusted, because a partially trusted reservation set would let
    /// two runners take the same account.
    pub fn validate(&self) -> Result<(), DispatchContractError> {
        if self.schema_version != SCHEMA_VERSION {
            return Err(DispatchContractError::UnsupportedSchemaVersion(
                self.schema_version,
            ));
        }
        if self.leases.len() > MAX_LEASES {
            return Err(DispatchContractError::TooManyLeases(self.leases.len()));
        }
        let ids: BTreeSet<&str> = self.leases.iter().map(|l| l.lease_id.as_str()).collect();
        if ids.len() != self.leases.len() {
            return Err(DispatchContractError::DuplicateLeaseId);
        }
        for lease in &self.leases {
            for (field, value) in [
                ("accountKey", &lease.account_key),
                ("aliasKey", &lease.alias_key),
                ("projectKey", &lease.project_key),
            ] {
                if !is_hex_key(value) {
                    return Err(DispatchContractError::InvalidKey { field });
                }
            }
            if lease.lease_id.is_empty()
                || lease.owner_thread_id.is_empty()
                || lease.task_id.is_empty()
            {
                return Err(DispatchContractError::EmptyIdentifier);
            }
            if !lease.created_at.is_finite()
                || !lease.updated_at.is_finite()
                || !lease.heartbeat_due_at.is_finite()
            {
                return Err(DispatchContractError::NonFiniteTimestamp);
            }
        }
        Ok(())
    }

    /// Whether any active lease holds this account.
    pub fn blocks_account(&self, account_key: &str) -> bool {
        self.leases
            .iter()
            .any(|lease| lease.account_key == account_key && lease.occupied())
    }

    /// Whether an account-scoped reservation would conflict.
    ///
    /// Conflicts on the account or the alias, and never ignores an expired
    /// heartbeat.
    pub fn blocks_account_route(&self, account_key: &str, alias_key: &str) -> bool {
        self.leases.iter().any(|lease| {
            lease.state.is_active()
                && (lease.account_key == account_key || lease.alias_key == alias_key)
        })
    }

    /// Whether a terminal reservation would conflict.
    ///
    /// The working directory counts too, so two accounts cannot run in the same
    /// real project at once.
    pub fn blocks_terminal(&self, account_key: &str, alias_key: &str, project_key: &str) -> bool {
        self.leases.iter().any(|lease| {
            lease.state.is_active()
                && (lease.account_key == account_key
                    || lease.alias_key == alias_key
                    || lease.project_key == project_key)
        })
    }

    /// The most relevant lease for an account.
    ///
    /// An occupied lease outranks a terminal one regardless of recency; warm-up
    /// and maintenance records only surface while they are occupied.
    pub fn latest_lease(
        &self,
        alias: Option<&str>,
        account_key: Option<&str>,
    ) -> Option<&DispatchLease> {
        let key = alias.map(alias_key);
        self.leases
            .iter()
            .filter(|lease| {
                let alias_matches = key.as_deref() == Some(lease.alias_key.as_str());
                let account_matches = account_key == Some(lease.account_key.as_str());
                let maintenance_like =
                    lease.route == ROUTE_WARMUP || lease.route == ROUTE_MAINTENANCE;
                (alias_matches || account_matches) && (!maintenance_like || lease.occupied())
            })
            .max_by(|a, b| match (a.occupied(), b.occupied()) {
                (true, false) => Ordering::Greater,
                (false, true) => Ordering::Less,
                _ => a.updated_at.partial_cmp(&b.updated_at).unwrap_or(Ordering::Equal),
            })
    }
}

fn is_hex_key(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// Keep every active lease plus the most recently finished ones.
///
/// A just-finished lease may already be first in the array, so retention is by
/// completion time: the next write must not evict a task before acceptance.
pub fn recent_ended_leases(leases: &[DispatchLease]) -> Vec<DispatchLease> {
    let mut ended: Vec<DispatchLease> = leases
        .iter()
        .filter(|lease| lease.state.is_terminal())
        .cloned()
        .collect();
    ended.sort_by(|a, b| {
        a.updated_at
            .partial_cmp(&b.updated_at)
            .unwrap_or(Ordering::Equal)
            .then_with(|| a.lease_id.cmp(&b.lease_id))
    });
    if ended.len() > RETAINED_ENDED_LEASES {
        ended.split_off(ended.len() - RETAINED_ENDED_LEASES)
    } else {
        ended
    }
}

/// Active leases first, then the retained terminal history.
pub fn reorder_leases(leases: &[DispatchLease]) -> Vec<DispatchLease> {
    let mut ordered: Vec<DispatchLease> = leases
        .iter()
        .filter(|lease| lease.state.is_active())
        .cloned()
        .collect();
    ordered.extend(recent_ended_leases(leases));
    ordered
}

/// Build the lease a reservation would write.
///
/// Every derived field is computed here so the wire output cannot drift from the
/// other two implementations.
#[allow(clippy::too_many_arguments)]
pub fn build_reservation_lease(
    lease_id: &str,
    owner_thread_id: &str,
    route: &str,
    account: &str,
    alias: &str,
    project_key: Option<String>,
    now: DateTime<Utc>,
) -> DispatchLease {
    let account_key = account_key(account);
    let alias_key = alias_key(alias);
    let project_key = project_key.unwrap_or_else(|| route_project_key(route, &account_key));
    let current = epoch_seconds(now);
    DispatchLease {
        lease_id: lease_id.to_string(),
        owner_thread_id: owner_thread_id.to_string(),
        task_id: format!("{route}-{lease_id}"),
        account_key,
        alias_key,
        project_key,
        code: None,
        route: route.to_string(),
        state: DispatchLeaseState::Preparing,
        created_at: current,
        updated_at: current,
        heartbeat_due_at: current + heartbeat_secs(route) as f64,
        pid: None,
    }
}

/// One line of the append-only incident journal.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DispatchIssueRecord {
    pub schema_version: i64,
    pub issue_id: String,
    pub component: String,
    pub phase: String,
    pub recorded_at: String,
    pub date_shanghai: String,
    pub summary: String,
    pub owner_thread_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
}

/// Build a journal record.
///
/// `recorded_at` is UTC and `date_shanghai` is the same instant in Asia/Shanghai,
/// matching the Python tooling's own timestamps.
pub fn build_issue_record(
    issue_id: &str,
    phase: &str,
    summary: &str,
    code: Option<&str>,
    owner_thread_id: &str,
    now: DateTime<Utc>,
) -> Result<DispatchIssueRecord, DispatchContractError> {
    validate_issue_summary(summary)?;
    if let Some(code) = code {
        if !is_valid_issue_code(code) {
            return Err(DispatchContractError::InvalidIssueCode);
        }
    }

    let shanghai = now.with_timezone(&chrono_tz::Asia::Shanghai);
    Ok(DispatchIssueRecord {
        schema_version: SCHEMA_VERSION,
        issue_id: issue_id.to_string(),
        component: ISSUE_COMPONENT.to_string(),
        phase: phase.to_string(),
        recorded_at: now.to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        date_shanghai: shanghai.to_rfc3339_opts(chrono::SecondsFormat::Millis, false),
        summary: summary.to_string(),
        owner_thread_id: owner_thread_id.to_string(),
        code: code.map(str::to_string),
    })
}

/// A journal code is a single upper-case letter.
pub fn is_valid_issue_code(code: &str) -> bool {
    code.len() == 1 && code.bytes().all(|byte| byte.is_ascii_uppercase())
}

/// Whether one whitespace-delimited token is an absolute path.
///
/// Covers a POSIX path and a Windows drive path. Checked per token so a path
/// hidden inside a sentence is still caught, which a "starts with /" test misses.
fn looks_like_absolute_path(token: &str) -> bool {
    if token.starts_with('/') || token.starts_with('\\') {
        return true;
    }
    let bytes = token.as_bytes();
    bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && (bytes[2] == b'\\' || bytes[2] == b'/')
}

/// Reject a journal summary that would leak local state.
///
/// The shared journal is read by other people and tools, so a raw path, URL or
/// email must never enter it. This is a guard, not a proof: it rejects the
/// shapes that actually leak, and the caller still owns the content.
pub fn validate_issue_summary(summary: &str) -> Result<(), DispatchContractError> {
    let trimmed = summary.trim();
    if trimmed.is_empty() {
        return Err(DispatchContractError::EmptyIssueSummary);
    }
    if summary.chars().any(char::is_control) {
        return Err(DispatchContractError::IssueSummaryHasControlCharacters);
    }
    for token in trimmed.split_whitespace() {
        if token.contains("://") || looks_like_absolute_path(token) {
            return Err(DispatchContractError::IssueSummaryLooksLikeAPath);
        }
    }
    if trimmed.contains('@') {
        return Err(DispatchContractError::IssueSummaryLooksLikeAnEmail);
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum DispatchContractError {
    #[error("unsupported dispatch schema version {0}")]
    UnsupportedSchemaVersion(i64),
    #[error("dispatch state carries {0} leases, above the 2000 lease limit")]
    TooManyLeases(usize),
    #[error("dispatch state contains a duplicate lease id")]
    DuplicateLeaseId,
    #[error("dispatch key {field} must be 64 lower-case hex characters")]
    InvalidKey { field: &'static str },
    #[error("dispatch lease identifiers must not be empty")]
    EmptyIdentifier,
    #[error("dispatch lease timestamps must be finite")]
    NonFiniteTimestamp,
    #[error("issue summary must not be empty")]
    EmptyIssueSummary,
    #[error("issue summary must not contain control characters")]
    IssueSummaryHasControlCharacters,
    #[error("issue summary must not contain a local path or URL")]
    IssueSummaryLooksLikeAPath,
    #[error("issue summary must not contain an email address")]
    IssueSummaryLooksLikeAnEmail,
    #[error("issue code must be a single upper-case letter")]
    InvalidIssueCode,
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn at(seconds: i64) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 9, 11, 12, 0, 0)
            .single()
            .expect("valid timestamp")
            + chrono::Duration::seconds(seconds)
    }

    fn lease(state: DispatchLeaseState, route: &str, updated_at: i64) -> DispatchLease {
        let mut lease = build_reservation_lease(
            &format!("lease-{route}-{updated_at}"),
            "next-1",
            route,
            "fixture-account",
            "fixture-alias",
            None,
            at(0),
        );
        lease.state = state;
        lease.updated_at = updated_at as f64;
        lease
    }

    fn lease_for(account: &str, alias: &str, state: DispatchLeaseState) -> DispatchLease {
        let mut lease = build_reservation_lease(
            "lease-a",
            "next-1",
            ROUTE_TERMINAL,
            account,
            alias,
            None,
            at(0),
        );
        lease.state = state;
        lease
    }

    #[test]
    fn hashing_matches_the_standard_sha256_vectors() {
        assert_eq!(
            hash_key(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            hash_key("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(hash_key("fixture").len(), 64);
    }

    #[test]
    fn alias_keys_are_trimmed_and_lower_cased_but_account_keys_are_not() {
        assert_eq!(alias_key("  Fixture-Alias  "), alias_key("fixture-alias"));
        // Account identity is hashed verbatim: the other implementations do not
        // normalise it either.
        assert_ne!(account_key("Fixture"), account_key("fixture"));
    }

    #[test]
    fn project_keys_follow_the_route_derivation() {
        let account = account_key("fixture-account");
        assert_eq!(
            route_project_key(ROUTE_WARMUP, &account),
            hash_key(&format!("warmup:{account}"))
        );
        assert_eq!(
            maintenance_project_key(&account),
            hash_key(&format!("maintenance:{account}"))
        );
        assert_ne!(
            route_project_key(ROUTE_WARMUP, &account),
            route_project_key(ROUTE_MAINTENANCE, &account)
        );
    }

    #[test]
    fn a_reservation_lease_matches_the_wire_contract() {
        let built = build_reservation_lease(
            "abc-123",
            "next-42",
            ROUTE_TERMINAL,
            "fixture-account",
            "Fixture-Alias",
            None,
            at(0),
        );
        assert_eq!(built.task_id, "terminal-abc-123");
        assert_eq!(built.state, DispatchLeaseState::Preparing);
        assert_eq!(built.alias_key, alias_key("fixture-alias"));
        assert_eq!(built.project_key, route_project_key(ROUTE_TERMINAL, &built.account_key));
        // Terminal heartbeats are the short window.
        assert_eq!(built.heartbeat_due_at - built.created_at, 120.0);

        let account_route = build_reservation_lease(
            "abc-123",
            "next-42",
            ROUTE_WARMUP,
            "fixture-account",
            "fixture-alias",
            None,
            at(0),
        );
        assert_eq!(account_route.heartbeat_due_at - account_route.created_at, 600.0);
    }

    #[test]
    fn the_serialised_field_names_match_the_shared_contract() {
        let built = build_reservation_lease(
            "abc",
            "next-1",
            ROUTE_TERMINAL,
            "account",
            "alias",
            None,
            at(0),
        );
        let json = serde_json::to_string(&built).expect("serialise");
        for field in [
            "\"leaseId\"",
            "\"ownerThreadId\"",
            "\"taskId\"",
            "\"accountKey\"",
            "\"aliasKey\"",
            "\"projectKey\"",
            "\"route\"",
            "\"state\"",
            "\"createdAt\"",
            "\"updatedAt\"",
            "\"heartbeatDueAt\"",
        ] {
            assert!(json.contains(field), "wire field {field} is missing");
        }
        assert!(!json.contains("\"code\""), "an unset code must not be written");
        assert!(!json.contains("\"pid\""), "an unset pid must not be written");
        assert!(json.contains("\"state\":\"preparing\""));
    }

    #[test]
    fn a_snapshot_round_trips_through_json() {
        let snapshot = DispatchSnapshot {
            schema_version: SCHEMA_VERSION,
            leases: vec![lease(DispatchLeaseState::Running, ROUTE_TERMINAL, 100)],
        };
        let json = serde_json::to_string(&snapshot).expect("serialise");
        let decoded: DispatchSnapshot = serde_json::from_str(&json).expect("deserialise");
        assert_eq!(decoded, snapshot);
        assert_eq!(decoded.validate(), Ok(()));
    }

    #[test]
    fn validation_rejects_what_the_other_readers_reject() {
        let base = build_reservation_lease("a", "next-1", ROUTE_WARMUP, "acc", "alias", None, at(0));

        let mut wrong_version = DispatchSnapshot::default();
        wrong_version.schema_version = 2;
        wrong_version.leases = vec![base.clone()];
        assert_eq!(
            wrong_version.validate(),
            Err(DispatchContractError::UnsupportedSchemaVersion(2))
        );

        let duplicate = DispatchSnapshot {
            schema_version: SCHEMA_VERSION,
            leases: vec![base.clone(), base.clone()],
        };
        assert_eq!(
            duplicate.validate(),
            Err(DispatchContractError::DuplicateLeaseId)
        );

        let mut short_key = DispatchSnapshot::default();
        let mut broken = base.clone();
        broken.account_key = "abc".to_string();
        short_key.leases = vec![broken];
        assert_eq!(
            short_key.validate(),
            Err(DispatchContractError::InvalidKey { field: "accountKey" })
        );

        // Upper-case hex is not accepted; the contract is lower-case only.
        let mut upper = DispatchSnapshot::default();
        let mut broken = base.clone();
        broken.alias_key = "A".repeat(64);
        upper.leases = vec![broken];
        assert_eq!(
            upper.validate(),
            Err(DispatchContractError::InvalidKey { field: "aliasKey" })
        );

        let mut empty_id = DispatchSnapshot::default();
        let mut broken = base.clone();
        broken.lease_id = String::new();
        empty_id.leases = vec![broken];
        assert_eq!(empty_id.validate(), Err(DispatchContractError::EmptyIdentifier));

        let mut non_finite = DispatchSnapshot::default();
        let mut broken = base;
        broken.updated_at = f64::NAN;
        non_finite.leases = vec![broken];
        assert_eq!(
            non_finite.validate(),
            Err(DispatchContractError::NonFiniteTimestamp)
        );
    }

    #[test]
    fn an_expired_heartbeat_becomes_uncertain_and_still_blocks() {
        // Timestamps on the wire are epoch seconds, so the fixture must use the
        // same scale as `at(..)`; small synthetic floats would all read as long
        // expired.
        let mut running = build_reservation_lease(
            "lease-running",
            "next-1",
            ROUTE_TERMINAL,
            "fixture-account",
            "fixture-alias",
            None,
            at(0),
        );
        running.state = DispatchLeaseState::Running;
        running.heartbeat_due_at = epoch_seconds(at(100));

        assert_eq!(running.effective_state(at(50)), DispatchLeaseState::Running);
        assert_eq!(running.effective_state(at(200)), DispatchLeaseState::Uncertain);
        // The recorded state never changes, so the reservation is kept.
        assert!(running.occupied());

        let snapshot = DispatchSnapshot {
            schema_version: SCHEMA_VERSION,
            leases: vec![running],
        };
        assert!(snapshot.blocks_account(&account_key("fixture-account")));
    }

    #[test]
    fn a_future_updated_at_is_also_treated_as_uncertain() {
        let mut running = build_reservation_lease(
            "lease-future",
            "next-1",
            ROUTE_TERMINAL,
            "fixture-account",
            "fixture-alias",
            None,
            at(0),
        );
        running.state = DispatchLeaseState::Running;
        running.heartbeat_due_at = epoch_seconds(at(10_000));
        running.updated_at = epoch_seconds(at(0)) + 30.0;

        assert_eq!(running.effective_state(at(0)), DispatchLeaseState::Uncertain);
    }

    #[test]
    fn a_terminal_state_is_never_downgraded_by_the_clock() {
        let mut accepted = build_reservation_lease(
            "lease-accepted",
            "next-1",
            ROUTE_TERMINAL,
            "fixture-account",
            "fixture-alias",
            None,
            at(0),
        );
        accepted.state = DispatchLeaseState::Accepted;
        accepted.heartbeat_due_at = epoch_seconds(at(0));
        assert_eq!(
            accepted.effective_state(at(10_000)),
            DispatchLeaseState::Accepted
        );
    }

    #[test]
    fn an_account_route_conflicts_on_account_or_alias() {
        let active = lease_for("fixture-account", "fixture-alias", DispatchLeaseState::Running);
        let snapshot = DispatchSnapshot {
            schema_version: SCHEMA_VERSION,
            leases: vec![active.clone()],
        };

        assert!(snapshot.blocks_account_route(&account_key("fixture-account"), &alias_key("other")));
        assert!(snapshot.blocks_account_route(&account_key("other"), &alias_key("fixture-alias")));
        assert!(!snapshot.blocks_account_route(&account_key("other"), &alias_key("other")));
    }

    #[test]
    fn a_terminal_reservation_also_conflicts_on_the_project_directory() {
        let active = lease_for("fixture-account", "fixture-alias", DispatchLeaseState::Running);
        let snapshot = DispatchSnapshot {
            schema_version: SCHEMA_VERSION,
            leases: vec![active.clone()],
        };

        assert!(snapshot.blocks_terminal(
            &account_key("other"),
            &alias_key("other"),
            &active.project_key
        ));
        assert!(!snapshot.blocks_terminal(
            &account_key("other"),
            &alias_key("other"),
            &terminal_project_key("/some/other/project")
        ));
    }

    #[test]
    fn a_terminal_lease_does_not_block_a_new_reservation() {
        let ended = lease_for("fixture-account", "fixture-alias", DispatchLeaseState::Accepted);
        let snapshot = DispatchSnapshot {
            schema_version: SCHEMA_VERSION,
            leases: vec![ended.clone()],
        };

        assert!(!snapshot.blocks_account_route(
            &account_key("fixture-account"),
            &alias_key("fixture-alias")
        ));
        assert!(!snapshot.blocks_terminal(
            &account_key("fixture-account"),
            &alias_key("fixture-alias"),
            &ended.project_key
        ));
        // History still answers "what happened to this account".
        assert!(snapshot.blocks_account(&account_key("fixture-account")) == false);
    }

    #[test]
    fn latest_lease_prefers_an_occupied_record_over_a_newer_terminal_one() {
        let mut occupied = lease(DispatchLeaseState::Running, ROUTE_TERMINAL, 100);
        occupied.lease_id = "occupied".to_string();
        let mut finished = lease(DispatchLeaseState::Accepted, ROUTE_TERMINAL, 900);
        finished.lease_id = "finished".to_string();

        let snapshot = DispatchSnapshot {
            schema_version: SCHEMA_VERSION,
            leases: vec![finished, occupied.clone()],
        };
        let latest = snapshot
            .latest_lease(Some("fixture-alias"), None)
            .expect("a lease");
        assert_eq!(latest.lease_id, occupied.lease_id);
    }

    #[test]
    fn latest_lease_hides_an_unoccupied_warm_up_record() {
        let warmup = lease(DispatchLeaseState::Accepted, ROUTE_WARMUP, 900);
        let snapshot = DispatchSnapshot {
            schema_version: SCHEMA_VERSION,
            leases: vec![warmup],
        };

        assert!(snapshot.latest_lease(Some("fixture-alias"), None).is_none());
        assert!(snapshot
            .latest_lease(None, Some(&account_key("fixture-account")))
            .is_none());

        // A terminal record is still visible as history.
        let terminal = lease(DispatchLeaseState::Accepted, ROUTE_TERMINAL, 900);
        let snapshot = DispatchSnapshot {
            schema_version: SCHEMA_VERSION,
            leases: vec![terminal],
        };
        assert!(snapshot.latest_lease(Some("fixture-alias"), None).is_some());
    }

    #[test]
    fn latest_lease_without_an_alias_only_matches_the_account_key() {
        let snapshot = DispatchSnapshot {
            schema_version: SCHEMA_VERSION,
            leases: vec![lease(DispatchLeaseState::Running, ROUTE_TERMINAL, 100)],
        };

        assert!(snapshot
            .latest_lease(None, Some(&account_key("fixture-account")))
            .is_some());
        assert!(snapshot
            .latest_lease(None, Some(&account_key("another-account")))
            .is_none());
    }

    #[test]
    fn retention_keeps_every_active_lease_and_the_newest_hundred_finished_ones() {
        let mut leases: Vec<DispatchLease> = (0..101)
            .map(|index| {
                let mut record = lease(DispatchLeaseState::Accepted, ROUTE_TERMINAL, index);
                record.lease_id = format!("old-{index}");
                record
            })
            .collect();
        let mut just_finished = lease(DispatchLeaseState::AwaitingAcceptance, ROUTE_TERMINAL, 500);
        just_finished.lease_id = "just-finished".to_string();
        leases.insert(0, just_finished);
        let mut active = lease(DispatchLeaseState::Running, ROUTE_TERMINAL, 1);
        active.lease_id = "active".to_string();
        leases.push(active);

        let retained = recent_ended_leases(&leases);
        assert_eq!(retained.len(), RETAINED_ENDED_LEASES);
        // The just-finished lease survives even though it sits first in the array.
        assert!(retained.iter().any(|l| l.lease_id == "just-finished"));
        assert!(!retained.iter().any(|l| l.lease_id == "old-0"));
        assert!(retained.iter().all(|l| l.state.is_terminal()));

        let ordered = reorder_leases(&leases);
        assert_eq!(ordered[0].lease_id, "active");
        assert_eq!(ordered.len(), RETAINED_ENDED_LEASES + 1);
    }

    #[test]
    fn an_issue_record_carries_both_timestamps() {
        let record = build_issue_record(
            "fixture-issue",
            "observed",
            "A short sanitized observation",
            Some("A"),
            "next-42",
            at(0),
        )
        .expect("valid record");

        assert_eq!(record.component, "next");
        assert_eq!(record.schema_version, SCHEMA_VERSION);
        assert!(record.recorded_at.ends_with('Z'), "UTC stamp must use Z");
        // 12:00 UTC is 20:00 in Asia/Shanghai.
        assert!(record.date_shanghai.starts_with("2026-09-11T20:00:00"));
        assert!(record.date_shanghai.ends_with("+08:00"));
    }

    #[test]
    fn an_issue_record_rejects_what_must_never_enter_the_journal() {
        for summary in [
            "",
            "   ",
            "see /Users/someone/project",
            r"see C:\Users\someone\project",
            "posted to https://open-apis.example/hook",
            "reported by a***@example.com",
            "line\nbreak",
        ] {
            assert!(
                build_issue_record("i", "observed", summary, None, "next-1", at(0)).is_err(),
                "{summary:?} must be rejected"
            );
        }

        assert!(build_issue_record("i", "observed", "A short sanitized observation", None, "next-1", at(0)).is_ok());
        // A slash inside a word is not a path, so ordinary prose still passes.
        assert!(build_issue_record("i", "observed", "5h/7d quota read failed", None, "next-1", at(0)).is_ok());
    }

    #[test]
    fn an_issue_code_is_a_single_upper_case_letter() {
        assert!(is_valid_issue_code("A"));
        assert!(!is_valid_issue_code("a"));
        assert!(!is_valid_issue_code("AB"));
        assert!(!is_valid_issue_code(""));
        assert!(build_issue_record("i", "observed", "ok", Some("a"), "next-1", at(0)).is_err());
        assert!(build_issue_record("i", "observed", "ok", Some("A"), "next-1", at(0)).is_ok());
    }

    #[test]
    fn state_sets_match_the_shared_contract() {
        let active: Vec<&str> = DispatchLeaseState::ALL
            .into_iter()
            .filter(|state| state.is_active())
            .map(|state| state.id())
            .collect();
        assert_eq!(
            active,
            vec!["preparing", "starting", "running", "cancel_requested", "uncertain"]
        );

        let terminal: Vec<&str> = DispatchLeaseState::ALL
            .into_iter()
            .filter(|state| state.is_terminal())
            .map(|state| state.id())
            .collect();
        assert_eq!(
            terminal,
            vec![
                "awaiting_acceptance",
                "accepted",
                "rejected",
                "failed",
                "cancelled"
            ]
        );

        for state in DispatchLeaseState::ALL {
            assert_eq!(DispatchLeaseState::from_id(state.id()), Some(state));
        }
        assert_eq!(DispatchLeaseState::from_id("mystery"), None);
    }
}
