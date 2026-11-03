//! Isolated synthetic vault and injected HTTP responses. No provider request.
use super::*;
use serde_json::json;
use std::sync::atomic::AtomicUsize;
struct Protector {
    fail: AtomicBool,
}
impl SecretProtector for Protector {
    fn seal(&self, _: &str, b: &[u8]) -> AccountResult<Vec<u8>> {
        if self.fail.load(Ordering::Acquire) {
            return Err(fail("fixture_save_failed"));
        }
        Ok(b.iter().map(|v| v ^ 0x6b).collect())
    }
    fn unseal(&self, _: &str, b: &[u8]) -> AccountResult<Vec<u8>> {
        Ok(b.iter().map(|v| v ^ 0x6b).collect())
    }
}
struct Runtime {
    calls: AtomicUsize,
    response: Mutex<(u16, Value)>,
    hook: Mutex<Option<Box<dyn Fn() + Send>>>,
}
impl ActionRuntime for Runtime {
    fn review(
        &self,
        _: &Path,
        _: &StoredCredential,
        _: &dyn Fn() -> AccountResult<()>,
    ) -> AccountResult<Value> {
        panic!("details must not refresh quota")
    }
    fn consume(
        &self,
        _: &Path,
        _: &StoredCredential,
        _: &str,
        _: i64,
        _: &str,
        _: &dyn Fn() -> AccountResult<()>,
    ) -> AccountResult<&'static str> {
        panic!("details must not consume")
    }
    fn http(
        &self,
        _: &StoredCredential,
        r: &HttpRequest,
        admit: &dyn Fn() -> AccountResult<()>,
    ) -> AccountResult<HttpResponse> {
        admit()?;
        assert_eq!(r.path, "/wham/profiles/me");
        assert_eq!(r.method, "GET");
        assert!(r.body.is_none());
        assert!(matches!(r.language.as_str(), "en" | "zh"));
        self.calls.fetch_add(1, Ordering::AcqRel);
        if let Some(hook) = self.hook.lock().unwrap().take() {
            hook();
        }
        let (status, body) = self.response.lock().unwrap().clone();
        Ok(HttpResponse {
            status,
            body: serde_json::to_vec(&body).unwrap(),
        })
    }
}
fn auth(account: &str, expires: i64) -> Vec<u8> {
    let claims = json!({"email":"details@fixture.invalid","account_id":account,"exp":expires,"https://api.openai.com/auth":{"chatgpt_account_id":account,"chatgpt_plan_type":"prolite","chatgpt_subscription_active_until":"2027-01-01T00:00:00Z"}});
    let token = format!(
        "synthetic.{}.signature",
        URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).unwrap())
    );
    serde_json::to_vec(&json!({"tokens":{"access_token":token,"id_token":token,"refresh_token":"synthetic-refresh","account_id":account}})).unwrap()
}
struct Fixture {
    _tmp: tempfile::TempDir,
    service: Arc<ManualAccountService>,
    runtime: Arc<Runtime>,
    protector: Arc<Protector>,
    id: String,
    system: PathBuf,
}
impl Fixture {
    fn new() -> Self {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().canonicalize().unwrap().join("details-fixture");
        storage::create_private_directory(&root).unwrap();
        let root = root.canonicalize().unwrap();
        let system = root.join("system");
        storage::secure_directory(&system).unwrap();
        storage::atomic_write(&system.join("auth.json"), b"synthetic untouched").unwrap();
        let protector = Arc::new(Protector {
            fail: AtomicBool::new(false),
        });
        let manager = AccountManager::with_components(
            AccountPaths::isolated(root.join("vault"), system.clone()).unwrap(),
            protector.clone(),
            Arc::new(NativeAccountRuntime),
            None,
        )
        .unwrap();
        let id = manager
            .create_managed_account("Details fixture".into(), "codex".into())
            .unwrap()
            .id;
        let quota = json!({"accountId":"synthetic-details-account","rateLimits":{"planType":"prolite","primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":ms()/1000+3600},"secondary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":ms()/1000+7200}},"rateLimitResetCredits":{"availableCount":1,"credits":[{"id":"never-export-card","resetType":"codexRateLimits","status":"available","expiresAt":ms()/1000+600}]}});
        let verified = crate::accounts::VerifiedCredential::from_official_read(
            auth("synthetic-details-account", 4102444800),
            &json!({"account":{"type":"chatgpt","email":"details@fixture.invalid"}}),
            quota,
        )
        .unwrap();
        {
            let mut store = manager.store().unwrap();
            store.vault.account_mut(&id).unwrap().credential =
                Some(verified.into_stored("c".repeat(32)));
            store.save().unwrap();
        }
        let runtime = Arc::new(Runtime {
            calls: AtomicUsize::new(0),
            response: Mutex::new((
                200,
                json!({"profile":{"display_name":"Synthetic Name","username":"synthetic-user"},"stats":{"lifetime_tokens":123456,"peak_daily_tokens":789},"metadata":{"stats_as_of":"2026-10-29T00:00:00Z"}}),
            )),
            hook: Mutex::new(None),
        });
        let service = ManualAccountService::with_runtime(manager, runtime.clone(), None).unwrap();
        Self {
            _tmp: tmp,
            service,
            runtime,
            protector,
            id,
            system,
        }
    }
    fn read(&self) -> LocalDetails {
        self.service.local_details(&self.id).unwrap()
    }
    fn refresh(&self) -> LocalDetails {
        self.service.refresh_local_details(&self.id, "en").unwrap()
    }
    fn edit(&self, edit: impl FnOnce(&mut StoredCredential)) {
        let mut store = self.service.manager.store().unwrap();
        edit(
            store
                .vault
                .account_mut(&self.id)
                .unwrap()
                .credential
                .as_mut()
                .unwrap(),
        );
        store.save().unwrap();
    }
    fn unchanged(&self) {
        assert_eq!(
            std::fs::read(self.system.join("auth.json")).unwrap(),
            b"synthetic untouched"
        );
    }
}
fn code<T>(r: AccountResult<T>) -> &'static str {
    match r {
        Err(e) => e.code,
        Ok(_) => panic!("expected failure"),
    }
}
#[test]
fn local_read_is_network_free_and_projects_only_recorded_facts() {
    let f = Fixture::new();
    let d = f.read();
    assert_eq!(f.runtime.calls.load(Ordering::Acquire), 0);
    assert!(d.display_name.is_none());
    assert_eq!(d.email.as_deref(), Some("details@fixture.invalid"));
    assert_eq!(d.masked_account_id.as_deref(), Some("synt…ount"));
    assert_eq!(d.account_type.as_deref(), Some("chatgpt"));
    assert_eq!(d.plan_type.as_deref(), Some("prolite"));
    assert_eq!(d.displayed_pro_tier_multiplier, Some(5));
    assert!(d.subscription_active_until_ms.is_some());
    assert!(d.quota_fresh);
    assert_eq!(d.quota_windows.len(), 2);
    assert_eq!(d.available_reset_cards, Some(1));
    assert_eq!(d.reset_card_expires_at_ms.len(), 1);
    assert!(
        d.added_at_ms.is_some_and(|at| at > 0 && at <= ms())
            && d.chrome_profile_name.is_none()
            && d.model.is_none()
            && d.participating.is_none()
    );
    let wire = serde_json::to_string(&d).unwrap();
    for secret in [
        "never-export-card",
        "synthetic-details-account",
        "synthetic-refresh",
        "access_token",
    ] {
        assert!(!wire.contains(secret));
    }
    f.unchanged();
}
#[test]
fn explicit_refresh_persists_only_typed_profile_fields_and_reopens_cache() {
    let f = Fixture::new();
    let d = f.refresh();
    assert_eq!(d.display_name.as_deref(), Some("Synthetic Name"));
    assert_eq!(d.lifetime_tokens, Some(123456));
    assert!(d.profile_fetched_at_ms.is_some());
    assert_eq!(f.runtime.calls.load(Ordering::Acquire), 1);
    let reopened =
        ManualAccountService::with_runtime(f.service.manager.clone(), f.runtime.clone(), None)
            .unwrap();
    assert_eq!(
        reopened.local_details(&f.id).unwrap().peak_daily_tokens,
        Some(789)
    );
    assert_eq!(f.runtime.calls.load(Ordering::Acquire), 1);
    let bytes = std::fs::read(cache_path(&f.service.manager, &f.id)).unwrap();
    assert!(!String::from_utf8_lossy(&bytes).contains("Synthetic Name"));
    f.unchanged();
}
#[test]
fn legacy_slot_creation_is_unknown_and_never_inferred_from_file_time() {
    let f = Fixture::new();
    {
        let mut store = f.service.manager.store().unwrap();
        store.vault.account_mut(&f.id).unwrap().created_at_ms = None;
        store.save().unwrap();
    }
    assert!(f.read().added_at_ms.is_none());
    assert!(f.refresh().added_at_ms.is_none());
}
#[test]
fn browser_details_project_saved_preference_without_discovery_or_launch() {
    use crate::accounts::browser::{BrowserMode, BrowserPreference};
    let f = Fixture::new();
    for (mode, directory, expected) in [
        (BrowserMode::SystemDefault, None, None),
        (
            BrowserMode::DedicatedChrome,
            None,
            Some("Chrome · dedicated"),
        ),
        (
            BrowserMode::ExistingChrome,
            Some("Profile 2"),
            Some("Profile 2"),
        ),
    ] {
        {
            let mut store = f.service.manager.store().unwrap();
            store.vault.account_mut(&f.id).unwrap().browser = BrowserPreference {
                mode,
                profile_directory: directory.map(str::to_owned),
            };
            store.save().unwrap();
        }
        assert_eq!(f.read().chrome_profile_name.as_deref(), expected);
    }
    assert_eq!(f.runtime.calls.load(Ordering::Acquire), 0);
    f.unchanged();
}
#[test]
fn malformed_fields_are_unknown_not_invented_zero_or_boolean_counts() {
    let f = Fixture::new();
    *f.runtime.response.lock().unwrap() = (
        200,
        json!({"profile":{"display_name":"bad\nname","username":12},"stats":{"lifetime_tokens":true,"peak_daily_tokens":-1},"metadata":{"stats_as_of":"not-date"}}),
    );
    let d = f.refresh();
    assert!(
        d.display_name.is_none()
            && d.username.is_none()
            && d.lifetime_tokens.is_none()
            && d.peak_daily_tokens.is_none()
            && d.stats_as_of_ms.is_none()
    );
    assert_eq!(
        count(Some(&json!(9_007_199_254_740_991i64))),
        Some(9_007_199_254_740_991)
    );
    assert_eq!(count(Some(&json!(9_007_199_254_740_992i64))), None);
}
#[test]
fn expired_credentials_allow_local_history_but_never_refresh() {
    let f = Fixture::new();
    f.refresh();
    f.edit(|c| c.auth = auth("synthetic-details-account", 1));
    assert_eq!(f.read().display_name.as_deref(), Some("Synthetic Name"));
    assert_eq!(
        code(f.service.refresh_local_details(&f.id, "en")),
        "manual_action_identity_changed"
    );
    assert_eq!(f.runtime.calls.load(Ordering::Acquire), 1);
}
#[test]
fn failed_http_or_malformed_profile_keeps_previous_cache() {
    let f = Fixture::new();
    f.refresh();
    let before = std::fs::read(cache_path(&f.service.manager, &f.id)).unwrap();
    for response in [
        (302, json!({})),
        (500, json!({})),
        (200, json!({"profile":{}})),
    ] {
        *f.runtime.response.lock().unwrap() = response;
        assert!(f.service.refresh_local_details(&f.id, "zh").is_err());
        assert_eq!(
            std::fs::read(cache_path(&f.service.manager, &f.id)).unwrap(),
            before
        );
    }
    assert_eq!(f.read().display_name.as_deref(), Some("Synthetic Name"));
}
#[test]
fn relogin_hides_old_identity_cache_and_local_multiplier() {
    let f = Fixture::new();
    f.refresh();
    f.service.set_pro_multiplier(&f.id, Some(25)).unwrap();
    f.edit(|c| {
        c.auth = auth("different-fixture-account", 4102444800);
        c.identity = parse_auth(&c.auth).unwrap().0;
    });
    let d = f.read();
    assert!(d.display_name.is_none());
    assert!(d.pro_tier_multiplier.is_none());
    assert!(d.reset_card_expires_at_ms.is_empty());
}
#[test]
fn identity_change_during_response_prevents_cache_commit() {
    let f = Fixture::new();
    let manager = f.service.manager.clone();
    let id = f.id.clone();
    *f.runtime.hook.lock().unwrap() = Some(Box::new(move || {
        let mut store = manager.store().unwrap();
        let c = store
            .vault
            .account_mut(&id)
            .unwrap()
            .credential
            .as_mut()
            .unwrap();
        c.auth = auth("different-fixture-account", 4102444800);
        c.identity = parse_auth(&c.auth).unwrap().0;
        store.save().unwrap();
    }));
    assert_eq!(
        code(f.service.refresh_local_details(&f.id, "en")),
        "manual_action_identity_changed"
    );
    assert!(!cache_path(&f.service.manager, &f.id).exists());
}
#[test]
fn save_failure_keeps_cached_profile_and_quota_does_not_become_fresh() {
    let f = Fixture::new();
    f.refresh();
    f.edit(|c| c.observed_at = 1);
    let before = std::fs::read(cache_path(&f.service.manager, &f.id)).unwrap();
    f.protector.fail.store(true, Ordering::Release);
    assert!(f.service.refresh_local_details(&f.id, "en").is_err());
    assert_eq!(
        std::fs::read(cache_path(&f.service.manager, &f.id)).unwrap(),
        before
    );
    let d = f.read();
    assert!(!d.quota_fresh);
    assert_eq!(d.quota_checked_at_ms, Some(1000));
}
#[test]
fn multiplier_is_identity_shared_metadata_only_and_invalid_values_do_not_write() {
    let f = Fixture::new();
    let before = f
        .service
        .manager
        .cached_quota_snapshot(&f.id)
        .unwrap()
        .unwrap();
    for n in [5, 10, 20, 25] {
        let d = f.service.set_pro_multiplier(&f.id, Some(n)).unwrap();
        assert_eq!(d.pro_tier_multiplier, Some(n));
        assert_eq!(d.displayed_pro_tier_multiplier, Some(n));
        assert_eq!(d.plan_type.as_deref(), Some("prolite"));
    }
    let identity = f
        .service
        .manager
        .managed_identity_hash(&f.id)
        .unwrap()
        .unwrap();
    let path = metadata_path(&f.service.manager, &identity);
    let bytes = std::fs::read(&path).unwrap();
    assert_eq!(
        code(f.service.set_pro_multiplier(&f.id, Some(7))),
        "account_details_invalid_multiplier"
    );
    assert_eq!(std::fs::read(&path).unwrap(), bytes);
    let alias = f
        .service
        .manager
        .create_managed_account("Alias fixture".into(), "codex".into())
        .unwrap()
        .id;
    {
        let mut store = f.service.manager.store().unwrap();
        let c = store.vault.account(&f.id).unwrap().credential.clone();
        store.vault.account_mut(&alias).unwrap().credential = c;
        store.save().unwrap();
    }
    assert_eq!(
        f.service.local_details(&alias).unwrap().pro_tier_multiplier,
        Some(25)
    );
    let d = f.service.set_pro_multiplier(&alias, None).unwrap();
    assert_eq!(d.pro_tier_multiplier, None);
    assert_eq!(d.displayed_pro_tier_multiplier, Some(5));
    assert_eq!(f.read().pro_tier_multiplier, None);
    assert_eq!(
        f.service
            .manager
            .cached_quota_snapshot(&f.id)
            .unwrap()
            .unwrap()
            .official_quota,
        before.official_quota
    );
    assert_eq!(f.runtime.calls.load(Ordering::Acquire), 0);
    f.unchanged();
}
#[test]
fn unknown_slot_is_empty_and_invalid_language_or_exit_never_fetches() {
    let f = Fixture::new();
    let id = f
        .service
        .manager
        .create_managed_account("Empty fixture".into(), "codex".into())
        .unwrap()
        .id;
    let d = f.service.local_details(&id).unwrap();
    assert!(d.email.is_none() && d.plan_type.is_none());
    assert_eq!(
        code(f.service.refresh_local_details(&f.id, "invalid")),
        "account_details_invalid_request"
    );
    f.service.cancel_for_exit();
    assert_eq!(
        code(f.service.local_details(&f.id)),
        "manual_action_cancelled"
    );
    assert!(f.service.set_pro_multiplier(&f.id, Some(5)).is_err());
    assert_eq!(f.runtime.calls.load(Ordering::Acquire), 0);
}
