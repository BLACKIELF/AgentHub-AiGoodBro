use super::*;
use codexu_core::accounts::{
    AccountIdentity, AccountLoginSpawner, AccountOccupancyGate, AccountPaths, AccountResult,
    AccountRuntime, CredentialWriteLease, CredentialWritePurpose, LoginAuthorization,
    SecretProtector, SwitchMaintenanceLease, VerifiedCredential,
};
use codexu_core::workflow::WorkflowPreferences;
use std::sync::{atomic::AtomicBool, Mutex};

struct Protector;
impl SecretProtector for Protector {
    fn seal(&self, c: &str, b: &[u8]) -> AccountResult<Vec<u8>> {
        Ok([c.as_bytes(), &[0], b].concat())
    }
    fn unseal(&self, c: &str, b: &[u8]) -> AccountResult<Vec<u8>> {
        b.strip_prefix(&[c.as_bytes(), &[0]].concat()[..])
            .map(|v| v.to_vec())
            .ok_or(AccountError {
                code: "fixture_context",
            })
    }
}
struct Runtime;
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
        let jwt="synthetic.eyJlbWFpbCI6ImZpeHR1cmVAZml4dHVyZS5pbnZhbGlkIiwiYWNjb3VudF9pZCI6ImZpeHR1cmUiLCJleHAiOjQxMDI0NDQ4MDB9.fixture";
        let auth=serde_json::to_vec(&serde_json::json!({"tokens":{"access_token":jwt,"id_token":jwt,"refresh_token":"synthetic-not-real","account_id":"fixture"}})).unwrap();
        VerifiedCredential::from_official_read(
            auth,
            &serde_json::json!({"account":{"type":"chatgpt","email":"fixture@fixture.invalid","planType":"plus"}}),
            serde_json::json!({"rateLimits":{"planType":"plus","primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":4102444800i64}}}),
        )
    }
    fn verify(&self, _: &Path, _: &AccountIdentity) -> AccountResult<VerifiedCredential> {
        panic!("registration must not request an official service")
    }
    fn require_system_idle(&self) -> AccountResult<()> {
        panic!("registration must not switch")
    }
    fn validate_target_configuration(&self, p: &Path) -> AccountResult<()> {
        codexu_core::accounts::validate_target_configuration(p)
    }
}
#[derive(Default)]
struct Spawner(Mutex<Option<Box<dyn FnOnce() + Send>>>);
impl AccountLoginSpawner for Spawner {
    fn spawn(&self, work: Box<dyn FnOnce() + Send>) -> AccountResult<()> {
        *self.0.lock().unwrap() = Some(work);
        Ok(())
    }
}
struct Gate;
struct Lease;
impl CredentialWriteLease for Lease {
    fn recheck(&self) -> AccountResult<()> {
        Ok(())
    }
}
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
        p: CredentialWritePurpose,
    ) -> AccountResult<Box<dyn CredentialWriteLease>> {
        assert!(matches!(p, CredentialWritePurpose::Managed));
        Ok(Box::new(Lease))
    }
}
struct Fixture {
    _temp: tempfile::TempDir,
    paths: AccountPaths,
    manager: Arc<AccountManager>,
    state: Arc<AppState>,
    workflow: WorkflowState,
    id: String,
}
impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let paths = AccountPaths::isolated(root.join("vault"), root.join("system")).unwrap();
        std::fs::create_dir(&paths.system_home).unwrap();
        let spawner = Arc::new(Spawner::default());
        let manager = AccountManager::with_components_and_spawner(
            paths.clone(),
            Arc::new(Protector),
            Arc::new(Runtime),
            Some(Arc::new(Gate)),
            spawner.clone(),
        )
        .unwrap();
        let id = manager
            .create_managed_account("Fixture".into(), "codex".into())
            .unwrap()
            .id;
        let attempt = manager.begin_account_login(id.clone()).unwrap();
        let work = spawner.0.lock().unwrap().take().unwrap();
        work();
        assert_eq!(
            manager
                .get_login_attempt(&attempt.attempt_id)
                .unwrap()
                .phase,
            "verified"
        );
        let state = Arc::new(AppState::new(root.join("app-data")));
        tauri::async_runtime::block_on(async {
            let mut c = state.config.write().await;
            c.codex_root = root.join("empty-codex");
            c.cache_dir = root.join("cache");
            c.save(&state.app_data_dir).unwrap();
        });
        Self {
            _temp: temp,
            paths,
            manager,
            state,
            workflow: WorkflowState::default(),
            id,
        }
    }
    fn run(&self) -> Result<Option<u64>, AccountError> {
        finish_pending(&self.manager, &self.state, &self.workflow, &self.id)
    }
    fn prefs(&self) -> WorkflowPreferences {
        serde_json::from_slice(
            &std::fs::read(self.state.app_data_dir.join("workflow-preferences-v1.json")).unwrap(),
        )
        .unwrap()
    }
    fn save_prefs(&self, p: &WorkflowPreferences) {
        codexu_core::atomic_settings::write_json(
            &self.state.app_data_dir.join("workflow-preferences-v1.json"),
            &serde_json::to_vec(p).unwrap(),
            |b| {
                let p: WorkflowPreferences = serde_json::from_slice(b)?;
                p.validate()
            },
        )
        .unwrap();
    }
    fn reload(&mut self) {
        self.manager = AccountManager::with_components(
            self.paths.clone(),
            Arc::new(Protector),
            Arc::new(Runtime),
            Some(Arc::new(Gate)),
        )
        .unwrap();
        self.state = Arc::new(AppState::new(self.state.app_data_dir.clone()));
    }
    fn blocked_workflow(&self) -> std::path::PathBuf {
        let p = self.state.app_data_dir.join("workflow-preferences-v1.json");
        std::fs::create_dir(&p).unwrap();
        p
    }
}
#[test]
fn actual_first_login_registers_unique_home_catalog_and_default_workflow_without_switching() {
    let mut f = Fixture::new();
    let before = tauri::async_runtime::block_on(async {
        let c = f.state.config.read().await;
        (c.codex_root.clone(), c.cache_dir.clone())
    });
    assert_eq!(f.run().unwrap(), Some(1));
    assert!(f.prefs().profiles[&1].participating);
    assert!(f.manager.pending_registration_ids().unwrap().is_empty());
    let hub = f.manager.hub_account_snapshot(&f.id).unwrap();
    assert_eq!(
        hub.identity_hash,
        f.manager
            .verified_credential_snapshot(&f.id, 45)
            .unwrap()
            .identity_hash
    );
    assert_eq!(
        hub.manager_profile("account-1", &f.prefs().profiles[&1])
            .unwrap_err()
            .code,
        "hub_model_required"
    );
    f.reload();
    assert_eq!(f.run().unwrap(), None);
    tauri::async_runtime::block_on(async {
        let c = f.state.config.read().await;
        assert_eq!(c.profiles.entries.len(), 1);
        assert_eq!((c.codex_root.clone(), c.cache_dir.clone()), before);
        let entry = &c.profiles.entries[0];
        let roots = f.manager.managed_history_roots().unwrap();
        assert_eq!(roots.len(), 1);
        assert_eq!(roots[0].1.canonicalize().unwrap(), entry.root);
    });
    assert!(!f.paths.system_home.join("auth.json").exists());
}
#[test]
fn catalog_saved_workflow_failed_restart_resumes_owned_id_once() {
    let mut f = Fixture::new();
    let block = f.blocked_workflow();
    assert_eq!(f.run().unwrap_err().code, "registration_persistence_failed");
    assert_eq!(
        f.manager.pending_registration_ids().unwrap(),
        vec![f.id.clone()]
    );
    f.reload();
    tauri::async_runtime::block_on(async {
        assert_eq!(f.state.config.read().await.profiles.entries.len(), 1)
    });
    std::fs::remove_dir(block).unwrap();
    assert_eq!(f.run().unwrap(), Some(1));
    assert!(f.prefs().profiles[&1].participating);
    assert_eq!(f.run().unwrap(), None);
}
#[test]
fn explicit_opt_out_during_recovery_survives_and_existing_root_is_not_new() {
    let mut f = Fixture::new();
    let block = f.blocked_workflow();
    assert!(f.run().is_err());
    std::fs::remove_dir(block).unwrap();
    let mut prefs = WorkflowPreferences::default();
    prefs.set_participating(1, false).unwrap();
    f.save_prefs(&prefs);
    f.reload();
    assert_eq!(f.run().unwrap(), Some(1));
    assert!(!f.prefs().profiles[&1].participating);
    // A subsequent explicit legacy/repair action must also preserve opt-out.
    f.manager.request_account_registration(&f.id).unwrap();
    assert_eq!(f.run().unwrap(), Some(1));
    assert!(!f.prefs().profiles[&1].participating);
    // Even a missing workflow entry cannot be treated as a new account.
    let empty = WorkflowPreferences::default();
    f.save_prefs(&empty);
    f.manager.request_account_registration(&f.id).unwrap();
    assert_eq!(f.run().unwrap(), Some(1));
    assert!(f.prefs().profiles.is_empty());
}
#[test]
fn planned_catalog_id_cannot_adopt_another_root_on_recovery() {
    let mut f = Fixture::new();
    let block = f.blocked_workflow();
    assert!(f.run().is_err());
    std::fs::remove_dir(block).unwrap();
    let other = f._temp.path().join("unrelated");
    std::fs::create_dir(&other).unwrap();
    tauri::async_runtime::block_on(f.state.try_update_config(|c| {
        c.profiles.entries[0].root = other.clone();
        Ok(())
    }))
    .unwrap();
    f.reload();
    assert_eq!(f.run().unwrap_err().code, "registration_persistence_failed");
    assert_eq!(f.manager.pending_registration_ids().unwrap().len(), 1);
    tauri::async_runtime::block_on(async {
        let c = f.state.config.read().await;
        assert_eq!(c.profiles.entries.len(), 1);
        assert_eq!(c.profiles.entries[0].root, other);
    });
    assert!(!f
        .state
        .app_data_dir
        .join("workflow-preferences-v1.json")
        .exists());
}
#[test]
fn catalog_save_failure_retains_exact_plan_then_recovers_without_duplicate() {
    let mut f = Fixture::new();
    let settings = f.state.app_data_dir.join("settings.json");
    let original = std::fs::read(&settings).unwrap();
    std::fs::remove_file(&settings).unwrap();
    std::fs::create_dir(&settings).unwrap();
    assert!(f.run().is_err());
    assert_eq!(f.manager.pending_registration_ids().unwrap().len(), 1);
    std::fs::remove_dir(&settings).unwrap();
    std::fs::write(&settings, original).unwrap();
    f.reload();
    assert_eq!(f.run().unwrap(), Some(1));
    assert!(f.prefs().profiles[&1].participating);
}

#[test]
fn workflow_committed_but_completion_interrupted_keeps_user_opt_out_on_resume() {
    let mut f = Fixture::new();
    let result = f.manager.register_pending_account(&f.id, |root, label, p| {
        tauri::async_runtime::block_on(persist_mapping(&f.state, &f.workflow, root, label, p))?;
        Err(AccountError {
            code: "synthetic_interruption_before_completion",
        })
    });
    assert_eq!(
        result.unwrap_err().code,
        "synthetic_interruption_before_completion"
    );
    assert!(f.prefs().profiles[&1].participating);
    let mut prefs = f.prefs();
    prefs.set_participating(1, false).unwrap();
    f.save_prefs(&prefs);
    f.reload();
    assert_eq!(f.run().unwrap(), Some(1));
    assert!(!f.prefs().profiles[&1].participating);
}
