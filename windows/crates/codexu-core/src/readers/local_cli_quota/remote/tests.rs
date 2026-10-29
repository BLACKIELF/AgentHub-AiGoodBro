use super::*;
use serde_json::json;

fn now() -> DateTime<Utc> {
    DateTime::parse_from_rfc3339("2026-10-29T00:00:00Z")
        .unwrap()
        .with_timezone(&Utc)
}
fn parsed(kind: LocalCliKind, v: Value) -> Result<LocalCliQuotaResult> {
    parse(kind, &serde_json::to_vec(&v).unwrap(), now())
}
fn grok() -> Value {
    json!({"https://auth.x.ai::official":{"key":"synthetic-secret","user_id":"synthetic-user","expires_at":"2026-11-01T00:00:00Z"}})
}
fn fixture(v: Value) -> tempfile::TempDir {
    let t = tempfile::tempdir().unwrap();
    fs::write(t.path().join("auth.json"), serde_json::to_vec(&v).unwrap()).unwrap();
    t
}
struct Fake<F: Fn(&Request) -> Result<Response>>(F);
impl<F: Fn(&Request) -> Result<Response>> Transport for Fake<F> {
    fn get(&self, request: &Request) -> Result<Response> {
        (self.0)(request)
    }
}
fn response(status: u32, v: Value) -> Result<Response> {
    Ok(Response {
        status,
        body: serde_json::to_vec(&v).unwrap(),
    })
}

#[test]
fn grok_preserves_authoritative_percentage_zero_balance_and_separate_period() {
    let q = parsed(LocalCliKind::Grok, json!({"config":{"subscriptionTier":"super","creditUsagePercent":27.5,"prepaidBalance":{},"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-11-02T00:00:00Z"}}})).unwrap();
    assert_eq!(q.windows[0].used_percent, 27.5);
    assert_eq!(q.windows[0].label, "7-day");
    assert_eq!(q.balance, Some(0.0));
    assert_eq!(q.balance_currency.as_deref(), Some("USD"));
    assert_eq!(q.period_resets_at, q.windows[0].resets_at);
}
#[test]
fn grok_legacy_uses_included_budget_not_on_demand() {
    let q=parsed(LocalCliKind::Grok,json!({"config":{"monthlyLimit":{"val":200},"used":{"val":50},"onDemandCap":{"val":10},"onDemandUsed":{"val":10},"prepaidBalance":{"val":-250}}})).unwrap();
    assert_eq!(q.windows[0].used_percent, 25.0);
    assert_eq!(q.balance, Some(2.5));
    let q = parsed(
        LocalCliKind::Grok,
        json!({"config":{"onDemandCap":{"val":10},"onDemandUsed":{"val":10}}}),
    )
    .unwrap();
    assert!(q.windows.is_empty());
    assert!(q.balance.is_none());
}
#[test]
fn grok_rejects_malformed_authoritative_fields_instead_of_falling_back() {
    for bad in [json!(true), json!("30"), json!(-1), json!(101)] {
        assert_eq!(parsed(LocalCliKind::Grok,json!({"config":{"creditUsagePercent":bad,"monthlyLimit":{"val":100},"used":{"val":30}}})).unwrap_err(),Failure::Response);
    }
    for bad in [
        json!(1),
        json!({"val":"2"}),
        json!({"val":false}),
        json!({"val":0.1}),
        json!({"val":9007199254740992u64}),
    ] {
        assert_eq!(
            parsed(LocalCliKind::Grok, json!({"config":{"prepaidBalance":bad}})).unwrap_err(),
            Failure::Response
        );
    }
}
#[test]
fn kimi_keeps_four_real_pools_and_missing_ratio_unknown() {
    let q=parsed(LocalCliKind::Kimi,json!({"planName":"Pro","usages":{"limit_5h":{"used_ratio":"0.25"},"limit_7d":{"used_ratio":0},"limit_month_total":{"used_ratio":1.5},"limit_month_code":{"used_ratio":0.5}}})).unwrap();
    assert_eq!(
        q.windows.iter().map(|w| w.id.as_str()).collect::<Vec<_>>(),
        ["session", "weekly", "monthly", "monthly-code"]
    );
    assert_eq!(
        q.windows.iter().map(|w| w.used_percent).collect::<Vec<_>>(),
        [25.0, 0.0, 100.0, 50.0]
    );
    assert!(parsed(
        LocalCliKind::Kimi,
        json!({"usages":{"limit_5h":{"reset_time":"2026-11-01T00:00:00Z"}}})
    )
    .is_err());
}
#[test]
fn kimi_only_more_exhausted_matching_legacy_window_can_replace_ratio() {
    for (reset, used, expected) in [
        ("2026-11-01T00:00:02Z", 80, 80.0),
        ("2026-11-01T00:00:03Z", 80, 20.0),
        ("2026-11-01T00:00:00Z", 10, 20.0),
    ] {
        let q=parsed(LocalCliKind::Kimi,json!({"usages":{"limit_7d":{"used_ratio":0.2,"reset_time":"2026-11-01T00:00:00Z"}},"usage":{"limit":100,"used":used,"resetTime":reset},"limits":[{"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":"100","remaining":"40"}}]})).unwrap();
        assert_eq!(q.windows[0].used_percent, expected);
        assert_eq!(q.windows[1].id, "session");
        assert_eq!(q.windows[1].used_percent, 60.0);
    }
}
#[test]
fn kimi_rejects_empty_malformed_and_unbounded_counters() {
    for v in [
        json!({}),
        json!({"usages":[]}),
        json!({"usages":{"limit_5h":{"used_ratio":true}}}),
        json!({"usages":{"limit_5h":{"used_ratio":"NaN"}}}),
        json!({"usage":{"limit":0,"used":0}}),
        json!({"usage":{"limit":100,"remaining":200}}),
        json!({"limits":[{"window":{"duration":5,"timeUnit":"UNKNOWN"},"limit":100,"used":2}]}),
    ] {
        assert!(parsed(LocalCliKind::Kimi, v).is_err());
    }
}

#[test]
fn kimi_duplicate_legacy_pool_cannot_replace_an_unrelated_original_counter() {
    let q = parsed(LocalCliKind::Kimi, json!({
        "usage":{"limit":100,"used":20,"resetTime":"2026-11-01T00:00:00Z"},
        "limits":[{"window":{"duration":7,"timeUnit":"DAY"},"detail":{"limit":100,"used":80,"resetTime":"2026-11-01T00:00:00Z"}}]
    })).unwrap();
    assert_eq!(q.windows.len(), 1);
    assert_eq!(q.windows[0].used_percent, 20.0);
}
#[test]
fn opencode_rate_limited_is_exhausted_and_null_missing_stay_missing() {
    let q=parsed(LocalCliKind::OpenCode,json!({"usage":{"rolling":{"status":"rate-limited"},"weekly":{"percent":25,"resetsAt":"2026-11-01T00:00:00Z"},"monthly":null}})).unwrap();
    assert_eq!(q.windows.len(), 2);
    assert_eq!(q.windows[0].used_percent, 100.0);
    assert_eq!(q.windows[1].used_percent, 25.0);
    for v in [
        json!({}),
        json!({"usage":[]}),
        json!({"usage":{"rolling":{"status":"rate-limited","percent":"25"}}}),
        json!({"usage":{"weekly":{}}}),
    ] {
        assert!(parsed(LocalCliKind::OpenCode, v).is_err());
    }
}
#[test]
fn grok_selected_credential_request_is_fixed_and_projection_is_masked() {
    let t = fixture(grok());
    let q = load_with(
        LocalCliKind::Grok,
        t.path(),
        now(),
        &Fake(|r: &Request| {
            assert_eq!(
                r.endpoint.location(),
                ("cli-chat-proxy.grok.com", "/v1/billing?format=credits")
            );
            assert_eq!(r.token, "synthetic-secret");
            assert_eq!(r.headers.last().unwrap().1, "synthetic-user");
            response(200, json!({"config":{"creditUsagePercent":42}}))
        }),
    );
    assert_eq!(q.state, LocalCliQuotaState::Available);
    let json = serde_json::to_string(&q).unwrap();
    assert!(!json.contains("synthetic-secret"));
    assert!(!json.contains("synthetic-user"));
    assert!(q.identity_fingerprint.is_some());
    assert!(q.masked_identity.is_some());
}
#[test]
fn credential_change_discards_success_and_unauthorized_reply() {
    for status in [200, 401, 429] {
        let t = fixture(grok());
        let q = load_with(
            LocalCliKind::Grok,
            t.path(),
            now(),
            &Fake(|_: &Request| {
                fs::write(t.path().join("auth.json"), b"{}").unwrap();
                response(status, json!({"config":{"creditUsagePercent":42}}))
            }),
        );
        assert_eq!(
            q.message_code.as_deref(),
            Some("local_cli_credentials_changed")
        );
        assert!(q.windows.is_empty());
    }
}
#[test]
fn expired_ambiguous_or_injected_grok_credentials_never_reach_transport() {
    let mut ambiguous = grok();
    ambiguous["https://accounts.x.ai/sign-in"] = ambiguous["https://auth.x.ai::official"].clone();
    let mut expired = grok();
    expired["https://auth.x.ai::official"]["expires_at"] = json!("2026-10-01T00:00:00Z");
    let mut injected = grok();
    injected["https://auth.x.ai::official"]["user_id"] = json!("someone\r\nAuthorization: secret");
    for value in [ambiguous, expired, injected] {
        let t = fixture(value);
        let q = load_with(
            LocalCliKind::Grok,
            t.path(),
            now(),
            &Fake(|_: &Request| panic!("must not send")),
        );
        assert_ne!(q.state, LocalCliQuotaState::Available);
    }
    let mut fallback = grok();
    let entry = fallback["https://auth.x.ai::official"]
        .as_object_mut()
        .unwrap();
    entry.remove("expires_at");
    entry.insert("create_time".into(), json!("2026-10-01T00:00:00Z"));
    let t = fixture(fallback);
    assert!(prepare(LocalCliKind::Grok, t.path(), now()).is_ok());
}
#[test]
fn kimi_expired_refresh_is_explicit_and_does_not_mutate_credentials() {
    let t = tempfile::tempdir().unwrap();
    fs::create_dir(t.path().join("credentials")).unwrap();
    let path = t.path().join("credentials/kimi-code.json");
    let bytes =
        br#"{"access_token":"synthetic","expires_at":1,"refresh_token":"synthetic-refresh"}"#;
    fs::write(&path, bytes).unwrap();
    let q = load_with(
        LocalCliKind::Kimi,
        t.path(),
        now(),
        &Fake(|_: &Request| panic!("must not send")),
    );
    assert_eq!(
        q.message_code.as_deref(),
        Some("local_cli_kimi_token_refresh_required")
    );
    assert_eq!(fs::read(path).unwrap(), bytes);
}
#[test]
fn kimi_request_uses_selected_device_and_disallows_device_replacement() {
    let t = tempfile::tempdir().unwrap();
    fs::create_dir(t.path().join("credentials")).unwrap();
    fs::write(t.path().join("credentials/kimi-code.json"),serde_json::to_vec(&json!({"access_token":"synthetic","expires_at":now().timestamp()+500,"user_id":"test-person"})).unwrap()).unwrap();
    fs::write(t.path().join("device_id"), b"selected-device").unwrap();
    let q = load_with(
        LocalCliKind::Kimi,
        t.path(),
        now(),
        &Fake(|r: &Request| {
            assert_eq!(r.endpoint.location(), ("api.kimi.com", "/coding/v1/usages"));
            assert_eq!(r.headers.last().unwrap().1, "selected-device");
            fs::write(t.path().join("device_id"), b"replacement").unwrap();
            response(200, json!({"usages":{"limit_5h":{"used_ratio":0.2}}}))
        }),
    );
    assert_eq!(
        q.message_code.as_deref(),
        Some("local_cli_credentials_changed")
    );
}
#[test]
fn opencode_other_provider_is_not_signed_out_and_never_used_as_go_key() {
    let t = fixture(json!({"anthropic":{"type":"api","key":"other-provider-secret"}}));
    let q = load_with(
        LocalCliKind::OpenCode,
        t.path(),
        now(),
        &Fake(|_: &Request| panic!("must not send")),
    );
    assert_eq!(q.state, LocalCliQuotaState::Unsupported);
    assert_eq!(
        q.message_code.as_deref(),
        Some("local_cli_opencode_go_not_connected")
    );
    let t = fixture(json!({"opencode-go":{"type":"api","key":"synthetic-go"}}));
    let q = load_with(
        LocalCliKind::OpenCode,
        t.path(),
        now(),
        &Fake(|r: &Request| {
            assert_eq!(r.endpoint.location(), ("opencode.ai", "/zen/go/v1/usage"));
            response(200, json!({"usage":{"weekly":{"percent":15}}}))
        }),
    );
    assert_eq!(q.state, LocalCliQuotaState::Available);
}
#[test]
fn rejection_and_oversize_are_not_success_or_an_invented_quota() {
    let t = fixture(grok());
    for (status, state) in [
        (401, LocalCliQuotaState::Unavailable),
        (429, LocalCliQuotaState::RateLimited),
        (302, LocalCliQuotaState::Unavailable),
        (500, LocalCliQuotaState::Unavailable),
    ] {
        let q = load_with(
            LocalCliKind::Grok,
            t.path(),
            now(),
            &Fake(|_: &Request| response(status, json!({"config":{"creditUsagePercent":0}}))),
        );
        assert_eq!(q.state, state);
        assert!(q.windows.is_empty());
    }
    assert!(object(&vec![b' '; MAX_BYTES + 1]).is_err());
    fs::write(t.path().join("auth.json"), vec![b' '; MAX_BYTES + 1]).unwrap();
    let q = load_with(
        LocalCliKind::Grok,
        t.path(),
        now(),
        &Fake(|_: &Request| panic!("must not send")),
    );
    assert_ne!(q.state, LocalCliQuotaState::Available);
}
#[cfg(unix)]
#[test]
fn credential_symlink_never_reaches_network() {
    let t = fixture(grok());
    let other = tempfile::tempdir().unwrap();
    std::os::unix::fs::symlink(t.path().join("auth.json"), other.path().join("auth.json")).unwrap();
    let q = load_with(
        LocalCliKind::Grok,
        other.path(),
        now(),
        &Fake(|_: &Request| panic!("must not send")),
    );
    assert_ne!(q.state, LocalCliQuotaState::Available);
}
