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
