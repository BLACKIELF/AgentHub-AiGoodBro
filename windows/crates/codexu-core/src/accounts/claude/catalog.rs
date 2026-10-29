//! Metadata-only saved-subscription actions. Removing a saved slot preserves
//! the official current credentials, configuration and history.
use super::*;

impl ClaudeSubscriptionManager {
    pub fn rename_claude_subscription(
        &self,
        account_id: &str,
        label: String,
    ) -> AccountResult<AccountOperationDto> {
        let _operation = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.recovered()?;
        self.no_other_operation()?;
        crate::profiles::validate_label(&label).map_err(|_| fail("invalid_label"))?;
        let mut store = self.store()?;
        if store
            .vault
            .records
            .iter()
            .any(|record| record.id != account_id && record.label.eq_ignore_ascii_case(&label))
        {
            return Err(fail("duplicate_label"));
        }
        let record = store.vault.record_mut(account_id)?;
        if record.label != label {
            record.revision = record
                .revision
                .checked_add(1)
                .ok_or_else(|| fail("claude_vault_invalid"))?;
            record.label = label;
            self.accepting()?;
            self.quota_cache.invalidate(account_id);
            store.save()?;
        }
        Ok(AccountOperationDto {
            account_id: account_id.into(),
            phase: "renamed",
            error_code: None,
        })
    }

    pub fn remove_claude_subscription(
        &self,
        account_id: &str,
    ) -> AccountResult<AccountOperationDto> {
        let _operation = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.recovered()?;
        self.no_other_operation()?;
        self.runtime.validate_environment()?;
        // This is the same global maintenance fence used by capture/switch;
        // an unknown or occupied native process cannot authorize slot removal.
        let lease = self.maintenance(account_id)?;
        let before = Target::read(&self.paths)?;
        before.validate()?;
        let locks = MutationLocks::acquire(&self.paths, &before)?;
        let mut store = self.store()?;
        let current = store
            .vault
            .active
            .as_ref()
            .ok_or_else(|| fail("account_identity_unverified"))?;
        let current_identity = before
            .account()
            .and_then(|account| identity::Identity::from_account(&account))
            .map_err(|_| fail("account_identity_unverified"))?
            .fingerprint();
        if current.identity != current_identity
            || current.legacy != before.legacy
            || before
                .credential
                .as_ref()
                .is_none_or(|value| identity::digest(value) != current.credential_digest)
            || before
                .config()
                .is_none_or(|value| identity::digest(value) != current.config_digest)
            || store
                .vault
                .record(&current.id)
                .map(|record| record.credential.identity.fingerprint())
                .ok()
                .as_deref()
                != Some(current_identity.as_str())
        {
            return Err(fail("account_identity_unverified"));
        }
        identity::oauth(before.credential.as_ref().unwrap(), false)
            .map_err(|_| fail("account_identity_unverified"))?;
        let record = store.vault.record(account_id)?;
        if current.id == account_id || record.credential.identity.fingerprint() == current_identity
        {
            return Err(fail("account_is_current"));
        }
        locks.verify()?;
        lease.recheck()?;
        self.runtime.require_system_idle()?;
        self.accepting()?;
        if Target::read(&self.paths)? != before {
            return Err(fail("target_changed"));
        }
        store.vault.records.retain(|record| record.id != account_id);
        store.vault.refresh.remove(account_id);
        store.vault.quota_retry.remove(account_id);
        self.quota_cache.invalidate(account_id);
        store.save()?;
        Ok(AccountOperationDto {
            account_id: account_id.into(),
            phase: "removed",
            error_code: None,
        })
    }
}
