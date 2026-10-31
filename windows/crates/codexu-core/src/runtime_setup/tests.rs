use super::*;
use std::{
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
};
struct Fake {
    calls: AtomicUsize,
    fail: bool,
}
impl Probe for Fake {
    fn inspect(&self, path: &Path, home: &Path) -> Result<String> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        assert!(path.is_absolute());
        assert!(home.is_dir());
        assert!(!home.join("auth.json").exists());
        if self.fail {
            Err(fail("runtime_capability_missing"))
        } else {
            Ok("0.154.0".into())
        }
    }
}
struct Fixture {
    temp: tempfile::TempDir,
    store: SelectionStore,
    a: PathBuf,
    b: PathBuf,
}
impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let store = SelectionStore::new(&root.join("app")).unwrap();
        let a = root.join("first.exe");
        let b = root.join("second.exe");
        for p in [&a, &b] {
            let mut bytes = vec![0; 256];
            bytes[..2].copy_from_slice(b"MZ");
            bytes[60..64].copy_from_slice(&64u32.to_le_bytes());
            bytes[64..68].copy_from_slice(b"PE\0\0");
            let machine = if cfg!(target_arch = "aarch64") {
                0xaa64u16
            } else {
                0x8664
            };
            bytes[68..70].copy_from_slice(&machine.to_le_bytes());
            bytes[88..90].copy_from_slice(b"\x0b\x02");
            std::fs::write(p, bytes).unwrap();
        }
        Self { temp, store, a, b }
    }
    fn settings(&self) -> PathBuf {
        self.temp
            .path()
            .canonicalize()
            .unwrap()
            .join("app/runtime-setup-v1/codex.json")
    }
}
fn probe(fail: bool) -> Fake {
    Fake {
        calls: AtomicUsize::new(0),
        fail,
    }
}
#[test]
fn explicit_selection_roundtrips_and_new_instance_reads_same_held_image() {
    let f = Fixture::new();
    let p = probe(false);
    let view = f.store.choose(&f.a, &p).unwrap();
    assert_eq!(view.state, "ready");
    assert!(view.selected);
    let next = SelectionStore::new(&f.temp.path().canonicalize().unwrap().join("app")).unwrap();
    assert_eq!(next.selected().unwrap().unwrap().path, f.a);
    assert_eq!(p.calls.load(Ordering::SeqCst), 1);
    let json = std::fs::read_to_string(f.settings()).unwrap();
    assert!(!json.contains("token"));
    assert_eq!(
        std::fs::read_dir(f.settings().parent().unwrap())
            .unwrap()
            .filter_map(|x| x.ok())
            .filter(|x| x.file_name().to_string_lossy().starts_with("probe-"))
            .count(),
        0
    );
}
#[test]
fn failed_capability_preserves_old_selection() {
    let f = Fixture::new();
    f.store.choose(&f.a, &probe(false)).unwrap();
    let before = std::fs::read(f.settings()).unwrap();
    assert_eq!(
        f.store.choose(&f.b, &probe(true)).unwrap_err().code,
        "runtime_capability_missing"
    );
    assert_eq!(std::fs::read(f.settings()).unwrap(), before);
    assert_eq!(f.store.selected().unwrap().unwrap().path, f.a);
}
#[test]
fn changed_selected_image_fails_closed_without_automatic_fallback() {
    let f = Fixture::new();
    f.store.choose(&f.a, &probe(false)).unwrap();
    let mut bytes = std::fs::read(&f.a).unwrap();
    bytes[200] = 1;
    std::fs::write(&f.a, bytes).unwrap();
    let p = probe(false);
    let view = f.store.inspect(&[f.b.clone()], &p);
    assert_ne!(view.state, "ready");
    assert_eq!(view.issue_code, Some("runtime_selection_changed"));
    assert!(view.selected);
    assert_eq!(p.calls.load(Ordering::SeqCst), 0);
}
#[test]
fn unknown_corrupt_selection_is_not_overwritten_by_inspection() {
    let f = Fixture::new();
    f.store.choose(&f.a, &probe(false)).unwrap();
    let before = b"not-json";
    std::fs::write(f.settings(), before).unwrap();
    let p = probe(false);
    let view = f.store.inspect(&[f.b.clone()], &p);
    assert_eq!(view.state, "unavailable");
    assert_eq!(p.calls.load(Ordering::SeqCst), 0);
    assert_eq!(std::fs::read(f.settings()).unwrap(), before);
}
#[test]
fn absent_selection_uses_only_bounded_candidates_without_saving_preference() {
    let f = Fixture::new();
    let p = probe(false);
    let view = f
        .store
        .inspect(&[f.temp.path().join("missing.exe"), f.b.clone()], &p);
    assert_eq!(view.state, "ready");
    assert!(!view.selected);
    assert!(!f.settings().exists());
    assert_eq!(p.calls.load(Ordering::SeqCst), 1);
}
#[test]
fn invalid_paths_and_images_never_execute_probe() {
    let f = Fixture::new();
    let p = probe(false);
    for candidate in [
        PathBuf::from("relative.exe"),
        f.temp.path().join("x/../first.exe"),
    ] {
        assert!(f.store.choose(&candidate, &p).is_err());
    }
    std::fs::write(&f.a, b"not an executable").unwrap();
    assert!(f.store.choose(&f.a, &p).is_err());
    assert_eq!(p.calls.load(Ordering::SeqCst), 0);
    assert!(!f.settings().exists());
}
#[test]
fn uncertain_probe_cleanup_preserves_its_private_home_and_prior_selection() {
    struct Unknown;
    impl Probe for Unknown {
        fn inspect(&self, _: &Path, home: &Path) -> Result<String> {
            std::fs::write(home.join("owned-evidence"), b"fixture").unwrap();
            Err(fail("cleanup_unconfirmed"))
        }
    }
    let f = Fixture::new();
    f.store.choose(&f.a, &probe(false)).unwrap();
    let before = std::fs::read(f.settings()).unwrap();
    assert_eq!(
        f.store.choose(&f.b, &Unknown).unwrap_err().code,
        "cleanup_unconfirmed"
    );
    assert_eq!(std::fs::read(f.settings()).unwrap(), before);
    assert_eq!(
        std::fs::read_dir(f.settings().parent().unwrap())
            .unwrap()
            .filter_map(|x| x.ok())
            .filter(|x| x.file_name().to_string_lossy().starts_with("probe-"))
            .count(),
        1
    );
}
#[test]
fn exclusive_selection_lock_blocks_second_probe() {
    let f = Fixture::new();
    let _lock =
        crate::accounts::storage::StoreLock::acquire(f.settings().parent().unwrap()).unwrap();
    let p = probe(false);
    assert_eq!(
        f.store.choose(&f.a, &p).unwrap_err().code,
        "runtime_setup_busy"
    );
    assert_eq!(p.calls.load(Ordering::SeqCst), 0);
}

#[test]
fn capability_probe_uses_only_bounded_non_account_commands() {
    let mut calls = vec![];
    let version = super::probe::inspect_with(|args, limit, seconds| {
        calls.push((
            args.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
            limit,
            seconds,
        ));
        if args == ["--version"] {
            Ok(b"codex-cli 0.154.0\r\n".to_vec())
        } else {
            Ok(b"--output-last-message PATH --sandbox MODE --model MODEL".to_vec())
        }
    })
    .unwrap();
    assert_eq!(version, "0.154.0");
    assert_eq!(
        calls,
        vec![
            (vec!["--version".into()], 1024, 2),
            (vec!["exec".into(), "--help".into()], 65536, 3)
        ]
    );
}
#[test]
fn wrong_binary_or_missing_capability_never_becomes_ready() {
    let mut count = 0;
    let err = super::probe::inspect_with(|_, _, _| {
        count += 1;
        Ok(b"another-cli 0.154.0".to_vec())
    })
    .unwrap_err();
    assert_eq!(err.code, "runtime_version_invalid");
    assert_eq!(count, 1);
    for absent in ["--output-last-message", "--sandbox", "--model"] {
        let err = super::probe::inspect_with(|args, _, _| {
            if args == ["--version"] {
                Ok(b"codex-cli 0.154.0".to_vec())
            } else {
                Ok(["--output-last-message", "--sandbox", "--model"]
                    .into_iter()
                    .filter(|v| *v != absent)
                    .collect::<Vec<_>>()
                    .join(" ")
                    .into_bytes())
            }
        })
        .unwrap_err();
        assert_eq!(err.code, "runtime_capability_missing");
    }
}
#[test]
#[cfg(unix)]
fn failed_save_does_not_replace_foreign_link_or_prior_settings_bytes() {
    let f = Fixture::new();
    f.store.choose(&f.a, &probe(false)).unwrap();
    let before = std::fs::read(f.settings()).unwrap();
    let original = f.settings().with_file_name("retained-codex.json");
    std::fs::rename(f.settings(), &original).unwrap();
    std::os::unix::fs::symlink(&original, f.settings()).unwrap();
    let result = f.store.choose(&f.b, &probe(false));
    assert_eq!(result.unwrap_err().code, "runtime_save_failed");
    assert!(std::fs::symlink_metadata(f.settings())
        .unwrap()
        .file_type()
        .is_symlink());
    assert_eq!(std::fs::read(original).unwrap(), before);
}

#[test]
fn every_failed_final_process_proof_is_preserved_as_cleanup_unknown() {
    struct Unconfirmed(&'static str);
    impl Probe for Unconfirmed {
        fn inspect(&self, _: &Path, _: &Path) -> Result<String> {
            super::require_confirmed_cleanup(Err(fail(self.0)))?;
            Ok("0.154.0".into())
        }
    }
    let f = Fixture::new();
    for code in [
        "native_process_unavailable",
        "cleanup_unconfirmed",
        "operation_cancelled",
    ] {
        assert_eq!(
            f.store.choose(&f.a, &Unconfirmed(code)).unwrap_err().code,
            "cleanup_unconfirmed"
        );
    }
    assert_eq!(
        std::fs::read_dir(f.settings().parent().unwrap())
            .unwrap()
            .filter_map(|x| x.ok())
            .filter(|x| x.file_name().to_string_lossy().starts_with("probe-"))
            .count(),
        3
    );
    assert!(!f.settings().exists());
    assert!(super::require_confirmed_cleanup(Ok(())).is_ok());
}
