//! Windows-only isolated PE fixture; no installed CLI, account or network use.
use super::*;
use crate::runtime_setup::{NativeProbe, SelectionStore};
use std::{
    io::Write,
    time::{Duration, Instant},
};

const SYNTHETIC_CLI: &str = r#"
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let home = std::path::PathBuf::from(std::env::var_os("CODEX_HOME").expect("isolated home"));
    assert!(home.is_dir());
    assert!(!home.join("auth.json").exists());
    let exe = std::env::current_exe().unwrap();
    let name = exe.file_stem().unwrap().to_string_lossy();
    if name == "sleep" { std::thread::sleep(std::time::Duration::from_secs(30)); }
    if args == ["--version"] { println!("codex-cli 0.154.0"); }
    else if args == ["exec", "--help"] {
        if name == "incomplete" { println!("--output-last-message --sandbox"); }
        else { println!("--output-last-message --sandbox --model"); }
    } else { std::process::exit(90); }
}
"#;

/// Select the already active rustup toolchain directly, never the shim which
/// could install a missing toolchain. Absence is a test failure, not a skip.
fn existing_rustc() -> PathBuf {
    let toolchain = std::env::var("RUSTUP_TOOLCHAIN").expect("active installed test toolchain");
    assert!(!toolchain.is_empty() && toolchain.len() <= 128);
    assert!(toolchain
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b)));
    let root = std::env::var_os("RUSTUP_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("USERPROFILE").expect("Windows test profile"))
                .join(".rustup")
        });
    let compiler = root
        .join("toolchains")
        .join(toolchain)
        .join("bin/rustc.exe")
        .canonicalize()
        .expect("already installed rustc");
    storage::ensure_no_links(&compiler).unwrap();
    assert!(compiler.is_file());
    compiler
}
fn compile_owned(root: &Path, output: &Path) {
    use std::os::windows::fs::OpenOptionsExt;
    let compiler = existing_rustc();
    let _image_guard = std::fs::OpenOptions::new()
        .read(true)
        .share_mode(1)
        .open(&compiler)
        .unwrap();
    let source = root.join("synthetic-cli.rs");
    let mut source_file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&source)
        .unwrap();
    source_file.write_all(SYNTHETIC_CLI.as_bytes()).unwrap();
    source_file.sync_all().unwrap();
    drop(source_file);
    let home = root.join("compiler-home");
    storage::create_private_directory(&home).unwrap();
    let args = vec![
        source.to_string_lossy().into_owned(),
        "--crate-name".into(),
        "aigoodbro_runtime_fixture".into(),
        "--edition=2021".into(),
        "-C".into(),
        "debuginfo=0".into(),
        "-o".into(),
        output.to_string_lossy().into_owned(),
    ];
    let mut child = process::Child::start(&compiler, &home, &args).unwrap();
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut bytes = Vec::new();
    let result = (|| -> AccountResult<()> {
        loop {
            bytes.extend(child.read_available()?);
            if bytes.len() > 262144 {
                return Err(fail("fixture_output_limit"));
            }
            if let Some(code) = child.exit_code()? {
                bytes.extend(child.read_available()?);
                return if code == 0 {
                    Ok(())
                } else {
                    Err(fail("fixture_compile_failed"))
                };
            }
            if Instant::now() >= deadline {
                return Err(fail("fixture_compile_timeout"));
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    })();
    // The test root is deliberately retained on any panic/failure. Never remove
    // scratch unless the same owned root and Job have been confirmed stopped.
    crate::runtime_setup::require_confirmed_cleanup(child.stop_confirmed()).unwrap();
    assert!(
        result.is_ok(),
        "synthetic compiler failed: {:?}; {}",
        result,
        std::str::from_utf8(&bytes).unwrap_or("non-text compiler output")
    );
    assert!(output.is_file());
}

#[test]
fn windows_selected_runtime_roundtrip_and_owned_probe() {
    let temporary = tempfile::Builder::new()
        .prefix("aigoodbro-runtime-fixture-")
        .tempdir()
        .unwrap()
        .keep();
    let root = temporary.canonicalize().unwrap();
    let executable = root.join("synthetic.exe");
    compile_owned(&root, &executable);
    let app = root.join("app");
    let store = SelectionStore::new(&app).unwrap();
    let ready = store.choose(&executable, &NativeProbe).unwrap();
    assert_eq!(ready.state, "ready");
    assert_eq!(ready.version.as_deref(), Some("0.154.0"));
    assert!(ready.selected);
    let settings = app.join("runtime-setup-v1/codex.json");
    let saved = std::fs::read(&settings).unwrap();
    let reopened = SelectionStore::new(&app).unwrap();
    let (resolved, image_guard) = reopened.resolve_cli().unwrap();
    assert_eq!(resolved, executable);
    drop(image_guard);
    assert_eq!(reopened.inspect(&[], &NativeProbe).state, "ready");
    let incomplete = root.join("incomplete.exe");
    std::fs::copy(&executable, &incomplete).unwrap();
    assert_eq!(
        reopened.choose(&incomplete, &NativeProbe).unwrap_err().code,
        "runtime_capability_missing"
    );
    assert_eq!(std::fs::read(&settings).unwrap(), saved);
    let sleeping = root.join("sleep.exe");
    std::fs::copy(&executable, &sleeping).unwrap();
    let started = Instant::now();
    assert_eq!(
        reopened.choose(&sleeping, &NativeProbe).unwrap_err().code,
        "runtime_probe_timeout"
    );
    assert!(started.elapsed() < Duration::from_secs(10));
    assert_eq!(std::fs::read(&settings).unwrap(), saved);
    assert_eq!(reopened.selected().unwrap().unwrap().path, executable);
    assert_eq!(
        std::fs::read_dir(settings.parent().unwrap())
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().starts_with("probe-"))
            .count(),
        0,
        "only positively cleaned probes may lose their homes"
    );
    // No held resolver image remains. A changed selected file cannot silently
    // become the new trusted preference or fall back to another executable.
    std::fs::OpenOptions::new()
        .append(true)
        .open(&executable)
        .unwrap()
        .write_all(b"changed")
        .unwrap();
    assert_eq!(
        reopened.inspect(&[incomplete], &NativeProbe).issue_code,
        Some("runtime_selection_changed")
    );
    assert!(reopened.resolve_cli().is_err());
    assert_eq!(std::fs::read(&settings).unwrap(), saved);
    std::fs::remove_dir_all(root).unwrap();
}
