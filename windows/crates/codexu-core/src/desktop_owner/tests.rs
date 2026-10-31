use super::{
    client::{Connection, Peer},
    protocol::{self, Socket},
    *,
};
use serde_json::{json, Value};
use std::sync::atomic::{AtomicUsize, Ordering};
use tokio::io::AsyncWriteExt;
const THREAD: &str = "00000000-0000-4000-8000-000000000001";
const CLIENT: &str = "00000000-0000-4000-8000-000000000002";
const OWNER: &str = "00000000-0000-4000-8000-000000000003";
const TURN: &str = "00000000-0000-4000-8000-000000000004";
const OP: &str = "00000000-0000-4000-8000-000000000005";
const TIME: Duration = Duration::from_millis(300);
struct TestPeer(Arc<AtomicBool>);
impl Peer for TestPeer {
    fn recheck(&self) -> OwnerResult<()> {
        if self.0.load(Ordering::SeqCst) {
            Ok(())
        } else {
            Err(OwnerError::PeerUntrusted)
        }
    }
}
pub(super) fn ok(req: &Value, owner: &str, result: Value) -> Value {
    json!({"type":"response","requestId":req["requestId"],"method":req["method"],"handledByClientId":owner,"resultType":"success","result":result})
}
pub(super) async fn reply(s: &mut dyn Socket, v: &Value) {
    protocol::write(s, &protocol::frame(v).unwrap())
        .await
        .unwrap();
}
pub(super) async fn handshake(s: &mut dyn Socket) {
    let init = protocol::read(s).await.unwrap();
    assert_eq!(init["method"], "initialize");
    assert_eq!(init["version"], 0);
    assert!(init.get("hostId").is_none());
    reply(s, &ok(&init, CLIENT, json!({"clientId":CLIENT}))).await;
}
pub(super) async fn discovery(s: &mut dyn Socket, target: bool) {
    let req = protocol::read(s).await.unwrap();
    assert_eq!(req["method"], protocol::DISCOVER);
    assert_eq!(req["version"], 1);
    assert_eq!(req["params"]["hostId"], "local");
    assert!(req.get("hostId").is_none());
    assert_eq!(
        req.get("targetClientId").and_then(Value::as_str),
        target.then_some(OWNER)
    );
    reply(
        s,
        &ok(&req, OWNER, json!({"supportsUntrustedAppInput":true})),
    )
    .await;
}
async fn setup() -> (DesktopOwnerClient, tokio::io::DuplexStream, Arc<AtomicBool>) {
    let (a, mut b) = tokio::io::duplex(65536);
    let alive = Arc::new(AtomicBool::new(true));
    let server = tokio::spawn(async move {
        handshake(&mut b).await;
        b
    });
    let budget = Budget::new(TIME, &Cancellation::default()).unwrap();
    let client = DesktopOwnerClient::initialize(
        Connection {
            socket: Box::new(a),
            peer: Box::new(TestPeer(alive.clone())),
        },
        &budget,
    )
    .await
    .unwrap();
    (client, server.await.unwrap(), alive)
}
async fn ticket(
    c: &mut DesktopOwnerClient,
    mut b: tokio::io::DuplexStream,
) -> (OwnerTicket, tokio::io::DuplexStream) {
    let server = tokio::spawn(async move {
        discovery(&mut b, false).await;
        b
    });
    let t = c
        .discover(THREAD, TIME, &Cancellation::default())
        .await
        .unwrap();
    (t, server.await.unwrap())
}

#[tokio::test]
async fn exact_local_start_and_interrupt_use_existing_owner_and_wire_versions() {
    let (mut c, b, _) = setup().await;
    let (t, mut b) = ticket(&mut c, b).await;
    let server = tokio::spawn(async move {
        discovery(&mut b, true).await;
        let r = protocol::read(&mut b).await.unwrap();
        assert_eq!(r["method"], protocol::START);
        assert_eq!(r["version"], 2);
        assert_eq!(r["targetClientId"], OWNER);
        assert!(r.get("hostId").is_none());
        assert_eq!(
            r["params"]["turnStart"],
            json!({"request":{"threadId":THREAD,"clientUserMessageId":OP,"input":[{"type":"text","text":"synthetic only","text_elements":[]}]},"context":{"inheritThreadSettings":true}})
        );
        reply(
            &mut b,
            &ok(&r, OWNER, json!({"result":{"turn":{"id":TURN}}})),
        )
        .await;
        discovery(&mut b, true).await;
        let r = protocol::read(&mut b).await.unwrap();
        assert_eq!(r["method"], protocol::INTERRUPT);
        assert_eq!(r["version"], 4);
        assert_eq!(r["params"]["expectedTurnId"], TURN);
        assert!(r.get("hostId").is_none());
        reply(
            &mut b,
            &ok(&r, OWNER, json!({"ok":true,"interruptedTurnId":TURN})),
        )
        .await;
    });
    assert_eq!(
        c.start_text(&t, OP, "synthetic only", TIME, &Cancellation::default())
            .await,
        ActionOutcome::Accepted {
            turn_id: TURN.into()
        }
    );
    assert_eq!(
        c.start_text(&t, OP, "synthetic only", TIME, &Cancellation::default())
            .await,
        ActionOutcome::NotSent(OwnerError::AlreadyAttempted)
    );
    assert_eq!(
        c.interrupt(
            &t,
            &random_id().unwrap(),
            TURN,
            TIME,
            &Cancellation::default()
        )
        .await,
        ActionOutcome::Accepted {
            turn_id: TURN.into()
        }
    );
    server.await.unwrap();
}

#[tokio::test]
async fn performed_then_generic_or_spoofed_error_is_unknown_and_never_replayed() {
    for mode in [
        "generic",
        "no-client-found",
        "request-version-mismatch",
        "no-handler-for-request",
        "lost",
        "wrong-owner",
        "wrong-method",
        "wrong-id",
        "malformed-success",
    ] {
        let (mut c, b, _) = setup().await;
        let (t, mut b) = ticket(&mut c, b).await;
        let count = Arc::new(AtomicUsize::new(0));
        let hits = count.clone();
        let which = mode.to_owned();
        let server = tokio::spawn(async move {
            discovery(&mut b, true).await;
            let r = protocol::read(&mut b).await.unwrap();
            assert_eq!(r["method"], protocol::START);
            hits.fetch_add(1, Ordering::SeqCst);
            if which == "lost" {
                return;
            }
            let mut v = ok(&r, OWNER, json!({"result":{"turn":{"id":TURN}}}));
            match which.as_str() {
                "wrong-owner" => v["handledByClientId"] = json!(CLIENT),
                "wrong-method" => v["method"] = json!(protocol::INTERRUPT),
                "wrong-id" => v["requestId"] = json!(TURN),
                "malformed-success" => v["result"] = json!({}),
                _ => {
                    v = json!({"type":"response","requestId":r["requestId"],"resultType":"error","error":which})
                }
            }
            reply(&mut b, &v).await;
            assert_eq!(
                tokio::time::timeout(TIME, protocol::read(&mut b))
                    .await
                    .unwrap()
                    .err(),
                Some(OwnerError::Disconnected)
            );
        });
        assert_eq!(
            c.start_text(&t, OP, "synthetic", TIME, &Cancellation::default())
                .await,
            ActionOutcome::Unknown,
            "{mode}"
        );
        assert!(!c.is_connected());
        assert_eq!(
            c.start_text(&t, OP, "synthetic", TIME, &Cancellation::default())
                .await,
            ActionOutcome::NotSent(OwnerError::AlreadyAttempted)
        );
        assert!(matches!(
            c.start_text(
                &t,
                &random_id().unwrap(),
                "synthetic",
                TIME,
                &Cancellation::default()
            )
            .await,
            ActionOutcome::NotSent(_)
        ));
        server.await.unwrap();
        assert_eq!(count.load(Ordering::SeqCst), 1);
    }
}

#[tokio::test]
async fn cancelled_and_expired_or_other_epoch_tickets_do_not_write() {
    let (mut c, b, _) = setup().await;
    let (mut t, mut b) = ticket(&mut c, b).await;
    let epoch = t.epoch.clone();
    let cancel = Cancellation::default();
    cancel.cancel();
    assert_eq!(
        c.start_text(&t, OP, "x", TIME, &cancel).await,
        ActionOutcome::NotSent(OwnerError::Cancelled)
    );
    t.epoch = "different".into();
    assert_eq!(
        c.start_text(&t, OP, "x", TIME, &Cancellation::default())
            .await,
        ActionOutcome::NotSent(OwnerError::StaleTicket)
    );
    t.epoch = epoch;
    t.expires = Instant::now();
    assert_eq!(
        c.start_text(&t, OP, "x", TIME, &Cancellation::default())
            .await,
        ActionOutcome::NotSent(OwnerError::StaleTicket)
    );
    assert!(
        tokio::time::timeout(Duration::from_millis(20), protocol::read(&mut b))
            .await
            .is_err()
    );
}

#[tokio::test]
async fn changed_peer_or_capability_refuses_mutation_before_write() {
    for change_peer in [false, true] {
        let (mut c, b, alive) = setup().await;
        let (t, mut b) = ticket(&mut c, b).await;
        let server = tokio::spawn(async move {
            let r = protocol::read(&mut b).await.unwrap();
            assert_eq!(r["method"], protocol::DISCOVER);
            if change_peer {
                alive.store(false, Ordering::SeqCst);
            }
            reply(
                &mut b,
                &ok(&r, OWNER, json!({"supportsUntrustedAppInput":change_peer})),
            )
            .await;
            assert_eq!(
                protocol::read(&mut b).await.err(),
                Some(OwnerError::Disconnected)
            );
        });
        assert!(matches!(
            c.start_text(&t, OP, "x", TIME, &Cancellation::default())
                .await,
            ActionOutcome::NotSent(_)
        ));
        server.await.unwrap();
    }
}

#[tokio::test]
async fn cancellation_after_possible_write_is_unknown_and_closes_only_client() {
    let (mut c, b, _) = setup().await;
    let (t, mut b) = ticket(&mut c, b).await;
    let cancel = Cancellation::default();
    let other = cancel.clone();
    let server = tokio::spawn(async move {
        discovery(&mut b, true).await;
        let r = protocol::read(&mut b).await.unwrap();
        assert_eq!(r["method"], protocol::START);
        other.cancel();
        assert_eq!(
            protocol::read(&mut b).await.err(),
            Some(OwnerError::Disconnected)
        );
    });
    assert_eq!(
        c.start_text(&t, OP, "x", TIME, &cancel).await,
        ActionOutcome::Unknown
    );
    server.await.unwrap();
}

#[tokio::test]
async fn partial_frames_and_invalid_size_are_bounded() {
    let (a, mut b) = tokio::io::duplex(128);
    let mut a: Box<dyn Socket> = Box::new(a);
    let f = protocol::frame(&json!({"x":1})).unwrap();
    let server = tokio::spawn(async move {
        for part in f.chunks(1) {
            b.write_all(part).await.unwrap();
        }
    });
    assert_eq!(protocol::read(a.as_mut()).await.unwrap(), json!({"x":1}));
    server.await.unwrap();
    for header in [0u32, (protocol::MAX_FRAME + 1) as u32] {
        let (mut a, mut b) = tokio::io::duplex(8);
        b.write_all(&header.to_le_bytes()).await.unwrap();
        assert_eq!(
            protocol::read(&mut a).await.err(),
            Some(OwnerError::InvalidFrame)
        );
    }
    let (mut a, mut b) = tokio::io::duplex(8);
    b.write_all(&[1, 0, 0, 0, b'{']).await.unwrap();
    assert_eq!(
        protocol::read(&mut a).await.err(),
        Some(OwnerError::InvalidFrame)
    );
}

#[tokio::test]
async fn snapshot_only_accepts_matching_owner_thread_version_targets_and_revision() {
    let (mut c, b, _) = setup().await;
    let (t, mut b) = ticket(&mut c, b).await;
    let server = tokio::spawn(async move {
        let f = protocol::read(&mut b).await.unwrap();
        assert_eq!(f["method"], "thread-stream-following-changed");
        assert_eq!(f["version"], 1);
        assert_eq!(f["params"]["following"], true);
        let valid = json!({"type":"broadcast","method":"thread-stream-state-changed","version":11,"sourceClientId":OWNER,"targetClientIds":[CLIENT],"params":{"hostId":"local","conversationId":THREAD,"change":{"type":"snapshot","revision":2,"conversationState":{"synthetic":true}}}});
        for which in 0..5 {
            let mut wrong = valid.clone();
            match which {
                0 => wrong["sourceClientId"] = json!(CLIENT),
                1 => wrong["version"] = json!(10),
                2 => wrong["params"]["conversationId"] = json!(TURN),
                3 => wrong["targetClientIds"] = json!([]),
                _ => wrong["params"]["change"]["type"] = json!("patches"),
            };
            reply(&mut b, &wrong).await;
        }
        reply(&mut b, &valid).await;
        let f = protocol::read(&mut b).await.unwrap();
        assert_eq!(f["params"]["following"], false);
    });
    let s = c
        .snapshot(&t, TIME, &Cancellation::default())
        .await
        .unwrap();
    assert_eq!(s.revision, 2);
    assert_eq!(s.state.get("synthetic"), Some(&json!(true)));
    server.await.unwrap();
    let v = json!({"type":"broadcast","method":"thread-stream-state-changed","version":11,"sourceClientId":OWNER,"targetClientIds":[CLIENT],"params":{"hostId":"local","conversationId":THREAD,"change":{"type":"snapshot","revision":2,"conversationState":{}}}});
    let previous = (2, protocol::state_digest(&s.state));
    assert!(protocol::snapshot(&v, CLIENT, &t, Some(&previous)).is_none());
    let previous = (
        3,
        protocol::state_digest(
            v["params"]["change"]["conversationState"]
                .as_object()
                .unwrap(),
        ),
    );
    assert!(protocol::snapshot(&v, CLIENT, &t, Some(&previous)).is_none());
}

#[tokio::test]
async fn a_new_follow_accepts_identical_unchanged_snapshot_without_claiming_progress() {
    let (mut c, b, _) = setup().await;
    let (t, mut b) = ticket(&mut c, b).await;
    let server = tokio::spawn(async move {
        for _ in 0..2 {
            assert_eq!(
                protocol::read(&mut b).await.unwrap()["params"]["following"],
                true
            );
            reply(&mut b,&json!({"type":"broadcast","method":"thread-stream-state-changed","version":11,"sourceClientId":OWNER,"targetClientIds":[CLIENT],"params":{"hostId":"local","conversationId":THREAD,"change":{"type":"snapshot","revision":2,"conversationState":{"synthetic":true}}}})).await;
            assert_eq!(
                protocol::read(&mut b).await.unwrap()["params"]["following"],
                false
            );
        }
    });
    let a = c
        .snapshot(&t, TIME, &Cancellation::default())
        .await
        .unwrap();
    let b = c
        .snapshot(&t, TIME, &Cancellation::default())
        .await
        .unwrap();
    assert_eq!(a.revision, b.revision);
    assert_eq!(a.state, b.state);
    server.await.unwrap();
}

#[tokio::test]
async fn client_discovery_never_advertises_an_owner() {
    let (mut c, mut b, _) = setup().await;
    let server = tokio::spawn(async move {
        let request = protocol::read(&mut b).await.unwrap();
        reply(&mut b,&json!({"type":"client-discovery-request","requestId":OP,"request":{"method":protocol::START}})).await;
        let r = protocol::read(&mut b).await.unwrap();
        assert_eq!(
            r,
            json!({"type":"client-discovery-response","requestId":OP,"response":{"canHandle":false}})
        );
        reply(
            &mut b,
            &ok(&request, OWNER, json!({"supportsUntrustedAppInput":true})),
        )
        .await;
    });
    c.discover(THREAD, TIME, &Cancellation::default())
        .await
        .unwrap();
    server.await.unwrap();
}
