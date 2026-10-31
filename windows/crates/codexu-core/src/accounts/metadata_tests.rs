use super::*;
use crate::accounts::{
    AccountIdentity, AccountPaths, AccountRuntime, LoginAuthorization, VerifiedCredential,
};
use std::path::Path;
use std::sync::atomic::AtomicBool;
struct Protector(Arc<AtomicBool>);
impl SecretProtector for Protector {
    fn seal(&self, _: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
        if self.0.load(Ordering::SeqCst) {
            Err(fail("synthetic_save_failed"))
        } else {
            Ok(bytes.iter().map(|b| b ^ 0x75).collect())
        }
    }
    fn unseal(&self, _: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
        Ok(bytes.iter().map(|b| b ^ 0x75).collect())
    }
}
struct Runtime;
impl AccountRuntime for Runtime {
    fn available(&self) -> bool {
        false
    }
    fn validate_target_configuration(&self, _: &Path) -> AccountResult<()> {
        panic!("metadata cannot inspect runtime settings")
    }
    fn login(
        &self,
        _: &Path,
        _: &AtomicBool,
        _: &mut dyn FnMut(LoginAuthorization),
    ) -> AccountResult<VerifiedCredential> {
        panic!("metadata cannot login")
    }
    fn verify(&self, _: &Path, _: &AccountIdentity) -> AccountResult<VerifiedCredential> {
        panic!("metadata cannot verify")
    }
    fn require_system_idle(&self) -> AccountResult<()> {
        panic!("metadata cannot inspect or change live process")
    }
}
struct Fixture {
    _temp: tempfile::TempDir,
    paths: AccountPaths,
    fail: Arc<AtomicBool>,
    manager: Arc<AccountManager>,
}
impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let base = temp.path().canonicalize().unwrap();
        let paths = AccountPaths::isolated(base.join("vault"), base.join("system")).unwrap();
        let fail = Arc::new(AtomicBool::new(false));
        let manager = AccountManager::with_components(
            paths.clone(),
            Arc::new(Protector(fail.clone())),
            Arc::new(Runtime),
            None,
        )
        .unwrap();
        Self {
            _temp: temp,
            paths,
            fail,
            manager,
        }
    }
    fn add(&self, label: &str) -> String {
        self.manager
            .create_managed_account(label.into(), "codex".into())
            .unwrap()
            .id
    }
    fn ids(&self) -> Vec<String> {
        self.manager
            .list_managed_accounts()
            .unwrap()
            .into_iter()
            .map(|a| a.id)
            .collect()
    }
    fn reopen(&self) -> Arc<AccountManager> {
        AccountManager::with_components(
            self.paths.clone(),
            Arc::new(Protector(self.fail.clone())),
            Arc::new(Runtime),
            None,
        )
        .unwrap()
    }
}
#[test]
fn unicode_remark_uses_extended_graphemes_and_empty_restores_legacy_alias() {
    let f = Fixture::new();
    let id = f.add("Legacy alias");
    for unit in ["👨‍👩‍👧‍👦", "e\u{301}", "🇨🇳"] {
        f.manager
            .rename_managed_account(&id, format!(" {} ", unit.repeat(41)))
            .unwrap();
        assert_eq!(
            f.manager.list_managed_accounts().unwrap()[0].label,
            unit.repeat(40)
        );
        assert_eq!(
            f.reopen().list_managed_accounts().unwrap()[0].label,
            unit.repeat(40)
        );
        assert_eq!(
            f.manager.store().unwrap().vault.account(&id).unwrap().label,
            "Legacy alias"
        );
    }
    f.manager
        .rename_managed_account(&id, " \r\n ".into())
        .unwrap();
    assert_eq!(
        f.reopen().list_managed_accounts().unwrap()[0].label,
        "Legacy alias"
    );
    for bad in ["a\0b", "email@fixture.invalid", "x/y"] {
        assert!(f.manager.rename_managed_account(&id, bad.into()).is_err());
    }
}
#[test]
fn failed_metadata_save_retains_prior_alias_order_and_legacy_records_decode() {
    let f = Fixture::new();
    let a = f.add("A");
    let b = f.add("B");
    let old = f.ids();
    let raw = serde_json::to_value(f.manager.store().unwrap().vault.account(&a).unwrap()).unwrap();
    assert!(raw.get("remark").is_none());
    let legacy: AccountRecord = serde_json::from_value(raw).unwrap();
    assert!(legacy.remark.is_none());
    f.fail.store(true, Ordering::SeqCst);
    assert!(f
        .manager
        .rename_managed_account(&a, "Changed".into())
        .is_err());
    assert!(f.manager.reorder_managed_accounts(&[b, a], &old).is_err());
    f.fail.store(false, Ordering::SeqCst);
    assert_eq!(f.ids(), old);
    assert_eq!(f.reopen().list_managed_accounts().unwrap()[0].label, "A");
}
#[test]
fn order_is_full_id_cas_and_keeps_credentials_fields_new_accounts_and_other_vaults() {
    let f = Fixture::new();
    let a = f.add("A");
    let b = f.add("B");
    let c = f.add("C");
    let old = f.ids();
    let next = vec![c.clone(), a.clone(), b.clone()];
    let before = f
        .manager
        .store()
        .unwrap()
        .vault
        .accounts
        .iter()
        .map(|r| (r.id.clone(), serde_json::to_value(r).unwrap()))
        .collect::<std::collections::BTreeMap<_, _>>();
    assert_eq!(
        f.manager.reorder_managed_accounts(&next, &old).unwrap(),
        next
    );
    assert_eq!(
        f.reopen()
            .list_managed_accounts()
            .unwrap()
            .into_iter()
            .map(|r| r.id)
            .collect::<Vec<_>>(),
        next
    );
    let after = f
        .manager
        .store()
        .unwrap()
        .vault
        .accounts
        .iter()
        .map(|r| (r.id.clone(), serde_json::to_value(r).unwrap()))
        .collect::<std::collections::BTreeMap<_, _>>();
    assert_eq!(before, after);
    assert_eq!(
        f.manager
            .reorder_managed_accounts(&old, &old)
            .unwrap_err()
            .code,
        "account_order_changed"
    );
    for invalid in [
        vec![a.clone(), a.clone(), c.clone()],
        vec![a.clone()],
        vec![a, b, "claude-other-provider-id".into()],
    ] {
        assert_eq!(
            f.manager
                .reorder_managed_accounts(&invalid, &next)
                .unwrap_err()
                .code,
            "invalid_account_order"
        );
    }
    let d = f.add("D");
    let mut appended = next;
    appended.push(d);
    assert_eq!(f.ids(), appended);
    assert!(!f.paths.vault_root.join("subscriptions.dpapi").exists());
}

#[test]
fn home_projection_shares_remark_and_order_without_writing_catalog_or_other_provider() {
    use crate::local_cli::LocalCliKind;
    let f = Fixture::new();
    let a = f.add("A");
    let b = f.add("B");
    let ar = f.paths.desktop(&a).unwrap();
    let br = f.paths.desktop(&b).unwrap();
    storage::secure_directory(&ar).unwrap();
    storage::secure_directory(&br).unwrap();
    let mut catalog = crate::profiles::ProfileCatalog::default();
    catalog
        .add(LocalCliKind::Codex, "old A".into(), ar)
        .unwrap();
    catalog
        .add(
            LocalCliKind::ClaudeCode,
            "Other provider".into(),
            f.paths.vault_root.parent().unwrap().join("claude"),
        )
        .unwrap();
    catalog
        .add(LocalCliKind::Codex, "old B".into(), br)
        .unwrap();
    let unchanged = serde_json::to_value(&catalog).unwrap();
    f.manager
        .rename_managed_account(&a, "Remark A".into())
        .unwrap();
    let rows = f.manager.project_profile_metadata(&catalog).unwrap();
    assert_eq!(rows[0].label, "Remark A");
    assert_eq!(rows[1].label, "Other provider");
    let ids = f.ids();
    f.manager
        .reorder_managed_accounts(&[b.clone(), a.clone()], &ids)
        .unwrap();
    let rows = f.manager.project_profile_metadata(&catalog).unwrap();
    assert_eq!(rows.iter().map(|r| r.id).collect::<Vec<_>>(), [3, 2, 1]);
    assert_eq!(rows[1].managed_id, None);
    assert!(f
        .manager
        .move_projected_managed_profile(&catalog, 1, -1)
        .unwrap());
    assert_eq!(f.ids(), vec![a.clone(), b]);
    f.manager.rename_managed_account(&a, String::new()).unwrap();
    assert_eq!(
        f.manager.project_profile_metadata(&catalog).unwrap()[0].label,
        "A"
    );
    assert_eq!(serde_json::to_value(&catalog).unwrap(), unchanged);
}

#[test]
fn noncanonical_parent_alias_is_rejected_before_projection() {
    let f = Fixture::new();
    let id = f.add("A");
    let root = f.paths.desktop(&id).unwrap();
    storage::secure_directory(&root.join("child")).unwrap();
    let mut catalog = crate::profiles::ProfileCatalog::default();
    catalog
        .add(
            crate::local_cli::LocalCliKind::Codex,
            "A".into(),
            root.clone(),
        )
        .unwrap();
    catalog
        .add(crate::local_cli::LocalCliKind::Codex, "Alias".into(), {
            let mut raw = root.join("child").into_os_string();
            raw.push(if cfg!(windows) { "\\.." } else { "/.." });
            let path = PathBuf::from(raw);
            assert!(path
                .components()
                .any(|c| matches!(c, std::path::Component::ParentDir)));
            path
        })
        .unwrap();
    assert_eq!(
        f.manager
            .project_profile_metadata(&catalog)
            .unwrap_err()
            .code,
        "account_paths_invalid"
    );
}
