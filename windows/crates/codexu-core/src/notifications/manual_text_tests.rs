//! Isolated service/storage and injected transport; never registers native HTTP.
use super::*;
use crate::accounts::{AccountError, AccountResult};
use serde_json::Value;
use std::sync::{atomic::AtomicUsize, mpsc};
use std::time::Duration;
const ID: &str = "1234567890abcdef1234567890abcdef";
struct Protector(Arc<AtomicBool>);
impl SecretProtector for Protector {
    fn seal(&self, _: &str, b: &[u8]) -> AccountResult<Vec<u8>> {
        if self.0.load(Ordering::Acquire) {
            return Err(AccountError {
                code: "synthetic_seal_failed",
            });
        }
        Ok(b.iter().map(|b| b ^ 0x71).collect())
    }
    fn unseal(&self, _: &str, b: &[u8]) -> AccountResult<Vec<u8>> {
        Ok(b.iter().map(|b| b ^ 0x71).collect())
    }
}
struct Transport {
    calls: AtomicUsize,
    requests: Mutex<Vec<(String, Value)>>,
    reply: Mutex<Option<Result<TransportResponse>>>,
    action: Mutex<Option<Box<dyn FnOnce() + Send>>>,
}
impl NotificationTransport for Transport {
    fn send(&self, r: &TransportRequest, _: &AtomicBool) -> Result<TransportResponse> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.requests.lock().unwrap().push((
            r.endpoint().as_str().into(),
            serde_json::from_slice(r.body()).unwrap(),
        ));
        if let Some(action) = self.action.lock().unwrap().take() {
            action();
        }
        self.reply
            .lock()
            .unwrap()
            .take()
            .expect("only one queued synthetic response")
    }
}
struct Fixture {
    _dir: tempfile::TempDir,
    root: PathBuf,
    service: Arc<NotificationService>,
    transport: Arc<Transport>,
    fail_seal: Arc<AtomicBool>,
}
impl Fixture {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap().join("notifications");
        let fail_seal = Arc::new(AtomicBool::new(false));
        let transport = Arc::new(Transport {
            calls: AtomicUsize::new(0),
            requests: Mutex::new(vec![]),
            action: Mutex::new(None),
            reply: Mutex::new(Some(Ok(TransportResponse {
                status: 200,
                body: br#"{"ret":0}"#.to_vec(),
            }))),
        });
        let service = NotificationService::with_components(
            root.clone(),
            Arc::new(Protector(fail_seal.clone())),
            transport.clone(),
        )
        .unwrap();
        service
            .storage
            .change(|v| {
                v.configs.insert(
                    ChannelKind::PersonalWeChat,
                    ChannelConfig {
                        enabled: true,
                        revision: 7,
                        secret: Some("synthetic-bot-token".into()),
                        target: Some("synthetic-user".into()),
                        binding: Some(PersonalBinding {
                            base_url: "https://ilinkai.weixin.qq.com".into(),
                            bot_id: "synthetic-bot".into(),
                            user_id: "synthetic-user".into(),
                            context_token: Some("synthetic-context".into()),
                            context_checked_at: Some(super::super::super::now()),
                            cursor: "synthetic-cursor".into(),
                        }),
                        options: Default::default(),
                        session_expired: false,
                    },
                );
                Ok(())
            })
            .unwrap();
        Self {
            _dir: dir,
            root,
            service,
            transport,
            fail_seal,
        }
    }
    fn send(&self, text: &str) -> Result<PersonalTextReceipt> {
        self.service.send_personal_wechat_text(ID, 7, text, true)
    }
    fn config(&self, f: impl FnOnce(&mut ChannelConfig)) {
        self.service
            .storage
            .change(|v| {
                f(v.configs.get_mut(&ChannelKind::PersonalWeChat).unwrap());
                Ok(())
            })
            .unwrap();
    }
    fn calls(&self) -> usize {
        self.transport.calls.load(Ordering::SeqCst)
    }
    fn reconnect(&self) -> Arc<NotificationService> {
        NotificationService::with_components(
            self.root.clone(),
            Arc::new(Protector(self.fail_seal.clone())),
            self.transport.clone(),
        )
        .unwrap()
    }
}
#[test]
fn original_text_footer_and_fixed_recipient_preserved_api_acceptance_only() {
    let f = Fixture::new();
    let raw = "  原文\r\n\t保留  ";
    let receipt = f.send(raw).unwrap();
    assert_eq!(receipt.state, "accepted");
    assert_eq!(f.calls(), 1);
    let requests = f.transport.requests.lock().unwrap();
    assert_eq!(
        requests[0].0,
        "https://ilinkai.weixin.qq.com/ilink/bot/sendmessage"
    );
    let msg = &requests[0].1["msg"];
    assert_eq!(msg["to_user_id"], "synthetic-user");
    assert_eq!(msg["context_token"], "synthetic-context");
    assert_eq!(msg["client_id"], format!("aigoodbro-{ID}"));
    assert_eq!(
        msg["item_list"][0]["text_item"]["text"],
        format!("{raw}{FOOTER}")
    );
    let dto = serde_json::to_string(&receipt).unwrap();
    assert!(!dto.contains(raw));
    assert!(!dto.contains("synthetic"));
    assert!(!dto.contains("read"));
    f.service
        .storage
        .read(|v| {
            assert_eq!(v.deliveries.len(), 2);
            let ledger = serde_json::to_string(&v.deliveries).unwrap();
            assert!(!ledger.contains(raw));
            assert!(!ledger.contains("保留"));
            Ok(())
        })
        .unwrap();
}
#[test]
fn explicit_consent_revision_and_utf8_limits_fail_before_network() {
    let f = Fixture::new();
    assert_eq!(
        f.service
            .send_personal_wechat_text(ID, 7, "hello", false)
            .unwrap_err()
            .0,
        "confirmation_required"
    );
    assert_eq!(
        f.service
            .send_personal_wechat_text("invalid", 7, "hello", true)
            .unwrap_err()
            .0,
        "invalid_request_id"
    );
    assert_eq!(
        f.service
            .send_personal_wechat_text(ID, 8, "hello", true)
            .unwrap_err()
            .0,
        "configuration_changed"
    );
    for raw in ["", " \t\r\n", "a\0b"] {
        assert_eq!(f.send(raw).unwrap_err().0, "invalid_message_text");
    }
    assert_eq!(
        f.send(&"a".repeat(4096 - FOOTER.len() + 1)).unwrap_err().0,
        "message_too_long"
    );
    assert_eq!(
        f.send(&"中".repeat(1361)).unwrap_err().0,
        "message_too_long"
    );
    assert_eq!(f.calls(), 0);
    assert_eq!(
        f.send(&"a".repeat(4096 - FOOTER.len())).unwrap().state,
        "accepted"
    );
}
#[test]
fn disabled_credential_context_and_session_gates_never_send() {
    for mutate in [
        (|c: &mut ChannelConfig| c.enabled = false) as fn(&mut ChannelConfig),
        |c| c.secret = None,
        |c| c.binding.as_mut().unwrap().context_token = None,
        |c| c.binding.as_mut().unwrap().context_checked_at = None,
        |c| {
            c.binding.as_mut().unwrap().context_checked_at = Some(super::super::super::now() + 3600)
        },
        |c| c.session_expired = true,
    ] {
        let f = Fixture::new();
        f.config(mutate);
        assert!(f.send("hello").is_err());
        assert_eq!(f.calls(), 0);
        assert!(!f.service.personal_text_active.load(Ordering::Acquire));
    }
    let f = Fixture::new();
    assert_eq!(
        f.service
            .storage
            .change(|v| {
                v.configs
                    .get_mut(&ChannelKind::PersonalWeChat)
                    .unwrap()
                    .target = Some("different-user".into());
                Ok(())
            })
            .unwrap_err()
            .0,
        "invalid_wechat_binding"
    );
    assert_eq!(f.calls(), 0);
    let f = Fixture::new();
    f.config(|c| c.binding.as_mut().unwrap().context_checked_at = Some(1));
    assert_eq!(
        f.send("Mac has no past-context age cap").unwrap().state,
        "accepted"
    );
}
#[test]
fn request_replay_is_bound_to_exact_body_and_survives_restart() {
    let f = Fixture::new();
    assert_eq!(f.send("hello").unwrap().state, "accepted");
    assert_eq!(f.send("hello").unwrap().state, "accepted");
    assert_eq!(f.send("different").unwrap_err().0, "request_id_reused");
    assert_eq!(
        f.reconnect()
            .send_personal_wechat_text(ID, 7, "hello", true)
            .unwrap()
            .state,
        "accepted"
    );
    assert_eq!(f.calls(), 1);
}
#[test]
fn lost_reply_and_crash_journal_never_resend() {
    let f = Fixture::new();
    *f.transport.reply.lock().unwrap() = Some(Err(Failure("timeout")));
    assert_eq!(f.send("hello").unwrap().state, "uncertain");
    f.service
        .storage
        .change(|v| {
            for row in v.deliveries.values_mut() {
                row.phase = Phase::Sending;
            }
            Ok(())
        })
        .unwrap();
    assert_eq!(
        f.reconnect()
            .send_personal_wechat_text(ID, 7, "hello", true)
            .unwrap()
            .state,
        "uncertain"
    );
    assert_eq!(f.calls(), 1);
}
#[test]
fn rejected_or_session_expired_is_not_success_or_automatic_retry() {
    let f = Fixture::new();
    *f.transport.reply.lock().unwrap() = Some(Ok(TransportResponse {
        status: 200,
        body: br#"{"ret":1}"#.to_vec(),
    }));
    assert_eq!(f.send("hello").unwrap().state, "rejected");
    assert_eq!(f.send("hello").unwrap().state, "not_sent");
    assert_eq!(f.calls(), 1);
    let f = Fixture::new();
    *f.transport.reply.lock().unwrap() = Some(Ok(TransportResponse {
        status: 200,
        body: br#"{"ret":-14}"#.to_vec(),
    }));
    let receipt = f.send("hello").unwrap();
    assert_eq!(receipt.state, "rejected");
    assert_eq!(receipt.failure_code, Some("wechat_session_expired"));
    assert!(f.send("hello").is_err());
    assert_eq!(f.calls(), 1);
}
#[test]
fn durable_claim_failure_does_not_send_and_result_save_failure_stays_unknown() {
    let f = Fixture::new();
    f.fail_seal.store(true, Ordering::Release);
    assert!(f.send("hello").is_err());
    assert_eq!(f.calls(), 0);
    f.fail_seal.store(false, Ordering::Release);
    let flag = f.fail_seal.clone();
    *f.transport.action.lock().unwrap() =
        Some(Box::new(move || flag.store(true, Ordering::Release)));
    assert!(f.send("hello").is_err());
    assert_eq!(f.calls(), 1);
    f.fail_seal.store(false, Ordering::Release);
    assert_eq!(
        f.reconnect()
            .send_personal_wechat_text(ID, 7, "hello", true)
            .unwrap()
            .state,
        "uncertain"
    );
    assert_eq!(f.calls(), 1);
}
#[test]
fn disabled_or_rebound_during_send_cannot_claim_late_success() {
    for rebind in [false, true] {
        let f = Fixture::new();
        let weak = Arc::downgrade(&f.service);
        *f.transport.action.lock().unwrap() = Some(Box::new(move || {
            let s = weak.upgrade().unwrap();
            if rebind {
                s.storage
                    .change(|v| {
                        v.configs
                            .get_mut(&ChannelKind::PersonalWeChat)
                            .unwrap()
                            .revision += 1;
                        Ok(())
                    })
                    .unwrap();
            } else {
                s.set_enabled(ChannelKind::PersonalWeChat, false).unwrap();
            }
        }));
        assert_eq!(f.send("hello").unwrap().state, "uncertain");
        assert_eq!(f.calls(), 1);
        assert!(f
            .service
            .channel_state(ChannelKind::PersonalWeChat)
            .unwrap()
            .last_accepted_at
            .is_none());
    }
}
#[test]
fn pairing_and_manual_send_share_admission_but_no_automatic_retry() {
    let f = Fixture::new();
    f.service.state.lock().unwrap().login = Some(LoginAttempt {
        id: ID.into(),
        phase: "waiting",
        reference: "synthetic".into(),
        qr: "synthetic".into(),
        base: "https://ilinkai.weixin.qq.com".into(),
        revision: 7,
        expires_at: super::super::super::now() + 60,
    });
    assert_eq!(f.send("hello").unwrap_err().0, "wechat_login_in_progress");
    assert_eq!(f.calls(), 0);
    f.service.state.lock().unwrap().login = None;
    let (entered, waiting) = mpsc::channel();
    let (release, released) = mpsc::channel();
    *f.transport.action.lock().unwrap() = Some(Box::new(move || {
        entered.send(()).unwrap();
        released.recv_timeout(Duration::from_secs(3)).unwrap();
    }));
    let service = f.service.clone();
    let worker =
        std::thread::spawn(move || service.send_personal_wechat_text(ID, 7, "hello", true));
    waiting.recv_timeout(Duration::from_secs(3)).unwrap();
    assert_eq!(
        f.service.begin_personal_wechat_login().err().unwrap().0,
        "notification_busy"
    );
    assert_eq!(f.send("second").unwrap_err().0, "notification_busy");
    release.send(()).unwrap();
    assert_eq!(worker.join().unwrap().unwrap().state, "accepted");
    assert_eq!(f.calls(), 1);
    assert!(!f.service.personal_text_active.load(Ordering::Acquire));
}
