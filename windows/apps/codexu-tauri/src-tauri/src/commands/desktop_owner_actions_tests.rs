//! Isolated caller policy tests. The injected session is not an official peer.
//! Fixture records exercise the real journal reader/reopen boundary; native
//! journal writes and transport are separately covered by core's duplex tests.
use super::*;
use serde_json::json;
use std::{
    collections::VecDeque,
    path::Path,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Mutex,
    },
};

const THREAD: &str = "00000000-0000-4000-8000-000000000001";
const TURN: &str = "00000000-0000-4000-8000-000000000002";
const OP: &str = "00000000-0000-4000-8000-000000000003";
const FOREIGN: &str = "00000000-0000-4000-8000-000000000004";
const TEXT: &str = "synthetic caller text, never sent to a real peer";

fn context() -> NativeOwnerContext {
    NativeOwnerContext {
        active: None,
        workbench: "a".repeat(64),
        thread: THREAD.into(),
        metadata: "b".repeat(64),
        identity: "c".repeat(64),
        profile: "synthetic-profile".into(),
        generation: "synthetic-generation".into(),
        home: "synthetic-home".into(),
        auth: "d".repeat(64),
        synthetic: true,
    }
}
fn snapshot(revision: u64, turn: Option<(&str, &str)>) -> OwnerSnapshot {
    let turns = turn
        .into_iter()
        .map(|(id, status)| json!({"turnId":id,"status":status}))
        .collect::<Vec<_>>();
    OwnerSnapshot {
        revision,
        state: json!({"id":THREAD,"hostId":"local","resumeState":"resumed",
        "threadRuntimeStatus":{"type":"idle"},"requests":[],"turns":turns})
        .as_object()
        .unwrap()
        .clone(),
    }
}
struct Guard(Arc<AtomicUsize>);
impl Drop for Guard {
    fn drop(&mut self) {
        self.0.fetch_add(1, Ordering::SeqCst);
    }
}
#[derive(Clone, Copy)]
enum Mode {
    Accepted,
    LostReply,
    LostReceipt,
    DropFuture,
    NotSent,
    WrongBinding,
}
struct Scenario {
    root: PathBuf,
    snapshots: VecDeque<Result<OwnerSnapshot>>,
    mode: Mode,
    opens: usize,
    submits: usize,
    polls: usize,
    entered: Arc<tokio::sync::Notify>,
}
#[derive(Clone)]
struct Fake(Arc<Mutex<Scenario>>);
struct FakeSession(Fake);
impl Factory for Fake {
    type Session = FakeSession;
    async fn open(&mut self, thread: &str) -> Result<FakeSession> {
        assert_eq!(thread, THREAD);
        self.0.lock().unwrap().opens += 1;
        Ok(FakeSession(self.clone()))
    }
}
fn fixture_record(root: &Path, r: &OperationRecord, outcome: Value) {
    let value = json!({"schema":1,"entries":{r.operation_id.clone():{
        "binding":{"conversation_id":r.conversation_id,"scope_sha256":r.scope_sha256,
            "action":r.action,"input_sha256":r.input_sha256},"outcome":outcome}}});
    // Public native settings writer gives the isolated fixture private owner
    // creation on Windows too; no test modifies an existing foreign directory.
    codexu_core::atomic_settings::write_json(
        &root.join("owner-operations-v1.json"),
        &serde_json::to_vec(&value).unwrap(),
        |_| Ok(()),
    )
    .unwrap();
}
impl OwnerSession for FakeSession {
    async fn snapshot(&mut self, refresh: bool) -> Result<OwnerSnapshot> {
        let mut s = self.0 .0.lock().unwrap();
        if refresh {
            s.polls += 1;
        }
        s.snapshots
            .pop_front()
            .expect("one prescribed snapshot per explicit read")
    }
    async fn submit(
        &mut self,
        journal: &OwnerJournal,
        id: &str,
        scope: &str,
        action: &OwnerAction,
    ) -> Result<OperationRecord> {
        let (root, mode, entered) = {
            let s = self.0 .0.lock().unwrap();
            (s.root.clone(), s.mode, s.entered.clone())
        };
        let mut r = OperationRecord {
            operation_id: id.into(),
            conversation_id: THREAD.into(),
            scope_sha256: scope.into(),
            action: action.action(),
            input_sha256: hash(action.input().as_bytes()),
            state: JournalState::Unknown,
        };
        fixture_record(&root, &r, json!({"state":"pending"}));
        assert_eq!(
            journal.status(id).unwrap().unwrap().state,
            JournalState::Unknown
        );
        self.0 .0.lock().unwrap().submits += 1;
        entered.notify_one();
        match mode {
            Mode::LostReply => return Err(fail("unavailable")),
            Mode::LostReceipt => return Ok(r), // accepted remotely, final durable receipt not saved
            Mode::DropFuture => std::future::pending::<()>().await,
            Mode::NotSent => {
                r.state = JournalState::NotSent;
                fixture_record(&root, &r, json!({"state":"not_sent"}));
            }
            Mode::Accepted | Mode::WrongBinding => {
                r.state = JournalState::Accepted {
                    turn_id: TURN.into(),
                };
                fixture_record(&root, &r, json!({"state":"accepted","turn_id":TURN}));
            }
        }
        if matches!(mode, Mode::WrongBinding) {
            r.conversation_id = FOREIGN.into();
        }
        Ok(r)
    }
}
struct Fixture {
    _dir: tempfile::TempDir,
    root: PathBuf,
    fake: Fake,
    released: Arc<AtomicUsize>,
}
impl Fixture {
    fn new(mode: Mode) -> Self {
        let dir = tempfile::tempdir_in(std::env::temp_dir().canonicalize().unwrap()).unwrap();
        let root = dir.path().join("journal");
        Self {
            _dir: dir,
            root: root.clone(),
            fake: Fake(Arc::new(Mutex::new(Scenario {
                root,
                snapshots: VecDeque::new(),
                mode,
                opens: 0,
                submits: 0,
                polls: 0,
                entered: Arc::new(tokio::sync::Notify::new()),
            }))),
            released: Arc::new(AtomicUsize::new(0)),
        }
    }
    fn caller(&self) -> OwnerActions<Fake, Guard> {
        OwnerActions::build(self.root.clone(), self.fake.clone()).unwrap()
    }
    fn guard(&self) -> Guard {
        Guard(self.released.clone())
    }
    fn push(&self, s: OwnerSnapshot) {
        self.fake.0.lock().unwrap().snapshots.push_back(Ok(s));
    }
    fn bytes(&self) -> Vec<u8> {
        std::fs::read(self.root.join("owner-operations-v1.json")).unwrap()
    }
    async fn prepared(&self, caller: &mut OwnerActions<Fake, Guard>) -> OwnerPreview {
        self.push(snapshot(1, None));
        caller
            .prepare(context(), OwnerAction::StartText(TEXT.into()), self.guard())
            .await
            .unwrap()
    }
    async fn submitted(&self, caller: &mut OwnerActions<Fake, Guard>) -> OwnerActionStatus {
        let p = self.prepared(caller).await;
        self.push(snapshot(1, None));
        caller
            .confirm(&p.preview_id, OP, &p.action_hash, || async {
                Ok(context())
            })
            .await
            .unwrap()
    }
}

#[tokio::test]
async fn missing_native_authority_rejects_before_any_peer_connection() {
    let f = Fixture::new(Mode::Accepted);
    let mut c = f.caller();
    let mut unverified = context();
    unverified.synthetic = false;
    assert!(
        matches!(c.prepare(unverified,OwnerAction::StartText(TEXT.into()),f.guard()).await,
        Err(e) if e=="owner_scope_unverified")
    );
    assert_eq!(f.fake.0.lock().unwrap().opens, 0);
    assert!(!f.root.exists());
    assert_eq!(f.released.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn preview_is_opaque_full_snapshot_and_body_bound() {
    let f = Fixture::new(Mode::Accepted);
    let mut c = f.caller();
    let p = f.prepared(&mut c).await;
    let dto = serde_json::to_string(&p).unwrap();
    for secret in [TEXT, "synthetic-home", "synthetic-profile"] {
        assert!(!dto.contains(secret));
    }
    assert!(!f.root.exists());
    assert!(!c.blocks_normal_exit());
    assert!(c
        .confirm(&p.preview_id, OP, &"0".repeat(64), || async {
            Ok(context())
        })
        .await
        .is_err());
    let mut changed = snapshot(1, None);
    changed
        .state
        .insert("cwd".into(), json!("synthetic-other-project"));
    f.push(changed);
    assert!(
        matches!(c.confirm(&p.preview_id,OP,&p.action_hash,||async{Ok(context())}).await,
        Err(e) if e=="owner_scope_changed")
    );
    assert_eq!(f.fake.0.lock().unwrap().submits, 0);
    assert!(!f.root.exists());
}

#[tokio::test]
async fn source_change_on_either_side_of_read_never_submits() {
    for second in [false, true] {
        for field in [
            "identity",
            "home",
            "thread",
            "metadata",
            "generation",
            "workbench",
        ] {
            let f = Fixture::new(Mode::Accepted);
            let mut c = f.caller();
            let p = f.prepared(&mut c).await;
            f.push(snapshot(1, None));
            let mut calls = 0;
            let result = c
                .confirm(&p.preview_id, OP, &p.action_hash, || {
                    calls += 1;
                    let mut v = context();
                    if !second || calls == 2 {
                        match field {
                            "identity" => v.identity = "e".repeat(64),
                            "home" => v.home = "other".into(),
                            "thread" => v.thread = FOREIGN.into(),
                            "metadata" => v.metadata = "e".repeat(64),
                            "generation" => v.generation = "other".into(),
                            _ => v.workbench = "e".repeat(64),
                        }
                    }
                    async move { Ok(v) }
                })
                .await;
            assert!(
                matches!(result,Err(e) if e=="owner_scope_changed"),
                "{field}/{second}"
            );
            assert_eq!(f.fake.0.lock().unwrap().submits, 0);
            assert_eq!(f.released.load(Ordering::SeqCst), 1);
        }
    }
}

#[tokio::test]
async fn authenticated_peer_still_requires_exact_local_resumed_thread() {
    for (field, value) in [
        ("id", FOREIGN),
        ("hostId", "remote"),
        ("resumeState", "notResumed"),
    ] {
        let f = Fixture::new(Mode::Accepted);
        let mut c = f.caller();
        let mut s = snapshot(1, None);
        s.state.insert(field.into(), json!(value));
        f.push(s);
        assert!(c
            .prepare(context(), OwnerAction::StartText(TEXT.into()), f.guard())
            .await
            .is_err());
        assert_eq!(f.fake.0.lock().unwrap().submits, 0);
        assert!(!f.root.exists());
    }
}

#[tokio::test]
async fn accepted_is_not_completion_and_only_exact_scoped_terminal_releases_once() {
    let f = Fixture::new(Mode::Accepted);
    let mut c = f.caller();
    assert_eq!(f.submitted(&mut c).await.state, "accepted");
    assert!(c.blocks_normal_exit());
    let mut duplicate = snapshot(2, Some((TURN, "completed")));
    duplicate.state["turns"]
        .as_array_mut()
        .unwrap()
        .push(json!({"turnId":TURN,"status":"completed"}));
    let mut remote = snapshot(2, Some((TURN, "completed")));
    remote.state["hostId"] = json!("remote");
    for s in [
        snapshot(2, None),
        snapshot(2, Some((FOREIGN, "completed"))),
        duplicate,
        remote,
        snapshot(0, Some((TURN, "completed"))),
        snapshot(2, Some((TURN, "inProgress"))),
    ] {
        f.push(s);
        assert_eq!(
            c.poll(OP, || async { Ok(context()) }).await.unwrap().state,
            "accepted"
        );
        assert_eq!(f.released.load(Ordering::SeqCst), 0);
    }
    f.fake
        .0
        .lock()
        .unwrap()
        .snapshots
        .push_back(Err(fail("scope_changed")));
    assert!(c.poll(OP, || async { Ok(context()) }).await.is_err());
    assert!(c.blocks_normal_exit());
    f.push(snapshot(3, Some((TURN, "completed"))));
    assert_eq!(
        c.poll(OP, || async { Ok(context()) }).await.unwrap().state,
        "completed"
    );
    assert_eq!(f.released.load(Ordering::SeqCst), 1);
    assert!(!c.blocks_normal_exit());
    c.poll(OP, || async { panic!("re-read must be durable only") })
        .await
        .unwrap();
    assert_eq!(f.released.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn unknown_reply_or_receipt_never_releases_on_idle_and_survives_reopen() {
    for mode in [Mode::LostReply, Mode::LostReceipt] {
        let f = Fixture::new(mode);
        let mut c = f.caller();
        assert_eq!(f.submitted(&mut c).await.state, "unknown");
        let bytes = f.bytes();
        assert_eq!(
            c.poll(OP, || async {
                panic!("unknown cannot acquire new authority")
            })
            .await
            .unwrap()
            .state,
            "unknown"
        );
        assert_eq!(f.released.load(Ordering::SeqCst), 0);
        assert!(c.blocks_normal_exit());
        drop(c);
        let mut reopened = f.caller();
        assert_eq!(reopened.status(OP).unwrap().unwrap().state, "unknown");
        let p = f.prepared(&mut reopened).await;
        assert_eq!(
            reopened
                .confirm(&p.preview_id, OP, &p.action_hash, || async {
                    panic!("no replay")
                })
                .await
                .unwrap()
                .state,
            "unknown"
        );
        assert_eq!(f.fake.0.lock().unwrap().submits, 1);
        assert_eq!(f.bytes(), bytes);
    }
}

#[tokio::test]
async fn same_operation_changed_body_scope_or_action_is_not_replayed() {
    for change in ["body", "scope", "thread", "action"] {
        let f = Fixture::new(Mode::LostReply);
        let mut c = f.caller();
        f.submitted(&mut c).await;
        let bytes = f.bytes();
        let mut next = f.caller();
        let mut ctx = context();
        if change == "scope" {
            ctx.workbench = "e".repeat(64);
        }
        // Changing the stored thread, rather than a mock owner name, exercises
        // the actual journal binding mismatch while native preview stays local.
        if change == "thread" {
            let mut record = c.journal.status(OP).unwrap().unwrap();
            record.conversation_id = FOREIGN.into();
            fixture_record(&f.root, &record, json!({"state":"pending"}));
        }
        let action = if change == "action" {
            OwnerAction::Interrupt {
                expected_turn_id: TURN.into(),
            }
        } else {
            OwnerAction::StartText(
                if change == "body" {
                    "different synthetic body"
                } else {
                    TEXT
                }
                .into(),
            )
        };
        f.push(snapshot(
            1,
            if change == "action" {
                Some((TURN, "inProgress"))
            } else {
                None
            },
        ));
        let p = next.prepare(ctx, action, f.guard()).await.unwrap();
        let before = f.bytes();
        assert!(
            matches!(next.confirm(&p.preview_id,OP,&p.action_hash,||async{panic!("must reject before capture")}).await,
            Err(e) if e=="owner_operation_conflict")
        );
        assert_eq!(f.fake.0.lock().unwrap().submits, 1);
        assert_eq!(f.bytes(), before);
        if change != "thread" {
            assert_eq!(before, bytes);
        }
    }
}

#[tokio::test]
async fn dropped_confirm_keeps_actual_attempt_guard_and_pending_claim() {
    let f = Fixture::new(Mode::DropFuture);
    let mut c = f.caller();
    let p = f.prepared(&mut c).await;
    f.push(snapshot(1, None));
    let entered = f.fake.0.lock().unwrap().entered.clone();
    {
        let pending = c.confirm(&p.preview_id, OP, &p.action_hash, || async {
            Ok(context())
        });
        tokio::pin!(pending);
        tokio::select! {_=&mut pending=>panic!("submit is prescribed pending"),_=entered.notified()=>{}}
    }
    assert!(c.blocks_normal_exit());
    assert_eq!(f.released.load(Ordering::SeqCst), 0);
    assert_eq!(c.status(OP).unwrap().unwrap().state, "unknown");
    assert_eq!(
        c.journal.status(OP).unwrap().unwrap().state,
        JournalState::Unknown
    );
    assert_eq!(f.fake.0.lock().unwrap().submits, 1);
}

#[tokio::test]
async fn not_sent_releases_but_same_id_is_never_retried() {
    let f = Fixture::new(Mode::NotSent);
    let mut c = f.caller();
    assert_eq!(f.submitted(&mut c).await.state, "notSent");
    assert!(!c.blocks_normal_exit());
    assert_eq!(f.released.load(Ordering::SeqCst), 1);
    let bytes = f.bytes();
    let p = f.prepared(&mut c).await;
    assert_eq!(
        c.confirm(&p.preview_id, OP, &p.action_hash, || async {
            panic!("no replay")
        })
        .await
        .unwrap()
        .state,
        "notSent"
    );
    assert_eq!(f.fake.0.lock().unwrap().submits, 1);
    assert_eq!(f.bytes(), bytes);
}

#[tokio::test]
async fn foreign_ack_and_preexisting_start_turn_remain_unknown() {
    for mode in [Mode::WrongBinding, Mode::Accepted] {
        let f = Fixture::new(mode);
        let mut c = f.caller();
        let s = snapshot(1, Some((TURN, "completed")));
        f.push(OwnerSnapshot {
            revision: s.revision,
            state: s.state.clone(),
        });
        let p = c
            .prepare(context(), OwnerAction::StartText(TEXT.into()), f.guard())
            .await
            .unwrap();
        f.push(s);
        assert_eq!(
            c.confirm(&p.preview_id, OP, &p.action_hash, || async {
                Ok(context())
            })
            .await
            .unwrap()
            .state,
            "unknown"
        );
        assert!(c.blocks_normal_exit());
        assert_eq!(f.released.load(Ordering::SeqCst), 0);
    }
}

#[test]
fn durable_read_errors_are_not_missing_or_repair_and_lost_preview_is_not_authority() {
    let f = Fixture::new(Mode::Accepted);
    let c = f.caller();
    assert_eq!(c.status(OP).unwrap(), None);
    assert!(!f.root.exists());
    let r = OperationRecord {
        operation_id: OP.into(),
        conversation_id: THREAD.into(),
        scope_sha256: "1".repeat(64),
        action: JournalAction::StartText,
        input_sha256: "2".repeat(64),
        state: JournalState::Unknown,
    };
    fixture_record(&f.root, &r, json!({"state":"pending"}));
    std::fs::write(f.root.join("owner-operations-v1.json"), b"{").unwrap();
    assert!(matches!(c.status(OP),Err(e) if e=="owner_journal_unavailable"));
    assert_eq!(f.bytes(), b"{");
    assert_eq!(f.fake.0.lock().unwrap().opens, 0);
}

#[tokio::test]
async fn expired_or_lost_preview_cannot_send_and_preserves_old_durable_bytes() {
    let f = Fixture::new(Mode::Accepted);
    let mut c = f.caller();
    let p = f.prepared(&mut c).await;
    c.previews.get_mut(&p.preview_id).unwrap().expires = Instant::now() - Duration::from_secs(1);
    assert!(
        matches!(c.confirm(&p.preview_id,OP,&p.action_hash,||async{panic!("expired")}).await,
        Err(e) if e=="owner_preview_expired")
    );
    let mut reopened = f.caller();
    assert!(
        matches!(reopened.confirm(&p.preview_id,OP,&p.action_hash,||async{panic!("lost")}).await,
        Err(e) if e=="owner_preview_expired")
    );
    assert_eq!(f.fake.0.lock().unwrap().submits, 0);
    assert!(!f.root.exists());
}

#[tokio::test]
async fn explicit_cancel_releases_only_unsent_preview_never_an_unknown_attempt() {
    let f = Fixture::new(Mode::LostReply);
    let mut c = f.caller();
    let first = f.prepared(&mut c).await;
    assert_eq!(f.released.load(Ordering::SeqCst), 0);
    assert!(c.discard_preview(&first.preview_id));
    assert!(!c.discard_preview(&first.preview_id));
    assert_eq!(f.released.load(Ordering::SeqCst), 1);
    assert!(!f.root.exists());
    assert_eq!(f.fake.0.lock().unwrap().submits, 0);

    let submitted = f.prepared(&mut c).await;
    f.push(snapshot(1, None));
    assert_eq!(
        c.confirm(
            &submitted.preview_id,
            OP,
            &submitted.action_hash,
            || async { Ok(context()) }
        )
        .await
        .unwrap()
        .state,
        "unknown"
    );
    assert!(!c.discard_preview(&submitted.preview_id));
    assert_eq!(f.released.load(Ordering::SeqCst), 1);
    assert!(c.blocks_normal_exit());
    assert_eq!(c.status(OP).unwrap().unwrap().state, "unknown");
}
