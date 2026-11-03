//! Actual vault/home projection with synthetic credentials; no native launch or network.
use super::*;
use crate::accounts::{
    AccountIdentity, AccountPaths, AccountRuntime, LoginAuthorization, SecretProtector,
    VerifiedCredential,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use std::sync::{atomic::AtomicBool, Arc};

struct Protector;
impl SecretProtector for Protector {
    fn seal(&self, _: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
        Ok(bytes.iter().map(|b| b ^ 0x61).collect())
    }
    fn unseal(&self, context: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
        self.seal(context, bytes)
    }
}
struct NoRuntime;
impl AccountRuntime for NoRuntime {
    fn available(&self) -> bool {
        false
    }
    fn login(
        &self,
        _: &Path,
        _: &AtomicBool,
        _: &mut dyn FnMut(LoginAuthorization),
    ) -> AccountResult<VerifiedCredential> {
        panic!("snapshot must not log in")
    }
    fn verify(&self, _: &Path, _: &AccountIdentity) -> AccountResult<VerifiedCredential> {
        panic!("snapshot must not make official reads")
    }
    fn require_system_idle(&self) -> AccountResult<()> {
        panic!("snapshot must not manage processes")
    }
    fn validate_target_configuration(&self, _: &Path) -> AccountResult<()> {
        panic!("snapshot must not change system configuration")
    }
}
fn auth(account: &str, expiry: i64, generation: &str) -> Vec<u8> {
    let token =
        format!("synthetic.{}.fixture", URL_SAFE_NO_PAD.encode(serde_json::to_vec(&json!({
        "email":"hub@fixture.invalid", "account_id":account, "exp":expiry, "jti":generation
    })).unwrap()));
    serde_json::to_vec(&json!({"tokens":{"access_token":token,"id_token":token,"refresh_token":"synthetic-secret-not-exported","account_id":account}})).unwrap()
}
fn verified(bytes: Vec<u8>) -> VerifiedCredential {
    VerifiedCredential::from_official_read(bytes,
        &json!({"account":{"type":"chatgpt","email":"hub@fixture.invalid","planType":"plus"}}),
        json!({"rateLimits":{"planType":"plus","primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":4102444800i64},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":4102444800i64}}}),
    ).unwrap()
}
struct Fixture {
    _temporary: tempfile::TempDir,
    manager: Arc<AccountManager>,
    id: String,
    home: PathBuf,
    initial_auth: Vec<u8>,
}
impl Fixture {
    fn new() -> Self {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap();
        let system = root.join("system");
        storage::secure_directory(&system).unwrap();
        storage::atomic_write(
            &system.join("auth.json"),
            b"synthetic system remains unchanged",
        )
        .unwrap();
        let manager = AccountManager::with_components(
            AccountPaths::isolated(root.join("vault"), system).unwrap(),
            Arc::new(Protector),
            Arc::new(NoRuntime),
            None,
        )
        .unwrap();
        let id = manager
            .create_managed_account("Hub fixture".into(), "codex".into())
            .unwrap()
            .id;
        let initial_auth = auth("workspace-hub", 4102444800, "first");
        {
            let mut store = manager.store().unwrap();
            store.vault.account_mut(&id).unwrap().credential =
                Some(verified(initial_auth.clone()).into_stored("a".repeat(32)));
            store.save().unwrap();
        }
        let home = manager.paths.desktop(&id).unwrap();
        storage::secure_directory(&home).unwrap();
        storage::atomic_write(&home.join("auth.json"), &initial_auth).unwrap();
        Self {
            _temporary: temporary,
            manager,
            id,
            home,
            initial_auth,
        }
    }
    fn project(&self) -> AccountResult<Value> {
        self.manager
            .hub_account_snapshot(&self.id)?
            .manager_profile(
                "account-1",
                &crate::workflow::WorkflowPreference {
                    participating: true,
                    model: Some("gpt-6-sol".into()),
                    effort: Some("high".into()),
                    revision: 7,
                    ..Default::default()
                },
            )
    }
    fn edit(&self, edit: impl FnOnce(&mut crate::accounts::identity::StoredCredential)) {
        let mut store = self.manager.store().unwrap();
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
}
fn code<T>(result: AccountResult<T>) -> &'static str {
    match result {
        Ok(_) => panic!("expected rejection"),
        Err(e) => e.code,
    }
}

#[test]
fn fresh_binding_pins_actual_home_auth_and_original_quota_time() {
    let f = Fixture::new();
    let observed = crate::accounts::now() - 12;
    f.edit(|c| c.observed_at = observed);
    let value = f.project().unwrap();
    let binding = &value["windowsBinding"];
    assert_eq!(binding["authSha256"], auth_digest(&f.initial_auth));
    assert_eq!(
        binding["identityHash"],
        AccountIdentity::from_auth(&f.initial_auth)
            .unwrap()
            .identity_hash()
    );
    assert_eq!(binding["credentialExpiresAtMs"], 4102444800000i64);
    assert_eq!(binding["quotaObservedAtMs"], observed * 1000);
    assert_eq!(binding["workflowRevision"], 7);
    assert_eq!(value["codexHomePath"], json!(f.home));
    assert_eq!(value["isSystemProfile"], false);
    let wire = value.to_string();
    assert!(!wire.contains("access_token"));
    assert!(!wire.contains("refresh_token"));
    assert!(!wire.contains("synthetic-secret-not-exported"));
    assert_eq!(
        std::fs::read(f.manager.paths.system_home.join("auth.json")).unwrap(),
        b"synthetic system remains unchanged"
    );
}

#[test]
fn actual_same_identity_rotated_home_is_pinned_without_using_stale_vault_bytes() {
    let f = Fixture::new();
    let rotated = auth("workspace-hub", 4102444799, "rotated-home");
    storage::atomic_write(&f.home.join("auth.json"), &rotated).unwrap();
    let value = f.project().unwrap();
    assert_eq!(value["windowsBinding"]["authSha256"], auth_digest(&rotated));
    assert_ne!(
        value["windowsBinding"]["authSha256"],
        auth_digest(&f.initial_auth)
    );
    assert_eq!(
        value["windowsBinding"]["credentialExpiresAtMs"],
        4102444799000i64
    );
}

#[test]
fn stale_future_or_failed_official_quota_cannot_be_refreshed_by_snapshot_collection() {
    for scenario in ["stale", "future", "failed"] {
        let f = Fixture::new();
        f.edit(|c| match scenario {
            "stale" => c.observed_at = crate::accounts::now() - 46,
            "future" => c.observed_at = crate::accounts::now() + 60,
            _ => c.quota = json!({}),
        });
        assert_eq!(code(f.project()), "evidence_stale", "{scenario}");
    }
}

#[test]
fn changed_home_identity_expired_auth_and_unrepresentable_expiry_are_rejected() {
    for bytes in [
        auth("other-workspace", 4102444800, "other"),
        auth("workspace-hub", crate::accounts::now() + 20, "expiring"),
        auth("workspace-hub", i64::MAX, "overflow"),
    ] {
        let f = Fixture::new();
        storage::atomic_write(&f.home.join("auth.json"), &bytes).unwrap();
        assert_eq!(code(f.project()), "identity_unverified");
    }
}

#[test]
fn replaced_slot_identity_cannot_reuse_its_old_home() {
    let f = Fixture::new();
    f.edit(|c| {
        *c = verified(auth("new-workspace", 4102444800, "new-slot")).into_stored("b".repeat(32))
    });
    assert_eq!(code(f.project()), "identity_unverified");
}

#[test]
fn missing_home_auth_and_unmanaged_system_id_are_rejected() {
    let f = Fixture::new();
    assert_eq!(
        code(f.manager.hub_account_snapshot("system")),
        "hub_registration_required"
    );
    std::fs::remove_file(f.home.join("auth.json")).unwrap();
    assert_eq!(code(f.project()), "login_required");
}

#[test]
fn duplicate_identity_keeps_existing_shared_terminal_exclusion() {
    let f = Fixture::new();
    let snapshot = f.manager.hub_account_snapshot(&f.id).unwrap();
    let gate = crate::managed_proxy::ManagedProxyGate::new(
        f._temporary.path().canonicalize().unwrap().join("dispatch"),
        &f.manager,
    )
    .unwrap();
    let _first = gate.reserve_terminal(&snapshot.identity_hash).unwrap();
    assert!(matches!(
        gate.reserve_terminal(&snapshot.identity_hash),
        Err(crate::proxy::ProxyFailure::AccountBusy)
    ));
    assert!(matches!(
        gate.reserve_terminal("system"),
        Err(crate::proxy::ProxyFailure::Identity)
    ));
}

#[cfg(unix)]
#[test]
fn linked_home_cannot_redirect_snapshot_to_system_home() {
    let f = Fixture::new();
    std::fs::remove_file(f.home.join("auth.json")).unwrap();
    std::fs::remove_dir(&f.home).unwrap();
    std::os::unix::fs::symlink(&f.manager.paths.system_home, &f.home).unwrap();
    assert!(f.project().is_err());
    assert_eq!(
        std::fs::read(f.manager.paths.system_home.join("auth.json")).unwrap(),
        b"synthetic system remains unchanged"
    );
}
