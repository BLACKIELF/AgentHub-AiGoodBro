use super::*;
use std::sync::atomic::AtomicUsize;

struct Owned {
    fail: Arc<AtomicBool>,
    calls: Arc<AtomicUsize>,
    drops: Arc<AtomicUsize>,
}
impl ReceiverControl for Owned {
    fn stop(&mut self) -> Result<(), String> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        if self.fail.load(Ordering::SeqCst) {
            Err("companion_cleanup_unconfirmed".into())
        } else {
            Ok(())
        }
    }
}
impl Drop for Owned {
    fn drop(&mut self) {
        self.drops.fetch_add(1, Ordering::SeqCst);
    }
}
#[test]
fn unconfirmed_stop_keeps_same_receiver_until_confirmed_without_repeat_drop() {
    let fail = Arc::new(AtomicBool::new(true));
    let calls = Arc::new(AtomicUsize::new(0));
    let drops = Arc::new(AtomicUsize::new(0));
    let mut slot = ReceiverSlot {
        value: Some(Owned {
            fail: fail.clone(),
            calls: calls.clone(),
            drops: drops.clone(),
        }),
        cleanup_unconfirmed: false,
        ..Default::default()
    };
    assert!(!slot.cleanup_unconfirmed); // An idle owned receiver is not a task.
    for _ in 0..2 {
        assert!(slot.stop().is_err());
        assert!(slot.value.is_some());
        assert!(slot.cleanup_unconfirmed);
        assert_eq!(drops.load(Ordering::SeqCst), 0);
    }
    fail.store(false, Ordering::SeqCst);
    slot.stop().unwrap();
    assert!(slot.value.is_none());
    assert!(!slot.cleanup_unconfirmed);
    assert_eq!(drops.load(Ordering::SeqCst), 1);
    slot.stop().unwrap();
    assert_eq!(calls.load(Ordering::SeqCst), 3);
    assert_eq!(drops.load(Ordering::SeqCst), 1);
}
#[test]
fn empty_receiver_stop_is_idempotent_without_fabricated_cleanup_failure() {
    let mut slot = ReceiverSlot::<Owned>::default();
    slot.stop().unwrap();
    slot.stop().unwrap();
    assert!(slot.value.is_none());
    assert!(!slot.cleanup_unconfirmed);
}

#[test]
fn selecting_the_same_automatic_python_invalidates_receiver_and_plan_binding() {
    let path = PathBuf::from("synthetic-python.exe");
    let image = digest(b"same held interpreter bytes");
    let explicit = Some((path, image.clone()));
    let binding = |selection: &Option<(PathBuf, String)>| {
        runtime_fingerprint(
            "same bundle",
            "same App",
            &image,
            "same Hub epoch",
            selection,
        )
    };
    let automatic_receiver = binding(&None);
    let explicit_candidate = binding(&explicit);
    // These are the actual keys Candidate::same uses for both prepare's
    // already-live path and confirm's receiver reuse, and Adapter persists.
    assert_ne!(automatic_receiver, explicit_candidate);
    assert_ne!(explicit_candidate, binding(&None));
    assert_eq!(explicit_candidate, binding(&explicit));
    let other_selection = Some((PathBuf::from("synthetic-other.exe"), image.clone()));
    assert_ne!(explicit_candidate, binding(&other_selection));
}

#[test]
fn normal_exit_busy_or_cancel_does_not_seal_hub_but_confirmed_force_does() {
    use codexu_core::accounts::{
        AccountIdentity, AccountPaths, AccountResult, AccountRuntime, LoginAuthorization,
        SecretProtector, VerifiedCredential,
    };
    struct Protector;
    impl SecretProtector for Protector {
        fn seal(&self, _: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
            Ok(bytes.iter().map(|b| b ^ 0x61).collect())
        }
        fn unseal(&self, _: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
            Ok(bytes.iter().map(|b| b ^ 0x61).collect())
        }
    }
    struct NoAccounts;
    impl AccountRuntime for NoAccounts {
        fn available(&self) -> bool {
            false
        }
        fn login(
            &self,
            _: &Path,
            _: &AtomicBool,
            _: &mut dyn FnMut(LoginAuthorization),
        ) -> AccountResult<VerifiedCredential> {
            panic!("exit must not log in")
        }
        fn verify(&self, _: &Path, _: &AccountIdentity) -> AccountResult<VerifiedCredential> {
            panic!("exit must not verify an account")
        }
        fn require_system_idle(&self) -> AccountResult<()> {
            panic!("no live system check")
        }
        fn validate_target_configuration(&self, _: &Path) -> AccountResult<()> {
            panic!("no live configuration")
        }
    }
    let temporary = tempfile::tempdir().unwrap();
    let root = temporary.path().canonicalize().unwrap();
    let manager = AccountManager::with_components(
        AccountPaths::isolated(root.join("vault"), root.join("synthetic-system")).unwrap(),
        Arc::new(Protector),
        Arc::new(NoAccounts),
        None,
    )
    .unwrap();
    let gate = ManagedProxyGate::new(root.join("dispatch"), &manager).unwrap();
    let hub = HubState::default();
    let runtime = CompanionRuntime::new(
        Arc::new(AppState::new(root.join("app"))),
        manager,
        gate,
        &hub,
    );
    let lock = runtime.state.lock().unwrap();
    assert_eq!(
        runtime.prepare_normal_exit().unwrap_err(),
        "companion_runtime_busy"
    );
    assert!(!hub.quitting.load(Ordering::Acquire));
    drop(lock);
    runtime.prepare_normal_exit().unwrap();
    runtime.resume_normal_exit().unwrap();
    assert!(!hub.quitting.load(Ordering::Acquire));
    // Cancelling the existing exit dialog must leave admission usable.
    assert!(runtime.lock().is_ok());
    runtime.stop_owned().unwrap();
    assert!(hub.quitting.load(Ordering::Acquire));
    assert_eq!(runtime.lock().err().unwrap(), "companion_app_quitting");
}

#[test]
fn normal_stop_then_late_guard_and_cancel_restore_the_same_owner_once() {
    let fail = Arc::new(AtomicBool::new(false));
    let drops = Arc::new(AtomicUsize::new(0));
    let mut slot = ReceiverSlot {
        value: Some(Owned {
            fail,
            calls: Arc::new(AtomicUsize::new(0)),
            drops: drops.clone(),
        }),
        ..Default::default()
    };
    let adopted_guard = Arc::new(());
    let retained_guard = adopted_guard.clone();
    let starts = AtomicUsize::new(0);
    slot.suspend().unwrap();
    assert!(slot.value.is_none());
    assert!(slot.suspended.is_some());
    assert!(slot.normal_exit_pending);
    // Parent discovers a late adopted task, then the user cancels its prompt.
    // Both callbacks execute the real slot resume path; only one restarts.
    for _ in 0..2 {
        slot.resume(|_| {
            starts.fetch_add(1, Ordering::SeqCst);
            Ok(())
        })
        .unwrap();
    }
    assert_eq!(starts.load(Ordering::SeqCst), 1);
    assert!(slot.value.is_some());
    assert!(!slot.normal_exit_pending);
    assert_eq!(drops.load(Ordering::SeqCst), 0);
    assert_eq!(Arc::strong_count(&adopted_guard), 2);
    drop(retained_guard);
}

#[test]
fn cancelled_exit_never_restarts_until_uncertain_stop_is_confirmed() {
    let fail = Arc::new(AtomicBool::new(true));
    let mut slot = ReceiverSlot {
        value: Some(Owned {
            fail: fail.clone(),
            calls: Arc::new(AtomicUsize::new(0)),
            drops: Arc::new(AtomicUsize::new(0)),
        }),
        ..Default::default()
    };
    let starts = AtomicUsize::new(0);
    assert!(slot.suspend().is_err());
    assert!(slot
        .resume(|_| {
            starts.fetch_add(1, Ordering::SeqCst);
            Ok(())
        })
        .is_err());
    assert_eq!(starts.load(Ordering::SeqCst), 0);
    assert!(slot.cleanup_unconfirmed && slot.value.is_some());
    fail.store(false, Ordering::SeqCst);
    slot.resume(|_| {
        starts.fetch_add(1, Ordering::SeqCst);
        Ok(())
    })
    .unwrap();
    assert_eq!(starts.load(Ordering::SeqCst), 1);
    assert!(!slot.cleanup_unconfirmed && slot.value.is_some());
}

#[test]
fn changed_original_binding_during_cancel_keeps_stopped_owner_and_never_rebinds() {
    let drops = Arc::new(AtomicUsize::new(0));
    let mut slot = ReceiverSlot {
        value: Some(Owned {
            fail: Arc::new(AtomicBool::new(false)),
            calls: Arc::new(AtomicUsize::new(0)),
            drops: drops.clone(),
        }),
        ..Default::default()
    };
    slot.suspend().unwrap();
    assert_eq!(
        slot.resume(|_| Err("companion_runtime_changed".into()))
            .unwrap_err(),
        "companion_runtime_changed"
    );
    assert!(slot.value.is_none() && slot.suspended.is_some());
    assert!(slot.normal_exit_pending && !slot.cleanup_unconfirmed);
    assert_eq!(drops.load(Ordering::SeqCst), 0);
    // A later explicit force-exit stops/drops only the retained owned receiver.
    slot.stop().unwrap();
    assert_eq!(drops.load(Ordering::SeqCst), 1);
}
