//! Real subscription manager/storage/transactions, entirely synthetic. No
//! native CLI, real profile, Keychain, network, App or proxy is started.
use codexu_core::accounts::{claude::*, *};
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};
const CONTEXT: &str = "AiGoodBro.Next.Windows.claude-subscriptions.v1";
fn error(code: &'static str) -> AccountError {
    AccountError { code }
}
fn credentials(subject: &str) -> Vec<u8> {
    serde_json::to_vec(&json!({"claudeAiOauth":{
    "accessToken":format!("synthetic-access-{subject}"),"refreshToken":format!("synthetic-refresh-{subject}"),
    "expiresAt":4_102_444_800_000i64,"subscriptionType":"pro"},"mcpOAuth":{"fixture":"keep"}})).unwrap()
}
fn account(subject: &str) -> Value {
    json!({"accountUuid":format!("fixture-{subject}"),"organizationUuid":"fixture-org","emailAddress":format!("{subject}@fixture.invalid")})
}
fn profile(subject: &str) -> Value {
    json!({"account":{"uuid":format!("fixture-{subject}"),"email":format!("{subject}@fixture.invalid")},"organization":{"uuid":"fixture-org"}})
}
fn verified(subject: &str) -> AccountResult<ClaudeVerifiedCredential> {
    ClaudeVerifiedCredential::from_official_profile(
        credentials(subject),
        account(subject),
        &profile(subject),
    )
}
struct FixtureProtector {
    reject: AtomicBool,
}
impl SecretProtector for FixtureProtector {
    fn seal(&self, context: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
        if self.reject.load(Ordering::SeqCst) {
            return Err(error("fixture_seal_failed"));
        }
        let mut result = context.as_bytes().to_vec();
        result.push(0);
        result.extend(bytes.iter().map(|b| b ^ 0x39));
        Ok(result)
    }
    fn unseal(&self, context: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
        let mut prefix = context.as_bytes().to_vec();
        prefix.push(0);
        if !bytes.starts_with(&prefix) {
            return Err(error("fixture_unseal_failed"));
        }
        Ok(bytes[prefix.len()..].iter().map(|b| b ^ 0x39).collect())
    }
}
struct Runtime {
    subject: Mutex<String>,
    system: PathBuf,
    config: PathBuf,
    wait: AtomicBool,
    idle: AtomicBool,
    fail_next: AtomicBool,
    foreign_next: AtomicBool,
    fail_seal_next: AtomicBool,
    protector: Arc<FixtureProtector>,
    refresh_count: AtomicUsize,
    lost_refresh: AtomicBool,
    fail_after_refresh: AtomicBool,
    usage_count: AtomicUsize,
    usage: Mutex<(u16, Vec<u8>, Option<String>)>,
    change_during_usage: AtomicBool,
}
impl ClaudeSubscriptionRuntime for Runtime {
    fn available(&self) -> bool {
        true
    }
    fn login(
        &self,
        directory: &Path,
        cancelled: &AtomicBool,
        waiting: &mut dyn FnMut(),
    ) -> AccountResult<ClaudeVerifiedCredential> {
        assert_ne!(directory, self.system);
        assert!(directory.is_absolute());
        waiting();
        while self.wait.load(Ordering::SeqCst) {
            if cancelled.load(Ordering::SeqCst) {
                return Err(error("login_cancelled"));
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        verified(&self.subject.lock().unwrap())
    }
    fn verify(
        &self,
        credential: &[u8],
        declared: &Value,
    ) -> AccountResult<ClaudeVerifiedCredential> {
        if self.fail_next.swap(false, Ordering::SeqCst) {
            return Err(error("fixture_identity_unavailable"));
        }
        if self.foreign_next.swap(false, Ordering::SeqCst) {
            std::fs::write(&self.config, b"{\"foreign\":true}").unwrap();
        }
        if self.fail_seal_next.swap(false, Ordering::SeqCst) {
            self.protector.reject.store(true, Ordering::SeqCst);
        }
        let subject = declared["accountUuid"]
            .as_str()
            .unwrap()
            .strip_prefix("fixture-")
            .unwrap();
        ClaudeVerifiedCredential::from_official_profile(
            credential.to_vec(),
            declared.clone(),
            &profile(subject),
        )
    }
    fn usage(&self, _: &[u8]) -> AccountResult<ClaudeUsageResponse> {
        self.usage_count.fetch_add(1, Ordering::SeqCst);
        if self.change_during_usage.load(Ordering::SeqCst) {
            std::fs::write(&self.config, b"{\"foreign\":true}").unwrap();
        }
        let (status, body, retry) = self.usage.lock().unwrap().clone();
        Ok(ClaudeUsageResponse {
            status,
            body,
            retry_after: retry,
        })
    }
    fn refresh(&self, bytes: &[u8]) -> AccountResult<Vec<u8>> {
        self.refresh_count.fetch_add(1, Ordering::SeqCst);
        if self.lost_refresh.load(Ordering::SeqCst) {
            return Err(error("fixture_lost_reply"));
        }
        let mut value: Value = serde_json::from_slice(bytes).unwrap();
        value["claudeAiOauth"]["expiresAt"] = json!(4_102_444_800_000i64);
        value["claudeAiOauth"]["accessToken"] = json!("synthetic-renewed-access");
        value["claudeAiOauth"]["refreshToken"] = json!("synthetic-renewed-refresh");
        if self.fail_after_refresh.swap(false, Ordering::SeqCst) {
            self.fail_next.store(true, Ordering::SeqCst);
        }
        Ok(serde_json::to_vec(&value).unwrap())
    }
    fn require_system_idle(&self) -> AccountResult<()> {
        if self.idle.load(Ordering::SeqCst) {
            Ok(())
        } else {
            Err(error("account_busy"))
        }
    }
    fn validate_environment(&self) -> AccountResult<()> {
        Ok(())
    }
}
struct Gate {
    busy: Arc<AtomicBool>,
    held: Arc<AtomicUsize>,
}
struct Lease {
    busy: Arc<AtomicBool>,
    held: Arc<AtomicUsize>,
}
impl SwitchMaintenanceLease for Lease {
    fn recheck(&self) -> AccountResult<()> {
        if self.busy.load(Ordering::SeqCst) {
            Err(error("occupancy_unknown"))
        } else {
            Ok(())
        }
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        self.held.fetch_sub(1, Ordering::SeqCst);
    }
}
impl AccountOccupancyGate for Gate {
    fn acquire_switch_maintenance(
        &self,
        _: &str,
        _: &str,
    ) -> AccountResult<Box<dyn SwitchMaintenanceLease>> {
        if self.busy.load(Ordering::SeqCst) {
            return Err(error("account_busy"));
        }
        self.held.fetch_add(1, Ordering::SeqCst);
        Ok(Box::new(Lease {
            busy: self.busy.clone(),
            held: self.held.clone(),
        }))
    }
}
struct Fixture {
    _temp: tempfile::TempDir,
    paths: ClaudeAccountPaths,
    manager: Arc<ClaudeSubscriptionManager>,
    runtime: Arc<Runtime>,
    protector: Arc<FixtureProtector>,
    gate: Arc<Gate>,
    before_auth: Vec<u8>,
    before_config: Vec<u8>,
}
impl Fixture {
    fn new(gated: bool) -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let system = root.join("synthetic-claude");
        std::fs::create_dir(&system).unwrap();
        let config = root.join("synthetic-claude.json");
        let before_auth = credentials("source");
        let before_config = serde_json::to_vec(
            &json!({"oauthAccount":account("source"),"preferences":{"fixture":"keep"}}),
        )
        .unwrap();
        std::fs::write(system.join(".credentials.json"), &before_auth).unwrap();
        std::fs::write(&config, &before_config).unwrap();
        std::fs::write(system.join("settings.json"), b"{}").unwrap();
        let paths =
            ClaudeAccountPaths::isolated(root.join("vault"), system.clone(), config.clone())
                .unwrap();
        let protector = Arc::new(FixtureProtector {
            reject: AtomicBool::new(false),
        });
        let runtime = Arc::new(Runtime {
            subject: Mutex::new("target".into()),
            system,
            config,
            wait: AtomicBool::new(false),
            idle: AtomicBool::new(true),
            fail_next: AtomicBool::new(false),
            foreign_next: AtomicBool::new(false),
            fail_seal_next: AtomicBool::new(false),
            protector: protector.clone(),
            refresh_count: AtomicUsize::new(0),
            lost_refresh: AtomicBool::new(false),
            fail_after_refresh: AtomicBool::new(false),
            usage_count: AtomicUsize::new(0),
            usage: Mutex::new((
                200,
                serde_json::to_vec(
                    &json!({"five_hour":{"utilization":23,"resets_at":"2100-01-01T00:00:00Z"}}),
                )
                .unwrap(),
                None,
            )),
            change_during_usage: AtomicBool::new(false),
        });
        let gate = Arc::new(Gate {
            busy: Arc::new(AtomicBool::new(false)),
            held: Arc::new(AtomicUsize::new(0)),
        });
        let manager = ClaudeSubscriptionManager::with_components(
            paths.clone(),
            protector.clone(),
            runtime.clone(),
            gated.then(|| gate.clone() as Arc<dyn AccountOccupancyGate>),
        )
        .unwrap();
        Self {
            _temp: temp,
            paths,
            manager,
            runtime,
            protector,
            gate,
            before_auth,
            before_config,
        }
    }
    fn finish(&self, id: &str) -> ClaudeLoginAttemptDto {
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let value = self.manager.get_claude_subscription_login(id).unwrap();
            if matches!(value.phase, "verified" | "failed" | "cancelled") {
                return value;
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(2));
        }
    }
    fn saved_target(&self) -> String {
        let a = self.manager.begin_claude_subscription_login().unwrap();
        assert_eq!(self.finish(&a.attempt_id).phase, "verified");
        self.manager
            .capture_claude_subscription("Target".into(), Some(&a.attempt_id))
            .unwrap()
            .id
    }
    fn saved_source(&self) -> String {
        self.manager
            .capture_claude_subscription("Source".into(), None)
            .unwrap()
            .id
    }
    fn ready(&self, id: &str) -> String {
        let dto = self
            .manager
            .prepare_claude_subscription_switch(id.into())
            .unwrap();
        assert_eq!(dto.phase, "ready");
        dto.ticket.unwrap()
    }
    fn unchanged(&self) {
        assert_eq!(
            std::fs::read(self.paths.live_directory.join(".credentials.json")).unwrap(),
            self.before_auth
        );
        assert_eq!(
            std::fs::read(&self.paths.global_config).unwrap(),
            self.before_config
        );
    }
    fn mutate_vault(&self, change: impl FnOnce(&mut Value)) {
        let path = self.paths.vault_root.join("subscriptions.dpapi");
        let bytes = self
            .protector
            .unseal(CONTEXT, &std::fs::read(&path).unwrap())
            .unwrap();
        let mut value: Value = serde_json::from_slice(&bytes).unwrap();
        change(&mut value);
        std::fs::write(
            path,
            self.protector
                .seal(CONTEXT, &serde_json::to_vec(&value).unwrap())
                .unwrap(),
        )
        .unwrap();
    }
    fn expire_target(&self, id: &str) {
        self.mutate_vault(|v| {
            let record = v["records"]
                .as_array_mut()
                .unwrap()
                .iter_mut()
                .find(|r| r["id"] == id)
                .unwrap();
            let bytes: Vec<u8> =
                serde_json::from_value(record["credential"]["bytes"].clone()).unwrap();
            let mut credential: Value = serde_json::from_slice(&bytes).unwrap();
            credential["claudeAiOauth"]["expiresAt"] = json!(1);
            record["credential"]["bytes"] = json!(serde_json::to_vec(&credential).unwrap());
        });
    }
}

#[test]
fn claude_official_identity_binds_uuid_organization_and_email_and_rejects_expiry() {
    assert!(verified("target").is_ok());
    for wrong in [
        profile("other"),
        json!({"account":{"uuid":"fixture-target","email":"target@fixture.invalid"},"organization":{"uuid":"other-org"}}),
    ] {
        assert!(ClaudeVerifiedCredential::from_official_profile(
            credentials("target"),
            account("target"),
            &wrong
        )
        .is_err());
    }
    let mut value: Value = serde_json::from_slice(&credentials("target")).unwrap();
    value["claudeAiOauth"]["expiresAt"] = json!(true);
    assert!(ClaudeVerifiedCredential::from_official_profile(
        serde_json::to_vec(&value).unwrap(),
        account("target"),
        &profile("target")
    )
    .is_err());
}
#[test]
fn claude_login_isolated_then_explicit_capture_encrypts_and_deduplicates_real_identity() {
    let f = Fixture::new(true);
    let id = f.saved_target();
    f.unchanged();
    let dto = f.manager.list_claude_subscriptions().unwrap().remove(0);
    assert_eq!(dto.id, id);
    assert_eq!(dto.plan_type.as_deref(), Some("pro"));
    let encoded = serde_json::to_string(&dto).unwrap();
    assert!(!encoded.contains("target@fixture.invalid"));
    assert!(!encoded.contains("synthetic-access"));
    assert!(!String::from_utf8_lossy(
        &std::fs::read(f.paths.vault_root.join("subscriptions.dpapi")).unwrap()
    )
    .contains("synthetic-access"));
    let a = f.manager.begin_claude_subscription_login().unwrap();
    assert_eq!(f.finish(&a.attempt_id).phase, "verified");
    assert_eq!(
        f.manager
            .capture_claude_subscription("Another label".into(), Some(&a.attempt_id))
            .unwrap()
            .id,
        id
    );
    assert_eq!(f.manager.list_claude_subscriptions().unwrap().len(), 1);
    assert!(std::fs::read_dir(f.paths.vault_root.join("staging"))
        .unwrap()
        .next()
        .is_none());
}
#[test]
fn claude_cancel_blocks_late_capture_without_touching_current_account() {
    let f = Fixture::new(true);
    f.runtime.wait.store(true, Ordering::SeqCst);
    let a = f.manager.begin_claude_subscription_login().unwrap();
    f.manager
        .cancel_claude_subscription_login(&a.attempt_id)
        .unwrap();
    assert_eq!(f.finish(&a.attempt_id).phase, "cancelled");
    assert_eq!(
        f.manager
            .capture_claude_subscription("Cancelled".into(), Some(&a.attempt_id))
            .unwrap_err()
            .code,
        "claude_login_attempt_unavailable"
    );
    f.unchanged();
}
#[test]
fn claude_capture_current_is_officially_verified_and_preserves_concurrent_target_change() {
    let f = Fixture::new(true);
    f.runtime.foreign_next.store(true, Ordering::SeqCst);
    assert_eq!(
        f.manager
            .capture_claude_subscription("Current".into(), None)
            .unwrap_err()
            .code,
        "target_changed"
    );
    assert!(f.manager.list_claude_subscriptions().unwrap().is_empty());
    assert_eq!(
        std::fs::read(&f.paths.global_config).unwrap(),
        b"{\"foreign\":true}"
    );
}
#[test]
fn claude_unknown_busy_and_existing_native_lock_never_allow_target_write() {
    let f = Fixture::new(false);
    assert_eq!(
        f.manager
            .capture_claude_subscription("Unknown".into(), None)
            .unwrap_err()
            .code,
        "occupancy_unknown"
    );
    f.unchanged();
    f.manager.install_occupancy_gate(f.gate.clone()).unwrap();
    f.saved_source();
    let id = f.saved_target();
    f.gate.busy.store(true, Ordering::SeqCst);
    assert!(f
        .manager
        .prepare_claude_subscription_switch(id.clone())
        .is_err());
    f.gate.busy.store(false, Ordering::SeqCst);
    let lock = f.paths.live_directory.join(".oauth_refresh.lock");
    std::fs::create_dir(&lock).unwrap();
    assert_eq!(
        f.manager
            .prepare_claude_subscription_switch(id)
            .unwrap_err()
            .code,
        "claude_account_busy"
    );
    assert!(lock.exists());
    f.unchanged();
}
#[test]
fn claude_switch_two_phase_preserves_settings_mcp_and_unrelated_global_fields() {
    let f = Fixture::new(true);
    f.saved_source();
    let id = f.saved_target();
    let ticket = f.ready(&id);
    f.unchanged();
    assert_eq!(
        f.manager
            .commit_claude_subscription_switch(&ticket)
            .unwrap()
            .phase,
        "verified"
    );
    let live: Value = serde_json::from_slice(
        &std::fs::read(f.paths.live_directory.join(".credentials.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(
        live["claudeAiOauth"]["accessToken"],
        "synthetic-access-target"
    );
    assert_eq!(live["mcpOAuth"]["fixture"], "keep");
    let config: Value =
        serde_json::from_slice(&std::fs::read(&f.paths.global_config).unwrap()).unwrap();
    assert_eq!(config["preferences"]["fixture"], "keep");
    assert_eq!(config["oauthAccount"], account("target"));
    assert_eq!(
        f.manager
            .list_claude_subscriptions()
            .unwrap()
            .iter()
            .find(|r| r.id == id)
            .unwrap()
            .active_state,
        "verified"
    );
    assert_eq!(f.gate.held.load(Ordering::SeqCst), 0);
    assert!(f
        .manager
        .commit_claude_subscription_switch(&ticket)
        .is_err());
}
#[test]
fn claude_postwrite_profile_failure_rolls_back_both_files_and_clears_owned_intent() {
    let f = Fixture::new(true);
    f.saved_source();
    let id = f.saved_target();
    let ticket = f.ready(&id);
    f.runtime.fail_next.store(true, Ordering::SeqCst);
    assert_eq!(
        f.manager
            .commit_claude_subscription_switch(&ticket)
            .unwrap_err()
            .code,
        "claude_switch_rolled_back"
    );
    f.unchanged();
    assert!(!f.paths.vault_root.join("switch-journal.dpapi").exists());
}
#[test]
fn claude_vault_failure_after_write_rolls_back_without_success_dto() {
    let f = Fixture::new(true);
    f.saved_source();
    let id = f.saved_target();
    let ticket = f.ready(&id);
    f.runtime.fail_seal_next.store(true, Ordering::SeqCst);
    assert_eq!(
        f.manager
            .commit_claude_subscription_switch(&ticket)
            .unwrap_err()
            .code,
        "claude_switch_rolled_back"
    );
    f.unchanged();
    assert!(!f.paths.vault_root.join("switch-journal.dpapi").exists());
}
#[test]
fn claude_external_writer_survives_and_recovery_stays_gated_until_known_target() {
    let f = Fixture::new(true);
    f.saved_source();
    let id = f.saved_target();
    let ticket = f.ready(&id);
    f.runtime.foreign_next.store(true, Ordering::SeqCst);
    assert_eq!(
        f.manager
            .commit_claude_subscription_switch(&ticket)
            .unwrap_err()
            .code,
        "recovery_required"
    );
    assert_eq!(
        std::fs::read(&f.paths.global_config).unwrap(),
        b"{\"foreign\":true}"
    );
    let reopened = ClaudeSubscriptionManager::with_components(
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
    assert!(reopened.recover_pending_switch().is_err());
    assert!(f.paths.vault_root.join("switch-journal.dpapi").exists());
    std::fs::write(&f.paths.global_config, &f.before_config).unwrap();
    assert_eq!(
        reopened.recover_pending_switch().unwrap().unwrap().phase,
        "rolled_back"
    );
    f.unchanged();
}
#[test]
fn claude_switch_refuses_unsaved_current_identity_and_changed_config_selection() {
    let f = Fixture::new(true);
    let id = f.saved_target();
    assert_eq!(
        f.manager
            .prepare_claude_subscription_switch(id.clone())
            .unwrap_err()
            .code,
        "claude_current_account_not_saved"
    );
    f.saved_source();
    let ticket = f.ready(&id);
    std::fs::write(
        f.paths.live_directory.join(".config.json"),
        &f.before_config,
    )
    .unwrap();
    assert_eq!(
        f.manager
            .commit_claude_subscription_switch(&ticket)
            .unwrap_err()
            .code,
        "target_changed"
    );
    f.unchanged();
}
#[test]
fn claude_expired_saved_grant_is_refreshed_once_then_committed_with_bound_identity() {
    let f = Fixture::new(true);
    f.saved_source();
    let id = f.saved_target();
    f.expire_target(&id);
    let ticket = f.ready(&id);
    assert_eq!(f.runtime.refresh_count.load(Ordering::SeqCst), 1);
    f.unchanged();
    assert_eq!(
        f.manager
            .commit_claude_subscription_switch(&ticket)
            .unwrap()
            .phase,
        "verified"
    );
    assert_eq!(f.runtime.refresh_count.load(Ordering::SeqCst), 1);
}
#[test]
fn claude_lost_refresh_reply_keeps_encrypted_pending_and_never_replays_old_grant() {
    let f = Fixture::new(true);
    f.saved_source();
    let id = f.saved_target();
    f.expire_target(&id);
    f.runtime.lost_refresh.store(true, Ordering::SeqCst);
    for _ in 0..2 {
        assert_eq!(
            f.manager
                .prepare_claude_subscription_switch(id.clone())
                .unwrap_err()
                .code,
            "claude_reauthentication_required"
        );
    }
    assert_eq!(f.runtime.refresh_count.load(Ordering::SeqCst), 1);
    assert_eq!(
        f.manager
            .list_claude_subscriptions()
            .unwrap()
            .iter()
            .find(|r| r.id == id)
            .unwrap()
            .login_state,
        "needs_reauth"
    );
    f.unchanged();
}

#[test]
fn claude_successful_rotated_grant_is_saved_before_identity_failure_and_resumed_without_refresh() {
    let f = Fixture::new(true);
    f.saved_source();
    let id = f.saved_target();
    f.expire_target(&id);
    f.runtime.fail_after_refresh.store(true, Ordering::SeqCst);
    assert_eq!(
        f.manager
            .prepare_claude_subscription_switch(id.clone())
            .unwrap_err()
            .code,
        "fixture_identity_unavailable"
    );
    assert_eq!(f.runtime.refresh_count.load(Ordering::SeqCst), 1);
    let ticket = f.ready(&id);
    assert_eq!(f.runtime.refresh_count.load(Ordering::SeqCst), 1);
    f.manager
        .cancel_claude_subscription_switch(&ticket)
        .unwrap();
    f.unchanged();
}

#[test]
fn claude_pending_refresh_cannot_be_reset_by_recapturing_the_same_old_grant() {
    let f = Fixture::new(true);
    f.saved_source();
    let id = f.saved_target();
    f.expire_target(&id);
    f.runtime.lost_refresh.store(true, Ordering::SeqCst);
    assert!(f.manager.prepare_claude_subscription_switch(id).is_err());
    let attempt = f.manager.begin_claude_subscription_login().unwrap();
    assert_eq!(f.finish(&attempt.attempt_id).phase, "verified");
    assert_eq!(
        f.manager
            .capture_claude_subscription("Old grant".into(), Some(&attempt.attempt_id))
            .unwrap_err()
            .code,
        "claude_reauthentication_required"
    );
    assert_eq!(f.runtime.refresh_count.load(Ordering::SeqCst), 1);
    f.unchanged();
}
#[test]
fn claude_usage_projects_only_returned_mac_fields_and_rejects_invalid_percent() {
    assert!(parse_claude_usage(b"{}").unwrap().is_empty());
    let windows=parse_claude_usage(br#"{"five_hour":{"utilization":23},"seven_day":null,"limits":[{"is_active":true,"scope":{"model":{"display_name":"Fixture scope"}},"kind":"weekly_scoped","group":"weekly","percent":42}]}"#).unwrap();
    assert_eq!(windows.len(), 2);
    assert_eq!(windows[0].id, "five_hour");
    assert_eq!(windows[1].label, "Fixture scope");
    assert_eq!(windows[0].remaining_percent(), 77.0);
    for body in [
        br#"{"five_hour":{"utilization":true}}"#.as_slice(),
        br#"{"five_hour":{"utilization":101}}"#,
        br#"{"limits":[{"is_active":"yes"}]}"#,
    ] {
        assert!(parse_claude_usage(body).is_err());
    }
}
#[test]
fn claude_quota_uses_saved_official_identity_and_preserves_rate_limit_deadline() {
    let f = Fixture::new(true);
    let id = f.saved_target();
    let dto = f.manager.read_claude_subscription_quota(&id).unwrap();
    assert_eq!(dto.quota.windows.len(), 1);
    assert_eq!(dto.quota.windows[0].used_percent, 23.0);
    *f.runtime.usage.lock().unwrap() = (429, b"{}".to_vec(), Some("120".into()));
    let before = chrono::Utc::now().timestamp();
    let dto = f.manager.read_claude_subscription_quota(&id).unwrap();
    assert_eq!(
        dto.quota.state,
        codexu_core::readers::local_cli_quota::LocalCliQuotaState::RateLimited
    );
    assert!(dto.quota.windows.is_empty());
    assert!(dto.server_retry_at.unwrap() >= before + 120);
    let cached = f.manager.read_claude_subscription_quota(&id).unwrap();
    assert_eq!(cached.server_retry_at, dto.server_retry_at);
    assert_eq!(f.runtime.usage_count.load(Ordering::SeqCst), 2);
    let reopened = ClaudeSubscriptionManager::with_components(
        f.paths.clone(),
        f.protector.clone(),
        f.runtime.clone(),
        Some(f.gate.clone()),
    )
    .unwrap();
    assert_eq!(
        reopened
            .read_claude_subscription_quota(&id)
            .unwrap()
            .server_retry_at,
        dto.server_retry_at
    );
    assert_eq!(f.runtime.usage_count.load(Ordering::SeqCst), 2);
    f.unchanged();
}
#[test]
fn claude_quota_rejects_credential_or_current_identity_change_during_read() {
    let f = Fixture::new(true);
    let id = f.saved_target();
    f.runtime.change_during_usage.store(true, Ordering::SeqCst);
    assert_eq!(
        f.manager
            .read_claude_subscription_quota(&id)
            .unwrap_err()
            .code,
        "claude_credentials_changed"
    );
}
#[test]
fn claude_exit_seals_new_work_without_clearing_unknown_journal_or_waiting_for_child() {
    let f = Fixture::new(true);
    f.runtime.wait.store(true, Ordering::SeqCst);
    let a = f.manager.begin_claude_subscription_login().unwrap();
    assert!(f.manager.has_inflight_operation());
    f.manager.cancel_inflight_for_exit();
    assert_eq!(
        f.manager
            .begin_claude_subscription_login()
            .unwrap_err()
            .code,
        "account_service_exiting"
    );
    assert_eq!(f.finish(&a.attempt_id).phase, "cancelled");
    assert!(!f.manager.has_inflight_operation());
    f.unchanged();
}

fn pending_recovery(f: &Fixture) -> String {
    f.saved_source();
    let id = f.saved_target();
    let ticket = f.ready(&id);
    f.runtime.foreign_next.store(true, Ordering::SeqCst);
    assert_eq!(
        f.manager
            .commit_claude_subscription_switch(&ticket)
            .unwrap_err()
            .code,
        "recovery_required"
    );
    assert!(f.paths.vault_root.join("switch-journal.dpapi").exists());
    id
}

#[test]
fn claude_explicit_capture_retries_temporarily_busy_recovery_without_clearing_unknown_intent() {
    let f = Fixture::new(true);
    pending_recovery(&f);
    // Only this synthetic external writer is restored; production recovery
    // never overwrites an unrecognized concurrent writer.
    std::fs::write(&f.paths.global_config, &f.before_config).unwrap();
    f.gate.busy.store(true, Ordering::SeqCst);
    assert_eq!(
        f.manager
            .capture_claude_subscription("Retry current".into(), None)
            .unwrap_err()
            .code,
        "account_busy"
    );
    assert!(f.paths.vault_root.join("switch-journal.dpapi").exists());
    f.gate.busy.store(false, Ordering::SeqCst);
    assert_eq!(
        f.manager
            .capture_claude_subscription("Retry current".into(), None)
            .unwrap()
            .active_state,
        "verified"
    );
    assert!(!f.paths.vault_root.join("switch-journal.dpapi").exists());
    f.unchanged();
}

#[test]
fn claude_explicit_login_and_prepare_retry_recovery_but_external_target_stays_unknown() {
    let f = Fixture::new(true);
    let id = pending_recovery(&f);
    assert_eq!(
        f.manager
            .begin_claude_subscription_login()
            .unwrap_err()
            .code,
        "external_change_preserved"
    );
    assert!(f.paths.vault_root.join("switch-journal.dpapi").exists());
    std::fs::write(&f.paths.global_config, &f.before_config).unwrap();
    let dto = f.manager.prepare_claude_subscription_switch(id).unwrap();
    assert_eq!(dto.phase, "ready");
    f.manager
        .cancel_claude_subscription_switch(dto.ticket.as_deref().unwrap())
        .unwrap();
    assert!(!f.paths.vault_root.join("switch-journal.dpapi").exists());
    let another = Fixture::new(true);
    pending_recovery(&another);
    std::fs::write(&another.paths.global_config, &another.before_config).unwrap();
    let attempt = another.manager.begin_claude_subscription_login().unwrap();
    assert_eq!(another.finish(&attempt.attempt_id).phase, "verified");
    assert!(!another
        .paths
        .vault_root
        .join("switch-journal.dpapi")
        .exists());
    another.unchanged();
}
