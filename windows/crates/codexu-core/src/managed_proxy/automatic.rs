//! One native reservation spans graceful close, preparation, commit and rollback.
//! It cannot be serialized or reconstructed from an operation ID.
use super::*;

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(super) struct DurableReservation {
    pub(super) operation: String,
    source_profile: String,
    source_identity: String,
    source_generation: String,
    target_profile: String,
    target_identity: String,
}
impl DurableReservation {
    pub(super) fn valid(&self) -> bool {
        opaque_id(&self.operation)
            && opaque_id(&self.source_profile)
            && opaque_id(&self.source_generation)
            && opaque_id(&self.target_profile)
            && identity_hash(&self.source_identity)
            && identity_hash(&self.target_identity)
            && self.source_profile != self.target_profile
            && self.source_identity != self.target_identity
    }
}
#[derive(Clone, PartialEq, Eq)]
pub(super) struct Reservation {
    source: accounts::ActiveSystemScope,
    pub(super) target: String,
    target_identity: String,
}
struct LeaseInner {
    shared: Arc<Shared>,
    operation: String,
    reservation: Reservation,
    durable: DurableReservation,
}

#[derive(Clone)]
pub struct AutomaticMaintenanceLease(Arc<LeaseInner>);
fn unavailable() -> accounts::AccountError {
    accounts::AccountError {
        code: "occupancy_unknown",
    }
}
fn busy() -> accounts::AccountError {
    accounts::AccountError {
        code: "account_busy",
    }
}
fn idle_domain(s: &State) -> bool {
    !s.poisoned
        && s.activities.is_empty()
        && s.journal.active_run.is_none()
        && s.journal.desktop_writers.is_empty()
        && !s
            .journal
            .records
            .iter()
            .any(|r| matches!(r.phase, Phase::Pending | Phase::Reserved))
}
impl ManagedProxyGate {
    pub fn reserve_automatic_maintenance(
        &self,
        source: &accounts::ActiveSystemScope,
        target: &str,
    ) -> accounts::AccountResult<AutomaticMaintenanceLease> {
        self.shared.source.recheck_active_scope(source)?;
        if !opaque_id(target) || source.profile_id() == target {
            return Err(accounts::AccountError {
                code: "switch_target_invalid",
            });
        }
        let lease = {
            let mut s = self.lock().map_err(|_| unavailable())?;
            if !idle_domain(&s) || s.maintenance.is_some() || !s.credential_writers.is_empty() {
                return Err(busy());
            }
            let identity = self
                .shared
                .source
                .identity(target)
                .map_err(|_| unavailable())?
                .filter(|identity| identity_hash(identity))
                .ok_or_else(unavailable)?;
            if identity == source.identity_hash() {
                return Err(accounts::AccountError {
                    code: "same_account_identity",
                });
            }
            let operation = random_id().map_err(|_| unavailable())?;
            let reservation = Reservation {
                source: source.clone(),
                target: target.into(),
                target_identity: identity,
            };
            let durable = DurableReservation {
                operation: operation.clone(),
                source_profile: source.profile_id().into(),
                source_identity: source.identity_hash().into(),
                source_generation: source.credential_generation().into(),
                target_profile: target.into(),
                target_identity: reservation.target_identity.clone(),
            };
            // A crashed owner leaves an opaque hold. A new process may not
            // adopt or clear it merely by knowing its operation ID.
            s.journal.automatic_hold = Some(durable.clone());
            self.persist(&mut s).map_err(|_| unavailable())?;
            s.maintenance = Some(operation.clone());
            s.automatic_maintenance = Some(reservation.clone());
            AutomaticMaintenanceLease(Arc::new(LeaseInner {
                shared: self.shared.clone(),
                operation,
                reservation,
                durable,
            }))
        };
        // No manager/vault call is made while holding the registry mutex.
        self.shared.source.recheck_active_scope(source)?;
        lease.recheck()?;
        Ok(lease)
    }
    pub(super) fn adopt_automatic(
        &self,
        lease: &AutomaticMaintenanceLease,
        target: &str,
    ) -> accounts::AccountResult<Box<dyn accounts::SwitchMaintenanceLease>> {
        lease.validate_owner(self, target)?;
        lease.recheck_cached()?;
        Ok(Box::new(lease.clone()))
    }
    pub(super) fn automatic_credential_write(
        &self,
        lease: &AutomaticMaintenanceLease,
        target: &str,
    ) -> accounts::AccountResult<Box<dyn accounts::CredentialWriteLease>> {
        lease.validate_owner(self, target)?;
        let mut s = self.lock().map_err(|_| unavailable())?;
        lease.check_locked(&s)?;
        if !s.credential_writers.is_empty() {
            return Err(busy());
        }
        let id = random_id().map_err(|_| unavailable())?;
        s.credential_writers.insert(
            target.into(),
            CredentialWriter {
                id: id.clone(),
                purpose: accounts::CredentialWritePurpose::Managed,
                identity: Some(lease.0.reservation.target_identity.clone()),
                automatic_operation: Some(lease.0.operation.clone()),
            },
        );
        Ok(Box::new(CredentialWriteGuard {
            shared: self.shared.clone(),
            profile: target.into(),
            id,
        }))
    }
    /// Live source callback: memory only, with unknown preserved on contention.
    pub fn cached_dispatch_busy(&self) -> Option<bool> {
        let s = self.shared.state.try_lock().ok()?;
        if s.poisoned {
            return None;
        }
        Some(!idle_domain(&s) || s.maintenance.is_some() || !s.credential_writers.is_empty())
    }
}
impl AutomaticMaintenanceLease {
    pub fn operation_id(&self) -> &str {
        &self.0.operation
    }
    pub fn source_profile_id(&self) -> &str {
        self.0.reservation.source.profile_id()
    }
    pub fn source_identity_hash(&self) -> &str {
        self.0.reservation.source.identity_hash()
    }
    pub fn source_credential_generation(&self) -> &str {
        self.0.reservation.source.credential_generation()
    }
    pub fn target_profile_id(&self) -> &str {
        &self.0.reservation.target
    }
    pub(crate) fn target_identity_hash(&self) -> &str {
        &self.0.reservation.target_identity
    }
    pub(crate) fn source_scope(&self) -> &accounts::ActiveSystemScope {
        &self.0.reservation.source
    }
    fn validate_owner(&self, gate: &ManagedProxyGate, target: &str) -> accounts::AccountResult<()> {
        if !Arc::ptr_eq(&self.0.shared, &gate.shared) || target != self.target_profile_id() {
            return Err(unavailable());
        }
        Ok(())
    }
    fn check_locked(&self, s: &State) -> accounts::AccountResult<()> {
        if !idle_domain(s)
            || s.maintenance.as_deref() != Some(self.operation_id())
            || s.automatic_maintenance.as_ref() != Some(&self.0.reservation)
            || s.journal.automatic_hold.as_ref() != Some(&self.0.durable)
            || s.credential_writers.iter().any(|(profile, writer)| {
                profile != self.target_profile_id()
                    || writer.automatic_operation.as_deref() != Some(self.operation_id())
                    || writer.identity.as_deref()
                        != Some(self.0.reservation.target_identity.as_str())
            })
        {
            return Err(busy());
        }
        Ok(())
    }
    /// Safe inside AccountManager's commit guard; never accesses a file/vault.
    pub fn recheck_cached(&self) -> accounts::AccountResult<()> {
        let s = self.0.shared.state.try_lock().map_err(|_| unavailable())?;
        self.check_locked(&s)
    }
    /// Durable registry check, used outside the account transaction lock.
    pub fn recheck(&self) -> accounts::AccountResult<()> {
        let s = self.0.shared.state.try_lock().map_err(|_| unavailable())?;
        self.check_locked(&s)?;
        let bytes = read(&self.0.shared.path)
            .map_err(|_| unavailable())?
            .ok_or_else(unavailable)?;
        let disk: Journal = serde_json::from_slice(&bytes).map_err(|_| unavailable())?;
        disk.validate().map_err(|_| unavailable())?;
        if serde_json::to_vec(&disk).map_err(|_| unavailable())?
            != serde_json::to_vec(&s.journal).map_err(|_| unavailable())?
        {
            return Err(unavailable());
        }
        Ok(())
    }
}
impl accounts::SwitchMaintenanceLease for AutomaticMaintenanceLease {
    fn recheck(&self) -> accounts::AccountResult<()> {
        self.recheck_cached()
    }
}
impl Drop for LeaseInner {
    fn drop(&mut self) {
        if let Ok(mut s) = self.shared.state.lock() {
            if s.maintenance.as_deref() == Some(self.operation.as_str()) {
                s.journal.automatic_hold = None;
                let gate = ManagedProxyGate {
                    shared: self.shared.clone(),
                };
                if gate.persist(&mut s).is_ok() {
                    s.maintenance = None;
                    s.automatic_maintenance = None;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::accounts::AccountOccupancyGate;
    struct NoCredentials;
    impl CredentialSource for NoCredentials {
        fn managed_ids(&self) -> Result<Vec<String>, ProxyFailure> {
            Ok(vec![])
        }
        fn read(&self, _: &str, _: bool) -> Result<Credential, ProxyFailure> {
            Err(ProxyFailure::Identity)
        }
    }
    fn hold() -> DurableReservation {
        DurableReservation {
            operation: "operation-fixture".into(),
            source_profile: "source".into(),
            source_identity: "a".repeat(64),
            source_generation: "generation-fixture".into(),
            target_profile: "target".into(),
            target_identity: "b".repeat(64),
        }
    }
    #[test]
    fn crashed_reservation_blocks_new_owner_and_matching_text_cannot_adopt() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap().join("registry");
        std::fs::create_dir(&root).unwrap();
        let journal = Journal {
            automatic_hold: Some(hold()),
            ..Journal::default()
        };
        std::fs::write(
            root.join("dispatch-v1.json"),
            serde_json::to_vec(&journal).unwrap(),
        )
        .unwrap();
        let gate = ManagedProxyGate::with_source(root, Arc::new(NoCredentials)).unwrap();
        assert_eq!(gate.cached_dispatch_busy(), Some(true));
        assert!(gate
            .acquire_switch_maintenance("target", "operation-fixture")
            .is_err());
        assert!(gate
            .acquire_credential_write("target", accounts::CredentialWritePurpose::Managed)
            .is_err());
        assert!(gate.reserve_terminal(&"b".repeat(64)).is_err());
        assert!(gate
            .shared
            .state
            .lock()
            .unwrap()
            .automatic_maintenance
            .is_none());
    }
    #[test]
    fn durable_hold_rejects_conflicting_or_malformed_scope() {
        let mut journal = Journal {
            automatic_hold: Some(hold()),
            ..Journal::default()
        };
        assert!(journal.validate().is_ok());
        journal.active_run = Some("run".into());
        assert!(journal.validate().is_err());
        journal.active_run = None;
        journal.automatic_hold.as_mut().unwrap().target_identity = "a".repeat(64);
        assert!(journal.validate().is_err());
        journal.automatic_hold.as_mut().unwrap().target_identity = "b".repeat(64);
        journal.automatic_hold.as_mut().unwrap().operation = "invalid/path".into();
        assert!(journal.validate().is_err());
    }
    #[test]
    fn old_journal_does_not_invent_an_automatic_hold() {
        let journal: Journal = serde_json::from_value(serde_json::json!({
            "version":1,"active_run":null,"records":[],"desktop_writers":[]
        }))
        .unwrap();
        assert!(journal.automatic_hold.is_none());
        assert!(journal.validate().is_ok());
    }
}
