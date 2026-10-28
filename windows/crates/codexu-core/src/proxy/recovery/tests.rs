//! Native Windows child-only fixtures. They never discover or launch an
//! installed app, load account auth, or contact a model/network endpoint.
use super::*;
use std::{
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

fn claim() -> DesktopWriterClaim {
    DesktopWriterClaim {
        writer_id: "1".repeat(32),
        profile_id: "2".repeat(32),
        proxy_run_id: "3".repeat(32),
        identity_hash: "a".repeat(64),
        initial_generation: "synthetic-generation".into(),
    }
}
#[derive(Deserialize)]
struct TestProcessBirth {
    pid: u32,
    created: u64,
}
fn wait_file(path: &Path, child: &mut Child) {
    let until = Instant::now() + Duration::from_secs(8);
    while !path.exists() {
        assert!(
            child.try_wait().unwrap().is_none(),
            "fixture owner exited before ready"
        );
        assert!(Instant::now() < until, "fixture owner readiness timeout");
        thread::sleep(Duration::from_millis(20));
    }
}
struct FixtureOwner {
    child: Child,
    root: PathBuf,
}
impl FixtureOwner {
    fn spawn(root: &Path, mode: &str) -> Self {
        std::fs::create_dir_all(root).unwrap();
        let log = std::fs::File::create(root.join("fixture-output.log")).unwrap();
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "proxy::recovery::tests::recovery_owner_fixture",
                "--ignored",
                "--nocapture",
            ])
            .env("AIGOODBRO_RECOVERY_TEST_ROLE", "owner")
            .env("AIGOODBRO_RECOVERY_TEST_ROOT", root)
            .env("AIGOODBRO_RECOVERY_TEST_MODE", mode)
            .stdin(Stdio::null())
            .stdout(Stdio::from(log.try_clone().unwrap()))
            .stderr(Stdio::from(log))
            .spawn()
            .unwrap();
        wait_file(&root.join("owner-ready"), &mut child);
        Self {
            child,
            root: root.into(),
        }
    }
    fn exit(&mut self) {
        std::fs::write(self.root.join("owner-exit"), b"exit owned fixture").unwrap();
        let until = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                assert!(status.success());
                return;
            }
            assert!(Instant::now() < until, "fixture owner exit timeout");
            thread::sleep(Duration::from_millis(20));
        }
    }
}
impl Drop for FixtureOwner {
    fn drop(&mut self) {
        // Only this exact test Child is terminated on a failing assertion. Its
        // private kill-on-close Job owns all child/grandchild test processes.
        if self.child.try_wait().ok().flatten().is_none() {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

#[test]
#[ignore = "child-only fixture, invoked by the native recovery acceptance tests"]
fn recovery_waiting_child() {
    if std::env::var("AIGOODBRO_RECOVERY_TEST_ROLE").as_deref() != Ok("hold") {
        return;
    }
    let root = PathBuf::from(std::env::var_os("AIGOODBRO_RECOVERY_TEST_ROOT").unwrap());
    let depth = std::env::var("AIGOODBRO_RECOVERY_TEST_DEPTH").unwrap_or_default();
    let until = Instant::now() + Duration::from_secs(20);
    while !root.join("child-continue").exists() {
        assert!(Instant::now() < until);
        thread::sleep(Duration::from_millis(10));
    }
    if depth != "grandchild" {
        let _grandchild = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "proxy::recovery::tests::recovery_waiting_child",
                "--ignored",
                "--nocapture",
            ])
            .env("AIGOODBRO_RECOVERY_TEST_DEPTH", "grandchild")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
    }
    let owner = native::current_owner().unwrap();
    let name = if depth == "grandchild" {
        "grandchild-ready.json"
    } else {
        "child-ready.json"
    };
    std::fs::write(
        root.join(name),
        serde_json::to_vec(&serde_json::json!({
            "pid": owner.pid, "created": owner.created,
        }))
        .unwrap(),
    )
    .unwrap();
    while Instant::now() < until && !root.join("child-exit").exists() {
        thread::sleep(Duration::from_millis(20));
    }
}

#[test]
#[ignore = "child-only fixture, invoked by the native recovery acceptance tests"]
fn recovery_owner_fixture() {
    if std::env::var("AIGOODBRO_RECOVERY_TEST_ROLE").as_deref() != Ok("owner") {
        return;
    }
    let root = PathBuf::from(std::env::var_os("AIGOODBRO_RECOVERY_TEST_ROOT").unwrap());
    let mode = std::env::var("AIGOODBRO_RECOVERY_TEST_MODE").unwrap();
    let claim = claim();
    let receipts = root.join("receipts");
    if mode == "helper" {
        prepare_helper(&receipts, &claim.proxy_run_id).unwrap();
        launching(&receipts, "helper", &claim.proxy_run_id).unwrap();
        let child = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "proxy::recovery::tests::recovery_waiting_child",
                "--ignored",
                "--nocapture",
            ])
            .env("AIGOODBRO_RECOVERY_TEST_ROLE", "hold")
            .env("AIGOODBRO_RECOVERY_TEST_ROOT", &root)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let job =
            crate::proxy::process::recovery_test_helper_job(&child, &claim.proxy_run_id, &receipts)
                .unwrap();
        // Leak only inside the short-lived fixture owner, so process exit (not
        // Rust Drop) closes the Job just as a crash does.
        std::mem::forget(job);
    } else {
        prepare_desktop(&receipts, &claim).unwrap();
        if mode == "launching" {
            launching(&receipts, "desktop", &claim.writer_id).unwrap();
        } else if mode == "armed" {
            let owned = crate::proxy::desktop::native::launch_recovery_test_child(
                &std::env::current_exe().unwrap(),
                &[
                    ("AIGOODBRO_RECOVERY_TEST_ROLE".into(), "hold".into()),
                    (
                        "AIGOODBRO_RECOVERY_TEST_ROOT".into(),
                        root.to_str().unwrap().into(),
                    ),
                ],
                &receipts,
                &claim,
            )
            .unwrap();
            std::mem::forget(owned);
        }
    }
    std::fs::write(root.join("child-continue"), b"owned Job armed").unwrap();
    let until = Instant::now() + Duration::from_secs(8);
    if mode == "helper" || mode == "armed" {
        while !root.join("grandchild-ready.json").exists() {
            assert!(Instant::now() < until);
            thread::sleep(Duration::from_millis(10));
        }
    }
    std::fs::write(root.join("owner-ready"), b"receipt durable").unwrap();
    let until = Instant::now() + Duration::from_secs(15);
    while Instant::now() < until && !root.join("owner-exit").exists() {
        thread::sleep(Duration::from_millis(20));
    }
    std::process::exit(0);
}

fn wait_proof(root: &Path, candidate: &DesktopWriterClaim) -> DesktopRecoveryProof {
    let until = Instant::now() + Duration::from_secs(4);
    loop {
        if let Ok(proof) = verify_desktop(root, candidate) {
            return proof;
        }
        assert!(
            Instant::now() < until,
            "native exit proof did not become positive"
        );
        thread::sleep(Duration::from_millis(20));
    }
}
#[test]
#[ignore = "Windows native owner/Job/DPAPI test processes only; no installed app"]
fn actual_helper_windows_desktop_crash_recovery_requires_owner_and_all_job_children_exit() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path();
    let mut owner = FixtureOwner::spawn(root, "armed");
    let candidate = claim();
    let receipts = root.join("receipts");
    assert!(matches!(
        verify_desktop(&receipts, &candidate),
        Err(ProxyFailure::CleanupUnconfirmed)
    ));
    let (receipt, _) = read(&receipts, "desktop", &candidate.writer_id).unwrap();
    let wide: Vec<u16> = receipt
        .job
        .as_ref()
        .unwrap()
        .encode_utf16()
        .chain(Some(0))
        .collect();
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn OpenJobObjectW(access: u32, inherit: i32, name: *const u16) -> isize;
        fn CloseHandle(handle: isize) -> i32;
    }
    let held_query = unsafe { OpenJobObjectW(4, 0, wide.as_ptr()) };
    assert_ne!(held_query, 0);
    owner.exit();
    // The read-only handle deliberately prevents last-handle Job destruction.
    // A dead owner alone cannot authorize import while its Job children live.
    assert!(matches!(
        verify_desktop(&receipts, &candidate),
        Err(ProxyFailure::CleanupUnconfirmed)
    ));
    unsafe {
        CloseHandle(held_query);
    }
    let mut rebound = candidate.clone();
    rebound.proxy_run_id = "4".repeat(32);
    let proof = wait_proof(&receipts, &rebound);
    assert_eq!(proof.claim().proxy_run_id, candidate.proxy_run_id);
    assert_eq!(proof.kind(), DesktopRecoveryKind::Exited);
    assert_eq!(proof.owner_pid(), owner.child.id());
    for name in ["child-ready.json", "grandchild-ready.json"] {
        let process: TestProcessBirth =
            serde_json::from_slice(&std::fs::read(root.join(name)).unwrap()).unwrap();
        assert!(native::process_gone(process.pid, process.created).unwrap());
    }
    let mut wrong = rebound.clone();
    wrong.initial_generation.push_str("-other");
    assert!(verify_desktop(&receipts, &wrong).is_err());
    let (original, _) = read(&receipts, "desktop", &candidate.writer_id).unwrap();
    let mut other_session = original.clone();
    other_session.owner.session ^= 1;
    write(&receipts, &other_session).unwrap();
    assert!(verify_desktop(&receipts, &candidate).is_err());
    write(&receipts, &original).unwrap();
    let path = receipt_path(&receipts, "desktop", &candidate.writer_id).unwrap();
    let mut tampered = std::fs::read(&path).unwrap();
    let last = tampered.len() - 1;
    tampered[last] ^= 1;
    std::fs::write(path, tampered).unwrap();
    assert!(verify_desktop(&receipts, &candidate).is_err());
}
#[test]
#[ignore = "Windows native no-spawn and partial-launch recovery evidence only"]
fn actual_helper_windows_prepared_and_unarmed_recovery_are_distinct() {
    for mode in ["prepared", "launching"] {
        let directory = tempfile::tempdir().unwrap();
        let mut owner = FixtureOwner::spawn(directory.path(), mode);
        let receipts = directory.path().join("receipts");
        assert!(verify_desktop(&receipts, &claim()).is_err());
        owner.exit();
        if mode == "prepared" {
            assert_eq!(
                wait_proof(&receipts, &claim()).kind(),
                DesktopRecoveryKind::Prepared
            );
        } else {
            assert!(matches!(
                verify_desktop(&receipts, &claim()),
                Err(ProxyFailure::CleanupUnconfirmed)
            ));
        }
    }
}
#[test]
#[ignore = "Windows native helper owner/Job/DPAPI evidence independent from Desktop"]
fn actual_helper_windows_proxy_helper_crash_uses_its_own_receipt() {
    let directory = tempfile::tempdir().unwrap();
    let mut owner = FixtureOwner::spawn(directory.path(), "helper");
    let receipts = directory.path().join("receipts");
    let run = claim().proxy_run_id;
    assert!(verify_helper(&receipts, &run).is_err());
    assert!(verify_desktop(&receipts, &claim()).is_err());
    owner.exit();
    let until = Instant::now() + Duration::from_secs(4);
    let proof = loop {
        if let Ok(proof) = verify_helper(&receipts, &run) {
            break proof;
        }
        assert!(Instant::now() < until);
        thread::sleep(Duration::from_millis(20));
    };
    assert_eq!(proof.run_id(), run);
    assert_eq!(proof.owner_pid(), owner.child.id());
    assert!(verify_helper(&receipts, &"5".repeat(32)).is_err());
}
