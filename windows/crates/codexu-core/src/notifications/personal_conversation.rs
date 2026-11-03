//! Selected original Codex conversation for the paired personal-WeChat bot.
//! Message bodies and context tokens remain in memory; the encrypted journal
//! stores only deterministic event IDs and delivery state.
use super::{
    domain::*, fail, hash, protocol, protocol::Accepted, service::NotificationService, storage::*,
    transport::TransportRequest, Failure, Result,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    future::Future,
    pin::Pin,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{SystemTime, UNIX_EPOCH},
};

const MAX_EVENTS: usize = 512;
const MAX_TEXT_BYTES: usize = 4096;
const MAX_ITEMS: usize = 8;
const MAX_BATCH: usize = 256;
const MAX_CONCURRENT: usize = 8;
const MAX_EVENT_AGE_MS: i64 = 120_000;
const MAX_FUTURE_SKEW_MS: i64 = 5_000;
const JOURNAL_RETENTION_MS: i64 = 7 * 24 * 60 * 60 * 1000;
const ACCEPTED_RETENTION_MS: i64 = 125_000;

pub(crate) type PersonalReplyFuture<'a> =
    Pin<Box<dyn Future<Output = PersonalReplyOutcome> + Send + 'a>>;
pub type PersonalReplyContinue = Arc<dyn Fn() -> bool + Send + Sync>;
pub type PersonalReplySubmitted = Arc<dyn Fn(&str) -> bool + Send + Sync>;

#[derive(Clone, PartialEq, Eq)]
pub struct PersonalConversationTarget {
    /// A TaskWorkbench scope selector. Native owner validation is authoritative.
    pub expected_scope_id: String,
    /// The user-selected local Codex thread. It is not an account credential.
    pub thread_id: String,
}

#[derive(PartialEq, Eq)]
pub enum PersonalReplyOutcome {
    Reply { turn_id: String, text: String },
    Busy,
    AwaitingHuman,
    Unavailable,
    Failed,
    Interrupted,
    TimedOut,
    Uncertain,
    Cancelled,
}

/// Owner boundary injected by the Tauri adapter before the application monitor
/// starts. The adapter must recapture and validate the native owner every time.
pub trait PersonalConversationOwner: Send + Sync {
    fn validate_target<'a>(
        &'a self,
        target: &'a PersonalConversationTarget,
        should_continue: PersonalReplyContinue,
    ) -> Pin<Box<dyn Future<Output = std::result::Result<(), PersonalReplyOutcome>> + Send + 'a>>;

    fn reply<'a>(
        &'a self,
        target: &'a PersonalConversationTarget,
        event_id: &'a str,
        text: &'a str,
        on_submitted: PersonalReplySubmitted,
        should_continue: PersonalReplyContinue,
    ) -> PersonalReplyFuture<'a>;
}

/// Safe UI projection. Never includes an incoming body, context token, or
/// credential fingerprint.
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PersonalConversationBindingDto {
    pub expected_scope_id: String,
    pub thread_id: String,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PersonalWeChatConversationState {
    pub binding: Option<PersonalConversationBindingDto>,
    pub revision: u64,
    pub enabled: bool,
    pub phase: &'static str,
    pub needs_confirmation: bool,
}

/// An inbound event is deliberately neither serializable nor Debug: it carries
/// the only in-memory copies of the message body and event-specific context.
pub(crate) struct PersonalWeChatConversationEvent {
    pub id: String,
    pub text: String,
    pub context_token: String,
    pub revision: u64,
}

pub(crate) struct PersonalWeChatUpdates {
    pub binding: PersonalBinding,
    pub events: Vec<(String, String, String, i64)>, // id, text, context, received_at_ms
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PersonalConversationBinding {
    pub enabled: bool,
    pub expected_scope_id: String,
    pub thread_id: String,
    pub credential_fingerprint: String,
    pub not_before_ms: i64,
}

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum PersonalConversationPhase {
    Received,
    Submitted,
    ReplyAttempted,
    Accepted,
    Uncertain,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PersonalConversationEntry {
    pub event_id: String,
    pub received_at_ms: i64,
    pub phase: PersonalConversationPhase,
    pub thread_id: Option<String>,
    pub turn_id: Option<String>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PersonalConversationJournal {
    pub binding: Option<PersonalConversationBinding>,
    pub entries: Vec<PersonalConversationEntry>,
    pub rejected_through_ms: Option<i64>,
}

impl Default for PersonalConversationJournal {
    fn default() -> Self {
        Self {
            binding: None,
            entries: Vec::new(),
            rejected_through_ms: None,
        }
    }
}

impl PersonalConversationJournal {
    pub(crate) fn valid(&self) -> bool {
        self.binding.as_ref().is_none_or(|binding| {
            valid_scope(&binding.expected_scope_id)
                && valid_uuid(&binding.thread_id)
                && super::valid_hash(&binding.credential_fingerprint)
                && binding.not_before_ms > 0
        }) && self.entries.len() <= MAX_EVENTS
            && self.rejected_through_ms.is_none_or(|at| at > 0)
            && self.entries.iter().all(|entry| {
                valid_uuid(&entry.event_id)
                    && entry.received_at_ms > 0
                    && entry
                        .thread_id
                        .as_ref()
                        .is_none_or(|value| valid_uuid(value))
                    && entry.turn_id.as_ref().is_none_or(|value| valid_uuid(value))
                    && (entry.phase != PersonalConversationPhase::Submitted
                        || entry.thread_id.is_some() && entry.turn_id.is_some())
            })
            && self
                .entries
                .iter()
                .map(|entry| entry.event_id.as_str())
                .collect::<std::collections::BTreeSet<_>>()
                .len()
                == self.entries.len()
    }
}

pub(crate) fn valid_scope(value: &str) -> bool {
    super::valid_hash(value)
}

fn valid_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if [8, 13, 18, 23].contains(&index) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

fn valid_final_answer(value: &str) -> bool {
    !value.trim().is_empty()
        && value.len() <= MAX_TEXT_BYTES
        && !value
            .chars()
            .any(|character| character < ' ' && !matches!(character, '\n' | '\r' | '\t'))
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|duration| i64::try_from(duration.as_millis()).ok())
        .unwrap_or(0)
}

fn credential_fingerprint(config: &ChannelConfig) -> Option<String> {
    let binding = config.binding.as_ref()?;
    let secret = config.secret.as_deref()?;
    let target = config.target.as_deref()?;
    if target != binding.user_id {
        return None;
    }
    let fields = [
        "personal-wechat-conversation-v1",
        binding.base_url.as_str(),
        binding.bot_id.as_str(),
        binding.user_id.as_str(),
        secret,
    ];
    serde_json::to_vec(&fields).ok().map(|bytes| hash(&bytes))
}

fn event_id(owner: &str, message_id: &str) -> String {
    let digest = Sha256::digest(format!("AiGoodBro-WeChat-v1\0{owner}\0{message_id}").as_bytes());
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    )
}

fn message_id(value: &Value) -> Option<String> {
    if let Some(value) = value.as_str() {
        return (!value.is_empty() && value.len() <= 256 && !value.chars().any(char::is_control))
            .then(|| value.to_owned());
    }
    value
        .as_u64()
        .filter(|value| *value > 0)
        .map(|value| value.to_string())
}

fn incoming_updates(value: &Value, config: &ChannelConfig) -> Result<PersonalWeChatUpdates> {
    let target = config
        .target
        .as_deref()
        .ok_or(Failure("wechat_binding_required"))?;
    let binding = config
        .binding
        .as_ref()
        .ok_or(Failure("wechat_binding_required"))?;
    if value.get("msgs").is_some_and(|value| !value.is_array())
        || value
            .get("get_updates_buf")
            .is_some_and(|value| !value.is_string())
    {
        return fail("invalid_response");
    }
    let messages = value["msgs"].as_array().map(Vec::as_slice).unwrap_or(&[]);
    if messages.len() > MAX_BATCH {
        return fail("invalid_response");
    }
    let now = now_ms();
    let mut latest_context = binding.context_token.clone();
    let mut latest_context_at = binding
        .context_checked_at
        .map(|time| time.saturating_mul(1000));
    let mut events = Vec::new();
    for message in messages {
        if message["message_type"].as_i64() != Some(1)
            || message["from_user_id"].as_str() != Some(target)
            || message["to_user_id"].as_str() != Some(binding.bot_id.as_str())
        {
            continue;
        }
        let Some(context_token) = message["context_token"]
            .as_str()
            .filter(|value| super::protocol::valid_token(value, 8192))
        else {
            continue;
        };
        let Some(received_at_ms) = message["create_time_ms"]
            .as_i64()
            .filter(|value| *value > 0)
        else {
            continue;
        };
        if received_at_ms > now + 60_000
            || latest_context_at.is_some_and(|previous| received_at_ms < previous)
        {
            continue;
        }
        latest_context = Some(context_token.to_owned());
        latest_context_at = Some(received_at_ms);

        let age = now.saturating_sub(received_at_ms);
        if !(-MAX_FUTURE_SKEW_MS..=MAX_EVENT_AGE_MS).contains(&age)
            || message["message_state"].as_i64() != Some(2)
        {
            continue;
        }
        let Some(id) = message_id(&message["message_id"]) else {
            continue;
        };
        let Some(items) = message["item_list"].as_array().filter(|items| {
            !items.is_empty()
                && items.len() <= MAX_ITEMS
                && items.iter().all(|item| item["type"].as_i64() == Some(1))
        }) else {
            continue;
        };
        let parts: Vec<&str> = items
            .iter()
            .filter_map(|item| item["text_item"]["text"].as_str())
            .collect();
        let text = parts.join("\n").replace("\r\n", "\n").trim().to_owned();
        if parts.len() != items.len()
            || text.is_empty()
            || text.len() > MAX_TEXT_BYTES
            || text
                .chars()
                .any(|character| character < ' ' && !matches!(character, '\n' | '\t'))
        {
            continue;
        }
        events.push((id, text, context_token.to_owned(), received_at_ms));
    }
    events.sort_by_key(|event| event.3);
    let cursor = value["get_updates_buf"]
        .as_str()
        .filter(|cursor| !cursor.is_empty())
        .map(str::to_owned)
        .unwrap_or_else(|| binding.cursor.clone());
    if !cursor.is_empty() {
        if !protocol::valid_token(&cursor, 8192) {
            return fail("invalid_response");
        }
    }
    Ok(PersonalWeChatUpdates {
        binding: PersonalBinding {
            base_url: binding.base_url.clone(),
            bot_id: binding.bot_id.clone(),
            user_id: binding.user_id.clone(),
            context_token: latest_context,
            context_checked_at: latest_context_at.map(|value| value / 1000),
            cursor,
        },
        events,
    })
}

fn response_object(response: super::transport::TransportResponse) -> Result<Value> {
    if (300..400).contains(&response.status) {
        return fail("redirected");
    }
    if response.status == 429 {
        return fail("rate_limited");
    }
    if !(200..300).contains(&response.status) || response.body.len() > 65_536 {
        return fail("invalid_response");
    }
    let value: Value =
        serde_json::from_slice(&response.body).map_err(|_| Failure("invalid_response"))?;
    protocol::ilink_response(&value, false)?;
    Ok(value)
}

fn updates_request(config: &ChannelConfig) -> Result<TransportRequest> {
    let secret = config
        .secret
        .as_deref()
        .ok_or(Failure("missing_credential"))?;
    let binding = config
        .binding
        .as_ref()
        .ok_or(Failure("wechat_binding_required"))?;
    protocol::ilink_request(
        &binding.base_url,
        "getupdates",
        Some(secret),
        json!({"get_updates_buf":binding.cursor}),
        false,
    )
}

impl NotificationService {
    pub(crate) fn personal_conversation_auto_enabled(&self) -> Result<bool> {
        self.storage.read(|vault| {
            let config = vault
                .configs
                .get(&ChannelKind::PersonalWeChat)
                .cloned()
                .unwrap_or_default();
            let binding = vault
                .personal_conversation
                .as_ref()
                .and_then(|journal| journal.binding.as_ref());
            let fingerprint = credential_fingerprint(&config);
            Ok(config.enabled
                && !config.session_expired
                && config.secret.is_some()
                && config.binding.is_some()
                && binding.is_some_and(|binding| {
                    binding.enabled
                        && fingerprint.as_deref() == Some(binding.credential_fingerprint.as_str())
                }))
        })
    }

    /// Installs the single app-lifetime owner adapter before the native monitor
    /// is started. Replacing it while a monitor is active would orphan replies.
    pub fn set_personal_conversation_owner(
        &self,
        owner: Arc<dyn PersonalConversationOwner>,
    ) -> Result<()> {
        if self.monitor_active.load(Ordering::Acquire) {
            return fail("notification_monitor_active");
        }
        let mut current = self
            .personal_conversation_owner
            .lock()
            .map_err(|_| Failure("notification_busy"))?;
        if current.is_some() {
            return fail("personal_conversation_owner_already_set");
        }
        *current = Some(owner);
        Ok(())
    }

    pub fn personal_conversation_state(&self) -> Result<PersonalWeChatConversationState> {
        self.storage.read(|vault| {
            let config = vault
                .configs
                .get(&ChannelKind::PersonalWeChat)
                .cloned()
                .unwrap_or_default();
            let binding = vault
                .personal_conversation
                .as_ref()
                .and_then(|journal| journal.binding.as_ref());
            let fingerprint = credential_fingerprint(&config);
            let needs_confirmation = binding.is_some_and(|binding| {
                fingerprint.as_deref() != Some(binding.credential_fingerprint.as_str())
            });
            let channel_available = config.enabled
                && !config.session_expired
                && config.secret.is_some()
                && config.binding.is_some();
            let enabled = channel_available
                && binding.is_some_and(|binding| binding.enabled)
                && !needs_confirmation;
            Ok(PersonalWeChatConversationState {
                binding: binding.map(|binding| PersonalConversationBindingDto {
                    expected_scope_id: binding.expected_scope_id.clone(),
                    thread_id: binding.thread_id.clone(),
                }),
                revision: config.revision,
                enabled,
                phase: if !channel_available {
                    "channel_unavailable"
                } else if binding.is_none() {
                    "unbound"
                } else if needs_confirmation {
                    "needs_confirmation"
                } else if binding.is_some_and(|binding| binding.enabled) {
                    "enabled"
                } else {
                    "disabled"
                },
                needs_confirmation,
            })
        })
    }

    pub async fn bind_personal_conversation(
        self: &Arc<Self>,
        expected_revision: u64,
        target: PersonalConversationTarget,
        confirmed: bool,
    ) -> Result<PersonalWeChatConversationState> {
        if !confirmed {
            return fail("confirmation_required");
        }
        if !valid_scope(&target.expected_scope_id) || !valid_uuid(&target.thread_id) {
            return fail("invalid_personal_conversation_target");
        }
        // A valid rebind fences the old target before the consent record is
        // changed. A stale request leaves the current target undisturbed.
        let (config, validation_revision) = self.storage.change(|vault| {
            let (config, validation_revision) = {
                let config = vault
                    .configs
                    .get_mut(&ChannelKind::PersonalWeChat)
                    .filter(|config| config.enabled && config.revision == expected_revision)
                    .ok_or(Failure("configuration_changed"))?;
                if config.secret.is_none() || config.binding.is_none() || config.session_expired {
                    return fail("wechat_binding_required");
                }
                let validation_revision = config
                    .revision
                    .checked_add(1)
                    .ok_or(Failure("notification_store_invalid"))?;
                self.revoke_personal_conversation_work();
                config.revision = validation_revision;
                (config.clone(), validation_revision)
            };
            if let Some(binding) = vault
                .personal_conversation
                .as_mut()
                .and_then(|journal| journal.binding.as_mut())
            {
                binding.enabled = false;
            }
            Ok((config, validation_revision))
        })?;
        let owner = self
            .personal_conversation_owner
            .lock()
            .map_err(|_| Failure("notification_busy"))?
            .clone()
            .ok_or(Failure("personal_conversation_owner_unavailable"))?;
        let generation = self
            .personal_conversation_generation
            .load(Ordering::Acquire);
        let weak = Arc::downgrade(self);
        let should_continue: PersonalReplyContinue = Arc::new(move || {
            weak.upgrade().is_some_and(|service| {
                service
                    .personal_conversation_generation
                    .load(Ordering::Acquire)
                    == generation
                    && !service.exiting.load(Ordering::Acquire)
            })
        });
        owner
            .validate_target(&target, should_continue.clone())
            .await
            .map_err(reply_failure)?;
        if !should_continue() {
            return fail("cancelled");
        }
        let fingerprint =
            credential_fingerprint(&config).ok_or(Failure("wechat_binding_required"))?;
        let now = now_ms();
        self.storage.change(|vault| {
            {
                let current = vault
                    .configs
                    .get_mut(&ChannelKind::PersonalWeChat)
                    .filter(|config| {
                        config.enabled
                            && !config.session_expired
                            && config.revision == validation_revision
                            && credential_fingerprint(config).as_deref()
                                == Some(fingerprint.as_str())
                    })
                    .ok_or(Failure("configuration_changed"))?;
                current.revision = current
                    .revision
                    .checked_add(1)
                    .ok_or(Failure("notification_store_invalid"))?;
            }
            let journal = vault
                .personal_conversation
                .get_or_insert_with(Default::default);
            journal.binding = Some(PersonalConversationBinding {
                enabled: true,
                expected_scope_id: target.expected_scope_id,
                thread_id: target.thread_id,
                credential_fingerprint: fingerprint,
                not_before_ms: now,
            });
            Ok(())
        })?;
        Ok(self.personal_conversation_state()?)
    }

    pub fn set_personal_conversation_enabled(
        &self,
        expected_revision: u64,
        enabled: bool,
    ) -> Result<PersonalWeChatConversationState> {
        if self.exiting.load(Ordering::Acquire) {
            return fail("notification_exiting");
        }
        if !enabled {
            // Stop admission before storage lock acquisition; the next check
            // at owner submission and WeChat send observes the new epoch.
            self.revoke_personal_conversation_work();
        }
        let now = now_ms();
        self.storage.change(|vault| {
            let fingerprint = {
                let config = vault
                    .configs
                    .get_mut(&ChannelKind::PersonalWeChat)
                    .filter(|config| config.enabled && config.revision == expected_revision)
                    .ok_or(Failure("configuration_changed"))?;
                let fingerprint =
                    credential_fingerprint(config).ok_or(Failure("wechat_binding_required"))?;
                config.revision = config
                    .revision
                    .checked_add(1)
                    .ok_or(Failure("notification_store_invalid"))?;
                fingerprint
            };
            let journal = vault
                .personal_conversation
                .as_mut()
                .ok_or(Failure("personal_conversation_unbound"))?;
            let binding = journal
                .binding
                .as_mut()
                .ok_or(Failure("personal_conversation_unbound"))?;
            if fingerprint != binding.credential_fingerprint {
                return fail("personal_conversation_confirmation_required");
            }
            binding.enabled = enabled;
            if enabled {
                binding.not_before_ms = now;
            }
            Ok(())
        })?;
        if enabled {
            self.revoke_personal_conversation_work();
        }
        self.personal_conversation_state()
    }

    pub fn unbind_personal_conversation(
        &self,
        expected_revision: u64,
    ) -> Result<PersonalWeChatConversationState> {
        if self.exiting.load(Ordering::Acquire) {
            return fail("notification_exiting");
        }
        self.revoke_personal_conversation_work();
        self.storage.change(|vault| {
            let config = vault
                .configs
                .get_mut(&ChannelKind::PersonalWeChat)
                .filter(|config| config.revision == expected_revision)
                .ok_or(Failure("configuration_changed"))?;
            config.revision = config
                .revision
                .checked_add(1)
                .ok_or(Failure("notification_store_invalid"))?;
            if let Some(journal) = vault.personal_conversation.as_mut() {
                journal.binding = None;
            }
            Ok(())
        })?;
        self.personal_conversation_state()
    }

    pub(crate) fn revoke_personal_conversation_work(&self) {
        self.personal_conversation_generation
            .fetch_add(1, Ordering::AcqRel);
        if let Ok(state) = self.state.try_lock() {
            if let Some(operations) = state.operations.get(&ChannelKind::PersonalWeChat) {
                for (cancelled, _) in operations {
                    cancelled.store(true, Ordering::Release);
                }
            }
        }
        self.wake.1.notify_all();
    }

    pub(crate) fn personal_conversation_owner(&self) -> Option<Arc<dyn PersonalConversationOwner>> {
        self.personal_conversation_owner
            .lock()
            .ok()
            .and_then(|owner| owner.clone())
    }

    pub(crate) async fn poll_personal_conversation_updates_owned(
        self: &Arc<Self>,
        stop: &Arc<AtomicBool>,
        active: &Arc<std::sync::Mutex<Option<Arc<AtomicBool>>>>,
    ) -> Result<bool> {
        let (op, config) = self.operation(ChannelKind::PersonalWeChat)?;
        *active.lock().map_err(|_| Failure("notification_busy"))? = Some(op.cancelled.clone());
        if stop.load(Ordering::Acquire) {
            op.cancelled.store(true, Ordering::Release);
            return fail("cancelled");
        }
        let secret = config
            .secret
            .as_deref()
            .ok_or(Failure("missing_credential"))?;
        protocol::validate_credential(
            ChannelKind::PersonalWeChat,
            secret,
            config.target.as_deref(),
            config.binding.as_ref(),
        )?;
        let request = updates_request(&config)?;
        let response = match self.transport.send(&request, &op.cancelled) {
            Ok(response) => match response_object(response) {
                Ok(value) => value,
                Err(error) => {
                    if error.0 == "wechat_session_expired" {
                        self.expire_personal_session(op.revision)?;
                    }
                    return Err(error);
                }
            },
            Err(error) => {
                if error.0 == "wechat_session_expired" {
                    self.expire_personal_session(op.revision)?;
                }
                return Err(error);
            }
        };
        op.current()?;
        let updates = incoming_updates(&response, &config)?;
        let fingerprint =
            credential_fingerprint(&config).ok_or(Failure("wechat_binding_required"))?;
        self.storage.change(|vault| {
            let current = vault
                .configs
                .get(&ChannelKind::PersonalWeChat)
                .filter(|current| current.enabled && current.revision == op.revision)
                .ok_or(Failure("configuration_changed"))?;
            let old_binding = current
                .binding
                .as_ref()
                .ok_or(Failure("wechat_binding_required"))?;
            let original_binding = config
                .binding
                .as_ref()
                .ok_or(Failure("wechat_binding_required"))?;
            if old_binding.base_url != original_binding.base_url
                || old_binding.bot_id != original_binding.bot_id
                || old_binding.user_id != original_binding.user_id
            {
                return fail("wechat_context_changed");
            }
            let journal = vault
                .personal_conversation
                .get_or_insert_with(Default::default);
            if let Some(binding) = journal.binding.as_mut() {
                if binding.credential_fingerprint != fingerprint {
                    binding.enabled = false;
                }
            }
            Ok(())
        })?;
        let now = now_ms();
        let target_and_enabled = self.storage.read(|vault| {
            let config = vault
                .configs
                .get(&ChannelKind::PersonalWeChat)
                .cloned()
                .unwrap_or_default();
            let binding = vault
                .personal_conversation
                .as_ref()
                .and_then(|journal| journal.binding.clone());
            Ok(binding.filter(|binding| {
                binding.enabled
                    && binding.credential_fingerprint == fingerprint
                    && config.enabled
                    && config.revision == op.revision
            }))
        })?;
        let Some(target_binding) = target_and_enabled else {
            // No consented target: context and cursor refresh retain the manual path.
            self.commit_personal_wechat_cursor(&updates.binding, op.revision)?;
            return Ok(true);
        };
        let owner = self
            .personal_conversation_owner()
            .ok_or(Failure("personal_conversation_owner_unavailable"))?;
        let generation = self
            .personal_conversation_generation
            .load(Ordering::Acquire);
        let target = PersonalConversationTarget {
            expected_scope_id: target_binding.expected_scope_id.clone(),
            thread_id: target_binding.thread_id.clone(),
        };
        let owner_key = format!(
            "{}\0{}",
            config.binding.as_ref().unwrap().bot_id,
            config.target.as_deref().unwrap_or_default()
        );
        let mut claimed = Vec::new();
        let mut complete_batch = true;
        for (message, text, context_token, received_at_ms) in updates.events {
            if stop.load(Ordering::Acquire) || op.cancelled.load(Ordering::Acquire) {
                return fail("cancelled");
            }
            if received_at_ms < target_binding.not_before_ms {
                continue;
            }
            if self.personal_conversation_tasks.load(Ordering::Acquire) >= MAX_CONCURRENT {
                complete_batch = false;
                break;
            }
            let id = event_id(&owner_key, &message);
            let claimed_id = self.storage.change(|vault| {
                let journal = vault
                    .personal_conversation
                    .get_or_insert_with(Default::default);
                if journal.entries.iter().any(|entry| entry.event_id == id)
                    || journal
                        .rejected_through_ms
                        .is_some_and(|floor| received_at_ms <= floor)
                {
                    return Ok(None);
                }
                let retained: Vec<_> = journal
                    .entries
                    .iter()
                    .filter(|entry| {
                        let age = now.saturating_sub(entry.received_at_ms);
                        !(age >= JOURNAL_RETENTION_MS
                            || entry.phase == PersonalConversationPhase::Accepted
                                && age > ACCEPTED_RETENTION_MS)
                    })
                    .cloned()
                    .collect();
                if retained.len() < journal.entries.len() {
                    if let Some(newest) = journal
                        .entries
                        .iter()
                        .filter(|entry| {
                            !retained.iter().any(|kept| kept.event_id == entry.event_id)
                        })
                        .map(|entry| entry.received_at_ms)
                        .max()
                    {
                        journal.rejected_through_ms =
                            Some(journal.rejected_through_ms.unwrap_or(0).max(newest));
                    }
                    journal.entries = retained;
                }
                if journal
                    .rejected_through_ms
                    .is_some_and(|floor| received_at_ms <= floor)
                {
                    return Ok(None);
                }
                if journal.entries.len() >= MAX_EVENTS {
                    return fail("personal_conversation_journal_capacity");
                }
                journal.entries.push(PersonalConversationEntry {
                    event_id: id.clone(),
                    received_at_ms,
                    phase: PersonalConversationPhase::Received,
                    thread_id: None,
                    turn_id: None,
                });
                Ok(Some(id.clone()))
            })?;
            if let Some(id) = claimed_id {
                claimed.push((
                    PersonalWeChatConversationEvent {
                        id,
                        text,
                        context_token,
                        revision: op.revision,
                    },
                    PersonalConversationTask::reserve(self.clone()),
                ));
            }
        }
        for (event, task_guard) in claimed {
            let Some(active_guard) = self.try_reserve_personal_reply() else {
                self.dispatch_personal_static_reply(
                    event,
                    task_guard,
                    target.clone(),
                    op.cancelled.clone(),
                    Arc::clone(stop),
                    generation,
                    "这个 Codex 聊天正在处理任务，请等结束后再发消息。",
                )?;
                continue;
            };
            let service = self.clone();
            let target = target.clone();
            let owner = owner.clone();
            let cancellation = op.cancelled.clone();
            let monitor_stop = Arc::clone(stop);
            tokio::spawn(async move {
                let _task = task_guard;
                let _active = active_guard;
                service
                    .run_personal_reply_event(
                        event,
                        target,
                        owner,
                        cancellation,
                        monitor_stop,
                        generation,
                    )
                    .await;
            });
        }
        op.current()?;
        if !complete_batch {
            return Ok(false);
        }
        self.commit_personal_wechat_cursor(&updates.binding, op.revision)?;
        Ok(true)
    }

    fn try_reserve_personal_reply(self: &Arc<Self>) -> Option<PersonalReplyActive> {
        self.personal_conversation_active
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .ok()
            .map(|_| PersonalReplyActive(self.clone()))
    }

    fn dispatch_personal_static_reply(
        self: &Arc<Self>,
        event: PersonalWeChatConversationEvent,
        task_guard: PersonalConversationTask,
        target: PersonalConversationTarget,
        operation_cancelled: Arc<AtomicBool>,
        monitor_stop: Arc<AtomicBool>,
        generation: u64,
        text: &'static str,
    ) -> Result<()> {
        let service = self.clone();
        // A busy response is at-most-once, does not submit to the Codex owner,
        // and uses the event's own context and deterministic client ID.
        tokio::spawn(async move {
            let _task = task_guard;
            let check_service = service.clone();
            let check_target = target.clone();
            let revision = event.revision;
            let should_continue: PersonalReplyContinue = Arc::new(move || {
                !check_service.exiting.load(Ordering::Acquire)
                    && !monitor_stop.load(Ordering::Acquire)
                    && !operation_cancelled.load(Ordering::Acquire)
                    && check_service
                        .personal_conversation_generation
                        .load(Ordering::Acquire)
                        == generation
                    && check_service.personal_conversation_still_enabled(&check_target, revision)
            });
            if !should_continue()
                || !service.mark_personal_conversation_event(
                    &event.id,
                    PersonalConversationPhase::ReplyAttempted,
                    None,
                    None,
                )
            {
                return;
            }
            let result = service.send_personal_conversation_text(
                &event.id,
                event.revision,
                &event.context_token,
                text,
                &should_continue,
            );
            service.mark_personal_conversation_event(
                &event.id,
                if result.is_ok() {
                    PersonalConversationPhase::Accepted
                } else {
                    PersonalConversationPhase::Uncertain
                },
                None,
                None,
            );
        });
        Ok(())
    }

    async fn run_personal_reply_event(
        self: Arc<Self>,
        event: PersonalWeChatConversationEvent,
        target: PersonalConversationTarget,
        owner: Arc<dyn PersonalConversationOwner>,
        operation_cancelled: Arc<AtomicBool>,
        monitor_stop: Arc<AtomicBool>,
        generation: u64,
    ) {
        let target_binding = target.clone();
        let service = self.clone();
        let continue_check: PersonalReplyContinue = Arc::new(move || {
            !service.exiting.load(Ordering::Acquire)
                && !monitor_stop.load(Ordering::Acquire)
                && !operation_cancelled.load(Ordering::Acquire)
                && service
                    .personal_conversation_generation
                    .load(Ordering::Acquire)
                    == generation
                && service.personal_conversation_still_enabled(&target_binding, event.revision)
        });
        if !continue_check() {
            return;
        }
        let submitted_service = self.clone();
        let submitted_event = event.id.clone();
        let submitted_thread = target.thread_id.clone();
        let on_submitted: PersonalReplySubmitted = Arc::new(move |turn_id| {
            submitted_service.mark_personal_conversation_event(
                &submitted_event,
                PersonalConversationPhase::Submitted,
                Some(&submitted_thread),
                Some(turn_id),
            )
        });
        let outcome = owner
            .reply(
                &target,
                &event.id,
                &event.text,
                on_submitted,
                continue_check.clone(),
            )
            .await;
        if !continue_check() {
            return;
        }
        // An unconfirmed submit acknowledgement cannot be turned into a new
        // WeChat send, even as a status message: the only safe reply after an
        // uncertain owner submit is to leave the event for manual inspection.
        if matches!(&outcome, PersonalReplyOutcome::Uncertain) {
            self.mark_personal_conversation_event(
                &event.id,
                PersonalConversationPhase::Uncertain,
                None,
                None,
            );
            return;
        }
        let answer = match outcome {
            PersonalReplyOutcome::Reply { turn_id, text } => {
                if !self.personal_conversation_submission_matches(
                    &event.id,
                    &target.thread_id,
                    &turn_id,
                ) || !valid_final_answer(&text)
                {
                    self.mark_personal_conversation_event(
                        &event.id,
                        PersonalConversationPhase::Uncertain,
                        None,
                        None,
                    );
                    return;
                }
                text
            }
            PersonalReplyOutcome::Busy => {
                "这个 Codex 聊天正在处理任务，请等结束后再发消息。".into()
            }
            PersonalReplyOutcome::AwaitingHuman => {
                "Codex 需要你在电脑上确认或补充信息，请打开原聊天处理。".into()
            }
            PersonalReplyOutcome::Unavailable => {
                "暂时无法连接或读取所选 Codex 原聊天，请在电脑上打开它后再试。".into()
            }
            PersonalReplyOutcome::Failed => "本次 Codex 任务失败，请在电脑上查看原聊天。".into(),
            PersonalReplyOutcome::Interrupted => {
                "本次 Codex 任务已中断，请在电脑上查看原聊天。".into()
            }
            PersonalReplyOutcome::TimedOut => {
                "Codex 仍未返回最终结果，请在电脑上查看原聊天；这条消息不会自动重发。".into()
            }
            PersonalReplyOutcome::Uncertain => unreachable!("handled above"),
            PersonalReplyOutcome::Cancelled => return,
        };
        if !self.mark_personal_conversation_event(
            &event.id,
            PersonalConversationPhase::ReplyAttempted,
            None,
            None,
        ) {
            return;
        }
        if !continue_check() {
            self.mark_personal_conversation_event(
                &event.id,
                PersonalConversationPhase::Uncertain,
                None,
                None,
            );
            return;
        }
        match self.send_personal_conversation_text(
            &event.id,
            event.revision,
            &event.context_token,
            &answer,
            &continue_check,
        ) {
            Ok(()) => {
                self.mark_personal_conversation_event(
                    &event.id,
                    PersonalConversationPhase::Accepted,
                    None,
                    None,
                );
            }
            Err(_) => {
                self.mark_personal_conversation_event(
                    &event.id,
                    PersonalConversationPhase::Uncertain,
                    None,
                    None,
                );
            }
        }
    }

    fn personal_conversation_still_enabled(
        &self,
        target: &PersonalConversationTarget,
        revision: u64,
    ) -> bool {
        self.storage
            .read(|vault| {
                let config = vault
                    .configs
                    .get(&ChannelKind::PersonalWeChat)
                    .filter(|config| config.enabled && config.revision == revision)
                    .ok_or(Failure("configuration_changed"))?;
                let fingerprint =
                    credential_fingerprint(config).ok_or(Failure("wechat_binding_required"))?;
                let binding = vault
                    .personal_conversation
                    .as_ref()
                    .and_then(|journal| journal.binding.as_ref())
                    .filter(|binding| {
                        binding.enabled
                            && binding.expected_scope_id == target.expected_scope_id
                            && binding.thread_id == target.thread_id
                            && binding.credential_fingerprint == fingerprint
                    })
                    .ok_or(Failure("personal_conversation_disabled"))?;
                let _ = binding;
                Ok(true)
            })
            .unwrap_or(false)
    }

    fn mark_personal_conversation_event(
        &self,
        event_id: &str,
        phase: PersonalConversationPhase,
        thread_id: Option<&str>,
        turn_id: Option<&str>,
    ) -> bool {
        self.storage
            .change(|vault| {
                let entry = vault
                    .personal_conversation
                    .as_mut()
                    .and_then(|journal| {
                        journal
                            .entries
                            .iter_mut()
                            .find(|entry| entry.event_id == event_id)
                    })
                    .ok_or(Failure("personal_conversation_event_missing"))?;
                let permitted = matches!(
                    (&entry.phase, &phase),
                    (
                        PersonalConversationPhase::Received,
                        PersonalConversationPhase::Submitted
                    ) | (
                        PersonalConversationPhase::Received,
                        PersonalConversationPhase::ReplyAttempted
                    ) | (
                        PersonalConversationPhase::Received,
                        PersonalConversationPhase::Uncertain
                    ) | (
                        PersonalConversationPhase::Submitted,
                        PersonalConversationPhase::ReplyAttempted
                    ) | (
                        PersonalConversationPhase::Submitted,
                        PersonalConversationPhase::Uncertain
                    ) | (
                        PersonalConversationPhase::ReplyAttempted,
                        PersonalConversationPhase::Accepted
                    ) | (
                        PersonalConversationPhase::ReplyAttempted,
                        PersonalConversationPhase::Uncertain
                    )
                );
                if !permitted
                    || thread_id.is_some_and(|value| !valid_uuid(value))
                    || turn_id.is_some_and(|value| !valid_uuid(value))
                {
                    return fail("personal_conversation_event_invalid");
                }
                if phase == PersonalConversationPhase::Submitted {
                    let thread = thread_id.ok_or(Failure("personal_conversation_event_invalid"))?;
                    let turn = turn_id.ok_or(Failure("personal_conversation_event_invalid"))?;
                    if entry
                        .thread_id
                        .as_deref()
                        .is_some_and(|value| value != thread)
                        || entry.turn_id.as_deref().is_some_and(|value| value != turn)
                    {
                        return fail("personal_conversation_event_invalid");
                    }
                    entry.thread_id = Some(thread.to_owned());
                    entry.turn_id = Some(turn.to_owned());
                }
                entry.phase = phase;
                Ok(())
            })
            .is_ok()
    }

    fn personal_conversation_submission_matches(
        &self,
        event_id: &str,
        thread_id: &str,
        turn_id: &str,
    ) -> bool {
        self.storage
            .read(|vault| {
                let entry = vault
                    .personal_conversation
                    .as_ref()
                    .and_then(|journal| {
                        journal
                            .entries
                            .iter()
                            .find(|entry| entry.event_id == event_id)
                    })
                    .ok_or(Failure("personal_conversation_event_missing"))?;
                Ok(entry.phase == PersonalConversationPhase::Submitted
                    && entry.thread_id.as_deref() == Some(thread_id)
                    && entry.turn_id.as_deref() == Some(turn_id))
            })
            .unwrap_or(false)
    }

    fn send_personal_conversation_text(
        self: &Arc<Self>,
        event_id: &str,
        expected_revision: u64,
        context_token: &str,
        text: &str,
        should_send: &PersonalReplyContinue,
    ) -> Result<()> {
        if !valid_uuid(event_id) || !should_send() {
            return fail("cancelled");
        }
        let (op, config) = self.operation(ChannelKind::PersonalWeChat)?;
        if op.revision != expected_revision || !should_send() {
            return fail("configuration_changed");
        }
        let secret = config
            .secret
            .as_deref()
            .ok_or(Failure("missing_credential"))?;
        let binding = config
            .binding
            .as_ref()
            .ok_or(Failure("wechat_binding_required"))?;
        protocol::validate_credential(
            ChannelKind::PersonalWeChat,
            secret,
            config.target.as_deref(),
            Some(binding),
        )?;
        if !protocol::valid_token(context_token, 8192) {
            return fail("invalid_response");
        }
        if text.trim().is_empty()
            || text
                .chars()
                .any(|character| character < ' ' && !matches!(character, '\n' | '\r' | '\t'))
        {
            return fail("invalid_message_text");
        }
        if text.len() > MAX_TEXT_BYTES {
            return fail("message_too_long");
        }
        let request = protocol::ilink_request(
            &binding.base_url,
            "sendmessage",
            Some(secret),
            json!({"msg":{"from_user_id":"","to_user_id":binding.user_id,"client_id":format!("aigoodbro-{event_id}"),"message_type":2,"message_state":2,"context_token":context_token,"item_list":[{"type":1,"text_item":{"text":text}}]}}),
            false,
        )?;
        op.current()?;
        if !should_send() {
            return fail("cancelled");
        }
        let response =
            self.transport
                .send_controlled(&request, &op.cancelled, should_send.as_ref())?;
        match protocol::parse_response(ChannelKind::PersonalWeChat, response) {
            Accepted::Ok(_) => Ok(()),
            Accepted::Rejected(error) | Accepted::Uncertain(error) => Err(error),
        }
    }

    fn commit_personal_wechat_cursor(
        &self,
        updates: &PersonalBinding,
        expected_revision: u64,
    ) -> Result<()> {
        self.storage.change(|vault| {
            let current = vault
                .configs
                .get_mut(&ChannelKind::PersonalWeChat)
                .filter(|config| config.enabled && config.revision == expected_revision)
                .ok_or(Failure("configuration_changed"))?;
            let binding = current
                .binding
                .as_mut()
                .ok_or(Failure("wechat_binding_required"))?;
            if binding.base_url != updates.base_url
                || binding.bot_id != updates.bot_id
                || binding.user_id != updates.user_id
            {
                return fail("wechat_context_changed");
            }
            binding.cursor = updates.cursor.clone();
            Ok(())
        })
    }
}

struct PersonalConversationTask(Arc<NotificationService>);
impl PersonalConversationTask {
    fn reserve(service: Arc<NotificationService>) -> Self {
        service
            .personal_conversation_tasks
            .fetch_add(1, Ordering::AcqRel);
        Self(service)
    }
}
impl Drop for PersonalConversationTask {
    fn drop(&mut self) {
        self.0
            .personal_conversation_tasks
            .try_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                Some(count.saturating_sub(1))
            })
            .ok();
    }
}

struct PersonalReplyActive(Arc<NotificationService>);
impl Drop for PersonalReplyActive {
    fn drop(&mut self) {
        self.0
            .personal_conversation_active
            .store(false, Ordering::Release);
    }
}

fn reply_failure(outcome: PersonalReplyOutcome) -> Failure {
    match outcome {
        PersonalReplyOutcome::Busy => Failure("owner_busy"),
        PersonalReplyOutcome::AwaitingHuman => Failure("owner_awaiting_human"),
        PersonalReplyOutcome::Unavailable => Failure("owner_unavailable"),
        PersonalReplyOutcome::Failed => Failure("owner_failed"),
        PersonalReplyOutcome::Interrupted => Failure("owner_interrupted"),
        PersonalReplyOutcome::TimedOut => Failure("owner_timed_out"),
        PersonalReplyOutcome::Uncertain => Failure("owner_uncertain"),
        PersonalReplyOutcome::Cancelled => Failure("cancelled"),
        PersonalReplyOutcome::Reply { .. } => Failure("owner_invalid_response"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::accounts::{AccountResult, SecretProtector};
    use std::{
        collections::VecDeque,
        sync::atomic::{AtomicUsize, Ordering},
        sync::{mpsc, Mutex},
        time::Duration,
    };

    struct FixtureProtector;
    impl SecretProtector for FixtureProtector {
        fn seal(&self, _: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
            Ok(bytes.iter().map(|byte| byte ^ 0x53).collect())
        }
        fn unseal(&self, _: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
            Ok(bytes.iter().map(|byte| byte ^ 0x53).collect())
        }
    }

    #[derive(Default)]
    struct FixtureTransport {
        updates: Mutex<VecDeque<Value>>,
        sent: Mutex<Vec<Value>>,
        send_count: AtomicUsize,
    }
    impl FixtureTransport {
        fn updates(&self, value: Value) {
            self.updates.lock().unwrap().push_back(value);
        }
        fn sent(&self) -> Vec<Value> {
            self.sent.lock().unwrap().clone()
        }
    }
    impl super::super::transport::NotificationTransport for FixtureTransport {
        fn send(
            &self,
            request: &TransportRequest,
            cancelled: &AtomicBool,
        ) -> Result<super::super::transport::TransportResponse> {
            if cancelled.load(Ordering::Acquire) {
                return fail("cancelled");
            }
            let body: Value = serde_json::from_slice(request.body())
                .map_err(|_| Failure("invalid_notification_request"))?;
            let value = if request.endpoint().path().ends_with("/getupdates") {
                self.updates
                    .lock()
                    .map_err(|_| Failure("notification_busy"))?
                    .pop_front()
                    .unwrap_or_else(|| json!({"ret":0,"msgs":[],"get_updates_buf":"cursor"}))
            } else if request.endpoint().path().ends_with("/sendmessage") {
                self.sent
                    .lock()
                    .map_err(|_| Failure("notification_busy"))?
                    .push(body);
                self.send_count.fetch_add(1, Ordering::AcqRel);
                json!({"ret":0})
            } else {
                return fail("unexpected_fixture_request");
            };
            Ok(super::super::transport::TransportResponse {
                status: 200,
                body: serde_json::to_vec(&value).map_err(|_| Failure("invalid_response"))?,
            })
        }
    }

    struct FixtureOwner {
        replies: AtomicUsize,
        reply_text: String,
        submitted_turn_id: Mutex<String>,
        reply_turn_id: Mutex<String>,
        after_submission: Mutex<Option<Arc<FixtureSubmissionGate>>>,
    }
    struct FixtureSubmissionGate {
        entered_tx: mpsc::Sender<()>,
        entered_rx: Mutex<mpsc::Receiver<()>>,
        release_tx: mpsc::Sender<()>,
        release_rx: Mutex<mpsc::Receiver<()>>,
    }
    impl FixtureOwner {
        fn new() -> Self {
            Self {
                replies: AtomicUsize::new(0),
                reply_text: "exact final answer: 東京".into(),
                submitted_turn_id: Mutex::new("123e4567-e89b-42d3-a456-426614174001".into()),
                reply_turn_id: Mutex::new("123e4567-e89b-42d3-a456-426614174001".into()),
                after_submission: Mutex::new(None),
            }
        }
        fn set_turn_ids(&self, submitted: &str, reply: &str) {
            *self.submitted_turn_id.lock().unwrap() = submitted.into();
            *self.reply_turn_id.lock().unwrap() = reply.into();
        }
        fn hold_after_submission(&self) -> Arc<FixtureSubmissionGate> {
            let (entered_tx, entered_rx) = mpsc::channel();
            let (release_tx, release_rx) = mpsc::channel();
            let gate = Arc::new(FixtureSubmissionGate {
                entered_tx,
                entered_rx: Mutex::new(entered_rx),
                release_tx,
                release_rx: Mutex::new(release_rx),
            });
            *self.after_submission.lock().unwrap() = Some(gate.clone());
            gate
        }
    }
    impl PersonalConversationOwner for FixtureOwner {
        fn validate_target<'a>(
            &'a self,
            _: &'a PersonalConversationTarget,
            should_continue: PersonalReplyContinue,
        ) -> Pin<Box<dyn Future<Output = std::result::Result<(), PersonalReplyOutcome>> + Send + 'a>>
        {
            Box::pin(async move {
                if should_continue() {
                    Ok(())
                } else {
                    Err(PersonalReplyOutcome::Cancelled)
                }
            })
        }

        fn reply<'a>(
            &'a self,
            _: &'a PersonalConversationTarget,
            _: &'a str,
            _: &'a str,
            on_submitted: PersonalReplySubmitted,
            should_continue: PersonalReplyContinue,
        ) -> PersonalReplyFuture<'a> {
            Box::pin(async move {
                self.replies.fetch_add(1, Ordering::AcqRel);
                if !should_continue() {
                    return PersonalReplyOutcome::Cancelled;
                }
                let submitted_turn_id = self.submitted_turn_id.lock().unwrap().clone();
                if !on_submitted(&submitted_turn_id) {
                    return PersonalReplyOutcome::Uncertain;
                }
                let gate = self.after_submission.lock().unwrap().take();
                if let Some(gate) = gate {
                    let _ = gate.entered_tx.send(());
                    if gate.release_rx.lock().unwrap().recv().is_err() {
                        return PersonalReplyOutcome::Cancelled;
                    }
                }
                if !should_continue() {
                    return PersonalReplyOutcome::Cancelled;
                }
                PersonalReplyOutcome::Reply {
                    turn_id: self.reply_turn_id.lock().unwrap().clone(),
                    text: self.reply_text.clone(),
                }
            })
        }
    }

    struct Fixture {
        _directory: tempfile::TempDir,
        service: Arc<NotificationService>,
        transport: Arc<FixtureTransport>,
        owner: Arc<FixtureOwner>,
        target: PersonalConversationTarget,
    }
    impl Fixture {
        fn new() -> Self {
            let directory = tempfile::tempdir().unwrap();
            let transport = Arc::new(FixtureTransport::default());
            let service = NotificationService::with_components(
                directory
                    .path()
                    .canonicalize()
                    .unwrap()
                    .join("notifications"),
                Arc::new(FixtureProtector),
                transport.clone(),
            )
            .unwrap();
            service
                .storage
                .change(|vault| {
                    let config = vault
                        .configs
                        .entry(ChannelKind::PersonalWeChat)
                        .or_default();
                    config.enabled = true;
                    config.revision = 1;
                    config.secret = Some("synthetic-bot-token".into());
                    config.target = Some("synthetic-user".into());
                    config.binding = Some(PersonalBinding {
                        base_url: "https://ilinkai.weixin.qq.com".into(),
                        bot_id: "synthetic-bot".into(),
                        user_id: "synthetic-user".into(),
                        context_token: Some("synthetic-manual-context".into()),
                        context_checked_at: Some(super::super::now()),
                        cursor: "synthetic-cursor".into(),
                    });
                    Ok(())
                })
                .unwrap();
            let owner = Arc::new(FixtureOwner::new());
            service
                .set_personal_conversation_owner(owner.clone())
                .unwrap();
            Self {
                _directory: directory,
                service,
                transport,
                owner,
                target: PersonalConversationTarget {
                    expected_scope_id: "a".repeat(64),
                    thread_id: "123e4567-e89b-42d3-a456-426614174000".into(),
                },
            }
        }

        async fn bind(&self) -> PersonalWeChatConversationState {
            self.service
                .bind_personal_conversation(1, self.target.clone(), true)
                .await
                .unwrap()
        }

        fn message(&self, at_ms: i64, message_id: &str) -> Value {
            self.message_with_context(at_ms, message_id, "synthetic-event-context")
        }

        fn message_with_context(&self, at_ms: i64, message_id: &str, context: &str) -> Value {
            json!({
                "message_type":1,
                "message_state":2,
                "from_user_id":"synthetic-user",
                "to_user_id":"synthetic-bot",
                "message_id":message_id,
                "context_token":context,
                "create_time_ms":at_ms,
                "item_list":[{"type":1,"text_item":{"text":"synthetic inbound body"}}]
            })
        }

        async fn poll(&self, update: Value) {
            self.poll_on(&self.service, update).await;
        }

        async fn poll_on(&self, service: &Arc<NotificationService>, update: Value) {
            self.transport.updates(update);
            service
                .poll_personal_conversation_updates_owned(
                    &Arc::new(AtomicBool::new(false)),
                    &Arc::new(Mutex::new(None)),
                )
                .await
                .unwrap();
        }

        async fn wait_for_tasks(&self) {
            self.wait_for_service_tasks(&self.service).await;
        }

        async fn wait_for_service_tasks(&self, service: &Arc<NotificationService>) {
            tokio::time::timeout(Duration::from_secs(2), async {
                while service.personal_conversation_tasks.load(Ordering::Acquire) > 0 {
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
            })
            .await
            .unwrap();
        }

        fn restart(&self, owner: Arc<FixtureOwner>) -> Arc<NotificationService> {
            let root = self
                ._directory
                .path()
                .canonicalize()
                .unwrap()
                .join("notifications");
            let service = NotificationService::with_components(
                root,
                Arc::new(FixtureProtector),
                self.transport.clone(),
            )
            .unwrap();
            service.set_personal_conversation_owner(owner).unwrap();
            service
        }
    }

    fn update(message: Value, cursor: &str) -> Value {
        json!({"ret":0,"msgs":[message],"get_updates_buf":cursor})
    }

    #[tokio::test]
    async fn explicit_binding_relays_only_the_exact_final_answer_and_never_replays() {
        let fixture = Fixture::new();
        let state = fixture.bind().await;
        assert!(state.enabled);
        assert_eq!(
            state.binding.as_ref().unwrap().thread_id,
            fixture.target.thread_id
        );

        let not_before = fixture
            .service
            .storage
            .read(|vault| {
                Ok(vault
                    .personal_conversation
                    .as_ref()
                    .unwrap()
                    .binding
                    .as_ref()
                    .unwrap()
                    .not_before_ms)
            })
            .unwrap();
        let received = now_ms().max(not_before);
        let event = fixture.message(received, "msg-001");
        fixture.poll(update(event.clone(), "cursor-next")).await;
        fixture.wait_for_tasks().await;

        assert_eq!(fixture.owner.replies.load(Ordering::Acquire), 1);
        assert_eq!(fixture.transport.send_count.load(Ordering::Acquire), 1);
        let sent = fixture.transport.sent();
        assert_eq!(sent[0]["msg"]["context_token"], "synthetic-event-context");
        assert_eq!(
            sent[0]["msg"]["item_list"][0]["text_item"]["text"],
            fixture.owner.reply_text
        );

        let persisted = fixture
            .service
            .storage
            .read(|vault| {
                let journal = vault.personal_conversation.as_ref().unwrap();
                Ok(serde_json::to_string(journal).unwrap())
            })
            .unwrap();
        assert!(!persisted.contains("synthetic inbound body"));
        assert!(!persisted.contains("synthetic-event-context"));
        assert!(!persisted.contains(&fixture.owner.reply_text));
        assert!(!persisted.contains("synthetic-bot-token"));
        assert_eq!(
            fixture
                .service
                .storage
                .read(|vault| Ok(vault.configs[&ChannelKind::PersonalWeChat]
                    .binding
                    .as_ref()
                    .unwrap()
                    .context_token
                    .clone()))
                .unwrap(),
            Some("synthetic-manual-context".into()),
            "automatic event contexts must not replace the manual context token"
        );

        let restarted_owner = Arc::new(FixtureOwner::new());
        let restarted = fixture.restart(restarted_owner.clone());
        fixture
            .poll_on(&restarted, update(event, "cursor-restart"))
            .await;
        fixture.wait_for_service_tasks(&restarted).await;
        assert_eq!(fixture.owner.replies.load(Ordering::Acquire), 1);
        assert_eq!(fixture.transport.send_count.load(Ordering::Acquire), 1);
        assert_eq!(restarted_owner.replies.load(Ordering::Acquire), 0);
    }

    #[tokio::test]
    async fn event_context_is_scoped_to_each_received_message() {
        let fixture = Fixture::new();
        let binding = fixture.bind().await;
        let received = now_ms().max(
            fixture
                .service
                .storage
                .read(|vault| {
                    Ok(vault
                        .personal_conversation
                        .as_ref()
                        .unwrap()
                        .binding
                        .as_ref()
                        .unwrap()
                        .not_before_ms)
                })
                .unwrap(),
        );

        fixture
            .poll(update(
                fixture.message_with_context(received, "context-1", "event-context-one"),
                "cursor-one",
            ))
            .await;
        fixture.wait_for_tasks().await;
        fixture
            .poll(update(
                fixture.message_with_context(received + 1, "context-2", "event-context-two"),
                "cursor-two",
            ))
            .await;
        fixture.wait_for_tasks().await;

        let sent = fixture.transport.sent();
        assert_eq!(sent.len(), 2);
        assert_eq!(sent[0]["msg"]["context_token"], "event-context-one");
        assert_eq!(sent[1]["msg"]["context_token"], "event-context-two");
        assert_ne!(
            sent[0]["msg"]["context_token"],
            sent[1]["msg"]["context_token"]
        );
        assert_eq!(
            fixture
                .service
                .storage
                .read(|vault| Ok(vault.configs[&ChannelKind::PersonalWeChat]
                    .binding
                    .as_ref()
                    .unwrap()
                    .context_token
                    .clone()))
                .unwrap(),
            Some("synthetic-manual-context".into())
        );
        assert_eq!(
            binding.binding.as_ref().unwrap().thread_id,
            fixture.target.thread_id
        );
    }

    #[test]
    fn inbound_parser_accepts_only_fresh_explicit_pure_text_events() {
        let fixture = Fixture::new();
        let mut config = fixture
            .service
            .storage
            .read(|vault| Ok(vault.configs[&ChannelKind::PersonalWeChat].clone()))
            .unwrap();
        config.binding.as_mut().unwrap().context_checked_at = None;
        let now = now_ms();

        let mut wrong_type = fixture.message(now, "wrong-type");
        wrong_type["message_type"] = json!(2);
        let mut wrong_state = fixture.message(now, "wrong-state");
        wrong_state["message_state"] = json!(1);
        let mut wrong_sender = fixture.message(now, "wrong-sender");
        wrong_sender["from_user_id"] = json!("other-user");
        let mut wrong_recipient = fixture.message(now, "wrong-recipient");
        wrong_recipient["to_user_id"] = json!("other-bot");
        let mut missing_recipient = fixture.message(now, "missing-recipient");
        missing_recipient
            .as_object_mut()
            .unwrap()
            .remove("to_user_id");
        let mut missing_context = fixture.message(now, "missing-context");
        missing_context
            .as_object_mut()
            .unwrap()
            .remove("context_token");
        let mut missing_id = fixture.message(now, "unused");
        missing_id.as_object_mut().unwrap().remove("message_id");
        let mut nontext = fixture.message(now, "nontext");
        nontext["item_list"] = json!([
            {"type":1,"text_item":{"text":"plain"}},
            {"type":2,"image_item":{"url":"synthetic"}}
        ]);
        let mut empty_text = fixture.message(now, "empty-text");
        empty_text["item_list"] = json!([]);
        let mut control = fixture.message(now, "control");
        let control_text = format!("bad{}text", char::from_u32(1).unwrap());
        control["item_list"] = json!([{"type":1,"text_item":{"text":control_text}}]);
        let mut oversize = fixture.message(now, "oversize");
        oversize["item_list"] =
            json!([{"type":1,"text_item":{"text":"x".repeat(MAX_TEXT_BYTES + 1)}}]);
        let too_old = fixture.message(now - MAX_EVENT_AGE_MS - 1, "too-old");
        let too_future = fixture.message(now + MAX_FUTURE_SKEW_MS + 1000, "too-future");
        let valid_old = fixture.message(now - MAX_EVENT_AGE_MS + 1000, "valid-old");
        let valid_future = fixture.message(now + MAX_FUTURE_SKEW_MS - 1000, "valid-future");
        let mut exact_byte_limit = fixture.message(now, "exact-byte-limit");
        exact_byte_limit["item_list"] =
            json!([{"type":1,"text_item":{"text":"x".repeat(MAX_TEXT_BYTES)}}]);
        let invalid_messages = vec![
            too_old,
            valid_old,
            wrong_type,
            wrong_state,
            wrong_sender,
            wrong_recipient,
            missing_recipient,
            missing_context,
            missing_id,
            nontext,
            empty_text,
            control,
            oversize,
            exact_byte_limit,
            valid_future,
            too_future,
        ];
        let result = incoming_updates(
            &json!({"ret":0,"msgs":invalid_messages,"get_updates_buf":"next-cursor"}),
            &config,
        )
        .unwrap();
        assert_eq!(
            result
                .events
                .iter()
                .map(|event| event.0.as_str())
                .collect::<Vec<_>>(),
            ["valid-old", "exact-byte-limit", "valid-future"]
        );
        assert_eq!(result.events[1].1.len(), MAX_TEXT_BYTES);
    }

    #[tokio::test]
    async fn wrong_or_unrecordable_turn_ack_never_sends_a_wechat_reply() {
        let wrong_turn = Fixture::new();
        wrong_turn.bind().await;
        wrong_turn.owner.set_turn_ids(
            "123e4567-e89b-42d3-a456-426614174001",
            "123e4567-e89b-42d3-a456-426614174099",
        );
        wrong_turn
            .poll(update(
                wrong_turn.message(now_ms(), "wrong-turn-ack"),
                "cursor-wrong",
            ))
            .await;
        wrong_turn.wait_for_tasks().await;
        assert_eq!(wrong_turn.transport.send_count.load(Ordering::Acquire), 0);
        let wrong_turn_entry = wrong_turn
            .service
            .storage
            .read(|vault| Ok(vault.personal_conversation.as_ref().unwrap().entries[0].clone()))
            .unwrap();
        assert!(matches!(
            wrong_turn_entry.phase,
            PersonalConversationPhase::Uncertain
        ));
        assert_eq!(
            wrong_turn_entry.turn_id.as_deref(),
            Some("123e4567-e89b-42d3-a456-426614174001")
        );

        let failed_receipt = Fixture::new();
        failed_receipt.bind().await;
        failed_receipt
            .owner
            .set_turn_ids("not-a-turn-id", "not-a-turn-id");
        failed_receipt
            .poll(update(
                failed_receipt.message(now_ms(), "failed-submit-receipt"),
                "cursor-failed-receipt",
            ))
            .await;
        failed_receipt.wait_for_tasks().await;
        assert_eq!(
            failed_receipt.transport.send_count.load(Ordering::Acquire),
            0
        );
        let failed_entry = failed_receipt
            .service
            .storage
            .read(|vault| Ok(vault.personal_conversation.as_ref().unwrap().entries[0].clone()))
            .unwrap();
        assert!(matches!(
            failed_entry.phase,
            PersonalConversationPhase::Uncertain
        ));
        assert!(failed_entry.turn_id.is_none());
    }

    #[tokio::test]
    async fn partial_claim_failure_releases_all_reserved_task_slots() {
        let fixture = Fixture::new();
        fixture.bind().await;
        fixture
            .service
            .storage
            .change(|vault| {
                let journal = vault
                    .personal_conversation
                    .as_mut()
                    .expect("binding creates the personal conversation journal");
                journal.entries = (0..MAX_EVENTS - 1)
                    .map(|index| PersonalConversationEntry {
                        event_id: event_id("capacity-fixture", &index.to_string()),
                        received_at_ms: now_ms(),
                        phase: PersonalConversationPhase::Accepted,
                        thread_id: None,
                        turn_id: None,
                    })
                    .collect();
                Ok(())
            })
            .unwrap();

        let received = now_ms();
        fixture.transport.updates(json!({
            "ret":0,
            "msgs":[
                fixture.message(received, "capacity-claim-1"),
                fixture.message(received + 1, "capacity-claim-2")
            ],
            "get_updates_buf":"cursor-capacity"
        }));
        let error = fixture
            .service
            .poll_personal_conversation_updates_owned(
                &Arc::new(AtomicBool::new(false)),
                &Arc::new(Mutex::new(None)),
            )
            .await
            .unwrap_err();

        assert_eq!(error.code(), "personal_conversation_journal_capacity");
        assert_eq!(
            fixture
                .service
                .personal_conversation_tasks
                .load(Ordering::Acquire),
            0
        );
        assert_eq!(fixture.owner.replies.load(Ordering::Acquire), 0);
        assert!(fixture.transport.sent().is_empty());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn stop_after_turn_ack_and_restart_do_not_replay_or_send() {
        let fixture = Fixture::new();
        let bound = fixture.bind().await;
        let gate = fixture.owner.hold_after_submission();
        let event = fixture.message(now_ms(), "stop-after-ack");
        fixture.poll(update(event.clone(), "cursor-first")).await;
        let wait_gate = gate.clone();
        tokio::time::timeout(
            Duration::from_secs(2),
            tokio::task::spawn_blocking(move || {
                wait_gate
                    .entered_rx
                    .lock()
                    .unwrap()
                    .recv_timeout(Duration::from_secs(2))
            }),
        )
        .await
        .unwrap()
        .unwrap()
        .unwrap();

        let entry = fixture
            .service
            .storage
            .read(|vault| Ok(vault.personal_conversation.as_ref().unwrap().entries[0].clone()))
            .unwrap();
        assert!(matches!(entry.phase, PersonalConversationPhase::Submitted));
        assert_eq!(
            entry.turn_id.as_deref(),
            Some("123e4567-e89b-42d3-a456-426614174001")
        );

        let restarted_owner = Arc::new(FixtureOwner::new());
        let restarted = fixture.restart(restarted_owner.clone());
        fixture
            .poll_on(&restarted, update(event, "cursor-after-restart"))
            .await;
        fixture.wait_for_service_tasks(&restarted).await;
        assert_eq!(restarted_owner.replies.load(Ordering::Acquire), 0);

        fixture
            .service
            .set_personal_conversation_enabled(bound.revision, false)
            .unwrap();
        gate.release_tx.send(()).unwrap();
        fixture.wait_for_tasks().await;
        assert_eq!(fixture.transport.send_count.load(Ordering::Acquire), 0);
        assert_eq!(restarted_owner.replies.load(Ordering::Acquire), 0);
    }

    #[tokio::test]
    async fn binding_mutations_use_compare_and_swap_revisions() {
        let fixture = Fixture::new();
        let bound = fixture.bind().await;
        assert_eq!(bound.revision, 3);

        for error in [
            fixture
                .service
                .set_personal_conversation_enabled(bound.revision - 1, false)
                .err()
                .unwrap()
                .code(),
            fixture
                .service
                .unbind_personal_conversation(bound.revision - 1)
                .err()
                .unwrap()
                .code(),
            fixture
                .service
                .bind_personal_conversation(bound.revision - 1, fixture.target.clone(), true)
                .await
                .err()
                .unwrap()
                .code(),
        ] {
            assert_eq!(error, "configuration_changed");
        }
        let still_bound = fixture.service.personal_conversation_state().unwrap();
        assert!(still_bound.enabled);
        assert_eq!(still_bound.revision, bound.revision);

        let paused = fixture
            .service
            .set_personal_conversation_enabled(bound.revision, false)
            .unwrap();
        assert!(!paused.enabled);
        assert_eq!(paused.revision, bound.revision + 1);
        assert_eq!(
            fixture
                .service
                .set_personal_conversation_enabled(bound.revision, true)
                .err()
                .unwrap()
                .code(),
            "configuration_changed"
        );
        let resumed = fixture
            .service
            .set_personal_conversation_enabled(paused.revision, true)
            .unwrap();
        assert!(resumed.enabled);
        assert_eq!(resumed.revision, paused.revision + 1);
        assert_eq!(
            fixture
                .service
                .unbind_personal_conversation(paused.revision)
                .err()
                .unwrap()
                .code(),
            "configuration_changed"
        );
        let unbound = fixture
            .service
            .unbind_personal_conversation(resumed.revision)
            .unwrap();
        assert!(!unbound.enabled);
        assert!(unbound.binding.is_none());
        assert_eq!(unbound.revision, resumed.revision + 1);
    }

    #[tokio::test]
    async fn stopping_and_personal_config_changes_revoke_before_busy_store_writes() {
        let fixture = Fixture::new();
        let bound = fixture.bind().await;
        let root = fixture
            ._directory
            .path()
            .canonicalize()
            .unwrap()
            .join("notifications");
        let lock = crate::accounts::storage::StoreLock::acquire(&root).unwrap();

        let generation = fixture
            .service
            .personal_conversation_generation
            .load(Ordering::Acquire);
        assert_eq!(
            fixture
                .service
                .set_personal_conversation_enabled(bound.revision, false)
                .err()
                .unwrap()
                .code(),
            "notification_store_busy"
        );
        let after_disable = fixture
            .service
            .personal_conversation_generation
            .load(Ordering::Acquire);
        assert_eq!(after_disable, generation + 1);

        assert_eq!(
            fixture
                .service
                .unbind_personal_conversation(bound.revision)
                .err()
                .unwrap()
                .code(),
            "notification_store_busy"
        );
        let after_unbind = fixture
            .service
            .personal_conversation_generation
            .load(Ordering::Acquire);
        assert_eq!(after_unbind, after_disable + 1);

        assert_eq!(
            fixture
                .service
                .forget_channel(ChannelKind::PersonalWeChat)
                .err()
                .unwrap()
                .code(),
            "notification_store_busy"
        );
        assert_eq!(
            fixture
                .service
                .personal_conversation_generation
                .load(Ordering::Acquire),
            after_unbind + 1
        );
        drop(lock);

        let persisted = fixture.service.personal_conversation_state().unwrap();
        assert!(persisted.enabled);
        assert_eq!(persisted.revision, bound.revision);
    }

    #[test]
    fn stale_session_expiry_does_not_revoke_a_newer_pairing() {
        let fixture = Fixture::new();
        fixture
            .service
            .storage
            .change(|vault| {
                let config = vault.configs.get_mut(&ChannelKind::PersonalWeChat).unwrap();
                config.secret = Some("synthetic-newer-token".into());
                config.revision += 1;
                Ok(())
            })
            .unwrap();
        let generation = fixture
            .service
            .personal_conversation_generation
            .load(Ordering::Acquire);
        assert_eq!(
            fixture
                .service
                .expire_personal_session(1)
                .unwrap_err()
                .code(),
            "configuration_changed"
        );
        assert_eq!(
            fixture
                .service
                .personal_conversation_generation
                .load(Ordering::Acquire),
            generation
        );
        assert!(!fixture
            .service
            .storage
            .read(|vault| Ok(vault.configs[&ChannelKind::PersonalWeChat].session_expired))
            .unwrap());
        fixture.service.expire_personal_session(2).unwrap();
        assert_eq!(
            fixture
                .service
                .personal_conversation_generation
                .load(Ordering::Acquire),
            generation + 1
        );
        assert!(fixture
            .service
            .storage
            .read(|vault| Ok(vault.configs[&ChannelKind::PersonalWeChat].session_expired))
            .unwrap());
    }

    #[tokio::test]
    async fn bind_and_enable_exclude_backlog_and_credential_changes_require_reconfirmation() {
        let fixture = Fixture::new();
        assert!(
            !fixture
                .service
                .personal_conversation_state()
                .unwrap()
                .enabled
        );
        assert_eq!(
            fixture
                .service
                .bind_personal_conversation(1, fixture.target.clone(), false)
                .await
                .err()
                .unwrap()
                .code(),
            "confirmation_required"
        );
        fixture.bind().await;
        let not_before = fixture
            .service
            .storage
            .read(|vault| {
                Ok(vault
                    .personal_conversation
                    .as_ref()
                    .unwrap()
                    .binding
                    .as_ref()
                    .unwrap()
                    .not_before_ms)
            })
            .unwrap();
        fixture
            .poll(update(
                fixture.message(not_before - 1, "old-message"),
                "old-cursor",
            ))
            .await;
        assert_eq!(fixture.owner.replies.load(Ordering::Acquire), 0);
        assert_eq!(fixture.transport.send_count.load(Ordering::Acquire), 0);

        fixture
            .service
            .storage
            .change(|vault| {
                let config = vault.configs.get_mut(&ChannelKind::PersonalWeChat).unwrap();
                config.secret = Some("synthetic-new-token".into());
                config.revision += 1;
                Ok(())
            })
            .unwrap();
        let changed = fixture.service.personal_conversation_state().unwrap();
        assert!(changed.needs_confirmation);
        assert!(!changed.enabled);
        assert_eq!(changed.phase, "needs_confirmation");
        assert_eq!(
            fixture
                .service
                .set_personal_conversation_enabled(changed.revision, true)
                .err()
                .unwrap()
                .code(),
            "personal_conversation_confirmation_required"
        );
        assert!(
            fixture
                .service
                .bind_personal_conversation(changed.revision, fixture.target.clone(), true)
                .await
                .unwrap()
                .enabled
        );
    }

    #[test]
    fn old_vaults_load_without_the_new_optional_journal() {
        let vault: Vault = serde_json::from_value(json!({
            "schema":1,
            "configs":{},
            "deliveries":{},
            "baselines":{}
        }))
        .unwrap();
        assert!(vault.personal_conversation.is_none());
    }
}
