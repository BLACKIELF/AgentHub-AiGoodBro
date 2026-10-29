//! Actual production automatic policy/service plus real AccountManager and
//! ManagedProxyGate. Encryption/runtime/live evidence collaborators below are
//! explicitly synthetic and are never registered by native composition.
pub use codexu_core::{accounts, atomic_settings, managed_proxy, readers, updates};
#[path = "../src/automatic_switch.rs"]
mod automatic_switch;
#[path = "support/windows_creation.rs"]
mod windows_creation;
use accounts::*;
use automatic_switch::*;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use codexu_core::managed_proxy::ManagedProxyGate;
use codexu_core::proxy::{AdmissionPass, AdmissionRequest, ProxyAccountGate};
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc, Condvar, Mutex,
    },
    time::{Duration, Instant},
};

fn now() -> u64 {
    chrono::Utc::now().timestamp_millis() as u64
}
fn err(code: &'static str) -> AccountError {
    AccountError { code }
}
fn auth(subject: &str, workspace: &str) -> Vec<u8> {
    let jwt=format!("synthetic.{}.not-a-real-signature",URL_SAFE_NO_PAD.encode(serde_json::to_vec(&json!({
        "email":format!("{subject}@fixture.invalid"),"account_id":workspace,"exp":4_102_444_800i64})).unwrap()));
    serde_json::to_vec(&json!({"tokens":{"access_token":jwt,"id_token":jwt,"refresh_token":"synthetic-refresh-only","account_id":workspace}})).unwrap()
}
fn identity_of(bytes: &[u8]) -> (String, String) {
    let value: Value = serde_json::from_slice(bytes).unwrap();
    let claims: Value = serde_json::from_slice(
        &URL_SAFE_NO_PAD
            .decode(
                value["tokens"]["access_token"]
                    .as_str()
                    .unwrap()
                    .split('.')
                    .nth(1)
                    .unwrap(),
            )
            .unwrap(),
    )
    .unwrap();
    (
        claims["email"].as_str().unwrap().into(),
        claims["account_id"].as_str().unwrap().into(),
    )
}
#[derive(Clone)]
struct Limits {
    plan: &'static str,
    five: Option<f64>,
    seven: Option<f64>,
}
impl Limits {
    fn response(&self) -> Value {
        let mut limits = json!({"planType":self.plan});
        if let Some(used) = self.five {
            limits["primary"] = json!({"usedPercent":used,"windowDurationMins":300,"resetsAt":chrono::Utc::now().timestamp()+3600});
        }
        if let Some(used) = self.seven {
            limits["secondary"] = json!({"usedPercent":used,"windowDurationMins":10080,"resetsAt":chrono::Utc::now().timestamp()+86400});
        }
        json!({"rateLimits":limits})
    }
}
struct FixtureProtector;
impl SecretProtector for FixtureProtector {
    fn seal(&self, context: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
        let mut out = context.as_bytes().to_vec();
        out.push(0);
        out.extend(bytes.iter().map(|b| b ^ 0x47));
        Ok(out)
    }
    fn unseal(&self, context: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
        let mut prefix = context.as_bytes().to_vec();
        prefix.push(0);
        if !bytes.starts_with(&prefix) {
            return Err(err("fixture_crypto_rejected"));
        }
        Ok(bytes[prefix.len()..].iter().map(|b| b ^ 0x47).collect())
    }
}
struct Pause {
    system: bool,
    entered: std::sync::mpsc::SyncSender<()>,
    released: Mutex<bool>,
    wake: Condvar,
}
struct FixtureRuntime {
    system: PathBuf,
    login: Mutex<(String, String)>,
    limits: Mutex<std::collections::BTreeMap<String, Limits>>,
    calls: AtomicUsize,
    idle: AtomicBool,
    fail: Mutex<Option<String>>,
    pause: Mutex<Option<Arc<Pause>>>,
}
impl FixtureRuntime {
    fn verified(&self, bytes: Vec<u8>) -> AccountResult<VerifiedCredential> {
        let (email, workspace) = identity_of(&bytes);
        if self.fail.lock().unwrap().as_deref() == Some(&workspace) {
            return Err(err("official_quota_unverified"));
        }
        let limits = self
            .limits
            .lock()
            .unwrap()
            .get(&workspace)
            .cloned()
            .unwrap();
        VerifiedCredential::from_official_read(
            bytes,
            &json!({"account":{"type":"chatgpt","email":email,"planType":limits.plan}}),
            limits.response(),
        )
    }
}
impl AccountRuntime for FixtureRuntime {
    fn available(&self) -> bool {
        true
    }
    fn login(
        &self,
        _: &Path,
        cancelled: &AtomicBool,
        _: &mut dyn FnMut(LoginAuthorization),
    ) -> AccountResult<VerifiedCredential> {
        if cancelled.load(Ordering::Acquire) {
            return Err(err("login_cancelled"));
        }
        let (subject, workspace) = self.login.lock().unwrap().clone();
        self.verified(auth(&subject, &workspace))
    }
    fn verify(&self, home: &Path, expected: &AccountIdentity) -> AccountResult<VerifiedCredential> {
        self.calls.fetch_add(1, Ordering::AcqRel);
        let bytes = std::fs::read(home.join("auth.json")).unwrap();
        if AccountIdentity::from_auth(&bytes)? != *expected {
            return Err(err("identity_mismatch"));
        }
        let pause = self.pause.lock().unwrap().clone();
        if let Some(pause) = pause.filter(|p| p.system == (home == self.system)) {
            pause.entered.send(()).unwrap();
            let until = Instant::now() + Duration::from_secs(5);
            let mut released = pause.released.lock().unwrap();
            while !*released {
                assert!(Instant::now() < until);
                released = pause
                    .wake
                    .wait_timeout(released, Duration::from_millis(20))
                    .unwrap()
                    .0;
            }
        }
        self.verified(bytes)
    }
    fn require_system_idle(&self) -> AccountResult<()> {
        if self.idle.load(Ordering::Acquire) {
            Ok(())
        } else {
            Err(err("account_busy"))
        }
    }
    fn validate_target_configuration(&self, home: &Path) -> AccountResult<()> {
        validate_target_configuration(home)
    }
}
struct FixtureSafety {
    available: AtomicBool,
    snapshot: Mutex<SafetySnapshot>,
}
impl AutomaticSwitchSafetySource for FixtureSafety {
    fn live_available(&self) -> bool {
        self.available.load(Ordering::Acquire)
    }
    fn snapshot(&self) -> automatic_switch::Result<SafetySnapshot> {
        Ok(self.snapshot.lock().unwrap().clone())
    }
}
struct FixtureObserver(Mutex<Vec<&'static str>>);
impl AutomaticSwitchObserver for FixtureObserver {
    fn record(&self, event: AutomaticSwitchEvent) {
        self.0.lock().unwrap().push(match event {
            AutomaticSwitchEvent::LowQuota {
                source_id,
                target_id,
                quota,
                at_ms,
            } => {
                assert_eq!(source_id.len(), 32);
                assert!(target_id.is_none_or(|id| id.len() == 32));
                assert!(quota.complete());
                assert!(at_ms > 0);
                "low"
            }
            AutomaticSwitchEvent::Succeeded {
                source_id,
                target_id,
                at_ms,
            } => {
                assert_eq!(source_id.len(), 32);
                assert_eq!(target_id.len(), 32);
                assert!(at_ms > 0);
                "success"
            }
            AutomaticSwitchEvent::Failed {
                source_id,
                target_id,
                failure,
                at_ms,
            } => {
                assert_eq!(source_id.len(), 32);
                assert_eq!(target_id.len(), 32);
                assert!(!failure.code().is_empty());
                assert!(at_ms > 0);
                "failure"
            }
        })
    }
}
struct Fixture {
    _temp: tempfile::TempDir,
    paths: AccountPaths,
    manager: Arc<AccountManager>,
    gate: Arc<ManagedProxyGate>,
    runtime: Arc<FixtureRuntime>,
    safety: Arc<FixtureSafety>,
    observer: Arc<FixtureObserver>,
    service: Arc<AutomaticSwitchService>,
    source: String,
    target: String,
}
impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = windows_creation::fixture_root(temp.path())
            .canonicalize()
            .unwrap();
        let system = root.join("synthetic-system");
        windows_creation::create_private_dir(&system).unwrap();
        windows_creation::write_private_file_new(
            &system.join("auth.json"),
            &auth("original", "original-workspace"),
        )
        .unwrap();
        windows_creation::write_private_file_new(
            &system.join("config.toml"),
            b"model_provider='openai'\ncli_auth_credentials_store='file'\n",
        )
        .unwrap();
        let paths = AccountPaths::isolated(root.join("vault"), system.clone()).unwrap();
        let runtime = Arc::new(FixtureRuntime {
            system,
            login: Mutex::new(("source".into(), "source-workspace".into())),
            limits: Mutex::new(
                [
                    (
                        "source-workspace".into(),
                        Limits {
                            plan: "plus",
                            five: Some(96.0),
                            seven: Some(20.0),
                        },
                    ),
                    (
                        "target-workspace".into(),
                        Limits {
                            plan: "plus",
                            five: Some(20.0),
                            seven: Some(20.0),
                        },
                    ),
                ]
                .into(),
            ),
            calls: AtomicUsize::new(0),
            idle: AtomicBool::new(true),
            fail: Mutex::new(None),
            pause: Mutex::new(None),
        });
        let manager = AccountManager::with_components(
            paths.clone(),
            Arc::new(FixtureProtector),
            runtime.clone(),
            None,
        )
        .unwrap();
        let gate = ManagedProxyGate::new(root.join("registry"), &manager).unwrap();
        manager.install_occupancy_gate(gate.clone()).unwrap();
        let source = Self::add(&manager, &runtime, "source", "source-workspace");
        let target = Self::add(&manager, &runtime, "target", "target-workspace");
        let ticket = manager
            .prepare_account_switch(source.clone())
            .unwrap()
            .ticket
            .unwrap();
        manager.commit_account_switch(&ticket).unwrap();
        let source_identity = manager.managed_identity_hash(&source).unwrap().unwrap();
        let safety = Arc::new(FixtureSafety {
            available: AtomicBool::new(true),
            snapshot: Mutex::new(SafetySnapshot {
                identity_hash: source_identity,
                credential_generation: manager
                    .verified_credential_snapshot(&source, 45)
                    .unwrap()
                    .token_generation,
                connection_generation: "synthetic-official-connection".into(),
                captured_at_ms: now(),
                connection: ConnectionMode::SharedDaemon,
                tasks: vec![TaskState::Idle],
                inactive_since_ms: Some(now() - 121_000),
                legacy_manager_running: Some(false),
            }),
        });
        let observer = Arc::new(FixtureObserver(Mutex::new(vec![])));
        let service = AutomaticSwitchService::new_with_observer(
            root.join("automatic.json"),
            manager.clone(),
            safety.clone(),
            Some(observer.clone()),
        )
        .unwrap();
        Self {
            _temp: temp,
            paths,
            manager,
            gate,
            runtime,
            safety,
            observer,
            service,
            source,
            target,
        }
    }
    fn add(
        manager: &Arc<AccountManager>,
        runtime: &Arc<FixtureRuntime>,
        subject: &str,
        workspace: &str,
    ) -> String {
        let id = manager
            .create_managed_account(format!("Synthetic {subject} {workspace}"), "codex".into())
            .unwrap()
            .id;
        *runtime.login.lock().unwrap() = (subject.into(), workspace.into());
        let attempt = manager.begin_account_login(id.clone()).unwrap();
        let until = Instant::now() + Duration::from_secs(3);
        loop {
            let status = manager.get_login_attempt(&attempt.attempt_id).unwrap();
            if status.phase == "verified" {
                break;
            }
            assert!(!["failed", "cancelled"].contains(&status.phase));
            assert!(Instant::now() < until);
            std::thread::sleep(Duration::from_millis(2));
        }
        id
    }
    fn enable(&self) {
        let mut p = self.service.preferences().unwrap();
        p.enabled = true;
        self.service.save_preferences(p).unwrap();
    }
    fn current(&self) -> String {
        let auth = std::fs::read(self.paths.system_home.join("auth.json")).unwrap();
        AccountIdentity::from_auth(&auth).unwrap().identity_hash()
    }
    fn source_hash(&self) -> String {
        self.manager
            .managed_identity_hash(&self.source)
            .unwrap()
            .unwrap()
    }
    fn pause(&self, system: bool) -> (Arc<Pause>, std::sync::mpsc::Receiver<()>) {
        let (tx, rx) = std::sync::mpsc::sync_channel(1);
        let pause = Arc::new(Pause {
            system,
            entered: tx,
            released: Mutex::new(false),
            wake: Condvar::new(),
        });
        *self.runtime.pause.lock().unwrap() = Some(pause.clone());
        (pause, rx)
    }
    fn stale_target(&self) {
        let path = self.paths.vault_root.join("accounts.dpapi");
        let protector = FixtureProtector;
        let mut value: Value = serde_json::from_slice(
            &protector
                .unseal(
                    "AiGoodBro.Next.Windows.accounts.v1",
                    &std::fs::read(&path).unwrap(),
                )
                .unwrap(),
        )
        .unwrap();
        let record = value["accounts"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|a| a["id"] == self.target)
            .unwrap();
        record["credential"]["observed_at"] = json!(chrono::Utc::now().timestamp() - 46);
        std::fs::write(
            path,
            protector
                .seal(
                    "AiGoodBro.Next.Windows.accounts.v1",
                    &serde_json::to_vec(&value).unwrap(),
                )
                .unwrap(),
        )
        .unwrap();
    }
}
fn release(pause: &Pause) {
    *pause.released.lock().unwrap() = true;
    pause.wake.notify_all();
}

#[test]
fn mac_threshold_edges_pro_topology_and_candidate_ranking_are_preserved() {
    let mut prefs = AutomaticSwitchPreferences::default();
    let quota = Quota {
        five_hour_remaining: Some(5.0),
        seven_day_remaining: Some(10.0),
        five_hour_not_applicable: false,
    };
    assert_eq!(quota.triggered(&prefs), vec![QuotaWindow::FiveHour]);
    prefs.seven_day_remaining_threshold = 1;
    assert_eq!(
        Quota {
            seven_day_remaining: Some(1.0),
            ..quota
        }
        .triggered(&prefs),
        vec![QuotaWindow::FiveHour, QuotaWindow::SevenDay]
    );
    let pro = Quota::from_official(
        Some("prolite"),
        &Limits {
            plan: "prolite",
            five: None,
            seven: Some(20.0),
        }
        .response(),
    )
    .unwrap();
    assert!(pro.complete());
    assert_eq!(pro.candidate_score(&[QuotaWindow::FiveHour]), Some(80.0));
    let plus = Quota::from_official(
        Some("plus"),
        &Limits {
            plan: "plus",
            five: None,
            seven: Some(20.0),
        }
        .response(),
    )
    .unwrap();
    assert!(!plus.complete());
    assert_eq!(plus.candidate_score(&[QuotaWindow::FiveHour]), None);
    assert_eq!(
        Quota {
            five_hour_remaining: Some(80.0),
            seven_day_remaining: Some(0.0),
            five_hour_not_applicable: false
        }
        .candidate_score(&[QuotaWindow::FiveHour]),
        None
    );
    assert_eq!(
        Quota {
            five_hour_remaining: Some(f64::NAN),
            ..quota
        }
        .candidate_score(&[QuotaWindow::FiveHour]),
        None
    );
    assert!(is_fresh(100_000, 45_000, 145_000));
    assert!(!is_fresh(100_000, 45_000, 145_001));
    assert_eq!(cooldown_until(Some(100), None), Some(3_600_100));
    assert_eq!(cooldown_until(None, Some(100)), Some(1_800_100));
    let permitted = SafetySnapshot {
        identity_hash: "a".repeat(64),
        credential_generation: "b".repeat(32),
        connection_generation: "same-official-peer".into(),
        captured_at_ms: 500_000,
        connection: ConnectionMode::SharedDaemon,
        tasks: vec![
            TaskState::Idle,
            TaskState::Failed,
            TaskState::Completed,
            TaskState::Interrupted,
        ],
        inactive_since_ms: Some(300_000),
        legacy_manager_running: Some(false),
    };
    assert!(permitted
        .validate_idle(
            &"a".repeat(64),
            &"b".repeat(32),
            Some("same-official-peer"),
            500_000
        )
        .is_ok());
    let mut disconnected = permitted.clone();
    disconnected.tasks.push(TaskState::Disconnected);
    assert_eq!(
        disconnected.validate_idle(&"a".repeat(64), &"b".repeat(32), None, 500_000),
        Err(Failure::TaskBusy)
    );
    assert_eq!(
        permitted.validate_idle(&"a".repeat(64), &"b".repeat(32), Some("new-peer"), 500_000),
        Err(Failure::IdentityChanged)
    );
    assert_eq!(
        permitted.validate_idle(&"a".repeat(64), &"c".repeat(32), None, 500_000),
        Err(Failure::IdentityChanged)
    );
}
#[test]
fn defaults_and_unsupported_live_connector_never_enable_a_fake_feature() {
    let f = Fixture::new();
    assert!(!f.service.preferences().unwrap().enabled);
    let before = f.runtime.calls.load(Ordering::Acquire);
    assert_eq!(f.service.evaluate_once().unwrap().phase, "disabled");
    assert_eq!(f.runtime.calls.load(Ordering::Acquire), before);
    let unavailable = AutomaticSwitchService::new(
        f._temp.path().join("unavailable.json"),
        f.manager.clone(),
        Arc::new(UnavailableSafetySource),
    )
    .unwrap();
    let mut prefs = unavailable.preferences().unwrap();
    prefs.enabled = true;
    assert_eq!(
        unavailable.save_preferences(prefs).unwrap_err(),
        Failure::LiveTasksUnavailable
    );
    assert!(!unavailable.preferences().unwrap().enabled);
    let mut prefs = f.service.preferences().unwrap();
    prefs.pause_at_one_percent = true;
    assert_eq!(
        f.service.save_preferences(prefs).unwrap_err(),
        Failure::PauseResumeUnavailable
    );
    assert_eq!(f.current(), f.source_hash());
}
#[test]
fn actual_manager_and_shared_gate_commit_then_persist_success_cooldown() {
    let f = Fixture::new();
    f.enable();
    let status = f.service.evaluate_once().unwrap();
    assert_eq!(status.phase, "switched");
    assert_eq!(
        f.current(),
        f.manager.managed_identity_hash(&f.target).unwrap().unwrap()
    );
    assert!(status.last_succeeded_at_ms.is_some());
    assert!(!status.resume_after_switch_available);
    assert_eq!(status.last_switch_restored, Some(false));
    assert_eq!(
        status.issue_code,
        Some(Failure::PauseResumeUnavailable.code())
    );
    assert!(status.last_attempt_at_ms.is_none());
    assert_eq!(f.observer.0.lock().unwrap().as_slice(), ["low", "success"]);
    let reopened = AutomaticSwitchService::new(
        f.paths.system_home.parent().unwrap().join("automatic.json"),
        f.manager.clone(),
        f.safety.clone(),
    )
    .unwrap();
    assert_eq!(reopened.evaluate_once().unwrap().phase, "cooldown");
}
#[test]
fn unknown_disconnected_busy_stale_foreground_and_legacy_evidence_block_before_prepare() {
    let f = Fixture::new();
    f.enable();
    let original = f.safety.snapshot.lock().unwrap().clone();
    let calls = f.runtime.calls.load(Ordering::Acquire);
    for mutate in [0, 1, 2, 3, 4, 5, 6] {
        let mut snapshot = original.clone();
        match mutate {
            0 => snapshot.connection = ConnectionMode::Disconnected,
            1 => snapshot.tasks = vec![TaskState::Recorded],
            2 => snapshot.tasks = vec![TaskState::WaitingInput],
            3 => snapshot.captured_at_ms = now() - 46_000,
            4 => snapshot.inactive_since_ms = Some(now() - 119_000),
            5 => snapshot.legacy_manager_running = None,
            _ => snapshot.connection = ConnectionMode::Isolated,
        }
        *f.safety.snapshot.lock().unwrap() = snapshot;
        assert!(f.service.evaluate_once().is_err());
        assert_eq!(f.current(), f.source_hash());
    }
    assert_eq!(f.runtime.calls.load(Ordering::Acquire), calls);
    assert!(f.service.status().unwrap().last_attempt_at_ms.is_none());
}
#[test]
fn no_candidate_consumes_the_mac_one_hour_retry_window() {
    let f = Fixture::new();
    let mut prefs = f.service.preferences().unwrap();
    prefs.enabled = true;
    prefs.excluded_profile_ids.insert(f.target.clone());
    f.service.save_preferences(prefs).unwrap();
    assert_eq!(
        f.service.evaluate_once().err(),
        Some(Failure::NoEligibleCandidate)
    );
    assert!(f.service.status().unwrap().last_attempt_at_ms.is_some());
    assert_eq!(f.service.evaluate_once().unwrap().phase, "cooldown");
    assert_eq!(f.current(), f.source_hash());
}
#[test]
fn stale_failed_candidate_reads_use_sixty_second_backoff_without_consuming_hour() {
    let f = Fixture::new();
    f.enable();
    f.stale_target();
    *f.runtime.fail.lock().unwrap() = Some("target-workspace".into());
    assert_eq!(f.service.evaluate_once().err(), Some(Failure::QuotaUnknown));
    let calls = f.runtime.calls.load(Ordering::Acquire);
    assert!(f.service.status().unwrap().last_attempt_at_ms.is_none());
    assert_eq!(f.service.evaluate_once().err(), Some(Failure::QuotaUnknown));
    assert_eq!(f.runtime.calls.load(Ordering::Acquire), calls);
    assert_eq!(f.current(), f.source_hash());
}
#[test]
fn live_proxy_lease_prevents_automatic_prepare_in_the_same_real_exclusion_domain() {
    let f = Fixture::new();
    f.enable();
    let run = "9".repeat(32);
    f.gate.activate_run(&run).unwrap();
    let snap = f
        .manager
        .verified_credential_snapshot(&f.target, 45)
        .unwrap();
    let at = now();
    let lease = f
        .gate
        .reserve(&AdmissionRequest {
            run_id: run.clone(),
            request_id: "automatic-fixture-request".into(),
            profile_id: f.target.clone(),
            expected_identity_hash: snap.identity_hash,
            expected_generation: snap.token_generation,
            pass: AdmissionPass::Subscription,
            policy: Default::default(),
            credit_floor: None,
            request_started_at_unix_ms: at,
            deadline_unix_ms: at + 10_000,
        })
        .unwrap();
    assert_eq!(f.service.evaluate_once().err(), Some(Failure::AccountBusy));
    assert_eq!(f.current(), f.source_hash());
    f.gate.release(&lease.tuple).unwrap();
    f.gate.retire_run(&run, true).unwrap();
}
#[test]
fn changing_live_task_state_during_preparation_cancels_exact_ticket() {
    let f = Fixture::new();
    f.enable();
    let (pause, entered) = f.pause(false);
    let service = f.service.clone();
    let worker = std::thread::spawn(move || service.evaluate_once());
    entered.recv_timeout(Duration::from_secs(3)).unwrap();
    f.safety.snapshot.lock().unwrap().tasks = vec![TaskState::Running];
    release(&pause);
    assert!(worker.join().unwrap().is_err());
    assert_eq!(f.current(), f.source_hash());
    assert!(!f.manager.has_inflight_operation());
}
#[test]
fn disable_during_commit_rolls_back_and_suppresses_late_success_events() {
    let f = Fixture::new();
    f.enable();
    let (pause, entered) = f.pause(true);
    let service = f.service.clone();
    let worker = std::thread::spawn(move || service.evaluate_once());
    entered.recv_timeout(Duration::from_secs(3)).unwrap();
    let mut prefs = f.service.preferences().unwrap();
    prefs.enabled = false;
    f.service.save_preferences(prefs).unwrap();
    release(&pause);
    assert_eq!(worker.join().unwrap().err(), Some(Failure::Cancelled));
    assert_eq!(f.current(), f.source_hash());
    assert!(!f.service.preferences().unwrap().enabled);
    assert_eq!(f.observer.0.lock().unwrap().as_slice(), ["low"]);
}
#[test]
fn exit_fence_during_commit_keeps_transaction_rollback_available() {
    let f = Fixture::new();
    f.enable();
    let (pause, entered) = f.pause(true);
    let service = f.service.clone();
    let worker = std::thread::spawn(move || service.evaluate_once());
    entered.recv_timeout(Duration::from_secs(3)).unwrap();
    f.service.cancel_for_exit();
    release(&pause);
    assert_eq!(worker.join().unwrap().err(), Some(Failure::Cancelled));
    assert_eq!(f.current(), f.source_hash());
}
#[test]
fn corrupt_settings_and_failed_disable_preserve_bytes_and_suspend_automation() {
    let f = Fixture::new();
    f.enable();
    let path = f.paths.system_home.parent().unwrap().join("automatic.json");
    std::fs::write(&path, b"invalid synthetic settings").unwrap();
    let mut prefs = f.service.preferences().unwrap();
    prefs.enabled = false;
    assert_eq!(
        f.service.save_preferences(prefs).unwrap_err(),
        Failure::SaveFailed
    );
    assert_eq!(std::fs::read(&path).unwrap(), b"invalid synthetic settings");
    assert_eq!(f.service.evaluate_once().err(), Some(Failure::SaveFailed));
    assert_eq!(f.current(), f.source_hash());
    assert!(AutomaticSwitchService::new(path, f.manager.clone(), f.safety.clone()).is_err());
}
#[test]
fn anonymous_email_group_optout_excludes_all_workspace_aliases() {
    let f = Fixture::new();
    f.runtime.limits.lock().unwrap().insert(
        "other-target-workspace".into(),
        Limits {
            plan: "plus",
            five: Some(10.0),
            seven: Some(10.0),
        },
    );
    let alias = Fixture::add(&f.manager, &f.runtime, "target", "other-target-workspace");
    let first = f
        .manager
        .managed_automation_keys(&f.target)
        .unwrap()
        .unwrap();
    let second = f.manager.managed_automation_keys(&alias).unwrap().unwrap();
    assert_eq!(first.0, second.0);
    assert_ne!(first.1, second.1);
    let mut prefs = f.service.preferences().unwrap();
    prefs.enabled = true;
    prefs.excluded_profile_ids.insert(alias);
    f.service.save_preferences(prefs).unwrap();
    assert_eq!(
        f.service.evaluate_once().err(),
        Some(Failure::NoEligibleCandidate)
    );
    assert_eq!(f.current(), f.source_hash());
}
#[test]
fn best_triggered_window_score_and_lexical_tie_break_match_mac() {
    let f = Fixture::new();
    let mut candidates = vec![];
    for subject in ["second", "third"] {
        let workspace = format!("{subject}-workspace");
        f.runtime.limits.lock().unwrap().insert(
            workspace.clone(),
            Limits {
                plan: "plus",
                five: Some(10.0),
                seven: Some(40.0),
            },
        );
        candidates.push(Fixture::add(&f.manager, &f.runtime, subject, &workspace));
    }
    candidates.sort();
    let expected = candidates[0].clone();
    f.enable();
    let status = f.service.evaluate_once().unwrap();
    assert_eq!(status.target_account_id, Some(expected.clone()));
    assert_eq!(
        f.current(),
        f.manager.managed_identity_hash(&expected).unwrap().unwrap()
    );
}
#[test]
fn owned_monitor_cancel_retires_worker_and_never_resumes_a_late_attempt() {
    let f = Fixture::new();
    f.enable();
    let (pause, entered) = f.pause(false);
    let monitor: AutomaticSwitchMonitor = f.service.start_monitor().unwrap();
    entered.recv_timeout(Duration::from_secs(3)).unwrap();
    assert!(f.service.has_inflight_operation());
    assert!(matches!(
        f.service.start_monitor(),
        Err(Failure::AccountBusy)
    ));
    monitor.cancel();
    release(&pause);
    let until = Instant::now() + Duration::from_secs(3);
    while !monitor.is_finished() {
        assert!(Instant::now() < until);
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(!f.service.has_inflight_operation());
    assert_eq!(f.service.status().unwrap().phase, "cancelled");
    assert_eq!(f.current(), f.source_hash());
    assert!(!f.observer.0.lock().unwrap().contains(&"success"));
}
#[test]
fn explicit_cancel_rolls_back_without_disabling_the_manual_manager() {
    let f = Fixture::new();
    f.enable();
    let (pause, entered) = f.pause(true);
    let service = f.service.clone();
    let worker = std::thread::spawn(move || service.evaluate_once());
    entered.recv_timeout(Duration::from_secs(3)).unwrap();
    assert_eq!(f.service.cancel().unwrap().phase, "cancelled");
    release(&pause);
    assert_eq!(worker.join().unwrap().err(), Some(Failure::Cancelled));
    assert_eq!(f.current(), f.source_hash());
    *f.runtime.pause.lock().unwrap() = None;
    let ticket = f
        .manager
        .prepare_account_switch(f.target.clone())
        .unwrap()
        .ticket
        .unwrap();
    assert_eq!(
        f.manager.commit_account_switch(&ticket).unwrap().phase,
        "committed"
    );
}
