use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};
#[path = "../../../tests/support/windows_creation.rs"]
mod windows_creation;

struct Protector {
    fail_next: AtomicBool,
}
impl SecretProtector for Protector {
    fn seal(&self, _: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
        if self.fail_next.swap(false, Ordering::SeqCst) {
            return Err(fail("synthetic_save_failed"));
        }
        Ok(bytes.to_vec())
    }
    fn unseal(&self, _: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
        Ok(bytes.to_vec())
    }
}
struct Runtime {
    calls: AtomicUsize,
    refreshes: AtomicUsize,
    lost: AtomicBool,
    fail_after_verify: AtomicBool,
    protector: Arc<Protector>,
    replace_during_verify: Mutex<Option<(PathBuf, Vec<u8>)>>,
}
impl ClaudeSubscriptionRuntime for Runtime {
    fn available(&self) -> bool {
        true
    }
    fn login(
        &self,
        _: &Path,
        _: &AtomicBool,
        _: &mut dyn FnMut(),
    ) -> AccountResult<ClaudeVerifiedCredential> {
        panic!("no login in source fixture")
    }
    fn verify(&self, bytes: &[u8], declared: &Value) -> AccountResult<ClaudeVerifiedCredential> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        if let Some((path, bytes)) = self.replace_during_verify.lock().unwrap().take() {
            super::super::super::super::storage::atomic_write(&path, &bytes).unwrap();
        }
        let result = ClaudeVerifiedCredential::from_official_profile(
            bytes.to_vec(),
            declared.clone(),
            &json!({"account":{"uuid":declared["accountUuid"],"email":declared["emailAddress"]},"organization":{"uuid":declared["organizationUuid"]}}),
        );
        if self.fail_after_verify.swap(false, Ordering::SeqCst) {
            self.protector.fail_next.store(true, Ordering::SeqCst);
        }
        result
    }
    fn usage(&self, _: &[u8]) -> AccountResult<super::super::super::ClaudeUsageResponse> {
        panic!("no usage in source fixture")
    }
    fn refresh(&self, bytes: &[u8]) -> AccountResult<Vec<u8>> {
        self.refreshes.fetch_add(1, Ordering::SeqCst);
        if self.lost.load(Ordering::SeqCst) {
            return Err(fail("synthetic_lost_response"));
        }
        let mut value: Value = serde_json::from_slice(bytes).unwrap();
        value["claudeAiOauth"]["accessToken"] = json!("synthetic-successor-access");
        value["claudeAiOauth"]["refreshToken"] = json!("synthetic-successor-refresh");
        value["claudeAiOauth"]["expiresAt"] = json!(4_102_444_800_000i64);
        Ok(serde_json::to_vec(&value).unwrap())
    }
    fn require_system_idle(&self) -> AccountResult<()> {
        Ok(())
    }
    fn validate_environment(&self) -> AccountResult<()> {
        Ok(())
    }
}
struct Gate;
impl SwitchMaintenanceLease for Gate {
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
        Ok(Box::new(Gate))
    }
}
struct Fixture {
    _temp: tempfile::TempDir,
    paths: ClaudeAccountPaths,
    manager: Arc<ClaudeSubscriptionManager>,
    runtime: Arc<Runtime>,
}
fn credential(subject: &str, expired: bool) -> Vec<u8> {
    serde_json::to_vec(&json!({"claudeAiOauth":{"accessToken":format!("synthetic-access-{subject}"),"refreshToken":format!("synthetic-refresh-{subject}"),"expiresAt":if expired { 1i64 } else { 4_102_444_800_000i64 }}})).unwrap()
}
fn account(subject: &str) -> Value {
    json!({"accountUuid":format!("synthetic-{subject}"),"organizationUuid":"synthetic-org","emailAddress":format!("{subject}@fixture.invalid")})
}
impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let base = windows_creation::fixture_root(temp.path());
        for path in [
            base.join("live"),
            base.join(".claude-swap-backup"),
            base.join(".claude-swap-backup/configs"),
            base.join(".claude-swap-backup/credentials"),
        ] {
            windows_creation::create_private_dir(&path).unwrap();
        }
        let paths = ClaudeAccountPaths::isolated(
            base.join("vault"),
            base.join("live"),
            base.join("global.json"),
        )
        .unwrap();
        for (path, bytes) in [
            (
                paths.global_config.clone(),
                serde_json::to_vec(&json!({"oauthAccount":account("source")})).unwrap(),
            ),
            (
                paths.live_directory.join(".credentials.json"),
                credential("source", false),
            ),
            (paths.live_directory.join("settings.json"), b"{}".to_vec()),
        ] {
            windows_creation::write_private_file_new(&path, &bytes).unwrap();
        }
        let protector = Arc::new(Protector {
            fail_next: AtomicBool::new(false),
        });
        let runtime = Arc::new(Runtime {
            calls: AtomicUsize::new(0),
            refreshes: AtomicUsize::new(0),
            lost: AtomicBool::new(false),
            fail_after_verify: AtomicBool::new(false),
            protector: protector.clone(),
            replace_during_verify: Mutex::new(None),
        });
        let manager = ClaudeSubscriptionManager::with_components(
            paths.clone(),
            protector,
            runtime.clone(),
            Some(Arc::new(Gate)),
        )
        .unwrap();
        Self {
            _temp: temp,
            paths,
            manager,
            runtime,
        }
    }
    fn put(&self, path: &Path, bytes: &[u8]) {
        if path.exists() {
            super::super::super::super::storage::atomic_write(path, bytes).unwrap();
        } else {
            windows_creation::write_private_file_new(path, bytes).unwrap();
        }
    }
    fn slot(&self, slot: &str, subject: &str, expired: bool) -> PathBuf {
        let root = root(&self.paths).unwrap();
        let seq_path = root.join("sequence.json");
        let mut seq: Value = std::fs::read(&seq_path)
            .ok()
            .map(|b| serde_json::from_slice(&b).unwrap())
            .unwrap_or(json!({"accounts":{}}));
        seq["accounts"][slot] = json!({"uuid":format!("synthetic-{subject}"),"organizationUuid":"synthetic-org","email":format!("{subject}@fixture.invalid")});
        self.put(&seq_path, &serde_json::to_vec(&seq).unwrap());
        self.put(
            &root.join("configs").join(format!(
                ".claude-config-{slot}-{subject}@fixture.invalid.json"
            )),
            &serde_json::to_vec(&json!({"oauthAccount":account(subject)})).unwrap(),
        );
        let path = root
            .join("credentials")
            .join(format!(".creds-{slot}-{subject}@fixture.invalid.enc"));
        self.put(
            &path,
            STANDARD.encode(credential(subject, expired)).as_bytes(),
        );
        path
    }
    fn import(&self, slot: &str) -> String {
        let candidate = self
            .manager
            .scan_claude_swap_candidates()
            .unwrap()
            .into_iter()
            .find(|c| c.label == format!("Claude {slot}"))
            .unwrap();
        self.manager
            .import_claude_swap_candidate(&candidate.candidate_id)
            .unwrap()
            .id
    }
    fn save_source(&self) -> String {
        self.manager
            .capture_claude_subscription("Source".into(), None)
            .unwrap()
            .id
    }
    fn reference(&self, id: &str) -> Reference {
        self.manager
            .store()
            .unwrap()
            .vault
            .record(id)
            .unwrap()
            .source
            .clone()
            .unwrap()
    }
}
#[test]
fn import_is_explicit_metadata_only_and_round_trips_reference_without_grants() {
    let f = Fixture::new();
    let path = f.slot("1", "target", false);
    let original = std::fs::read(&path).unwrap();
    let candidates = f.manager.scan_claude_swap_candidates().unwrap();
    let dto = serde_json::to_string(&candidates).unwrap();
    assert!(!dto.contains("target@"));
    assert!(!dto.contains("Token"));
    assert!(!dto.contains(".enc"));
    assert!(f.manager.list_claude_subscriptions().unwrap().is_empty());
    let id = f.import("1");
    assert_eq!(f.runtime.calls.load(Ordering::SeqCst), 0);
    assert_eq!(std::fs::read(path).unwrap(), original);
    let persisted: Value =
        serde_json::from_slice(&std::fs::read(f.paths.store()).unwrap()).unwrap();
    assert_eq!(persisted["records"][0]["credential"]["bytes"], json!([]));
    assert_eq!(persisted["records"][0]["source"]["slot"], "1");
    let loaded = f
        .manager
        .store()
        .unwrap()
        .vault
        .record(&id)
        .unwrap()
        .clone();
    assert_eq!(loaded.credential.bytes, credential("target", false));
    assert_eq!(
        f.manager
            .import_claude_swap_candidate(&candidates[0].candidate_id)
            .unwrap_err()
            .code,
        "duplicate_identity"
    );
}
#[test]
fn stale_candidate_invalid_slot_and_identity_changes_are_rejected() {
    let f = Fixture::new();
    f.slot("1", "target", false);
    let candidate = f.manager.scan_claude_swap_candidates().unwrap().remove(0);
    f.slot("1", "other", false);
    assert_eq!(
        f.manager
            .import_claude_swap_candidate(&candidate.candidate_id)
            .unwrap_err()
            .code,
        "claude_swap_changed"
    );
    f.slot("01", "bad", false);
    assert_eq!(f.manager.scan_claude_swap_candidates().unwrap().len(), 1);
    let id = f.import("1");
    f.slot("1", "third", false);
    let row = f.manager.list_claude_subscriptions().unwrap().remove(0);
    assert!(!row.can_switch);
    assert_eq!(
        row.switch_block_reason,
        Some("claude_swap_identity_changed")
    );
    assert_eq!(
        f.manager
            .store()
            .unwrap()
            .vault
            .record(&id)
            .unwrap()
            .credential
            .bytes,
        Vec::<u8>::new()
    );
}
#[test]
fn source_missing_does_not_corrupt_other_saved_native_accounts() {
    let f = Fixture::new();
    let path = f.slot("1", "target", false);
    let id = f.import("1");
    f.save_source();
    std::fs::remove_file(path).unwrap();
    let rows = f.manager.list_claude_subscriptions().unwrap();
    assert_eq!(rows.len(), 2);
    assert!(!rows.iter().find(|r| r.id == id).unwrap().can_switch);
    assert!(
        rows.iter()
            .find(|r| r.label == "Source")
            .unwrap()
            .can_switch
    );
}
#[test]
fn pending_upstream_lineage_and_competing_consumption_lock_fail_closed() {
    let f = Fixture::new();
    f.slot("1", "target", false);
    let candidate = f.manager.scan_claude_swap_candidates().unwrap().remove(0);
    let reference = Reference {
        slot: "1".into(),
        identity_fingerprint: identity::Identity::from_account(&account("target"))
            .unwrap()
            .fingerprint(),
    };
    let locks = SwapLocks::acquire(&f.paths, std::iter::once(reference)).unwrap();
    assert_eq!(
        f.manager
            .import_claude_swap_candidate(&candidate.candidate_id)
            .unwrap_err()
            .code,
        "claude_swap_busy"
    );
    drop(locks);
    f.put(
        &root(&f.paths)
            .unwrap()
            .join("credentials/.unclaimed-manifest.json"),
        b"{}",
    );
    assert_eq!(
        f.manager
            .import_claude_swap_candidate(&candidate.candidate_id)
            .unwrap_err()
            .code,
        "claude_swap_busy"
    );
}

#[test]
fn unicode_email_reference_and_any_session_alias_for_same_slot_are_checked() {
    let f = Fixture::new();
    f.slot("1", "é", false);
    let id = f.import("1");
    let sessions = root(&f.paths).unwrap().join("sessions");
    windows_creation::create_private_dir(&sessions).unwrap();
    windows_creation::create_private_dir(&sessions.join("1-old_normalized_alias")).unwrap();
    let row = f
        .manager
        .list_claude_subscriptions()
        .unwrap()
        .into_iter()
        .find(|r| r.id == id)
        .unwrap();
    assert!(!row.can_switch);
    assert_eq!(row.switch_block_reason, Some("claude_swap_busy"));
}
#[test]
fn prepared_reference_holds_lock_and_source_change_cannot_commit() {
    let f = Fixture::new();
    let path = f.slot("1", "target", false);
    let id = f.import("1");
    f.save_source();
    let before = Target::read(&f.paths).unwrap();
    let ready = f
        .manager
        .prepare_claude_subscription_switch(id.clone())
        .unwrap();
    assert_eq!(
        SwapLocks::acquire(&f.paths, std::iter::once(f.reference(&id)))
            .err()
            .unwrap()
            .code,
        "claude_swap_busy"
    );
    f.put(
        &path,
        STANDARD.encode(credential("changed", false)).as_bytes(),
    );
    assert_eq!(
        f.manager
            .commit_claude_subscription_switch(ready.ticket.as_deref().unwrap())
            .unwrap_err()
            .code,
        "claude_swap_changed"
    );
    assert!(Target::read(&f.paths).unwrap() == before);
    assert!(SwapLocks::acquire(&f.paths, std::iter::once(f.reference(&id))).is_ok());
}
#[test]
fn reference_switch_and_return_write_current_rotated_grant_to_original_slot() {
    let f = Fixture::new();
    let path = f.slot("1", "target", false);
    let id = f.import("1");
    let native = f.save_source();
    let ready = f
        .manager
        .prepare_claude_subscription_switch(id.clone())
        .unwrap();
    f.manager
        .commit_claude_subscription_switch(ready.ticket.as_deref().unwrap())
        .unwrap();
    f.put(
        &f.paths.live_directory.join(".credentials.json"),
        &credential("rotated", false),
    );
    let ready = f
        .manager
        .prepare_claude_subscription_switch(native)
        .unwrap();
    f.manager
        .commit_claude_subscription_switch(ready.ticket.as_deref().unwrap())
        .unwrap();
    assert_eq!(
        STANDARD.decode(std::fs::read(path).unwrap()).unwrap(),
        credential("rotated", false)
    );
    assert!(f
        .manager
        .store()
        .unwrap()
        .vault
        .record(&id)
        .unwrap()
        .source
        .is_some());
    let persisted = std::fs::read(f.paths.store()).unwrap();
    assert!(!String::from_utf8(persisted)
        .unwrap()
        .contains("synthetic-refresh-rotated"));
}
#[test]
fn rotating_refresh_successor_is_written_back_and_old_grant_is_not_retried() {
    let f = Fixture::new();
    let path = f.slot("1", "target", true);
    let id = f.import("1");
    let locks = SwapLocks::acquire(&f.paths, std::iter::once(f.reference(&id))).unwrap();
    f.runtime.fail_after_verify.store(true, Ordering::SeqCst);
    assert_eq!(
        f.manager.verified_saved(&id, &locks).err().unwrap().code,
        "synthetic_save_failed"
    );
    let after = STANDARD.decode(std::fs::read(&path).unwrap()).unwrap();
    assert!(String::from_utf8(after)
        .unwrap()
        .contains("synthetic-successor-refresh"));
    assert!(f.manager.store().unwrap().vault.refresh.contains_key(&id));
    f.manager.verified_saved(&id, &locks).unwrap();
    assert_eq!(f.runtime.refreshes.load(Ordering::SeqCst), 1);
    assert!(!f.manager.store().unwrap().vault.refresh.contains_key(&id));
    let persisted: Value =
        serde_json::from_slice(&std::fs::read(f.paths.store()).unwrap()).unwrap();
    assert_eq!(persisted["records"][0]["credential"]["bytes"], json!([]));
}
#[test]
fn lost_refresh_response_never_reuses_source_grant() {
    let f = Fixture::new();
    let path = f.slot("1", "target", true);
    let id = f.import("1");
    let before = std::fs::read(&path).unwrap();
    let locks = SwapLocks::acquire(&f.paths, std::iter::once(f.reference(&id))).unwrap();
    f.runtime.lost.store(true, Ordering::SeqCst);
    assert!(f.manager.verified_saved(&id, &locks).is_err());
    assert!(f.manager.verified_saved(&id, &locks).is_err());
    assert_eq!(f.runtime.refreshes.load(Ordering::SeqCst), 1);
    assert_eq!(std::fs::read(path).unwrap(), before);
}
#[test]
fn capture_current_cannot_replace_reference_with_a_second_runnable_grant() {
    let f = Fixture::new();
    f.slot("1", "source", false);
    f.import("1");
    assert_eq!(
        f.manager
            .capture_claude_subscription("Source".into(), None)
            .unwrap_err()
            .code,
        "claude_swap_reference_exists"
    );
}

#[test]
fn source_rotation_during_official_verification_is_not_overwritten() {
    let f = Fixture::new();
    let path = f.slot("1", "target", false);
    let id = f.import("1");
    let locks = SwapLocks::acquire(&f.paths, std::iter::once(f.reference(&id))).unwrap();
    let replacement = STANDARD
        .encode(credential("foreign-successor", false))
        .into_bytes();
    *f.runtime.replace_during_verify.lock().unwrap() = Some((path.clone(), replacement.clone()));
    assert_eq!(
        f.manager.verified_saved(&id, &locks).err().unwrap().code,
        "account_changed"
    );
    assert_eq!(std::fs::read(path).unwrap(), replacement);
}

#[test]
fn config_identity_mismatch_and_source_symlink_are_not_importable() {
    let f = Fixture::new();
    f.slot("1", "target", false);
    let candidate = f.manager.scan_claude_swap_candidates().unwrap().remove(0);
    let config = root(&f.paths)
        .unwrap()
        .join("configs/.claude-config-1-target@fixture.invalid.json");
    f.put(
        &config,
        &serde_json::to_vec(&json!({"oauthAccount":account("other")})).unwrap(),
    );
    assert_eq!(
        f.manager
            .import_claude_swap_candidate(&candidate.candidate_id)
            .unwrap_err()
            .code,
        "claude_swap_identity_changed"
    );
    #[cfg(unix)]
    {
        std::fs::remove_file(&config).unwrap();
        std::os::unix::fs::symlink(&f.paths.global_config, &config).unwrap();
        assert!(f
            .manager
            .import_claude_swap_candidate(&candidate.candidate_id)
            .is_err());
    }
    assert!(f.manager.list_claude_subscriptions().unwrap().is_empty());
}

#[test]
fn old_native_vault_without_reference_fields_remains_readable() {
    let f = Fixture::new();
    let id = f.save_source();
    let persisted: Value =
        serde_json::from_slice(&std::fs::read(f.paths.store()).unwrap()).unwrap();
    assert!(persisted["records"][0].get("source").is_none());
    assert!(!persisted["records"][0]["credential"]["bytes"]
        .as_array()
        .unwrap()
        .is_empty());
    assert!(f
        .manager
        .list_claude_subscriptions()
        .unwrap()
        .iter()
        .any(|r| r.id == id && r.can_switch));
}

#[cfg(windows)]
#[test]
fn windows_source_lock_matches_upstream_one_byte_not_whole_file() {
    use std::os::windows::io::AsRawHandle;
    use windows::Win32::{
        Foundation::HANDLE,
        Storage::FileSystem::{
            LockFileEx, UnlockFileEx, LOCKFILE_EXCLUSIVE_LOCK, LOCKFILE_FAIL_IMMEDIATELY,
        },
        System::IO::{OVERLAPPED, OVERLAPPED_0, OVERLAPPED_0_0},
    };
    let f = Fixture::new();
    f.slot("1", "target", false);
    let id = f.import("1");
    let reference = f.reference(&id);
    let held = SwapLocks::acquire(&f.paths, std::iter::once(reference.clone())).unwrap();
    let probe = open_with(
        &root(&f.paths).unwrap().join("credentials/.consume-1.lock"),
        true,
        false,
    )
    .unwrap();
    let mut second = OVERLAPPED::default();
    second.Anonymous = OVERLAPPED_0 {
        Anonymous: OVERLAPPED_0_0 {
            Offset: 1,
            OffsetHigh: 0,
        },
    };
    unsafe {
        LockFileEx(
            HANDLE(probe.as_raw_handle()),
            LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY,
            Some(0),
            1,
            0,
            &mut second,
        )
    }
    .unwrap();
    assert_eq!(
        SwapLocks::acquire(&f.paths, std::iter::once(reference.clone()))
            .err()
            .unwrap()
            .code,
        "claude_swap_busy"
    );
    unsafe { UnlockFileEx(HANDLE(probe.as_raw_handle()), Some(0), 1, 0, &mut second) }.unwrap();
    drop(held);
    assert!(SwapLocks::acquire(&f.paths, std::iter::once(reference)).is_ok());
}

#[test]
fn source_reference_remarks_never_hydrate_copy_or_rewrite_a_grant() {
    let f = Fixture::new();
    let source = f.slot("1", "target", false);
    let id = f.import("1");
    let before = Store::load_metadata(&f.paths, f.manager.protector.as_ref())
        .unwrap()
        .vault
        .record(&id)
        .unwrap()
        .clone();
    assert!(before.credential.bytes.is_empty());
    let source_bytes = std::fs::read(&source).unwrap();
    std::fs::remove_file(&source).unwrap();
    let calls = f.runtime.calls.load(Ordering::SeqCst);
    f.manager
        .rename_claude_subscription(&id, " 👨‍👩‍👧‍👦备注 ".into())
        .unwrap();
    let after = Store::load_metadata(&f.paths, f.manager.protector.as_ref())
        .unwrap()
        .vault
        .record(&id)
        .unwrap()
        .clone();
    assert_eq!(after.display_label(), "👨‍👩‍👧‍👦备注");
    assert_eq!(after.label, before.label);
    assert!(after.credential.bytes.is_empty());
    assert_eq!(
        serde_json::to_value(&after.source).unwrap(),
        serde_json::to_value(&before.source).unwrap()
    );
    assert_eq!(
        after.credential.oauth_account,
        before.credential.oauth_account
    );
    assert_eq!(calls, f.runtime.calls.load(Ordering::SeqCst));
    assert!(!source.exists());
    f.manager
        .rename_claude_subscription(&id, String::new())
        .unwrap();
    assert_eq!(
        Store::load_metadata(&f.paths, f.manager.protector.as_ref())
            .unwrap()
            .vault
            .record(&id)
            .unwrap()
            .display_label(),
        before.label
    );
    f.put(&source, &source_bytes);
}
