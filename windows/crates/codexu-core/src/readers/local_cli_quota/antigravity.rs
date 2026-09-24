//! Read-only Antigravity quota observation for Windows.
//!
//! This mirrors `AntigravityCLIQuotaReader.swift`. It only observes the
//! already-running official desktop application, or an explicitly selected legacy
//! IDE cache. It never starts an OAuth flow, refreshes a token, reads browser
//! storage, or switches accounts.
//!
//! Windows mapping of the macOS kernel-identity checks:
//! - the owning process must be a `language_server*.exe` inside an `Antigravity`
//!   install root;
//! - the process must be openable by this user, which another user's server is
//!   not;
//! - the port must be a listening IPv4 loopback port owned by that very PID, read
//!   from the TCP owner-PID table rather than trusted from a command-line flag.
//!
//! Cache boundary carried over from macOS: a failed live read never substitutes a
//! previous account's IDE cache, and a cache result is history, never proof of a
//! fresh quota or a current sign-in.

use std::collections::BTreeMap;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use chrono::{DateTime, TimeZone, Utc};
use serde_json::Value as Json;

use super::{
    fingerprint, valid_windows, LocalCliQuotaResult, LocalCliQuotaState, LocalCliQuotaWindow,
};
use crate::local_cli::{bounded_label, masked_identity, valid_identity, LocalCliKind};

pub const MAX_BYTES: usize = 1_048_576;
const SERVICE_PATH: &str = "/exa.language_server_pb.LanguageServerService/";
const ALLOWED_METHODS: [&str; 2] = ["GetUserStatus", "RetrieveUserQuotaSummary"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EndpointScheme {
    Http,
    Https,
}

/// One candidate local Antigravity endpoint and the evidence behind it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AntigravityEndpoint {
    pub pid: u32,
    pub birth_seconds: u64,
    pub executable: PathBuf,
    pub port: u16,
    pub csrf: String,
    pub scheme: EndpointScheme,
}

/// A process observed on this machine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcessEntry {
    pub pid: u32,
    pub executable: PathBuf,
    pub command_line: String,
    pub birth_seconds: u64,
}

#[derive(Debug, Clone)]
pub struct LoopbackRequest {
    pub scheme: EndpointScheme,
    pub port: u16,
    pub path: String,
    pub csrf: String,
    pub body: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct LoopbackResponse {
    pub status: u16,
    pub body: Vec<u8>,
}

/// A previously observed IDE cache blob. `modified_at` is a file observation time,
/// never an official quota observation time.
#[derive(Debug, Clone)]
pub struct AntigravityCache {
    pub data: Vec<u8>,
    pub modified_at: DateTime<Utc>,
}

pub type Transport =
    Arc<dyn Fn(&LoopbackRequest) -> anyhow::Result<LoopbackResponse> + Send + Sync>;
pub type ProcessLister = Arc<dyn Fn() -> anyhow::Result<Vec<ProcessEntry>> + Send + Sync>;
pub type PortLister = Arc<dyn Fn(u32) -> anyhow::Result<Vec<u16>> + Send + Sync>;
pub type CacheReader = Arc<dyn Fn(&Path) -> anyhow::Result<Option<AntigravityCache>> + Send + Sync>;

/// Everything the reader needs, injectable so the whole state machine can be
/// exercised without a running Antigravity install.
#[derive(Clone)]
pub struct AntigravityReader {
    pub transport: Transport,
    pub processes: ProcessLister,
    pub ports: PortLister,
    pub cache: CacheReader,
}

impl AntigravityReader {
    pub fn native() -> Self {
        Self {
            transport: Arc::new(native_transport),
            processes: Arc::new(native_processes),
            ports: Arc::new(native_ports),
            cache: Arc::new(native_cache),
        }
    }

    pub fn synthetic(
        transport: Transport,
        processes: ProcessLister,
        ports: PortLister,
        cache: CacheReader,
    ) -> Self {
        Self {
            transport,
            processes,
            ports,
            cache,
        }
    }

    /// Observe one Antigravity account directory.
    ///
    /// `is_shared` marks the platform default directory; only there may the
    /// running desktop application be queried live.
    pub fn load(&self, root: &Path, is_shared: bool, now: DateTime<Utc>) -> LocalCliQuotaResult {
        if is_shared {
            let endpoints = match (self.processes)() {
                Ok(endpoints) => endpoints,
                Err(_) => {
                    // Failure to inspect processes is not evidence that no live
                    // account exists. Do not substitute an unbound cache.
                    return result(
                        LocalCliQuotaState::Unavailable,
                        now,
                        None,
                        None,
                        Vec::new(),
                        false,
                        Some("local_cli_antigravity_live_unavailable"),
                    );
                }
            };
            let candidates = discover_with(&endpoints, |pid| (self.ports)(pid));
            let discovered_live_endpoint = !candidates.is_empty();
            for endpoint in candidates.iter().take(6) {
                if !verify_with(&endpoints, |pid| (self.ports)(pid), endpoint) {
                    continue;
                }
                let status = match self.request("GetUserStatus", endpoint) {
                    Ok(response) => response,
                    Err(_) => continue,
                };
                let identity = match parse_status(&status, now) {
                    Ok(value) => value,
                    Err(_) => continue,
                };
                let Some(account) = identity.identity else {
                    continue;
                };
                let mut windows = identity.windows;
                if let Ok(summary) = self.request("RetrieveUserQuotaSummary", endpoint) {
                    if let Ok(richer) = parse_summary(&summary, now) {
                        if !richer.is_empty() && valid_windows(&richer) {
                            windows = richer;
                        }
                    }
                }
                // The user can switch accounts in Antigravity during a refresh.
                // Never combine one account's identity with another's summary.
                let after = match self
                    .request("GetUserStatus", endpoint)
                    .and_then(|response| parse_status(&response, now).map_err(anyhow::Error::from))
                {
                    Ok(value) => value,
                    Err(_) => continue,
                };
                if after.identity.as_deref().map(|value| value.to_lowercase())
                    != Some(account.to_lowercase())
                {
                    return result(
                        LocalCliQuotaState::Unavailable,
                        now,
                        None,
                        None,
                        Vec::new(),
                        false,
                        Some("local_cli_antigravity_account_changed"),
                    );
                }
                let empty = windows.is_empty();
                return result(
                    if empty {
                        LocalCliQuotaState::Unavailable
                    } else {
                        LocalCliQuotaState::Available
                    },
                    now,
                    Some(&account),
                    after.plan.or(identity.plan),
                    windows,
                    false,
                    if empty {
                        Some("local_cli_antigravity_no_quota")
                    } else {
                        None
                    },
                );
            }
            // A failed live read must not substitute a previous account's cache.
            if discovered_live_endpoint {
                return result(
                    LocalCliQuotaState::Unavailable,
                    now,
                    None,
                    None,
                    Vec::new(),
                    false,
                    Some("local_cli_antigravity_live_unavailable"),
                );
            }
        }

        match (self.cache)(root) {
            Ok(Some(cached)) => match parse_cache(&cached, now) {
                Ok(value) => value,
                Err(_) => result(
                    LocalCliQuotaState::Unavailable,
                    now,
                    None,
                    None,
                    Vec::new(),
                    false,
                    Some("local_cli_antigravity_cache_unavailable"),
                ),
            },
            _ => result(
                LocalCliQuotaState::Unavailable,
                now,
                None,
                None,
                Vec::new(),
                false,
                Some(if is_shared {
                    "local_cli_antigravity_open_app"
                } else {
                    "local_cli_antigravity_linked_cache_only"
                }),
            ),
        }
    }

    fn request(&self, method: &str, endpoint: &AntigravityEndpoint) -> anyhow::Result<Vec<u8>> {
        if !ALLOWED_METHODS.contains(&method) {
            anyhow::bail!("Unsupported Antigravity method");
        }
        if endpoint.csrf.is_empty() || endpoint.csrf.len() > 512 {
            anyhow::bail!("Missing or oversized CSRF token");
        }
        if endpoint.csrf.chars().any(char::is_control) {
            anyhow::bail!("Malformed CSRF token");
        }
        let body: Json = if method == "RetrieveUserQuotaSummary" {
            serde_json::json!({ "forceRefresh": true })
        } else {
            serde_json::json!({
                "metadata": { "ideName": "antigravity", "extensionName": "antigravity", "locale": "en" }
            })
        };
        let response = (self.transport)(&LoopbackRequest {
            scheme: endpoint.scheme,
            port: endpoint.port,
            path: format!("{}{}", SERVICE_PATH, method),
            csrf: endpoint.csrf.clone(),
            body: serde_json::to_vec(&body)?,
        })?;
        if response.status != 200 || response.body.len() > MAX_BYTES {
            anyhow::bail!("Antigravity endpoint returned an unusable response");
        }
        Ok(response.body)
    }
}

/// Entry point used by the shared quota dispatcher.
pub fn load_default(root: &Path, is_shared: bool, now: DateTime<Utc>) -> LocalCliQuotaResult {
    AntigravityReader::native().load(root, is_shared, now)
}

fn result(
    state: LocalCliQuotaState,
    at: DateTime<Utc>,
    identity: Option<&str>,
    plan: Option<String>,
    windows: Vec<LocalCliQuotaWindow>,
    cached: bool,
    code: Option<&str>,
) -> LocalCliQuotaResult {
    let identity = identity.and_then(valid_identity);
    let mut value = LocalCliQuotaResult::new(
        state,
        at,
        if cached {
            "Antigravity · cached IDE quota"
        } else {
            "Antigravity · official desktop quota"
        },
        code,
    );
    value.identity_fingerprint = identity
        .as_deref()
        .map(|value| fingerprint(LocalCliKind::Antigravity, value));
    value.masked_identity = identity.as_deref().map(masked_identity);
    value.plan_label = plan.and_then(|value| bounded_label(&value, 64));
    if valid_windows(&windows) {
        value.windows = windows;
    }
    value
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

/// Keep only processes that really are the official Antigravity language server,
/// and pair them with ports that same process listens on.
pub fn discover_with<F>(processes: &[ProcessEntry], ports: F) -> Vec<AntigravityEndpoint>
where
    F: Fn(u32) -> anyhow::Result<Vec<u16>>,
{
    let mut endpoints = Vec::new();
    for entry in processes {
        if !is_language_server(&entry.executable) {
            continue;
        }
        let Some(csrf) = flag("--csrf_token", &entry.command_line) else {
            continue;
        };
        let Ok(listening) = ports(entry.pid) else {
            continue;
        };
        let mut owned: BTreeSet<u16> = listening.into_iter().filter(|port| *port != 0).collect();
        for port in owned.iter().take(4) {
            endpoints.push(AntigravityEndpoint {
                pid: entry.pid,
                birth_seconds: entry.birth_seconds,
                executable: entry.executable.clone(),
                port: *port,
                csrf: csrf.clone(),
                scheme: EndpointScheme::Https,
            });
        }
        // The legacy extension HTTP endpoint is only eligible when this same
        // verified process owns the advertised port. Never trust a bare flag.
        if let Some(text) = flag("--extension_server_port", &entry.command_line) {
            if let Ok(port) = text.parse::<u16>() {
                if owned.contains(&port) {
                    let token = flag("--extension_server_csrf_token", &entry.command_line)
                        .unwrap_or_else(|| csrf.clone());
                    endpoints.push(AntigravityEndpoint {
                        pid: entry.pid,
                        birth_seconds: entry.birth_seconds,
                        executable: entry.executable.clone(),
                        port,
                        csrf: token,
                        scheme: EndpointScheme::Http,
                    });
                    let _ = owned.remove(&port);
                }
            }
        }
        if endpoints.len() >= 6 {
            break;
        }
    }
    endpoints
}

/// Re-check path, start time and port ownership immediately before and after a
/// request, so a reused PID cannot receive the CSRF token.
pub fn verify_with<F>(processes: &[ProcessEntry], ports: F, endpoint: &AntigravityEndpoint) -> bool
where
    F: Fn(u32) -> anyhow::Result<Vec<u16>>,
{
    let Some(entry) = processes.iter().find(|entry| entry.pid == endpoint.pid) else {
        return false;
    };
    if entry.executable != endpoint.executable || entry.birth_seconds != endpoint.birth_seconds {
        return false;
    }
    if !is_language_server(&entry.executable) {
        return false;
    }
    match ports(entry.pid) {
        Ok(listening) => listening.contains(&endpoint.port),
        Err(_) => false,
    }
}

/// The executable must be a `language_server*.exe` inside an Antigravity
/// install root. This replaces the macOS bundle-identifier check.
pub fn is_language_server(executable: &Path) -> bool {
    let Some(file_name) = executable
        .file_name()
        .map(|value| value.to_string_lossy().to_lowercase())
    else {
        return false;
    };
    if !file_name.starts_with("language_server") || !file_name.ends_with(".exe") {
        return false;
    }
    let Some(parent_text) = executable
        .parent()
        .map(|value| value.to_string_lossy().to_lowercase())
    else {
        return false;
    };
    if !parent_text.contains("antigravity") {
        return false;
    }
    is_under_install_root(executable)
}

fn is_under_install_root(executable: &Path) -> bool {
    let lower = executable
        .to_string_lossy()
        .to_lowercase()
        .replace('/', "\\");
    let mut roots: Vec<String> = Vec::new();
    for key in ["LOCALAPPDATA", "ProgramFiles", "PROGRAMFILES(X86)"] {
        if let Ok(value) = std::env::var(key) {
            roots.push(value.to_lowercase());
        }
    }
    if roots.is_empty() {
        return false;
    }
    roots.iter().any(|root| lower.starts_with(root.as_str()))
}

/// Read `--flag value` or `--flag=value` from a command line.
pub fn flag(name: &str, command: &str) -> Option<String> {
    let mut pieces = command.split_whitespace();
    while let Some(piece) = pieces.next() {
        if piece == name {
            return pieces
                .next()
                .filter(|value| is_token(value))
                .map(|value| value.to_string());
        }
        if let Some(rest) = piece.strip_prefix(&format!("{}=", name)) {
            if is_token(rest) {
                return Some(rest.to_string());
            }
        }
    }
    None
}

fn is_token(value: &str) -> bool {
    // A value that starts with '-' is the next flag, not this flag's value.
    !value.is_empty()
        && !value.starts_with('-')
        && value.len() <= 512
        && value.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-')
        })
}

// ---------------------------------------------------------------------------
// Response parsing
// ---------------------------------------------------------------------------

pub struct Status {
    pub identity: Option<String>,
    pub plan: Option<String>,
    pub windows: Vec<LocalCliQuotaWindow>,
}

fn object(bytes: &[u8]) -> anyhow::Result<Json> {
    anyhow::ensure!(bytes.len() <= MAX_BYTES, "Response too large");
    let value: Json = serde_json::from_slice(bytes)?;
    let object = value
        .as_object()
        .ok_or_else(|| anyhow::anyhow!("Response is not an object"))?;
    if let Some(code) = object.get("code") {
        let accepted = match code.as_str() {
            Some(text) => ["ok", "success", "0"].contains(&text.to_lowercase().as_str()),
            None => matches!(code.as_i64(), Some(0)),
        };
        anyhow::ensure!(accepted, "Response reported an error code");
    }
    Ok(value)
}

pub fn parse_status(bytes: &[u8], now: DateTime<Utc>) -> anyhow::Result<Status> {
    let value = object(bytes)?;
    let status = value
        .get("userStatus")
        .and_then(|value| value.as_object())
        .ok_or_else(|| anyhow::anyhow!("Missing userStatus"))?;
    let identity = status
        .get("email")
        .and_then(|value| value.as_str())
        .and_then(valid_identity);
    let plan_info = status
        .get("planStatus")
        .and_then(|value| value.get("planInfo"))
        .and_then(|value| value.as_object())
        .cloned();
    let tier = status.get("userTier").and_then(|value| value.as_object());
    let plan = tier
        .and_then(|tier| tier.get("name"))
        .and_then(|value| value.as_str())
        .and_then(|value| bounded_label(value, 64))
        .or_else(|| {
            [
                "planDisplayName",
                "displayName",
                "productName",
                "planName",
                "planShortName",
            ]
            .iter()
            .filter_map(|key| plan_info.as_ref().and_then(|info| info.get(*key)))
            .filter_map(|value| value.as_str())
            .find_map(|value| bounded_label(value, 64))
        });
    let models = status
        .get("cascadeModelConfigData")
        .and_then(|value| value.get("clientModelConfigs"))
        .and_then(|value| value.as_array())
        .cloned()
        .unwrap_or_default();
    anyhow::ensure!(models.len() <= 256, "Too many models");
    let mut windows = Vec::new();
    for (index, model) in models.iter().enumerate() {
        let Some(label) = model
            .get("label")
            .and_then(|value| value.as_str())
            .and_then(|value| bounded_label(value, 128))
        else {
            continue;
        };
        let Some(quota) = model.get("quotaInfo").and_then(|value| value.as_object()) else {
            continue;
        };
        let Some(remaining) = fraction(quota.get("remainingFraction")) else {
            continue;
        };
        let reset = timestamp(quota.get("resetTime"));
        if reset.map(|value| value <= now).unwrap_or(false) {
            continue;
        }
        windows.push(LocalCliQuotaWindow {
            id: format!("model-{}", index),
            label,
            used_percent: (1.0 - remaining) * 100.0,
            resets_at: reset,
        });
    }
    Ok(Status {
        identity,
        plan,
        windows,
    })
}

pub fn parse_summary(bytes: &[u8], now: DateTime<Utc>) -> anyhow::Result<Vec<LocalCliQuotaWindow>> {
    let value = object(bytes)?;
    let fallback = value
        .as_object()
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("Response is not an object"))?;
    let payload = value
        .get("response")
        .and_then(|value| value.as_object())
        .or_else(|| value.get("summary").and_then(|value| value.as_object()))
        .unwrap_or(&fallback);
    let groups = payload
        .get("groups")
        .and_then(|value| value.as_array())
        .ok_or_else(|| anyhow::anyhow!("Missing groups"))?;
    anyhow::ensure!(groups.len() <= 32, "Too many groups");
    let mut windows = Vec::new();
    for (group_index, group) in groups.iter().enumerate() {
        let group_name = ["displayName", "name"]
            .iter()
            .filter_map(|key| group.get(*key))
            .filter_map(|value| value.as_str())
            .find_map(|value| bounded_label(value, 64))
            .unwrap_or_else(|| "Quota".to_string());
        let buckets = group
            .get("buckets")
            .and_then(|value| value.as_array())
            .cloned()
            .unwrap_or_default();
        anyhow::ensure!(buckets.len() <= 32, "Too many buckets");
        for (bucket_index, bucket) in buckets.iter().enumerate() {
            if bucket.get("disabled").and_then(|value| value.as_bool()) == Some(true) {
                continue;
            }
            let remaining_object = bucket
                .get("remaining")
                .and_then(|value| value.as_object())
                .cloned()
                .unwrap_or_default();
            let raw = bucket
                .get("remainingFraction")
                .or_else(|| remaining_object.get("remainingFraction"))
                .or_else(|| {
                    if remaining_object
                        .get("case")
                        .and_then(|value| value.as_str())
                        == Some("remainingFraction")
                    {
                        remaining_object.get("value")
                    } else {
                        None
                    }
                });
            let Some(remaining) = fraction(raw) else {
                continue;
            };
            let Some(name) = ["displayName", "name", "bucketId", "id"]
                .iter()
                .filter_map(|key| bucket.get(*key))
                .filter_map(|value| value.as_str())
                .find_map(|value| bounded_label(value, 64))
            else {
                continue;
            };
            let reset = timestamp(bucket.get("resetTime"));
            if reset.map(|value| value <= now).unwrap_or(false) {
                continue;
            }
            let mut label = format!("{} · {}", group_name, name);
            label.truncate(100);
            windows.push(LocalCliQuotaWindow {
                id: format!("group-{}-bucket-{}", group_index, bucket_index),
                label,
                used_percent: (1.0 - remaining) * 100.0,
                resets_at: reset,
            });
        }
    }
    anyhow::ensure!(valid_windows(&windows), "Invalid windows");
    Ok(windows)
}

fn fraction(value: Option<&Json>) -> Option<f64> {
    value
        .and_then(|value| value.as_f64())
        .filter(|value| value.is_finite() && (0.0..=1.0).contains(value))
}

fn timestamp(value: Option<&Json>) -> Option<DateTime<Utc>> {
    value
        .and_then(|value| value.as_str())
        .filter(|value| value.len() <= 80)
        .and_then(|value| DateTime::parse_from_rfc3339(value).ok())
        .map(|value| value.with_timezone(&Utc))
}

// ---------------------------------------------------------------------------
// Legacy IDE cache
// ---------------------------------------------------------------------------

pub fn cache_file(root: &Path) -> Option<PathBuf> {
    if !root.is_absolute() {
        return None;
    }
    let file = root.join("User").join("globalStorage").join("state.vscdb");
    let metadata = std::fs::metadata(&file).ok()?;
    if !metadata.is_file() || metadata.len() > 512 * 1024 * 1024 {
        return None;
    }
    Some(file)
}

/// Read the cached auth status blob. `Ok(None)` means the selected directory is
/// not a usable cache.
pub fn native_cache(root: &Path) -> anyhow::Result<Option<AntigravityCache>> {
    let Some(file) = cache_file(root) else {
        return Ok(None);
    };
    let connection = rusqlite::Connection::open_with_flags(
        file.clone(),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    let mut statement = connection.prepare(
        "SELECT CAST(value AS TEXT) AS auth FROM ItemTable WHERE key='antigravityAuthStatus' AND length(value)<=1048576 LIMIT 1",
    )?;
    let mut rows = statement.query([])?;
    let Some(row) = rows.next()? else {
        return Ok(None);
    };
    let text: String = row.get(0)?;
    if text.len() > MAX_BYTES {
        return Ok(None);
    }
    let modified = std::fs::metadata(&file)
        .and_then(|metadata| metadata.modified())
        .map(DateTime::<Utc>::from)
        .unwrap_or_else(|_| Utc.timestamp_opt(0, 0).unwrap());
    Ok(Some(AntigravityCache {
        data: text.into_bytes(),
        modified_at: modified,
    }))
}

pub fn parse_cache(
    cache: &AntigravityCache,
    now: DateTime<Utc>,
) -> anyhow::Result<LocalCliQuotaResult> {
    let value: Json = serde_json::from_slice(&cache.data)?;
    let object = value
        .as_object()
        .ok_or_else(|| anyhow::anyhow!("Cache is not an object"))?;
    let base64_text = object
        .get("userStatusProtoBinaryBase64")
        .and_then(|value| value.as_str())
        .ok_or_else(|| anyhow::anyhow!("Cache has no status blob"))?;
    let payload = decode_base64(base64_text).ok_or_else(|| anyhow::anyhow!("Bad base64"))?;
    anyhow::ensure!(payload.len() <= MAX_BYTES, "Cache too large");
    let root = protobuf(&payload)?;
    let embedded = root
        .get(&7)
        .and_then(|values| values.first())
        .and_then(|value| value.bytes.as_ref())
        .and_then(|bytes| String::from_utf8(bytes.clone()).ok());
    let identity = valid_identity(
        embedded
            .as_deref()
            .or_else(|| object.get("email").and_then(|value| value.as_str()))
            .unwrap_or(""),
    )
    .ok_or_else(|| anyhow::anyhow!("Cache has no usable identity"))?;
    if let (Some(embedded), Some(outer)) = (
        embedded.as_deref(),
        object.get("email").and_then(|value| value.as_str()),
    ) {
        anyhow::ensure!(
            embedded.to_lowercase() == outer.to_lowercase(),
            "Cache identity mismatch"
        );
    }
    let mut windows = Vec::new();
    for group in root.get(&33).cloned().unwrap_or_default() {
        let Some(bytes) = group.bytes else { continue };
        for model in protobuf(&bytes)?.get(&1).cloned().unwrap_or_default() {
            let Some(data) = model.bytes else { continue };
            let fields = protobuf(&data)?;
            let Some(label) = fields
                .get(&1)
                .and_then(|values| values.first())
                .and_then(|value| value.bytes.as_ref())
                .and_then(|bytes| String::from_utf8(bytes.clone()).ok())
                .and_then(|value| bounded_label(&value, 128))
            else {
                continue;
            };
            let Some(quota_bytes) = fields
                .get(&15)
                .and_then(|values| values.first())
                .and_then(|value| value.bytes.clone())
            else {
                continue;
            };
            let quota = protobuf(&quota_bytes)?;
            let Some(remaining) = quota
                .get(&1)
                .and_then(|values| values.first())
                .and_then(|value| value.fraction)
                .filter(|value| value.is_finite() && (0.0..=1.0).contains(value))
            else {
                continue;
            };
            let reset = quota
                .get(&2)
                .and_then(|values| values.first())
                .and_then(|value| value.bytes.clone())
                .and_then(|bytes| protobuf(&bytes).ok())
                .and_then(|time| {
                    let seconds = time.get(&1)?.first()?.integer?;
                    if seconds > 253_402_300_799 {
                        return None;
                    }
                    let nanos = time
                        .get(&2)
                        .and_then(|values| values.first())
                        .and_then(|value| value.integer)
                        .unwrap_or(0);
                    if nanos >= 1_000_000_000 {
                        return None;
                    }
                    Utc.timestamp_opt(seconds as i64, nanos as u32).single()
                });
            // An old reset time does not establish that the bucket refilled.
            if reset.map(|value| value <= now).unwrap_or(false) {
                continue;
            }
            windows.push(LocalCliQuotaWindow {
                id: format!("cache-model-{}", windows.len()),
                label,
                used_percent: (1.0 - remaining) * 100.0,
                resets_at: reset,
            });
        }
    }
    anyhow::ensure!(valid_windows(&windows), "Invalid cached windows");
    anyhow::ensure!(
        cache.modified_at <= now + chrono::Duration::seconds(60),
        "Cache modified in the future"
    );
    Ok(result(
        // Cache-file mtime is not the official quota observation time. Keep
        // history visible but never let it prove fresh quota or sign-in.
        LocalCliQuotaState::Unavailable,
        cache.modified_at,
        Some(&identity),
        None,
        windows,
        true,
        Some("local_cli_antigravity_cached_quota"),
    ))
}

fn decode_base64(text: &str) -> Option<Vec<u8>> {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let bytes: Vec<u8> = text
        .bytes()
        .filter(|byte| !matches!(byte, b'\n' | b'\r' | b' ' | b'\t'))
        .collect();
    if bytes.is_empty() || bytes.len() % 4 != 0 {
        return None;
    }
    let mut output = Vec::with_capacity(bytes.len() / 4 * 3);
    for chunk in bytes.chunks(4) {
        let mut value: u32 = 0;
        for (index, byte) in chunk.iter().enumerate() {
            if *byte == b'=' {
                continue;
            }
            let Some(position) = TABLE.iter().position(|candidate| candidate == byte) else {
                return None;
            };
            value |= (position as u32) << (18 - index * 6);
        }
        let produced = match chunk.iter().filter(|byte| **byte != b'=').count() {
            2 => 1,
            3 => 2,
            4 => 3,
            _ => return None,
        };
        for index in 0..produced {
            output.push(((value >> (16 - index * 8)) & 0xff) as u8);
        }
    }
    Some(output)
}

#[derive(Debug, Clone)]
struct ProtoValue {
    bytes: Option<Vec<u8>>,
    integer: Option<u64>,
    fraction: Option<f64>,
}

fn protobuf(data: &[u8]) -> anyhow::Result<BTreeMap<u64, Vec<ProtoValue>>> {
    anyhow::ensure!(data.len() <= MAX_BYTES, "Protobuf too large");
    let mut offset = 0usize;
    let mut fields: BTreeMap<u64, Vec<ProtoValue>> = BTreeMap::new();

    fn varint(bytes: &[u8], offset: &mut usize) -> anyhow::Result<u64> {
        let mut value: u64 = 0;
        for index in 0..10 {
            anyhow::ensure!(*offset < bytes.len(), "Truncated varint");
            let byte = bytes[*offset];
            *offset += 1;
            anyhow::ensure!(index != 9 || byte <= 1, "Oversized varint");
            value |= ((byte & 0x7f) as u64) << (index * 7);
            if byte < 128 {
                return Ok(value);
            }
        }
        anyhow::bail!("Unterminated varint")
    }

    let mut count = 0usize;
    while offset < data.len() {
        count += 1;
        anyhow::ensure!(count <= 4096, "Too many protobuf fields");
        let key = varint(data, &mut offset)?;
        let field = key >> 3;
        anyhow::ensure!(field > 0 && field <= 0x1fff_ffff, "Invalid field number");
        let value = match key & 7 {
            0 => {
                let integer = varint(data, &mut offset)?;
                ProtoValue {
                    bytes: None,
                    integer: Some(integer),
                    fraction: Some(integer as f64),
                }
            }
            1 | 5 => {
                let length = if key & 7 == 1 { 8 } else { 4 };
                anyhow::ensure!(data.len() - offset >= length, "Truncated fixed value");
                let mut raw: u64 = 0;
                for index in 0..length {
                    raw |= (data[offset + index] as u64) << (8 * index);
                }
                offset += length;
                ProtoValue {
                    bytes: None,
                    integer: None,
                    fraction: Some(if length == 8 {
                        f64::from_bits(raw)
                    } else {
                        f32::from_bits(raw as u32) as f64
                    }),
                }
            }
            2 => {
                let length = varint(data, &mut offset)?;
                let length = usize::try_from(length)?;
                anyhow::ensure!(length <= data.len() - offset, "Truncated bytes");
                let slice = data[offset..offset + length].to_vec();
                offset += length;
                ProtoValue {
                    bytes: Some(slice),
                    integer: None,
                    fraction: None,
                }
            }
            _ => anyhow::bail!("Unsupported protobuf wire type"),
        };
        fields.entry(field).or_default().push(value);
    }
    Ok(fields)
}

// ---------------------------------------------------------------------------
// Windows-native probing
// ---------------------------------------------------------------------------

#[cfg(windows)]
mod win32 {
    use super::{EndpointScheme, LoopbackRequest, LoopbackResponse, ProcessEntry, MAX_BYTES};
    use std::path::PathBuf;
    use windows::core::PCWSTR;
    use windows::Win32::Foundation::{CloseHandle, FILETIME, HANDLE};
    use windows::Win32::NetworkManagement::IpHelper::{
        GetExtendedTcpTable, TCP_TABLE_OWNER_PID_LISTENER,
    };
    use windows::Win32::Networking::WinHttp::{
        WinHttpAddRequestHeaders, WinHttpCloseHandle, WinHttpConnect, WinHttpOpen,
        WinHttpOpenRequest, WinHttpQueryHeaders, WinHttpReadData, WinHttpReceiveResponse,
        WinHttpSendRequest, WinHttpSetOption, WinHttpSetTimeouts, WINHTTP_ACCESS_TYPE_NO_PROXY,
        WINHTTP_ADDREQ_FLAG_ADD, WINHTTP_ADDREQ_FLAG_REPLACE, WINHTTP_DISABLE_AUTHENTICATION,
        WINHTTP_DISABLE_COOKIES, WINHTTP_DISABLE_REDIRECTS, WINHTTP_FLAG_SECURE,
        WINHTTP_OPTION_DISABLE_FEATURE, WINHTTP_OPTION_SECURITY_FLAGS, WINHTTP_QUERY_FLAG_NUMBER,
        WINHTTP_QUERY_STATUS_CODE,
    };
    use windows::Win32::Networking::WinSock::AF_INET;
    use windows::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
        TH32CS_SNAPPROCESS,
    };
    use windows::Win32::System::LibraryLoader::{GetModuleHandleW, GetProcAddress};
    use windows::Win32::System::Threading::{
        GetProcessTimes, OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_FORMAT,
        PROCESS_QUERY_LIMITED_INFORMATION,
    };

    /// Row layout of `MIB_TCPROW_OWNER_PID`: state, local address, local port,
    /// remote address, remote port, owning PID.
    const ROW_SIZE: usize = 24;

    pub(super) fn native_process_list() -> anyhow::Result<Vec<ProcessEntry>> {
        unsafe {
            let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)?;
            let mut entries = Vec::new();
            let mut entry = PROCESSENTRY32W::default();
            entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
            let mut has_entry = Process32FirstW(snapshot, &mut entry).is_ok();
            while has_entry {
                let pid = entry.th32ProcessID;
                // OpenProcess fails for another user's process unless this one
                // holds debug privilege, so success already constrains ownership.
                if pid != 0 {
                    if let Ok(process) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
                    {
                        // Read the command line and start time only for the one
                        // executable family this adapter may talk to, instead of
                        // querying every process on the machine.
                        if let Some(executable) = image_name(process) {
                            if super::is_language_server(&executable) {
                                entries.push(ProcessEntry {
                                    pid,
                                    executable,
                                    command_line: command_line(process).unwrap_or_default(),
                                    birth_seconds: birth_seconds(process).unwrap_or(0),
                                });
                            }
                        }
                        let _ = CloseHandle(process);
                    }
                }
                entry = PROCESSENTRY32W::default();
                entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
                has_entry = Process32NextW(snapshot, &mut entry).is_ok();
            }
            let _ = CloseHandle(snapshot);
            Ok(entries)
        }
    }

    unsafe fn image_name(handle: HANDLE) -> Option<PathBuf> {
        let mut buffer = vec![0u16; 4096];
        let mut size = buffer.len() as u32;
        QueryFullProcessImageNameW(
            handle,
            PROCESS_NAME_FORMAT(0),
            windows::core::PWSTR(buffer.as_mut_ptr()),
            &mut size,
        )
        .ok()?;
        Some(PathBuf::from(String::from_utf16_lossy(
            &buffer[..size as usize],
        )))
    }

    unsafe fn birth_seconds(handle: HANDLE) -> Option<u64> {
        let mut creation = FILETIME::default();
        let mut exit = FILETIME::default();
        let mut kernel = FILETIME::default();
        let mut user = FILETIME::default();
        GetProcessTimes(handle, &mut creation, &mut exit, &mut kernel, &mut user).ok()?;
        let value = ((creation.dwHighDateTime as u64) << 32) | creation.dwLowDateTime as u64;
        Some(value / 10_000_000)
    }

    type NtQueryInformationProcess =
        unsafe extern "system" fn(HANDLE, i32, *mut core::ffi::c_void, u32, *mut u32) -> i32;

    #[repr(C)]
    struct UnicodeString {
        length: u16,
        maximum_length: u16,
        _reserved: u32,
        buffer: *mut u16,
    }

    unsafe fn command_line(handle: HANDLE) -> Option<String> {
        let module = GetModuleHandleW(PCWSTR(
            "ntdll.dll\0".encode_utf16().collect::<Vec<u16>>().as_ptr(),
        ))
        .ok()?;
        let address = GetProcAddress(
            module,
            windows::core::PCSTR(b"NtQueryInformationProcess\0".as_ptr()),
        )?;
        let function: NtQueryInformationProcess = std::mem::transmute(address);
        let mut buffer = vec![0u8; 32 * 1024];
        let mut length = 0u32;
        // 60 = ProcessCommandLineInformation.
        let status = function(
            handle,
            60,
            buffer.as_mut_ptr() as *mut core::ffi::c_void,
            buffer.len() as u32,
            &mut length,
        );
        if status != 0 || length == 0 || length as usize > buffer.len() {
            return None;
        }
        let raw = std::ptr::read_unaligned(buffer.as_ptr() as *const UnicodeString);
        if raw.buffer.is_null() || raw.length == 0 {
            return Some(String::new());
        }
        let count = (raw.length as usize) / 2;
        if count == 0 || count > 16 * 1024 {
            return None;
        }
        let slice = std::slice::from_raw_parts(raw.buffer, count);
        Some(String::from_utf16_lossy(slice))
    }

    pub(super) fn native_port_list(pid: u32) -> anyhow::Result<Vec<u16>> {
        unsafe {
            let mut size = 0u32;
            let status = GetExtendedTcpTable(
                None,
                &mut size,
                true,
                AF_INET.0 as u32,
                TCP_TABLE_OWNER_PID_LISTENER,
                0,
            );
            // 122 = ERROR_INSUFFICIENT_BUFFER, the expected measuring result.
            if status != 0 && status != 122 {
                anyhow::bail!("Could not size the TCP table: {}", status);
            }
            if size < 4 || size > 16 * 1024 * 1024 {
                anyhow::bail!("Unexpected TCP table size");
            }
            let mut buffer = vec![0u8; size as usize];
            let status = GetExtendedTcpTable(
                Some(buffer.as_mut_ptr() as *mut core::ffi::c_void),
                &mut size,
                true,
                AF_INET.0 as u32,
                TCP_TABLE_OWNER_PID_LISTENER,
                0,
            );
            if status != 0 {
                anyhow::bail!("Could not read the TCP table: {}", status);
            }
            let count = u32::from_le_bytes([buffer[0], buffer[1], buffer[2], buffer[3]]) as usize;
            if count
                .saturating_mul(ROW_SIZE)
                .saturating_add(std::mem::size_of::<u32>())
                > buffer.len()
            {
                anyhow::bail!("Truncated TCP table");
            }
            let mut ports = Vec::new();
            for index in 0..count {
                let start = std::mem::size_of::<u32>() + index * ROW_SIZE;
                let row = &buffer[start..start + ROW_SIZE];
                let local_address = u32::from_le_bytes([row[4], row[5], row[6], row[7]]);
                let local_port = u32::from_le_bytes([row[8], row[9], row[10], row[11]]);
                let owning_pid = u32::from_le_bytes([row[20], row[21], row[22], row[23]]);
                // Network byte order: the first address byte is 127 for loopback
                // and the port occupies the low 16 bits, byte-swapped.
                let is_loopback = local_address & 0xff == 0x7f;
                let port = u16::from_be((local_port & 0xffff) as u16);
                if owning_pid == pid && is_loopback && port != 0 {
                    ports.push(port);
                }
            }
            ports.sort_unstable();
            ports.dedup();
            Ok(ports)
        }
    }

    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(std::iter::once(0)).collect()
    }

    pub(super) fn native_transport_call(
        request: &LoopbackRequest,
    ) -> anyhow::Result<LoopbackResponse> {
        anyhow::ensure!(
            request
                .path
                .starts_with("/exa.language_server_pb.LanguageServerService/"),
            "Refusing a non-Antigravity path"
        );
        anyhow::ensure!(request.port != 0, "Refusing an unspecified port");
        let agent = wide("AiGoodBro/1.0");
        let host = wide("127.0.0.1");
        let method = wide("POST");
        let path = wide(&request.path);
        let content_type = wide("Content-Type: application/json");
        let protocol = wide("Connect-Protocol-Version: 1");
        let csrf = wide(&format!("X-Codeium-Csrf-Token: {}", request.csrf));
        unsafe {
            let session = WinHttpOpen(
                PCWSTR(agent.as_ptr()),
                WINHTTP_ACCESS_TYPE_NO_PROXY,
                PCWSTR(host.as_ptr()),
                PCWSTR::null(),
                0,
            );
            if session.is_null() {
                anyhow::bail!("WinHttpOpen failed");
            }
            let connect = WinHttpConnect(session, PCWSTR(host.as_ptr()), request.port, 0);
            if connect.is_null() {
                let _ = WinHttpCloseHandle(session);
                anyhow::bail!("WinHttpConnect failed");
            }
            let flags = if request.scheme == EndpointScheme::Https {
                WINHTTP_FLAG_SECURE
            } else {
                Default::default()
            };
            let handle = WinHttpOpenRequest(
                connect,
                PCWSTR(method.as_ptr()),
                PCWSTR(path.as_ptr()),
                PCWSTR::null(),
                PCWSTR::null(),
                std::ptr::null(),
                flags,
            );
            if handle.is_null() {
                let _ = WinHttpCloseHandle(connect);
                let _ = WinHttpCloseHandle(session);
                anyhow::bail!("WinHttpOpenRequest failed");
            }
            let outcome = (|| -> anyhow::Result<LoopbackResponse> {
                // Redirects, cookies and automatic authentication are never used.
                let disabled = WINHTTP_DISABLE_REDIRECTS
                    | WINHTTP_DISABLE_COOKIES
                    | WINHTTP_DISABLE_AUTHENTICATION;
                let _ = WinHttpSetOption(
                    Some(handle),
                    WINHTTP_OPTION_DISABLE_FEATURE,
                    Some(&disabled.to_le_bytes()),
                );
                let _ = WinHttpSetTimeouts(handle, 3000, 3000, 3000, 4000);
                if request.scheme == EndpointScheme::Https {
                    // Self-signed TLS is accepted only for the verified loopback
                    // endpoint whose owning official process was checked first.
                    let security = windows::Win32::Networking::WinHttp::SECURITY_FLAG_IGNORE_UNKNOWN_CA
                        | windows::Win32::Networking::WinHttp::SECURITY_FLAG_IGNORE_CERT_CN_INVALID
                        | windows::Win32::Networking::WinHttp::SECURITY_FLAG_IGNORE_CERT_DATE_INVALID
                        | windows::Win32::Networking::WinHttp::SECURITY_FLAG_IGNORE_CERT_WRONG_USAGE;
                    let _ = WinHttpSetOption(
                        Some(handle),
                        WINHTTP_OPTION_SECURITY_FLAGS,
                        Some(&security.to_le_bytes()),
                    );
                }
                // ADD|REPLACE is "set this header": REPLACE alone fails with
                // ERROR_WINHTTP_HEADER_NOT_FOUND when the header is not present.
                let set_header = WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE;
                WinHttpAddRequestHeaders(handle, &content_type, set_header)?;
                WinHttpAddRequestHeaders(handle, &protocol, set_header)?;
                WinHttpAddRequestHeaders(handle, &csrf, set_header)?;
                WinHttpSendRequest(
                    handle,
                    None,
                    Some(request.body.as_ptr() as *const core::ffi::c_void),
                    request.body.len() as u32,
                    request.body.len() as u32,
                    0,
                )?;
                WinHttpReceiveResponse(handle, std::ptr::null_mut())?;
                let mut status = 0u32;
                let mut status_length = std::mem::size_of::<u32>() as u32;
                WinHttpQueryHeaders(
                    handle,
                    WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                    PCWSTR::null(),
                    Some(&mut status as *mut u32 as *mut core::ffi::c_void),
                    &mut status_length,
                    std::ptr::null_mut(),
                )?;
                let mut body = Vec::new();
                let mut chunk = [0u8; 8192];
                loop {
                    let mut read = 0u32;
                    WinHttpReadData(
                        handle,
                        chunk.as_mut_ptr() as *mut core::ffi::c_void,
                        chunk.len() as u32,
                        &mut read,
                    )?;
                    if read == 0 {
                        break;
                    }
                    body.extend_from_slice(&chunk[..read as usize]);
                    if body.len() > MAX_BYTES {
                        break;
                    }
                }
                Ok(LoopbackResponse {
                    status: status as u16,
                    body,
                })
            })();
            let _ = WinHttpCloseHandle(handle);
            let _ = WinHttpCloseHandle(connect);
            let _ = WinHttpCloseHandle(session);
            outcome
        }
    }
}

#[cfg(windows)]
pub fn native_processes() -> anyhow::Result<Vec<ProcessEntry>> {
    win32::native_process_list()
}

#[cfg(windows)]
pub fn native_ports(pid: u32) -> anyhow::Result<Vec<u16>> {
    win32::native_port_list(pid)
}

#[cfg(windows)]
pub fn native_transport(request: &LoopbackRequest) -> anyhow::Result<LoopbackResponse> {
    win32::native_transport_call(request)
}

#[cfg(not(windows))]
pub fn native_processes() -> anyhow::Result<Vec<ProcessEntry>> {
    anyhow::bail!("Antigravity discovery requires Windows")
}

#[cfg(not(windows))]
pub fn native_ports(_pid: u32) -> anyhow::Result<Vec<u16>> {
    anyhow::bail!("Antigravity discovery requires Windows")
}

#[cfg(not(windows))]
pub fn native_transport(_request: &LoopbackRequest) -> anyhow::Result<LoopbackResponse> {
    anyhow::bail!("Antigravity transport requires Windows")
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// A path that really sits under this machine's user install root, so the
    /// install-root check behaves here exactly as it does in production.
    fn install_executable() -> PathBuf {
        let local = std::env::var("LOCALAPPDATA").unwrap_or_else(|_| {
            std::env::var("ProgramFiles").unwrap_or_else(|_| r"C:\Program Files".to_string())
        });
        PathBuf::from(local)
            .join("Programs")
            .join("Antigravity")
            .join("language_server.exe")
    }

    fn process(pid: u32, command: &str) -> ProcessEntry {
        ProcessEntry {
            pid,
            executable: install_executable(),
            command_line: command.to_string(),
            birth_seconds: 100,
        }
    }

    fn endpoint(port: u16, csrf: &str) -> AntigravityEndpoint {
        AntigravityEndpoint {
            pid: 4242,
            birth_seconds: 100,
            executable: install_executable(),
            port,
            csrf: csrf.to_string(),
            scheme: EndpointScheme::Https,
        }
    }

    fn cache_with(data: Vec<u8>, modified: DateTime<Utc>) -> AntigravityCache {
        AntigravityCache {
            data,
            modified_at: modified,
        }
    }

    fn synthetic_reader(
        responses: Vec<(String, Option<Vec<u8>>)>,
        processes: Vec<ProcessEntry>,
        ports: Vec<u16>,
        cache: Option<AntigravityCache>,
    ) -> AntigravityReader {
        let responses = Arc::new(responses);
        AntigravityReader::synthetic(
            Arc::new(move |request: &LoopbackRequest| {
                let method = request
                    .path
                    .rsplit('/')
                    .next()
                    .unwrap_or_default()
                    .to_string();
                let body = responses
                    .iter()
                    .find(|(name, _)| *name == method)
                    .and_then(|(_, body)| body.clone());
                match body {
                    Some(body) => Ok(LoopbackResponse { status: 200, body }),
                    None => anyhow::bail!("synthetic transport refused {}", method),
                }
            }),
            Arc::new(move || Ok(processes.clone())),
            Arc::new(move |_| Ok(ports.clone())),
            Arc::new(move |_| Ok(cache.clone())),
        )
    }

    fn status_json(email: &str, remaining: f64) -> Vec<u8> {
        serde_json::json!({
            "userStatus": {
                "email": email,
                "userTier": { "name": "Pro" },
                "cascadeModelConfigData": {
                    "clientModelConfigs": [
                        { "label": "Gemini", "quotaInfo": { "remainingFraction": remaining } }
                    ]
                }
            }
        })
        .to_string()
        .into_bytes()
    }

    #[test]
    fn live_read_returns_the_verified_account_windows() {
        let now = Utc::now();
        let reader = synthetic_reader(
            vec![(
                "GetUserStatus".to_string(),
                Some(status_json("user@example.com", 0.75)),
            )],
            vec![process(4242, "language_server.exe --csrf_token abc123")],
            vec![31337],
            None,
        );
        let result = reader.load(Path::new(r"C:\Antigravity"), true, now);
        assert_eq!(result.state, LocalCliQuotaState::Available);
        assert_eq!(result.masked_identity.as_deref(), Some("u***@example.com"));
        assert_eq!(result.plan_label.as_deref(), Some("Pro"));
        assert_eq!(result.windows.len(), 1);
        assert!((result.windows[0].used_percent - 25.0).abs() < 1e-9);
        assert_eq!(result.source_label, "Antigravity · official desktop quota");
        assert!(!serde_json::to_string(&result)
            .unwrap()
            .contains("user@example.com"));
    }

    #[test]
    fn an_account_switch_during_the_read_is_reported_not_merged() {
        let now = Utc::now();
        let calls = Arc::new(AtomicUsize::new(0));
        let inner = calls.clone();
        let reader = AntigravityReader::synthetic(
            Arc::new(move |_request: &LoopbackRequest| {
                let count = inner.fetch_add(1, Ordering::SeqCst);
                let email = if count == 0 {
                    "first@example.com"
                } else {
                    "second@example.com"
                };
                Ok(LoopbackResponse {
                    status: 200,
                    body: status_json(email, 0.5),
                })
            }),
            Arc::new(|| {
                Ok(vec![process(
                    4242,
                    "language_server.exe --csrf_token abc123",
                )])
            }),
            Arc::new(|_| Ok(vec![31337])),
            Arc::new(|_| Ok(None)),
        );
        let result = reader.load(Path::new(r"C:\Antigravity"), true, now);
        assert_eq!(result.state, LocalCliQuotaState::Unavailable);
        assert_eq!(
            result.message_code.as_deref(),
            Some("local_cli_antigravity_account_changed")
        );
        assert!(result.windows.is_empty());
    }

    #[test]
    fn a_failed_live_read_never_substitutes_another_accounts_cache() {
        let now = Utc::now();
        let reader = AntigravityReader::synthetic(
            Arc::new(|_| anyhow::bail!("synthetic failure")),
            Arc::new(|| {
                Ok(vec![process(
                    4242,
                    "language_server.exe --csrf_token abc123",
                )])
            }),
            Arc::new(|_| Ok(vec![31337])),
            Arc::new(move |_| {
                Ok(Some(cache_with(
                    br#"{"email":"cached@example.com"}"#.to_vec(),
                    now,
                )))
            }),
        );
        let result = reader.load(Path::new(r"C:\Antigravity"), true, now);
        assert_eq!(result.state, LocalCliQuotaState::Unavailable);
        assert_eq!(
            result.message_code.as_deref(),
            Some("local_cli_antigravity_live_unavailable")
        );
        assert_eq!(result.masked_identity, None);
    }

    #[test]
    fn cache_is_only_read_when_no_live_endpoint_exists() {
        let now = Utc::now();
        let reader = AntigravityReader::synthetic(
            Arc::new(|_| anyhow::bail!("unused")),
            Arc::new(|| Ok(Vec::new())),
            Arc::new(|_| Ok(Vec::new())),
            Arc::new(move |_| {
                Ok(Some(cache_with(
                    serde_json::json!({
                        "email": "cached@example.com",
                        "userStatusProtoBinaryBase64": base64_of(b"\n\x05proto")
                    })
                    .to_string()
                    .into_bytes(),
                    now,
                )))
            }),
        );
        let result = reader.load(Path::new(r"C:\Antigravity"), true, now);
        assert_eq!(result.state, LocalCliQuotaState::Unavailable);
        assert_eq!(
            result.message_code.as_deref(),
            Some("local_cli_antigravity_cached_quota")
        );
        assert_eq!(result.masked_identity.as_deref(), Some("c***@example.com"));
        assert_eq!(result.source_label, "Antigravity · cached IDE quota");
        // History is visible but is never a fresh success.
        assert_ne!(result.state, LocalCliQuotaState::Available);
    }

    #[test]
    fn a_linked_directory_without_live_or_cache_evidence_says_so() {
        let now = Utc::now();
        let reader = AntigravityReader::synthetic(
            Arc::new(|_| anyhow::bail!("unused")),
            Arc::new(|| Ok(Vec::new())),
            Arc::new(|_| Ok(Vec::new())),
            Arc::new(|_| Ok(None)),
        );
        let shared = reader.load(Path::new(r"C:\Antigravity"), true, now);
        assert_eq!(
            shared.message_code.as_deref(),
            Some("local_cli_antigravity_open_app")
        );
        let linked = reader.load(Path::new(r"C:\Antigravity"), false, now);
        assert_eq!(
            linked.message_code.as_deref(),
            Some("local_cli_antigravity_linked_cache_only")
        );
    }

    #[test]
    fn discovery_requires_language_server_path_owned_port_and_csrf() {
        let command = "language_server.exe --csrf_token abc123 --extension_server_port 9000";
        let endpoints = discover_with(&[process(4242, command)], |_| Ok(vec![31337, 9000]));
        assert!(endpoints
            .iter()
            .any(|endpoint| endpoint.port == 31337 && endpoint.scheme == EndpointScheme::Https));
        assert!(endpoints
            .iter()
            .any(|endpoint| endpoint.port == 9000 && endpoint.scheme == EndpointScheme::Http));

        // A port the process does not own is never used, even when advertised.
        let unowned = discover_with(&[process(4242, command)], |_| Ok(vec![31337]));
        assert!(!unowned.iter().any(|endpoint| endpoint.port == 9000));

        assert!(discover_with(
            &[process(
                4242,
                "language_server.exe --extension_server_port 9000"
            )],
            |_| Ok(vec![9000])
        )
        .is_empty());

        let mut other = process(4242, command);
        other.executable = PathBuf::from(r"C:\Tools\evil\language_server.exe");
        assert!(discover_with(&[other], |_| Ok(vec![9000])).is_empty());
    }

    #[test]
    fn verification_rejects_a_reused_pid_or_a_moved_port() {
        let endpoints = vec![process(4242, "language_server.exe --csrf_token abc123")];
        let endpoint = endpoint(31337, "abc123");
        assert!(verify_with(&endpoints, |_| Ok(vec![31337]), &endpoint));
        assert!(!verify_with(&endpoints, |_| Ok(vec![1]), &endpoint));
        let mut stale = process(4242, "language_server.exe --csrf_token abc123");
        stale.birth_seconds = 999;
        assert!(!verify_with(&[stale], |_| Ok(vec![31337]), &endpoint));
        assert!(!verify_with(&[], |_| Ok(vec![31337]), &endpoint));
    }

    #[test]
    fn flag_parsing_accepts_only_bounded_tokens() {
        assert_eq!(
            flag("--csrf_token", "app --csrf_token abc123 --x"),
            Some("abc123".to_string())
        );
        assert_eq!(
            flag("--csrf_token", "app --csrf_token=abc123"),
            Some("abc123".to_string())
        );
        assert_eq!(flag("--csrf_token", "app --csrf_token"), None);
        assert_eq!(flag("--csrf_token", "app --csrf_token -abc"), None);
        assert_eq!(flag("--csrf_token", "app"), None);
        assert_eq!(
            flag(
                "--csrf_token",
                &format!("app --csrf_token {}", "a".repeat(600))
            ),
            None
        );
    }

    #[test]
    fn status_parsing_rejects_malformed_and_expired_windows() {
        let now = Utc::now();
        let parsed = parse_status(&status_json("user@example.com", 0.25), now).unwrap();
        assert_eq!(parsed.windows.len(), 1);
        assert!((parsed.windows[0].used_percent - 75.0).abs() < 1e-9);

        let expired = serde_json::json!({
            "userStatus": {
                "email": "user@example.com",
                "cascadeModelConfigData": { "clientModelConfigs": [
                    { "label": "Gemini", "quotaInfo": {
                        "remainingFraction": 0.5,
                        "resetTime": (now - Duration::hours(1)).to_rfc3339()
                    } }
                ] }
            }
        })
        .to_string()
        .into_bytes();
        assert!(parse_status(&expired, now).unwrap().windows.is_empty());

        let out_of_range = serde_json::json!({
            "userStatus": { "email": "u@e.com", "cascadeModelConfigData": { "clientModelConfigs": [
                { "label": "Gemini", "quotaInfo": { "remainingFraction": 5.0 } }
            ] } }
        })
        .to_string()
        .into_bytes();
        assert!(parse_status(&out_of_range, now).unwrap().windows.is_empty());

        assert!(parse_status(b"{}", now).is_err());
        assert!(parse_status(
            &serde_json::json!({"code":"permission_denied"})
                .to_string()
                .into_bytes(),
            now
        )
        .is_err());
    }

    #[test]
    fn summary_parsing_merges_group_and_bucket_labels() {
        let now = Utc::now();
        let summary = serde_json::json!({
            "response": { "groups": [
                { "displayName": "Gemini", "buckets": [
                    { "displayName": "Flash", "remainingFraction": 0.4 },
                    { "displayName": "Disabled", "remainingFraction": 0.4, "disabled": true }
                ] }
            ] }
        })
        .to_string()
        .into_bytes();
        let windows = parse_summary(&summary, now).unwrap();
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].label, "Gemini · Flash");
        assert!((windows[0].used_percent - 60.0).abs() < 1e-9);
        assert!(parse_summary(b"{}", now).is_err());
    }

    #[test]
    fn base64_and_protobuf_helpers_stay_bounded() {
        assert_eq!(decode_base64("Cgdwcm90bw==").unwrap(), b"\n\x07proto");
        assert!(decode_base64("not-base64!!").is_none());
        assert!(decode_base64("abc").is_none());
        let mut payload = Vec::new();
        payload.push(0x0a);
        payload.push(5);
        payload.extend_from_slice(b"proto");
        let fields = protobuf(&payload).unwrap();
        assert_eq!(fields[&1][0].bytes.as_deref(), Some(b"proto".as_slice()));
        assert!(protobuf(&[0x0a]).is_err());
    }

    #[test]
    fn cache_parsing_requires_matching_identity_and_never_reports_fresh() {
        let now = Utc::now();
        let mut payload = Vec::new();
        payload.push((7 << 3) | 2);
        payload.push(11);
        payload.extend_from_slice(b"user@ex.com");
        let cache = cache_with(
            serde_json::json!({
                "email": "user@ex.com",
                "userStatusProtoBinaryBase64": base64_of(&payload)
            })
            .to_string()
            .into_bytes(),
            now - Duration::hours(2),
        );
        let parsed = parse_cache(&cache, now).unwrap();
        assert_eq!(parsed.state, LocalCliQuotaState::Unavailable);
        assert_eq!(
            parsed.message_code.as_deref(),
            Some("local_cli_antigravity_cached_quota")
        );
        assert_eq!(parsed.masked_identity.as_deref(), Some("u***@ex.com"));

        let mismatched = cache_with(
            serde_json::json!({
                "email": "other@ex.com",
                "userStatusProtoBinaryBase64": base64_of(&payload)
            })
            .to_string()
            .into_bytes(),
            now,
        );
        assert!(parse_cache(&mismatched, now).is_err());
        assert!(parse_cache(&cache_with(b"{}".to_vec(), now), now).is_err());
    }

    #[test]
    fn cache_file_lookup_stays_inside_the_selected_directory() {
        let temp = tempfile::tempdir().unwrap();
        assert_eq!(cache_file(temp.path()), None);
        let storage = temp.path().join("User").join("globalStorage");
        std::fs::create_dir_all(&storage).unwrap();
        std::fs::write(storage.join("state.vscdb"), b"sqlite").unwrap();
        assert_eq!(cache_file(temp.path()), Some(storage.join("state.vscdb")));
        assert_eq!(cache_file(Path::new("relative")), None);
    }

    /// Real Win32 smoke tests. They never touch Antigravity itself: they exercise
    /// the native process snapshot, the TCP owner-PID table and the WinHTTP
    /// loopback transport against a listener this test owns.
    #[cfg(windows)]
    #[test]
    fn native_process_snapshot_only_returns_language_server_candidates() {
        let entries = native_processes().expect("the process snapshot must be readable");
        for entry in &entries {
            assert!(
                is_language_server(&entry.executable),
                "unexpected process family reached the Antigravity adapter"
            );
        }
    }

    #[cfg(windows)]
    #[test]
    fn native_port_lookup_finds_a_listener_owned_by_this_process() {
        use std::net::TcpListener;
        let listener = TcpListener::bind("127.0.0.1:0").expect("loopback listener");
        let port = listener.local_addr().unwrap().port();
        let ports = native_ports(std::process::id()).expect("the TCP table must be readable");
        assert!(
            ports.contains(&port),
            "the owner-PID table did not report this process's own listening port"
        );
    }

    #[cfg(windows)]
    #[test]
    fn native_transport_speaks_http_to_a_verified_loopback_endpoint() {
        use std::io::{Read, Write};
        use std::net::TcpListener;
        let listener = TcpListener::bind("127.0.0.1:0").expect("loopback listener");
        let port = listener.local_addr().unwrap().port();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let mut buffer = [0u8; 8192];
            let _ = stream.read(&mut buffer);
            let body = br#"{"userStatus":{"email":"synthetic@example.invalid"}}"#;
            let head = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            let _ = stream.write_all(head.as_bytes());
            let _ = stream.write_all(body);
            let _ = stream.flush();
        });
        let response = native_transport(&LoopbackRequest {
            scheme: EndpointScheme::Http,
            port,
            path: format!("{}GetUserStatus", SERVICE_PATH),
            csrf: "synthetic-token".to_string(),
            body: br#"{"metadata":{}}"#.to_vec(),
        })
        .expect("the loopback transport must complete");
        server.join().unwrap();
        assert_eq!(response.status, 200);
        let parsed = parse_status(&response.body, Utc::now()).unwrap();
        assert_eq!(
            parsed.identity.as_deref(),
            Some("synthetic@example.invalid")
        );
    }

    #[cfg(windows)]
    #[test]
    fn native_transport_refuses_paths_outside_the_antigravity_service() {
        let error = native_transport(&LoopbackRequest {
            scheme: EndpointScheme::Http,
            port: 1,
            path: "/etc/passwd".to_string(),
            csrf: "synthetic-token".to_string(),
            body: Vec::new(),
        })
        .unwrap_err();
        assert!(error.to_string().contains("non-Antigravity path"));
    }

    #[test]
    fn install_root_check_rejects_paths_outside_supported_roots() {
        let local = std::env::var("LOCALAPPDATA").unwrap_or_default();
        if !local.is_empty() {
            assert!(is_language_server(&PathBuf::from(format!(
                r"{}\Programs\Antigravity\language_server.exe",
                local
            ))));
        }
        assert!(!is_language_server(&PathBuf::from(
            r"C:\Users\example\Downloads\Antigravity\language_server.exe"
        )));
        assert!(!is_language_server(&PathBuf::from(
            r"C:\Users\example\AppData\Local\Programs\Antigravity\other.exe"
        )));
    }

    fn base64_of(bytes: &[u8]) -> String {
        const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut text = String::new();
        for chunk in bytes.chunks(3) {
            let mut value: u32 = 0;
            for (index, byte) in chunk.iter().enumerate() {
                value |= (*byte as u32) << (16 - index * 8);
            }
            let length = chunk.len();
            for index in 0..4 {
                if index <= length {
                    let shift = 18 - index * 6;
                    text.push(TABLE[((value >> shift) & 0x3f) as usize] as char);
                } else {
                    text.push('=');
                }
            }
        }
        text
    }
}
