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
struct FixtureAccountRuntime {
    verify_calls: AtomicUsize,
    pause: AtomicBool,
    entered: AtomicBool,
    release: AtomicBool,
    fail_next: AtomicBool,
}
impl crate::accounts::AccountRuntime for FixtureAccountRuntime {
    fn available(&self) -> bool {
        true
    }
    fn login(
        &self,
        _: &Path,
        _: &AtomicBool,
        _: &mut dyn FnMut(crate::accounts::LoginAuthorization),
    ) -> AccountResult<crate::accounts::VerifiedCredential> {
        Err(crate::accounts::fail("login_unavailable"))
    }
    fn verify(
        &self,
        home: &Path,
        expected: &crate::accounts::AccountIdentity,
    ) -> AccountResult<crate::accounts::VerifiedCredential> {
        self.verify_calls.fetch_add(1, Ordering::AcqRel);
        if self.pause.load(Ordering::Acquire) {
            self.entered.store(true, Ordering::Release);
            wait_until(|| self.release.load(Ordering::Acquire));
        }
        if self.fail_next.swap(false, Ordering::AcqRel) {
            return Err(crate::accounts::fail("verification_unavailable"));
        }
        let auth = std::fs::read(home.join("auth.json"))
            .map_err(|_| crate::accounts::fail("verification_unavailable"))?;
        crate::accounts::VerifiedCredential::from_official_read(
            auth,
            &json!({"account":{"type":"chatgpt","email":expected.email.clone(),"planType":"plus"}}),
            json!({"rateLimits":{"planType":"plus","primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":chrono::Utc::now().timestamp()+3600}}}),
        )
    }
    fn require_system_idle(&self) -> AccountResult<()> {
        Ok(())
    }
    fn validate_target_configuration(&self, _: &Path) -> AccountResult<()> {
        Ok(())
    }
}
fn add_fixture_account(
    manager: &AccountManager,
    label: &str,
    email: &str,
    account_id: &str,
    generation: &str,
) -> String {
    let id = manager
        .create_managed_account(label.into(), "codex".into())
        .unwrap()
        .id;
    let jwt = format!(
        "synthetic.{}.not-a-real-signature",
        URL_SAFE_NO_PAD.encode(
            serde_json::to_vec(
                &json!({"email":email,"account_id":account_id,"exp":4_102_444_800i64})
            )
            .unwrap()
        )
    );
    let auth = serde_json::to_vec(&json!({"tokens":{"access_token":jwt,"id_token":jwt,"refresh_token":"synthetic-refresh","account_id":account_id}})).unwrap();
    let verified = crate::accounts::VerifiedCredential::from_official_read(
        auth,
        &json!({"account":{"type":"chatgpt","email":email,"planType":"plus"}}),
        json!({"rateLimits":{"planType":"plus","primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":chrono::Utc::now().timestamp()+3600}}}),
    )
    .unwrap();
    let mut store = manager.store().unwrap();
    store.vault.account_mut(&id).unwrap().credential =
        Some(verified.into_stored(generation.into()));
    store.save().unwrap();
    id
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
    account_runtime: Arc<FixtureAccountRuntime>,
    system_auth: PathBuf,
    profile_id: String,
}
impl Fixture {
    fn new(wait: bool, may_have_sent: bool) -> Self {
        let temp = tempfile::tempdir().unwrap();
        // Production creation enforces Windows TokenUser ownership even on CI.
        let root = temp
            .path()
            .canonicalize()
            .unwrap()
            .join("synthetic-maintenance");
        storage::create_private_directory(&root).unwrap();
        let root = root.canonicalize().unwrap();
        let system = root.join("synthetic-system-home");
        storage::secure_directory(&system).unwrap();
        let system_auth = system.join("auth.json");
        storage::atomic_write(&system_auth, b"synthetic untouched system auth").unwrap();
        let account_runtime = Arc::new(FixtureAccountRuntime {
            verify_calls: AtomicUsize::new(0),
            pause: AtomicBool::new(false),
            entered: AtomicBool::new(false),
            release: AtomicBool::new(true),
            fail_next: AtomicBool::new(false),
        });
        let manager = AccountManager::with_components(
            AccountPaths::isolated(root.join("vault"), system).unwrap(),
            Arc::new(FixtureProtector),
            account_runtime.clone(),
            None,
        )
        .unwrap();
        let gate =
            crate::managed_proxy::ManagedProxyGate::new(root.join("dispatch"), &manager).unwrap();
        manager.install_occupancy_gate(gate).unwrap();
        let id = add_fixture_account(
            &manager,
            "Synthetic maintenance fixture",
            "maintenance@fixture.invalid",
            "synthetic-maintenance-account",
            &"c".repeat(32),
        );
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
            account_runtime,
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
    assert_eq!(
        f.service.preferences().unwrap().quota_refresh_frequency,
        QuotaRefreshFrequency::Automatic
    );
    let first = f.service.evaluate_once().unwrap();
    assert_eq!(first.phase, "idle");
    assert_eq!(first.entries[0].kind, "quota_refresh");
    assert_eq!(first.entries[0].phase, "succeeded");
    assert_eq!(f.account_runtime.verify_calls.load(Ordering::Acquire), 1);
    assert_eq!(f.runtime.calls.load(Ordering::Acquire), 0);
    assert!(f.service.path.exists());
    let stored: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&f.service.path).unwrap()).unwrap();
    assert_eq!(stored["settings"]["quotaRefreshFrequency"], "automatic");
    f.service.evaluate_once().unwrap();
    assert_eq!(f.account_runtime.verify_calls.load(Ordering::Acquire), 1);
    f.service.set_warmup_selection(true, false).unwrap();
    let status = f.service.evaluate_once().unwrap();
    assert_eq!(status.phase, "idle");
    assert!(status
        .entries
        .iter()
        .any(|entry| entry.kind == "warmup" && entry.phase == "succeeded"));
    f.service.evaluate_once().unwrap();
    assert_eq!(f.runtime.calls.load(Ordering::Acquire), 1);
    assert_eq!(f.account_runtime.verify_calls.load(Ordering::Acquire), 1);
    assert!(!f.service.has_inflight_operation());
    f.untouched();
}

#[test]
fn quota_refresh_frequency_persists_and_a_failed_save_keeps_the_confirmed_value() {
    let f = Fixture::new(false, false);
    let saved = f
        .service
        .set_quota_refresh_frequency(QuotaRefreshFrequency::ThirtyMinutes)
        .unwrap();
    assert_eq!(
        saved.quota_refresh_frequency,
        QuotaRefreshFrequency::ThirtyMinutes
    );
    let reloaded = AccountMaintenanceService::with_runtime(
        f.service.path.clone(),
        f.service.manager.clone(),
        f.runtime.clone(),
    )
    .unwrap();
    assert_eq!(
        reloaded.preferences().unwrap().quota_refresh_frequency,
        QuotaRefreshFrequency::ThirtyMinutes
    );

    std::fs::remove_file(&f.service.path).unwrap();
    std::fs::create_dir(&f.service.path).unwrap();
    assert!(matches!(
        reloaded.set_quota_refresh_frequency(QuotaRefreshFrequency::OneMinute),
        Err(Failure::SaveFailed)
    ));
    assert_eq!(
        reloaded.preferences().unwrap().quota_refresh_frequency,
        QuotaRefreshFrequency::ThirtyMinutes
    );
}

#[test]
fn existing_maintenance_settings_without_frequency_default_to_automatic() {
    let stored: Stored = serde_json::from_value(json!({
        "version": 1,
        "settings": {
            "fiveHourWarmup": false,
            "sevenDayWarmup": false,
            "resetLeadMinutes": 30,
            "resetAuthorizations": {}
        },
        "entries": []
    }))
    .unwrap();
    stored.validate().unwrap();
    assert_eq!(
        stored.settings.quota_refresh_frequency,
        QuotaRefreshFrequency::Automatic
    );
}

#[test]
fn automatic_refresh_uses_foreground_and_background_intervals_without_early_reads() {
    let f = Fixture::new(false, false);
    f.service.evaluate_once().unwrap();
    assert_eq!(f.account_runtime.verify_calls.load(Ordering::Acquire), 1);

    {
        let mut state = f.service.state.lock().unwrap();
        let entry = state
            .saved
            .entries
            .iter_mut()
            .find(|entry| entry.kind == "quota_refresh")
            .unwrap();
        entry.last_attempt_at_ms = Some(now() - 240_000);
        save(&f.service.path, &state.saved).unwrap();
    }
    f.service.set_foreground(false);
    f.service.evaluate_once().unwrap();
    assert_eq!(f.account_runtime.verify_calls.load(Ordering::Acquire), 1);

    f.service.set_foreground(true);
    f.service.evaluate_once().unwrap();
    assert_eq!(f.account_runtime.verify_calls.load(Ordering::Acquire), 2);
}

#[test]
fn failed_quota_refresh_keeps_the_last_success_and_cached_quota_snapshot() {
    let f = Fixture::new(false, false);
    let initial = f.service.evaluate_once().unwrap();
    let last_success = initial
        .entries
        .iter()
        .find(|entry| entry.kind == "quota_refresh")
        .unwrap()
        .last_succeeded_at_ms;
    let before = {
        let store = f.service.manager.store().unwrap();
        let credential = store
            .vault
            .account(&f.profile_id)
            .unwrap()
            .credential
            .as_ref()
            .unwrap();
        (credential.observed_at, credential.quota.clone())
    };
    {
        let mut state = f.service.state.lock().unwrap();
        let entry = state
            .saved
            .entries
            .iter_mut()
            .find(|entry| entry.kind == "quota_refresh")
            .unwrap();
        entry.last_attempt_at_ms = Some(now() - 240_000);
        save(&f.service.path, &state.saved).unwrap();
    }
    f.account_runtime.fail_next.store(true, Ordering::Release);

    let failed = f.service.evaluate_once().unwrap();
    let entry = failed
        .entries
        .iter()
        .find(|entry| entry.kind == "quota_refresh")
        .unwrap();
    assert_eq!(entry.phase, "blocked");
    assert_eq!(entry.last_succeeded_at_ms, last_success);
    let after = {
        let store = f.service.manager.store().unwrap();
        let credential = store
            .vault
            .account(&f.profile_id)
            .unwrap()
            .credential
            .as_ref()
            .unwrap();
        (credential.observed_at, credential.quota.clone())
    };
    assert_eq!(after, before);
    assert_eq!(f.account_runtime.verify_calls.load(Ordering::Acquire), 2);
}

#[test]
fn cancellation_after_the_durable_attempt_record_prevents_the_quota_read_launch() {
    let f = Fixture::new(false, false);
    let weak = Arc::downgrade(&f.service);
    *f.service.before_quota_refresh.lock().unwrap() = Some(Arc::new(move || {
        weak.upgrade().unwrap().cancel().unwrap();
    }));

    assert!(matches!(f.service.evaluate_once(), Err(Failure::Cancelled)));
    assert_eq!(f.account_runtime.verify_calls.load(Ordering::Acquire), 0);
    assert!(!f.service.has_inflight_operation());
    let status = f.service.status().unwrap();
    let entry = status
        .entries
        .iter()
        .find(|entry| entry.kind == "quota_refresh")
        .unwrap();
    assert_eq!(entry.phase, "cancelled");
    assert_eq!(entry.last_succeeded_at_ms, None);
    f.untouched();
}

#[test]
fn cancellation_during_quota_read_allows_one_owned_read_but_launches_no_next_account() {
    let f = Fixture::new(false, false);
    add_fixture_account(
        &f.service.manager,
        "Synthetic second maintenance fixture",
        "maintenance2@fixture.invalid",
        "synthetic-maintenance-account-2",
        &"d".repeat(32),
    );
    f.account_runtime.pause.store(true, Ordering::Release);
    f.account_runtime.release.store(false, Ordering::Release);
    let service = f.service.clone();
    let worker = std::thread::spawn(move || service.evaluate_once());
    wait_until(|| f.account_runtime.entered.load(Ordering::Acquire));

    f.service.cancel().unwrap();
    f.account_runtime.release.store(true, Ordering::Release);
    assert!(matches!(worker.join().unwrap(), Err(Failure::Cancelled)));
    assert_eq!(f.account_runtime.verify_calls.load(Ordering::Acquire), 1);
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
    assert_eq!(
        status
            .entries
            .iter()
            .find(|entry| entry.kind == "warmup")
            .unwrap()
            .phase,
        "cancelled"
    );
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
    assert_eq!(
        status
            .entries
            .iter()
            .find(|entry| entry.kind == "warmup")
            .unwrap()
            .phase,
        "uncertain"
    );
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
    f.service.evaluate_once().unwrap();
    f.service.set_warmup_selection(true, false).unwrap();
    let staging = f.service.manager.paths.staging();
    std::fs::remove_dir(&staging).unwrap();
    storage::atomic_write(&staging, b"synthetic staging failure").unwrap();
    let status = f.service.evaluate_once().unwrap();
    assert_eq!(status.phase, "idle");
    assert!(status.running_profile_id.is_none());
    assert!(status.issue_code.is_some());
    assert_eq!(
        status
            .entries
            .iter()
            .find(|entry| entry.kind == "warmup")
            .unwrap()
            .phase,
        "running"
    );
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
    assert_eq!(f.service.evaluate_once().unwrap().phase, "idle");
    f.runtime.reset_allowed.store(true, Ordering::Release);
    f.service.authorize_reset(&f.profile_id, true).unwrap();
    let status = f.service.evaluate_once().unwrap();
    let reset = status
        .entries
        .iter()
        .find(|entry| entry.kind == "reset_credit")
        .unwrap();
    assert_eq!(reset.phase, "succeeded");
    let before = serde_json::to_value(&status.entries).unwrap();
    let repeated = f.service.evaluate_once().unwrap();
    assert_eq!(serde_json::to_value(&repeated.entries).unwrap(), before);
    assert_eq!(f.runtime.reset_calls.load(Ordering::Acquire), 1);
    f.service.authorize_reset(&f.profile_id, false).unwrap();
    assert_eq!(f.service.evaluate_once().unwrap().phase, "idle");
    assert_eq!(f.runtime.reset_calls.load(Ordering::Acquire), 1);
    f.untouched();
}
