use super::*;
use serde_json::json;
use std::sync::atomic::AtomicUsize;
struct Protector;
impl SecretProtector for Protector {
    fn seal(&self, _: &str, b: &[u8]) -> AccountResult<Vec<u8>> {
        Ok(b.iter().map(|v| v ^ 0x6b).collect())
    }
    fn unseal(&self, c: &str, b: &[u8]) -> AccountResult<Vec<u8>> {
        self.seal(c, b)
    }
}
struct FakeBrowser {
    available: bool,
    profiles: Vec<ChromeProfile>,
    profile_root: Option<PathBuf>,
    opens: AtomicUsize,
}
impl FakeBrowser {
    fn new() -> Self {
        Self {
            available: true,
            profiles: vec![ChromeProfile {
                directory_name: "Profile 2".into(),
                display_name: "Fixture".into(),
            }],
            profile_root: None,
            opens: AtomicUsize::new(0),
        }
    }
}
impl BrowserRuntime for FakeBrowser {
    fn profiles(&self) -> AccountResult<Vec<ChromeProfile>> {
        if let Some(root) = &self.profile_root {
            return profiles_at(root);
        }
        Ok(self.profiles.clone())
    }
    fn available(&self) -> bool {
        self.available
    }
    fn open(&self, plan: &Plan, admit: &dyn Fn() -> AccountResult<()>) -> AccountResult<()> {
        admit()?;
        if let Plan::Chrome(args) = plan {
            assert_eq!(args.last().unwrap(), LOGIN_URL);
        }
        self.opens.fetch_add(1, Ordering::AcqRel);
        Ok(())
    }
}
struct Fixture {
    _temp: tempfile::TempDir,
    root: PathBuf,
    manager: Arc<AccountManager>,
    id: String,
}
impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap().join("browser-fixture");
        storage::secure_directory(&root).unwrap();
        let system = root.join("system");
        storage::secure_directory(&system).unwrap();
        storage::atomic_write(&system.join("auth.json"), b"untouched synthetic system").unwrap();
        let manager = AccountManager::with_components(
            AccountPaths::isolated(root.join("vault"), system).unwrap(),
            Arc::new(Protector),
            Arc::new(NativeAccountRuntime),
            None,
        )
        .unwrap();
        let id = manager
            .create_managed_account("Fixture slot".into(), "codex".into())
            .unwrap()
            .id;
        Self {
            _temp: temp,
            root,
            manager,
            id,
        }
    }
    fn attempt(&self) -> String {
        let id = "a".repeat(32);
        self.manager.attempts.lock().unwrap().insert(
            id.clone(),
            Attempt {
                dto: LoginAttemptDto {
                    attempt_id: id.clone(),
                    account_id: self.id.clone(),
                    phase: "waiting",
                    verification_url: Some(LOGIN_URL.into()),
                    user_code: Some("TEST-1234".into()),
                    error_code: None,
                },
                cancelled: Arc::new(AtomicBool::new(false)),
            },
        );
        id
    }
}
#[test]
fn legacy_record_defaults_and_real_creation_time_are_distinct() {
    let f = Fixture::new();
    let r = f
        .manager
        .store()
        .unwrap()
        .vault
        .account(&f.id)
        .unwrap()
        .clone();
    assert!(r.created_at_ms.is_some_and(|v| v > 0));
    assert!(r.browser.mode == BrowserMode::SystemDefault);
    let mut v = serde_json::to_value(&r).unwrap();
    v.as_object_mut().unwrap().remove("created_at_ms");
    v.as_object_mut().unwrap().remove("browser");
    let old: AccountRecord = serde_json::from_value(v).unwrap();
    assert!(old.created_at_ms.is_none());
    assert!(old.browser.valid());
}
#[test]
fn settings_save_is_metadata_only_and_missing_profile_keeps_original() {
    let f = Fixture::new();
    let runtime = FakeBrowser::new();
    let p = BrowserPreference {
        mode: BrowserMode::ExistingChrome,
        profile_directory: Some("Profile 2".into()),
    };
    f.manager
        .set_browser_with(&f.id, p.clone(), &runtime)
        .unwrap();
    assert!(f.manager.browser_preference(&f.id).unwrap() == p);
    assert_eq!(runtime.opens.load(Ordering::Acquire), 0);
    assert!(!f.root.join("vault/browser").exists());
    assert!(f
        .manager
        .set_browser_with(
            &f.id,
            BrowserPreference {
                mode: BrowserMode::ExistingChrome,
                profile_directory: Some("Profile 3".into())
            },
            &runtime
        )
        .is_err());
    assert!(f.manager.browser_preference(&f.id).unwrap() == p);
    assert_eq!(
        std::fs::read(f.root.join("system/auth.json")).unwrap(),
        b"untouched synthetic system"
    );
}
#[test]
fn malformed_profile_metadata_allows_safe_fallback_but_never_existing_selection() {
    let f = Fixture::new();
    let mut runtime = FakeBrowser::new();
    let existing = BrowserPreference {
        mode: BrowserMode::ExistingChrome,
        profile_directory: Some("Profile 2".into()),
    };
    f.manager
        .set_browser_with(&f.id, existing.clone(), &runtime)
        .unwrap();
    let root = f.root.join("malformed-chrome");
    storage::secure_directory(&root).unwrap();
    storage::atomic_write(&root.join("Local State"), b"not JSON").unwrap();
    runtime.profile_root = Some(root);
    let current = f.manager.browser_settings_with(&f.id, &runtime).unwrap();
    assert!(current.mode == BrowserMode::ExistingChrome);
    assert_eq!(
        current.profile_scan_issue,
        Some("browser_profiles_unavailable")
    );
    assert!(current.profiles.is_empty());
    for mode in [BrowserMode::SystemDefault, BrowserMode::DedicatedChrome] {
        let preference = BrowserPreference {
            mode,
            profile_directory: None,
        };
        let settings = f
            .manager
            .set_browser_with(&f.id, preference.clone(), &runtime)
            .unwrap();
        assert!(f.manager.browser_preference(&f.id).unwrap() == preference);
        assert_eq!(
            settings.profile_scan_issue,
            Some("browser_profiles_unavailable")
        );
        assert!(settings.profiles.is_empty());
        assert!(f
            .manager
            .set_browser_with(&f.id, existing.clone(), &runtime)
            .is_err());
        assert!(f.manager.browser_preference(&f.id).unwrap() == preference);
    }
    assert!(f.manager.browser_plan(&f.id, &existing, &runtime).is_err());
    assert_eq!(runtime.opens.load(Ordering::Acquire), 0);
    assert!(!f.root.join("vault/browser").exists());
}
#[test]
fn dedicated_profiles_are_unique_and_never_copy_shared_browser_state() {
    let f = Fixture::new();
    let runtime = FakeBrowser::new();
    let second = f
        .manager
        .create_managed_account("Second".into(), "codex".into())
        .unwrap()
        .id;
    let p = BrowserPreference {
        mode: BrowserMode::DedicatedChrome,
        profile_directory: None,
    };
    let Plan::Chrome(a) = f.manager.browser_plan(&f.id, &p, &runtime).unwrap() else {
        panic!()
    };
    let Plan::Chrome(b) = f.manager.browser_plan(&second, &p, &runtime).unwrap() else {
        panic!()
    };
    assert_ne!(a[0], b[0]);
    assert!(a[0].to_string_lossy().contains(&f.id));
    assert!(a.iter().any(|v| v == "--profile-directory=Default"));
    assert!(a.iter().any(|v| v == "--no-first-run"));
    assert!(std::fs::read_dir(f.root.join("vault/browser").join(&f.id))
        .unwrap()
        .next()
        .is_none());
    assert_eq!(runtime.opens.load(Ordering::Acquire), 0);
}
#[test]
fn unsupported_or_traversal_profile_names_are_rejected() {
    for name in [
        "../Default",
        "Profile /2",
        "Profile 2/..",
        "Profile -1",
        "Profile ２",
        "--remote-debugging-port=9222",
        "",
    ] {
        assert!(!valid_directory(name));
    }
    assert!(valid_directory("Default"));
    assert!(valid_directory("Profile 22"));
    let f = Fixture::new();
    assert!(f
        .manager
        .set_browser_with(
            &f.id,
            BrowserPreference {
                mode: BrowserMode::DedicatedChrome,
                profile_directory: Some("Default".into())
            },
            &FakeBrowser::new()
        )
        .is_err());
}
#[test]
fn local_state_enumeration_is_bounded_metadata_only() {
    let f = Fixture::new();
    let root = f.root.join("synthetic-chrome");
    storage::secure_directory(&root.join("Default")).unwrap();
    storage::secure_directory(&root.join("Profile 2")).unwrap();
    storage::atomic_write(&root.join("Local State"),&serde_json::to_vec(&json!({"profile":{"info_cache":{"Default":{"name":"Personal","user_name":"secret@fixture.invalid"},"Profile 2":{"name":"private@fixture.invalid"},"../other":{"name":"outside"}}}})).unwrap()).unwrap();
    let list = profiles_at(&root).unwrap();
    assert_eq!(list.len(), 2);
    assert_eq!(list[1].display_name, "Profile 2");
    let text = serde_json::to_string(&list).unwrap();
    assert!(!text.contains("fixture.invalid"));
    assert!(!root.join("Default/Cookies").exists());
}
#[test]
fn missing_chrome_never_falls_back_to_shared_system_browser() {
    let f = Fixture::new();
    let mut r = FakeBrowser::new();
    r.available = false;
    let pref = BrowserPreference {
        mode: BrowserMode::DedicatedChrome,
        profile_directory: None,
    };
    assert!(f.manager.browser_plan(&f.id, &pref, &r).is_err());
    assert!(!f.root.join("vault/browser").exists());
    assert_eq!(r.opens.load(Ordering::Acquire), 0);
}
#[test]
fn only_current_waiting_attempt_can_open_and_cancel_blocks_replay() {
    let f = Fixture::new();
    let r = FakeBrowser::new();
    let attempt = f.attempt();
    f.manager.open_login_browser_with(&attempt, &r).unwrap();
    assert_eq!(r.opens.load(Ordering::Acquire), 1);
    f.manager.cancel_account_login(&attempt).unwrap();
    assert!(f.manager.open_login_browser_with(&attempt, &r).is_err());
    assert_eq!(r.opens.load(Ordering::Acquire), 1);
}
#[cfg(unix)]
#[test]
fn linked_profile_or_owned_directory_is_rejected() {
    let f = Fixture::new();
    let root = f.root.join("synthetic-chrome");
    storage::secure_directory(&root).unwrap();
    std::os::unix::fs::symlink(&f.root, root.join("Default")).unwrap();
    storage::atomic_write(
        &root.join("Local State"),
        br#"{"profile":{"info_cache":{"Default":{"name":"linked"}}}}"#,
    )
    .unwrap();
    assert!(profiles_at(&root).is_err());
    storage::secure_directory(&f.root.join("vault/browser")).unwrap();
    std::os::unix::fs::symlink(&f.root, f.root.join("vault/browser").join(&f.id)).unwrap();
    assert!(f
        .manager
        .browser_plan(
            &f.id,
            &BrowserPreference {
                mode: BrowserMode::DedicatedChrome,
                profile_directory: None
            },
            &FakeBrowser::new()
        )
        .is_err());
}
