//! Real native producer/service/vault/ledger, synthetic collaborators only.
//! No native transport, user account, external endpoint or App is invoked.
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
const CONTEXT: &str = "AiGoodBro.Next.Windows.notifications.v1";
struct Protector {
    fail: AtomicBool,
}
impl SecretProtector for Protector {
    fn seal(&self, c: &str, b: &[u8]) -> AccountResult<Vec<u8>> {
        if self.fail.load(Ordering::Acquire) {
            return Err(AccountError {
                code: "synthetic_seal_failed",
            });
        }
        let mut out = c.as_bytes().to_vec();
        out.push(0);
        out.extend(b.iter().map(|b| b ^ 0x5a));
        Ok(out)
    }
    fn unseal(&self, c: &str, b: &[u8]) -> AccountResult<Vec<u8>> {
        let mut prefix = c.as_bytes().to_vec();
        prefix.push(0);
        if !b.starts_with(&prefix) {
            return Err(AccountError {
                code: "synthetic_unseal_failed",
            });
        }
        Ok(b[prefix.len()..].iter().map(|b| b ^ 0x5a).collect())
    }
}
struct Source {
    steps: Mutex<VecDeque<(String, Result<PublicResetResponse>)>>,
    seen: Mutex<Vec<String>>,
    on_fetch: Mutex<Option<Box<dyn FnOnce() + Send>>>,
}
impl Source {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            steps: Mutex::new(VecDeque::new()),
            seen: Mutex::new(Vec::new()),
            on_fetch: Mutex::new(None),
        })
    }
    fn history(&self, cursor: Option<&str>, body: Value) {
        self.push(
            cursor
                .map(|s| format!("history:{s}"))
                .unwrap_or_else(|| "history".into()),
            PublicResetResponse {
                status: 200,
                body: body.to_string().into_bytes(),
                content_type: Some("application/json; charset=utf-8".into()),
                retry_after: None,
            },
        );
    }
    fn forecast(&self, html: String) {
        self.push(
            "forecast".into(),
            PublicResetResponse {
                status: 200,
                body: html.into_bytes(),
                content_type: Some("text/html".into()),
                retry_after: None,
            },
        );
    }
    fn push(&self, key: String, response: PublicResetResponse) {
        self.steps.lock().unwrap().push_back((key, Ok(response)));
    }
    fn checked(&self) {
        assert!(
            self.steps.lock().unwrap().is_empty(),
            "all declared source steps must be consumed"
        );
    }
}
impl PublicResetSource for Source {
    fn fetch(&self, r: &PublicResetRequest, c: &AtomicBool) -> Result<PublicResetResponse> {
        assert!(!c.load(Ordering::Acquire));
        let key = match r {
            PublicResetRequest::History { cursor: None } => "history".into(),
            PublicResetRequest::History { cursor: Some(c) } => format!("history:{c}"),
            PublicResetRequest::Forecast => "forecast".into(),
        };
        let endpoint = r.endpoint()?;
        assert_eq!(endpoint.scheme(), "https");
        assert_eq!(endpoint.host_str(), Some("codex-resets.com"));
        self.seen.lock().unwrap().push(key.clone());
        let step = self
            .steps
            .lock()
            .unwrap()
            .pop_front()
            .expect("unexpected source read forbidden");
        assert_eq!(step.0, key);
        let callback = self.on_fetch.lock().unwrap().take();
        if let Some(callback) = callback {
            callback();
        }
        step.1
    }
}
struct Transport {
    responses: Mutex<VecDeque<Result<TransportResponse>>>,
    seen: Mutex<Vec<(String, Value)>>,
    calls: AtomicUsize,
    on_send: Mutex<Option<Box<dyn FnOnce() + Send>>>,
}
impl Transport {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            responses: Mutex::new(VecDeque::new()),
            seen: Mutex::new(Vec::new()),
            calls: AtomicUsize::new(0),
            on_send: Mutex::new(None),
        })
    }
    fn response(&self, status: u16, body: Value) {
        self.responses
            .lock()
            .unwrap()
            .push_back(Ok(TransportResponse {
                status,
                body: body.to_string().into_bytes(),
            }));
    }
    fn accept(&self, count: usize) {
        for _ in 0..count {
            self.response(
                200,
                json!({"code":0,"errcode":0,"ok":true,"result":{"message_id":42}}),
            );
        }
    }
}
impl NotificationTransport for Transport {
    fn send(&self, r: &TransportRequest, c: &AtomicBool) -> Result<TransportResponse> {
        assert!(!c.load(Ordering::Acquire));
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.seen.lock().unwrap().push((
            r.endpoint().as_str().into(),
            serde_json::from_slice(r.body()).unwrap(),
        ));
        let callback = self.on_send.lock().unwrap().take();
        if let Some(callback) = callback {
            callback();
        }
        self.responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("unexpected message send forbidden")
    }
}
struct Fixture {
    _temp: tempfile::TempDir,
    root: PathBuf,
    service: Arc<NotificationService>,
    source: Arc<Source>,
    transport: Arc<Transport>,
    protector: Arc<Protector>,
    at: i64,
}
impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = temp
            .path()
            .canonicalize()
            .unwrap()
            .join("synthetic-notifications");
        let source = Source::new();
        let transport = Transport::new();
        let protector = Arc::new(Protector {
            fail: AtomicBool::new(false),
        });
        let service = NotificationService::with_components_and_public_source(
            root.clone(),
            protector.clone(),
            transport.clone(),
            source.clone(),
        )
        .unwrap();
        Self {
            _temp: temp,
            root,
            service,
            source,
            transport,
            protector,
            at: chrono::Utc::now().timestamp_millis() - 1000,
        }
    }
    fn setup(&self, kind: ChannelKind) {
        let (secret, target) = match kind {
            ChannelKind::Feishu => (
                "https://open.feishu.cn/open-apis/bot/v2/hook/synthetic-not-real".into(),
                None,
            ),
            ChannelKind::Telegram => (
                "12345:synthetic_token_which_is_not_real_123456".into(),
                Some("-12345".into()),
            ),
            ChannelKind::WeCom => ("11111111-2222-3333-4444-555555555555".into(), None),
            ChannelKind::PersonalWeChat => {
                panic!("personal requires its separate synthetic QR binding tests")
            }
        };
        self.service.save_channel(kind, secret, target).unwrap();
        self.service.set_enabled(kind, true).unwrap();
    }
    fn initial(&self) {
        self.source.history(
            None,
            page(
                vec![row(
                    "observed-baseline",
                    self.at - 100000,
                    "Baseline public post",
                )],
                false,
                None,
            ),
        );
        self.source.forecast(empty());
        self.service
            .set_public_reset_delivery_enabled(true)
            .unwrap();
        self.service.check_public_reset_now().unwrap();
        assert_eq!(self.sent(), 0);
    }
    fn next(&self, rows: Vec<Value>, html: String) {
        self.source.history(None, page(rows, false, None));
        self.source.forecast(html);
    }
    fn base(&self) -> Value {
        row(
            "observed-baseline",
            self.at - 100000,
            "Baseline public post",
        )
    }
    fn sent(&self) -> usize {
        self.transport.calls.load(Ordering::SeqCst)
    }
    fn reopen(&self) -> Arc<NotificationService> {
        NotificationService::with_components_and_public_source(
            self.root.clone(),
            self.protector.clone(),
            self.transport.clone(),
            self.source.clone(),
        )
        .unwrap()
    }
    fn vault(&self) -> Value {
        serde_json::from_slice(
            &self
                .protector
                .unseal(
                    CONTEXT,
                    &std::fs::read(self.root.join("channels.dpapi")).unwrap(),
                )
                .unwrap(),
        )
        .unwrap()
    }
}
fn iso(at: i64) -> String {
    chrono::DateTime::from_timestamp_millis(at)
        .unwrap()
        .to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}
fn row(id: &str, at: i64, text: &str) -> Value {
    json!({"id":id,"reset_type":"regular","announced_at":iso(at),"text":text,"source":{"type":"observed","author":null,"url":null}})
}
fn post_row(id: &str, at: i64) -> Value {
    json!({"id":id,"reset_type":"banked","announced_at":iso(at),"text":"Verified public source","source":{"type":"x_post","author":"thsottiaux","url":format!("https://x.com/thsottiaux/status/{id}")}})
}
fn page(rows: Vec<Value>, more: bool, cursor: Option<&str>) -> Value {
    json!({"data":rows,"pagination":{"has_more":more,"next_cursor":cursor},"meta":{"api_version":"v1","generated_at":iso(chrono::Utc::now().timestamp_millis())}})
}
fn document(body: &str) -> String {
    format!("<html><meta charset=utf-8><body class='codex-resets'><div class='hero-figure'>{body}</div></body></html>")
}
fn empty() -> String {
    document("<div data-role='pending-reset'></div>")
}
fn snowflake(at: i64) -> String {
    (((at - 1_288_834_974_657) as u64) << 22).to_string()
}
fn forecast(id: &str, deadline: Option<i64>) -> String {
    document(&format!("<section data-role='scheduled-reset' data-scheduled-for='{}'><p>Unconfirmed public forecast</p><a href='https://x.com/thsottiaux/status/{id}'>Original source</a></section>",deadline.map(iso).unwrap_or_default()))
}
fn public_phase(f: &Fixture, channel: &str, id: &str) -> String {
    f.vault()["public_reset"]["completed"][channel]["records"][id]["phase"]
        .as_str()
        .unwrap()
        .to_owned()
}

#[test]
fn public_reset_defaults_off_and_ui_check_only_queues_without_io() {
    let f = Fixture::new();
    let s = f.service.public_reset_delivery_state().unwrap();
    assert!(!s.enabled);
    assert_eq!(s.phase, "disabled");
    f.service.request_public_reset_check().unwrap();
    assert!(f.source.seen.lock().unwrap().is_empty());
    assert_eq!(f.sent(), 0);
}

#[test]
fn public_reset_first_enable_baselines_and_restart_does_not_replay() {
    let f = Fixture::new();
    f.setup(ChannelKind::Feishu);
    f.setup(ChannelKind::Telegram);
    f.initial();
    let new = row("observed-new", f.at, "New public announcement");
    f.next(vec![new.clone(), f.base()], empty());
    f.transport.accept(2);
    f.service.check_public_reset_now().unwrap();
    assert_eq!(f.sent(), 2);
    assert_eq!(public_phase(&f, "feishu", "observed-new"), "sent");
    f.next(vec![new, f.base()], empty());
    f.reopen().check_public_reset_now().unwrap();
    assert_eq!(f.sent(), 2);
    f.source.checked();
}

#[test]
fn public_reset_multiple_new_rows_are_delivered_oldest_first() {
    let f = Fixture::new();
    f.setup(ChannelKind::Feishu);
    f.initial();
    f.next(
        vec![
            row("observed-newer", f.at, "Newer public post"),
            row("observed-older", f.at - 1000, "Older public post"),
            f.base(),
        ],
        empty(),
    );
    f.transport.accept(2);
    f.service.check_public_reset_now().unwrap();
    assert_eq!(f.sent(), 2);
    let sent = f.transport.seen.lock().unwrap();
    assert!(sent[0].1.to_string().contains("Older public post"));
    assert!(sent[1].1.to_string().contains("Newer public post"));
}

#[test]
fn public_reset_invalid_source_metadata_or_duplicates_preserve_durable_ledger() {
    let f = Fixture::new();
    f.setup(ChannelKind::Feishu);
    f.initial();
    let before = std::fs::read(f.root.join("channels.dpapi")).unwrap();
    let mut cases = Vec::new();
    let mut p = page(vec![f.base()], false, None);
    p["meta"]["api_version"] = json!("v2");
    cases.push(p);
    let mut p = page(vec![f.base()], false, None);
    p["meta"]["generated_at"] = json!(iso(f.at - 2 * 86400000));
    cases.push(p);
    let mut a = post_row("123", f.at);
    a["source"]["author"] = json!("other");
    cases.push(page(vec![a], false, None));
    let mut a = post_row("123", f.at);
    a["source"]["url"] = json!("https://x.com/thsottiaux/status/123?untrusted=1");
    cases.push(page(vec![a], false, None));
    cases.push(page(vec![f.base(), f.base()], false, None));
    cases.push(page(vec![f.base()], true, Some("bad\nvalue")));
    for p in cases {
        f.source.history(None, p);
        assert_eq!(
            f.service.check_public_reset_now().err().unwrap().code(),
            "public_reset_invalid_response"
        );
        assert_eq!(
            std::fs::read(f.root.join("channels.dpapi")).unwrap(),
            before
        );
    }
    assert_eq!(f.sent(), 0);
    f.source.checked();
}

#[test]
fn public_reset_history_accepts_mac_64_digit_source_ids_but_not_forecast_snowflakes() {
    let f = Fixture::new();
    f.setup(ChannelKind::Feishu);
    f.initial();
    let id = "9".repeat(64);
    f.next(vec![post_row(&id, f.at), f.base()], empty());
    f.transport.accept(1);
    f.service.check_public_reset_now().unwrap();
    assert_eq!(f.sent(), 1);
    f.next(vec![f.base()], forecast(&id, None));
    f.service.check_public_reset_now().unwrap();
    assert_eq!(
        f.service
            .public_reset_delivery_state()
            .unwrap()
            .failure_code,
        Some("public_forecast_invalid_response")
    );
    assert_eq!(f.sent(), 1);
}

#[test]
fn public_reset_disable_during_fetch_discards_late_result() {
    let f = Fixture::new();
    f.setup(ChannelKind::Feishu);
    f.initial();
    f.next(
        vec![row("observed-late", f.at, "Must not deliver"), f.base()],
        empty(),
    );
    let service = f.service.clone();
    *f.source.on_fetch.lock().unwrap() = Some(Box::new(move || {
        service.set_public_reset_delivery_enabled(false).unwrap();
    }));
    assert!(f.service.check_public_reset_now().is_err());
    assert_eq!(f.sent(), 0);
    assert!(!f.service.public_reset_delivery_state().unwrap().enabled);
    assert!(f.vault()["public_reset"]["completed"]["feishu"]["records"]
        .get("observed-late")
        .is_none());
}

#[test]
fn public_reset_cancelled_late_acceptance_is_uncertain_and_never_retried() {
    let f = Fixture::new();
    f.setup(ChannelKind::Feishu);
    f.initial();
    let a = row("observed-cancelled", f.at, "Public event");
    f.next(vec![a.clone(), f.base()], empty());
    f.transport.accept(1);
    let service = f.service.clone();
    *f.transport.on_send.lock().unwrap() = Some(Box::new(move || {
        service.set_public_reset_delivery_enabled(false).unwrap();
    }));
    f.service.check_public_reset_now().unwrap();
    assert_eq!(f.sent(), 1);
    assert_eq!(
        public_phase(&f, "feishu", "observed-cancelled"),
        "uncertain"
    );
    f.service.set_public_reset_delivery_enabled(true).unwrap();
    f.next(vec![a.clone(), f.base()], empty());
    f.reopen().check_public_reset_now().unwrap();
    f.next(vec![a, f.base()], empty());
    f.reopen().check_public_reset_now().unwrap();
    assert_eq!(f.sent(), 1);
}

#[test]
fn public_reset_transport_or_500_is_uncertain_and_target_change_does_not_replay() {
    for failure in ["transport", "http500", "config_change"] {
        let f = Fixture::new();
        f.setup(ChannelKind::Feishu);
        f.initial();
        let a = row("observed-uncertain", f.at, "Public event");
        f.next(vec![a.clone(), f.base()], empty());
        match failure {
            "transport" => f
                .transport
                .responses
                .lock()
                .unwrap()
                .push_back(Err(Failure("transport_failed"))),
            "http500" => f.transport.response(500, json!({})),
            _ => {
                f.transport.accept(1);
                let s = f.service.clone();
                *f.transport.on_send.lock().unwrap() = Some(Box::new(move || {
                    s.save_channel(
                        ChannelKind::Feishu,
                        "https://open.feishu.cn/open-apis/bot/v2/hook/synthetic-new-not-real"
                            .into(),
                        None,
                    )
                    .unwrap();
                }));
            }
        }
        f.service.check_public_reset_now().unwrap();
        assert_eq!(
            public_phase(&f, "feishu", "observed-uncertain"),
            "uncertain"
        );
        f.next(vec![a, f.base()], empty());
        f.reopen().check_public_reset_now().unwrap();
        assert_eq!(f.sent(), 1);
        assert!(f.transport.seen.lock().unwrap()[0]
            .0
            .ends_with("synthetic-not-real"));
    }
}

#[test]
fn public_reset_sending_crash_recovers_uncertain_without_overwriting_complete_receipts() {
    let f = Fixture::new();
    f.setup(ChannelKind::Feishu);
    f.initial();
    let a = row("observed-interrupted", f.at, "Public event");
    f.next(vec![a.clone(), f.base()], empty());
    f.transport.accept(1);
    let p = f.protector.clone();
    *f.transport.on_send.lock().unwrap() = Some(Box::new(move || {
        p.fail.store(true, Ordering::Release);
    }));
    assert!(f.service.check_public_reset_now().is_err());
    assert_eq!(f.sent(), 1);
    assert_eq!(
        public_phase(&f, "feishu", "observed-interrupted"),
        "sending"
    );
    f.protector.fail.store(false, Ordering::Release);
    let restored = f.reopen();
    assert_eq!(
        public_phase(&f, "feishu", "observed-interrupted"),
        "uncertain"
    );
    f.next(vec![a, f.base()], empty());
    restored.check_public_reset_now().unwrap();
    assert_eq!(f.sent(), 1);
}

#[test]
fn public_reset_native_source_rate_limit_is_persisted_and_manual_check_cannot_bypass() {
    let f = Fixture::new();
    f.setup(ChannelKind::Feishu);
    f.initial();
    f.source.push(
        "history".into(),
        PublicResetResponse {
            status: 429,
            body: vec![],
            content_type: None,
            retry_after: Some("900".into()),
        },
    );
    assert_eq!(
        f.service.check_public_reset_now().err().unwrap().code(),
        "public_reset_rate_limited"
    );
    let calls = f.source.seen.lock().unwrap().len();
    assert!(f.reopen().check_public_reset_now().is_err());
    assert_eq!(f.source.seen.lock().unwrap().len(), calls);
    assert!(
        f.service
            .public_reset_delivery_state()
            .unwrap()
            .next_check_at
            .unwrap()
            > f.at + 800000
    );
    assert_eq!(f.sent(), 0);
}

#[test]
fn public_reset_pagination_gap_is_bounded_and_checkpointed_without_new_admission() {
    let f = Fixture::new();
    f.setup(ChannelKind::Feishu);
    f.initial();
    f.source.history(
        None,
        page(
            vec![row("observed-new-head", f.at, "New head")],
            true,
            Some("cursor-1"),
        ),
    );
    f.source.forecast(empty());
    for i in 1..=4 {
        f.source.history(
            Some(&format!("cursor-{i}")),
            page(
                vec![row(
                    &format!("observed-page-{i}"),
                    f.at - i * 1000,
                    "Unconnected history",
                )],
                true,
                Some(&format!("cursor-{}", i + 1)),
            ),
        );
    }
    let state = f.service.check_public_reset_now().unwrap();
    assert_eq!(state.failure_code, Some("public_reset_history_gap"));
    assert_eq!(f.sent(), 0);
    let vault = f.vault();
    assert_eq!(vault["public_reset"]["checkpoint"]["cursor"], "cursor-5");
    assert_eq!(
        vault["public_reset"]["completed"]["feishu"]["records"]
            .as_object()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        f.source
            .seen
            .lock()
            .unwrap()
            .iter()
            .filter(|s| s.starts_with("history"))
            .count(),
        6
    );
    f.source.checked();
}

#[test]
fn public_reset_cursor_cycle_or_page_time_inversion_fails_closed() {
    for cycle in [true, false] {
        let f = Fixture::new();
        f.setup(ChannelKind::Feishu);
        f.initial();
        f.source.history(
            None,
            page(
                vec![row("observed-new-head", f.at, "New head")],
                true,
                Some("cursor-1"),
            ),
        );
        f.source.forecast(empty());
        let at = if cycle { f.at - 1000 } else { f.at + 1000 };
        f.source.history(
            Some("cursor-1"),
            page(
                vec![row("observed-tail", at, "Disconnected tail")],
                true,
                Some("cursor-1"),
            ),
        );
        let state = f.service.check_public_reset_now().unwrap();
        assert!(state.failure_code.is_some());
        assert_eq!(f.sent(), 0);
        assert_eq!(
            f.vault()["public_reset"]["completed"]["feishu"]["records"]
                .as_object()
                .unwrap()
                .len(),
            1
        );
        f.source.checked();
    }
}

#[test]
fn public_reset_contiguous_recovery_admits_only_after_known_overlap() {
    let f = Fixture::new();
    f.setup(ChannelKind::Feishu);
    f.initial();
    f.source.history(
        None,
        page(
            vec![row("observed-new-head", f.at, "New public head")],
            true,
            Some("tail"),
        ),
    );
    f.source.forecast(empty());
    f.source
        .history(Some("tail"), page(vec![f.base()], false, None));
    f.transport.accept(1);
    f.service.check_public_reset_now().unwrap();
    assert_eq!(f.sent(), 1);
    assert_eq!(public_phase(&f, "feishu", "observed-new-head"), "sent");
    f.source.checked();
}

#[test]
fn public_reset_retained_pending_needs_current_source_after_partial_batch_and_restart() {
    let f = Fixture::new();
    f.setup(ChannelKind::Feishu);
    f.initial();
    let rows = (0..22)
        .rev()
        .map(|i| {
            row(
                &format!("observed-queued-{i}"),
                f.at + i * 10,
                "Retained public text",
            )
        })
        .chain(std::iter::once(f.base()))
        .collect();
    f.next(rows, empty());
    f.transport.accept(20);
    f.service.check_public_reset_now().unwrap();
    assert_eq!(f.sent(), 20);
    assert_eq!(
        f.service
            .public_reset_delivery_state()
            .unwrap()
            .pending_count,
        2
    );
    f.next(vec![f.base()], empty());
    let state = f.reopen().check_public_reset_now().unwrap();
    assert_eq!(state.failure_code, Some("public_reset_history_gap"));
    assert_eq!(f.sent(), 20);
    assert_eq!(state.pending_count, 2);
    // A current known overlap alone cannot prove the two saved pending rows.
    // This later contiguous cursor response supplies their exact identities.
    f.source.history(
        None,
        page(
            vec![row(
                "observed-queued-21",
                f.at + 210,
                "Retained public text",
            )],
            true,
            Some("recover-pending"),
        ),
    );
    f.source.forecast(empty());
    f.source.history(
        Some("recover-pending"),
        page(
            vec![
                row("observed-queued-20", f.at + 200, "Retained public text"),
                row("observed-queued-19", f.at + 190, "Retained public text"),
            ],
            false,
            None,
        ),
    );
    f.transport.accept(2);
    f.reopen().check_public_reset_now().unwrap();
    assert_eq!(f.sent(), 22);
    assert_eq!(
        f.service
            .public_reset_delivery_state()
            .unwrap()
            .pending_count,
        0
    );
    f.source.checked();
}

#[test]
fn public_reset_recovered_pending_changed_source_tuple_cannot_send_saved_text() {
    let f = Fixture::new();
    f.setup(ChannelKind::Feishu);
    f.initial();
    let pending = row("observed-pending", f.at, "Saved safe public text");
    // A synthetic source gives 21 new records so the chronological batch cap
    // leaves the selected last one durably pending before service restart.
    let mut rows = (0..20)
        .rev()
        .map(|i| {
            row(
                &format!("observed-before-{i}"),
                f.at - 1000 + i * 10,
                "Earlier safe public text",
            )
        })
        .collect::<Vec<_>>();
    rows.insert(0, pending.clone());
    rows.push(f.base());
    f.next(rows, empty());
    f.transport.accept(20);
    f.service.check_public_reset_now().unwrap();
    assert_eq!(f.sent(), 20);
    let before =
        f.vault()["public_reset"]["completed"]["feishu"]["records"]["observed-pending"].clone();
    assert_eq!(before["phase"], "pending");
    let mut changed = pending.clone();
    changed["reset_type"] = json!("banked");
    f.next(vec![changed, f.base()], empty());
    assert!(f.reopen().check_public_reset_now().is_err());
    assert_eq!(f.sent(), 20);
    assert_eq!(
        f.vault()["public_reset"]["completed"]["feishu"]["records"]["observed-pending"],
        before
    );
    f.next(vec![pending, f.base()], empty());
    f.transport.accept(1);
    f.reopen().check_public_reset_now().unwrap();
    assert_eq!(f.sent(), 21);
    assert_eq!(public_phase(&f, "feishu", "observed-pending"), "sent");
}

#[test]
fn public_reset_forecast_is_feishu_only_and_completed_stage_has_independent_dedupe() {
    let f = Fixture::new();
    for k in [
        ChannelKind::Feishu,
        ChannelKind::Telegram,
        ChannelKind::WeCom,
    ] {
        f.setup(k);
    }
    f.initial();
    let id = snowflake(f.at - 1000);
    f.next(vec![f.base()], forecast(&id, Some(f.at + 3600000)));
    f.transport.accept(1);
    f.service.check_public_reset_now().unwrap();
    assert_eq!(f.sent(), 1);
    assert!(f.transport.seen.lock().unwrap()[0]
        .0
        .contains("open.feishu.cn"));
    assert_eq!(
        f.vault()["public_reset"]["forecast"]["records"][&id]["phase"],
        "sent"
    );
    f.next(vec![post_row(&id, f.at - 1000), f.base()], empty());
    f.transport.accept(3);
    f.service.check_public_reset_now().unwrap();
    assert_eq!(f.sent(), 4);
    assert_eq!(public_phase(&f, "feishu", &id), "sent");
    assert_eq!(
        f.vault()["public_reset"]["forecast"]["records"][&id]["phase"],
        "sent"
    );
}

#[test]
fn public_reset_forecast_first_observation_and_already_completed_source_are_not_sent() {
    let f = Fixture::new();
    f.setup(ChannelKind::Feishu);
    let first = snowflake(f.at - 10000);
    f.next(vec![f.base()], forecast(&first, None));
    f.service.set_public_reset_delivery_enabled(true).unwrap();
    f.service.check_public_reset_now().unwrap();
    assert_eq!(f.sent(), 0);
    let next = snowflake(f.at - 1000);
    f.next(
        vec![post_row(&next, f.at - 1000), f.base()],
        forecast(&next, None),
    );
    f.transport.accept(1);
    f.service.check_public_reset_now().unwrap();
    assert_eq!(f.sent(), 1);
    assert_eq!(
        f.vault()["public_reset"]["forecast"]["records"][&next]["phase"],
        "baseline"
    );
    assert!(f.transport.seen.lock().unwrap()[0]
        .1
        .to_string()
        .contains("公开重置公告"));
}

#[test]
fn public_reset_forecast_rejection_retries_but_unknown_transport_never_does() {
    for uncertain in [false, true] {
        let f = Fixture::new();
        f.setup(ChannelKind::Feishu);
        f.initial();
        let id = snowflake(f.at - 1000);
        f.next(vec![f.base()], forecast(&id, None));
        if uncertain {
            f.transport
                .responses
                .lock()
                .unwrap()
                .push_back(Err(Failure("transport_failed")));
        } else {
            f.transport.response(400, json!({"code":19001}));
        }
        f.service.check_public_reset_now().unwrap();
        let phase = f.vault()["public_reset"]["forecast"]["records"][&id]["phase"].clone();
        assert_eq!(phase, if uncertain { "uncertain" } else { "pending" });
        f.next(vec![f.base()], forecast(&id, None));
        if !uncertain {
            f.transport.accept(1);
        }
        f.reopen().check_public_reset_now().unwrap();
        assert_eq!(f.sent(), if uncertain { 1 } else { 2 });
    }
}

#[test]
fn public_reset_forecast_inert_html_unsourced_watch_and_malformed_layout_cannot_authorize() {
    let f = Fixture::new();
    f.setup(ChannelKind::Feishu);
    let id = snowflake(f.at - 1000);
    let bait = forecast(&id, None);
    f.next(
        vec![f.base()],
        document(&format!(
            "<script>{bait}</script><!-- {bait} --><div data-role='pending-reset'></div>"
        )),
    );
    f.service.set_public_reset_delivery_enabled(true).unwrap();
    f.service.check_public_reset_now().unwrap();
    assert!(f
        .service
        .public_reset_delivery_state()
        .unwrap()
        .forecast
        .is_none());
    f.next(vec![f.base()],document(&format!("<section data-role='reset-watch' data-expires-at='{}'><p class='watch-rumor'>Unlinked site rumor</p></section>",iso(f.at+3600000))));
    f.service.check_public_reset_now().unwrap();
    assert_eq!(f.sent(), 0);
    assert!(f
        .service
        .public_reset_delivery_state()
        .unwrap()
        .forecast
        .is_none());
    f.next(vec![f.base()], forecast(&id, Some(f.at - 500)));
    f.transport.accept(1);
    f.service.check_public_reset_now().unwrap();
    let state = f.service.public_reset_delivery_state().unwrap();
    let cached = state.forecast.unwrap();
    assert_eq!(cached.announced_at, f.at - 1000);
    assert_eq!(cached.phase, "awaiting_confirmation");
    assert!(cached.fetched_at > cached.announced_at);
    f.next(
        vec![f.base()],
        document("<div data-role='changed-layout'>Unknown</div>"),
    );
    f.service.check_public_reset_now().unwrap();
    let restored = f.reopen().public_reset_delivery_state().unwrap();
    assert_eq!(restored.forecast.unwrap().id, id);
    assert_eq!(f.sent(), 1);
    f.next(vec![f.base()], empty());
    f.service.check_public_reset_now().unwrap();
    assert!(f
        .reopen()
        .public_reset_delivery_state()
        .unwrap()
        .forecast
        .is_none());
}

#[test]
fn public_reset_public_copy_drops_destinations_and_preserves_unconfirmed_wording() {
    let f = Fixture::new();
    f.setup(ChannelKind::Feishu);
    f.initial();
    f.next(vec![row("observed-unconfirmed",f.at,"We may reset tomorrow https://fixture.invalid/route user@fixture.invalid Keep safe") ,f.base()],empty());
    f.transport.accept(1);
    f.service.check_public_reset_now().unwrap();
    let sent = f.transport.seen.lock().unwrap()[0].1.to_string();
    assert!(!sent.contains("fixture.invalid"));
    assert!(sent.contains("尚未确认"));
    let dto = serde_json::to_string(&f.service.public_reset_delivery_state().unwrap()).unwrap();
    assert!(!dto.contains("synthetic-not-real"));
    assert!(!dto.contains("fixture.invalid"));
    assert!(dto.contains("Keep safe"));
}

#[test]
fn public_reset_unsourced_watch_does_not_establish_forecast_baseline() {
    let f = Fixture::new();
    f.setup(ChannelKind::Feishu);
    f.next(vec![f.base()],document(&format!("<section data-role='reset-watch' data-expires-at='{}'><p class='watch-rumor'>Unconfirmed site watch</p></section>",iso(f.at+3600000))));
    f.service.set_public_reset_delivery_enabled(true).unwrap();
    f.service.check_public_reset_now().unwrap();
    assert_eq!(f.vault()["public_reset"]["forecast"]["initialized"], false);
    let id = snowflake(f.at - 1000);
    f.next(vec![f.base()], forecast(&id, None));
    f.service.check_public_reset_now().unwrap();
    assert_eq!(f.sent(), 0);
    assert_eq!(
        f.vault()["public_reset"]["forecast"]["records"][&id]["phase"],
        "baseline"
    );
}

#[test]
fn public_reset_forecast_invalid_sources_duplicate_banners_and_script_links_preserve_cache() {
    let f = Fixture::new();
    f.setup(ChannelKind::Feishu);
    let id = snowflake(f.at - 1000);
    let known = forecast(&id, None);
    f.next(vec![f.base()], known.clone());
    f.service.set_public_reset_delivery_enabled(true).unwrap();
    f.service.check_public_reset_now().unwrap();
    let source = format!("https://x.com/thsottiaux/status/{id}");
    let cases=[known.replace(&source,&format!("{source}?s=1")),known.replace(&source,&source.replace("x.com","x.com:443")),known.replace(&source,&source.replace("https://","https://@")),known.replace(&source,&source.replace("thsottiaux","untrusted")),document(&format!("{}{}",known,known)),document(&format!("<section data-role='scheduled-reset' data-scheduled-for=''><script><a href='{source}'>Hidden</a></script></section>"))];
    for html in cases {
        f.next(vec![f.base()], html);
        let state = f.service.check_public_reset_now().unwrap();
        assert_eq!(state.failure_code, Some("public_forecast_invalid_response"));
        assert_eq!(state.forecast.unwrap().id, id);
        assert_eq!(f.sent(), 0);
    }
    assert_eq!(
        f.reopen()
            .public_reset_delivery_state()
            .unwrap()
            .forecast
            .unwrap()
            .id,
        id
    );
}

#[test]
fn public_reset_fixed_endpoint_encodes_cursor_and_rejects_control_data() {
    let cursor = "https://fixture.invalid/path?destination=elsewhere#fragment";
    let url = PublicResetRequest::History {
        cursor: Some(cursor.into()),
    }
    .endpoint()
    .unwrap();
    assert_eq!(url.host_str(), Some("codex-resets.com"));
    assert_eq!(url.path(), "/api/v1/resets");
    assert_eq!(
        url.query_pairs().find(|(k, _)| k == "cursor").unwrap().1,
        cursor
    );
    assert!(PublicResetRequest::History {
        cursor: Some("bad\nvalue".into())
    }
    .endpoint()
    .is_err());
    assert_eq!(
        PublicResetRequest::Forecast.endpoint().unwrap().as_str(),
        "https://codex-resets.com/zh-CN"
    );
}

#[test]
fn public_reset_source_redirect_and_wrong_mime_never_update_or_send() {
    for (status, mime) in [
        (302, Some("application/json")),
        (200, Some("text/html")),
        (200, None),
    ] {
        let f = Fixture::new();
        f.setup(ChannelKind::Feishu);
        f.initial();
        let before = std::fs::read(f.root.join("channels.dpapi")).unwrap();
        f.source.push(
            "history".into(),
            PublicResetResponse {
                status,
                body: page(
                    vec![row("observed-invalid", f.at, "Untrusted response")],
                    false,
                    None,
                )
                .to_string()
                .into_bytes(),
                content_type: mime.map(str::to_owned),
                retry_after: None,
            },
        );
        assert!(f.service.check_public_reset_now().is_err());
        assert_eq!(
            std::fs::read(f.root.join("channels.dpapi")).unwrap(),
            before
        );
        assert_eq!(f.sent(), 0);
    }
}

#[test]
fn public_reset_owned_monitor_checks_only_after_opt_in_and_cancels_without_spawn_per_poll() {
    use std::time::{Duration, Instant};
    let f = Fixture::new();
    f.setup(ChannelKind::Feishu);
    let monitor = f.service.start_monitor().unwrap();
    assert!(f.service.start_monitor().is_err());
    std::thread::sleep(Duration::from_millis(50));
    assert!(f.source.seen.lock().unwrap().is_empty());
    f.source.history(None, page(vec![f.base()], false, None));
    f.source.forecast(empty());
    f.service.set_public_reset_delivery_enabled(true).unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    while f
        .service
        .public_reset_delivery_state()
        .unwrap()
        .checked_at
        .is_none()
    {
        assert!(
            Instant::now() < deadline,
            "owned monitor did not process queued native source check"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    monitor.cancel();
    let deadline = Instant::now() + Duration::from_secs(3);
    while !monitor.is_finished() {
        assert!(Instant::now() < deadline, "owned monitor did not cancel");
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(f.sent(), 0);
    f.source.checked();
    f.service.cancel_inflight_for_exit();
    assert!(f.service.request_public_reset_check().is_err());
}

#[test]
fn public_reset_existing_id_cannot_change_kind_or_source_time() {
    let f = Fixture::new();
    f.setup(ChannelKind::Feishu);
    f.initial();
    let id = "observed-saved";
    let a = row(id, f.at, "Original public text");
    f.next(vec![a.clone(), f.base()], empty());
    f.transport.accept(1);
    f.service.check_public_reset_now().unwrap();
    let before = f.vault()["public_reset"]["completed"]["feishu"]["records"][id].clone();
    for changed in [
        {
            let mut a = a.clone();
            a["reset_type"] = json!("banked");
            a
        },
        row(id, f.at - 2000, "Changed source time"),
    ] {
        f.next(vec![changed, f.base()], empty());
        let state = f.service.check_public_reset_now().unwrap();
        assert_eq!(state.failure_code, Some("public_reset_source_changed"));
        assert_eq!(
            f.vault()["public_reset"]["completed"]["feishu"]["records"][id],
            before
        );
        assert_eq!(f.sent(), 1);
    }
}

#[test]
fn public_reset_forecast_cannot_send_without_this_check_validated_completed_page() {
    let f = Fixture::new();
    f.setup(ChannelKind::Feishu);
    f.initial();
    let before = f.vault()["public_reset"]["forecast"].clone();
    let mut invalid = page(vec![f.base()], false, None);
    invalid["meta"]["api_version"] = json!("untrusted");
    f.source.history(None, invalid);
    assert!(f.service.check_public_reset_now().is_err());
    assert_eq!(f.vault()["public_reset"]["forecast"], before);
    assert_eq!(f.sent(), 0);
    f.source.checked();
}

#[test]
fn public_reset_reenable_and_late_channel_binding_baseline_new_history() {
    let f = Fixture::new();
    f.setup(ChannelKind::Feishu);
    f.initial();
    f.service.set_public_reset_delivery_enabled(false).unwrap();
    let history = row("observed-disabled-history", f.at, "While disabled");
    f.next(vec![history.clone(), f.base()], empty());
    f.service.check_public_reset_now().unwrap();
    assert_eq!(f.sent(), 0);
    f.service.set_public_reset_delivery_enabled(true).unwrap();
    f.next(vec![history.clone(), f.base()], empty());
    f.service.check_public_reset_now().unwrap();
    assert_eq!(f.sent(), 0);
    assert_eq!(
        public_phase(&f, "feishu", "observed-disabled-history"),
        "baseline"
    );
    f.setup(ChannelKind::Telegram);
    f.next(vec![history, f.base()], empty());
    f.service.check_public_reset_now().unwrap();
    assert_eq!(f.sent(), 0);
    assert_eq!(
        public_phase(&f, "telegram", "observed-disabled-history"),
        "baseline"
    );
}
