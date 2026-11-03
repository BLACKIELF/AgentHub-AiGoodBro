//! Explicit personal-WeChat text, separate from automatic notification events.
//! The journal contains hashes only; drafts and remote credentials never persist
//! as message records. Replays cannot resend an uncertain submission.
use super::*;
use serde::Serialize;
use serde_json::json;

const FOOTER: &str = "\n\naigoodbro.com";
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PersonalTextReceipt {
    pub request_id: String,
    pub revision: u64,
    pub state: &'static str,
    pub checked_at: i64,
    pub failure_code: Option<&'static str>,
}
struct Active<'a>(&'a AtomicBool);
impl Drop for Active<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}
fn content(text: &str) -> Result<String> {
    if text.trim().is_empty()
        || text
            .chars()
            .any(|c| c < ' ' && !matches!(c, '\n' | '\r' | '\t'))
    {
        return fail("invalid_message_text");
    }
    if text.len() > 4096 - FOOTER.len() {
        return fail("message_too_long");
    }
    Ok(format!("{text}{FOOTER}"))
}
impl NotificationService {
    pub fn send_personal_wechat_text(
        self: &Arc<Self>,
        request_id: &str,
        expected_revision: u64,
        text: &str,
        confirmed: bool,
    ) -> Result<PersonalTextReceipt> {
        if !confirmed {
            return fail("confirmation_required");
        }
        if request_id.len() != 32
            || !request_id
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return fail("invalid_request_id");
        }
        let text = content(text)?;
        let kind = ChannelKind::PersonalWeChat;
        let (op, c) = self.operation(kind)?;
        if c.revision != expected_revision {
            return fail("configuration_changed");
        }
        {
            let state = self
                .state
                .lock()
                .map_err(|_| Failure("notification_busy"))?;
            if state.login.as_ref().is_some_and(|a| {
                a.expires_at > super::super::now()
                    && matches!(
                        a.phase,
                        "starting" | "waiting" | "scanned" | "verification_required"
                    )
            }) {
                return fail("wechat_login_in_progress");
            }
            // Pairing admission checks this flag under the same state mutex.
            if self.personal_text_active.swap(true, Ordering::AcqRel) {
                return fail("notification_busy");
            }
        }
        let _active = Active(&self.personal_text_active);
        if c.session_expired {
            return fail("wechat_session_expired");
        }
        let secret = c.secret.as_deref().ok_or(Failure("missing_credential"))?;
        protocol::validate_credential(kind, secret, c.target.as_deref(), c.binding.as_ref())?;
        let binding = c
            .binding
            .as_ref()
            .ok_or(Failure("wechat_binding_required"))?;
        let context = binding
            .context_token
            .as_deref()
            .ok_or(Failure("wechat_context_required"))?;
        if binding
            .context_checked_at
            .is_none_or(|at| at > super::super::now() + 60)
        {
            return fail("wechat_context_required");
        }
        let request = protocol::ilink_request(
            &binding.base_url,
            "sendmessage",
            Some(secret),
            json!({"msg":{"from_user_id":"","to_user_id":binding.user_id,"client_id":format!("aigoodbro-{request_id}"),"message_type":2,"message_state":2,"context_token":context,"item_list":[{"type":1,"text_item":{"text":text}}]}}),
            false,
        )?;
        let keys = vec![
            super::super::hash(format!("personal-text-request\0{request_id}").as_bytes()),
            super::super::hash(
                format!("personal-text-body\0{request_id}\0{}\0{text}", c.revision).as_bytes(),
            ),
        ];
        op.current()?;
        let previous = self.storage.change(|v| {
            if v.configs
                .get(&kind)
                .is_none_or(|current| !current.enabled || current.revision != c.revision)
            {
                return fail("configuration_changed");
            }
            if let Some(old) = v.deliveries.get(&keys[0]) {
                let body = v
                    .deliveries
                    .get(&keys[1])
                    .ok_or(Failure("request_id_reused"))?;
                if old.revision != c.revision
                    || old.phase != body.phase
                    || old.attempt != body.attempt
                {
                    return fail("request_id_reused");
                }
                return Ok(Some(old.phase.clone()));
            }
            if v.deliveries.len() + 2 > 16384 {
                return fail("notification_store_capacity");
            }
            for key in &keys {
                v.deliveries.insert(
                    key.clone(),
                    Delivery {
                        phase: Phase::Sending,
                        attempt: op.id.clone(),
                        revision: c.revision,
                        at: super::super::now(),
                    },
                );
            }
            Ok(None)
        })?;
        if let Some(phase) = previous {
            return Ok(PersonalTextReceipt {
                request_id: request_id.into(),
                revision: c.revision,
                state: match phase {
                    Phase::Sent => "accepted",
                    Phase::Pending => "not_sent",
                    Phase::Sending | Phase::Uncertain => "uncertain",
                },
                checked_at: super::super::now(),
                failure_code: None,
            });
        }
        // Reservation is durable before the sole send. A crash or lost response
        // stays Sending/Uncertain and is never an automatic retry candidate.
        if let Err(error) = op.current() {
            self.finish(&keys, &op, Phase::Pending, None)?;
            return Err(error);
        }
        let parsed = match self.transport.send(&request, &op.cancelled) {
            Ok(response) => protocol::parse_response(kind, response),
            Err(error) => Accepted::Uncertain(error),
        };
        let parsed = if op.current().is_err() {
            Accepted::Uncertain(Failure("cancelled"))
        } else {
            parsed
        };
        let (phase, mut state, mut error) = match parsed {
            Accepted::Ok(_) => (Phase::Sent, "accepted", None),
            Accepted::Rejected(e) => (Phase::Pending, "rejected", Some(e.0)),
            Accepted::Uncertain(e) => (Phase::Uncertain, "uncertain", Some(e.0)),
        };
        if self.finish(&keys, &op, phase, None)? == Phase::Uncertain && state == "accepted" {
            state = "uncertain";
            error = Some("cancelled");
        }
        if error == Some("wechat_session_expired") {
            self.expire_personal_session(c.revision)?;
        }
        {
            let mut runtime = self
                .state
                .lock()
                .map_err(|_| Failure("notification_busy"))?;
            if op.current().is_ok() {
                if state == "accepted" {
                    runtime
                        .verified
                        .insert(kind, (c.revision, super::super::now()));
                    runtime.failures.remove(&kind);
                } else if let Some(code) = error {
                    runtime.verified.remove(&kind);
                    runtime.failures.insert(kind, code);
                }
            }
        }
        Ok(PersonalTextReceipt {
            request_id: request_id.into(),
            revision: c.revision,
            state,
            checked_at: super::super::now(),
            failure_code: error,
        })
    }
}

#[cfg(test)]
#[path = "manual_text_tests.rs"]
mod tests;
