use super::*;
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) struct Boundary {
    request: u64,
    revision: u64,
}
struct Refresh {
    boundary: Boundary,
    loaded: Option<BTreeSet<String>>,
    rows: BTreeMap<String, LiveTaskRecord>,
    observed_at_unix_ms: u64,
}
pub(super) struct Reducer {
    scope: SystemDaemonScope,
    generation: String,
    revision: u64,
    records: BTreeMap<String, LiveTaskRecord>,
    notifications: BTreeMap<String, u64>,
    pending: Option<Refresh>,
    complete: bool,
    roster_observed_at_unix_ms: u64,
    valid: Arc<AtomicBool>,
    current_revision: Arc<AtomicU64>,
}
impl Reducer {
    pub(super) fn new(scope: SystemDaemonScope, generation: String, now: u64) -> LiveResult<Self> {
        scope.validate(now)?;
        if !valid_id(&generation) {
            return Err(LiveIssue::Protocol);
        }
        Ok(Self {
            scope,
            generation,
            revision: 0,
            records: BTreeMap::new(),
            notifications: BTreeMap::new(),
            pending: None,
            complete: false,
            roster_observed_at_unix_ms: 0,
            valid: Arc::new(AtomicBool::new(true)),
            current_revision: Arc::new(AtomicU64::new(0)),
        })
    }
    pub(super) fn invalidate(&mut self) {
        self.valid.store(false, Ordering::Release);
        self.complete = false;
        self.pending = None;
        self.records.clear();
        self.notifications.clear();
    }
    pub(super) fn begin(&mut self, request: u64, now: u64) -> LiveResult<Boundary> {
        if request == 0 || self.pending.is_some() || !self.valid.load(Ordering::Acquire) {
            return Err(LiveIssue::Protocol);
        }
        let boundary = Boundary {
            request,
            revision: self.revision,
        };
        self.pending = Some(Refresh {
            boundary,
            loaded: None,
            rows: BTreeMap::new(),
            observed_at_unix_ms: now,
        });
        Ok(boundary)
    }
    pub(super) fn loaded(&mut self, boundary: Boundary, result: &Value) -> LiveResult<Vec<String>> {
        let pending = self
            .pending
            .as_mut()
            .filter(|p| p.boundary == boundary)
            .ok_or(LiveIssue::Protocol)?;
        if pending.loaded.is_some() || result.get("nextCursor") != Some(&Value::Null) {
            return Err(LiveIssue::Incomplete);
        }
        let ids = result
            .get("data")
            .and_then(Value::as_array)
            .ok_or(LiveIssue::Protocol)?;
        if ids.len() > MAXIMUM_THREADS {
            return Err(LiveIssue::Overflow);
        }
        let mut loaded = BTreeSet::new();
        for id in ids {
            let id = id
                .as_str()
                .filter(|v| opaque_id(v))
                .ok_or(LiveIssue::Protocol)?;
            if !loaded.insert(id.to_owned()) {
                return Err(LiveIssue::Protocol);
            }
        }
        let out = loaded.iter().cloned().collect();
        pending.loaded = Some(loaded);
        Ok(out)
    }
    pub(super) fn row(
        &mut self,
        boundary: Boundary,
        expected: &str,
        result: &Value,
    ) -> LiveResult<()> {
        let pending = self
            .pending
            .as_mut()
            .filter(|p| p.boundary == boundary)
            .ok_or(LiveIssue::Protocol)?;
        if !pending
            .loaded
            .as_ref()
            .is_some_and(|ids| ids.contains(expected))
            || pending.rows.contains_key(expected)
        {
            return Err(LiveIssue::Protocol);
        }
        let thread = result.get("thread").ok_or(LiveIssue::Protocol)?;
        if thread.get("id").and_then(Value::as_str) != Some(expected) {
            return Err(LiveIssue::Protocol);
        }
        let state = runtime_state(thread.get("status").ok_or(LiveIssue::Protocol)?)?;
        // A loaded-set member cannot be reconciled using a recorded-only row.
        if state == TaskState::Recorded {
            return Err(LiveIssue::Incomplete);
        }
        pending.rows.insert(
            expected.into(),
            LiveTaskRecord {
                thread_id: expected.into(),
                state,
                turn_id: None,
                turn_state: None,
                turn_started_at_unix_ms: None,
                turn_completed_at_unix_ms: None,
            },
        );
        Ok(())
    }
    pub(super) fn turn(
        &mut self,
        boundary: Boundary,
        expected: &str,
        result: &Value,
        now: u64,
    ) -> LiveResult<()> {
        let pending = self
            .pending
            .as_mut()
            .filter(|p| p.boundary == boundary)
            .ok_or(LiveIssue::Protocol)?;
        let row = pending.rows.get_mut(expected).ok_or(LiveIssue::Protocol)?;
        let turns = result
            .get("data")
            .and_then(Value::as_array)
            .ok_or(LiveIssue::Protocol)?;
        if turns.len() > 1 {
            return Err(LiveIssue::Overflow);
        }
        let Some(turn) = turns.first() else {
            return if matches!(row.state, TaskState::Running | TaskState::WaitingInput) {
                Err(LiveIssue::Incomplete)
            } else {
                Ok(())
            };
        };
        // This query intentionally includes only current-turn metadata, not
        // complete history. Its nextCursor must never be used as global idle
        // proof; the independently complete loaded roster supplies that proof.
        if turn.get("itemsView").and_then(Value::as_str) != Some("notLoaded")
            || !turn
                .get("items")
                .and_then(Value::as_array)
                .is_some_and(Vec::is_empty)
        {
            return Err(LiveIssue::Protocol);
        }
        let id = turn
            .get("id")
            .and_then(Value::as_str)
            .filter(|v| opaque_id(v))
            .ok_or(LiveIssue::Protocol)?;
        let state = match turn.get("status").and_then(Value::as_str) {
            Some("inProgress") => TaskState::Running,
            Some("completed") => TaskState::Completed,
            Some("failed") => TaskState::Failed,
            Some("interrupted") => TaskState::Interrupted,
            _ => return Err(LiveIssue::Protocol),
        };
        let start = timestamp(turn.get("startedAt"), now)?;
        let end = timestamp(turn.get("completedAt"), now)?;
        if matches!((start,end),(Some(a),Some(b)) if b<a) {
            return Err(LiveIssue::Protocol);
        }
        if matches!(row.state, TaskState::Running | TaskState::WaitingInput) && terminal(state) {
            // A newly started runtime turn can precede history metadata. Keep
            // its busy state, without attributing an older terminal turn ID.
            return Ok(());
        }
        row.turn_id = Some(id.into());
        row.turn_state = Some(state);
        row.turn_started_at_unix_ms = start;
        row.turn_completed_at_unix_ms = end;
        Ok(())
    }
    pub(super) fn finish(&mut self, boundary: Boundary, now: u64) -> LiveResult<()> {
        let pending = self
            .pending
            .take()
            .filter(|p| p.boundary == boundary)
            .ok_or(LiveIssue::Protocol)?;
        let loaded = pending.loaded.ok_or(LiveIssue::Incomplete)?;
        if loaded.len() != pending.rows.len() {
            return Err(LiveIssue::Incomplete);
        }
        let mut next = pending.rows;
        for (id, previous) in &self.records {
            if self
                .notifications
                .get(id)
                .is_some_and(|r| *r > boundary.revision)
            {
                // Notifications received after request emission win, including
                // an active thread omitted from that older loaded-set response.
                next.insert(id.clone(), previous.clone());
            }
        }
        if next.len() > MAXIMUM_THREADS {
            return Err(LiveIssue::Overflow);
        }
        self.notifications.retain(|_, r| *r > boundary.revision);
        self.records = next;
        self.complete = true;
        if !is_fresh(pending.observed_at_unix_ms, TASK_MAX_AGE_MS, now) {
            return Err(LiveIssue::Incomplete);
        }
        self.roster_observed_at_unix_ms = pending.observed_at_unix_ms;
        self.advance()?;
        Ok(())
    }
    fn advance(&mut self) -> LiveResult<()> {
        self.revision = self.revision.checked_add(1).ok_or(LiveIssue::Overflow)?;
        self.current_revision
            .store(self.revision, Ordering::Release);
        Ok(())
    }
    pub(super) fn notification(
        &mut self,
        method: &str,
        params: &Value,
        now: u64,
    ) -> LiveResult<bool> {
        if !matches!(
            method,
            "thread/status/changed" | "turn/started" | "turn/completed"
        ) {
            return Ok(false);
        }
        let id = params
            .get("threadId")
            .and_then(Value::as_str)
            .filter(|v| opaque_id(v))
            .ok_or(LiveIssue::Protocol)?;
        let previous = self.records.get(id);
        let mut row = previous.cloned().unwrap_or_else(|| LiveTaskRecord {
            thread_id: id.into(),
            state: TaskState::Disconnected,
            turn_id: None,
            turn_state: None,
            turn_started_at_unix_ms: None,
            turn_completed_at_unix_ms: None,
        });
        if method == "thread/status/changed" {
            row.state = runtime_state(params.get("status").ok_or(LiveIssue::Protocol)?)?;
            if (matches!(row.state, TaskState::Running | TaskState::WaitingInput)
                && row.turn_state != Some(TaskState::Running))
                || matches!(row.state, TaskState::Recorded | TaskState::Failed)
            {
                // Runtime may already have started a newer turn while history
                // still names the previous one. Do not attribute its busy
                // state to that old ID or accept a late old completion as idle.
                row.turn_id = None;
                row.turn_state = None;
                row.turn_started_at_unix_ms = None;
                row.turn_completed_at_unix_ms = None;
            }
        } else {
            let turn = params.get("turn").ok_or(LiveIssue::Protocol)?;
            let turn_id = turn
                .get("id")
                .and_then(Value::as_str)
                .filter(|v| opaque_id(v))
                .ok_or(LiveIssue::Protocol)?;
            if method == "turn/completed" && row.turn_id.as_ref().is_some_and(|id| id != turn_id) {
                return Ok(false);
            }
            let state = match turn.get("status").and_then(Value::as_str) {
                Some("inProgress") if method == "turn/started" => TaskState::Running,
                Some("completed") if method == "turn/completed" => TaskState::Completed,
                Some("failed") if method == "turn/completed" => TaskState::Failed,
                Some("interrupted") if method == "turn/completed" => TaskState::Interrupted,
                _ => return Err(LiveIssue::Protocol),
            };
            if row.turn_id.as_deref() == Some(turn_id) && row.turn_state.is_some_and(terminal) {
                // No terminal turn may be resurrected by an older start, or
                // replayed by another terminal notification.
                return Ok(false);
            }
            let started = timestamp(turn.get("startedAt"), now)?;
            let completed = timestamp(turn.get("completedAt"), now)?;
            if matches!((started, completed), (Some(a), Some(b)) if b < a) {
                return Err(LiveIssue::Protocol);
            }
            if method == "turn/completed"
                && row.turn_id.is_none()
                && matches!(row.state, TaskState::Running | TaskState::WaitingInput)
            {
                return Ok(false);
            }
            if method == "turn/started" && row.turn_id.as_ref().is_some_and(|id| id != turn_id) {
                match (row.turn_started_at_unix_ms, started) {
                    (Some(previous), Some(incoming)) if incoming < previous => return Ok(false),
                    (Some(previous), Some(incoming)) if incoming > previous => {}
                    _ => return Err(LiveIssue::Incomplete),
                }
            }
            row.turn_id = Some(turn_id.into());
            row.turn_state = Some(state);
            row.turn_started_at_unix_ms = started.or_else(|| {
                previous.and_then(|p| {
                    (p.turn_id.as_deref() == Some(turn_id))
                        .then_some(p.turn_started_at_unix_ms)
                        .flatten()
                })
            });
            row.turn_completed_at_unix_ms = completed;
        }
        if !self.records.contains_key(id) && self.records.len() >= MAXIMUM_THREADS {
            return Err(LiveIssue::Overflow);
        }
        self.advance()?;
        self.notifications.insert(id.into(), self.revision);
        self.records.insert(id.into(), row);
        Ok(true)
    }
    pub(super) fn snapshot(&self, now: u64) -> LiveResult<Arc<LiveTaskSnapshot>> {
        if !self.complete
            || !self.valid.load(Ordering::Acquire)
            || !is_fresh(self.roster_observed_at_unix_ms, TASK_MAX_AGE_MS, now)
        {
            return Err(LiveIssue::Incomplete);
        }
        // Unrelated notifications cannot extend the age of a complete roster.
        Ok(Arc::new(LiveTaskSnapshot {
            scope: self.scope.clone(),
            connection_generation: self.generation.clone(),
            revision: self.revision,
            observed_at_unix_ms: self.roster_observed_at_unix_ms,
            records: self.records.values().cloned().collect(),
            valid: self.valid.clone(),
            current_revision: self.current_revision.clone(),
        }))
    }
}
fn runtime_state(value: &Value) -> LiveResult<TaskState> {
    Ok(match value.get("type").and_then(Value::as_str) {
        Some("idle") => TaskState::Idle,
        Some("notLoaded") => TaskState::Recorded,
        Some("systemError") => TaskState::Failed,
        Some("active") => {
            let flags = value
                .get("activeFlags")
                .and_then(Value::as_array)
                .ok_or(LiveIssue::Protocol)?;
            if flags
                .iter()
                .any(|f| !matches!(f.as_str(), Some("waitingOnApproval" | "waitingOnUserInput")))
            {
                return Err(LiveIssue::Protocol);
            }
            if flags.is_empty() {
                TaskState::Running
            } else {
                TaskState::WaitingInput
            }
        }
        _ => return Err(LiveIssue::Protocol),
    })
}
fn timestamp(value: Option<&Value>, now: u64) -> LiveResult<Option<u64>> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(value) => {
            let seconds = value
                .as_f64()
                .filter(|v| {
                    v.is_finite() && *v > 0.0 && *v <= (now.saturating_add(5_000) as f64) / 1000.0
                })
                .ok_or(LiveIssue::Protocol)?;
            Ok(Some((seconds * 1000.0) as u64))
        }
    }
}
fn terminal(state: TaskState) -> bool {
    matches!(
        state,
        TaskState::Completed | TaskState::Failed | TaskState::Interrupted
    )
}
