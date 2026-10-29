use super::*;
#[test]
fn session_history_accepts_only_masked_bounded_metadata() {
    let id = format!("opaque-{}", "a".repeat(24));
    let row = json!({"client":"codex","models":{"public/model":0},"totalTokens":0,"costUsd":null,"lastUsedAt":"2026-09-13T02:00:00Z","turnEnded":false});
    assert!(validate_sessions(&Value::Null).is_ok());
    assert!(validate_sessions(&json!({})).is_ok());
    assert!(validate_sessions(&json!({id.clone():row.clone()})).is_ok());
    assert!(validate_sessions(&json!({"raw":row.clone()})).is_err());
    for (field, value) in [
        ("title", json!("private")),
        ("client", Value::Null),
        ("turnEnded", json!("false")),
        ("lastUsedAt", json!("2026-02-30T00:00:00Z")),
        ("totalTokens", json!(-1)),
    ] {
        let mut invalid = row.clone();
        invalid[field] = value;
        assert!(validate_sessions(&json!({id.clone():invalid})).is_err());
    }
}
#[test]
fn rate_requires_actual_current_timed_evidence() {
    let now = Utc::now().timestamp_millis();
    let mut rate = TokenRate {
        mode: "burn".into(),
        scope: "local".into(),
        burn_per_minute: 1.,
        speed_per_second: 1.,
        sampled_at: now,
        expires_at: now + 8000,
        idle: false,
        revision: 1,
        context_key: "a".repeat(64),
    };
    assert!(validate_rate(&rate, &"a".repeat(64)).is_ok());
    rate.expires_at = now + 9000;
    assert!(validate_rate(&rate, &"a".repeat(64)).is_err());
    rate.expires_at = now + 8000;
    rate.burn_per_minute = f64::NAN;
    assert!(validate_rate(&rate, &"a".repeat(64)).is_err());
}
#[test]
fn private_and_unbounded_data_never_pass_response_gate() {
    for value in [
        json!({"prompt":"secret"}),
        json!({"email":"synthetic@example.invalid"}),
        json!({"x":"C:\\Users\\Private"}),
        json!({"tokens":-1}),
        json!({"path":"opaque"}),
    ] {
        assert!(validate_tree(&value, "", 0).is_err());
    }
    assert!(validate_tree(&json!({"tokens":0,"model":"claude-code"}), "", 0).is_ok());
}
#[test]
fn response_lines_are_bounded_and_must_be_complete() {
    let mut count = 0;
    assert!(process::read_events(&b"{}\n{}\n"[..], |_| {
        count += 1;
        Ok(())
    })
    .is_ok());
    assert_eq!(count, 2);
    assert!(process::read_events(&b"{}"[..], |_| Ok(())).is_err());
}
#[test]
fn catalog_and_source_roles_are_frozen() {
    let catalog = provider_catalog().unwrap();
    assert!(catalog.iter().any(|p| p.id == "codex" && p.default_tracked));
    assert!(catalog
        .iter()
        .any(|p| p.id == "qodercn" && !p.default_tracked));
    let root = std::env::temp_dir().join("synthetic");
    assert!(validate_sources(&[TokenMonitorSource {
        id: "system-history".into(),
        provider_id: "codex".into(),
        label: "Codex".into(),
        root: root.clone(),
        path_role: SourceRole::CodexHome,
        default_enabled: true
    }])
    .is_ok());
    assert!(validate_sources(&[TokenMonitorSource {
        id: "bad".into(),
        provider_id: "codex".into(),
        label: "Codex".into(),
        root,
        path_role: SourceRole::UserHome,
        default_enabled: true
    }])
    .is_err());
}
#[test]
fn wire_duplicate_keys_are_rejected_before_dto_decode() {
    assert!(
        serde_json::from_slice::<UniqueJson>(br#"{"event":"rate","event":"snapshot"}"#).is_err()
    );
    assert!(
        serde_json::from_slice::<UniqueJson>(br#"{"event":"rate","nested":{"ok":true}}"#).is_ok()
    );
}
fn source(root: PathBuf, id: &str, default_enabled: bool) -> TokenMonitorSource {
    let (provider, role, label) = match id {
        "system-history" => ("codex", SourceRole::CodexHome, "Codex"),
        "managed-next" => ("claude", SourceRole::UserHome, "Claude"),
        _ => ("qodercn", SourceRole::UserHome, "Optional"),
    };
    TokenMonitorSource {
        id: id.into(),
        provider_id: provider.into(),
        label: label.into(),
        root,
        path_role: role,
        default_enabled,
    }
}
fn service(data: PathBuf, sources: Vec<TokenMonitorSource>) -> Arc<TokenMonitorService> {
    let enabled = sources
        .iter()
        .filter(|s| s.default_enabled)
        .map(|s| s.id.clone())
        .collect::<BTreeSet<_>>();
    let dtos = sources
        .iter()
        .map(|s| SourceDto {
            id: s.id.clone(),
            provider_id: s.provider_id.clone(),
            label: s.label.clone(),
            enabled: enabled.contains(&s.id),
        })
        .collect();
    Arc::new(TokenMonitorService {
        resources: data.join("resources"),
        data,
        owned_domains: None,
        timezone: Mutex::new(String::new()),
        sources: Mutex::new(sources),
        enabled: Mutex::new(enabled),
        state: Mutex::new(TokenMonitorState {
            phase: "idle",
            revision: 0,
            context_key: None,
            sources: dtos,
            timezone: None,
            snapshot: None,
            token_rate: None,
            failure_code: None,
        }),
        notifications: Mutex::new(StateNotifications::default()),
        runtime: Mutex::new(None),
        cancel_handle: Mutex::new(None),
        operation: Mutex::new(()),
        epoch: AtomicU64::new(0),
        exiting: AtomicBool::new(false),
    })
}
#[test]
fn unknown_timezone_cannot_collect_and_real_zone_change_clears_scope() {
    let home = tempfile::tempdir().unwrap();
    let s = service(
        home.path().to_owned(),
        vec![source(home.path().join("codex"), "system-history", true)],
    );
    assert!(matches!(s.refresh(),Err(e) if e.code()=="statistics_timezone_required"));
    assert!(s.set_timezone("arbitrary offset".into()).is_err());
    assert!(s.set_timezone("a".repeat(65)).is_err());
    let state = s.set_timezone("Asia/Shanghai".into()).unwrap();
    assert_eq!(state.timezone.as_deref(), Some("Asia/Shanghai"));
    assert_eq!(state.phase, "idle");
    let epoch = s.epoch.load(Ordering::Acquire);
    s.set_timezone("Asia/Shanghai".into()).unwrap();
    assert_eq!(s.epoch.load(Ordering::Acquire), epoch);
    s.state.lock().unwrap().snapshot = Some(json!({"old":true}));
    s.state.lock().unwrap().context_key = Some("a".repeat(64));
    let state = s.set_timezone("America/Los_Angeles".into()).unwrap();
    assert!(state.snapshot.is_none());
    assert!(state.context_key.is_none());
    assert!(s.epoch.load(Ordering::Acquire) > epoch);
}
#[test]
fn source_replacement_preserves_selection_applies_only_new_defaults_and_is_idempotent() {
    let home = tempfile::tempdir().unwrap();
    let first = source(home.path().join("first"), "system-history", true);
    let s = service(home.path().to_owned(), vec![first.clone()]);
    s.select_sources(vec![]).unwrap();
    let epoch = s.epoch.load(Ordering::Acquire);
    s.replace_sources(vec![first.clone()]).unwrap();
    assert_eq!(s.epoch.load(Ordering::Acquire), epoch);
    let next = source(home.path().join("next"), "managed-next", true);
    let optional = source(home.path().join("optional"), "managed-optional", false);
    let state = s
        .replace_sources(vec![first.clone(), next.clone(), optional.clone()])
        .unwrap();
    assert!(!state.sources[0].enabled);
    assert!(state.sources[1].enabled);
    assert!(!state.sources[2].enabled);
    let persisted = read_selection(
        &home.path().join("sources.json"),
        &[first.clone(), next.clone(), optional],
    )
    .unwrap();
    assert_eq!(persisted, BTreeSet::from(["managed-next".to_owned()]));
    let moved = source(home.path().join("changed-root"), "system-history", true);
    s.state.lock().unwrap().snapshot = Some(json!({"old":true}));
    let state = s.replace_sources(vec![moved, next]).unwrap();
    assert!(state.snapshot.is_none());
    assert!(!state.sources[0].enabled);
    assert!(state.sources[1].enabled);
    assert!(s
        .select_sources(vec!["unknown-or-linked-id".into()])
        .is_err());
}
#[test]
fn a_late_event_cannot_restore_a_cancelled_generation() {
    let home = tempfile::tempdir().unwrap();
    let s = service(home.path().to_owned(), vec![]);
    let context = "a".repeat(64);
    s.state.lock().unwrap().context_key = Some(context.clone());
    s.epoch.store(2, Ordering::Release);
    let event =
        serde_json::to_vec(&json!({"event":"rate","contextKey":context,"rate":null})).unwrap();
    assert!(s.accept_event(&event, &context, 1).is_err());
    assert_eq!(s.state().unwrap().revision, 0);
    s.cancel().unwrap();
    assert!(s.accept_event(&event, &context, 2).is_err());
    assert_eq!(s.state().unwrap().phase, "stopped");
}
#[test]
fn unknown_field_in_timed_metrics_is_rejected_and_public_model_route_is_allowed() {
    let mut value = json!({"capabilities":{"throughput":true},"modelThroughput":{"public/model@route":{"timedTokens":0,"timedOutputTokens":0,"timedDurationMs":0}}});
    for key in [
        "clients",
        "clientCosts",
        "clientCacheReads",
        "clientCacheWrites",
        "clientOutputs",
        "clientUnclassifiedTokens",
        "models",
        "modelCosts",
        "modelCacheReads",
        "modelCacheWrites",
        "modelOutputs",
        "modelUnclassifiedTokens",
    ] {
        value[key] = json!({});
    }
    assert!(validate_period(&value).is_ok());
    assert!(validate_tree(&value, "", 0).is_ok());
    value["modelThroughput"]["public/model@route"]["unexpected"] = json!(1);
    assert!(validate_period(&value).is_err());
}
#[test]
fn actual_pinned_handler_projection_passes_native_gate_without_losing_multi_source_history() {
    let snapshot: Value = serde_json::from_slice(include_bytes!(
        "../../../../token-monitor/tests/fixtures/handler-snapshot.json"
    ))
    .unwrap();
    let root = std::env::temp_dir().join("synthetic");
    let sources = vec![
        TokenMonitorSource {
            id: "codex-synthetic".into(),
            provider_id: "codex".into(),
            label: "Codex".into(),
            root: root.clone(),
            path_role: SourceRole::CodexHome,
            default_enabled: true,
        },
        TokenMonitorSource {
            id: "claude-synthetic".into(),
            provider_id: "claude".into(),
            label: "Claude".into(),
            root,
            path_role: SourceRole::LogRoot,
            default_enabled: true,
        },
    ];
    validate_snapshot(&snapshot, &sources).unwrap();
    assert_eq!(
        snapshot["payload"]["aggregate"]["today"]["totalTokens"],
        300
    );
    assert_eq!(snapshot["payload"]["history"]["daily"][0]["tokens"], 100);
    assert_eq!(snapshot["payload"]["history"]["daily"][0]["cost"], 10);
    for available in [json!(true), json!(false), Value::Null] {
        let mut projected = snapshot.clone();
        projected["payload"]["usage"] = json!({"historyAvailable":available});
        validate_snapshot(&projected, &sources).unwrap();
    }
    for usage in [
        json!({"historyAvailable":"true"}),
        json!({"historyAvailable":true,"unverified":true}),
    ] {
        let mut projected = snapshot.clone();
        projected["payload"]["usage"] = usage;
        assert!(validate_snapshot(&projected, &sources).is_err());
    }
    let mut wrong = snapshot.clone();
    wrong["payload"]["history"]["daily"][0]["perClient"]["codex"]["prompt"] = json!("private");
    assert!(validate_snapshot(&wrong, &sources).is_err());
    let mut wrong = snapshot.clone();
    wrong["payload"]["aggregate"]["today"]["extra"] = json!(1);
    assert!(validate_snapshot(&wrong, &sources).is_err());
}
#[test]
fn exit_fence_never_reopens_a_host() {
    let home = tempfile::tempdir().unwrap();
    let s = service(home.path().to_owned(), vec![]);
    s.set_timezone("Asia/Shanghai".into()).unwrap();
    s.cancel_for_exit();
    assert!(matches!(s.refresh(),Err(e)if e.code()=="statistics_cancelled"));
}

#[cfg(windows)]
#[test]
#[ignore = "Requires this build's pinned staged Node/scanner resources; synthetic roots only"]
fn staged_node_and_scanner_native_smoke() {
    let resources = PathBuf::from(
        std::env::var_os("AIGOODBRO_TM_TEST_RESOURCES")
            .expect("explicit staged resource directory required"),
    );
    let home = tempfile::tempdir().unwrap();
    let codex = home.path().join("codex");
    fs::create_dir_all(codex.join("sessions")).unwrap();
    let day = (Utc::now() - chrono::Duration::days(1))
        .format("%Y-%m-%d")
        .to_string();
    let content = String::from_utf8(
        include_bytes!("../../../../token-monitor/tests/fixtures/codex-duration.jsonl").to_vec(),
    )
    .unwrap()
    .replace("2040-01-01", &day);
    let file = codex.join("sessions/synthetic.jsonl");
    fs::write(&file, content).unwrap();
    let before = hash(&fs::read(&file).unwrap());
    let data = home.path().join("data");
    let s = TokenMonitorService::native(
        resources,
        data,
        vec![TokenMonitorSource {
            id: "system-history".into(),
            provider_id: "codex".into(),
            label: "Codex synthetic".into(),
            root: codex,
            path_role: SourceRole::CodexHome,
            default_enabled: true,
        }],
        String::new(),
    )
    .unwrap();
    assert!(matches!(s.refresh(),Err(e)if e.code()=="statistics_timezone_required"));
    s.set_timezone("UTC".into()).unwrap();
    s.refresh().unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(180);
    let snapshot = loop {
        let state = s.state().unwrap();
        if let Some(snapshot) = state.snapshot {
            break snapshot;
        }
        assert_ne!(state.phase, "failed", "{:?}", state.failure_code);
        assert!(std::time::Instant::now() < deadline);
        std::thread::sleep(std::time::Duration::from_millis(50));
    };
    assert_eq!(
        snapshot["payload"]["aggregate"]["allTime"]["totalTokens"],
        160
    );
    assert_eq!(
        snapshot["payload"]["aggregate"]["allTime"]["timedDurationMs"],
        7000
    );
    assert_eq!(snapshot["payload"]["history"]["daily"][0]["tokens"], 160);
    assert!(
        s.state().unwrap().token_rate.is_none(),
        "initial totals must only anchor a tracker"
    );
    let cancelled = s.cancel().unwrap();
    assert_eq!(cancelled.phase, "stopped");
    assert!(!s.has_inflight_operation());
    assert_eq!(hash(&fs::read(&file).unwrap()), before);
}

#[test]
fn listener_install_reads_current_state_reentrantly_without_a_service_lock() {
    let home = tempfile::tempdir().unwrap();
    let service = service(home.path().to_owned(), vec![]);
    let weak = Arc::downgrade(&service);
    let (sent, received) = std::sync::mpsc::channel();
    let install = service.clone();
    std::thread::spawn(move || {
        let result = install.install_state_listener(Arc::new(move |value| {
            let current = weak.upgrade().unwrap().state().unwrap();
            sent.send((value.revision, current.revision)).unwrap();
        }));
        assert!(result.is_ok());
    });
    assert_eq!(
        received
            .recv_timeout(std::time::Duration::from_secs(2))
            .unwrap(),
        (0, 0)
    );
}

#[test]
fn listener_deduplicates_revision_and_callback_panic_cannot_poison_collection_state() {
    let home = tempfile::tempdir().unwrap();
    let service = service(home.path().to_owned(), vec![]);
    let called = Arc::new(AtomicU64::new(0));
    let count = called.clone();
    service
        .install_state_listener(Arc::new(move |_| {
            count.fetch_add(1, Ordering::AcqRel);
            panic!("synthetic presentation callback failure");
        }))
        .unwrap();
    service.publish_state(None);
    assert_eq!(called.load(Ordering::Acquire), 1);
    service.state.lock().unwrap().revision = 1;
    service.publish_state(None);
    assert_eq!(called.load(Ordering::Acquire), 2);
    assert_eq!(service.state().unwrap().revision, 1);
    assert!(service.notifications.lock().is_ok());
}

#[test]
fn listener_serializes_callbacks_and_coalesces_pending_to_latest_revision() {
    let home = tempfile::tempdir().unwrap();
    let service = service(home.path().to_owned(), vec![]);
    let seen = Arc::new(Mutex::new(Vec::new()));
    let records = seen.clone();
    let (entered, waiting) = std::sync::mpsc::channel();
    let (release, released) = std::sync::mpsc::channel();
    let released = Mutex::new(released);
    service
        .install_state_listener(Arc::new(move |value| {
            records.lock().unwrap().push(value.revision);
            if value.revision == 1 {
                entered.send(()).unwrap();
                released
                    .lock()
                    .unwrap()
                    .recv_timeout(std::time::Duration::from_secs(2))
                    .unwrap();
            }
        }))
        .unwrap();
    service.state.lock().unwrap().revision = 1;
    let publish = service.clone();
    let first = std::thread::spawn(move || publish.publish_state(None));
    waiting
        .recv_timeout(std::time::Duration::from_secs(2))
        .unwrap();
    service.state.lock().unwrap().revision = 2;
    service.publish_state(None);
    service.state.lock().unwrap().revision = 3;
    service.publish_state(None);
    release.send(()).unwrap();
    first.join().unwrap();
    assert_eq!(*seen.lock().unwrap(), vec![0, 1, 3]);
}

#[test]
fn listener_can_reentrantly_cancel_and_publishes_cleared_rate_after_current_callback() {
    let home = tempfile::tempdir().unwrap();
    let service = service(home.path().to_owned(), vec![]);
    let weak = Arc::downgrade(&service);
    let seen = Arc::new(Mutex::new(Vec::new()));
    let records = seen.clone();
    service.state.lock().unwrap().snapshot = Some(json!({"previous":true}));
    service
        .install_state_listener(Arc::new(move |value| {
            records.lock().unwrap().push((
                value.revision,
                value.phase,
                value.token_rate.is_none(),
                value.snapshot.is_some(),
            ));
            if value.revision == 0 {
                weak.upgrade().unwrap().cancel().unwrap();
            }
        }))
        .unwrap();
    let records = seen.lock().unwrap();
    assert_eq!(records.len(), 2);
    assert_eq!(records[0], (0, "idle", true, true));
    assert_eq!(records[1], (1, "stopped", true, true));
}

#[test]
fn listener_source_change_clears_scope_and_late_previous_generation_never_republishes() {
    let home = tempfile::tempdir().unwrap();
    let service = service(
        home.path().to_owned(),
        vec![source(home.path().join("codex"), "system-history", true)],
    );
    let context = "a".repeat(64);
    service.epoch.store(5, Ordering::Release);
    service.state.lock().unwrap().context_key = Some(context.clone());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let records = seen.clone();
    service
        .install_state_listener(Arc::new(move |value| {
            records.lock().unwrap().push(value);
        }))
        .unwrap();
    let rate =
        serde_json::to_vec(&json!({"event":"rate","contextKey":context,"rate":null})).unwrap();
    service.accept_event(&rate, &context, 5).unwrap();
    service.state.lock().unwrap().snapshot = Some(json!({"previous":true}));
    let after = service.select_sources(vec![]).unwrap();
    assert!(after.context_key.is_none());
    assert!(after.snapshot.is_none());
    assert!(after.token_rate.is_none());
    let before = seen.lock().unwrap().len();
    assert!(service.accept_event(&rate, &context, 5).is_err());
    service.publish_state(Some(5));
    let records = seen.lock().unwrap();
    assert_eq!(records.len(), before);
    let last = records.last().unwrap();
    assert_eq!(last.revision, after.revision);
    assert!(last.context_key.is_none() && last.snapshot.is_none() && last.token_rate.is_none());
    assert!(records
        .windows(2)
        .all(|rows| rows[0].revision < rows[1].revision));
}

#[test]
fn listener_identical_catalog_and_timezone_are_silent_and_exit_seals_publication() {
    let home = tempfile::tempdir().unwrap();
    let sources = vec![source(home.path().join("codex"), "system-history", true)];
    let service = service(home.path().to_owned(), sources.clone());
    let called = Arc::new(AtomicU64::new(0));
    let count = called.clone();
    service
        .install_state_listener(Arc::new(move |_| {
            count.fetch_add(1, Ordering::AcqRel);
        }))
        .unwrap();
    service.replace_sources(sources).unwrap();
    assert_eq!(called.load(Ordering::Acquire), 1);
    service.set_timezone("Asia/Shanghai".into()).unwrap();
    let after = called.load(Ordering::Acquire);
    service.set_timezone("Asia/Shanghai".into()).unwrap();
    assert_eq!(called.load(Ordering::Acquire), after);
    service.cancel_for_exit();
    service.state.lock().unwrap().revision += 1;
    service.publish_state(None);
    assert_eq!(called.load(Ordering::Acquire), after);
}
