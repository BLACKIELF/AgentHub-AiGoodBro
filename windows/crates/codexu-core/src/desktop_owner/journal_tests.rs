use super::super::{
    client::{Connection, Peer},
    tests::{discovery, handshake, ok, reply},
    *,
};
use super::{binding, Document, Entry, SavedState, FILE, MAX_RECORDS};
use crate::accounts::storage;
use serde_json::json;
use std::path::Path;

const THREAD: &str = "00000000-0000-4000-8000-000000000001";
const OWNER: &str = "00000000-0000-4000-8000-000000000003";
const TURN: &str = "00000000-0000-4000-8000-000000000004";
const OP: &str = "00000000-0000-4000-8000-000000000005";
const TIME: Duration = Duration::from_secs(3);
fn scope() -> String {
    "1".repeat(64)
}
fn temporary() -> tempfile::TempDir {
    tempfile::tempdir_in(std::env::temp_dir().canonicalize().unwrap()).unwrap()
}
fn journal(path: &Path) -> OwnerJournal {
    OwnerJournal::new(path.join("journal")).unwrap()
}
fn t() -> OwnerTicket {
    OwnerTicket {
        conversation: THREAD.into(),
        owner: OWNER.into(),
        epoch: "fixture".into(),
        expires: Instant::now() + TIME,
    }
}
struct TestPeer;
impl Peer for TestPeer {
    fn recheck(&self) -> OwnerResult<()> {
        Ok(())
    }
}
async fn connected() -> (DesktopOwnerClient, OwnerTicket, tokio::io::DuplexStream) {
    let (a, mut b) = tokio::io::duplex(65536);
    let server = tokio::spawn(async move {
        handshake(&mut b).await;
        discovery(&mut b, false).await;
        b
    });
    let budget = Budget::new(TIME, &Cancellation::default()).unwrap();
    let mut c = DesktopOwnerClient::initialize(
        Connection {
            socket: Box::new(a),
            peer: Box::new(TestPeer),
        },
        &budget,
    )
    .await
    .unwrap();
    let t = c
        .discover(THREAD, TIME, &Cancellation::default())
        .await
        .unwrap();
    (c, t, server.await.unwrap())
}

#[test]
fn read_only_status_does_not_create_and_invalid_store_never_means_absent() {
    let dir = temporary();
    let j = journal(dir.path());
    assert_eq!(j.status(OP).unwrap(), None);
    assert!(!dir.path().join("journal").exists());
    assert!(OwnerJournal::new("relative".into()).is_err());
    assert_eq!(j.status("bad"), Err(JournalError::InvalidRequest));
    storage::secure_directory(&dir.path().join("journal")).unwrap();
    storage::atomic_write(&dir.path().join("journal").join(FILE), b"{").unwrap();
    assert_eq!(j.status(OP), Err(JournalError::InvalidStore));
    std::fs::remove_file(dir.path().join("journal").join(FILE)).unwrap();
    std::fs::create_dir(dir.path().join("journal").join(FILE)).unwrap();
    assert_eq!(j.status(OP), Err(JournalError::StorageUnavailable));
}

#[test]
fn pending_survives_reopen_and_all_bindings_reject_same_id_changes() {
    let dir = temporary();
    let j = journal(dir.path());
    let b = binding(
        &t(),
        &scope(),
        JournalAction::StartText,
        "private synthetic body",
    )
    .unwrap();
    assert_eq!(j.claim(OP, &b).unwrap(), None);
    let bytes = std::fs::read(dir.path().join("journal").join(FILE)).unwrap();
    assert!(!String::from_utf8_lossy(&bytes).contains("private synthetic body"));
    assert_eq!(
        journal(dir.path()).status(OP).unwrap().unwrap().state,
        JournalState::Unknown
    );
    assert_eq!(
        journal(dir.path()).claim(OP, &b).unwrap().unwrap().state,
        JournalState::Unknown
    );
    for field in 0..4 {
        let mut changed = b.clone();
        match field {
            0 => changed.input_sha256 = "2".repeat(64),
            1 => changed.scope_sha256 = "2".repeat(64),
            2 => changed.conversation_id = TURN.into(),
            _ => changed.action = JournalAction::Interrupt,
        }
        assert_eq!(j.claim(OP, &changed), Err(JournalError::Conflict));
        assert_eq!(
            std::fs::read(dir.path().join("journal").join(FILE)).unwrap(),
            bytes
        );
    }
}

#[test]
fn busy_and_full_do_not_replace_or_prune_unknown_claims() {
    let dir = temporary();
    let j = journal(dir.path());
    let b = binding(&t(), &scope(), JournalAction::StartText, "x").unwrap();
    let lock = storage::StoreLock::acquire(&dir.path().join("journal")).unwrap();
    assert_eq!(j.claim(OP, &b), Err(JournalError::Busy));
    assert_eq!(j.status(OP).unwrap(), None);
    drop(lock);
    let mut d = Document::default();
    for n in 0..MAX_RECORDS {
        d.entries.insert(
            format!("00000000-0000-4000-8000-{n:012x}"),
            Entry {
                binding: b.clone(),
                outcome: SavedState::Pending,
            },
        );
    }
    let bytes = serde_json::to_vec(&d).unwrap();
    storage::atomic_write(&dir.path().join("journal").join(FILE), &bytes).unwrap();
    assert_eq!(
        j.claim("ffffffff-ffff-4fff-8fff-ffffffffffff", &b),
        Err(JournalError::Full)
    );
    assert_eq!(
        std::fs::read(dir.path().join("journal").join(FILE)).unwrap(),
        bytes
    );
    assert_eq!(
        j.claim(OP, &b).unwrap().unwrap().state,
        JournalState::Unknown
    );
}

#[tokio::test]
async fn accepted_actual_start_and_interrupt_are_durable_and_not_replayed() {
    let dir = temporary();
    let j = journal(dir.path());
    let (mut c, t, mut server) = connected().await;
    let root = dir.path().to_owned();
    let op2 = random_id().unwrap();
    let expected = op2.clone();
    let task = tokio::spawn(async move {
        discovery(&mut server, true).await;
        let req = protocol::read(&mut server).await.unwrap();
        assert_eq!(req["requestId"], OP);
        // The real mutation cannot precede the durable on-disk claim.
        assert_eq!(
            journal(&root).status(OP).unwrap().unwrap().state,
            JournalState::Unknown
        );
        reply(
            &mut server,
            &ok(&req, OWNER, json!({"result":{"turn":{"id":TURN}}})),
        )
        .await;
        discovery(&mut server, true).await;
        let req = protocol::read(&mut server).await.unwrap();
        assert_eq!(req["method"], protocol::INTERRUPT);
        assert_eq!(req["params"]["expectedTurnId"], TURN);
        assert_eq!(
            journal(&root).status(&expected).unwrap().unwrap().state,
            JournalState::Unknown
        );
        reply(
            &mut server,
            &ok(&req, OWNER, json!({"ok":true,"interruptedTurnId":TURN})),
        )
        .await;
        assert_eq!(
            protocol::read(&mut server).await.err(),
            Some(OwnerError::Disconnected)
        );
    });
    let result = j
        .execute_start(
            &mut c,
            &t,
            OP,
            &scope(),
            "synthetic",
            TIME,
            &Cancellation::default(),
        )
        .await
        .unwrap();
    assert_eq!(
        result.state,
        JournalState::Accepted {
            turn_id: TURN.into()
        }
    );
    assert_eq!(
        journal(dir.path()).status(OP).unwrap(),
        Some(result.clone())
    );
    assert_eq!(
        j.execute_start(
            &mut c,
            &t,
            OP,
            &scope(),
            "synthetic",
            TIME,
            &Cancellation::default()
        )
        .await
        .unwrap(),
        result
    );
    assert_eq!(
        j.execute_interrupt(
            &mut c,
            &t,
            &op2,
            &scope(),
            TURN,
            TIME,
            &Cancellation::default()
        )
        .await
        .unwrap()
        .state,
        JournalState::Accepted {
            turn_id: TURN.into()
        }
    );
    c.close();
    task.await.unwrap();
}

#[tokio::test]
async fn executed_generic_error_is_unknown_across_new_client_and_restart() {
    let dir = temporary();
    let j = journal(dir.path());
    let (mut c, t, mut server) = connected().await;
    let task = tokio::spawn(async move {
        discovery(&mut server, true).await;
        let req = protocol::read(&mut server).await.unwrap();
        reply(&mut server, &json!({"type":"response","requestId":req["requestId"],"resultType":"error","error":"no-client-found"})).await;
        assert_eq!(
            protocol::read(&mut server).await.err(),
            Some(OwnerError::Disconnected)
        );
        1
    });
    assert_eq!(
        j.execute_start(
            &mut c,
            &t,
            OP,
            &scope(),
            "synthetic",
            TIME,
            &Cancellation::default()
        )
        .await
        .unwrap()
        .state,
        JournalState::Unknown
    );
    assert_eq!(task.await.unwrap(), 1);
    let (mut c2, t2, mut server2) = connected().await;
    let j2 = journal(dir.path());
    assert_eq!(
        j2.execute_start(
            &mut c2,
            &t2,
            OP,
            &scope(),
            "synthetic",
            TIME,
            &Cancellation::default()
        )
        .await
        .unwrap()
        .state,
        JournalState::Unknown
    );
    assert_eq!(
        j2.execute_start(
            &mut c2,
            &t2,
            OP,
            &scope(),
            "changed",
            TIME,
            &Cancellation::default()
        )
        .await,
        Err(JournalError::Conflict)
    );
    c2.close();
    assert_eq!(
        protocol::read(&mut server2).await.err(),
        Some(OwnerError::Disconnected)
    );
}

#[tokio::test]
async fn final_receipt_lock_failure_returns_unknown_and_keeps_pending() {
    let dir = temporary();
    let j = journal(dir.path());
    let root = dir.path().join("journal");
    let (mut c, t, mut server) = connected().await;
    let task = tokio::spawn(async move {
        discovery(&mut server, true).await;
        let req = protocol::read(&mut server).await.unwrap();
        let lock = storage::StoreLock::acquire(&root).unwrap();
        reply(
            &mut server,
            &ok(&req, OWNER, json!({"result":{"turn":{"id":TURN}}})),
        )
        .await;
        (server, lock)
    });
    assert_eq!(
        j.execute_start(
            &mut c,
            &t,
            OP,
            &scope(),
            "synthetic",
            TIME,
            &Cancellation::default()
        )
        .await
        .unwrap()
        .state,
        JournalState::Unknown
    );
    let (mut server, held) = task.await.unwrap();
    drop(held);
    let saved: Document =
        serde_json::from_slice(&std::fs::read(dir.path().join("journal").join(FILE)).unwrap())
            .unwrap();
    assert_eq!(saved.entries[OP].outcome, SavedState::Pending);
    assert_eq!(
        journal(dir.path())
            .execute_start(
                &mut c,
                &t,
                OP,
                &scope(),
                "synthetic",
                TIME,
                &Cancellation::default()
            )
            .await
            .unwrap()
            .state,
        JournalState::Unknown
    );
    c.close();
    assert_eq!(
        protocol::read(&mut server).await.err(),
        Some(OwnerError::Disconnected)
    );
}

#[tokio::test]
async fn dropped_inflight_wrapper_preserves_pending_and_only_closes_client() {
    let dir = temporary();
    let j = journal(dir.path());
    let (mut c, t, mut server) = connected().await;
    let read = Arc::new(AtomicBool::new(false));
    let signal = read.clone();
    let task = tokio::spawn(async move {
        discovery(&mut server, true).await;
        let req = protocol::read(&mut server).await.unwrap();
        assert_eq!(req["method"], protocol::START);
        signal.store(true, Ordering::Release);
        assert_eq!(
            protocol::read(&mut server).await.err(),
            Some(OwnerError::Disconnected)
        );
    });
    let scope = scope();
    let cancel = Cancellation::default();
    {
        let work = j.execute_start(&mut c, &t, OP, &scope, "synthetic", TIME, &cancel);
        tokio::pin!(work);
        let observed = async {
            let end = Instant::now() + TIME;
            while !read.load(Ordering::Acquire) {
                assert!(
                    Instant::now() < end,
                    "synthetic peer must observe the request"
                );
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        };
        tokio::select! { _ = &mut work => panic!("peer sent no result"), _ = observed => {} }
    }
    task.await.unwrap();
    assert!(!c.is_connected());
    assert_eq!(
        journal(dir.path()).status(OP).unwrap().unwrap().state,
        JournalState::Unknown
    );
}

#[tokio::test]
async fn only_real_not_sent_is_recorded_and_same_id_never_retries() {
    let dir = temporary();
    let j = journal(dir.path());
    let (mut c, t, mut server) = connected().await;
    let cancel = Cancellation::default();
    cancel.cancel();
    let result = j
        .execute_start(&mut c, &t, OP, &scope(), "synthetic", TIME, &cancel)
        .await
        .unwrap();
    assert_eq!(result.state, JournalState::NotSent);
    assert_eq!(
        journal(dir.path())
            .execute_start(
                &mut c,
                &t,
                OP,
                &scope(),
                "synthetic",
                TIME,
                &Cancellation::default()
            )
            .await
            .unwrap(),
        result
    );
    c.close();
    assert_eq!(
        protocol::read(&mut server).await.err(),
        Some(OwnerError::Disconnected)
    );
}

#[tokio::test]
async fn admission_storage_failure_never_sends_even_discovery() {
    let dir = temporary();
    let j = journal(dir.path());
    let (mut c, t, mut server) = connected().await;
    let lock = storage::StoreLock::acquire(&dir.path().join("journal")).unwrap();
    assert_eq!(
        j.execute_start(
            &mut c,
            &t,
            OP,
            &scope(),
            "synthetic",
            TIME,
            &Cancellation::default()
        )
        .await,
        Err(JournalError::Busy)
    );
    assert_eq!(j.status(OP).unwrap(), None);
    drop(lock);
    c.close();
    assert_eq!(
        protocol::read(&mut server).await.err(),
        Some(OwnerError::Disconnected)
    );
}
