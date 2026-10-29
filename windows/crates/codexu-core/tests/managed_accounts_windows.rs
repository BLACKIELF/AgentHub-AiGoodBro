#![cfg(windows)]
//! Native crypto/ACL/lock fixtures only, never a real CLI/account/login.
use codexu_core::accounts::*;
#[path = "support/windows_creation.rs"]
mod windows_creation;
use std::{
    path::Path,
    sync::{atomic::AtomicBool, Arc},
};

struct NoAccountRuntime;
impl AccountRuntime for NoAccountRuntime {
    fn available(&self) -> bool {
        false
    }
    fn login(
        &self,
        _: &Path,
        _: &AtomicBool,
        _: &mut dyn FnMut(LoginAuthorization),
    ) -> AccountResult<VerifiedCredential> {
        Err(AccountError {
            code: "fixture_native_login_forbidden",
        })
    }
    fn verify(&self, _: &Path, _: &AccountIdentity) -> AccountResult<VerifiedCredential> {
        Err(AccountError {
            code: "fixture_native_verify_forbidden",
        })
    }
    fn require_system_idle(&self) -> AccountResult<()> {
        Err(AccountError {
            code: "occupancy_unknown",
        })
    }
    fn validate_target_configuration(&self, _: &Path) -> AccountResult<()> {
        Ok(())
    }
}

#[test]
fn native_dpapi_roundtrip_is_context_bound_and_not_plaintext() {
    let protector = DpapiProtector;
    let secret = b"synthetic-native-secret-no-real-account";
    let ciphertext = protector.seal("fixture-context-a", secret).unwrap();
    assert_ne!(ciphertext, secret);
    assert!(!ciphertext.windows(secret.len()).any(|w| w == secret));
    assert_eq!(
        protector.unseal("fixture-context-a", &ciphertext).unwrap(),
        secret
    );
    assert!(protector.unseal("fixture-context-b", &ciphertext).is_err());
    let mut corrupt = ciphertext;
    let last = corrupt.len() - 1;
    corrupt[last] ^= 1;
    assert!(protector.unseal("fixture-context-a", &corrupt).is_err());
}

#[test]
fn native_vault_acl_dpapi_and_exclusive_os_lock_work_on_synthetic_paths() {
    use std::os::windows::fs::OpenOptionsExt;
    let temp = tempfile::tempdir().unwrap();
    let root = windows_creation::fixture_root(temp.path());
    let system = root.join("synthetic-system");
    windows_creation::create_private_dir(&system).unwrap();
    let paths = AccountPaths::isolated(root.join("vault"), system).unwrap();
    let manager = AccountManager::with_components(
        paths.clone(),
        Arc::new(DpapiProtector),
        Arc::new(NoAccountRuntime),
        None,
    )
    .unwrap();
    manager
        .create_managed_account("Synthetic only".into(), "codex".into())
        .unwrap();
    manager
        .save_secret("proxy.client_key", Some("synthetic-native-key"))
        .unwrap();
    assert_eq!(
        manager.load_secret("proxy.client_key").unwrap().as_deref(),
        Some("synthetic-native-key")
    );
    let bytes = std::fs::read(paths.vault_root.join("accounts.dpapi")).unwrap();
    assert!(!String::from_utf8_lossy(&bytes).contains("synthetic-native-key"));
    let guard = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .share_mode(0)
        .open(paths.vault_root.join("accounts.lock"))
        .unwrap();
    assert_eq!(
        manager
            .create_managed_account("Blocked".into(), "codex".into())
            .unwrap_err()
            .code,
        "account_store_busy"
    );
    drop(guard);
    assert!(manager
        .create_managed_account("Allowed".into(), "codex".into())
        .is_ok());
}
