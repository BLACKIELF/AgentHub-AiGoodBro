//! Native caller for the original GUI owner. No runner, Web authority,
//! automatic replay or transcript persistence.
use codexu_core::{
    accounts::ActiveSystemScope,
    desktop_owner::{
        Cancellation, DesktopOwnerClient, JournalAction, JournalState, OperationRecord,
        OwnerJournal, OwnerSnapshot, OwnerTicket,
    },
    managed_proxy::{AutomaticMaintenanceLease, ManagedActivityGuard},
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
    pub(crate) fn recheck_admission(
        &self,
        manager: &codexu_core::accounts::AccountManager,
        selected_home: &std::path::Path,
    ) -> bool {
        self.active.as_ref().is_some_and(|active| {
            selected_home.canonicalize().ok().as_deref() == Some(active.canonical_home())
                && manager.recheck_active_system_scope(active).is_ok()
        })
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
fn all_snapshot_turns(s: &OwnerSnapshot) -> Option<Vec<&Value>> {
    let turns: Vec<_> = if s
        .state
        .get("turnHistory")
        .and_then(|h| h.get("kind"))
        .and_then(Value::as_str)
        == Some("canonical")
    {
        s.state
            .get("turnHistory")?
            .get("history")?
            .get("entitiesByKey")?
            .as_object()?
            .values()
            .collect()
    } else {
        s.state.get("turns")?.as_array()?.iter().collect()
    };
    (turns.len() <= 4096).then_some(turns)
}
fn turn_id(turn: &Value) -> Option<&str> {
    turn.get("turnId")
        .or_else(|| turn.get("id"))?
        .as_str()
        .filter(|id| uuid(id))
}
fn exact_turn<'a>(s: &'a OwnerSnapshot, id: &str) -> Option<&'a Value> {
    let found: Vec<_> = all_snapshot_turns(s)?
        .into_iter()
        .filter(|turn| turn_id(turn) == Some(id))
        .collect();
    (found.len() == 1).then(|| found[0])
}
/// Verified GUI canonical order uses the last island's exhausted newer
/// boundary and ordered entries, never entitiesByKey's map iteration order.
fn latest_turn(s: &OwnerSnapshot) -> Option<&Value> {
    let canonical = s
        .state
        .get("turnHistory")
        .filter(|h| h.get("kind").and_then(Value::as_str) == Some("canonical"));
    let turn = if let Some(canonical) = canonical {
        let history = canonical.get("history")?;
        let islands = history.get("islands")?.as_array()?;
        if islands.len() > 4096 {
            return None;
        }
        let latest = islands.last()?;
        if latest.get("newerBoundary")?.get("status")?.as_str()? != "exhausted" {
            return None;
        }
        let entries = latest.get("entries")?.as_array()?;
        if entries.len() > 4096 {
            return None;
        }
        let key = entries.last()?.get("value")?.as_str()?;
        history.get("entitiesByKey")?.as_object()?.get(key)?
    } else {
        s.state.get("turns")?.as_array()?.last()?
    };
    let id = turn_id(turn)?;
    exact_turn(s, id)
}
fn turn_status<'a>(s: &'a OwnerSnapshot, id: &str) -> Option<&'a str> {
    exact_turn(s, id)?.get("status")?.as_str()
}
fn may_contain_turn(s: &OwnerSnapshot, id: &str) -> bool {
    all_snapshot_turns(s)
        .is_none_or(|turns| turns.into_iter().any(|turn| turn_id(turn) == Some(id)))
}
fn awaiting_human(s: &OwnerSnapshot) -> bool {
    s.state
        .get("threadRuntimeStatus")
        .and_then(|v| v.get("activeFlags"))
        .and_then(Value::as_array)
        .is_some_and(|flags| {
            flags.iter().any(|flag| {
                matches!(
                    flag.as_str(),
                    Some("waitingOnApproval" | "waitingOnUserInput")
                )
            })
        })
}
/// In-memory native result only. Never a Web DTO or durable transcript.
#[derive(PartialEq, Eq)]
#[cfg_attr(test, derive(Debug))]
pub(crate) enum OwnerReplyPoll {
    Pending,
    AwaitingHuman,
    Reply { turn_id: String, text: String },
    Failed,
    Interrupted,
    Unavailable,
    Uncertain,
}
fn final_text(s: &OwnerSnapshot, turn_id: &str) -> Option<String> {
    let turn = exact_turn(s, turn_id)?;
    if turn.get("status")?.as_str()? != "completed" {
        return None;
    }
    let items = turn.get("items")?.as_array()?;
    if items.len() > 4096 || items.iter().any(|item| !item.is_object()) {
        return None;
    }
    let mut parts = Vec::new();
    let mut bytes = 0usize;
    for item in items {
        if item.get("type").and_then(Value::as_str) == Some("agentMessage")
            && item.get("phase").and_then(Value::as_str) == Some("final_answer")
        {
            let text = item.get("text")?.as_str()?;
            bytes = bytes.checked_add(text.len() + if parts.is_empty() { 0 } else { 2 })?;
            if bytes > 4096 || text.contains('\0') {
                return None;
            }
            parts.push(text);
        }
    }
    let text = parts.join("\n\n").trim().to_owned();
    (!text.is_empty()).then_some(text)
}
fn active_turn_id(s: &OwnerSnapshot) -> Option<String> {
    // Interrupts are derived from the just-read owner snapshot. The UI never
    // supplies a turn ID from a cached/history list.
    let runtime = s.state.get("threadRuntimeStatus")?.get("type")?.as_str()?;
    if runtime.is_empty() || runtime == "idle" {
        return None;
    }
    let turns = all_snapshot_turns(s)?;
    let active: Vec<_> = turns
        .into_iter()
        .filter(|t| t.get("status").and_then(Value::as_str) == Some("inProgress"))
        .collect();
    if active.len() != 1 {
        return None;
    }
    let id = active[0]
        .get("turnId")
        .and_then(Value::as_str)
        .or_else(|| active[0].get("id").and_then(Value::as_str))?;
    if uuid(id) && id == id.to_ascii_lowercase() {
        Some(id.to_owned())
    } else {
        None
    }
}

pub(crate) trait OwnerSession: Send {
    async fn snapshot(&mut self, refresh_ticket: bool) -> Result<OwnerSnapshot>;
    async fn submit(
        &mut self,
        journal: &OwnerJournal,
        id: &str,
        scope: &str,
        action: &OwnerAction,
    ) -> Result<OperationRecord>;
    async fn submit_controlled(
        &mut self,
        journal: &OwnerJournal,
        id: &str,
        scope: &str,
        action: &OwnerAction,
        cancel: &Cancellation,
    ) -> Result<OperationRecord> {
        if cancel.is_cancelled() {
            return Err(fail("cancelled"));
        }
        self.submit(journal, id, scope, action).await
    }
}
pub(crate) trait Factory: Send {
    type Session: OwnerSession + Send;
    async fn open(&mut self, thread: &str) -> Result<Self::Session>;
}
pub(crate) struct OfficialFactory;
pub(crate) struct OfficialSession {
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
        self.submit_controlled(journal, id, scope, action, &Cancellation::default())
            .await
    }
    async fn submit_controlled(
        &mut self,
        journal: &OwnerJournal,
        id: &str,
        scope: &str,
        action: &OwnerAction,
        cancel: &Cancellation,
    ) -> Result<OperationRecord> {
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
                        cancel,
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
                        cancel,
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
/// Either path retains its original exclusion authority. An uncertain
/// automatic request pins the maintenance lease just as a manual request pins
/// its terminal guard; neither can be released by closing a window.
pub(crate) enum OwnerActivityGuard {
    Terminal(ManagedActivityGuard),
    Automatic(AutomaticMaintenanceLease),
}
impl From<ManagedActivityGuard> for OwnerActivityGuard {
    fn from(value: ManagedActivityGuard) -> Self {
        Self::Terminal(value)
    }
}
impl From<AutomaticMaintenanceLease> for OwnerActivityGuard {
    fn from(value: AutomaticMaintenanceLease) -> Self {
        Self::Automatic(value)
    }
}
/// Parent State retains this object through app lifetime. Pending attempts block
/// normal exit; replacing/dropping the State is never a cleanup operation.
pub(crate) struct OwnerActions<F: Factory = OfficialFactory, G: Send = OwnerActivityGuard> {
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
impl<F: Factory, G: Send> OwnerActions<F, G> {
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
    /// Window close drops every unsubmitted preview and its guard. Submitted
    /// attempts, including Unknown, remain retained and continue blocking exit.
    pub(crate) fn close_previews(&mut self) -> usize {
        let count = self.previews.len();
        self.previews.clear();
        count
    }
    /// Read-only binding check. No preview, operation claim or mutation.
    pub(crate) async fn validate_idle_target(
        &mut self,
        context: &NativeOwnerContext,
    ) -> Result<()> {
        context.check()?;
        let mut session = self.factory.open(&context.thread).await?;
        let snapshot = session.snapshot(false).await?;
        if !snapshot_identity(&snapshot, &context.thread) {
            return Err(fail("scope_changed"));
        }
        if awaiting_human(&snapshot) {
            return Err(fail("awaiting_human"));
        }
        if !idle(&snapshot) {
            return Err(fail("not_admissible"));
        }
        Ok(())
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
        self.save_preview(context, action, guard, session, snapshot)
    }
    /// Resume only the exact interrupted latest turn. The ordinary confirm
    /// path then rechecks this entire snapshot twice before its single write.
    pub(crate) async fn prepare_resume(
        &mut self,
        context: NativeOwnerContext,
        original_turn: &str,
        guard: G,
    ) -> Result<OwnerPreview> {
        context.check()?;
        if !uuid(original_turn) {
            return Err(fail("invalid_request"));
        }
        self.previews.retain(|_, p| Instant::now() < p.expires);
        if self.previews.len() + self.attempts.len() >= MAX_PENDING {
            return Err(fail("busy"));
        }
        let mut session = self.factory.open(&context.thread).await?;
        let snapshot = session.snapshot(false).await?;
        if !snapshot_identity(&snapshot, &context.thread) {
            return Err(fail("scope_changed"));
        }
        if awaiting_human(&snapshot) || !idle(&snapshot) {
            return Err(fail("not_admissible"));
        }
        let latest = latest_turn(&snapshot).ok_or_else(|| fail("history_incomplete"))?;
        if turn_id(latest) != Some(original_turn) {
            return Err(fail("resume_changed"));
        }
        if latest.get("status").and_then(Value::as_str) != Some("interrupted") {
            return Err(fail("resume_changed"));
        }
        let action = OwnerAction::StartText("Continue the task that was just interrupted. First check what has already been done, and avoid repeating completed actions.".into());
        self.save_preview(context, action, guard, session, snapshot)
    }
    /// Prepare an interrupt using the unique active turn in a fresh full
    /// snapshot from the verified original owner.
    pub(crate) async fn prepare_current_interrupt(
        &mut self,
        context: NativeOwnerContext,
        guard: G,
    ) -> Result<OwnerPreview> {
        context.check()?;
        self.previews.retain(|_, p| Instant::now() < p.expires);
        if self.previews.len() + self.attempts.len() >= MAX_PENDING {
            return Err(fail("busy"));
        }
        let mut session = self.factory.open(&context.thread).await?;
        let snapshot = session.snapshot(false).await?;
        if !snapshot_identity(&snapshot, &context.thread) {
            return Err(fail("scope_changed"));
        }
        let expected_turn_id = active_turn_id(&snapshot).ok_or_else(|| fail("not_admissible"))?;
        self.save_preview(
            context,
            OwnerAction::Interrupt { expected_turn_id },
            guard,
            session,
            snapshot,
        )
    }
    fn save_preview(
        &mut self,
        context: NativeOwnerContext,
        action: OwnerAction,
        guard: G,
        session: F::Session,
        snapshot: OwnerSnapshot,
    ) -> Result<OwnerPreview> {
        context.check()?;
        action.validate()?;
        context.check()?;
        if !snapshot_identity(&snapshot, &context.thread) {
            return Err(fail("scope_changed"));
        }
        if matches!(&action, OwnerAction::StartText(_)) && awaiting_human(&snapshot) {
            return Err(fail("awaiting_human"));
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
        capture: C,
    ) -> Result<OwnerActionStatus>
    where
        C: FnMut() -> U,
        U: std::future::Future<Output = Result<NativeOwnerContext>>,
    {
        self.confirm_controlled(
            preview_id,
            operation_id,
            expected_action_hash,
            capture,
            &Cancellation::default(),
        )
        .await
    }
    pub(crate) async fn confirm_controlled<C, U>(
        &mut self,
        preview_id: &str,
        operation_id: &str,
        expected_action_hash: &str,
        mut capture: C,
        cancel: &Cancellation,
    ) -> Result<OwnerActionStatus>
    where
        C: FnMut() -> U,
        U: std::future::Future<Output = Result<NativeOwnerContext>>,
    {
        if cancel.is_cancelled() {
            self.discard_preview(preview_id);
            return Err(fail("cancelled"));
        }
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
        if cancel.is_cancelled() {
            return Err(fail("cancelled"));
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
            .submit_controlled(
                &self.journal,
                &id,
                &attempt.preview.hash,
                &attempt.preview.action,
                cancel,
            )
            .await;
        let record = match outcome {
            Ok(r) if binding_matches(&r, &id, &attempt.preview) => r,
            _ => return Ok(unknown(&id)),
        };
        // A start acknowledgement cannot identify a pre-existing turn.
        if let JournalState::Accepted { turn_id } = &record.state {
            if matches!(attempt.preview.action, OwnerAction::StartText(_))
                && may_contain_turn(&attempt.preview.snapshot, turn_id)
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
    /// Background consent uses the same retained attempt and exact owner as
    /// manual actions. Only the accepted turn's final public answer escapes.
    pub(crate) async fn poll_reply<C, U>(
        &mut self,
        operation_id: &str,
        mut capture: C,
    ) -> Result<OwnerReplyPoll>
    where
        C: FnMut() -> U,
        U: std::future::Future<Output = Result<NativeOwnerContext>>,
    {
        if !uuid(operation_id) {
            return Err(fail("invalid_request"));
        }
        let id = operation_id.to_ascii_lowercase();
        let Some(attempt) = self.attempts.get_mut(&id) else {
            // A restart or a separately consumed receipt cannot recreate text.
            return Ok(OwnerReplyPoll::Uncertain);
        };
        let Some(record) = &attempt.record else {
            return Ok(OwnerReplyPoll::Uncertain);
        };
        let JournalState::Accepted { turn_id } = &record.state else {
            return Ok(OwnerReplyPoll::Uncertain);
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
        {
            return Err(fail("scope_changed"));
        }
        if awaiting_human(&snapshot) {
            return Ok(OwnerReplyPoll::AwaitingHuman);
        }
        if !idle(&snapshot) {
            return Ok(OwnerReplyPoll::Pending);
        }
        let outcome = match turn_status(&snapshot, turn_id) {
            Some("completed") => final_text(&snapshot, turn_id)
                .map(|text| OwnerReplyPoll::Reply {
                    turn_id: turn_id.clone(),
                    text,
                })
                .unwrap_or(OwnerReplyPoll::Unavailable),
            Some("failed") => OwnerReplyPoll::Failed,
            Some("interrupted") => OwnerReplyPoll::Interrupted,
            _ => return Ok(OwnerReplyPoll::Pending),
        };
        self.attempts.remove(&id);
        Ok(outcome)
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
