//! Native-only authority after positive exit, separate from a live daemon.
//! No public constructor, serialized fields, WebView input or disconnect proof.
use super::*;
use crate::{accounts::SwitchCommitGuard, managed_proxy::AutomaticMaintenanceLease};
use std::{
    sync::{atomic::AtomicBool, Weak},
    time::{Duration, Instant},
};

pub(super) trait CloseTarget: Send + Sync {
    /// May send only a bounded graceful request to this exact retained entity.
    /// The callback must pass again immediately before each request and while
    /// waiting. Successful delivery alone must never return Ok.
    fn close_and_confirm(
        &self,
        before_close: &dyn Fn() -> LiveResult<()>,
        current: &dyn Fn() -> LiveResult<()>,
    ) -> LiveResult<()>;
    /// Positive held-handle exit plus a new complete conservative OS inventory.
    fn recheck_quiesced(
        &self,
        permitted: &[crate::accounts::OwnedVerificationProcess],
    ) -> LiveResult<()>;
}

pub struct QuiescedSystemProof {
    scope: SystemDaemonScope,
    lease: AutomaticMaintenanceLease,
    automatic_epoch: u64,
    peer_generation: String,
    roster_revision: u64,
    expires: Instant,
    target: Arc<dyn CloseTarget>,
    policy: Arc<dyn SwitchCommitGuard>,
    lifecycle: Arc<dyn Fn() -> LiveResult<()> + Send + Sync>,
    revoked: AtomicBool,
    used_for_commit: AtomicBool,
    checked: std::sync::Mutex<Instant>,
    permitted: std::sync::Mutex<Vec<crate::accounts::OwnedVerificationProcess>>,
    native_gate: Arc<std::sync::atomic::AtomicU8>,
}
impl QuiescedSystemProof {
    pub(super) fn close(
        lease: AutomaticMaintenanceLease,
        automatic_epoch: u64,
        snapshot: Arc<LiveTaskSnapshot>,
        target: Arc<dyn CloseTarget>,
        policy: Arc<dyn SwitchCommitGuard>,
        lifecycle: Arc<dyn Fn() -> LiveResult<()> + Send + Sync>,
    ) -> LiveResult<Arc<Self>> {
        let remaining = snapshot
            .observed_at_unix_ms
            .checked_add(TASK_MAX_AGE_MS)
            .and_then(|end| end.checked_sub(super::super::now_ms()))
            .filter(|remaining| *remaining <= TASK_MAX_AGE_MS)
            .ok_or(LiveIssue::Incomplete)?;
        let expires = Instant::now() + Duration::from_millis(remaining);
        let current = || {
            lifecycle()?;
            policy.recheck().map_err(|_| LiveIssue::Cancelled)?;
            lease
                .recheck_cached()
                .map_err(|_| LiveIssue::ScopeUnverified)?;
            if Instant::now() >= expires {
                return Err(LiveIssue::Incomplete);
            }
            Ok(())
        };
        let before_close = || {
            current()?;
            if !snapshot.is_current() {
                return Err(LiveIssue::Incomplete);
            }
            Ok(())
        };
        before_close()?;
        target.close_and_confirm(&before_close, &current)?;
        // EOF may now have invalidated the ordinary live cache. It cannot mint
        // this proof: close_and_confirm and this second native check both need
        // the exact retained kernel object's positive signaled exit.
        lifecycle()?;
        policy.recheck().map_err(|_| LiveIssue::Cancelled)?;
        lease.recheck().map_err(|_| LiveIssue::ScopeUnverified)?;
        target.recheck_quiesced(&[])?;
        let proof = Arc::new(Self {
            scope: snapshot.scope.clone(),
            lease,
            automatic_epoch,
            peer_generation: snapshot.connection_generation.clone(),
            roster_revision: snapshot.revision,
            expires,
            target,
            policy,
            lifecycle,
            revoked: AtomicBool::new(false),
            used_for_commit: AtomicBool::new(false),
            checked: std::sync::Mutex::new(Instant::now()),
            permitted: std::sync::Mutex::new(Vec::new()),
            native_gate: Arc::new(std::sync::atomic::AtomicU8::new(0)),
        });
        let weak = Arc::downgrade(&proof);
        std::thread::Builder::new()
            .name("agb-quiesced-system-fence".into())
            .spawn(move || {
                Self::monitor(weak);
            })
            .map_err(|_| {
                proof.revoke();
                LiveIssue::Unavailable
            })?;
        proof.recheck_cached()?;
        Ok(proof)
    }
    fn monitor(weak: Weak<Self>) {
        loop {
            let Some(proof) = weak.upgrade() else { break };
            if proof.recheck_cached().is_err() || proof.lease.recheck().is_err() {
                proof.revoke();
                break;
            }
            if let Ok(scan) =
                proof
                    .native_gate
                    .compare_exchange(0, 1, Ordering::AcqRel, Ordering::Acquire)
            {
                let _ = scan;
                let _scan = NativeGate(proof.native_gate.clone());
                let result = proof
                    .permitted
                    .lock()
                    .map_err(|_| LiveIssue::Unavailable)
                    .and_then(|permitted| proof.target.recheck_quiesced(&permitted));
                if result.is_err() {
                    proof.revoke();
                    break;
                }
                match proof.checked.lock() {
                    Ok(mut checked) => *checked = Instant::now(),
                    Err(_) => {
                        proof.revoke();
                        break;
                    }
                }
            }
            drop(proof);
            std::thread::sleep(Duration::from_millis(250));
        }
    }
    pub fn operation_id(&self) -> &str {
        self.lease.operation_id()
    }
    pub fn source_profile_id(&self) -> &str {
        &self.scope.profile_id
    }
    pub fn source_identity_hash(&self) -> &str {
        &self.scope.identity_hash
    }
    pub fn source_credential_generation(&self) -> &str {
        &self.scope.credential_generation
    }
    pub fn target_profile_id(&self) -> &str {
        self.lease.target_profile_id()
    }
    pub fn automatic_epoch(&self) -> u64 {
        self.automatic_epoch
    }
    pub fn previous_peer_generation(&self) -> &str {
        &self.peer_generation
    }
    pub fn final_roster_revision(&self) -> u64 {
        self.roster_revision
    }
    pub fn revoke(&self) {
        self.revoked.store(true, Ordering::Release);
    }
    /// Memory-only commit fence. Its native sampler owns OS scans, and no
    /// callback here may reopen a manager/vault, reconnect or inspect SQLite.
    pub fn recheck_cached(&self) -> LiveResult<()> {
        if self.revoked.load(Ordering::Acquire)
            || Instant::now() >= self.expires
            || self
                .checked
                .try_lock()
                .map_err(|_| LiveIssue::Unavailable)?
                .elapsed()
                > Duration::from_millis(super::activity::ACTIVITY_MAX_AGE_MS)
        {
            return Err(LiveIssue::Incomplete);
        }
        (self.lifecycle)()?;
        self.policy.recheck().map_err(|_| LiveIssue::Cancelled)?;
        self.lease
            .recheck_cached()
            .map_err(|_| LiveIssue::ScopeUnverified)
    }
    /// The service calls this once before AccountManager consumes its prepared
    /// ticket; rejection never prevents AccountManager's exact rollback path.
    pub fn claim_for_commit(&self) -> LiveResult<()> {
        self.recheck_cached()?;
        self.used_for_commit
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .map_err(|_| LiveIssue::Cancelled)?;
        Ok(())
    }
    pub fn verification_process_permit(
        self: &Arc<Self>,
    ) -> Arc<dyn crate::accounts::VerificationProcessPermit> {
        Arc::new(Permit(self.clone()))
    }
}
struct NativeGate(Arc<std::sync::atomic::AtomicU8>);
impl crate::accounts::VerificationSpawnLease for NativeGate {}
impl Drop for NativeGate {
    fn drop(&mut self) {
        self.0.store(0, Ordering::Release);
    }
}
struct Permit(Arc<QuiescedSystemProof>);
fn denied() -> crate::accounts::AccountError {
    crate::accounts::AccountError {
        code: "switch_cancelled",
    }
}
impl crate::accounts::VerificationProcessPermit for Permit {
    fn recheck(&self) -> crate::accounts::AccountResult<()> {
        self.0.recheck_cached().map_err(|_| denied())
    }
    fn begin_spawn(
        &self,
    ) -> crate::accounts::AccountResult<Box<dyn crate::accounts::VerificationSpawnLease>> {
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            self.recheck()?;
            if self
                .0
                .native_gate
                .compare_exchange(0, 2, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
            {
                return Ok(Box::new(NativeGate(self.0.native_gate.clone())));
            }
            if Instant::now() >= deadline {
                return Err(denied());
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    fn register(
        &self,
        process: crate::accounts::OwnedVerificationProcess,
    ) -> crate::accounts::AccountResult<()> {
        self.recheck()?;
        if self.0.native_gate.load(Ordering::Acquire) != 2 {
            return Err(denied());
        }
        let mut permitted = self.0.permitted.lock().map_err(|_| denied())?;
        if permitted.len() >= 32 || permitted.iter().any(|old| old.same(&process)) {
            return Err(denied());
        }
        permitted.push(process);
        Ok(())
    }
    fn completed(
        &self,
        process: &crate::accounts::OwnedVerificationProcess,
    ) -> crate::accounts::AccountResult<()> {
        // Cleanup must finish even after user cancellation. Keep the receipt
        // retained; an empty Job cannot authorize a later unrelated process.
        let known = self
            .0
            .permitted
            .lock()
            .map_err(|_| denied())?
            .iter()
            .any(|p| p.same(process));
        if !known || !process.confirmed_empty()? {
            self.0.revoke();
            return Err(denied());
        }
        Ok(())
    }
}
