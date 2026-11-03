use super::{
    domain::*,
    fail, nonce,
    process::{Helper, HelperResource, NativeRuntime, Runtime},
    storage::{checked_root, Store},
    Result,
};
use crate::accounts::{DpapiProtector, SecretProtector};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, SyncSender},
        Arc, Mutex, Weak,
    },
    time::{Duration, Instant},
};

/// The native caller opens only a provider URL already checked by this host.
pub trait AuthorizationBrowser: Send + Sync {
    fn open(&self, url: &str) -> Result<()>;
}
/// Intentionally not serializable/debuggable. Only an explicit native copy or
/// isolated CLI launch may use this value while `with_connection` holds its gate.
pub struct NativeConnection<'a> {
    pub endpoint: String,
    pub client_key: &'a str,
    pub run_id: &'a str,
}
enum Control {
    Frame(Vec<u8>),
    Stop,
}
struct Active {
    sender: SyncSender<Control>,
    cancel: Arc<AtomicBool>,
}
struct State {
    phase: Phase,
    run: Option<String>,
    active: Option<Active>,
    key: Option<String>,
    providers: Vec<Provider>,
    models: BTreeMap<Provider, Vec<String>>,
    rows: Vec<AccountView>,
    authorization: Option<AuthorizationView>,
    added: Option<String>,
    revoked: BTreeSet<(String, String)>,
    persisted: BTreeSet<String>,
    issue: Option<&'static str>,
}
impl Default for State {
    fn default() -> Self {
        Self {
            phase: Phase::Stopped,
            run: None,
            active: None,
            key: None,
            providers: vec![],
            models: BTreeMap::new(),
            rows: vec![],
            authorization: None,
            added: None,
            revoked: BTreeSet::new(),
            persisted: BTreeSet::new(),
            issue: None,
        }
    }
}
pub struct ProviderPool {
    store: Store,
    resource: HelperResource,
    runtime: Arc<dyn Runtime>,
    browser: Arc<dyn AuthorizationBrowser>,
    state: Mutex<State>,
}
impl ProviderPool {
    pub fn new(
        root: PathBuf,
        resource: HelperResource,
        browser: Arc<dyn AuthorizationBrowser>,
    ) -> Result<Arc<Self>> {
        Self::with_runtime(
            root,
            resource,
            browser,
            Arc::new(DpapiProtector),
            Arc::new(NativeRuntime),
        )
    }
    pub(super) fn with_runtime(
        root: PathBuf,
        resource: HelperResource,
        browser: Arc<dyn AuthorizationBrowser>,
        protector: Arc<dyn SecretProtector>,
        runtime: Arc<dyn Runtime>,
    ) -> Result<Arc<Self>> {
        Ok(Arc::new(Self {
            store: Store::new(root, protector)?,
            resource,
            runtime,
            browser,
            state: Mutex::new(State::default()),
        }))
    }
    fn lock(&self) -> Result<std::sync::MutexGuard<'_, State>> {
        self.state.lock().map_err(|_| fail("provider_pool_busy"))
    }
    fn snapshot_locked(&self, s: &State) -> Result<PoolSnapshot> {
        let mut accounts = self.store.list()?;
        if s.phase == Phase::Running {
            for saved in &mut accounts {
                if let Some(row) = s.rows.iter().find(|r| {
                    r.id == saved.id
                        && r.generation == saved.generation
                        && r.enabled == saved.enabled
                }) {
                    *saved = row.clone();
                }
            }
        }
        Ok(PoolSnapshot {
            phase: s.phase,
            run_id: s.run.clone(),
            port: (s.phase == Phase::Running).then_some(PORT),
            accounts,
            providers: s.providers.clone(),
            provider_models: s.models.clone(),
            authorization: s.authorization.clone(),
            issue_code: s.issue,
        })
    }
    pub fn snapshot(&self) -> Result<PoolSnapshot> {
        self.snapshot_locked(&*self.lock()?)
    }
    /// Native exit admission must not depend on a successful disk snapshot.
    pub fn requires_exit_confirmation(&self) -> bool {
        self.state
            .try_lock()
            .map(|s| s.active.is_some())
            .unwrap_or(true)
    }
    pub fn start(self: &Arc<Self>, network_proxy: Option<String>) -> Result<PoolSnapshot> {
        let proxy = validate_proxy(network_proxy)?;
        let mut s = self.lock()?;
        if s.active.is_some()
            || matches!(s.phase, Phase::Starting | Phase::Running | Phase::Stopping)
        {
            return Err(fail("provider_pool_busy"));
        }
        let owner = self.store.owner()?;
        let (key, rows) = self.store.bootstrap()?;
        let root = checked_root(&self.store.root)?;
        let accounts:Vec<_>=rows.into_iter().map(|(m,c)|json!({"credential":c,"enabled":m.enabled,"concurrencyLimit":m.concurrency_limit,"cooldownUntil":m.cooldown_until.unwrap_or(0)})).collect();
        let mut startup=serde_json::to_vec(&json!({"schemaVersion":1,"clientKey":key,"port":PORT,"networkProxy":proxy,"accounts":accounts})).map_err(|_|fail("provider_pool_invalid_data"))?;
        startup.push(b'\n');
        if startup.len() > MAX_IPC {
            return Err(fail("provider_pool_capacity"));
        }
        let run = nonce()?;
        let (tx, rx) = mpsc::sync_channel(32);
        let cancel = Arc::new(AtomicBool::new(false));
        *s = State {
            phase: Phase::Starting,
            run: Some(run.clone()),
            key: Some(key),
            active: Some(Active {
                sender: tx,
                cancel: cancel.clone(),
            }),
            ..Default::default()
        };
        let weak = Arc::downgrade(self);
        let runtime = self.runtime.clone();
        let resource = self.resource.clone();
        if std::thread::Builder::new()
            .name("provider-pool-owned".into())
            .spawn(move || match runtime.launch(&resource, &root, &cancel) {
                Ok(helper) => worker(weak, &run, rx, cancel, helper, owner, startup),
                Err(e) => {
                    drop(owner);
                    finish(&weak, &run, Some(e.code));
                }
            })
            .is_err()
        {
            s.phase = Phase::Failed;
            s.active = None;
            s.key = None;
            s.issue = Some("provider_pool_process_unavailable");
        }
        self.snapshot_locked(&s)
    }
    fn running<'a>(s: &'a mut State, run: &str) -> Result<&'a Active> {
        if s.phase != Phase::Running || s.run.as_deref() != Some(run) {
            return Err(fail("provider_pool_run_changed"));
        }
        s.active
            .as_ref()
            .ok_or_else(|| fail("provider_pool_run_changed"))
    }
    fn send(s: &mut State, value: Value) -> Result<()> {
        let bytes = frame(value)?;
        let a = s
            .active
            .as_ref()
            .ok_or_else(|| fail("provider_pool_not_running"))?;
        if a.sender.try_send(Control::Frame(bytes)).is_err() {
            a.cancel.store(true, Ordering::Release);
            s.phase = Phase::Stopping;
            s.issue = Some("provider_pool_pipe_failed");
            return Err(fail("provider_pool_pipe_failed"));
        }
        Ok(())
    }
    pub fn stop(&self, run: &str, confirmed: bool) -> Result<PoolSnapshot> {
        if !confirmed {
            return Err(fail("provider_pool_confirmation_required"));
        }
        let mut s = self.lock()?;
        if s.run.as_deref() != Some(run) {
            return Err(fail("provider_pool_run_changed"));
        }
        if let Some(a) = &s.active {
            a.cancel.store(true, Ordering::Release);
            let _ = a.sender.try_send(Control::Stop);
            s.phase = Phase::Stopping;
            s.models.clear();
            s.authorization = None;
        }
        self.snapshot_locked(&s)
    }
    pub fn request_exit(&self) {
        if let Ok(mut s) = self.state.lock() {
            if let Some(a) = &s.active {
                a.cancel.store(true, Ordering::Release);
                let _ = a.sender.try_send(Control::Stop);
                s.phase = Phase::Stopping;
            }
        }
    }
    pub fn begin_authorization(&self, run: &str, provider: Provider) -> Result<PoolSnapshot> {
        let mut s = self.lock()?;
        Self::running(&mut s, run)?;
        if !s.providers.contains(&provider) {
            return Err(fail("provider_pool_provider_unavailable"));
        }
        if s.authorization.is_some() {
            return Err(fail("provider_pool_authorization_busy"));
        }
        if self.store.list()?.len() >= 100 {
            return Err(fail("provider_pool_capacity"));
        }
        let attempt = nonce()?;
        Self::send(
            &mut s,
            json!({"command":"auth","provider":provider,"requestID":attempt}),
        )?;
        s.authorization = Some(AuthorizationView {
            attempt_id: attempt,
            provider,
            cancelling: false,
            user_code: None,
        });
        s.added = None;
        s.issue = None;
        self.snapshot_locked(&s)
    }
    pub fn cancel_authorization(&self, run: &str, attempt: &str) -> Result<PoolSnapshot> {
        let mut s = self.lock()?;
        Self::running(&mut s, run)?;
        if !s
            .authorization
            .as_ref()
            .is_some_and(|a| a.attempt_id == attempt)
        {
            return Err(fail("provider_pool_authorization_changed"));
        }
        Self::send(&mut s, json!({"command":"cancel_auth","requestID":attempt}))?;
        s.authorization.as_mut().unwrap().cancelling = true;
        self.snapshot_locked(&s)
    }
    fn edit_gate(s: &State, run: Option<&str>) -> Result<()> {
        if s.active.is_some() {
            if s.phase != Phase::Running || s.run.as_deref() != run {
                return Err(fail("provider_pool_run_changed"));
            }
        } else if run.is_some() {
            return Err(fail("provider_pool_run_changed"));
        }
        Ok(())
    }
    pub fn set_enabled(
        &self,
        run: Option<&str>,
        id: &str,
        generation: &str,
        enabled: bool,
    ) -> Result<PoolSnapshot> {
        let mut s = self.lock()?;
        Self::edit_gate(&s, run)?;
        let row = self.store.enabled(id, generation, enabled)?;
        s.rows.retain(|r| r.id != id);
        s.models.remove(&row.provider);
        if s.active.is_some() {
            Self::send(
                &mut s,
                json!({"command":"set_enabled","accountID":id,"generation":generation,"enabled":enabled,"concurrencyLimit":row.concurrency_limit}),
            )?;
        }
        self.snapshot_locked(&s)
    }
    pub fn remove_account(
        &self,
        run: Option<&str>,
        id: &str,
        generation: &str,
        confirmed: bool,
    ) -> Result<PoolSnapshot> {
        if !confirmed {
            return Err(fail("provider_pool_confirmation_required"));
        }
        let mut s = self.lock()?;
        Self::edit_gate(&s, run)?;
        let row = self
            .store
            .list()?
            .into_iter()
            .find(|r| r.id == id && r.generation == generation)
            .ok_or_else(|| fail("provider_pool_identity_changed"))?;
        self.store.remove(id, generation)?;
        s.revoked.insert((id.into(), generation.into()));
        s.rows.retain(|r| r.id != id);
        s.models.remove(&row.provider);
        if s.active.is_some() {
            Self::send(
                &mut s,
                json!({"command":"remove","accountID":id,"generation":generation}),
            )?;
        }
        self.snapshot_locked(&s)
    }
    pub fn refresh_models(&self, run: &str) -> Result<PoolSnapshot> {
        let mut s = self.lock()?;
        Self::running(&mut s, run)?;
        Self::send(&mut s, json!({"command":"refresh_models"}))?;
        self.snapshot_locked(&s)
    }
    pub fn with_connection<T>(
        &self,
        run: &str,
        provider: Provider,
        model: Option<&str>,
        use_connection: impl FnOnce(NativeConnection<'_>) -> Result<T>,
    ) -> Result<T> {
        let s = self.lock()?;
        if s.phase != Phase::Running || s.run.as_deref() != Some(run) {
            return Err(fail("provider_pool_run_changed"));
        }
        let models = s
            .models
            .get(&provider)
            .filter(|v| !v.is_empty())
            .ok_or_else(|| fail("provider_pool_models_unavailable"))?;
        if model.is_some_and(|m| !models.iter().any(|known| known == m)) {
            return Err(fail("provider_pool_models_unavailable"));
        }
        let key = s
            .key
            .as_deref()
            .ok_or_else(|| fail("provider_pool_not_running"))?;
        use_connection(NativeConnection {
            endpoint: format!("http://127.0.0.1:{PORT}/providers/{}", provider.id()),
            client_key: key,
            run_id: run,
        })
    }
    fn event(&self, run: &str, e: Event, helper: &mut dyn Helper) -> Result<()> {
        let mut s = self.lock()?;
        if s.run.as_deref() != Some(run) || !matches!(s.phase, Phase::Starting | Phase::Running) {
            return Ok(());
        }
        match e.event.as_str() {
            "ready" => {
                let providers = e
                    .providers
                    .ok_or_else(|| fail("provider_pool_protocol_invalid"))?;
                if s.phase != Phase::Starting
                    || e.port != Some(PORT)
                    || providers.is_empty()
                    || providers.len() > 4
                    || providers.iter().collect::<BTreeSet<_>>().len() != providers.len()
                {
                    return Err(fail("provider_pool_protocol_invalid"));
                }
                s.providers = providers;
                s.phase = Phase::Running;
            }
            "snapshot" => {
                if s.phase != Phase::Running {
                    return Err(fail("provider_pool_protocol_invalid"));
                }
                let rows = e.accounts.unwrap_or_default();
                validate_rows(&rows)?;
                let saved = self.store.list()?;
                let mut accepted = Vec::new();
                for row in rows {
                    if let Some(m) = saved.iter().find(|m| {
                        m.id == row.id
                            && m.generation == row.generation
                            && m.provider == row.provider
                            && m.masked_identity == row.masked_identity
                    }) {
                        if m.enabled == row.enabled
                            && m.concurrency_limit == row.concurrency_limit
                            && !s
                                .revoked
                                .contains(&(row.id.clone(), row.generation.clone()))
                        {
                            accepted.push(row);
                        }
                    }
                }
                let mut catalogs = e.provider_models.unwrap_or_default();
                if let Some(models) = e.models {
                    if models.len() > 512 || models.iter().any(|m| !super::domain::model(m)) {
                        return Err(fail("provider_pool_protocol_invalid"));
                    }
                }
                for (provider, models) in &mut catalogs {
                    if !s.providers.contains(provider)
                        || models.len() > 512
                        || models.iter().any(|m| !super::domain::model(m))
                        || models.iter().collect::<BTreeSet<_>>().len() != models.len()
                    {
                        return Err(fail("provider_pool_protocol_invalid"));
                    }
                    models.retain(|m| {
                        accepted.iter().any(|r| {
                            r.provider == *provider
                                && r.enabled
                                && r.state != AccountState::ReauthRequired
                                && r.models.contains(m)
                        })
                    });
                }
                self.store.cooldowns(&accepted)?;
                s.rows = accepted;
                s.models = catalogs;
            }
            "open_browser" => {
                let Some(a) = s.authorization.as_ref().filter(|a| {
                    Some(a.attempt_id.as_str()) == e.session_id.as_deref()
                        && Some(a.provider) == e.provider
                        && !a.cancelling
                }) else {
                    return Ok(());
                };
                let attempt = a.attempt_id.clone();
                let url = authorization_url(
                    e.url.as_deref().unwrap_or(""),
                    a.provider,
                    e.user_code.as_deref(),
                )?;
                if self.browser.open(&url).is_err() {
                    Self::send(&mut s, json!({"command":"cancel_auth","requestID":attempt}))?;
                    s.authorization.as_mut().unwrap().cancelling = true;
                    s.issue = Some("provider_pool_browser_unavailable");
                } else {
                    s.authorization.as_mut().unwrap().user_code = e.user_code;
                }
            }
            "persist_credential" => {
                let request = e
                    .request_id
                    .filter(|s| opaque(s))
                    .ok_or_else(|| fail("provider_pool_protocol_invalid"))?;
                if s.persisted.contains(&request) || s.persisted.len() >= 4096 {
                    return Err(fail("provider_pool_protocol_invalid"));
                }
                s.persisted.insert(request.clone());
                let accepted = (|| {
                    let c = e
                        .credential
                        .as_ref()
                        .ok_or_else(|| fail("provider_pool_invalid_credential"))?;
                    c.validate()?;
                    if e.provider != Some(c.provider)
                        || e.account_id.as_deref() != Some(&c.account_id)
                        || e.generation.as_deref() != Some(&c.generation)
                        || s.revoked
                            .contains(&(c.account_id.clone(), c.generation.clone()))
                    {
                        return Err(fail("provider_pool_identity_changed"));
                    }
                    let add = match e.purpose.as_deref() {
                        Some("add") => {
                            if !s.authorization.as_ref().is_some_and(|a| {
                                !a.cancelling
                                    && a.provider == c.provider
                                    && Some(a.attempt_id.as_str()) == e.session_id.as_deref()
                            }) {
                                return Err(fail("provider_pool_authorization_changed"));
                            }
                            true
                        }
                        Some("refresh") => {
                            if e.session_id.as_deref().is_some_and(|v| !v.is_empty()) {
                                return Err(fail("provider_pool_identity_changed"));
                            }
                            false
                        }
                        _ => return Err(fail("provider_pool_protocol_invalid")),
                    };
                    self.store.persist(c, add)?;
                    if add {
                        s.added = Some(c.account_id.clone());
                    }
                    Ok(())
                })();
                if let Err(error) = accepted {
                    s.issue = Some(error.code);
                }
                helper.frame(&frame(
                    json!({"command":"persist_result","requestID":request,"ok":accepted.is_ok()}),
                )?)?;
            }
            "auth_result" => {
                let Some(a) = s.authorization.as_ref().filter(|a| {
                    Some(a.attempt_id.as_str()) == e.session_id.as_deref()
                        && Some(a.provider) == e.provider
                }) else {
                    return Ok(());
                };
                if e.code.as_deref() == Some("ok") {
                    if a.cancelling || e.account_id != s.added {
                        s.issue = Some("provider_pool_authorization_changed");
                    } else {
                        s.issue = None;
                    }
                } else if !matches!(e.code.as_deref(), Some("oauth_cancelled")) {
                    s.issue = Some("provider_pool_authorization_failed");
                }
                s.authorization = None;
                s.added = None;
            }
            "error" => return Err(fail("provider_pool_helper_failed")),
            _ => return Err(fail("provider_pool_protocol_invalid")),
        }
        Ok(())
    }
}
impl Drop for ProviderPool {
    fn drop(&mut self) {
        self.request_exit();
    }
}
fn frame(value: Value) -> Result<Vec<u8>> {
    let mut bytes =
        serde_json::to_vec(&value).map_err(|_| fail("provider_pool_protocol_invalid"))?;
    bytes.push(b'\n');
    if bytes.len() > 512 {
        return Err(fail("provider_pool_capacity"));
    }
    Ok(bytes)
}
fn validate_proxy(value: Option<String>) -> Result<String> {
    let value = value.unwrap_or_default();
    if value.is_empty() {
        return Ok(value);
    }
    let u = url::Url::parse(&value).map_err(|_| fail("provider_pool_proxy_invalid"))?;
    if value.len() > 2048
        || value.chars().any(char::is_control)
        || !matches!(u.scheme(), "http" | "https" | "socks5")
        || u.host_str().is_none()
        || u.port().is_none()
        || !u.username().is_empty()
        || u.password().is_some()
        || u.query().is_some()
        || u.fragment().is_some()
        || !matches!(u.path(), "" | "/")
    {
        return Err(fail("provider_pool_proxy_invalid"));
    }
    Ok(value)
}
fn finish(weak: &Weak<ProviderPool>, run: &str, issue: Option<&'static str>) {
    if let Some(pool) = weak.upgrade() {
        if let Ok(mut s) = pool.state.lock() {
            if s.run.as_deref() == Some(run) {
                s.phase = if issue.is_some() {
                    Phase::Failed
                } else {
                    Phase::Stopped
                };
                s.active = None;
                s.key = None;
                s.models.clear();
                s.rows.clear();
                s.authorization = None;
                s.issue = issue;
            }
        }
    }
}
fn worker(
    weak: Weak<ProviderPool>,
    run: &str,
    receiver: Receiver<Control>,
    cancel: Arc<AtomicBool>,
    mut helper: Box<dyn Helper>,
    owner: crate::accounts::storage::StoreLock,
    startup: Vec<u8>,
) {
    let mut bytes = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(10);
    // Once a child belongs to our Job, every failure retains its ownership fence
    // until the same root handle and Job tree are confirmed stopped.
    let mut issue = helper.bootstrap(&startup, &cancel).err().map(|e| e.code);
    if issue.is_some() {
        cancel.store(true, Ordering::Release);
    }
    drop(startup);
    let mut cleanup_attempted = false;
    loop {
        if weak.strong_count() == 0 {
            // The service can disappear before Windows has terminated every
            // descendant. This same owned worker retains the fence and handle;
            // it never infers exit from a missing UI/service or adopts a PID.
            if helper.stop().is_ok() {
                return;
            }
            std::thread::sleep(Duration::from_secs(1));
            continue;
        }
        let mut stop_again = false;
        for command in receiver.try_iter() {
            match command {
                Control::Stop => {
                    cancel.store(true, Ordering::Release);
                    stop_again = true;
                }
                Control::Frame(data) => {
                    if !cancel.load(Ordering::Acquire) {
                        if let Err(e) = helper.frame(&data) {
                            issue = Some(e.code);
                            cancel.store(true, Ordering::Release);
                        }
                    }
                }
            }
        }
        if cancel.load(Ordering::Acquire) {
            if !cleanup_attempted || stop_again {
                cleanup_attempted = true;
                match helper.stop() {
                    Ok(()) => {
                        drop(helper);
                        drop(owner);
                        finish(&weak, run, issue);
                        return;
                    }
                    Err(_) => {
                        if let Some(pool) = weak.upgrade() {
                            if let Ok(mut s) = pool.state.lock() {
                                if s.run.as_deref() == Some(run) {
                                    s.phase = Phase::Stopping;
                                    s.issue = Some("provider_pool_cleanup_unconfirmed");
                                    s.models.clear();
                                    s.authorization = None;
                                }
                            }
                        }
                    }
                }
            }
            std::thread::sleep(Duration::from_millis(20));
            continue;
        }
        let result = (|| {
            let chunk = helper.output()?;
            if bytes.len() + chunk.len() > MAX_IPC {
                return Err(fail("provider_pool_protocol_invalid"));
            }
            bytes.extend(chunk);
            while let Some(end) = bytes.iter().position(|b| *b == b'\n') {
                let line: Vec<_> = bytes.drain(..=end).collect();
                let e: Event = serde_json::from_slice(&line)
                    .map_err(|_| fail("provider_pool_protocol_invalid"))?;
                let Some(pool) = weak.upgrade() else {
                    return Err(fail("provider_pool_cancelled"));
                };
                pool.event(run, e, helper.as_mut())?;
            }
            if helper.exited()? {
                return Err(fail("provider_pool_helper_exited"));
            }
            if Instant::now() >= deadline {
                if let Some(pool) = weak.upgrade() {
                    if pool.lock()?.phase == Phase::Starting {
                        return Err(fail("provider_pool_startup_failed"));
                    }
                }
            }
            Ok(())
        })();
        if let Err(e) = result {
            issue = Some(e.code);
            cancel.store(true, Ordering::Release);
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}
