//! Run-bound native enrollment. No credential or registration identity is a UI DTO.
use super::*;
use std::sync::mpsc::{self, Receiver, Sender};

pub(super) struct PendingRegistration {
    run: String,
    request: String,
    profile: String,
    identity: String,
    reply: Sender<Result<(), ProxyFailure>>,
}

pub(super) fn accept_event(pending: &Mutex<Option<PendingRegistration>>, event: &ProxyEvent) {
    let Ok(mut guard) = pending.lock() else {
        return;
    };
    let Some(waiter) = guard.as_ref() else { return };
    if event.event != "account_registered"
        || event.run_id.as_deref() != Some(&waiter.run)
        || event.request_id.as_deref() != Some(&waiter.request)
        || event.profile_id.as_deref() != Some(&waiter.profile)
        || event.identity_hash.as_deref() != Some(&waiter.identity)
    {
        return;
    }
    let result = match (event.state.as_deref(), event.error_code.as_deref()) {
        (Some("registered"), None) => Ok(()),
        (Some("rejected"), Some("identity" | "duplicate_identity")) => Err(ProxyFailure::Identity),
        (Some("rejected"), Some("stopping")) => Err(ProxyFailure::Stopping),
        (Some("rejected"), _) => Err(ProxyFailure::RegistrationFailed),
        _ => return,
    };
    if let Some(waiter) = guard.take() {
        let _ = waiter.reply.send(result);
    }
}

fn wait_for_ack(
    receive: &Receiver<Result<(), ProxyFailure>>,
    command_generation: &AtomicUsize,
    generation: usize,
    timeout: Duration,
) -> Result<(), ProxyFailure> {
    let deadline = Instant::now() + timeout;
    loop {
        if command_generation.load(Ordering::Acquire) != generation {
            return Err(ProxyFailure::Stopping);
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(ProxyFailure::RegistrationFailed);
        }
        match receive.recv_timeout(remaining.min(Duration::from_millis(25))) {
            Ok(reply) => return reply,
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Err(ProxyFailure::RegistrationFailed)
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
        }
    }
}

impl LocalProxyService {
    /// Called by the credential lifecycle only for the first verified login.
    /// Re-login never silently re-enables a user's existing disabled account.
    pub fn enroll_new_verified_account(&self, id: &str) -> Result<ProxyPreferences, ProxyFailure> {
        let result = (|| {
            let _lifecycle = self
                .lifecycle
                .try_lock()
                .map_err(|_| ProxyFailure::ControlBusy)?;
            let mut next = {
                let host = self.host.lock().map_err(|_| ProxyFailure::Unavailable)?;
                host.registration_candidate(id)?;
                host.preferences()
            };
            next.enabled_ids.insert(id.to_owned());
            self.save_preferences_with_registration(next)
        })();
        if result.is_err() && policy::valid_id(id) {
            if let Ok(mut status) = self.status.lock() {
                status.accounts.insert(
                    id.to_owned(),
                    ProxyAccountState {
                        state: "registration_failed".into(),
                        ..ProxyAccountState::default()
                    },
                );
            }
        }
        result
    }

    /// Caller holds lifecycle. Never hold the admission mutex while waiting:
    /// existing requests and lease cleanup must keep progressing normally.
    pub(super) fn register_running_account(&self, id: &str) -> Result<(), ProxyFailure> {
        let (run, candidate) = {
            let host = self.host.lock().map_err(|_| ProxyFailure::Unavailable)?;
            let Some(run) = host.running_id() else {
                return if host.has_unretired_run() {
                    Err(ProxyFailure::Stopping)
                } else {
                    Ok(())
                };
            };
            if host.is_registered(id) {
                return Ok(());
            }
            (run, host.registration_candidate(id)?)
        };
        if self.cached_status()?.phase != ProxyPhase::Running {
            return Err(ProxyFailure::Stopping);
        }
        let generation = self.command_generation.load(Ordering::Acquire);
        if generation & 1 == 0 {
            return Err(ProxyFailure::Stopping);
        }
        let nonce = random_run_id()?;
        let request = format!(
            "{}-{}-{}-{}-{}",
            &nonce[..8],
            &nonce[8..12],
            &nonce[12..16],
            &nonce[16..20],
            &nonce[20..]
        );
        let (send, receive) = mpsc::channel();
        {
            let mut pending = self
                .registration
                .lock()
                .map_err(|_| ProxyFailure::Unavailable)?;
            if pending.is_some() {
                return Err(ProxyFailure::ControlBusy);
            }
            *pending = Some(PendingRegistration {
                run: run.clone(),
                request: request.clone(),
                profile: id.to_owned(),
                identity: candidate.identity_hash.clone(),
                reply: send,
            });
        }
        let result = (|| {
            {
                let mut inner = self.inner.lock().map_err(|_| ProxyFailure::Unavailable)?;
                let child = inner.child.as_mut().ok_or(ProxyFailure::Unavailable)?;
                if child.command_generation != generation
                    || self.command_generation.load(Ordering::Acquire) != generation
                    || child
                        .child
                        .try_wait()
                        .map_err(|_| ProxyFailure::Unavailable)?
                        .is_some()
                {
                    return Err(ProxyFailure::Stopping);
                }
                let mut frame = serde_json::to_vec(&serde_json::json!({
                    "command":"register_account", "runID":run, "requestID":request,
                    "profileID":id, "identityHash":candidate.identity_hash,
                }))
                .map_err(|_| ProxyFailure::RegistrationFailed)?;
                frame.push(b'\n');
                self.send_owned_command(child, &frame)?;
            }
            wait_for_ack(
                &receive,
                &self.command_generation,
                generation,
                Duration::from_secs(10),
            )?;
            // Hold the child lock before the host lock, as lifecycle/status do.
            let mut inner = self.inner.lock().map_err(|_| ProxyFailure::Unavailable)?;
            let child = inner.child.as_mut().ok_or(ProxyFailure::Stopping)?;
            if child.command_generation != generation
                || self.command_generation.load(Ordering::Acquire) != generation
                || child
                    .child
                    .try_wait()
                    .map_err(|_| ProxyFailure::Unavailable)?
                    .is_some()
                || self.cached_status()?.phase != ProxyPhase::Running
            {
                return Err(ProxyFailure::Stopping);
            }
            let mut host = self.host.lock().map_err(|_| ProxyFailure::Unavailable)?;
            host.commit_registration(&run, id, &candidate.identity_hash)
        })();
        // A late or unsolicited acknowledgement cannot publish registration.
        if let Ok(mut pending) = self.registration.lock() {
            if pending.as_ref().is_some_and(|p| p.request == request) {
                pending.take();
            }
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn event(state: &str) -> ProxyEvent {
        serde_json::from_value(serde_json::json!({"event":"account_registered",
            "runID":"run", "requestID":"request", "profileID":"new", "identityHash":"a".repeat(64), "state":state})).unwrap()
    }
    #[test]
    fn registration_ack_requires_every_binding_and_success_state() {
        let (send, receive) = mpsc::channel();
        let pending = Mutex::new(Some(PendingRegistration {
            run: "run".into(),
            request: "request".into(),
            profile: "new".into(),
            identity: "a".repeat(64),
            reply: send,
        }));
        let mut wrong = event("registered");
        wrong.run_id = Some("old-run".into());
        accept_event(&pending, &wrong);
        wrong = event("registered");
        wrong.request_id = Some("other".into());
        accept_event(&pending, &wrong);
        wrong = event("registered");
        wrong.profile_id = Some("other".into());
        accept_event(&pending, &wrong);
        wrong = event("registered");
        wrong.identity_hash = Some("b".repeat(64));
        accept_event(&pending, &wrong);
        wrong = event("registered");
        wrong.error_code = Some("registration_failed".into());
        accept_event(&pending, &wrong);
        assert!(receive.try_recv().is_err());
        accept_event(&pending, &event("registered"));
        assert_eq!(receive.try_recv(), Ok(Ok(())));
        assert!(pending.lock().unwrap().is_none());
        accept_event(&pending, &event("registered"));
        assert!(receive.try_recv().is_err());
    }
    #[test]
    fn rejected_ack_never_becomes_success() {
        let (send, receive) = mpsc::channel();
        let pending = Mutex::new(Some(PendingRegistration {
            run: "run".into(),
            request: "request".into(),
            profile: "new".into(),
            identity: "a".repeat(64),
            reply: send,
        }));
        let mut rejected = event("rejected");
        rejected.error_code = Some("duplicate_identity".into());
        accept_event(&pending, &rejected);
        assert_eq!(receive.try_recv(), Ok(Err(ProxyFailure::Identity)));
    }

    #[test]
    fn late_ack_cannot_complete_a_new_attempt_for_the_same_account() {
        let (send, receive) = mpsc::channel();
        let pending = Mutex::new(Some(PendingRegistration {
            run: "run".into(),
            request: "new-request".into(),
            profile: "new".into(),
            identity: "a".repeat(64),
            reply: send,
        }));
        accept_event(&pending, &event("registered"));
        assert!(receive.try_recv().is_err());
        let mut current = event("registered");
        current.request_id = Some("new-request".into());
        accept_event(&pending, &current);
        assert_eq!(receive.try_recv(), Ok(Ok(())));
    }

    #[test]
    fn missing_ack_and_stop_never_publish_registration() {
        let (send, receive) = mpsc::channel();
        let generation = AtomicUsize::new(1);
        assert_eq!(
            wait_for_ack(&receive, &generation, 1, Duration::from_millis(1)),
            Err(ProxyFailure::RegistrationFailed)
        );
        send.send(Ok(())).unwrap();
        generation.store(2, Ordering::Release);
        assert_eq!(
            wait_for_ack(&receive, &generation, 1, Duration::from_secs(1)),
            Err(ProxyFailure::Stopping)
        );
        drop(send);
        let (_send, closed) = mpsc::channel();
        drop(_send);
        assert_eq!(
            wait_for_ack(&closed, &generation, 2, Duration::from_secs(1)),
            Err(ProxyFailure::RegistrationFailed)
        );
    }

    #[test]
    #[ignore = "requires the freshly built helper; isolated registration only, no model request"]
    fn actual_helper_hot_registration_keeps_run_port_pid_and_manual_opt_out() {
        use crate::proxy::tests::{preferences, FixtureGate, FixtureSecrets};
        let helper = std::env::var_os("AIGOODBRO_TEST_PROXY_HELPER").expect("isolated helper path");
        let dir = tempfile::tempdir().unwrap();
        let gate = FixtureGate::new();
        let service = LocalProxyService::new(
            dir.path().join("proxy.json"),
            dir.path().join("state"),
            helper.into(),
            // Larger than CreatePipe's default Windows capacity: startup must
            // stream a complete first line while the real helper drains it.
            (0..100)
                .map(|n| format!("fixture-{n}-{}", "x".repeat(100)))
                .collect(),
            gate.clone(),
            Arc::new(FixtureSecrets(Mutex::default())),
        )
        .unwrap();
        let mut prefs = preferences();
        prefs.listen_port = 0;
        prefs.enabled_ids.remove("B");
        service.save_preferences(prefs).unwrap();
        let before = service.start().unwrap();
        let pid = service.owned_fixture_pid();
        let run = service.host.lock().unwrap().running_id().unwrap();
        let mut new = gate.evidence.lock().unwrap()["A"].clone();
        new.profile_id = "new".into();
        new.identity_hash = "b".repeat(64);
        new.quota.as_mut().unwrap().identity_hash = new.identity_hash.clone();
        gate.evidence
            .lock()
            .unwrap()
            .insert("new".into(), new.clone());
        // An acknowledged helper candidate is not participation if the saved
        // preference transaction fails. Retry on the same run stays idempotent.
        let preferences_path = dir.path().join("proxy.json");
        let original = std::fs::read(&preferences_path).unwrap();
        std::fs::remove_file(&preferences_path).unwrap();
        std::fs::create_dir(&preferences_path).unwrap();
        assert_eq!(
            service.enroll_new_verified_account("new"),
            Err(ProxyFailure::SaveFailed)
        );
        assert!(!service.preferences().unwrap().enabled_ids.contains("new"));
        assert!(service.host.lock().unwrap().is_registered("new"));
        assert_eq!(service.owned_fixture_pid(), pid);
        std::fs::remove_dir(&preferences_path).unwrap();
        std::fs::write(&preferences_path, original).unwrap();
        let saved = service.enroll_new_verified_account("new").unwrap();
        let persisted: ProxyPreferences =
            serde_json::from_slice(&std::fs::read(&preferences_path).unwrap()).unwrap();
        assert_eq!(persisted, saved);
        assert!(saved.enabled_ids.contains("new"));
        assert!(!saved.enabled_ids.contains("B"));
        assert_eq!(service.owned_fixture_pid(), pid);
        assert_eq!(service.status().unwrap().port, before.port);
        assert_eq!(service.host.lock().unwrap().running_id(), Some(run.clone()));
        assert!(service.host.lock().unwrap().is_registered("new"));
        // A second profile cannot reuse the newly registered identity.
        new.profile_id = "duplicate".into();
        gate.evidence
            .lock()
            .unwrap()
            .insert("duplicate".into(), new);
        assert_eq!(
            service.enroll_new_verified_account("duplicate"),
            Err(ProxyFailure::Identity)
        );
        assert!(!service
            .preferences()
            .unwrap()
            .enabled_ids
            .contains("duplicate"));
        assert!(!service.host.lock().unwrap().is_registered("duplicate"));
        assert_eq!(service.owned_fixture_pid(), pid);
        assert_eq!(service.stop().unwrap().phase, ProxyPhase::Stopped);
    }
}
