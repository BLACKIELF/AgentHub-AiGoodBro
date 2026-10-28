use super::*;
use crate::proxy::tests::{preferences, FixtureGate, FixtureSecrets};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

struct FixtureHome {
    dir: Option<tempfile::TempDir>,
    identity: String,
    generation: String,
    gate: Arc<dyn ProxyAccountGate>,
    claim: DesktopWriterClaim,
    launched: bool,
    finalized: Arc<AtomicUsize>,
    abandoned: Arc<AtomicUsize>,
}
impl Home for FixtureHome {
    fn mark_launched(&mut self) {
        self.launched = true;
    }
    fn rebind_claim(&mut self, claim: &DesktopWriterClaim) -> Result<(), ProxyFailure> {
        self.claim = claim.clone();
        Ok(())
    }
    fn path(&self) -> &Path {
        self.dir.as_ref().unwrap().path()
    }
    fn profile(&self) -> &str {
        "A"
    }
    fn identity(&self) -> &str {
        &self.identity
    }
    fn generation(&self) -> &str {
        &self.generation
    }
    fn cleanup(&mut self) -> Result<(), ProxyFailure> {
        self.gate.confirm_desktop_exit(&self.claim)?;
        if self.launched {
            self.finalized.fetch_add(1, Ordering::AcqRel);
        } else {
            self.abandoned.fetch_add(1, Ordering::AcqRel);
        }
        self.dir
            .take()
            .unwrap()
            .close()
            .map_err(|_| ProxyFailure::CleanupUnconfirmed)?;
        self.gate.release_desktop_writer(&self.claim)
    }
}
impl Drop for FixtureHome {
    fn drop(&mut self) {
        if let Some(dir) = self.dir.take() {
            let _ = dir.keep();
        }
    }
}
struct FixtureAccounts {
    root: PathBuf,
    busy: AtomicBool,
    created: AtomicUsize,
    fail_prepare: AtomicBool,
    finalized: Arc<AtomicUsize>,
    abandoned: Arc<AtomicUsize>,
}
impl Accounts for FixtureAccounts {
    fn reconstruct(
        &self,
        claim: &DesktopWriterClaim,
        gate: Arc<dyn ProxyAccountGate>,
    ) -> Result<Box<dyn Home>, ProxyFailure> {
        let mut home = self.home(&claim.profile_id, claim, gate)?;
        home.mark_launched();
        Ok(home)
    }
    fn abandon(&self, _: &DesktopWriterClaim) -> Result<(), ProxyFailure> {
        Ok(())
    }
    fn idle(&self) -> Result<(), ProxyFailure> {
        if self.busy.load(Ordering::Acquire) {
            Err(ProxyFailure::DesktopRunning)
        } else {
            Ok(())
        }
    }
    fn home(
        &self,
        _: &str,
        claim: &DesktopWriterClaim,
        gate: Arc<dyn ProxyAccountGate>,
    ) -> Result<Box<dyn Home>, ProxyFailure> {
        self.created.fetch_add(1, Ordering::AcqRel);
        if self.fail_prepare.load(Ordering::Acquire) {
            return Err(ProxyFailure::Identity);
        }
        let dir = tempfile::tempdir_in(&self.root).unwrap();
        Ok(Box::new(FixtureHome {
            dir: Some(dir),
            identity: "a".repeat(64),
            generation: "fixture-generation-1".into(),
            gate,
            claim: claim.clone(),
            launched: false,
            finalized: self.finalized.clone(),
            abandoned: self.abandoned.clone(),
        }))
    }
    fn cli(&self, _: &Path, _: &Path) -> Result<PinnedExecutable, ProxyFailure> {
        let path = self.root.join("fixture-cli");
        std::fs::write(&path, b"synthetic").unwrap();
        Ok(PinnedExecutable {
            _guard: File::open(&path).unwrap(),
            path,
        })
    }
}
struct FixtureProcess {
    exited: Arc<AtomicBool>,
    terminate_confirms: bool,
}
impl DesktopProcess for FixtureProcess {
    fn exited(&mut self) -> Result<bool, ProxyFailure> {
        Ok(self.exited.load(Ordering::Acquire))
    }
    fn terminate(&mut self) -> Result<(), ProxyFailure> {
        if self.terminate_confirms {
            self.exited.store(true, Ordering::Release)
        }
        Ok(())
    }
}
struct FixtureRuntime {
    root: PathBuf,
    launched: AtomicUsize,
    exited: Arc<AtomicBool>,
    confirm: AtomicBool,
    environment: Mutex<Vec<(String, String)>>,
    launch_pause: Mutex<Option<Arc<LaunchPause>>>,
}
struct LaunchPause {
    entered: std::sync::mpsc::SyncSender<()>,
    released: Mutex<bool>,
    wake: std::sync::Condvar,
}
impl Runtime for FixtureRuntime {
    fn prepare_owner_receipt(&self, _: &Path, _: &DesktopWriterClaim) -> Result<(), ProxyFailure> {
        Ok(())
    }
    fn discover(&self, _: &Path) -> Result<PinnedExecutable, ProxyFailure> {
        let path = self.root.join("fixture-app");
        std::fs::write(&path, b"synthetic").unwrap();
        Ok(PinnedExecutable {
            _guard: File::open(&path).unwrap(),
            path,
        })
    }
    fn launch(
        &self,
        _: &PinnedExecutable,
        environment: &[(String, String)],
        _: &Path,
        _: &DesktopWriterClaim,
    ) -> Result<Box<dyn DesktopProcess>, ProxyFailure> {
        self.launched.fetch_add(1, Ordering::AcqRel);
        *self.environment.lock().unwrap() = environment.to_vec();
        if let Some(pause) = self.launch_pause.lock().unwrap().clone() {
            pause.entered.send(()).unwrap();
            let mut released = pause.released.lock().unwrap();
            while !*released {
                released = pause.wake.wait(released).unwrap();
            }
        }
        Ok(Box::new(FixtureProcess {
            exited: self.exited.clone(),
            terminate_confirms: self.confirm.load(Ordering::Acquire),
        }))
    }
}
fn fixture() -> (
    tempfile::TempDir,
    Arc<LocalProxyService>,
    Arc<ProxyDesktopConnector>,
    Arc<FixtureAccounts>,
    Arc<FixtureRuntime>,
    Arc<FixtureGate>,
) {
    let helper = std::env::var_os("AIGOODBRO_TEST_PROXY_HELPER").expect("set isolated helper");
    let dir = tempfile::tempdir().unwrap();
    let gate = FixtureGate::new();
    let proxy = Arc::new(
        LocalProxyService::new(
            dir.path().join("proxy.json"),
            dir.path().join("state"),
            helper.into(),
            vec!["fixture-model".into()],
            gate.clone(),
            Arc::new(FixtureSecrets(Mutex::default())),
        )
        .unwrap(),
    );
    let mut prefs = preferences();
    prefs.listen_port = 0;
    proxy.save_preferences(prefs).unwrap();
    proxy.start().unwrap();
    let accounts = Arc::new(FixtureAccounts {
        root: dir.path().into(),
        busy: AtomicBool::new(false),
        created: AtomicUsize::new(0),
        fail_prepare: AtomicBool::new(false),
        finalized: Arc::new(AtomicUsize::new(0)),
        abandoned: Arc::new(AtomicUsize::new(0)),
    });
    let runtime = Arc::new(FixtureRuntime {
        root: dir.path().into(),
        launched: AtomicUsize::new(0),
        exited: Arc::new(AtomicBool::new(false)),
        confirm: AtomicBool::new(true),
        environment: Mutex::default(),
        launch_pause: Mutex::default(),
    });
    let connector = Arc::new(ProxyDesktopConnector {
        proxy: Arc::downgrade(&proxy),
        accounts: accounts.clone(),
        runtime: runtime.clone(),
        receipts: dir.path().join("desktop-receipts"),
        state: Mutex::new(State::default()),
        operation: Mutex::new(()),
        intent: AtomicUsize::new(0),
    });
    (dir, proxy, connector, accounts, runtime, gate)
}
#[test]
#[ignore = "requires freshly built AIGOODBRO_TEST_PROXY_HELPER; synthetic Desktop runtime only"]
fn actual_helper_desktop_prepare_launch_and_positive_cleanup() {
    let (_dir, proxy, connector, accounts, runtime, _) = fixture();
    let prepared = connector.prepare("A").unwrap();
    assert_eq!(prepared.phase, ProxyDesktopPhase::Prepared);
    assert_eq!(runtime.launched.load(Ordering::Acquire), 0);
    assert_eq!(prepared.routing_verified, None);
    let home = connector
        .state
        .lock()
        .unwrap()
        .prepared
        .as_ref()
        .unwrap()
        .home
        .path()
        .to_owned();
    let data: serde_json::Value =
        serde_json::from_slice(&std::fs::read(home.join("desktop-connection.json")).unwrap())
            .unwrap();
    assert!(data.get("clientKey").is_some());
    assert!(data.get("accessToken").is_none());
    let launched = connector
        .launch(prepared.launch_id.as_deref().unwrap())
        .unwrap();
    assert_eq!(launched.phase, ProxyDesktopPhase::Launched);
    assert_eq!(launched.routing_verified, None);
    let env = runtime.environment.lock().unwrap().clone();
    assert!(env
        .iter()
        .any(|(k, v)| k == "CODEX_HOME" && v == home.to_str().unwrap()));
    assert!(env
        .iter()
        .any(|(k, v)| k == "CODEX_APP_SERVER_FORCE_CLI" && v == "1"));
    assert!(connector.requires_exit_confirmation());
    assert_eq!(
        connector.cancel().unwrap().phase,
        ProxyDesktopPhase::Stopped
    );
    assert!(!home.exists());
    assert_eq!(accounts.finalized.load(Ordering::Acquire), 1);
    assert_eq!(accounts.abandoned.load(Ordering::Acquire), 0);
    let receipts: Vec<_> = std::fs::read_dir(&connector.receipts).unwrap().collect();
    assert_eq!(receipts.len(), 1);
    proxy.stop().unwrap();
}
#[test]
#[ignore = "requires freshly built AIGOODBRO_TEST_PROXY_HELPER; synthetic Desktop runtime only"]
fn actual_helper_prepared_desktop_still_requires_cleanup_after_proxy_stops() {
    let (_dir, proxy, connector, accounts, runtime, _) = fixture();
    connector.prepare("A").unwrap();
    proxy.stop().unwrap();
    assert!(!proxy.requires_exit_confirmation());
    assert!(connector.requires_exit_confirmation());
    assert_eq!(runtime.launched.load(Ordering::Acquire), 0);
    assert_eq!(
        connector.cancel().unwrap().phase,
        ProxyDesktopPhase::Stopped
    );
    assert!(!connector.requires_exit_confirmation());
    assert_eq!(accounts.finalized.load(Ordering::Acquire), 0);
    assert_eq!(accounts.abandoned.load(Ordering::Acquire), 1);
}
#[test]
#[ignore = "requires freshly built AIGOODBRO_TEST_PROXY_HELPER; synthetic Desktop runtime only"]
fn actual_helper_desktop_rejects_running_and_late_identity_change() {
    let (_dir, proxy, connector, accounts, runtime, gate) = fixture();
    accounts.busy.store(true, Ordering::Release);
    assert_eq!(
        connector.prepare("A").unwrap_err(),
        ProxyFailure::DesktopRunning
    );
    assert_eq!(accounts.created.load(Ordering::Acquire), 0);
    accounts.busy.store(false, Ordering::Release);
    let prepared = connector.prepare("A").unwrap();
    let home = connector
        .state
        .lock()
        .unwrap()
        .prepared
        .as_ref()
        .unwrap()
        .home
        .path()
        .to_owned();
    gate.evidence
        .lock()
        .unwrap()
        .get_mut("A")
        .unwrap()
        .token_generation = "fixture-generation-2".into();
    assert_eq!(
        connector
            .launch(prepared.launch_id.as_deref().unwrap())
            .unwrap_err(),
        ProxyFailure::Identity
    );
    assert_eq!(runtime.launched.load(Ordering::Acquire), 0);
    assert!(!home.exists());
    let cancelled = connector.cancel().unwrap();
    assert_eq!(cancelled.phase, ProxyDesktopPhase::Stopped);
    assert!(cancelled.issue.is_none());
    assert!(cancelled.launch_id.is_none());
    proxy.stop().unwrap();
}

#[test]
#[ignore = "requires freshly built AIGOODBRO_TEST_PROXY_HELPER; synthetic Desktop runtime only"]
fn actual_helper_desktop_cancelled_late_launch_cannot_report_active() {
    let (_dir, proxy, connector, _accounts, runtime, _) = fixture();
    let prepared = connector.prepare("A").unwrap();
    let home = connector
        .state
        .lock()
        .unwrap()
        .prepared
        .as_ref()
        .unwrap()
        .home
        .path()
        .to_owned();
    let (tx, rx) = std::sync::mpsc::sync_channel(1);
    let pause = Arc::new(LaunchPause {
        entered: tx,
        released: Mutex::new(false),
        wake: std::sync::Condvar::new(),
    });
    *runtime.launch_pause.lock().unwrap() = Some(pause.clone());
    let launching = connector.clone();
    let ticket = prepared.launch_id.unwrap();
    let task = std::thread::spawn(move || launching.launch(&ticket));
    rx.recv_timeout(Duration::from_secs(2)).unwrap();
    assert_eq!(connector.cancel().unwrap_err(), ProxyFailure::ControlBusy);
    *pause.released.lock().unwrap() = true;
    pause.wake.notify_all();
    assert_eq!(task.join().unwrap().unwrap_err(), ProxyFailure::Stopping);
    let cancelled = connector.cancel().unwrap();
    assert_eq!(cancelled.phase, ProxyDesktopPhase::Stopped);
    assert!(cancelled.launch_id.is_none());
    assert!(cancelled.issue.is_none());
    assert!(!home.exists());
    proxy.stop().unwrap();
}
#[test]
#[ignore = "requires freshly built AIGOODBRO_TEST_PROXY_HELPER; synthetic Desktop runtime only"]
fn actual_helper_desktop_expired_prepare_can_be_cancelled_to_clean_stopped() {
    let (_dir, proxy, connector, _accounts, runtime, _) = fixture();
    let prepared = connector.prepare("A").unwrap();
    connector
        .state
        .lock()
        .unwrap()
        .prepared
        .as_mut()
        .unwrap()
        .prepared_at = Instant::now() - Duration::from_secs(31);
    assert_eq!(
        connector
            .launch(prepared.launch_id.as_deref().unwrap())
            .unwrap_err(),
        ProxyFailure::DesktopPreparationExpired
    );
    assert_eq!(runtime.launched.load(Ordering::Acquire), 0);
    let cancelled = connector.cancel().unwrap();
    assert_eq!(cancelled.phase, ProxyDesktopPhase::Stopped);
    assert!(cancelled.issue.is_none());
    assert!(cancelled.launch_id.is_none());
    proxy.stop().unwrap();
}

#[test]
#[ignore = "requires freshly built AIGOODBRO_TEST_PROXY_HELPER; synthetic Desktop runtime only"]
fn actual_helper_desktop_rebinds_same_owned_backend_after_proxy_restart() {
    let (_dir, proxy, connector, _accounts, runtime, gate) = fixture();
    connector.connect("A").unwrap();
    gate.writer_requires_proof.store(true, Ordering::Release);
    let home = connector
        .state
        .lock()
        .unwrap()
        .launched
        .as_ref()
        .unwrap()
        .prepared
        .home
        .path()
        .to_owned();
    let before: serde_json::Value =
        serde_json::from_slice(&std::fs::read(home.join("desktop-connection.json")).unwrap())
            .unwrap();
    proxy.stop().unwrap();
    assert_eq!(
        connector.status().unwrap().issue.as_deref(),
        Some("desktop_connection_stale")
    );
    proxy.start().unwrap();
    assert!(connector.status().unwrap().issue.is_none());
    let after: serde_json::Value =
        serde_json::from_slice(&std::fs::read(home.join("desktop-connection.json")).unwrap())
            .unwrap();
    assert_ne!(before["runID"], after["runID"]);
    assert_ne!(before["endpoint"], after["endpoint"]);
    assert_eq!(before["writerID"], after["writerID"]);
    assert_eq!(before["evidenceKey"], after["evidenceKey"]);
    assert_eq!(runtime.launched.load(Ordering::Acquire), 1);
    connector.cancel().unwrap();
    proxy.stop().unwrap();
}

#[test]
#[ignore = "requires freshly built AIGOODBRO_TEST_PROXY_HELPER; synthetic Desktop runtime only"]
fn actual_helper_desktop_prepare_failure_abandons_exact_unlaunched_writer() {
    let (_dir, proxy, connector, accounts, runtime, _) = fixture();
    accounts.fail_prepare.store(true, Ordering::Release);
    assert_eq!(connector.prepare("A").unwrap_err(), ProxyFailure::Identity);
    assert_eq!(runtime.launched.load(Ordering::Acquire), 0);
    assert_eq!(
        connector.cancel().unwrap().phase,
        ProxyDesktopPhase::Stopped
    );
    accounts.fail_prepare.store(false, Ordering::Release);
    assert_eq!(
        connector.connect("A").unwrap().phase,
        ProxyDesktopPhase::Launched
    );
    connector.cancel().unwrap();
    proxy.stop().unwrap();
}
#[test]
#[ignore = "requires freshly built AIGOODBRO_TEST_PROXY_HELPER; synthetic Desktop runtime only"]
fn actual_helper_desktop_unknown_exit_keeps_home_until_owned_job_confirmation() {
    let (_dir, proxy, connector, _accounts, runtime, _) = fixture();
    let prepared = connector.prepare("A").unwrap();
    let home = connector
        .state
        .lock()
        .unwrap()
        .prepared
        .as_ref()
        .unwrap()
        .home
        .path()
        .to_owned();
    runtime.confirm.store(false, Ordering::Release);
    connector
        .launch(prepared.launch_id.as_deref().unwrap())
        .unwrap();
    connector.force_stop_owned().unwrap();
    assert_eq!(
        connector.status().unwrap().phase,
        ProxyDesktopPhase::Stopping
    );
    assert!(home.exists());
    runtime.exited.store(true, Ordering::Release);
    assert_eq!(
        connector.status().unwrap().phase,
        ProxyDesktopPhase::Stopped
    );
    assert!(!home.exists());
    proxy.stop().unwrap();
}
