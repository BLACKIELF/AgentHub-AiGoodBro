//! Fixed-resource Token Monitor host. Paths remain native-only; public state
//! contains a strict, privacy-checked projection of the pinned upstream engine.
#[path = "token_monitor/process.rs"]
mod process;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
};

pub const ENGINE_COMMIT: &str = "5d2db368d8313415763860d594de00e46a663418";
pub const SCANNER_PATCH: &str = "a5c09f55a7e70f167e4a48b793a169043fdc45c946773360b4e2739cdff5f52d";
pub const MAX_RESPONSE: usize = 32 * 1024 * 1024;
pub type Result<T> = std::result::Result<T, Failure>;
#[derive(Clone, Copy, Debug)]
pub struct Failure(pub &'static str);
impl Failure {
    pub fn code(self) -> &'static str {
        self.0
    }
}
impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}
impl std::error::Error for Failure {}
fn fail<T>(code: &'static str) -> Result<T> {
    Err(Failure(code))
}
fn valid_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._:-".contains(&b))
}
fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

/// Constructed only by the native host from approved source roots. Never an IPC
/// argument; the WebView may choose only IDs from this registered catalogue.
#[derive(Clone, PartialEq, Eq)]
pub struct TokenMonitorSource {
    pub id: String,
    pub provider_id: String,
    pub label: String,
    pub root: PathBuf,
    pub path_role: SourceRole,
    pub default_enabled: bool,
}
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum SourceRole {
    UserHome,
    LogRoot,
    CodexHome,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceDto {
    pub id: String,
    pub provider_id: String,
    pub label: String,
    pub enabled: bool,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Provider {
    pub id: String,
    pub label: String,
    pub default_tracked: bool,
}
/// The exact catalog already used by the Mac product; no guessed providers.
pub fn provider_catalog() -> Result<Vec<Provider>> {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Catalog {
        schema_version: u32,
        upstream_commit: String,
        clients: Vec<Provider>,
    }
    let value: Catalog = serde_json::from_slice(include_bytes!(
        "../../../../Companion/TokenMonitorEngine/client-catalog.json"
    ))
    .map_err(|_| Failure("statistics_resources_invalid"))?;
    if value.schema_version != 1
        || value.upstream_commit != ENGINE_COMMIT
        || value.clients.is_empty()
    {
        return fail("statistics_resources_invalid");
    }
    Ok(value.clients)
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenMonitorState {
    pub phase: &'static str,
    pub revision: u64,
    pub context_key: Option<String>,
    pub sources: Vec<SourceDto>,
    pub timezone: Option<String>,
    pub snapshot: Option<Value>,
    pub token_rate: Option<TokenRate>,
    pub failure_code: Option<&'static str>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TokenRate {
    pub mode: String,
    pub scope: String,
    pub burn_per_minute: f64,
    pub speed_per_second: f64,
    pub sampled_at: i64,
    pub expires_at: i64,
    pub idle: bool,
    pub revision: u64,
    pub context_key: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Event {
    event: String,
    context_key: String,
    snapshot: Option<Value>,
    rate: Option<TokenRate>,
    code: Option<String>,
}

pub struct TokenMonitorService {
    resources: PathBuf,
    data: PathBuf,
    timezone: Mutex<String>,
    sources: Mutex<Vec<TokenMonitorSource>>,
    enabled: Mutex<BTreeSet<String>>,
    state: Mutex<TokenMonitorState>,
    runtime: Mutex<Option<process::OwnedRuntime>>,
    cancel_handle: Mutex<Option<process::CancelHandle>>,
    operation: Mutex<()>,
    epoch: AtomicU64,
    exiting: AtomicBool,
}
impl TokenMonitorService {
    /// `resources` is the installed `token-monitor` directory, not a user path.
    pub fn native(
        resources: PathBuf,
        data: PathBuf,
        sources: Vec<TokenMonitorSource>,
        timezone: String,
    ) -> Result<Arc<Self>> {
        #[cfg(not(windows))]
        {
            let _ = (resources, data, sources, timezone);
            fail("windows_required")
        }
        #[cfg(windows)]
        {
            Self::create(resources, data, sources, timezone)
        }
    }
    fn create(
        resources: PathBuf,
        data: PathBuf,
        sources: Vec<TokenMonitorSource>,
        timezone: String,
    ) -> Result<Arc<Self>> {
        if !resources.is_absolute()
            || !data.is_absolute()
            || sources.len() > 256
            || !timezone.is_empty() && !valid_timezone(&timezone)
        {
            return fail("invalid_statistics_settings");
        }
        validate_sources(&sources)?;
        process::verify_resources(&resources)?;
        fs::create_dir_all(&data).map_err(|_| Failure("statistics_cache_unavailable"))?;
        let path = data.join("sources.json");
        let enabled = read_selection(&path, &sources)?;
        let source_dtos = sources
            .iter()
            .map(|s| SourceDto {
                id: s.id.clone(),
                provider_id: s.provider_id.clone(),
                label: s.label.clone(),
                enabled: enabled.contains(&s.id),
            })
            .collect();
        let public_timezone = if timezone.is_empty() {
            None
        } else {
            Some(timezone.clone())
        };
        Ok(Arc::new(Self {
            resources,
            data,
            timezone: Mutex::new(timezone),
            sources: Mutex::new(sources),
            enabled: Mutex::new(enabled),
            state: Mutex::new(TokenMonitorState {
                phase: "idle",
                revision: 0,
                context_key: None,
                sources: source_dtos,
                timezone: public_timezone,
                snapshot: None,
                token_rate: None,
                failure_code: None,
            }),
            runtime: Mutex::new(None),
            cancel_handle: Mutex::new(None),
            operation: Mutex::new(()),
            epoch: AtomicU64::new(0),
            exiting: AtomicBool::new(false),
        }))
    }
    pub fn state(&self) -> Result<TokenMonitorState> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| Failure("statistics_unavailable"))?;
        if state
            .token_rate
            .as_ref()
            .is_some_and(|rate| rate.expires_at <= Utc::now().timestamp_millis())
        {
            state.token_rate = None;
        }
        Ok(state.clone())
    }
    pub fn refresh(self: &Arc<Self>) -> Result<TokenMonitorState> {
        let _guard = self
            .operation
            .try_lock()
            .map_err(|_| Failure("statistics_busy"))?;
        if self.exiting.load(Ordering::Acquire) {
            return fail("statistics_cancelled");
        }
        if self
            .timezone
            .lock()
            .map_err(|_| Failure("statistics_unavailable"))?
            .is_empty()
        {
            return fail("statistics_timezone_required");
        }
        if self
            .enabled
            .lock()
            .map_err(|_| Failure("statistics_unavailable"))?
            .is_empty()
        {
            self.cancel_locked()?;
            return self.state();
        }
        let mut runtime = self
            .runtime
            .lock()
            .map_err(|_| Failure("statistics_unavailable"))?;
        if let Some(child) = runtime.as_mut() {
            if !child.exited()? {
                child.send(&json!({"command":"refresh"}))?;
                let mut s = self
                    .state
                    .lock()
                    .map_err(|_| Failure("statistics_unavailable"))?;
                s.phase = "loading";
                s.failure_code = None;
                return Ok(s.clone());
            }
            runtime.take();
        }
        let request = self.request()?;
        let context = hash(
            &serde_json::to_vec(&request).map_err(|_| Failure("invalid_statistics_settings"))?,
        );
        let epoch = self.epoch.fetch_add(1, Ordering::AcqRel) + 1;
        let mut child = process::OwnedRuntime::spawn(&self.resources, &self.data)?;
        {
            let mut cancellation = self
                .cancel_handle
                .lock()
                .map_err(|_| Failure("statistics_unavailable"))?;
            if self.exiting.load(Ordering::Acquire) || self.epoch.load(Ordering::Acquire) != epoch {
                drop(cancellation);
                child.stop()?;
                return fail("statistics_cancelled");
            }
            *cancellation = Some(child.cancellation());
        }
        let stdout = child.take_stdout()?;
        child.send(&json!({"command":"configure","contextKey":context,"request":request}))?;
        {
            let mut s = self
                .state
                .lock()
                .map_err(|_| Failure("statistics_unavailable"))?;
            if s.context_key.as_deref() != Some(&context) {
                s.snapshot = None;
                s.token_rate = None;
            }
            s.context_key = Some(context.clone());
            s.phase = "loading";
            s.failure_code = None;
        }
        *runtime = Some(child);
        let weak = Arc::downgrade(self);
        let watch = weak.clone();
        let started = std::time::Instant::now();
        let last_event = Arc::new(AtomicU64::new(0));
        let last_read = last_event.clone();
        let output = std::thread::Builder::new()
            .name("token-monitor-output".into())
            .spawn(move || {
                let result = process::read_events(stdout, |line| {
                    let service = weak.upgrade().ok_or(Failure("statistics_cancelled"))?;
                    if service.epoch.load(Ordering::Acquire) != epoch {
                        return fail("statistics_cancelled");
                    }
                    service.accept_event(line, &context, epoch)?;
                    last_read.store(started.elapsed().as_millis() as u64, Ordering::Release);
                    Ok(())
                });
                if let Some(service) = weak.upgrade() {
                    service.fail_generation(
                        epoch,
                        result.err().unwrap_or(Failure("statistics_runtime_exited")),
                    );
                }
            });
        if output.is_err() {
            if let Some(child) = runtime.as_mut() {
                child.stop()?;
            }
            runtime.take();
            return fail("statistics_unavailable");
        }
        drop(runtime);
        std::thread::Builder::new()
            .name("token-monitor-deadline".into())
            .spawn(move || loop {
                std::thread::sleep(std::time::Duration::from_secs(1));
                let Some(service) = watch.upgrade() else {
                    return;
                };
                if service.epoch.load(Ordering::Acquire) != epoch
                    || service.exiting.load(Ordering::Acquire)
                {
                    return;
                }
                // Normal host output includes a one-second rate heartbeat even
                // while an asynchronous scan runs. Bound an unresponsive event
                // loop by the engine's 180-second request budget plus cleanup.
                if started.elapsed().as_millis() as u64 - last_event.load(Ordering::Acquire)
                    > 190000
                {
                    service.fail_generation(epoch, Failure("statistics_timeout"));
                    return;
                }
            })
            .map_err(|_| {
                self.cancel_for_exit();
                Failure("statistics_unavailable")
            })?;
        self.state()
    }
    fn fail_generation(&self, epoch: u64, error: Failure) {
        // Recheck while holding the runtime lock: an old EOF/watchdog must
        // never stop a replacement host created while it was waiting.
        let Ok(mut runtime) = self.runtime.lock() else {
            return;
        };
        if self.epoch.load(Ordering::Acquire) != epoch {
            return;
        }
        self.epoch.fetch_add(1, Ordering::AcqRel);
        let cleaned = runtime.as_mut().is_none_or(|child| child.stop().is_ok());
        if cleaned {
            runtime.take();
            if let Ok(mut handle) = self.cancel_handle.lock() {
                handle.take();
            }
        }
        if let Ok(mut state) = self.state.lock() {
            state.phase = "failed";
            state.failure_code = Some(if cleaned {
                error.code()
            } else {
                "statistics_cleanup_unconfirmed"
            });
            state.token_rate = None;
        }
    }
    pub fn select_sources(self: &Arc<Self>, ids: Vec<String>) -> Result<TokenMonitorState> {
        let _guard = self
            .operation
            .try_lock()
            .map_err(|_| Failure("statistics_busy"))?;
        let sources = self
            .sources
            .lock()
            .map_err(|_| Failure("statistics_unavailable"))?;
        let selected: BTreeSet<_> = ids.iter().cloned().collect();
        if selected.len() != ids.len()
            || selected
                .iter()
                .any(|id| !sources.iter().any(|s| &s.id == id))
        {
            return fail("invalid_statistics_source");
        }
        if *self
            .enabled
            .lock()
            .map_err(|_| Failure("statistics_unavailable"))?
            == selected
        {
            return self.state();
        }
        self.cancel_locked()?;
        save_selection(&self.data, &sources, &selected)?;
        *self
            .enabled
            .lock()
            .map_err(|_| Failure("statistics_unavailable"))? = selected.clone();
        let mut state = self
            .state
            .lock()
            .map_err(|_| Failure("statistics_unavailable"))?;
        for source in &mut state.sources {
            source.enabled = selected.contains(&source.id);
        }
        state.snapshot = None;
        state.token_rate = None;
        state.context_key = None;
        state.phase = "idle";
        state.failure_code = None;
        state.revision = state
            .revision
            .checked_add(1)
            .ok_or(Failure("statistics_unavailable"))?;
        Ok(state.clone())
    }
    /// Native composition only. It accepts no WebView supplied paths.
    pub fn replace_sources(&self, sources: Vec<TokenMonitorSource>) -> Result<TokenMonitorState> {
        validate_sources(&sources)?;
        if *self
            .sources
            .lock()
            .map_err(|_| Failure("statistics_unavailable"))?
            == sources
        {
            return self.state();
        }
        let _guard = self
            .operation
            .try_lock()
            .map_err(|_| Failure("statistics_busy"))?;
        let mut old = self
            .sources
            .lock()
            .map_err(|_| Failure("statistics_unavailable"))?;
        if *old == sources {
            return self.state();
        }
        let previous = self
            .enabled
            .lock()
            .map_err(|_| Failure("statistics_unavailable"))?
            .clone();
        let enabled = sources
            .iter()
            .filter(|s| {
                previous.contains(&s.id) || s.default_enabled && !old.iter().any(|o| o.id == s.id)
            })
            .map(|s| s.id.clone())
            .collect::<BTreeSet<_>>();
        self.cancel_locked()?;
        save_selection(&self.data, &sources, &enabled)?;
        *old = sources;
        *self
            .enabled
            .lock()
            .map_err(|_| Failure("statistics_unavailable"))? = enabled.clone();
        let mut state = self
            .state
            .lock()
            .map_err(|_| Failure("statistics_unavailable"))?;
        state.sources = old
            .iter()
            .map(|s| SourceDto {
                id: s.id.clone(),
                provider_id: s.provider_id.clone(),
                label: s.label.clone(),
                enabled: enabled.contains(&s.id),
            })
            .collect();
        state.snapshot = None;
        state.token_rate = None;
        state.context_key = None;
        state.phase = "idle";
        state.failure_code = None;
        state.revision = state
            .revision
            .checked_add(1)
            .ok_or(Failure("statistics_unavailable"))?;
        Ok(state.clone())
    }
    pub fn set_timezone(self: &Arc<Self>, timezone: String) -> Result<TokenMonitorState> {
        if !valid_timezone(&timezone) {
            return fail("invalid_statistics_timezone");
        }
        let _guard = self
            .operation
            .try_lock()
            .map_err(|_| Failure("statistics_busy"))?;
        if *self
            .timezone
            .lock()
            .map_err(|_| Failure("statistics_unavailable"))?
            == timezone
        {
            return self.state();
        }
        self.cancel_locked()?;
        *self
            .timezone
            .lock()
            .map_err(|_| Failure("statistics_unavailable"))? = timezone.clone();
        let mut state = self
            .state
            .lock()
            .map_err(|_| Failure("statistics_unavailable"))?;
        state.timezone = Some(timezone);
        state.snapshot = None;
        state.token_rate = None;
        state.context_key = None;
        state.phase = "idle";
        state.failure_code = None;
        state.revision = state
            .revision
            .checked_add(1)
            .ok_or(Failure("statistics_unavailable"))?;
        Ok(state.clone())
    }
    pub fn cancel(&self) -> Result<TokenMonitorState> {
        self.epoch.fetch_add(1, Ordering::AcqRel);
        let _guard = self
            .operation
            .lock()
            .map_err(|_| Failure("statistics_unavailable"))?;
        self.cancel_locked()?;
        self.state()
    }
    fn cancel_locked(&self) -> Result<()> {
        self.epoch.fetch_add(1, Ordering::AcqRel);
        if process::cleanup_unassigned(std::time::Duration::from_secs(2)).is_err() {
            let mut state = self
                .state
                .lock()
                .map_err(|_| Failure("statistics_unavailable"))?;
            state.phase = "failed";
            state.failure_code = Some("statistics_cleanup_unconfirmed");
            state.token_rate = None;
            return fail("statistics_cleanup_unconfirmed");
        }
        let mut runtime = self
            .runtime
            .lock()
            .map_err(|_| Failure("statistics_unavailable"))?;
        if let Some(child) = runtime.as_mut() {
            if child.stop().is_err() {
                let mut s = self
                    .state
                    .lock()
                    .map_err(|_| Failure("statistics_unavailable"))?;
                s.phase = "failed";
                s.failure_code = Some("statistics_cleanup_unconfirmed");
                s.token_rate = None;
                return fail("statistics_cleanup_unconfirmed");
            }
        }
        runtime.take();
        self.cancel_handle
            .lock()
            .map_err(|_| Failure("statistics_unavailable"))?
            .take();
        let mut state = self
            .state
            .lock()
            .map_err(|_| Failure("statistics_unavailable"))?;
        state.phase = "stopped";
        state.token_rate = None;
        Ok(())
    }
    pub fn cancel_for_exit(&self) {
        self.exiting.store(true, Ordering::Release);
        self.epoch.fetch_add(1, Ordering::AcqRel);
        let _ = process::cleanup_unassigned(std::time::Duration::ZERO);
        if let Ok(handle) = self.cancel_handle.lock() {
            if let Some(handle) = handle.as_ref() {
                handle.terminate();
            }
        }
    }
    pub fn has_inflight_operation(&self) -> bool {
        process::has_pending() || self.runtime.try_lock().map(|r| r.is_some()).unwrap_or(true)
    }
    fn request(&self) -> Result<Value> {
        let registered = self
            .sources
            .lock()
            .map_err(|_| Failure("statistics_unavailable"))?;
        let enabled = self
            .enabled
            .lock()
            .map_err(|_| Failure("statistics_unavailable"))?;
        let sources:Vec<_>=registered.iter().filter(|s|enabled.contains(&s.id)).map(|s|json!({"id":s.id,"providerId":s.provider_id,"kind":if matches!(s.path_role,SourceRole::CodexHome){"managedAccount"}else{"agentLogs"},"canonicalPath":s.root,"pathRole":match s.path_role{SourceRole::CodexHome=>"codexHome",SourceRole::UserHome=>"userHome",SourceRole::LogRoot=>"logRoot"},"authority":"upstream","enabled":true})).collect();
        Ok(
            json!({"schemaVersion":1,"requestId":"configure","operation":"collectUsage","timezone":*self.timezone.lock().map_err(|_|Failure("statistics_unavailable"))?,"cacheDirectory":self.data.join("cache"),"sources":sources}),
        )
    }
    fn accept_event(&self, bytes: &[u8], context: &str, epoch: u64) -> Result<()> {
        serde_json::from_slice::<UniqueJson>(bytes)
            .map_err(|_| Failure("statistics_invalid_response"))?;
        let event: Event =
            serde_json::from_slice(bytes).map_err(|_| Failure("statistics_invalid_response"))?;
        if event.context_key != context {
            return fail("statistics_scope_mismatch");
        }
        let sources = self
            .sources
            .lock()
            .map_err(|_| Failure("statistics_unavailable"))?;
        let mut state = self
            .state
            .lock()
            .map_err(|_| Failure("statistics_unavailable"))?;
        if self.epoch.load(Ordering::Acquire) != epoch
            || state.context_key.as_deref() != Some(context)
        {
            return fail("statistics_cancelled");
        }
        match event.event.as_str() {
            "snapshot" => {
                let snapshot = event
                    .snapshot
                    .ok_or(Failure("statistics_invalid_response"))?;
                validate_snapshot(&snapshot, &sources)?;
                state.phase = match snapshot["status"].as_str() {
                    Some("ok") => "ready",
                    Some("partial") => "partial",
                    _ => "failed",
                };
                if state.phase != "failed" {
                    state.snapshot = Some(snapshot);
                }
                state.failure_code = if state.phase == "failed" {
                    Some("statistics_collection_failed")
                } else {
                    None
                };
            }
            "rate" => {
                if event.snapshot.is_some() {
                    return fail("statistics_invalid_response");
                }
            }
            "failed" => {
                if event.code.as_deref() == Some("cleanup_unconfirmed") {
                    return fail("statistics_cleanup_unconfirmed");
                }
                if !matches!(event.code.as_deref(), Some("timeout" | "collection_failed")) {
                    return fail("statistics_invalid_response");
                }
                state.phase = "failed";
                state.failure_code = Some("statistics_collection_failed");
            }
            _ => return fail("statistics_invalid_response"),
        }
        if let Some(rate) = &event.rate {
            validate_rate(rate, context)?;
        }
        state.token_rate = event.rate;
        state.revision = state
            .revision
            .checked_add(1)
            .ok_or(Failure("statistics_invalid_response"))?;
        Ok(())
    }
}
impl Drop for TokenMonitorService {
    fn drop(&mut self) {
        if let Ok(runtime) = self.runtime.get_mut() {
            if let Some(child) = runtime.as_mut() {
                child.terminate_now();
            }
        }
    }
}

fn safe_label(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && !value.chars().any(char::is_control)
        && !value.contains('\\')
        && !looks_email(value)
        && !value.contains("://")
        && !value.starts_with('/')
        && !value.contains("..")
        && !drive_path(value)
}
fn looks_email(value: &str) -> bool {
    value
        .rsplit_once('@')
        .is_some_and(|(left, right)| !left.is_empty() && right.contains('.'))
}
fn drive_path(value: &str) -> bool {
    let b = value.as_bytes();
    b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && (b[2] == b'/' || b[2] == b'\\')
}
fn valid_timezone(value: &str) -> bool {
    !value.is_empty() && value.len() <= 64 && value.parse::<chrono_tz::Tz>().is_ok()
}
fn validate_sources(sources: &[TokenMonitorSource]) -> Result<()> {
    if sources.len() > 256 {
        return fail("invalid_statistics_source");
    }
    let catalog = provider_catalog()?;
    let mut ids = BTreeSet::new();
    for source in sources {
        if !valid_id(&source.id)
            || !catalog.iter().any(|p| p.id == source.provider_id)
            || !safe_label(&source.label)
            || !ids.insert(&source.id)
            || !source.root.is_absolute()
            || source.root.parent().is_none()
        {
            return fail("invalid_statistics_source");
        }
        let name = source
            .root
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        if [
            "auth.json",
            "credentials.json",
            ".credentials.json",
            "token.json",
            "tokens.json",
        ]
        .contains(&name.as_str())
            || matches!(source.path_role, SourceRole::CodexHome) && source.provider_id != "codex"
            || source.provider_id == "codex" && !matches!(source.path_role, SourceRole::CodexHome)
        {
            return fail("invalid_statistics_source");
        }
    }
    Ok(())
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Selection {
    schema_version: u32,
    known_source_ids: BTreeSet<String>,
    enabled_source_ids: BTreeSet<String>,
}
fn read_selection(path: &Path, sources: &[TokenMonitorSource]) -> Result<BTreeSet<String>> {
    let bytes = match fs::read(path) {
        Ok(bytes) if bytes.len() <= 65536 => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Ok(sources
                .iter()
                .filter(|s| s.default_enabled)
                .map(|s| s.id.clone())
                .collect())
        }
        _ => return fail("invalid_statistics_settings"),
    };
    let settings: Selection =
        serde_json::from_slice(&bytes).map_err(|_| Failure("invalid_statistics_settings"))?;
    if settings.schema_version != 1
        || !settings
            .enabled_source_ids
            .is_subset(&settings.known_source_ids)
    {
        return fail("invalid_statistics_settings");
    }
    Ok(sources
        .iter()
        .filter(|s| {
            settings.enabled_source_ids.contains(&s.id)
                || s.default_enabled && !settings.known_source_ids.contains(&s.id)
        })
        .map(|s| s.id.clone())
        .collect())
}
fn save_selection(
    data: &Path,
    sources: &[TokenMonitorSource],
    enabled: &BTreeSet<String>,
) -> Result<()> {
    let bytes = serde_json::to_vec(&Selection {
        schema_version: 1,
        known_source_ids: sources.iter().map(|s| s.id.clone()).collect(),
        enabled_source_ids: enabled.clone(),
    })
    .map_err(|_| Failure("statistics_save_failed"))?;
    let mut temp =
        tempfile::NamedTempFile::new_in(data).map_err(|_| Failure("statistics_save_failed"))?;
    std::io::Write::write_all(&mut temp, &bytes).map_err(|_| Failure("statistics_save_failed"))?;
    temp.as_file()
        .sync_all()
        .map_err(|_| Failure("statistics_save_failed"))?;
    temp.persist(data.join("sources.json"))
        .map_err(|_| Failure("statistics_save_failed"))?;
    Ok(())
}
fn validate_rate(rate: &TokenRate, context: &str) -> Result<()> {
    let now = Utc::now().timestamp_millis();
    if rate.mode != "burn"
        || rate.scope != "local"
        || rate.context_key != context
        || !rate.burn_per_minute.is_finite()
        || !rate.speed_per_second.is_finite()
        || !(0.0..=1e12).contains(&rate.burn_per_minute)
        || !(0.0..=1e12).contains(&rate.speed_per_second)
        || rate.sampled_at <= 0
        || rate.sampled_at > now + 1000
        || rate.expires_at <= rate.sampled_at
        || rate.expires_at <= now
        || rate.expires_at - rate.sampled_at > if rate.idle { 180000 } else { 8000 }
    {
        return fail("statistics_invalid_response");
    }
    Ok(())
}
fn validate_snapshot(value: &Value, sources: &[TokenMonitorSource]) -> Result<()> {
    let object = value
        .as_object()
        .ok_or(Failure("statistics_invalid_response"))?;
    let expected = [
        "schemaVersion",
        "requestId",
        "engine",
        "collectedAt",
        "timezone",
        "status",
        "sources",
        "coverage",
        "errors",
        "historyCollectedAt",
        "payload",
    ];
    if object.len() != expected.len()
        || object.keys().any(|key| !expected.contains(&key.as_str()))
        || value["schemaVersion"] != 1
        || value["engine"]["repository"] != "Javis603/token-monitor"
        || value["engine"]["commit"] != ENGINE_COMMIT
        || value["engine"]["version"] != "0.68.0"
        || !matches!(value["status"].as_str(), Some("ok" | "partial" | "error"))
    {
        return fail("statistics_invalid_response");
    }
    for key in ["collectedAt"] {
        if DateTime::parse_from_rfc3339(
            value[key]
                .as_str()
                .ok_or(Failure("statistics_invalid_response"))?,
        )
        .is_err()
        {
            return fail("statistics_invalid_response");
        }
    }
    if value["timezone"]
        .as_str()
        .and_then(|tz| tz.parse::<chrono_tz::Tz>().ok())
        .is_none()
    {
        return fail("statistics_invalid_response");
    }
    let returned = value["sources"]
        .as_array()
        .ok_or(Failure("statistics_invalid_response"))?;
    if returned.len() > 256
        || returned.iter().any(|s| {
            !sources
                .iter()
                .any(|source| s["id"] == source.id && s["providerId"] == source.provider_id)
        })
    {
        return fail("statistics_invalid_response");
    }
    if !valid_id(
        value["requestId"]
            .as_str()
            .ok_or(Failure("statistics_invalid_response"))?,
    ) {
        return fail("statistics_invalid_response");
    }
    for source in returned {
        only(
            source,
            &["id", "providerId", "status", "coverage", "reasonCode"],
        )?;
        if !matches!(
            source["status"].as_str(),
            Some("ok" | "unavailable" | "error" | "excluded")
        ) || !matches!(
            source["coverage"].as_str(),
            Some("known" | "partial" | "unknown")
        ) {
            return fail("statistics_invalid_response");
        }
    }
    validate_tree(value, "", 0)?;
    for period in ["today", "month", "allTime"] {
        validate_period(&value["payload"]["aggregate"][period])?;
    }
    let payload = value["payload"]
        .as_object()
        .ok_or(Failure("statistics_invalid_response"))?;
    if payload
        .keys()
        .any(|k| !["aggregate", "history", "costEstimates"].contains(&k.as_str()))
    {
        return fail("statistics_invalid_response");
    }
    only(&value["engine"], &["repository", "commit", "version"])?;
    only(
        &value["payload"]["aggregate"],
        &["today", "month", "allTime"],
    )?;
    validate_history(&value["payload"]["history"])?;
    let estimates = &value["payload"]["costEstimates"];
    if !estimates.is_null() {
        only(estimates, &["daily", "totalCost", "status"])?;
        for day in estimates["daily"]
            .as_array()
            .ok_or(Failure("statistics_invalid_response"))?
        {
            only(day, &["date", "cost", "status"])?;
            date(&day["date"], false)?;
            if !matches!(
                day["status"].as_str(),
                Some("unknown" | "partial" | "estimated")
            ) {
                return fail("statistics_invalid_response");
            }
        }
    }
    only(&value["coverage"], &["entries", "days", "cost"])?;
    for entry in value["coverage"]["entries"]
        .as_array()
        .ok_or(Failure("statistics_invalid_response"))?
    {
        only(
            entry,
            &[
                "sourceId",
                "providerId",
                "toolId",
                "accountId",
                "date",
                "metric",
                "status",
            ],
        )?;
    }
    for day in value["coverage"]["days"]
        .as_array()
        .ok_or(Failure("statistics_invalid_response"))?
    {
        only(day, &["date", "status"])?;
    }
    for error in value["errors"]
        .as_array()
        .ok_or(Failure("statistics_invalid_response"))?
    {
        only(error, &["code", "sourceId", "retryable"])?;
    }
    Ok(())
}
fn only(value: &Value, keys: &[&str]) -> Result<()> {
    let map = value
        .as_object()
        .ok_or(Failure("statistics_invalid_response"))?;
    if map.keys().any(|k| !keys.contains(&k.as_str())) {
        return fail("statistics_invalid_response");
    }
    Ok(())
}
fn date(value: &Value, monthly: bool) -> Result<()> {
    let s = value
        .as_str()
        .ok_or(Failure("statistics_invalid_response"))?;
    let s = if monthly {
        format!("{s}-01")
    } else {
        s.to_owned()
    };
    if chrono::NaiveDate::parse_from_str(&s, "%Y-%m-%d").is_err() {
        return fail("statistics_invalid_response");
    }
    Ok(())
}
fn validate_history(value: &Value) -> Result<()> {
    if value.is_null() {
        return Ok(());
    }
    only(value, &["daily", "monthly", "summary"])?;
    let metrics = [
        "tokens",
        "cost",
        "unpricedTokens",
        "inputTokens",
        "outputTokens",
        "cacheReadTokens",
        "cacheWriteTokens",
        "unclassifiedTokens",
        "messages",
        "activeTimeMs",
    ];
    for (key, monthly) in [("daily", false), ("monthly", true)] {
        let rows = value[key]
            .as_array()
            .ok_or(Failure("statistics_invalid_response"))?;
        if rows.len() > 10000 {
            return fail("statistics_invalid_response");
        }
        let mut seen = BTreeSet::new();
        for row in rows {
            let mut fields = metrics.to_vec();
            fields.extend([
                if monthly { "month" } else { "date" },
                "perClient",
                "perModel",
            ]);
            only(row, &fields)?;
            date(&row[if monthly { "month" } else { "date" }], monthly)?;
            if !seen.insert(
                row[if monthly { "month" } else { "date" }]
                    .clone()
                    .to_string(),
            ) {
                return fail("statistics_invalid_response");
            }
            for group in ["perClient", "perModel"] {
                for (name, bucket) in row[group]
                    .as_object()
                    .ok_or(Failure("statistics_invalid_response"))?
                {
                    if !safe_label(name) && name != "<synthetic>" {
                        return fail("statistics_invalid_response");
                    }
                    only(bucket, &metrics)?;
                }
            }
        }
    }
    only(
        &value["summary"],
        &[
            "totalTokens",
            "totalCost",
            "activeDays",
            "currentStreak",
            "longestStreak",
            "messages",
            "peakDayTokens",
            "unpricedTokens",
            "activeTimeMs",
            "favoriteModel",
            "timeMetrics",
        ],
    )?;
    if !value["summary"]["timeMetrics"].is_null() {
        only(
            &value["summary"]["timeMetrics"],
            &[
                "totalActiveTimeMs",
                "longestContinuousMs",
                "maxConcurrentSessions",
                "sessionCount",
            ],
        )?;
    }
    Ok(())
}
fn validate_period(value: &Value) -> Result<()> {
    if value.is_null() {
        return Ok(());
    }
    let obj = value
        .as_object()
        .ok_or(Failure("statistics_invalid_response"))?;
    let numeric = [
        "totalTokens",
        "costUsd",
        "unpricedTokens",
        "inputTokens",
        "outputTokens",
        "cacheReadTokens",
        "cacheWriteTokens",
        "unclassifiedTokens",
        "timedTokens",
        "timedOutputTokens",
        "timedDurationMs",
    ];
    let maps = [
        "clients",
        "clientCosts",
        "clientCacheReads",
        "clientCacheWrites",
        "clientOutputs",
        "clientUnclassifiedTokens",
        "models",
        "modelCosts",
        "modelCacheReads",
        "modelCacheWrites",
        "modelOutputs",
        "modelUnclassifiedTokens",
    ];
    if obj.keys().any(|k| {
        !numeric.contains(&k.as_str())
            && !maps.contains(&k.as_str())
            && !["capabilities", "modelThroughput"].contains(&k.as_str())
    }) {
        return fail("statistics_invalid_response");
    }
    for key in numeric {
        if !value[key].is_null() {
            number(&value[key])?;
        }
    }
    for key in maps {
        let map = value[key]
            .as_object()
            .ok_or(Failure("statistics_invalid_response"))?;
        if map.len() > 10000 {
            return fail("statistics_invalid_response");
        }
        for (name, v) in map {
            if !safe_label(name) && name != "<synthetic>" {
                return fail("statistics_invalid_response");
            }
            if !v.is_null() {
                number(v)?;
            }
        }
    }
    only(&value["capabilities"], &["throughput"])?;
    if value["capabilities"]["throughput"].as_bool().is_none() {
        return fail("statistics_invalid_response");
    }
    if !value["modelThroughput"].is_null() {
        for (name, bucket) in value["modelThroughput"]
            .as_object()
            .ok_or(Failure("statistics_invalid_response"))?
        {
            if !safe_label(name) && name != "<synthetic>" {
                return fail("statistics_invalid_response");
            }
            only(
                bucket,
                &["timedTokens", "timedOutputTokens", "timedDurationMs"],
            )?;
            for key in ["timedTokens", "timedOutputTokens", "timedDurationMs"] {
                if !bucket[key].is_null() {
                    number(&bucket[key])?;
                }
            }
        }
    }
    Ok(())
}
/// serde_json::Value normally keeps the last duplicate. Check the wire before
/// decoding the DTO so ambiguity can never change a validated public field.
struct UniqueJson;
impl<'de> Deserialize<'de> for UniqueJson {
    fn deserialize<D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> std::result::Result<Self, D::Error> {
        struct Visitor;
        impl<'de> serde::de::Visitor<'de> for Visitor {
            type Value = UniqueJson;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("JSON without duplicate keys")
            }
            fn visit_map<M: serde::de::MapAccess<'de>>(
                self,
                mut map: M,
            ) -> std::result::Result<Self::Value, M::Error> {
                let mut seen = BTreeSet::new();
                while let Some(key) = map.next_key::<String>()? {
                    if !seen.insert(key) {
                        return Err(serde::de::Error::custom("duplicate key"));
                    }
                    map.next_value::<UniqueJson>()?;
                }
                Ok(UniqueJson)
            }
            fn visit_seq<S: serde::de::SeqAccess<'de>>(
                self,
                mut seq: S,
            ) -> std::result::Result<Self::Value, S::Error> {
                while seq.next_element::<UniqueJson>()?.is_some() {}
                Ok(UniqueJson)
            }
            fn visit_str<E: serde::de::Error>(
                self,
                _: &str,
            ) -> std::result::Result<Self::Value, E> {
                Ok(UniqueJson)
            }
            fn visit_bool<E: serde::de::Error>(
                self,
                _: bool,
            ) -> std::result::Result<Self::Value, E> {
                Ok(UniqueJson)
            }
            fn visit_i64<E: serde::de::Error>(self, _: i64) -> std::result::Result<Self::Value, E> {
                Ok(UniqueJson)
            }
            fn visit_u64<E: serde::de::Error>(self, _: u64) -> std::result::Result<Self::Value, E> {
                Ok(UniqueJson)
            }
            fn visit_f64<E: serde::de::Error>(self, _: f64) -> std::result::Result<Self::Value, E> {
                Ok(UniqueJson)
            }
            fn visit_unit<E: serde::de::Error>(self) -> std::result::Result<Self::Value, E> {
                Ok(UniqueJson)
            }
        }
        deserializer.deserialize_any(Visitor)
    }
}
fn number(value: &Value) -> Result<()> {
    match value.as_f64() {
        Some(v) if v.is_finite() && (0.0..=9007199254740991.0).contains(&v) => Ok(()),
        _ => fail("statistics_invalid_response"),
    }
}
fn validate_tree(value: &Value, key: &str, depth: usize) -> Result<()> {
    if depth > 20 {
        return fail("statistics_invalid_response");
    }
    let forbidden = [
        "auth",
        "authorization",
        "credential",
        "credentials",
        "token",
        "access_token",
        "refresh_token",
        "api_key",
        "password",
        "cookie",
        "email",
        "prompt",
        "response",
        "content",
        "text",
        "transcript",
        "path",
        "cwd",
        "directory",
        "homedir",
        "hostname",
        "title",
    ];
    if forbidden.contains(&key.to_ascii_lowercase().as_str()) {
        return fail("statistics_private_response");
    }
    match value {
        Value::String(s) => {
            if s.len() > 256
                || s.chars().any(char::is_control)
                || s.contains('\\')
                || s.starts_with('/')
                || s.contains("://") && key != "repository"
                || looks_email(s)
                || s.to_ascii_lowercase().contains("bearer ")
                || s.contains("sk-")
                || drive_path(s)
                || s.contains("/Users/")
                || s.contains("/home/")
            {
                return fail("statistics_private_response");
            }
        }
        Value::Number(_) => number(value)?,
        Value::Array(items) => {
            if items.len() > 100000 {
                return fail("statistics_invalid_response");
            }
            for item in items {
                validate_tree(item, key, depth + 1)?;
            }
        }
        Value::Object(map) => {
            if map.len() > 10000 {
                return fail("statistics_invalid_response");
            }
            for (k, v) in map {
                validate_tree(v, k, depth + 1)?;
            }
        }
        _ => (),
    }
    Ok(())
}

#[cfg(test)]
#[path = "token_monitor/tests.rs"]
mod tests;
