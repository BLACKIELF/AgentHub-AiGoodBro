use super::{reducer::Reducer, *};
use serde_json::{json, Value};

const THREAD: &str = "00000000-0000-0000-0000-000000000001";
const TURN: &str = "00000000-0000-0000-0000-000000000002";
const NEXT_TURN: &str = "00000000-0000-0000-0000-000000000003";
fn scope() -> SystemDaemonScope {
    SystemDaemonScope {
        canonical_home: std::env::temp_dir().join("synthetic-system-only"),
        profile_id: "a".repeat(32),
        identity_hash: "b".repeat(64),
        credential_generation: "c".repeat(32),
        auth_digest: "d".repeat(64),
        established_at_unix_ms: 1,
    }
}
fn reducer() -> Reducer {
    Reducer::new(scope(), "e".repeat(32), super::super::now_ms()).unwrap()
}
fn row(state: &str) -> Value {
    json!({"thread":{"id":THREAD,"status":{"type":state}}})
}
fn current_turn(status: &str, now: u64) -> Value {
    json!({"data":[{"id":TURN,"status":status,"itemsView":"notLoaded","items":[],"startedAt":(now-1_000)/1_000,"completedAt":if status=="completed" {Some(now/1_000)} else {None}}],"nextCursor":"older-history-is-not-loaded-roster"})
}
fn complete(r: &mut Reducer, request: u64, state: &str, status: &str, now: u64) {
    let b = r.begin(request, now).unwrap();
    r.loaded(b, &json!({"data":[THREAD],"nextCursor":null}))
        .unwrap();
    r.row(b, THREAD, &row(state)).unwrap();
    r.turn(b, THREAD, &current_turn(status, now), now).unwrap();
    r.finish(b, now).unwrap();
}
#[test]
fn official_live_complete_roster_and_same_turn_metadata_are_memory_only() {
    let now = super::super::now_ms();
    let mut r = reducer();
    complete(&mut r, 1, "idle", "completed", now);
    let snapshot = r.snapshot(now).unwrap();
    assert!(snapshot.is_current());
    assert_eq!(snapshot.records().len(), 1);
    assert_eq!(snapshot.records()[0].state, TaskState::Idle);
    assert_eq!(snapshot.records()[0].turn_state, Some(TaskState::Completed));
    assert_eq!(snapshot.records()[0].turn_id.as_deref(), Some(TURN));
    assert_eq!(snapshot.identity_hash(), "b".repeat(64));
    r.invalidate();
    assert!(!snapshot.is_current());
    assert!(r.snapshot(now).is_err());
}
#[test]
fn official_live_cursor_duplicate_unknown_and_missing_loaded_status_never_prove_idle() {
    let now = super::super::now_ms();
    for loaded in [
        json!({"data":[THREAD],"nextCursor":"more"}),
        json!({"data":[THREAD,THREAD],"nextCursor":null}),
        json!({"data":[THREAD]}),
        json!({"data":["not-a-codex-thread"],"nextCursor":null}),
    ] {
        let mut r = reducer();
        let b = r.begin(1, now).unwrap();
        assert!(r.loaded(b, &loaded).is_err());
        assert!(r.snapshot(now).is_err());
    }
    let mut r = reducer();
    let b = r.begin(1, now).unwrap();
    r.loaded(b, &json!({"data":[THREAD],"nextCursor":null}))
        .unwrap();
    assert!(r.finish(b, now).is_err());
    assert!(r.snapshot(now).is_err());
    let mut r = reducer();
    let b = r.begin(1, now).unwrap();
    r.loaded(b, &json!({"data":[THREAD],"nextCursor":null}))
        .unwrap();
    assert!(r.row(b, THREAD, &row("notLoaded")).is_err());
    assert!(r.row(b, THREAD, &row("futureUnknownStatus")).is_err());
}
#[test]
fn official_live_notification_after_request_wins_over_late_idle_and_omission() {
    let now = super::super::now_ms();
    let mut r = reducer();
    complete(&mut r, 1, "idle", "completed", now);
    let old = r.snapshot(now).unwrap();
    let b = r.begin(2, now).unwrap();
    r.notification("turn/started",&json!({"threadId":THREAD,"turn":{"id":NEXT_TURN,"status":"inProgress","startedAt":now/1_000}}),now).unwrap();
    assert!(!old.is_current());
    r.loaded(b, &json!({"data":[],"nextCursor":null})).unwrap();
    r.finish(b, now).unwrap();
    let current = r.snapshot(now).unwrap();
    assert_eq!(current.records()[0].turn_state, Some(TaskState::Running));
    assert_eq!(current.records()[0].turn_id.as_deref(), Some(NEXT_TURN));
    assert!(!r.notification("turn/completed",&json!({"threadId":THREAD,"turn":{"id":TURN,"status":"completed","startedAt":(now-1_000)/1_000,"completedAt":now/1_000}}),now).unwrap());
    assert_eq!(
        r.snapshot(now).unwrap().records()[0].turn_state,
        Some(TaskState::Running)
    );
}
#[test]
fn official_live_waiting_remains_busy_and_metadata_cannot_override_newer_notification() {
    let now = super::super::now_ms();
    let mut r = reducer();
    let b = r.begin(1, now).unwrap();
    r.loaded(b, &json!({"data":[THREAD],"nextCursor":null}))
        .unwrap();
    r.row(b,THREAD,&json!({"thread":{"id":THREAD,"status":{"type":"active","activeFlags":["waitingOnUserInput"]}}})).unwrap();
    r.turn(b, THREAD, &current_turn("inProgress", now), now)
        .unwrap();
    r.finish(b, now).unwrap();
    assert_eq!(
        r.snapshot(now).unwrap().records()[0].state,
        TaskState::WaitingInput
    );
    assert!(r
        .notification(
            "thread/status/changed",
            &json!({"threadId":THREAD,"status":{"type":"active","activeFlags":["unknownFlag"]}}),
            now
        )
        .is_err());
}
#[test]
fn official_live_old_boundary_reconnect_and_overflow_are_rejected() {
    let now = super::super::now_ms();
    let mut r = reducer();
    let old = r.begin(1, now).unwrap();
    r.loaded(old, &json!({"data":[],"nextCursor":null}))
        .unwrap();
    r.finish(old, now).unwrap();
    let b = r.begin(2, now).unwrap();
    assert!(r
        .loaded(old, &json!({"data":[],"nextCursor":null}))
        .is_err());
    let ids = (0..=MAXIMUM_THREADS)
        .map(|i| format!("00000000-0000-0000-0000-{i:012x}"))
        .collect::<Vec<_>>();
    assert_eq!(
        r.loaded(b, &json!({"data":ids,"nextCursor":null}))
            .unwrap_err(),
        LiveIssue::Overflow
    );
    r.invalidate();
    assert!(r.begin(3, now).is_err());
}
#[test]
fn official_live_unrelated_notifications_cannot_extend_complete_roster_freshness() {
    let now = super::super::now_ms();
    let mut r = reducer();
    complete(&mut r, 1, "idle", "completed", now);
    assert!(!r
        .notification("account/rateLimits/updated", &json!({}), now + 46_000)
        .unwrap());
    assert!(r.snapshot(now + 46_000).is_err());
}

#[test]
fn official_live_fresh_turn_metadata_replaces_the_previous_turn() {
    let now = super::super::now_ms();
    let mut r = reducer();
    complete(&mut r, 1, "idle", "completed", now);
    let b = r.begin(2, now).unwrap();
    r.loaded(b, &json!({"data":[THREAD],"nextCursor":null}))
        .unwrap();
    r.row(b, THREAD, &row("idle")).unwrap();
    let mut turns = current_turn("inProgress", now);
    turns["data"][0]["id"] = json!(NEXT_TURN);
    r.turn(b, THREAD, &turns, now).unwrap();
    r.finish(b, now).unwrap();
    let snapshot = r.snapshot(now).unwrap();
    assert_eq!(snapshot.records()[0].turn_id.as_deref(), Some(NEXT_TURN));
    assert_eq!(snapshot.records()[0].turn_state, Some(TaskState::Running));
    assert_eq!(snapshot.records()[0].turn_completed_at_unix_ms, None);
}

#[test]
fn official_live_late_completion_never_clears_a_newer_busy_runtime() {
    let now = super::super::now_ms();
    let mut r = reducer();
    complete(&mut r, 1, "idle", "completed", now);
    r.notification(
        "thread/status/changed",
        &json!({"threadId":THREAD,"status":{"type":"active","activeFlags":[]}}),
        now,
    )
    .unwrap();
    assert!(!r.notification("turn/completed",&json!({"threadId":THREAD,"turn":{"id":TURN,"status":"completed","startedAt":(now-1_000)/1_000,"completedAt":now/1_000}}),now).unwrap());
    let snapshot = r.snapshot(now).unwrap();
    assert_eq!(snapshot.records()[0].state, TaskState::Running);
    assert_eq!(snapshot.records()[0].turn_id, None);
    assert_eq!(snapshot.records()[0].turn_state, None);
}

#[test]
fn official_live_completion_metadata_preserves_runtime_waiting_until_official_idle() {
    let now = super::super::now_ms();
    let mut r = reducer();
    let b = r.begin(1, now).unwrap();
    r.loaded(b, &json!({"data":[THREAD],"nextCursor":null}))
        .unwrap();
    r.row(b, THREAD, &json!({"thread":{"id":THREAD,"status":{"type":"active","activeFlags":["waitingOnApproval"]}}})).unwrap();
    r.turn(b, THREAD, &current_turn("inProgress", now), now)
        .unwrap();
    r.finish(b, now).unwrap();
    r.notification("turn/completed",&json!({"threadId":THREAD,"turn":{"id":TURN,"status":"completed","startedAt":(now-1_000)/1_000,"completedAt":now/1_000}}),now).unwrap();
    let snapshot = r.snapshot(now).unwrap();
    assert_eq!(snapshot.records()[0].state, TaskState::WaitingInput);
    assert_eq!(snapshot.records()[0].turn_state, Some(TaskState::Completed));
    r.notification(
        "thread/status/changed",
        &json!({"threadId":THREAD,"status":{"type":"idle"}}),
        now,
    )
    .unwrap();
    assert_eq!(r.snapshot(now).unwrap().records()[0].state, TaskState::Idle);
    assert!(!r.notification("turn/started",&json!({"threadId":THREAD,"turn":{"id":TURN,"status":"inProgress","startedAt":(now-1_000)/1_000}}),now).unwrap());
    assert_eq!(
        r.snapshot(now).unwrap().records()[0].turn_state,
        Some(TaskState::Completed)
    );
}

struct FixtureAuthority {
    valid: AtomicBool,
}
impl SystemScopeAuthority for FixtureAuthority {
    fn current(&self) -> LiveResult<SystemDaemonScope> {
        if self.valid.load(Ordering::Acquire) {
            Ok(scope())
        } else {
            Err(LiveIssue::ScopeUnverified)
        }
    }
    fn recheck(&self, value: &SystemDaemonScope) -> LiveResult<()> {
        if self.valid.load(Ordering::Acquire) && *value == scope() {
            Ok(())
        } else {
            Err(LiveIssue::ScopeUnverified)
        }
    }
}
struct FixtureActivity;
impl SystemActivitySource for FixtureActivity {
    fn current(&self) -> LiveResult<SystemActivityEvidence> {
        let now = super::super::now_ms();
        Ok(SystemActivityEvidence {
            observed_at_unix_ms: now,
            inactive_since_unix_ms: Some(now - 121_000),
            legacy_manager_running: Some(false),
            dispatch_busy: Some(false),
        })
    }
}
struct FixturePeer(Arc<AtomicBool>);
impl client::VerifiedPeer for FixturePeer {
    fn recheck(&self) -> LiveResult<()> {
        if self.0.load(Ordering::Acquire) {
            Ok(())
        } else {
            Err(LiveIssue::PeerUntrusted)
        }
    }
}
struct FixtureObserver(std::sync::Mutex<Vec<&'static str>>);
impl LiveTaskObserver for FixtureObserver {
    fn record(&self, event: LiveTaskEvent) {
        self.0.lock().unwrap().push(match event {
            LiveTaskEvent::Reset { .. } => "reset",
            LiveTaskEvent::Snapshot(_) => "snapshot",
        });
    }
}
struct FixtureConnector {
    connected: std::sync::atomic::AtomicUsize,
    peer: Arc<AtomicBool>,
    malformed: bool,
    signal: Arc<std::sync::atomic::AtomicUsize>,
    requests: Arc<std::sync::atomic::AtomicUsize>,
}
impl client::Connector for FixtureConnector {
    fn connect<'a>(
        &'a self,
        _: &'a SystemDaemonScope,
        _: Arc<AtomicBool>,
    ) -> client::Connected<'a> {
        Box::pin(async move {
            use futures_util::{SinkExt, StreamExt};
            use tokio_tungstenite::tungstenite::{protocol::Role, Message};
            self.connected.fetch_add(1, Ordering::AcqRel);
            let (client, server) = tokio::io::duplex(64 * 1024);
            let malformed = self.malformed;
            let signal = self.signal.clone();
            let requests = self.requests.clone();
            tokio::spawn(async move {
                let mut socket =
                    tokio_tungstenite::WebSocketStream::from_raw_socket(server, Role::Server, None)
                        .await;
                loop {
                    let message = tokio::select! {
                        message = socket.next() => message,
                        _ = tokio::time::sleep(std::time::Duration::from_millis(5)) => {
                            let message = match signal.swap(0, Ordering::AcqRel) {
                                0 => continue,
                                1 => break, // Actual in-memory stream EOF.
                                2 => json!({"method":"thread/status/changed","params":{"threadId":THREAD,"status":{"type":"futureUnknownStatus"}}}).to_string(),
                                3 => json!({"method":"thread/status/changed","params":{"threadId":THREAD,"status":{"type":"idle"}}}).to_string(),
                                4 => " ".repeat(MAXIMUM_MESSAGE_BYTES + 1),
                                5 => json!({"id":77,"method":"item/commandExecution/requestApproval","params":{}}).to_string(),
                                _ => panic!("unknown test control"),
                            };
                            if socket.send(Message::Text(message.into())).await.is_err() { break; }
                            continue;
                        },
                    };
                    let Some(Ok(Message::Text(text))) = message else {
                        break;
                    };
                    let value: Value = serde_json::from_str(&text).unwrap();
                    let Some(id) = value.get("id").cloned() else {
                        continue;
                    };
                    requests.fetch_add(1, Ordering::AcqRel);
                    let result = match value["method"].as_str().unwrap() {
                        "initialize" => {
                            json!({"codexHome":scope().canonical_home.to_string_lossy()})
                        }
                        "thread/loaded/list" => {
                            if malformed {
                                json!({"data":[],"nextCursor":"not-complete"})
                            } else {
                                json!({"data":[THREAD],"nextCursor":null})
                            }
                        }
                        "thread/read" => row("idle"),
                        "thread/turns/list" => current_turn("completed", super::super::now_ms()),
                        _ => panic!("readonly fixture received unsupported operation"),
                    };
                    if socket
                        .send(Message::Text(
                            json!({"id":id,"result":result}).to_string().into(),
                        ))
                        .await
                        .is_err()
                    {
                        break;
                    }
                }
            });
            let socket: client::Socket = Box::new(client);
            Ok(client::Connection {
                socket: tokio_tungstenite::WebSocketStream::from_raw_socket(
                    socket,
                    Role::Client,
                    None,
                )
                .await,
                peer: Box::new(FixturePeer(self.peer.clone())),
            })
        })
    }
}
#[test]
fn official_live_owned_monitor_uses_single_connection_and_cancel_seals_snapshots() {
    use std::time::{Duration, Instant};
    let authority = Arc::new(FixtureAuthority {
        valid: AtomicBool::new(true),
    });
    let connector = Arc::new(FixtureConnector {
        connected: 0.into(),
        peer: Arc::new(AtomicBool::new(true)),
        malformed: false,
        signal: Arc::new(0.into()),
        requests: Arc::new(0.into()),
    });
    let observer = Arc::new(FixtureObserver(std::sync::Mutex::new(vec![])));
    let source = SystemDaemonSource::fixture(
        authority,
        Arc::new(FixtureActivity),
        Some(observer.clone()),
        connector.clone(),
    );
    let monitor = source.start().unwrap();
    assert!(source.start().is_err());
    let until = Instant::now() + Duration::from_secs(3);
    let snapshot = loop {
        if let Ok(snapshot) = source.latest() {
            break snapshot;
        }
        assert!(
            Instant::now() < until,
            "synthetic connection did not produce complete roster"
        );
        std::thread::sleep(Duration::from_millis(5));
    };
    assert_eq!(snapshot.records()[0].state, TaskState::Idle);
    assert_eq!(snapshot.records()[0].turn_state, Some(TaskState::Completed));
    assert_eq!(connector.connected.load(Ordering::Acquire), 1);
    // This fixture supplies fresh external idle/legacy booleans, but has no
    // private native process receipt. Observation cannot authorize a switch.
    assert!(matches!(
        crate::automatic_switch::AutomaticSwitchSafetySource::snapshot(source.as_ref()),
        Err(crate::automatic_switch::Failure::TaskUnknown)
    ));
    monitor.cancel();
    assert!(!snapshot.is_current());
    assert!(source.latest().is_err());
    while !monitor.is_finished() {
        assert!(Instant::now() < until);
        std::thread::sleep(Duration::from_millis(5));
    }
    let count = observer
        .0
        .lock()
        .unwrap()
        .iter()
        .filter(|&&v| v == "snapshot")
        .count();
    std::thread::sleep(Duration::from_millis(80));
    assert_eq!(
        observer
            .0
            .lock()
            .unwrap()
            .iter()
            .filter(|&&v| v == "snapshot")
            .count(),
        count
    );
    let restarted = source.start().unwrap();
    let next = loop {
        if let Ok(next) = source.latest() {
            break next;
        }
        assert!(Instant::now() < until);
        std::thread::sleep(Duration::from_millis(5));
    };
    assert!(next.connection_generation() > snapshot.connection_generation());
    assert!(!snapshot.is_current());
    assert_eq!(connector.connected.load(Ordering::Acquire), 2);
    restarted.cancel();
    while !restarted.is_finished() {
        assert!(Instant::now() < until);
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn official_live_native_activity_receipt_requires_same_peer_generation_and_monotonic_freshness() {
    use crate::automatic_switch::{AutomaticSwitchSafetySource, Failure};
    use std::time::{Duration, Instant};
    let authority = Arc::new(FixtureAuthority {
        valid: AtomicBool::new(true),
    });
    let source = SystemDaemonSource::fixture(
        authority,
        Arc::new(FixtureActivity),
        None,
        Arc::new(FixtureConnector {
            connected: 0.into(),
            peer: Arc::new(AtomicBool::new(true)),
            malformed: false,
            signal: Arc::new(0.into()),
            requests: Arc::new(0.into()),
        }),
    );
    let monitor = source.start().unwrap();
    let until = Instant::now() + Duration::from_secs(3);
    let snapshot = loop {
        if let Ok(snapshot) = source.latest() {
            break snapshot;
        }
        assert!(Instant::now() < until);
        std::thread::sleep(Duration::from_millis(5));
    };
    let receipt = |generation: String, elapsed: Duration| {
        let now = super::super::now_ms();
        super::activity::BoundActivity {
            connection_generation: generation,
            peer: super::activity::PeerActivity {
                observed_at_unix_ms: now,
                observed_at: Instant::now() - elapsed,
                inactive_since_unix_ms: Some(now - 121_000),
                legacy_manager_running: false,
            },
        }
    };
    // Explicit cfg(test) receipt construction cannot be called by production.
    source.set_fixture_activity(receipt(
        snapshot.connection_generation().into(),
        Duration::ZERO,
    ));
    assert!(source.snapshot().is_ok());
    source.set_fixture_activity(receipt("another-peer".into(), Duration::ZERO));
    assert!(matches!(source.snapshot(), Err(Failure::TaskUnknown)));
    source.set_fixture_activity(receipt(
        snapshot.connection_generation().into(),
        Duration::from_secs(2),
    ));
    assert!(matches!(source.snapshot(), Err(Failure::TaskUnknown)));
    monitor.cancel();
}
#[test]
fn official_live_malformed_roster_never_publishes_empty_idle_and_stop_cancels_reconnect() {
    use std::time::{Duration, Instant};
    let connector = Arc::new(FixtureConnector {
        connected: 0.into(),
        peer: Arc::new(AtomicBool::new(true)),
        malformed: true,
        signal: Arc::new(0.into()),
        requests: Arc::new(0.into()),
    });
    let source = SystemDaemonSource::fixture(
        Arc::new(FixtureAuthority {
            valid: AtomicBool::new(true),
        }),
        Arc::new(FixtureActivity),
        None,
        connector.clone(),
    );
    let monitor = source.start().unwrap();
    let until = Instant::now() + Duration::from_secs(3);
    while source.issue() != Some(LiveIssue::Incomplete) {
        assert!(Instant::now() < until);
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(source.latest().is_err());
    monitor.cancel();
    while !monitor.is_finished() {
        assert!(Instant::now() < until);
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(connector.connected.load(Ordering::Acquire), 1);
}

#[test]
fn official_live_eof_unknown_status_oversized_message_and_server_request_revoke_idle() {
    use std::time::{Duration, Instant};
    for (signal, expected) in [
        (1, LiveIssue::Unavailable),
        (2, LiveIssue::Protocol),
        (4, LiveIssue::Overflow),
        (5, LiveIssue::Protocol),
    ] {
        let connector = Arc::new(FixtureConnector {
            connected: 0.into(),
            peer: Arc::new(AtomicBool::new(true)),
            malformed: false,
            signal: Arc::new(0.into()),
            requests: Arc::new(0.into()),
        });
        let source = SystemDaemonSource::fixture(
            Arc::new(FixtureAuthority {
                valid: AtomicBool::new(true),
            }),
            Arc::new(FixtureActivity),
            None,
            connector.clone(),
        );
        let monitor = source.start().unwrap();
        let until = Instant::now() + Duration::from_secs(3);
        let snapshot = loop {
            if let Ok(snapshot) = source.latest() {
                break snapshot;
            }
            assert!(Instant::now() < until);
            std::thread::sleep(Duration::from_millis(5));
        };
        connector.signal.store(signal, Ordering::Release);
        while snapshot.is_current() || source.latest().is_ok() {
            assert!(Instant::now() < until);
            std::thread::sleep(Duration::from_millis(5));
        }
        while source.issue() != Some(expected) {
            assert!(
                Instant::now() < until,
                "expected source failure was not retained"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
        monitor.cancel();
        while !monitor.is_finished() {
            assert!(Instant::now() < until);
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(connector.connected.load(Ordering::Acquire), 1);
        assert_eq!(connector.requests.load(Ordering::Acquire), 4);
    }
}

#[test]
fn official_live_scope_or_peer_revocation_during_notification_retires_queued_snapshot() {
    use std::time::{Duration, Instant};
    for revoke_peer in [false, true] {
        let authority = Arc::new(FixtureAuthority {
            valid: AtomicBool::new(true),
        });
        let connector = Arc::new(FixtureConnector {
            connected: 0.into(),
            peer: Arc::new(AtomicBool::new(true)),
            malformed: false,
            signal: Arc::new(0.into()),
            requests: Arc::new(0.into()),
        });
        let source = SystemDaemonSource::fixture(
            authority.clone(),
            Arc::new(FixtureActivity),
            None,
            connector.clone(),
        );
        let monitor = source.start().unwrap();
        let until = Instant::now() + Duration::from_secs(3);
        let snapshot = loop {
            if let Ok(snapshot) = source.latest() {
                break snapshot;
            }
            assert!(Instant::now() < until);
            std::thread::sleep(Duration::from_millis(5));
        };
        if revoke_peer {
            connector.peer.store(false, Ordering::Release);
        } else {
            authority.valid.store(false, Ordering::Release);
        }
        connector.signal.store(3, Ordering::Release);
        while snapshot.is_current() || source.latest().is_ok() {
            assert!(Instant::now() < until);
            std::thread::sleep(Duration::from_millis(5));
        }
        monitor.cancel();
        while !monitor.is_finished() {
            assert!(Instant::now() < until);
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}

#[test]
fn official_live_untrusted_peer_receives_no_initialize_or_session_data() {
    use std::time::{Duration, Instant};
    let connector = Arc::new(FixtureConnector {
        connected: 0.into(),
        peer: Arc::new(AtomicBool::new(false)),
        malformed: false,
        signal: Arc::new(0.into()),
        requests: Arc::new(0.into()),
    });
    let source = SystemDaemonSource::fixture(
        Arc::new(FixtureAuthority {
            valid: AtomicBool::new(true),
        }),
        Arc::new(FixtureActivity),
        None,
        connector.clone(),
    );
    let monitor = source.start().unwrap();
    let until = Instant::now() + Duration::from_secs(3);
    while source.issue() != Some(LiveIssue::PeerUntrusted) {
        assert!(Instant::now() < until);
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(connector.requests.load(Ordering::Acquire), 0);
    assert!(source.latest().is_err());
    monitor.cancel();
    while !monitor.is_finished() {
        assert!(Instant::now() < until);
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn official_live_private_backend_or_disconnection_cannot_authorize_global_idle() {
    use crate::automatic_switch::{ConnectionMode, SafetySnapshot};
    let now = super::super::now_ms();
    let mut value = SafetySnapshot {
        identity_hash: "b".repeat(64),
        credential_generation: "c".repeat(32),
        connection_generation: "e".repeat(32),
        captured_at_ms: now,
        connection: ConnectionMode::SharedDaemon,
        tasks: vec![],
        inactive_since_ms: Some(now - 121_000),
        legacy_manager_running: Some(false),
    };
    assert!(value
        .validate_idle(&"b".repeat(64), &"c".repeat(32), None, now)
        .is_ok());
    for mode in [ConnectionMode::Isolated, ConnectionMode::Disconnected] {
        value.connection = mode;
        assert_eq!(
            value.validate_idle(&"b".repeat(64), &"c".repeat(32), None, now),
            Err(crate::automatic_switch::Failure::TaskUnknown)
        );
    }
}

#[test]
fn official_live_reported_home_cannot_fold_distinct_case_sensitive_directories() {
    let home = std::path::Path::new(r"\\?\C:\Users\Fixture\.codex");
    assert!(client::same_home(home, r"C:\Users\Fixture\.codex"));
    assert!(client::same_home(home, "C:/Users/Fixture/.codex/"));
    assert!(!client::same_home(home, r"C:\Users\Fixture\.Codex"));
    assert!(!client::same_home(home, r"C:\Users\Other\.codex"));
    assert!(!client::same_home(home, ""));
}
