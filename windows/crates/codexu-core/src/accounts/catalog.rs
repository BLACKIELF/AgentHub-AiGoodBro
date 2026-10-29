//! Saved-slot metadata actions. System login files and persistent Desktop homes
//! are never deleted by removing a slot.
use super::*;

impl AccountManager {
    fn catalog_ready(&self) -> AccountResult<()> {
        self.require_recovered()?;
        self.require_no_login()?;
        self.expire_tickets()?;
        if !self
            .tickets
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?
            .is_empty()
        {
            return Err(fail("switch_in_progress"));
        }
        if self
            .attempts
            .lock()
            .map_err(|_| fail("account_state_unavailable"))?
            .values()
            .any(|attempt| attempt.dto.error_code == Some("cleanup_unconfirmed"))
        {
            return Err(fail("cleanup_unconfirmed"));
        }
        Ok(())
    }

    pub fn rename_managed_account(
        &self,
        account_id: &str,
        label: String,
    ) -> AccountResult<AccountOperationDto> {
        let _operation = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.catalog_ready()?;
        crate::profiles::validate_label(&label).map_err(|_| fail("invalid_label"))?;
        let mut store = self.store()?;
        if store
            .vault
            .accounts
            .iter()
            .any(|record| record.id != account_id && record.label.eq_ignore_ascii_case(&label))
        {
            return Err(fail("duplicate_label"));
        }
        let record = store.vault.account_mut(account_id)?;
        if record.label != label {
            record.revision = record
                .revision
                .checked_add(1)
                .ok_or_else(|| fail("vault_invalid"))?;
            record.label = label;
            self.require_accepting()?;
            store.save()?;
        }
        Ok(AccountOperationDto {
            account_id: account_id.into(),
            phase: "renamed",
            error_code: None,
        })
    }

    pub fn remove_managed_account(&self, account_id: &str) -> AccountResult<AccountOperationDto> {
        let _operation = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.catalog_ready()?;
        // Freeze the real shared reservation before the vault commit lock.
        // Its writer lease also rejects same-identity Desktop aliases.
        let lease = self.acquire_maintenance(account_id, &super::super::nonce()?)?;
        let writer = self.credential_write(account_id, CredentialWritePurpose::Managed)?;
        let before = TargetSnapshot::read(&self.paths.system_home)?;
        let scope = self.active_system_scope_locked().map_err(|error| {
            if matches!(
                error.code,
                "active_scope_unverified" | "active_scope_changed"
            ) {
                fail("account_identity_unverified")
            } else {
                error
            }
        })?;
        if TargetSnapshot::read(&self.paths.system_home)? != before {
            return Err(fail("target_changed"));
        }
        let home = self.paths.desktop(account_id)?;
        if storage::read_optional(&home.join("writer-claim.dpapi"), 65536)?.is_some() {
            return Err(fail("desktop_writer_recovery_required"));
        }
        let mut store = self.store()?;
        let record = store.vault.account(account_id)?;
        if scope.profile_id() == account_id
            || record.credential.as_ref().is_some_and(|credential| {
                credential.identity.identity_hash() == scope.identity_hash()
            })
        {
            return Err(fail("account_is_current"));
        }
        lease.recheck()?;
        writer.recheck()?;
        self.runtime.require_system_idle()?;
        self.require_accepting()?;
        if TargetSnapshot::read(&self.paths.system_home)? != before {
            return Err(fail("target_changed"));
        }
        store
            .vault
            .accounts
            .retain(|record| record.id != account_id);
        store.save()?;
        drop(store);
        if let Ok(mut attempts) = self.attempts.lock() {
            attempts.retain(|_, attempt| attempt.dto.account_id != account_id);
        }
        Ok(AccountOperationDto {
            account_id: account_id.into(),
            phase: "removed",
            error_code: None,
        })
    }
}
