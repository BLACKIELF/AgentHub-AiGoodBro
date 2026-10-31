//! Native official-success receipts only; never accepts WebView notification bodies.
use super::{domain::*, fail, storage::*, Failure, NotificationService, Result};
use serde::{Deserialize, Serialize};
use std::sync::{atomic::AtomicBool, Arc, Mutex};

/// Native-only opt-in snapshot captured when the official action succeeds.
/// Legacy outbox entries default to no authorization and are never retro-sent.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ManualResetAuthorization {
    revision: Option<u64>,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ManualResetNotice {
    event_hash: String,
    account_hash: String,
    label: String,
    confirmed_at: i64,
    available: Option<u32>,
}
impl ManualResetNotice {
    /// account_id is the verified native identity key, as in managed quota input.
    pub fn new(
        event_id: &str,
        account_id: &str,
        label: &str,
        confirmed_at: i64,
        available: Option<u32>,
    ) -> Result<Self> {
        if event_id.is_empty()
            || event_id.len() > 512
            || event_id.chars().any(char::is_control)
            || account_id.is_empty()
            || account_id.len() > 512
            || account_id.chars().any(char::is_control)
            || !safe_label(label)
            || confirmed_at <= 0
            || available.is_some_and(|n| n > 1_000_000)
        {
            return fail("invalid_manual_reset_notice");
        }
        let account_hash = super::hash(account_id.as_bytes());
        Ok(Self {
            event_hash: super::hash(format!("{account_hash}:manual-reset:{event_id}").as_bytes()),
            account_hash,
            label: label.into(),
            confirmed_at,
            available,
        })
    }
    fn valid(&self) -> bool {
        super::valid_hash(&self.event_hash)
            && super::valid_hash(&self.account_hash)
            && safe_label(&self.label)
            && self.confirmed_at > 0
            && self.available.is_none_or(|n| n <= 1_000_000)
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ManualResetRecord {
    notice: ManualResetNotice,
    revision: Option<u64>,
    last_attempt_at: Option<i64>,
}
impl ManualResetRecord {
    pub(crate) fn valid(&self, key: &str) -> bool {
        self.notice.valid()
            && self.notice.event_hash == key
            && self
                .last_attempt_at
                .is_none_or(|t| t >= self.notice.confirmed_at)
    }
    fn event(&self, now: i64) -> Result<NotificationEvent> {
        let mut event = NotificationEvent::new(
            &self.notice.event_hash,
            Some(&self.notice.label),
            EventBody::ManualReset {
                event_hash: self.notice.event_hash.clone(),
                confirmed_at: self.notice.confirmed_at,
                available: self.notice.available,
            },
            now,
        )?;
        event.expected_channel_revision = self.revision;
        Ok(event)
    }
    fn delivery_key(&self) -> String {
        let event_key = super::hash(self.notice.event_hash.as_bytes());
        super::hash(format!("feishu:{event_key}").as_bytes())
    }
}

pub(crate) fn current(v: &Vault, event: &NotificationEvent) -> bool {
    let EventBody::ManualReset {
        event_hash,
        confirmed_at,
        available,
    } = &event.body
    else {
        return true;
    };
    v.manual_resets.get(event_hash).is_some_and(|r| {
        r.revision.is_some()
            && r.revision == event.expected_channel_revision
            && r.notice.confirmed_at == *confirmed_at
            && r.notice.available == *available
            && event.account.as_deref() == Some(&r.notice.label)
    })
}
pub(crate) fn mark_attempt(v: &mut Vault, event_hash: &str, at: i64) -> Result<()> {
    let record = v
        .manual_resets
        .get_mut(event_hash)
        .ok_or(Failure("manual_reset_notice_missing"))?;
    record.last_attempt_at = Some(at);
    Ok(())
}
pub(crate) fn explains_decrease(
    v: &Vault,
    account: &str,
    before: u32,
    after: u32,
    previous_at: i64,
    observed_at: i64,
) -> bool {
    if before.checked_sub(1) != Some(after) {
        return false;
    }
    let mut matches = v.manual_resets.values().filter(|r| {
        r.revision.is_some_and(|revision| {
            v.configs
                .get(&ChannelKind::Feishu)
                .is_some_and(|c| c.enabled && c.revision == revision)
        }) && r.notice.account_hash == account
            && r.notice.confirmed_at > previous_at
            && r.notice.confirmed_at <= observed_at
            && r.notice.available.is_none_or(|n| n == after)
    });
    matches.next().is_some() && matches.next().is_none()
}

impl NotificationService {
    pub fn manual_reset_authorization(&self) -> Result<ManualResetAuthorization> {
        if self.exiting.load(std::sync::atomic::Ordering::Acquire) {
            return fail("notification_exiting");
        }
        self.storage.read(|v| {
            Ok(ManualResetAuthorization {
                revision: v
                    .configs
                    .get(&ChannelKind::Feishu)
                    .filter(|c| c.enabled)
                    .map(|c| c.revision),
            })
        })
    }
    /// Durable queue intent is captured only for the existing enabled Feishu revision.
    /// Idempotent success permits the native action journal to acknowledge consumption.
    pub fn record_manual_reset(&self, notice: ManualResetNotice) -> Result<()> {
        self.record_manual_reset_authorized(notice, self.manual_reset_authorization()?)
    }
    pub fn record_manual_reset_authorized(
        &self,
        notice: ManualResetNotice,
        authorization: ManualResetAuthorization,
    ) -> Result<()> {
        if !notice.valid() || notice.confirmed_at > super::now() {
            return fail("invalid_manual_reset_notice");
        }
        if self.exiting.load(std::sync::atomic::Ordering::Acquire) {
            return fail("notification_exiting");
        }
        self.storage.change(|v| {
            if let Some(old) = v.manual_resets.get(&notice.event_hash) {
                return if old.notice == notice {
                    Ok(())
                } else {
                    fail("manual_reset_notice_changed")
                };
            }
            if v.manual_resets.len() >= 4096 {
                return fail("notification_store_capacity");
            }
            let revision = v
                .configs
                .get(&ChannelKind::Feishu)
                .filter(|c| c.enabled && authorization.revision == Some(c.revision))
                .map(|c| c.revision);
            v.manual_resets.insert(
                notice.event_hash.clone(),
                ManualResetRecord {
                    notice,
                    revision,
                    last_attempt_at: None,
                },
            );
            let redundant = v
                .card_changes
                .iter()
                .filter(|(_, c)| {
                    c.channel == ChannelKind::Feishu
                        && explains_decrease(
                            v,
                            &c.account_hash,
                            c.previous,
                            c.available,
                            c.previous_at,
                            c.observed_at,
                        )
                })
                .map(|(key, _)| key.clone())
                .collect::<Vec<_>>();
            for key in redundant {
                v.card_changes.remove(&key);
            }
            Ok(())
        })?;
        self.wake.1.notify_all();
        Ok(())
    }
    pub fn drain_manual_resets(self: &Arc<Self>) -> Result<Vec<DeliveryReceipt>> {
        self.drain_manual_resets_controlled(None)
    }
    pub(crate) fn drain_manual_resets_controlled(
        self: &Arc<Self>,
        control: Option<(&AtomicBool, &Mutex<Option<Arc<AtomicBool>>>)>,
    ) -> Result<Vec<DeliveryReceipt>> {
        let candidates = self.storage.read(|v| {
            let now = super::now();
            let mut pending = v
                .manual_resets
                .values()
                .filter(|r| {
                    r.revision.is_some_and(|revision| {
                        v.configs
                            .get(&ChannelKind::Feishu)
                            .is_some_and(|c| c.enabled && c.revision == revision)
                    }) && r.notice.confirmed_at <= now
                        && r.last_attempt_at.is_none_or(|at| now - at >= 300)
                        && v.deliveries
                            .get(&r.delivery_key())
                            .is_none_or(|d| d.phase == Phase::Pending)
                })
                .collect::<Vec<_>>();
            pending.sort_by_key(|r| r.notice.confirmed_at);
            pending
                .into_iter()
                .take(20)
                .map(|r| r.event(now))
                .collect::<Result<Vec<_>>>()
        })?;
        let mut receipts = Vec::new();
        for event in candidates {
            receipts.push(
                self.send_event_to_controlled(ChannelKind::Feishu, &event, control)
                    .unwrap_or_else(|e| DeliveryReceipt {
                        channel: ChannelKind::Feishu,
                        event_id: event.key,
                        state: "not_sent",
                        checked_at: super::now(),
                        remote_message_id: None,
                        failure_code: Some(e.0),
                    }),
            );
        }
        Ok(receipts)
    }
}
