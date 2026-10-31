use super::*;
use crate::accounts::storage;
use std::{collections::BTreeMap, path::PathBuf};
const FILE: &str = "companion-requests-v1.json";
const MAX_BYTES: usize = 4 * 1024 * 1024;
const MAX_ENTRIES: usize = 4096;

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Binding {
    pub actor: String,
    pub runtime: String,
    pub scope: String,
    pub epoch: String,
    pub intent: String,
    pub lease: String,
    pub create_id: String,
    pub create_body: String,
    pub approve_id: String,
}
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "phase", rename_all = "camelCase", deny_unknown_fields)]
pub(super) enum Phase {
    PendingCreate,
    Created { task: TaskBinding },
    PendingApprove { task: TaskBinding, body: String },
    Accepted { task: TaskBinding, body: String },
}
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(super) struct Entry {
    pub binding: Binding,
    pub phase: Phase,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Document {
    schema: u32,
    entries: BTreeMap<String, Entry>,
}
pub(super) struct Journal {
    root: PathBuf,
    #[cfg(test)]
    writes: std::sync::atomic::AtomicUsize,
    #[cfg(test)]
    pub fail_write: std::sync::atomic::AtomicUsize,
}
impl Entry {
    fn valid(&self) -> bool {
        let b = &self.binding;
        [
            &b.actor,
            &b.runtime,
            &b.scope,
            &b.epoch,
            &b.intent,
            &b.lease,
            &b.create_id,
            &b.create_body,
            &b.approve_id,
        ]
        .iter()
        .all(|s| digest(s))
            && match &self.phase {
                Phase::PendingCreate => true,
                Phase::Created { task } => task.valid() && task.scope_sha256 == b.scope,
                Phase::PendingApprove { task, body } | Phase::Accepted { task, body } => {
                    task.valid()
                        && task.scope_sha256 == b.scope
                        && *body == hash_parts(&["approve", &task.task_id, &task.action_hash])
                }
            }
    }
}
impl Journal {
    pub fn new(root: PathBuf) -> Result<Self> {
        storage::ensure_no_links(&root).map_err(|_| fail("companion_storage_unavailable"))?;
        Ok(Self {
            root,
            #[cfg(test)]
            writes: std::sync::atomic::AtomicUsize::new(0),
            #[cfg(test)]
            fail_write: std::sync::atomic::AtomicUsize::new(usize::MAX),
        })
    }
    fn read(&self) -> Result<(Document, Option<Vec<u8>>)> {
        let prior = storage::read_bound_optional(&self.root.join(FILE), MAX_BYTES, true)
            .map_err(|_| fail("companion_storage_unavailable"))?;
        let doc = match &prior {
            None => Document {
                schema: 1,
                entries: BTreeMap::new(),
            },
            Some(b) => serde_json::from_slice::<Document>(b)
                .map_err(|_| fail("companion_journal_invalid"))?,
        };
        if doc.schema != 1
            || doc.entries.len() > MAX_ENTRIES
            || doc.entries.iter().any(|(k, v)| !digest(k) || !v.valid())
        {
            return Err(fail("companion_journal_invalid"));
        }
        Ok((doc, prior))
    }
    fn save(&self, d: &Document, prior: &Option<Vec<u8>>) -> Result<()> {
        #[cfg(test)]
        {
            use std::sync::atomic::Ordering;
            let n = self.writes.fetch_add(1, Ordering::SeqCst) + 1;
            if self.fail_write.load(Ordering::SeqCst) == n {
                return Err(fail("companion_storage_unavailable"));
            }
        }
        let path = self.root.join(FILE);
        if storage::read_bound_optional(&path, MAX_BYTES, true)
            .map_err(|_| fail("companion_storage_unavailable"))?
            != *prior
        {
            return Err(fail("companion_journal_changed"));
        }
        let bytes = serde_json::to_vec(d).map_err(|_| fail("companion_journal_invalid"))?;
        if bytes.len() > MAX_BYTES {
            return Err(fail("companion_journal_full"));
        }
        storage::atomic_write(&path, &bytes).map_err(|_| fail("companion_storage_unavailable"))?;
        #[cfg(unix)]
        std::fs::File::open(&self.root)
            .and_then(|f| f.sync_all())
            .map_err(|_| fail("companion_storage_unavailable"))?;
        if storage::read_bound_optional(&path, MAX_BYTES, true)
            .map_err(|_| fail("companion_storage_unavailable"))?
            .as_deref()
            != Some(bytes.as_slice())
        {
            return Err(fail("companion_storage_unavailable"));
        }
        Ok(())
    }
    pub fn get(&self, id: &str) -> Result<Option<Entry>> {
        if !digest(id) {
            return Err(fail("companion_invalid_request"));
        }
        Ok(self.read()?.0.entries.get(id).cloned())
    }
    pub fn claim(&self, id: &str, entry: &Entry) -> Result<bool> {
        let _lock =
            storage::StoreLock::acquire(&self.root).map_err(|_| fail("companion_journal_busy"))?;
        let (mut d, prior) = self.read()?;
        if let Some(existing) = d.entries.get(id) {
            if existing.binding != entry.binding {
                return Err(fail("companion_request_changed"));
            }
            return Ok(false);
        }
        if !digest(id) || !entry.valid() || entry.phase != Phase::PendingCreate {
            return Err(fail("companion_invalid_request"));
        }
        if d.entries.len() == MAX_ENTRIES {
            return Err(fail("companion_journal_full"));
        }
        d.entries.insert(id.into(), entry.clone());
        self.save(&d, &prior)?;
        Ok(true)
    }
    pub fn advance(&self, id: &str, old: &Entry, phase: Phase) -> Result<Entry> {
        let _lock =
            storage::StoreLock::acquire(&self.root).map_err(|_| fail("companion_journal_busy"))?;
        let (mut d, prior) = self.read()?;
        if d.entries.get(id) != Some(old) {
            return Err(fail("companion_journal_changed"));
        }
        let next = Entry {
            binding: old.binding.clone(),
            phase,
        };
        let allowed = matches!(
            (&old.phase, &next.phase),
            (Phase::PendingCreate, Phase::Created { .. })
                | (Phase::Created { .. }, Phase::PendingApprove { .. })
                | (Phase::PendingApprove { .. }, Phase::Accepted { .. })
        );
        if !allowed || !next.valid() {
            return Err(fail("companion_journal_invalid"));
        }
        d.entries.insert(id.into(), next.clone());
        self.save(&d, &prior)?;
        Ok(next)
    }
}
