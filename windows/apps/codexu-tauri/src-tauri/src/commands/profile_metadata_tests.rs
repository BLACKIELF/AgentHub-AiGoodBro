use super::*;
use codexu_core::accounts::{
    AccountIdentity, AccountPaths, AccountResult, AccountRuntime, LoginAuthorization,
    SecretProtector, VerifiedCredential,
};
use std::{path::Path, sync::atomic::AtomicBool};
struct Protector;
impl SecretProtector for Protector {
    fn seal(&self, _: &str, b: &[u8]) -> AccountResult<Vec<u8>> {
        Ok(b.iter().map(|b| b ^ 0x65).collect())
    }
    fn unseal(&self, _: &str, b: &[u8]) -> AccountResult<Vec<u8>> {
        Ok(b.iter().map(|b| b ^ 0x65).collect())
    }
}
struct Runtime;
impl AccountRuntime for Runtime {
    fn available(&self) -> bool {
        false
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
        panic!("metadata cannot change live processes")
    }
    fn validate_target_configuration(&self, _: &Path) -> AccountResult<()> {
        panic!("metadata cannot inspect auth")
    }
}
struct Fixture {
    _temp: tempfile::TempDir,
    manager: Arc<AccountManager>,
    config: AppConfig,
    settings: PathBuf,
    ids: Vec<String>,
}
impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let paths = AccountPaths::isolated(root.join("vault"), root.join("system")).unwrap();
        let manager = AccountManager::with_components(
            paths.clone(),
            Arc::new(Protector),
            Arc::new(Runtime),
            None,
        )
        .unwrap();
        let mut config = AppConfig::default();
        let mut ids = vec![];
        for label in ["Legacy A", "Legacy B"] {
            let id = manager
                .create_managed_account(label.into(), "codex".into())
                .unwrap()
                .id;
            let home = paths.vault_root.join("desktop").join(&id);
            std::fs::create_dir_all(&home).unwrap();
            config
                .profiles
                .add(LocalCliKind::Codex, label.into(), home)
                .unwrap();
            ids.push(id);
        }
        let linked = root.join("ordinary");
        std::fs::create_dir(&linked).unwrap();
        config
            .profiles
            .add(LocalCliKind::Codex, "Ordinary".into(), linked)
            .unwrap();
        let settings = root.join("app");
        config.save(&settings).unwrap();
        Self {
            _temp: temp,
            manager,
            config,
            settings: settings.join("settings.json"),
            ids,
        }
    }
}
#[test]
fn managed_rename_projects_both_entries_and_empty_restores_without_catalog_write() {
    let f = Fixture::new();
    let original = std::fs::read(&f.settings).unwrap();
    for (input, want) in [("New remark", "New remark"), ("", "Legacy A")] {
        assert!(managed_action(
            &f.config,
            Some(&f.manager),
            &ProfileAction::Rename {
                id: "1".into(),
                label: input.into()
            }
        )
        .unwrap());
        assert_eq!(project(&f.config, Some(&f.manager)).unwrap()[0].label, want);
        assert_eq!(f.manager.list_managed_accounts().unwrap()[0].label, want);
        assert_eq!(std::fs::read(&f.settings).unwrap(), original);
    }
}
#[test]
fn managed_move_changes_vault_order_and_projection_without_rewriting_linked_settings() {
    let f = Fixture::new();
    let original = std::fs::read(&f.settings).unwrap();
    assert!(managed_action(
        &f.config,
        Some(&f.manager),
        &ProfileAction::Move {
            id: "1".into(),
            delta: 1
        }
    )
    .unwrap());
    assert_eq!(f.manager.list_managed_accounts().unwrap()[0].id, f.ids[1]);
    let rows = project(&f.config, Some(&f.manager)).unwrap();
    assert_eq!(
        rows.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(),
        vec!["2", "1", "3"]
    );
    assert_eq!(std::fs::read(&f.settings).unwrap(), original);
}
#[test]
fn ordinary_linked_alias_keeps_existing_catalog_route_and_missing_service_cannot_fork_managed_alias(
) {
    let mut f = Fixture::new();
    assert!(!managed_action(
        &f.config,
        Some(&f.manager),
        &ProfileAction::Rename {
            id: "3".into(),
            label: "Linked rename".into()
        }
    )
    .unwrap());
    f.config.profiles.rename(3, "Linked rename".into()).unwrap();
    assert_eq!(
        project(&f.config, Some(&f.manager)).unwrap()[2].label,
        "Linked rename"
    );
    assert!(!project(&f.config, Some(&f.manager)).unwrap()[2].managed);
    assert!(managed_action(
        &f.config,
        None,
        &ProfileAction::Rename {
            id: "1".into(),
            label: "Wrong store".into()
        }
    )
    .is_err());
    assert_eq!(
        f.manager.list_managed_accounts().unwrap()[0].label,
        "Legacy A"
    );
}
