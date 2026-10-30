//! Actual AccountManager switches/read evidence; synthetic runtime and private
//! filesystem only. No official process, system account or network is used.
use super::*;
use crate::accounts::{
    AccountIdentity, AccountRuntime, CredentialWritePurpose, LoginAuthorization, VerifiedCredential,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde_json::json;
use std::{path::Path, sync::atomic::AtomicUsize};
struct Protector;
impl SecretProtector for Protector {
    fn seal(&self, c: &str, b: &[u8]) -> AccountResult<Vec<u8>> {
        let mut out = c.as_bytes().to_vec();
        out.push(0);
        out.extend(b.iter().map(|b| b ^ 0x37));
        Ok(out)
    }
    fn unseal(&self, c: &str, b: &[u8]) -> AccountResult<Vec<u8>> {
        let mut prefix = c.as_bytes().to_vec();
        prefix.push(0);
        if !b.starts_with(&prefix) {
            return Err(fail("synthetic_unseal_failed"));
        }
        Ok(b[prefix.len()..].iter().map(|b| b ^ 0x37).collect())
    }
}
fn auth(name: &str) -> Vec<u8> {
    let jwt=format!("synthetic.{}.fixture",URL_SAFE_NO_PAD.encode(serde_json::to_vec(&json!({"email":format!("{name}@fixture.invalid"),"account_id":format!("workspace-{name}"),"exp":4_102_444_800i64})).unwrap()));
    serde_json::to_vec(&json!({"tokens":{"access_token":jwt,"id_token":jwt,"refresh_token":"synthetic-not-real","account_id":format!("workspace-{name}")}})).unwrap()
}
fn verified(bytes: Vec<u8>) -> AccountResult<VerifiedCredential> {
    let identity = AccountIdentity::from_auth(&bytes)?;
    VerifiedCredential::from_official_read(
        bytes,
        &json!({"account":{"type":"chatgpt","email":identity.email,"planType":"plus"}}),
        json!({"rateLimits":{"planType":"plus","primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":4_102_444_800i64}}}),
    )
}
struct Runtime {
    verifications: AtomicUsize,
    change_during_validation: AtomicBool,
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
        Err(fail("synthetic_login_forbidden"))
    }
    fn verify(&self, home: &Path, expected: &AccountIdentity) -> AccountResult<VerifiedCredential> {
        self.verifications.fetch_add(1, Ordering::AcqRel);
        let bytes = storage::read_optional(
            &home.join("auth.json"),
            crate::accounts::identity::MAX_AUTH_BYTES,
        )?
        .ok_or_else(|| fail("credentials_missing"))?;
        let v = verified(bytes)?;
        if &v.identity != expected {
            return Err(fail("identity_mismatch"));
        }
        Ok(v)
    }
    fn verify_in_operation(
        &self,
        home: &Path,
        expected: &AccountIdentity,
        guard: &dyn crate::accounts::SwitchCommitGuard,
    ) -> AccountResult<VerifiedCredential> {
        // Explicit synthetic transaction fixture. This does not manufacture a
        // native process/job receipt or advertise production runtime authority.
        guard.recheck()?;
        self.verify(home, expected)
    }
    fn require_system_idle(&self) -> AccountResult<()> {
        Ok(())
    }
    fn validate_target_configuration(&self, home: &Path) -> AccountResult<()> {
        if self.change_during_validation.swap(false, Ordering::AcqRel) {
            storage::atomic_write(
                &home.join("config.toml"),
                b"# synthetic concurrent config writer\n",
            )?;
        }
        crate::accounts::validate_target_configuration(home)
    }
}
struct Lease;
impl SwitchMaintenanceLease for Lease {
    fn recheck(&self) -> AccountResult<()> {
        Ok(())
    }
}
impl CredentialWriteLease for Lease {
    fn recheck(&self) -> AccountResult<()> {
        Ok(())
    }
}
struct Gate;
impl AccountOccupancyGate for Gate {
    fn acquire_switch_maintenance(
        &self,
        _: &str,
        _: &str,
    ) -> AccountResult<Box<dyn SwitchMaintenanceLease>> {
        Ok(Box::new(Lease))
    }
    fn acquire_credential_write(
        &self,
        _: &str,
        purpose: CredentialWritePurpose,
    ) -> AccountResult<Box<dyn CredentialWriteLease>> {
        if matches!(purpose, CredentialWritePurpose::Managed) {
            Ok(Box::new(Lease))
        } else {
            Err(fail("occupancy_unknown"))
        }
    }
}
struct Fixture {
    _temp: tempfile::TempDir,
    manager: Arc<AccountManager>,
    runtime: Arc<Runtime>,
    source: String,
    target: String,
    config: Vec<u8>,
}
impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let home = root.join("synthetic-system-home");
        storage::secure_directory(&home).unwrap();
        let config = b"cli_auth_credentials_store = 'file'\n".to_vec();
        storage::atomic_write(&home.join("config.toml"), &config).unwrap();
        storage::atomic_write(&home.join("auth.json"), &auth("source")).unwrap();
        let runtime = Arc::new(Runtime {
            verifications: AtomicUsize::new(0),
            change_during_validation: AtomicBool::new(false),
        });
        let manager = AccountManager::with_components(
            AccountPaths::isolated(root.join("synthetic-vault"), home).unwrap(),
            Arc::new(Protector),
            runtime.clone(),
            Some(Arc::new(Gate)),
        )
        .unwrap();
        let source = crate::accounts::nonce().unwrap();
        let target = crate::accounts::nonce().unwrap();
        {
            let mut store = manager.store().unwrap();
            for (id, name) in [(&source, "source"), (&target, "target")] {
                store.vault.accounts.push(AccountRecord {
                    id: id.clone(),
                    label: name.into(),
                    platform: "codex".into(),
                    revision: 1,
                    created_at_ms: None,
                    browser: Default::default(),
                    credential: Some(
                        verified(auth(name))
                            .unwrap()
                            .into_stored(crate::accounts::nonce().unwrap()),
                    ),
                });
            }
            store.save().unwrap();
        }
        Self {
            _temp: temp,
            manager,
            runtime,
            source,
            target,
            config,
        }
    }
    fn switched(&self) -> crate::accounts::ActiveSystemScope {
        let prepared = self
            .manager
            .prepare_account_switch(self.target.clone())
            .unwrap();
        assert_eq!(prepared.phase, "ready");
        assert_eq!(
            self.manager
                .commit_account_switch(prepared.ticket.as_ref().unwrap())
                .unwrap()
                .phase,
            "committed"
        );
        self.manager.verified_active_system_scope().unwrap()
    }
}

#[test]
fn active_system_scope_only_real_committed_switch_sets_establishment_time_and_read_is_side_effect_free(
) {
    let f = Fixture::new();
    assert!(f.manager.verified_active_system_scope().is_err());
    let before = chrono::Utc::now().timestamp_millis() as u64;
    let scope = f.switched();
    let calls = f.runtime.verifications.load(Ordering::Acquire);
    let vault = std::fs::read(f.manager.paths.vault_root.join("accounts.dpapi")).unwrap();
    let target = TargetSnapshot::read(&f.manager.paths.system_home).unwrap();
    assert!(scope.canonical_home() == std::fs::canonicalize(&f.manager.paths.system_home).unwrap());
    assert_eq!(scope.profile_id(), f.target);
    assert!(scope.established_at_unix_ms() >= before);
    assert!(scope.established_at_unix_ms() <= chrono::Utc::now().timestamp_millis() as u64);
    for _ in 0..3 {
        f.manager.recheck_active_system_scope(&scope).unwrap();
    }
    assert_eq!(f.runtime.verifications.load(Ordering::Acquire), calls);
    assert!(std::fs::read(f.manager.paths.vault_root.join("accounts.dpapi")).unwrap() == vault);
    assert!(TargetSnapshot::read(&f.manager.paths.system_home).unwrap() == target);
}

#[test]
fn active_system_scope_legacy_proof_does_not_borrow_quota_observation_time() {
    let f = Fixture::new();
    let _ = f.switched();
    {
        let mut store = f.manager.store().unwrap();
        store.vault.active.as_mut().unwrap().established_at_unix_ms = None;
        store.save().unwrap();
    }
    assert_eq!(
        f.manager.verified_active_system_scope().err().unwrap().code,
        "active_scope_unverified"
    );
}

#[test]
fn active_system_scope_auth_config_and_generation_changes_revoke_old_proof() {
    let f = Fixture::new();
    let scope = f.switched();
    let auth_path = f.manager.paths.system_home.join("auth.json");
    let saved = std::fs::read(&auth_path).unwrap();
    storage::atomic_write(&auth_path, &auth("external")).unwrap();
    assert!(f.manager.recheck_active_system_scope(&scope).is_err());
    storage::atomic_write(&auth_path, &saved).unwrap();
    storage::atomic_write(
        &f.manager.paths.system_home.join("config.toml"),
        b"# changed synthetic config\n",
    )
    .unwrap();
    assert!(f.manager.recheck_active_system_scope(&scope).is_err());
    storage::atomic_write(&f.manager.paths.system_home.join("config.toml"), &f.config).unwrap();
    f.manager.recheck_active_system_scope(&scope).unwrap();
    {
        let mut store = f.manager.store().unwrap();
        store
            .vault
            .account_mut(&f.target)
            .unwrap()
            .credential
            .as_mut()
            .unwrap()
            .generation = crate::accounts::nonce().unwrap();
        store.save().unwrap();
    }
    assert!(f.manager.recheck_active_system_scope(&scope).is_err());
}

#[test]
fn active_system_scope_pending_switch_login_cleanup_journal_and_exit_remain_unknown() {
    let f = Fixture::new();
    let scope = f.switched();
    let ticket = f
        .manager
        .prepare_account_switch(f.source.clone())
        .unwrap()
        .ticket
        .unwrap();
    assert_eq!(
        f.manager.verified_active_system_scope().err().unwrap().code,
        "switch_in_progress"
    );
    f.manager.cancel_account_switch(&ticket).unwrap();
    let attempt = crate::accounts::nonce().unwrap();
    f.manager.attempts.lock().unwrap().insert(
        attempt.clone(),
        Attempt {
            dto: LoginAttemptDto {
                attempt_id: attempt.clone(),
                account_id: f.target.clone(),
                phase: "waiting",
                verification_url: None,
                user_code: None,
                error_code: None,
            },
            cancelled: Arc::new(AtomicBool::new(false)),
        },
    );
    assert_eq!(
        f.manager.verified_active_system_scope().err().unwrap().code,
        "login_in_progress"
    );
    f.manager.attempts.lock().unwrap().clear();
    f.manager.cleanup_unconfirmed.store(true, Ordering::Release);
    assert_eq!(
        f.manager.verified_active_system_scope().err().unwrap().code,
        "cleanup_unconfirmed"
    );
    f.manager
        .cleanup_unconfirmed
        .store(false, Ordering::Release);
    storage::atomic_write(&f.manager.paths.journal(), b"synthetic-unknown-journal").unwrap();
    assert_eq!(
        f.manager.verified_active_system_scope().err().unwrap().code,
        "recovery_required"
    );
    assert_eq!(
        std::fs::read(f.manager.paths.journal()).unwrap(),
        b"synthetic-unknown-journal"
    );
    std::fs::remove_file(f.manager.paths.journal()).unwrap();
    f.manager.cancel_inflight_for_exit();
    assert_eq!(
        f.manager
            .recheck_active_system_scope(&scope)
            .err()
            .unwrap()
            .code,
        "account_service_exiting"
    );
}

#[test]
fn active_system_scope_try_locks_reject_contention_without_waiting() {
    let f = Fixture::new();
    let _ = f.switched();
    let held = f.manager.mutation.lock().unwrap();
    assert_eq!(
        f.manager.verified_active_system_scope().err().unwrap().code,
        "account_busy"
    );
    drop(held);
    let held = f.manager.attempts.lock().unwrap();
    assert_eq!(
        f.manager.verified_active_system_scope().err().unwrap().code,
        "account_state_unavailable"
    );
    drop(held);
    let held = storage::StoreLock::acquire(&f.manager.paths.vault_root).unwrap();
    assert_eq!(
        f.manager.verified_active_system_scope().err().unwrap().code,
        "account_store_busy"
    );
    drop(held);
}

#[test]
fn active_system_scope_stale_quota_never_fakes_freshness_or_blocks_identity_proof() {
    let f = Fixture::new();
    let scope = f.switched();
    {
        let mut store = f.manager.store().unwrap();
        store
            .vault
            .account_mut(&f.target)
            .unwrap()
            .credential
            .as_mut()
            .unwrap()
            .observed_at = crate::accounts::now() - 3600;
        store.save().unwrap();
    }
    assert!(f
        .manager
        .verified_credential_snapshot(&f.target, 45)
        .is_err());
    f.manager.recheck_active_system_scope(&scope).unwrap();
}

#[test]
fn active_system_scope_checks_target_again_after_native_config_validation() {
    let f = Fixture::new();
    let scope = f.switched();
    let calls = f.runtime.verifications.load(Ordering::Acquire);
    f.runtime
        .change_during_validation
        .store(true, Ordering::Release);
    assert!(f.manager.recheck_active_system_scope(&scope).is_err());
    assert_eq!(f.runtime.verifications.load(Ordering::Acquire), calls);
}

#[test]
fn active_system_scope_same_identity_token_rotation_never_adopts_old_system_or_vault_bytes() {
    let f = Fixture::new();
    let scope = f.switched();
    let path = f.manager.paths.system_home.join("auth.json");
    let original = std::fs::read(&path).unwrap();
    let mut value: serde_json::Value = serde_json::from_slice(&original).unwrap();
    value["tokens"]["refresh_token"] = json!("synthetic-rotated-not-real");
    let rotated = serde_json::to_vec(&value).unwrap();
    assert!(
        AccountIdentity::from_auth(&original).unwrap()
            == AccountIdentity::from_auth(&rotated).unwrap()
    );
    storage::atomic_write(&path, &rotated).unwrap();
    assert!(f.manager.recheck_active_system_scope(&scope).is_err());
    let vault_before = std::fs::read(f.manager.paths.vault_root.join("accounts.dpapi")).unwrap();
    f.manager.refresh_managed_credential(&f.target).unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), rotated);
    assert!(f.manager.verified_active_system_scope().is_err());
    assert!(f
        .manager
        .cached_quota_snapshot(&f.target)
        .unwrap()
        .is_some());
    // A saved quota receipt has no power to bind an externally rotated system
    // grant back to the previous active credential generation.
    assert!(f.manager.recheck_active_system_scope(&scope).is_err());
    assert_ne!(
        std::fs::read(f.manager.paths.vault_root.join("accounts.dpapi")).unwrap(),
        vault_before
    );
}

#[test]
fn managed_catalog_rename_current_preserves_identity_scope_and_same_name_is_a_noop() {
    let f = Fixture::new();
    let scope = f.switched();
    let before = TargetSnapshot::read(&f.manager.paths.system_home).unwrap();
    let result = f
        .manager
        .rename_managed_account(&f.target, "Renamed".into())
        .unwrap();
    assert_eq!(result.phase, "renamed");
    f.manager.recheck_active_system_scope(&scope).unwrap();
    assert!(TargetSnapshot::read(&f.manager.paths.system_home).unwrap() == before);
    let bytes = std::fs::read(f.manager.paths.vault_root.join("accounts.dpapi")).unwrap();
    f.manager
        .rename_managed_account(&f.target, "Renamed".into())
        .unwrap();
    assert_eq!(
        std::fs::read(f.manager.paths.vault_root.join("accounts.dpapi")).unwrap(),
        bytes
    );
    assert_eq!(
        f.manager
            .rename_managed_account(&f.source, "renamed".into())
            .err()
            .unwrap()
            .code,
        "duplicate_label"
    );
    assert_eq!(
        f.manager
            .rename_managed_account(&f.source, "".into())
            .err()
            .unwrap()
            .code,
        "invalid_label"
    );
}

#[test]
fn managed_catalog_remove_preserves_system_and_desktop_history_and_rejects_current_alias() {
    let f = Fixture::new();
    let scope = f.switched();
    let before = TargetSnapshot::read(&f.manager.paths.system_home).unwrap();
    let home = f.manager.paths.desktop(&f.source).unwrap();
    storage::secure_directory(&home).unwrap();
    storage::atomic_write(&home.join("history.jsonl"), b"synthetic retained history\n").unwrap();
    assert_eq!(
        f.manager.remove_managed_account(&f.source).unwrap().phase,
        "removed"
    );
    assert!(f
        .manager
        .list_managed_accounts()
        .unwrap()
        .iter()
        .all(|r| r.id != f.source));
    assert_eq!(
        std::fs::read(home.join("history.jsonl")).unwrap(),
        b"synthetic retained history\n"
    );
    assert!(TargetSnapshot::read(&f.manager.paths.system_home).unwrap() == before);
    f.manager.recheck_active_system_scope(&scope).unwrap();
    assert_eq!(
        f.manager
            .remove_managed_account(&f.target)
            .err()
            .unwrap()
            .code,
        "account_is_current"
    );
    let alias = crate::accounts::nonce().unwrap();
    {
        let mut store = f.manager.store().unwrap();
        let mut record = store.vault.account(&f.target).unwrap().clone();
        record.id = alias.clone();
        record.label = "Alias".into();
        store.vault.accounts.push(record);
        store.save().unwrap();
    }
    assert_eq!(
        f.manager.remove_managed_account(&alias).err().unwrap().code,
        "account_is_current"
    );
    assert_eq!(f.manager.list_managed_accounts().unwrap().len(), 2);
}

#[test]
fn managed_catalog_unknown_current_writer_or_pending_switch_never_removes_saved_slot() {
    let f = Fixture::new();
    assert_eq!(
        f.manager
            .remove_managed_account(&f.target)
            .err()
            .unwrap()
            .code,
        "account_identity_unverified"
    );
    let scope = f.switched();
    let home = f.manager.paths.desktop(&f.source).unwrap();
    storage::secure_directory(&home).unwrap();
    storage::atomic_write(
        &home.join("writer-claim.dpapi"),
        b"synthetic unknown writer",
    )
    .unwrap();
    assert_eq!(
        f.manager
            .remove_managed_account(&f.source)
            .err()
            .unwrap()
            .code,
        "desktop_writer_recovery_required"
    );
    let ticket = f
        .manager
        .prepare_account_switch(f.source.clone())
        .unwrap()
        .ticket
        .unwrap();
    assert_eq!(
        f.manager
            .rename_managed_account(&f.source, "Blocked".into())
            .err()
            .unwrap()
            .code,
        "switch_in_progress"
    );
    assert_eq!(
        f.manager
            .remove_managed_account(&f.source)
            .err()
            .unwrap()
            .code,
        "switch_in_progress"
    );
    f.manager.cancel_account_switch(&ticket).unwrap();
    storage::atomic_write(
        &f.manager.paths.system_home.join("config.toml"),
        b"# unknown external config\n",
    )
    .unwrap();
    assert_eq!(
        f.manager
            .remove_managed_account(&f.source)
            .err()
            .unwrap()
            .code,
        "account_identity_unverified"
    );
    assert_eq!(f.manager.list_managed_accounts().unwrap().len(), 2);
    assert!(f.manager.recheck_active_system_scope(&scope).is_err());
}

struct AutomaticGuard(crate::managed_proxy::AutomaticMaintenanceLease);
impl crate::accounts::SwitchCommitGuard for AutomaticGuard {
    fn recheck(&self) -> AccountResult<()> {
        self.0.recheck_cached()
    }
}
fn actual_gate(f: &Fixture, name: &str) -> Arc<crate::managed_proxy::ManagedProxyGate> {
    let gate =
        crate::managed_proxy::ManagedProxyGate::new(f._temp.path().join(name), &f.manager).unwrap();
    f.manager.install_occupancy_gate(gate.clone()).unwrap();
    gate
}

#[test]
fn automatic_account_lease_spans_real_prepare_commit_and_retains_source_target_scope() {
    let f = Fixture::new();
    let source = f.switched();
    let gate = actual_gate(&f, "synthetic-auto-registry");
    let lease = gate
        .reserve_automatic_maintenance(&source, &f.source)
        .unwrap();
    assert_eq!(lease.source_profile_id(), source.profile_id());
    assert_eq!(lease.target_profile_id(), f.source);
    let guard = AutomaticGuard(lease.clone());
    let prepared = f
        .manager
        .prepare_account_switch_in_operation(&f.source, &lease, &guard)
        .unwrap();
    assert_eq!(prepared.phase, "ready");
    assert_eq!(prepared.ticket.as_deref(), Some(lease.operation_id()));
    assert!(gate.reserve_terminal(source.identity_hash()).is_err());
    assert!(gate
        .acquire_credential_write(&f.source, CredentialWritePurpose::Managed)
        .is_err());
    assert_eq!(
        f.manager
            .commit_account_switch_guarded(prepared.ticket.as_ref().unwrap(), &guard)
            .unwrap()
            .phase,
        "committed"
    );
    lease.recheck().unwrap();
    assert_eq!(
        f.manager
            .verified_active_system_scope()
            .unwrap()
            .profile_id(),
        f.source
    );
    assert!(f.manager.recheck_active_system_scope(&source).is_err());
    drop(guard);
    assert!(gate.reserve_terminal(source.identity_hash()).is_err());
    drop(lease);
    assert!(gate.reserve_terminal(source.identity_hash()).is_ok());
}

#[test]
fn automatic_account_lease_wrong_target_and_foreign_gate_cannot_be_adopted() {
    let f = Fixture::new();
    let source = f.switched();
    let gate = actual_gate(&f, "synthetic-auto-registry");
    let lease = gate
        .reserve_automatic_maintenance(&source, &f.source)
        .unwrap();
    let guard = AutomaticGuard(lease.clone());
    let calls = f.runtime.verifications.load(Ordering::Acquire);
    let wrong_target = f
        .manager
        .prepare_account_switch_in_operation(&f.target, &lease, &guard)
        .unwrap();
    assert_eq!(wrong_target.phase, "blocked");
    assert_eq!(wrong_target.reason_code, Some("occupancy_unknown"));
    let foreign = actual_gate(&f, "synthetic-foreign-registry");
    let wrong_gate = f
        .manager
        .prepare_account_switch_in_operation(&f.source, &lease, &guard)
        .unwrap();
    assert_eq!(wrong_gate.phase, "blocked");
    assert_eq!(wrong_gate.reason_code, Some("occupancy_unknown"));
    assert_eq!(f.runtime.verifications.load(Ordering::Acquire), calls);
    assert_eq!(foreign.cached_dispatch_busy(), Some(false));
    lease.recheck().unwrap();
    f.manager.recheck_active_system_scope(&source).unwrap();
}

#[test]
fn automatic_account_lease_clone_outlives_parent_and_blocks_plain_writes_and_terminals() {
    let f = Fixture::new();
    let source = f.switched();
    let gate = actual_gate(&f, "synthetic-auto-registry");
    let parent = gate
        .reserve_automatic_maintenance(&source, &f.source)
        .unwrap();
    let retained = parent.clone();
    drop(parent);
    retained.recheck().unwrap();
    assert_eq!(gate.cached_dispatch_busy(), Some(true));
    assert!(gate
        .acquire_credential_write(&f.source, CredentialWritePurpose::Managed)
        .is_err());
    assert!(gate
        .acquire_credential_write(&f.target, CredentialWritePurpose::Managed)
        .is_err());
    assert!(gate.reserve_terminal(source.identity_hash()).is_err());
    drop(retained);
    assert_eq!(gate.cached_dispatch_busy(), Some(false));
    assert!(gate
        .acquire_credential_write(&f.source, CredentialWritePurpose::Managed)
        .is_ok());
    assert!(gate.reserve_terminal(source.identity_hash()).is_ok());
}

#[test]
fn automatic_account_prepare_rejects_source_token_rotation_or_config_change_before_official_read() {
    for change_config in [false, true] {
        let f = Fixture::new();
        let source = f.switched();
        let gate = actual_gate(&f, "synthetic-auto-registry");
        let lease = gate
            .reserve_automatic_maintenance(&source, &f.source)
            .unwrap();
        let guard = AutomaticGuard(lease.clone());
        if change_config {
            storage::atomic_write(
                &f.manager.paths.system_home.join("config.toml"),
                b"# synthetic advanced config\n",
            )
            .unwrap();
        } else {
            let path = f.manager.paths.system_home.join("auth.json");
            let mut auth: serde_json::Value =
                serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
            auth["tokens"]["refresh_token"] = json!("synthetic-system-successor");
            storage::atomic_write(&path, &serde_json::to_vec(&auth).unwrap()).unwrap();
        }
        let calls = f.runtime.verifications.load(Ordering::Acquire);
        let changed = TargetSnapshot::read(&f.manager.paths.system_home).unwrap();
        let vault = std::fs::read(f.manager.paths.vault_root.join("accounts.dpapi")).unwrap();
        let result = f
            .manager
            .prepare_account_switch_in_operation(&f.source, &lease, &guard)
            .unwrap();
        assert_eq!(result.phase, "blocked");
        assert_eq!(result.reason_code, Some("active_scope_changed"));
        assert_eq!(f.runtime.verifications.load(Ordering::Acquire), calls);
        assert_eq!(
            std::fs::read(f.manager.paths.vault_root.join("accounts.dpapi")).unwrap(),
            vault
        );
        assert!(TargetSnapshot::read(&f.manager.paths.system_home).unwrap() == changed);
    }
}
