use super::*;
struct Fixture {
    _temp: tempfile::TempDir,
    store: RecommendationStore,
}
impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let resources = root.join("resources");
        std::fs::create_dir(&resources).unwrap();
        std::fs::write(resources.join("catalog.json"), CATALOG).unwrap();
        for (name, skill, info) in PACKAGES {
            let directory = resources.join(name);
            std::fs::create_dir(&directory).unwrap();
            std::fs::write(directory.join("SKILL.md"), skill).unwrap();
            std::fs::write(directory.join("安装说明.md"), info).unwrap();
        }
        let home = root.join("home");
        std::fs::create_dir(&home).unwrap();
        let store = RecommendationStore::new(&root.join("app"), &resources, &home).unwrap();
        Self { _temp: temp, store }
    }
    fn install(&self, alias: &str, text: &str) {
        let path = self.store.home.join(".codex/skills").join(alias);
        std::fs::create_dir_all(&path).unwrap();
        std::fs::write(path.join("SKILL.md"), text).unwrap();
    }
    fn saved(&self) -> Vec<u8> {
        std::fs::read(self.store.root.join("visibility.json")).unwrap()
    }
}
fn row(snapshot: &Snapshot, id: &str) -> Item {
    snapshot.items.iter().find(|x| x.id == id).unwrap().clone()
}
#[test]
fn pinned_catalog_has_six_real_entries_and_no_implicit_probe_or_install() {
    let f = Fixture::new();
    f.install("oracle", "---\nname: oracle\n---\nfixture");
    let s = f.store.snapshot().unwrap();
    assert_eq!(s.items.len(), 6);
    assert_eq!(s.checked_at_ms, None);
    assert_eq!(row(&s, "oracle").presence, Presence::Unknown);
    assert!(row(&s, "oracle").package_available);
    assert!(!row(&s, "aihot").can_install);
    assert_eq!(row(&s, "quicktoggle").presence, Presence::NotApplicable);
    assert!(!f.store.root.exists());
}
#[test]
fn hide_restore_and_presence_survive_reopen_without_restoring_installed_items() {
    let f = Fixture::new();
    f.store.set_hidden("handoff", true).unwrap();
    f.install("oracle", "---\nname: oracle\n---\nfixture");
    let checked = f.store.recheck(1000).unwrap();
    assert!(row(&checked, "handoff").hidden);
    assert_eq!(row(&checked, "oracle").presence, Presence::Installed);
    let reopened = RecommendationStore::new(
        f.store.root.parent().unwrap(),
        &f.store.resources,
        &f.store.home,
    )
    .unwrap();
    assert!(row(&reopened.snapshot().unwrap(), "handoff").hidden);
    let restored = reopened.restore_hidden().unwrap();
    assert!(!row(&restored, "handoff").hidden);
    assert_eq!(row(&restored, "oracle").presence, Presence::Installed);
    assert_eq!(restored.checked_at_ms, Some(1000));
}
#[test]
fn recheck_uses_exact_fixed_alias_frontmatter_and_keeps_unknown_distinct() {
    let f = Fixture::new();
    f.install(
        "handoffskill",
        "---\r\nname: 'handoffskill'\r\n---\r\nfixture",
    );
    f.install("oracle", "---\nname: oracle\nname: oracle\n---");
    f.install("jev-use", "---\nname: 'jev-use\n---");
    let s = f.store.recheck(1000).unwrap();
    assert_eq!(row(&s, "handoff").presence, Presence::Installed);
    assert_eq!(row(&s, "oracle").presence, Presence::Unknown);
    assert_eq!(row(&s, "jev-use").presence, Presence::Unknown);
    assert_eq!(row(&s, "rea").presence, Presence::NotInstalled);
    assert_eq!(row(&s, "aihot").presence, Presence::Unknown);
}
#[test]
fn unavailable_or_changed_package_has_no_install_or_private_path_dto() {
    let f = Fixture::new();
    let prompt = f.store.install_prompt("oracle").unwrap();
    assert!(prompt.contains("SKILL.md"));
    assert!(prompt.contains("不调用模型"));
    let s = f.store.snapshot().unwrap();
    let json = serde_json::to_string(&s).unwrap();
    assert!(!json.contains(&f.store.resources.to_string_lossy().to_string()));
    std::fs::write(f.store.resources.join("oracle/SKILL.md"), "replaced").unwrap();
    assert!(!row(&f.store.snapshot().unwrap(), "oracle").can_install);
    assert!(f.store.install_prompt("oracle").is_err());
    assert!(f.store.package_directory("oracle").is_err());
    assert!(f.store.install_prompt("quicktoggle").is_err());
    assert!(f.store.install_prompt("aihot").is_err());
    assert!(f.store.package_directory("../oracle").is_err());
}
#[test]
fn corrupt_state_busy_and_changed_catalog_never_overwrite_previous_bytes() {
    let f = Fixture::new();
    f.store.set_hidden("oracle", true).unwrap();
    let before = f.saved();
    let lock = storage::StoreLock::acquire(&f.store.root).unwrap();
    assert!(f.store.set_hidden("handoff", true).is_err());
    assert_eq!(f.saved(), before);
    drop(lock);
    std::fs::write(f.store.root.join("visibility.json"), b"{broken").unwrap();
    assert!(f.store.restore_hidden().is_err());
    assert_eq!(f.saved(), b"{broken");
    std::fs::write(f.store.resources.join("catalog.json"), b"{}").unwrap();
    assert!(f.store.recheck(2000).is_err());
    assert_eq!(f.saved(), b"{broken");
}
#[test]
fn snapshot_after_readonly_recheck_reports_local_presence_not_runtime_readiness() {
    let f = Fixture::new();
    f.install("oracle", "---\nname: oracle\n---\nfixture");
    f.store.recheck(1200).unwrap();
    let s = f.store.snapshot().unwrap();
    assert_eq!(row(&s, "oracle").presence, Presence::Installed);
    std::fs::remove_file(f.store.home.join(".codex/skills/oracle/SKILL.md")).unwrap();
    assert_eq!(
        row(&f.store.snapshot().unwrap(), "oracle").presence,
        Presence::Installed
    );
    assert_eq!(
        row(&f.store.recheck(1300).unwrap(), "oracle").presence,
        Presence::Unknown
    );
}
#[cfg(unix)]
#[test]
fn linked_and_hardlinked_skill_or_package_cannot_claim_verified_presence() {
    use std::os::unix::fs::symlink;
    let f = Fixture::new();
    let outside = f.store.home.join("outside");
    std::fs::create_dir(&outside).unwrap();
    std::fs::write(outside.join("SKILL.md"), "---\nname: oracle\n---").unwrap();
    let base = f.store.home.join(".codex/skills");
    std::fs::create_dir_all(&base).unwrap();
    symlink(&outside, base.join("oracle")).unwrap();
    assert_eq!(
        row(&f.store.recheck(1000).unwrap(), "oracle").presence,
        Presence::Unknown
    );
    let path = f.store.resources.join("oracle/SKILL.md");
    std::fs::hard_link(&path, f.store.home.join("second-link")).unwrap();
    assert!(f.store.package_directory("oracle").is_err());
}
