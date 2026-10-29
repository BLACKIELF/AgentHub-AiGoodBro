//! Real notification service/vault/protocol/ledger with synthetic inputs only.
//! Native transport is never registered here and no remote request is possible.
use codexu_core::{
    accounts::{AccountError, AccountResult, SecretProtector},
    notifications::*,
};
use serde_json::{json, Value};
use std::{
    collections::VecDeque,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc, Mutex,
    },
};

struct SyntheticProtector;
struct FailingProtector(Arc<AtomicBool>);
struct FailingFromSeal {
    calls: AtomicUsize,
    from: AtomicUsize,
}
impl SecretProtector for FailingFromSeal {
    fn seal(&self, c: &str, b: &[u8]) -> AccountResult<Vec<u8>> {
        let call = self.calls.fetch_add(1, Ordering::SeqCst) + 1;
        if call >= self.from.load(Ordering::Acquire) {
            Err(AccountError {
                code: "synthetic_seal_failed",
            })
        } else {
            SyntheticProtector.seal(c, b)
        }
    }
    fn unseal(&self, c: &str, b: &[u8]) -> AccountResult<Vec<u8>> {
        SyntheticProtector.unseal(c, b)
    }
}
impl SecretProtector for FailingProtector {
    fn seal(&self, c: &str, b: &[u8]) -> AccountResult<Vec<u8>> {
        if self.0.load(Ordering::Acquire) {
            Err(AccountError {
                code: "synthetic_seal_failed",
            })
        } else {
            SyntheticProtector.seal(c, b)
        }
    }
    fn unseal(&self, c: &str, b: &[u8]) -> AccountResult<Vec<u8>> {
        SyntheticProtector.unseal(c, b)
    }
}
impl SecretProtector for SyntheticProtector {
    fn seal(&self, context: &str, plain: &[u8]) -> AccountResult<Vec<u8>> {
        let mut b = context.as_bytes().to_vec();
        b.push(0);
        b.extend(plain.iter().map(|v| v ^ 0x59));
        Ok(b)
    }
    fn unseal(&self, context: &str, b: &[u8]) -> AccountResult<Vec<u8>> {
        let mut p = context.as_bytes().to_vec();
        p.push(0);
        if !b.starts_with(&p) {
            return Err(AccountError {
                code: "synthetic_unseal_failed",
            });
        }
        Ok(b[p.len()..].iter().map(|v| v ^ 0x59).collect())
    }
}
struct SyntheticTransport {
    responses: Mutex<VecDeque<std::result::Result<TransportResponse, Failure>>>,
    requests: Mutex<Vec<(String, String, Value)>>,
    calls: AtomicUsize,
    on_send: Mutex<Option<Box<dyn FnOnce() + Send>>>,
}
impl SyntheticTransport {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            responses: Mutex::new(VecDeque::new()),
            requests: Mutex::new(Vec::new()),
            calls: AtomicUsize::new(0),
            on_send: Mutex::new(None),
        })
    }
    fn json(&self, v: Value) {
        self.responses
            .lock()
            .unwrap()
            .push_back(Ok(TransportResponse {
                status: 200,
                body: v.to_string().into_bytes(),
            }));
    }
}
impl NotificationTransport for SyntheticTransport {
    fn send(&self, r: &TransportRequest, c: &AtomicBool) -> Result<TransportResponse> {
        if c.load(Ordering::Acquire) {
            return Err(Failure("cancelled"));
        }
        self.calls.fetch_add(1, Ordering::SeqCst);
        if let Some(action) = self.on_send.lock().unwrap().take() {
            action();
        }
        self.requests.lock().unwrap().push((
            r.method().into(),
            r.endpoint().as_str().into(),
            serde_json::from_slice(r.body()).unwrap_or(Value::Null),
        ));
        self.responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("only explicitly queued synthetic responses may be used")
    }
}
struct Fixture {
    _temp: tempfile::TempDir,
    root: PathBuf,
    service: Arc<NotificationService>,
    transport: Arc<SyntheticTransport>,
}
impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = temp
            .path()
            .canonicalize()
            .unwrap()
            .join("synthetic-notifications");
        let transport = SyntheticTransport::new();
        let service = NotificationService::with_components(
            root.clone(),
            Arc::new(SyntheticProtector),
            transport.clone(),
        )
        .unwrap();
        Self {
            _temp: temp,
            root,
            service,
            transport,
        }
    }
    fn setup(&self, kind: ChannelKind) {
        let (secret, target) = match kind {
            ChannelKind::Feishu => (
                "https://open.feishu.cn/open-apis/bot/v2/hook/synthetic-not-a-real-webhook"
                    .to_owned(),
                None,
            ),
            ChannelKind::Telegram => (
                "12345:synthetic_token_which_is_not_real_123456".to_owned(),
                Some("-12345".into()),
            ),
            ChannelKind::WeCom => ("11111111-2222-3333-4444-555555555555".into(), None),
            ChannelKind::PersonalWeChat => panic!("personal requires actual QR protocol fixture"),
        };
        self.service.save_channel(kind, secret, target).unwrap();
        self.service.set_enabled(kind, true).unwrap();
    }
    fn event(&self, id: &str) -> NotificationEvent {
        NotificationEvent::task(
            id,
            "Fixture account",
            "Synthetic task",
            TaskState::Completed,
            chrono::Utc::now().timestamp(),
        )
        .unwrap()
    }
    fn reconnect(&self) -> Arc<NotificationService> {
        NotificationService::with_components(
            self.root.clone(),
            Arc::new(SyntheticProtector),
            self.transport.clone(),
        )
        .unwrap()
    }
    fn pair_personal(&self) -> String {
        self.service
            .set_enabled(ChannelKind::PersonalWeChat, true)
            .unwrap();
        self.transport.json(json!({"qrcode":"synthetic-qr-reference","qrcode_img_content":"synthetic-official-qr-content"}));
        let login = self.service.begin_personal_wechat_login().unwrap();
        self.transport.json(json!({"status":"confirmed","bot_token":"synthetic-bot-token","ilink_bot_id":"synthetic-bot","ilink_user_id":"synthetic-user","baseurl":"https://ilinkai.weixin.qq.com"}));
        self.service
            .poll_personal_wechat_login(&login.attempt_id, None)
            .unwrap();
        login.attempt_id
    }
    fn personal_context(&self, at: i64) {
        self.transport.json(json!({"msgs":[{"message_type":1,"from_user_id":"synthetic-user","to_user_id":"synthetic-bot","context_token":"synthetic-context","create_time_ms":at*1000}],"get_updates_buf":"synthetic-cursor"}));
        self.service.refresh_personal_wechat_context().unwrap();
    }
}
#[test]
fn channels_default_disabled_and_save_never_enables_or_sends() {
    let f = Fixture::new();
    assert!(f
        .service
        .states()
        .unwrap()
        .iter()
        .all(|s| !s.enabled && s.phase == "disabled"));
    f.service
        .save_channel(
            ChannelKind::WeCom,
            "11111111-2222-3333-4444-555555555555".into(),
            None,
        )
        .unwrap();
    assert_eq!(
        f.service
            .send_test(ChannelKind::WeCom)
            .err()
            .unwrap()
            .code(),
        "channel_disabled"
    );
    assert_eq!(f.transport.calls.load(Ordering::SeqCst), 0);
}
#[test]
fn vault_is_encrypted_and_restore_is_not_a_verified_delivery() {
    let f = Fixture::new();
    f.setup(ChannelKind::Telegram);
    let bytes = std::fs::read(f.root.join("channels.dpapi")).unwrap();
    assert!(!String::from_utf8_lossy(&bytes).contains("synthetic_token"));
    f.transport
        .json(json!({"ok":true,"result":{"message_id":42}}));
    assert_eq!(
        f.service.send_test(ChannelKind::Telegram).unwrap().state,
        "accepted"
    );
    assert_eq!(
        f.service
            .channel_state(ChannelKind::Telegram)
            .unwrap()
            .phase,
        "ready"
    );
    let dto = serde_json::to_string(&f.service.states().unwrap()).unwrap();
    assert!(!dto.contains("synthetic_token"));
    assert!(!dto.contains("-12345"));
    assert!(!dto.contains(f.root.to_string_lossy().as_ref()));
    assert_eq!(
        f.reconnect()
            .restore_saved_connections()
            .unwrap()
            .iter()
            .find(|s| s.channel == ChannelKind::Telegram)
            .unwrap()
            .phase,
        "pending_verification"
    );
}
#[test]
fn fixed_protocol_routes_and_provider_acceptance_are_real() {
    let f = Fixture::new();
    for kind in [
        ChannelKind::Feishu,
        ChannelKind::Telegram,
        ChannelKind::WeCom,
    ] {
        f.setup(kind);
        f.transport.json(match kind {
            ChannelKind::Feishu => json!({"code":0}),
            ChannelKind::Telegram => json!({"ok":true,"result":{"message_id":7}}),
            _ => json!({"errcode":0}),
        });
        assert_eq!(f.service.send_test(kind).unwrap().state, "accepted");
    }
    let requests = f.transport.requests.lock().unwrap();
    assert!(requests[0]
        .1
        .starts_with("https://open.feishu.cn/open-apis/bot/v2/hook/"));
    assert_eq!(requests[0].2["msg_type"], "interactive");
    assert!(requests[1].1.starts_with("https://api.telegram.org/bot"));
    assert!(requests[1].1.ends_with("/sendMessage"));
    assert_eq!(requests[1].2["chat_id"], "-12345");
    assert!(requests[2]
        .1
        .starts_with("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key="));
    assert_eq!(requests[2].2["msgtype"], "markdown");
}
#[test]
fn malformed_credentials_and_secret_destinations_are_rejected_before_transport() {
    let f = Fixture::new();
    for url in [
        "https://open.feishu.cn.evil.invalid/open-apis/bot/v2/hook/synthetic-valid-token",
        "https://open.feishu.cn/open-apis/bot/v2/hook/synthetic-valid-token?key=x",
        "https://user@open.feishu.cn/open-apis/bot/v2/hook/synthetic-valid-token",
        "http://open.feishu.cn/open-apis/bot/v2/hook/synthetic-valid-token",
    ] {
        assert!(f
            .service
            .save_channel(ChannelKind::Feishu, url.into(), None)
            .is_err());
    }
    assert!(f
        .service
        .save_channel(ChannelKind::WeCom, "not-a-guid".into(), None)
        .is_err());
    assert!(NotificationEvent::task(
        "test",
        "private@fixture.invalid",
        "Safe",
        TaskState::Running,
        chrono::Utc::now().timestamp()
    )
    .is_err());
    assert_eq!(f.transport.calls.load(Ordering::SeqCst), 0);
}
#[test]
fn remote_rejection_is_not_success_and_remote_text_never_reaches_receipt() {
    let f = Fixture::new();
    f.setup(ChannelKind::Telegram);
    f.transport.json(
        json!({"ok":false,"error_code":401,"description":"synthetic_private_token_and_path"}),
    );
    let r = f.service.send_test(ChannelKind::Telegram).unwrap();
    assert_eq!(r.state, "rejected");
    assert_eq!(r.failure_code, Some("rejected"));
    assert!(!serde_json::to_string(&r)
        .unwrap()
        .contains("synthetic_private"));
    f.transport.json(json!({"ok":true}));
    assert_eq!(
        f.service.send_test(ChannelKind::Telegram).unwrap().state,
        "uncertain"
    );
}
#[test]
fn uncertain_attempt_survives_restart_and_cannot_automatically_resend() {
    let f = Fixture::new();
    f.setup(ChannelKind::WeCom);
    f.transport
        .responses
        .lock()
        .unwrap()
        .push_back(Err(Failure("transport_failed")));
    let event = f.event("durable synthetic task");
    assert_eq!(
        f.service
            .send_event_to(ChannelKind::WeCom, &event)
            .unwrap()
            .state,
        "uncertain"
    );
    assert_eq!(
        f.reconnect()
            .send_event_to(ChannelKind::WeCom, &event)
            .unwrap()
            .state,
        "duplicate_skipped"
    );
    assert_eq!(f.transport.calls.load(Ordering::SeqCst), 1);
}
#[test]
fn proven_rejection_can_retry_but_accepted_event_is_durable() {
    let f = Fixture::new();
    f.setup(ChannelKind::WeCom);
    let event = f.event("rejection retry");
    f.transport.json(json!({"errcode":45009}));
    assert_eq!(
        f.service
            .send_event_to(ChannelKind::WeCom, &event)
            .unwrap()
            .state,
        "rejected"
    );
    f.transport.json(json!({"errcode":0}));
    assert_eq!(
        f.service
            .send_event_to(ChannelKind::WeCom, &event)
            .unwrap()
            .state,
        "accepted"
    );
    assert_eq!(
        f.reconnect()
            .send_event_to(ChannelKind::WeCom, &event)
            .unwrap()
            .state,
        "duplicate_skipped"
    );
    assert_eq!(f.transport.calls.load(Ordering::SeqCst), 2);
}
#[test]
fn stale_or_unknown_event_facts_do_not_send() {
    let f = Fixture::new();
    f.setup(ChannelKind::WeCom);
    let stale = NotificationEvent::task(
        "stale",
        "Fixture",
        "Synthetic",
        TaskState::Completed,
        chrono::Utc::now().timestamp() - 301,
    )
    .unwrap();
    assert!(f.service.dispatch(&stale).is_err());
    let now = chrono::Utc::now().timestamp();
    let o = OfficialQuotaObservation::new(
        "synthetic-account",
        "Fixture",
        now,
        false,
        Some("codex"),
        None,
        None,
        Some(2),
        Some(vec![ResetCard::from_official_id(
            "real-backend-synthetic-id",
            Some(now + 100),
        )
        .unwrap()]),
    )
    .unwrap();
    assert!(f.service.observe_official_quota(o).unwrap().is_empty());
    assert_eq!(f.transport.calls.load(Ordering::SeqCst), 0);
}
#[test]
fn official_reset_cards_use_backend_ids_and_expiry_is_deduplicated() {
    let f = Fixture::new();
    f.setup(ChannelKind::WeCom);
    let now = chrono::Utc::now().timestamp();
    let observation = || {
        OfficialQuotaObservation::new(
            "synthetic-account",
            "Fixture",
            now,
            true,
            Some("codex"),
            None,
            None,
            Some(3),
            Some(vec![
                ResetCard::from_official_id("synthetic-card-one", Some(now + 100)).unwrap(),
                ResetCard::from_official_id("synthetic-card-two", None).unwrap(),
                ResetCard::from_official_id("synthetic-card-three", Some(now + 86401)).unwrap(),
            ]),
        )
        .unwrap()
    };
    f.transport.json(json!({"errcode":0}));
    assert_eq!(
        f.service.observe_official_quota(observation()).unwrap()[0].state,
        "accepted"
    );
    assert_eq!(
        f.service.observe_official_quota(observation()).unwrap()[0].state,
        "duplicate_skipped"
    );
    assert_eq!(f.transport.calls.load(Ordering::SeqCst), 1);
    let body = f.transport.requests.lock().unwrap()[0].2.to_string();
    assert!(body.contains("24小时"));
    assert!(body.contains("未知：1"));
    assert!(!body.contains("synthetic-card-one"));
}
#[test]
fn personal_wechat_qr_binding_and_own_context_use_real_protocol() {
    let f = Fixture::new();
    f.service
        .set_enabled(ChannelKind::PersonalWeChat, true)
        .unwrap();
    f.transport.json(json!({"qrcode":"synthetic-qr-reference","qrcode_img_content":"synthetic-official-qr-content"}));
    let login = f.service.begin_personal_wechat_login().unwrap();
    assert_eq!(login.phase, "waiting");
    f.transport.json(json!({"status":"confirmed","bot_token":"synthetic-bot-token","ilink_bot_id":"synthetic-bot","ilink_user_id":"synthetic-user","baseurl":"https://ilinkai.weixin.qq.com"}));
    assert_eq!(
        f.service
            .poll_personal_wechat_login(&login.attempt_id, None)
            .unwrap()
            .phase,
        "confirmed"
    );
    assert_eq!(
        f.service
            .send_test(ChannelKind::PersonalWeChat)
            .err()
            .unwrap()
            .code(),
        "wechat_context_required"
    );
    let ms = chrono::Utc::now().timestamp_millis();
    f.transport.json(json!({"msgs":[{"message_type":1,"from_user_id":"wrong-user","to_user_id":"synthetic-bot","context_token":"wrong-context","create_time_ms":ms},{"message_type":1,"from_user_id":"synthetic-user","to_user_id":"synthetic-bot","context_token":"synthetic-own-context","create_time_ms":ms}],"get_updates_buf":"synthetic-cursor"}));
    f.service.refresh_personal_wechat_context().unwrap();
    f.transport.json(json!({}));
    assert_eq!(
        f.service
            .send_test(ChannelKind::PersonalWeChat)
            .unwrap()
            .state,
        "accepted"
    );
    let requests = f.transport.requests.lock().unwrap();
    assert!(requests[0]
        .1
        .ends_with("/ilink/bot/get_bot_qrcode?bot_type=3"));
    assert_eq!(requests[1].0, "GET");
    assert!(requests[1].1.contains("get_qrcode_status?qrcode="));
    assert_eq!(
        requests[3].2["msg"]["context_token"],
        "synthetic-own-context"
    );
    assert_eq!(requests[3].2["msg"]["to_user_id"], "synthetic-user");
    assert!(!serde_json::to_string(&f.service.states().unwrap())
        .unwrap()
        .contains("synthetic-own-context"));
}
#[test]
fn personal_redirect_outside_tencent_and_unknown_ack_are_rejected() {
    let f = Fixture::new();
    f.service
        .set_enabled(ChannelKind::PersonalWeChat, true)
        .unwrap();
    f.transport
        .json(json!({"qrcode":"synthetic-qr","qrcode_img_content":"synthetic-qr-content"}));
    let l = f.service.begin_personal_wechat_login().unwrap();
    f.transport
        .json(json!({"status":"scaned_but_redirect","redirect_host":"evil.invalid"}));
    assert_eq!(
        f.service
            .poll_personal_wechat_login(&l.attempt_id, None)
            .err()
            .unwrap()
            .code(),
        "invalid_wechat_endpoint"
    );
    assert!(
        !f.service
            .channel_state(ChannelKind::PersonalWeChat)
            .unwrap()
            .credential_present
    );
}
#[test]
fn exit_seal_rejects_new_network_operations() {
    let f = Fixture::new();
    f.setup(ChannelKind::WeCom);
    f.service.cancel_inflight_for_exit();
    assert_eq!(
        f.service
            .send_test(ChannelKind::WeCom)
            .err()
            .unwrap()
            .code(),
        "notification_exiting"
    );
    assert_eq!(f.transport.calls.load(Ordering::SeqCst), 0);
}

#[test]
fn cancelled_or_reconfigured_late_acceptance_stays_uncertain_and_never_ready() {
    for reconfigure in [false, true] {
        let f = Fixture::new();
        f.setup(ChannelKind::WeCom);
        let service = f.service.clone();
        *f.transport.on_send.lock().unwrap() = Some(Box::new(move || {
            if reconfigure {
                service
                    .save_channel(
                        ChannelKind::WeCom,
                        "66666666-2222-3333-4444-555555555555".into(),
                        None,
                    )
                    .unwrap();
            } else {
                service.cancel_channel(ChannelKind::WeCom).unwrap();
            }
        }));
        f.transport.json(json!({"errcode":0}));
        let event = f.event("cancelled request");
        let receipt = f.service.send_event_to(ChannelKind::WeCom, &event).unwrap();
        assert_eq!(receipt.state, "uncertain");
        assert_eq!(receipt.failure_code, Some("cancelled"));
        assert_eq!(
            f.service.channel_state(ChannelKind::WeCom).unwrap().phase,
            "pending_verification"
        );
        assert!(!f.service.has_inflight_operation());
        assert_eq!(
            f.reconnect()
                .send_event_to(ChannelKind::WeCom, &event)
                .unwrap()
                .state,
            "duplicate_skipped"
        );
        assert_eq!(f.transport.calls.load(Ordering::SeqCst), 1);
    }
}

#[test]
fn cancelled_personal_pair_cannot_save_late_credentials() {
    let f = Fixture::new();
    f.service
        .set_enabled(ChannelKind::PersonalWeChat, true)
        .unwrap();
    f.transport
        .json(json!({"qrcode":"synthetic-qr","qrcode_img_content":"synthetic-qr-content"}));
    let login = f.service.begin_personal_wechat_login().unwrap();
    let service = f.service.clone();
    *f.transport.on_send.lock().unwrap() = Some(Box::new(move || {
        service.cancel_channel(ChannelKind::PersonalWeChat).unwrap();
    }));
    f.transport.json(json!({"status":"confirmed","bot_token":"synthetic-bot-token","ilink_bot_id":"synthetic-bot","ilink_user_id":"synthetic-user"}));
    assert!(f
        .service
        .poll_personal_wechat_login(&login.attempt_id, None)
        .is_err());
    assert_eq!(
        f.service
            .personal_wechat_login(&login.attempt_id)
            .unwrap()
            .phase,
        "cancelled"
    );
    assert!(
        !f.reconnect()
            .channel_state(ChannelKind::PersonalWeChat)
            .unwrap()
            .credential_present
    );
}

#[test]
fn personal_context_has_no_invented_24_hour_expiry_and_session_error_is_persistent() {
    let f = Fixture::new();
    f.pair_personal();
    f.personal_context(chrono::Utc::now().timestamp() - 90_000);
    f.transport.json(json!({"unrelated":"synthetic"}));
    assert_eq!(
        f.service
            .send_test(ChannelKind::PersonalWeChat)
            .unwrap()
            .state,
        "uncertain"
    );
    f.transport
        .json(json!({"ret":0,"errcode":-14,"errmsg":"synthetic secret must not escape"}));
    let receipt = f.service.send_test(ChannelKind::PersonalWeChat).unwrap();
    assert_eq!(receipt.state, "rejected");
    assert_eq!(receipt.failure_code, Some("wechat_session_expired"));
    assert_eq!(
        f.reconnect()
            .channel_state(ChannelKind::PersonalWeChat)
            .unwrap()
            .phase,
        "session_expired"
    );
    let calls = f.transport.calls.load(Ordering::SeqCst);
    assert_eq!(
        f.service
            .send_test(ChannelKind::PersonalWeChat)
            .err()
            .unwrap()
            .code(),
        "wechat_session_expired"
    );
    assert_eq!(f.transport.calls.load(Ordering::SeqCst), calls);
}

#[test]
fn partial_expiry_batch_sends_new_card_without_resending_old_card() {
    let f = Fixture::new();
    f.setup(ChannelKind::WeCom);
    let now = chrono::Utc::now().timestamp();
    let observation = |at, new: bool| {
        OfficialQuotaObservation::new(
            "synthetic-account",
            "Fixture",
            at,
            true,
            Some("codex"),
            None,
            None,
            Some(3),
            Some(if new {
                vec![
                    ResetCard::from_official_id("synthetic-old", Some(now + 1000)).unwrap(),
                    ResetCard::from_official_id("synthetic-new", Some(now + 1000)).unwrap(),
                ]
            } else {
                vec![ResetCard::from_official_id("synthetic-old", Some(now + 1000)).unwrap()]
            }),
        )
        .unwrap()
    };
    f.transport.json(json!({"errcode":0}));
    f.service
        .observe_official_quota(observation(now - 2, false))
        .unwrap();
    f.transport.json(json!({"errcode":0}));
    let receipt = f
        .service
        .observe_official_quota(observation(now - 1, true))
        .unwrap();
    assert_eq!(receipt[0].state, "accepted");
    assert_eq!(f.transport.calls.load(Ordering::SeqCst), 2);
    let requests = f.transport.requests.lock().unwrap();
    let body = requests[1].2.to_string();
    assert!(body.contains("到期：1 张"));
    assert!(!body.contains("到期：2 张"));
}

fn official(
    at: i64,
    used: Option<f64>,
    cards: Option<u32>,
    limit: Option<&str>,
) -> OfficialQuotaObservation {
    OfficialQuotaObservation::new(
        "synthetic-quota-account",
        "Fixture",
        at,
        true,
        limit,
        used.map(|used| OfficialRateWindow {
            used_percent: used,
            duration_minutes: 300,
            resets_at: Some(at + 1000),
        }),
        None,
        cards,
        None,
    )
    .unwrap()
}
#[test]
fn quota_events_require_comparable_official_baselines_and_preserve_unknown() {
    let f = Fixture::new();
    f.setup(ChannelKind::WeCom);
    let now = chrono::Utc::now().timestamp();
    assert!(f
        .service
        .observe_official_quota(official(now - 10, Some(80.0), Some(2), Some("codex")))
        .unwrap()
        .is_empty());
    f.transport.json(json!({"errcode":0}));
    f.transport.json(json!({"errcode":0}));
    let receipts = f
        .service
        .observe_official_quota(official(now - 8, Some(0.0), Some(1), Some("codex")))
        .unwrap();
    assert_eq!(receipts.len(), 2);
    assert!(receipts.iter().all(|r| r.state == "accepted"));
    assert!(f
        .service
        .observe_official_quota(official(now - 6, None, None, Some("codex")))
        .unwrap()
        .is_empty());
    assert!(f
        .service
        .observe_official_quota(official(now - 4, Some(0.0), Some(5), Some("codex")))
        .unwrap()
        .is_empty());
    f.transport.json(json!({"errcode":0}));
    let changed = f
        .service
        .observe_official_quota(official(now - 2, Some(0.0), Some(9), Some("other-bucket")))
        .unwrap();
    assert_eq!(changed.len(), 1);
    let requests = f.transport.requests.lock().unwrap();
    let body = requests.last().unwrap().2.to_string();
    assert!(body.contains("重置卡增加"));
    assert!(!body.contains("额度已重置"));
    assert_eq!(f.transport.calls.load(Ordering::SeqCst), 3);
}

#[test]
fn monitor_consumes_bounded_coalescing_queue_without_ui_or_parallel_thread_per_event() {
    use std::time::{Duration, Instant};
    let f = Fixture::new();
    f.setup(ChannelKind::WeCom);
    let now = chrono::Utc::now().timestamp();
    for _ in 0..100 {
        f.service
            .queue_official_quota(official(now, Some(99.0), None, Some("codex")))
            .unwrap();
    }
    assert_eq!(f.transport.calls.load(Ordering::SeqCst), 0);
    f.transport.json(json!({"errcode":0}));
    let changed = Arc::new(AtomicUsize::new(0));
    let listener = changed.clone();
    let monitor = f
        .service
        .start_monitor_with_listener(Arc::new(move || {
            listener.fetch_add(1, Ordering::SeqCst);
        }))
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    while f.transport.calls.load(Ordering::SeqCst) < 1 {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(5));
    }
    monitor.cancel();
    while !monitor.is_finished() {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(f.transport.calls.load(Ordering::SeqCst), 1);
    assert!(!f.service.has_inflight_operation());
    assert!(changed.load(Ordering::SeqCst) >= 1);
}

#[test]
fn native_queue_enforces_existing_managed_catalog_capacity_without_network() {
    let f = Fixture::new();
    let now = chrono::Utc::now().timestamp();
    for i in 0..64 {
        let o = OfficialQuotaObservation::new(
            &format!("synthetic-account-{i}"),
            "Fixture",
            now,
            true,
            Some("codex"),
            None,
            None,
            None,
            None,
        )
        .unwrap();
        f.service.queue_official_quota(o).unwrap();
    }
    let o = OfficialQuotaObservation::new(
        "synthetic-account-over-capacity",
        "Fixture",
        now,
        true,
        Some("codex"),
        None,
        None,
        None,
        None,
    )
    .unwrap();
    assert_eq!(
        f.service.queue_official_quota(o).err().unwrap().code(),
        "notification_queue_capacity"
    );
    assert_eq!(f.transport.calls.load(Ordering::SeqCst), 0);
    assert_eq!(
        f.service
            .channel_state(ChannelKind::WeCom)
            .unwrap()
            .failure_code,
        Some("notification_queue_capacity")
    );
}

#[test]
fn owned_context_monitor_uses_only_enabled_binding_and_disable_cancels_late_update() {
    use std::time::{Duration, Instant};
    let f = Fixture::new();
    f.pair_personal();
    let service = f.service.clone();
    *f.transport.on_send.lock().unwrap() = Some(Box::new(move || {
        service
            .set_enabled(ChannelKind::PersonalWeChat, false)
            .unwrap();
    }));
    f.transport.json(json!({"msgs":[{"message_type":1,"from_user_id":"synthetic-user","to_user_id":"synthetic-bot","context_token":"late-cancelled-context","create_time_ms":chrono::Utc::now().timestamp_millis()}]}));
    let monitor = f.service.start_monitor().unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    while f.transport.calls.load(Ordering::SeqCst) < 3 {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(5));
    }
    monitor.cancel();
    while !monitor.is_finished() {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(5));
    }
    let c = f
        .service
        .channel_state(ChannelKind::PersonalWeChat)
        .unwrap();
    assert_eq!(c.phase, "disabled");
    assert!(!f.service.has_inflight_operation());
    assert_eq!(f.transport.calls.load(Ordering::SeqCst), 3);
}

#[test]
fn ledger_write_failure_blocks_before_send_and_preserves_uncertain_after_acceptance() {
    for after in [false, true] {
        let temp = tempfile::tempdir().unwrap();
        let root = temp
            .path()
            .canonicalize()
            .unwrap()
            .join("synthetic-failing-store");
        let reject = Arc::new(AtomicBool::new(false));
        let transport = SyntheticTransport::new();
        let protector = Arc::new(FailingProtector(reject.clone()));
        let service = NotificationService::with_components(
            root.clone(),
            protector.clone(),
            transport.clone(),
        )
        .unwrap();
        service
            .save_channel(
                ChannelKind::WeCom,
                "11111111-2222-3333-4444-555555555555".into(),
                None,
            )
            .unwrap();
        service.set_enabled(ChannelKind::WeCom, true).unwrap();
        let event = NotificationEvent::task(
            "durable save failure",
            "Fixture",
            "Synthetic",
            TaskState::Completed,
            chrono::Utc::now().timestamp(),
        )
        .unwrap();
        if after {
            let flag = reject.clone();
            *transport.on_send.lock().unwrap() =
                Some(Box::new(move || flag.store(true, Ordering::Release)));
            transport.json(json!({"errcode":0}));
        } else {
            reject.store(true, Ordering::Release);
        }
        assert_eq!(
            service
                .send_event_to(ChannelKind::WeCom, &event)
                .err()
                .unwrap()
                .code(),
            "notification_credentials_unavailable"
        );
        assert_eq!(transport.calls.load(Ordering::SeqCst), usize::from(after));
        reject.store(false, Ordering::Release);
        if after {
            let reopened =
                NotificationService::with_components(root, protector, transport.clone()).unwrap();
            assert_eq!(
                reopened
                    .send_event_to(ChannelKind::WeCom, &event)
                    .unwrap()
                    .state,
                "duplicate_skipped"
            );
            assert_eq!(transport.calls.load(Ordering::SeqCst), 1);
        }
    }
}

#[test]
fn card_change_pending_is_atomic_with_baseline_and_recovers_before_reserve_after_restart() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp
        .path()
        .canonicalize()
        .unwrap()
        .join("synthetic-card-outbox");
    let protector = Arc::new(FailingFromSeal {
        calls: AtomicUsize::new(0),
        from: AtomicUsize::new(usize::MAX),
    });
    let transport = SyntheticTransport::new();
    let service =
        NotificationService::with_components(root.clone(), protector.clone(), transport.clone())
            .unwrap();
    service
        .save_channel(
            ChannelKind::WeCom,
            "11111111-2222-3333-4444-555555555555".into(),
            None,
        )
        .unwrap();
    service.set_enabled(ChannelKind::WeCom, true).unwrap();
    let now = chrono::Utc::now().timestamp();
    service
        .observe_official_quota(official(now - 3, None, Some(2), None))
        .unwrap();
    protector.from.store(
        protector.calls.load(Ordering::SeqCst) + 2,
        Ordering::Release,
    );
    let result = service
        .observe_official_quota(official(now - 2, None, Some(1), None))
        .unwrap();
    assert!(result.iter().all(|r| r.state == "not_sent"));
    assert_eq!(transport.calls.load(Ordering::SeqCst), 0);
    let plain = protector
        .unseal(
            "AiGoodBro.Next.Windows.notifications.v1",
            &std::fs::read(root.join("channels.dpapi")).unwrap(),
        )
        .unwrap();
    let vault: Value = serde_json::from_slice(&plain).unwrap();
    assert_eq!(vault["card_changes"].as_object().unwrap().len(), 1);
    protector.from.store(usize::MAX, Ordering::Release);
    let reopened =
        NotificationService::with_components(root, protector, transport.clone()).unwrap();
    transport.json(json!({"errcode":0}));
    assert_eq!(reopened.drain_card_changes().unwrap()[0].state, "accepted");
    assert!(reopened.drain_card_changes().unwrap().is_empty());
    assert_eq!(transport.calls.load(Ordering::SeqCst), 1);
}

#[test]
fn pending_count_change_needs_fresh_verified_matching_end_count() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp
        .path()
        .canonicalize()
        .unwrap()
        .join("synthetic-fresh-outbox");
    let protector = Arc::new(FailingFromSeal {
        calls: AtomicUsize::new(0),
        from: AtomicUsize::new(usize::MAX),
    });
    let transport = SyntheticTransport::new();
    let service =
        NotificationService::with_components(root.clone(), protector.clone(), transport.clone())
            .unwrap();
    service
        .save_channel(
            ChannelKind::WeCom,
            "11111111-2222-3333-4444-555555555555".into(),
            None,
        )
        .unwrap();
    service.set_enabled(ChannelKind::WeCom, true).unwrap();
    let now = chrono::Utc::now().timestamp();
    service
        .observe_official_quota(official(now - 4, None, Some(2), None))
        .unwrap();
    protector.from.store(
        protector.calls.load(Ordering::SeqCst) + 2,
        Ordering::Release,
    );
    service
        .observe_official_quota(official(now - 3, None, Some(1), None))
        .unwrap();
    protector.from.store(usize::MAX, Ordering::Release);
    let reopened =
        NotificationService::with_components(root, protector, transport.clone()).unwrap();
    let unverified = OfficialQuotaObservation::new(
        "synthetic-quota-account",
        "Fixture",
        now - 2,
        false,
        None,
        None,
        None,
        Some(1),
        None,
    )
    .unwrap();
    assert!(reopened
        .observe_official_quota(unverified)
        .unwrap()
        .is_empty());
    assert!(reopened.drain_card_changes().unwrap().is_empty());
    assert_eq!(transport.calls.load(Ordering::SeqCst), 0);
    transport.json(json!({"errcode":0}));
    let result = reopened
        .observe_official_quota(official(now - 1, None, Some(1), None))
        .unwrap();
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].state, "accepted");
    assert_eq!(transport.calls.load(Ordering::SeqCst), 1);
}

#[test]
fn wecom_and_personal_use_shared_mac_message_options_without_enabling_either() {
    let f = Fixture::new();
    let mut options = MessageOptions::default();
    options.includes_quotas = false;
    options.notifies_five_hour_reset = false;
    f.service
        .set_options(ChannelKind::PersonalWeChat, options)
        .unwrap();
    for channel in [ChannelKind::WeCom, ChannelKind::PersonalWeChat] {
        let c = f.service.channel_state(channel).unwrap();
        assert!(!c.enabled);
        assert!(!c.options.includes_quotas);
        assert!(!c.options.notifies_five_hour_reset);
    }
    assert_eq!(f.transport.calls.load(Ordering::SeqCst), 0);
}

#[cfg(windows)]
#[test]
fn native_dpapi_roundtrip_notification_vault_is_opaque_without_network() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp
        .path()
        .canonicalize()
        .unwrap()
        .join("synthetic-dpapi-notifications");
    let transport = SyntheticTransport::new();
    let service = NotificationService::with_components(
        root.clone(),
        Arc::new(codexu_core::accounts::DpapiProtector),
        transport.clone(),
    )
    .unwrap();
    service
        .save_channel(
            ChannelKind::WeCom,
            "11111111-2222-3333-4444-555555555555".into(),
            None,
        )
        .unwrap();
    let bytes = std::fs::read(root.join("channels.dpapi")).unwrap();
    assert!(!String::from_utf8_lossy(&bytes).contains("11111111-2222"));
    assert!(
        NotificationService::with_components(
            root,
            Arc::new(codexu_core::accounts::DpapiProtector),
            transport.clone()
        )
        .unwrap()
        .channel_state(ChannelKind::WeCom)
        .unwrap()
        .credential_present
    );
    assert_eq!(transport.calls.load(Ordering::SeqCst), 0);
}
