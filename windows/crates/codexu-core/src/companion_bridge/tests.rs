use super::*;
use crate::accounts::storage;
use std::{
    collections::BTreeMap,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
        Arc, Mutex,
    },
};
fn h(s: &str) -> String {
    hash(s.as_bytes())
}
struct Live(Arc<AtomicBool>);
impl PeerGuard for Live {
    fn check(&self) -> Result<()> {
        if self.0.load(Ordering::SeqCst) {
            Ok(())
        } else {
            Err(fail("companion_peer_untrusted"))
        }
    }
}
struct Permit(Arc<AtomicUsize>);
impl Drop for Permit {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}
struct Fake {
    scope: Mutex<Scope>,
    now: AtomicU64,
    refreshes: AtomicUsize,
    reservations: AtomicUsize,
    held: Arc<AtomicUsize>,
    adopted: Mutex<Vec<Permit>>,
    creates: AtomicUsize,
    approves: AtomicUsize,
    records: Mutex<BTreeMap<String, Acknowledgement>>,
    mode: AtomicUsize,
    lookup_corrupt: AtomicBool,
    execution_authority: Mutex<Option<ExecutionAuthority>>,
    created_execution: Mutex<Vec<Option<WindowsExecution>>>,
    approved_execution: Mutex<Vec<Option<WindowsExecution>>>,
    request_deadlines: Mutex<Vec<Option<Instant>>>,
    request_peers: Mutex<Vec<Option<Peer>>>,
    audit_root: Mutex<Option<PathBuf>>,
    audit_order: Mutex<Vec<&'static str>>,
}
impl Fake {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            scope: Mutex::new(Scope {
                fingerprint: h("scope"),
                epoch: h("epoch"),
                runtime_sha256: h("python"),
                alias: "fixture".into(),
                valid_until_ms: 40_000,
            }),
            now: AtomicU64::new(1_000),
            refreshes: AtomicUsize::new(0),
            reservations: AtomicUsize::new(0),
            held: Arc::new(AtomicUsize::new(0)),
            adopted: Mutex::new(vec![]),
            creates: AtomicUsize::new(0),
            approves: AtomicUsize::new(0),
            records: Mutex::new(BTreeMap::new()),
            mode: AtomicUsize::new(0),
            lookup_corrupt: AtomicBool::new(false),
            execution_authority: Mutex::new(None),
            created_execution: Mutex::new(vec![]),
            approved_execution: Mutex::new(vec![]),
            request_deadlines: Mutex::new(vec![]),
            request_peers: Mutex::new(vec![]),
            audit_root: Mutex::new(None),
            audit_order: Mutex::new(vec![]),
        })
    }
    fn task(&self) -> TaskBinding {
        TaskBinding {
            task_id: "synthetic-task-1".into(),
            action_hash: h("action"),
            scope_sha256: self.scope.lock().unwrap().fingerprint.clone(),
        }
    }
    fn set_execution_authority(&self, authority: Option<ExecutionAuthority>) {
        *self.execution_authority.lock().unwrap() = authority;
    }
    fn create_with_body(&self, id: &str, body_sha256: String) -> Result<Acknowledgement> {
        self.audit_durable_phase("create");
        self.creates.fetch_add(1, Ordering::SeqCst);
        let ack = Acknowledgement {
            request_id: id.into(),
            body_sha256,
            task: self.task(),
            state: TaskState::AwaitingApproval,
        };
        self.records.lock().unwrap().insert(id.into(), ack.clone());
        match self.mode.load(Ordering::SeqCst) {
            1 => Err(fail("synthetic_lost_response")),
            2 => {
                let mut bad = ack;
                bad.body_sha256 = h("wrong");
                Ok(bad)
            }
            4 => {
                self.scope.lock().unwrap().fingerprint = h("changed-scope");
                Ok(ack)
            }
            _ => Ok(ack),
        }
    }
    fn audit_durable_phase(&self, stage: &'static str) {
        if let Some(root) = self.audit_root.lock().unwrap().clone() {
            let entry = journal::Journal::new(root)
                .unwrap()
                .get(&h("run"))
                .unwrap()
                .unwrap();
            match stage {
                "adopt" | "create" => assert!(matches!(entry.phase, journal::Phase::PendingCreate)),
                "approve" => assert!(matches!(entry.phase, journal::Phase::PendingApprove { .. })),
                _ => panic!("unexpected audit stage"),
            }
            if stage != "adopt" {
                assert_eq!(self.adopted.lock().unwrap().len(), 1);
                assert_eq!(self.held.load(Ordering::SeqCst), 1);
            }
            self.audit_order.lock().unwrap().push(stage);
        }
    }
}

fn execution_authority() -> ExecutionAuthority {
    ExecutionAuthority {
        profile_id: 1,
        preference: crate::workflow::WorkflowPreference {
            participating: true,
            model: Some("gpt-6-astra".into()),
            effort: Some("high".into()),
            service_tier: Some(crate::workflow_execution::ServiceTier::Fast),
            revision: 7,
            ..Default::default()
        },
        excluded_plan_types: vec!["pro".into()],
        official_plan: "plus".into(),
        models: vec![
            crate::workflow::WorkflowModel {
                id: "gpt-6-astra".into(),
                label: "Astra".into(),
                efforts: vec!["low".into(), "high".into(), "ultra".into()],
                default_effort: "low".into(),
                is_default: true,
            },
            crate::workflow::WorkflowModel {
                id: "gpt-5.5".into(),
                label: "5.5".into(),
                efforts: vec!["low".into(), "high".into(), "xhigh".into()],
                default_effort: "low".into(),
                is_default: false,
            },
        ],
    }
}
impl Backend for Fake {
    type Permit = Permit;
    fn set_request_deadline(&self, deadline: Option<Instant>) {
        self.request_deadlines.lock().unwrap().push(deadline);
    }
    fn set_request_peer(&self, peer: Option<Peer>) {
        self.request_peers.lock().unwrap().push(peer);
    }
    fn now_ms(&self) -> u64 {
        self.now.load(Ordering::SeqCst)
    }
    fn capture(&self, _: &Selector, refresh: bool) -> Result<Scope> {
        if refresh {
            self.refreshes.fetch_add(1, Ordering::SeqCst);
        }
        Ok(self.scope.lock().unwrap().clone())
    }
    fn execution_required(&self) -> bool {
        self.execution_authority.lock().unwrap().is_some()
    }
    fn capture_execution(
        &self,
        selector: &Selector,
        refresh: bool,
        _: &ExecutionOverrides,
    ) -> Result<(Scope, Option<ExecutionAuthority>)> {
        let scope = self.capture(selector, refresh)?;
        Ok((scope, self.execution_authority.lock().unwrap().clone()))
    }
    fn reserve(&self, _: &Scope) -> Result<Permit> {
        self.reservations.fetch_add(1, Ordering::SeqCst);
        self.held.fetch_add(1, Ordering::SeqCst);
        Ok(Permit(self.held.clone()))
    }
    fn adopt(&self, _: &str, _: &Scope, p: Permit) -> Result<()> {
        self.audit_durable_phase("adopt");
        self.adopted.lock().unwrap().push(p);
        Ok(())
    }
    fn create(&self, _: &str, s: &Scope, id: &str, prompt: &str) -> Result<Acknowledgement> {
        self.create_with_body(
            id,
            hash_parts(&[
                "create",
                "codex",
                "workspace",
                &s.alias,
                &hash(prompt.as_bytes()),
                "",
            ]),
        )
    }
    fn create_with_execution(
        &self,
        _: &str,
        s: &Scope,
        id: &str,
        prompt: &str,
        execution: Option<&WindowsExecution>,
        authority: Option<&ExecutionAuthority>,
    ) -> Result<Acknowledgement> {
        self.created_execution
            .lock()
            .unwrap()
            .push(execution.cloned());
        if execution.is_some() != authority.is_some() {
            return Err(fail("companion_execution_unavailable"));
        }
        let mut body = hash_parts(&[
            "create",
            "codex",
            "workspace",
            &s.alias,
            &hash(prompt.as_bytes()),
            "",
        ]);
        if let Some(execution) = execution {
            body = windows_execution_body_hash(&body, Some(execution))?;
        }
        self.create_with_body(id, body)
    }
    fn approve(&self, _: &str, _: &Scope, id: &str, task: &TaskBinding) -> Result<Acknowledgement> {
        self.audit_durable_phase("approve");
        self.approves.fetch_add(1, Ordering::SeqCst);
        let ack = Acknowledgement {
            request_id: id.into(),
            body_sha256: hash_parts(&["approve", &task.task_id, &task.action_hash]),
            task: task.clone(),
            state: TaskState::Running,
        };
        self.records.lock().unwrap().insert(id.into(), ack.clone());
        if self.mode.load(Ordering::SeqCst) == 3 {
            Err(fail("synthetic_lost_response"))
        } else {
            Ok(ack)
        }
    }
    fn approve_with_execution(
        &self,
        lease_id: &str,
        scope: &Scope,
        id: &str,
        task: &TaskBinding,
        execution: Option<&WindowsExecution>,
        authority: Option<&ExecutionAuthority>,
    ) -> Result<Acknowledgement> {
        self.approved_execution
            .lock()
            .unwrap()
            .push(execution.cloned());
        if execution.is_some() != authority.is_some() {
            return Err(fail("companion_execution_unavailable"));
        }
        self.approve(lease_id, scope, id, task)
    }
    fn lookup(
        &self,
        _: LookupAction,
        id: &str,
        _: &str,
        _: &str,
        _: &str,
    ) -> Result<Option<Acknowledgement>> {
        let mut v = self.records.lock().unwrap().get(id).cloned();
        if self.lookup_corrupt.load(Ordering::SeqCst) {
            if let Some(v) = &mut v {
                v.request_id = h("wrong-request");
            }
        }
        Ok(v)
    }
}
struct Fixture {
    _tmp: tempfile::TempDir,
    root: PathBuf,
    fake: Arc<Fake>,
    bridge: Bridge<Fake>,
    peer: Peer,
    live: Arc<AtomicBool>,
}
impl Fixture {
    fn new() -> Self {
        let tmp = tempfile::Builder::new()
            .prefix("companion-bridge-")
            .tempdir_in(std::env::temp_dir().canonicalize().unwrap())
            .unwrap();
        let root = tmp.path().join("private");
        storage::create_private_directory(&root).unwrap();
        let fake = Fake::new();
        let live = Arc::new(AtomicBool::new(true));
        let peer =
            Peer::from_native(h("actor"), h("python"), Box::new(Live(live.clone()))).unwrap();
        let bridge = Bridge::new(root.clone(), fake.clone()).unwrap();
        Self {
            _tmp: tmp,
            root,
            fake,
            bridge,
            peer,
            live,
        }
    }
    fn intent(&self) -> Intent {
        Intent {
            selector: Selector {
                profile_id: 1,
                project: "C:\\synthetic\\workspace".into(),
            },
            prompt: "synthetic prompt never persist this".into(),
            model: None,
            effort: None,
            tier: None,
        }
    }
    fn request(&self, id: &str, method: Method) -> Result<Reply> {
        self.bridge.handle(
            &self.peer,
            Request {
                abi: ABI,
                request_id: h(id),
                method,
            },
        )
    }
    fn reserve(&self) -> String {
        match self
            .request(
                "reserve",
                Method::Reserve {
                    intent: self.intent(),
                },
            )
            .unwrap()
        {
            Reply::Reserved { lease_id, .. } => lease_id,
            _ => panic!("missing reservation"),
        }
    }
    fn run(&self, lease: &str) -> Result<Reply> {
        self.request(
            "run",
            Method::Run {
                lease_id: lease.into(),
                intent: self.intent(),
            },
        )
    }
    fn calls(&self) -> (usize, usize) {
        (
            self.fake.creates.load(Ordering::SeqCst),
            self.fake.approves.load(Ordering::SeqCst),
        )
    }
}
#[test]
fn wire_exact_abi_length_and_unknown_fields() {
    let f = Fixture::new();
    let request = Request {
        abi: ABI,
        request_id: h("r"),
        method: Method::Reserve { intent: f.intent() },
    };
    let bytes = request.encode().unwrap();
    assert!(Request::decode(&bytes).is_ok());
    let mut extra = bytes.clone();
    extra.push(0);
    assert!(Request::decode(&extra).is_err());
    let mut wrong = bytes.clone();
    wrong[0] = 0;
    assert!(Request::decode(&wrong).is_err());
    let mut v: serde_json::Value = serde_json::from_slice(&bytes[4..]).unwrap();
    v["method"]["approved"] = serde_json::Value::Bool(true);
    let data = serde_json::to_vec(&v).unwrap();
    let mut frame = (data.len() as u32).to_le_bytes().to_vec();
    frame.extend(data);
    assert!(Request::decode(&frame).is_err());
    let mut oversized = f.intent();
    oversized.prompt = "x".repeat(65_537);
    assert!(oversized.validate().is_err());
    let mut unsupported = f.intent();
    unsupported.model = Some("self/claimed-model".into());
    assert_eq!(
        unsupported.validate().unwrap_err().code,
        "companion_invalid_execution_override"
    );
    assert_eq!(f.calls(), (0, 0));
}

#[test]
fn native_request_deadline_is_forwarded_without_resetting_and_expired_auth_cannot_restart_it() {
    let f = Fixture::new();
    let selector = f.intent().selector;
    let request = || Request {
        abi: ABI,
        request_id: h("native-deadline"),
        method: Method::Preflight {
            selector: selector.clone(),
        },
    };
    let deadline = Instant::now() + std::time::Duration::from_secs(30);
    assert!(matches!(
        f.bridge.handle_until(&f.peer, request(), deadline).unwrap(),
        Reply::Ready { .. }
    ));
    assert_eq!(
        f.fake.request_deadlines.lock().unwrap().as_slice(),
        &[Some(deadline), None]
    );
    let peers = f.fake.request_peers.lock().unwrap();
    assert_eq!(peers.len(), 2);
    assert!(peers[0].is_some());
    assert!(peers[1].is_none());
    assert!(peers[0].as_ref().unwrap().check().is_ok());
    drop(peers);
    f.live.store(false, Ordering::SeqCst);
    assert_eq!(
        f.fake.request_peers.lock().unwrap()[0]
            .as_ref()
            .unwrap()
            .check()
            .unwrap_err()
            .code,
        "companion_peer_untrusted"
    );

    let expired = Instant::now() - std::time::Duration::from_millis(1);
    assert_eq!(
        f.bridge
            .handle_until(&f.peer, request(), expired)
            .unwrap_err()
            .code,
        "companion_ipc_timeout"
    );
    assert_eq!(f.fake.refreshes.load(Ordering::SeqCst), 0);
    assert_eq!(
        f.fake.request_deadlines.lock().unwrap().as_slice(),
        &[Some(deadline), None]
    );
}

#[test]
fn concurrent_request_cannot_replace_another_request_peer_context() {
    let f = Fixture::new();
    let _active_request = f.bridge.request_context.try_lock().unwrap();
    f.fake.set_request_peer(Some(f.peer.clone()));
    let first_count = f.fake.request_peers.lock().unwrap().len();
    let other_live = Arc::new(AtomicBool::new(true));
    let other_peer = Peer::from_native(
        h("other-actor"),
        h("other-runtime"),
        Box::new(Live(other_live)),
    )
    .unwrap();
    let error = f
        .bridge
        .handle_until(
            &other_peer,
            Request {
                abi: ABI,
                request_id: h("concurrent-peer"),
                method: Method::Preflight {
                    selector: f.intent().selector,
                },
            },
            Instant::now() + std::time::Duration::from_secs(1),
        )
        .unwrap_err();
    assert_eq!(error.code, "companion_bridge_busy");
    let peers = f.fake.request_peers.lock().unwrap();
    assert_eq!(peers.len(), first_count);
    assert!(peers[0].as_ref().unwrap().check().is_ok());
}

#[test]
fn late_receipt_keeps_unknown_or_confirmed_success_and_never_replays_create() {
    let confirmed = Fixture::new();
    let confirmed_lease = confirmed.reserve();
    let confirmed_id = h("late-confirmed");
    let started = Instant::now();
    let deadline = started + std::time::Duration::from_secs(30);
    let now_calls = AtomicUsize::new(0);
    let confirmed_result = confirmed
        .bridge
        .handle_until_with_clock(
            &confirmed.peer,
            Request {
                abi: ABI,
                request_id: confirmed_id.clone(),
                method: Method::Run {
                    lease_id: confirmed_lease,
                    intent: confirmed.intent(),
                },
            },
            deadline,
            || {
                if now_calls.fetch_add(1, Ordering::SeqCst) < 2 {
                    started
                } else {
                    deadline + std::time::Duration::from_millis(1)
                }
            },
        )
        .unwrap();
    assert!(matches!(confirmed_result, Reply::Accepted { .. }));
    let confirmed_entry = confirmed
        .bridge
        .journal
        .get(&confirmed_id)
        .unwrap()
        .unwrap();
    assert!(matches!(
        confirmed_entry.phase,
        journal::Phase::Accepted { .. }
    ));
    assert_eq!(confirmed.calls(), (1, 1));

    let uncertain = Fixture::new();
    uncertain.fake.mode.store(1, Ordering::SeqCst);
    let uncertain_lease = uncertain.reserve();
    let uncertain_id = h("late-uncertain");
    let started = Instant::now();
    let deadline = started + std::time::Duration::from_secs(30);
    let now_calls = AtomicUsize::new(0);
    let uncertain_result = uncertain
        .bridge
        .handle_until_with_clock(
            &uncertain.peer,
            Request {
                abi: ABI,
                request_id: uncertain_id.clone(),
                method: Method::Run {
                    lease_id: uncertain_lease.clone(),
                    intent: uncertain.intent(),
                },
            },
            deadline,
            || {
                if now_calls.fetch_add(1, Ordering::SeqCst) < 2 {
                    started
                } else {
                    deadline + std::time::Duration::from_millis(1)
                }
            },
        )
        .unwrap();
    assert_eq!(uncertain_result, Reply::Unknown);
    let uncertain_entry = uncertain
        .bridge
        .journal
        .get(&uncertain_id)
        .unwrap()
        .unwrap();
    assert!(matches!(
        uncertain_entry.phase,
        journal::Phase::PendingCreate
    ));
    assert_eq!(uncertain.calls(), (1, 0));

    assert!(matches!(
        uncertain
            .request(
                "late-uncertain",
                Method::Run {
                    lease_id: uncertain_lease,
                    intent: uncertain.intent(),
                },
            )
            .unwrap(),
        Reply::Created { .. }
    ));
    assert_eq!(uncertain.calls(), (1, 0));
}

#[test]
fn execution_extension_is_persisted_and_used_for_create_and_approval() {
    let f = Fixture::new();
    f.fake.set_execution_authority(Some(execution_authority()));
    let mut intent = f.intent();
    intent.model = Some("gpt-5.5".into());
    intent.effort = Some("high".into());
    intent.tier = Some("default".into());
    let lease = match f
        .request(
            "reserve-execution",
            Method::Reserve {
                intent: intent.clone(),
            },
        )
        .unwrap()
    {
        Reply::Reserved { lease_id, .. } => lease_id,
        _ => panic!("unexpected reserve result"),
    };
    let result = f
        .request(
            "run-execution",
            Method::Run {
                lease_id: lease,
                intent: intent.clone(),
            },
        )
        .unwrap();
    assert!(matches!(result, Reply::Accepted { .. }));

    let entry = journal::Journal::new(f.root.clone())
        .unwrap()
        .get(&h("run-execution"))
        .unwrap()
        .unwrap();
    let execution = entry.binding.windows_execution.clone().unwrap();
    assert_eq!(execution.workflow_revision, 7);
    assert_eq!(execution.overrides.model.as_deref(), Some("gpt-5.5"));
    assert_eq!(execution.overrides.effort.as_deref(), Some("high"));
    assert_eq!(
        execution.overrides.service_tier,
        Some(crate::workflow_execution::ServiceTier::Default)
    );
    let old_body = hash_parts(&[
        "create",
        "codex",
        "workspace",
        "fixture",
        &hash(intent.prompt.as_bytes()),
        "",
    ]);
    assert_eq!(
        entry.binding.create_body,
        windows_execution_body_hash(&old_body, Some(&execution)).unwrap()
    );
    assert_eq!(
        f.fake.created_execution.lock().unwrap().as_slice(),
        &[Some(execution.clone())]
    );
    assert_eq!(
        f.fake.approved_execution.lock().unwrap().as_slice(),
        &[Some(execution)]
    );
    let serialized = serde_json::to_value(&entry.binding.windows_execution).unwrap();
    assert_eq!(
        serialized
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect::<Vec<_>>(),
        vec![
            "bindingSha256".to_owned(),
            "overrides".to_owned(),
            "workflowRevision".to_owned(),
        ]
    );
}

#[test]
fn fresh_reservation_rejects_changed_preference_or_model_inventory() {
    for change in ["preference", "models"] {
        let f = Fixture::new();
        let mut original = execution_authority();
        f.fake.set_execution_authority(Some(original.clone()));
        let mut intent = f.intent();
        intent.model = Some("gpt-5.5".into());
        let lease = match f
            .request(
                "reserve-stale-execution",
                Method::Reserve {
                    intent: intent.clone(),
                },
            )
            .unwrap()
        {
            Reply::Reserved { lease_id, .. } => lease_id,
            _ => panic!("unexpected reserve result"),
        };
        match change {
            "preference" => original.preference.model = Some("gpt-5.5".into()),
            "models" => original.models.push(crate::workflow::WorkflowModel {
                id: "gpt-5.6".into(),
                label: "new model".into(),
                efforts: vec!["low".into()],
                default_effort: "low".into(),
                is_default: false,
            }),
            _ => unreachable!(),
        }
        f.fake.set_execution_authority(Some(original));
        let error = f
            .request(
                "run-stale-execution",
                Method::Run {
                    lease_id: lease,
                    intent,
                },
            )
            .unwrap_err();
        assert_eq!(error.code, "companion_scope_changed", "{change}");
        assert_eq!(f.calls(), (0, 0), "{change}");
        assert!(f.fake.created_execution.lock().unwrap().is_empty());
    }
}

#[test]
fn invalid_execution_evidence_does_not_advertise_ready() {
    let f = Fixture::new();
    let mut authority = execution_authority();
    authority.excluded_plan_types = vec!["plus".into()];
    f.fake.set_execution_authority(Some(authority));
    let error = f
        .request(
            "preflight-invalid-plan",
            Method::Preflight {
                selector: f.intent().selector,
            },
        )
        .unwrap_err();
    assert_eq!(error.code, "companion_execution_unavailable");
}
#[test]
fn explicit_refresh_only_and_single_reservation_duplicate() {
    let f = Fixture::new();
    let selector = f.intent().selector;
    f.request(
        "preflight",
        Method::Preflight {
            selector: selector.clone(),
        },
    )
    .unwrap();
    assert_eq!(f.fake.refreshes.load(Ordering::SeqCst), 0);
    f.request("refresh", Method::Refresh { selector }).unwrap();
    assert_eq!(f.fake.refreshes.load(Ordering::SeqCst), 1);
    let a = f.reserve();
    let b = f.reserve();
    assert_eq!(a, b);
    assert_eq!(f.fake.refreshes.load(Ordering::SeqCst), 2);
    assert_eq!(f.fake.reservations.load(Ordering::SeqCst), 1);
    assert_eq!(f.calls(), (0, 0));
}
#[test]
fn one_guard_transferred_before_create_and_never_dropped_with_bridge() {
    let f = Fixture::new();
    let lease = f.reserve();
    assert_eq!(f.fake.held.load(Ordering::SeqCst), 1);
    assert!(matches!(
        f.run(&lease).unwrap(),
        Reply::Accepted {
            task_state: TaskState::Running,
            ..
        }
    ));
    assert_eq!(f.calls(), (1, 1));
    assert_eq!(f.fake.reservations.load(Ordering::SeqCst), 1);
    let fake = f.fake.clone();
    drop(f.bridge);
    assert_eq!(fake.held.load(Ordering::SeqCst), 1);
    assert_eq!(fake.adopted.lock().unwrap().len(), 1);
}
#[test]
fn cancel_only_unclaimed_reservation_and_never_submitted_job() {
    let f = Fixture::new();
    let lease = f.reserve();
    assert_eq!(
        f.request(
            "cancel",
            Method::CancelReservation {
                lease_id: lease.clone()
            }
        )
        .unwrap(),
        Reply::Cancelled
    );
    assert_eq!(f.fake.held.load(Ordering::SeqCst), 0);
    assert!(f.run(&lease).is_err());
    let lease = f.reserve();
    f.run(&lease).unwrap();
    assert!(f
        .request(
            "cancel-again",
            Method::CancelReservation { lease_id: lease }
        )
        .is_err());
    assert_eq!(f.fake.held.load(Ordering::SeqCst), 1);
    assert_eq!(f.calls(), (1, 1));
}
#[test]
fn expiry_peer_runtime_and_scope_changes_reject_before_mutation() {
    for change in 0..4 {
        let f = Fixture::new();
        let lease = f.reserve();
        match change {
            0 => f.fake.now.store(40_001, Ordering::SeqCst),
            1 => f.live.store(false, Ordering::SeqCst),
            2 => f.fake.scope.lock().unwrap().fingerprint = h("changed"),
            _ => f.fake.scope.lock().unwrap().runtime_sha256 = h("other-runtime"),
        }
        assert!(f.run(&lease).is_err());
        assert_eq!(f.calls(), (0, 0));
    }
}
#[test]
fn receiver_expiry_and_shutdown_release_only_unclaimed_guards() {
    let f = Fixture::new();
    let lease = f.reserve();
    assert_eq!(f.bridge.expire_unclaimed().unwrap(), 0);
    assert_eq!(f.fake.held.load(Ordering::SeqCst), 1);
    f.fake.now.store(40_001, Ordering::SeqCst);
    assert_eq!(f.bridge.expire_unclaimed().unwrap(), 1);
    assert_eq!(f.fake.held.load(Ordering::SeqCst), 0);
    assert!(f.run(&lease).is_err());
    assert_eq!(f.calls(), (0, 0));

    f.fake.now.store(1_000, Ordering::SeqCst);
    let abandoned = f.reserve();
    f.bridge.close_preparing().unwrap();
    assert_eq!(f.fake.held.load(Ordering::SeqCst), 0);
    assert!(f.run(&abandoned).is_err());
    let submitted = f.reserve();
    f.run(&submitted).unwrap();
    f.fake.now.store(40_001, Ordering::SeqCst);
    assert_eq!(f.bridge.expire_unclaimed().unwrap(), 0);
    f.bridge.close_preparing().unwrap();
    assert_eq!(f.fake.held.load(Ordering::SeqCst), 1);
    assert_eq!(f.fake.adopted.lock().unwrap().len(), 1);
    assert_eq!(f.calls(), (1, 1));
}
#[test]
fn each_durable_stage_failure_has_exact_zero_or_one_calls() {
    for fault in 1..=4 {
        let f = Fixture::new();
        let lease = f.reserve();
        f.bridge.journal.fail_write.store(fault, Ordering::SeqCst);
        let result = f.run(&lease);
        if fault == 1 {
            assert!(result.is_err());
            assert_eq!(f.calls(), (0, 0));
        } else {
            assert_eq!(result.unwrap(), Reply::Unknown);
            assert_eq!(f.calls(), (1, usize::from(fault == 4)));
        }
        if fault > 1 {
            f.run(&lease).unwrap();
            assert_eq!(f.calls(), (1, usize::from(fault == 4)));
            assert_eq!(f.fake.held.load(Ordering::SeqCst), 1);
        }
    }
}
#[test]
fn durable_pending_precedes_adoption_and_each_backend_mutation() {
    let f = Fixture::new();
    *f.fake.audit_root.lock().unwrap() = Some(f.root.clone());
    let lease = f.reserve();
    assert!(matches!(f.run(&lease).unwrap(), Reply::Accepted { .. }));
    assert_eq!(
        *f.fake.audit_order.lock().unwrap(),
        ["adopt", "create", "approve"]
    );
    assert_eq!(f.calls(), (1, 1));
    assert_eq!(f.fake.reservations.load(Ordering::SeqCst), 1);
    assert_eq!(f.fake.held.load(Ordering::SeqCst), 1);
}

#[test]
fn restarted_backend_with_no_session_keeps_all_durable_phases_read_only() {
    for fault in [0, 2, 3, 4] {
        let f = Fixture::new();
        let lease = f.reserve();
        if fault != 0 {
            f.bridge.journal.fail_write.store(fault, Ordering::SeqCst);
        }
        let result = f.run(&lease).unwrap();
        if fault == 0 {
            assert!(matches!(result, Reply::Accepted { .. }));
        } else {
            assert_eq!(result, Reply::Unknown);
        }
        let file = f.root.join("companion-requests-v1.json");
        let before = std::fs::read(&file).unwrap();
        let intent = f.intent();
        let fresh_backend = Fake::new();
        fresh_backend.scope.lock().unwrap().epoch = h("new-session-epoch");
        // A fresh backend has no old Session, request association, or owned
        // process. Reopening the durable journal must never recreate one.
        let reopened = Bridge::new(f.root.clone(), fresh_backend.clone()).unwrap();
        drop(f.bridge);
        for method in [
            Method::Status {
                operation_id: h("run"),
            },
            Method::Run {
                lease_id: lease.clone(),
                intent: intent.clone(),
            },
        ] {
            assert_eq!(
                reopened
                    .handle(
                        &f.peer,
                        Request {
                            abi: ABI,
                            request_id: h("run"),
                            method,
                        }
                    )
                    .unwrap(),
                Reply::Unknown
            );
        }
        assert_eq!(fresh_backend.creates.load(Ordering::SeqCst), 0);
        assert_eq!(fresh_backend.approves.load(Ordering::SeqCst), 0);
        assert_eq!(fresh_backend.reservations.load(Ordering::SeqCst), 0);
        assert!(fresh_backend.adopted.lock().unwrap().is_empty());
        assert_eq!(std::fs::read(file).unwrap(), before);
    }
}

#[test]
fn lost_create_or_approve_receipt_status_never_retransmits() {
    for mode in [1, 3] {
        let f = Fixture::new();
        let lease = f.reserve();
        f.fake.mode.store(mode, Ordering::SeqCst);
        assert_eq!(f.run(&lease).unwrap(), Reply::Unknown);
        let before = f.calls();
        let result = f.run(&lease).unwrap();
        if mode == 1 {
            assert!(matches!(result, Reply::Created { .. }));
        } else {
            assert!(matches!(result, Reply::Accepted { .. }));
        }
        assert_eq!(f.calls(), before);
        let reopened = Bridge::new(f.root.clone(), f.fake.clone()).unwrap();
        reopened
            .handle(
                &f.peer,
                Request {
                    abi: ABI,
                    request_id: h("status"),
                    method: Method::Status {
                        operation_id: h("run"),
                    },
                },
            )
            .unwrap();
        assert_eq!(f.calls(), before);
    }
}
#[test]
fn wrong_ack_and_wrong_lookup_do_not_authorize_approval_or_claim_success() {
    let f = Fixture::new();
    let lease = f.reserve();
    f.fake.mode.store(2, Ordering::SeqCst);
    assert_eq!(f.run(&lease).unwrap(), Reply::Unknown);
    assert_eq!(f.calls(), (1, 0));
    f.fake.lookup_corrupt.store(true, Ordering::SeqCst);
    assert_eq!(f.run(&lease).unwrap(), Reply::Unknown);
    assert_eq!(f.calls(), (1, 0));
}
#[test]
fn input_reuse_conflicts_and_journal_never_stores_prompt_or_paths() {
    let f = Fixture::new();
    let lease = f.reserve();
    f.run(&lease).unwrap();
    let mut changed = f.intent();
    changed.prompt.push('!');
    assert_eq!(
        f.request(
            "run",
            Method::Run {
                lease_id: lease,
                intent: changed
            }
        )
        .unwrap_err()
        .code,
        "companion_request_changed"
    );
    let data = std::fs::read_to_string(f.root.join("companion-requests-v1.json")).unwrap();
    assert!(!data.contains(&f.intent().prompt));
    assert!(!data.contains("workspace"));
    assert!(!data.contains("fixture"));
    assert_eq!(f.calls(), (1, 1));
}
#[test]
fn changed_scope_after_create_keeps_draft_without_later_auto_approval() {
    let f = Fixture::new();
    let lease = f.reserve();
    f.fake.mode.store(4, Ordering::SeqCst);
    assert!(matches!(f.run(&lease).unwrap(), Reply::Created { .. }));
    assert_eq!(f.calls(), (1, 0));
    f.fake.mode.store(0, Ordering::SeqCst);
    assert!(matches!(f.run(&lease).unwrap(), Reply::Created { .. }));
    assert_eq!(f.calls(), (1, 0));
}
#[test]
fn malformed_journal_is_preserved_and_cannot_create() {
    let f = Fixture::new();
    let lease = f.reserve();
    let path = f.root.join("companion-requests-v1.json");
    storage::atomic_write(&path, b"not-json").unwrap();
    assert_eq!(f.run(&lease).unwrap_err().code, "companion_journal_invalid");
    assert_eq!(std::fs::read(path).unwrap(), b"not-json");
    assert_eq!(f.calls(), (0, 0));
}
