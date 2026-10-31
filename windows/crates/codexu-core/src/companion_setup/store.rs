use super::{manifest::*, *};
use crate::accounts::storage;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeSet,
    path::{Path, PathBuf},
};

const MAX_PLAN: usize = 4 * 1024 * 1024;
#[derive(Clone)]
pub struct SetupStore {
    root: PathBuf,
    target: PathBuf,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Change {
    path: String,
    before: Option<String>,
    after: String,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Plan {
    version: u8,
    id: String,
    target_key: String,
    target_identity: Option<String>,
    bundle_sha256: String,
    runtime_fingerprint: String,
    changes: Vec<Change>,
}
#[derive(Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
enum Phase {
    Applying,
    Complete,
    RolledBack,
    Conflict,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Journal {
    version: u8,
    plan_id: String,
    target_identity: String,
    attempted: Vec<usize>,
    phase: Phase,
}

fn storage_error<T>(r: crate::accounts::AccountResult<T>) -> Result<T> {
    r.map_err(|_| fail("companion_storage_unavailable"))
}
fn read_private<T: serde::de::DeserializeOwned>(p: &Path) -> Result<Option<T>> {
    storage_error(storage::read_bound_optional(p, MAX_PLAN, true))?
        .map(|b| serde_json::from_slice(&b).map_err(|_| fail("companion_journal_invalid")))
        .transpose()
}
fn save<T: Serialize>(p: &Path, value: &T) -> Result<()> {
    let data = serde_json::to_vec(value).map_err(|_| fail("companion_storage_unavailable"))?;
    if data.len() > MAX_PLAN {
        return Err(fail("companion_storage_limit"));
    }
    write(p, &data)?;
    if storage_error(storage::read_bound_optional(p, MAX_PLAN, true))?.as_deref() != Some(&data) {
        return Err(fail("companion_storage_unavailable"));
    }
    Ok(())
}
fn write(path: &Path, bytes: &[u8]) -> Result<()> {
    storage_error(storage::atomic_write(path, bytes))?;
    #[cfg(unix)]
    std::fs::File::open(
        path.parent()
            .ok_or_else(|| fail("companion_target_invalid"))?,
    )
    .and_then(|directory| directory.sync_all())
    .map_err(|_| fail("companion_storage_unavailable"))?;
    Ok(())
}
fn owned(p: &Path) -> Result<()> {
    storage_error(storage::check_existing_owned_path(p))
}
fn existing(p: &Path) -> Result<bool> {
    storage_error(storage::ensure_no_links(p))?;
    match std::fs::symlink_metadata(p) {
        Ok(_) => {
            owned(p)?;
            Ok(true)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(_) => Err(fail("companion_storage_unavailable")),
    }
}
fn directory_identity(p: &Path) -> Result<Option<String>> {
    if !existing(p)? {
        return Ok(None);
    }
    let m = std::fs::metadata(p).map_err(|_| fail("companion_target_invalid"))?;
    if !m.is_dir() {
        return Err(fail("companion_target_invalid"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Ok(Some(format!("{}:{}", m.dev(), m.ino())))
    }
    #[cfg(windows)]
    {
        use std::os::windows::{fs::OpenOptionsExt, io::AsRawHandle};
        use windows::Win32::{
            Foundation::HANDLE,
            Storage::FileSystem::{GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION},
        };
        let f = std::fs::OpenOptions::new()
            .read(true)
            .share_mode(7)
            .custom_flags(0x02200000)
            .open(p)
            .map_err(|_| fail("companion_target_invalid"))?;
        let mut i = BY_HANDLE_FILE_INFORMATION::default();
        unsafe { GetFileInformationByHandle(HANDLE(f.as_raw_handle()), &mut i) }
            .map_err(|_| fail("companion_target_invalid"))?;
        Ok(Some(format!(
            "{}:{}:{}",
            i.dwVolumeSerialNumber, i.nFileIndexHigh, i.nFileIndexLow
        )))
    }
    #[cfg(not(any(unix, windows)))]
    {
        Err(fail("companion_platform_unavailable"))
    }
}
/// Existing directories are checked, never chmod/chowned or adopted.
fn make_owned_dirs(p: &Path) -> Result<()> {
    let mut missing = vec![];
    let mut at = p;
    while !existing(at)? {
        missing.push(at.to_path_buf());
        at = at
            .parent()
            .ok_or_else(|| fail("companion_target_invalid"))?;
    }
    if !at.is_dir() {
        return Err(fail("companion_target_invalid"));
    }
    for d in missing.into_iter().rev() {
        // CREATE_NEW only: a raced-in object is rejected, not reused.
        storage_error(storage::create_private_directory(&d))?;
        owned(&d)?;
    }
    Ok(())
}
fn target_text(root: &Path, relative: &str) -> Result<Option<String>> {
    if !safe_relative(relative) {
        return Err(fail("companion_target_invalid"));
    }
    let p = root.join(relative);
    let mut at = p.parent();
    while let Some(d) = at {
        if !d.starts_with(root) {
            break;
        }
        if existing(d)? && !d.is_dir() {
            return Err(fail("companion_target_invalid"));
        }
        at = d.parent();
    }
    if !existing(&p)? {
        return Ok(None);
    }
    storage_error(storage::read_bound_owned_optional(&p, MAX_FILE))?
        .map(|b| String::from_utf8(b).map_err(|_| fail("companion_target_invalid")))
        .transpose()
}
fn allowed_target(path: &str) -> bool {
    SLOTS.iter().any(|(_, p, _)| !p.is_empty() && path == *p)
        || (path.starts_with("bin/next-dispatch")
            && path.split('/').count() == 2
            && safe_relative(path))
        || matches!(
            path,
            "config/runtime-paths.json" | "config/runtime-python.txt"
        )
}
fn empty_scaffold(root: &Path) -> Result<bool> {
    // A compensated first install can leave only these empty, owned folders.
    // Do not recursively adopt an arbitrary directory merely lacking SKILL.md.
    for item in std::fs::read_dir(root).map_err(|_| fail("companion_target_invalid"))? {
        let item = item.map_err(|_| fail("companion_target_invalid"))?;
        let name = item.file_name();
        if !matches!(
            name.to_str(),
            Some("bin" | "config" | "references" | "scripts")
        ) {
            return Ok(false);
        }
        let path = item.path();
        owned(&path)?;
        if !path.is_dir()
            || std::fs::read_dir(path)
                .map_err(|_| fail("companion_target_invalid"))?
                .next()
                .is_some()
        {
            return Ok(false);
        }
    }
    Ok(true)
}
impl SetupStore {
    /// Paths come from the native App-data/Skill resolver, never an IPC string.
    pub fn new(app_data: &Path, target: PathBuf) -> Result<Self> {
        if !app_data.is_absolute() || !target.is_absolute() || target.parent().is_none() {
            return Err(fail("companion_target_invalid"));
        }
        storage_error(storage::ensure_no_links(app_data))?;
        storage_error(storage::ensure_no_links(&target))?;
        // Remove only redundant separators/dot components after rejecting
        // traversal; preserve case and never resolve a different existing link.
        let target: PathBuf = target.components().collect();
        Ok(Self {
            root: app_data.join("companion-setup-v1"),
            target,
        })
    }
    fn target_key(&self) -> String {
        hash(self.target.as_os_str().as_encoded_bytes())
    }
    fn journal(&self) -> PathBuf {
        self.root.join("transaction.json")
    }
    fn plan_path(&self, id: &str) -> Result<PathBuf> {
        if !is_hash(id) {
            return Err(fail("companion_plan_invalid"));
        }
        // One outstanding confirmation only; repeated previews do not create
        // an unbounded collection of abandoned plans.
        Ok(self.root.join("plan.json"))
    }
    fn check_journal(&self) -> Result<Option<Journal>> {
        let j: Option<Journal> = read_private(&self.journal())?;
        if let Some(j) = &j {
            self.plan_path(&j.plan_id)?;
            if j.version != 1
                || j.attempted.len() > 21
                || j.attempted.iter().copied().collect::<BTreeSet<_>>().len() != j.attempted.len()
            {
                return Err(fail("companion_journal_invalid"));
            }
        }
        Ok(j)
    }
    fn no_pending(&self) -> Result<()> {
        if self
            .check_journal()?
            .is_some_and(|j| matches!(j.phase, Phase::Applying | Phase::Conflict))
        {
            return Err(fail("companion_recovery_required"));
        }
        Ok(())
    }
    fn load_plan(&self, id: &str) -> Result<Plan> {
        let p: Plan =
            read_private(&self.plan_path(id)?)?.ok_or_else(|| fail("companion_plan_missing"))?;
        if p.version != 1
            || p.id != id
            || p.target_key != self.target_key()
            || !is_hash(&p.bundle_sha256)
            || !is_hash(&p.runtime_fingerprint)
            || p.changes.is_empty()
            || p.changes.len() > 21
        {
            return Err(fail("companion_plan_invalid"));
        }
        let mut paths = BTreeSet::new();
        let mut total = 0;
        for c in &p.changes {
            total += c.before.as_ref().map_or(0, String::len) + c.after.len();
            if !allowed_target(&c.path)
                || !paths.insert(c.path.to_lowercase())
                || c.after.len() > MAX_FILE
                || c.before.as_ref().is_some_and(|v| v.len() > MAX_FILE)
                || c.before.as_ref() == Some(&c.after)
            {
                return Err(fail("companion_plan_invalid"));
            }
        }
        if total > 2 * MAX_TOTAL {
            return Err(fail("companion_storage_limit"));
        }
        Ok(p)
    }
    fn capture(&self, pin: &BundlePin, adapter: &dyn PlatformAdapter) -> Result<(Plan, Snapshot)> {
        let b = Bundle::load(pin)?;
        let runtime = adapter.verify(&pin.sha256, b.abi)?;
        let identity = directory_identity(&self.target)?;
        let skill = target_text(&self.target, "SKILL.md")?;
        let initial = skill.is_none();
        if initial && identity.is_some() && !empty_scaffold(&self.target)? {
            return Err(fail("companion_unrecognized_installation"));
        }
        let source_skill = b
            .files
            .iter()
            .find(|f| f.path == "SKILL.md")
            .ok_or_else(|| fail("companion_bundle_invalid"))?;
        let mut desired: Vec<(String, String)> = b
            .files
            .iter()
            .filter(|f| f.path != "SKILL.md" && (initial || f.managed))
            .map(|f| (f.path.clone(), f.text.clone()))
            .collect();
        desired.push((
            "SKILL.md".into(),
            managed_skill(skill.as_deref().unwrap_or(&source_skill.text), &b.note)?,
        ));
        desired.push(("config/runtime-paths.json".into(), runtime.paths_json));
        desired.push(("config/runtime-python.txt".into(), runtime.python_line));
        desired.sort_by(|a, b| a.0.cmp(&b.0));
        let mut changes = vec![];
        let mut statuses = vec![];
        let mut total = 0;
        for (path, after) in desired {
            let before = target_text(&self.target, &path)?;
            total += before.as_ref().map_or(0, String::len) + after.len();
            let status = if before.as_ref() == Some(&after) {
                FileState::Same
            } else if before.is_none() {
                FileState::Missing
            } else {
                FileState::Changed
            };
            statuses.push(FileStatus {
                path: path.clone(),
                status,
            });
            if status != FileState::Same {
                changes.push(Change {
                    path,
                    before,
                    after,
                });
            }
        }
        if total > 2 * MAX_TOTAL {
            return Err(fail("companion_storage_limit"));
        }
        let state = if changes.is_empty() {
            State::Ready
        } else if initial {
            State::Missing
        } else {
            State::Outdated
        };
        Ok((
            Plan {
                version: 1,
                id: {
                    let mut entropy = [0u8; 32];
                    getrandom::fill(&mut entropy)
                        .map_err(|_| fail("companion_storage_unavailable"))?;
                    hash(&entropy)
                },
                target_key: self.target_key(),
                target_identity: identity,
                bundle_sha256: pin.sha256.clone(),
                runtime_fingerprint: runtime.fingerprint,
                changes,
            },
            Snapshot {
                state,
                issue_code: None,
                files: statuses,
                plan_id: None,
                backup_available: false,
            },
        ))
    }
    pub fn inspect(&self, pin: &BundlePin, adapter: &dyn PlatformAdapter) -> Snapshot {
        let result = (|| {
            // Read-only inspection creates no state or Skill directories.
            self.no_pending()?;
            self.capture(pin, adapter).map(|(_, s)| s)
        })();
        result.unwrap_or_else(|e: Error| {
            let mut s = Snapshot::unavailable(e.code);
            if matches!(
                e.code,
                "companion_managed_section_conflict"
                    | "companion_recovery_required"
                    | "companion_unrecognized_installation"
            ) {
                s.state = State::Conflict;
            }
            s
        })
    }
    /// First explicit step. Returns an opaque plan id for a separate confirmation.
    pub fn prepare(&self, pin: &BundlePin, adapter: &dyn PlatformAdapter) -> Result<Snapshot> {
        let _lock = storage_error(storage::StoreLock::acquire(&self.root))?;
        self.no_pending()?;
        let (plan, mut snapshot) = self.capture(pin, adapter)?;
        if !plan.changes.is_empty() {
            save(&self.plan_path(&plan.id)?, &plan)?;
            snapshot.plan_id = Some(plan.id);
        }
        Ok(snapshot)
    }
    pub fn confirm_install(
        &self,
        id: &str,
        pin: &BundlePin,
        adapter: &dyn PlatformAdapter,
    ) -> Result<Snapshot> {
        self.apply_with(id, pin, adapter, |_, _| Ok(()))
    }
    // The hook is internal and used only by synthetic fault-injection fixtures.
    pub(super) fn apply_with(
        &self,
        id: &str,
        pin: &BundlePin,
        adapter: &dyn PlatformAdapter,
        mut after_write: impl FnMut(usize, &Path) -> Result<()>,
    ) -> Result<Snapshot> {
        let _lock = storage_error(storage::StoreLock::acquire(&self.root))?;
        self.no_pending()?;
        let plan = self.load_plan(id)?;
        let (now, _) = self.capture(pin, adapter)?;
        if plan.bundle_sha256 != now.bundle_sha256
            || plan.runtime_fingerprint != now.runtime_fingerprint
            || plan.target_identity != now.target_identity
            || serde_json::to_vec(&plan.changes).ok() != serde_json::to_vec(&now.changes).ok()
        {
            return Err(fail("companion_plan_stale"));
        }
        let backup = self.root.join(format!("backup-{id}"));
        make_owned_dirs(&backup)?;
        // Complete and read back all backups before touching any target file.
        for (i, c) in plan.changes.iter().enumerate() {
            if let Some(old) = &c.before {
                let path = backup.join(format!("{i}.txt"));
                match storage_error(storage::read_bound_optional(&path, MAX_FILE, true))? {
                    Some(v) if v == old.as_bytes() => (),
                    Some(_) => return Err(fail("companion_backup_conflict")),
                    None => write(&path, old.as_bytes())?,
                }
                if storage_error(storage::read_bound_optional(&path, MAX_FILE, true))?.as_deref()
                    != Some(old.as_bytes())
                {
                    return Err(fail("companion_backup_unavailable"));
                }
            }
        }
        make_owned_dirs(&self.target)?;
        let mut journal = Journal {
            version: 1,
            plan_id: id.into(),
            target_identity: directory_identity(&self.target)?
                .ok_or_else(|| fail("companion_target_invalid"))?,
            attempted: vec![],
            phase: Phase::Applying,
        };
        save(&self.journal(), &journal)?;
        let work = (|| {
            for (i, c) in plan.changes.iter().enumerate() {
                self.require_target(&journal)?;
                if target_text(&self.target, &c.path)? != c.before {
                    return Err(fail("companion_concurrent_change"));
                }
                // Persist intent before writing: recovery includes writes whose
                // result was lost. It only undoes bytes still equal to ours.
                journal.attempted.push(i);
                save(&self.journal(), &journal)?;
                let path = self.target.join(&c.path);
                make_owned_dirs(path.parent().unwrap())?;
                self.require_target(&journal)?;
                if target_text(&self.target, &c.path)? != c.before {
                    return Err(fail("companion_concurrent_change"));
                }
                // Recheck native capability on each write; revocation stops apply.
                let live = adapter.verify(&pin.sha256, 1)?;
                if live.fingerprint != plan.runtime_fingerprint {
                    return Err(fail("companion_adapter_changed"));
                }
                write(&path, c.after.as_bytes())?;
                if target_text(&self.target, &c.path)?.as_ref() != Some(&c.after) {
                    return Err(fail("companion_write_unconfirmed"));
                }
                after_write(i, &path)?;
            }
            self.require_target(&journal)?;
            let (final_plan, ready) = self.capture(pin, adapter)?;
            self.require_target(&journal)?;
            if ready.state != State::Ready
                || final_plan.runtime_fingerprint != plan.runtime_fingerprint
            {
                return Err(fail("companion_write_unconfirmed"));
            }
            journal.phase = Phase::Complete;
            save(&self.journal(), &journal)?;
            Ok(Snapshot {
                backup_available: plan.changes.iter().any(|c| c.before.is_some()),
                ..ready
            })
        })();
        match work {
            Ok(v) => Ok(v),
            Err(e) => {
                if self.rollback(&plan, &mut journal).is_err() {
                    return Err(fail("companion_rollback_conflict"));
                }
                Err(e)
            }
        }
    }
    fn require_target(&self, j: &Journal) -> Result<()> {
        if directory_identity(&self.target)?.as_deref() != Some(&j.target_identity) {
            return Err(fail("companion_target_changed"));
        }
        Ok(())
    }
    fn rollback(&self, plan: &Plan, j: &mut Journal) -> Result<()> {
        self.require_target(j)?;
        let mut conflict = false;
        for &i in j.attempted.iter().rev() {
            let c = plan
                .changes
                .get(i)
                .ok_or_else(|| fail("companion_journal_invalid"))?;
            let restore = (|| {
                self.require_target(j)?;
                let current = target_text(&self.target, &c.path)?;
                if current == c.before {
                    return Ok(());
                }
                if current.as_ref() != Some(&c.after) {
                    return Err(fail("companion_concurrent_change"));
                }
                let path = self.target.join(&c.path);
                if let Some(old) = &c.before {
                    let backup = self
                        .root
                        .join(format!("backup-{}", plan.id))
                        .join(format!("{i}.txt"));
                    let bytes =
                        storage_error(storage::read_bound_optional(&backup, MAX_FILE, true))?
                            .ok_or_else(|| fail("companion_backup_unavailable"))?;
                    if bytes != old.as_bytes() {
                        return Err(fail("companion_backup_conflict"));
                    }
                    if target_text(&self.target, &c.path)?.as_ref() != Some(&c.after) {
                        return Err(fail("companion_concurrent_change"));
                    }
                    write(&path, &bytes)?;
                } else {
                    if target_text(&self.target, &c.path)?.as_ref() != Some(&c.after) {
                        return Err(fail("companion_concurrent_change"));
                    }
                    std::fs::remove_file(&path)
                        .map_err(|_| fail("companion_storage_unavailable"))?;
                    #[cfg(unix)]
                    std::fs::File::open(path.parent().unwrap())
                        .and_then(|d| d.sync_all())
                        .map_err(|_| fail("companion_storage_unavailable"))?;
                }
                if target_text(&self.target, &c.path)? != c.before {
                    return Err(fail("companion_write_unconfirmed"));
                }
                Ok(())
            })();
            if restore.is_err() {
                conflict = true;
            }
        }
        j.phase = if conflict {
            Phase::Conflict
        } else {
            Phase::RolledBack
        };
        save(&self.journal(), j)?;
        if conflict {
            Err(fail("companion_rollback_conflict"))
        } else {
            Ok(())
        }
    }
    /// Explicit recovery never runs a task or reapplies an installation. No
    /// capability is required to restore our still-matching interrupted writes.
    pub fn recover(&self) -> Result<()> {
        let _lock = storage_error(storage::StoreLock::acquire(&self.root))?;
        let Some(mut j) = self.check_journal()? else {
            return Ok(());
        };
        if matches!(j.phase, Phase::Complete | Phase::RolledBack) {
            return Ok(());
        }
        let plan = self.load_plan(&j.plan_id)?;
        self.rollback(&plan, &mut j)
    }
}
