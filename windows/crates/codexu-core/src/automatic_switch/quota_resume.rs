//! Durable, at-most-once journal for resuming exact Desktop turns after an
//! automatic account switch. This module stores task identifiers only; it
//! never stores prompt content, credentials, or the supplied settings path.

use super::{Failure, Result};
use crate::accounts::storage;
use serde::{Deserialize, Serialize};
use std::path::{Component, Path, PathBuf};

const SCHEMA_VERSION: u32 = 1;
const MAX_ENTRIES: usize = 128;
const MAX_JOURNAL_BYTES: usize = 64 * 1024;

/// A non-secret account binding used only to fence a resume batch.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AccountIdentity {
    pub profile_id: String,
    pub identity_hash: String,
    pub credential_generation: String,
}

impl AccountIdentity {
    pub fn new(
        profile_id: impl Into<String>,
        identity_hash: impl Into<String>,
        credential_generation: impl Into<String>,
    ) -> Result<Self> {
        let value = Self {
            profile_id: profile_id.into(),
            identity_hash: identity_hash.into(),
            credential_generation: credential_generation.into(),
        };
        if !value.is_valid() {
            return Err(Failure::InvalidSettings);
        }
        Ok(value)
    }

    pub fn is_valid(&self) -> bool {
        lower_hex(&self.profile_id, 32)
            && lower_hex(&self.identity_hash, 64)
            && lower_hex(&self.credential_generation, 32)
    }

    pub fn profile_id(&self) -> &str {
        &self.profile_id
    }

    pub fn identity_hash(&self) -> &str {
        &self.identity_hash
    }

    pub fn credential_generation(&self) -> &str {
        &self.credential_generation
    }
}

/// The exact switch scope. `home_scope_hash` is caller-verified and is the
/// only Home representation stored by this journal.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResumeScope {
    pub source: AccountIdentity,
    pub target: AccountIdentity,
    pub home_scope_hash: String,
}

impl ResumeScope {
    pub fn new(
        source: AccountIdentity,
        target: AccountIdentity,
        home_scope_hash: impl Into<String>,
    ) -> Result<Self> {
        let value = Self {
            source,
            target,
            home_scope_hash: home_scope_hash.into(),
        };
        if !value.is_valid() {
            return Err(Failure::InvalidSettings);
        }
        Ok(value)
    }

    pub fn is_valid(&self) -> bool {
        self.source.is_valid() && self.target.is_valid() && lower_hex(&self.home_scope_hash, 64)
    }

    pub fn source(&self) -> &AccountIdentity {
        &self.source
    }

    pub fn target(&self) -> &AccountIdentity {
        &self.target
    }

    pub fn home_scope_hash(&self) -> &str {
        &self.home_scope_hash
    }
}

/// Exact opaque identifiers for one original Desktop turn.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct TurnRef {
    pub thread_id: String,
    pub turn_id: String,
}

impl TurnRef {
    pub fn new(thread_id: impl Into<String>, turn_id: impl Into<String>) -> Result<Self> {
        let value = Self {
            thread_id: thread_id.into(),
            turn_id: turn_id.into(),
        };
        if !value.is_valid() {
            return Err(Failure::InvalidSettings);
        }
        Ok(value)
    }

    pub fn is_valid(&self) -> bool {
        valid_task_id(&self.thread_id) && valid_task_id(&self.turn_id)
    }

    pub fn thread_id(&self) -> &str {
        &self.thread_id
    }

    pub fn turn_id(&self) -> &str {
        &self.turn_id
    }
}

/// Terminal states read from the exact original turn snapshot.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TerminalTurnStatus {
    Interrupted,
    Completed,
}

/// A caller-produced projection of a verified terminal snapshot. The journal
/// checks the exact IDs and status; an ACK alone cannot create this proof.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ExactTurnTerminalSnapshot {
    turn: TurnRef,
    status: TerminalTurnStatus,
}

impl ExactTurnTerminalSnapshot {
    pub fn new(turn: TurnRef, status: TerminalTurnStatus) -> Result<Self> {
        if !turn.is_valid() {
            return Err(Failure::InvalidSettings);
        }
        Ok(Self { turn, status })
    }

    pub fn turn(&self) -> &TurnRef {
        &self.turn
    }

    pub fn status(&self) -> TerminalTurnStatus {
        self.status
    }
}

/// Opaque batch fence. Only the explicitly named batch ID accessor exposes
/// its stable string representation for native recovery receipts.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct BatchToken([u8; 16]);

impl BatchToken {
    pub fn batch_id(&self) -> String {
        hex_bytes(&self.0)
    }
}

impl std::fmt::Debug for BatchToken {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("BatchToken([redacted])")
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QuotaResumeEntryState {
    Pending,
    InterruptAttempted,
    Interrupted,
    PauseUnknown,
    SkippedBeforeInterrupt,
    ResumeAttempted,
    Submitted,
    SkippedAlreadyChanged,
    ResumeUnknown,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QuotaResumeEntrySnapshot {
    turn: TurnRef,
    state: QuotaResumeEntryState,
    submitted_turn_id: Option<String>,
}

impl QuotaResumeEntrySnapshot {
    pub fn turn(&self) -> &TurnRef {
        &self.turn
    }

    pub fn state(&self) -> QuotaResumeEntryState {
        self.state
    }

    pub fn submitted_turn_id(&self) -> Option<&str> {
        self.submitted_turn_id.as_deref()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResumeBatchSnapshot {
    token: BatchToken,
    scope: ResumeScope,
    ready: bool,
    abandoned: bool,
    entries: Vec<QuotaResumeEntrySnapshot>,
}

impl ResumeBatchSnapshot {
    pub fn token(&self) -> BatchToken {
        self.token
    }

    pub fn batch_id(&self) -> String {
        self.token.batch_id()
    }

    pub fn scope(&self) -> &ResumeScope {
        &self.scope
    }

    pub fn ready(&self) -> bool {
        self.ready && !self.abandoned
    }

    pub fn abandoned(&self) -> bool {
        self.abandoned
    }

    pub fn entries(&self) -> &[QuotaResumeEntrySnapshot] {
        &self.entries
    }
}

/// Stores one current, fixed-size batch in a native private settings file.
/// The path is kept only in memory and is never serialized or logged.
#[derive(Clone)]
pub struct QuotaResumeJournal {
    path: PathBuf,
}

impl QuotaResumeJournal {
    pub fn new(path: impl Into<PathBuf>) -> Result<Self> {
        let path = path.into();
        if !path.is_absolute()
            || path.file_name().is_none()
            || path.parent().is_none()
            || path
                .components()
                .any(|component| matches!(component, Component::CurDir | Component::ParentDir))
        {
            return Err(Failure::InvalidSettings);
        }
        storage::ensure_no_links(&path).map_err(|_| Failure::RecoveryRequired)?;
        Ok(Self { path })
    }

    /// Saves the complete Pending batch before returning its one-shot token.
    pub fn stage_batch(&self, scope: ResumeScope, turns: Vec<TurnRef>) -> Result<BatchToken> {
        if !scope.is_valid() || !valid_batch_turns(&turns) {
            return Err(Failure::InvalidSettings);
        }
        self.mutate(|current| {
            if current.as_ref().is_some_and(has_unresolved_disk) {
                return Err(Failure::RecoveryRequired);
            }
            let token = fresh_token(current.as_ref())?;
            let next = DiskJournal {
                schema_version: SCHEMA_VERSION,
                token: token.batch_id(),
                scope: DiskResumeScope::from(&scope),
                ready: false,
                abandoned: false,
                entries: turns
                    .into_iter()
                    .map(|turn| DiskEntry {
                        turn: DiskTurnRef::from(&turn),
                        state: DiskEntryState::Pending,
                        submitted_turn_id: None,
                    })
                    .collect(),
            };
            Ok((next, token))
        })
    }

    /// Writes InterruptAttempted before the caller sends one interrupt.
    pub fn claim_interrupt(&self, token: &BatchToken, turn: &TurnRef) -> Result<()> {
        self.update_entry(token, turn, |ready, abandoned, entry| {
            if ready || abandoned || entry.state != DiskEntryState::Pending {
                return Err(Failure::RecoveryRequired);
            }
            entry.state = DiskEntryState::InterruptAttempted;
            Ok(())
        })
    }

    /// Records only a terminal snapshot for the exact original turn.
    pub fn record_interrupted(
        &self,
        token: &BatchToken,
        proof: &ExactTurnTerminalSnapshot,
    ) -> Result<()> {
        if proof.status != TerminalTurnStatus::Interrupted {
            return Err(Failure::RecoveryRequired);
        }
        self.update_entry(token, &proof.turn, |ready, abandoned, entry| {
            if ready || abandoned || entry.state != DiskEntryState::InterruptAttempted {
                return Err(Failure::RecoveryRequired);
            }
            entry.state = DiskEntryState::Interrupted;
            Ok(())
        })
    }

    /// Records an interrupt whose outcome could not be proven. This row stays
    /// unresolved until explicit abandonment and can never be retried.
    pub fn record_pause_unknown(&self, token: &BatchToken, turn: &TurnRef) -> Result<()> {
        self.update_entry(token, turn, |ready, abandoned, entry| {
            if ready || abandoned || entry.state != DiskEntryState::InterruptAttempted {
                return Err(Failure::RecoveryRequired);
            }
            entry.state = DiskEntryState::PauseUnknown;
            Ok(())
        })
    }

    /// Skips an exact original task that was already terminal before any
    /// interrupt attempt. No ACK or different turn ID is sufficient.
    pub fn skip_terminal_before_interrupt(
        &self,
        token: &BatchToken,
        proof: &ExactTurnTerminalSnapshot,
    ) -> Result<()> {
        self.update_entry(token, &proof.turn, |ready, abandoned, entry| {
            if ready || abandoned || entry.state != DiskEntryState::Pending {
                return Err(Failure::RecoveryRequired);
            }
            entry.state = DiskEntryState::SkippedBeforeInterrupt;
            Ok(())
        })
    }

    /// Enables resume only after the exact target binding and Home hash have
    /// been re-verified and every required pause has a terminal result.
    pub fn mark_resume_ready(
        &self,
        token: &BatchToken,
        verified_target: &AccountIdentity,
        verified_home_scope_hash: &str,
    ) -> Result<()> {
        self.mutate(|current| {
            let mut next = require_token(current, token)?;
            if next.abandoned {
                return Err(Failure::RecoveryRequired);
            }
            if !verified_target.is_valid()
                || next.scope.target != DiskAccountIdentity::from(verified_target)
                || next.scope.home_scope_hash != verified_home_scope_hash
            {
                return Err(Failure::IdentityChanged);
            }
            if next.entries.iter().any(|entry| {
                !matches!(
                    entry.state,
                    DiskEntryState::Interrupted | DiskEntryState::SkippedBeforeInterrupt
                )
            }) {
                return Err(Failure::RecoveryRequired);
            }
            next.ready = true;
            Ok((next, ()))
        })
    }

    /// A verified account transaction may rotate the target credential. Only
    /// the still-held native maintenance lease can bind that new generation;
    /// source identity, target identity, Home and exact batch stay fixed.
    pub fn mark_resume_ready_after_guarded_switch(
        &self,
        token: &BatchToken,
        target: &crate::accounts::ActiveSystemScope,
        lease: &crate::managed_proxy::AutomaticMaintenanceLease,
        home_scope_hash: &str,
    ) -> Result<()> {
        lease.recheck().map_err(|_| Failure::AccountBusy)?;
        let current = AccountIdentity::new(
            target.profile_id(),
            target.identity_hash(),
            target.credential_generation(),
        )?;
        self.mutate(|saved| {
            let mut next = require_token(saved, token)?;
            lease.recheck_cached().map_err(|_| Failure::AccountBusy)?;
            if next.ready
                || next.abandoned
                || next.scope.home_scope_hash != home_scope_hash
                || lease.source_scope().canonical_home() != target.canonical_home()
                || next.scope.source.profile_id != lease.source_profile_id()
                || next.scope.source.identity_hash != lease.source_identity_hash()
                || next.scope.source.credential_generation != lease.source_credential_generation()
                || next.scope.target.profile_id != lease.target_profile_id()
                || next.scope.target.identity_hash != lease.target_identity_hash()
                || next.scope.target.profile_id != current.profile_id
                || next.scope.target.identity_hash != current.identity_hash
            {
                return Err(Failure::IdentityChanged);
            }
            if next.entries.iter().any(|entry| {
                !matches!(
                    entry.state,
                    DiskEntryState::Interrupted | DiskEntryState::SkippedBeforeInterrupt
                )
            }) {
                return Err(Failure::RecoveryRequired);
            }
            next.scope.target = DiskAccountIdentity::from(&current);
            next.ready = true;
            Ok((next, ()))
        })
    }

    /// Writes ResumeAttempted before the caller starts the original thread.
    pub fn claim_resume(&self, token: &BatchToken, turn: &TurnRef) -> Result<()> {
        self.update_entry(token, turn, |ready, abandoned, entry| {
            if !ready || abandoned || entry.state != DiskEntryState::Interrupted {
                return Err(Failure::RecoveryRequired);
            }
            entry.state = DiskEntryState::ResumeAttempted;
            Ok(())
        })
    }

    pub fn record_submitted(
        &self,
        token: &BatchToken,
        turn: &TurnRef,
        new_turn_id: &str,
    ) -> Result<()> {
        if !valid_task_id(new_turn_id) || new_turn_id == turn.turn_id {
            return Err(Failure::InvalidSettings);
        }
        self.update_entry(token, turn, |ready, abandoned, entry| {
            if !ready || abandoned || entry.state != DiskEntryState::ResumeAttempted {
                return Err(Failure::RecoveryRequired);
            }
            entry.state = DiskEntryState::Submitted;
            entry.submitted_turn_id = Some(new_turn_id.to_owned());
            Ok(())
        })
    }

    /// Marks a still-unattempted interrupted row skipped. The caller must
    /// first verify from a fresh exact snapshot that the original thread has
    /// already changed or completed.
    pub fn record_resume_skipped(&self, token: &BatchToken, turn: &TurnRef) -> Result<()> {
        self.update_entry(token, turn, |ready, abandoned, entry| {
            if !ready || abandoned || entry.state != DiskEntryState::Interrupted {
                return Err(Failure::RecoveryRequired);
            }
            entry.state = DiskEntryState::SkippedAlreadyChanged;
            Ok(())
        })
    }

    /// Records an unconfirmed result after ResumeAttempted. It is never made
    /// pending again after process restart.
    pub fn record_resume_unknown(&self, token: &BatchToken, turn: &TurnRef) -> Result<()> {
        self.update_entry(token, turn, |ready, abandoned, entry| {
            if !ready || abandoned || entry.state != DiskEntryState::ResumeAttempted {
                return Err(Failure::RecoveryRequired);
            }
            entry.state = DiskEntryState::ResumeUnknown;
            Ok(())
        })
    }

    /// Closes this journal's recovery gate without claiming task completion
    /// or releasing any external owner action or gate reservation.
    pub fn abandon(&self, token: &BatchToken) -> Result<()> {
        self.mutate(|current| {
            let mut next = require_token(current, token)?;
            if !has_unresolved_disk(&next) {
                return Err(Failure::RecoveryRequired);
            }
            next.ready = false;
            next.abandoned = true;
            Ok((next, ()))
        })
    }

    /// Returns the durable batch, token, scope, and every row for explicit
    /// recovery or status after restart.
    pub fn current_batch(&self) -> Result<Option<ResumeBatchSnapshot>> {
        let _lock = self.lock()?;
        self.read_disk()?.map(|disk| snapshot(disk)).transpose()
    }

    /// Storage uncertainty blocks all automatic sources, including a different
    /// source account. Read/lock failures therefore return `true`.
    pub fn has_unresolved(&self) -> bool {
        match self.current_batch() {
            Ok(Some(batch)) if !batch.abandoned => batch
                .entries
                .iter()
                .any(|entry| !disk_entry_state_is_terminal(entry.state.into())),
            Ok(_) => false,
            Err(_) => true,
        }
    }

    fn update_entry(
        &self,
        token: &BatchToken,
        turn: &TurnRef,
        transition: impl FnOnce(bool, bool, &mut DiskEntry) -> Result<()>,
    ) -> Result<()> {
        if !turn.is_valid() {
            return Err(Failure::InvalidSettings);
        }
        self.mutate(|current| {
            let mut next = require_token(current, token)?;
            let index = next
                .entries
                .iter()
                .position(|entry| {
                    entry.turn.thread_id == turn.thread_id && entry.turn.turn_id == turn.turn_id
                })
                .ok_or(Failure::RecoveryRequired)?;
            let ready = next.ready;
            let abandoned = next.abandoned;
            transition(ready, abandoned, &mut next.entries[index])?;
            Ok((next, ()))
        })
    }

    fn mutate<T>(
        &self,
        change: impl FnOnce(Option<DiskJournal>) -> Result<(DiskJournal, T)>,
    ) -> Result<T> {
        self.mutate_with(change, storage::atomic_write)
    }

    fn mutate_with<T>(
        &self,
        change: impl FnOnce(Option<DiskJournal>) -> Result<(DiskJournal, T)>,
        writer: impl FnOnce(&Path, &[u8]) -> crate::accounts::AccountResult<()>,
    ) -> Result<T> {
        let _lock = self.lock()?;
        let current = self.read_disk()?;
        let (next, result) = change(current)?;
        validate_disk(&next)?;
        let bytes = serde_json::to_vec(&next).map_err(|_| Failure::SaveFailed)?;
        if bytes.len() > MAX_JOURNAL_BYTES {
            return Err(Failure::SaveFailed);
        }
        writer(&self.path, &bytes).map_err(|_| Failure::SaveFailed)?;
        let readback = storage::read_bound_optional(&self.path, MAX_JOURNAL_BYTES, true)
            .map_err(|_| Failure::RecoveryRequired)?
            .ok_or(Failure::RecoveryRequired)?;
        if readback != bytes {
            return Err(Failure::RecoveryRequired);
        }
        let checked: DiskJournal =
            serde_json::from_slice(&readback).map_err(|_| Failure::RecoveryRequired)?;
        validate_disk(&checked)?;
        Ok(result)
    }

    fn lock(&self) -> Result<storage::StoreLock> {
        let root = self.path.parent().ok_or(Failure::InvalidSettings)?;
        storage::StoreLock::acquire(root).map_err(|_| Failure::RecoveryRequired)
    }

    fn read_disk(&self) -> Result<Option<DiskJournal>> {
        let Some(bytes) = storage::read_bound_optional(&self.path, MAX_JOURNAL_BYTES, true)
            .map_err(|_| Failure::RecoveryRequired)?
        else {
            return Ok(None);
        };
        let disk: DiskJournal =
            serde_json::from_slice(&bytes).map_err(|_| Failure::RecoveryRequired)?;
        validate_disk(&disk)?;
        Ok(Some(disk))
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct DiskJournal {
    schema_version: u32,
    token: String,
    scope: DiskResumeScope,
    ready: bool,
    abandoned: bool,
    entries: Vec<DiskEntry>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct DiskResumeScope {
    source: DiskAccountIdentity,
    target: DiskAccountIdentity,
    home_scope_hash: String,
}

impl From<&ResumeScope> for DiskResumeScope {
    fn from(value: &ResumeScope) -> Self {
        Self {
            source: DiskAccountIdentity::from(&value.source),
            target: DiskAccountIdentity::from(&value.target),
            home_scope_hash: value.home_scope_hash.clone(),
        }
    }
}

impl TryFrom<&DiskResumeScope> for ResumeScope {
    type Error = Failure;

    fn try_from(value: &DiskResumeScope) -> Result<Self> {
        ResumeScope::new(
            AccountIdentity::new(
                value.source.profile_id.clone(),
                value.source.identity_hash.clone(),
                value.source.credential_generation.clone(),
            )?,
            AccountIdentity::new(
                value.target.profile_id.clone(),
                value.target.identity_hash.clone(),
                value.target.credential_generation.clone(),
            )?,
            value.home_scope_hash.clone(),
        )
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct DiskAccountIdentity {
    profile_id: String,
    identity_hash: String,
    credential_generation: String,
}

impl From<&AccountIdentity> for DiskAccountIdentity {
    fn from(value: &AccountIdentity) -> Self {
        Self {
            profile_id: value.profile_id.clone(),
            identity_hash: value.identity_hash.clone(),
            credential_generation: value.credential_generation.clone(),
        }
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct DiskEntry {
    turn: DiskTurnRef,
    state: DiskEntryState,
    submitted_turn_id: Option<String>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct DiskTurnRef {
    thread_id: String,
    turn_id: String,
}

impl From<&TurnRef> for DiskTurnRef {
    fn from(value: &TurnRef) -> Self {
        Self {
            thread_id: value.thread_id.clone(),
            turn_id: value.turn_id.clone(),
        }
    }
}

impl TryFrom<&DiskTurnRef> for TurnRef {
    type Error = Failure;

    fn try_from(value: &DiskTurnRef) -> Result<Self> {
        TurnRef::new(value.thread_id.clone(), value.turn_id.clone())
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum DiskEntryState {
    Pending,
    InterruptAttempted,
    Interrupted,
    PauseUnknown,
    SkippedBeforeInterrupt,
    ResumeAttempted,
    Submitted,
    SkippedAlreadyChanged,
    ResumeUnknown,
}

impl From<QuotaResumeEntryState> for DiskEntryState {
    fn from(value: QuotaResumeEntryState) -> Self {
        match value {
            QuotaResumeEntryState::Pending => Self::Pending,
            QuotaResumeEntryState::InterruptAttempted => Self::InterruptAttempted,
            QuotaResumeEntryState::Interrupted => Self::Interrupted,
            QuotaResumeEntryState::PauseUnknown => Self::PauseUnknown,
            QuotaResumeEntryState::SkippedBeforeInterrupt => Self::SkippedBeforeInterrupt,
            QuotaResumeEntryState::ResumeAttempted => Self::ResumeAttempted,
            QuotaResumeEntryState::Submitted => Self::Submitted,
            QuotaResumeEntryState::SkippedAlreadyChanged => Self::SkippedAlreadyChanged,
            QuotaResumeEntryState::ResumeUnknown => Self::ResumeUnknown,
        }
    }
}

impl From<DiskEntryState> for QuotaResumeEntryState {
    fn from(value: DiskEntryState) -> Self {
        match value {
            DiskEntryState::Pending => Self::Pending,
            DiskEntryState::InterruptAttempted => Self::InterruptAttempted,
            DiskEntryState::Interrupted => Self::Interrupted,
            DiskEntryState::PauseUnknown => Self::PauseUnknown,
            DiskEntryState::SkippedBeforeInterrupt => Self::SkippedBeforeInterrupt,
            DiskEntryState::ResumeAttempted => Self::ResumeAttempted,
            DiskEntryState::Submitted => Self::Submitted,
            DiskEntryState::SkippedAlreadyChanged => Self::SkippedAlreadyChanged,
            DiskEntryState::ResumeUnknown => Self::ResumeUnknown,
        }
    }
}

fn snapshot(disk: DiskJournal) -> Result<ResumeBatchSnapshot> {
    let token = token_from_string(&disk.token).ok_or(Failure::RecoveryRequired)?;
    let scope = ResumeScope::try_from(&disk.scope)?;
    Ok(ResumeBatchSnapshot {
        token,
        scope,
        ready: disk.ready,
        abandoned: disk.abandoned,
        entries: disk
            .entries
            .into_iter()
            .map(|entry| {
                Ok(QuotaResumeEntrySnapshot {
                    turn: TurnRef::try_from(&entry.turn)?,
                    state: entry.state.into(),
                    submitted_turn_id: entry.submitted_turn_id,
                })
            })
            .collect::<Result<Vec<_>>>()?,
    })
}

fn require_token(current: Option<DiskJournal>, token: &BatchToken) -> Result<DiskJournal> {
    let current = current.ok_or(Failure::RecoveryRequired)?;
    if current.token != token.batch_id() {
        return Err(Failure::RecoveryRequired);
    }
    Ok(current)
}

fn fresh_token(current: Option<&DiskJournal>) -> Result<BatchToken> {
    for _ in 0..4 {
        let mut bytes = [0u8; 16];
        getrandom::fill(&mut bytes).map_err(|_| Failure::Unavailable)?;
        let candidate = BatchToken(bytes);
        if !current.is_some_and(|disk| disk.token == candidate.batch_id()) {
            return Ok(candidate);
        }
    }
    Err(Failure::Unavailable)
}

fn token_from_string(value: &str) -> Option<BatchToken> {
    if !lower_hex(value, 32) {
        return None;
    }
    let mut bytes = [0u8; 16];
    for (index, byte) in bytes.iter_mut().enumerate() {
        let offset = index * 2;
        *byte = u8::from_str_radix(&value[offset..offset + 2], 16).ok()?;
    }
    Some(BatchToken(bytes))
}

fn validate_disk(disk: &DiskJournal) -> Result<()> {
    let scope = ResumeScope::try_from(&disk.scope).map_err(|_| Failure::RecoveryRequired)?;
    if disk.schema_version != SCHEMA_VERSION
        || !scope.is_valid()
        || !lower_hex(&disk.token, 32)
        || disk.entries.is_empty()
        || disk.entries.len() > MAX_ENTRIES
        || disk.abandoned && disk.ready
    {
        return Err(Failure::RecoveryRequired);
    }
    let mut threads = std::collections::HashSet::new();
    for entry in &disk.entries {
        if TurnRef::try_from(&entry.turn).is_err() || !threads.insert(entry.turn.thread_id.as_str())
        {
            return Err(Failure::RecoveryRequired);
        }
        if (entry.state == DiskEntryState::Submitted)
            != entry
                .submitted_turn_id
                .as_deref()
                .is_some_and(valid_task_id)
            || (entry.state != DiskEntryState::Submitted && entry.submitted_turn_id.is_some())
        {
            return Err(Failure::RecoveryRequired);
        }
        if disk.ready
            && !matches!(
                entry.state,
                DiskEntryState::Interrupted
                    | DiskEntryState::SkippedBeforeInterrupt
                    | DiskEntryState::ResumeAttempted
                    | DiskEntryState::Submitted
                    | DiskEntryState::SkippedAlreadyChanged
                    | DiskEntryState::ResumeUnknown
            )
        {
            return Err(Failure::RecoveryRequired);
        }
        if !disk.ready
            && !disk.abandoned
            && matches!(
                entry.state,
                DiskEntryState::ResumeAttempted
                    | DiskEntryState::Submitted
                    | DiskEntryState::SkippedAlreadyChanged
                    | DiskEntryState::ResumeUnknown
            )
        {
            return Err(Failure::RecoveryRequired);
        }
    }
    Ok(())
}

fn valid_batch_turns(turns: &[TurnRef]) -> bool {
    if turns.is_empty() || turns.len() > MAX_ENTRIES {
        return false;
    }
    let mut threads = std::collections::HashSet::new();
    turns
        .iter()
        .all(|turn| turn.is_valid() && threads.insert(turn.thread_id.as_str()))
}

fn has_unresolved_disk(disk: &DiskJournal) -> bool {
    !disk.abandoned
        && disk
            .entries
            .iter()
            .any(|entry| !disk_entry_state_is_terminal(entry.state))
}

fn disk_entry_state_is_terminal(state: DiskEntryState) -> bool {
    matches!(
        state,
        DiskEntryState::SkippedBeforeInterrupt
            | DiskEntryState::Submitted
            | DiskEntryState::SkippedAlreadyChanged
    )
}

fn lower_hex(value: &str, bytes: usize) -> bool {
    value.len() == bytes
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn valid_task_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
}

fn hex_bytes(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(HEX[(byte >> 4) as usize] as char);
        output.push(HEX[(byte & 0x0f) as usize] as char);
    }
    output
}

#[cfg(test)]
#[path = "quota_resume/tests.rs"]
mod tests;
