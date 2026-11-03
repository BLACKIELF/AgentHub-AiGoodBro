//! Explicit original-thread recovery for a durably staged quota pause.
//! No UI request supplies identity, task evidence, a prompt, or a file path.
use super::{
    desktop_owner_actions::{NativeOwnerContext, OwnerAction},
    task_workbench::{capture_owner_context, capture_owner_context_with_guard},
};
use crate::{app_state::AppState, live_tasks::LiveTasks};
use codexu_core::{
    accounts::{AccountManager, ActiveSystemScope},
    automatic_switch::{
        live::LiveTaskSnapshot, quota_resume::*, Failure, QuotaPauseController, QuotaPauseReceipt,
        QuotaPauseRequest, Result, TaskState,
    },
    desktop_owner::Cancellation,
    managed_proxy::ManagedProxyGate,
    task_workbench::TaskWorkbenchStore,
};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};
use tauri::{AppHandle, Emitter, State};

#[derive(Clone)]
pub(crate) struct QuotaResumeAdapter {
    state: Arc<AppState>,
    accounts: Arc<AccountManager>,
    gate: Arc<ManagedProxyGate>,
    live: Arc<LiveTasks>,
    journal: Arc<QuotaResumeJournal>,
    operation: Arc<Mutex<()>>,
    epoch: Arc<AtomicU64>,
    exiting: Arc<AtomicBool>,
}
impl QuotaResumeAdapter {
    pub(crate) fn new(
        state: Arc<AppState>,
        accounts: Arc<AccountManager>,
        gate: Arc<ManagedProxyGate>,
        live: Arc<LiveTasks>,
        path: PathBuf,
    ) -> Result<Arc<Self>> {
        Ok(Arc::new(Self {
            state,
            accounts,
            gate,
            live,
            journal: Arc::new(QuotaResumeJournal::new(path)?),
            operation: Arc::new(Mutex::new(())),
            epoch: Arc::new(AtomicU64::new(0)),
            exiting: Arc::new(AtomicBool::new(false)),
        }))
    }
    pub(crate) fn has_inflight_operation(&self) -> bool {
        self.operation.try_lock().is_err()
    }
    pub(crate) fn cancel_for_exit(&self) {
        self.exiting.store(true, Ordering::Release);
        self.epoch.fetch_add(1, Ordering::AcqRel);
    }
    fn selected_scope(&self, active: &ActiveSystemScope) -> Result<String> {
        let config = self.state.config.blocking_read();
        if config.codex_root.canonicalize().ok().as_deref() != Some(active.canonical_home()) {
            return Err(Failure::IdentityChanged);
        }
        let store = TaskWorkbenchStore::open(&self.state.app_data_dir, &config.codex_root)
            .map_err(|_| Failure::TaskUnknown)?;
        self.accounts
            .recheck_active_system_scope(active)
            .map_err(|_| Failure::IdentityChanged)?;
        Ok(store.scope_id().to_owned())
    }
    async fn capture(
        &self,
        scope: &str,
        turn: &TurnRef,
    ) -> std::result::Result<NativeOwnerContext, String> {
        capture_owner_context(
            self.state.clone(),
            self.accounts.clone(),
            scope.into(),
            turn.thread_id.clone(),
        )
        .await
    }
    fn pause_cancel(
        &self,
        request: &QuotaPauseRequest,
        turn: &TurnRef,
        context: NativeOwnerContext,
    ) -> Cancellation {
        let state = self.state.clone();
        let accounts = self.accounts.clone();
        let source = self.live.source.clone();
        let original = request.snapshot.clone();
        let lease = request.lease.clone();
        let admission = request.admission.clone();
        let exiting = self.exiting.clone();
        let turn = turn.clone();
        Cancellation::while_allowed(Arc::new(move || {
            !exiting.load(Ordering::Acquire)
                && admission()
                && lease.recheck().is_ok()
                && state
                    .config
                    .try_read()
                    .is_ok_and(|config| context.recheck_admission(&accounts, &config.codex_root))
                && source.latest().is_ok_and(|snapshot| {
                    snapshot.matches_pause_roster(&original, false)
                        && snapshot.records().iter().any(|row| {
                            row.thread_id == turn.thread_id
                                && row.turn_id.as_deref() == Some(&turn.turn_id)
                                && row.state == TaskState::Running
                                && row.turn_state == Some(TaskState::Running)
                        })
                })
        }))
    }
    fn pause_current(
        &self,
        request: &QuotaPauseRequest,
        require_idle: bool,
    ) -> Result<Arc<LiveTaskSnapshot>> {
        if self.exiting.load(Ordering::Acquire) || !(request.admission)() {
            return Err(Failure::Cancelled);
        }
        request.lease.recheck().map_err(|_| Failure::AccountBusy)?;
        self.accounts
            .recheck_active_system_scope(&request.source)
            .map_err(|_| Failure::IdentityChanged)?;
        let current = self
            .live
            .source
            .latest()
            .map_err(|_| Failure::TaskUnknown)?;
        if !current.matches_scope(&request.source)
            || !current.matches_pause_roster(&request.snapshot, require_idle)
        {
            return Err(Failure::TaskUnknown);
        }
        Ok(current)
    }
    async fn pause_async(
        &self,
        request: QuotaPauseRequest,
        scope: String,
    ) -> Result<Option<QuotaPauseReceipt>> {
        if !request.snapshot.is_current()
            || !request.snapshot.matches_scope(&request.source)
            || request.snapshot.records().len() > 128
        {
            return Err(Failure::TaskUnknown);
        }
        let mut turns = Vec::new();
        for row in request.snapshot.records() {
            match row.state {
                TaskState::Running if row.turn_state == Some(TaskState::Running) => {
                    turns.push(TurnRef::new(
                        row.thread_id.clone(),
                        row.turn_id.clone().ok_or(Failure::TaskUnknown)?,
                    )?);
                }
                TaskState::Idle if row.turn_state != Some(TaskState::Running) => {}
                _ => return Err(Failure::TaskBusy),
            }
        }
        self.pause_current(&request, false)?;
        if turns.is_empty() {
            return Ok(None);
        }
        let target = AccountIdentity::new(
            request.target_profile_id.clone(),
            request.target_identity_hash.clone(),
            request.target_credential_generation.clone(),
        )?;
        let token = self.journal.stage_batch(
            ResumeScope::new(identity(&request.source)?, target, scope.clone())?,
            turns.clone(),
        )?;
        let deadline = Instant::now() + Duration::from_secs(90);
        for turn in turns {
            let snapshot = self.pause_current(&request, false)?;
            let row = snapshot
                .records()
                .iter()
                .find(|row| row.thread_id == turn.thread_id)
                .ok_or(Failure::TaskUnknown)?;
            if row.state == TaskState::Idle {
                let status = match row.turn_state {
                    Some(TaskState::Completed) => TerminalTurnStatus::Completed,
                    Some(TaskState::Interrupted) => TerminalTurnStatus::Interrupted,
                    _ => return Err(Failure::RecoveryRequired),
                };
                self.journal.skip_terminal_before_interrupt(
                    &token,
                    &ExactTurnTerminalSnapshot::new(turn.clone(), status)?,
                )?;
                continue;
            }
            if Instant::now() >= deadline {
                return Err(Failure::RecoveryRequired);
            }
            let context = self
                .capture(&scope, &turn)
                .await
                .map_err(|_| Failure::TaskUnknown)?;
            let cancel = self.pause_cancel(&request, &turn, context.clone());
            let operation_id = operation_id(&token.batch_id(), &turn, "interrupt");
            let outcome = {
                let mut actions = self.state.owner_actions.lock().await;
                let actions = actions.as_mut().ok_or(Failure::Unavailable)?;
                let preview = actions
                    .prepare(
                        context,
                        OwnerAction::Interrupt {
                            expected_turn_id: turn.turn_id.clone(),
                        },
                        request.lease.clone().into(),
                    )
                    .await
                    .map_err(|_| Failure::TaskUnknown)?;
                if cancel.is_cancelled() {
                    actions.discard_preview(&preview.preview_id);
                    return Err(Failure::RecoveryRequired);
                }
                if let Err(error) = self.journal.claim_interrupt(&token, &turn) {
                    actions.discard_preview(&preview.preview_id);
                    return Err(error);
                }
                let result = actions
                    .confirm_controlled(
                        &preview.preview_id,
                        &operation_id,
                        &preview.action_hash,
                        || self.capture(&scope, &turn),
                        &cancel,
                    )
                    .await;
                actions.discard_preview(&preview.preview_id);
                result
            };
            if !outcome.is_ok_and(|outcome| {
                outcome.state == "accepted" && outcome.turn_id.as_deref() == Some(&turn.turn_id)
            }) {
                let _ = self.journal.record_pause_unknown(&token, &turn);
                return Err(Failure::RecoveryRequired);
            }
            loop {
                if Instant::now() >= deadline || self.pause_current(&request, false).is_err() {
                    let _ = self.journal.record_pause_unknown(&token, &turn);
                    return Err(Failure::RecoveryRequired);
                }
                let outcome = {
                    let mut actions = self.state.owner_actions.lock().await;
                    let actions = actions.as_mut().ok_or(Failure::Unavailable)?;
                    actions
                        .poll(&operation_id, || self.capture(&scope, &turn))
                        .await
                };
                match outcome {
                    Ok(status)
                        if status.state == "interrupted"
                            && status.turn_id.as_deref() == Some(&turn.turn_id) =>
                    {
                        self.journal.record_interrupted(
                            &token,
                            &ExactTurnTerminalSnapshot::new(
                                turn.clone(),
                                TerminalTurnStatus::Interrupted,
                            )?,
                        )?;
                        break;
                    }
                    Ok(status) if status.state == "accepted" => {
                        tokio::time::sleep(Duration::from_millis(250)).await
                    }
                    _ => {
                        let _ = self.journal.record_pause_unknown(&token, &turn);
                        return Err(Failure::RecoveryRequired);
                    }
                }
            }
        }
        loop {
            let current = self.pause_current(&request, false)?;
            if current.matches_pause_roster(&request.snapshot, true) {
                break;
            }
            if Instant::now() >= deadline {
                return Err(Failure::RecoveryRequired);
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        Ok(Some(QuotaPauseReceipt {
            batch_id: token.batch_id(),
        }))
    }
    fn resume(&self, batch_id: &str) -> Result<QuotaResumeStateDto> {
        let _operation = self
            .operation
            .try_lock()
            .map_err(|_| Failure::AccountBusy)?;
        let batch = self.batch(batch_id)?;
        if !batch.ready() || batch.abandoned() {
            return Err(Failure::RecoveryRequired);
        }
        let active = self
            .accounts
            .verified_active_system_scope()
            .map_err(|_| Failure::IdentityChanged)?;
        let scope = self.selected_scope(&active)?;
        if identity(&active)? != *batch.scope().target() || scope != batch.scope().home_scope_hash()
        {
            return Err(Failure::IdentityChanged);
        }
        let epoch = self.epoch.load(Ordering::Acquire);
        tauri::async_runtime::block_on(self.resume_async(batch, active, scope, epoch))?;
        self.state_dto()
    }
    async fn resume_async(
        &self,
        batch: ResumeBatchSnapshot,
        active: ActiveSystemScope,
        scope: String,
        epoch: u64,
    ) -> Result<()> {
        for entry in batch
            .entries()
            .iter()
            .filter(|entry| entry.state() == QuotaResumeEntryState::Interrupted)
        {
            if self.exiting.load(Ordering::Acquire) || self.epoch.load(Ordering::Acquire) != epoch {
                return Err(Failure::Cancelled);
            }
            let turn = entry.turn();
            let (context, guard) = capture_owner_context_with_guard(
                self.state.clone(),
                self.accounts.clone(),
                self.gate.clone(),
                scope.clone(),
                turn.thread_id.clone(),
            )
            .await
            .map_err(|_| Failure::TaskUnknown)?;
            let state = self.state.clone();
            let accounts = self.accounts.clone();
            let exiting = self.exiting.clone();
            let current_epoch = self.epoch.clone();
            let admission_context = context.clone();
            let active_check = active.clone();
            let cancel = Cancellation::while_allowed(Arc::new(move || {
                !exiting.load(Ordering::Acquire)
                    && current_epoch.load(Ordering::Acquire) == epoch
                    && accounts.recheck_active_system_scope(&active_check).is_ok()
                    && state.config.try_read().is_ok_and(|config| {
                        admission_context.recheck_admission(&accounts, &config.codex_root)
                    })
            }));
            let id = operation_id(&batch.batch_id(), turn, "resume");
            let outcome = {
                let mut actions = self.state.owner_actions.lock().await;
                let actions = actions.as_mut().ok_or(Failure::Unavailable)?;
                let preview = match actions
                    .prepare_resume(context, &turn.turn_id, guard.into())
                    .await
                {
                    Ok(preview) => preview,
                    Err(error) if error == "owner_resume_changed" => {
                        self.journal.record_resume_skipped(&batch.token(), turn)?;
                        continue;
                    }
                    Err(_) => return Err(Failure::TaskUnknown),
                };
                if cancel.is_cancelled() {
                    actions.discard_preview(&preview.preview_id);
                    return Err(Failure::Cancelled);
                }
                if let Err(error) = self.journal.claim_resume(&batch.token(), turn) {
                    actions.discard_preview(&preview.preview_id);
                    return Err(error);
                }
                let result = actions
                    .confirm_controlled(
                        &preview.preview_id,
                        &id,
                        &preview.action_hash,
                        || self.capture(&scope, turn),
                        &cancel,
                    )
                    .await;
                actions.discard_preview(&preview.preview_id);
                result
            };
            match outcome {
                Ok(status) if status.state == "accepted" => {
                    let new_turn = status.turn_id.ok_or(Failure::RecoveryRequired)?;
                    self.reconcile(scope.clone(), turn.clone(), id);
                    self.journal
                        .record_submitted(&batch.token(), turn, &new_turn)?;
                }
                _ => {
                    let _ = self.journal.record_resume_unknown(&batch.token(), turn);
                    return Err(Failure::RecoveryRequired);
                }
            }
        }
        Ok(())
    }
    /// Passive exact-turn reconciliation only; never resumes or repeats work.
    fn reconcile(&self, scope: String, turn: TurnRef, id: String) {
        let adapter = self.clone();
        tauri::async_runtime::spawn(async move {
            while !adapter.exiting.load(Ordering::Acquire) {
                tokio::time::sleep(Duration::from_secs(2)).await;
                let outcome = {
                    let mut actions = adapter.state.owner_actions.lock().await;
                    let Some(actions) = actions.as_mut() else {
                        return;
                    };
                    actions.poll(&id, || adapter.capture(&scope, &turn)).await
                };
                if !outcome.is_ok_and(|status| status.state == "accepted") {
                    return;
                }
            }
        });
    }
    fn batch(&self, batch_id: &str) -> Result<ResumeBatchSnapshot> {
        self.journal
            .current_batch()?
            .filter(|batch| batch.batch_id() == batch_id)
            .ok_or(Failure::RecoveryRequired)
    }
    fn clear(&self, batch_id: &str) -> Result<QuotaResumeStateDto> {
        let _operation = self
            .operation
            .try_lock()
            .map_err(|_| Failure::AccountBusy)?;
        let batch = self.batch(batch_id)?;
        self.journal.abandon(&batch.token())?;
        self.state_dto()
    }
    fn state_dto(&self) -> Result<QuotaResumeStateDto> {
        let Some(batch) = self.journal.current_batch()? else {
            return Ok(QuotaResumeStateDto::empty());
        };
        let pending = batch
            .entries()
            .iter()
            .filter(|entry| entry.state() == QuotaResumeEntryState::Interrupted)
            .count();
        let uncertain = batch
            .entries()
            .iter()
            .filter(|entry| {
                matches!(
                    entry.state(),
                    QuotaResumeEntryState::InterruptAttempted
                        | QuotaResumeEntryState::PauseUnknown
                        | QuotaResumeEntryState::ResumeAttempted
                        | QuotaResumeEntryState::ResumeUnknown
                )
            })
            .count();
        let unresolved = self.journal.has_unresolved();
        Ok(QuotaResumeStateDto {
            batch_id: Some(batch.batch_id()),
            phase: if batch.abandoned() {
                "abandoned"
            } else if !unresolved {
                "submitted"
            } else if batch.ready() {
                "ready"
            } else {
                "recovery"
            },
            pending_count: pending,
            uncertain_count: uncertain,
            can_resume: batch.ready() && !batch.abandoned() && pending > 0 && uncertain == 0,
            can_clear: unresolved,
            busy: self.has_inflight_operation(),
        })
    }
}
impl QuotaPauseController for QuotaResumeAdapter {
    fn has_unresolved(&self) -> Result<bool> {
        Ok(self.journal.has_unresolved())
    }
    fn pause(&self, request: QuotaPauseRequest) -> Result<Option<QuotaPauseReceipt>> {
        let _operation = self
            .operation
            .try_lock()
            .map_err(|_| Failure::AccountBusy)?;
        let scope = self.selected_scope(&request.source)?;
        tauri::async_runtime::block_on(self.pause_async(request, scope))
    }
    fn switch_verified(
        &self,
        receipt: &QuotaPauseReceipt,
        target: &ActiveSystemScope,
        lease: &codexu_core::managed_proxy::AutomaticMaintenanceLease,
    ) -> Result<()> {
        let batch = self.batch(&receipt.batch_id)?;
        let scope = self.selected_scope(target)?;
        self.journal
            .mark_resume_ready_after_guarded_switch(&batch.token(), target, lease, &scope)
    }
}
fn identity(scope: &ActiveSystemScope) -> Result<AccountIdentity> {
    AccountIdentity::new(
        scope.profile_id(),
        scope.identity_hash(),
        scope.credential_generation(),
    )
}
fn operation_id(batch: &str, turn: &TurnRef, action: &str) -> String {
    let bytes = Sha256::digest(format!(
        "quota-resume-v1\0{batch}\0{}\0{}\0{action}",
        turn.thread_id, turn.turn_id
    ));
    let hex = format!("{:x}", bytes);
    format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaResumeStateDto {
    batch_id: Option<String>,
    phase: &'static str,
    pending_count: usize,
    uncertain_count: usize,
    can_resume: bool,
    can_clear: bool,
    busy: bool,
}
impl QuotaResumeStateDto {
    fn empty() -> Self {
        Self {
            batch_id: None,
            phase: "empty",
            pending_count: 0,
            uncertain_count: 0,
            can_resume: false,
            can_clear: false,
            busy: false,
        }
    }
}
pub(crate) struct QuotaResumeState(pub std::result::Result<Arc<QuotaResumeAdapter>, &'static str>);
async fn run(
    state: &QuotaResumeState,
    action: impl FnOnce(Arc<QuotaResumeAdapter>) -> Result<QuotaResumeStateDto> + Send + 'static,
) -> std::result::Result<QuotaResumeStateDto, String> {
    let service = state.0.clone().map_err(str::to_owned)?;
    tauri::async_runtime::spawn_blocking(move || action(service))
        .await
        .map_err(|_| "automatic_switch_unavailable".to_owned())?
        .map_err(|error| error.code().to_owned())
}
#[tauri::command]
pub async fn get_quota_resume_state(
    state: State<'_, QuotaResumeState>,
) -> std::result::Result<QuotaResumeStateDto, String> {
    run(&state, |service| service.state_dto()).await
}
#[tauri::command]
pub async fn resume_quota_tasks(
    app: AppHandle,
    state: State<'_, QuotaResumeState>,
    batch_id: String,
) -> std::result::Result<QuotaResumeStateDto, String> {
    let result = run(&state, move |service| service.resume(&batch_id)).await;
    let _ = app.emit("automatic-switch:changed", ());
    result
}
#[tauri::command]
pub async fn clear_quota_resume(
    app: AppHandle,
    state: State<'_, QuotaResumeState>,
    batch_id: String,
) -> std::result::Result<QuotaResumeStateDto, String> {
    let result = run(&state, move |service| service.clear(&batch_id)).await;
    let _ = app.emit("automatic-switch:changed", ());
    result
}
#[tauri::command]
pub async fn cancel_quota_resume(
    state: State<'_, QuotaResumeState>,
) -> std::result::Result<QuotaResumeStateDto, String> {
    if let Ok(service) = &state.0 {
        service.epoch.fetch_add(1, Ordering::AcqRel);
    }
    run(&state, |service| service.state_dto()).await
}
