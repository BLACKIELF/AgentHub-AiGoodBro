use super::*;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

const REQUEST: &str = "11111111-1111-4111-8111-111111111111";
const REQUEST2: &str = "22222222-2222-4222-8222-222222222222";
const KEY: &str = "fixture_control_key_which_is_not_a_product_key";
pub(super) struct FixtureGate {
    pub(super) evidence: Mutex<BTreeMap<String, AccountEvidence>>,
    leases: Mutex<BTreeMap<String, LeaseTuple>>,
    denied: Mutex<BTreeSet<String>>,
    fail_retirement: AtomicBool,
    writer: Mutex<Option<DesktopWriterClaim>>,
    pub(super) writer_requires_proof: AtomicBool,
}
impl FixtureGate {
    pub(super) fn new() -> Arc<Self> {
        Arc::new(Self {
            evidence: Mutex::new(
                [
                    ("A".into(), evidence("A", "plus", 10.0)),
                    ("B".into(), evidence("B", "plus", 20.0)),
                    ("P".into(), evidence("P", "pro", 0.0)),
                ]
                .into(),
            ),
            leases: Mutex::default(),
            denied: Mutex::default(),
            fail_retirement: AtomicBool::new(false),
            writer: Mutex::default(),
            writer_requires_proof: AtomicBool::new(false),
        })
    }
}
impl ProxyAccountGate for FixtureGate {
    fn registration(&self, id: &str) -> Result<AccountRegistration, ProxyFailure> {
        let e = self
            .evidence
            .lock()
            .unwrap()
            .get(id)
            .cloned()
            .ok_or(ProxyFailure::Identity)?;
        Ok(AccountRegistration {
            profile_id: e.profile_id,
            identity_hash: e.identity_hash,
        })
    }
    fn claim_desktop_writer(
        &self,
        profile: &str,
        run: &str,
        identity: &str,
        generation: &str,
    ) -> Result<DesktopWriterClaim, ProxyFailure> {
        let mut writer = self.writer.lock().unwrap();
        if writer.is_some() {
            return Err(ProxyFailure::AccountBusy);
        }
        let claim = DesktopWriterClaim {
            writer_id: "synthetic-writer".into(),
            profile_id: profile.into(),
            proxy_run_id: run.into(),
            identity_hash: identity.into(),
            initial_generation: generation.into(),
        };
        *writer = Some(claim.clone());
        Ok(claim)
    }
    fn recheck_desktop_writer(&self, claim: &DesktopWriterClaim) -> Result<(), ProxyFailure> {
        let e = self.evidence(&claim.profile_id)?;
        if self
            .writer
            .lock()
            .unwrap()
            .as_ref()
            .is_some_and(|w| w.writer_id == claim.writer_id)
            && e.identity_hash == claim.identity_hash
            && e.token_generation == claim.initial_generation
        {
            Ok(())
        } else {
            Err(ProxyFailure::Identity)
        }
    }
    fn rebind_desktop_writer(
        &self,
        old: &DesktopWriterClaim,
        run: &str,
    ) -> Result<DesktopWriterClaim, ProxyFailure> {
        let mut writer = self.writer.lock().unwrap();
        let claim = writer
            .as_mut()
            .filter(|w| w.writer_id == old.writer_id)
            .ok_or(ProxyFailure::Identity)?;
        claim.proxy_run_id = run.to_owned();
        Ok(claim.clone())
    }
    fn accept_desktop_evidence(
        &self,
        claim: &DesktopWriterClaim,
        _: DesktopQuotaEvidence,
    ) -> Result<(), ProxyFailure> {
        self.recheck_desktop_writer(claim)
    }
    fn confirm_desktop_exit(&self, _: &DesktopWriterClaim) -> Result<(), ProxyFailure> {
        Ok(())
    }
    fn release_desktop_writer(&self, claim: &DesktopWriterClaim) -> Result<(), ProxyFailure> {
        let mut writer = self.writer.lock().unwrap();
        if writer
            .as_ref()
            .is_some_and(|w| w.writer_id == claim.writer_id)
        {
            *writer = None;
            Ok(())
        } else {
            Err(ProxyFailure::Identity)
        }
    }
    fn managed_profile_ids(&self) -> Result<Vec<String>, ProxyFailure> {
        Ok(self.evidence.lock().unwrap().keys().cloned().collect())
    }
    fn evidence(&self, id: &str) -> Result<AccountEvidence, ProxyFailure> {
        if self.writer_requires_proof.load(Ordering::Acquire)
            && self
                .writer
                .lock()
                .unwrap()
                .as_ref()
                .is_some_and(|w| w.profile_id == id)
        {
            return Err(ProxyFailure::QuotaUnknown);
        }
        self.evidence
            .lock()
            .unwrap()
            .get(id)
            .cloned()
            .ok_or(ProxyFailure::Identity)
    }
    fn reserve(&self, r: &AdmissionRequest) -> Result<CredentialLease, ProxyFailure> {
        if self
            .denied
            .lock()
            .unwrap()
            .contains(&format!("{}:{}:{}", r.run_id, r.request_id, r.profile_id))
        {
            return Err(ProxyFailure::AcquireAbandoned);
        }
        let e = self.evidence(&r.profile_id)?;
        if e.identity_hash != r.expected_identity_hash
            || e.token_generation != r.expected_generation
        {
            return Err(ProxyFailure::Identity);
        }
        let mut leases = self.leases.lock().unwrap();
        if leases.values().any(|t| t.profile_id == r.profile_id) {
            return Err(ProxyFailure::AccountBusy);
        }
        let tuple = LeaseTuple {
            run_id: r.run_id.clone(),
            request_id: r.request_id.clone(),
            profile_id: r.profile_id.clone(),
            lease_id: format!("lease-{}", r.profile_id),
        };
        leases.insert(tuple.lease_id.clone(), tuple.clone());
        Ok(CredentialLease {
            tuple,
            access_token: "synthetic-test-token".into(),
            account_id: "synthetic-account".into(),
            expires_at: (host::unix_now() + 3600.0) as i64,
            identity_hash: e.identity_hash,
            token_generation: e.token_generation,
        })
    }
    fn resolve(&self, t: &LeaseTuple) -> Result<AdmissionResolution, ProxyFailure> {
        self.denied
            .lock()
            .unwrap()
            .insert(format!("{}:{}:{}", t.run_id, t.request_id, t.profile_id));
        let mut leases = self.leases.lock().unwrap();
        if let Some(id) = leases
            .iter()
            .find(|(_, l)| {
                l.run_id == t.run_id && l.request_id == t.request_id && l.profile_id == t.profile_id
            })
            .map(|(id, _)| id.clone())
        {
            leases.remove(&id);
            Ok(AdmissionResolution::RolledBack)
        } else {
            Ok(AdmissionResolution::NotReserved)
        }
    }
    fn heartbeat(&self, t: &LeaseTuple) -> Result<(), ProxyFailure> {
        if self.leases.lock().unwrap().get(&t.lease_id) == Some(t) {
            Ok(())
        } else {
            Err(ProxyFailure::Identity)
        }
    }
    fn release(&self, t: &LeaseTuple) -> Result<(), ProxyFailure> {
        let mut l = self.leases.lock().unwrap();
        if l.get(&t.lease_id) != Some(t) {
            return Err(ProxyFailure::Identity);
        }
        l.remove(&t.lease_id);
        Ok(())
    }
    fn retire_run(&self, run: &str, confirmed: bool) -> Result<(), ProxyFailure> {
        if !confirmed || self.fail_retirement.load(Ordering::Acquire) {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
        self.leases.lock().unwrap().retain(|_, t| t.run_id != run);
        Ok(())
    }
}
fn evidence(id: &str, plan: &str, used: f64) -> AccountEvidence {
    let now = host::unix_now();
    let hash = "a".repeat(64);
    AccountEvidence {
        profile_id: id.into(),
        identity_hash: hash.clone(),
        token_generation: "fixture-generation-1".into(),
        identity_verified: true,
        is_system_home: false,
        is_desktop: false,
        plan: Some(plan.into()),
        quota: Some(QuotaEvidence {
            observed_at: now,
            read_succeeded: true,
            last_failure_at: None,
            identity_hash: hash,
            five_hour: Some(QuotaWindowEvidence {
                used_percent: used,
                resets_at: now + 3600.0,
            }),
            seven_day: Some(QuotaWindowEvidence {
                used_percent: 0.0,
                resets_at: now + 86400.0,
            }),
            monthly: None,
            credit_balance: Some("2000.0001".into()),
            credit_balance_unlimited: Some(false),
        }),
    }
}
pub(super) fn preferences() -> ProxyPreferences {
    let mut p = ProxyPreferences::default();
    p.is_enabled = true;
    p.order = vec!["A".into(), "P".into(), "B".into()];
    p.enabled_ids = ["A".into(), "B".into(), "P".into()].into();
    p.known_ids = p.enabled_ids.clone();
    p
}
fn fixture() -> (ProxyHost, Arc<FixtureGate>) {
    let gate = FixtureGate::new();
    let mut h = ProxyHost::new(preferences(), gate.clone()).unwrap();
    h.begin("fixture-run".into(), KEY.into()).unwrap();
    (h, gate)
}
fn request(command: &str, id: &str, request: &str) -> BridgeRequest {
    BridgeRequest {
        schema_version: 1,
        run_id: "fixture-run".into(),
        key: KEY.into(),
        command: command.into(),
        request_id: request.into(),
        profile_id: id.into(),
        lease_id: None,
    }
}

#[test]
fn current_order_freezes_and_pro_default_is_movable() {
    let (mut h, _) = fixture();
    let first = h.handle(request("order", "A", REQUEST));
    assert_eq!(first.order.unwrap(), vec!["A", "B", "P"]);
    assert_eq!(first.deferred_ids.unwrap(), vec!["P"]);
    let mut p = h.preferences();
    p.last_overrides.insert("P".into(), false);
    p.priority_ids.insert("P".into());
    h.update_preferences(p).unwrap();
    assert_eq!(
        h.handle(request("order", "A", REQUEST)).order.unwrap(),
        vec!["A", "B", "P"]
    );
    assert_eq!(
        h.handle(request("order", "A", REQUEST2)).order.unwrap(),
        vec!["P", "A", "B"]
    );
}
#[test]
fn removal_and_reenable_never_revives_old_admission() {
    let (mut h, g) = fixture();
    h.handle(request("order", "A", REQUEST));
    let mut p = h.preferences();
    p.enabled_ids.remove("A");
    h.update_preferences(p.clone()).unwrap();
    assert_eq!(
        h.handle(request("acquire", "A", REQUEST)).error,
        Some("not_participating")
    );
    p.enabled_ids.insert("A".into());
    h.update_preferences(p).unwrap();
    assert_eq!(
        h.handle(request("acquire", "A", REQUEST)).error,
        Some("not_participating")
    );
    assert!(g.leases.lock().unwrap().is_empty());
    h.handle(request("order", "A", REQUEST2));
    assert!(h.handle(request("acquire", "A", REQUEST2)).ok);
}
#[test]
fn admitted_lease_finishes_after_removal_and_tuple_is_exact() {
    let (mut h, g) = fixture();
    h.handle(request("order", "A", REQUEST));
    let reply = h.handle(request("acquire", "A", REQUEST));
    assert!(reply.ok);
    let mut p = h.preferences();
    p.enabled_ids.remove("A");
    h.update_preferences(p).unwrap();
    let mut heartbeat = request("heartbeat", "A", REQUEST);
    heartbeat.lease_id = reply.lease_id.clone();
    assert!(h.handle(heartbeat).ok);
    let mut wrong = request("release", "B", REQUEST);
    wrong.lease_id = reply.lease_id.clone();
    assert_eq!(h.handle(wrong).error, Some("identity"));
    let mut release = request("release", "A", REQUEST);
    release.lease_id = reply.lease_id;
    assert!(h.handle(release).ok);
    assert!(g.leases.lock().unwrap().is_empty());
}
#[test]
fn unknown_quota_and_wrong_identity_never_reserve() {
    let (mut h, g) = fixture();
    h.handle(request("order", "A", REQUEST));
    g.evidence.lock().unwrap().get_mut("A").unwrap().quota = None;
    assert_eq!(
        h.handle(request("acquire", "A", REQUEST)).error,
        Some("quota_unknown")
    );
    g.evidence
        .lock()
        .unwrap()
        .get_mut("A")
        .unwrap()
        .identity_hash = "b".repeat(64);
    assert_eq!(
        h.handle(request("acquire", "A", REQUEST)).error,
        Some("identity")
    );
    assert!(g.leases.lock().unwrap().is_empty());
}
#[test]
fn used_percentage_and_official_pro_semantics() {
    let mut e = evidence("A", "plus", 50.0);
    let mut p = AccountPolicy::default();
    p.five_hour_used_limit = 50.0;
    let now = host::unix_now();
    assert_eq!(
        quota_admission(&e, &p, now, None, false),
        Err(ProxyFailure::UsageLimit)
    );
    p.five_hour_used_limit = 51.0;
    assert_eq!(quota_admission(&e, &p, now, None, false), Ok(()));
    e.plan = Some("pro".into());
    e.quota.as_mut().unwrap().five_hour = None;
    assert_eq!(quota_admission(&e, &p, now, None, false), Ok(()));
    e.quota.as_mut().unwrap().seven_day = None;
    assert_eq!(
        quota_admission(&e, &p, now, None, false),
        Err(ProxyFailure::QuotaUnknown)
    );
}
#[test]
fn paid_floors_are_exact_and_require_whole_pool_exhaustion() {
    let mut e = evidence("A", "plus", 100.0);
    let p = AccountPolicy::default();
    let now = host::unix_now();
    assert_eq!(quota_admission(&e, &p, now, Some(2000), true), Ok(()));
    e.quota.as_mut().unwrap().credit_balance = Some("2000.0".into());
    assert_eq!(
        quota_admission(&e, &p, now, Some(2000), true),
        Err(ProxyFailure::Quota)
    );
    let (mut h, g) = fixture();
    let mut prefs = h.preferences();
    prefs.credit_fallback = true;
    h.update_preferences(prefs).unwrap();
    h.handle(request("order", "A", REQUEST));
    g.evidence
        .lock()
        .unwrap()
        .get_mut("A")
        .unwrap()
        .quota
        .as_mut()
        .unwrap()
        .five_hour
        .as_mut()
        .unwrap()
        .used_percent = 100.0;
    assert_eq!(
        h.handle(request("acquire_credit_primary", "A", REQUEST))
            .error,
        Some("subscription_pending")
    );
    assert!(g.leases.lock().unwrap().is_empty());
}
#[test]
fn unconfirmed_exit_retains_reservations_and_resolution_tombstones() {
    let (mut h, g) = fixture();
    h.handle(request("order", "A", REQUEST));
    assert!(h.handle(request("acquire", "A", REQUEST)).ok);
    assert_eq!(h.retire(false), Err(ProxyFailure::CleanupUnconfirmed));
    assert_eq!(g.leases.lock().unwrap().len(), 1);
    assert!(h.handle(request("acquire_resolve", "A", REQUEST)).ok);
    assert!(g.leases.lock().unwrap().is_empty());
    assert!(h.retire(true).is_ok());
}
#[test]
fn control_protocol_rejects_wrong_key_and_emits_exact_field_names() {
    let (mut h, _) = fixture();
    let mut bad = request("order", "A", REQUEST);
    bad.key = "wrong".into();
    assert_eq!(h.handle(bad).error, Some("identity"));
    let request:BridgeRequest=serde_json::from_value(serde_json::json!({"schemaVersion":1,"runID":"fixture-run","key":KEY,"command":"order","requestID":REQUEST,"profileID":"A"})).unwrap();
    let json = serde_json::to_value(h.handle(request)).unwrap();
    assert!(json.get("deferredIDs").is_some());
    assert!(json.get("lastResortIDs").is_some());
    assert!(json.get("accessToken").is_none());
}

#[test]
fn batch_plus_limit_is_atomic_and_leaves_pro_unchanged() {
    let (mut h, g) = fixture();
    let p = h.plus_policy(37.5).unwrap();
    assert_eq!(p.policy("A").five_hour_used_limit, 37.5);
    assert_eq!(p.policy("B").five_hour_used_limit, 37.5);
    assert_eq!(p.policy("P").five_hour_used_limit, 100.0);
    h.update_preferences(p.clone()).unwrap();
    g.evidence
        .lock()
        .unwrap()
        .get_mut("B")
        .unwrap()
        .identity_verified = false;
    assert!(h.plus_policy(50.0).is_err());
    assert_eq!(h.preferences(), p);
}

#[test]
fn plus_batch_cannot_be_shrunk_by_ui_known_ids_or_miss_new_enabled_plus() {
    let (mut h, _) = fixture();
    let mut p = h.preferences();
    p.known_ids.remove("B");
    h.update_preferences(p).unwrap();
    let batch = h.plus_policy(42.0).unwrap();
    assert_eq!(batch.policy("A").five_hour_used_limit, 42.0);
    assert_eq!(batch.policy("B").five_hour_used_limit, 42.0);
    assert!(batch.known_ids.contains("B"));
    let mut spoof = batch.clone();
    spoof.known_ids.clear();
    spoof.known_ids.insert("invented".into());
    let canonical = h.normalize_preferences(spoof).unwrap();
    assert_eq!(
        canonical.known_ids,
        ["A".into(), "B".into(), "P".into()].into()
    );
    let mut unknown = canonical;
    unknown.enabled_ids.insert("invented".into());
    assert_eq!(
        h.normalize_preferences(unknown).unwrap_err(),
        ProxyFailure::Identity
    );
}
pub(super) struct FixtureSecrets(pub(super) Mutex<Option<String>>);
impl ProxySecretStore for FixtureSecrets {
    fn load_client_key(&self) -> Result<Option<String>, ProxyFailure> {
        Ok(self.0.lock().unwrap().clone())
    }
    fn save_client_key(&self, k: &str) -> Result<(), ProxyFailure> {
        *self.0.lock().unwrap() = Some(k.into());
        Ok(())
    }
}
#[test]
fn saved_policy_roundtrips_and_failed_save_leaves_previous_rule() {
    let dir = tempfile::tempdir().unwrap();
    let service = LocalProxyService::new(
        dir.path().join("proxy.json"),
        dir.path().join("state"),
        dir.path().join("helper"),
        vec!["fixture-model".into()],
        FixtureGate::new(),
        Arc::new(FixtureSecrets(Mutex::default())),
    )
    .unwrap();
    let mut p = preferences();
    p.account_policies.insert(
        "A".into(),
        AccountPolicy {
            five_hour_used_limit: 37.5,
            ..Default::default()
        },
    );
    service.save_preferences(p.clone()).unwrap();
    let loaded: ProxyPreferences =
        serde_json::from_slice(&std::fs::read(dir.path().join("proxy.json")).unwrap()).unwrap();
    assert_eq!(p, loaded);
    let mut invalid = p.clone();
    invalid
        .account_policies
        .get_mut("A")
        .unwrap()
        .five_hour_used_limit = f64::NAN;
    assert!(service.save_preferences(invalid).is_err());
    assert_eq!(service.preferences().unwrap(), p);
}

#[test]
#[ignore = "requires the freshly built helper in AIGOODBRO_TEST_PROXY_HELPER; no real credentials or inference"]
fn actual_helper_authentication_and_owned_eof_shutdown() {
    use std::io::{Read, Write};
    use std::net::TcpStream;
    let helper = std::env::var_os("AIGOODBRO_TEST_PROXY_HELPER")
        .expect("set the isolated staged helper path");
    let dir = tempfile::tempdir().unwrap();
    let gate = FixtureGate::new();
    let service = LocalProxyService::new(
        dir.path().join("proxy.json"),
        dir.path().join("state"),
        helper.into(),
        vec!["fixture-model".into()],
        gate.clone(),
        Arc::new(FixtureSecrets(Mutex::default())),
    )
    .unwrap();
    let mut p = preferences();
    p.listen_port = 0;
    service.save_preferences(p).unwrap();
    let state = service.start().unwrap();
    assert_eq!(state.phase, ProxyPhase::Running);
    let connection = service.connection().unwrap();
    for (key, expected) in [("incorrect", 401), (connection.client_key.as_str(), 200)] {
        let mut socket =
            TcpStream::connect((std::net::Ipv4Addr::LOCALHOST, state.port.unwrap())).unwrap();
        socket
            .set_read_timeout(Some(std::time::Duration::from_secs(3)))
            .unwrap();
        write!(socket,"GET /v1/models HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {key}\r\nConnection: close\r\n\r\n").unwrap();
        let mut response = String::new();
        socket.read_to_string(&mut response).unwrap();
        assert!(response.starts_with(&format!("HTTP/1.1 {expected}")));
    }
    assert!(gate.leases.lock().unwrap().is_empty());
    assert_eq!(service.stop().unwrap().phase, ProxyPhase::Stopped);
    assert!(TcpStream::connect((std::net::Ipv4Addr::LOCALHOST, state.port.unwrap())).is_err());
}

#[test]
#[ignore = "requires the freshly built helper in AIGOODBRO_TEST_PROXY_HELPER; no real credentials or inference"]
fn actual_helper_recovery_is_optin_cancellable_and_user_stop_is_final() {
    use std::thread;
    use std::time::{Duration, Instant};
    let helper = std::env::var_os("AIGOODBRO_TEST_PROXY_HELPER").expect("set isolated helper");
    let dir = tempfile::tempdir().unwrap();
    let service = Arc::new(
        LocalProxyService::new(
            dir.path().join("proxy.json"),
            dir.path().join("state"),
            helper.into(),
            vec!["fixture-model".into()],
            FixtureGate::new(),
            Arc::new(FixtureSecrets(Mutex::default())),
        )
        .unwrap(),
    );
    let mut p = preferences();
    p.listen_port = 0;
    p.automatic_recovery_enabled = true;
    service.save_preferences(p).unwrap();
    let monitor = service.start_recovery_monitor().unwrap();
    assert!(service.start_recovery_monitor().is_err());
    thread::sleep(Duration::from_millis(200));
    assert_eq!(service.status().unwrap().phase, ProxyPhase::Stopped);
    assert!(service.owned_fixture_pid().is_none());
    service.start().unwrap();
    let first = service.owned_fixture_pid().unwrap();
    service.terminate_owned_fixture_child();
    let until = Instant::now() + Duration::from_secs(5);
    let mut recovered = false;
    while Instant::now() < until {
        if service.status().unwrap().phase == ProxyPhase::Running
            && service.owned_fixture_pid().is_some_and(|pid| pid != first)
        {
            recovered = true;
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }
    assert!(recovered, "owned confirmed exit did not recover");
    service.stop().unwrap();
    thread::sleep(Duration::from_millis(300));
    assert_eq!(service.status().unwrap().phase, ProxyPhase::Stopped);
    assert!(service.owned_fixture_pid().is_none());
    service.start().unwrap();
    monitor.join();
    service.terminate_owned_fixture_child();
    thread::sleep(Duration::from_millis(300));
    let _ = service.status().unwrap();
    assert!(service.owned_fixture_pid().is_none());
    service.stop().unwrap();
}

#[test]
#[ignore = "requires the freshly built helper in AIGOODBRO_TEST_PROXY_HELPER; no real credentials or inference"]
fn actual_helper_stop_revokes_start_blocked_in_secret_store() {
    use std::sync::{mpsc, Condvar};
    use std::thread;
    use std::time::{Duration, Instant};
    struct BlockingSecrets {
        entered: Mutex<Option<mpsc::Sender<()>>>,
        released: Mutex<bool>,
        wake: Condvar,
    }
    impl ProxySecretStore for BlockingSecrets {
        fn load_client_key(&self) -> Result<Option<String>, ProxyFailure> {
            if let Some(entered) = self.entered.lock().unwrap().take() {
                entered.send(()).unwrap();
            }
            let mut released = self.released.lock().unwrap();
            while !*released {
                released = self.wake.wait(released).unwrap();
            }
            Ok(None)
        }
        fn save_client_key(&self, _: &str) -> Result<(), ProxyFailure> {
            Ok(())
        }
    }
    let helper = std::env::var_os("AIGOODBRO_TEST_PROXY_HELPER").expect("set isolated helper");
    let dir = tempfile::tempdir().unwrap();
    let (tx, rx) = mpsc::channel();
    let secrets = Arc::new(BlockingSecrets {
        entered: Mutex::new(Some(tx)),
        released: Mutex::new(false),
        wake: Condvar::new(),
    });
    let service = Arc::new(
        LocalProxyService::new(
            dir.path().join("proxy.json"),
            dir.path().join("state"),
            helper.into(),
            vec!["fixture-model".into()],
            FixtureGate::new(),
            secrets.clone(),
        )
        .unwrap(),
    );
    let mut p = preferences();
    p.listen_port = 0;
    service.save_preferences(p).unwrap();
    let start_service = service.clone();
    let starter = thread::spawn(move || start_service.start());
    rx.recv_timeout(Duration::from_secs(2)).unwrap();
    let stop_service = service.clone();
    let stopper = thread::spawn(move || stop_service.stop());
    let deadline = Instant::now() + Duration::from_secs(1);
    while !service.fixture_user_stopped() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(1));
    }
    assert!(service.fixture_user_stopped());
    *secrets.released.lock().unwrap() = true;
    secrets.wake.notify_all();
    assert_eq!(starter.join().unwrap().unwrap_err(), ProxyFailure::Stopping);
    assert_eq!(stopper.join().unwrap().unwrap().phase, ProxyPhase::Stopped);
    assert!(service.owned_fixture_pid().is_none());
    assert_eq!(service.start().unwrap().phase, ProxyPhase::Running);
    service.stop().unwrap();
}

#[test]
#[ignore = "requires the freshly built helper in AIGOODBRO_TEST_PROXY_HELPER; no real credentials or inference"]
fn actual_helper_unconfirmed_retirement_blocks_recovery_and_new_start() {
    use std::thread;
    use std::time::{Duration, Instant};
    let helper = std::env::var_os("AIGOODBRO_TEST_PROXY_HELPER").expect("set isolated helper");
    let dir = tempfile::tempdir().unwrap();
    let gate = FixtureGate::new();
    let service = Arc::new(
        LocalProxyService::new(
            dir.path().join("proxy.json"),
            dir.path().join("state"),
            helper.into(),
            vec!["fixture-model".into()],
            gate.clone(),
            Arc::new(FixtureSecrets(Mutex::default())),
        )
        .unwrap(),
    );
    let mut p = preferences();
    p.listen_port = 0;
    p.automatic_recovery_enabled = true;
    service.save_preferences(p).unwrap();
    let monitor = service.start_recovery_monitor().unwrap();
    service.start().unwrap();
    gate.fail_retirement.store(true, Ordering::Release);
    service.terminate_owned_fixture_child();
    let deadline = Instant::now() + Duration::from_secs(2);
    while service.owned_fixture_pid().is_some() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(10));
        let _ = service.status();
    }
    thread::sleep(Duration::from_millis(300));
    assert_eq!(service.status().unwrap().phase, ProxyPhase::Failed);
    assert!(service.owned_fixture_pid().is_none());
    assert_eq!(
        service.start().unwrap_err(),
        ProxyFailure::CleanupUnconfirmed
    );
    gate.fail_retirement.store(false, Ordering::Release);
    service.stop().unwrap();
    monitor.join();
}

#[test]
fn request_membership_is_bounded_and_expired_requests_cannot_admit() {
    let (mut h, g) = fixture();
    let now = host::unix_now();
    for n in 0..1024 {
        let id = format!("{n:08x}-1111-4111-8111-111111111111");
        assert!(h.handle_at(request("order", "A", &id), now).ok);
    }
    assert_eq!(
        h.handle_at(request("order", "A", REQUEST2), now).error,
        Some("control_busy")
    );
    let old = "00000000-1111-4111-8111-111111111111";
    assert_eq!(
        h.handle_at(request("acquire", "A", old), now + 16.0 * 60.0)
            .error,
        Some("identity")
    );
    assert!(
        h.handle_at(request("order", "A", REQUEST2), now + 16.0 * 60.0)
            .ok
    );
    assert!(g.leases.lock().unwrap().is_empty());
}

#[test]
#[ignore = "requires the freshly built helper in AIGOODBRO_TEST_PROXY_HELPER; no real credentials or inference"]
fn actual_helper_unknown_lease_event_stops_only_owned_child_before_retirement() {
    let helper = std::env::var_os("AIGOODBRO_TEST_PROXY_HELPER").expect("set isolated helper");
    let dir = tempfile::tempdir().unwrap();
    let gate = FixtureGate::new();
    let service = LocalProxyService::new(
        dir.path().join("proxy.json"),
        dir.path().join("state"),
        helper.into(),
        vec!["fixture-model".into()],
        gate.clone(),
        Arc::new(FixtureSecrets(Mutex::default())),
    )
    .unwrap();
    let mut p = preferences();
    p.listen_port = 0;
    service.save_preferences(p).unwrap();
    let running = service.start().unwrap();
    service.inject_fixture_lease_failure();
    let failed = service.status().unwrap();
    assert_eq!(failed.phase, ProxyPhase::Failed);
    assert_eq!(failed.issue.as_deref(), Some("lease_acquire_unknown"));
    assert!(service.owned_fixture_pid().is_none());
    assert!(
        std::net::TcpStream::connect((std::net::Ipv4Addr::LOCALHOST, running.port.unwrap()))
            .is_err()
    );
    assert!(gate.leases.lock().unwrap().is_empty());
    service.stop().unwrap();
}
