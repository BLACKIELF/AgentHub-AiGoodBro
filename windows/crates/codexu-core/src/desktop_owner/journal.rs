//! Native-only durable claims. Pending is exposed as Unknown after every read,
//! including another client or restart; no entry is ever automatically retried.
use super::*;
use crate::accounts::storage;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, path::PathBuf};

const MAX_RECORDS: usize = 4096;
const MAX_BYTES: usize = 4 * 1024 * 1024;
const FILE: &str = "owner-operations-v1.json";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum JournalError {
    InvalidRequest,
    Busy,
    StorageUnavailable,
    InvalidStore,
    Conflict,
    Full,
}
pub type JournalResult<T> = Result<T, JournalError>;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JournalAction {
    StartText,
    Interrupt,
}

/// Accepted records the owner's accepted turn, never model completion.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum JournalState {
    Unknown,
    NotSent,
    Accepted { turn_id: String },
}

/// These hashes and identifiers are native metadata, not Web-supplied authority.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OperationRecord {
    pub operation_id: String,
    pub conversation_id: String,
    pub scope_sha256: String,
    pub action: JournalAction,
    pub input_sha256: String,
    pub state: JournalState,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Binding {
    conversation_id: String,
    scope_sha256: String,
    action: JournalAction,
    input_sha256: String,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case", deny_unknown_fields)]
enum SavedState {
    Pending,
    Unknown,
    NotSent,
    Accepted { turn_id: String },
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    binding: Binding,
    outcome: SavedState,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Document {
    schema: u32,
    entries: BTreeMap<String, Entry>,
}
impl Default for Document {
    fn default() -> Self {
        Self {
            schema: 1,
            entries: BTreeMap::new(),
        }
    }
}
fn digest(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn id(s: &str) -> JournalResult<String> {
    if protocol::uuid(s) {
        Ok(s.to_ascii_lowercase())
    } else {
        Err(JournalError::InvalidRequest)
    }
}
fn binding(
    ticket: &OwnerTicket,
    scope: &str,
    action: JournalAction,
    input: &str,
) -> JournalResult<Binding> {
    if !digest(scope) {
        return Err(JournalError::InvalidRequest);
    }
    Ok(Binding {
        conversation_id: id(&ticket.conversation)?,
        scope_sha256: scope.into(),
        action,
        input_sha256: format!("{:x}", Sha256::digest(input.as_bytes())),
    })
}
fn record(operation_id: &str, e: &Entry) -> OperationRecord {
    OperationRecord {
        operation_id: operation_id.into(),
        conversation_id: e.binding.conversation_id.clone(),
        scope_sha256: e.binding.scope_sha256.clone(),
        action: e.binding.action,
        input_sha256: e.binding.input_sha256.clone(),
        state: match &e.outcome {
            SavedState::Pending | SavedState::Unknown => JournalState::Unknown,
            SavedState::NotSent => JournalState::NotSent,
            SavedState::Accepted { turn_id } => JournalState::Accepted {
                turn_id: turn_id.clone(),
            },
        },
    }
}

/// One native-selected private directory shared by all owner clients. No
/// automatic pruning: exhaustion is explicit, so old Unknown claims survive.
pub struct OwnerJournal {
    root: PathBuf,
}
impl OwnerJournal {
    pub fn new(root: PathBuf) -> JournalResult<Self> {
        storage::ensure_no_links(&root).map_err(|_| JournalError::InvalidRequest)?;
        Ok(Self { root })
    }
    fn read(&self) -> JournalResult<(Document, Option<Vec<u8>>)> {
        let prior = storage::read_bound_optional(&self.root.join(FILE), MAX_BYTES, true)
            .map_err(|_| JournalError::StorageUnavailable)?;
        let d = match &prior {
            None => Document::default(),
            Some(b) => {
                serde_json::from_slice::<Document>(b).map_err(|_| JournalError::InvalidStore)?
            }
        };
        if d.schema != 1 || d.entries.len() > MAX_RECORDS || d.entries.iter().any(|(key, e)| {
            id(key).as_ref() != Ok(key) || id(&e.binding.conversation_id).as_ref() != Ok(&e.binding.conversation_id)
                || !digest(&e.binding.scope_sha256) || !digest(&e.binding.input_sha256)
                || matches!(&e.outcome, SavedState::Accepted{turn_id} if id(turn_id).as_ref() != Ok(turn_id))
        }) { return Err(JournalError::InvalidStore); }
        Ok((d, prior))
    }
    fn lock(&self) -> JournalResult<storage::StoreLock> {
        storage::StoreLock::acquire(&self.root).map_err(|e| {
            if e.code == "account_store_busy" {
                JournalError::Busy
            } else {
                JournalError::StorageUnavailable
            }
        })
    }
    fn save(&self, d: &Document, prior: &Option<Vec<u8>>) -> JournalResult<()> {
        let path = self.root.join(FILE);
        if storage::read_bound_optional(&path, MAX_BYTES, true)
            .map_err(|_| JournalError::StorageUnavailable)?
            != *prior
        {
            return Err(JournalError::Conflict);
        }
        let bytes = serde_json::to_vec(d).map_err(|_| JournalError::InvalidStore)?;
        if bytes.len() > MAX_BYTES {
            return Err(JournalError::Full);
        }
        storage::atomic_write(&path, &bytes).map_err(|_| JournalError::StorageUnavailable)?;
        #[cfg(unix)]
        std::fs::File::open(&self.root)
            .and_then(|f| f.sync_all())
            .map_err(|_| JournalError::StorageUnavailable)?;
        if storage::read_bound_optional(&path, MAX_BYTES, true)
            .map_err(|_| JournalError::StorageUnavailable)?
            .as_deref()
            != Some(&bytes)
        {
            return Err(JournalError::StorageUnavailable);
        }
        Ok(())
    }
    /// Read-only: no lock file/directory creation and no state repair on read.
    pub fn status(&self, operation_id: &str) -> JournalResult<Option<OperationRecord>> {
        let operation_id = id(operation_id)?;
        let (d, _) = self.read()?;
        Ok(d.entries
            .get(&operation_id)
            .map(|e| record(&operation_id, e)))
    }
    fn claim(&self, operation_id: &str, b: &Binding) -> JournalResult<Option<OperationRecord>> {
        let _lock = self.lock()?;
        let (mut d, prior) = self.read()?;
        if let Some(e) = d.entries.get(operation_id) {
            if &e.binding != b {
                return Err(JournalError::Conflict);
            }
            return Ok(Some(record(operation_id, e)));
        }
        if d.entries.len() >= MAX_RECORDS {
            return Err(JournalError::Full);
        }
        d.entries.insert(
            operation_id.into(),
            Entry {
                binding: b.clone(),
                outcome: SavedState::Pending,
            },
        );
        self.save(&d, &prior)?;
        Ok(None)
    }
    // Private: only the wrapper's real core result can resolve a pending claim.
    fn finish(&self, operation_id: &str, b: &Binding, result: ActionOutcome) -> OperationRecord {
        let unknown = Entry {
            binding: b.clone(),
            outcome: SavedState::Unknown,
        };
        let attempt = (|| {
            let _lock = self.lock()?;
            let (mut d, prior) = self.read()?;
            let e = d
                .entries
                .get_mut(operation_id)
                .ok_or(JournalError::Conflict)?;
            if &e.binding != b || e.outcome != SavedState::Pending {
                return Err(JournalError::Conflict);
            }
            e.outcome = match result {
                ActionOutcome::NotSent(_) => SavedState::NotSent,
                ActionOutcome::Unknown => SavedState::Unknown,
                ActionOutcome::Accepted { turn_id } => SavedState::Accepted {
                    turn_id: id(&turn_id)?,
                },
            };
            let out = record(operation_id, e);
            self.save(&d, &prior)?;
            Ok::<_, JournalError>(out)
        })();
        // Even an accepted remote action is Unknown to the caller if its final
        // receipt cannot be saved. Existing Pending still prevents any replay.
        attempt.unwrap_or_else(|_| record(operation_id, &unknown))
    }
    pub async fn execute_start(
        &self,
        client: &mut DesktopOwnerClient,
        ticket: &OwnerTicket,
        operation_id: &str,
        scope_sha256: &str,
        text: &str,
        timeout: Duration,
        cancel: &Cancellation,
    ) -> JournalResult<OperationRecord> {
        if text.trim().is_empty() || text.len() > 4096 || text.contains('\0') {
            return Err(JournalError::InvalidRequest);
        }
        let operation_id = id(operation_id)?;
        let b = binding(ticket, scope_sha256, JournalAction::StartText, text)?;
        if let Some(prior) = self.claim(&operation_id, &b)? {
            return Ok(prior);
        }
        let result = client
            .start_text(ticket, &operation_id, text, timeout, cancel)
            .await;
        Ok(self.finish(&operation_id, &b, result))
    }
    pub async fn execute_interrupt(
        &self,
        client: &mut DesktopOwnerClient,
        ticket: &OwnerTicket,
        operation_id: &str,
        scope_sha256: &str,
        expected_turn_id: &str,
        timeout: Duration,
        cancel: &Cancellation,
    ) -> JournalResult<OperationRecord> {
        let operation_id = id(operation_id)?;
        let turn = id(expected_turn_id)?;
        let b = binding(ticket, scope_sha256, JournalAction::Interrupt, &turn)?;
        if let Some(prior) = self.claim(&operation_id, &b)? {
            return Ok(prior);
        }
        let result = client
            .interrupt(ticket, &operation_id, &turn, timeout, cancel)
            .await;
        Ok(self.finish(&operation_id, &b, result))
    }
}

#[cfg(test)]
#[path = "journal_tests.rs"]
mod tests;
