//! Native original-chat adapter for explicitly enabled personal-WeChat replies.
//! It never creates a chat, launches a CLI, changes an account or retries input.
use super::{
    desktop_owner_actions::{NativeOwnerContext, OwnerAction, OwnerReplyPoll},
    task_workbench::{capture_owner_context, capture_owner_context_with_guard},
};
use crate::app_state::AppState;
use codexu_core::{
    accounts::AccountManager,
    desktop_owner::Cancellation,
    managed_proxy::ManagedProxyGate,
    notifications::{
        PersonalConversationOwner, PersonalConversationTarget, PersonalReplyContinue,
        PersonalReplyOutcome, PersonalReplySubmitted,
    },
};
use std::{future::Future, pin::Pin, sync::Arc, time::Duration};

const REPLY_WAIT: Duration = Duration::from_secs(120);
const POLL_INTERVAL: Duration = Duration::from_secs(2);

#[derive(Clone)]
pub(crate) struct PersonalConversationOwnerAdapter {
    state: Arc<AppState>,
    accounts: Arc<AccountManager>,
    gate: Arc<ManagedProxyGate>,
}

impl PersonalConversationOwnerAdapter {
    pub(crate) fn new(
        state: Arc<AppState>,
        accounts: Arc<AccountManager>,
        gate: Arc<ManagedProxyGate>,
    ) -> Self {
        Self {
            state,
            accounts,
            gate,
        }
    }

    fn admission(
        &self,
        context: NativeOwnerContext,
        allowed: PersonalReplyContinue,
    ) -> Cancellation {
        let state = self.state.clone();
        let accounts = self.accounts.clone();
        Cancellation::while_allowed(Arc::new(move || {
            allowed()
                && state
                    .config
                    .try_read()
                    .is_ok_and(|config| context.recheck_admission(&accounts, &config.codex_root))
        }))
    }

    async fn capture(
        &self,
        target: &PersonalConversationTarget,
    ) -> Result<NativeOwnerContext, String> {
        capture_owner_context(
            self.state.clone(),
            self.accounts.clone(),
            target.expected_scope_id.clone(),
            target.thread_id.clone(),
        )
        .await
    }

    /// After a known ACK, cancellation means no reply and no further input.
    /// A bounded passive reconciliation can release the existing guard only
    /// after exact terminal proof; an uncertain result keeps it retained.
    fn reconcile(&self, target: PersonalConversationTarget, event_id: String) {
        let adapter = self.clone();
        tauri::async_runtime::spawn(async move {
            let deadline = tokio::time::Instant::now() + REPLY_WAIT;
            while tokio::time::Instant::now() < deadline {
                tokio::time::sleep(POLL_INTERVAL).await;
                let outcome = {
                    let mut actions = adapter.state.owner_actions.lock().await;
                    let Some(actions) = actions.as_mut() else {
                        return;
                    };
                    actions.poll(&event_id, || adapter.capture(&target)).await
                };
                match outcome {
                    Ok(status) if status.state == "accepted" => {}
                    _ => return,
                }
            }
        });
    }

    async fn reply_once(
        &self,
        target: &PersonalConversationTarget,
        event_id: &str,
        text: &str,
        on_submitted: PersonalReplySubmitted,
        allowed: PersonalReplyContinue,
    ) -> PersonalReplyOutcome {
        if !allowed() {
            return PersonalReplyOutcome::Cancelled;
        }
        let (context, guard) = match capture_owner_context_with_guard(
            self.state.clone(),
            self.accounts.clone(),
            self.gate.clone(),
            target.expected_scope_id.clone(),
            target.thread_id.clone(),
        )
        .await
        {
            Ok(value) => value,
            Err(error) => return before_submit_error(&error),
        };
        let cancel = self.admission(context.clone(), allowed.clone());
        let status = {
            let mut actions = self.state.owner_actions.lock().await;
            let Some(actions) = actions.as_mut() else {
                return PersonalReplyOutcome::Unavailable;
            };
            if cancel.is_cancelled() {
                return PersonalReplyOutcome::Cancelled;
            }
            // The service's durable event claim and this owner journal both
            // prohibit replay, including a previous NotSent receipt.
            match actions.status(event_id) {
                Ok(None) => {}
                Ok(Some(_)) => return PersonalReplyOutcome::Uncertain,
                Err(_) => return PersonalReplyOutcome::Unavailable,
            }
            let preview = match actions
                .prepare(context, OwnerAction::StartText(text.into()), guard.into())
                .await
            {
                Ok(preview) => preview,
                Err(error) => return before_submit_error(&error),
            };
            actions
                .confirm_controlled(
                    &preview.preview_id,
                    event_id,
                    &preview.action_hash,
                    || self.capture(target),
                    &cancel,
                )
                .await
        };
        let turn_id = match status {
            Ok(status) if status.state == "accepted" => match status.turn_id {
                Some(id) => id,
                None => return PersonalReplyOutcome::Uncertain,
            },
            Ok(status) if status.state == "notSent" => return PersonalReplyOutcome::Unavailable,
            Ok(_) => return PersonalReplyOutcome::Uncertain,
            Err(error) => return before_submit_error(&error),
        };
        // Persist the exact ACK before any snapshot polling or reply delivery.
        if !on_submitted(&turn_id) {
            self.reconcile(target.clone(), event_id.into());
            return PersonalReplyOutcome::Uncertain;
        }
        let deadline = tokio::time::Instant::now() + REPLY_WAIT;
        loop {
            if !allowed() {
                self.reconcile(target.clone(), event_id.into());
                return PersonalReplyOutcome::Cancelled;
            }
            if tokio::time::Instant::now() >= deadline {
                self.reconcile(target.clone(), event_id.into());
                return PersonalReplyOutcome::TimedOut;
            }
            let outcome = {
                let mut actions = self.state.owner_actions.lock().await;
                let Some(actions) = actions.as_mut() else {
                    return PersonalReplyOutcome::Uncertain;
                };
                actions.poll_reply(event_id, || self.capture(target)).await
            };
            if !allowed() {
                self.reconcile(target.clone(), event_id.into());
                return PersonalReplyOutcome::Cancelled;
            }
            match outcome {
                Ok(OwnerReplyPoll::Reply {
                    turn_id: returned,
                    text,
                }) if returned == turn_id => {
                    return PersonalReplyOutcome::Reply { turn_id, text };
                }
                Ok(OwnerReplyPoll::Pending) => {}
                Ok(OwnerReplyPoll::Failed) => return PersonalReplyOutcome::Failed,
                Ok(OwnerReplyPoll::Interrupted) => return PersonalReplyOutcome::Interrupted,
                Ok(OwnerReplyPoll::Unavailable) => return PersonalReplyOutcome::Unavailable,
                Ok(OwnerReplyPoll::AwaitingHuman) => {
                    self.reconcile(target.clone(), event_id.into());
                    return PersonalReplyOutcome::AwaitingHuman;
                }
                _ => {
                    self.reconcile(target.clone(), event_id.into());
                    return PersonalReplyOutcome::Uncertain;
                }
            }
            // Never retain the shared OwnerActions mutex during a polling wait.
            tokio::time::sleep(POLL_INTERVAL).await;
        }
    }
}

fn before_submit_error(error: &str) -> PersonalReplyOutcome {
    match error {
        "owner_cancelled" => PersonalReplyOutcome::Cancelled,
        "owner_busy" | "owner_not_admissible" => PersonalReplyOutcome::Busy,
        "owner_awaiting_human" => PersonalReplyOutcome::AwaitingHuman,
        _ => PersonalReplyOutcome::Unavailable,
    }
}

impl PersonalConversationOwner for PersonalConversationOwnerAdapter {
    fn validate_target<'a>(
        &'a self,
        target: &'a PersonalConversationTarget,
        allowed: PersonalReplyContinue,
    ) -> Pin<Box<dyn Future<Output = Result<(), PersonalReplyOutcome>> + Send + 'a>> {
        Box::pin(async move {
            if !allowed() {
                return Err(PersonalReplyOutcome::Cancelled);
            }
            let (context, _guard) = capture_owner_context_with_guard(
                self.state.clone(),
                self.accounts.clone(),
                self.gate.clone(),
                target.expected_scope_id.clone(),
                target.thread_id.clone(),
            )
            .await
            .map_err(|error| before_submit_error(&error))?;
            let cancel = self.admission(context.clone(), allowed);
            let mut actions = self.state.owner_actions.lock().await;
            let actions = actions.as_mut().ok_or(PersonalReplyOutcome::Unavailable)?;
            if cancel.is_cancelled() {
                return Err(PersonalReplyOutcome::Cancelled);
            }
            actions
                .validate_idle_target(&context)
                .await
                .map_err(|error| before_submit_error(&error))?;
            if cancel.is_cancelled() {
                return Err(PersonalReplyOutcome::Cancelled);
            }
            Ok(())
        })
    }

    fn reply<'a>(
        &'a self,
        target: &'a PersonalConversationTarget,
        event_id: &'a str,
        text: &'a str,
        on_submitted: PersonalReplySubmitted,
        allowed: PersonalReplyContinue,
    ) -> Pin<Box<dyn Future<Output = PersonalReplyOutcome> + Send + 'a>> {
        Box::pin(self.reply_once(target, event_id, text, on_submitted, allowed))
    }
}
