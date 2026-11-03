//! Synthetic credentials, isolated vault and injected non-network runtime only.
use super::*;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde_json::json;
use std::sync::atomic::AtomicUsize;
struct Protector;
impl SecretProtector for Protector {
    fn seal(&self, _: &str, b: &[u8]) -> AccountResult<Vec<u8>> {
        Ok(b.iter().map(|v| v ^ 0x6b).collect())
    }
    fn unseal(&self, c: &str, b: &[u8]) -> AccountResult<Vec<u8>> {
        self.seal(c, b)
    }
}
struct Runtime {
    quota: Mutex<Value>,
    outcome: Mutex<&'static str>,
    keys: Mutex<Vec<String>>,
    posts: AtomicUsize,
    response: Mutex<(u16, Value)>,
    tracking: Mutex<Value>,
    capacity: Mutex<u32>,
    review_calls: AtomicUsize,
    after_consume: Mutex<Option<Box<dyn Fn() + Send>>>,
}
impl ActionRuntime for Runtime {
    fn review(
        &self,
        _: &Path,
        _: &StoredCredential,
        admit: &dyn Fn() -> AccountResult<()>,
    ) -> AccountResult<Value> {
        admit()?;
        self.review_calls.fetch_add(1, Ordering::AcqRel);
        Ok(self.quota.lock().unwrap().clone())
    }
    fn consume(
        &self,
        _: &Path,
        c: &StoredCredential,
        card: &str,
        expiry: i64,
        key: &str,
        admit: &dyn Fn() -> AccountResult<()>,
    ) -> AccountResult<&'static str> {
        admit()?;
        let q = self.quota.lock().unwrap();
        let actual = maintenance::manual_card(&q, &c.identity.account_id, ms())
            .map_err(|_| fail("reset_card_unavailable"))?;
        if actual.id != card || actual.expires_at_ms != expiry {
            return Err(fail("manual_action_identity_changed"));
        }
        self.keys.lock().unwrap().push(key.into());
        if let Some(action) = self.after_consume.lock().unwrap().take() {
            action();
        }
        Ok(*self.outcome.lock().unwrap())
    }
    fn http(
        &self,
        c: &StoredCredential,
        r: &HttpRequest,
        admit: &dyn Fn() -> AccountResult<()>,
    ) -> AccountResult<HttpResponse> {
        admit()?;
        assert!(matches!(r.language.as_str(), "en" | "zh"));
        let (status, value) = if r.method == "POST" {
            self.posts.fetch_add(1, Ordering::AcqRel);
            assert_eq!(r.path, "/referrals/invite");
            let body: Value = serde_json::from_slice(r.body.as_ref().unwrap()).unwrap();
            assert_eq!(body["entrypoint"], "persistent");
            self.response.lock().unwrap().clone()
        } else if r.path == "/wham/accounts/check" {
            (
                200,
                json!({"accounts":[{"id":c.identity.account_id,"structure":"personal"}]}),
            )
        } else if r.path.starts_with("/referrals/invite/eligibility?") {
            (
                200,
                json!({"should_show":true,"offer_id":"credits_250","title":"Invite","rules":[],"remaining_send_capacity":*self.capacity.lock().unwrap(),"remaining_reward_capacity":5,"requires_explicit_confirmation":true}),
            )
        } else if r.path.starts_with("/referrals/invite/tracking?") {
            (200, self.tracking.lock().unwrap().clone())
        } else {
            panic!("unexpected synthetic route")
        };
        Ok(HttpResponse {
            status,
            body: serde_json::to_vec(&value).unwrap(),
        })
    }
}
struct Fixture {
    _tmp: tempfile::TempDir,
    service: Arc<ManualAccountService>,
    runtime: Arc<Runtime>,
    id: String,
    system: PathBuf,
}
impl Fixture {
    fn new() -> Self {
        Self::with_protector(Arc::new(Protector))
    }
    fn with_protector(protector: Arc<dyn SecretProtector>) -> Self {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().canonicalize().unwrap().join("manual-fixture");
        storage::create_private_directory(&root).unwrap();
        let root = root.canonicalize().unwrap();
        let system = root.join("system");
        storage::secure_directory(&system).unwrap();
        storage::atomic_write(
            &system.join("auth.json"),
            b"synthetic unchanged system auth",
        )
        .unwrap();
        let manager = AccountManager::with_components(
            AccountPaths::isolated(root.join("vault"), system.clone()).unwrap(),
            protector,
            Arc::new(NativeAccountRuntime),
            None,
        )
        .unwrap();
        let id = manager
            .create_managed_account("Account 12".into(), "codex".into())
            .unwrap()
            .id;
        let jwt=format!("synthetic.{}.signature",URL_SAFE_NO_PAD.encode(serde_json::to_vec(&json!({"email":"manual@fixture.invalid","account_id":"manual-fixture-account","exp":4102444800i64})).unwrap()));
        let auth=serde_json::to_vec(&json!({"tokens":{"access_token":jwt,"id_token":jwt,"refresh_token":"synthetic-refresh","account_id":"manual-fixture-account"}})).unwrap();
        let quota = json!({"accountId":"manual-fixture-account","rateLimits":{"planType":"plus","primary":{"usedPercent":80,"windowDurationMins":300,"resetsAt":ms()/1000+3600}},"rateLimitResetCredits":{"availableCount":1,"credits":[{"id":"synthetic-card","resetType":"codexRateLimits","status":"available","expiresAt":ms()/1000+600}]}});
        let verified=crate::accounts::VerifiedCredential::from_official_read(auth,&json!({"account":{"type":"chatgpt","email":"manual@fixture.invalid","planType":"plus"}}),quota.clone()).unwrap();
        {
            let mut store = manager.store().unwrap();
            store.vault.account_mut(&id).unwrap().credential =
                Some(verified.into_stored("c".repeat(32)));
            store.save().unwrap();
        }
        let runtime = Arc::new(Runtime {
            quota: Mutex::new(quota),
            outcome: Mutex::new("reset"),
            keys: Mutex::new(Vec::new()),
            posts: AtomicUsize::new(0),
            response: Mutex::new((
                200,
                json!({"invites":[{"id":"synthetic-referral","email":"one@fixture.invalid"}],"failed_emails":[]}),
            )),
            tracking: Mutex::new(json!({"items":[],"cursor":null})),
            capacity: Mutex::new(5),
            review_calls: AtomicUsize::new(0),
            after_consume: Mutex::new(None),
        });
        let service = ManualAccountService::with_runtime(manager, runtime.clone(), None).unwrap();
        Self {
            _tmp: tmp,
            service,
            runtime,
            id,
            system,
        }
    }
    fn review(&self) -> ResetReview {
        self.service.begin_reset_review(&self.id).unwrap()
    }
    fn confirmed(&self) -> ResetReview {
        let r = self.review();
        self.service
            .confirm_reset_review(&self.id, &r.review_id)
            .unwrap()
    }
    fn consume(&self) -> ResetResult {
        let r = self.confirmed();
        self.service.consume_reset(&self.id, &r.review_id).unwrap()
    }
    fn unchanged(&self) {
        assert_eq!(
            std::fs::read(self.system.join("auth.json")).unwrap(),
            b"synthetic unchanged system auth"
        );
    }
}
fn code<T>(r: AccountResult<T>) -> &'static str {
    match r {
        Err(e) => e.code,
        Ok(_) => panic!("expected failure"),
    }
}
#[test]
fn reset_requires_second_confirmation_and_is_once_per_ticket() {
    let f = Fixture::new();
    let r = f.review();
    assert_eq!(r.available_count, 1);
    assert_eq!(r.remaining5h_percent, Some(20.0));
    assert_eq!(
        code(f.service.consume_reset(&f.id, &r.review_id)),
        "reset_confirmation_required"
    );
    f.service.confirm_reset_review(&f.id, &r.review_id).unwrap();
    assert_eq!(
        f.service
            .consume_reset(&f.id, &r.review_id)
            .unwrap()
            .outcome,
        "reset"
    );
    assert_eq!(
        code(f.service.consume_reset(&f.id, &r.review_id)),
        "reset_confirmation_required"
    );
    assert_eq!(f.runtime.keys.lock().unwrap().len(), 1);
    f.unchanged();
}
#[test]
fn reset_ignores_unrelated_account_mutation_and_proxy_occupancy() {
    let f = Fixture::new();
    let identity = f
        .service
        .credential(&f.id)
        .unwrap()
        .value
        .identity
        .identity_hash();
    let gate = crate::managed_proxy::ManagedProxyGate::new(
        f.system.parent().unwrap().join("dispatch"),
        &f.service.manager,
    )
    .unwrap();
    f.service
        .manager
        .install_occupancy_gate(gate.clone())
        .unwrap();
    let _active = gate.reserve_terminal(&identity).unwrap();
    let _global = f.service.manager.mutation.lock().unwrap();
    let result = f.consume();
    assert_eq!(result.outcome, "reset");
    f.unchanged();
}
#[test]
fn reset_rejects_wrong_profile_expired_cancelled_and_changed_card() {
    let f = Fixture::new();
    let r = f.confirmed();
    assert_eq!(
        code(f.service.consume_reset(&"a".repeat(32), &r.review_id)),
        "account_not_found"
    );
    f.service
        .reset_tickets
        .lock()
        .unwrap()
        .get_mut(&r.review_id)
        .unwrap()
        .dto
        .expires_at_ms = ms() - 1;
    assert_eq!(
        code(f.service.consume_reset(&f.id, &r.review_id)),
        "reset_review_expired"
    );
    let r = f.confirmed();
    f.service.cancel_reset_review(&f.id, &r.review_id).unwrap();
    assert_eq!(
        code(f.service.consume_reset(&f.id, &r.review_id)),
        "reset_confirmation_required"
    );
    let r = f.confirmed();
    f.runtime.quota.lock().unwrap()["rateLimitResetCredits"]["credits"][0]["id"] = json!("changed");
    assert_eq!(
        f.service
            .consume_reset(&f.id, &r.review_id)
            .unwrap()
            .outcome,
        "unknown"
    );
    assert!(f.runtime.keys.lock().unwrap().is_empty());
}
#[test]
fn unknown_keeps_same_key_and_blocks_automatic_but_not_other_identity() {
    let f = Fixture::new();
    *f.runtime.outcome.lock().unwrap() = "unknown";
    let a = f.consume();
    assert!(a.manual_confirmation.is_none());
    let identity = f
        .service
        .credential(&f.id)
        .unwrap()
        .value
        .identity
        .identity_hash();
    let before = read_journal(&f.service.manager).unwrap().pending[&identity]
        .key
        .clone();
    assert!(automatic_reset_guard(&f.service.manager, &identity).is_err());
    assert!(automatic_reset_guard(&f.service.manager, &"b".repeat(64)).is_ok());
    let restarted =
        ManualAccountService::with_runtime(f.service.manager.clone(), f.runtime.clone(), None)
            .unwrap();
    let r = restarted.begin_reset_review(&f.id).unwrap();
    restarted.confirm_reset_review(&f.id, &r.review_id).unwrap();
    *f.runtime.outcome.lock().unwrap() = "alreadyRedeemed";
    assert!(restarted
        .consume_reset(&f.id, &r.review_id)
        .unwrap()
        .manual_confirmation
        .is_none());
    let keys = f.runtime.keys.lock().unwrap();
    assert_eq!(keys.len(), 2);
    assert_eq!(keys[0], before);
    assert_eq!(keys[1], before);
}

#[test]
fn only_reset_persists_confirmation_and_drain_retries_only_until_durable_record() {
    let f = Fixture::new();
    let r = f.consume();
    let event = r.manual_confirmation.unwrap();
    assert_eq!(event.masked_label, "Account 12");
    assert!(event.available_cards.is_none());
    let calls = AtomicUsize::new(0);
    assert!(f
        .service
        .drain_confirmed(|_| Err(fail("fixture-save-failed")))
        .is_err());
    f.service
        .drain_confirmed(|v| {
            assert_eq!(v.event_id, event.event_id);
            calls.fetch_add(1, Ordering::AcqRel);
            Ok(())
        })
        .unwrap();
    f.service
        .drain_confirmed(|_| {
            calls.fetch_add(1, Ordering::AcqRel);
            Ok(())
        })
        .unwrap();
    assert_eq!(calls.load(Ordering::Acquire), 1);
    assert!(read_journal(&f.service.manager).unwrap().pending.is_empty());
    let bytes = std::fs::read(state_root(&f.service.manager).join("journal.dpapi")).unwrap();
    assert!(!String::from_utf8_lossy(&bytes).contains("fixture.invalid"));
}
#[test]
fn non_reset_official_outcomes_do_not_notify() {
    for outcome in ["nothingToReset", "noCredit", "alreadyRedeemed"] {
        let f = Fixture::new();
        *f.runtime.outcome.lock().unwrap() = outcome;
        assert!(f.consume().manual_confirmation.is_none());
        assert!(read_journal(&f.service.manager)
            .unwrap()
            .confirmations
            .is_empty());
    }
}
#[test]
fn malformed_or_expired_cards_never_review() {
    let f = Fixture::new();
    f.runtime.quota.lock().unwrap()["rateLimitResetCredits"]["credits"][0]["expiresAt"] =
        json!(ms() / 1000 - 1);
    assert_eq!(
        code(f.service.begin_reset_review(&f.id)),
        "reset_card_unavailable"
    );
    assert!(f.runtime.keys.lock().unwrap().is_empty());
}
#[test]
fn referral_consent_capacity_and_duplicate_validation_prevent_post() {
    let f = Fixture::new();
    let r = f.service.referral_eligibility(&f.id, "en").unwrap();
    assert_eq!(r.invitation_capacity, 5);
    assert_eq!(r.credit_amount, Some(250.0));
    assert_eq!(
        code(f.service.send_referrals(
            &f.id,
            &r.review_id,
            vec!["one@fixture.invalid".into()],
            false,
            "en"
        )),
        "referral_consent_required"
    );
    assert_eq!(
        code(f.service.send_referrals(
            &f.id,
            &r.review_id,
            vec!["ONE@fixture.invalid".into(), "one@fixture.invalid".into()],
            true,
            "en"
        )),
        "referral_invalid_email"
    );
    *f.runtime.capacity.lock().unwrap() = 0;
    assert_eq!(
        code(f.service.send_referrals(
            &f.id,
            &r.review_id,
            vec!["one@fixture.invalid".into()],
            true,
            "en"
        )),
        "referral_capacity_reached"
    );
    assert_eq!(f.runtime.posts.load(Ordering::Acquire), 0);
}
#[test]
fn referral_partial_ack_unknown_stays_blocked_despite_matching_history() {
    let f = Fixture::new();
    let r = f.service.referral_eligibility(&f.id, "en").unwrap();
    let recipients = vec!["one@fixture.invalid".into(), "two@fixture.invalid".into()];
    let result = f
        .service
        .send_referrals(&f.id, &r.review_id, recipients.clone(), true, "en")
        .unwrap();
    assert_eq!(result.sent, vec![0]);
    assert_eq!(result.uncertain, vec![1]);
    let next = f.service.referral_eligibility(&f.id, "en").unwrap();
    assert_eq!(
        code(
            f.service
                .send_referrals(&f.id, &next.review_id, recipients, true, "en")
        ),
        "referral_reconciliation_required"
    );
    for status in ["pending", "redeemed", "expired", "unknown", "rejected"] {
        *f.runtime.tracking.lock().unwrap() = json!({"items":[{"referral_id":"old-two-record","email":"two@fixture.invalid","status":status}],"cursor":null});
        let checked = f
            .service
            .check_referral_outcome(&f.id, &r.review_id, "en")
            .unwrap();
        assert_eq!(
            checked.sent,
            vec![0],
            "historical {status} is not this attempt"
        );
        assert_eq!(checked.uncertain, vec![1]);
    }
    assert_eq!(f.runtime.posts.load(Ordering::Acquire), 1);
    f.unchanged();
}
#[test]
fn referral_redirect_and_server_failure_are_uncertain_after_restart() {
    for status in [302, 500] {
        let f = Fixture::new();
        *f.runtime.response.lock().unwrap() = (status, json!({}));
        let r = f.service.referral_eligibility(&f.id, "en").unwrap();
        assert_eq!(
            f.service
                .send_referrals(
                    &f.id,
                    &r.review_id,
                    vec!["one@fixture.invalid".into()],
                    true,
                    "en"
                )
                .unwrap()
                .uncertain,
            vec![0]
        );
        let restarted =
            ManualAccountService::with_runtime(f.service.manager.clone(), f.runtime.clone(), None)
                .unwrap();
        let review = restarted.referral_eligibility(&f.id, "en").unwrap();
        assert_eq!(
            code(restarted.send_referrals(
                &f.id,
                &review.review_id,
                vec!["one@fixture.invalid".into()],
                true,
                "en"
            )),
            "referral_reconciliation_required"
        );
        assert_eq!(f.runtime.posts.load(Ordering::Acquire), 1);
    }
}
#[test]
fn referral_explicit_failure_allows_new_review_and_tracking_masks_email() {
    let f = Fixture::new();
    *f.runtime.response.lock().unwrap() = (
        422,
        json!({"detail":{"failed_emails":["one@fixture.invalid"]}}),
    );
    let r = f.service.referral_eligibility(&f.id, "zh").unwrap();
    assert_eq!(
        f.service
            .send_referrals(
                &f.id,
                &r.review_id,
                vec!["one@fixture.invalid".into()],
                true,
                "zh"
            )
            .unwrap()
            .failed,
        vec![0]
    );
    assert!(read_journal(&f.service.manager)
        .unwrap()
        .referral_attempts
        .is_empty());
    *f.runtime.tracking.lock().unwrap() = json!({"items":[{"referral_id":"one-record","email":"one@fixture.invalid","status":"redeemed"}],"cursor":null});
    let serialized = serde_json::to_string(
        &f.service
            .referral_tracking(&f.id, "this_month", None, "en")
            .unwrap(),
    )
    .unwrap();
    assert!(!serialized.contains("one@fixture.invalid"));
    assert!(serialized.contains("redeemed"));
}
#[test]
fn exit_cancellation_prevents_new_actions() {
    let f = Fixture::new();
    let r = f.confirmed();
    f.service.cancel_for_exit();
    assert_eq!(
        code(f.service.consume_reset(&f.id, &r.review_id)),
        "manual_action_cancelled"
    );
    assert_eq!(
        code(f.service.referral_eligibility(&f.id, "en")),
        "manual_action_cancelled"
    );
    assert!(f.runtime.keys.lock().unwrap().is_empty());
}

#[test]
fn per_account_operations_are_independent_but_same_account_is_serial() {
    let f = Fixture::new();
    let _a = reserve_operation(&f.service.reset_operation, &f.id).unwrap();
    assert_eq!(
        code(reserve_operation(&f.service.reset_operation, &f.id)),
        "manual_action_busy"
    );
    assert!(reserve_operation(&f.service.reset_operation, &"b".repeat(32)).is_ok());
    assert!(f.service.has_inflight_operation());
}
#[test]
fn profile_alias_mapping_requires_unique_canonical_managed_root() {
    let f = Fixture::new();
    let home = f.service.manager.paths.desktop(&f.id).unwrap();
    storage::secure_directory(&home).unwrap();
    assert_eq!(f.service.resolve_managed_root(&home).unwrap(), f.id);
    assert_eq!(
        code(f.service.resolve_managed_root(&f.system)),
        "manual_action_registration_required"
    );
}

#[test]
fn changed_identity_after_review_cannot_consume_or_send() {
    let f = Fixture::new();
    let review = f.confirmed();
    let invite = f.service.referral_eligibility(&f.id, "en").unwrap();
    {
        let mut store = f.service.manager.store().unwrap();
        store.vault.account_mut(&f.id).unwrap().credential = None;
        store.save().unwrap();
    }
    assert_eq!(
        code(f.service.consume_reset(&f.id, &review.review_id)),
        "login_required"
    );
    assert_eq!(
        code(f.service.send_referrals(
            &f.id,
            &invite.review_id,
            vec!["one@fixture.invalid".into()],
            true,
            "en"
        )),
        "login_required"
    );
    assert!(f.runtime.keys.lock().unwrap().is_empty());
    assert_eq!(f.runtime.posts.load(Ordering::Acquire), 0);
}
#[test]
fn persisted_automatic_uncertain_reset_blocks_only_its_identity() {
    let f = Fixture::new();
    let identity = f
        .service
        .credential(&f.id)
        .unwrap()
        .value
        .identity
        .identity_hash();
    let path = f
        .system
        .parent()
        .unwrap()
        .join("automatic-maintenance.json");
    storage::atomic_write(&path,&serde_json::to_vec(&json!({"version":1,"settings":{"fiveHourWarmup":false,"sevenDayWarmup":false,"resetLeadMinutes":30,"resetAuthorizations":{}},"entries":[{"profileId":f.id,"kind":"reset_credit","phase":"uncertain","issueCode":null,"lastAttemptAtMs":ms(),"lastSucceededAtMs":null,"nextEligibleAtMs":null,"identity":identity,"generation":"c".repeat(32),"windowBaseline":[],"cardHash":"a".repeat(64),"idempotencyKey":"synthetic-key","quotaFingerprint":null}]})).unwrap()).unwrap();
    let maintenance =
        maintenance::AccountMaintenanceService::new(path, f.service.manager.clone()).unwrap();
    assert!(maintenance.manual_reset_admission(&identity).is_err());
    assert!(maintenance.manual_reset_admission(&"b".repeat(64)).is_ok());
    let service = ManualAccountService::with_runtime(
        f.service.manager.clone(),
        f.runtime.clone(),
        Some(maintenance),
    )
    .unwrap();
    let r = service.begin_reset_review(&f.id).unwrap();
    service.confirm_reset_review(&f.id, &r.review_id).unwrap();
    assert_eq!(
        code(service.consume_reset(&f.id, &r.review_id)),
        "reset_reconciliation_required"
    );
    assert!(f.runtime.keys.lock().unwrap().is_empty());
}

struct NoticeTransport(AtomicUsize);
impl crate::notifications::NotificationTransport for NoticeTransport {
    fn send(
        &self,
        _: &crate::notifications::TransportRequest,
        cancel: &AtomicBool,
    ) -> crate::notifications::Result<crate::notifications::TransportResponse> {
        assert!(!cancel.load(Ordering::Acquire));
        self.0.fetch_add(1, Ordering::AcqRel);
        Ok(crate::notifications::TransportResponse {
            status: 200,
            body: br#"{"code":0}"#.to_vec(),
        })
    }
}
#[test]
fn official_success_authorization_survives_outbox_restart_without_retroactive_opt_in() {
    use crate::notifications::{ChannelKind, ManualResetNotice, NotificationService};
    for mode in ["disabled", "reconfigured", "enabled", "read-failed"] {
        let f = Fixture::new();
        let transport = Arc::new(NoticeTransport(AtomicUsize::new(0)));
        let notices = NotificationService::with_components(
            f.system.parent().unwrap().join("notices"),
            Arc::new(Protector),
            transport.clone(),
        )
        .unwrap();
        notices
            .save_channel(
                ChannelKind::Feishu,
                "https://open.feishu.cn/open-apis/bot/v2/hook/synthetic-not-a-real-webhook".into(),
                None,
            )
            .unwrap();
        if mode != "disabled" {
            notices.set_enabled(ChannelKind::Feishu, true).unwrap();
        }
        let n = notices.clone();
        let fail_read = mode == "read-failed";
        let service = ManualAccountService::with_runtime_authorization(
            f.service.manager.clone(),
            f.runtime.clone(),
            None,
            Arc::new(move || {
                if fail_read {
                    ManualResetAuthorization::default()
                } else {
                    n.manual_reset_authorization().unwrap_or_default()
                }
            }),
        )
        .unwrap();
        let r = service.begin_reset_review(&f.id).unwrap();
        service.confirm_reset_review(&f.id, &r.review_id).unwrap();
        let result = service.consume_reset(&f.id, &r.review_id).unwrap();
        assert_eq!(result.outcome, "reset");
        assert!(!serde_json::to_string(&result)
            .unwrap()
            .contains("authorization"));
        if mode == "disabled" {
            notices.set_enabled(ChannelKind::Feishu, true).unwrap();
        }
        if mode == "reconfigured" {
            notices.set_enabled(ChannelKind::Feishu, false).unwrap();
            notices.set_enabled(ChannelKind::Feishu, true).unwrap();
        }
        // Restarted action service's default closure must not replace the saved
        // official-success snapshot with the now-enabled channel.
        let restarted =
            ManualAccountService::with_runtime(f.service.manager.clone(), f.runtime.clone(), None)
                .unwrap();
        let relay = |e: &ManualResetConfirmation| {
            let notice = ManualResetNotice::new(
                &e.event_id,
                &e.account_key,
                &e.masked_label,
                e.confirmed_at_ms / 1000,
                e.available_cards,
            )
            .unwrap();
            notices
                .record_manual_reset_authorized(notice, e.authorization.clone())
                .map_err(|_| fail("notice_failed"))
        };
        restarted.drain_confirmed(relay).unwrap();
        let receipts = notices.drain_manual_resets().unwrap();
        assert_eq!(receipts.len(), usize::from(mode == "enabled"));
        assert_eq!(
            transport.0.load(Ordering::Acquire),
            usize::from(mode == "enabled")
        );
        restarted.drain_confirmed(relay).unwrap();
        assert!(notices.drain_manual_resets().unwrap().is_empty());
        assert_eq!(
            transport.0.load(Ordering::Acquire),
            usize::from(mode == "enabled")
        );
    }
}
#[test]
fn legacy_success_receipt_defaults_to_no_notification_authorization() {
    let f = Fixture::new();
    f.consume();
    let journal = read_journal(&f.service.manager).unwrap();
    let original = journal.confirmations.values().next().unwrap();
    let mut value = serde_json::to_value(original).unwrap();
    value.as_object_mut().unwrap().remove("authorization");
    let legacy: ManualResetConfirmation = serde_json::from_value(value).unwrap();
    assert_eq!(legacy.authorization, ManualResetAuthorization::default());
}

struct FailSeal(Arc<AtomicBool>);
impl SecretProtector for FailSeal {
    fn seal(&self, c: &str, b: &[u8]) -> AccountResult<Vec<u8>> {
        if self.0.load(Ordering::Acquire) {
            Err(fail("fixture_seal_failed"))
        } else {
            Protector.seal(c, b)
        }
    }
    fn unseal(&self, c: &str, b: &[u8]) -> AccountResult<Vec<u8>> {
        Protector.unseal(c, b)
    }
}
#[test]
fn success_journal_failure_preserves_reset_and_only_allows_original_key_after_restart() {
    let failing = Arc::new(AtomicBool::new(false));
    let f = Fixture::with_protector(Arc::new(FailSeal(failing.clone())));
    let flag = failing.clone();
    *f.runtime.after_consume.lock().unwrap() =
        Some(Box::new(move || flag.store(true, Ordering::Release)));
    let result = f.consume();
    assert_eq!(result.outcome, "reset");
    assert_eq!(result.issue_code, Some("notification_receipt_save_failed"));
    assert!(result.manual_confirmation.is_none());
    assert_eq!(f.runtime.keys.lock().unwrap().len(), 1);
    let identity = f
        .service
        .credential(&f.id)
        .unwrap()
        .value
        .identity
        .identity_hash();
    let before = read_journal(&f.service.manager).unwrap().pending[&identity]
        .key
        .clone();
    failing.store(false, Ordering::Release);
    let restarted =
        ManualAccountService::with_runtime(f.service.manager.clone(), f.runtime.clone(), None)
            .unwrap();
    let retry = f.service.begin_reset_review(&f.id).unwrap();
    f.service
        .confirm_reset_review(&f.id, &retry.review_id)
        .unwrap();
    assert_eq!(
        code(f.service.consume_reset(&f.id, &retry.review_id)),
        "reset_reconciliation_required"
    );
    assert!(restarted.begin_reset_review(&f.id).is_ok());
    assert_eq!(
        read_journal(&f.service.manager).unwrap().pending[&identity].key,
        before
    );
    assert_eq!(f.runtime.keys.lock().unwrap().len(), 1);
    assert!(automatic_reset_guard(&f.service.manager, &identity).is_err());
    // The official protocol defines a retry as the same logical attempt and
    // returns alreadyRedeemed when this key previously completed a reset.
    let review = restarted.begin_reset_review(&f.id).unwrap();
    restarted
        .confirm_reset_review(&f.id, &review.review_id)
        .unwrap();
    *f.runtime.outcome.lock().unwrap() = "alreadyRedeemed";
    let resolved = restarted.consume_reset(&f.id, &review.review_id).unwrap();
    assert_eq!(resolved.outcome, "alreadyRedeemed");
    assert!(resolved.manual_confirmation.is_none());
    let keys = f.runtime.keys.lock().unwrap();
    assert_eq!(keys.len(), 2);
    assert_eq!(keys[0], before);
    assert_eq!(keys[1], before);
    let journal = read_journal(&f.service.manager).unwrap();
    assert!(!journal.pending.contains_key(&identity));
    assert!(journal.confirmations.is_empty());
}
