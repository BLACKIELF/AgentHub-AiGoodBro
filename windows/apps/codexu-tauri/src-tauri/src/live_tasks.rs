//! One native SystemDaemon observer, separate from the recorded-history board.
use codexu_core::{
    accounts::AccountManager,
    automatic_switch::{live::*, TaskState},
    managed_proxy::ManagedProxyGate,
    notifications::{NativeTaskCompletionProducer, NotificationService},
};
use serde::Serialize;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, State};

struct Authority(Arc<AccountManager>);
impl SystemScopeAuthority for Authority {
    fn current(&self) -> LiveResult<SystemDaemonScope> {
        let scope = self
            .0
            .verified_active_system_scope()
            .map_err(|_| LiveIssue::ScopeUnverified)?;
        Ok(SystemDaemonScope {
            canonical_home: scope.canonical_home().to_owned(),
            profile_id: scope.profile_id().into(),
            identity_hash: scope.identity_hash().into(),
            credential_generation: scope.credential_generation().into(),
            auth_digest: scope.auth_digest().into(),
            established_at_unix_ms: scope.established_at_unix_ms(),
        })
    }
    fn recheck(&self, scope: &SystemDaemonScope) -> LiveResult<()> {
        (self.current()? == *scope)
            .then_some(())
            .ok_or(LiveIssue::ScopeUnverified)
    }
}
struct Dispatch(Arc<ManagedProxyGate>);
impl SystemActivitySource for Dispatch {
    fn current(&self) -> LiveResult<SystemActivityEvidence> {
        Ok(SystemActivityEvidence {
            observed_at_unix_ms: chrono::Utc::now().timestamp_millis().max(0) as u64,
            // OS focus and inventory are supplied by the verified native peer.
            inactive_since_unix_ms: None,
            legacy_manager_running: None,
            dispatch_busy: self.0.cached_dispatch_busy(),
        })
    }
}
struct Observer {
    completion: Option<Arc<NativeTaskCompletionProducer>>,
    app: AppHandle,
}
impl LiveTaskObserver for Observer {
    fn record(&self, event: LiveTaskEvent) {
        if let Some(completion) = &self.completion {
            completion.record(event);
        }
        // Empty change signal only; the command reads a fresh sanitized cache.
        let _ = self.app.emit("live-tasks:changed", ());
    }
}
pub struct LiveTasks {
    pub source: Arc<SystemDaemonSource>,
    monitor: Mutex<Option<SystemDaemonMonitor>>,
}
impl LiveTasks {
    pub fn new(
        app: AppHandle,
        manager: Arc<AccountManager>,
        gate: Arc<ManagedProxyGate>,
        notifications: Option<&Arc<NotificationService>>,
        owned_domains: Arc<OwnedProcessDomains>,
    ) -> Result<Arc<Self>, &'static str> {
        let completion = notifications.map(NativeTaskCompletionProducer::new);
        let source = SystemDaemonSource::native_with_owned_domains(
            Arc::new(Authority(manager)),
            Arc::new(Dispatch(gate)),
            Some(Arc::new(Observer {
                completion: completion.clone(),
                app,
            })),
            owned_domains,
        )
        .map_err(LiveIssue::code)?;
        if let Some(completion) = completion {
            completion.bind_source(&source).map_err(|e| e.code())?;
        }
        let monitor = source.start().map_err(LiveIssue::code)?;
        Ok(Arc::new(Self {
            source,
            monitor: Mutex::new(Some(monitor)),
        }))
    }
    pub fn cancel(&self) {
        if let Ok(monitor) = self.monitor.try_lock() {
            if let Some(monitor) = &*monitor {
                monitor.cancel();
            }
        }
    }
    /// Explicit retry after the bounded native connection lifecycle finishes.
    /// Never starts or restarts the official application/business process.
    fn reconnect(&self) -> Result<(), &'static str> {
        let mut monitor = self
            .monitor
            .try_lock()
            .map_err(|_| "official_tasks_unavailable")?;
        if monitor.as_ref().is_some_and(|m| !m.is_finished()) {
            return Ok(());
        }
        monitor.take();
        *monitor = Some(self.source.start().map_err(LiveIssue::code)?);
        Ok(())
    }
    fn state(&self) -> LiveTaskStateDto {
        match self.source.latest() {
            Ok(snapshot) => LiveTaskStateDto {
                phase: "live",
                issue_code: None,
                observed_at_ms: Some(snapshot.observed_at_unix_ms()),
                tasks: snapshot
                    .records()
                    .iter()
                    .enumerate()
                    .map(|(index, row)| LiveTaskDto {
                        // Short per-snapshot display positions are not external IDs.
                        ordinal: index + 1,
                        state: task_state(row.state),
                        turn_state: row.turn_state.map(task_state),
                        started_at_ms: row.turn_started_at_unix_ms,
                        completed_at_ms: row.turn_completed_at_unix_ms,
                    })
                    .collect(),
            },
            Err(issue) => LiveTaskStateDto {
                phase: "unavailable",
                issue_code: Some(self.source.issue().unwrap_or(issue).code()),
                observed_at_ms: None,
                tasks: vec![],
            },
        }
    }
}
fn task_state(state: TaskState) -> &'static str {
    match state {
        TaskState::Idle => "idle",
        TaskState::Running => "running",
        TaskState::WaitingInput => "waiting_input",
        TaskState::Recorded => "recorded",
        TaskState::Disconnected => "disconnected",
        TaskState::Failed => "failed",
        TaskState::Completed => "completed",
        TaskState::Interrupted => "interrupted",
    }
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveTaskStateDto {
    phase: &'static str,
    issue_code: Option<&'static str>,
    observed_at_ms: Option<u64>,
    tasks: Vec<LiveTaskDto>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LiveTaskDto {
    ordinal: usize,
    state: &'static str,
    turn_state: Option<&'static str>,
    started_at_ms: Option<u64>,
    completed_at_ms: Option<u64>,
}
pub struct LiveTaskAppState(pub Result<Arc<LiveTasks>, &'static str>);
#[tauri::command]
pub fn get_live_task_state(state: State<'_, LiveTaskAppState>) -> LiveTaskStateDto {
    match &state.0 {
        Ok(service) => service.state(),
        Err(issue) => LiveTaskStateDto {
            phase: "unavailable",
            issue_code: Some(issue),
            observed_at_ms: None,
            tasks: vec![],
        },
    }
}
#[tauri::command]
pub fn reconnect_live_tasks(
    state: State<'_, LiveTaskAppState>,
) -> Result<LiveTaskStateDto, String> {
    let service = state.0.as_ref().map_err(|e| e.to_string())?;
    service.reconnect().map_err(str::to_owned)?;
    Ok(service.state())
}
