//! Verified launcher for Google's separately installed Antigravity CLI.
//! The Desktop GUI is a different product and is never used as a fallback.
use super::*;
use crate::{
    local_cli::{LocalCliKind, PlatformDirectories},
    provider_pool::{NativeConnection, Provider},
};
use sha2::{Digest, Sha512};
use std::{fs::File, io::Read};

const MAX_AGY_IMAGE: u64 = 128 * 1024 * 1024;
// Official Windows amd64 manifest observed for agy 1.4.12. Extend this
// allowlist only from a separately verified official manifest.
const VERIFIED_RELEASES: &[(&str, &str)] = &[(
    "1.4.12",
    "6f44299b3b2f8ddb349f1e21bf07962c602a117adb62d7e81a4b041ede2067ec77ed26059f8636cb94295bfc9dd9f8ca9bf9ca4f4b4159ee6171a17a082c4082",
)];

/// Read-shared executable handle kept through the complete owned process Job.
pub struct VerifiedAgyExecutable {
    path: PathBuf,
    guard: File,
}
impl VerifiedAgyExecutable {
    pub fn path(&self) -> &Path {
        &self.path
    }
    pub fn into_parts(self) -> (PathBuf, File) {
        (self.path, self.guard)
    }
}

fn amd64_pe(bytes: &[u8]) -> bool {
    if bytes.len() < 64 || &bytes[..2] != b"MZ" {
        return false;
    }
    let at = u32::from_le_bytes(bytes[60..64].try_into().unwrap()) as usize;
    at.checked_add(26).is_some_and(|end| {
        end <= bytes.len()
            && &bytes[at..at + 4] == b"PE\0\0"
            && bytes[at + 4..at + 6] == [0x64, 0x86]
            && bytes[at + 24..at + 26] == [0x0b, 0x02]
    })
}

fn verified_candidate(candidate: &Path) -> Result<VerifiedAgyExecutable> {
    verify_candidate_with(candidate, |_path, bytes| {
        #[cfg(windows)]
        let publisher = crate::readers::local_cli_quota::antigravity::publisher_of(_path);
        #[cfg(not(windows))]
        let publisher: Option<String> = None;
        trusted_release(bytes, publisher.as_deref())
    })
}

fn verify_candidate_with(
    candidate: &Path,
    trusted: impl FnOnce(&Path, &[u8]) -> bool,
) -> Result<VerifiedAgyExecutable> {
    let resolved = candidate
        .canonicalize()
        .map_err(|_| fail("cli_unavailable"))?;
    check_path(&resolved).map_err(|_| fail("executable_unverified"))?;
    if resolved.file_name().and_then(|s| s.to_str()) != Some("agy.exe") {
        return Err(fail("executable_unverified"));
    }
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        // The same held file is hashed and later passed to the owned launcher;
        // deny write/delete sharing so self-update cannot replace it mid-run.
        options.share_mode(1).custom_flags(0x0020_0000);
    }
    let mut guard = options
        .open(&resolved)
        .map_err(|_| fail("executable_unverified"))?;
    let metadata = guard
        .metadata()
        .map_err(|_| fail("executable_unverified"))?;
    if !metadata.is_file() || metadata.len() < 90 || metadata.len() > MAX_AGY_IMAGE {
        return Err(fail("executable_unverified"));
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    guard
        .by_ref()
        .take(MAX_AGY_IMAGE + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| fail("executable_unverified"))?;
    if bytes.len() as u64 != metadata.len() || !amd64_pe(&bytes) {
        return Err(fail("executable_unverified"));
    }
    if !trusted(&resolved, &bytes) {
        return Err(fail("executable_unverified"));
    }
    crate::accounts::storage::ensure_no_links(&resolved)
        .map_err(|_| fail("executable_unverified"))?;
    Ok(VerifiedAgyExecutable {
        path: resolved,
        guard,
    })
}

fn trusted_release(bytes: &[u8], publisher: Option<&str>) -> bool {
    let hash = format!("{:x}", Sha512::digest(bytes));
    VERIFIED_RELEASES
        .iter()
        .any(|(_, expected)| *expected == hash)
        || publisher.is_some_and(official_publisher)
}

fn official_publisher(value: &str) -> bool {
    let normalized: String = value
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .flat_map(char::to_lowercase)
        .collect();
    matches!(normalized.as_str(), "googlellc" | "googleinc")
}

/// The official installer places its native CLI at
/// `%LOCALAPPDATA%\\agy\\bin\\agy.exe`. A final-file symlink is accepted
/// only after resolving and verifying the target bytes; wrappers and Desktop
/// executables are never searched or launched.
pub fn discover_agy(dirs: &PlatformDirectories) -> Result<VerifiedAgyExecutable> {
    if !cfg!(windows) {
        return Err(fail("windows_required"));
    }
    let parent = dirs.local_app_data.join("agy").join("bin");
    check_path(&parent).map_err(|_| fail("cli_unavailable"))?;
    verified_candidate(&parent.join("agy.exe"))
}

impl Environment {
    /// Clean, private Agy profile plus the fixed local Antigravity gateway.
    pub fn agy_provider_pool(
        home: &Path,
        connection: &NativeConnection<'_>,
        provider: Provider,
    ) -> Result<Self> {
        check_path(home)?;
        if provider != Provider::Antigravity
            || connection.endpoint != "http://127.0.0.1:18081/providers/antigravity"
            || !(32..=256).contains(&connection.client_key.len())
            || !connection
                .client_key
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
        {
            return Err(fail("environment_invalid"));
        }
        let mut out = Self::dependency_probe(home)?;
        if let Ok(path) = std::env::var("PATH") {
            if path.len() > 32767 || path.contains('\0') {
                return Err(fail("environment_invalid"));
            }
            if let Some((_, value)) = out.bindings.iter_mut().find(|(key, _)| key == "PATH") {
                *value = path;
            }
        }
        let term = std::env::var("TERM").unwrap_or_else(|_| "xterm-256color".into());
        if term.len() > 256 || term.chars().any(char::is_control) {
            return Err(fail("environment_invalid"));
        }
        out.kind = LocalCliKind::Antigravity;
        out.bindings.push(("LANG".into(), "en_US.UTF-8".into()));
        out.bindings.push(("TERM".into(), term));
        out.bindings
            .push(("GEMINI_API_KEY".into(), connection.client_key.into()));
        out.bindings
            .push(("GOOGLE_GEMINI_BASE_URL".into(), connection.endpoint.clone()));
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn synthetic_pe() -> Vec<u8> {
        let mut bytes = vec![0; 90];
        bytes[..2].copy_from_slice(b"MZ");
        bytes[60..64].copy_from_slice(&64u32.to_le_bytes());
        bytes[64..68].copy_from_slice(b"PE\0\0");
        bytes[68..70].copy_from_slice(&[0x64, 0x86]);
        bytes[88..90].copy_from_slice(&[0x0b, 0x02]);
        bytes
    }

    #[test]
    fn pinned_agy_candidate_checks_amd64_pe_hash_and_final_symlink_target() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let bundle = root.join("bundle");
        let install = root.join("agy/bin");
        std::fs::create_dir_all(&bundle).unwrap();
        std::fs::create_dir_all(&install).unwrap();
        let bytes = synthetic_pe();
        let target = bundle.join("agy.exe");
        std::fs::File::create(&target)
            .unwrap()
            .write_all(&bytes)
            .unwrap();
        let link = install.join("agy.exe");
        #[cfg(unix)]
        std::os::unix::fs::symlink(&target, &link).unwrap();
        #[cfg(windows)]
        std::os::windows::fs::symlink_file(&target, &link).unwrap();

        let hash = format!("{:x}", Sha512::digest(&bytes));
        let verified = verify_candidate_with(&link, |_, data| {
            amd64_pe(data) && format!("{:x}", Sha512::digest(data)) == hash
        })
        .unwrap();
        assert_eq!(verified.path(), target);
        drop(verified);

        let altered = root.join("altered.exe");
        let mut x86 = synthetic_pe();
        x86[68..70].copy_from_slice(&[0x4c, 0x01]);
        std::fs::write(&altered, &x86).unwrap();
        assert!(verify_candidate_with(&altered, |_, bytes| amd64_pe(bytes)).is_err());

        let malformed = root.join("malformed.exe");
        std::fs::write(&malformed, b"MZ but not an executable").unwrap();
        assert!(verify_candidate_with(&malformed, |_, bytes| amd64_pe(bytes)).is_err());
    }

    #[test]
    fn pinned_release_and_google_authenticode_signer_are_accepted() {
        assert_eq!(VERIFIED_RELEASES.len(), 1);
        assert_eq!(VERIFIED_RELEASES[0].0, "1.4.12");
        assert!(VERIFIED_RELEASES[0].1.len() == 128);
        assert!(official_publisher("Google LLC"));
        assert!(official_publisher("Google Inc."));
        assert!(!official_publisher("Not Google LLC"));
        assert!(trusted_release(&synthetic_pe(), Some("Google LLC")));
        assert!(!trusted_release(
            &synthetic_pe(),
            Some("Untrusted Publisher")
        ));
    }

    #[test]
    fn gateway_environment_uses_private_home_and_scrubs_ambient_provider_secrets() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().canonicalize().unwrap().join("private Agy home");
        std::fs::create_dir_all(&home).unwrap();
        let connection = NativeConnection {
            endpoint: "http://127.0.0.1:18081/providers/antigravity".into(),
            client_key: "synthetic_gateway_key_abcdefghijklmnopqrstuvwxyz",
            run_id: "synthetic-run",
        };
        let environment =
            Environment::agy_provider_pool(&home, &connection, Provider::Antigravity).unwrap();
        let applied = environment
            .apply([
                ("USERPROFILE".into(), "wrong-home".into()),
                ("GEMINI_API_KEY".into(), "stale-key".into()),
                (
                    "GOOGLE_GEMINI_BASE_URL".into(),
                    "https://wrong.invalid".into(),
                ),
                ("GOOGLE_API_KEY".into(), "ambient-key".into()),
                ("HTTP_PROXY".into(), "ambient-proxy".into()),
                ("NODE_OPTIONS".into(), "injected".into()),
            ])
            .unwrap();
        let values: std::collections::BTreeMap<_, _> = applied
            .into_iter()
            .map(|(k, v)| {
                (
                    k.to_string_lossy().into_owned(),
                    v.to_string_lossy().into_owned(),
                )
            })
            .collect();
        assert_eq!(values["HOME"], home.to_string_lossy());
        assert_eq!(values["USERPROFILE"], home.to_string_lossy());
        assert_eq!(
            values["GEMINI_API_KEY"],
            "synthetic_gateway_key_abcdefghijklmnopqrstuvwxyz"
        );
        assert_eq!(
            values["GOOGLE_GEMINI_BASE_URL"],
            "http://127.0.0.1:18081/providers/antigravity"
        );
        assert!(!values.values().any(|value| {
            [
                "wrong-home",
                "stale-key",
                "ambient-key",
                "ambient-proxy",
                "injected",
            ]
            .iter()
            .any(|secret| value == secret)
        }));
    }
}
