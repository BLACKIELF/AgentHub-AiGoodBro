//! Account occupancy and the dispatch reservation gate.
//!
//! The workbench is a *coordination* surface: it records that an account and a
//! real project directory are in use so that a second caller cannot silently
//! take the same slot. Two rules from the macOS product are load-bearing here:
//!
//! * A concurrent reservation for the same account or the same real project
//!   directory is rejected.
//! * A missed heartbeat is *not* treated as idle. It downgrades the record to
//!   "unconfirmed" and keeps holding the slot.

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

use super::account::AccountRecord;

/// Occupancy state shown on the workbench.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OccupancyState {
    /// Slot reserved, real execution not yet proven.
    OnlinePreparing,
    /// A real process or Hub run evidence exists.
    OnlineRunning,
    /// Warm-up or an authorized maintenance hold.
    OnlineMaintenance,
    /// The process ended; the result still needs review.
    EndedPendingReview,
    /// Evidence is insufficient. The slot is kept.
    Unconfirmed,
}

impl OccupancyState {
    pub fn id(self) -> &'static str {
        match self {
            OccupancyState::OnlinePreparing => "online_preparing",
            OccupancyState::OnlineRunning => "online_running",
            OccupancyState::OnlineMaintenance => "online_maintenance",
            OccupancyState::EndedPendingReview => "ended_pending_review",
            OccupancyState::Unconfirmed => "unconfirmed",
        }
    }

    /// Chinese label as published on the workbench status table.
    pub fn label_zh(self) -> &'static str {
        match self {
            OccupancyState::OnlinePreparing => "在线·准备中",
            OccupancyState::OnlineRunning => "在线·运行中",
            OccupancyState::OnlineMaintenance => "在线·维护中",
            OccupancyState::EndedPendingReview => "已结束·待验收",
            OccupancyState::Unconfirmed => "状态待确认",
        }
    }

    pub fn label_en(self) -> &'static str {
        match self {
            OccupancyState::OnlinePreparing => "Online · preparing",
            OccupancyState::OnlineRunning => "Online · running",
            OccupancyState::OnlineMaintenance => "Online · maintenance",
            OccupancyState::EndedPendingReview => "Ended · awaiting review",
            OccupancyState::Unconfirmed => "State unconfirmed",
        }
    }

    /// Whether this state keeps holding the slot.
    ///
    /// Every current state holds its slot, including the terminal-looking
    /// "awaiting review" state: the slot is only released by an explicit release
    /// action, never by time passing.
    pub fn holds_slot(self) -> bool {
        match self {
            OccupancyState::OnlinePreparing
            | OccupancyState::OnlineRunning
            | OccupancyState::OnlineMaintenance
            | OccupancyState::EndedPendingReview
            | OccupancyState::Unconfirmed => true,
        }
    }
}

/// One occupancy record for an account.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OccupancyRecord {
    pub account_id: String,
    /// Dispatch identifier when the reservation came from the coordination
    /// protocol. `None` for a local manual hold.
    pub dispatch_id: Option<String>,
    /// Project directory *basename* only. The full path is never persisted.
    pub project_dir_label: String,
    pub state: OccupancyState,
    /// Short evidence note describing what the state is based on.
    pub state_basis: String,
    #[serde(with = "chrono::serde::ts_milliseconds_option")]
    pub heartbeat_at: Option<DateTime<Utc>>,
    #[serde(with = "chrono::serde::ts_milliseconds")]
    pub started_at: DateTime<Utc>,
}

impl OccupancyRecord {
    /// Downgrade to `Unconfirmed` when the heartbeat has gone quiet.
    ///
    /// A missed heartbeat never means "free". It means the workbench no longer
    /// has proof, so the slot stays held and the caller must re-verify.
    pub fn reconcile(&self, now: DateTime<Utc>, heartbeat_timeout: Duration) -> OccupancyState {
        match self.heartbeat_at {
            Some(heartbeat) => {
                let age = now - heartbeat;
                if age < Duration::zero() || age > heartbeat_timeout {
                    OccupancyState::Unconfirmed
                } else {
                    self.state
                }
            }
            // No heartbeat at all is insufficient evidence, not a free slot.
            None => OccupancyState::Unconfirmed,
        }
    }
}

/// Why a new dispatch reservation was refused.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "reason", content = "detail")]
pub enum DispatchRejection {
    /// The account is signed out or opted out of dispatch.
    AccountNotParticipating,
    /// The account already holds a slot.
    AccountBusy(OccupancyState),
    /// The account's heartbeat expired, so its state is unconfirmed. Still held.
    HeartbeatExpired,
    /// Another reservation already owns this project directory.
    ProjectBusy { project_dir_label: String },
}

/// Result of a reservation attempt.
pub type DispatchDecision = Result<(), DispatchRejection>;

/// Decide whether a new task may reserve `account` for `project_dir_label`.
///
/// `existing` is the current occupancy set. The check is intentionally
/// fail-closed: any unresolved hold, including an unconfirmed one, refuses the
/// new reservation.
pub fn can_accept_new_task(
    account: &AccountRecord,
    project_dir_label: &str,
    existing: &[OccupancyRecord],
    now: DateTime<Utc>,
    heartbeat_timeout: Duration,
) -> DispatchDecision {
    if !account.is_dispatch_eligible() {
        return Err(DispatchRejection::AccountNotParticipating);
    }

    for record in existing.iter().filter(|r| r.account_id == account.identity.id) {
        let reconciled = record.reconcile(now, heartbeat_timeout);
        if reconciled == OccupancyState::Unconfirmed && record.state != OccupancyState::Unconfirmed {
            return Err(DispatchRejection::HeartbeatExpired);
        }
        if reconciled.holds_slot() {
            return Err(DispatchRejection::AccountBusy(reconciled));
        }
    }

    let requested = project_dir_label.trim();
    if !requested.is_empty() {
        for record in existing.iter().filter(|r| r.project_dir_label == requested) {
            let reconciled = record.reconcile(now, heartbeat_timeout);
            if reconciled.holds_slot() {
                return Err(DispatchRejection::ProjectBusy {
                    project_dir_label: requested.to_string(),
                });
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::account::{AccountIdentity, ExecutionPreference};
    use chrono::TimeZone;

    fn at(minutes: i64) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 9, 11, 12, 0, 0)
            .single()
            .expect("valid timestamp")
            + Duration::minutes(minutes)
    }

    fn account() -> AccountRecord {
        AccountRecord {
            identity: AccountIdentity {
                id: "acc-1".to_string(),
                label: "work".to_string(),
                masked_email: Some("a***@example.com".to_string()),
                plan_label: Some("plus".to_string()),
                is_signed_in: true,
            },
            home_dir_label: "profile-a".to_string(),
            preference: ExecutionPreference::default(),
            participates_in_dispatch: true,
            order: 0,
            pinned_first: false,
            is_system_profile: false,
        }
    }

    fn record(state: OccupancyState, heartbeat_minutes: Option<i64>) -> OccupancyRecord {
        OccupancyRecord {
            account_id: "acc-1".to_string(),
            dispatch_id: Some("d-1".to_string()),
            project_dir_label: "proj-a".to_string(),
            state,
            state_basis: "test".to_string(),
            heartbeat_at: heartbeat_minutes.map(at),
            started_at: at(-10),
        }
    }

    const TIMEOUT: Duration = Duration::minutes(2);

    #[test]
    fn every_state_keeps_holding_its_slot() {
        for state in [
            OccupancyState::OnlinePreparing,
            OccupancyState::OnlineRunning,
            OccupancyState::OnlineMaintenance,
            OccupancyState::EndedPendingReview,
            OccupancyState::Unconfirmed,
        ] {
            assert!(state.holds_slot(), "{} must hold its slot", state.id());
        }
    }

    #[test]
    fn state_labels_match_the_published_table() {
        assert_eq!(OccupancyState::OnlinePreparing.label_zh(), "在线·准备中");
        assert_eq!(OccupancyState::OnlineRunning.label_zh(), "在线·运行中");
        assert_eq!(OccupancyState::OnlineMaintenance.label_zh(), "在线·维护中");
        assert_eq!(OccupancyState::EndedPendingReview.label_zh(), "已结束·待验收");
        assert_eq!(OccupancyState::Unconfirmed.label_zh(), "状态待确认");
    }

    #[test]
    fn empty_occupancy_allows_the_reservation() {
        assert_eq!(
            can_accept_new_task(&account(), "proj-a", &[], at(0), TIMEOUT),
            Ok(())
        );
    }

    #[test]
    fn an_opted_out_account_is_refused() {
        let mut account = account();
        account.participates_in_dispatch = false;
        assert_eq!(
            can_accept_new_task(&account, "proj-a", &[], at(0), TIMEOUT),
            Err(DispatchRejection::AccountNotParticipating)
        );
    }

    #[test]
    fn a_busy_account_is_refused_even_for_a_different_project() {
        let existing = vec![record(OccupancyState::OnlineRunning, Some(0))];
        assert_eq!(
            can_accept_new_task(&account(), "proj-b", &existing, at(1), TIMEOUT),
            Err(DispatchRejection::AccountBusy(OccupancyState::OnlineRunning))
        );
    }

    #[test]
    fn a_busy_project_is_refused_for_a_different_account() {
        let mut other = account();
        other.identity.id = "acc-2".to_string();
        let existing = vec![record(OccupancyState::OnlineRunning, Some(0))];
        assert_eq!(
            can_accept_new_task(&other, "proj-a", &existing, at(1), TIMEOUT),
            Err(DispatchRejection::ProjectBusy {
                project_dir_label: "proj-a".to_string()
            })
        );
    }

    #[test]
    fn a_blank_project_label_does_not_collide() {
        let existing = vec![record(OccupancyState::OnlineRunning, Some(0))];
        assert_eq!(
            can_accept_new_task(&account(), "   ", &existing, at(1), TIMEOUT),
            Err(DispatchRejection::AccountBusy(OccupancyState::OnlineRunning))
        );
    }

    #[test]
    fn a_missed_heartbeat_is_never_treated_as_idle() {
        let stale = record(OccupancyState::OnlineRunning, Some(-30));
        assert_eq!(stale.reconcile(at(0), TIMEOUT), OccupancyState::Unconfirmed);

        let existing = vec![stale];
        assert_eq!(
            can_accept_new_task(&account(), "proj-b", &existing, at(0), TIMEOUT),
            Err(DispatchRejection::HeartbeatExpired)
        );
    }

    #[test]
    fn a_record_without_any_heartbeat_stays_unconfirmed_and_blocks() {
        let existing = vec![record(OccupancyState::OnlinePreparing, None)];
        assert_eq!(
            can_accept_new_task(&account(), "proj-b", &existing, at(0), TIMEOUT),
            Err(DispatchRejection::HeartbeatExpired)
        );
    }

    #[test]
    fn awaiting_review_still_blocks_until_released() {
        let existing = vec![record(OccupancyState::EndedPendingReview, Some(0))];
        assert_eq!(
            can_accept_new_task(&account(), "proj-b", &existing, at(1), TIMEOUT),
            Err(DispatchRejection::AccountBusy(
                OccupancyState::EndedPendingReview
            ))
        );
    }
}
