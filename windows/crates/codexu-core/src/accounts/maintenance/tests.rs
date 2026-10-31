//! Production service/gate, synthetic vault, and an explicit non-network runtime.
use super::*;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde_json::json;
use std::sync::atomic::AtomicUsize;

struct FixtureProtector;
impl SecretProtector for FixtureProtector {
    fn seal(&self, _: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
        Ok(bytes.iter().map(|b| b ^ 0x6b).collect())
    }
    fn unseal(&self, _: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
        self.seal("", bytes)
    }
}
struct FixtureRuntime {
    calls: AtomicUsize,
    entered: AtomicBool,
    release: AtomicBool,
    may_have_sent: bool,
    reset_allowed: AtomicBool,
    reset_calls: AtomicUsize,
}
impl Runtime for FixtureRuntime {
    fn available(&self) -> bool {
        true
    }
    fn warmup(
        &self,
        _: &super::super::super::identity::StoredCredential,
        admit: &dyn Fn() -> Result<()>,
    ) -> Execution {
        self.calls.fetch_add(1, Ordering::AcqRel);
        self.entered.store(true, Ordering::Release);
        wait_until(|| self.release.load(Ordering::Acquire));
        Execution {
            outcome: if admit().is_ok() {
                Outcome::Succeeded
            } else if self.may_have_sent {
                Outcome::Unknown
            } else {
                Outcome::NotSent
            },
            verified: None,
        }
    }
    fn reset(
        &self,
        _: &Path,
        _: &super::super::super::identity::StoredCredential,
        claim: &dyn Fn(&Card) -> Result<String>,
        admit: &dyn Fn() -> Result<()>,
    ) -> Execution {
        assert!(self.reset_allowed.load(Ordering::Acquire));
        let selected = Card {
            id: "synthetic-reset-credit".into(),
            expires_at_ms: now() + 600000,
            fingerprint: "b".repeat(64),
        };
        let outcome = if claim(&selected).is_ok() && admit().is_ok() {
            self.reset_calls.fetch_add(1, Ordering::AcqRel);
            Outcome::Reset
        } else {
            Outcome::NotSent
        };
        Execution {
            outcome,
            verified: None,
        }
    }
}
fn wait_until(check: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !check() {
        assert!(Instant::now() < deadline, "fixture operation timed out");
        std::thread::sleep(Duration::from_millis(5));
    }
}
struct Fixture {
    _temp: tempfile::TempDir,
    service: Arc<AccountMaintenanceService>,
    runtime: Arc<FixtureRuntime>,
    system_auth: PathBuf,
    profile_id: String,
}
impl Fixture {
    fn new(wait: bool, may_have_sent: bool) -> Self {
        let temp = tempfile::tempdir().unwrap();
        // Production creation enforces Windows TokenUser ownership even on CI.
        let root = temp.path().join("synthetic-maintenance");
        storage::create_private_directory(&root).unwrap();
        let root = root.canonicalize().unwrap();
        let system = root.join("synthetic-system-home");
        storage::secure_directory(&system).unwrap();
        let system_auth = system.join("auth.json");
        storage::atomic_write(&system_auth, b"synthetic untouched system auth").unwrap();
        let manager = AccountManager::with_components(
            AccountPaths::isolated(root.join("vault"), system).unwrap(),
            Arc::new(FixtureProtector),
            Arc::new(NativeAccountRuntime),
            None,
        )
        .unwrap();
        let gate =
            crate::managed_proxy::ManagedProxyGate::new(root.join("dispatch"), &manager).unwrap();
        manager.install_occupancy_gate(gate).unwrap();
        let id = manager
            .create_managed_account("Synthetic maintenance fixture".into(), "codex".into())
            .unwrap()
            .id;
        let jwt = format!(
            "synthetic.{}.not-a-real-signature",
            URL_SAFE_NO_PAD.encode(
                serde_json::to_vec(&json!({"email":"maintenance@fixture.invalid","account_id":"synthetic-maintenance-account","exp":4_102_444_800i64})).unwrap()
            )
        );
        let auth = serde_json::to_vec(&json!({"tokens":{"access_token":jwt,"id_token":jwt,"refresh_token":"synthetic-refresh","account_id":"synthetic-maintenance-account"}})).unwrap();
        let verified = crate::accounts::VerifiedCredential::from_official_read(
            auth,
            &json!({"account":{"type":"chatgpt","email":"maintenance@fixture.invalid","planType":"plus"}}),
            json!({"rateLimits":{"planType":"plus","primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":chrono::Utc::now().timestamp()+3600}}}),
        )
        .unwrap();
        {
            let mut store = manager.store().unwrap();
            store.vault.account_mut(&id).unwrap().credential =
                Some(verified.into_stored("c".repeat(32)));
            store.save().unwrap();
        }
        let runtime = Arc::new(FixtureRuntime {
            calls: AtomicUsize::new(0),
            entered: AtomicBool::new(false),
            release: AtomicBool::new(!wait),
            may_have_sent,
            reset_allowed: AtomicBool::new(false),
            reset_calls: AtomicUsize::new(0),
        });
        let service = AccountMaintenanceService::with_runtime(
            root.join("maintenance.json"),
            manager,
            runtime.clone(),
        )
        .unwrap();
        Self {
            _temp: temp,
            service,
            runtime,
            system_auth,
            profile_id: id,
        }
    }
    fn start(&self) -> std::thread::JoinHandle<Result<AccountMaintenanceStatus>> {
        self.service.set_warmup_selection(true, false).unwrap();
        let service = self.service.clone();
        let worker = std::thread::spawn(move || service.evaluate_once());
        wait_until(|| self.runtime.entered.load(Ordering::Acquire));
        worker
    }
    fn untouched(&self) {
        assert_eq!(
            std::fs::read(&self.system_auth).unwrap(),
            b"synthetic untouched system auth"
        );
    }
}

#[test]
fn default_off_then_explicit_opt_in_runs_once_without_switching_system_auth() {
    let f = Fixture::new(false, false);
    assert_eq!(f.service.evaluate_once().unwrap().phase, "disabled");
    assert_eq!(f.runtime.calls.load(Ordering::Acquire), 0);
    assert!(!f.service.path.exists());
    f.service.set_warmup_selection(true, false).unwrap();
    let status = f.service.evaluate_once().unwrap();
    assert_eq!(status.phase, "idle");
    assert_eq!(status.entries[0].phase, "succeeded");
    f.service.evaluate_once().unwrap();
    assert_eq!(f.runtime.calls.load(Ordering::Acquire), 1);
    assert!(!f.service.has_inflight_operation());
    f.untouched();
}

#[test]
fn cancellation_fences_unsent_work_and_does_not_replay_same_window() {
    let f = Fixture::new(true, false);
    let worker = f.start();
    assert!(f.service.has_inflight_operation());
    assert_eq!(f.service.status().unwrap().phase, "running");
    f.service.cancel().unwrap();
    f.runtime.release.store(true, Ordering::Release);
    let status = worker.join().unwrap().unwrap();
    assert_eq!(status.phase, "idle");
    assert_eq!(status.entries[0].phase, "cancelled");
    assert_eq!(status.issue_code, Some(Failure::Cancelled.code()));
    f.service.evaluate_once().unwrap();
    assert_eq!(f.runtime.calls.load(Ordering::Acquire), 1);
    assert!(!f.service.has_inflight_operation());
    f.untouched();
}

#[test]
fn exit_fence_keeps_sent_unknown_and_rejects_future_work_and_settings() {
    let f = Fixture::new(true, true);
    let worker = f.start();
    f.service.cancel_for_exit();
    f.runtime.release.store(true, Ordering::Release);
    let status = worker.join().unwrap().unwrap();
    assert_eq!(status.entries[0].phase, "uncertain");
    assert_eq!(status.issue_code, Some(Failure::OutcomeUnknown.code()));
    assert!(matches!(f.service.evaluate_once(), Err(Failure::Cancelled)));
    assert!(matches!(
        f.service.set_warmup_selection(false, false),
        Err(Failure::Cancelled)
    ));
    assert!(matches!(f.service.start_monitor(), Err(Failure::Cancelled)));
    assert!(!f.service.has_inflight_operation());
    f.untouched();
}

#[test]
fn staging_failure_clears_runtime_running_but_preserves_durable_attempt() {
    let f = Fixture::new(false, false);
    f.service.set_warmup_selection(true, false).unwrap();
    let staging = f.service.manager.paths.staging();
    std::fs::remove_dir(&staging).unwrap();
    storage::atomic_write(&staging, b"synthetic staging failure").unwrap();
    let status = f.service.evaluate_once().unwrap();
    assert_eq!(status.phase, "idle");
    assert!(status.running_profile_id.is_none());
    assert!(status.issue_code.is_some());
    assert_eq!(status.entries[0].phase, "running");
    assert_eq!(f.runtime.calls.load(Ordering::Acquire), 0);
    assert!(!f.service.has_inflight_operation());
    f.untouched();
}

#[test]
fn retained_monitor_reports_state_and_cancel_releases_single_worker_slot() {
    let f = Fixture::new(false, false);
    let updates = Arc::new(AtomicUsize::new(0));
    let signal = updates.clone();
    let monitor = f
        .service
        .start_monitor_with_listener(Arc::new(move || {
            signal.fetch_add(1, Ordering::AcqRel);
        }))
        .unwrap();
    assert!(matches!(f.service.start_monitor(), Err(Failure::Busy)));
    wait_until(|| updates.load(Ordering::Acquire) > 0);
    drop(monitor);
    wait_until(|| !f.service.monitor_active.load(Ordering::Acquire));
    let next = f.service.start_monitor().unwrap();
    f.service.cancel_for_exit();
    drop(next);
    wait_until(|| !f.service.monitor_active.load(Ordering::Acquire));
    assert_eq!(f.runtime.calls.load(Ordering::Acquire), 0);
    f.untouched();
}

#[test]
fn reset_requires_identity_bound_opt_in_and_keeps_success_on_repeated_card() {
    let f = Fixture::new(false, false);
    f.service.set_reset_options(30).unwrap();
    assert_eq!(f.service.evaluate_once().unwrap().phase, "disabled");
    f.runtime.reset_allowed.store(true, Ordering::Release);
    f.service.authorize_reset(&f.profile_id, true).unwrap();
    let status = f.service.evaluate_once().unwrap();
    assert_eq!(status.entries[0].kind, "reset_credit");
    assert_eq!(status.entries[0].phase, "succeeded");
    let before = serde_json::to_value(&status.entries).unwrap();
    let repeated = f.service.evaluate_once().unwrap();
    assert_eq!(serde_json::to_value(&repeated.entries).unwrap(), before);
    assert_eq!(f.runtime.reset_calls.load(Ordering::Acquire), 1);
    f.service.authorize_reset(&f.profile_id, false).unwrap();
    assert_eq!(f.service.evaluate_once().unwrap().phase, "disabled");
    assert_eq!(f.runtime.reset_calls.load(Ordering::Acquire), 1);
    f.untouched();
}
