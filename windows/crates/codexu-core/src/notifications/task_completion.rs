//! Native live transitions only. History/startup terminal rows are not events.
use super::{NotificationEvent, NotificationService, TaskState};
use crate::automatic_switch::{
    live::{LiveTaskEvent, LiveTaskObserver, LiveTaskRecord, LiveTaskSnapshot, SystemDaemonSource},
    TaskState as LiveState,
};
use std::{
    collections::BTreeMap,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, OnceLock, Weak,
    },
};

#[derive(Clone, PartialEq, Eq)]
struct Scope {
    profile: String,
    identity: String,
    generation: String,
    connection: String,
}
impl Scope {
    fn from_snapshot(value: &LiveTaskSnapshot) -> Self {
        Self {
            profile: value.profile_id().into(),
            identity: value.identity_hash().into(),
            generation: value.credential_generation().into(),
            connection: value.connection_generation().into(),
        }
    }
}
#[derive(Clone)]
struct Transition {
    thread: String,
    turn: String,
    completed: u64,
    state: LiveState,
}
#[derive(Default)]
struct Tracker {
    scope: Option<Scope>,
    revision: u64,
    observed: u64,
    running: BTreeMap<(String, String), u64>,
}
impl Tracker {
    fn observe(
        &mut self,
        scope: Scope,
        revision: u64,
        observed: u64,
        records: &[LiveTaskRecord],
    ) -> Vec<Transition> {
        if self.scope.as_ref() != Some(&scope) {
            *self = Self::default();
            self.scope = Some(scope);
        }
        if revision <= self.revision || observed < self.observed || records.len() > 1000 {
            *self = Self::default();
            return vec![];
        }
        self.revision = revision;
        self.observed = observed;
        let mut current = BTreeMap::new();
        let mut completed = vec![];
        for record in records {
            let Some(turn) = &record.turn_id else {
                continue;
            };
            let key = (record.thread_id.clone(), turn.clone());
            let Some(started) = record
                .turn_started_at_unix_ms
                .filter(|at| *at > 0 && *at <= observed)
            else {
                continue;
            };
            if matches!(record.state, LiveState::Running | LiveState::WaitingInput)
                && record.turn_state == Some(LiveState::Running)
            {
                current.insert(key, started);
            } else if let Some(
                state @ (LiveState::Completed | LiveState::Failed | LiveState::Interrupted),
            ) = record.turn_state
            {
                if self.running.get(&key) != Some(&started) {
                    continue;
                }
                let Some(at) = record
                    .turn_completed_at_unix_ms
                    .filter(|at| *at >= started && *at <= observed && observed - *at <= 300_000)
                else {
                    continue;
                };
                completed.push(Transition {
                    thread: record.thread_id.clone(),
                    turn: turn.clone(),
                    completed: at,
                    state,
                });
            }
        }
        self.running = current;
        completed
    }
}

/// The queue rebinds to the current same peer/identity/turn before each send.
/// These raw IDs exist in memory only; durable delivery keys are hashes.
pub(crate) struct TaskCompletionProof {
    source: Weak<SystemDaemonSource>,
    scope: Scope,
    transition: Transition,
}
impl TaskCompletionProof {
    pub(crate) fn current(&self) -> bool {
        let Some(source) = self.source.upgrade() else {
            return false;
        };
        let Ok(snapshot) = source.latest() else {
            return false;
        };
        snapshot.is_current()
            && Scope::from_snapshot(&snapshot) == self.scope
            && snapshot.records().iter().any(|row| {
                row.thread_id == self.transition.thread
                    && row.turn_id.as_ref() == Some(&self.transition.turn)
                    && row.turn_state == Some(self.transition.state)
                    && row.turn_completed_at_unix_ms == Some(self.transition.completed)
            })
    }
}

pub struct NativeTaskCompletionProducer {
    service: Weak<NotificationService>,
    source: OnceLock<Weak<SystemDaemonSource>>,
    tracker: Mutex<Tracker>,
    discontinuity: AtomicBool,
}
impl NativeTaskCompletionProducer {
    pub fn new(service: &Arc<NotificationService>) -> Arc<Self> {
        Arc::new(Self {
            service: Arc::downgrade(service),
            source: OnceLock::new(),
            tracker: Mutex::new(Tracker::default()),
            discontinuity: AtomicBool::new(false),
        })
    }
    pub fn bind_source(&self, source: &Arc<SystemDaemonSource>) -> super::Result<()> {
        self.source
            .set(Arc::downgrade(source))
            .map_err(|_| super::Failure("task_source_already_bound"))
    }
}
impl LiveTaskObserver for NativeTaskCompletionProducer {
    fn record(&self, event: LiveTaskEvent) {
        let Ok(mut tracker) = self.tracker.try_lock() else {
            self.discontinuity.store(true, Ordering::Release);
            return;
        };
        if self.discontinuity.swap(false, Ordering::AcqRel) {
            *tracker = Tracker::default();
        }
        let LiveTaskEvent::Snapshot(snapshot) = event else {
            *tracker = Tracker::default();
            return;
        };
        if !snapshot.is_current() {
            *tracker = Tracker::default();
            return;
        }
        let Some(source) = self.source.get() else {
            *tracker = Tracker::default();
            return;
        };
        let Some(service) = self.service.upgrade() else {
            return;
        };
        let scope = Scope::from_snapshot(&snapshot);
        let transitions = tracker.observe(
            scope.clone(),
            snapshot.revision(),
            snapshot.observed_at_unix_ms(),
            snapshot.records(),
        );
        for transition in transitions {
            let state = match transition.state {
                LiveState::Completed => TaskState::Completed,
                LiveState::Failed => TaskState::Failed,
                LiveState::Interrupted => TaskState::Interrupted,
                _ => continue,
            };
            let key = super::hash(
                format!(
                    "task:{}:{}:{}:{}:{}",
                    scope.profile,
                    scope.identity,
                    scope.generation,
                    transition.thread,
                    transition.turn
                )
                .as_bytes(),
            );
            // No prompt, title, path, email or raw remote identifier is displayed.
            if let Ok(mut event) = NotificationEvent::task(
                &key,
                "Codex",
                "Codex 任务",
                state,
                (transition.completed / 1000) as i64,
            ) {
                event.task_proof = Some(Arc::new(TaskCompletionProof {
                    source: source.clone(),
                    scope: scope.clone(),
                    transition,
                }));
                let _ = service.queue_event(event);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn scope() -> Scope {
        Scope {
            profile: "p".into(),
            identity: "i".into(),
            generation: "g".into(),
            connection: "c".into(),
        }
    }
    fn row(state: LiveState) -> LiveTaskRecord {
        LiveTaskRecord {
            thread_id: "thread".into(),
            state,
            turn_id: Some("turn".into()),
            turn_state: Some(state),
            turn_started_at_unix_ms: Some(1000),
            turn_completed_at_unix_ms: (state == LiveState::Completed).then_some(2000),
        }
    }
    #[test]
    fn terminal_history_is_not_startup_completion() {
        assert!(Tracker::default()
            .observe(scope(), 1, 2500, &[row(LiveState::Completed)])
            .is_empty());
    }
    #[test]
    fn witnessed_same_turn_completes_once() {
        let mut t = Tracker::default();
        assert!(t
            .observe(scope(), 1, 1500, &[row(LiveState::Running)])
            .is_empty());
        assert_eq!(
            t.observe(scope(), 2, 2500, &[row(LiveState::Completed)])
                .len(),
            1
        );
        assert!(t
            .observe(scope(), 3, 2600, &[row(LiveState::Completed)])
            .is_empty());
    }
    #[test]
    fn connection_identity_generation_changes_cannot_reuse_running_witness() {
        for field in 0..4 {
            let mut t = Tracker::default();
            t.observe(scope(), 1, 1500, &[row(LiveState::Running)]);
            let mut s = scope();
            match field {
                0 => s.profile.push('2'),
                1 => s.identity.push('2'),
                2 => s.generation.push('2'),
                _ => s.connection.push('2'),
            }
            assert!(t
                .observe(s, 2, 2500, &[row(LiveState::Completed)])
                .is_empty());
        }
    }
    #[test]
    fn absent_turn_discontinuity_or_out_of_order_sample_cannot_complete() {
        for mode in 0..4 {
            let mut t = Tracker::default();
            t.observe(scope(), 1, 1500, &[row(LiveState::Running)]);
            let mut done = row(LiveState::Completed);
            match mode {
                0 => {
                    t.observe(scope(), 2, 1600, &[]);
                }
                1 => {
                    t.observe(scope(), 1, 1600, &[row(LiveState::Running)]);
                }
                2 => done.turn_id = Some("another".into()),
                _ => done.turn_completed_at_unix_ms = Some(900),
            }
            assert!(t.observe(scope(), 3, 2500, &[done]).is_empty());
        }
    }
    #[test]
    fn terminal_turn_metadata_does_not_mark_runtime_idle() {
        let mut t = Tracker::default();
        t.observe(scope(), 1, 1500, &[row(LiveState::Running)]);
        let mut done = row(LiveState::Completed);
        done.state = LiveState::Running;
        assert_eq!(t.observe(scope(), 2, 2500, &[done]).len(), 1);
        // This producer reports the observed turn only; no idle policy is exposed.
    }
}
