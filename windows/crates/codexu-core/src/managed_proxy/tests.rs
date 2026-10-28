use super::*;
use crate::accounts::AccountOccupancyGate;
use std::sync::atomic::{AtomicUsize, Ordering};

struct Source {
    generation: AtomicUsize,
    calls: AtomicUsize,
    change_at: AtomicUsize,
}
impl Default for Source {
    fn default() -> Self {
        Self {
            generation: AtomicUsize::new(1),
            calls: AtomicUsize::new(0),
            change_at: AtomicUsize::new(usize::MAX),
        }
    }
}
impl CredentialSource for Source {
    fn managed_ids(&self) -> Result<Vec<String>, ProxyFailure> {
        Ok(vec!["account-a".into()])
    }
    fn read(&self, id: &str, _refresh: bool) -> Result<Credential, ProxyFailure> {
        let call = self.calls.fetch_add(1, Ordering::SeqCst) + 1;
        if call == self.change_at.load(Ordering::SeqCst) {
            self.generation.fetch_add(1, Ordering::SeqCst);
        }
        let generation = self.generation.load(Ordering::SeqCst).to_string();
        let now = now_ms() as f64 / 1000.0;
        Ok(Credential {
            evidence: AccountEvidence {
                profile_id: id.into(),
                identity_hash: "a".repeat(64),
                token_generation: generation,
                identity_verified: true,
                is_system_home: false,
                is_desktop: false,
                plan: Some("plus".into()),
                quota: Some(QuotaEvidence {
                    observed_at: now,
                    read_succeeded: true,
                    last_failure_at: None,
                    identity_hash: "a".repeat(64),
                    five_hour: Some(QuotaWindowEvidence {
                        used_percent: 12.0,
                        resets_at: now + 500.0,
                    }),
                    seven_day: Some(QuotaWindowEvidence {
                        used_percent: 20.0,
                        resets_at: now + 1000.0,
                    }),
                    monthly: None,
                    credit_balance: Some("0".into()),
                    credit_balance_unlimited: Some(false),
                }),
            },
            access_token: "isolated-test-token-never-live".into(),
            account_id: "isolated-test-account".into(),
            expires_at: (now as i64) + 3600,
        })
    }
    fn read_desktop(
        &self,
        claim: &DesktopWriterClaim,
        proof: &DesktopQuotaEvidence,
    ) -> Result<Credential, ProxyFailure> {
        let mut c = self.read(&claim.profile_id, false)?;
        c.evidence.is_desktop = true;
        c.evidence.token_generation = proof.auth_digest[..32].into();
        c.evidence.quota.as_mut().unwrap().observed_at = proof.observed_at;
        Ok(c)
    }
    fn desktop_display(
        &self,
        claim: &DesktopWriterClaim,
        proof: &DesktopQuotaEvidence,
    ) -> Result<accounts::CachedQuotaSnapshot, ProxyFailure> {
        self.read_desktop(claim, proof)?;
        Ok(accounts::CachedQuotaSnapshot {
            plan: Some("plus".into()),
            official_quota: proof.rate_limits.clone(),
            observed_at: proof.observed_at.floor() as i64,
        })
    }
    fn display(&self, id: &str) -> Result<accounts::CachedQuotaSnapshot, ProxyFailure> {
        self.read(id, false)?;
        Ok(accounts::CachedQuotaSnapshot {
            plan: Some("plus".into()),
            official_quota: serde_json::json!({"source":"vault"}),
            observed_at: (now_ms() / 1000) as i64,
        })
    }
}
fn setup() -> (tempfile::TempDir, Arc<ManagedProxyGate>, Arc<Source>) {
    let dir = tempfile::tempdir().unwrap();
    let source = Arc::new(Source::default());
    let gate = ManagedProxyGate::with_source(dir.path().join("registry"), source.clone()).unwrap();
    (dir, gate, source)
}
fn request(id: &str) -> AdmissionRequest {
    AdmissionRequest {
        run_id: "run-a".into(),
        request_id: id.into(),
        profile_id: "account-a".into(),
        expected_identity_hash: "a".repeat(64),
        expected_generation: "1".into(),
        pass: AdmissionPass::Subscription,
        policy: AccountPolicy::default(),
        credit_floor: None,
        deadline_unix_ms: now_ms() + 18_000,
        request_started_at_unix_ms: now_ms(),
    }
}
fn tuple(id: &str) -> LeaseTuple {
    LeaseTuple {
        run_id: "run-a".into(),
        request_id: id.into(),
        profile_id: "account-a".into(),
        lease_id: String::new(),
    }
}

#[test]
fn stale_or_expired_evidence_refreshes_once_but_identity_failure_never_does() {
    struct RefreshSource {
        initial: ProxyFailure,
        refreshes: AtomicUsize,
        valid: Source,
    }
    impl CredentialSource for RefreshSource {
        fn managed_ids(&self) -> Result<Vec<String>, ProxyFailure> {
            self.valid.managed_ids()
        }
        fn read(&self, id: &str, refresh: bool) -> Result<Credential, ProxyFailure> {
            if !refresh {
                return Err(self.initial);
            }
            self.refreshes.fetch_add(1, Ordering::SeqCst);
            self.valid.read(id, true)
        }
    }
    for initial in [
        ProxyFailure::QuotaUnknown,
        ProxyFailure::LoginExpired,
        ProxyFailure::Identity,
    ] {
        let dir = tempfile::tempdir().unwrap();
        let source = Arc::new(RefreshSource {
            initial,
            refreshes: AtomicUsize::new(0),
            valid: Source::default(),
        });
        let gate =
            ManagedProxyGate::with_source(dir.path().join("registry"), source.clone()).unwrap();
        let result = gate.evidence("account-a");
        if initial == ProxyFailure::Identity {
            assert!(matches!(result, Err(ProxyFailure::Identity)));
            assert_eq!(source.refreshes.load(Ordering::SeqCst), 0);
        } else {
            let result = result.unwrap();
            assert_eq!(result.identity_hash, "a".repeat(64));
            assert_eq!(source.refreshes.load(Ordering::SeqCst), 1);
        }
        // Reading or refreshing evidence cannot create a dispatch lease.
        assert!(gate.lock().unwrap().journal.records.is_empty());
    }
}

#[test]
fn lease_exclusion_release_and_durable_redaction() {
    let (dir, gate, _) = setup();
    gate.activate_run("run-a").unwrap();
    let a = request("request-a");
    let leased = gate.reserve(&a).unwrap();
    assert_eq!(gate.reserve(&a).unwrap().tuple, leased.tuple);
    assert!(matches!(
        gate.reserve(&request("request-b")),
        Err(ProxyFailure::AccountBusy)
    ));
    let mut wrong = leased.tuple.clone();
    wrong.profile_id = "another-account".into();
    assert!(gate.heartbeat(&wrong).is_err());
    assert!(gate.release(&wrong).is_err());
    gate.heartbeat(&leased.tuple).unwrap();
    gate.release(&leased.tuple).unwrap();
    gate.release(&leased.tuple).unwrap();
    assert!(matches!(
        gate.reserve(&a),
        Err(ProxyFailure::AcquireAbandoned)
    ));
    gate.reserve(&request("request-b")).unwrap();
    let json = std::fs::read_to_string(dir.path().join("registry/dispatch-v1.json")).unwrap();
    assert!(!json.contains("isolated-test-token"));
    assert!(!json.contains("isolated-test-account"));
    assert!(!json.contains("access_token"));
}
#[test]
fn resolving_missing_admission_durably_denies_late_reserve() {
    let (_dir, gate, _) = setup();
    gate.activate_run("run-a").unwrap();
    assert!(matches!(
        gate.resolve(&tuple("late-request")).unwrap(),
        AdmissionResolution::NotReserved
    ));
    assert!(matches!(
        gate.reserve(&request("late-request")),
        Err(ProxyFailure::AcquireAbandoned)
    ));
}
#[test]
fn generation_change_between_intent_and_commit_never_returns_credentials() {
    let (_dir, gate, source) = setup();
    gate.activate_run("run-a").unwrap();
    source.change_at.store(2, Ordering::SeqCst);
    assert!(matches!(
        gate.reserve(&request("generation-race")),
        Err(ProxyFailure::Identity)
    ));
    assert!(matches!(
        gate.resolve(&tuple("generation-race")).unwrap(),
        AdmissionResolution::NotReserved
    ));
}
#[test]
fn maintenance_terminal_and_proxy_are_one_exclusion_domain() {
    let (_dir, gate, _) = setup();
    let hash = "a".repeat(64);
    let activity = gate.reserve_terminal(&hash).unwrap();
    assert!(gate.acquire_switch_maintenance("a", "switch-a").is_err());
    gate.activate_run("run-a").unwrap();
    assert!(matches!(
        gate.reserve(&request("same-identity")),
        Err(ProxyFailure::AccountBusy)
    ));
    gate.retire_run("run-a", true).unwrap();
    drop(activity);
    let maintenance = gate.acquire_switch_maintenance("a", "switch-a").unwrap();
    maintenance.recheck().unwrap();
    assert!(gate.reserve_terminal(&hash).is_err());
    assert!(gate.activate_run("run-a").is_err());
    drop(maintenance);
    gate.activate_run("run-a").unwrap();
    let leased = gate.reserve(&request("same-identity")).unwrap();
    assert!(gate.reserve_terminal(&hash).is_err());
    // A different verified identity is independent, not globally disabled.
    drop(gate.reserve_terminal(&"b".repeat(64)).unwrap());
    gate.release(&leased.tuple).unwrap();
    assert!(gate.acquire_switch_maintenance("a", "switch-b").is_err());
    gate.retire_run("run-a", true).unwrap();
    gate.reserve_terminal(&hash).unwrap();
}
#[test]
fn unconfirmed_exit_and_reopen_preserve_unknown_run() {
    let (dir, gate, source) = setup();
    gate.activate_run("run-a").unwrap();
    gate.reserve(&request("running")).unwrap();
    assert!(gate.retire_run("run-a", false).is_err());
    assert!(gate.retire_run("wrong-run", true).is_err());
    assert!(ManagedProxyGate::with_source(dir.path().join("registry"), source.clone()).is_err());
    drop(gate);
    let reopened = ManagedProxyGate::with_source(dir.path().join("registry"), source).unwrap();
    assert!(reopened.activate_run("new-run").is_err());
    assert!(reopened.acquire_switch_maintenance("a", "s").is_err());
    // A genuine owned-exit receipt is the only authority to retire. This fixture
    // provides it explicitly; product startup must never invent that receipt.
    reopened.retire_run("run-a", true).unwrap();
    reopened.activate_run("new-run").unwrap();
    assert!(reopened.reserve(&request("running")).is_err());
}
#[test]
fn corruption_and_failed_journal_write_fail_closed() {
    let (dir, gate, source) = setup();
    gate.activate_run("run-a").unwrap();
    std::fs::write(dir.path().join("registry/dispatch-v1.json"), b"invalid").unwrap();
    assert!(gate.reserve(&request("write-failure")).is_err());
    assert!(gate.evidence("account-a").is_err());
    assert_eq!(
        std::fs::read(dir.path().join("registry/dispatch-v1.json")).unwrap(),
        b"invalid"
    );
    drop(gate);
    assert!(ManagedProxyGate::with_source(dir.path().join("registry"), source).is_err());
}
#[test]
fn expired_requests_cannot_reenter_after_terminal_history_pruning() {
    let (_dir, gate, _) = setup();
    gate.activate_run("run-a").unwrap();
    let a = request("expired");
    let lease = gate.reserve(&a).unwrap();
    gate.release(&lease.tuple).unwrap();
    {
        let mut s = gate.shared.state.lock().unwrap();
        s.journal.records[0].forget_after_ms = 0;
    }
    let other = gate.reserve(&request("fresh")).unwrap();
    gate.release(&other.tuple).unwrap();
    let mut old = a;
    old.request_started_at_unix_ms = now_ms() - 17 * 60 * 1000;
    assert!(matches!(
        gate.reserve(&old),
        Err(ProxyFailure::AdmissionDeadline)
    ));
    assert_eq!(gate.shared.state.lock().unwrap().journal.records.len(), 1);
}
#[test]
fn pending_and_live_records_are_never_age_pruned() {
    let (_dir, gate, _) = setup();
    gate.activate_run("run-a").unwrap();
    gate.reserve(&request("still-live")).unwrap();
    {
        let mut s = gate.shared.state.lock().unwrap();
        s.journal.records[0].forget_after_ms = 0;
        s.journal.records[0].heartbeat_ms = 0;
    }
    assert!(matches!(
        gate.reserve(&request("new-request")),
        Err(ProxyFailure::AccountBusy)
    ));
    assert_eq!(gate.shared.state.lock().unwrap().journal.records.len(), 1);
}

fn prepare_desktop(gate: &ManagedProxyGate) -> DesktopWriterClaim {
    let claim = gate
        .claim_desktop_writer("account-a", "run-a", &"a".repeat(64), "1")
        .unwrap();
    let write = gate
        .acquire_credential_write(
            "account-a",
            accounts::CredentialWritePurpose::DesktopPrepare {
                writer_id: claim.writer_id.clone(),
            },
        )
        .unwrap();
    write.recheck().unwrap();
    drop(write);
    claim
}
fn proof(claim: &DesktopWriterClaim) -> DesktopQuotaEvidence {
    DesktopQuotaEvidence {
        writer_id: claim.writer_id.clone(),
        proxy_run_id: claim.proxy_run_id.clone(),
        backend_id: "isolated-desktop-backend".into(),
        observed_at: now_ms() as f64 / 1000.0,
        auth_digest: "c".repeat(64),
        account: serde_json::json!({"isolated":true}),
        rate_limits: serde_json::json!({"isolated":true}),
    }
}
#[test]
fn desktop_single_writer_fences_refresh_aliases_switch_and_second_prepare() {
    let (_dir, gate, _) = setup();
    gate.activate_run("run-a").unwrap();
    let claim = prepare_desktop(&gate);
    assert!(gate
        .acquire_credential_write("account-a", accounts::CredentialWritePurpose::Managed)
        .is_err());
    // A second managed profile with the same official identity cannot bypass
    // the writer fence by its local ID.
    assert!(gate
        .acquire_credential_write("account-alias", accounts::CredentialWritePurpose::Managed)
        .is_err());
    assert!(gate
        .acquire_credential_write(
            "account-a",
            accounts::CredentialWritePurpose::DesktopPrepare {
                writer_id: claim.writer_id.clone()
            }
        )
        .is_err());
    assert!(gate
        .claim_desktop_writer("account-alias", "run-a", &"a".repeat(64), "1")
        .is_err());
    assert!(gate.evidence("account-alias").is_err());
    assert!(gate.quota_snapshot("account-alias", false).is_err());
    assert!(gate.quota_snapshot("account-alias", true).is_err());
    assert!(gate.reserve_terminal(&"a".repeat(64)).is_err());
    assert!(gate
        .acquire_switch_maintenance("account-a", "switch")
        .is_err());
    assert!(gate.release_desktop_writer(&claim).is_err());
}
#[test]
fn desktop_evidence_never_uses_vault_before_first_proof_or_after_rebind() {
    let (dir, gate, source) = setup();
    gate.activate_run("run-a").unwrap();
    assert!(gate.desktop_quota_snapshot("account-a").unwrap().is_none());
    let claim = prepare_desktop(&gate);
    let before = source.calls.load(Ordering::SeqCst);
    assert!(matches!(
        gate.evidence("account-a"),
        Err(ProxyFailure::QuotaUnknown)
    ));
    assert!(gate.desktop_quota_snapshot("account-a").is_err());
    assert_eq!(source.calls.load(Ordering::SeqCst), before);
    let p = proof(&claim);
    gate.accept_desktop_evidence(&claim, p.clone()).unwrap();
    let displayed = gate.desktop_quota_snapshot("account-a").unwrap().unwrap();
    assert_eq!(displayed.official_quota, p.rate_limits);
    assert_eq!(displayed.observed_at, p.observed_at.floor() as i64);
    let c = gate.evidence("account-a").unwrap();
    assert!(c.is_desktop);
    assert_eq!(c.token_generation, "c".repeat(32));
    assert!(gate.accept_desktop_evidence(&claim, p.clone()).is_err());
    let mut foreign = p.clone();
    foreign.backend_id = "other-backend".into();
    foreign.observed_at += 0.001;
    assert!(gate.accept_desktop_evidence(&claim, foreign).is_err());
    let mut old = p.clone();
    old.observed_at -= 60.0;
    assert!(gate.accept_desktop_evidence(&claim, old).is_err());
    gate.retire_run("run-a", true).unwrap();
    assert!(gate.evidence("account-a").is_err());
    // Real host registration must not depend on quota from a run which does
    // not yet exist. Admission stays unknown until a new same-backend proof.
    let mut preferences = ProxyPreferences::default();
    preferences.is_enabled = true;
    preferences.enabled_ids.insert("account-a".into());
    preferences.known_ids.insert("account-a".into());
    let mut host = ProxyHost::new(preferences, gate.clone()).unwrap();
    let registered = host.begin("run-b".into(), "b".repeat(64)).unwrap();
    assert_eq!(registered, vec![("account-a".into(), "a".repeat(64))]);
    let next = gate.rebind_desktop_writer(&claim, "run-b").unwrap();
    assert!(gate.evidence("account-a").is_err());
    assert!(gate.desktop_quota_snapshot("account-a").is_err());
    assert!(gate.accept_desktop_evidence(&claim, p.clone()).is_err());
    let mut fresh = p;
    fresh.proxy_run_id = "run-b".into();
    fresh.observed_at += 0.002;
    gate.accept_desktop_evidence(&next, fresh).unwrap();
    assert!(gate.evidence("account-a").unwrap().is_desktop);
    let journal = std::fs::read_to_string(dir.path().join("registry/dispatch-v1.json")).unwrap();
    for secret in [
        "isolated-test-token",
        "rate_limits",
        "auth_digest",
        "isolated-test-account",
        "\"account\"",
    ] {
        assert!(!journal.contains(secret));
    }
}
#[test]
fn desktop_exit_waits_for_existing_reply_and_needs_finalize_before_release() {
    let (_dir, gate, _) = setup();
    gate.activate_run("run-a").unwrap();
    let claim = prepare_desktop(&gate);
    gate.accept_desktop_evidence(&claim, proof(&claim)).unwrap();
    let mut r = request("desktop-request");
    r.pass = AdmissionPass::DesktopSubscription;
    r.expected_generation = "c".repeat(32);
    let lease = gate.reserve(&r).unwrap();
    assert!(gate.confirm_desktop_exit(&claim).is_err());
    assert!(gate
        .acquire_credential_write(
            "account-a",
            accounts::CredentialWritePurpose::DesktopFinalize {
                writer_id: claim.writer_id.clone()
            }
        )
        .is_err());
    gate.release(&lease.tuple).unwrap();
    gate.confirm_desktop_exit(&claim).unwrap();
    gate.confirm_desktop_exit(&claim).unwrap();
    assert!(gate.evidence("account-a").is_err());
    let finalize = gate
        .acquire_credential_write(
            "account-a",
            accounts::CredentialWritePurpose::DesktopFinalize {
                writer_id: claim.writer_id.clone(),
            },
        )
        .unwrap();
    finalize.recheck().unwrap();
    assert!(gate.release_desktop_writer(&claim).is_err());
    drop(finalize);
    gate.release_desktop_writer(&claim).unwrap();
    assert!(gate.release_desktop_writer(&claim).is_err());
    assert!(!gate.evidence("account-a").unwrap().is_desktop);
}
#[test]
fn restart_cannot_adopt_or_clear_old_desktop_claim_or_use_its_vault_copy() {
    let (dir, gate, source) = setup();
    gate.activate_run("run-a").unwrap();
    let claim = prepare_desktop(&gate);
    gate.accept_desktop_evidence(&claim, proof(&claim)).unwrap();
    gate.retire_run("run-a", true).unwrap();
    drop(gate);
    let gate = ManagedProxyGate::with_source(dir.path().join("registry"), source).unwrap();
    assert!(gate.activate_run("run-b").is_err());
    assert!(gate.registration("account-a").is_err());
    assert!(gate.evidence("account-a").is_err());
    assert!(gate.recheck_desktop_writer(&claim).is_err());
    assert!(gate.confirm_desktop_exit(&claim).is_err());
    assert!(gate.release_desktop_writer(&claim).is_err());
    assert!(gate
        .acquire_credential_write("account-a", accounts::CredentialWritePurpose::Managed)
        .is_err());
}
#[test]
fn recovery_requires_separate_helper_and_gui_proofs_and_never_reclaims_current_owner() {
    let (dir, gate, source) = setup();
    gate.activate_run("run-a").unwrap();
    let claim = prepare_desktop(&gate);
    gate.accept_desktop_evidence(&claim, proof(&claim)).unwrap();
    let mut r = request("recovery-existing-reply");
    r.pass = AdmissionPass::DesktopSubscription;
    r.expected_generation = "c".repeat(32);
    gate.reserve(&r).unwrap();
    let helper = ProxyHelperRecoveryProof::synthetic("run-a".into());
    let gui = DesktopRecoveryProof::synthetic(claim.clone(), DesktopRecoveryKind::Exited);
    assert!(gate.recover_proxy_run(&helper).is_err());
    assert!(gate.recover_desktop_writer(&gui).is_err());
    assert!(gate.desktop_recovery_candidates().unwrap().is_empty());
    assert!(gate.proxy_run_recovery_candidate().unwrap().is_none());
    drop(gate);
    let gate = ManagedProxyGate::with_source(dir.path().join("registry"), source).unwrap();
    assert!(gate
        .recover_proxy_run(&ProxyHelperRecoveryProof::synthetic("wrong-run".into()))
        .is_err());
    assert!(gate.recover_desktop_writer(&gui).is_err());
    assert_eq!(gate.lock().unwrap().journal.records.len(), 1);
    gate.recover_proxy_run(&helper).unwrap();
    assert!(gate.recover_proxy_run(&helper).is_err());
    assert_eq!(gate.desktop_recovery_candidates().unwrap().len(), 1);
    assert!(gate.activate_run("run-b").is_err());
    let recovered = gate.recover_desktop_writer(&gui).unwrap();
    assert_eq!(recovered.writer_id, claim.writer_id);
    assert!(gate.evidence("account-a").is_err());
    assert!(gate
        .acquire_credential_write("account-a", accounts::CredentialWritePurpose::Managed)
        .is_err());
    // Retry of the same authenticated receipt cannot make this writer active.
    gate.recover_desktop_writer(&gui).unwrap();
    let finalize = gate
        .acquire_credential_write(
            "account-a",
            accounts::CredentialWritePurpose::DesktopFinalize {
                writer_id: claim.writer_id.clone(),
            },
        )
        .unwrap();
    finalize.recheck().unwrap();
    drop(finalize);
    gate.release_desktop_writer(&recovered).unwrap();
    assert!(gate.recover_desktop_writer(&gui).is_err());
    gate.activate_run("run-b").unwrap();
}
#[test]
fn fixed_initial_receipt_survives_rebind_but_does_not_authorize_other_claims() {
    let (dir, gate, source) = setup();
    gate.activate_run("run-a").unwrap();
    let first = prepare_desktop(&gate);
    gate.accept_desktop_evidence(&first, proof(&first)).unwrap();
    gate.retire_run("run-a", true).unwrap();
    gate.activate_run("run-b").unwrap();
    let current = gate.rebind_desktop_writer(&first, "run-b").unwrap();
    gate.retire_run("run-b", true).unwrap();
    drop(gate);
    let gate = ManagedProxyGate::with_source(dir.path().join("registry"), source).unwrap();
    let wrong_run = DesktopRecoveryProof::synthetic(current.clone(), DesktopRecoveryKind::Exited);
    assert!(gate.recover_desktop_writer(&wrong_run).is_err());
    // A changed immutable tuple never acquires a finalize capability.
    let mut wrong = first.clone();
    wrong.identity_hash = "d".repeat(64);
    assert!(gate
        .recover_desktop_writer(&DesktopRecoveryProof::synthetic(
            wrong,
            DesktopRecoveryKind::Exited
        ))
        .is_err());
    let mut wrong = first.clone();
    wrong.initial_generation = "2".into();
    assert!(gate
        .recover_desktop_writer(&DesktopRecoveryProof::synthetic(
            wrong,
            DesktopRecoveryKind::Exited
        ))
        .is_err());
    let mut wrong = first.clone();
    wrong.profile_id = "other".into();
    assert!(gate
        .recover_desktop_writer(&DesktopRecoveryProof::synthetic(
            wrong,
            DesktopRecoveryKind::Exited
        ))
        .is_err());
    let mut wrong = first.clone();
    wrong.writer_id = "other".into();
    assert!(gate
        .recover_desktop_writer(&DesktopRecoveryProof::synthetic(
            wrong,
            DesktopRecoveryKind::Exited
        ))
        .is_err());
    assert!(gate
        .recover_desktop_writer(&DesktopRecoveryProof::synthetic(
            first.clone(),
            DesktopRecoveryKind::Prepared
        ))
        .is_err());
    let recovered = gate
        .recover_desktop_writer(&DesktopRecoveryProof::synthetic(
            first,
            DesktopRecoveryKind::Exited,
        ))
        .unwrap();
    assert_eq!(recovered.proxy_run_id, "run-b");
    gate.release_desktop_writer(&recovered).unwrap();
}
#[test]
fn prepared_recovery_remains_fail_closed_until_abandon_and_release() {
    let (dir, gate, source) = setup();
    gate.activate_run("run-a").unwrap();
    let claim = prepare_desktop(&gate);
    gate.retire_run("run-a", true).unwrap();
    drop(gate);
    let gate = ManagedProxyGate::with_source(dir.path().join("registry"), source).unwrap();
    let recovered = gate
        .recover_desktop_writer(&DesktopRecoveryProof::synthetic(
            claim,
            DesktopRecoveryKind::Prepared,
        ))
        .unwrap();
    assert!(gate.evidence("account-a").is_err());
    assert!(gate.activate_run("run-b").is_err());
    let cleanup = gate
        .acquire_credential_write(
            "account-a",
            accounts::CredentialWritePurpose::DesktopFinalize {
                writer_id: recovered.writer_id.clone(),
            },
        )
        .unwrap();
    cleanup.recheck().unwrap();
    drop(cleanup);
    gate.release_desktop_writer(&recovered).unwrap();
    gate.activate_run("run-b").unwrap();
}
#[test]
fn credential_write_and_request_with_another_profile_for_same_identity_exclude_each_other() {
    let (_dir, gate, _) = setup();
    gate.activate_run("run-a").unwrap();
    let lease = gate.reserve(&request("alias-active")).unwrap();
    assert!(gate
        .acquire_credential_write("account-alias", accounts::CredentialWritePurpose::Managed)
        .is_err());
    let mut t = tuple("alias-active");
    t.lease_id = lease.tuple.lease_id;
    gate.release(&t).unwrap();
    let writer = gate
        .acquire_credential_write("account-alias", accounts::CredentialWritePurpose::Managed)
        .unwrap();
    assert!(gate.reserve(&request("alias-blocked")).is_err());
    writer.recheck().unwrap();
    drop(writer);
    gate.reserve(&request("alias-after-release")).unwrap();
}
#[test]
fn refresh_guard_and_desktop_claim_cannot_race_or_create_a_second_writer() {
    let (_dir, gate, _) = setup();
    let guard = gate
        .acquire_credential_write("account-a", accounts::CredentialWritePurpose::Managed)
        .unwrap();
    assert!(gate
        .acquire_switch_maintenance("account-a", "switch")
        .is_err());
    assert!(gate
        .acquire_credential_write("account-b", accounts::CredentialWritePurpose::Managed)
        .is_err());
    gate.activate_run("run-a").unwrap();
    assert!(gate
        .claim_desktop_writer("account-a", "run-a", &"a".repeat(64), "1")
        .is_err());
    assert!(gate.reserve(&request("while-refreshing")).is_err());
    drop(guard);
    let claim = prepare_desktop(&gate);
    gate.confirm_desktop_exit(&claim).unwrap();
    gate.release_desktop_writer(&claim).unwrap();
    gate.retire_run("run-a", true).unwrap();
    let maintenance = gate
        .acquire_switch_maintenance("account-a", "switch")
        .unwrap();
    let guard = gate
        .acquire_credential_write("account-a", accounts::CredentialWritePurpose::Managed)
        .unwrap();
    guard.recheck().unwrap();
    maintenance.recheck().unwrap();
}

#[test]
fn writer_recheck_does_not_reenter_the_vault_and_unidentified_login_excludes_requests() {
    struct IdentitySource {
        base: Source,
        reads: AtomicUsize,
        unidentified: bool,
    }
    impl CredentialSource for IdentitySource {
        fn managed_ids(&self) -> Result<Vec<String>, ProxyFailure> {
            self.base.managed_ids()
        }
        fn read(&self, id: &str, refresh: bool) -> Result<Credential, ProxyFailure> {
            self.base.read(id, refresh)
        }
        fn identity(&self, _id: &str) -> Result<Option<String>, ProxyFailure> {
            if self.reads.fetch_add(1, Ordering::SeqCst) != 0 {
                return Err(ProxyFailure::AccountBusy);
            }
            Ok((!self.unidentified).then(|| "b".repeat(64)))
        }
    }
    for unidentified in [false, true] {
        let dir = tempfile::tempdir().unwrap();
        let source = Arc::new(IdentitySource {
            base: Source::default(),
            reads: AtomicUsize::new(0),
            unidentified,
        });
        let gate =
            ManagedProxyGate::with_source(dir.path().join("registry"), source.clone()).unwrap();
        gate.activate_run("run-a").unwrap();
        let writer = gate
            .acquire_credential_write("account-b", accounts::CredentialWritePurpose::Managed)
            .unwrap();
        writer.recheck().unwrap();
        writer.recheck().unwrap();
        let result = gate.reserve(&request("different-account"));
        assert_eq!(result.is_err(), unidentified);
        writer.recheck().unwrap();
        assert_eq!(source.reads.load(Ordering::SeqCst), 1);
    }
}

#[test]
fn quota_display_holds_the_source_selection_until_pure_read_finishes() {
    struct InterleavingSource {
        base: Source,
        gate: Mutex<Option<Weak<ManagedProxyGate>>>,
        claim_was_blocked: AtomicUsize,
    }
    impl CredentialSource for InterleavingSource {
        fn managed_ids(&self) -> Result<Vec<String>, ProxyFailure> {
            self.base.managed_ids()
        }
        fn read(&self, id: &str, refresh: bool) -> Result<Credential, ProxyFailure> {
            self.base.read(id, refresh)
        }
        fn display(&self, id: &str) -> Result<accounts::CachedQuotaSnapshot, ProxyFailure> {
            let gate = self
                .gate
                .lock()
                .unwrap()
                .as_ref()
                .unwrap()
                .upgrade()
                .unwrap();
            if matches!(
                gate.claim_desktop_writer(id, "run-a", &"a".repeat(64), "1"),
                Err(ProxyFailure::ControlBusy)
            ) {
                self.claim_was_blocked.fetch_add(1, Ordering::SeqCst);
            }
            self.base.display(id)
        }
    }
    let dir = tempfile::tempdir().unwrap();
    let source = Arc::new(InterleavingSource {
        base: Source::default(),
        gate: Mutex::new(None),
        claim_was_blocked: AtomicUsize::new(0),
    });
    let gate = ManagedProxyGate::with_source(dir.path().join("registry"), source.clone()).unwrap();
    *source.gate.lock().unwrap() = Some(Arc::downgrade(&gate));
    gate.activate_run("run-a").unwrap();
    let snapshot = gate.quota_snapshot("account-a", false).unwrap();
    assert_eq!(snapshot.official_quota["source"], "vault");
    assert_eq!(source.claim_was_blocked.load(Ordering::SeqCst), 1);
    let claim = prepare_desktop(&gate);
    assert!(gate.quota_snapshot("account-a", false).is_err());
    gate.confirm_desktop_exit(&claim).unwrap();
}
