use super::*;
use crate::accounts::{
    AccountIdentity, AccountLoginSpawner, AccountRuntime, LoginAuthorization, VerifiedCredential,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde_json::json;

struct Protector;
impl SecretProtector for Protector {
    fn seal(&self, context: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
        Ok([context.as_bytes(), &[0], bytes].concat())
    }
    fn unseal(&self, context: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
        let prefix = [context.as_bytes(), &[0]].concat();
        bytes
            .strip_prefix(&prefix[..])
            .map(|b| b.to_vec())
            .ok_or_else(|| fail("fixture_context"))
    }
}
fn auth(name: &str) -> Vec<u8> {
    let jwt = format!("synthetic.{}.fixture", URL_SAFE_NO_PAD.encode(serde_json::to_vec(&json!({"email":format!("{name}@fixture.invalid"),"account_id":name,"exp":4102444800i64})).unwrap()));
    serde_json::to_vec(&json!({"tokens":{"access_token":jwt,"id_token":jwt,"refresh_token":"synthetic-not-real","account_id":name}})).unwrap()
}
fn verified(name: &str) -> VerifiedCredential {
    VerifiedCredential::from_official_read(auth(name), &json!({"account":{"type":"chatgpt","email":format!("{name}@fixture.invalid"),"planType":"plus"}}), json!({"rateLimits":{"planType":"plus","primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":4102444800i64}}})).unwrap()
}
#[derive(Default)]
struct Runtime {
    verifications: std::sync::atomic::AtomicUsize,
    fail_verify: AtomicBool,
}
impl AccountRuntime for Runtime {
    fn available(&self) -> bool {
        true
    }
    fn login(
        &self,
        _: &Path,
        _: &AtomicBool,
        _: &mut dyn FnMut(LoginAuthorization),
    ) -> AccountResult<VerifiedCredential> {
        Ok(verified("fixture"))
    }
    fn verify(&self, _: &Path, _: &AccountIdentity) -> AccountResult<VerifiedCredential> {
        self.verifications.fetch_add(1, Ordering::SeqCst);
        if self.fail_verify.load(Ordering::SeqCst) {
            return Err(fail("synthetic_verification_failed"));
        }
        Ok(verified("fixture"))
    }
    fn require_system_idle(&self) -> AccountResult<()> {
        panic!("registration must not switch Desktop")
    }
    fn validate_target_configuration(&self, home: &Path) -> AccountResult<()> {
        crate::accounts::validate_target_configuration(home)
    }
}
#[derive(Default)]
struct Spawner(Mutex<Option<Box<dyn FnOnce() + Send>>>);
impl AccountLoginSpawner for Spawner {
    fn spawn(&self, worker: Box<dyn FnOnce() + Send>) -> AccountResult<()> {
        *self.0.lock().unwrap() = Some(worker);
        Ok(())
    }
}
struct Lease;
impl CredentialWriteLease for Lease {
    fn recheck(&self) -> AccountResult<()> {
        Ok(())
    }
}
#[derive(Default)]
struct Gate(AtomicBool);
impl AccountOccupancyGate for Gate {
    fn acquire_switch_maintenance(
        &self,
        _: &str,
        _: &str,
    ) -> AccountResult<Box<dyn SwitchMaintenanceLease>> {
        panic!("no switching")
    }
    fn acquire_credential_write(
        &self,
        _: &str,
        purpose: CredentialWritePurpose,
    ) -> AccountResult<Box<dyn CredentialWriteLease>> {
        assert!(matches!(purpose, CredentialWritePurpose::Managed));
        if self.0.load(Ordering::SeqCst) {
            Err(fail("account_busy"))
        } else {
            Ok(Box::new(Lease))
        }
    }
}
struct Fixture {
    _temp: tempfile::TempDir,
    manager: Arc<AccountManager>,
    runtime: Arc<Runtime>,
    spawner: Arc<Spawner>,
    gate: Arc<Gate>,
    id: String,
}
impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let paths = AccountPaths::isolated(root.join("vault"), root.join("system")).unwrap();
        storage::secure_directory(&paths.system_home).unwrap();
        let spawner = Arc::new(Spawner::default());
        let gate = Arc::new(Gate::default());
        let runtime = Arc::new(Runtime::default());
        let manager = AccountManager::with_components_and_spawner(
            paths,
            Arc::new(Protector),
            runtime.clone(),
            Some(gate.clone()),
            spawner.clone(),
        )
        .unwrap();
        let id = manager
            .create_managed_account("Fixture".into(), "codex".into())
            .unwrap()
            .id;
        let f = Self {
            _temp: temp,
            manager,
            runtime,
            spawner,
            gate,
            id,
        };
        f.login();
        f
    }
    fn login(&self) {
        let attempt = self.manager.begin_account_login(self.id.clone()).unwrap();
        let worker = self.spawner.0.lock().unwrap().take().unwrap();
        worker();
        assert_eq!(
            self.manager
                .get_login_attempt(&attempt.attempt_id)
                .unwrap()
                .phase,
            "verified"
        );
    }
    fn reopen(&self) -> Arc<AccountManager> {
        AccountManager::with_components_and_spawner(
            self.manager.paths.clone(),
            Arc::new(Protector),
            self.runtime.clone(),
            Some(self.gate.clone()),
            self.spawner.clone(),
        )
        .unwrap()
    }
}
#[test]
fn first_verified_login_durable_intent_exact_home_and_completion_are_idempotent() {
    let f = Fixture::new();
    assert_eq!(
        f.manager.pending_registration_ids().unwrap(),
        vec![f.id.clone()]
    );
    assert!(f.manager.list_managed_accounts().unwrap()[0].registration_pending);
    let manager = f.reopen();
    let home = manager.paths.desktop(&f.id).unwrap();
    assert!(manager
        .register_pending_account(&f.id, |root, _, progress| {
            assert_eq!(root, home.canonicalize().unwrap());
            assert_eq!(progress.planned_profile_id()?, None);
            progress.plan_profile(7)?;
            Ok(())
        })
        .unwrap());
    assert_eq!(
        storage::read_optional(&home.join("auth.json"), 100000).unwrap(),
        Some(auth("fixture"))
    );
    assert!(!manager
        .register_pending_account(&f.id, |_, _, _| panic!("completed registration repeated"))
        .unwrap());
    assert!(manager.pending_registration_ids().unwrap().is_empty());
    assert!(!manager.paths.system_home.join("auth.json").exists());
}
#[test]
fn metadata_failure_keeps_account_and_exact_planned_id_across_restart() {
    let f = Fixture::new();
    let error = f
        .manager
        .register_pending_account(&f.id, |_, _, p| {
            p.plan_profile(7)?;
            Err(fail("synthetic_write_failed"))
        })
        .unwrap_err();
    assert_eq!(error.code, "synthetic_write_failed");
    let manager = f.reopen();
    assert_eq!(manager.list_managed_accounts().unwrap().len(), 1);
    manager
        .register_pending_account(&f.id, |_, _, p| {
            assert_eq!(p.planned_profile_id()?, Some(7));
            assert_eq!(
                p.plan_profile(8).unwrap_err().code,
                "registration_catalog_changed"
            );
            Ok(())
        })
        .unwrap();
    assert!(manager.pending_registration_ids().unwrap().is_empty());
}
#[test]
fn legacy_accounts_are_not_adopted_until_explicit_request_and_relogin_keeps_no_intent() {
    let f = Fixture::new();
    {
        let mut store = f.manager.store().unwrap();
        store.vault.pending_registrations.clear();
        store.save().unwrap();
    }
    f.login();
    assert!(f.manager.pending_registration_ids().unwrap().is_empty());
    assert!(!f
        .manager
        .register_pending_account(&f.id, |_, _, _| panic!("legacy adoption"))
        .unwrap());
    f.manager.request_account_registration(&f.id).unwrap();
    f.manager
        .register_pending_account(&f.id, |_, _, _| Ok(()))
        .unwrap();
}
#[test]
fn busy_or_stale_verification_keeps_pending_without_creating_home() {
    let f = Fixture::new();
    f.gate.0.store(true, Ordering::SeqCst);
    assert_eq!(
        f.manager
            .register_pending_account(&f.id, |_, _, _| panic!())
            .unwrap_err()
            .code,
        "account_busy"
    );
    assert!(!f.manager.paths.desktop(&f.id).unwrap().exists());
    f.gate.0.store(false, Ordering::SeqCst);
    {
        let mut s = f.manager.store().unwrap();
        s.vault
            .account_mut(&f.id)
            .unwrap()
            .credential
            .as_mut()
            .unwrap()
            .observed_at = 1;
        s.save().unwrap();
    }
    assert!(f
        .manager
        .register_pending_account(&f.id, |_, _, _| panic!())
        .is_err());
    assert_eq!(f.manager.pending_registration_ids().unwrap().len(), 1);
}
#[test]
fn identity_change_cannot_reuse_pending_registration() {
    let f = Fixture::new();
    {
        let mut s = f.manager.store().unwrap();
        s.vault.account_mut(&f.id).unwrap().credential =
            Some(verified("different").into_stored(crate::accounts::nonce().unwrap()));
        s.save().unwrap();
    }
    assert_eq!(
        f.manager
            .register_pending_account(&f.id, |_, _, _| panic!())
            .unwrap_err()
            .code,
        "identity_mismatch"
    );
    assert_eq!(
        f.manager
            .request_account_registration(&f.id)
            .unwrap_err()
            .code,
        "identity_mismatch"
    );
}
#[test]
fn existing_rotated_grant_and_writer_marker_are_never_overwritten() {
    let f = Fixture::new();
    let home = f.manager.paths.desktop(&f.id).unwrap();
    storage::secure_directory(home.parent().unwrap()).unwrap();
    storage::secure_directory(&home).unwrap();
    storage::atomic_write(&home.join("auth.json"), &auth("different")).unwrap();
    assert_eq!(
        f.manager
            .register_pending_account(&f.id, |_, _, _| panic!())
            .unwrap_err()
            .code,
        "desktop_auth_changed"
    );
    assert_eq!(
        std::fs::read(home.join("auth.json")).unwrap(),
        auth("different")
    );
    storage::atomic_write(&home.join("writer-claim.dpapi"), b"synthetic-owned-marker").unwrap();
    assert_eq!(
        f.manager
            .register_pending_account(&f.id, |_, _, _| panic!())
            .unwrap_err()
            .code,
        "desktop_writer_recovery_required"
    );
}
#[test]
fn post_callback_auth_change_cannot_clear_pending_or_report_registered() {
    let f = Fixture::new();
    assert_eq!(
        f.manager
            .register_pending_account(&f.id, |home, _, _| storage::atomic_write(
                &home.join("auth.json"),
                &auth("different")
            ))
            .unwrap_err()
            .code,
        "desktop_auth_changed"
    );
    assert_eq!(f.reopen().pending_registration_ids().unwrap().len(), 1);
}
#[test]
fn duplicate_identity_login_never_creates_a_second_registration_intent() {
    let f = Fixture::new();
    let second = f
        .manager
        .create_managed_account("Second".into(), "codex".into())
        .unwrap()
        .id;
    let attempt = f.manager.begin_account_login(second.clone()).unwrap();
    let worker = f.spawner.0.lock().unwrap().take().unwrap();
    worker();
    assert_eq!(
        f.manager
            .get_login_attempt(&attempt.attempt_id)
            .unwrap()
            .error_code,
        Some("account_already_exists")
    );
    assert_eq!(f.manager.pending_registration_ids().unwrap(), vec![f.id]);
    assert!(!f.manager.paths.desktop(&second).unwrap().exists());
}
#[test]
fn first_login_listener_can_finish_registration_after_all_login_fences_are_released() {
    let f = Fixture::new();
    // Only synthetic test storage resets this fixture to its before-first-login
    // state; production never clears a verified identity for registration.
    {
        let mut s = f.manager.store().unwrap();
        s.vault.account_mut(&f.id).unwrap().credential = None;
        s.vault.pending_registrations.clear();
        s.save().unwrap();
    }
    let manager = Arc::downgrade(&f.manager);
    f.manager
        .install_first_verified_listener(Arc::new(move |id| {
            let m = manager.upgrade().unwrap();
            assert!(m
                .register_pending_account(id, |_, _, p| p.plan_profile(3))
                .unwrap());
        }))
        .unwrap();
    f.login();
    assert!(f.manager.pending_registration_ids().unwrap().is_empty());
}

#[test]
fn explicit_legacy_registration_refreshes_stale_evidence_once_and_failure_preserves_account() {
    let f = Fixture::new();
    {
        let mut s = f.manager.store().unwrap();
        s.vault.pending_registrations.clear();
        s.vault
            .account_mut(&f.id)
            .unwrap()
            .credential
            .as_mut()
            .unwrap()
            .observed_at = 1;
        s.save().unwrap();
    }
    f.manager.request_account_registration(&f.id).unwrap();
    f.runtime.fail_verify.store(true, Ordering::SeqCst);
    assert_eq!(
        f.manager
            .refresh_registration_evidence(&f.id)
            .unwrap_err()
            .code,
        "synthetic_verification_failed"
    );
    assert_eq!(f.manager.list_managed_accounts().unwrap().len(), 1);
    assert_eq!(
        f.manager.pending_registration_ids().unwrap(),
        vec![f.id.clone()]
    );
    assert!(!f.manager.paths.desktop(&f.id).unwrap().exists());
    f.runtime.fail_verify.store(false, Ordering::SeqCst);
    f.manager.refresh_registration_evidence(&f.id).unwrap();
    assert_eq!(f.runtime.verifications.load(Ordering::SeqCst), 2);
    f.manager.refresh_registration_evidence(&f.id).unwrap();
    assert_eq!(f.runtime.verifications.load(Ordering::SeqCst), 2);
    f.manager.request_account_registration(&f.id).unwrap();
    f.manager
        .register_pending_account(&f.id, |_, _, _| Ok(()))
        .unwrap();
}
