use super::{
    journal::{Binding, Entry, Journal, Phase},
    *,
};
use std::{
    collections::BTreeMap,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

struct Reservation<P> {
    id: String,
    reserve_id: String,
    actor: String,
    runtime: String,
    scope: Scope,
    intent: String,
    deadline: Instant,
    permit: P,
}
/// One App-owned instance. The native receiver must dispatch this synchronous
/// method on its own worker; dropping a connection is not cancellation of work.
pub struct Bridge<B: Backend> {
    backend: Arc<B>,
    pub(super) journal: Journal,
    reservations: Mutex<BTreeMap<String, Reservation<B::Permit>>>,
}
impl<B: Backend> Bridge<B> {
    pub fn new(private_root: PathBuf, backend: Arc<B>) -> Result<Self> {
        Ok(Self {
            backend,
            journal: Journal::new(private_root)?,
            reservations: Mutex::new(BTreeMap::new()),
        })
    }
    /// Receiver idle maintenance only; no account I/O or new timer/monitor.
    /// Claimed/adopted guards are absent from this map and cannot be released.
    pub fn expire_unclaimed(&self) -> Result<usize> {
        let mut leases = self
            .reservations
            .try_lock()
            .map_err(|_| fail("companion_bridge_busy"))?;
        let before = leases.len();
        let now = self.backend.now_ms();
        leases.retain(|_, v| v.deadline > Instant::now() && v.scope.valid_until_ms > now);
        Ok(before - leases.len())
    }
    /// Native receiver shutdown, not an IPC assertion that tasks have stopped.
    pub fn close_preparing(&self) -> Result<()> {
        self.reservations
            // Cleanup stays on the receiver's owned worker. If another local
            // call is finishing, Receiver::stop may report unconfirmed while
            // that worker retains its fence. Poison cannot make an unclaimed
            // permit into a submitted task; only this map is cleared.
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clear();
        Ok(())
    }
    fn scope(&self, peer: &Peer, selector: &Selector, refresh: bool) -> Result<Scope> {
        selector.validate()?;
        peer.check()?;
        let scope = self.backend.capture(selector, refresh)?;
        peer.check()?;
        if !scope.valid(self.backend.now_ms()) || scope.runtime_sha256 != peer.runtime {
            return Err(fail("companion_scope_changed"));
        }
        Ok(scope)
    }
    pub fn handle(&self, peer: &Peer, request: Request) -> Result<Reply> {
        request.validate()?;
        peer.check()?;
        match request.method {
            Method::Preflight { selector } => {
                let scope = self.scope(peer, &selector, false)?;
                Ok(Reply::Ready {
                    scope_sha256: scope.fingerprint,
                    valid_until_ms: scope.valid_until_ms,
                })
            }
            Method::Refresh { selector } => {
                let scope = self.scope(peer, &selector, true)?;
                Ok(Reply::Ready {
                    scope_sha256: scope.fingerprint,
                    valid_until_ms: scope.valid_until_ms,
                })
            }
            Method::Reserve { intent } => self.reserve(peer, &request.request_id, &intent),
            Method::Run { lease_id, intent } => {
                self.run(peer, &request.request_id, &lease_id, &intent)
            }
            Method::Status { operation_id } => self.status(peer, &operation_id),
            Method::CancelReservation { lease_id } => {
                let mut leases = self
                    .reservations
                    .try_lock()
                    .map_err(|_| fail("companion_bridge_busy"))?;
                if let Some(lease) = leases.get(&lease_id) {
                    if lease.actor != peer.actor || lease.runtime != peer.runtime {
                        return Err(fail("companion_peer_untrusted"));
                    }
                    leases.remove(&lease_id);
                    Ok(Reply::Cancelled)
                } else {
                    Err(fail("companion_lease_unavailable"))
                }
            }
        }
    }
    fn reserve(&self, peer: &Peer, id: &str, intent: &Intent) -> Result<Reply> {
        let fingerprint = intent.fingerprint()?;
        let mut leases = self
            .reservations
            .try_lock()
            .map_err(|_| fail("companion_bridge_busy"))?;
        let now = self.backend.now_ms();
        leases.retain(|_, v| v.deadline > Instant::now() && v.scope.valid_until_ms > now);
        if let Some(v) = leases.values().find(|v| v.reserve_id == id) {
            if v.actor != peer.actor || v.runtime != peer.runtime || v.intent != fingerprint {
                return Err(fail("companion_request_changed"));
            }
            let scope = self.scope(peer, &intent.selector, false)?;
            if !same_scope(&scope, &v.scope) {
                return Err(fail("companion_scope_changed"));
            }
            return Ok(Reply::Reserved {
                lease_id: v.id.clone(),
                scope_sha256: v.scope.fingerprint.clone(),
                valid_until_ms: v.scope.valid_until_ms,
            });
        }
        if leases.len() >= 128 {
            return Err(fail("companion_reservation_limit"));
        }
        // Capture/controlled freshness precedes acquisition of the existing gate.
        let scope = self.scope(peer, &intent.selector, true)?;
        let permit = self.backend.reserve(&scope)?;
        let after = self.scope(peer, &intent.selector, false)?;
        if !same_scope(&scope, &after) {
            return Err(fail("companion_scope_changed"));
        }
        let remaining = scope
            .valid_until_ms
            .saturating_sub(self.backend.now_ms())
            .min(45_000);
        if remaining == 0 {
            return Err(fail("companion_lease_expired"));
        }
        let lease = nonce()?;
        let reply = Reply::Reserved {
            lease_id: lease.clone(),
            scope_sha256: scope.fingerprint.clone(),
            valid_until_ms: scope.valid_until_ms,
        };
        leases.insert(
            lease.clone(),
            Reservation {
                id: lease,
                reserve_id: id.into(),
                actor: peer.actor.clone(),
                runtime: peer.runtime.clone(),
                scope,
                intent: fingerprint,
                deadline: Instant::now() + Duration::from_millis(remaining),
                permit,
            },
        );
        Ok(reply)
    }
    fn run(&self, peer: &Peer, id: &str, lease_id: &str, intent: &Intent) -> Result<Reply> {
        let fingerprint = intent.fingerprint()?;
        if let Some(old) = self.journal.get(id)? {
            if old.binding.actor != peer.actor
                || old.binding.runtime != peer.runtime
                || old.binding.intent != fingerprint
                || old.binding.lease != lease_id
            {
                return Err(fail("companion_request_changed"));
            }
            // A prior Pending/Created/Accepted request is NEVER another POST.
            return self.status(peer, id);
        }
        let mut leases = self
            .reservations
            .try_lock()
            .map_err(|_| fail("companion_bridge_busy"))?;
        let v = leases
            .get(lease_id)
            .ok_or_else(|| fail("companion_lease_unavailable"))?;
        if v.actor != peer.actor || v.runtime != peer.runtime || v.intent != fingerprint {
            return Err(fail("companion_request_changed"));
        }
        if v.deadline <= Instant::now() || !v.scope.valid(self.backend.now_ms()) {
            return Err(fail("companion_lease_expired"));
        }
        let current = self.scope(peer, &intent.selector, false)?;
        if !same_scope(&current, &v.scope) {
            return Err(fail("companion_scope_changed"));
        }
        let entry = Entry {
            binding: Binding {
                actor: peer.actor.clone(),
                runtime: peer.runtime.clone(),
                scope: v.scope.fingerprint.clone(),
                epoch: v.scope.epoch.clone(),
                intent: fingerprint,
                lease: lease_id.into(),
                create_id: hash_parts(&["companion-create", id]),
                create_body: hash_parts(&[
                    "create",
                    "codex",
                    "workspace",
                    &v.scope.alias,
                    &hash(intent.prompt.as_bytes()),
                    "",
                ]),
                approve_id: hash_parts(&["companion-approve", id]),
            },
            phase: Phase::PendingCreate,
        };
        if !self.journal.claim(id, &entry)? {
            return self.status(peer, id);
        }
        let owned = leases.remove(lease_id).unwrap();
        drop(leases);
        // The Session owns the guard before any backend mutation. A later
        // receipt failure/disconnect never releases it through this stack.
        if self
            .backend
            .adopt(lease_id, &owned.scope, owned.permit)
            .is_err()
        {
            return Ok(Reply::Unknown);
        }
        if peer.check().is_err() {
            return Ok(Reply::Unknown);
        }
        let created = match self.backend.create(
            lease_id,
            &owned.scope,
            &entry.binding.create_id,
            &intent.prompt,
        ) {
            Ok(v)
                if valid_ack(
                    &v,
                    &entry.binding.create_id,
                    &entry.binding.create_body,
                    &entry.binding.scope,
                    None,
                ) && v.state == TaskState::AwaitingApproval =>
            {
                v
            }
            _ => return Ok(Reply::Unknown),
        };
        let entry = match self.journal.advance(
            id,
            &entry,
            Phase::Created {
                task: created.task.clone(),
            },
        ) {
            Ok(v) => v,
            Err(_) => return Ok(Reply::Unknown),
        };
        // Re-read after create. The native backend also repeats its actual
        // action hash, identity, policy, quota and final-spawn checks.
        match self.scope(peer, &intent.selector, false) {
            Ok(scope)
                if same_scope(&scope, &owned.scope)
                    && owned.scope.valid(self.backend.now_ms())
                    && owned.deadline > Instant::now() => {}
            _ => {
                return Ok(Reply::Created {
                    task: created.task,
                    task_state: TaskState::AwaitingApproval,
                })
            }
        }
        let body = hash_parts(&["approve", &created.task.task_id, &created.task.action_hash]);
        let entry = match self.journal.advance(
            id,
            &entry,
            Phase::PendingApprove {
                task: created.task.clone(),
                body: body.clone(),
            },
        ) {
            Ok(v) => v,
            Err(_) => return Ok(Reply::Unknown),
        };
        if peer.check().is_err() {
            return Ok(Reply::Unknown);
        }
        let acknowledged = match self.backend.approve(
            lease_id,
            &owned.scope,
            &entry.binding.approve_id,
            &created.task,
        ) {
            Ok(v)
                if valid_ack(
                    &v,
                    &entry.binding.approve_id,
                    &body,
                    &entry.binding.scope,
                    Some(&created.task),
                ) && v.state != TaskState::AwaitingApproval =>
            {
                v
            }
            _ => return Ok(Reply::Unknown),
        };
        if self
            .journal
            .advance(
                id,
                &entry,
                Phase::Accepted {
                    task: created.task,
                    body,
                },
            )
            .is_err()
        {
            return Ok(Reply::Unknown);
        }
        Ok(Reply::Accepted {
            task: acknowledged.task,
            task_state: acknowledged.state,
        })
    }
    fn status(&self, peer: &Peer, id: &str) -> Result<Reply> {
        let Some(entry) = self.journal.get(id)? else {
            return Ok(Reply::Missing);
        };
        if entry.binding.actor != peer.actor || entry.binding.runtime != peer.runtime {
            return Err(fail("companion_peer_untrusted"));
        }
        let (action, request, body, task) = match &entry.phase {
            Phase::PendingCreate => (
                LookupAction::Create,
                &entry.binding.create_id,
                &entry.binding.create_body,
                None,
            ),
            Phase::Created { task } => (
                LookupAction::Create,
                &entry.binding.create_id,
                &entry.binding.create_body,
                Some(task),
            ),
            Phase::PendingApprove { task, body } | Phase::Accepted { task, body } => (
                LookupAction::Approve,
                &entry.binding.approve_id,
                body,
                Some(task),
            ),
        };
        peer.check()?;
        match self.backend.lookup(
            action,
            request,
            body,
            &entry.binding.scope,
            &entry.binding.epoch,
        ) {
            Ok(Some(v)) if valid_ack(&v, request, body, &entry.binding.scope, task) => {
                if matches!(action, LookupAction::Create) {
                    // Seeing a created record is not proof that this request
                    // ever issued an approval, even if another UI later did.
                    Ok(Reply::Created {
                        task: v.task,
                        task_state: v.state,
                    })
                } else if v.state != TaskState::AwaitingApproval {
                    Ok(Reply::Accepted {
                        task: v.task,
                        task_state: v.state,
                    })
                } else {
                    Ok(Reply::Unknown)
                }
            }
            _ => Ok(Reply::Unknown),
        }
    }
}
fn same_scope(a: &Scope, b: &Scope) -> bool {
    a.fingerprint == b.fingerprint
        && a.epoch == b.epoch
        && a.runtime_sha256 == b.runtime_sha256
        && a.alias == b.alias
}
fn valid_ack(
    v: &Acknowledgement,
    id: &str,
    body: &str,
    scope: &str,
    task: Option<&TaskBinding>,
) -> bool {
    v.request_id == id
        && v.body_sha256 == body
        && v.task.valid()
        && v.task.scope_sha256 == scope
        && task.is_none_or(|expected| expected == &v.task)
}
