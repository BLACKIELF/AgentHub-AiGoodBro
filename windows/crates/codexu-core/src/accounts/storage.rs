use super::{fail, identity::StoredCredential, AccountResult};
use serde::{Deserialize, Serialize};
use std::{
    fs::{File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
};

const MAX_VAULT: usize = 16 * 1024 * 1024;
pub(crate) const VAULT_CONTEXT: &str = "AiGoodBro.Next.Windows.accounts.v1";
pub(crate) const JOURNAL_CONTEXT: &str = "AiGoodBro.Next.Windows.account-switch.v1";

pub trait SecretProtector: Send + Sync {
    fn seal(&self, context: &str, plaintext: &[u8]) -> AccountResult<Vec<u8>>;
    fn unseal(&self, context: &str, ciphertext: &[u8]) -> AccountResult<Vec<u8>>;
}

#[derive(Clone)]
pub struct AccountPaths {
    pub vault_root: PathBuf,
    pub system_home: PathBuf,
}
impl AccountPaths {
    pub fn isolated(vault_root: PathBuf, system_home: PathBuf) -> AccountResult<Self> {
        if !vault_root.is_absolute()
            || !system_home.is_absolute()
            || vault_root == system_home
            || vault_root.starts_with(&system_home)
            || system_home.starts_with(&vault_root)
        {
            return Err(fail("account_paths_invalid"));
        }
        ensure_no_links(&vault_root)?;
        ensure_no_links(&system_home)?;
        Ok(Self {
            vault_root,
            system_home,
        })
    }
    pub(crate) fn journal(&self) -> PathBuf {
        self.vault_root.join("switch-journal.dpapi")
    }
    pub(crate) fn staging(&self) -> PathBuf {
        self.vault_root.join("staging")
    }
    pub(crate) fn desktop(&self, profile_id: &str) -> AccountResult<PathBuf> {
        if !valid_id(profile_id) {
            return Err(fail("account_not_found"));
        }
        let path = self.vault_root.join("desktop").join(profile_id);
        ensure_no_links(&path)?;
        Ok(path)
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct AccountRecord {
    pub id: String,
    pub label: String,
    pub platform: String,
    pub revision: u64,
    pub credential: Option<StoredCredential>,
}
#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct ActiveProof {
    pub account_id: String,
    pub generation: String,
    pub target_digest: String,
}
#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct Vault {
    pub schema_version: u32,
    pub revision: u64,
    pub accounts: Vec<AccountRecord>,
    pub active: Option<ActiveProof>,
    #[serde(default)]
    pub secrets: std::collections::BTreeMap<String, String>,
}
impl Default for Vault {
    fn default() -> Self {
        Self {
            schema_version: 1,
            revision: 0,
            accounts: Vec::new(),
            active: None,
            secrets: Default::default(),
        }
    }
}
impl Vault {
    pub(crate) fn validate(&self) -> AccountResult<()> {
        if self.schema_version != 1 || self.accounts.len() > 64 {
            return Err(fail("vault_invalid"));
        }
        let mut ids = std::collections::HashSet::new();
        for record in &self.accounts {
            if !valid_id(&record.id)
                || !ids.insert(&record.id)
                || record.platform != "codex"
                || crate::profiles::validate_label(&record.label).is_err()
            {
                return Err(fail("vault_invalid"));
            }
            if let Some(credential) = &record.credential {
                if !valid_id(&credential.generation)
                    || super::AccountIdentity::from_auth(&credential.auth)? != credential.identity
                {
                    return Err(fail("vault_invalid"));
                }
            }
        }
        if self.secrets.len() > 2
            || self.secrets.iter().any(|(name, value)| {
                !matches!(name.as_str(), "proxy.client_key" | "proxy.mihomo_secret")
                    || value.is_empty()
                    || value.len() > 4096
                    || value.chars().any(char::is_control)
            })
        {
            return Err(fail("vault_invalid"));
        }
        Ok(())
    }
    pub(crate) fn account(&self, id: &str) -> AccountResult<&AccountRecord> {
        self.accounts
            .iter()
            .find(|a| a.id == id)
            .ok_or_else(|| fail("account_not_found"))
    }
    pub(crate) fn account_mut(&mut self, id: &str) -> AccountResult<&mut AccountRecord> {
        self.accounts
            .iter_mut()
            .find(|a| a.id == id)
            .ok_or_else(|| fail("account_not_found"))
    }
}
pub(crate) fn valid_id(id: &str) -> bool {
    id.len() == 32
        && id
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}

/// Real cross-process exclusion. The file may remain after a crash; its OS lock
/// cannot. Never infer ownership from an old PID or unlink another process lock.
pub(crate) struct StoreLock {
    _file: File,
}
impl StoreLock {
    pub(crate) fn acquire(root: &Path) -> AccountResult<Self> {
        secure_directory(root)?;
        let path = root.join("accounts.lock");
        ensure_no_links(&path)?;
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true);
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            options.share_mode(0);
        }
        let file = options
            .open(&path)
            .map_err(|_| fail("account_store_busy"))?;
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            unsafe extern "C" {
                fn flock(fd: i32, operation: i32) -> i32;
            }
            if unsafe { flock(file.as_raw_fd(), 2 | 4) } != 0 {
                return Err(fail("account_store_busy"));
            }
        }
        #[cfg(not(any(unix, windows)))]
        return Err(fail("platform_unsupported"));
        Ok(Self { _file: file })
    }
}

pub(crate) struct StoreGuard<'a> {
    pub vault: Vault,
    path: PathBuf,
    prior: Option<Vec<u8>>,
    protector: &'a dyn SecretProtector,
    _lock: StoreLock,
}
impl<'a> StoreGuard<'a> {
    pub(crate) fn load(
        paths: &AccountPaths,
        protector: &'a dyn SecretProtector,
    ) -> AccountResult<Self> {
        let lock = StoreLock::acquire(&paths.vault_root)?;
        let path = paths.vault_root.join("accounts.dpapi");
        let prior = read_optional(&path, MAX_VAULT)?;
        let vault = if let Some(bytes) = &prior {
            let data = protector.unseal(VAULT_CONTEXT, bytes)?;
            if data.len() > MAX_VAULT {
                return Err(fail("vault_invalid"));
            }
            serde_json::from_slice::<Vault>(&data).map_err(|_| fail("vault_invalid"))?
        } else {
            Vault::default()
        };
        vault.validate()?;
        Ok(Self {
            vault,
            path,
            prior,
            protector,
            _lock: lock,
        })
    }
    pub(crate) fn save(&mut self) -> AccountResult<()> {
        self.vault.validate()?;
        if read_optional(&self.path, MAX_VAULT)? != self.prior {
            return Err(fail("vault_changed"));
        }
        self.vault.revision = self
            .vault
            .revision
            .checked_add(1)
            .ok_or_else(|| fail("vault_invalid"))?;
        let data = serde_json::to_vec(&self.vault).map_err(|_| fail("vault_invalid"))?;
        if data.len() > MAX_VAULT {
            return Err(fail("vault_full"));
        }
        let ciphertext = self.protector.seal(VAULT_CONTEXT, &data)?;
        if ciphertext.len() > MAX_VAULT {
            return Err(fail("vault_full"));
        }
        if read_optional(&self.path, MAX_VAULT)? != self.prior {
            return Err(fail("vault_changed"));
        }
        atomic_write(&self.path, &ciphertext)?;
        self.prior = Some(ciphertext);
        Ok(())
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct TargetSnapshot {
    pub auth: Option<Vec<u8>>,
    pub config: Option<Vec<u8>>,
}
impl TargetSnapshot {
    pub(crate) fn read(home: &Path) -> AccountResult<Self> {
        ensure_no_links(home)?;
        if !home.is_dir() {
            return Err(fail("target_home_unavailable"));
        }
        Ok(Self {
            auth: read_optional(&home.join("auth.json"), super::identity::MAX_AUTH_BYTES)?,
            config: read_optional(&home.join("config.toml"), super::identity::MAX_AUTH_BYTES)?,
        })
    }
}

#[derive(Serialize, Deserialize)]
pub(crate) struct SwitchJournal {
    pub schema_version: u32,
    pub account_id: String,
    pub generation: String,
    pub before: TargetSnapshot,
    pub written_auth: Vec<u8>,
    #[serde(default)]
    pub verified_rotation: Option<VerifiedSwitchRotation>,
    #[serde(default)]
    pub verification_started: bool,
    #[serde(default)]
    pub expected_revision: Option<u64>,
}
#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct VerifiedSwitchRotation {
    pub revision: u64,
    pub previous_auth_digest: String,
    pub credential: StoredCredential,
}
pub(crate) fn save_journal(
    paths: &AccountPaths,
    protector: &dyn SecretProtector,
    value: &SwitchJournal,
) -> AccountResult<()> {
    let data = serde_json::to_vec(value).map_err(|_| fail("journal_invalid"))?;
    let encrypted = protector.seal(JOURNAL_CONTEXT, &data)?;
    atomic_write(&paths.journal(), &encrypted)
}
pub(crate) fn load_journal(
    paths: &AccountPaths,
    protector: &dyn SecretProtector,
) -> AccountResult<Option<SwitchJournal>> {
    let Some(data) = read_optional(&paths.journal(), MAX_VAULT)? else {
        return Ok(None);
    };
    let data = protector.unseal(JOURNAL_CONTEXT, &data)?;
    let value: SwitchJournal =
        serde_json::from_slice(&data).map_err(|_| fail("journal_invalid"))?;
    if value.schema_version != 1
        || !valid_id(&value.account_id)
        || !valid_id(&value.generation)
        || value.written_auth.len() > super::identity::MAX_AUTH_BYTES
    {
        return Err(fail("journal_invalid"));
    }
    if let Some(rotation) = &value.verified_rotation {
        if !valid_id(&rotation.credential.generation)
            || rotation.credential.generation == value.generation
            || rotation.credential.auth != value.written_auth
            || rotation.previous_auth_digest.len() != 64
            || super::AccountIdentity::from_auth(&rotation.credential.auth)?
                != rotation.credential.identity
            || !crate::readers::CodexAppServerQuotaSnapshot::from_rate_limit_response(
                &rotation.credential.quota,
            )
            .quota_read_succeeded
        {
            return Err(fail("journal_invalid"));
        }
    }
    Ok(Some(value))
}
pub(crate) fn clear_journal(paths: &AccountPaths) -> AccountResult<()> {
    ensure_no_links(&paths.journal())?;
    match std::fs::remove_file(paths.journal()) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(_) => Err(fail("recovery_required")),
    }
}
pub(crate) fn read_optional(path: &Path, maximum: usize) -> AccountResult<Option<Vec<u8>>> {
    ensure_no_links(path)?;
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(value) => value,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(fail("account_storage_unavailable")),
    };
    if !metadata.is_file() || metadata.len() > maximum as u64 {
        return Err(fail("account_storage_invalid"));
    }
    let mut data = Vec::new();
    File::open(path)
        .map_err(|_| fail("account_storage_unavailable"))?
        .take(maximum as u64 + 1)
        .read_to_end(&mut data)
        .map_err(|_| fail("account_storage_unavailable"))?;
    if data.len() > maximum {
        return Err(fail("account_storage_invalid"));
    }
    Ok(Some(data))
}
pub(crate) fn atomic_write(path: &Path, bytes: &[u8]) -> AccountResult<()> {
    ensure_no_links(path)?;
    let parent = path.parent().ok_or_else(|| fail("account_paths_invalid"))?;
    if !parent.is_dir() {
        return Err(fail("account_storage_unavailable"));
    }
    let mut temp =
        tempfile::NamedTempFile::new_in(parent).map_err(|_| fail("account_storage_unavailable"))?;
    secure_file(temp.path())?;
    temp.write_all(bytes)
        .and_then(|_| temp.as_file().sync_all())
        .map_err(|_| fail("account_save_failed"))?;
    temp.persist(path)
        .map_err(|_| fail("account_save_failed"))?;
    Ok(())
}
pub(crate) fn restore_owned(
    home: &Path,
    written: &[u8],
    before: &TargetSnapshot,
) -> AccountResult<()> {
    let current = TargetSnapshot::read(home)?;
    if current.auth.as_deref() != Some(written) || current.config != before.config {
        return Err(fail("external_change_preserved"));
    }
    let path = home.join("auth.json");
    match &before.auth {
        Some(bytes) => atomic_write(&path, bytes)?,
        None => std::fs::remove_file(&path).map_err(|_| fail("rollback_failed"))?,
    }
    if TargetSnapshot::read(home)? != *before {
        return Err(fail("rollback_failed"));
    }
    Ok(())
}
pub(crate) fn ensure_no_links(path: &Path) -> AccountResult<()> {
    if !path.is_absolute()
        || path
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return Err(fail("account_paths_invalid"));
    }
    for ancestor in path.ancestors() {
        match std::fs::symlink_metadata(ancestor) {
            Ok(metadata) => {
                if metadata.file_type().is_symlink() {
                    return Err(fail("account_path_linked"));
                }
                #[cfg(windows)]
                {
                    use std::os::windows::fs::MetadataExt;
                    if metadata.file_attributes() & 0x400 != 0 {
                        return Err(fail("account_path_linked"));
                    }
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err(fail("account_storage_unavailable")),
        }
    }
    Ok(())
}
pub(crate) fn secure_directory(path: &Path) -> AccountResult<()> {
    ensure_no_links(path)?;
    std::fs::create_dir_all(path).map_err(|_| fail("account_storage_unavailable"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))
            .map_err(|_| fail("account_storage_unavailable"))?;
    }
    #[cfg(windows)]
    super::native::restrict_access(path)?;
    Ok(())
}
fn secure_file(path: &Path) -> AccountResult<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
            .map_err(|_| fail("account_storage_unavailable"))?;
    }
    #[cfg(windows)]
    super::native::restrict_access(path)?;
    Ok(())
}
