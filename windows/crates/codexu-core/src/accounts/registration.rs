//! First-login registration uses the existing private managed Desktop home.
//! The callback persists metadata only; it never receives credential bytes.
use super::*;
use std::path::Path;

/// Native-only durable ownership of a planned catalog entry. No credential or
/// untrusted home crosses this interface. The caller holds the manager mutation
/// fence, while each progress write takes only the existing vault transaction.
pub struct RegistrationProgress<'a> {
    manager: &'a AccountManager,
    account_id: &'a str,
    identity: &'a str,
}
impl RegistrationProgress<'_> {
    pub fn planned_profile_id(&self) -> AccountResult<Option<u64>> {
        let store = self.manager.store()?;
        let intent = store
            .vault
            .pending_registrations
            .get(self.account_id)
            .ok_or_else(|| fail("account_changed"))?;
        if intent.identity_hash != self.identity {
            return Err(fail("identity_mismatch"));
        }
        Ok(intent.planned_profile_id)
    }
    pub fn plan_profile(&self, profile_id: u64) -> AccountResult<()> {
        if profile_id == 0 {
            return Err(fail("registration_catalog_changed"));
        }
        let mut store = self.manager.store()?;
        let intent = store
            .vault
            .pending_registrations
            .get_mut(self.account_id)
            .ok_or_else(|| fail("account_changed"))?;
        if intent.identity_hash != self.identity {
            return Err(fail("identity_mismatch"));
        }
        match intent.planned_profile_id {
            Some(id) if id == profile_id => return Ok(()),
            Some(_) => return Err(fail("registration_catalog_changed")),
            None => intent.planned_profile_id = Some(profile_id),
        }
        self.manager.require_accepting()?;
        store.save()
    }
}

impl AccountManager {
    /// Explicit repair may refresh stale official evidence using the existing
    /// isolated verifier and writer fence. Background retries never call this.
    pub fn refresh_registration_evidence(&self, id: &str) -> AccountResult<()> {
        if self.verified_credential_snapshot(id, 45).is_err() {
            self.refresh_managed_credential(id)?;
        }
        Ok(())
    }
    /// Explicit user retry may adopt a legacy verified slot. Background retries
    /// never call this method and never manufacture intent for old accounts.
    pub fn request_account_registration(&self, id: &str) -> AccountResult<()> {
        let _operation = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.catalog_ready()?;
        let mut store = self.store()?;
        let credential = store
            .vault
            .account(id)?
            .credential
            .as_ref()
            .ok_or_else(|| fail("login_required"))?;
        // Intent alone grants no credential or scheduling authority. Fresh official
        // evidence is still mandatory before any home/catalog write.
        let identity = credential.identity.identity_hash();
        if let Some(intent) = store.vault.pending_registrations.get(id) {
            return if intent.identity_hash == identity {
                Ok(())
            } else {
                Err(fail("identity_mismatch"))
            };
        }
        store.vault.pending_registrations.insert(
            id.into(),
            storage::RegistrationIntent {
                identity_hash: identity,
                planned_profile_id: None,
            },
        );
        store.save()
    }

    pub fn pending_registration_ids(&self) -> AccountResult<Vec<String>> {
        self.require_accepting()?;
        Ok(self
            .store()?
            .vault
            .pending_registrations
            .keys()
            .cloned()
            .collect())
    }

    /// Native composition only. Keep the ordinary managed writer fence until
    /// the metadata callback and the identity-bound completion commit finish.
    /// Returning false means no pending intent; it never adopts a legacy slot.
    pub fn register_pending_account(
        &self,
        id: &str,
        persist_catalog: impl FnOnce(&Path, &str, &RegistrationProgress<'_>) -> AccountResult<()>,
    ) -> AccountResult<bool> {
        let _operation = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.catalog_ready()?;
        let (expected, credential, label) = {
            let store = self.store()?;
            let Some(expected) = store.vault.pending_registrations.get(id) else {
                return Ok(false);
            };
            let record = store.vault.account(id)?;
            (
                expected.identity_hash.clone(),
                record
                    .credential
                    .clone()
                    .ok_or_else(|| fail("login_required"))?,
                record.label.clone(),
            )
        };
        let evidence = VerifiedCredentialSnapshot::from_stored(&credential, 45)?;
        if evidence.identity_hash != expected {
            return Err(fail("identity_mismatch"));
        }
        let writer = self.credential_write(id, CredentialWritePurpose::Managed)?;
        let home = self.paths.desktop(id)?;
        storage::secure_directory(home.parent().ok_or_else(|| fail("account_paths_invalid"))?)?;
        storage::secure_directory(&home)?;
        if storage::read_optional(&home.join("writer-claim.dpapi"), 65536)?.is_some() {
            return Err(fail("desktop_writer_recovery_required"));
        }
        // Reuse only the exact grant, including after a partial registration.
        // A rotated/uncertain Desktop grant must go through its existing import
        // recovery, never be overwritten from the older vault snapshot.
        let auth_path = home.join("auth.json");
        let existing = storage::read_optional(&auth_path, super::super::identity::MAX_AUTH_BYTES)?;
        if existing
            .as_ref()
            .is_some_and(|auth| auth != &credential.auth)
        {
            return Err(fail("desktop_auth_changed"));
        }
        if home.join("config.toml").exists() {
            self.runtime.validate_target_configuration(&home)?;
        }
        writer.recheck()?;
        self.require_accepting()?;
        if existing.is_none() {
            storage::atomic_write(&auth_path, &credential.auth)?;
        }
        if !home.join("config.toml").exists() {
            storage::atomic_write(
                &home.join("config.toml"),
                b"cli_auth_credentials_store = 'file'\nmodel_provider = 'openai'\n",
            )?;
        }
        let canonical = home
            .canonicalize()
            .map_err(|_| fail("account_paths_invalid"))?;
        writer.recheck()?;
        persist_catalog(
            &canonical,
            &label,
            &RegistrationProgress {
                manager: self,
                account_id: id,
                identity: &expected,
            },
        )?;
        writer.recheck()?;
        if storage::read_optional(&auth_path, super::super::identity::MAX_AUTH_BYTES)?.as_ref()
            != Some(&credential.auth)
        {
            return Err(fail("desktop_auth_changed"));
        }
        let mut store = self.store()?;
        let current = store
            .vault
            .account(id)?
            .credential
            .as_ref()
            .ok_or_else(|| fail("login_required"))?;
        if current.identity != credential.identity
            || current.generation != credential.generation
            || current.auth != credential.auth
            || store
                .vault
                .pending_registrations
                .get(id)
                .map(|intent| &intent.identity_hash)
                != Some(&expected)
        {
            return Err(fail("account_changed"));
        }
        self.require_accepting()?;
        store.vault.pending_registrations.remove(id);
        store.save()?;
        Ok(true)
    }
}

#[cfg(test)]
#[path = "registration_tests.rs"]
mod tests;
