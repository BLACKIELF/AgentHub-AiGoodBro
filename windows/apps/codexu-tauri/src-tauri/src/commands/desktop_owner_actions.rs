//! Explicit native caller for the original GUI owner. No runner, Web authority,
//! automatic replay, transcript persistence or background polling.
use codexu_core::{
    accounts::ActiveSystemScope,
    desktop_owner::{
        Cancellation, DesktopOwnerClient, JournalAction, JournalState, OperationRecord,
        OwnerJournal, OwnerSnapshot, OwnerTicket,
    },
    managed_proxy::ManagedActivityGuard,
};
use serde::Serialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    path::PathBuf,
    time::{Duration, Instant},
};

type Result<T> = std::result::Result<T, String>;
const BUDGET: Duration = Duration::from_secs(10);
const PREVIEW_AGE: Duration = Duration::from_secs(10);
const MAX_PENDING: usize = 64;
fn fail(code: &str) -> String {
    format!("owner_{code}")
}
fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn hash_parts(parts: &[&str]) -> String {
    hash(&serde_json::to_vec(parts).expect("string array serializes"))
}
fn is_hash(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn uuid(s: &str) -> bool {
    s.len() == 36
        && s.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}
fn nonce() -> Result<String> {
    codexu_core::local_cli::launch::session_nonce()
        .map(|v| v.iter().map(|b| format!("{b:02x}")).collect())
        .map_err(|_| fail("unavailable"))
}

/// Constructed only by the native workbench/AccountManager adapter. The local
/// context protects this App's selected source and concurrent operations. It
/// does not assert which account the separate original GUI is using.
#[derive(Clone)]
pub(crate) struct NativeOwnerContext {
    active: Option<ActiveSystemScope>,
    workbench: String,
    thread: String,
    metadata: String,
    identity: String,
    profile: String,
    generation: String,
    home: String,
    auth: String,
    #[cfg(test)]
    synthetic: bool,
}
impl NativeOwnerContext {
    pub(crate) fn from_verified(
        active: ActiveSystemScope,
        workbench: String,
        thread: String,
        metadata: String,
    ) -> Result<Self> {
        if !is_hash(&workbench) || !is_hash(&metadata) || !uuid(&thread) {
            return Err(fail("scope_unverified"));
        }
        let home = active
            .canonical_home()
            .to_str()
            .ok_or_else(|| fail("scope_unverified"))?
            .to_owned();
        Ok(Self {
            identity: active.identity_hash().into(),
            profile: active.profile_id().into(),
            generation: active.credential_generation().into(),
            auth: active.auth_digest().into(),
            active: Some(active),
            workbench,
            thread: thread.to_ascii_lowercase(),
            metadata,
            home,
            #[cfg(test)]
            synthetic: false,
        })
    }
    fn check(&self) -> Result<()> {
        #[cfg(test)]
        if self.synthetic {
            return Ok(());
        }
        if self.active.is_none() {
            return Err(fail("scope_unverified"));
        }
        Ok(())
    }
    fn identity_key(&self) -> String {
        hash_parts(&[
            "original-owner-context-v1",
            &self.workbench,
            &self.thread,
            &self.home,
            &self.profile,
            &self.identity,
            &self.generation,
            &self.auth,
        ])
    }
    fn same_identity(&self, other: &Self) -> bool {
        self.identity_key() == other.identity_key() && self.active == other.active
    }
    fn same_preview(&self, other: &Self) -> bool {
        self.same_identity(other) && self.metadata == other.metadata
    }
}

/// Native request only: neither Serialize nor Deserialize. No prompt appears in
/// the preview/status DTO or durable caller metadata.
pub(crate) enum OwnerAction {
    StartText(String),
    Interrupt { expected_turn_id: String },
}
impl OwnerAction {
    fn validate(&self) -> Result<()> {
        match self {
            Self::StartText(s) if !s.trim().is_empty() && s.len() <= 4096 && !s.contains('\0') => {
                Ok(())
            }
            Self::Interrupt { expected_turn_id }
                if uuid(expected_turn_id)
                    && *expected_turn_id == expected_turn_id.to_ascii_lowercase() =>
            {
                Ok(())
            }
            _ => Err(fail("invalid_request")),
        }
    }
    fn action(&self) -> JournalAction {
        match self {
            Self::StartText(_) => JournalAction::StartText,
            Self::Interrupt { .. } => JournalAction::Interrupt,
        }
    }
    fn input(&self) -> &str {
        match self {
            Self::StartText(s) => s,
            Self::Interrupt { expected_turn_id } => expected_turn_id,
        }
    }
    fn label(&self) -> &'static str {
        match self {
            Self::StartText(_) => "start_text",
            Self::Interrupt { .. } => "interrupt",
        }
    }
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct OwnerPreview {
    pub preview_id: String,
    pub action_hash: String,
    pub snapshot_revision: u64,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct OwnerActionStatus {
    pub operation_id: String,
    /// accepted is only owner acceptance; terminal is exact scoped turn proof.
    pub state: &'static str,
    pub turn_id: Option<String>,
}
fn status(record: &OperationRecord) -> OwnerActionStatus {
    let (state, turn_id) = match &record.state {
        JournalState::Unknown => ("unknown", None),
        JournalState::NotSent => ("notSent", None),
        JournalState::Accepted { turn_id } => ("accepted", Some(turn_id.clone())),
    };
    OwnerActionStatus {
        operation_id: record.operation_id.clone(),
        state,
        turn_id,
    }
}
fn unknown(id: &str) -> OwnerActionStatus {
    OwnerActionStatus {
        operation_id: id.into(),
        state: "unknown",
        turn_id: None,
    }
}
fn snapshot_hash(s: &OwnerSnapshot) -> String {
    hash(&serde_json::to_vec(&(s.revision, &s.state)).expect("JSON serializes"))
}
fn snapshot_identity(s: &OwnerSnapshot, thread: &str) -> bool {
    s.state.get("id").and_then(Value::as_str) == Some(thread)
        && s.state.get("hostId").and_then(Value::as_str) == Some("local")
        && s.state.get("resumeState").and_then(Value::as_str) == Some("resumed")
}
fn idle(s: &OwnerSnapshot) -> bool {
    let v = &s.state;
    v.get("threadRuntimeStatus")
        .and_then(|v| v.get("type"))
        .and_then(Value::as_str)
        == Some("idle")
        && v.get("requests")
            .and_then(Value::as_array)
            .is_some_and(|r| r.is_empty())
        && v.get("threadGoal").is_none_or(|g| {
            g.is_null() || g.get("status").and_then(Value::as_str) == Some("active")
        })
        && v.get("threadGoalResumeConfirmation")
            .is_none_or(|v| v.is_null() || *v == false)
}
fn turn_status<'a>(s: &'a OwnerSnapshot, id: &str) -> Option<&'a str> {
    // Match committed Mac owner state: one exact turn, never an arbitrary idle
    // snapshot, another turn, ambiguous duplicate or user-facing task label.
    let turns: Vec<&Value> = if let Some(a) = s.state.get("turns").and_then(Value::as_array) {
        if a.len() > 4096 {
            return None;
        }
        a.iter().collect()
    } else {
        let entities = s
            .state
            .get("turnHistory")?
            .get("history")?
            .get("entitiesByKey")?
            .as_object()?;
        if entities.len() > 4096 {
            return None;
        }
        entities.values().collect()
    };
    let found: Vec<_> = turns
        .into_iter()
        .filter(|t| {
            t.get("turnId")
                .and_then(Value::as_str)
                .or_else(|| t.get("id").and_then(Value::as_str))
                == Some(id)
        })
        .collect();
    if found.len() != 1 {
        return None;
    }
    found[0].get("status")?.as_str()
}

trait OwnerSession {
    async fn snapshot(&mut self, refresh_ticket: bool) -> Result<OwnerSnapshot>;
    async fn submit(
        &mut self,
        journal: &OwnerJournal,
        id: &str,
        scope: &str,
        action: &OwnerAction,
    ) -> Result<OperationRecord>;
}
trait Factory {
    type Session: OwnerSession;
    async fn open(&mut self, thread: &str) -> Result<Self::Session>;
}
pub(crate) struct OfficialFactory;
struct OfficialSession {
    client: DesktopOwnerClient,
    ticket: OwnerTicket,
    thread: String,
}
impl Factory for OfficialFactory {
    type Session = OfficialSession;
    async fn open(&mut self, thread: &str) -> Result<OfficialSession> {
        let cancel = Cancellation::default();
        let mut client = DesktopOwnerClient::connect(BUDGET, &cancel)
            .await
            .map_err(|_| fail("unavailable"))?;
        let ticket = client
            .discover(thread, BUDGET, &cancel)
            .await
            .map_err(|_| fail("unavailable"))?;
        Ok(OfficialSession {
            client,
            ticket,
            thread: thread.into(),
        })
    }
}
impl OwnerSession for OfficialSession {
    async fn snapshot(&mut self, refresh_ticket: bool) -> Result<OwnerSnapshot> {
        let cancel = Cancellation::default();
        if refresh_ticket {
            let next = self
                .client
                .discover(&self.thread, BUDGET, &cancel)
                .await
                .map_err(|_| fail("unavailable"))?;
            if !self.ticket.same_owner(&next) {
                self.client.close();
                return Err(fail("scope_changed"));
            }
            self.ticket = next;
        }
        self.client
            .snapshot(&self.ticket, BUDGET, &cancel)
            .await
            .map_err(|_| fail("unavailable"))
    }
    async fn submit(
        &mut self,
        journal: &OwnerJournal,
        id: &str,
        scope: &str,
        action: &OwnerAction,
    ) -> Result<OperationRecord> {
        let cancel = Cancellation::default();
        match action {
            OwnerAction::StartText(text) => {
                journal
                    .execute_start(
                        &mut self.client,
                        &self.ticket,
                        id,
                        scope,
                        text,
                        BUDGET,
                        &cancel,
                    )
                    .await
            }
            OwnerAction::Interrupt { expected_turn_id } => {
                journal
                    .execute_interrupt(
                        &mut self.client,
                        &self.ticket,
                        id,
                        scope,
                        expected_turn_id,
                        BUDGET,
                        &cancel,
                    )
                    .await
            }
        }
        .map_err(|_| fail("journal_unavailable"))
    }
}
struct Preview<S, G> {
    context: NativeOwnerContext,
    action: OwnerAction,
    snapshot: OwnerSnapshot,
    hash: String,
    expires: Instant,
    session: S,
    _guard: G,
}
struct Attempt<S, G> {
    preview: Preview<S, G>,
    record: Option<OperationRecord>,
}
/// Parent State retains this object through app lifetime. Pending attempts block
/// normal exit; replacing/dropping the State is never a cleanup operation.
pub(crate) struct OwnerActions<F: Factory = OfficialFactory, G = ManagedActivityGuard> {
    journal: OwnerJournal,
    factory: F,
    previews: BTreeMap<String, Preview<F::Session, G>>,
    attempts: BTreeMap<String, Attempt<F::Session, G>>,
}
impl OwnerActions {
    pub(crate) fn new(native_private_root: PathBuf) -> Result<Self> {
        Self::build(native_private_root, OfficialFactory)
    }
}
impl<F: Factory, G> OwnerActions<F, G> {
    fn build(root: PathBuf, factory: F) -> Result<Self> {
        Ok(Self {
            journal: OwnerJournal::new(root).map_err(|_| fail("journal_unavailable"))?,
            factory,
            previews: BTreeMap::new(),
            attempts: BTreeMap::new(),
        })
    }
    pub(crate) fn blocks_normal_exit(&self) -> bool {
        !self.attempts.is_empty()
    }
    /// Explicit preview cancellation/closing by the parent UI. A submitted
    /// attempt has already left this map and cannot be released by cancellation.
    pub(crate) fn discard_preview(&mut self, preview_id: &str) -> bool {
        self.previews.remove(preview_id).is_some()
    }
    pub(crate) async fn prepare(
        &mut self,
        context: NativeOwnerContext,
        action: OwnerAction,
        guard: G,
    ) -> Result<OwnerPreview> {
        context.check()?;
        action.validate()?;
        self.previews.retain(|_, p| Instant::now() < p.expires);
        if self.previews.len() + self.attempts.len() >= MAX_PENDING {
            return Err(fail("busy"));
        }
        let mut session = self.factory.open(&context.thread).await?;
        let snapshot = session.snapshot(false).await?;
        context.check()?;
        if !snapshot_identity(&snapshot, &context.thread) {
            return Err(fail("scope_changed"));
        }
        let allowed = match &action {
            OwnerAction::StartText(_) => idle(&snapshot),
            OwnerAction::Interrupt { expected_turn_id } => {
                turn_status(&snapshot, expected_turn_id) == Some("inProgress")
            }
        };
        if !allowed {
            return Err(fail("not_admissible"));
        }
        let hash = hash_parts(&[
            &context.identity_key(),
            &context.metadata,
            &snapshot_hash(&snapshot),
            action.label(),
            &hash(action.input().as_bytes()),
        ]);
        let preview_id = nonce()?;
        let result = OwnerPreview {
            preview_id: preview_id.clone(),
            action_hash: hash.clone(),
            snapshot_revision: snapshot.revision,
        };
        self.previews.insert(
            preview_id,
            Preview {
                context,
                action,
                snapshot,
                hash,
                expires: Instant::now() + PREVIEW_AGE,
                session,
                _guard: guard,
            },
        );
        Ok(result)
    }
    pub(crate) async fn confirm<C, U>(
        &mut self,
        preview_id: &str,
        operation_id: &str,
        expected_action_hash: &str,
        mut capture: C,
    ) -> Result<OwnerActionStatus>
    where
        C: FnMut() -> U,
        U: std::future::Future<Output = Result<NativeOwnerContext>>,
    {
        if !uuid(operation_id) {
            return Err(fail("invalid_request"));
        }
        let id = operation_id.to_ascii_lowercase();
        let p = self
            .previews
            .get(preview_id)
            .ok_or_else(|| fail("preview_expired"))?;
        if p.hash != expected_action_hash {
            return Err(fail("scope_changed"));
        }
        if let Some(existing) = self
            .journal
            .status(&id)
            .map_err(|_| fail("journal_unavailable"))?
        {
            if !binding_matches(&existing, &id, p) {
                return Err(fail("operation_conflict"));
            }
            return Ok(status(&existing)); // Even NotSent is never replayed.
        }
        if let Some(a) = self.attempts.get(&id) {
            if a.preview.hash != p.hash {
                return Err(fail("operation_conflict"));
            }
            return Ok(a
                .record
                .as_ref()
                .map(status)
                .unwrap_or_else(|| unknown(&id)));
        }
        let mut p = self.previews.remove(preview_id).unwrap();
        if Instant::now() >= p.expires {
            return Err(fail("preview_expired"));
        }
        let current = capture().await?;
        current.check()?;
        p.context.check()?;
        if !p.context.same_preview(&current) {
            return Err(fail("scope_changed"));
        }
        let snapshot = p.session.snapshot(false).await?;
        let current = capture().await?;
        current.check()?;
        p.context.check()?;
        if !p.context.same_preview(&current)
            || snapshot_hash(&snapshot) != snapshot_hash(&p.snapshot)
            || Instant::now() >= p.expires
        {
            return Err(fail("scope_changed"));
        }
        // Store the actual admission guard BEFORE awaiting the durable journal
        // wrapper. Dropped futures leave this attempt Unknown, never re-sendable.
        self.attempts.insert(
            id.clone(),
            Attempt {
                preview: p,
                record: None,
            },
        );
        let attempt = self.attempts.get_mut(&id).unwrap();
        let outcome = attempt
            .preview
            .session
            .submit(
                &self.journal,
                &id,
                &attempt.preview.hash,
                &attempt.preview.action,
            )
            .await;
        let record = match outcome {
            Ok(r) if binding_matches(&r, &id, &attempt.preview) => r,
            _ => return Ok(unknown(&id)),
        };
        // A start acknowledgement cannot identify a pre-existing turn.
        if let JournalState::Accepted { turn_id } = &record.state {
            if matches!(attempt.preview.action, OwnerAction::StartText(_))
                && turn_status(&attempt.preview.snapshot, turn_id).is_some()
            {
                return Ok(unknown(&id));
            }
        }
        let result = status(&record);
        attempt.record = Some(record);
        if result.state == "notSent" {
            self.attempts.remove(&id);
        }
        Ok(result)
    }
    /// Durable read only. No connection, discovery or mutation on restart.
    pub(crate) fn status(&self, operation_id: &str) -> Result<Option<OwnerActionStatus>> {
        if !uuid(operation_id) {
            return Err(fail("invalid_request"));
        }
        let id = operation_id.to_ascii_lowercase();
        if let Some(a) = self.attempts.get(&id) {
            return Ok(Some(
                a.record
                    .as_ref()
                    .map(status)
                    .unwrap_or_else(|| unknown(&id)),
            ));
        }
        self.journal
            .status(&id)
            .map(|r| r.as_ref().map(status))
            .map_err(|_| fail("journal_unavailable"))
    }
    pub(crate) async fn poll<C, U>(
        &mut self,
        operation_id: &str,
        mut capture: C,
    ) -> Result<OwnerActionStatus>
    where
        C: FnMut() -> U,
        U: std::future::Future<Output = Result<NativeOwnerContext>>,
    {
        if !uuid(operation_id) {
            return Err(fail("invalid_request"));
        }
        let id = operation_id.to_ascii_lowercase();
        let Some(attempt) = self.attempts.get_mut(&id) else {
            return self.status(&id)?.ok_or_else(|| fail("operation_missing"));
        };
        let Some(record) = &attempt.record else {
            return Ok(unknown(&id));
        };
        let JournalState::Accepted { turn_id } = &record.state else {
            return Ok(status(record));
        };
        let current = capture().await?;
        current.check()?;
        if !attempt.preview.context.same_identity(&current) {
            return Err(fail("scope_changed"));
        }
        let snapshot = attempt.preview.session.snapshot(true).await?;
        let current = capture().await?;
        current.check()?;
        if !attempt.preview.context.same_identity(&current)
            || !snapshot_identity(&snapshot, &current.thread)
            || snapshot.revision < attempt.preview.snapshot.revision
            || !idle(&snapshot)
        {
            return Ok(status(record));
        }
        let terminal = match turn_status(&snapshot, turn_id) {
            Some("completed") => "completed",
            Some("failed") => "failed",
            Some("interrupted") => "interrupted",
            _ => return Ok(status(record)),
        };
        let result = OwnerActionStatus {
            operation_id: id.clone(),
            state: terminal,
            turn_id: Some(turn_id.clone()),
        };
        self.attempts.remove(&id); // Only exact scoped terminal releases admission.
        Ok(result)
    }
}
fn binding_matches<S, G>(r: &OperationRecord, id: &str, p: &Preview<S, G>) -> bool {
    r.operation_id == id
        && r.conversation_id == p.context.thread
        && r.scope_sha256 == p.hash
        && r.action == p.action.action()
        && r.input_sha256 == hash(p.action.input().as_bytes())
}

#[cfg(test)]
#[path = "desktop_owner_actions_tests.rs"]
mod tests;
