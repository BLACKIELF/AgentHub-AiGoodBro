//! Native-only bridge to the existing Go Hub. Identity never enters a WebView
//! DTO. These values are written only to the owned private Hub input directory.
use super::AccountManager;
use crate::accounts::{
    fail,
    identity::{auth_digest, parse_auth},
    storage, AccountResult, VerifiedCredentialSnapshot,
};
use serde_json::{json, Value};
use std::{
    fs::File,
    path::{Path, PathBuf},
};

pub struct VerifiedHubAccount {
    pub identity_hash: String,
    pub home: PathBuf,
    profile: Value,
}
impl VerifiedHubAccount {
    pub fn manager_profile(
        &self,
        alias: &str,
        preference: &crate::workflow::WorkflowPreference,
    ) -> AccountResult<Value> {
        if alias.len() > 40
            || alias.is_empty()
            || !alias
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
        {
            return Err(fail("hub_invalid_account"));
        }
        let mut value = self.profile.clone();
        value["name"] = json!(alias);
        value["automaticSwitchParticipation"] = json!(preference.participating);
        value["dispatchParticipationWindow"] = serde_json::to_value(&preference.dispatch_window)
            .map_err(|_| fail("hub_invalid_preferences"))?;
        let model = preference
            .model
            .as_ref()
            .filter(|s| !s.is_empty())
            .ok_or_else(|| fail("hub_model_required"))?;
        let effort = preference
            .effort
            .as_ref()
            .filter(|s| !s.is_empty())
            .ok_or_else(|| fail("hub_model_required"))?;
        value["executionPreference"] = json!({"model":model,"reasoningEffort":effort,"serviceTier":"default","subagentMode":"standard"});
        // Backend-only input for the final Go spawn gate. This object is never
        // part of manager overview or a WebView DTO.
        value["windowsBinding"]["workflowRevision"] = json!(preference.revision);
        Ok(value)
    }
}
impl AccountManager {
    pub fn hub_account_snapshot(&self, id: &str) -> AccountResult<VerifiedHubAccount> {
        self.require_recovered()?;
        let home = self
            .managed_history_roots()?
            .into_iter()
            .find(|(key, _)| key == id)
            .map(|(_, p)| p)
            .ok_or_else(|| fail("hub_registration_required"))?;
        let store = self.store()?;
        let credential = store
            .vault
            .account(id)?
            .credential
            .as_ref()
            .ok_or_else(|| fail("login_required"))?;
        let verified = VerifiedCredentialSnapshot::from_stored(credential, 45)?;
        let auth = storage::read_optional(&home.join("auth.json"), 1024 * 1024)?
            .ok_or_else(|| fail("login_required"))?;
        let (identity, expiry) = parse_auth(&auth)?;
        if identity != credential.identity || expiry <= crate::accounts::now() + 30 {
            return Err(fail("identity_unverified"));
        }
        let quota = crate::readers::CodexAppServerQuotaSnapshot::from_rate_limit_response(
            &verified.official_quota,
        );
        if !quota.quota_read_succeeded {
            return Err(fail("evidence_stale"));
        }
        let window = |w: &Option<crate::models::RateWindow>| {
            w.as_ref().map(|w| json!({"usedPercent":w.used_percent,"resetsAt":w.resets_at.map(|t|t.timestamp_millis() as f64/1000.0-978307200.0),"windowDurationMins":w.window_duration_mins})).unwrap_or(json!({}))
        };
        let expires_ms = expiry
            .checked_mul(1000)
            .ok_or_else(|| fail("identity_unverified"))?;
        let observed_ms = verified
            .observed_at
            .checked_mul(1000)
            .ok_or_else(|| fail("evidence_stale"))?;
        // Pin the actual home bytes that were identity-checked above, not the
        // vault grant: official refresh can rotate the latter independently.
        // Keep the original observation time; collecting a bridge snapshot
        // must never renew stale quota evidence.
        let profile = json!({"codexHomePath":home,"isSystemProfile":false,"lastQuotaReadFailureAt":null,"windowsBinding":{"authSha256":auth_digest(&auth),"credentialExpiresAtMs":expires_ms,"quotaObservedAtMs":observed_ms,"identityHash":verified.identity_hash},"lastSnapshot":{"email":identity.email,"accountID":identity.account_id,"planType":verified.plan,"fetchedAt":verified.observed_at as f64-978307200.0,"quotaReadSucceeded":true,"fiveHour":window(&quota.five_hour_quota),"sevenDay":window(&quota.seven_day_quota)}});
        Ok(VerifiedHubAccount {
            identity_hash: verified.identity_hash,
            home,
            profile,
        })
    }
}

#[cfg(test)]
#[path = "hub_snapshot_tests.rs"]
mod snapshot_tests;

/// Fixed files only. This capability is backend-only, not an arbitrary-path IPC.
pub struct HubFiles {
    root: PathBuf,
    session: PathBuf,
    _owner: File,
}
impl HubFiles {
    pub fn open(app_data: &Path, workspace: &Path, managed_id: &str) -> AccountResult<Self> {
        use sha2::{Digest, Sha256};
        let namespace = format!(
            "{:x}",
            Sha256::digest(format!("{}\0{}", workspace.display(), managed_id).as_bytes())
        );
        let root = app_data.join("companion-hub").join(namespace);
        storage::secure_directory(&root)?;
        #[cfg(windows)]
        let owner = crate::accounts::native::private::open_lock(&root.join("native.owner"))?;
        #[cfg(not(windows))]
        let owner = File::open(&root).map_err(|_| fail("windows_required"))?;
        let session = root.join(format!("session-{}", crate::accounts::nonce()?));
        storage::create_private_directory(&session)?;
        storage::secure_directory(&root.join("data"))?;
        storage::secure_directory(&root.join("activity"))?;
        Ok(Self {
            root,
            session,
            _owner: owner,
        })
    }
    pub fn config(&self) -> PathBuf {
        self.session.join("config.json")
    }
    pub fn ready(&self) -> PathBuf {
        self.session.join("ready.json")
    }
    pub fn manager(&self) -> PathBuf {
        self.session.join("manager.json")
    }
    pub fn token_file(&self) -> PathBuf {
        self.session.join("token")
    }
    pub fn data(&self) -> PathBuf {
        self.root.join("data")
    }
    pub fn activity(&self) -> PathBuf {
        self.root.join("activity")
    }
    pub fn write_inputs(&self, config: &Value, manager: &Value, token: &str) -> AccountResult<()> {
        if token.len() != 64 || !token.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(fail("hub_invalid_token"));
        }
        storage::atomic_write(
            &self.config(),
            &serde_json::to_vec(config).map_err(|_| fail("hub_invalid_config"))?,
        )?;
        self.write_manager(manager)?;
        storage::atomic_write(&self.token_file(), token.as_bytes())
    }
    pub fn write_manager(&self, value: &Value) -> AccountResult<()> {
        storage::atomic_write(
            &self.manager(),
            &serde_json::to_vec(value).map_err(|_| fail("hub_invalid_snapshot"))?,
        )
    }
    pub fn read_ready(&self) -> AccountResult<Option<Value>> {
        let Some(bytes) = storage::read_optional(&self.ready(), 4096)? else {
            return Ok(None);
        };
        match serde_json::from_slice(&bytes) {
            Ok(value) => Ok(Some(value)),
            // The owned helper creates this private file before writing it.
            // An unfinished JSON record is still pending within the caller's
            // existing process-alive and five-second readiness deadline.
            Err(error) if error.is_eof() => Ok(None),
            Err(_) => Err(fail("hub_invalid_ready")),
        }
    }
}

/// Hash the exact locked file handle that will be retained across spawn.
pub fn verify_helper(file: &mut File, expected: Option<&str>) -> AccountResult<()> {
    use sha2::{Digest, Sha256};
    use std::io::{Read, Seek, SeekFrom};
    let expected = expected
        .filter(|s| {
            s.len() == 64
                && s.bytes()
                    .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        })
        .ok_or_else(|| fail("hub_helper_unbound"))?;
    let size = file
        .metadata()
        .map_err(|_| fail("hub_helper_unavailable"))?
        .len();
    if size == 0 || size > 128 * 1024 * 1024 {
        return Err(fail("hub_helper_invalid"));
    }
    file.seek(SeekFrom::Start(0))
        .map_err(|_| fail("hub_helper_unavailable"))?;
    let mut h = Sha256::new();
    let mut buffer = [0u8; 65536];
    let mut count = 0u64;
    loop {
        let n = file
            .read(&mut buffer)
            .map_err(|_| fail("hub_helper_unavailable"))?;
        if n == 0 {
            break;
        }
        count += n as u64;
        if count > 128 * 1024 * 1024 {
            return Err(fail("hub_helper_invalid"));
        }
        h.update(&buffer[..n]);
    }
    if count != size || format!("{:x}", h.finalize()) != expected {
        return Err(fail("hub_helper_mismatch"));
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ready_reader_waits_only_for_incomplete_json() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap();
        let files = HubFiles::open(&root.join("app-data"), &root, "fixture").unwrap();
        assert!(files.read_ready().unwrap().is_none());
        for bytes in [b"".as_slice(), br#"{"schemaVersion":1,"pid":"#] {
            storage::atomic_write(&files.ready(), bytes).unwrap();
            assert!(files.read_ready().unwrap().is_none());
        }
        storage::atomic_write(
            &files.ready(),
            br#"{"schemaVersion":1,"pid":7,"listen":"127.0.0.1:1234"}"#,
        )
        .unwrap();
        assert_eq!(files.read_ready().unwrap().unwrap()["pid"], 7);
        storage::atomic_write(&files.ready(), b"{invalid}").unwrap();
        assert_eq!(files.read_ready().unwrap_err().code, "hub_invalid_ready");
        storage::atomic_write(&files.ready(), &vec![b' '; 4097]).unwrap();
        assert!(files.read_ready().is_err());
        drop(files);
        temporary.close().unwrap();
    }
    #[test]
    fn locked_helper_requires_binding_and_detects_changes() {
        use sha2::{Digest, Sha256};
        use std::io::Write;
        let mut file = tempfile::tempfile().unwrap();
        file.write_all(b"synthetic fixture binary").unwrap();
        let hash = format!("{:x}", Sha256::digest(b"synthetic fixture binary"));
        assert!(verify_helper(&mut file, None).is_err());
        assert!(verify_helper(&mut file, Some(&"0".repeat(64))).is_err());
        verify_helper(&mut file, Some(&hash)).unwrap();
        file.write_all(b"modified").unwrap();
        assert!(verify_helper(&mut file, Some(&hash)).is_err());
    }
    #[test]
    fn policy_projection_requires_explicit_model_and_preserves_schedule() {
        let account = VerifiedHubAccount {
            identity_hash: "a".repeat(64),
            home: PathBuf::from("synthetic"),
            profile: json!({"lastSnapshot":{"email":"fixture@example.invalid"}}),
        };
        assert!(account
            .manager_profile("account-1", &Default::default())
            .is_err());
        let preference = crate::workflow::WorkflowPreference {
            participating: false,
            model: Some("gpt-6-sol".into()),
            effort: Some("high".into()),
            dispatch_window: Some(Default::default()),
            ..Default::default()
        };
        let value = account.manager_profile("account-1", &preference).unwrap();
        assert_eq!(value["automaticSwitchParticipation"], false);
        assert_eq!(value["executionPreference"]["serviceTier"], "default");
        assert_eq!(
            value["dispatchParticipationWindow"]["timeZoneIdentifier"],
            "UTC"
        );
        assert!(account.manager_profile("../account", &preference).is_err());
    }
}
