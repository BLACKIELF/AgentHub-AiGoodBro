use super::*;
use serde_json::json;
use std::sync::atomic::{AtomicUsize, Ordering};

struct Fixture {
    _temp: tempfile::TempDir,
    root: PathBuf,
    a: PathBuf,
    b: PathBuf,
    python: PythonSelection,
}
impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let a = root.join("python.exe");
        let b = root.join("other.exe");
        for p in [&a, &b] {
            let mut bytes = vec![0; 256];
            bytes[..2].copy_from_slice(b"MZ");
            bytes[60..64].copy_from_slice(&64u32.to_le_bytes());
            bytes[64..68].copy_from_slice(b"PE\0\0");
            let machine: u16 = if cfg!(target_arch = "aarch64") {
                0xaa64
            } else {
                0x8664
            };
            bytes[68..70].copy_from_slice(&machine.to_le_bytes());
            bytes[88..90].copy_from_slice(b"\x0b\x02");
            std::fs::write(p, bytes).unwrap();
        }
        let python = PythonSelection::new(&root.join("app")).unwrap();
        Self {
            _temp: temp,
            root,
            a,
            b,
            python,
        }
    }
    fn settings(&self) -> PathBuf {
        self.root
            .join("app/python-runtime-v1/runtime-setup-v1/codex.json")
    }
}
fn report(path: &Path) -> serde_json::Value {
    json!({"version":[3,9,0],"executable":path,"platform":"win32",
        "stdlib":{"ssl":true,"sqlite3":true,"ctypes":true,"msvcrt":true},"timezone":true})
}
struct Fake {
    calls: AtomicUsize,
    error: Option<&'static str>,
}
impl Fake {
    fn ready() -> Self {
        Self {
            calls: AtomicUsize::new(0),
            error: None,
        }
    }
}
impl Probe for Fake {
    fn inspect(&self, path: &Path, home: &Path) -> Result<String> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        assert!(home.is_dir());
        assert!(!home.join("auth.json").exists());
        if let Some(code) = self.error {
            return Err(fail(code));
        }
        parse_report(&serde_json::to_vec(&report(path)).unwrap(), path)
    }
}

#[test]
fn python_fixed_probe_is_isolated_and_not_codex_help_or_caller_code() {
    assert_eq!(&probe_args()[..3], &["-I", "-B", "-c"]);
    assert_eq!(probe_args()[3], PROBE_SCRIPT);
    for needed in [
        "sys.version_info[:3]",
        "sys.executable",
        "'ssl'",
        "'sqlite3'",
        "'ctypes'",
        "'msvcrt'",
        "ZoneInfo('Asia/Shanghai')",
    ] {
        assert!(PROBE_SCRIPT.contains(needed));
    }
    for forbidden in [
        "fcntl",
        "subprocess",
        "pip",
        "requests",
        "auth.json",
        "exec --help",
    ] {
        assert!(!PROBE_SCRIPT.contains(forbidden));
    }
}
#[test]
fn python_requires_three_nine_or_newer_without_accepting_other_major() {
    let f = Fixture::new();
    for version in [[3, 9, 0], [3, 12, 11], [3, 15, 2]] {
        let mut v = report(&f.a);
        v["version"] = json!(version);
        assert!(parse_report(&serde_json::to_vec(&v).unwrap(), &f.a).is_ok());
    }
    for version in [
        json!([3, 8, 99]),
        json!([2, 7, 18]),
        json!([4, 0, 0]),
        json!([3, 9]),
        json!([3, 9, -1]),
        json!([3, "9", 0]),
    ] {
        let mut v = report(&f.a);
        v["version"] = version;
        assert!(parse_report(&serde_json::to_vec(&v).unwrap(), &f.a).is_err());
    }
}
#[test]
fn python_timezone_and_stdlib_missing_are_distinct_not_ready() {
    let f = Fixture::new();
    for name in ["ssl", "sqlite3", "ctypes", "msvcrt"] {
        let mut v = report(&f.a);
        v["stdlib"][name] = json!(false);
        assert_eq!(
            parse_report(&serde_json::to_vec(&v).unwrap(), &f.a)
                .unwrap_err()
                .code,
            "python_stdlib_missing"
        );
    }
    let mut v = report(&f.a);
    v["timezone"] = json!(false);
    assert_eq!(
        parse_report(&serde_json::to_vec(&v).unwrap(), &f.a)
            .unwrap_err()
            .code,
        "python_timezone_missing"
    );
}
#[test]
fn python_report_is_bounded_exact_and_bound_to_invoked_image() {
    let f = Fixture::new();
    for (key, value) in [
        ("executable", json!(f.b)),
        ("platform", json!("linux")),
        ("extra", json!(true)),
    ] {
        let mut v = report(&f.a);
        v[key] = value;
        assert!(parse_report(&serde_json::to_vec(&v).unwrap(), &f.a).is_err());
    }
    for bytes in [b"not json".to_vec(), vec![b' '; 8193], b"{}\n{}".to_vec()] {
        assert!(parse_report(&bytes, &f.a).is_err());
    }
}
#[test]
fn python_choice_roundtrip_does_not_change_codex_selection() {
    let f = Fixture::new();
    let fake = Fake::ready();
    let codex = SelectionStore::new(&f.root.join("app")).unwrap();
    codex.choose(&f.b, &fake).unwrap();
    let codex_file = f.root.join("app/runtime-setup-v1/codex.json");
    let before = std::fs::read(&codex_file).unwrap();
    f.python.selection.choose(&f.a, &fake).unwrap();
    let reopen = PythonSelection::new(&f.root.join("app")).unwrap();
    assert_eq!(reopen.for_companion_with(&[], &fake).unwrap().path, f.a);
    assert_eq!(std::fs::read(codex_file).unwrap(), before);
    assert_eq!(codex.selected().unwrap().unwrap().path, f.b);
}
#[test]
fn python_failed_probe_or_timeout_preserves_previous_choice() {
    let f = Fixture::new();
    f.python.selection.choose(&f.a, &Fake::ready()).unwrap();
    let before = std::fs::read(f.settings()).unwrap();
    for error in [
        "python_stdlib_missing",
        "python_timezone_missing",
        "runtime_probe_timeout",
    ] {
        let probe = Fake {
            calls: AtomicUsize::new(0),
            error: Some(error),
        };
        assert_eq!(
            f.python.selection.choose(&f.b, &probe).unwrap_err().code,
            error
        );
        assert_eq!(std::fs::read(f.settings()).unwrap(), before);
    }
}
#[test]
fn python_companion_consumer_rejects_changed_image_without_fallback() {
    let f = Fixture::new();
    f.python.selection.choose(&f.a, &Fake::ready()).unwrap();
    let mut b = std::fs::read(&f.a).unwrap();
    b[200] = 1;
    std::fs::write(&f.a, b).unwrap();
    let probe = Fake::ready();
    assert!(
        matches!(f.python.for_companion_with(&[f.b.clone()], &probe),Err(e)if e.code=="runtime_selection_changed")
    );
    assert_eq!(probe.calls.load(Ordering::SeqCst), 0);
}
#[test]
fn python_automatic_probe_is_read_only_and_unknown_cleanup_preserves_home() {
    let f = Fixture::new();
    let p = Fake::ready();
    assert_eq!(
        f.python.selection.inspect(&[f.a.clone()], &p).state,
        "ready"
    );
    assert!(!f.settings().exists());
    let p = Fake {
        calls: AtomicUsize::new(0),
        error: Some("cleanup_unconfirmed"),
    };
    assert_eq!(
        f.python
            .selection
            .inspect(&[f.a.clone(), f.b.clone()], &p)
            .issue_code,
        Some("cleanup_unconfirmed")
    );
    assert_eq!(p.calls.load(Ordering::SeqCst), 1);
    assert!(!f.settings().exists());
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
#[cfg(unix)]
fn python_failed_private_save_does_not_follow_link_or_overwrite_old_record() {
    let f = Fixture::new();
    f.python.selection.choose(&f.a, &Fake::ready()).unwrap();
    let before = std::fs::read(f.settings()).unwrap();
    let kept = f.settings().with_file_name("preserved.json");
    std::fs::rename(f.settings(), &kept).unwrap();
    std::os::unix::fs::symlink(&kept, f.settings()).unwrap();
    assert_eq!(
        f.python
            .selection
            .choose(&f.b, &Fake::ready())
            .unwrap_err()
            .code,
        "runtime_save_failed"
    );
    assert_eq!(std::fs::read(kept).unwrap(), before);
}

#[test]
fn python_companion_resolver_uses_automatic_image_without_saving_preference() {
    let f = Fixture::new();
    let p = Fake::ready();
    let image = f.python.for_companion_with(&[f.a.clone()], &p).unwrap();
    assert_eq!(image.path, f.a);
    assert!(image.guard.metadata().unwrap().is_file());
    assert_eq!(p.calls.load(Ordering::SeqCst), 1);
    assert!(!f.settings().exists());
}

#[test]
fn python_companion_resolver_shares_lock_with_explicit_selection() {
    let f = Fixture::new();
    let p = Fake::ready();
    let _lock =
        crate::accounts::storage::StoreLock::acquire(f.settings().parent().unwrap()).unwrap();
    assert!(
        matches!(f.python.for_companion_with(&[f.a.clone()],&p),Err(e)if e.code=="runtime_setup_busy")
    );
    assert_eq!(p.calls.load(Ordering::SeqCst), 0);
    assert!(!f.settings().exists());
}
