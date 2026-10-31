use super::*;

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
