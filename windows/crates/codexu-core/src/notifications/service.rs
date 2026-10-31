use super::{
    domain::*,
    events, fail,
    personal::*,
    protocol::{self, Accepted},
    storage::*,
    transport::*,
    Failure, Result,
};
use crate::accounts::{DpapiProtector, SecretProtector};
use std::{
    collections::{BTreeMap, VecDeque},
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicU8, Ordering},
        Arc, Mutex,
    },
};

#[path = "manual_text.rs"]
mod manual_text;
pub use manual_text::PersonalTextReceipt;

pub struct NotificationService {
    pub(crate) storage: Storage,
    pub(crate) transport: Arc<dyn NotificationTransport>,
    pub(crate) state: Mutex<RuntimeState>,
    pub(crate) exiting: AtomicBool,
    pub(crate) public_runtime: super::public_reset::Runtime,
    monitor_active: Arc<AtomicBool>,
    pending: Mutex<Pending>,
    pub(crate) wake: Arc<(Mutex<()>, std::sync::Condvar)>,
    queue_failure: AtomicU8,
    pub(crate) personal_text_active: AtomicBool,
}
#[derive(Default)]
struct Pending {
    quotas: BTreeMap<String, events::OfficialQuotaObservation>,
    events: VecDeque<NotificationEvent>,
}
enum Queued {
    Quota(events::OfficialQuotaObservation),
    Event(NotificationEvent),
}

#[cfg(test)]
mod tests {
    use super::*;
    struct SyntheticProtector;
    struct SystemTransport {
        allowed: AtomicBool,
        uncertain: bool,
        calls: std::sync::atomic::AtomicUsize,
    }
    impl NotificationTransport for SystemTransport {
        fn system_permission(&self) -> super::super::SystemNotificationPermission {
            if self.allowed.load(Ordering::Acquire) {
                super::super::SystemNotificationPermission::Enabled
            } else {
                super::super::SystemNotificationPermission::DisabledUser
            }
        }
        fn send_system(&self, _: &str, _: &str, cancelled: &AtomicBool) -> Result<()> {
            if cancelled.load(Ordering::Acquire) {
                return fail("cancelled");
            }
            self.calls.fetch_add(1, Ordering::SeqCst);
            if self.uncertain {
                fail("system_notification_submission_failed")
            } else {
                Ok(())
            }
        }
        fn send(&self, _: &TransportRequest, _: &AtomicBool) -> Result<TransportResponse> {
            panic!("a local system notification must never reach HTTP")
        }
    }
    impl SecretProtector for SyntheticProtector {
        fn seal(&self, _: &str, b: &[u8]) -> crate::accounts::AccountResult<Vec<u8>> {
            Ok(b.iter().map(|v| v ^ 0x73).collect())
        }
        fn unseal(&self, _: &str, b: &[u8]) -> crate::accounts::AccountResult<Vec<u8>> {
            Ok(b.iter().map(|v| v ^ 0x73).collect())
        }
    }
    #[test]
    fn system_notifications_require_opt_in_and_actual_permission_and_share_deduplication() {
        let dir = tempfile::tempdir().unwrap();
        let transport = Arc::new(SystemTransport {
            allowed: AtomicBool::new(false),
            uncertain: false,
            calls: Default::default(),
        });
        let service = NotificationService::with_components(
            dir.path().canonicalize().unwrap().join("notifications"),
            Arc::new(SyntheticProtector),
            transport.clone(),
        )
        .unwrap();
        assert!(!service.channel_state(ChannelKind::System).unwrap().enabled);
        assert!(service.send_test(ChannelKind::System).is_err());
        service.set_enabled(ChannelKind::System, true).unwrap();
        assert!(service.send_test(ChannelKind::System).is_err());
        assert_eq!(transport.calls.load(Ordering::SeqCst), 0);
        transport.allowed.store(true, Ordering::Release);
        let event = NotificationEvent::new(
            "synthetic-system-test",
            None,
            EventBody::Test,
            super::super::now(),
        )
        .unwrap();
        assert_eq!(
            service
                .send_event_to(ChannelKind::System, &event)
                .unwrap()
                .state,
            "accepted"
        );
        assert_eq!(
            service
                .send_event_to(ChannelKind::System, &event)
                .unwrap()
                .state,
            "duplicate_skipped"
        );
        assert_eq!(transport.calls.load(Ordering::SeqCst), 1);
        assert!(service
            .save_channel(ChannelKind::System, "invalid".into(), None)
            .is_err());
    }
    #[test]
    fn uncertain_system_submission_never_retries_the_same_event() {
        let dir = tempfile::tempdir().unwrap();
        let transport = Arc::new(SystemTransport {
            allowed: AtomicBool::new(true),
            uncertain: true,
            calls: Default::default(),
        });
        let service = NotificationService::with_components(
            dir.path().canonicalize().unwrap().join("notifications"),
            Arc::new(SyntheticProtector),
            transport.clone(),
        )
        .unwrap();
        service.set_enabled(ChannelKind::System, true).unwrap();
        let event = NotificationEvent::new(
            "synthetic-system-uncertain",
            None,
            EventBody::Test,
            super::super::now(),
        )
        .unwrap();
        assert_eq!(
            service
                .send_event_to(ChannelKind::System, &event)
                .unwrap()
                .state,
            "uncertain"
        );
        assert_eq!(
            service
                .send_event_to(ChannelKind::System, &event)
                .unwrap()
                .state,
            "duplicate_skipped"
        );
        assert_eq!(transport.calls.load(Ordering::SeqCst), 1);
    }
    #[test]
    fn operation_drop_during_state_lock_cannot_leak_inflight_or_capacity() {
        let dir = tempfile::tempdir().unwrap();
        let service = NotificationService::with_components(
            dir.path().canonicalize().unwrap().join("notifications"),
            Arc::new(SyntheticProtector),
            Arc::new(NativeNotificationTransport),
        )
        .unwrap();
        service.set_enabled(ChannelKind::WeCom, true).unwrap();
        for _ in 0..12 {
            let (op, _) = service.operation(ChannelKind::WeCom).unwrap();
            let held = service.state.lock().unwrap();
            drop(op);
            drop(held);
            assert!(!service.has_inflight_operation());
        }
    }
    #[test]
    fn old_session_expiry_cannot_cancel_a_new_configuration_operation() {
        let dir = tempfile::tempdir().unwrap();
        let service = NotificationService::with_components(
            dir.path().canonicalize().unwrap().join("notifications"),
            Arc::new(SyntheticProtector),
            Arc::new(NativeNotificationTransport),
        )
        .unwrap();
        let old = service
            .set_enabled(ChannelKind::PersonalWeChat, true)
            .unwrap()
            .revision;
        service
            .set_enabled(ChannelKind::PersonalWeChat, true)
            .unwrap();
        let (current, _) = service.operation(ChannelKind::PersonalWeChat).unwrap();
        assert_eq!(
            service.expire_personal_session(old).unwrap_err().code(),
            "configuration_changed"
        );
        assert!(!current.cancelled.load(Ordering::Acquire));
        assert_ne!(
            service
                .channel_state(ChannelKind::PersonalWeChat)
                .unwrap()
                .phase,
            "session_expired"
        );
    }
}
#[derive(Default)]
pub(crate) struct RuntimeState {
    operations: BTreeMap<ChannelKind, Vec<(Arc<AtomicBool>, Arc<AtomicBool>)>>,
    verified: BTreeMap<ChannelKind, (u64, i64)>,
    pub login: Option<LoginAttempt>,
    failure: Option<&'static str>,
    failures: BTreeMap<ChannelKind, &'static str>,
    public_operations: Vec<(Arc<AtomicBool>, Arc<AtomicBool>)>,
}
pub(crate) struct Operation {
    service: Arc<NotificationService>,
    pub id: String,
    pub cancelled: Arc<AtomicBool>,
    pub revision: u64,
    pub kind: ChannelKind,
    completed: Arc<AtomicBool>,
}
impl Drop for Operation {
    fn drop(&mut self) {
        // No lock/wait in Drop. Admission lazily prunes completed entries and
        // exit checks read the flag, so mutex contention cannot leak an actor.
        self.completed.store(true, Ordering::Release);
    }
}
impl Operation {
    pub fn current(&self) -> Result<()> {
        if self.cancelled.load(Ordering::Acquire) || self.service.exiting.load(Ordering::Acquire) {
            return fail("cancelled");
        }
        self.service.storage.read(|v| {
            if v.configs
                .get(&self.kind)
                .is_some_and(|c| c.enabled && c.revision == self.revision)
            {
                Ok(())
            } else {
                fail("configuration_changed")
            }
        })
    }
}

/// Root retains this native-only handle. Cancellation never waits for network
/// or a mutex; an already admitted WinHTTP call returns within its own bound.
pub struct NotificationMonitor {
    stop: Arc<AtomicBool>,
    active: Arc<Mutex<Option<Arc<AtomicBool>>>>,
    wake: Arc<(Mutex<()>, std::sync::Condvar)>,
    handle: Option<std::thread::JoinHandle<()>>,
}
impl NotificationMonitor {
    pub fn cancel(&self) {
        self.stop.store(true, Ordering::Release);
        if let Ok(active) = self.active.try_lock() {
            if let Some(cancel) = active.as_ref() {
                cancel.store(true, Ordering::Release);
            }
        }
        self.wake.1.notify_all();
    }
    pub fn is_finished(&self) -> bool {
        self.handle.as_ref().is_none_or(|h| h.is_finished())
    }
}
impl Drop for NotificationMonitor {
    fn drop(&mut self) {
        self.cancel();
    }
}

impl NotificationService {
    pub fn start_monitor(self: &Arc<Self>) -> Result<NotificationMonitor> {
        self.start_monitor_with_listener(Arc::new(|| {}))
    }
    /// Empty native change signal only; no credential/message body is passed.
    pub fn start_monitor_with_listener(
        self: &Arc<Self>,
        changed: Arc<dyn Fn() + Send + Sync>,
    ) -> Result<NotificationMonitor> {
        if self.exiting.load(Ordering::Acquire) {
            return fail("notification_exiting");
        }
        if self
            .monitor_active
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return fail("notification_monitor_active");
        }
        let stop = Arc::new(AtomicBool::new(false));
        let active = Arc::new(Mutex::new(None));
        let wake = self.wake.clone();
        let weak = Arc::downgrade(self);
        let cancelled = stop.clone();
        let poll = active.clone();
        let signal = wake.clone();
        let running = self.monitor_active.clone();
        let spawned = std::thread::Builder::new()
            .name("notification-context".into())
            .spawn(move || {
                let mut failures = 0u32;
                while !cancelled.load(Ordering::Acquire) {
                    let Some(service) = weak.upgrade() else { break };
                    if service.exiting.load(Ordering::Acquire) {
                        break;
                    }
                    let queued = service.pending.try_lock().ok().and_then(|mut q| {
                        q.events
                            .pop_front()
                            .map(Queued::Event)
                            .or_else(|| q.quotas.pop_first().map(|(_, o)| Queued::Quota(o)))
                    });
                    match service.drain_manual_resets_controlled(Some((&cancelled, &poll))) {
                        Ok(receipts) if !receipts.is_empty() => changed(),
                        Err(e) => service.record_failure(e.0),
                        _ => (),
                    }
                    if let Some(queued) = queued {
                        let events = match queued {
                            Queued::Event(e) => Ok(vec![e]),
                            Queued::Quota(o) => service
                                .storage
                                .change(|v| events::observe(v, o, super::now(), (5.0, 10.0))),
                        };
                        match events {
                            Ok(events) => {
                                for event in events {
                                    if cancelled.load(Ordering::Acquire) {
                                        break;
                                    }
                                    if matches!(event.body, EventBody::CardsChanged { .. }) {
                                        continue;
                                    }
                                    if let Err(e) = service
                                        .dispatch_controlled(&event, Some((&cancelled, &poll)))
                                    {
                                        service.record_failure(e.0);
                                    }
                                }
                            }
                            Err(e) => service.record_failure(e.0),
                        }
                        if let Ok(mut current) = poll.lock() {
                            *current = None;
                        }
                        if let Err(e) =
                            service.drain_card_changes_controlled(Some((&cancelled, &poll)))
                        {
                            service.record_failure(e.0);
                        }
                        changed();
                        continue;
                    }
                    match service.drain_card_changes_controlled(Some((&cancelled, &poll))) {
                        Ok(receipts) if !receipts.is_empty() => changed(),
                        Err(e) => service.record_failure(e.0),
                        _ => (),
                    }
                    match service.public_reset_tick(Some((&cancelled, &poll))) {
                        Ok(true) | Err(_) => changed(),
                        _ => (),
                    }
                    let bound = service.storage.read(|v| {
                        Ok(v.configs
                            .get(&ChannelKind::PersonalWeChat)
                            .is_some_and(|c| {
                                c.enabled
                                    && c.secret.is_some()
                                    && c.binding.is_some()
                                    && !c.session_expired
                            }))
                    });
                    let delay = if matches!(bound, Ok(true)) {
                        let result =
                            service.refresh_personal_wechat_context_owned(&cancelled, &poll);
                        changed();
                        if let Ok(mut current) = poll.lock() {
                            *current = None;
                        }
                        if result.is_ok() {
                            failures = 0;
                            2
                        } else {
                            if let Err(e) = result {
                                service.record_failure(e.0);
                            }
                            failures = failures.saturating_add(1);
                            (2u64.saturating_pow(failures.min(5))).min(60)
                        }
                    } else {
                        2
                    };
                    drop(service);
                    if cancelled.load(Ordering::Acquire) {
                        break;
                    }
                    let Ok(lock) = signal.0.lock() else { break };
                    let _ = signal
                        .1
                        .wait_timeout(lock, std::time::Duration::from_secs(delay));
                }
                running.store(false, Ordering::Release);
            });
        match spawned {
            Ok(handle) => Ok(NotificationMonitor {
                stop,
                active,
                wake,
                handle: Some(handle),
            }),
            Err(_) => {
                self.monitor_active.store(false, Ordering::Release);
                fail("notification_monitor_unavailable")
            }
        }
    }
    pub fn native(app_data: PathBuf) -> Result<Arc<Self>> {
        if !cfg!(windows) {
            return fail("windows_required");
        }
        Self::with_components_and_public_source(
            app_data.join("notifications-v1"),
            Arc::new(DpapiProtector),
            Arc::new(NativeNotificationTransport),
            Arc::new(super::NativePublicResetSource),
        )
    }
    pub fn with_components(
        root: PathBuf,
        protector: Arc<dyn SecretProtector>,
        transport: Arc<dyn NotificationTransport>,
    ) -> Result<Arc<Self>> {
        let storage = Storage::new(root, protector)?;
        Ok(Arc::new(Self {
            storage,
            transport,
            state: Mutex::new(RuntimeState::default()),
            exiting: AtomicBool::new(false),
            public_runtime: Default::default(),
            monitor_active: Arc::new(AtomicBool::new(false)),
            pending: Mutex::new(Pending::default()),
            wake: Arc::new((Mutex::new(()), std::sync::Condvar::new())),
            queue_failure: AtomicU8::new(0),
            personal_text_active: AtomicBool::new(false),
        }))
    }
    pub fn states(&self) -> Result<Vec<ChannelState>> {
        ChannelKind::ALL
            .into_iter()
            .map(|k| self.channel_state(k))
            .collect()
    }
    pub fn system_permission(&self) -> super::SystemNotificationPermission {
        self.transport.system_permission()
    }
    pub fn with_components_and_public_source(
        root: PathBuf,
        protector: Arc<dyn SecretProtector>,
        transport: Arc<dyn NotificationTransport>,
        source: Arc<dyn super::PublicResetSource>,
    ) -> Result<Arc<Self>> {
        let s = Self::with_components(root, protector, transport)?;
        *s.public_runtime
            .source
            .write()
            .map_err(|_| Failure("public_reset_source_unavailable"))? = source;
        Ok(s)
    }
    pub(crate) fn cancel_public_sends(&self) {
        self.public_runtime.cancel();
        if let Ok(state) = self.state.try_lock() {
            for (c, _) in &state.public_operations {
                c.store(true, Ordering::Release);
            }
        }
    }
    pub fn channel_state(&self, kind: ChannelKind) -> Result<ChannelState> {
        let state = self
            .state
            .lock()
            .map_err(|_| Failure("notification_busy"))?;
        self.storage.read(|v| {
            let c = v.configs.get(&kind).cloned().unwrap_or_default();
            let accepted = state
                .verified
                .get(&kind)
                .filter(|(rev, _)| *rev == c.revision)
                .map(|(_, at)| *at);
            let phase = if !c.enabled {
                "disabled"
            } else if c.session_expired {
                "session_expired"
            } else if c.secret.is_none() && kind != ChannelKind::System {
                "needs_setup"
            } else if kind == ChannelKind::PersonalWeChat
                && c.binding.as_ref().is_none_or(|b| b.context_token.is_none())
            {
                "context_required"
            } else if accepted.is_some() {
                "ready"
            } else {
                "pending_verification"
            };
            Ok(ChannelState {
                channel: kind,
                enabled: c.enabled,
                phase,
                revision: c.revision,
                credential_present: c.secret.is_some(),
                target_present: c.target.is_some(),
                last_accepted_at: accepted,
                failure_code: if c.session_expired {
                    Some("wechat_session_expired")
                } else {
                    state
                        .failures
                        .get(&kind)
                        .copied()
                        .or(state.failure)
                        .or_else(|| match self.queue_failure.load(Ordering::Acquire) {
                            1 => Some("notification_queue_busy"),
                            2 => Some("notification_queue_capacity"),
                            3 => Some("invalid_official_observation"),
                            _ => None,
                        })
                },
                options: c.options,
            })
        })
    }
    /// Enable/disable never implicitly verifies or sends a message.
    pub fn set_enabled(&self, kind: ChannelKind, enabled: bool) -> Result<ChannelState> {
        self.mutate_config(kind, |c| {
            c.enabled = enabled;
            Ok(())
        })?;
        self.channel_state(kind)
    }
    pub fn save_channel(
        &self,
        kind: ChannelKind,
        secret: String,
        target: Option<String>,
    ) -> Result<ChannelState> {
        if kind == ChannelKind::System {
            return fail("system_notification_has_no_credentials");
        }
        if kind == ChannelKind::PersonalWeChat {
            return fail("wechat_qr_login_required");
        }
        let secret = secret.trim().to_owned();
        let target = target.map(|s| s.trim().to_owned());
        protocol::validate_credential(kind, &secret, target.as_deref(), None)?;
        self.mutate_config(kind, |c| {
            c.secret = Some(secret);
            c.target = target;
            c.binding = None;
            Ok(())
        })?;
        self.channel_state(kind)
    }
    pub fn set_options(&self, kind: ChannelKind, options: MessageOptions) -> Result<ChannelState> {
        if matches!(kind, ChannelKind::WeCom | ChannelKind::PersonalWeChat) {
            if self.exiting.load(Ordering::Acquire) {
                return fail("notification_exiting");
            }
            let mut state = self
                .state
                .lock()
                .map_err(|_| Failure("notification_busy"))?;
            self.storage.change(|v| {
                for shared in [ChannelKind::WeCom, ChannelKind::PersonalWeChat] {
                    let c = v.configs.entry(shared).or_default();
                    c.options = options.clone();
                    c.revision = c
                        .revision
                        .checked_add(1)
                        .ok_or(Failure("notification_store_invalid"))?;
                }
                Ok(())
            })?;
            for shared in [ChannelKind::WeCom, ChannelKind::PersonalWeChat] {
                if let Some(ops) = state.operations.get(&shared) {
                    for (cancel, _) in ops {
                        cancel.store(true, Ordering::Release);
                    }
                }
                state.verified.remove(&shared);
                state.failures.remove(&shared);
            }
            state.login = None;
            drop(state);
            return self.channel_state(kind);
        }
        self.mutate_config(kind, |c| {
            c.options = options;
            Ok(())
        })?;
        self.channel_state(kind)
    }
    pub fn forget_channel(&self, kind: ChannelKind) -> Result<ChannelState> {
        self.mutate_config(kind, |c| {
            c.enabled = false;
            c.secret = None;
            c.target = None;
            c.binding = None;
            c.session_expired = false;
            Ok(())
        })?;
        self.channel_state(kind)
    }
    pub(crate) fn expire_personal_session(&self, revision: u64) -> Result<()> {
        if self.exiting.load(Ordering::Acquire) {
            return fail("notification_exiting");
        }
        let kind = ChannelKind::PersonalWeChat;
        let mut state = self
            .state
            .lock()
            .map_err(|_| Failure("notification_busy"))?;
        self.storage.change(|v| {
            let c = v
                .configs
                .get_mut(&kind)
                .filter(|c| c.enabled && c.revision == revision)
                .ok_or(Failure("configuration_changed"))?;
            c.session_expired = true;
            c.revision = c
                .revision
                .checked_add(1)
                .ok_or(Failure("notification_store_invalid"))?;
            Ok(())
        })?;
        // A late old-session error must not revoke a newer scan/configuration.
        if let Some(ops) = state.operations.get(&kind) {
            for (cancel, _) in ops {
                cancel.store(true, Ordering::Release);
            }
        }
        state.verified.remove(&kind);
        state.login = None;
        Ok(())
    }
    fn mutate_config(
        &self,
        kind: ChannelKind,
        f: impl FnOnce(&mut ChannelConfig) -> Result<()>,
    ) -> Result<()> {
        if self.exiting.load(Ordering::Acquire) {
            return fail("notification_exiting");
        }
        let mut state = self
            .state
            .lock()
            .map_err(|_| Failure("notification_busy"))?;
        if let Some(ops) = state.operations.get(&kind) {
            for (cancel, _) in ops {
                cancel.store(true, Ordering::Release);
            }
        }
        state.verified.remove(&kind);
        state.failures.remove(&kind);
        if kind == ChannelKind::PersonalWeChat {
            state.login = None;
        }
        self.storage.change(|v| {
            let c = v.configs.entry(kind).or_default();
            f(c)?;
            c.revision = c
                .revision
                .checked_add(1)
                .ok_or(Failure("notification_store_invalid"))?;
            Ok(())
        })
    }
    pub fn cancel_channel(&self, kind: ChannelKind) -> Result<ChannelState> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| Failure("notification_busy"))?;
        if let Some(ops) = state.operations.get(&kind) {
            for (cancel, _) in ops {
                cancel.store(true, Ordering::Release);
            }
        }
        if kind == ChannelKind::PersonalWeChat {
            if let Some(login) = state.login.as_mut() {
                login.phase = "cancelled";
                login.reference.clear();
                login.qr.clear();
            }
        }
        drop(state);
        self.channel_state(kind)
    }
    pub fn restore_saved_connections(&self) -> Result<Vec<ChannelState>> {
        self.states()
    }
    /// No I/O, no wait and no new work during application exit.
    pub fn cancel_inflight_for_exit(&self) {
        self.exiting.store(true, Ordering::Release);
        self.public_runtime.cancel();
        if let Ok(mut state) = self.state.try_lock() {
            for ops in state.operations.values() {
                for (cancel, _) in ops {
                    cancel.store(true, Ordering::Release);
                }
            }
            if let Some(login) = state.login.as_mut() {
                login.phase = "cancelled";
                login.reference.clear();
                login.qr.clear();
            }
        }
    }
    pub fn has_inflight_operation(&self) -> bool {
        self.public_runtime.checking.load(Ordering::Acquire)
            || self
                .state
                .try_lock()
                .map(|s| {
                    s.operations
                        .values()
                        .any(|v| v.iter().any(|(_, done)| !done.load(Ordering::Acquire)))
                })
                .unwrap_or(true)
    }
    pub(crate) fn operation(
        self: &Arc<Self>,
        kind: ChannelKind,
    ) -> Result<(Operation, ChannelConfig)> {
        if self.exiting.load(Ordering::Acquire) {
            return fail("notification_exiting");
        }
        let mut state = self
            .state
            .lock()
            .map_err(|_| Failure("notification_busy"))?;
        let c = self
            .storage
            .read(|v| Ok(v.configs.get(&kind).cloned().unwrap_or_default()))?;
        if !c.enabled {
            return fail("channel_disabled");
        }
        let ops = state.operations.entry(kind).or_default();
        ops.retain(|(_, done)| !done.load(Ordering::Acquire));
        if ops.len() >= 4 {
            return fail("notification_busy");
        }
        let id = super::nonce()?;
        let cancelled = Arc::new(AtomicBool::new(false));
        let completed = Arc::new(AtomicBool::new(false));
        ops.push((cancelled.clone(), completed.clone()));
        Ok((
            Operation {
                service: self.clone(),
                id,
                cancelled,
                revision: c.revision,
                kind,
                completed,
            },
            c,
        ))
    }
    pub fn send_test(self: &Arc<Self>, kind: ChannelKind) -> Result<DeliveryReceipt> {
        let event = NotificationEvent::new(&super::nonce()?, None, EventBody::Test, super::now())?;
        self.send_event_to(kind, &event)
    }
    pub fn dispatch(self: &Arc<Self>, event: &NotificationEvent) -> Result<Vec<DeliveryReceipt>> {
        self.dispatch_controlled(event, None)
    }
    fn dispatch_controlled(
        self: &Arc<Self>,
        event: &NotificationEvent,
        control: Option<(&AtomicBool, &Mutex<Option<Arc<AtomicBool>>>)>,
    ) -> Result<Vec<DeliveryReceipt>> {
        if !event.current(super::now()) {
            return fail("stale_notification");
        }
        let kinds = self.storage.read(|v| {
            Ok(v.configs
                .iter()
                .filter(|(kind, c)| {
                    c.enabled
                        && (!matches!(event.body, EventBody::ManualReset { .. })
                            || **kind == ChannelKind::Feishu)
                        && (!matches!(event.body, EventBody::CardsChanged { .. })
                            || v.card_changes.contains_key(&super::hash(
                                format!("{}:{}", kind.id(), event.key).as_bytes(),
                            )))
                })
                .map(|(k, _)| *k)
                .collect::<Vec<_>>())
        })?;
        let mut results = Vec::new();
        for kind in kinds {
            let result = self.send_event_to_controlled(kind, event, control);
            results.push(result.unwrap_or_else(|e| DeliveryReceipt {
                channel: kind,
                event_id: event.key.clone(),
                state: "not_sent",
                checked_at: super::now(),
                remote_message_id: None,
                failure_code: Some(e.0),
            }));
        }
        Ok(results)
    }
    fn record_failure(&self, code: &'static str) {
        if let Ok(mut state) = self.state.lock() {
            state.failure = Some(code);
        }
    }
    /// No disk, transport, thread spawn or credential retention on this path.
    /// The current catalogue admits at most 64 managed identities.
    pub fn queue_managed_quota(
        &self,
        label: &str,
        snapshot: &crate::accounts::VerifiedCredentialSnapshot,
    ) -> Result<()> {
        match events::OfficialQuotaObservation::from_managed_snapshot(label, snapshot) {
            Ok(o) => self.queue_official_quota(o),
            Err(e) => {
                self.queue_failure.store(3, Ordering::Release);
                Err(e)
            }
        }
    }
    pub fn queue_official_quota(
        &self,
        mut observation: events::OfficialQuotaObservation,
    ) -> Result<()> {
        if self.exiting.load(Ordering::Acquire) {
            return fail("notification_exiting");
        }
        let mut queue = self.pending.try_lock().map_err(|_| {
            self.queue_failure.store(1, Ordering::Release);
            Failure("notification_queue_busy")
        })?;
        if let Some(old) = queue.quotas.get(&observation.account_hash) {
            if old.value.observed_at > observation.value.observed_at {
                return Ok(());
            }
            if old.value.observed_at == observation.value.observed_at
                && old.value != observation.value
            {
                observation.value.verified = false;
            }
        }
        if queue.quotas.len() >= 64 && !queue.quotas.contains_key(&observation.account_hash) {
            self.queue_failure.store(2, Ordering::Release);
            return fail("notification_queue_capacity");
        }
        queue
            .quotas
            .insert(observation.account_hash.clone(), observation);
        self.wake.1.notify_all();
        Ok(())
    }
    pub fn queue_event(&self, event: NotificationEvent) -> Result<()> {
        if self.exiting.load(Ordering::Acquire) {
            return fail("notification_exiting");
        }
        if !event.current(super::now()) {
            return fail("stale_notification");
        }
        let mut queue = self.pending.try_lock().map_err(|_| {
            self.queue_failure.store(1, Ordering::Release);
            Failure("notification_queue_busy")
        })?;
        if queue.events.iter().any(|e| e.key == event.key) {
            return Ok(());
        }
        if queue.events.len() >= 64 {
            self.queue_failure.store(2, Ordering::Release);
            return fail("notification_queue_capacity");
        }
        queue.events.push_back(event);
        self.wake.1.notify_all();
        Ok(())
    }
    pub fn observe_official_quota(
        self: &Arc<Self>,
        observation: events::OfficialQuotaObservation,
    ) -> Result<Vec<DeliveryReceipt>> {
        self.observe_official_quota_with_thresholds(observation, 5.0, 10.0)
    }
    pub fn observe_managed_quota(
        self: &Arc<Self>,
        label: &str,
        snapshot: &crate::accounts::VerifiedCredentialSnapshot,
    ) -> Result<Vec<DeliveryReceipt>> {
        self.observe_official_quota(events::OfficialQuotaObservation::from_managed_snapshot(
            label, snapshot,
        )?)
    }
    pub fn observe_official_quota_with_thresholds(
        self: &Arc<Self>,
        observation: events::OfficialQuotaObservation,
        five_hour: f64,
        seven_day: f64,
    ) -> Result<Vec<DeliveryReceipt>> {
        if !five_hour.is_finite()
            || !seven_day.is_finite()
            || !(1.0..=100.0).contains(&five_hour)
            || !(1.0..=100.0).contains(&seven_day)
        {
            return fail("invalid_quota_threshold");
        }
        let now = super::now();
        let events = self
            .storage
            .change(|v| events::observe(v, observation, now, (five_hour, seven_day)))?;
        let mut receipts = Vec::new();
        for event in events {
            if matches!(event.body, EventBody::CardsChanged { .. }) {
                continue;
            }
            receipts.extend(self.dispatch(&event)?);
        }
        receipts.extend(self.drain_card_changes()?);
        Ok(receipts)
    }
    /// Worker-only durable retry path. A pending count change is rebound only
    /// to fresh official evidence with that same current end count. It never
    /// uses the age of a persisted observation as evidence of freshness.
    pub fn drain_card_changes(self: &Arc<Self>) -> Result<Vec<DeliveryReceipt>> {
        self.drain_card_changes_controlled(None)
    }
    fn drain_card_changes_controlled(
        self: &Arc<Self>,
        control: Option<(&AtomicBool, &Mutex<Option<Arc<AtomicBool>>>)>,
    ) -> Result<Vec<DeliveryReceipt>> {
        let candidates = self.storage.read(|v| {
            let now = super::now();
            let mut pending = Vec::new();
            for (key, c) in &v.card_changes {
                let Some(b) = v.baselines.get(&c.account_hash).filter(|b| {
                    b.verified
                        && b.available == Some(c.available)
                        && b.observed_at >= c.observed_at
                        && b.observed_at <= now
                        && now - b.observed_at <= 300
                }) else {
                    continue;
                };
                if !v.configs.get(&c.channel).is_some_and(|cfg| cfg.enabled)
                    || v.deliveries
                        .get(key)
                        .is_some_and(|d| d.phase != Phase::Pending)
                    || c.last_attempt_at
                        .is_some_and(|at| now - at < 300 && b.observed_at <= at)
                {
                    continue;
                }
                pending.push((c.observed_at, c.channel, c.event(b.observed_at)?));
            }
            pending.sort_by_key(|(at, kind, _)| (*at, *kind));
            Ok(pending.into_iter().take(20).collect::<Vec<_>>())
        })?;
        let mut receipts = Vec::new();
        for (_, kind, event) in candidates {
            receipts.push(
                self.send_event_to_controlled(kind, &event, control)
                    .unwrap_or_else(|e| DeliveryReceipt {
                        channel: kind,
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
    fn event_current(v: &Vault, event: &NotificationEvent, now: i64) -> bool {
        event.current(now)
            && super::manual_reset::current(v, event)
            && event
                .public_revision
                .is_none_or(|rev| v.public_reset.enabled && v.public_reset.revision == rev)
            && event.proof.as_ref().is_none_or(|(id, at)| {
                v.baselines
                    .get(id)
                    .is_some_and(|b| b.verified && b.observed_at == *at)
            })
    }
    pub fn send_event_to(
        self: &Arc<Self>,
        kind: ChannelKind,
        event: &NotificationEvent,
    ) -> Result<DeliveryReceipt> {
        self.send_event_to_controlled(kind, event, None)
    }
    pub(crate) fn send_event_to_controlled(
        self: &Arc<Self>,
        kind: ChannelKind,
        event: &NotificationEvent,
        control: Option<(&AtomicBool, &Mutex<Option<Arc<AtomicBool>>>)>,
    ) -> Result<DeliveryReceipt> {
        if matches!(event.body, EventBody::ManualReset { .. }) && kind != ChannelKind::Feishu {
            return fail("notification_filtered");
        }
        let (op, c) = self.operation(kind)?;
        if event
            .expected_channel_revision
            .is_some_and(|revision| revision != c.revision)
        {
            return fail("configuration_changed");
        }
        if event.public_revision.is_some() {
            let mut state = self
                .state
                .lock()
                .map_err(|_| Failure("notification_busy"))?;
            state
                .public_operations
                .retain(|(_, done)| !done.load(Ordering::Acquire));
            state
                .public_operations
                .push((op.cancelled.clone(), op.completed.clone()));
        }
        if let Some((stop, active)) = control {
            *active.lock().map_err(|_| Failure("notification_busy"))? = Some(op.cancelled.clone());
            if stop.load(Ordering::Acquire) {
                op.cancelled.store(true, Ordering::Release);
                return fail("cancelled");
            }
        }
        if c.session_expired {
            return fail("wechat_session_expired");
        }
        let mut filtered = event.clone();
        if let EventBody::QuotaReset { five, seven } = &mut filtered.body {
            *five &= c.options.notifies_five_hour_reset;
            *seven &= c.options.notifies_seven_day_reset;
            if !*five && !*seven {
                return fail("notification_filtered");
            }
        }
        if let Some(items) = &event.expiry_items {
            let remaining = self.storage.read(|v| {
                Ok(items
                    .iter()
                    .filter(|(key, _)| {
                        let key = super::hash(format!("{}:{key}", kind.id()).as_bytes());
                        v.deliveries
                            .get(&key)
                            .is_none_or(|d| d.phase == Phase::Pending)
                    })
                    .cloned()
                    .collect::<Vec<_>>())
            })?;
            if remaining.is_empty() {
                return Ok(DeliveryReceipt {
                    channel: kind,
                    event_id: event.key.clone(),
                    state: "duplicate_skipped",
                    checked_at: super::now(),
                    remote_message_id: None,
                    failure_code: None,
                });
            }
            filtered.keys = remaining.iter().map(|(key, _)| key.clone()).collect();
            let mut batches = BTreeMap::<i64, u32>::new();
            for (_, at) in &remaining {
                *batches.entry(*at).or_default() += 1;
            }
            if let EventBody::CardsExpiring {
                batches: current, ..
            } = &mut filtered.body
            {
                *current = batches.into_iter().collect();
            }
            filtered.expiry_items = Some(remaining);
        }
        let event = &filtered;
        if !event.current(super::now()) {
            return fail("stale_notification");
        }
        if let EventBody::QuotaReset { five, seven } = event.body {
            if (!five || !c.options.notifies_five_hour_reset)
                && (!seven || !c.options.notifies_seven_day_reset)
            {
                return fail("notification_filtered");
            }
        }
        let request = if kind == ChannelKind::System {
            // Mac local notifications cover quota/reset facts. Channel setup
            // never broadens this to unrelated conversation or switch alerts.
            if matches!(
                event.body,
                EventBody::Task { .. } | EventBody::Switch { .. }
            ) {
                return fail("notification_filtered");
            }
            if self.system_permission() != super::SystemNotificationPermission::Enabled {
                return fail("system_notifications_disabled");
            }
            None
        } else {
            Some(protocol::send_request(kind, &c, event)?)
        };
        op.current()?;
        let keys = event
            .keys
            .iter()
            .map(|k| super::hash(format!("{}:{k}", kind.id()).as_bytes()))
            .collect::<Vec<_>>();
        let reserved = self.storage.change(|v| {
            if let EventBody::CardsChanged {
                previous,
                available,
                previous_at,
                observed_at,
            } = event.body
            {
                if kind == ChannelKind::Feishu
                    && event.proof.as_ref().is_some_and(|(account, _)| {
                        super::manual_reset::explains_decrease(
                            v,
                            account,
                            previous,
                            available,
                            previous_at,
                            observed_at,
                        )
                    })
                {
                    return fail("notification_filtered");
                }
            }
            if !Self::event_current(v, event, super::now())
                || v.configs
                    .get(&kind)
                    .is_none_or(|r| r.revision != c.revision || !r.enabled)
            {
                return fail("stale_notification");
            }
            if keys.iter().any(|key| {
                v.deliveries.get(key).is_some_and(|e| {
                    matches!(e.phase, Phase::Sending | Phase::Sent | Phase::Uncertain)
                })
            }) {
                return Ok(false);
            }
            if v.deliveries.len() + keys.len() > 16384 {
                return fail("notification_store_capacity");
            }
            for key in &keys {
                if let EventBody::ManualReset { ref event_hash, .. } = event.body {
                    super::manual_reset::mark_attempt(v, event_hash, super::now())?;
                }
                if let Some(pending) = v.card_changes.get_mut(key) {
                    pending.last_attempt_at = Some(super::now());
                }
                v.deliveries.insert(
                    key.clone(),
                    Delivery {
                        phase: Phase::Sending,
                        attempt: op.id.clone(),
                        revision: c.revision,
                        at: super::now(),
                    },
                );
            }
            Ok(true)
        })?;
        if !reserved {
            return Ok(DeliveryReceipt {
                channel: kind,
                event_id: event.key.clone(),
                state: "duplicate_skipped",
                checked_at: super::now(),
                remote_message_id: None,
                failure_code: None,
            });
        }
        // A crash from this durable reservation onwards is uncertain, never an
        // automatic retry. Only a proven pre-send failure or rejection is pending.
        if let Err(e) = op.current() {
            self.finish(&keys, &op, Phase::Pending, event.public_revision)?;
            return Err(e);
        }
        let current = self
            .storage
            .read(|v| Ok(Self::event_current(v, event, super::now())))?;
        if !current {
            self.finish(&keys, &op, Phase::Pending, event.public_revision)?;
            return fail("stale_notification");
        }
        let parsed = match request {
            Some(request) => match self.transport.send(&request, &op.cancelled) {
                Ok(r) => protocol::parse_response(kind, r),
                Err(e) => Accepted::Uncertain(e),
            },
            None => {
                let (title, _, lines) = event.content(&c.options);
                let body = format!("{}\n\naigoodbro.com", lines.join("\n"));
                match self.transport.send_system(&title, &body, &op.cancelled) {
                    Ok(()) => Accepted::Ok(None),
                    Err(e) => Accepted::Uncertain(e),
                }
            }
        };
        let parsed = if op.current().is_err()
            || !self
                .storage
                .read(|v| Ok(Self::event_current(v, event, super::now())))
                .unwrap_or(false)
        {
            Accepted::Uncertain(Failure("cancelled"))
        } else {
            parsed
        };
        let (phase, mut state, mut id, mut error) = match parsed {
            Accepted::Ok(id) => (Phase::Sent, "accepted", id, None),
            Accepted::Rejected(e) => (Phase::Pending, "rejected", None, Some(e.0)),
            Accepted::Uncertain(e) => (Phase::Uncertain, "uncertain", None, Some(e.0)),
        };
        if self.finish(&keys, &op, phase, event.public_revision)? == Phase::Uncertain
            && state == "accepted"
        {
            state = "uncertain";
            id = None;
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
                    runtime.verified.insert(kind, (c.revision, super::now()));
                    runtime.failures.remove(&kind);
                } else if let Some(error) = error {
                    runtime.verified.remove(&kind);
                    runtime.failures.insert(kind, error);
                }
            }
        }
        Ok(DeliveryReceipt {
            channel: kind,
            event_id: event.key.clone(),
            state,
            checked_at: super::now(),
            remote_message_id: id,
            failure_code: error,
        })
    }
    fn finish(
        &self,
        keys: &[String],
        op: &Operation,
        mut phase: Phase,
        public_revision: Option<u64>,
    ) -> Result<Phase> {
        self.storage.change(|v| {
            if phase == Phase::Sent
                && (op.cancelled.load(Ordering::Acquire)
                    || self.exiting.load(Ordering::Acquire)
                    || public_revision.is_some_and(|rev| {
                        !v.public_reset.enabled || v.public_reset.revision != rev
                    })
                    || v.configs
                        .get(&op.kind)
                        .is_none_or(|c| !c.enabled || c.revision != op.revision))
            {
                phase = Phase::Uncertain;
            }
            for key in keys {
                let e = v
                    .deliveries
                    .get_mut(key)
                    .ok_or(Failure("notification_ledger_changed"))?;
                if e.attempt != op.id || e.revision != op.revision {
                    return fail("notification_ledger_changed");
                }
                e.phase = phase.clone();
                e.at = super::now();
                if phase == Phase::Sent {
                    if let Some(sent) = v.card_changes.get(key).cloned() {
                        v.card_changes.retain(|_, c| {
                            c.channel != sent.channel
                                || c.account_hash != sent.account_hash
                                || c.observed_at > sent.observed_at
                        });
                    }
                }
                if matches!(phase, Phase::Sent | Phase::Uncertain) {
                    v.card_changes.remove(key);
                }
            }
            Ok(phase)
        })
    }
}
