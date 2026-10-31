use super::{manifest::*, store::*, *};
use crate::accounts::storage;
use std::{cell::Cell, path::PathBuf};

struct Adapter {
    bridge_root: PathBuf,
    available: Cell<bool>,
    revision: Cell<u8>,
    calls: Cell<usize>,
    revoke_at: Cell<usize>,
}
impl Adapter {
    fn new(bridge_root: PathBuf) -> Self {
        Self {
            bridge_root,
            available: Cell::new(true),
            revision: Cell::new(1),
            calls: Cell::new(0),
            revoke_at: Cell::new(usize::MAX),
        }
    }
}
impl PlatformAdapter for Adapter {
    fn verify(&self, _bundle: &str, abi: u32) -> Result<RuntimeBinding> {
        self.calls.set(self.calls.get() + 1);
        if !self.available.get() || self.calls.get() >= self.revoke_at.get() {
            return Err(fail("companion_platform_adapter_unavailable"));
        }
        let python = if cfg!(windows) {
            PathBuf::from(r"C:\synthetic\python.exe")
        } else {
            PathBuf::from("/synthetic/python.exe")
        };
        RuntimeBinding::new(
            hash(&[self.revision.get()]),
            &python,
            &self.bridge_root,
            abi,
        )
    }
}
struct Fixture {
    _tmp: tempfile::TempDir,
    root: PathBuf,
    pin: BundlePin,
    setup: SetupStore,
    adapter: Adapter,
}
impl Fixture {
    fn new() -> Self {
        let tmp = tempfile::Builder::new()
            .prefix("companion-synthetic-")
            .tempdir_in(std::env::temp_dir().canonicalize().unwrap())
            .unwrap();
        let root = tmp.path().to_path_buf();
        let bundle = root.join("bundle");
        storage::create_private_directory(&bundle).unwrap();
        let app = root.join("app");
        storage::create_private_directory(&app).unwrap();
        let bridge_root = app.join("companion-bridge-v1");
        storage::create_private_directory(&bridge_root).unwrap();
        let bridge_root = bridge_root.canonicalize().unwrap();
        let parent = root.join("skills");
        storage::create_private_directory(&parent).unwrap();
        let mut entries = vec![];
        for (slot, rel, _) in SLOTS {
            let rel = if *slot == "launcher" {
                "bin/next-dispatch.py"
            } else {
                rel
            };
            let target = bundle.join(rel);
            std::fs::create_dir_all(target.parent().unwrap()).unwrap();
            let data = format!("synthetic bundled {slot}\n");
            std::fs::write(&target, &data).unwrap();
            entries
                .push(serde_json::json!({"slot":slot,"path":rel,"sha256":hash(data.as_bytes())}));
        }
        let manifest = serde_json::to_vec(
            &serde_json::json!({"schemaVersion":1,"platform":"windows","adapterABI":1,
            "managedNote":format!("{BEGIN}\nSynthetic runtime note\n{END}"),"files":entries}),
        )
        .unwrap();
        std::fs::write(bundle.join("manifest.json"), &manifest).unwrap();
        let pin = BundlePin::new(bundle, hash(&manifest)).unwrap();
        let setup = SetupStore::new(&app, parent.join("multi-agent-management")).unwrap();
        Self {
            _tmp: tmp,
            root,
            pin,
            setup,
            adapter: Adapter::new(bridge_root),
        }
    }
    fn install(&self) {
        let p = self.setup.prepare(&self.pin, &self.adapter).unwrap();
        self.setup
            .confirm_install(p.plan_id.as_deref().unwrap(), &self.pin, &self.adapter)
            .unwrap();
    }
    fn target(&self, rel: &str) -> PathBuf {
        self.root.join("skills/multi-agent-management").join(rel)
    }
    fn update_bundle(&mut self, path: &str, text: &str) {
        std::fs::write(self.pin.root.join(path), text).unwrap();
        let mp = self.pin.root.join("manifest.json");
        let mut m: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&mp).unwrap()).unwrap();
        for e in m["files"].as_array_mut().unwrap() {
            if e["path"] == path {
                e["sha256"] = hash(text.as_bytes()).into();
            }
        }
        let bytes = serde_json::to_vec(&m).unwrap();
        std::fs::write(mp, &bytes).unwrap();
        self.pin.sha256 = hash(&bytes);
    }
}

#[test]
fn runtime_binding_requires_existing_owned_canonical_bridge_root_without_writes() {
    let f = Fixture::new();
    let python = if cfg!(windows) {
        PathBuf::from(r"C:\synthetic\python.exe")
    } else {
        PathBuf::from("/synthetic/python.exe")
    };
    let missing = f.root.join("missing-bridge");
    let file = f.root.join("not-directory");
    storage::atomic_write(&file, b"unchanged").unwrap();
    let mut parent = f.adapter.bridge_root.as_os_str().to_os_string();
    parent.push(std::path::MAIN_SEPARATOR_STR);
    parent.push("..");
    parent.push(std::path::MAIN_SEPARATOR_STR);
    parent.push("companion-bridge-v1");
    for path in [
        missing.clone(),
        file.clone(),
        PathBuf::from("relative-root"),
        PathBuf::from(parent),
    ] {
        assert!(RuntimeBinding::new(hash(b"adapter"), &python, &path, 1).is_err());
    }
    assert!(!missing.exists());
    assert_eq!(std::fs::read(file).unwrap(), b"unchanged");
    let bound = RuntimeBinding::new(hash(b"adapter"), &python, &f.adapter.bridge_root, 1).unwrap();
    let other = f.root.join("other-owned-bridge");
    storage::create_private_directory(&other).unwrap();
    let other = other.canonicalize().unwrap();
    let changed = RuntimeBinding::new(hash(b"adapter"), &python, &other, 1).unwrap();
    assert_ne!(bound.fingerprint, changed.fingerprint);
}

#[cfg(unix)]
#[test]
fn runtime_binding_rejects_link_without_changing_target_permissions() {
    use std::os::unix::fs::{symlink, PermissionsExt};
    let f = Fixture::new();
    let mode = std::fs::metadata(&f.adapter.bridge_root)
        .unwrap()
        .permissions()
        .mode();
    let link = f.root.join("linked-bridge");
    symlink(&f.adapter.bridge_root, &link).unwrap();
    assert!(RuntimeBinding::new(
        hash(b"adapter"),
        PathBuf::from("/synthetic/python.exe").as_path(),
        &link,
        1
    )
    .is_err());
    assert_eq!(
        std::fs::metadata(&f.adapter.bridge_root)
            .unwrap()
            .permissions()
            .mode(),
        mode
    );
    assert!(std::fs::symlink_metadata(link)
        .unwrap()
        .file_type()
        .is_symlink());
}

#[test]
fn unavailable_adapter_never_creates_skill_or_claims_ready() {
    let f = Fixture::new();
    f.adapter.available.set(false);
    assert_eq!(
        f.setup.inspect(&f.pin, &f.adapter).state,
        State::Unavailable
    );
    assert!(f.setup.prepare(&f.pin, &f.adapter).is_err());
    assert!(!f.target("").exists());
}
#[cfg(target_os = "macos")]
#[test]
fn actual_installed_layout_is_read_by_the_bundled_launcher_main() {
    let mut f = Fixture::new();
    let source = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../companion")
        .canonicalize()
        .unwrap();
    let bundle = f.root.join("actual-production-bundle");
    // Stage the actual pinned payload and manifest via its real production
    // staging implementation. Only the output is this fixture's temporary tree.
    let staged = std::process::Command::new("/usr/bin/python3")
        .args(["-I", "-B", "-c",
            "import importlib.util,sys; from pathlib import Path; s=importlib.util.spec_from_file_location('production_stage',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); m.stage(Path(sys.argv[2]))"])
        .arg(source.join("prepare.py")).arg(&bundle).output().unwrap();
    assert!(
        staged.status.success(),
        "production stage failed: {}",
        String::from_utf8_lossy(&staged.stderr)
    );
    f.pin = BundlePin::new(
        bundle.clone(),
        hash(&std::fs::read(bundle.join("manifest.json")).unwrap()),
    )
    .unwrap();
    assert_eq!(Bundle::load(&f.pin).unwrap().files.len(), 16);
    f.install();
    assert!(!f.target("config/dispatch-codes-v1.json").exists());
    assert!(!f.target("config/dispatch-policy-v1.json").exists());
    let payload: serde_json::Value =
        serde_json::from_slice(&std::fs::read(bundle.join("manifest.json")).unwrap()).unwrap();
    for file in payload["files"].as_array().unwrap() {
        let relative = file["path"].as_str().unwrap();
        if relative != "SKILL.md" {
            assert_eq!(
                std::fs::read(f.target(relative)).unwrap(),
                std::fs::read(bundle.join(relative)).unwrap()
            );
        }
    }
    assert_eq!(f.setup.inspect(&f.pin, &f.adapter).state, State::Ready);
    f.adapter.available.set(false);
    assert_eq!(
        f.setup.inspect(&f.pin, &f.adapter).state,
        State::Unavailable
    );
    f.adapter.available.set(true);
    let checker = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../companion/test_client.py")
        .canonicalize()
        .unwrap();
    // Only pure stdlib/module code runs. The checker replaces WinTransport,
    // so this cannot connect to a pipe, start the App or submit a Hub request.
    let output = std::process::Command::new("/usr/bin/python3")
        .args(["-I", "-B", "-c",
            "import importlib.util,sys; from pathlib import Path; s=importlib.util.spec_from_file_location('layout_check',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); m.verify_installed_layout(Path(sys.argv[2]))"])
        .arg(checker).arg(f.target("bin/next-dispatch.py"))
        .output().unwrap();
    assert!(
        output.status.success(),
        "synthetic installed layout contract failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}
#[test]
fn initial_install_is_explicit_and_reopen_reads_exact_ready() {
    let f = Fixture::new();
    assert_eq!(f.setup.inspect(&f.pin, &f.adapter).state, State::Missing);
    assert!(!f.target("").exists());
    let plan = f.setup.prepare(&f.pin, &f.adapter).unwrap();
    assert_eq!(plan.files.len(), 18); // 16 actual payloads plus two runtime bindings.
    assert!(!f.target("").exists());
    let r = f
        .setup
        .confirm_install(plan.plan_id.as_deref().unwrap(), &f.pin, &f.adapter)
        .unwrap();
    assert_eq!(r.state, State::Ready);
    let reopened = SetupStore::new(&f.root.join("app"), f.target("")).unwrap();
    assert_eq!(reopened.inspect(&f.pin, &f.adapter).state, State::Ready);
    assert!(reopened
        .prepare(&f.pin, &f.adapter)
        .unwrap()
        .plan_id
        .is_none());
    assert_eq!(
        std::fs::read_to_string(f.target("bin/next-dispatch.py")).unwrap(),
        "synthetic bundled launcher\n"
    );
    let config: serde_json::Value =
        serde_json::from_slice(&std::fs::read(f.target("config/runtime-paths.json")).unwrap())
            .unwrap();
    assert_eq!(config.as_object().unwrap().len(), 4);
    assert_eq!(config["schemaVersion"], 1);
    assert_eq!(config["adapterABI"], 1);
    assert_eq!(
        config["bridgeRoot"],
        f.adapter.bridge_root.to_str().unwrap()
    );
    assert!(config["python"].as_str().is_some());
}
#[test]
fn update_preserves_user_body_unmanaged_config_and_unrelated_files() {
    let mut f = Fixture::new();
    f.install();
    let skill = f.target("SKILL.md");
    let old = std::fs::read_to_string(&skill).unwrap();
    let user = format!("CUSTOM PREFIX\n{old}\nCUSTOM SUFFIX");
    std::fs::write(&skill, &user).unwrap();
    std::fs::write(f.target("config/dispatch-policy-v1.json"), "user policy").unwrap();
    std::fs::write(f.target("config/dispatch-codes-v1.json"), "user mapping").unwrap();
    std::fs::write(f.target("private-user-note.md"), "unrelated").unwrap();
    f.update_bundle(
        "scripts/next_dispatch_activity.py",
        "new synthetic adapter\n",
    );
    let p = f.setup.prepare(&f.pin, &f.adapter).unwrap();
    assert_eq!(p.files.len(), 12);
    let r = f
        .setup
        .confirm_install(p.plan_id.as_deref().unwrap(), &f.pin, &f.adapter)
        .unwrap();
    assert!(r.backup_available);
    assert_eq!(std::fs::read_to_string(skill).unwrap(), user);
    assert_eq!(
        std::fs::read_to_string(f.target("config/dispatch-policy-v1.json")).unwrap(),
        "user policy"
    );
    assert_eq!(
        std::fs::read_to_string(f.target("config/dispatch-codes-v1.json")).unwrap(),
        "user mapping"
    );
    assert_eq!(
        std::fs::read_to_string(f.target("private-user-note.md")).unwrap(),
        "unrelated"
    );
}
#[test]
fn malformed_managed_markers_and_unrecognized_directory_refuse_without_writes() {
    let f = Fixture::new();
    storage::create_private_directory(&f.target("")).unwrap();
    std::fs::write(f.target("unrelated.txt"), "keep").unwrap();
    assert_eq!(
        f.setup.prepare(&f.pin, &f.adapter).unwrap_err().code,
        "companion_unrecognized_installation"
    );
    storage::atomic_write(
        &f.target("SKILL.md"),
        format!("before{BEGIN}broken").as_bytes(),
    )
    .unwrap();
    assert_eq!(
        f.setup.prepare(&f.pin, &f.adapter).unwrap_err().code,
        "companion_managed_section_conflict"
    );
    assert_eq!(
        std::fs::read_to_string(f.target("unrelated.txt")).unwrap(),
        "keep"
    );
}
#[test]
fn bundle_hash_platform_slot_and_payload_checks_are_real() {
    let f = Fixture::new();
    std::fs::write(f.pin.root.join("references/coordination.md"), "changed").unwrap();
    assert_eq!(
        f.setup.prepare(&f.pin, &f.adapter).unwrap_err().code,
        "companion_bundle_changed"
    );
    assert!(!f.target("").exists());
    let f = Fixture::new();
    let mp = f.pin.root.join("manifest.json");
    let mut m: serde_json::Value = serde_json::from_slice(&std::fs::read(&mp).unwrap()).unwrap();
    m["platform"] = "darwin".into();
    let b = serde_json::to_vec(&m).unwrap();
    std::fs::write(mp, &b).unwrap();
    let pin = BundlePin::new(f.pin.root.clone(), hash(&b)).unwrap();
    assert!(f.setup.prepare(&pin, &f.adapter).is_err());
}
#[test]
fn stale_resource_runtime_or_user_bytes_cannot_apply_old_confirmation() {
    for change in 0..4 {
        let mut f = Fixture::new();
        f.install();
        f.update_bundle("references/runtime-setup.md", "updated\n");
        let p = f.setup.prepare(&f.pin, &f.adapter).unwrap();
        match change {
            0 => f.update_bundle("references/runtime-setup.md", "updated twice\n"),
            1 => f.adapter.revision.set(2),
            2 => std::fs::write(f.target("references/runtime-setup.md"), "USER LATEST").unwrap(),
            _ => {
                let moved = f.root.join("other-bridge");
                storage::create_private_directory(&moved).unwrap();
                f.adapter.bridge_root = moved.canonicalize().unwrap();
            }
        }
        assert_eq!(
            f.setup
                .confirm_install(p.plan_id.as_deref().unwrap(), &f.pin, &f.adapter)
                .unwrap_err()
                .code,
            "companion_plan_stale"
        );
        if change == 2 {
            assert_eq!(
                std::fs::read_to_string(f.target("references/runtime-setup.md")).unwrap(),
                "USER LATEST"
            );
        }
    }
}
#[test]
fn each_initial_write_failure_rolls_back_and_can_prepare_again() {
    for fail_at in 0..18 {
        let f = Fixture::new();
        let p = f.setup.prepare(&f.pin, &f.adapter).unwrap();
        let e = f
            .setup
            .apply_with(p.plan_id.as_deref().unwrap(), &f.pin, &f.adapter, |i, _| {
                if i == fail_at {
                    Err(fail("synthetic_write_failure"))
                } else {
                    Ok(())
                }
            })
            .unwrap_err();
        assert_eq!(e.code, "synthetic_write_failure");
        for status in p.files {
            assert!(!f.target(&status.path).exists());
        }
        assert!(f
            .setup
            .prepare(&f.pin, &f.adapter)
            .unwrap()
            .plan_id
            .is_some());
    }
}
#[test]
fn update_failure_restores_exact_backup_bytes() {
    let mut f = Fixture::new();
    f.install();
    let path = "references/runtime-setup.md";
    let old = std::fs::read(f.target(path)).unwrap();
    f.update_bundle(path, "replacement\n");
    let p = f.setup.prepare(&f.pin, &f.adapter).unwrap();
    assert_eq!(
        f.setup
            .apply_with(p.plan_id.as_deref().unwrap(), &f.pin, &f.adapter, |_, _| {
                Err(fail("synthetic_failure"))
            })
            .unwrap_err()
            .code,
        "synthetic_failure"
    );
    assert_eq!(std::fs::read(f.target(path)).unwrap(), old);
    let backup = f
        .root
        .join("app/companion-setup-v1")
        .join(format!("backup-{}", p.plan_id.unwrap()))
        .join("0.txt");
    assert_eq!(std::fs::read(backup).unwrap(), old);
}
#[test]
fn simulated_crash_retains_intent_and_recovery_does_not_reapply() {
    let f = Fixture::new();
    let p = f.setup.prepare(&f.pin, &f.adapter).unwrap();
    let caught = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _ = f
            .setup
            .apply_with(p.plan_id.as_deref().unwrap(), &f.pin, &f.adapter, |i, _| {
                if i == 3 {
                    panic!("synthetic crash after persisted write");
                }
                Ok(())
            });
    }));
    assert!(caught.is_err());
    let reopened = SetupStore::new(&f.root.join("app"), f.target("")).unwrap();
    assert_eq!(reopened.inspect(&f.pin, &f.adapter).state, State::Conflict);
    f.adapter.available.set(false);
    reopened.recover().unwrap();
    reopened.recover().unwrap();
    for status in p.files {
        assert!(!f.target(&status.path).exists());
    }
}
#[test]
fn concurrent_edit_is_retained_and_never_reported_rolled_back() {
    let f = Fixture::new();
    let p = f.setup.prepare(&f.pin, &f.adapter).unwrap();
    let err = f
        .setup
        .apply_with(
            p.plan_id.as_deref().unwrap(),
            &f.pin,
            &f.adapter,
            |_, path| {
                std::fs::write(path, "CONCURRENT USER").unwrap();
                Err(fail("synthetic_failure"))
            },
        )
        .unwrap_err();
    assert_eq!(err.code, "companion_rollback_conflict");
    assert_eq!(
        std::fs::read_to_string(f.target("SKILL.md")).unwrap(),
        "CONCURRENT USER"
    );
    assert!(f.setup.recover().is_err());
    assert!(f.setup.prepare(&f.pin, &f.adapter).is_err());
}
#[test]
fn capability_revocation_mid_apply_rolls_back_without_ready() {
    let f = Fixture::new();
    let p = f.setup.prepare(&f.pin, &f.adapter).unwrap();
    f.adapter.revoke_at.set(f.adapter.calls.get() + 4);
    assert!(f
        .setup
        .confirm_install(p.plan_id.as_deref().unwrap(), &f.pin, &f.adapter)
        .is_err());
    for status in p.files {
        assert!(!f.target(&status.path).exists());
    }
}
#[test]
fn duplicate_confirmation_and_transaction_lock_do_not_write_again() {
    let f = Fixture::new();
    let p = f.setup.prepare(&f.pin, &f.adapter).unwrap();
    let id = p.plan_id.unwrap();
    let lock = storage::StoreLock::acquire(&f.root.join("app/companion-setup-v1")).unwrap();
    assert!(f.setup.confirm_install(&id, &f.pin, &f.adapter).is_err());
    assert!(!f.target("").exists());
    drop(lock);
    f.setup.confirm_install(&id, &f.pin, &f.adapter).unwrap();
    let data = std::fs::read(f.target("SKILL.md")).unwrap();
    assert!(f.setup.confirm_install(&id, &f.pin, &f.adapter).is_err());
    assert_eq!(std::fs::read(f.target("SKILL.md")).unwrap(), data);
}
#[cfg(unix)]
#[test]
fn existing_directory_mode_unchanged_and_links_or_hardlinks_rejected() {
    use std::os::unix::fs::{symlink, PermissionsExt};
    let f = Fixture::new();
    std::fs::create_dir(f.target("")).unwrap();
    std::fs::set_permissions(f.target(""), std::fs::Permissions::from_mode(0o755)).unwrap();
    f.install();
    assert_eq!(
        std::fs::metadata(f.target(""))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o755
    );
    let outside = f.root.join("outside.md");
    std::fs::write(&outside, "never overwritten").unwrap();
    std::fs::remove_file(f.target("SKILL.md")).unwrap();
    symlink(&outside, f.target("SKILL.md")).unwrap();
    assert!(f.setup.prepare(&f.pin, &f.adapter).is_err());
    std::fs::remove_file(f.target("SKILL.md")).unwrap();
    std::fs::hard_link(&outside, f.target("SKILL.md")).unwrap();
    assert!(f.setup.prepare(&f.pin, &f.adapter).is_err());
    assert_eq!(
        std::fs::read_to_string(outside).unwrap(),
        "never overwritten"
    );
}
#[test]
fn plan_target_binding_prevents_cross_scope_reuse() {
    let f = Fixture::new();
    let p = f.setup.prepare(&f.pin, &f.adapter).unwrap();
    let other = SetupStore::new(&f.root.join("app"), f.root.join("skills/other")).unwrap();
    assert_eq!(
        other
            .confirm_install(p.plan_id.as_deref().unwrap(), &f.pin, &f.adapter)
            .unwrap_err()
            .code,
        "companion_plan_invalid"
    );
    assert!(!f.root.join("skills/other").exists());
}

#[test]
fn failed_plan_or_backup_persistence_never_changes_target_bytes() {
    let f = Fixture::new();
    let state = f.root.join("app/companion-setup-v1");
    storage::create_private_directory(&state).unwrap();
    std::fs::create_dir(state.join("plan.json")).unwrap();
    assert!(f.setup.prepare(&f.pin, &f.adapter).is_err());
    assert!(!f.target("").exists());

    let mut f = Fixture::new();
    f.install();
    let path = "references/runtime-setup.md";
    let old = std::fs::read(f.target(path)).unwrap();
    f.update_bundle(path, "new controlled document\n");
    let p = f.setup.prepare(&f.pin, &f.adapter).unwrap();
    let id = p.plan_id.unwrap();
    let backup = f
        .root
        .join("app/companion-setup-v1")
        .join(format!("backup-{id}"));
    storage::create_private_directory(&backup).unwrap();
    std::fs::create_dir(backup.join("0.txt")).unwrap();
    assert!(f.setup.confirm_install(&id, &f.pin, &f.adapter).is_err());
    assert_eq!(std::fs::read(f.target(path)).unwrap(), old);
}

#[test]
fn replaced_target_directory_is_not_adopted_during_recovery() {
    let f = Fixture::new();
    let p = f.setup.prepare(&f.pin, &f.adapter).unwrap();
    let moved = f.root.join("retained-original-target");
    let result = f
        .setup
        .apply_with(p.plan_id.as_deref().unwrap(), &f.pin, &f.adapter, |_, _| {
            std::fs::rename(f.target(""), &moved).unwrap();
            std::fs::create_dir(f.target("")).unwrap();
            std::fs::write(f.target("SKILL.md"), "replacement directory user content").unwrap();
            Err(fail("synthetic_root_replaced"))
        });
    assert_eq!(result.unwrap_err().code, "companion_rollback_conflict");
    assert!(f.setup.recover().is_err());
    assert_eq!(
        std::fs::read_to_string(f.target("SKILL.md")).unwrap(),
        "replacement directory user content"
    );
    assert!(moved.join("SKILL.md").is_file());
}
