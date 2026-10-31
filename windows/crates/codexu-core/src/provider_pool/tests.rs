use super::{domain::*, host::*, process::*, storage::Store, *};
use crate::accounts::{AccountResult, SecretProtector};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::VecDeque,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};

struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("provider-pool-test-{}", nonce().unwrap()));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
#[derive(Default)]
struct Protector {
    reads: AtomicUsize,
    fail: AtomicBool,
}
impl SecretProtector for Protector {
    fn seal(&self, context: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
        if self.fail.load(Ordering::Acquire) {
            return Err(crate::accounts::fail("fixture_failure"));
        }
        let mut v = context.as_bytes().to_vec();
        v.push(0);
        v.extend(bytes);
        Ok(v)
    }
    fn unseal(&self, context: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
        self.reads.fetch_add(1, Ordering::AcqRel);
        let prefix = format!("{context}\0");
        bytes
            .strip_prefix(prefix.as_bytes())
            .map(|b| b.to_vec())
            .ok_or_else(|| crate::accounts::fail("fixture_context"))
    }
}
fn credential(provider: Provider) -> Credential {
    Credential {
        provider,
        account_id: format!(
            "{}{}",
            if provider == Provider::Antigravity {
                "ag-"
            } else {
                match provider {
                    Provider::Claude => "claude-",
                    Provider::Kimi => "kimi-",
                    _ => "xai-",
                }
            },
            "a".repeat(32)
        ),
        generation: "g".repeat(43),
        masked_identity: "a***@e***".into(),
        access_token: "synthetic-access".into(),
        refresh_token: "synthetic-refresh".into(),
        project_id: if provider == Provider::Antigravity {
            "fixture-project".into()
        } else {
            String::new()
        },
        expires_at: 4_000_000_000,
        id_token: None,
        device_id: None,
        account_subject: Some("fixture-subject".into()),
        organization_id: None,
        refresh_expires_at: None,
    }
}
#[derive(Default)]
struct Browser(Mutex<Vec<String>>);
impl AuthorizationBrowser for Browser {
    fn open(&self, url: &str) -> Result<()> {
        self.0.lock().unwrap().push(url.into());
        Ok(())
    }
}
#[derive(Default)]
struct Fake {
    output: Mutex<VecDeque<Vec<u8>>>,
    frames: Mutex<Vec<Value>>,
    startups: Mutex<Vec<Value>>,
    launched: AtomicUsize,
    stops: AtomicUsize,
    stop_fails: AtomicBool,
    pipe_fails: AtomicBool,
    bootstrap_fails: AtomicBool,
    exited: AtomicBool,
}
impl Fake {
    fn emit(&self, v: Value) {
        let mut b = serde_json::to_vec(&v).unwrap();
        b.push(b'\n');
        self.output.lock().unwrap().push_back(b);
    }
    fn frames(&self) -> Vec<Value> {
        self.frames.lock().unwrap().clone()
    }
}
struct FakeRuntime(Arc<Fake>);
struct FakeHelper(Arc<Fake>);
impl Runtime for FakeRuntime {
    fn launch(&self, _: &HelperResource, _: &Path, _: &AtomicBool) -> Result<Box<dyn Helper>> {
        self.0.launched.fetch_add(1, Ordering::AcqRel);
        Ok(Box::new(FakeHelper(self.0.clone())))
    }
}
impl Helper for FakeHelper {
    fn bootstrap(&mut self, bytes: &[u8], _: &AtomicBool) -> Result<()> {
        self.0
            .startups
            .lock()
            .unwrap()
            .push(serde_json::from_slice(bytes).unwrap());
        if self.0.bootstrap_fails.load(Ordering::Acquire) {
            Err(fail("provider_pool_startup_failed"))
        } else {
            Ok(())
        }
    }
    fn frame(&mut self, b: &[u8]) -> Result<()> {
        if self.0.pipe_fails.load(Ordering::Acquire) {
            return Err(fail("provider_pool_pipe_failed"));
        }
        self.0
            .frames
            .lock()
            .unwrap()
            .push(serde_json::from_slice(b).unwrap());
        Ok(())
    }
    fn output(&mut self) -> Result<Vec<u8>> {
        Ok(self
            .0
            .output
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or_default())
    }
    fn exited(&mut self) -> Result<bool> {
        Ok(self.0.exited.load(Ordering::Acquire))
    }
    fn stop(&mut self) -> Result<()> {
        self.0.stops.fetch_add(1, Ordering::AcqRel);
        if self.0.stop_fails.load(Ordering::Acquire) {
            Err(fail("provider_pool_cleanup_unconfirmed"))
        } else {
            Ok(())
        }
    }
}
fn resource(root: &Path) -> HelperResource {
    HelperResource::new(
        root.join("aigoodbro-antigravity-proxy.exe"),
        "0".repeat(64),
        "1".repeat(64),
    )
    .unwrap()
}
struct Harness {
    root: Root,
    pool: Arc<ProviderPool>,
    fake: Arc<Fake>,
    protector: Arc<Protector>,
    browser: Arc<Browser>,
}
impl Harness {
    fn new() -> Self {
        let root = Root::new();
        let fake = Arc::new(Fake::default());
        let protector = Arc::new(Protector::default());
        let browser = Arc::new(Browser::default());
        let pool = ProviderPool::with_runtime(
            root.0.join("pool"),
            resource(&root.0),
            browser.clone(),
            protector.clone(),
            Arc::new(FakeRuntime(fake.clone())),
        )
        .unwrap();
        Self {
            root,
            pool,
            fake,
            protector,
            browser,
        }
    }
    fn start(&self) -> String {
        let state = self.pool.start(None).unwrap();
        let run = state.run_id.unwrap();
        self.fake.emit(
            json!({"event":"ready","port":PORT,"providers":["antigravity","claude","kimi","xai"]}),
        );
        wait(|| self.pool.snapshot().unwrap().phase == Phase::Running);
        run
    }
    fn auth(&self, run: &str, provider: Provider) -> String {
        self.pool
            .begin_authorization(run, provider)
            .unwrap()
            .authorization
            .unwrap()
            .attempt_id
    }
    fn persist(&self, c: &Credential, attempt: Option<&str>, request: &str, purpose: &str) {
        self.fake.emit(json!({"event":"persist_credential","provider":c.provider,"accountID":c.account_id,"generation":c.generation,"credential":c,"sessionID":attempt,"requestID":request,"purpose":purpose}));
    }
    fn ack(&self, request: &str) -> bool {
        wait(|| {
            self.fake
                .frames()
                .iter()
                .any(|v| v["requestID"] == request && v["command"] == "persist_result")
        });
        self.fake
            .frames()
            .iter()
            .find(|v| v["requestID"] == request && v["command"] == "persist_result")
            .unwrap()["ok"]
            .as_bool()
            .unwrap()
    }
    fn seed(&self, c: &Credential) {
        Store::new(self.root.0.join("pool"), self.protector.clone())
            .unwrap()
            .persist(c, true)
            .unwrap();
    }
}
impl Drop for Harness {
    fn drop(&mut self) {
        self.fake.stop_fails.store(false, Ordering::Release);
        self.pool.request_exit();
        wait(|| {
            matches!(
                self.pool.snapshot().map(|s| s.phase),
                Ok(Phase::Stopped | Phase::Failed)
            )
        });
    }
}
fn wait(mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(3);
    while !condition() {
        assert!(
            Instant::now() < deadline,
            "bounded fixture condition did not arrive"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn unopened_snapshot_does_not_decrypt_or_launch() {
    let h = Harness::new();
    h.seed(&credential(Provider::Kimi));
    let before = h.protector.reads.load(Ordering::Acquire);
    let s = h.pool.snapshot().unwrap();
    assert_eq!(s.accounts.len(), 1);
    assert_eq!(s.phase, Phase::Stopped);
    assert_eq!(h.fake.launched.load(Ordering::Acquire), 0);
    assert_eq!(h.protector.reads.load(Ordering::Acquire), before);
    let safe = serde_json::to_string(&s).unwrap();
    for secret in [
        "synthetic-access",
        "synthetic-refresh",
        "fixture-subject",
        "clientKey",
    ] {
        assert!(!safe.contains(secret));
    }
}
#[test]
fn startup_restores_provider_isolation_and_persistent_disable() {
    let h = Harness::new();
    let a = credential(Provider::Kimi);
    let b = credential(Provider::Claude);
    h.seed(&a);
    h.seed(&b);
    h.pool
        .set_enabled(None, &a.account_id, &a.generation, false)
        .unwrap();
    let run = h.start();
    let startup = h.fake.startups.lock().unwrap()[0].clone();
    assert_eq!(startup["schemaVersion"], 1);
    assert_eq!(startup["port"], PORT);
    assert_eq!(startup["accounts"][0]["enabled"], false);
    assert_eq!(startup["accounts"][1]["credential"]["provider"], "claude");
    assert!(h.pool.start(None).is_err());
    h.pool.stop(&run, true).unwrap();
    wait(|| h.pool.snapshot().unwrap().phase == Phase::Stopped);
    assert!(!h.pool.snapshot().unwrap().accounts[0].enabled);
}
#[test]
fn matching_authorization_saves_before_positive_ack() {
    let h = Harness::new();
    let run = h.start();
    let attempt = h.auth(&run, Provider::Kimi);
    let c = credential(Provider::Kimi);
    let request = "r".repeat(43);
    h.persist(&c, Some(&attempt), &request, "add");
    assert!(h.ack(&request));
    let reopened = Store::new(h.root.0.join("pool"), h.protector.clone()).unwrap();
    let (_, rows) = reopened.bootstrap().unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].1.access_token, c.access_token);
    h.fake.emit(json!({"event":"auth_result","provider":"kimi","sessionID":attempt,"accountID":c.account_id,"code":"ok"}));
    wait(|| h.pool.snapshot().unwrap().authorization.is_none());
    assert!(h.pool.snapshot().unwrap().issue_code.is_none());
}
#[test]
fn cancelled_or_wrong_provider_cannot_persist_late_credentials() {
    let h = Harness::new();
    let run = h.start();
    let attempt = h.auth(&run, Provider::Kimi);
    let request = "r".repeat(43);
    h.persist(
        &credential(Provider::Claude),
        Some(&attempt),
        &request,
        "add",
    );
    assert!(!h.ack(&request));
    h.pool.cancel_authorization(&run, &attempt).unwrap();
    let request = "s".repeat(43);
    h.persist(&credential(Provider::Kimi), Some(&attempt), &request, "add");
    assert!(!h.ack(&request));
    assert!(h.pool.snapshot().unwrap().accounts.is_empty());
    assert!(h.pool.snapshot().unwrap().authorization.unwrap().cancelling);
}
#[test]
fn secret_save_failure_sends_negative_ack_and_keeps_old_bytes() {
    let h = Harness::new();
    let c = credential(Provider::Kimi);
    h.seed(&c);
    let run = h.start();
    let path = h.root.0.join("pool/pool-v1.json");
    let before = std::fs::read(&path).unwrap();
    h.protector.fail.store(true, Ordering::Release);
    let mut rotated = c;
    rotated.access_token = "synthetic-rotated".into();
    let request = "r".repeat(43);
    h.persist(&rotated, None, &request, "refresh");
    assert!(!h.ack(&request));
    assert_eq!(std::fs::read(path).unwrap(), before);
    assert_eq!(
        h.pool.snapshot().unwrap().issue_code,
        Some("provider_pool_secret_store_unavailable")
    );
    assert!(h.pool.stop(&run, false).is_err());
}
#[test]
fn removed_generation_rejects_late_refresh_and_cannot_return_in_snapshot() {
    let h = Harness::new();
    let c = credential(Provider::Kimi);
    h.seed(&c);
    let run = h.start();
    h.pool
        .remove_account(Some(&run), &c.account_id, &c.generation, true)
        .unwrap();
    let request = "r".repeat(43);
    h.persist(&c, None, &request, "refresh");
    assert!(!h.ack(&request));
    h.fake.emit(
        json!({"event":"snapshot","accounts":[c.view()],"providerModels":{"kimi":["model-a"]}}),
    );
    wait(|| h.fake.output.lock().unwrap().is_empty());
    assert!(h.pool.snapshot().unwrap().accounts.is_empty());
    assert!(h
        .pool
        .with_connection(&run, Provider::Kimi, None, |_| Ok(()))
        .is_err());
}
#[test]
fn cleanup_failure_retains_ownership_and_blocks_restart_until_explicit_retry() {
    let h = Harness::new();
    let run = h.start();
    h.fake.stop_fails.store(true, Ordering::Release);
    h.pool.stop(&run, true).unwrap();
    wait(|| h.pool.snapshot().unwrap().issue_code == Some("provider_pool_cleanup_unconfirmed"));
    assert_eq!(h.fake.stops.load(Ordering::Acquire), 1);
    assert!(h.pool.start(None).is_err());
    let other = Store::new(h.root.0.join("pool"), h.protector.clone()).unwrap();
    assert!(other.owner().is_err());
    h.fake.stop_fails.store(false, Ordering::Release);
    h.pool.stop(&run, true).unwrap();
    wait(|| h.pool.snapshot().unwrap().phase == Phase::Stopped);
    wait(|| other.owner().is_ok());
}
#[test]
fn stale_run_and_attempt_do_not_control_new_run() {
    let h = Harness::new();
    let first = h.start();
    h.pool.stop(&first, true).unwrap();
    wait(|| h.pool.snapshot().unwrap().phase == Phase::Stopped);
    let second = h.start();
    assert_ne!(first, second);
    assert!(h.pool.begin_authorization(&first, Provider::Kimi).is_err());
    assert!(h.pool.stop(&first, true).is_err());
    let attempt = h.auth(&second, Provider::Kimi);
    assert!(h
        .pool
        .cancel_authorization(&second, &"x".repeat(43))
        .is_err());
    h.fake.emit(
        json!({"event":"auth_result","provider":"kimi","sessionID":"x".repeat(43),"code":"ok"}),
    );
    wait(|| h.fake.output.lock().unwrap().is_empty());
    assert_eq!(
        h.pool.snapshot().unwrap().authorization.unwrap().attempt_id,
        attempt
    );
}
#[test]
fn browser_uses_fixed_provider_url_and_visible_device_code_only() {
    let h = Harness::new();
    let run = h.start();
    let attempt = h.auth(&run, Provider::Kimi);
    h.fake.emit(json!({"event":"open_browser","provider":"kimi","sessionID":attempt,"url":"https://kimi.com/code/authorize_device?user_code=ABCD-1234","userCode":"ABCD-1234"}));
    wait(|| h.browser.0.lock().unwrap().len() == 1);
    assert_eq!(
        h.pool
            .snapshot()
            .unwrap()
            .authorization
            .unwrap()
            .user_code
            .as_deref(),
        Some("ABCD-1234")
    );
    h.pool.cancel_authorization(&run, &attempt).unwrap();
    h.fake.emit(json!({"event":"open_browser","provider":"kimi","sessionID":attempt,"url":"https://kimi.com/code/authorize_device?user_code=ABCD-1234","userCode":"ABCD-1234"}));
    wait(|| h.fake.output.lock().unwrap().is_empty());
    assert_eq!(h.browser.0.lock().unwrap().len(), 1);
}
#[test]
fn invalid_browser_or_protocol_stops_only_the_owned_helper() {
    let h = Harness::new();
    let run = h.start();
    let attempt = h.auth(&run, Provider::Kimi);
    h.fake.emit(json!({"event":"open_browser","provider":"kimi","sessionID":attempt,"url":"https://attacker.invalid/code/authorize_device?user_code=ABCD","userCode":"ABCD"}));
    wait(|| h.pool.snapshot().unwrap().phase == Phase::Failed);
    assert_eq!(h.fake.stops.load(Ordering::Acquire), 1);
    assert!(h.browser.0.lock().unwrap().is_empty());
    assert!(h.pool.snapshot().unwrap().accounts.is_empty());
}
#[test]
fn catalog_cannot_cross_provider_and_disable_invalidates_native_connection() {
    let h = Harness::new();
    let c = credential(Provider::Kimi);
    h.seed(&c);
    let run = h.start();
    let mut view = c.view();
    view.models = vec!["model-k".into()];
    view.state = AccountState::Ready;
    h.fake.emit(json!({"event":"snapshot","accounts":[view],"providerModels":{"kimi":["model-k"],"claude":["model-k"]}}));
    wait(|| {
        h.pool
            .snapshot()
            .unwrap()
            .provider_models
            .get(&Provider::Kimi)
            .is_some_and(|m| m.len() == 1)
    });
    h.pool
        .with_connection(&run, Provider::Kimi, Some("model-k"), |c| {
            assert!(c.endpoint.ends_with("/providers/kimi"));
            assert!(c.client_key.len() >= 32);
            Ok(())
        })
        .unwrap();
    assert!(h
        .pool
        .with_connection(&run, Provider::Claude, Some("model-k"), |_| Ok(()))
        .is_err());
    h.pool
        .set_enabled(Some(&run), &c.account_id, &c.generation, false)
        .unwrap();
    assert!(h
        .pool
        .with_connection(&run, Provider::Kimi, None, |_| Ok(()))
        .is_err());
}
#[test]
fn corrupt_or_identity_mismatched_store_does_not_overwrite_original() {
    let root = Root::new();
    let protector = Arc::new(Protector::default());
    let store = Store::new(root.0.join("pool"), protector.clone()).unwrap();
    store.persist(&credential(Provider::Kimi), true).unwrap();
    let path = root.0.join("pool/pool-v1.json");
    let mut v: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    v["accounts"][0]["metadata"]["generation"] = json!("z".repeat(43));
    std::fs::write(&path, serde_json::to_vec(&v).unwrap()).unwrap();
    let original = std::fs::read(&path).unwrap();
    assert!(store.bootstrap().is_err());
    assert_eq!(std::fs::read(&path).unwrap(), original);
    std::fs::write(&path, b"invalid").unwrap();
    assert!(store.list().is_err());
    assert_eq!(std::fs::read(path).unwrap(), b"invalid");
}
#[test]
fn duplicate_or_changed_generation_refresh_does_not_replace_saved_identity() {
    let root = Root::new();
    let store = Store::new(root.0.join("pool"), Arc::new(Protector::default())).unwrap();
    let mut c = credential(Provider::Claude);
    store.persist(&c, true).unwrap();
    assert!(store.persist(&c, true).is_err());
    let original = std::fs::read(root.0.join("pool/pool-v1.json")).unwrap();
    c.generation = "z".repeat(43);
    assert!(store.persist(&c, false).is_err());
    assert_eq!(
        std::fs::read(root.0.join("pool/pool-v1.json")).unwrap(),
        original
    );
}
#[test]
fn browser_validation_rejects_extra_code_userinfo_and_cross_provider() {
    let valid = "https://kimi.com/code/authorize_device?user_code=ABCD";
    assert!(authorization_url(valid, Provider::Kimi, Some("ABCD")).is_ok());
    for bad in [
        "http://kimi.com/code/authorize_device?user_code=ABCD",
        "https://user@kimi.com/code/authorize_device?user_code=ABCD",
        "https://kimi.com/code/authorize_device?user_code=ABCD&token=secret",
        "https://kimi.com/code/authorize_device?user_code=OTHER",
    ] {
        assert!(authorization_url(bad, Provider::Kimi, Some("ABCD")).is_err());
    }
    assert!(authorization_url(valid, Provider::Xai, Some("ABCD")).is_err());
}
#[test]
fn resource_pin_requires_exact_source_digest_and_amd64_pe() {
    let root = Root::new();
    let path = root.0.join("aigoodbro-antigravity-proxy.exe");
    let mut b = vec![0u8; 128];
    b[..2].copy_from_slice(b"MZ");
    b[60..64].copy_from_slice(&64u32.to_le_bytes());
    b[64..68].copy_from_slice(b"PE\0\0");
    b[68..70].copy_from_slice(&[0x64, 0x86]);
    b[88..90].copy_from_slice(&[0x0b, 0x02]);
    std::fs::write(&path, &b).unwrap();
    let source = b"{\"fixture\":true}";
    std::fs::write(root.0.join("SOURCE.json"), source).unwrap();
    let r = HelperResource::new(
        path.clone(),
        format!("{:x}", Sha256::digest(&b)),
        format!("{:x}", Sha256::digest(source)),
    )
    .unwrap();
    assert!(r.verified().is_ok());
    b[68] = 0x4c;
    std::fs::write(&path, &b).unwrap();
    assert!(r.verified().is_err());
    std::fs::write(&path, &[1, 2, 3]).unwrap();
    assert!(HelperResource::new(root.0.join("other.exe"), "0".repeat(64), "1".repeat(64)).is_err());
}

#[test]
fn startup_failure_keeps_owned_fence_until_tree_cleanup_is_confirmed() {
    let h = Harness::new();
    h.fake.bootstrap_fails.store(true, Ordering::Release);
    h.fake.stop_fails.store(true, Ordering::Release);
    let run = h.pool.start(None).unwrap().run_id.unwrap();
    wait(|| h.pool.snapshot().unwrap().issue_code == Some("provider_pool_cleanup_unconfirmed"));
    assert!(h.pool.start(None).is_err());
    let store = Store::new(h.root.0.join("pool"), h.protector.clone()).unwrap();
    assert!(store.owner().is_err());
    h.fake.stop_fails.store(false, Ordering::Release);
    h.pool.stop(&run, true).unwrap();
    wait(|| h.pool.snapshot().unwrap().phase == Phase::Failed);
    assert_eq!(
        h.pool.snapshot().unwrap().issue_code,
        Some("provider_pool_startup_failed")
    );
    assert!(store.owner().is_ok());
}

#[test]
fn dropped_service_retains_fence_while_owned_cleanup_is_unconfirmed() {
    let root = Root::new();
    let fake = Arc::new(Fake::default());
    let protector = Arc::new(Protector::default());
    let pool = ProviderPool::with_runtime(
        root.0.join("pool"),
        resource(&root.0),
        Arc::new(Browser::default()),
        protector.clone(),
        Arc::new(FakeRuntime(fake.clone())),
    )
    .unwrap();
    pool.start(None).unwrap();
    fake.emit(json!({"event":"ready","port":PORT,"providers":["kimi"]}));
    wait(|| pool.snapshot().unwrap().phase == Phase::Running);
    fake.stop_fails.store(true, Ordering::Release);
    drop(pool);
    wait(|| fake.stops.load(Ordering::Acquire) > 0);
    let store = Store::new(root.0.join("pool"), protector).unwrap();
    assert!(
        store.owner().is_err(),
        "a missing service is not proof its Job is empty"
    );
    fake.stop_fails.store(false, Ordering::Release);
    wait(|| store.owner().is_ok());
}

/// Required by Windows package acceptance. This exercises the new real native
/// process/Job/pipe/DPAPI code with an empty synthetic pool, never OAuth/model IO.
#[cfg(windows)]
#[test]
fn windows_pinned_helper_empty_start_stop_and_dpapi_roundtrip() {
    struct NeverAuthorize;
    impl AuthorizationBrowser for NeverAuthorize {
        fn open(&self, _: &str) -> Result<()> {
            panic!("empty fixture must never authorize")
        }
    }
    struct Cleanup {
        pool: Arc<ProviderPool>,
        root: Option<Root>,
    }
    impl Drop for Cleanup {
        fn drop(&mut self) {
            self.pool.request_exit();
            let deadline = Instant::now() + Duration::from_secs(8);
            while Instant::now() < deadline {
                if self
                    .pool
                    .snapshot()
                    .is_ok_and(|s| matches!(s.phase, Phase::Stopped | Phase::Failed))
                {
                    return;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            // Leave diagnostics/fence files intact if native cleanup is unknown.
            if let Some(root) = self.root.take() {
                std::mem::forget(root);
            }
        }
    }
    let resources = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../apps/codexu-tauri/src-tauri/resources/provider-pool")
        .canonicalize()
        .expect("required staged provider resources missing");
    let receipt: Value =
        serde_json::from_slice(&std::fs::read(resources.join("WINDOWS-RESOURCES.json")).unwrap())
            .unwrap();
    assert_eq!(receipt["schemaVersion"], 1);
    assert_eq!(receipt["target"], "windows-amd64");
    let source = std::fs::read(resources.join("SOURCE.json")).unwrap();
    assert!(source == include_bytes!("../../../../../Companion/AntigravityProxy/SOURCE.json"));
    let resource = HelperResource::new(
        resources.join("aigoodbro-antigravity-proxy.exe"),
        receipt["files"]["aigoodbro-antigravity-proxy.exe"]["sha256"]
            .as_str()
            .unwrap()
            .into(),
        receipt["files"]["SOURCE.json"]["sha256"]
            .as_str()
            .unwrap()
            .into(),
    )
    .unwrap();
    let root = Root::new();
    let storage = root.0.join("pool");
    let pool = ProviderPool::new(storage.clone(), resource, Arc::new(NeverAuthorize)).unwrap();
    let _cleanup = Cleanup {
        pool: pool.clone(),
        root: Some(root),
    };
    let mut saved_key = None;
    for _ in 0..2 {
        let run = pool.start(None).unwrap().run_id.unwrap();
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            let s = pool.snapshot().unwrap();
            assert!(
                !matches!(s.phase, Phase::Failed),
                "real empty helper failed before ready"
            );
            if s.phase == Phase::Running {
                assert!(s.accounts.is_empty());
                assert_eq!(s.providers.len(), 4);
                break;
            }
            assert!(Instant::now() < deadline, "real helper ready timed out");
            std::thread::sleep(Duration::from_millis(20));
        }
        let store = Store::new(storage.clone(), Arc::new(crate::accounts::DpapiProtector)).unwrap();
        assert!(
            store.owner().is_err(),
            "running native helper must retain its owner fence"
        );
        pool.stop(&run, true).unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while pool.snapshot().unwrap().phase != Phase::Stopped {
            assert!(
                Instant::now() < deadline,
                "native root/Job empty cleanup timed out"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(store.owner().is_ok());
        let (key, accounts) = store.bootstrap().unwrap();
        assert!(accounts.is_empty());
        if let Some(previous) = &saved_key {
            assert!(previous == &key, "DPAPI client key did not survive reopen");
        }
        let sealed = std::fs::read(storage.join("pool-v1.json")).unwrap();
        assert!(!sealed
            .windows(key.len())
            .any(|bytes| bytes == key.as_bytes()));
        saved_key = Some(key);
    }
}

#[test]
fn exit_confirmation_uses_owned_runtime_state_without_decrypting_storage() {
    let h = Harness::new();
    assert!(!h.pool.requires_exit_confirmation());
    assert_eq!(h.protector.reads.load(Ordering::Acquire), 0);
    let run = h.start();
    assert!(h.pool.requires_exit_confirmation());
    h.fake.stop_fails.store(true, Ordering::Release);
    h.pool.stop(&run, true).unwrap();
    wait(|| h.pool.snapshot().unwrap().issue_code == Some("provider_pool_cleanup_unconfirmed"));
    assert!(h.pool.requires_exit_confirmation());
    h.fake.stop_fails.store(false, Ordering::Release);
    h.pool.stop(&run, true).unwrap();
    wait(|| h.pool.snapshot().unwrap().phase == Phase::Stopped);
    assert!(!h.pool.requires_exit_confirmation());
}
