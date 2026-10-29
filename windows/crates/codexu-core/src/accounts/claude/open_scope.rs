//! Rust-only exact current-login evidence for the official CLI launcher.
use super::*;
#[derive(Clone, PartialEq, Eq)]
pub struct ClaudeOpenScope {
    home: PathBuf,
    id: String,
    identity: String,
    credential: String,
    target: Target,
}
impl ClaudeOpenScope {
    pub fn canonical_home(&self) -> &std::path::Path {
        &self.home
    }
    pub fn account_id(&self) -> &str {
        &self.id
    }
    pub fn identity_hash(&self) -> &str {
        &self.identity
    }
}
impl ClaudeSubscriptionManager {
    /// No request, refresh, process start or write. An unsaved or externally
    /// advanced system credential is explicitly unavailable.
    pub fn current_open_scope(&self, id: Option<&str>) -> AccountResult<ClaudeOpenScope> {
        let _operation = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.recovered()?;
        self.no_other_operation()?;
        self.runtime.validate_environment()?;
        let target = Target::read(&self.paths)?;
        target.validate()?;
        let store = self.store()?;
        let active = store
            .vault
            .active
            .as_ref()
            .ok_or_else(|| fail("account_identity_unverified"))?;
        let record = store.vault.record(id.unwrap_or(&active.id))?;
        let identity = identity::Identity::from_account(&target.account()?)?.fingerprint();
        let bytes = target
            .credential
            .as_ref()
            .ok_or_else(|| fail("account_identity_unverified"))?;
        identity::oauth(bytes, false)?;
        if active.identity != identity
            || record.credential.identity.fingerprint() != identity
            || active.credential_digest != identity::digest(bytes)
            || target
                .config()
                .is_none_or(|b| identity::digest(b) != active.config_digest)
            || target.legacy != active.legacy
            || store.vault.refresh.contains_key(&record.id)
        {
            return Err(fail("account_identity_unverified"));
        }
        let home = std::fs::canonicalize(&self.paths.live_directory)
            .map_err(|_| fail("target_home_unavailable"))?;
        if Target::read(&self.paths)? != target {
            return Err(fail("target_changed"));
        }
        self.accepting()?;
        Ok(ClaudeOpenScope {
            home,
            id: record.id.clone(),
            identity,
            credential: identity::digest(bytes),
            target,
        })
    }
    pub fn recheck_open_scope(&self, scope: &ClaudeOpenScope) -> AccountResult<()> {
        if self.current_open_scope(Some(&scope.id))? != *scope {
            return Err(fail("account_identity_unverified"));
        }
        Ok(())
    }
}
