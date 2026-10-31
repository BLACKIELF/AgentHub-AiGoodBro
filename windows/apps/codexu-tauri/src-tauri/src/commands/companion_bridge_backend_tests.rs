use super::*;
use std::sync::atomic::AtomicUsize;

fn scope() -> Scope {
    Scope {
        fingerprint: "a".repeat(64),
        epoch: "b".repeat(64),
        runtime_sha256: "c".repeat(64),
        alias: "account-7".into(),
        valid_until_ms: u64::MAX,
    }
}
fn task(state: &str) -> Value {
    json!({"id":"task-fixture","agent":"codex","project":"workspace",
        "accountAlias":"account-7","actionHash":"d".repeat(64),"state":state,
        "approvalExpired":false})
}
fn record(action: &'static str) -> Submitted {
    Submitted {
        lease: "e".repeat(64),
        action,
        body: "f".repeat(64),
        scope: scope().fingerprint,
        task: None,
    }
}
struct Guard(Arc<AtomicUsize>);
impl Drop for Guard {
    fn drop(&mut self) {
        self.0.fetch_add(1, Ordering::SeqCst);
    }
}

#[test]
fn adopted_unknown_guard_survives_missing_foreign_and_unproven_terminal_rows() {
    let released = Arc::new(AtomicUsize::new(0));
    let mut session = Claims::new().unwrap();
    let lease = "e".repeat(64);
    session
        .adopt(&lease, &scope(), Guard(released.clone()))
        .unwrap();
    for rows in [vec![], vec![task("succeeded")], vec![task("failed")]] {
        session.observe_tasks(&rows);
        assert_eq!(released.load(Ordering::SeqCst), 0);
        assert!(session.has_unresolved());
    }
    let binding = task_binding(&task("running"), &scope().fingerprint, &scope().alias)
        .unwrap()
        .0;
    session.adopted.get_mut(&lease).unwrap().task = Some(binding);
    for field in ["id", "actionHash", "accountAlias", "agent", "project"] {
        let mut foreign = task("succeeded");
        foreign[field] = json!("foreign");
        session.observe_tasks(&[foreign]);
        assert_eq!(released.load(Ordering::SeqCst), 0, "{field}");
    }
    for state in ["running", "uncertain", "cancel_requested", "unknown"] {
        session.observe_tasks(&[task(state)]);
        assert_eq!(released.load(Ordering::SeqCst), 0, "{state}");
    }
    session.observe_tasks(&[task("cancelled")]);
    assert_eq!(released.load(Ordering::SeqCst), 1);
    assert!(!session.has_unresolved());
    assert!(session.adopted.get(&lease).unwrap().task.is_some());
    session.observe_tasks(&[task("cancelled")]);
    assert_eq!(released.load(Ordering::SeqCst), 1);
}

#[test]
fn transferred_guard_keeps_exact_proof_and_exit_fence_until_matching_terminal() {
    let released = Arc::new(AtomicUsize::new(0));
    let mut session = Claims::new().unwrap();
    let mut leases = BTreeMap::new();
    let expected = record("create");
    session
        .adopt(&expected.lease, &scope(), Guard(released.clone()))
        .unwrap();
    let binding = task_binding(
        &task("awaiting_approval"),
        &scope().fingerprint,
        &scope().alias,
    )
    .unwrap()
    .0;
    session.bind_task(&expected, &binding, &mut leases).unwrap();
    assert!(session.adopted[&expected.lease].guard.is_none());
    assert_eq!(leases.len(), 1);
    assert!(session.has_unresolved());
    assert_eq!(session.retain_known_lease("ordinary-ui-task", &[]), None);
    let mut invalid_rows = vec![
        vec![],
        vec![task("running")],
        vec![task("uncertain")],
        vec![task("cancel_requested")],
    ];
    for field in ["id", "actionHash", "accountAlias", "agent", "project"] {
        let mut foreign = task("succeeded");
        foreign[field] = json!("foreign");
        invalid_rows.push(vec![foreign]);
    }
    for rows in invalid_rows {
        leases.retain(|id, _| session.retain_known_lease(id, &rows).unwrap());
        session.observe_tasks(&rows);
        assert_eq!(released.load(Ordering::SeqCst), 0);
        assert_eq!(leases.len(), 1);
        assert!(session.has_unresolved());
    }
    let rows = vec![task("cancelled")];
    leases.retain(|id, _| session.retain_known_lease(id, &rows).unwrap());
    session.observe_tasks(&rows);
    assert_eq!(released.load(Ordering::SeqCst), 1);
    assert!(leases.is_empty());
    assert!(!session.has_unresolved());
    session.bind_task(&expected, &binding, &mut leases).unwrap();
    assert!(leases.is_empty());
    session.observe_tasks(&rows);
    assert_eq!(released.load(Ordering::SeqCst), 1);
}

#[test]
fn duplicate_adoption_cannot_replace_the_original_owned_guard() {
    let original = Arc::new(AtomicUsize::new(0));
    let rejected = Arc::new(AtomicUsize::new(0));
    let mut session = Claims::new().unwrap();
    let lease = "e".repeat(64);
    session
        .adopt(&lease, &scope(), Guard(original.clone()))
        .unwrap();
    assert!(session
        .adopt(&lease, &scope(), Guard(rejected.clone()))
        .is_err());
    assert_eq!(rejected.load(Ordering::SeqCst), 1);
    assert_eq!(original.load(Ordering::SeqCst), 0);
    assert!(session.has_unresolved());
}

#[test]
fn post_claim_is_single_use_even_if_body_is_identical_or_result_is_lost() {
    let mut session = Claims::<()>::new().unwrap();
    let id = "1".repeat(64);
    session.submit(&id, record("create")).unwrap();
    assert!(session.submit(&id, record("create")).is_err());
    assert!(session.submit(&id, record("approve")).is_err());
    assert_eq!(session.requests.len(), 1);
    assert_eq!(session.requests[&id].action, "create");
}

#[test]
fn lookup_requires_exact_request_action_body_task_and_scoped_account() {
    let id = "1".repeat(64);
    let expected = record("create");
    let valid = json!({"requestHash":digest(id.as_bytes()),"bodyHash":expected.body,
        "task":task("awaiting_approval")});
    let ack = decode_lookup(&valid, &id, &expected, "account-7").unwrap();
    assert_eq!(ack.state, TaskState::AwaitingApproval);
    for field in ["requestHash", "bodyHash"] {
        let mut wrong = valid.clone();
        wrong[field] = json!("0".repeat(64));
        assert!(decode_lookup(&wrong, &id, &expected, "account-7").is_err());
    }
    let mut finding = valid.clone();
    finding.as_object_mut().unwrap().remove("task");
    finding["findingId"] = json!("task-fixture");
    assert!(decode_lookup(&finding, &id, &expected, "account-7").is_err());
    for field in ["agent", "project", "accountAlias"] {
        let mut wrong = valid.clone();
        wrong["task"][field] = json!("foreign");
        assert!(decode_lookup(&wrong, &id, &expected, "account-7").is_err());
    }
    let mut approval = record("approve");
    approval.task = Some(ack.task);
    for field in ["id", "actionHash"] {
        let mut wrong = valid.clone();
        wrong["task"][field] = if field == "actionHash" {
            json!("0".repeat(64))
        } else {
            json!("other-task")
        };
        assert!(decode_lookup(&wrong, &id, &approval, "account-7").is_err());
    }
}

#[test]
fn backend_exit_is_not_user_acceptance_and_cancel_request_is_not_stopped() {
    assert_eq!(
        task_binding(&task("succeeded"), &scope().fingerprint, "account-7")
            .unwrap()
            .1,
        TaskState::AwaitingAcceptance
    );
    assert_eq!(
        task_binding(&task("cancel_requested"), &scope().fingerprint, "account-7")
            .unwrap()
            .1,
        TaskState::Uncertain
    );
    assert!(task_binding(&task("made_up_success"), &scope().fingerprint, "account-7").is_err());
}

#[test]
fn trusted_scope_binds_root_identity_auth_quota_revision_and_effective_preferences() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().canonicalize().unwrap();
    let other = root.join("other");
    std::fs::create_dir(&other).unwrap();
    let now = 10_000_000;
    let manager = json!({"profiles":[{"windowsBinding":{"quotaObservedAtMs":now-1000,
        "credentialExpiresAtMs":now+120000,"authSha256":"a".repeat(64),
        "identityHash":"b".repeat(64),"workflowRevision":3},
        "executionPreference":{"model":"gpt-synthetic","reasoningEffort":"high"},
        "automaticSwitchParticipation":true,"lastSnapshot":{"fiveHour":{"usedPercent":1}}}]});
    let capture = |workspace: &Path, home: &Path, value: &Value, time| {
        scope_from_snapshot(
            7,
            workspace,
            home,
            &scope().epoch,
            "account-7",
            &scope().runtime_sha256,
            value,
            time,
        )
    };
    let original = capture(&root, &root, &manager, now).unwrap();
    assert_eq!(original.valid_until_ms, now + 44000);
    assert_ne!(
        original.fingerprint,
        capture(&other, &root, &manager, now).unwrap().fingerprint
    );
    assert_ne!(
        original.fingerprint,
        capture(&root, &other, &manager, now).unwrap().fingerprint
    );
    for field in ["authSha256", "identityHash", "workflowRevision"] {
        let mut changed = manager.clone();
        changed["profiles"][0]["windowsBinding"][field] = json!("changed");
        assert_ne!(
            original.fingerprint,
            capture(&root, &root, &changed, now).unwrap().fingerprint
        );
    }
    for field in ["model", "reasoningEffort"] {
        let mut changed = manager.clone();
        changed["profiles"][0]["executionPreference"][field] = json!("changed");
        assert_ne!(
            original.fingerprint,
            capture(&root, &root, &changed, now).unwrap().fingerprint
        );
    }
    assert!(capture(&root, &root, &manager, now + 44000).is_err());
    assert!(capture(&root, &root, &manager, now - 2000).is_err());
    let mut expired = manager.clone();
    expired["profiles"][0]["windowsBinding"]["credentialExpiresAtMs"] = json!(now + 30000);
    assert!(capture(&root, &root, &expired, now).is_err());
}

#[test]
fn action_domains_and_exact_prompt_bytes_match_existing_hub_hash_contract() {
    let prompt = "  synthetic task\n";
    let create = parts(&[
        "create",
        "codex",
        "workspace",
        "account-7",
        &digest(prompt.as_bytes()),
        "",
    ]);
    let trimmed = parts(&[
        "create",
        "codex",
        "workspace",
        "account-7",
        &digest(prompt.trim().as_bytes()),
        "",
    ]);
    assert_ne!(create, trimmed);
    assert_ne!(create, parts(&["approve", "task-fixture", &"d".repeat(64)]));
    assert_ne!(
        create,
        parts(&[
            "create",
            "codex",
            "workspace",
            "account-8",
            &digest(prompt.as_bytes()),
            ""
        ])
    );
}

#[test]
fn project_selector_requires_exact_existing_absolute_directory_without_traversal() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().canonicalize().unwrap();
    let child = root.join("child");
    std::fs::create_dir(&child).unwrap();
    assert!(project_matches(&root, &root));
    assert!(!project_matches(Path::new("."), &root));
    assert!(!project_matches(&child, &root));
    assert!(!project_matches(&root.join("missing"), &root));
    // Raw construction preserves ParentDir even for Windows verbatim roots.
    let mut traversal = child.as_os_str().to_os_string();
    traversal.push(std::path::MAIN_SEPARATOR_STR);
    traversal.push("..");
    assert!(!project_matches(Path::new(&traversal), &root));
}
