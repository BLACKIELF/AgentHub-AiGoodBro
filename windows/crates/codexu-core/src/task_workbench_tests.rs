use super::*;
use rusqlite::{params, Connection};
use serde_json::json;
const THREAD: &str = "11111111-1111-4111-8111-111111111111";
const OTHER: &str = "22222222-2222-4222-8222-222222222222";
const NOW: i64 = 1_900_000_000_000;
struct Fixture {
    _temp: tempfile::TempDir,
    root: PathBuf,
    app_data: PathBuf,
    store: TaskWorkbenchStore,
}
impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let base = temp.path().canonicalize().unwrap();
        let root = base.join("codex-synthetic");
        std::fs::create_dir(&root).unwrap();
        let conn = Connection::open(root.join("state_5.sqlite")).unwrap();
        conn.execute_batch("CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,cwd TEXT,updated_at_ms INTEGER,created_at INTEGER,updated_at INTEGER,archived INTEGER,thread_source TEXT,preview BLOB,rollout_path TEXT);").unwrap();
        conn.execute("INSERT INTO threads VALUES(?1,'Existing task','C:\\private\\project-one',?2,1,1,0,'main',X'FFFE','/not-read/session.jsonl')",params![THREAD,NOW-1000]).unwrap();
        drop(conn);
        let app_data = base.join("app-data");
        let store = TaskWorkbenchStore::open(&app_data, &root).unwrap();
        Self {
            _temp: temp,
            root,
            app_data,
            store,
        }
    }
    fn input(&self, outcome: &str) -> String {
        serde_json::to_string(&json!({"threadID":THREAD,"project":"Project","outcome":outcome,"remaining":["Verify on target device"],"nextStep":"Review the output","artifacts":[{"title":"Report","reference":"https://example.invalid/report.pdf"}],"evidence":"Synthetic local fixture, no model request"})).unwrap()
    }
    fn bytes(&self) -> Vec<u8> {
        std::fs::read(&self.store.path).unwrap()
    }
    fn connection(&self) -> Connection {
        Connection::open(self.root.join("state_5.sqlite")).unwrap()
    }
}
#[test]
fn all_date_metadata_is_bounded_and_never_reads_preview_or_exposes_source_path() {
    let f = Fixture::new();
    let before = std::fs::read(f.root.join("state_5.sqlite")).unwrap();
    let view = f.store.load(NOW).unwrap();
    assert!(view.source_available);
    assert_eq!(view.items.len(), 1);
    assert_eq!(view.items[0].thread_id, THREAD);
    assert_eq!(view.items[0].project, "project-one");
    assert_eq!(view.items[0].execution_state, "recorded");
    assert_eq!(view.items[0].outcome, Outcome::Unknown);
    let dto = serde_json::to_string(&view).unwrap();
    for secret in [
        f.root.to_str().unwrap(),
        "private",
        "session.jsonl",
        "rollout_path",
        "preview",
    ] {
        assert!(!dto.contains(secret));
    }
    assert!(!f.app_data.exists());
    assert_eq!(
        before,
        std::fs::read(f.root.join("state_5.sqlite")).unwrap()
    );
    assert_eq!(std::fs::read_dir(&f.root).unwrap().count(), 1);
}
#[test]
fn import_complete_never_accepts_itself_and_manual_decisions_survive_import_and_restart() {
    let f = Fixture::new();
    f.store
        .import_inventory(THREAD, &f.input("complete"), NOW)
        .unwrap();
    let item = &f.store.load(NOW).unwrap().items[0];
    assert_eq!(item.outcome, Outcome::AwaitingAcceptance);
    assert!(item.needs_attention);
    f.store
        .set_decision(THREAD, Decision::Completed, NOW + 1)
        .unwrap();
    f.store
        .import_inventory(THREAD, &f.input("incomplete"), NOW + 2)
        .unwrap();
    let reopened = TaskWorkbenchStore::open(&f.app_data, &f.root).unwrap();
    assert_eq!(
        reopened.load(NOW + 3).unwrap().items[0].outcome,
        Outcome::Complete
    );
    reopened
        .set_decision(THREAD, Decision::None, NOW + 4)
        .unwrap();
    assert_eq!(
        reopened.load(NOW + 4).unwrap().items[0].outcome,
        Outcome::Incomplete
    );
    for decision in [Decision::Paused, Decision::Cancelled] {
        reopened.set_decision(THREAD, decision, NOW + 5).unwrap();
        reopened
            .import_inventory(THREAD, &f.input("candidate"), NOW + 6)
            .unwrap();
        let item = &reopened.load(NOW + 7).unwrap().items[0];
        assert_eq!(item.decision, decision);
        assert!(!item.needs_attention);
        assert_eq!(item.execution_state, "recorded");
    }
}
#[test]
fn archived_execution_is_not_completion_and_new_activity_marks_inventory_stale() {
    let f = Fixture::new();
    f.store
        .import_inventory(THREAD, &f.input("candidate"), NOW)
        .unwrap();
    f.connection()
        .execute("UPDATE threads SET updated_at_ms=?1,archived=1", [NOW + 20])
        .unwrap();
    let item = &f.store.load(NOW + 30).unwrap().items[0];
    assert!(item.archived);
    assert!(item.inventory_is_stale);
    assert_eq!(item.outcome, Outcome::Unknown);
    assert!(item.needs_attention);
    f.store
        .set_decision(THREAD, Decision::Completed, NOW + 40)
        .unwrap();
    assert_eq!(
        f.store.load(NOW + 50).unwrap().items[0].outcome,
        Outcome::Complete
    );
}
#[test]
fn invalid_inventory_thread_secret_or_reference_preserves_prior_bytes() {
    let f = Fixture::new();
    f.store
        .import_inventory(THREAD, &f.input("candidate"), NOW)
        .unwrap();
    let before = f.bytes();
    for reference in [
        "https://user:secret@example.invalid/x",
        "file:///tmp/doc.pdf",
        "javascript:alert(1)",
        "/tmp/auth.json",
        "/tmp/%61uth.json",
        "C:\\tmp\\credentials.json",
        "C:\\tmp\\app.exe",
        "relative.pdf",
        "/tmp/../escape.pdf",
        "\\\\server\\share\\doc.pdf",
        "https://example.invalid/%63redentials.json",
    ] {
        let mut v: serde_json::Value = serde_json::from_str(&f.input("complete")).unwrap();
        v["artifacts"][0]["reference"] = json!(reference);
        assert!(
            f.store
                .import_inventory(THREAD, &v.to_string(), NOW + 1)
                .is_err(),
            "{reference}"
        );
        assert_eq!(f.bytes(), before);
    }
    for secret in [
        "Bearer abcdefghijklmnop123456",
        "sk-abcdefghijklmnop123456",
        "access_token = abcdefghijklmnop",
        "password: abcdefghijklmnop",
    ] {
        let mut v: serde_json::Value = serde_json::from_str(&f.input("candidate")).unwrap();
        v["evidence"] = json!(secret);
        assert!(f
            .store
            .import_inventory(THREAD, &v.to_string(), NOW)
            .is_err());
    }
    assert!(f
        .store
        .import_inventory(OTHER, &f.input("complete"), NOW)
        .is_err());
    assert!(f
        .store
        .import_inventory(THREAD, &"x".repeat(MAX_INVENTORY + 1), NOW)
        .is_err());
    let mut v: serde_json::Value = serde_json::from_str(&f.input("candidate")).unwrap();
    v["decision"] = json!("completed");
    assert!(f
        .store
        .import_inventory(THREAD, &v.to_string(), NOW)
        .is_err());
    assert_eq!(f.bytes(), before);
}
#[test]
fn unknown_thread_unavailable_source_and_scope_change_cannot_reuse_annotations() {
    let f = Fixture::new();
    assert_eq!(
        f.store
            .set_decision(OTHER, Decision::Completed, NOW)
            .unwrap_err(),
        WorkbenchError::ThreadMissing
    );
    f.store
        .set_decision(THREAD, Decision::Completed, NOW)
        .unwrap();
    let before = f.bytes();
    let other_root = f
        ._temp
        .path()
        .canonicalize()
        .unwrap()
        .join("different-source");
    std::fs::create_dir(&other_root).unwrap();
    std::fs::copy(
        f.root.join("state_5.sqlite"),
        other_root.join("state_5.sqlite"),
    )
    .unwrap();
    let other = TaskWorkbenchStore::open(&f.app_data, &other_root).unwrap();
    assert_ne!(other.scope_id(), f.store.scope_id());
    assert_eq!(other.load(NOW).unwrap().items[0].outcome, Outcome::Unknown);
    std::fs::rename(
        other_root.join("state_5.sqlite"),
        other_root.join("kept.sqlite"),
    )
    .unwrap();
    assert!(!other.load(NOW).unwrap().source_available);
    assert_eq!(
        other
            .import_inventory(THREAD, &f.input("complete"), NOW)
            .unwrap_err(),
        WorkbenchError::SourceUnavailable
    );
    assert_eq!(f.bytes(), before);
}
#[test]
fn canonical_path_aliases_share_scope_without_case_folding_the_native_root() {
    let f = Fixture::new();
    let alias = TaskWorkbenchStore::open(&f.app_data, &f.root.join(".")).unwrap();
    assert_eq!(alias.scope_id(), f.store.scope_id());
    let expected = format!(
        "{:x}",
        Sha256::digest(
            format!(
                "AiGoodBro.task-workbench.v1\0{}",
                f.root.canonicalize().unwrap().to_str().unwrap()
            )
            .as_bytes()
        )
    );
    assert_eq!(f.store.scope_id(), expected);
}
#[test]
fn corrupt_store_is_not_replaced_and_concurrent_writer_is_busy() {
    let f = Fixture::new();
    f.store.set_decision(THREAD, Decision::Paused, NOW).unwrap();
    let held = storage::StoreLock::acquire(&f.store.directory).unwrap();
    let before = f.bytes();
    assert_eq!(
        f.store
            .set_decision(THREAD, Decision::Completed, NOW)
            .unwrap_err(),
        WorkbenchError::Busy
    );
    assert_eq!(f.bytes(), before);
    drop(held);
    std::fs::write(&f.store.path, b"corrupt preserved bytes").unwrap();
    assert!(f.store.load(NOW).is_err());
    assert!(f
        .store
        .set_decision(THREAD, Decision::Completed, NOW)
        .is_err());
    assert_eq!(f.bytes(), b"corrupt preserved bytes");
}
#[test]
fn separate_handles_reread_notes_so_decision_and_inventory_do_not_lose_updates() {
    let f = Fixture::new();
    let second = TaskWorkbenchStore::open(&f.app_data, &f.root).unwrap();
    f.store.set_decision(THREAD, Decision::Paused, NOW).unwrap();
    second
        .import_inventory(THREAD, &f.input("candidate"), NOW + 1)
        .unwrap();
    let item = &f.store.load(NOW + 2).unwrap().items[0];
    assert_eq!(item.decision, Decision::Paused);
    assert_eq!(item.inventory.as_ref().unwrap().outcome, Outcome::Candidate);
    assert_eq!(
        second.artifact_reference(THREAD, 0).unwrap(),
        "https://example.invalid/report.pdf"
    );
    f.connection().execute("DELETE FROM threads", []).unwrap();
    assert_eq!(
        second.artifact_reference(THREAD, 0).unwrap_err(),
        WorkbenchError::ThreadMissing
    );
}
#[test]
fn metadata_limit_is_explicit_and_subagents_are_not_invented_as_user_threads() {
    let f = Fixture::new();
    let mut conn = f.connection();
    let transaction = conn.transaction().unwrap();
    for n in 0..1002 {
        let id = format!("33333333-3333-4333-8333-{n:012x}");
        transaction.execute("INSERT INTO threads(id,title,cwd,updated_at_ms,archived,thread_source) VALUES(?1,'Fixture','/project',?2,0,'main')",params![id,NOW+n]).unwrap();
    }
    transaction.execute("INSERT INTO threads(id,title,cwd,updated_at_ms,archived,thread_source) VALUES(?1,'Child','/project',?2,0,'subagent')",params![OTHER,NOW+9000]).unwrap();
    transaction.commit().unwrap();
    let view = f.store.load(NOW + 10000).unwrap();
    assert_eq!(view.items.len(), 1000);
    assert!(view.truncated);
    assert!(!view.items.iter().any(|v| v.thread_id == OTHER));
}
#[test]
fn bounded_inventory_and_store_schema_do_not_overwrite_on_capacity_or_scope_mismatch() {
    let f = Fixture::new();
    f.store.set_decision(THREAD, Decision::Paused, NOW).unwrap();
    let before = f.bytes();
    let mut input: serde_json::Value = serde_json::from_str(&f.input("candidate")).unwrap();
    input["remaining"] = json!(vec!["task"; 9]);
    assert!(f
        .store
        .import_inventory(THREAD, &input.to_string(), NOW)
        .is_err());
    assert_eq!(f.bytes(), before);
    let mut saved = f.store.read().unwrap();
    saved.scope_id = "wrong-scope".into();
    std::fs::write(&f.store.path, serde_json::to_vec(&saved).unwrap()).unwrap();
    let corrupted = f.bytes();
    assert_eq!(
        f.store.load(NOW).err().unwrap(),
        WorkbenchError::SourceChanged
    );
    assert!(f.store.set_decision(THREAD, Decision::None, NOW).is_err());
    assert_eq!(f.bytes(), corrupted);
}
#[test]
fn annotation_count_and_serialized_byte_limits_preserve_the_last_saved_bytes() {
    let f = Fixture::new();
    f.store.set_decision(THREAD, Decision::Paused, NOW).unwrap();
    let mut saved = f.store.read().unwrap();
    saved.annotations.clear();
    for n in 0..MAX_ITEMS {
        saved.annotations.insert(
            format!("33333333-3333-4333-8333-{n:012x}"),
            Annotation::default(),
        );
    }
    storage::atomic_write(&f.store.path, &serde_json::to_vec(&saved).unwrap()).unwrap();
    let before = f.bytes();
    assert_eq!(
        f.store
            .set_decision(THREAD, Decision::Completed, NOW)
            .unwrap_err(),
        WorkbenchError::Capacity
    );
    assert_eq!(f.bytes(), before);

    saved.annotations.clear();
    saved
        .annotations
        .insert(THREAD.into(), Annotation::default());
    let mut input: serde_json::Value = serde_json::from_str(&f.input("candidate")).unwrap();
    input["remaining"] = json!(vec!["r".repeat(800); 8]);
    input["evidence"] = json!("e".repeat(1600));
    let full = Inventory::parse(&input.to_string(), THREAD, NOW).unwrap();
    for n in 0..MAX_ITEMS {
        let id = format!("44444444-4444-4444-8444-{n:012x}");
        let mut inventory = full.clone();
        inventory.thread_id = id.clone();
        saved.annotations.insert(
            id.clone(),
            Annotation {
                inventory: Some(inventory),
                ..Default::default()
            },
        );
        if serde_json::to_vec(&saved).unwrap().len() > MAX_STORE {
            saved.annotations.remove(&id);
            break;
        }
    }
    saved.validate(f.store.scope_id()).unwrap();
    let bytes = serde_json::to_vec(&saved).unwrap();
    assert!(bytes.len() <= MAX_STORE && bytes.len() > MAX_STORE - MAX_INVENTORY);
    storage::atomic_write(&f.store.path, &bytes).unwrap();
    assert_eq!(
        f.store
            .import_inventory(THREAD, &input.to_string(), NOW)
            .unwrap_err(),
        WorkbenchError::Capacity
    );
    assert_eq!(f.bytes(), bytes);
}

#[test]
fn seconds_schema_is_read_as_metadata_without_requiring_newer_columns() {
    let f = Fixture::new();
    let connection = f.connection();
    connection.execute_batch("DROP TABLE threads; CREATE TABLE threads(id TEXT, title TEXT, cwd TEXT, updated_at INTEGER, archived INTEGER);").unwrap();
    connection
        .execute(
            "INSERT INTO threads VALUES(?1,'Older metadata','/workspace/old-project',?2,0)",
            params![THREAD, NOW / 1000 - 1],
        )
        .unwrap();
    drop(connection);
    let snapshot = f.store.load(NOW).unwrap();
    assert_eq!(snapshot.items[0].updated_at_ms, Some(NOW - 1000));
    assert_eq!(snapshot.items[0].project, "old-project");
    assert_eq!(snapshot.items[0].outcome, Outcome::Unknown);
}
#[cfg(unix)]
#[test]
fn symlinked_metadata_or_store_is_rejected_without_following_it() {
    let f = Fixture::new();
    f.store.set_decision(THREAD, Decision::Paused, NOW).unwrap();
    let original = f.bytes();
    let kept = f.store.path.with_extension("kept");
    std::fs::rename(&f.store.path, &kept).unwrap();
    std::os::unix::fs::symlink(&kept, &f.store.path).unwrap();
    assert!(f.store.load(NOW).is_err());
    assert!(f
        .store
        .set_decision(THREAD, Decision::Completed, NOW)
        .is_err());
    assert_eq!(std::fs::read(&kept).unwrap(), original);
    let db = f.root.join("state_5.sqlite");
    let kept_db = f.root.join("kept.sqlite");
    std::fs::rename(&db, &kept_db).unwrap();
    std::os::unix::fs::symlink(&kept_db, &db).unwrap();
    assert!(read_workbench_metadata(&f.root).is_err());
}
#[test]
fn native_selected_inventory_document_is_bounded_utf8_json_without_private_acl_requirement() {
    let f = Fixture::new();
    let path = f._temp.path().join("chosen.JSON");
    let input = f.input("candidate");
    std::fs::write(&path, &input).unwrap();
    assert_eq!(read_inventory_file(&path).unwrap(), input);
    std::fs::write(&path, vec![b' '; MAX_INVENTORY + 1]).unwrap();
    assert!(read_inventory_file(&path).is_err());
    std::fs::write(&path, [0xff]).unwrap();
    assert!(read_inventory_file(&path).is_err());
    assert!(read_inventory_file(&path.with_extension("exe")).is_err());
}
#[cfg(unix)]
#[test]
fn private_store_rejects_hardlinks_or_public_permissions_without_repairing_them() {
    use std::os::unix::fs::PermissionsExt;
    let f = Fixture::new();
    f.store.set_decision(THREAD, Decision::Paused, NOW).unwrap();
    let before = f.bytes();
    let link = f.store.path.with_extension("linked");
    std::fs::hard_link(&f.store.path, &link).unwrap();
    assert!(f.store.load(NOW).is_err());
    assert!(f
        .store
        .set_decision(THREAD, Decision::Completed, NOW)
        .is_err());
    std::fs::remove_file(link).unwrap();
    std::fs::set_permissions(&f.store.path, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert!(f.store.load(NOW).is_err());
    assert!(f
        .store
        .set_decision(THREAD, Decision::Completed, NOW)
        .is_err());
    assert_eq!(f.bytes(), before);
    assert_eq!(
        std::fs::metadata(&f.store.path)
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o644
    );
}
