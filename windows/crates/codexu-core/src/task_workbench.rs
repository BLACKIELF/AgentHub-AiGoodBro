//! Local semantic annotations over existing Codex metadata. No conversation
//! writer, runner, model call or process cancellation is part of this module.
use crate::{
    accounts::storage,
    readers::codex_task_board::{read_workbench_metadata, WorkbenchMetadata},
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};

const MAX_STORE: usize = 1024 * 1024;
const MAX_INVENTORY: usize = 24 * 1024;
const MAX_ITEMS: usize = 1000;
#[derive(Clone, Copy, Debug, thiserror::Error, PartialEq, Eq)]
pub enum WorkbenchError {
    #[error("workbench_invalid")]
    Invalid,
    #[error("workbench_source_unavailable")]
    SourceUnavailable,
    #[error("workbench_source_changed")]
    SourceChanged,
    #[error("workbench_storage_unavailable")]
    StorageUnavailable,
    #[error("workbench_busy")]
    Busy,
    #[error("workbench_capacity")]
    Capacity,
    #[error("workbench_thread_missing")]
    ThreadMissing,
}
pub type Result<T> = std::result::Result<T, WorkbenchError>;
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Outcome {
    #[default]
    Unknown,
    Incomplete,
    Candidate,
    AwaitingAcceptance,
    Complete,
}
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Decision {
    #[default]
    None,
    Paused,
    Cancelled,
    Completed,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Artifact {
    pub title: String,
    pub reference: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Inventory {
    #[serde(rename = "threadID")]
    pub thread_id: String,
    pub project: String,
    pub outcome: Outcome,
    pub remaining: Vec<String>,
    pub next_step: String,
    pub artifacts: Vec<Artifact>,
    pub evidence: String,
    pub checked_at_ms: i64,
    #[serde(rename = "sourceTurnID")]
    pub source_turn_id: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ImportedInventory {
    #[serde(rename = "threadID")]
    thread_id: String,
    project: String,
    outcome: Outcome,
    remaining: Vec<String>,
    next_step: String,
    artifacts: Vec<Artifact>,
    evidence: String,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Annotation {
    inventory: Option<Inventory>,
    decision: Decision,
    decision_at_ms: Option<i64>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Saved {
    version: u32,
    scope_id: String,
    annotations: BTreeMap<String, Annotation>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkbenchItem {
    pub thread_id: String,
    pub title: String,
    pub project: String,
    pub updated_at_ms: Option<i64>,
    pub archived: bool,
    pub execution_state: &'static str,
    pub outcome: Outcome,
    pub decision: Decision,
    pub decision_at_ms: Option<i64>,
    pub inventory_is_stale: bool,
    pub needs_attention: bool,
    pub inventory: Option<Inventory>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkbenchSnapshot {
    pub scope_id: String,
    pub checked_at_ms: i64,
    pub source_available: bool,
    pub truncated: bool,
    pub items: Vec<WorkbenchItem>,
}

pub fn valid_thread_id(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}
fn valid_time(value: i64) -> bool {
    (0..=8_640_000_000_000_000).contains(&value)
}
fn token_length(value: &str) -> usize {
    value
        .bytes()
        .take_while(|b| b.is_ascii_alphanumeric() || b"._-".contains(b))
        .count()
}
fn safe_text(value: &str, limit: usize) -> bool {
    if value.len() > limit
        || value
            .chars()
            .any(|c| c.is_control() && c != '\n' && c != '\t')
    {
        return false;
    }
    let lower = value.to_ascii_lowercase();
    for (index, _) in lower.match_indices("sk-") {
        if token_length(&lower[index + 3..]) >= 16 {
            return false;
        }
    }
    for (index, _) in lower.match_indices("bearer") {
        let tail = &lower[index + 6..];
        if tail.starts_with(char::is_whitespace) && token_length(tail.trim_start()) >= 16 {
            return false;
        }
    }
    for prefix in [
        "apikey",
        "api_key",
        "api-key",
        "api key",
        "accesstoken",
        "access_token",
        "access-token",
        "access token",
        "bottoken",
        "bot_token",
        "bot-token",
        "bot token",
        "password",
    ] {
        for (index, _) in lower.match_indices(prefix) {
            let tail = lower[index + prefix.len()..].trim_start();
            if let Some(tail) = tail.strip_prefix([':', '=']) {
                if token_length(tail.trim_start()) >= 12 {
                    return false;
                }
            }
        }
    }
    true
}
fn decoded_leaf(path: &str) -> Option<String> {
    let leaf = path.rsplit(['/', '\\']).next()?;
    let mut bytes = Vec::new();
    let mut i = 0;
    let raw = leaf.as_bytes();
    while i < raw.len() {
        if raw[i] == b'%' {
            if i + 2 >= raw.len() {
                return None;
            }
            let digits = std::str::from_utf8(&raw[i + 1..i + 3]).ok()?;
            bytes.push(u8::from_str_radix(digits, 16).ok()?);
            i += 3;
        } else {
            bytes.push(raw[i]);
            i += 1;
        }
    }
    String::from_utf8(bytes).ok().map(|s| s.to_lowercase())
}
fn valid_reference(reference: &str) -> bool {
    if !safe_text(reference, 2048) {
        return false;
    }
    let forbidden = |leaf: &str| {
        [
            "auth.json",
            "credentials.json",
            "secrets.json",
            ".credentials.json",
            ".env",
        ]
        .contains(&leaf)
    };
    if reference.starts_with("https://") {
        return url::Url::parse(reference).ok().is_some_and(|u| {
            u.scheme() == "https"
                && u.host_str().is_some()
                && u.username().is_empty()
                && u.password().is_none()
                && decoded_leaf(u.path())
                    .is_some_and(|leaf| !forbidden(&leaf) && !leaf.contains(['/', '\\']))
        });
    }
    let bytes = reference.as_bytes();
    let drive = bytes.len() > 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && [b'\\', b'/'].contains(&bytes[2]);
    if !(reference.starts_with('/') && !reference.starts_with("//") || drive)
        || reference.starts_with("\\\\")
        || reference.split(['/', '\\']).any(|part| part == "..")
    {
        return false;
    }
    let Some(leaf) = decoded_leaf(reference) else {
        return false;
    };
    if forbidden(&leaf) || leaf.contains(['/', '\\']) || leaf.contains(':') {
        return false;
    }
    leaf.rsplit_once('.').is_some_and(|(_, ext)| {
        [
            "md", "txt", "pdf", "png", "jpg", "jpeg", "webp", "svg", "html", "json", "csv", "xlsx",
            "pptx", "docx", "mp4", "mov",
        ]
        .contains(&ext)
    })
}
impl Inventory {
    fn validate(&self, expected: &str) -> Result<()> {
        if self.thread_id != expected
            || !valid_thread_id(expected)
            || !safe_text(&self.project, 160)
            || !safe_text(&self.next_step, 800)
            || !safe_text(&self.evidence, 1600)
            || self.remaining.len() > 8
            || self.remaining.iter().any(|s| !safe_text(s, 800))
            || self.artifacts.len() > 8
            || !valid_time(self.checked_at_ms)
            || self
                .source_turn_id
                .as_ref()
                .is_some_and(|s| !valid_thread_id(s))
        {
            return Err(WorkbenchError::Invalid);
        }
        let mut references = std::collections::HashSet::new();
        if self.artifacts.iter().any(|a| {
            !safe_text(&a.title, 160)
                || !valid_reference(&a.reference)
                || !references.insert(&a.reference)
        }) {
            return Err(WorkbenchError::Invalid);
        }
        Ok(())
    }
    pub fn parse(input: &str, thread_id: &str, now_ms: i64) -> Result<Self> {
        if input.len() > MAX_INVENTORY || !valid_time(now_ms) {
            return Err(WorkbenchError::Invalid);
        }
        let v: ImportedInventory =
            serde_json::from_str(input).map_err(|_| WorkbenchError::Invalid)?;
        let inventory = Self {
            thread_id: v.thread_id,
            project: v.project,
            outcome: if v.outcome == Outcome::Complete {
                Outcome::AwaitingAcceptance
            } else {
                v.outcome
            },
            remaining: v.remaining,
            next_step: v.next_step,
            artifacts: v.artifacts,
            evidence: v.evidence,
            checked_at_ms: now_ms,
            source_turn_id: None,
        };
        inventory.validate(thread_id)?;
        Ok(inventory)
    }
}
impl Saved {
    fn validate(&self, scope: &str) -> Result<()> {
        if self.version != 1 || self.scope_id != scope {
            return Err(WorkbenchError::SourceChanged);
        }
        if self.annotations.len() > MAX_ITEMS {
            return Err(WorkbenchError::Capacity);
        }
        for (id, note) in &self.annotations {
            if !valid_thread_id(id) || note.decision_at_ms.is_some_and(|v| !valid_time(v)) {
                return Err(WorkbenchError::Invalid);
            }
            if let Some(value) = &note.inventory {
                value.validate(id)?;
            }
        }
        Ok(())
    }
}

/// Only a native file picker supplies this path. User-selected documents are
/// not required to have vault ACLs; they are still bounded, no-link and read
/// through one identity-checked handle. No path is returned to a WebView.
pub fn read_inventory_file(path: &Path) -> Result<String> {
    if !path
        .extension()
        .and_then(|v| v.to_str())
        .is_some_and(|s| s.eq_ignore_ascii_case("json"))
    {
        return Err(WorkbenchError::Invalid);
    }
    let bytes = storage::read_bound_optional(path, MAX_INVENTORY, false)
        .map_err(|_| WorkbenchError::Invalid)?
        .ok_or(WorkbenchError::Invalid)?;
    String::from_utf8(bytes).map_err(|_| WorkbenchError::Invalid)
}

pub struct TaskWorkbenchStore {
    root: PathBuf,
    directory: PathBuf,
    path: PathBuf,
    scope_id: String,
}
impl TaskWorkbenchStore {
    pub fn open(app_data: &Path, codex_root: &Path) -> Result<Self> {
        storage::ensure_no_links(app_data).map_err(|_| WorkbenchError::StorageUnavailable)?;
        storage::ensure_no_links(codex_root).map_err(|_| WorkbenchError::SourceUnavailable)?;
        let root = codex_root
            .canonicalize()
            .map_err(|_| WorkbenchError::SourceUnavailable)?;
        if !root.is_dir() {
            return Err(WorkbenchError::SourceChanged);
        }
        let text = root.to_str().ok_or(WorkbenchError::SourceUnavailable)?;
        // Use the filesystem's canonical spelling. Lowercasing would collapse
        // distinct roots in Windows directories configured as case-sensitive.
        let scope_id = format!(
            "{:x}",
            Sha256::digest(format!("AiGoodBro.task-workbench.v1\0{text}").as_bytes())
        );
        let directory = app_data.join("task-workbench-v1").join(&scope_id);
        let path = directory.join("inventory.json");
        Ok(Self {
            root,
            directory,
            path,
            scope_id,
        })
    }
    pub fn scope_id(&self) -> &str {
        &self.scope_id
    }
    fn metadata(&self) -> Result<WorkbenchMetadata> {
        let mut metadata =
            read_workbench_metadata(&self.root).map_err(|_| WorkbenchError::SourceUnavailable)?;
        let mut seen = std::collections::HashSet::new();
        metadata
            .threads
            .retain(|t| valid_thread_id(&t.thread_id) && seen.insert(t.thread_id.clone()));
        Ok(metadata)
    }
    fn read(&self) -> Result<Saved> {
        let bytes = storage::read_bound_optional(&self.path, MAX_STORE, true)
            .map_err(|_| WorkbenchError::StorageUnavailable)?;
        let value = match bytes {
            Some(b) => {
                serde_json::from_slice(&b).map_err(|_| WorkbenchError::StorageUnavailable)?
            }
            None => Saved {
                version: 1,
                scope_id: self.scope_id.clone(),
                annotations: BTreeMap::new(),
            },
        };
        value.validate(&self.scope_id)?;
        Ok(value)
    }
    fn selected(&self, id: &str) -> Result<()> {
        if !valid_thread_id(id) {
            return Err(WorkbenchError::Invalid);
        }
        let metadata = self.metadata()?;
        if !metadata.source_available {
            return Err(WorkbenchError::SourceUnavailable);
        }
        if !metadata.threads.iter().any(|t| t.thread_id == id) {
            return Err(WorkbenchError::ThreadMissing);
        }
        Ok(())
    }
    fn mutate(&self, id: &str, change: impl FnOnce(&mut Annotation) -> Result<()>) -> Result<()> {
        self.selected(id)?;
        let _lock = storage::StoreLock::acquire(&self.directory).map_err(|e| {
            if e.code == "account_store_busy" {
                WorkbenchError::Busy
            } else {
                WorkbenchError::StorageUnavailable
            }
        })?;
        let before = storage::read_bound_optional(&self.path, MAX_STORE, true)
            .map_err(|_| WorkbenchError::StorageUnavailable)?;
        let mut saved = self.read()?;
        if saved.annotations.len() >= MAX_ITEMS && !saved.annotations.contains_key(id) {
            return Err(WorkbenchError::Capacity);
        }
        change(saved.annotations.entry(id.into()).or_default())?;
        saved.validate(&self.scope_id)?;
        let bytes = serde_json::to_vec(&saved).map_err(|_| WorkbenchError::Invalid)?;
        if bytes.len() > MAX_STORE {
            return Err(WorkbenchError::Capacity);
        }
        self.selected(id)?;
        if storage::read_bound_optional(&self.path, MAX_STORE, true)
            .map_err(|_| WorkbenchError::StorageUnavailable)?
            != before
        {
            return Err(WorkbenchError::SourceChanged);
        }
        storage::atomic_write(&self.path, &bytes)
            .map_err(|_| WorkbenchError::StorageUnavailable)?;
        Ok(())
    }
    pub fn import_inventory(&self, thread_id: &str, input: &str, now_ms: i64) -> Result<()> {
        let inventory = Inventory::parse(input, thread_id, now_ms)?;
        self.mutate(thread_id, |note| {
            note.inventory = Some(inventory);
            Ok(())
        })
    }
    pub fn set_decision(&self, thread_id: &str, decision: Decision, now_ms: i64) -> Result<()> {
        if !valid_time(now_ms) {
            return Err(WorkbenchError::Invalid);
        }
        self.mutate(thread_id, |note| {
            note.decision = decision;
            note.decision_at_ms = Some(now_ms);
            Ok(())
        })
    }
    pub fn artifact_reference(&self, thread_id: &str, index: usize) -> Result<String> {
        self.selected(thread_id)?;
        let saved = self.read()?;
        let reference = saved
            .annotations
            .get(thread_id)
            .and_then(|n| n.inventory.as_ref())
            .and_then(|i| i.artifacts.get(index))
            .map(|a| a.reference.clone())
            .ok_or(WorkbenchError::Invalid)?;
        if !valid_reference(&reference) {
            return Err(WorkbenchError::Invalid);
        }
        Ok(reference)
    }
    pub fn load(&self, now_ms: i64) -> Result<WorkbenchSnapshot> {
        if !valid_time(now_ms) {
            return Err(WorkbenchError::Invalid);
        }
        let metadata = self.metadata()?;
        let saved = self.read()?;
        let mut items = Vec::new();
        for task in metadata.threads {
            let note = saved
                .annotations
                .get(&task.thread_id)
                .cloned()
                .unwrap_or_default();
            let inventory_is_stale = note
                .inventory
                .as_ref()
                .zip(task.updated_at_ms)
                .is_some_and(|(i, t)| t > i.checked_at_ms);
            let outcome = if note.decision == Decision::Completed {
                Outcome::Complete
            } else if inventory_is_stale {
                Outcome::Unknown
            } else {
                match note
                    .inventory
                    .as_ref()
                    .map(|i| i.outcome)
                    .unwrap_or_default()
                {
                    Outcome::Complete => Outcome::AwaitingAcceptance,
                    other => other,
                }
            };
            let project = note
                .inventory
                .as_ref()
                .map(|i| i.project.trim())
                .filter(|s| !s.is_empty())
                .unwrap_or(task.project.trim());
            let project = if safe_text(project, 160) && !project.is_empty() {
                project.to_owned()
            } else {
                "Uncategorized".into()
            };
            let title = if safe_text(&task.title, 512) {
                task.title
            } else {
                "Untitled".into()
            };
            let needs_attention = note.decision == Decision::None
                && (inventory_is_stale
                    || matches!(
                        outcome,
                        Outcome::Incomplete | Outcome::Candidate | Outcome::AwaitingAcceptance
                    ));
            items.push(WorkbenchItem {
                thread_id: task.thread_id,
                title,
                project,
                updated_at_ms: task.updated_at_ms,
                archived: task.archived,
                execution_state: "recorded",
                outcome,
                decision: note.decision,
                decision_at_ms: note.decision_at_ms,
                inventory_is_stale,
                needs_attention,
                inventory: note.inventory,
            });
        }
        Ok(WorkbenchSnapshot {
            scope_id: self.scope_id.clone(),
            checked_at_ms: now_ms,
            source_available: metadata.source_available,
            truncated: metadata.truncated,
            items,
        })
    }
}
#[cfg(test)]
#[path = "task_workbench_tests.rs"]
mod tests;
