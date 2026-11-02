use super::*;

fn owner_snapshot() -> WorkbenchSnapshot {
    use codexu_core::task_workbench::{Outcome, WorkbenchItem};
    WorkbenchSnapshot {
        scope_id: "a".repeat(64),
        checked_at_ms: 1,
        source_available: true,
        truncated: false,
        items: vec![WorkbenchItem {
            thread_id: "12345678-1234-1234-1234-123456789abc".into(),
            title: "Synthetic local thread".into(),
            project: "Synthetic".into(),
            updated_at_ms: Some(10),
            archived: false,
            execution_state: "recorded",
            outcome: Outcome::Unknown,
            decision: Decision::None,
            decision_at_ms: None,
            inventory_is_stale: false,
            needs_attention: false,
            inventory: None,
        }],
    }
}

#[test]
fn owner_context_metadata_rejects_changed_scope_missing_archived_or_duplicate_thread() {
    let mut snapshot = owner_snapshot();
    let thread = snapshot.items[0].thread_id.clone();
    assert!(owner_metadata_digest(&snapshot, &"b".repeat(64), &thread).is_err());
    snapshot.source_available = false;
    assert!(owner_metadata_digest(&snapshot, &snapshot.scope_id, &thread).is_err());
    snapshot.source_available = true;
    snapshot.items[0].archived = true;
    assert!(owner_metadata_digest(&snapshot, &snapshot.scope_id, &thread).is_err());
    snapshot.items[0].archived = false;
    assert!(owner_metadata_digest(
        &snapshot,
        &snapshot.scope_id,
        "22345678-1234-1234-1234-123456789abc"
    )
    .is_err());
    snapshot.items.push(owner_snapshot().items.remove(0));
    assert!(owner_metadata_digest(&snapshot, &snapshot.scope_id, &thread).is_err());
}

#[test]
fn owner_context_metadata_binds_actual_record_but_not_read_clock() {
    let mut snapshot = owner_snapshot();
    let thread = snapshot.items[0].thread_id.clone();
    let original = owner_metadata_digest(&snapshot, &snapshot.scope_id, &thread).unwrap();
    snapshot.checked_at_ms = 100;
    assert_eq!(
        owner_metadata_digest(&snapshot, &snapshot.scope_id, &thread).unwrap(),
        original
    );
    snapshot.items[0].updated_at_ms = Some(11);
    assert_ne!(
        owner_metadata_digest(&snapshot, &snapshot.scope_id, &thread).unwrap(),
        original
    );
    snapshot.items[0].updated_at_ms = Some(10);
    snapshot.items[0].decision = Decision::Paused;
    assert_ne!(
        owner_metadata_digest(&snapshot, &snapshot.scope_id, &thread).unwrap(),
        original
    );
}

fn fixture() -> (tempfile::TempDir, AppState) {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().canonicalize().unwrap();
    let data = root.join("app-data");
    let source = root.join("codex-source");
    std::fs::create_dir(&data).unwrap();
    std::fs::create_dir(&source).unwrap();
    let state = AppState::new(data);
    state.config.blocking_write().codex_root = source;
    (temp, state)
}

#[test]
fn close_epoch_recheck_catches_prepare_paused_after_old_epoch_check() {
    use std::{
        sync::{mpsc, Arc},
        thread,
        time::Duration,
    };

    let (_temp, state) = fixture();
    let state = Arc::new(state);
    let preview_id = "11111111-1111-1111-1111-111111111111".to_owned();
    let (checked_tx, checked_rx) = mpsc::channel();
    let (continue_tx, continue_rx) = mpsc::channel();
    let (registered_tx, registered_rx) = mpsc::channel();
    let (closed_tx, closed_rx) = mpsc::channel();
    let register_state = state.clone();
    let register = thread::spawn(move || {
        let result =
            remember_owner_preview_after_epoch_check(&register_state, &preview_id, 0, || {
                checked_tx.send(()).unwrap();
                let _ = continue_rx.recv_timeout(Duration::from_secs(2));
            });
        registered_tx.send(result).unwrap();
    });
    let checked = checked_rx.recv_timeout(Duration::from_secs(1));
    let close_state = state.clone();
    let close = thread::spawn(move || {
        closed_tx.send(close_state.close_owner_window()).unwrap();
    });
    let close_early = closed_rx.recv_timeout(Duration::from_millis(100));
    let _ = continue_tx.send(());
    let closed_previews = match close_early {
        Ok(ids) => Ok(ids),
        Err(mpsc::RecvTimeoutError::Timeout) => closed_rx.recv_timeout(Duration::from_secs(2)),
        Err(error) => Err(error),
    };
    let registered = registered_rx.recv_timeout(Duration::from_secs(2));
    let closed_previews = closed_previews.expect("close did not complete within the bounded wait");
    let registered =
        registered.expect("late registration did not complete within the bounded wait");
    register.join().unwrap();
    close.join().unwrap();

    assert!(
        checked.is_ok(),
        "prepare did not reach the pre-lock barrier"
    );
    assert!(closed_previews.is_empty());
    assert_eq!(registered.unwrap_err(), "owner_window_closed");
    assert!(state.owner_preview_epochs.lock().unwrap().is_empty());
}

#[test]
fn late_close_cleanup_discards_only_old_epoch_previews() {
    use std::collections::BTreeSet;

    let (_temp, state) = fixture();
    let old_id = "11111111-1111-1111-1111-111111111111";
    let new_id = "22222222-2222-2222-2222-222222222222";
    remember_owner_preview(&state, old_id, 0).unwrap();

    let closed_previews = state.close_owner_window();
    assert_eq!(closed_previews, [old_id.to_owned()]);
    let new_epoch = state
        .owner_window_epoch
        .load(std::sync::atomic::Ordering::Acquire);
    remember_owner_preview(&state, new_id, new_epoch).unwrap();

    // Model the asynchronous OwnerActions cleanup after the window is reopened.
    let mut service_previews = BTreeSet::from([old_id.to_owned(), new_id.to_owned()]);
    discard_closed_preview_ids(&closed_previews, |preview_id| {
        service_previews.remove(preview_id);
    });
    assert_eq!(service_previews, BTreeSet::from([new_id.to_owned()]));
    assert_eq!(
        state.owner_preview_epochs.lock().unwrap().get(new_id),
        Some(&new_epoch)
    );
}

#[test]
fn workbench_scope_is_bound_before_any_local_mutation() {
    let (_temp, state) = fixture();
    let actual = with_store(&state, None, |store| Ok(store.scope_id().to_owned())).unwrap();
    let before = std::fs::read_dir(&state.app_data_dir).unwrap().count();
    let result: Result<(), String> = with_store(&state, Some(&"a".repeat(64)), |_| {
        panic!("wrong scope must not execute")
    });
    assert_eq!(result.err().as_deref(), Some("workbench_source_changed"));
    with_store(&state, Some(&actual), |_| Ok(())).unwrap();
    assert_eq!(
        std::fs::read_dir(&state.app_data_dir).unwrap().count(),
        before
    );
}
#[test]
fn workbench_changed_source_rejects_prior_dialog_intent() {
    let (temp, state) = fixture();
    let old = with_store(&state, None, |store| Ok(store.scope_id().to_owned())).unwrap();
    let next = temp.path().canonicalize().unwrap().join("other-source");
    std::fs::create_dir(&next).unwrap();
    state.config.blocking_write().codex_root = next;
    let result: Result<(), String> = with_store(&state, Some(&old), |_| {
        panic!("late chooser must not write new source")
    });
    assert_eq!(result.err().as_deref(), Some("workbench_source_changed"));
}
#[test]
fn workbench_file_artifact_only_selects_a_folder_without_running_document() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().canonicalize().unwrap();
    let file = root.join("result.html");
    std::fs::write(&file, "synthetic document, never executed").unwrap();
    let (target, action) = artifact_target(file.to_str().unwrap()).unwrap();
    assert_eq!(Path::new(&target), root);
    assert_eq!(action, "openedFolder");
    assert!(artifact_target(root.join("missing.txt").to_str().unwrap()).is_err());
    #[cfg(unix)]
    {
        let link = root.join("alias.html");
        std::os::unix::fs::symlink(&file, &link).unwrap();
        assert!(artifact_target(link.to_str().unwrap()).is_err());
    }
}
