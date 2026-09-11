//! Read-only discovery of local Codex accounts.
//!
//! The reader is the privacy boundary: it opens `auth.json` only to derive a
//! *reduced* identity, and it never returns tokens, raw email, the raw account
//! id, or any absolute local path.
//!
//! Identity verification mirrors `CodexOfficialProfileReader.credentialIdentity`
//! in the macOS source: the stored account id, the id-token claim and the
//! access-token claim must all agree, and a conflicting access-token email
//! invalidates the identity instead of being averaged away.

use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::models::account::{mask_email, AccountIdentity, AccountRecord, ExecutionPreference};

/// Managed profile directory, relative to the user home directory.
///
/// This is the Next namespace: it must not reuse the legacy macOS
/// `.codex-account-manager-next` path or any `codexu` directory.
pub const MANAGED_PROFILES_RELATIVE_PATH: &str = ".aigoodbro-agenthub/profiles";

/// Account id reserved for the non-isolated system login.
///
/// A managed profile directory with this exact name is skipped by
/// [`CodexAccountReader::read_managed_accounts`]. Without that guard it would
/// share a key with the system login and the workbench would attribute the
/// system login's quota to an unrelated profile.
pub const SYSTEM_ACCOUNT_ID: &str = "system";

/// Reduced identity extracted from `auth.json`.
///
/// `account_id` is kept internal for cross-checking only and is never promoted
/// into [`AccountIdentity`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthIdentity {
    pub account_id: String,
    pub masked_email: String,
    pub plan_label: Option<String>,
}

/// Reads accounts from a Codex home directory and a managed profiles root.
#[derive(Debug, Clone)]
pub struct CodexAccountReader {
    codex_root: PathBuf,
    profiles_root: PathBuf,
}

impl CodexAccountReader {
    pub fn new(codex_root: impl Into<PathBuf>, profiles_root: impl Into<PathBuf>) -> Self {
        Self {
            codex_root: codex_root.into(),
            profiles_root: profiles_root.into(),
        }
    }

    /// Default layout for a user home directory.
    pub fn for_home(home: impl AsRef<Path>) -> Self {
        let home = home.as_ref();
        Self::new(
            home.join(".codex"),
            home.join(MANAGED_PROFILES_RELATIVE_PATH),
        )
    }

    pub fn codex_root(&self) -> &Path {
        &self.codex_root
    }

    pub fn profiles_root(&self) -> &Path {
        &self.profiles_root
    }

    /// The system (non-isolated) login. Always reported, even when signed out,
    /// so the workbench can show an explicit "not signed in" state.
    pub fn read_system_account(&self) -> AccountRecord {
        let identity = identity_from_auth_file(&self.codex_root.join("auth.json"));
        build_record(
            SYSTEM_ACCOUNT_ID.to_string(),
            &self.codex_root,
            identity,
            true,
            0,
        )
    }

    /// Managed profiles, sorted by directory name for a stable display order.
    ///
    /// A directory named exactly [`SYSTEM_ACCOUNT_ID`] is skipped so it cannot
    /// collide with the system login's key.
    pub fn read_managed_accounts(&self) -> Vec<AccountRecord> {
        let Ok(entries) = std::fs::read_dir(&self.profiles_root) else {
            return Vec::new();
        };

        let mut directories: Vec<PathBuf> = entries
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.path())
            .filter(|path| path.is_dir())
            .filter(|path| {
                path.file_name()
                    .map(|name| name.to_string_lossy() != SYSTEM_ACCOUNT_ID)
                    .unwrap_or(false)
            })
            .collect();
        directories.sort();

        directories
            .into_iter()
            .enumerate()
            .map(|(index, directory)| {
                let id = directory
                    .file_name()
                    .map(|name| name.to_string_lossy().to_string())
                    .unwrap_or_default();
                let identity = identity_from_auth_file(&directory.join("auth.json"));
                build_record(id, &directory, identity, false, (index as i64) + 1)
            })
            .collect()
    }

    /// System account first, then managed profiles.
    pub fn read_all(&self) -> Vec<AccountRecord> {
        let mut accounts = vec![self.read_system_account()];
        accounts.extend(self.read_managed_accounts());
        accounts
    }
}

fn build_record(
    id: String,
    home: &Path,
    identity: Option<AuthIdentity>,
    is_system_profile: bool,
    order: i64,
) -> AccountRecord {
    let home_dir_label = home
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_else(|| id.clone());

    let (masked_email, plan_label, is_signed_in, label) = match identity {
        Some(identity) => {
            let label = identity.masked_email.clone();
            (
                Some(identity.masked_email),
                identity.plan_label,
                true,
                label,
            )
        }
        None => (None, None, false, id.clone()),
    };

    AccountRecord {
        identity: AccountIdentity {
            id,
            label,
            masked_email,
            plan_label,
            is_signed_in,
        },
        home_dir_label,
        preference: ExecutionPreference::default(),
        // New accounts participate in dispatch by default; an existing user
        // choice is preserved by the store, not by this reader.
        participates_in_dispatch: true,
        order,
        pinned_first: false,
        is_system_profile,
    }
}

fn identity_from_auth_file(path: &Path) -> Option<AuthIdentity> {
    let data = std::fs::read_to_string(path).ok()?;
    let auth: Value = serde_json::from_str(&data).ok()?;
    identity_from_auth_json(&auth)
}

/// Reduce an `auth.json` document to a verified identity.
///
/// Returns `None` whenever the credential cannot be verified, so callers show
/// "not signed in" instead of a partially trusted identity.
pub fn identity_from_auth_json(auth: &Value) -> Option<AuthIdentity> {
    let tokens = auth.get("tokens")?;
    let access_token = non_empty(tokens.get("access_token")?.as_str())?;
    let id_token = non_empty(tokens.get("id_token")?.as_str())?;

    let id_claims = token_claims(id_token)?;
    let email = normalized_email(id_claims.get("email").and_then(Value::as_str))?;

    let access_claims = token_claims(access_token);
    let stored_account_id = non_empty(tokens.get("account_id").and_then(Value::as_str));
    let id_token_account_id = account_id_in(&id_claims);
    let access_token_account_id = access_claims.as_ref().and_then(account_id_in);

    let account_id = stored_account_id
        .or(id_token_account_id)
        .or(access_token_account_id)?
        .to_string();

    // Every present source must agree; a single mismatch invalidates the
    // credential rather than picking a winner.
    for candidate in [
        stored_account_id,
        id_token_account_id,
        access_token_account_id,
    ]
    .into_iter()
    .flatten()
    {
        if candidate != account_id.as_str() {
            return None;
        }
    }

    let access_email = normalized_email(
        access_claims
            .as_ref()
            .and_then(|claims| claims.get("email"))
            .and_then(Value::as_str),
    );
    if let Some(access_email) = access_email {
        if access_email != email {
            return None;
        }
    }

    Some(AuthIdentity {
        account_id,
        masked_email: mask_email(&email)?,
        plan_label: plan_label(&id_claims),
    })
}

fn plan_label(claims: &Value) -> Option<String> {
    let auth = claims.get("https://api.openai.com/auth")?;
    non_empty(auth.get("chatgpt_plan_type").and_then(Value::as_str)).map(str::to_string)
}

fn account_id_in(claims: &Value) -> Option<&str> {
    let namespaced = claims.get("https://api.openai.com/auth");
    namespaced
        .and_then(|auth| non_empty(auth.get("chatgpt_account_id").and_then(Value::as_str)))
        .or_else(|| {
            namespaced.and_then(|auth| non_empty(auth.get("account_id").and_then(Value::as_str)))
        })
        .or_else(|| non_empty(claims.get("chatgpt_account_id").and_then(Value::as_str)))
        .or_else(|| non_empty(claims.get("account_id").and_then(Value::as_str)))
}

/// Normalise an email for comparison.
///
/// Lower-cased, matching `CodexOfficialProfileReader.normalizedEmail`. Without
/// this a login whose id-token and access-token claims differ only in case would
/// be rejected as a mismatched credential and shown as signed out.
fn normalized_email(value: Option<&str>) -> Option<String> {
    non_empty(value).map(str::to_lowercase)
}

fn non_empty(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|value| !value.is_empty())
}

/// Decode the JWT payload. A malformed token yields `None` rather than a guess.
fn token_claims(token: &str) -> Option<Value> {
    let payload = token.split('.').nth(1)?;
    if payload.is_empty() {
        return None;
    }
    let normalized = payload.replace('-', "+").replace('_', "/");
    let bytes = decode_base64(&normalized)?;
    serde_json::from_slice(&bytes).ok()
}

/// Minimal standard-alphabet base64 decoder.
///
/// Implemented locally to avoid adding a dependency for one call site.
fn decode_base64(input: &str) -> Option<Vec<u8>> {
    fn sextet(byte: u8) -> Option<u32> {
        match byte {
            b'A'..=b'Z' => Some(u32::from(byte - b'A')),
            b'a'..=b'z' => Some(u32::from(byte - b'a') + 26),
            b'0'..=b'9' => Some(u32::from(byte - b'0') + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }

    let mut output = Vec::with_capacity(input.len() / 4 * 3);
    let mut buffer: u32 = 0;
    let mut bits: u32 = 0;

    for byte in input.bytes() {
        if byte == b'=' {
            break;
        }
        let value = sextet(byte)?;
        buffer = (buffer << 6) | value;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            output.push(((buffer >> bits) & 0xFF) as u8);
        }
    }

    Some(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const NAMESPACE: &str = "https://api.openai.com/auth";

    /// Minimal base64url encoder used only to build fixtures.
    fn encode_base64url(input: &[u8]) -> String {
        const ALPHABET: &[u8; 64] =
            b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        let mut output = String::new();
        for chunk in input.chunks(3) {
            let b0 = u32::from(chunk[0]);
            let b1 = chunk.get(1).copied().map(u32::from);
            let b2 = chunk.get(2).copied().map(u32::from);

            output.push(ALPHABET[(b0 >> 2) as usize] as char);
            let second = ((b0 & 0b11) << 4) | (b1.unwrap_or(0) >> 4);
            output.push(ALPHABET[second as usize] as char);
            if let Some(b1) = b1 {
                let third = ((b1 & 0b1111) << 2) | (b2.unwrap_or(0) >> 6);
                output.push(ALPHABET[third as usize] as char);
            }
            if let Some(b2) = b2 {
                output.push(ALPHABET[(b2 & 0b11_1111) as usize] as char);
            }
        }
        output
    }

    fn token(claims: &Value) -> String {
        let header = encode_base64url(br#"{"alg":"none","typ":"JWT"}"#);
        let payload = encode_base64url(claims.to_string().as_bytes());
        format!("{}.{}.signature", header, payload)
    }

    fn auth_json(id_claims: &Value, access_claims: &Value, stored_account_id: Option<&str>) -> Value {
        let mut tokens = json!({
            "access_token": token(access_claims),
            "id_token": token(id_claims),
        });
        if let Some(account_id) = stored_account_id {
            tokens["account_id"] = json!(account_id);
        }
        json!({ "tokens": tokens })
    }

    fn id_claims(email: &str, account_id: &str, plan: Option<&str>) -> Value {
        let mut auth = json!({ "chatgpt_account_id": account_id });
        if let Some(plan) = plan {
            auth["chatgpt_plan_type"] = json!(plan);
        }
        json!({ "email": email, NAMESPACE: auth })
    }

    #[test]
    fn base64url_round_trips_through_the_local_decoder() {
        for sample in [
            &b"{}"[..],
            &b"{\"a\":1}"[..],
            &b"hello world"[..],
            &b"{\"email\":\"alice@example.com\"}"[..],
        ] {
            let encoded = encode_base64url(sample);
            assert_eq!(decode_base64(&encoded).as_deref(), Some(sample));
        }
    }

    #[test]
    fn reads_a_verified_identity_and_masks_the_email() {
        let auth = auth_json(
            &id_claims("alice@example.com", "acc-123", Some("plus")),
            &id_claims("alice@example.com", "acc-123", Some("plus")),
            Some("acc-123"),
        );

        let identity = identity_from_auth_json(&auth).expect("verified identity");
        assert_eq!(identity.account_id, "acc-123");
        assert_eq!(identity.masked_email, "a***@example.com");
        assert_eq!(identity.plan_label.as_deref(), Some("plus"));
        assert!(!identity.masked_email.contains("lice"));
    }

    #[test]
    fn a_mismatched_account_id_invalidates_the_credential() {
        let auth = auth_json(
            &id_claims("alice@example.com", "acc-123", None),
            &id_claims("alice@example.com", "acc-123", None),
            Some("acc-999"),
        );
        assert_eq!(identity_from_auth_json(&auth), None);

        let auth = auth_json(
            &id_claims("alice@example.com", "acc-123", None),
            &id_claims("alice@example.com", "acc-456", None),
            None,
        );
        assert_eq!(identity_from_auth_json(&auth), None);
    }

    #[test]
    fn a_mismatched_access_token_email_invalidates_the_credential() {
        let auth = auth_json(
            &id_claims("alice@example.com", "acc-123", None),
            &id_claims("bob@example.com", "acc-123", None),
            None,
        );
        assert_eq!(identity_from_auth_json(&auth), None);
    }

    #[test]
    fn a_case_only_email_difference_is_not_a_mismatch() {
        // The source compares emails case-insensitively; rejecting this would
        // show a correctly signed-in account as signed out.
        let auth = auth_json(
            &id_claims("Alice@Example.COM", "acc-123", Some("plus")),
            &id_claims("alice@example.com", "acc-123", Some("plus")),
            Some("acc-123"),
        );

        let identity = identity_from_auth_json(&auth).expect("verified identity");
        assert_eq!(identity.masked_email, "a***@example.com");
        assert_eq!(identity.plan_label.as_deref(), Some("plus"));
    }

    #[test]
    fn a_managed_directory_named_like_the_system_login_is_skipped() {
        let temp = tempfile::tempdir().expect("temp dir");
        let reader = CodexAccountReader::for_home(temp.path());

        for name in ["system", "profile-a"] {
            let directory = reader.profiles_root().join(name);
            std::fs::create_dir_all(&directory).expect("create profile dir");
            let auth = auth_json(
                &id_claims("alice@example.com", "acc-1", None),
                &id_claims("alice@example.com", "acc-1", None),
                Some("acc-1"),
            );
            std::fs::write(
                directory.join("auth.json"),
                serde_json::to_string(&auth).expect("serialise auth"),
            )
            .expect("write auth.json");
        }

        let accounts = reader.read_managed_accounts();
        assert_eq!(accounts.len(), 1);
        assert_eq!(accounts[0].identity.id, "profile-a");

        // The system login still owns the reserved id, so the ids cannot collide.
        let all = reader.read_all();
        let ids: Vec<&str> = all.iter().map(|account| account.identity.id.as_str()).collect();
        assert_eq!(ids, vec!["system", "profile-a"]);
        assert!(all[0].is_system_profile);
    }

    #[test]
    fn a_credential_without_tokens_is_not_an_identity() {
        assert_eq!(identity_from_auth_json(&json!({})), None);
        assert_eq!(identity_from_auth_json(&json!({ "tokens": {} })), None);
        assert_eq!(
            identity_from_auth_json(&json!({ "tokens": { "access_token": "  ", "id_token": "a.b.c" } })),
            None
        );
    }

    #[test]
    fn a_malformed_token_is_rejected_rather_than_guessed() {
        let auth = json!({
            "tokens": {
                "access_token": "not-a-jwt",
                "id_token": "also-not-a-jwt",
            }
        });
        assert_eq!(identity_from_auth_json(&auth), None);
    }

    #[test]
    fn plan_label_is_optional() {
        let auth = auth_json(
            &id_claims("alice@example.com", "acc-123", None),
            &id_claims("alice@example.com", "acc-123", None),
            None,
        );
        let identity = identity_from_auth_json(&auth).expect("verified identity");
        assert_eq!(identity.plan_label, None);
    }

    #[test]
    fn missing_auth_file_reports_a_signed_out_system_account() {
        let temp = tempfile::tempdir().expect("temp dir");
        let reader = CodexAccountReader::for_home(temp.path());

        let system = reader.read_system_account();
        assert!(!system.identity.is_signed_in);
        assert_eq!(system.identity.id, "system");
        assert!(system.is_system_profile);
        assert!(system.identity.masked_email.is_none());
        assert!(!system.can_store_preference());
        // A signed-out account is never dispatch eligible.
        assert!(!system.is_dispatch_eligible());
    }

    #[test]
    fn managed_profiles_are_discovered_in_a_stable_order() {
        let temp = tempfile::tempdir().expect("temp dir");
        let reader = CodexAccountReader::for_home(temp.path());
        let profiles_root = reader.profiles_root().to_path_buf();

        for name in ["profile-b", "profile-a"] {
            let directory = profiles_root.join(name);
            std::fs::create_dir_all(&directory).expect("create profile dir");
            let auth = auth_json(
                &id_claims("alice@example.com", "acc-1", Some("plus")),
                &id_claims("alice@example.com", "acc-1", Some("plus")),
                Some("acc-1"),
            );
            std::fs::write(
                directory.join("auth.json"),
                serde_json::to_string(&auth).expect("serialise auth"),
            )
            .expect("write auth.json");
        }

        let accounts = reader.read_managed_accounts();
        assert_eq!(accounts.len(), 2);
        assert_eq!(accounts[0].identity.id, "profile-a");
        assert_eq!(accounts[1].identity.id, "profile-b");
        assert!(accounts.iter().all(|account| account.identity.is_signed_in));
        assert!(accounts.iter().all(|account| !account.is_system_profile));
        assert!(accounts.iter().all(|account| account.can_store_preference()));

        let all = reader.read_all();
        assert_eq!(all.len(), 3);
        assert!(all[0].is_system_profile);
    }

    #[test]
    fn a_profile_without_a_valid_credential_is_reported_as_signed_out() {
        let temp = tempfile::tempdir().expect("temp dir");
        let reader = CodexAccountReader::for_home(temp.path());
        let directory = reader.profiles_root().join("profile-empty");
        std::fs::create_dir_all(&directory).expect("create profile dir");

        let accounts = reader.read_managed_accounts();
        assert_eq!(accounts.len(), 1);
        assert!(!accounts[0].identity.is_signed_in);
        assert_eq!(accounts[0].identity.label, "profile-empty");
    }

    #[test]
    fn a_missing_profiles_root_yields_no_managed_accounts() {
        let temp = tempfile::tempdir().expect("temp dir");
        let reader = CodexAccountReader::for_home(temp.path());
        assert!(reader.read_managed_accounts().is_empty());
    }

    #[test]
    fn the_managed_root_does_not_reuse_a_legacy_namespace() {
        let home = Path::new("/home/tester");
        let reader = CodexAccountReader::for_home(home);
        let profiles = reader.profiles_root().to_string_lossy().to_string();
        assert!(profiles.contains(".aigoodbro-agenthub"));
        assert!(!profiles.contains("codex-account-manager-next"));
        assert!(!profiles.contains("codexu"));
    }
}
