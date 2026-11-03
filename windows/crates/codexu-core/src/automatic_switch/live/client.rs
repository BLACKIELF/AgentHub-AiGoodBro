use super::{reducer::Reducer, *};
use crate::automatic_switch::{
    AutomaticSwitchSafetySource, ConnectionMode, Failure, SafetySnapshot,
};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::{
    future::Future,
    pin::Pin,
    sync::{atomic::AtomicU64, Mutex, Weak},
    time::Duration,
};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio_tungstenite::{tungstenite::Message, WebSocketStream};

pub(super) trait Duplex: AsyncRead + AsyncWrite + Send + Unpin {}
impl<T: AsyncRead + AsyncWrite + Send + Unpin> Duplex for T {}
pub(super) type Socket = Box<dyn Duplex>;
pub(super) trait VerifiedPeer: Send {
    fn recheck(&self) -> LiveResult<()>;
    /// Only the authenticated native peer can mint global process/foreground
    /// evidence. A connector without this capability remains observation-only.
    fn activity(&self) -> LiveResult<super::activity::PeerActivity> {
        Err(LiveIssue::Unavailable)
    }
    #[cfg(windows)]
    fn close_target(&self) -> LiveResult<Arc<dyn super::quiescence::CloseTarget>> {
        Err(LiveIssue::Unavailable)
    }
}
pub(super) struct Connection {
    pub socket: WebSocketStream<Socket>,
    pub peer: Box<dyn VerifiedPeer>,
}
pub(super) type Connected<'a> = Pin<Box<dyn Future<Output = LiveResult<Connection>> + Send + 'a>>;
pub(super) trait Connector: Send + Sync {
    fn connect<'a>(&'a self, scope: &'a SystemDaemonScope, stop: Arc<AtomicBool>) -> Connected<'a>;
}
struct NativeConnector {
    domains: Arc<OwnedProcessDomains>,
}
impl Connector for NativeConnector {
    fn connect<'a>(&'a self, scope: &'a SystemDaemonScope, stop: Arc<AtomicBool>) -> Connected<'a> {
        #[cfg(windows)]
        {
            Box::pin(super::native::connect(scope, stop, self.domains.clone()))
        }
        #[cfg(not(windows))]
        {
            let _ = (scope, stop);
            Box::pin(async { Err(LiveIssue::Unavailable) })
        }
    }
}
struct Cache {
    snapshot: Option<Arc<LiveTaskSnapshot>>,
    issue: Option<LiveIssue>,
    activity: Option<super::activity::BoundActivity>,
    #[cfg(windows)]
    close_target: Option<Arc<dyn super::quiescence::CloseTarget>>,
}
pub struct SystemDaemonSource {
    authority: Arc<dyn SystemScopeAuthority>,
    activity: Arc<dyn SystemActivitySource>,
    connector: Arc<dyn Connector>,
    observer: Option<Arc<dyn LiveTaskObserver>>,
    cache: Mutex<Cache>,
    epoch: AtomicU64,
    connection_sequence: AtomicU64,
    running: AtomicBool,
}

#[cfg(test)]
impl SystemDaemonSource {
    pub(super) fn set_fixture_activity(&self, activity: super::activity::BoundActivity) {
        self.cache.lock().unwrap().activity = Some(activity);
    }
    pub(super) fn fixture(
        authority: Arc<dyn SystemScopeAuthority>,
        activity: Arc<dyn SystemActivitySource>,
        observer: Option<Arc<dyn LiveTaskObserver>>,
        connector: Arc<dyn Connector>,
    ) -> Arc<Self> {
        Self::with_connector(authority, activity, observer, connector)
    }
}
impl SystemDaemonSource {
    pub fn native(
        authority: Arc<dyn SystemScopeAuthority>,
        activity: Arc<dyn SystemActivitySource>,
        observer: Option<Arc<dyn LiveTaskObserver>>,
    ) -> LiveResult<Arc<Self>> {
        Self::native_with_owned_domains(authority, activity, observer, OwnedProcessDomains::new())
    }
    pub fn native_with_owned_domains(
        authority: Arc<dyn SystemScopeAuthority>,
        activity: Arc<dyn SystemActivitySource>,
        observer: Option<Arc<dyn LiveTaskObserver>>,
        domains: Arc<OwnedProcessDomains>,
    ) -> LiveResult<Arc<Self>> {
        if !cfg!(windows) {
            return Err(LiveIssue::Unavailable);
        }
        Ok(Self::with_connector(
            authority,
            activity,
            observer,
            Arc::new(NativeConnector { domains }),
        ))
    }
    fn with_connector(
        authority: Arc<dyn SystemScopeAuthority>,
        activity: Arc<dyn SystemActivitySource>,
        observer: Option<Arc<dyn LiveTaskObserver>>,
        connector: Arc<dyn Connector>,
    ) -> Arc<Self> {
        Arc::new(Self {
            authority,
            activity,
            observer,
            connector,
            cache: Mutex::new(Cache {
                snapshot: None,
                issue: Some(LiveIssue::Unavailable),
                activity: None,
                #[cfg(windows)]
                close_target: None,
            }),
            epoch: AtomicU64::new(0),
            connection_sequence: AtomicU64::new(0),
            running: AtomicBool::new(false),
        })
    }
    pub fn latest(&self) -> LiveResult<Arc<LiveTaskSnapshot>> {
        self.cache
            .try_lock()
            .map_err(|_| LiveIssue::Unavailable)?
            .snapshot
            .as_ref()
            .filter(|s| s.is_current())
            .cloned()
            .ok_or(LiveIssue::Incomplete)
    }
    pub fn issue(&self) -> Option<LiveIssue> {
        self.cache
            .try_lock()
            .map(|c| c.issue)
            .unwrap_or(Some(LiveIssue::Unavailable))
    }
    fn invalidate(&self, epoch: u64, issue: LiveIssue) {
        if self.epoch.load(Ordering::Acquire) != epoch {
            return;
        }
        if let Ok(mut cache) = self.cache.lock() {
            if self.epoch.load(Ordering::Acquire) != epoch {
                return;
            }
            if let Some(snapshot) = cache.snapshot.take() {
                snapshot.valid.store(false, Ordering::Release);
            }
            cache.issue = Some(issue);
            cache.activity = None;
            #[cfg(windows)]
            {
                cache.close_target = None;
            }
        }
        if self.epoch.load(Ordering::Acquire) == epoch {
            if let Some(observer) = &self.observer {
                observer.record(LiveTaskEvent::Reset { issue });
            }
        }
    }
    fn pending_update(&self, epoch: u64) -> LiveResult<()> {
        let mut cache = self.cache.lock().map_err(|_| LiveIssue::Unavailable)?;
        if self.epoch.load(Ordering::Acquire) != epoch {
            return Err(LiveIssue::Cancelled);
        }
        // A known new event must fence the old idle cache before any manager
        // recheck or list-response wait. It does not invalidate this peer.
        cache.snapshot = None;
        cache.issue = Some(LiveIssue::Incomplete);
        Ok(())
    }
    fn sample_activity(&self, epoch: u64, peer: &dyn VerifiedPeer, generation: &str) {
        let activity = peer
            .activity()
            .ok()
            .map(|peer| super::activity::BoundActivity {
                peer,
                connection_generation: generation.to_owned(),
            });
        if let Ok(mut cache) = self.cache.lock() {
            if self.epoch.load(Ordering::Acquire) == epoch {
                cache.activity = activity;
            }
        }
    }
    fn publish(
        &self,
        epoch: u64,
        snapshot: Arc<LiveTaskSnapshot>,
        stop: &AtomicBool,
    ) -> LiveResult<()> {
        if stop.load(Ordering::Acquire) || self.epoch.load(Ordering::Acquire) != epoch {
            return Err(LiveIssue::Cancelled);
        }
        self.authority.recheck(&snapshot.scope)?;
        let mut cache = self.cache.lock().map_err(|_| LiveIssue::Unavailable)?;
        if stop.load(Ordering::Acquire)
            || self.epoch.load(Ordering::Acquire) != epoch
            || !snapshot.is_current()
        {
            return Err(LiveIssue::Cancelled);
        }
        cache.snapshot = Some(snapshot.clone());
        cache.issue = None;
        drop(cache);
        if !stop.load(Ordering::Acquire) && self.epoch.load(Ordering::Acquire) == epoch {
            if let Some(observer) = &self.observer {
                observer.record(LiveTaskEvent::Snapshot(snapshot));
            }
        }
        Ok(())
    }
    pub fn start(self: &Arc<Self>) -> LiveResult<SystemDaemonMonitor> {
        self.running
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .map_err(|_| LiveIssue::Unavailable)?;
        let epoch = self
            .epoch
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |v| v.checked_add(1))
            .map_err(|_| {
                self.running.store(false, Ordering::Release);
                LiveIssue::Overflow
            })?
            + 1;
        self.invalidate(epoch, LiveIssue::Unavailable);
        let stop = Arc::new(AtomicBool::new(false));
        let worker_stop = stop.clone();
        let source = self.clone();
        let thread = std::thread::Builder::new()
            .name("agb-official-system-tasks".into())
            .spawn(move || {
                let runtime = match tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                {
                    Ok(runtime) => runtime,
                    Err(_) => {
                        source.invalidate(epoch, LiveIssue::Unavailable);
                        source.running.store(false, Ordering::Release);
                        return;
                    }
                };
                runtime.block_on(async {
                    // Mac's live client permits one delayed reconnect per explicit
                    // lifecycle start. Never create or restart a business process.
                    for attempt in 0..2 {
                        if worker_stop.load(Ordering::Acquire) {
                            break;
                        }
                        let issue = source
                            .session(epoch, worker_stop.clone())
                            .await
                            .err()
                            .unwrap_or(LiveIssue::Unavailable);
                        source.invalidate(epoch, issue);
                        if issue == LiveIssue::Cancelled || attempt == 1 {
                            break;
                        }
                        if cancellable(&worker_stop, Duration::from_secs(31), async {
                            tokio::time::sleep(Duration::from_secs(30)).await;
                            Ok(())
                        })
                        .await
                        .is_err()
                        {
                            break;
                        }
                    }
                });
                if worker_stop.load(Ordering::Acquire) {
                    source.invalidate(epoch, LiveIssue::Cancelled);
                }
                runtime.shutdown_timeout(Duration::from_millis(100));
                // A replacement cannot start until this worker releases the
                // running flag, including after cancellation changed its epoch.
                source.running.store(false, Ordering::Release);
            })
            .map_err(|_| {
                self.running.store(false, Ordering::Release);
                LiveIssue::Unavailable
            })?;
        Ok(SystemDaemonMonitor {
            source: Arc::downgrade(self),
            epoch,
            stop,
            thread: Some(thread),
        })
    }
    async fn session(&self, epoch: u64, stop: Arc<AtomicBool>) -> LiveResult<()> {
        let scope = self.authority.current()?;
        scope.validate(super::super::now_ms())?;
        let mut connection = cancellable(
            &stop,
            Duration::from_secs(5),
            self.connector.connect(&scope, stop.clone()),
        )
        .await?;
        connection.peer.recheck()?;
        self.authority.recheck(&scope)?;
        let sequence = self
            .connection_sequence
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |v| v.checked_add(1))
            .map_err(|_| LiveIssue::Overflow)?
            + 1;
        // Generation is local, increasing and memory-only. A reconnect within
        // this monitor's epoch still gets a new generation; old snapshots are
        // separately invalidated before either connection can publish.
        let generation = format!("{epoch:016x}{sequence:016x}");
        let mut reducer = Reducer::new(scope.clone(), generation.clone(), super::super::now_ms())?;
        #[cfg(windows)]
        if let Ok(mut cache) = self.cache.lock() {
            if self.epoch.load(Ordering::Acquire) == epoch {
                // Failure to capture a verified GUI path keeps observation
                // available, while graceful system switching stays unavailable.
                cache.close_target = connection.peer.close_target().ok();
            }
        }
        let result = async {
            let mut next_id = 1u64;
            let init = request(self, epoch, &mut connection, &mut reducer, &stop, &mut next_id, "initialize", json!({"clientInfo":{"name":"aigoodbro-windows","title":"AiGoodBro","version":env!("CARGO_PKG_VERSION")},"capabilities":{"experimentalApi":false,"optOutNotificationMethods":[]}})).await?;
            if !same_home(&scope.canonical_home, init.get("codexHome").and_then(Value::as_str).ok_or(LiveIssue::ScopeUnverified)?) { return Err(LiveIssue::ScopeUnverified); }
            send(&mut connection, &stop, json!({"method":"initialized"})).await?;
            self.refresh(&mut connection, &mut reducer, &stop, &mut next_id, epoch).await?;
            let mut refresh_at = tokio::time::Instant::now() + Duration::from_secs(10);
            let mut activity_at = tokio::time::Instant::now();
            loop {
                let message = tokio::select! {
                    _ = cancelled(&stop) => return Err(LiveIssue::Cancelled),
                    _ = tokio::time::sleep_until(activity_at) => {
                        connection.peer.recheck()?;
                        self.sample_activity(epoch, connection.peer.as_ref(), &generation);
                        activity_at = tokio::time::Instant::now() + Duration::from_secs(1);
                        continue;
                    },
                    _ = tokio::time::sleep_until(refresh_at) => {
                        self.refresh(&mut connection, &mut reducer, &stop, &mut next_id, epoch).await?;
                        refresh_at = tokio::time::Instant::now() + Duration::from_secs(10);
                        continue;
                    },
                    message = connection.socket.next() => decode(message)?,
                };
                if let Some(message) = message {
                    if !notification(&mut reducer, &message)? { continue; }
                    self.pending_update(epoch)?;
                    connection.peer.recheck()?;
                    self.publish(epoch, reducer.snapshot(super::super::now_ms())?, &stop)?;
                }
            }
        }.await;
        reducer.invalidate();
        result
    }
    async fn refresh(
        &self,
        connection: &mut Connection,
        reducer: &mut Reducer,
        stop: &AtomicBool,
        next_id: &mut u64,
        epoch: u64,
    ) -> LiveResult<()> {
        let boundary = reducer.begin(*next_id, super::super::now_ms())?;
        let operation = async {
            let result = request(
                self,
                epoch,
                connection,
                reducer,
                stop,
                next_id,
                "thread/loaded/list",
                json!({"limit":MAXIMUM_THREADS+1}),
            )
            .await?;
            let ids = reducer.loaded(boundary, &result)?;
            for id in ids {
                let row = request(
                    self,
                    epoch,
                    connection,
                    reducer,
                    stop,
                    next_id,
                    "thread/read",
                    json!({"threadId":id,"includeTurns":false}),
                )
                .await?;
                reducer.row(boundary, &id, &row)?;
                let turns = request(
                    self,
                    epoch,
                    connection,
                    reducer,
                    stop,
                    next_id,
                    "thread/turns/list",
                    json!({"threadId":id,"limit":1,"sortDirection":"desc","itemsView":"notLoaded"}),
                )
                .await?;
                reducer.turn(boundary, &id, &turns, super::super::now_ms())?;
            }
            connection.peer.recheck()?;
            reducer.finish(boundary, super::super::now_ms())?;
            self.publish(epoch, reducer.snapshot(super::super::now_ms())?, stop)
        };
        cancellable(stop, Duration::from_secs(20), operation).await
    }
}
#[cfg(windows)]
impl SystemDaemonSource {
    /// Rust-only: the concrete same-domain lease must already cover both
    /// identities before any request to close a native window is possible.
    pub fn quiesce_for_switch(
        self: &Arc<Self>,
        lease: crate::managed_proxy::AutomaticMaintenanceLease,
        automatic_epoch: u64,
        policy: Arc<dyn crate::accounts::SwitchCommitGuard>,
    ) -> LiveResult<Arc<super::quiescence::QuiescedSystemProof>> {
        lease.recheck().map_err(|_| LiveIssue::ScopeUnverified)?;
        policy.recheck().map_err(|_| LiveIssue::Cancelled)?;
        let epoch = self.epoch.load(Ordering::Acquire);
        let (snapshot, target) = {
            let cache = self.cache.try_lock().map_err(|_| LiveIssue::Unavailable)?;
            let snapshot = cache
                .snapshot
                .as_ref()
                .filter(|s| s.is_current())
                .cloned()
                .ok_or(LiveIssue::Incomplete)?;
            let native = cache
                .activity
                .as_ref()
                .filter(|activity| {
                    activity.connection_generation == snapshot.connection_generation
                        && activity.peer.current(super::super::now_ms())
                })
                .ok_or(LiveIssue::Incomplete)?;
            let scope = lease.source_scope();
            if snapshot.scope.canonical_home != scope.canonical_home()
                || snapshot.scope.profile_id != scope.profile_id()
                || snapshot.scope.identity_hash != scope.identity_hash()
                || snapshot.scope.credential_generation != scope.credential_generation()
                || snapshot.scope.auth_digest != scope.auth_digest()
                || snapshot.scope.established_at_unix_ms != scope.established_at_unix_ms()
                || native.peer.legacy_manager_running
                || !native.peer.inactive_since_unix_ms.is_some_and(|since| {
                    since <= super::super::now_ms()
                        && super::super::now_ms() - since >= crate::automatic_switch::INACTIVE_MS
                })
                || snapshot
                    .records
                    .iter()
                    .any(|r| r.state != TaskState::Idle || r.turn_state == Some(TaskState::Running))
            {
                return Err(LiveIssue::Incomplete);
            }
            (
                snapshot,
                cache.close_target.clone().ok_or(LiveIssue::Unavailable)?,
            )
        };
        self.authority.recheck(&snapshot.scope)?;
        let source = Arc::downgrade(self);
        let peer_sequence = self.connection_sequence.load(Ordering::Acquire);
        super::quiescence::QuiescedSystemProof::close(
            lease,
            automatic_epoch,
            snapshot,
            target,
            policy,
            Arc::new(move || {
                source
                    .upgrade()
                    .filter(|s| {
                        s.epoch.load(Ordering::Acquire) == epoch
                            && s.connection_sequence.load(Ordering::Acquire) == peer_sequence
                    })
                    .map(|_| ())
                    .ok_or(LiveIssue::Cancelled)
            }),
        )
    }
}
impl AutomaticSwitchSafetySource for SystemDaemonSource {
    fn live_available(&self) -> bool {
        cfg!(windows)
    }
    fn requires_native_quiescence(&self) -> bool {
        true
    }
    fn snapshot(&self) -> crate::automatic_switch::Result<SafetySnapshot> {
        let live = self.latest().map_err(|_| Failure::TaskUnknown)?;
        let activity = self.activity.current().map_err(|_| Failure::TaskUnknown)?;
        let cache = self.cache.try_lock().map_err(|_| Failure::TaskUnknown)?;
        let native = cache
            .activity
            .as_ref()
            .filter(|bound| {
                bound.connection_generation == live.connection_generation
                    && bound.peer.current(super::super::now_ms())
            })
            .ok_or(Failure::TaskUnknown)?;
        if !is_fresh(
            activity.observed_at_unix_ms,
            TASK_MAX_AGE_MS,
            super::super::now_ms(),
        ) || activity.dispatch_busy.is_none()
        {
            return Err(Failure::TaskUnknown);
        }
        let mut tasks = live.records.iter().map(|r| r.state).collect::<Vec<_>>();
        if live
            .records
            .iter()
            .any(|r| r.turn_state == Some(TaskState::Running))
        {
            // Runtime status may lag a just-started turn. The independent
            // metadata can add busy evidence but never erase runtime activity.
            tasks.push(TaskState::Running);
        }
        if activity.dispatch_busy == Some(true) {
            tasks.push(TaskState::Running);
        }
        Ok(SafetySnapshot {
            identity_hash: live.scope.identity_hash.clone(),
            credential_generation: live.scope.credential_generation.clone(),
            connection_generation: live.connection_generation.clone(),
            captured_at_ms: live
                .observed_at_unix_ms
                .min(activity.observed_at_unix_ms)
                .min(native.peer.observed_at_unix_ms),
            connection: ConnectionMode::SharedDaemon,
            tasks,
            inactive_since_ms: native.peer.inactive_since_unix_ms,
            legacy_manager_running: Some(native.peer.legacy_manager_running),
        })
    }
}
pub struct SystemDaemonMonitor {
    source: Weak<SystemDaemonSource>,
    epoch: u64,
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}
impl SystemDaemonMonitor {
    pub fn cancel(&self) {
        self.stop.store(true, Ordering::Release);
        if let Some(source) = self.source.upgrade() {
            source.invalidate(self.epoch, LiveIssue::Cancelled);
            // Explicit owner cancellation also revokes private quiescence
            // continuations. Ordinary EOF alone never changes this lifecycle.
            let _ = source.epoch.compare_exchange(
                self.epoch,
                self.epoch.saturating_add(1),
                Ordering::AcqRel,
                Ordering::Acquire,
            );
        }
    }
    pub fn is_finished(&self) -> bool {
        self.thread.as_ref().is_none_or(|t| t.is_finished())
    }
}
impl Drop for SystemDaemonMonitor {
    fn drop(&mut self) {
        self.cancel();
    }
}

async fn cancelled(stop: &AtomicBool) {
    while !stop.load(Ordering::Acquire) {
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}
pub(super) async fn cancellable<T>(
    stop: &AtomicBool,
    timeout: Duration,
    work: impl Future<Output = LiveResult<T>>,
) -> LiveResult<T> {
    if stop.load(Ordering::Acquire) {
        return Err(LiveIssue::Cancelled);
    }
    tokio::select! { _ = cancelled(stop) => Err(LiveIssue::Cancelled), result = tokio::time::timeout(timeout, work) => result.map_err(|_| LiveIssue::TimedOut)? }
}
async fn send(connection: &mut Connection, stop: &AtomicBool, value: Value) -> LiveResult<()> {
    let text = serde_json::to_string(&value).map_err(|_| LiveIssue::Protocol)?;
    if text.len() > MAXIMUM_MESSAGE_BYTES {
        return Err(LiveIssue::Overflow);
    }
    cancellable(stop, Duration::from_secs(5), async {
        connection
            .socket
            .send(Message::Text(text.into()))
            .await
            .map_err(|_| LiveIssue::Unavailable)
    })
    .await
}
async fn request(
    source: &SystemDaemonSource,
    epoch: u64,
    connection: &mut Connection,
    reducer: &mut Reducer,
    stop: &AtomicBool,
    next_id: &mut u64,
    method: &str,
    params: Value,
) -> LiveResult<Value> {
    let id = *next_id;
    *next_id = next_id.checked_add(1).ok_or(LiveIssue::Overflow)?;
    send(
        connection,
        stop,
        json!({"id":id,"method":method,"params":params}),
    )
    .await?;
    cancellable(stop, Duration::from_secs(5), async {
        loop {
            let Some(message) = decode(connection.socket.next().await)? else {
                continue;
            };
            if message.get("method").is_some() {
                if notification(reducer, &message)? {
                    source.pending_update(epoch)?;
                    if let Ok(snapshot) = reducer.snapshot(super::super::now_ms()) {
                        connection.peer.recheck()?;
                        source.publish(epoch, snapshot, stop)?;
                    }
                }
                continue;
            }
            if message.get("id").and_then(Value::as_u64) != Some(id) {
                return Err(LiveIssue::Protocol);
            }
            if message.get("error").is_some() {
                return Err(LiveIssue::Protocol);
            }
            return message.get("result").cloned().ok_or(LiveIssue::Protocol);
        }
    })
    .await
}
fn notification(reducer: &mut Reducer, value: &Value) -> LiveResult<bool> {
    if value.get("id").is_some() {
        return Err(LiveIssue::Protocol);
    } // never approve or reject another client's requests
    let method = value
        .get("method")
        .and_then(Value::as_str)
        .ok_or(LiveIssue::Protocol)?;
    reducer.notification(
        method,
        value.get("params").unwrap_or(&Value::Null),
        super::super::now_ms(),
    )
}
fn decode(
    message: Option<std::result::Result<Message, tokio_tungstenite::tungstenite::Error>>,
) -> LiveResult<Option<Value>> {
    match message {
        Some(Ok(Message::Text(text))) if text.len() <= MAXIMUM_MESSAGE_BYTES => {
            serde_json::from_str(&text)
                .map(Some)
                .map_err(|_| LiveIssue::Protocol)
        }
        Some(Ok(Message::Ping(_) | Message::Pong(_))) => Ok(None),
        Some(Ok(Message::Text(_))) => Err(LiveIssue::Overflow),
        Some(Ok(Message::Binary(_) | Message::Frame(_))) => Err(LiveIssue::Protocol),
        Some(Ok(Message::Close(_))) | Some(Err(_)) | None => Err(LiveIssue::Unavailable),
    }
}
pub(super) fn same_home(home: &std::path::Path, reported: &str) -> bool {
    let Some(home) = home.to_str() else {
        return false;
    };
    let trim = |v: &str| {
        v.strip_prefix(r"\\?\")
            .unwrap_or(v)
            .trim_end_matches(['\\', '/'])
            .replace('/', "\\")
    };
    // Windows directories can opt into case sensitivity. Textual case folding
    // is not a canonical file-identity check and could join distinct homes.
    !reported.is_empty() && trim(home) == trim(reported)
}
