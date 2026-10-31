//! claude-swap v0.27.1 Windows file references. No credential crosses IPC and
//! no second durable runnable grant is created by importing a slot.
use super::*;
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    fs::{File, OpenOptions},
    io::Read,
    path::Path,
};

#[derive(Clone, Serialize, Deserialize)]
pub(in super::super) struct Reference {
    pub slot: String,
    pub identity_fingerprint: String,
}
impl Reference {
    pub fn validate(&self, identity: &identity::Identity) -> AccountResult<()> {
        if !valid_slot(&self.slot) || self.identity_fingerprint != identity.fingerprint() {
            return Err(fail("claude_swap_identity_changed"));
        }
        Ok(())
    }
}
#[derive(Clone, PartialEq, Eq)]
pub(in super::super) struct Snapshot {
    slot: String,
    identity: String,
    sequence: String,
    config: String,
    encoded: String,
    path: PathBuf,
}
#[derive(Clone, Serialize)]
pub struct ClaudeSwapCandidate {
    pub candidate_id: String,
    pub label: String,
    pub masked_identity: Option<String>,
    pub already_imported: bool,
}
struct Slot {
    reference: Reference,
    identity: identity::Identity,
    snapshot: Snapshot,
    bytes: Vec<u8>,
}
fn root(paths: &ClaudeAccountPaths) -> AccountResult<PathBuf> {
    Ok(paths
        .global_config
        .parent()
        .ok_or_else(|| fail("account_paths_invalid"))?
        .join(".claude-swap-backup"))
}
fn valid_slot(slot: &str) -> bool {
    slot.parse::<u32>()
        .ok()
        .is_some_and(|n| (1..=10000).contains(&n) && n.to_string() == slot)
}
fn slot_identity(slot: &str, record: &Value) -> AccountResult<identity::Identity> {
    if !valid_slot(slot) {
        return Err(fail("claude_swap_invalid"));
    }
    let email = record["email"]
        .as_str()
        .and_then(crate::local_cli::valid_identity)
        .filter(|email| {
            email.len() <= 254
                && !email.contains("..")
                && !email.chars().any(|c| "/\\:<>\"|?*".contains(c))
        })
        .ok_or_else(|| fail("claude_swap_invalid"))?;
    let uuid = identity::text(&record["uuid"], 128).ok_or_else(|| fail("claude_swap_invalid"))?;
    let organization = match record.get("organizationUuid") {
        None => "",
        Some(Value::String(s)) if s.is_empty() => "",
        Some(value) => identity::text(value, 128).ok_or_else(|| fail("claude_swap_invalid"))?,
    };
    Ok(identity::Identity {
        uuid: uuid.into(),
        organization: organization.into(),
        email: Some(email),
    })
}
fn candidate_id(slot: &str, identity: &identity::Identity) -> String {
    identity::digest(
        format!(
            "cswap-v1\0{slot}\0{}\0{}",
            identity.fingerprint(),
            identity.email.as_deref().unwrap_or("")
        )
        .as_bytes(),
    )
}
fn sequence(
    paths: &ClaudeAccountPaths,
) -> AccountResult<Option<(Vec<u8>, serde_json::Map<String, Value>)>> {
    let Some(bytes) = read(&root(paths)?.join("sequence.json"))? else {
        return Ok(None);
    };
    let value = identity::object(&bytes).map_err(|_| fail("claude_swap_invalid"))?;
    let accounts = value["accounts"]
        .as_object()
        .filter(|v| v.len() <= 64)
        .ok_or_else(|| fail("claude_swap_invalid"))?
        .clone();
    Ok(Some((bytes, accounts)))
}
fn unresolved(root: &Path, slot: &str) -> AccountResult<()> {
    // A session for this numeric slot may own its newest grant. Check the slot
    // prefix (including an old alias) rather than reimplement Python's Unicode
    // normalization of the email slug. Never recurse into session contents.
    let sessions = root.join("sessions");
    super::super::super::storage::ensure_no_links(&sessions)?;
    match std::fs::read_dir(&sessions) {
        Ok(entries) => {
            for (index, entry) in entries.enumerate() {
                if index >= 4096 {
                    return Err(fail("claude_swap_busy"));
                }
                let entry = entry.map_err(|_| fail("claude_swap_unavailable"))?;
                if entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(&format!("{slot}-"))
                {
                    return Err(fail("claude_swap_busy"));
                }
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
        Err(_) => return Err(fail("claude_swap_unavailable")),
    }
    for name in [
        "credentials/.unclaimed-manifest.json",
        ".unclaimed-manifest.json",
    ] {
        if read(&root.join(name))?.is_some_and(|v| !v.is_empty()) {
            return Err(fail("claude_swap_busy"));
        }
    }
    Ok(())
}
fn load(paths: &ClaudeAccountPaths, reference: &Reference) -> AccountResult<Slot> {
    let (sequence, accounts) = sequence(paths)?.ok_or_else(|| fail("claude_swap_unavailable"))?;
    let declared = slot_identity(
        &reference.slot,
        accounts
            .get(&reference.slot)
            .ok_or_else(|| fail("claude_swap_identity_changed"))?,
    )?;
    reference.validate(&declared)?;
    let root = root(paths)?;
    let email = declared.email.as_deref().unwrap();
    unresolved(&root, &reference.slot)?;
    let config = read(
        &root
            .join("configs")
            .join(format!(".claude-config-{}-{email}.json", reference.slot)),
    )?
    .ok_or_else(|| fail("claude_swap_unavailable"))?;
    let account =
        identity::object(&config).map_err(|_| fail("claude_swap_invalid"))?["oauthAccount"].clone();
    let actual = identity::Identity::from_account(&account)?;
    if actual != declared {
        return Err(fail("claude_swap_identity_changed"));
    }
    let path = root
        .join("credentials")
        .join(format!(".creds-{}-{email}.enc", reference.slot));
    let encoded = read(&path)?.ok_or_else(|| fail("claude_swap_unavailable"))?;
    let bytes = STANDARD
        .decode(
            std::str::from_utf8(&encoded)
                .map_err(|_| fail("claude_swap_invalid"))?
                .trim(),
        )
        .map_err(|_| fail("claude_swap_invalid"))?;
    identity::oauth(&bytes, true)?;
    let snapshot = Snapshot {
        slot: reference.slot.clone(),
        identity: actual.fingerprint(),
        sequence: identity::digest(&sequence),
        config: identity::digest(&config),
        encoded: identity::digest(&encoded),
        path,
    };
    // Re-read metadata to reject a torn slot (all mutation paths additionally
    // hold the upstream consumption and catalog locks).
    if read(&root.join("sequence.json"))?.as_deref() != Some(sequence.as_slice()) {
        return Err(fail("claude_swap_changed"));
    }
    Ok(Slot {
        reference: reference.clone(),
        identity: actual,
        snapshot,
        bytes,
    })
}
pub(in super::super) fn hydrate(paths: &ClaudeAccountPaths, record: &mut Record) {
    let Some(reference) = &record.source else {
        return;
    };
    record.credential.bytes.clear();
    record.source_snapshot = None;
    record.source_error = None;
    match load(paths, reference) {
        Ok(slot) => {
            record.credential.generation = identity::digest(&slot.bytes)[..32].into();
            record.credential.bytes = slot.bytes;
            record.source_snapshot = Some(slot.snapshot);
        }
        Err(error) => record.source_error = Some(error.code),
    }
}
pub(super) fn check(paths: &ClaudeAccountPaths, record: &Record) -> AccountResult<()> {
    if let Some(error) = record.source_error {
        return Err(fail(error));
    }
    if let Some(reference) = &record.source {
        if record.source_snapshot.as_ref() != Some(&load(paths, reference)?.snapshot) {
            return Err(fail("claude_swap_changed"));
        }
    }
    Ok(())
}
pub(super) fn write_back(
    paths: &ClaudeAccountPaths,
    record: &mut Record,
    bytes: &[u8],
    locks: &SwapLocks,
) -> AccountResult<()> {
    let Some(reference) = &record.source else {
        return Ok(());
    };
    locks.verify()?;
    if !locks.slots.contains(&reference.slot) {
        return Err(fail("claude_swap_busy"));
    }
    check(paths, record)?;
    identity::oauth(bytes, true)?;
    let snapshot = record
        .source_snapshot
        .as_ref()
        .ok_or_else(|| fail("claude_swap_unavailable"))?;
    if bytes != record.credential.bytes {
        // Same-directory atomic replacement; the source is never deleted and
        // its exact prior digest was checked while both upstream locks held.
        super::super::super::storage::atomic_write(
            &snapshot.path,
            STANDARD.encode(bytes).as_bytes(),
        )?;
    }
    let next = load(paths, reference)?;
    if next.bytes != bytes {
        return Err(fail("claude_swap_changed"));
    }
    record.source_snapshot = Some(next.snapshot);
    record.credential.bytes = next.bytes;
    record.credential.generation = identity::digest(bytes)[..32].into();
    Ok(())
}

pub(super) struct SwapLocks {
    held: Vec<(PathBuf, File)>,
    slots: Vec<String>,
}
impl SwapLocks {
    pub fn acquire(
        paths: &ClaudeAccountPaths,
        references: impl Iterator<Item = Reference>,
    ) -> AccountResult<Self> {
        let mut slots: Vec<_> = references.map(|r| r.slot).collect();
        slots.sort();
        slots.dedup();
        let mut result = Self {
            held: vec![],
            slots,
        };
        if result.slots.is_empty() {
            return Ok(result);
        }
        let root = root(paths)?;
        for path in result
            .slots
            .iter()
            .map(|slot| {
                root.join("credentials")
                    .join(format!(".consume-{slot}.lock"))
            })
            .chain(std::iter::once(root.join(".lock")))
        {
            let file = open(&path, true)?;
            lock(&file)?;
            result.held.push((path, file));
        }
        result.verify()?;
        Ok(result)
    }
    pub fn verify(&self) -> AccountResult<()> {
        for (path, file) in &self.held {
            if file_identity(file)? != file_identity(&open_with(path, false, false)?)? {
                return Err(fail("claude_swap_changed"));
            }
        }
        Ok(())
    }
}
impl Drop for SwapLocks {
    fn drop(&mut self) {
        for (_, file) in self.held.iter().rev() {
            unlock(file);
        }
    }
}
fn read(path: &Path) -> AccountResult<Option<Vec<u8>>> {
    match std::fs::symlink_metadata(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(fail("claude_swap_unavailable")),
        Ok(_) => (),
    }
    let mut file = open(path, false)?;
    let mut bytes = Vec::new();
    (&mut file)
        .take(identity::MAX_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| fail("claude_swap_unavailable"))?;
    if bytes.len() > identity::MAX_BYTES
        || file_identity(&file)? != file_identity(&open(path, false)?)?
    {
        return Err(fail("claude_swap_invalid"));
    }
    Ok(Some(bytes))
}
fn open(path: &Path, lock_file: bool) -> AccountResult<File> {
    open_with(path, lock_file, !lock_file)
}
fn open_with(path: &Path, lock_file: bool, owner_required: bool) -> AccountResult<File> {
    super::super::super::storage::ensure_no_links(path)?;
    let mut options = OpenOptions::new();
    options.read(true).write(lock_file).create(lock_file);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        // Upstream uses LK_NBLCK on byte zero. Shared reads/writes are needed
        // for that protocol; deny delete/rename while the lock is owned.
        options.share_mode(3).custom_flags(0x0020_0000);
    }
    let file = options
        .open(path)
        .map_err(|_| fail("claude_swap_unavailable"))?;
    let metadata = file
        .metadata()
        .map_err(|_| fail("claude_swap_unavailable"))?;
    if !metadata.is_file() || metadata.len() > identity::MAX_BYTES as u64 {
        return Err(fail("claude_swap_invalid"));
    }
    super::super::super::storage::ensure_no_links(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.nlink() != 1 {
            return Err(fail("claude_swap_invalid"));
        }
    }
    #[cfg(windows)]
    {
        // The upstream lock files contain no credential and retain upstream's
        // default ACL; never take ownership or rewrite an existing lock ACL.
        if owner_required {
            super::super::super::native::private::check_owner(path)?;
        }
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return Err(fail("claude_swap_invalid"));
        }
    }
    #[cfg(not(windows))]
    let _ = owner_required;
    Ok(file)
}
#[cfg(unix)]
fn file_identity(file: &File) -> AccountResult<(u64, u64)> {
    use std::os::unix::fs::MetadataExt;
    let m = file
        .metadata()
        .map_err(|_| fail("claude_swap_unavailable"))?;
    Ok((m.dev(), m.ino()))
}
#[cfg(windows)]
fn file_identity(file: &File) -> AccountResult<(u64, u64)> {
    use std::os::windows::io::AsRawHandle;
    use windows::Win32::{
        Foundation::HANDLE,
        Storage::FileSystem::{GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION},
    };
    let mut info = BY_HANDLE_FILE_INFORMATION::default();
    unsafe { GetFileInformationByHandle(HANDLE(file.as_raw_handle()), &mut info) }
        .map_err(|_| fail("claude_swap_unavailable"))?;
    if info.nNumberOfLinks != 1 {
        return Err(fail("claude_swap_invalid"));
    }
    Ok((
        info.dwVolumeSerialNumber as u64,
        ((info.nFileIndexHigh as u64) << 32) | info.nFileIndexLow as u64,
    ))
}
#[cfg(unix)]
unsafe extern "C" {
    fn flock(fd: i32, operation: i32) -> i32;
}
#[cfg(unix)]
fn lock(file: &File) -> AccountResult<()> {
    use std::os::fd::AsRawFd;
    if unsafe { flock(file.as_raw_fd(), 2 | 4) } != 0 {
        Err(fail("claude_swap_busy"))
    } else {
        Ok(())
    }
}
#[cfg(unix)]
fn unlock(file: &File) {
    use std::os::fd::AsRawFd;
    unsafe {
        flock(file.as_raw_fd(), 8);
    }
}
#[cfg(windows)]
fn lock(file: &File) -> AccountResult<()> {
    use std::os::windows::io::AsRawHandle;
    use windows::Win32::{
        Foundation::HANDLE,
        Storage::FileSystem::{LockFileEx, LOCKFILE_EXCLUSIVE_LOCK, LOCKFILE_FAIL_IMMEDIATELY},
        System::IO::OVERLAPPED,
    };
    unsafe {
        LockFileEx(
            HANDLE(file.as_raw_handle()),
            LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY,
            Some(0),
            1,
            0,
            &mut OVERLAPPED::default(),
        )
    }
    .map_err(|_| fail("claude_swap_busy"))
}
#[cfg(windows)]
fn unlock(file: &File) {
    use std::os::windows::io::AsRawHandle;
    use windows::Win32::{
        Foundation::HANDLE, Storage::FileSystem::UnlockFileEx, System::IO::OVERLAPPED,
    };
    let _ = unsafe {
        UnlockFileEx(
            HANDLE(file.as_raw_handle()),
            Some(0),
            1,
            0,
            &mut OVERLAPPED::default(),
        )
    };
}
impl ClaudeSubscriptionManager {
    pub fn scan_claude_swap_candidates(&self) -> AccountResult<Vec<ClaudeSwapCandidate>> {
        self.accepting()?;
        let Some((_, accounts)) = sequence(&self.paths)? else {
            return Ok(vec![]);
        };
        let store = self.store()?;
        let mut candidates = Vec::new();
        for (slot, value) in accounts {
            let Ok(identity) = slot_identity(&slot, &value) else {
                continue;
            };
            candidates.push(ClaudeSwapCandidate {
                candidate_id: candidate_id(&slot, &identity),
                label: format!("Claude {slot}"),
                masked_identity: identity.masked(),
                already_imported: store
                    .vault
                    .records
                    .iter()
                    .any(|r| r.credential.identity.fingerprint() == identity.fingerprint()),
            });
        }
        Ok(candidates)
    }
    pub fn import_claude_swap_candidate(
        &self,
        candidate: &str,
    ) -> AccountResult<super::super::ClaudeSubscriptionDto> {
        let _op = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.recovered()?;
        self.no_other_operation()?;
        let (_, accounts) =
            sequence(&self.paths)?.ok_or_else(|| fail("claude_swap_unavailable"))?;
        let (slot, identity) = accounts
            .iter()
            .filter_map(|(slot, value)| slot_identity(slot, value).ok().map(|id| (slot, id)))
            .find(|(slot, id)| candidate_id(slot, id) == candidate)
            .ok_or_else(|| fail("claude_swap_changed"))?;
        let reference = Reference {
            slot: slot.clone(),
            identity_fingerprint: identity.fingerprint(),
        };
        let locks = SwapLocks::acquire(&self.paths, std::iter::once(reference.clone()))?;
        let source = load(&self.paths, &reference)?;
        let mut store = self.store()?;
        if store
            .vault
            .records
            .iter()
            .any(|r| r.credential.identity.fingerprint() == source.identity.fingerprint())
        {
            return Err(fail("duplicate_identity"));
        }
        if store.vault.records.len() >= 64 {
            return Err(fail("account_limit"));
        }
        let label = format!("Claude {slot}");
        if store
            .vault
            .records
            .iter()
            .any(|r| r.label.eq_ignore_ascii_case(&label))
        {
            return Err(fail("duplicate_label"));
        }
        let id = nonce()?;
        let record = Record {
            id: id.clone(),
            label,
            remark: None,
            revision: 1,
            credential: identity::StoredCredential {
                bytes: source.bytes.clone(),
                oauth_account: json!({"accountUuid":source.identity.uuid,"organizationUuid":source.identity.organization,"emailAddress":source.identity.email}),
                identity: source.identity,
                generation: identity::digest(&source.bytes)[..32].into(),
                observed_at: now(),
                plan: None,
            },
            source: Some(source.reference),
            source_snapshot: Some(source.snapshot),
            source_error: None,
        };
        locks.verify()?;
        check(&self.paths, &record)?;
        store.vault.records.push(record);
        self.accepting()?;
        store.save()?;
        drop(store);
        self.list_claude_subscriptions()?
            .into_iter()
            .find(|r| r.id == id)
            .ok_or_else(|| fail("account_not_found"))
    }
}

#[cfg(test)]
#[path = "cswap_tests.rs"]
mod tests;
