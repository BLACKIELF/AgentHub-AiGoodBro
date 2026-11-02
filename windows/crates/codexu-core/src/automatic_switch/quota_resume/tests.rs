use super::*;
use std::{
    path::PathBuf,
    sync::{Arc, Barrier},
    thread,
};
use tempfile::TempDir;

fn identity(profile: char, hash: char, generation: char) -> AccountIdentity {
    AccountIdentity::new(
        profile.to_string().repeat(32),
        hash.to_string().repeat(64),
        generation.to_string().repeat(32),
    )
    .unwrap()
}

fn scope() -> ResumeScope {
    ResumeScope::new(
        identity('a', 'b', 'c'),
        identity('d', 'e', 'f'),
        "1".repeat(64),
    )
    .unwrap()
}

fn turn(n: usize) -> TurnRef {
    TurnRef::new(format!("thread-{n}"), format!("turn-{n}")).unwrap()
}

fn fixture() -> (TempDir, PathBuf, QuotaResumeJournal, ResumeScope) {
    let temp = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(temp.path()).unwrap();
    let path = root.join("quota-resume-v1.json");
    let journal = QuotaResumeJournal::new(path.clone()).unwrap();
    (temp, path, journal, scope())
}

fn interrupted(turn: &TurnRef) -> ExactTurnTerminalSnapshot {
    ExactTurnTerminalSnapshot::new(turn.clone(), TerminalTurnStatus::Interrupted).unwrap()
}

fn complete(turn: &TurnRef) -> ExactTurnTerminalSnapshot {
    ExactTurnTerminalSnapshot::new(turn.clone(), TerminalTurnStatus::Completed).unwrap()
}

#[test]
fn restart_never_retries_interrupt_or_resume_attempts() {
    let (_temp, path, journal, scope) = fixture();
    let original = turn(1);
    let token = journal
        .stage_batch(scope.clone(), vec![original.clone()])
        .unwrap();

    journal.claim_interrupt(&token, &original).unwrap();
    let reopened = QuotaResumeJournal::new(path.clone()).unwrap();
    assert_eq!(reopened.current_batch().unwrap().unwrap().token(), token);
    assert_eq!(
        reopened.claim_interrupt(&token, &original),
        Err(Failure::RecoveryRequired)
    );
    assert_eq!(
        reopened.current_batch().unwrap().unwrap().entries()[0].state(),
        QuotaResumeEntryState::InterruptAttempted
    );

    reopened
        .record_interrupted(&token, &interrupted(&original))
        .unwrap();
    reopened
        .mark_resume_ready(&token, &scope.target, &scope.home_scope_hash)
        .unwrap();
    reopened.claim_resume(&token, &original).unwrap();

    let after_resume_attempt = QuotaResumeJournal::new(path).unwrap();
    assert_eq!(
        after_resume_attempt.claim_resume(&token, &original),
        Err(Failure::RecoveryRequired)
    );
    assert_eq!(
        after_resume_attempt
            .current_batch()
            .unwrap()
            .unwrap()
            .entries()[0]
            .state(),
        QuotaResumeEntryState::ResumeAttempted
    );
}

#[test]
fn unknown_resume_stays_unresolved_until_explicit_abandonment() {
    let (_temp, _path, journal, scope) = fixture();
    let original = turn(1);
    let token = journal
        .stage_batch(scope.clone(), vec![original.clone()])
        .unwrap();
    journal.claim_interrupt(&token, &original).unwrap();
    journal
        .record_interrupted(&token, &interrupted(&original))
        .unwrap();
    journal
        .mark_resume_ready(&token, &scope.target, &scope.home_scope_hash)
        .unwrap();
    journal.claim_resume(&token, &original).unwrap();
    journal.record_resume_unknown(&token, &original).unwrap();

    let reopened = QuotaResumeJournal::new(journal.path.clone()).unwrap();
    assert!(reopened.has_unresolved());
    assert_eq!(
        reopened.claim_resume(&token, &original),
        Err(Failure::RecoveryRequired)
    );
    let other_scope = ResumeScope::new(
        identity('9', '8', '7'),
        scope.target.clone(),
        scope.home_scope_hash.clone(),
    )
    .unwrap();
    assert_eq!(
        reopened.stage_batch(other_scope.clone(), vec![turn(2)]),
        Err(Failure::RecoveryRequired)
    );

    reopened.abandon(&token).unwrap();
    assert!(!reopened.has_unresolved());
    let snapshot = reopened.current_batch().unwrap().unwrap();
    assert!(snapshot.abandoned());
    assert_eq!(
        snapshot.entries()[0].state(),
        QuotaResumeEntryState::ResumeUnknown
    );
    let replacement = reopened.stage_batch(other_scope, vec![turn(2)]).unwrap();
    assert_ne!(replacement.batch_id(), token.batch_id());
    assert_eq!(
        reopened.claim_interrupt(&token, &turn(1)),
        Err(Failure::RecoveryRequired)
    );
}

#[test]
fn partial_pause_and_unverified_switch_keep_the_batch_blocking() {
    let (_temp, _path, journal, scope) = fixture();
    let first = turn(1);
    let second = turn(2);
    let token = journal
        .stage_batch(scope.clone(), vec![first.clone(), second.clone()])
        .unwrap();
    journal.claim_interrupt(&token, &first).unwrap();
    journal
        .record_interrupted(&token, &interrupted(&first))
        .unwrap();
    journal.claim_interrupt(&token, &second).unwrap();
    journal.record_pause_unknown(&token, &second).unwrap();

    assert_eq!(
        journal.mark_resume_ready(&token, &scope.target, &scope.home_scope_hash),
        Err(Failure::RecoveryRequired)
    );
    assert!(journal.has_unresolved());
    let different_source = ResumeScope::new(
        identity('9', '8', '7'),
        scope.target.clone(),
        scope.home_scope_hash.clone(),
    )
    .unwrap();
    assert_eq!(
        journal.stage_batch(different_source, vec![turn(3)]),
        Err(Failure::RecoveryRequired)
    );
    let entries = journal.current_batch().unwrap().unwrap();
    assert_eq!(
        entries.entries()[0].state(),
        QuotaResumeEntryState::Interrupted
    );
    assert_eq!(
        entries.entries()[1].state(),
        QuotaResumeEntryState::PauseUnknown
    );

    // Even a fully paused batch blocks replacement until the switch is verified
    // or the caller explicitly abandons the recovery record.
    let (_temp2, _path2, journal2, scope2) = fixture();
    let only = turn(4);
    let token2 = journal2
        .stage_batch(scope2.clone(), vec![only.clone()])
        .unwrap();
    journal2.claim_interrupt(&token2, &only).unwrap();
    journal2
        .record_interrupted(&token2, &interrupted(&only))
        .unwrap();
    assert_eq!(
        journal2.stage_batch(scope2, vec![turn(5)]),
        Err(Failure::RecoveryRequired)
    );
}

#[test]
fn missing_corrupt_and_save_failed_storage_fail_closed() {
    let (_temp, path, journal, scope) = fixture();
    assert_eq!(journal.current_batch().unwrap(), None);
    assert!(!journal.has_unresolved());

    crate::accounts::storage::atomic_write(&path, b"{corrupt").unwrap();
    assert_eq!(journal.current_batch(), Err(Failure::RecoveryRequired));
    assert!(journal.has_unresolved());

    std::fs::remove_file(&path).unwrap();
    let token = journal.stage_batch(scope, vec![turn(1)]).unwrap();
    assert_eq!(token.batch_id().len(), 32);
    let before = std::fs::read(&path).unwrap();
    let result = journal.mutate_with(
        |current| {
            let mut next = current.ok_or(Failure::RecoveryRequired)?;
            next.entries[0].state = DiskEntryState::InterruptAttempted;
            Ok((next, ()))
        },
        |_path, _bytes| Err(crate::accounts::fail("account_save_failed")),
    );
    assert_eq!(result, Err(Failure::SaveFailed));
    assert_eq!(std::fs::read(&path).unwrap(), before);
    assert_eq!(
        QuotaResumeJournal::new(path)
            .unwrap()
            .current_batch()
            .unwrap()
            .unwrap()
            .entries()[0]
            .state(),
        QuotaResumeEntryState::Pending
    );
}

#[test]
fn duplicate_or_oversized_batches_are_rejected_before_staging() {
    let (_temp, _path, journal, scope) = fixture();
    let duplicate_thread = TurnRef::new("thread-1", "another-turn").unwrap();
    assert_eq!(
        journal.stage_batch(scope.clone(), vec![turn(1), duplicate_thread]),
        Err(Failure::InvalidSettings)
    );
    let oversized = (0..=MAX_ENTRIES).map(turn).collect();
    assert_eq!(
        journal.stage_batch(scope, oversized),
        Err(Failure::InvalidSettings)
    );
    assert_eq!(journal.current_batch().unwrap(), None);
}

#[test]
fn token_turn_and_target_mismatches_do_not_change_the_journal() {
    let (_temp, _path, journal, scope) = fixture();
    let original = turn(1);
    let token = journal
        .stage_batch(scope.clone(), vec![original.clone()])
        .unwrap();
    let wrong_token = BatchToken([9; 16]);
    assert_eq!(
        journal.claim_interrupt(&wrong_token, &original),
        Err(Failure::RecoveryRequired)
    );
    assert_eq!(
        journal.claim_interrupt(&token, &turn(2)),
        Err(Failure::RecoveryRequired)
    );
    journal.claim_interrupt(&token, &original).unwrap();
    assert_eq!(
        journal.record_interrupted(&token, &complete(&original)),
        Err(Failure::RecoveryRequired)
    );
    journal
        .record_interrupted(&token, &interrupted(&original))
        .unwrap();
    let wrong_target = identity('9', '8', '7');
    assert_eq!(
        journal.mark_resume_ready(&token, &wrong_target, &scope.home_scope_hash),
        Err(Failure::IdentityChanged)
    );
    assert_eq!(
        journal.mark_resume_ready(&token, &scope.target, &"2".repeat(64)),
        Err(Failure::IdentityChanged)
    );
    assert_eq!(
        journal.current_batch().unwrap().unwrap().entries()[0].state(),
        QuotaResumeEntryState::Interrupted
    );
    journal
        .mark_resume_ready(&token, &scope.target, &scope.home_scope_hash)
        .unwrap();
}

#[test]
fn already_terminal_before_interrupt_is_skipped_without_resume() {
    let (_temp, _path, journal, scope) = fixture();
    let original = turn(1);
    let token = journal
        .stage_batch(scope.clone(), vec![original.clone()])
        .unwrap();
    journal
        .skip_terminal_before_interrupt(&token, &complete(&original))
        .unwrap();
    journal
        .mark_resume_ready(&token, &scope.target, &scope.home_scope_hash)
        .unwrap();
    assert!(!journal.has_unresolved());
    assert_eq!(
        journal.claim_resume(&token, &original),
        Err(Failure::RecoveryRequired)
    );
}

#[test]
fn already_changed_thread_is_skipped_without_claiming_a_new_resume() {
    let (_temp, _path, journal, scope) = fixture();
    let original = turn(1);
    let token = journal
        .stage_batch(scope.clone(), vec![original.clone()])
        .unwrap();
    journal.claim_interrupt(&token, &original).unwrap();
    journal
        .record_interrupted(&token, &interrupted(&original))
        .unwrap();
    journal
        .mark_resume_ready(&token, &scope.target, &scope.home_scope_hash)
        .unwrap();
    journal.record_resume_skipped(&token, &original).unwrap();

    assert!(!journal.has_unresolved());
    assert_eq!(
        journal.current_batch().unwrap().unwrap().entries()[0].state(),
        QuotaResumeEntryState::SkippedAlreadyChanged
    );
    assert_eq!(
        journal.claim_resume(&token, &original),
        Err(Failure::RecoveryRequired)
    );
}

#[test]
fn concurrent_claims_allow_only_one_interrupt_attempt() {
    let (_temp, path, journal, scope) = fixture();
    let turn = turn(1);
    let token = journal.stage_batch(scope, vec![turn.clone()]).unwrap();
    let other = journal.clone();
    let barrier = Arc::new(Barrier::new(3));
    let first_barrier = Arc::clone(&barrier);
    let second_barrier = Arc::clone(&barrier);
    let first_turn = turn.clone();
    let second_turn = turn.clone();
    let first = thread::spawn(move || {
        first_barrier.wait();
        journal.claim_interrupt(&token, &first_turn)
    });
    let second = thread::spawn(move || {
        second_barrier.wait();
        other.claim_interrupt(&token, &second_turn)
    });
    barrier.wait();
    let results = [first.join().unwrap(), second.join().unwrap()];
    assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
    assert_eq!(
        QuotaResumeJournal::new(path)
            .unwrap()
            .current_batch()
            .unwrap()
            .unwrap()
            .entries()[0]
            .state(),
        QuotaResumeEntryState::InterruptAttempted
    );
}
