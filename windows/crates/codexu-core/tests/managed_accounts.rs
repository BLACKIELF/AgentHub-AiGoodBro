//! Actual production manager/transaction with synthetic credentials and explicit
//! transport/encryption collaborators. No native account, process or network.
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use codexu_core::accounts::*;
use serde_json::{json, Value};
#[path = "support/windows_creation.rs"]
mod windows_creation;
use std::{
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};

fn error(code: &'static str) -> AccountError {
    AccountError { code }
}
fn claims(value: Value) -> String {
    format!(
        "synthetic.{}.not-a-real-signature",
        URL_SAFE_NO_PAD.encode(serde_json::to_vec(&value).unwrap())
    )
}
fn credential(subject: &str) -> Vec<u8> {
    let jwt = claims(
        json!({"email":format!("{subject}@fixture.invalid"),"account_id":format!("workspace-{subject}"),"exp":4_102_444_800i64}),
    );
    serde_json::to_vec(&json!({"tokens":{"access_token":jwt,"id_token":jwt,"refresh_token":"synthetic-refresh","account_id":format!("workspace-{subject}")}})).unwrap()
}
fn verified(subject: &str) -> AccountResult<VerifiedCredential> {
    VerifiedCredential::from_official_read(
        credential(subject),
        &json!({"account":{"type":"chatgpt","email":format!("{subject}@fixture.invalid"),"planType":"plus"}}),
        json!({"rateLimits":{"planType":"plus","primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":chrono::Utc::now().timestamp()+3600}}}),
    )
}

/// Named as a test collaborator: product never registers this protector.
struct FixtureProtector {
    reject: AtomicBool,
}
impl SecretProtector for FixtureProtector {
    fn seal(&self, context: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
        if self.reject.load(Ordering::SeqCst) {
            return Err(error("fixture_seal_failed"));
        }
        let mut value = context.as_bytes().to_vec();
        value.push(0);
        value.extend(bytes.iter().map(|b| b ^ 0x6b));
        Ok(value)
    }
    fn unseal(&self, context: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
        let mut prefix = context.as_bytes().to_vec();
        prefix.push(0);
        if !bytes.starts_with(&prefix) {
            return Err(error("fixture_unseal_failed"));
        }
        Ok(bytes[prefix.len()..].iter().map(|b| b ^ 0x6b).collect())
    }
}
struct FixtureRuntime {
    subject: Mutex<String>,
    system: PathBuf,
    fail_target: AtomicBool,
    rotate_target: AtomicBool,
    foreign_target: AtomicBool,
    wait_login: AtomicBool,
    idle: AtomicBool,
    verify_calls: AtomicUsize,
    unknown_login_cleanup: AtomicBool,
    unknown_verify_cleanup: AtomicBool,
    fail_seal_after_target: Mutex<Option<Arc<FixtureProtector>>>,
}
impl AccountRuntime for FixtureRuntime {
    fn available(&self) -> bool {
        true
    }
    fn login(
        &self,
        home: &Path,
        cancelled: &AtomicBool,
        report: &mut dyn FnMut(LoginAuthorization),
    ) -> AccountResult<VerifiedCredential> {
        assert_ne!(home, self.system);
        assert!(home.is_absolute());
        if self.unknown_login_cleanup.load(Ordering::SeqCst) {
            std::fs::write(home.join("auth.json"), credential("chosen")).unwrap();
            return Err(error("cleanup_unconfirmed"));
        }
        report(LoginAuthorization {
            verification_url: "https://auth.openai.com/codex/device".into(),
            user_code: "ABCD-1234".into(),
        });
        while self.wait_login.load(Ordering::SeqCst) {
            if cancelled.load(Ordering::SeqCst) {
                return Err(error("login_cancelled"));
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        verified(&self.subject.lock().unwrap())
    }
    fn verify(&self, home: &Path, expected: &AccountIdentity) -> AccountResult<VerifiedCredential> {
        self.verify_calls.fetch_add(1, Ordering::SeqCst);
        if self.unknown_verify_cleanup.load(Ordering::SeqCst) {
            return Err(error("cleanup_unconfirmed"));
        }
        if home == self.system {
            if self.foreign_target.load(Ordering::SeqCst) {
                std::fs::write(home.join("auth.json"), credential("external")).unwrap();
                return Err(error("verification_failed"));
            }
            if self.fail_target.load(Ordering::SeqCst) {
                return Err(error("verification_failed"));
            }
            if let Some(protector) = self.fail_seal_after_target.lock().unwrap().as_ref() {
                protector.reject.store(true, Ordering::SeqCst);
            }
            if self.rotate_target.load(Ordering::SeqCst) {
                let mut value: Value =
                    serde_json::from_slice(&std::fs::read(home.join("auth.json")).unwrap())
                        .unwrap();
                value["tokens"]["refresh_token"] = json!("synthetic-official-rotated-refresh");
                std::fs::write(home.join("auth.json"), serde_json::to_vec(&value).unwrap())
                    .unwrap();
            }
        }
        let subject = self.subject.lock().unwrap().clone();
        let auth = std::fs::read(home.join("auth.json")).unwrap();
        if AccountIdentity::from_auth(&auth)?.identity_hash() != expected.identity_hash() {
            return Err(error("identity_mismatch"));
        }
        VerifiedCredential::from_official_read(
            auth,
            &json!({"account":{"type":"chatgpt","email":format!("{subject}@fixture.invalid"),"planType":"plus"}}),
            json!({"rateLimits":{"planType":"plus","primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":chrono::Utc::now().timestamp()+3600}}}),
        )
    }
    fn require_system_idle(&self) -> AccountResult<()> {
        if self.idle.load(Ordering::SeqCst) {
            Ok(())
        } else {
            Err(error("account_busy"))
        }
    }
    fn validate_target_configuration(&self, home: &Path) -> AccountResult<()> {
        validate_target_configuration(home)
    }
}
struct FixtureGate {
    busy: Arc<AtomicBool>,
    checks: Arc<AtomicUsize>,
    fail_at: AtomicUsize,
    held: Arc<AtomicUsize>,
    writer_busy: Arc<AtomicBool>,
}
struct FixtureWriteLease(Arc<AtomicBool>);
impl CredentialWriteLease for FixtureWriteLease {
    fn recheck(&self) -> AccountResult<()> {
        if self.0.load(Ordering::SeqCst) {
            Err(error("desktop_writer_active"))
        } else {
            Ok(())
        }
    }
}
struct FixtureLease {
    busy: Arc<AtomicBool>,
    checks: Arc<AtomicUsize>,
    held: Arc<AtomicUsize>,
    fail_at: usize,
}
impl SwitchMaintenanceLease for FixtureLease {
    fn recheck(&self) -> AccountResult<()> {
        let count = self.checks.fetch_add(1, Ordering::SeqCst) + 1;
        if self.busy.load(Ordering::SeqCst) || count == self.fail_at {
            return Err(error("occupancy_unknown"));
        }
        Ok(())
    }
}
impl Drop for FixtureLease {
    fn drop(&mut self) {
        self.held.fetch_sub(1, Ordering::SeqCst);
    }
}
impl AccountOccupancyGate for FixtureGate {
    fn acquire_credential_write(
        &self,
        _: &str,
        _: CredentialWritePurpose,
    ) -> AccountResult<Box<dyn CredentialWriteLease>> {
        let lease = FixtureWriteLease(self.writer_busy.clone());
        lease.recheck()?;
        Ok(Box::new(lease))
    }
    fn acquire_switch_maintenance(
        &self,
        _account: &str,
        _operation: &str,
    ) -> AccountResult<Box<dyn SwitchMaintenanceLease>> {
        if self.busy.load(Ordering::SeqCst) {
            return Err(error("account_busy"));
        }
        self.held.fetch_add(1, Ordering::SeqCst);
        Ok(Box::new(FixtureLease {
            busy: self.busy.clone(),
            checks: self.checks.clone(),
            held: self.held.clone(),
            fail_at: self.fail_at.load(Ordering::SeqCst),
        }))
    }
}
struct Fixture {
    _temp: tempfile::TempDir,
    paths: AccountPaths,
    manager: Arc<AccountManager>,
    runtime: Arc<FixtureRuntime>,
    protector: Arc<FixtureProtector>,
    gate: Arc<FixtureGate>,
    before: Vec<u8>,
}
impl Fixture {
    fn new(gated: bool) -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = windows_creation::fixture_root(temp.path());
        let system = root.join("synthetic-system-home");
        windows_creation::create_private_dir(&system).unwrap();
        let before = credential("original");
        windows_creation::write_private_file_new(&system.join("auth.json"), &before).unwrap();
        windows_creation::write_private_file_new(
            &system.join("config.toml"),
            b"model_provider = 'openai'\ncli_auth_credentials_store = 'file'\n",
        )
        .unwrap();
        let paths = AccountPaths::isolated(root.join("vault"), system.clone()).unwrap();
        let protector = Arc::new(FixtureProtector {
            reject: AtomicBool::new(false),
        });
        let runtime = Arc::new(FixtureRuntime {
            subject: Mutex::new("chosen".into()),
            system,
            fail_target: AtomicBool::new(false),
            rotate_target: AtomicBool::new(false),
            foreign_target: AtomicBool::new(false),
            wait_login: AtomicBool::new(false),
            idle: AtomicBool::new(true),
            verify_calls: AtomicUsize::new(0),
            unknown_login_cleanup: AtomicBool::new(false),
            unknown_verify_cleanup: AtomicBool::new(false),
            fail_seal_after_target: Mutex::new(None),
        });
        let gate = Arc::new(FixtureGate {
            busy: Arc::new(AtomicBool::new(false)),
            checks: Arc::new(AtomicUsize::new(0)),
            fail_at: AtomicUsize::new(0),
            held: Arc::new(AtomicUsize::new(0)),
            writer_busy: Arc::new(AtomicBool::new(false)),
        });
        let manager = AccountManager::with_components(
            paths.clone(),
            protector.clone(),
            runtime.clone(),
            if gated { Some(gate.clone()) } else { None },
        )
        .unwrap();
        Self {
            _temp: temp,
            paths,
            manager,
            runtime,
            protector,
            gate,
            before,
        }
    }
    fn create(&self, label: &str) -> String {
        self.manager
            .create_managed_account(label.into(), "codex".into())
            .unwrap()
            .id
    }
    fn login(&self, id: &str) -> LoginAttemptDto {
        let attempt = self.manager.begin_account_login(id.into()).unwrap();
        self.finish(&attempt.attempt_id)
    }
    fn finish(&self, id: &str) -> LoginAttemptDto {
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let value = self.manager.get_login_attempt(id).unwrap();
            if ["verified", "failed", "cancelled"].contains(&value.phase) {
                return value;
            }
            assert!(
                Instant::now() < deadline,
                "bounded fixture login did not settle"
            );
            std::thread::sleep(Duration::from_millis(2));
        }
    }
    fn ready(&self, id: &str) -> String {
        let value = self.manager.prepare_account_switch(id.into()).unwrap();
        assert_eq!(value.phase, "ready", "{:?}", value);
        value.ticket.unwrap()
    }
    fn claim(&self, id: &str) -> codexu_core::proxy::DesktopWriterClaim {
        let bytes = self
            .protector
            .unseal(
                "AiGoodBro.Next.Windows.accounts.v1",
                &std::fs::read(self.paths.vault_root.join("accounts.dpapi")).unwrap(),
            )
            .unwrap();
        let value: Value = serde_json::from_slice(&bytes).unwrap();
        let record = value["accounts"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["id"] == id)
            .unwrap();
        codexu_core::proxy::DesktopWriterClaim {
            writer_id: "11111111111111111111111111111111".into(),
            profile_id: id.into(),
            proxy_run_id: "22222222222222222222222222222222".into(),
            identity_hash: AccountIdentity::from_auth(&credential("chosen"))
                .unwrap()
                .identity_hash(),
            initial_generation: record["credential"]["generation"].as_str().unwrap().into(),
        }
    }
    fn auth(&self) -> Vec<u8> {
        std::fs::read(self.paths.system_home.join("auth.json")).unwrap()
    }
}

#[test]
fn encrypted_store_survives_reopen_without_exposing_credentials_or_link_semantics() {
    let f = Fixture::new(true);
    let id = f.create("Primary");
    assert_eq!(f.login(&id).phase, "verified");
    assert_eq!(f.auth(), f.before);
    assert!(std::fs::read_dir(f.paths.vault_root.join("staging"))
        .unwrap()
        .next()
        .is_none());
    let bytes = std::fs::read(f.paths.vault_root.join("accounts.dpapi")).unwrap();
    let text = String::from_utf8_lossy(&bytes);
    for forbidden in [
        "synthetic-refresh",
        "access_token",
        "chosen@fixture.invalid",
    ] {
        assert!(!text.contains(forbidden));
    }
    let value = serde_json::to_string(&f.manager.list_managed_accounts().unwrap()).unwrap();
    for forbidden in [
        "synthetic-refresh",
        "access_token",
        "chosen@fixture.invalid",
        "workspace-chosen",
        f.paths.system_home.to_str().unwrap(),
    ] {
        assert!(!value.contains(forbidden));
    }
    let reopened = AccountManager::with_components(
        f.paths.clone(),
        f.protector.clone(),
        f.runtime.clone(),
        None,
    )
    .unwrap();
    let accounts = reopened.list_managed_accounts().unwrap();
    assert_eq!(accounts[0].id, id);
    assert!(!accounts[0].can_switch);
    assert_eq!(accounts[0].switch_block_reason, Some("occupancy_unknown"));
}
#[test]
fn duplicate_real_identity_and_mismatched_relogin_never_replace_saved_account() {
    let f = Fixture::new(true);
    let a = f.create("First");
    let b = f.create("Second");
    assert_eq!(f.login(&a).phase, "verified");
    let before = std::fs::read(f.paths.vault_root.join("accounts.dpapi")).unwrap();
    assert_eq!(f.login(&b).error_code, Some("account_already_exists"));
    assert_eq!(
        std::fs::read(f.paths.vault_root.join("accounts.dpapi")).unwrap(),
        before
    );
    *f.runtime.subject.lock().unwrap() = "different".into();
    assert_eq!(f.login(&a).error_code, Some("identity_mismatch"));
    assert_eq!(
        std::fs::read(f.paths.vault_root.join("accounts.dpapi")).unwrap(),
        before
    );
    assert_eq!(f.auth(), f.before);
}
#[test]
fn cancel_login_blocks_late_save_and_keeps_second_attempt_possible() {
    let f = Fixture::new(true);
    let id = f.create("Cancel");
    f.runtime.wait_login.store(true, Ordering::SeqCst);
    let attempt = f.manager.begin_account_login(id.clone()).unwrap();
    assert_eq!(
        f.manager.begin_account_login(id.clone()).unwrap_err().code,
        "login_in_progress"
    );
    assert_eq!(
        f.manager
            .cancel_account_login(&attempt.attempt_id)
            .unwrap()
            .phase,
        "cancelling"
    );
    assert_eq!(f.finish(&attempt.attempt_id).phase, "cancelled");
    assert_eq!(
        f.manager.list_managed_accounts().unwrap()[0].login_state,
        "signed_out"
    );
    f.runtime.wait_login.store(false, Ordering::SeqCst);
    assert_eq!(f.login(&id).phase, "verified");
    assert_eq!(f.auth(), f.before);
}
#[test]
fn switch_is_two_phase_rechecks_target_and_commits_verified_identity_only() {
    let f = Fixture::new(true);
    let id = f.create("Switch");
    assert_eq!(f.login(&id).phase, "verified");
    let ticket = f.ready(&id);
    assert_eq!(f.auth(), f.before);
    assert_eq!(f.gate.held.load(Ordering::SeqCst), 1);
    assert_eq!(
        f.manager.commit_account_switch(&ticket).unwrap().phase,
        "committed"
    );
    assert_eq!(f.auth(), credential("chosen"));
    assert!(!f.paths.vault_root.join("switch-journal.dpapi").exists());
    assert_eq!(f.gate.held.load(Ordering::SeqCst), 0);
    assert_eq!(
        f.manager.list_managed_accounts().unwrap()[0].active_state,
        "verified"
    );
    assert_eq!(
        f.manager.commit_account_switch(&ticket).unwrap_err().code,
        "switch_ticket_invalid"
    );
}
#[test]
fn unknown_busy_or_changed_target_cannot_mutate_target() {
    let mut f = Fixture::new(true);
    let id = f.create("Gates");
    assert_eq!(f.login(&id).phase, "verified");
    f.manager = AccountManager::with_components(
        f.paths.clone(),
        f.protector.clone(),
        f.runtime.clone(),
        None,
    )
    .unwrap();
    assert_eq!(
        f.manager
            .prepare_account_switch(id.clone())
            .unwrap()
            .reason_code,
        Some("occupancy_unknown")
    );
    f.manager.install_occupancy_gate(f.gate.clone()).unwrap();
    f.runtime.idle.store(false, Ordering::SeqCst);
    assert_eq!(
        f.manager
            .prepare_account_switch(id.clone())
            .unwrap()
            .reason_code,
        Some("account_busy")
    );
    assert_eq!(f.auth(), f.before);
    f.runtime.idle.store(true, Ordering::SeqCst);
    let ticket = f.ready(&id);
    std::fs::write(
        f.paths.system_home.join("auth.json"),
        credential("external"),
    )
    .unwrap();
    assert_eq!(
        f.manager.commit_account_switch(&ticket).unwrap_err().code,
        "target_changed"
    );
    assert_eq!(f.auth(), credential("external"));
}
#[test]
fn changing_configuration_or_occupied_ticket_fails_before_target_write() {
    let f = Fixture::new(true);
    let id = f.create("Config");
    assert_eq!(f.login(&id).phase, "verified");
    let ticket = f.ready(&id);
    std::fs::write(
        f.paths.system_home.join("config.toml"),
        "model_provider='custom'\n",
    )
    .unwrap();
    assert_eq!(
        f.manager.commit_account_switch(&ticket).unwrap_err().code,
        "target_auth_route_unsupported"
    );
    assert_eq!(f.auth(), f.before);
    std::fs::write(
        f.paths.system_home.join("config.toml"),
        "model_provider='openai'\n",
    )
    .unwrap();
    let ticket = f.ready(&id);
    f.gate.busy.store(true, Ordering::SeqCst);
    assert_eq!(
        f.manager.commit_account_switch(&ticket).unwrap_err().code,
        "occupancy_unknown"
    );
    assert_eq!(f.auth(), f.before);
}
#[test]
fn cancelled_ticket_releases_maintenance_without_target_io() {
    let f = Fixture::new(true);
    let id = f.create("Cancel switch");
    assert_eq!(f.login(&id).phase, "verified");
    let ticket = f.ready(&id);
    assert_eq!(
        f.manager.cancel_account_switch(&ticket).unwrap().phase,
        "cancelled"
    );
    assert_eq!(f.auth(), f.before);
    assert_eq!(f.gate.held.load(Ordering::SeqCst), 0);
    assert_eq!(
        f.manager.commit_account_switch(&ticket).unwrap_err().code,
        "switch_ticket_invalid"
    );
}
#[test]
fn postwrite_verification_failure_rolls_back_prior_auth_and_preserves_config() {
    let f = Fixture::new(true);
    let id = f.create("Rollback");
    assert_eq!(f.login(&id).phase, "verified");
    let ticket = f.ready(&id);
    let config = std::fs::read(f.paths.system_home.join("config.toml")).unwrap();
    f.runtime.fail_target.store(true, Ordering::SeqCst);
    assert_eq!(
        f.manager.commit_account_switch(&ticket).unwrap_err().code,
        "verification_failed"
    );
    assert_eq!(f.auth(), f.before);
    assert_eq!(
        std::fs::read(f.paths.system_home.join("config.toml")).unwrap(),
        config
    );
    assert!(!f.paths.vault_root.join("switch-journal.dpapi").exists());
}
#[test]
fn failed_vault_save_after_target_verification_rolls_back_target() {
    let f = Fixture::new(true);
    let id = f.create("Save failure");
    assert_eq!(f.login(&id).phase, "verified");
    let ticket = f.ready(&id);
    *f.runtime.fail_seal_after_target.lock().unwrap() = Some(f.protector.clone());
    assert_eq!(
        f.manager.commit_account_switch(&ticket).unwrap_err().code,
        "fixture_seal_failed"
    );
    assert_eq!(f.auth(), f.before);
    assert!(!f.paths.vault_root.join("switch-journal.dpapi").exists());
}
#[test]
fn external_writer_is_preserved_and_pending_journal_requires_gated_recovery() {
    let f = Fixture::new(true);
    let id = f.create("External writer");
    assert_eq!(f.login(&id).phase, "verified");
    let ticket = f.ready(&id);
    f.runtime.foreign_target.store(true, Ordering::SeqCst);
    assert_eq!(
        f.manager.commit_account_switch(&ticket).unwrap_err().code,
        "recovery_required"
    );
    assert_eq!(f.auth(), credential("external"));
    assert!(f.manager.list_managed_accounts().unwrap()[0].recovery_required);
    assert_eq!(
        f.manager
            .create_managed_account("Blocked".into(), "codex".into())
            .unwrap_err()
            .code,
        "recovery_required"
    );
    let reopened = AccountManager::with_components(
        f.paths.clone(),
        f.protector.clone(),
        f.runtime.clone(),
        None,
    )
    .unwrap();
    assert_eq!(
        reopened.recover_pending_switch().unwrap_err().code,
        "occupancy_unknown"
    );
    reopened.install_occupancy_gate(f.gate.clone()).unwrap();
    assert_eq!(
        reopened.recover_pending_switch().unwrap().unwrap().phase,
        "external_change_preserved"
    );
    assert_eq!(f.auth(), credential("external"));
}
#[test]
fn prewrite_late_gate_failure_clears_unwritten_intent_without_mutating_target() {
    let f = Fixture::new(true);
    let id = f.create("Late gate");
    assert_eq!(f.login(&id).phase, "verified");
    // acquire-check, prepared-check, initial commit-check, durable-intent-check.
    f.gate.fail_at.store(4, Ordering::SeqCst);
    let ticket = f.ready(&id);
    assert_eq!(
        f.manager.commit_account_switch(&ticket).unwrap_err().code,
        "occupancy_unknown"
    );
    assert_eq!(f.auth(), f.before);
    assert!(!f.paths.vault_root.join("switch-journal.dpapi").exists());
}
#[test]
fn isolated_official_refresh_updates_evidence_without_touching_system_and_excludes_switch() {
    let f = Fixture::new(true);
    let id = f.create("Refresh");
    assert_eq!(f.login(&id).phase, "verified");
    let proof = f.manager.verified_credential_snapshot(&id, 45).unwrap();
    let generation = proof.token_generation;
    // Advance only the persisted official evidence timestamp, not wall clock
    // or real account state. Refresh must not rely on an always-fresh fixture.
    let path = f.paths.vault_root.join("accounts.dpapi");
    let raw = f
        .protector
        .unseal(
            "AiGoodBro.Next.Windows.accounts.v1",
            &std::fs::read(&path).unwrap(),
        )
        .unwrap();
    let mut vault: Value = serde_json::from_slice(&raw).unwrap();
    vault["accounts"][0]["credential"]["observed_at"] = json!(chrono::Utc::now().timestamp() - 46);
    let sealed = f
        .protector
        .seal(
            "AiGoodBro.Next.Windows.accounts.v1",
            &serde_json::to_vec(&vault).unwrap(),
        )
        .unwrap();
    std::fs::write(&path, sealed).unwrap();
    assert_eq!(
        f.manager
            .verified_credential_snapshot(&id, 45)
            .err()
            .unwrap()
            .code,
        "evidence_stale"
    );
    assert_eq!(
        f.manager
            .prepare_proxy_desktop_home(&id, &f.claim(&id))
            .err()
            .unwrap()
            .code,
        "evidence_stale"
    );
    let display = f.manager.cached_quota_snapshot(&id).unwrap().unwrap();
    assert!(display.observed_at < chrono::Utc::now().timestamp() - 45);
    assert_eq!(display.plan.as_deref(), Some("plus"));
    assert_eq!(
        display.official_quota["rateLimits"]["primary"]["usedPercent"],
        10
    );
    // Display provenance can persist; admission freshness must not be relaxed.
    assert_eq!(
        f.manager.list_managed_accounts().unwrap()[0]
            .plan_type
            .as_deref(),
        Some("plus")
    );
    let refreshed = f.manager.refresh_managed_credential(&id).unwrap();
    assert_eq!(refreshed.token_generation, generation);
    assert!(f.runtime.verify_calls.load(Ordering::SeqCst) > 0);
    assert_eq!(f.auth(), f.before);
    let ticket = f.ready(&id);
    assert_eq!(
        f.manager
            .refresh_managed_credential(&id)
            .err()
            .unwrap()
            .code,
        "switch_in_progress"
    );
    f.manager.cancel_account_switch(&ticket).unwrap();
    refreshed.with_secret(|token, account| {
        assert!(!token.is_empty());
        assert_eq!(account, "workspace-chosen");
    });
}

#[test]
fn proxy_desktop_home_copies_verified_full_auth_without_system_or_store_lock_lifetime() {
    let f = Fixture::new(true);
    let id = f.create("Desktop");
    assert_eq!(f.login(&id).phase, "verified");
    let proof = f.manager.verified_credential_snapshot(&id, 45).unwrap();
    let mut guard = f
        .manager
        .prepare_proxy_desktop_home(&id, &f.claim(&id))
        .unwrap();
    let path = guard.path().to_owned();
    assert!(path.starts_with(f.paths.vault_root.join("desktop")));
    assert_ne!(path, f.paths.system_home);
    assert_eq!(guard.profile_id(), id);
    assert_eq!(guard.identity_hash(), proof.identity_hash);
    assert_eq!(guard.token_generation(), proof.token_generation);
    assert_eq!(
        std::fs::read(path.join("auth.json")).unwrap(),
        credential("chosen")
    );
    assert_eq!(f.manager.load_secret("proxy.client_key").unwrap(), None);
    assert_eq!(f.auth(), f.before);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o077,
            0
        );
        assert_eq!(
            std::fs::metadata(path.join("auth.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o077,
            0
        );
    }
    f.manager
        .finalize_desktop_after_exit(&mut guard, &f.claim(&id))
        .unwrap();
    assert!(path.exists());
    assert!(path.join("writer-claim.dpapi").exists());
    f.manager
        .complete_desktop_writer_release(&mut guard, &f.claim(&id))
        .unwrap();
    assert!(!path.join("writer-claim.dpapi").exists());
}

#[test]
fn unknown_desktop_exit_retains_private_home_and_switch_or_login_excludes_preparation() {
    let f = Fixture::new(true);
    let id = f.create("Desktop retention");
    assert_eq!(f.login(&id).phase, "verified");
    let mut guard = f
        .manager
        .prepare_proxy_desktop_home(&id, &f.claim(&id))
        .unwrap();
    let path = guard.path().to_owned();
    drop(guard); // Deliberately no false claim that an owned Job exited.
    assert!(path.join("auth.json").is_file());
    let ticket = f.ready(&id);
    assert_eq!(
        f.manager
            .prepare_proxy_desktop_home(&id, &f.claim(&id))
            .err()
            .unwrap()
            .code,
        "switch_in_progress"
    );
    f.manager.cancel_account_switch(&ticket).unwrap();
    f.runtime.wait_login.store(true, Ordering::SeqCst);
    let attempt = f.manager.begin_account_login(id.clone()).unwrap();
    assert_eq!(
        f.manager
            .prepare_proxy_desktop_home(&id, &f.claim(&id))
            .err()
            .unwrap()
            .code,
        "login_in_progress"
    );
    f.manager.cancel_account_login(&attempt.attempt_id).unwrap();
    assert_eq!(f.finish(&attempt.attempt_id).phase, "cancelled");
    f.runtime.idle.store(false, Ordering::SeqCst);
    assert_eq!(
        f.manager.require_codex_system_idle().unwrap_err().code,
        "account_busy"
    );
    assert_eq!(f.auth(), f.before);
    // Fixture root owns every retained byte; it removes this synthetic home.
}

#[test]
fn desktop_cleanup_removes_only_fixed_secrets_and_preserves_new_user_history() {
    let f = Fixture::new(true);
    let id = f.create("History retention");
    assert_eq!(f.login(&id).phase, "verified");
    let mut guard = f
        .manager
        .prepare_proxy_desktop_home(&id, &f.claim(&id))
        .unwrap();
    let path = guard.path().to_owned();
    std::fs::create_dir(path.join("sessions")).unwrap();
    std::fs::write(
        path.join("sessions/fixture-rollout.jsonl"),
        b"synthetic user history",
    )
    .unwrap();
    std::fs::write(
        path.join("desktop-connection.json"),
        b"synthetic client key",
    )
    .unwrap();
    std::fs::write(path.join("connection.json"), b"unknown user file").unwrap();
    let receipt = f
        .manager
        .finalize_desktop_after_exit(&mut guard, &f.claim(&id))
        .unwrap();
    assert_eq!(receipt.retained_home.as_deref(), Some(path.as_path()));
    assert!(path.join("sessions/fixture-rollout.jsonl").is_file());
    assert!(path.join("connection.json").is_file());
    assert!(!path.join("desktop-connection.json").exists());
    for name in ["auth.json", "config.toml"] {
        assert!(path.join(name).exists());
    }
    assert_eq!(f.auth(), f.before);
}

#[test]
fn unconfirmed_login_cleanup_retains_private_home_and_blocks_all_new_work() {
    let f = Fixture::new(true);
    let id = f.create("Unknown child");
    f.runtime
        .unknown_login_cleanup
        .store(true, Ordering::SeqCst);
    let attempt = f.manager.begin_account_login(id.clone()).unwrap();
    assert_eq!(
        f.finish(&attempt.attempt_id).error_code,
        Some("cleanup_unconfirmed")
    );
    assert!(f.manager.has_inflight_operation());
    assert!(std::fs::read_dir(f.paths.vault_root.join("staging"))
        .unwrap()
        .next()
        .is_some());
    assert_eq!(
        f.manager.begin_account_login(id).unwrap_err().code,
        "cleanup_unconfirmed"
    );
    assert!(f.manager.list_managed_accounts().unwrap()[0].recovery_required);
    f.manager.cancel_inflight_for_exit();
    assert!(f.manager.has_inflight_operation());
    assert_eq!(f.auth(), f.before);
}

#[test]
fn exit_seals_prepared_switch_without_clearing_intent_or_waiting_on_children() {
    let f = Fixture::new(true);
    let id = f.create("Exit");
    assert_eq!(f.login(&id).phase, "verified");
    let ticket = f.ready(&id);
    assert!(f.manager.has_inflight_operation());
    f.manager.cancel_inflight_for_exit();
    assert_eq!(
        f.manager.commit_account_switch(&ticket).unwrap_err().code,
        "account_service_exiting"
    );
    assert_eq!(
        f.manager.begin_account_login(id).unwrap_err().code,
        "account_service_exiting"
    );
    assert!(f.manager.has_inflight_operation());
    assert_eq!(f.auth(), f.before);
}

#[test]
fn desktop_snapshot_is_pure_digest_bound_and_rejects_stale_or_wrong_backend_tuple() {
    use sha2::{Digest, Sha256};
    let f = Fixture::new(true);
    let id = f.create("Desktop evidence");
    assert_eq!(f.login(&id).phase, "verified");
    let claim = f.claim(&id);
    let mut home = f.manager.prepare_proxy_desktop_home(&id, &claim).unwrap();
    let before = std::fs::read(f.paths.vault_root.join("accounts.dpapi")).unwrap();
    let calls = f.runtime.verify_calls.load(Ordering::SeqCst);
    let auth = std::fs::read(home.path().join("auth.json")).unwrap();
    let mut proof = codexu_core::proxy::DesktopQuotaEvidence {
        writer_id: claim.writer_id.clone(),
        proxy_run_id: claim.proxy_run_id.clone(),
        backend_id: "33333333333333333333333333333333".into(),
        observed_at: chrono::Utc::now().timestamp() as f64,
        auth_digest: format!("{:x}", Sha256::digest(&auth)),
        account: json!({"account":{"type":"chatgpt","email":"chosen@fixture.invalid","planType":"plus"}}),
        rate_limits: json!({"rateLimits":{"planType":"plus","primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":chrono::Utc::now().timestamp()+3600}}}),
    };
    let snapshot = f
        .manager
        .read_current_desktop_snapshot(&claim, &proof)
        .unwrap();
    assert_eq!(snapshot.identity_hash, claim.identity_hash);
    assert_eq!(snapshot.token_generation, proof.auth_digest[..32]);
    assert_eq!(f.runtime.verify_calls.load(Ordering::SeqCst), calls);
    assert_eq!(
        std::fs::read(f.paths.vault_root.join("accounts.dpapi")).unwrap(),
        before
    );
    proof.observed_at -= 46.0;
    assert_eq!(
        f.manager
            .read_current_desktop_snapshot(&claim, &proof)
            .err()
            .unwrap()
            .code,
        "evidence_stale"
    );
    proof.observed_at += 46.0;
    proof.proxy_run_id = "44444444444444444444444444444444".into();
    assert!(f
        .manager
        .read_current_desktop_snapshot(&claim, &proof)
        .is_err());
    proof.proxy_run_id = claim.proxy_run_id.clone();
    proof.auth_digest = "0".repeat(64);
    assert_eq!(
        f.manager
            .read_current_desktop_snapshot(&claim, &proof)
            .err()
            .unwrap()
            .code,
        "desktop_auth_changed"
    );
    f.manager
        .finalize_desktop_after_exit(&mut home, &claim)
        .unwrap();
    let calls = f.runtime.verify_calls.load(Ordering::SeqCst);
    f.manager
        .finalize_desktop_after_exit(&mut home, &claim)
        .unwrap();
    assert_eq!(f.runtime.verify_calls.load(Ordering::SeqCst), calls);
    f.manager
        .complete_desktop_writer_release(&mut home, &claim)
        .unwrap();
    f.manager
        .complete_desktop_writer_release(&mut home, &claim)
        .unwrap();
    assert!(home.path().join("auth.json").exists());
    assert_eq!(f.auth(), f.before);
}

#[test]
fn credential_write_fence_blocks_private_refresh_login_and_switch_before_official_io() {
    let f = Fixture::new(true);
    let id = f.create("Writer fence");
    assert_eq!(f.login(&id).phase, "verified");
    f.gate.writer_busy.store(true, Ordering::SeqCst);
    let before = f.runtime.verify_calls.load(Ordering::SeqCst);
    assert_eq!(
        f.manager
            .refresh_managed_credential(&id)
            .err()
            .unwrap()
            .code,
        "desktop_writer_active"
    );
    let dto = f.manager.prepare_account_switch(id.clone()).unwrap();
    assert_eq!(dto.reason_code, Some("desktop_writer_active"));
    assert_eq!(
        f.manager.begin_account_login(id.clone()).unwrap_err().code,
        "desktop_writer_active"
    );
    assert_eq!(f.runtime.verify_calls.load(Ordering::SeqCst), before);
    assert_eq!(
        f.manager.managed_identity_hash(&id).unwrap(),
        Some(
            AccountIdentity::from_auth(&credential("chosen"))
                .unwrap()
                .identity_hash()
        )
    );
    assert!(f.manager.cached_quota_snapshot(&id).unwrap().is_some());
    assert_eq!(f.auth(), f.before);
}

#[test]
fn persistent_desktop_home_reuses_history_and_rejects_unimported_or_unknown_grant() {
    let f = Fixture::new(true);
    let id = f.create("Persistent desktop");
    assert_eq!(f.login(&id).phase, "verified");
    let claim = f.claim(&id);
    let mut first = f.manager.prepare_proxy_desktop_home(&id, &claim).unwrap();
    let path = first.path().to_owned();
    std::fs::write(path.join("fixture-rollout.jsonl"), b"synthetic history").unwrap();
    f.manager
        .finalize_desktop_after_exit(&mut first, &claim)
        .unwrap();
    f.manager
        .complete_desktop_writer_release(&mut first, &claim)
        .unwrap();
    let mut second = f.manager.prepare_proxy_desktop_home(&id, &claim).unwrap();
    assert_eq!(second.path(), path);
    assert_eq!(
        std::fs::read(path.join("fixture-rollout.jsonl")).unwrap(),
        b"synthetic history"
    );
    assert_eq!(
        f.manager
            .prepare_proxy_desktop_home(&id, &claim)
            .err()
            .unwrap()
            .code,
        "desktop_writer_recovery_required"
    );
    f.manager
        .finalize_desktop_after_exit(&mut second, &claim)
        .unwrap();
    f.manager
        .complete_desktop_writer_release(&mut second, &claim)
        .unwrap();
    // A later verified vault rotation may update only an exact known inactive
    // home grant. Unknown current home bytes remain protected below.
    let vault = f.paths.vault_root.join("accounts.dpapi");
    let mut value: Value = serde_json::from_slice(
        &f.protector
            .unseal(
                "AiGoodBro.Next.Windows.accounts.v1",
                &std::fs::read(&vault).unwrap(),
            )
            .unwrap(),
    )
    .unwrap();
    let mut updated: Value = serde_json::from_slice(&credential("chosen")).unwrap();
    updated["tokens"]["refresh_token"] = json!("synthetic-rotated-refresh");
    let updated = serde_json::to_vec(&updated).unwrap();
    value["accounts"][0]["credential"]["auth"] = json!(updated);
    value["accounts"][0]["credential"]["generation"] = json!("55555555555555555555555555555555");
    std::fs::write(
        &vault,
        f.protector
            .seal(
                "AiGoodBro.Next.Windows.accounts.v1",
                &serde_json::to_vec(&value).unwrap(),
            )
            .unwrap(),
    )
    .unwrap();
    let next = f.claim(&id);
    let mut third = f.manager.prepare_proxy_desktop_home(&id, &next).unwrap();
    assert_eq!(std::fs::read(path.join("auth.json")).unwrap(), updated);
    f.manager
        .finalize_desktop_after_exit(&mut third, &next)
        .unwrap();
    f.manager
        .complete_desktop_writer_release(&mut third, &next)
        .unwrap();
    std::fs::write(path.join("auth.json"), credential("external")).unwrap();
    assert_eq!(
        f.manager
            .prepare_proxy_desktop_home(&id, &f.claim(&id))
            .err()
            .unwrap()
            .code,
        "desktop_auth_changed"
    );
    assert_eq!(
        std::fs::read(path.join("auth.json")).unwrap(),
        credential("external")
    );
    assert_eq!(f.auth(), f.before);
}

#[test]
fn positively_unlaunched_desktop_abort_cleans_only_owned_marker_and_keeps_history() {
    let f = Fixture::new(true);
    let id = f.create("Unlaunched abort");
    assert_eq!(f.login(&id).phase, "verified");
    let claim = f.claim(&id);
    let home = f.manager.prepare_proxy_desktop_home(&id, &claim).unwrap();
    let path = home.path().to_owned();
    std::fs::write(path.join("fixture-rollout.jsonl"), b"synthetic history").unwrap();
    drop(home);
    f.gate.writer_busy.store(true, Ordering::SeqCst);
    assert!(f
        .manager
        .abandon_unlaunched_desktop_prepare(&claim)
        .is_err());
    assert!(path.join("writer-claim.dpapi").exists());
    f.gate.writer_busy.store(false, Ordering::SeqCst);
    f.manager
        .abandon_unlaunched_desktop_prepare(&claim)
        .unwrap();
    assert!(!path.join("writer-claim.dpapi").exists());
    assert!(path.join("fixture-rollout.jsonl").exists());
    assert!(path.join("auth.json").exists());
    assert_eq!(f.auth(), f.before);
}

#[test]
fn recovery_reconstructs_only_gate_authorized_exact_private_home_without_official_io() {
    let f = Fixture::new(true);
    let id = f.create("Recovery guard");
    assert_eq!(f.login(&id).phase, "verified");
    let claim = f.claim(&id);
    let home = f.manager.prepare_proxy_desktop_home(&id, &claim).unwrap();
    let path = home.path().to_owned();
    drop(home);
    std::fs::write(path.join("fixture-rollout.jsonl"), b"synthetic history").unwrap();
    let auth = std::fs::read(path.join("auth.json")).unwrap();
    let vault = std::fs::read(f.paths.vault_root.join("accounts.dpapi")).unwrap();
    let calls = f.runtime.verify_calls.load(Ordering::SeqCst);
    f.gate.writer_busy.store(true, Ordering::SeqCst);
    assert_eq!(
        f.manager
            .reconstruct_desktop_home_for_recovery(&claim)
            .err()
            .unwrap()
            .code,
        "desktop_writer_active"
    );
    assert!(path.join("writer-claim.dpapi").exists());
    f.gate.writer_busy.store(false, Ordering::SeqCst);
    let mut recovered = f
        .manager
        .reconstruct_desktop_home_for_recovery(&claim)
        .unwrap();
    assert_eq!(recovered.path(), path);
    assert_eq!(f.runtime.verify_calls.load(Ordering::SeqCst), calls);
    assert_eq!(std::fs::read(path.join("auth.json")).unwrap(), auth);
    assert_eq!(
        std::fs::read(f.paths.vault_root.join("accounts.dpapi")).unwrap(),
        vault
    );
    f.manager
        .finalize_desktop_after_exit(&mut recovered, &claim)
        .unwrap();
    f.manager
        .complete_desktop_writer_release(&mut recovered, &claim)
        .unwrap();
    assert!(path.join("fixture-rollout.jsonl").exists());
    assert_eq!(f.auth(), f.before);
}

#[test]
fn recovery_guard_rejects_forged_claim_changed_identity_or_missing_marker() {
    let f = Fixture::new(true);
    let id = f.create("Recovery negative");
    assert_eq!(f.login(&id).phase, "verified");
    let claim = f.claim(&id);
    let home = f.manager.prepare_proxy_desktop_home(&id, &claim).unwrap();
    let path = home.path().to_owned();
    drop(home);
    let marker = std::fs::read(path.join("writer-claim.dpapi")).unwrap();
    let mut wrong = claim.clone();
    wrong.writer_id = "66666666666666666666666666666666".into();
    assert_eq!(
        f.manager
            .reconstruct_desktop_home_for_recovery(&wrong)
            .err()
            .unwrap()
            .code,
        "desktop_writer_recovery_required"
    );
    wrong = claim.clone();
    wrong.initial_generation = "77777777777777777777777777777777".into();
    assert!(f
        .manager
        .reconstruct_desktop_home_for_recovery(&wrong)
        .is_err());
    std::fs::write(path.join("auth.json"), credential("external")).unwrap();
    assert_eq!(
        f.manager
            .reconstruct_desktop_home_for_recovery(&claim)
            .err()
            .unwrap()
            .code,
        "identity_mismatch"
    );
    assert_eq!(
        std::fs::read(path.join("writer-claim.dpapi")).unwrap(),
        marker
    );
    std::fs::write(path.join("auth.json"), credential("chosen")).unwrap();
    std::fs::remove_file(path.join("writer-claim.dpapi")).unwrap();
    assert_eq!(
        f.manager
            .reconstruct_desktop_home_for_recovery(&claim)
            .err()
            .unwrap()
            .code,
        "desktop_writer_recovery_required"
    );
    assert_eq!(f.auth(), f.before);
}

fn edit_encrypted_fixture_json(
    protector: &FixtureProtector,
    path: &Path,
    context: &str,
    edit: impl FnOnce(&mut Value),
) {
    let mut value: Value = serde_json::from_slice(
        &protector
            .unseal(context, &std::fs::read(path).unwrap())
            .unwrap(),
    )
    .unwrap();
    edit(&mut value);
    std::fs::write(
        path,
        protector
            .seal(context, &serde_json::to_vec(&value).unwrap())
            .unwrap(),
    )
    .unwrap();
}

#[test]
fn retired_writer_cleanup_closes_release_crash_after_reopen_without_auth_or_history_io() {
    let f = Fixture::new(true);
    let id = f.create("Retired crash");
    assert_eq!(f.login(&id).phase, "verified");
    let claim = f.claim(&id);
    let mut home = f.manager.prepare_proxy_desktop_home(&id, &claim).unwrap();
    let path = home.path().to_owned();
    std::fs::write(path.join("synthetic-rollout.jsonl"), b"retained history").unwrap();
    f.manager
        .finalize_desktop_after_exit(&mut home, &claim)
        .unwrap();
    assert!(path.join("writer-claim.dpapi").exists());
    assert!(path.join("finalized-writer.dpapi").exists());
    // Registry release succeeded; process is lost before complete is called.
    drop(home);
    let reopened = AccountManager::with_components(
        f.paths.clone(),
        f.protector.clone(),
        f.runtime.clone(),
        Some(f.gate.clone()),
    )
    .unwrap();
    let auth = std::fs::read(path.join("auth.json")).unwrap();
    let vault = std::fs::read(f.paths.vault_root.join("accounts.dpapi")).unwrap();
    let calls = f.runtime.verify_calls.load(Ordering::SeqCst);
    std::fs::write(
        path.join("desktop-connection.json"),
        b"synthetic connection",
    )
    .unwrap();
    assert!(reopened.complete_retired_desktop_writer(&id).unwrap());
    assert!(!path.join("writer-claim.dpapi").exists());
    assert!(!path.join("finalized-writer.dpapi").exists());
    assert!(!path.join("desktop-connection.json").exists());
    assert!(!reopened.complete_retired_desktop_writer(&id).unwrap());
    assert_eq!(std::fs::read(path.join("auth.json")).unwrap(), auth);
    assert_eq!(
        std::fs::read(path.join("synthetic-rollout.jsonl")).unwrap(),
        b"retained history"
    );
    assert_eq!(
        std::fs::read(f.paths.vault_root.join("accounts.dpapi")).unwrap(),
        vault
    );
    assert_eq!(f.runtime.verify_calls.load(Ordering::SeqCst), calls);
    assert_eq!(f.auth(), f.before);
}

#[test]
fn retired_writer_cleanup_rejects_missing_or_mismatched_writer_proof_even_for_same_grant() {
    for variant in ["missing", "writer", "marker_digest", "auth_digest"] {
        let f = Fixture::new(true);
        let id = f.create("Retired proof negative");
        assert_eq!(f.login(&id).phase, "verified");
        let claim = f.claim(&id);
        let mut home = f.manager.prepare_proxy_desktop_home(&id, &claim).unwrap();
        let path = home.path().to_owned();
        f.manager
            .finalize_desktop_after_exit(&mut home, &claim)
            .unwrap();
        let receipt = path.join("finalized-writer.dpapi");
        if variant == "missing" {
            std::fs::remove_file(&receipt).unwrap();
        } else {
            edit_encrypted_fixture_json(
                &f.protector,
                &receipt,
                "AiGoodBro.Next.Windows.desktop-finalized-writer.v1",
                |value| {
                    value[variant] = json!(if variant == "writer" {
                        "66666666666666666666666666666666"
                    } else {
                        "0000000000000000000000000000000000000000000000000000000000000000"
                    })
                },
            );
        }
        let marker = std::fs::read(path.join("writer-claim.dpapi")).unwrap();
        let auth = std::fs::read(path.join("auth.json")).unwrap();
        assert!(
            f.manager.complete_retired_desktop_writer(&id).is_err(),
            "{variant}"
        );
        assert_eq!(
            std::fs::read(path.join("writer-claim.dpapi")).unwrap(),
            marker
        );
        assert_eq!(std::fs::read(path.join("auth.json")).unwrap(), auth);
        assert_eq!(f.auth(), f.before);
    }
}

#[test]
fn retired_writer_cleanup_rejects_a_new_vault_generation_or_changed_auth() {
    for variant in ["generation", "auth"] {
        let f = Fixture::new(true);
        let id = f.create("Retired grant negative");
        assert_eq!(f.login(&id).phase, "verified");
        let claim = f.claim(&id);
        let mut home = f.manager.prepare_proxy_desktop_home(&id, &claim).unwrap();
        let path = home.path().to_owned();
        f.manager
            .finalize_desktop_after_exit(&mut home, &claim)
            .unwrap();
        if variant == "generation" {
            edit_encrypted_fixture_json(
                &f.protector,
                &f.paths.vault_root.join("accounts.dpapi"),
                "AiGoodBro.Next.Windows.accounts.v1",
                |value| {
                    value["accounts"][0]["credential"]["generation"] =
                        json!("77777777777777777777777777777777")
                },
            );
        } else {
            let mut auth: Value = serde_json::from_slice(&credential("chosen")).unwrap();
            auth["tokens"]["refresh_token"] = json!("synthetic-new-unknown-grant");
            std::fs::write(path.join("auth.json"), serde_json::to_vec(&auth).unwrap()).unwrap();
        }
        let marker = std::fs::read(path.join("writer-claim.dpapi")).unwrap();
        assert_eq!(
            f.manager
                .complete_retired_desktop_writer(&id)
                .unwrap_err()
                .code,
            "desktop_auth_changed"
        );
        assert_eq!(
            std::fs::read(path.join("writer-claim.dpapi")).unwrap(),
            marker
        );
        assert!(path.join("finalized-writer.dpapi").exists());
        assert_eq!(f.auth(), f.before);
    }
}

#[test]
fn retired_writer_cleanup_requires_live_managed_lease_and_retains_proof_while_blocked() {
    let f = Fixture::new(true);
    let id = f.create("Retired busy gate");
    assert_eq!(f.login(&id).phase, "verified");
    let claim = f.claim(&id);
    let mut home = f.manager.prepare_proxy_desktop_home(&id, &claim).unwrap();
    let path = home.path().to_owned();
    f.manager
        .finalize_desktop_after_exit(&mut home, &claim)
        .unwrap();
    let marker = std::fs::read(path.join("writer-claim.dpapi")).unwrap();
    let receipt = std::fs::read(path.join("finalized-writer.dpapi")).unwrap();
    // A real registry uses this denial for any live same-identity alias writer.
    // This fixture verifies that AccountManager cannot bypass that decision.
    f.gate.writer_busy.store(true, Ordering::SeqCst);
    assert_eq!(
        f.manager
            .complete_retired_desktop_writer(&id)
            .unwrap_err()
            .code,
        "desktop_writer_active"
    );
    assert_eq!(
        std::fs::read(path.join("writer-claim.dpapi")).unwrap(),
        marker
    );
    assert_eq!(
        std::fs::read(path.join("finalized-writer.dpapi")).unwrap(),
        receipt
    );
    f.gate.writer_busy.store(false, Ordering::SeqCst);
    assert!(f.manager.complete_retired_desktop_writer(&id).unwrap());
    assert_eq!(f.auth(), f.before);
}

#[test]
fn retired_writer_cleanup_finishes_orphan_receipt_after_marker_delete_crash() {
    let f = Fixture::new(true);
    let id = f.create("Retired orphan receipt");
    assert_eq!(f.login(&id).phase, "verified");
    let claim = f.claim(&id);
    let mut home = f.manager.prepare_proxy_desktop_home(&id, &claim).unwrap();
    let path = home.path().to_owned();
    f.manager
        .finalize_desktop_after_exit(&mut home, &claim)
        .unwrap();
    std::fs::remove_file(path.join("writer-claim.dpapi")).unwrap();
    assert!(f.manager.complete_retired_desktop_writer(&id).unwrap());
    assert!(!path.join("finalized-writer.dpapi").exists());
    assert!(path.join("auth.json").exists());
    assert_eq!(f.auth(), f.before);
}

#[test]
fn real_managed_gate_allows_unrelated_refresh_during_live_lease_without_reentering_vault() {
    use codexu_core::{managed_proxy::ManagedProxyGate, proxy::*};
    let f = Fixture::new(true);
    let a = f.create("Actual gate A");
    assert_eq!(f.login(&a).phase, "verified");
    *f.runtime.subject.lock().unwrap() = "second".into();
    let b = f.create("Actual gate B");
    assert_eq!(f.login(&b).phase, "verified");
    // A legacy duplicate identity can exist in an encrypted catalogue even
    // though the current official login path rejects creating another alias.
    let alias = f.create("Legacy identity alias");
    edit_encrypted_fixture_json(
        &f.protector,
        &f.paths.vault_root.join("accounts.dpapi"),
        "AiGoodBro.Next.Windows.accounts.v1",
        |v| {
            let records = v["accounts"].as_array_mut().unwrap();
            // The existing account-only fixture has just the 5h window. Actual
            // proxy subscription admission additionally requires official 7d facts.
            for record in records.iter_mut().filter(|r| r["credential"].is_object()) {
                record["credential"]["quota"]["rateLimits"]["secondary"] = json!({"usedPercent":10,"windowDurationMins":10080,"resetsAt":chrono::Utc::now().timestamp()+86400});
            }
            let original = records.iter().find(|r| r["id"] == a).unwrap()["credential"].clone();
            records.iter_mut().find(|r| r["id"] == alias).unwrap()["credential"] = original;
        },
    );
    let gate = ManagedProxyGate::new(f._temp.path().join("actual-registry"), &f.manager).unwrap();
    f.manager.install_occupancy_gate(gate.clone()).unwrap();
    let run = "22222222222222222222222222222222";
    gate.activate_run(run).unwrap();
    let snapshot = f.manager.verified_credential_snapshot(&a, 45).unwrap();
    let now = chrono::Utc::now().timestamp_millis() as u64;
    let lease = gate
        .reserve(&AdmissionRequest {
            run_id: run.into(),
            request_id: "33333333333333333333333333333333".into(),
            profile_id: a.clone(),
            expected_identity_hash: snapshot.identity_hash,
            expected_generation: snapshot.token_generation,
            pass: AdmissionPass::Subscription,
            policy: AccountPolicy::default(),
            credit_floor: None,
            request_started_at_unix_ms: now,
            deadline_unix_ms: now + 18000,
        })
        .unwrap();
    let calls = f.runtime.verify_calls.load(Ordering::SeqCst);
    let refreshed = f
        .manager
        .refresh_managed_credential(&b)
        .expect("real writer recheck must not reenter the already held vault lock");
    assert_eq!(
        refreshed.identity_hash,
        AccountIdentity::from_auth(&credential("second"))
            .unwrap()
            .identity_hash()
    );
    assert_eq!(f.runtime.verify_calls.load(Ordering::SeqCst), calls + 1);
    let calls = f.runtime.verify_calls.load(Ordering::SeqCst);
    assert!(f.manager.refresh_managed_credential(&a).is_err());
    assert!(f.manager.refresh_managed_credential(&alias).is_err());
    assert_eq!(f.runtime.verify_calls.load(Ordering::SeqCst), calls);
    gate.release(&lease.tuple).unwrap();
    gate.retire_run(run, true).unwrap();
    assert_eq!(f.auth(), f.before);
}

#[test]
fn managed_history_catalog_never_opens_auth_or_returns_vault_staging_roots() {
    let f = Fixture::new(true);
    let id = f.create("History catalogue");
    assert_eq!(f.login(&id).phase, "verified");
    assert!(f.manager.managed_history_roots().unwrap().is_empty());
    let home = f
        .manager
        .prepare_proxy_desktop_home(&id, &f.claim(&id))
        .unwrap();
    std::fs::write(
        home.path().join("auth.json"),
        b"not auth: catalogue must not read this",
    )
    .unwrap();
    let roots = f.manager.managed_history_roots().unwrap();
    assert_eq!(roots, vec![(id, home.path().to_path_buf())]);
    assert_ne!(roots[0].1, f.paths.vault_root);
    assert!(!roots[0].1.ends_with("staging"));
    assert_eq!(f.auth(), f.before);
}

#[test]
fn real_managed_snapshot_queues_official_card_notifications_without_auth_or_network_on_caller() {
    use codexu_core::notifications::*;
    struct AcceptedSynthetic(AtomicUsize);
    impl NotificationTransport for AcceptedSynthetic {
        fn send(&self, r: &TransportRequest, _: &AtomicBool) -> Result<TransportResponse> {
            assert_eq!(r.endpoint().host_str(), Some("qyapi.weixin.qq.com"));
            let body = String::from_utf8_lossy(r.body());
            assert!(body.contains("24小时"));
            assert!(!body.contains("synthetic-backend-card-id"));
            self.0.fetch_add(1, Ordering::SeqCst);
            Ok(TransportResponse {
                status: 200,
                body: b"{\"errcode\":0}".to_vec(),
            })
        }
    }
    let f = Fixture::new(true);
    let id = f.create("Notification source");
    assert_eq!(f.login(&id).phase, "verified");
    let now = chrono::Utc::now().timestamp();
    edit_encrypted_fixture_json(
        &f.protector,
        &f.paths.vault_root.join("accounts.dpapi"),
        "AiGoodBro.Next.Windows.accounts.v1",
        |v| v["accounts"][0]["credential"]["quota"]["rateLimitResetCredits"] = json!({"availableCount":1,"credits":[{"id":"synthetic-backend-card-id","status":"available","resetType":"codexRateLimits","expiresAt":now+1000}]}),
    );
    let snapshot = f.manager.verified_credential_snapshot(&id, 45).unwrap();
    let transport = Arc::new(AcceptedSynthetic(AtomicUsize::new(0)));
    let service = NotificationService::with_components(
        f._temp.path().join("synthetic-notifications"),
        f.protector.clone(),
        transport.clone(),
    )
    .unwrap();
    service
        .save_channel(
            ChannelKind::WeCom,
            "11111111-2222-3333-4444-555555555555".into(),
            None,
        )
        .unwrap();
    service.set_enabled(ChannelKind::WeCom, true).unwrap();
    service.queue_managed_quota("Fixture", &snapshot).unwrap();
    assert_eq!(transport.0.load(Ordering::SeqCst), 0);
    let monitor = service.start_monitor().unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    while transport.0.load(Ordering::SeqCst) < 1 {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(5));
    }
    monitor.cancel();
    while !monitor.is_finished() {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(transport.0.load(Ordering::SeqCst), 1);
    assert_eq!(f.auth(), f.before);
}

#[test]
fn guarded_switch_cancellation_at_every_write_boundary_rolls_back_exactly() {
    struct Fence {
        calls: AtomicUsize,
        fail_at: usize,
        exit: bool,
        manager: Arc<AccountManager>,
    }
    impl SwitchCommitGuard for Fence {
        fn recheck(&self) -> AccountResult<()> {
            if self.calls.fetch_add(1, Ordering::SeqCst) + 1 == self.fail_at {
                if self.exit {
                    self.manager.cancel_inflight_for_exit();
                }
                Err(error("synthetic_policy_revoked"))
            } else {
                Ok(())
            }
        }
    }
    for at in 1..=5 {
        let f = Fixture::new(true);
        let id = f.create("Guarded cancellation");
        assert_eq!(f.login(&id).phase, "verified");
        let ticket = f.ready(&id);
        let vault = std::fs::read(f.paths.vault_root.join("accounts.dpapi")).unwrap();
        let guard = Fence {
            calls: AtomicUsize::new(0),
            fail_at: at,
            exit: at >= 4,
            manager: f.manager.clone(),
        };
        assert_eq!(
            f.manager
                .commit_account_switch_guarded(&ticket, &guard)
                .unwrap_err()
                .code,
            "switch_cancelled"
        );
        assert_eq!(f.auth(), f.before, "cancel boundary {at}");
        assert!(!f.paths.vault_root.join("switch-journal.dpapi").exists());
        assert_eq!(
            std::fs::read(f.paths.vault_root.join("accounts.dpapi")).unwrap(),
            vault
        );
        assert_eq!(f.gate.held.load(Ordering::SeqCst), 0);
    }
}

#[test]
fn managed_automation_keys_use_verified_email_group_and_workspace_only() {
    let f = Fixture::new(true);
    let id = f.create("Anonymous automation metadata");
    assert!(f.manager.managed_automation_keys(&id).unwrap().is_none());
    assert_eq!(f.login(&id).phase, "verified");
    let keys = f.manager.managed_automation_keys(&id).unwrap().unwrap();
    let other = f.create("Other workspace same email");
    edit_encrypted_fixture_json(
        &f.protector,
        &f.paths.vault_root.join("accounts.dpapi"),
        "AiGoodBro.Next.Windows.accounts.v1",
        |v| {
            let records = v["accounts"].as_array_mut().unwrap();
            let mut copied = records.iter().find(|r| r["id"] == id).unwrap()["credential"].clone();
            let jwt = claims(
                json!({"email":"chosen@fixture.invalid","account_id":"workspace-other-synthetic","exp":4_102_444_800i64}),
            );
            let auth=serde_json::to_vec(&json!({"tokens":{"access_token":jwt,"id_token":jwt,"refresh_token":"synthetic-refresh","account_id":"workspace-other-synthetic"}})).unwrap();
            copied["auth"] = json!(auth);
            copied["identity"][1] = json!("workspace-other-synthetic");
            records.iter_mut().find(|r| r["id"] == other).unwrap()["credential"] = copied;
        },
    );
    let other_keys = f.manager.managed_automation_keys(&other).unwrap().unwrap();
    assert_eq!(keys.0, other_keys.0);
    assert_ne!(keys.1, other_keys.1);
    assert_eq!(keys.0.len(), 64);
    assert_eq!(keys.1.len(), 64);
    assert_ne!(keys.0, keys.1);
    let identity = f.manager.managed_identity_hash(&id).unwrap().unwrap();
    assert_ne!(keys.0, identity);
    assert_ne!(keys.1, identity);
    assert!(!keys.0.contains("chosen"));
    assert_eq!(f.auth(), f.before);
}

struct CancelRotatedCommit {
    calls: AtomicUsize,
    fail_seal: Option<Arc<FixtureProtector>>,
}
impl SwitchCommitGuard for CancelRotatedCommit {
    fn recheck(&self) -> AccountResult<()> {
        if self.calls.fetch_add(1, Ordering::SeqCst) + 1 == 4 {
            if let Some(p) = &self.fail_seal {
                p.reject.store(true, Ordering::SeqCst);
            }
            Err(error("synthetic_cancel_after_official_rotation"))
        } else {
            Ok(())
        }
    }
}
fn stored_fixture_auth(f: &Fixture, id: &str) -> (Vec<u8>, Value) {
    let v: Value = serde_json::from_slice(
        &f.protector
            .unseal(
                "AiGoodBro.Next.Windows.accounts.v1",
                &std::fs::read(f.paths.vault_root.join("accounts.dpapi")).unwrap(),
            )
            .unwrap(),
    )
    .unwrap();
    let auth: Vec<u8> = serde_json::from_value(
        v["accounts"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["id"] == id)
            .unwrap()["credential"]["auth"]
            .clone(),
    )
    .unwrap();
    (auth, v["active"].clone())
}

#[test]
fn official_rotation_then_cancel_restores_system_and_preserves_successor_without_activation() {
    let f = Fixture::new(true);
    let id = f.create("Rotating cancelled switch");
    assert_eq!(f.login(&id).phase, "verified");
    let ticket = f.ready(&id);
    let (before, active) = stored_fixture_auth(&f, &id);
    f.runtime.rotate_target.store(true, Ordering::SeqCst);
    let guard = CancelRotatedCommit {
        calls: AtomicUsize::new(0),
        fail_seal: None,
    };
    assert_eq!(
        f.manager
            .commit_account_switch_guarded(&ticket, &guard)
            .unwrap_err()
            .code,
        "switch_cancelled"
    );
    assert_eq!(f.auth(), f.before);
    let (after, new_active) = stored_fixture_auth(&f, &id);
    assert_ne!(before, after);
    assert_eq!(
        serde_json::from_slice::<Value>(&after).unwrap()["tokens"]["refresh_token"],
        "synthetic-official-rotated-refresh"
    );
    assert_eq!(new_active, active);
    assert!(!f.paths.vault_root.join("switch-journal.dpapi").exists());
    assert!(f.manager.verified_credential_snapshot(&id, 45).is_ok());
}

#[test]
fn failed_successor_vault_save_keeps_journal_and_recovery_retries_exact_owned_rotation() {
    let f = Fixture::new(true);
    let id = f.create("Rotating save retry");
    assert_eq!(f.login(&id).phase, "verified");
    let ticket = f.ready(&id);
    let (old, active) = stored_fixture_auth(&f, &id);
    f.runtime.rotate_target.store(true, Ordering::SeqCst);
    let guard = CancelRotatedCommit {
        calls: AtomicUsize::new(0),
        fail_seal: Some(f.protector.clone()),
    };
    assert_eq!(
        f.manager
            .commit_account_switch_guarded(&ticket, &guard)
            .unwrap_err()
            .code,
        "recovery_required"
    );
    assert_eq!(f.auth(), f.before);
    assert!(f.paths.vault_root.join("switch-journal.dpapi").exists());
    assert_eq!(stored_fixture_auth(&f, &id).0, old);
    f.protector.reject.store(false, Ordering::SeqCst);
    let result = f.manager.recover_pending_switch().unwrap().unwrap();
    assert_eq!(result.phase, "rolled_back");
    let (new, new_active) = stored_fixture_auth(&f, &id);
    assert_ne!(new, old);
    assert_eq!(new_active, active);
    assert!(!f.paths.vault_root.join("switch-journal.dpapi").exists());
    assert_eq!(f.auth(), f.before);
}

#[test]
fn successor_recovery_rejects_changed_revision_or_wrong_identity_and_keeps_evidence() {
    for changed in ["revision", "identity"] {
        let f = Fixture::new(true);
        let id = f.create("Rotation CAS negative");
        assert_eq!(f.login(&id).phase, "verified");
        let ticket = f.ready(&id);
        f.runtime.rotate_target.store(true, Ordering::SeqCst);
        let guard = CancelRotatedCommit {
            calls: AtomicUsize::new(0),
            fail_seal: Some(f.protector.clone()),
        };
        assert_eq!(
            f.manager
                .commit_account_switch_guarded(&ticket, &guard)
                .unwrap_err()
                .code,
            "recovery_required"
        );
        f.protector.reject.store(false, Ordering::SeqCst);
        edit_encrypted_fixture_json(
            &f.protector,
            &f.paths.vault_root.join("accounts.dpapi"),
            "AiGoodBro.Next.Windows.accounts.v1",
            |v| {
                if changed == "revision" {
                    let n = v["accounts"][0]["revision"].as_u64().unwrap();
                    v["accounts"][0]["revision"] = json!(n + 10);
                } else {
                    v["accounts"][0]["credential"]["auth"] = json!(credential("external"));
                    v["accounts"][0]["credential"]["identity"] =
                        json!(["external@fixture.invalid", "workspace-external"]);
                }
            },
        );
        let before = std::fs::read(f.paths.vault_root.join("accounts.dpapi")).unwrap();
        assert_eq!(
            f.manager.recover_pending_switch().unwrap_err().code,
            "recovery_required"
        );
        assert_eq!(
            std::fs::read(f.paths.vault_root.join("accounts.dpapi")).unwrap(),
            before
        );
        assert!(f.paths.vault_root.join("switch-journal.dpapi").exists());
        assert_eq!(f.auth(), f.before);
    }
}

#[test]
fn unavailable_encryption_never_rolls_back_the_only_surviving_rotated_grant() {
    let f = Fixture::new(true);
    let id = f.create("Rotation encryption unavailable");
    assert_eq!(f.login(&id).phase, "verified");
    let ticket = f.ready(&id);
    f.runtime.rotate_target.store(true, Ordering::SeqCst);
    *f.runtime.fail_seal_after_target.lock().unwrap() = Some(f.protector.clone());
    assert_eq!(
        f.manager.commit_account_switch(&ticket).unwrap_err().code,
        "recovery_required"
    );
    let surviving = f.auth();
    assert_ne!(surviving, f.before);
    assert_eq!(
        serde_json::from_slice::<Value>(&surviving).unwrap()["tokens"]["refresh_token"],
        "synthetic-official-rotated-refresh"
    );
    assert!(f.paths.vault_root.join("switch-journal.dpapi").exists());
    f.protector.reject.store(false, Ordering::SeqCst);
    *f.runtime.fail_seal_after_target.lock().unwrap() = None;
    let calls = f.runtime.verify_calls.load(Ordering::SeqCst);
    assert_eq!(
        f.manager.recover_pending_switch().unwrap().unwrap().phase,
        "rolled_back"
    );
    assert_eq!(f.runtime.verify_calls.load(Ordering::SeqCst), calls + 1);
    assert_eq!(f.auth(), f.before);
    assert_eq!(stored_fixture_auth(&f, &id).0, surviving);
    assert!(!f.paths.vault_root.join("switch-journal.dpapi").exists());
}

/// Explicit cross-language integration entry. The fixture driver executes the
/// production Go evidence collector using only this test's synthetic auth and
/// official-response collaborators; never a real CLI or user account.
#[test]
#[ignore = "requires the explicitly supplied production Go fixture driver"]
fn actual_go_desktop_evidence_is_accepted_by_real_account_manager() {
    let driver = std::env::var_os("AIGOODBRO_TEST_GO_EVIDENCE_DRIVER")
        .expect("explicit production Go evidence fixture driver required");
    let driver = PathBuf::from(driver);
    assert!(driver.is_absolute() && driver.is_file());
    let f = Fixture::new(true);
    let id = f.create("Go proof integration");
    assert_eq!(f.login(&id).phase, "verified");
    let claim = f.claim(&id);
    let mut home = f.manager.prepare_proxy_desktop_home(&id, &claim).unwrap();
    let input = f._temp.path().join("go-input.json");
    let output = f._temp.path().join("go-proof.json");
    let build = f._temp.path().join("go-build");
    let account =
        json!({"account":{"type":"chatgpt","email":"chosen@fixture.invalid","planType":"plus"}});
    let quota = json!({"rateLimits":{"planType":"plus","primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":chrono::Utc::now().timestamp()+3600}}});
    std::fs::write(
        &input,
        serde_json::to_vec(
            &json!({"syntheticFixture":true,"writerID":claim.writer_id,"proxyRunID":claim.proxy_run_id,
        "authPath":home.path().join("auth.json"),"account":account,"rateLimits":quota}),
        )
        .unwrap(),
    )
    .unwrap();
    let vault_before = std::fs::read(f.paths.vault_root.join("accounts.dpapi")).unwrap();
    let calls = f.runtime.verify_calls.load(Ordering::SeqCst);
    let python = std::env::var_os("AIGOODBRO_TEST_PYTHON").unwrap_or_else(|| "python3".into());
    let result = std::process::Command::new(python)
        .arg(driver)
        .arg("--input")
        .arg(&input)
        .arg("--output")
        .arg(&output)
        .arg("--build-root")
        .arg(&build)
        .current_dir(f._temp.path())
        .output()
        .expect("isolated Go fixture driver starts");
    assert!(
        result.status.success(),
        "isolated Go fixture driver failed (output kept private)"
    );
    let proof: codexu_core::proxy::DesktopQuotaEvidence =
        serde_json::from_slice(&std::fs::read(&output).unwrap()).unwrap();
    assert_eq!(proof.backend_id.len(), 32);
    assert!(proof
        .backend_id
        .bytes()
        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)));
    assert_eq!(proof.writer_id, claim.writer_id);
    assert_eq!(proof.proxy_run_id, claim.proxy_run_id);
    assert_eq!(proof.account, account);
    assert_eq!(proof.rate_limits, quota);
    let snapshot = f
        .manager
        .read_current_desktop_snapshot(&claim, &proof)
        .unwrap();
    assert_eq!(snapshot.identity_hash, claim.identity_hash);
    assert_eq!(snapshot.official_quota, quota);
    assert_eq!(f.runtime.verify_calls.load(Ordering::SeqCst), calls);
    assert_eq!(
        std::fs::read(f.paths.vault_root.join("accounts.dpapi")).unwrap(),
        vault_before
    );
    assert_eq!(f.auth(), f.before);
    let mut incompatible = proof.clone();
    incompatible.backend_id = "00000000-0000-4000-8000-000000000000".into();
    assert_eq!(
        f.manager
            .read_current_desktop_snapshot(&claim, &incompatible)
            .err()
            .unwrap()
            .code,
        "evidence_stale"
    );
    f.manager
        .finalize_desktop_after_exit(&mut home, &claim)
        .unwrap();
    f.manager
        .complete_desktop_writer_release(&mut home, &claim)
        .unwrap();
}

#[test]
#[ignore = "requires the isolated production Go helper; no real auth or inference"]
fn actual_helper_service_run_is_accepted_by_real_account_manager() {
    use codexu_core::proxy::*;
    struct RunBoundaryGate {
        id: String,
        identity: String,
        run: Mutex<Option<String>>,
    }
    impl ProxyAccountGate for RunBoundaryGate {
        fn registration(&self, id: &str) -> std::result::Result<AccountRegistration, ProxyFailure> {
            if id != self.id {
                return Err(ProxyFailure::Identity);
            }
            Ok(AccountRegistration {
                profile_id: id.into(),
                identity_hash: self.identity.clone(),
            })
        }
        fn managed_profile_ids(&self) -> std::result::Result<Vec<String>, ProxyFailure> {
            Ok(vec![self.id.clone()])
        }
        fn activate_run(&self, run: &str) -> std::result::Result<(), ProxyFailure> {
            *self.run.lock().unwrap() = Some(run.into());
            Ok(())
        }
        fn evidence(&self, _: &str) -> std::result::Result<AccountEvidence, ProxyFailure> {
            Err(ProxyFailure::QuotaUnknown)
        }
        fn reserve(
            &self,
            _: &AdmissionRequest,
        ) -> std::result::Result<CredentialLease, ProxyFailure> {
            Err(ProxyFailure::AdmissionUnknown)
        }
        fn resolve(
            &self,
            _: &LeaseTuple,
        ) -> std::result::Result<AdmissionResolution, ProxyFailure> {
            Err(ProxyFailure::AdmissionUnknown)
        }
        fn heartbeat(&self, _: &LeaseTuple) -> std::result::Result<(), ProxyFailure> {
            Err(ProxyFailure::AdmissionUnknown)
        }
        fn release(&self, _: &LeaseTuple) -> std::result::Result<(), ProxyFailure> {
            Err(ProxyFailure::AdmissionUnknown)
        }
        fn retire_run(&self, run: &str, confirmed: bool) -> std::result::Result<(), ProxyFailure> {
            if confirmed && self.run.lock().unwrap().as_deref() == Some(run) {
                Ok(())
            } else {
                Err(ProxyFailure::CleanupUnconfirmed)
            }
        }
    }
    struct NoPersistentSecrets;
    impl ProxySecretStore for NoPersistentSecrets {
        fn load_client_key(&self) -> std::result::Result<Option<String>, ProxyFailure> {
            Err(ProxyFailure::Unavailable)
        }
        fn save_client_key(&self, _: &str) -> std::result::Result<(), ProxyFailure> {
            Err(ProxyFailure::Unavailable)
        }
    }
    let helper = PathBuf::from(
        std::env::var_os("AIGOODBRO_TEST_PROXY_HELPER").expect("explicit isolated helper required"),
    );
    assert!(helper.is_absolute() && helper.is_file());
    let f = Fixture::new(true);
    let id = f.create("Service boundary");
    assert_eq!(f.login(&id).phase, "verified");
    let mut claim = f.claim(&id);
    let gate = Arc::new(RunBoundaryGate {
        id: id.clone(),
        identity: claim.identity_hash.clone(),
        run: Mutex::new(None),
    });
    let service = LocalProxyService::new(
        f._temp.path().join("synthetic-proxy.json"),
        f._temp.path().join("synthetic-proxy-state"),
        helper,
        vec!["synthetic-model".into()],
        gate.clone(),
        Arc::new(NoPersistentSecrets),
    )
    .unwrap();
    let mut preferences = ProxyPreferences::default();
    preferences.is_enabled = true;
    preferences.order = vec![id.clone()];
    preferences.enabled_ids.insert(id.clone());
    preferences.known_ids.insert(id.clone());
    preferences.listen_port = 0;
    preferences.client_key_mode = ClientKeyMode::PerRun;
    service.save_preferences(preferences).unwrap();
    let started = service.start().unwrap();
    assert_eq!(started.phase, ProxyPhase::Running);
    claim.proxy_run_id = gate
        .run
        .lock()
        .unwrap()
        .clone()
        .expect("real Service called Host.begin and activate_run");
    // Stop the owned helper before assertions, so a negative case cannot leave
    // an isolated listener/process behind. No inference request is ever made.
    assert_eq!(service.stop().unwrap().phase, ProxyPhase::Stopped);
    let mut home = f.manager.prepare_proxy_desktop_home(&id, &claim).unwrap();
    let mut incompatible = claim.clone();
    incompatible.proxy_run_id = "a".repeat(64);
    assert!(f
        .manager
        .prepare_proxy_desktop_home(&id, &incompatible)
        .is_err());
    f.manager
        .finalize_desktop_after_exit(&mut home, &claim)
        .unwrap();
    f.manager
        .complete_desktop_writer_release(&mut home, &claim)
        .unwrap();
    assert_eq!(f.auth(), f.before);
}

#[test]
fn login_page_resolution_is_attempt_bound_and_revoked_by_cancel_or_completion() {
    let f = Fixture::new(true);
    let id = f.create("Pairing page");
    f.runtime.wait_login.store(true, Ordering::SeqCst);
    let attempt = f.manager.begin_account_login(id).unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    while f
        .manager
        .get_login_attempt(&attempt.attempt_id)
        .unwrap()
        .phase
        != "waiting"
    {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(2));
    }
    assert_eq!(
        f.manager.account_login_page(&attempt.attempt_id).unwrap(),
        "https://auth.openai.com/codex/device"
    );
    assert_eq!(
        f.manager
            .account_login_page("https://evil.invalid/")
            .unwrap_err()
            .code,
        "login_attempt_not_found"
    );
    f.manager.cancel_account_login(&attempt.attempt_id).unwrap();
    assert_eq!(
        f.manager
            .account_login_page(&attempt.attempt_id)
            .unwrap_err()
            .code,
        "login_page_unavailable"
    );
    assert_eq!(f.finish(&attempt.attempt_id).phase, "cancelled");
}
#[test]
fn native_secret_slots_are_fixed_encrypted_and_not_part_of_account_dtos() {
    let f = Fixture::new(false);
    f.manager
        .save_secret("proxy.client_key", Some("synthetic-secret-key"))
        .unwrap();
    assert_eq!(
        f.manager
            .load_secret("proxy.client_key")
            .unwrap()
            .as_deref(),
        Some("synthetic-secret-key")
    );
    assert!(!String::from_utf8_lossy(
        &std::fs::read(f.paths.vault_root.join("accounts.dpapi")).unwrap()
    )
    .contains("synthetic-secret-key"));
    assert_eq!(
        f.manager
            .save_secret("arbitrary", Some("no"))
            .unwrap_err()
            .code,
        "secret_slot_invalid"
    );
    f.manager.save_secret("proxy.client_key", None).unwrap();
    assert!(f.manager.load_secret("proxy.client_key").unwrap().is_none());
}
#[test]
fn malformed_vault_symlinks_and_unsupported_platform_do_not_fall_back_to_empty_success() {
    let f = Fixture::new(false);
    assert_eq!(
        f.manager
            .create_managed_account("Claude".into(), "claude_code".into())
            .unwrap_err()
            .code,
        "platform_not_supported"
    );
    std::fs::write(f.paths.vault_root.join("accounts.dpapi"), b"corrupt").unwrap();
    assert!(f.manager.list_managed_accounts().is_err());
    #[cfg(unix)]
    {
        let root = f._temp.path().canonicalize().unwrap();
        let link = root.join("link");
        std::os::unix::fs::symlink(&f.paths.system_home, &link).unwrap();
        assert!(AccountPaths::isolated(root.join("another-vault"), link).is_err());
    }
}
#[test]
fn official_identity_requires_matching_claims_email_valid_expiry_and_authoritative_quota() {
    let auth = credential("chosen");
    let account = json!({"account":{"type":"chatgpt","email":"chosen@fixture.invalid"}});
    assert!(VerifiedCredential::from_official_read(auth.clone(), &account, json!({})).is_err());
    assert!(VerifiedCredential::from_official_read(
        auth,
        &json!({"account":{"type":"chatgpt","email":"different@fixture.invalid"}}),
        json!({})
    )
    .is_err());
    let mut auth: Value = serde_json::from_slice(&credential("chosen")).unwrap();
    auth["tokens"]["account_id"] = json!("wrong-workspace");
    assert!(AccountIdentity::from_auth(&serde_json::to_vec(&auth).unwrap()).is_err());
    auth["tokens"]["account_id"] = json!("workspace-chosen");
    auth["tokens"]["refresh_token"] = json!("   ");
    assert!(AccountIdentity::from_auth(&serde_json::to_vec(&auth).unwrap()).is_err());
}
#[test]
fn authorization_parser_uses_exact_official_host_and_bounded_code_grammar() {
    let parsed =
        parse_authorization(b"\x1b[32mhttps://auth.openai.com/codex/device\x1b[0m\nABCD-1234\n")
            .unwrap()
            .unwrap();
    assert_eq!(
        parsed.verification_url,
        "https://auth.openai.com/codex/device"
    );
    assert_eq!(parsed.user_code, "ABCD-1234");
    let dto = LoginAttemptDto {
        attempt_id: "fixture-attempt".into(),
        account_id: "fixture-account".into(),
        phase: "waiting",
        verification_url: Some(parsed.verification_url),
        user_code: Some(parsed.user_code),
        error_code: None,
    };
    assert!(!format!("{dto:?}").contains("ABCD-1234"));
    for text in [
        "https://auth.openai.com.evil.invalid/codex/device\nABCD-1234",
        "https://auth.openai.com/codex/device?redirect=evil\nABCD-1234",
        "https://evil.invalid/\nABCD-1234",
    ] {
        assert!(parse_authorization(text.as_bytes()).unwrap().is_none());
    }
    assert!(parse_authorization(&vec![b'x'; 65537]).is_err());
}

#[test]
fn failed_worker_spawn_removes_starting_attempt_and_does_not_block_future_login() {
    struct RejectSpawn;
    impl AccountLoginSpawner for RejectSpawn {
        fn spawn(&self, _: Box<dyn FnOnce() + Send>) -> AccountResult<()> {
            Err(error("login_unavailable"))
        }
    }
    let f = Fixture::new(true);
    let manager = AccountManager::with_components_and_spawner(
        f.paths.clone(),
        f.protector.clone(),
        f.runtime.clone(),
        Some(f.gate.clone()),
        Arc::new(RejectSpawn),
    )
    .unwrap();
    let id = manager
        .create_managed_account("Spawn failure".into(), "codex".into())
        .unwrap()
        .id;
    assert_eq!(
        manager.begin_account_login(id.clone()).unwrap_err().code,
        "login_unavailable"
    );
    assert_eq!(
        manager.list_managed_accounts().unwrap()[0].login_state,
        "signed_out"
    );
    assert_eq!(
        manager.begin_account_login(id.clone()).unwrap_err().code,
        "login_unavailable"
    );
    assert_eq!(f.auth(), f.before);
}

#[test]
fn stale_source_revision_after_prepare_is_rejected_before_target_write() {
    let f = Fixture::new(true);
    let id = f.create("Source generation");
    assert_eq!(f.login(&id).phase, "verified");
    let ticket = f.ready(&id);
    let another = AccountManager::with_components(
        f.paths.clone(),
        f.protector.clone(),
        f.runtime.clone(),
        Some(f.gate.clone()),
    )
    .unwrap();
    another.refresh_managed_credential(&id).unwrap();
    assert_eq!(
        f.manager.commit_account_switch(&ticket).unwrap_err().code,
        "account_changed"
    );
    assert_eq!(f.auth(), f.before);
}

#[test]
fn expired_ticket_releases_maintenance_and_never_mutates_target() {
    let f = Fixture::new(true);
    let id = f.create("Expiration");
    assert_eq!(f.login(&id).phase, "verified");
    let prepared = f.manager.prepare_account_switch(id).unwrap();
    assert_eq!(prepared.phase, "ready");
    let deadline = prepared.expires_at.unwrap() + 2;
    while chrono::Utc::now().timestamp() < deadline {
        std::thread::sleep(Duration::from_millis(100));
    }
    let code = f
        .manager
        .commit_account_switch(prepared.ticket.as_ref().unwrap())
        .unwrap_err()
        .code;
    assert!(matches!(
        code,
        "switch_ticket_expired" | "switch_ticket_invalid"
    ));
    assert_eq!(f.gate.held.load(Ordering::SeqCst), 0);
    assert_eq!(f.auth(), f.before);
}

#[cfg(unix)]
#[test]
fn real_os_store_lock_excludes_a_second_writer_and_recovers_after_release() {
    use std::os::fd::AsRawFd;
    unsafe extern "C" {
        fn flock(fd: i32, operation: i32) -> i32;
    }
    let f = Fixture::new(false);
    let id = f.create("Lock fixture");
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(f.paths.vault_root.join("accounts.lock"))
        .unwrap();
    assert_eq!(unsafe { flock(file.as_raw_fd(), 2 | 4) }, 0);
    assert_eq!(
        f.manager
            .save_secret("proxy.client_key", Some("synthetic"))
            .unwrap_err()
            .code,
        "account_store_busy"
    );
    drop(file);
    assert!(f
        .manager
        .save_secret("proxy.client_key", Some("synthetic"))
        .is_ok());
    assert_eq!(f.manager.list_managed_accounts().unwrap()[0].id, id);
}
