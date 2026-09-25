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
                // `request` re-checks the endpoint against the live process and
                // TCP tables on both sides of every exchange, so no stale
                // discovery snapshot is trusted here.
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
        // The identity is re-checked on both sides of the exchange, so a reused
        // PID, a moved port or a replaced image cannot receive the CSRF token and
        // a result cannot be attributed to an endpoint that has since changed.
        anyhow::ensure!(
            self.verify(endpoint),
            "Endpoint is no longer the verified process"
        );
        let response = (self.transport)(&LoopbackRequest {
            scheme: endpoint.scheme,
            port: endpoint.port,
            path: format!("{}{}", SERVICE_PATH, method),
            csrf: endpoint.csrf.clone(),
            body: serde_json::to_vec(&body)?,
        })?;
        anyhow::ensure!(
            self.verify(endpoint),
            "Endpoint changed while the request was in flight"
        );
        if response.status != 200 || response.body.len() > MAX_BYTES {
            anyhow::bail!("Antigravity endpoint returned an unusable response");
        }
        Ok(response.body)
    }

    /// Re-check an endpoint against the *current* process and TCP tables.
    ///
    /// The discovery snapshot is deliberately not reused: it ages while the read
    /// runs, and a process that exited and had its PID reassigned must not be
    /// treated as the one that was verified.
    pub fn verify(&self, endpoint: &AntigravityEndpoint) -> bool {
        let Ok(processes) = (self.processes)() else {
            return false;
        };
        let Ok(listening) = (self.ports)(endpoint.pid) else {
            return false;
        };
        verify_lists(&processes, &listening, endpoint)
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
/// Re-check an endpoint against a process and port snapshot.
///
/// The macOS transport compares the image path, the process start time and port
/// ownership, and deliberately does not repeat the code-signature check there.
/// This one repeats everything, signature included, because the install roots are
/// broader than macOS': the other side accepts only `/Applications` and
/// `~/Applications`, while here the image may sit anywhere under `%LOCALAPPDATA%`
/// or either `Program Files` tree. The signature is what keeps that breadth from
/// being a weakness, so it is not dropped on the second look.
pub fn verify_lists(
    processes: &[ProcessEntry],
    listening: &[u16],
    endpoint: &AntigravityEndpoint,
) -> bool {
    let Some(entry) = processes.iter().find(|entry| entry.pid == endpoint.pid) else {
        return false;
    };
    if entry.executable != endpoint.executable || entry.birth_seconds != endpoint.birth_seconds {
        return false;
    }
    if !is_language_server(&entry.executable) {
        return false;
    }
    listening.contains(&endpoint.port)
}

pub fn verify_with<F>(processes: &[ProcessEntry], ports: F, endpoint: &AntigravityEndpoint) -> bool
where
    F: Fn(u32) -> anyhow::Result<Vec<u16>>,
{
    match ports(endpoint.pid) {
        Ok(listening) => verify_lists(processes, &listening, endpoint),
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

/// Publishers whose signature makes an Antigravity language server official.
///
/// The macOS reader pins Google's designated requirement for the application
/// bundle; the Windows analogue is the Authenticode signer. A binary that is
/// merely placed under an install root is not accepted.
const OFFICIAL_PUBLISHERS: [&str; 1] = ["google"];

/// True when the image carries a valid, trusted signature from an official publisher.
pub fn is_officially_signed(executable: &Path) -> bool {
    publisher_of(executable)
        .map(|publisher| {
            let publisher = publisher.to_lowercase();
            OFFICIAL_PUBLISHERS
                .iter()
                .any(|official| publisher.contains(official))
        })
        .unwrap_or(false)
}

/// Authenticode signer of an image, or `None` when it is unsigned or the
/// signature does not verify.
#[cfg(windows)]
pub fn publisher_of(executable: &Path) -> Option<String> {
    win32::signature_publisher(executable)
}

#[cfg(not(windows))]
pub fn publisher_of(_executable: &Path) -> Option<String> {
    None
}

/// Install roots this adapter accepts.
///
/// The environment variables are the fast path; a curated shell can define none
/// of them, so the documented per-user and system-drive layouts are used as
/// fallbacks. Nothing here trusts a caller-supplied string.
pub fn install_roots() -> Vec<PathBuf> {
    let mut roots: Vec<PathBuf> = Vec::new();
    let mut add = |candidate: PathBuf| {
        if candidate.is_absolute() && !roots.iter().any(|existing| same_path(existing, &candidate))
        {
            roots.push(candidate);
        }
    };
    let profile = std::env::var("USERPROFILE").ok();
    let system_drive = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".to_string());
    let local_app_data_fallback = profile
        .as_deref()
        .map(|value| Path::new(value).join("AppData").join("Local"));
    for (key, fallback) in [
        ("LOCALAPPDATA", local_app_data_fallback),
        (
            "ProgramFiles",
            Some(Path::new(&system_drive).join("Program Files")),
        ),
        (
            "ProgramFiles(x86)",
            Some(Path::new(&system_drive).join("Program Files (x86)")),
        ),
    ] {
        match std::env::var(key) {
            Ok(value) => add(PathBuf::from(value)),
            Err(_) => {
                if let Some(value) = fallback {
                    add(value);
                }
            }
        }
    }
    roots
}

fn same_path(left: &Path, right: &Path) -> bool {
    left.as_os_str()
        .to_string_lossy()
        .eq_ignore_ascii_case(&right.as_os_str().to_string_lossy())
}

/// Compare by whole path components, case-insensitively.
///
/// A string prefix test accepts `C:\Program Files Elsewhere` for the root
/// `C:\Program Files`, so any directory whose name merely starts like an install
/// root would pass. Components also fold `\` and `/` correctly.
fn path_starts_with(path: &Path, root: &Path) -> bool {
    let mut path_components = path.components();
    for root_component in root.components() {
        match path_components.next() {
            Some(component)
                if component
                    .as_os_str()
                    .to_string_lossy()
                    .eq_ignore_ascii_case(
                        root_component.as_os_str().to_string_lossy().as_ref(),
                    ) => {}
            _ => return false,
        }
    }
    true
}

fn is_under_install_root(executable: &Path) -> bool {
    install_roots()
        .iter()
        .any(|root| path_starts_with(executable, root))
}

/// Whether a listener bound to `local_address` can be reached at 127.0.0.1.
///
/// The value arrives in network byte order, so 127.0.0.1 reads back as
/// `0x0100_007F`. Only that exact address and the IPv4 wildcard qualify: accepting
/// the whole 127/8 range would yield endpoints that cannot be reached at
/// 127.0.0.1 at all, and the wildcard mirrors the macOS reader, which accepts a
/// `*:` listener. Requests are still only ever sent to 127.0.0.1.
pub fn reachable_at_loopback(local_address: u32) -> bool {
    const LOOPBACK: u32 = 0x0100_007f;
    const WILDCARD: u32 = 0;
    local_address == LOOPBACK || local_address == WILDCARD
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
            // Bounded by characters, not bytes: `String::truncate` panics when the
            // offset lands inside a multi-byte character, and these labels come
            // from the provider.
            let label = truncate_chars(&format!("{} · {}", group_name, name), 100);
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

/// Keep at most `maximum` characters. Slicing a `str` by byte offset panics when
/// the offset is not a character boundary, which provider-supplied labels can hit.
pub fn truncate_chars(value: &str, maximum: usize) -> String {
    value.chars().take(maximum).collect()
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

/// The legacy IDE cache inside an explicitly selected directory.
///
/// The file must stay inside that directory. `User` or `globalStorage` can be a
/// junction or symlink pointing anywhere, and following one would read a cache
/// belonging to a different installation than the one the user selected, so every
/// link in the chain is rejected and the resolved path must still be under the
/// resolved root.
pub fn cache_file(root: &Path) -> Option<PathBuf> {
    if !root.is_absolute() {
        return None;
    }
    let canonical_root = root.canonicalize().ok()?;
    let user = canonical_root.join("User");
    let storage = user.join("globalStorage");
    if is_linked(&user) || is_linked(&storage) {
        return None;
    }
    let resolved = storage.join("state.vscdb").canonicalize().ok()?;
    // Containment is decided on the fully resolved form, the only one a link
    // anywhere in the chain cannot fool.
    if !resolved.starts_with(&canonical_root) {
        return None;
    }
    let metadata = std::fs::metadata(&resolved).ok()?;
    if !metadata.is_file() || metadata.len() > 512 * 1024 * 1024 {
        return None;
    }
    // Callers get the user-facing spelling, without the `\\?\` prefix that
    // `canonicalize` adds on Windows.
    Some(without_verbatim_prefix(resolved))
}

/// Drops the verbatim (`\\?\`) prefix `canonicalize` adds on Windows.
///
/// The prefix is required by the Win32 APIs but is an implementation detail for
/// a caller that only compares or displays the path. A verbatim volume path
/// (`\\?\Volume{...}`) has no plain spelling and is left untouched, as is any
/// path that is not valid UTF-8.
fn without_verbatim_prefix(path: PathBuf) -> PathBuf {
    #[cfg(windows)]
    {
        if let Some(text) = path.to_str() {
            if let Some(rest) = text.strip_prefix(r"\\?\UNC\") {
                return PathBuf::from(format!(r"\\{rest}"));
            }
            if let Some(rest) = text.strip_prefix(r"\\?\") {
                if !rest.starts_with("Volume{") {
                    return PathBuf::from(rest);
                }
            }
        }
    }
    path
}

/// True when the entry is a symlink or a Windows reparse point (junction).
fn is_linked(path: &Path) -> bool {
    let Ok(metadata) = std::fs::symlink_metadata(path) else {
        // A missing entry is not a link; the caller treats it as "no cache".
        return false;
    };
    if metadata.file_type().is_symlink() {
        return true;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        // FILE_ATTRIBUTE_REPARSE_POINT, which also covers junctions that
        // `is_symlink` does not report.
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
        metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
    }
    #[cfg(not(windows))]
    {
        false
    }
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
    use super::{
        reachable_at_loopback, EndpointScheme, LoopbackRequest, LoopbackResponse, ProcessEntry,
        ALLOWED_METHODS, MAX_BYTES, SERVICE_PATH,
    };
    use std::path::{Path, PathBuf};
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
                if pid != 0 {
                    if let Ok(process) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
                    {
                        // Cheapest checks first: the image path is read for every
                        // process, while the token comparison and the Authenticode
                        // probe only run for the one executable family this adapter
                        // may talk to.
                        if let Some(executable) = image_name(process) {
                            if super::is_language_server(&executable)
                                // Ownership is compared through the process token,
                                // the Windows equivalent of the macOS
                                // `pbi_uid == geteuid()` test: an elevated caller can
                                // open another user's process, so a successful
                                // OpenProcess is not evidence of ownership.
                                && same_user(process)
                                && super::is_officially_signed(&executable)
                            {
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

    /// True when the process runs under the same user as this process.
    unsafe fn same_user(handle: HANDLE) -> bool {
        use windows::Win32::Security::{EqualSid, PSID};

        let current = token_user_sid(windows::Win32::System::Threading::GetCurrentProcess());
        let target = token_user_sid(handle);
        let (Some((current_buffer, current_sid)), Some((target_buffer, target_sid))) =
            (current, target)
        else {
            return false;
        };
        // Both buffers stay alive for the comparison, which is what the raw
        // SID pointers inside them refer to.
        let _keep_alive = (&current_buffer, &target_buffer);
        // `EqualSid` reports a mismatch as an error, not as `FALSE`.
        EqualSid(
            PSID(current_sid as *mut core::ffi::c_void),
            PSID(target_sid as *mut core::ffi::c_void),
        )
        .is_ok()
    }

    /// Buffer plus the address of the SID inside it.
    unsafe fn token_user_sid(handle: HANDLE) -> Option<(Vec<u8>, usize)> {
        use windows::Win32::Security::{GetTokenInformation, TokenUser, TOKEN_QUERY, TOKEN_USER};
        use windows::Win32::System::Threading::OpenProcessToken;

        let mut token = HANDLE::default();
        OpenProcessToken(handle, TOKEN_QUERY, &mut token).ok()?;
        let mut length = 0u32;
        // The first call only measures the buffer it needs.
        let _ = GetTokenInformation(token, TokenUser, None, 0, &mut length);
        if length == 0 || length > 64 * 1024 {
            let _ = CloseHandle(token);
            return None;
        }
        let mut buffer = vec![0u8; length as usize];
        let measured = GetTokenInformation(
            token,
            TokenUser,
            Some(buffer.as_mut_ptr() as *mut core::ffi::c_void),
            length,
            &mut length,
        )
        .is_ok();
        let _ = CloseHandle(token);
        if !measured {
            return None;
        }
        let sid = (*(buffer.as_ptr() as *const TOKEN_USER)).User.Sid;
        if sid.0.is_null() {
            return None;
        }
        Some((buffer, sid.0 as usize))
    }

    /// Releases a catalog admin context on every path, including an early return.
    struct CatalogAdmin(isize);

    impl Drop for CatalogAdmin {
        fn drop(&mut self) {
            if self.0 != 0 {
                unsafe {
                    let _ = windows::Win32::Security::Cryptography::Catalog::
                        CryptCATAdminReleaseContext(self.0, 0);
                }
            }
        }
    }

    /// Releases a catalog enumeration context; the admin context outlives it.
    struct CatalogContext {
        admin: isize,
        context: isize,
    }

    impl Drop for CatalogContext {
        fn drop(&mut self) {
            if self.context != 0 {
                unsafe {
                    let _ = windows::Win32::Security::Cryptography::Catalog::
                        CryptCATAdminReleaseCatalogContext(self.admin, self.context, 0);
                }
            }
        }
    }

    /// Publisher named by a verification state, or `None` when it cannot be read.
    unsafe fn state_publisher(state: HANDLE) -> Option<String> {
        use windows::Win32::Security::Cryptography::{
            CertGetNameStringW, CERT_NAME_SIMPLE_DISPLAY_TYPE,
        };
        use windows::Win32::Security::WinTrust::{
            WTHelperGetProvCertFromChain, WTHelperGetProvSignerFromChain,
            WTHelperProvDataFromStateData,
        };

        let provider = WTHelperProvDataFromStateData(state);
        if provider.is_null() {
            return None;
        }
        let signer = WTHelperGetProvSignerFromChain(provider, 0, false, 0);
        if signer.is_null() {
            return None;
        }
        let certificate = WTHelperGetProvCertFromChain(signer, 0);
        if certificate.is_null() || (*certificate).pCert.is_null() {
            return None;
        }
        let mut buffer = [0u16; 256];
        let written = CertGetNameStringW(
            (*certificate).pCert,
            CERT_NAME_SIMPLE_DISPLAY_TYPE,
            0,
            None,
            Some(&mut buffer),
        );
        if written <= 1 {
            return None;
        }
        let text = String::from_utf16_lossy(&buffer[..(written as usize - 1).min(buffer.len())]);
        let text = text.trim().to_string();
        (!text.is_empty()).then_some(text)
    }

    /// Signer of an image, whether the signature is embedded in it or lives in a
    /// system catalog.
    ///
    /// Windows has two Authenticode forms and both are in use. An *embedded*
    /// signature travels inside the image. A *catalog* signature lives in a
    /// catalog file and references the image by hash; `WinVerifyTrust` answers
    /// `TRUST_E_NOSIGNATURE` for it when asked with `WTD_CHOICE_FILE`. That was
    /// measured on this machine, where every `System32` image is catalog-signed,
    /// so checking only the embedded form would reject a genuine Google-signed
    /// install. The embedded form is tried first because it needs no lookup.
    ///
    /// Revocation checking and URL retrieval are switched off, so a probe never
    /// reaches the network.
    pub(super) fn signature_publisher(path: &Path) -> Option<String> {
        embedded_publisher(path).or_else(|| catalog_publisher(path))
    }

    /// Signer of the signature embedded in the image, if there is one.
    pub(super) fn embedded_publisher(path: &Path) -> Option<String> {
        use windows::Win32::Foundation::HWND;
        use windows::Win32::Security::WinTrust::{
            WinVerifyTrust, WINTRUST_ACTION_GENERIC_VERIFY_V2, WINTRUST_DATA, WINTRUST_DATA_0,
            WINTRUST_FILE_INFO, WTD_CACHE_ONLY_URL_RETRIEVAL, WTD_CHOICE_FILE, WTD_DISABLE_MD2_MD4,
            WTD_REVOKE_NONE, WTD_STATEACTION_CLOSE, WTD_STATEACTION_VERIFY, WTD_UI_NONE,
        };

        let wide: Vec<u16> = path
            .as_os_str()
            .to_string_lossy()
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        let mut file_info = WINTRUST_FILE_INFO {
            cbStruct: std::mem::size_of::<WINTRUST_FILE_INFO>() as u32,
            pcwszFilePath: PCWSTR(wide.as_ptr()),
            hFile: HANDLE::default(),
            pgKnownSubject: std::ptr::null_mut(),
        };
        let mut data = WINTRUST_DATA {
            cbStruct: std::mem::size_of::<WINTRUST_DATA>() as u32,
            dwUIChoice: WTD_UI_NONE,
            fdwRevocationChecks: WTD_REVOKE_NONE,
            dwUnionChoice: WTD_CHOICE_FILE,
            Anonymous: WINTRUST_DATA_0 {
                pFile: &mut file_info,
            },
            dwStateAction: WTD_STATEACTION_VERIFY,
            dwProvFlags: WTD_CACHE_ONLY_URL_RETRIEVAL | WTD_DISABLE_MD2_MD4,
            ..Default::default()
        };

        let mut action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
        let status = unsafe {
            WinVerifyTrust(
                HWND::default(),
                &mut action,
                &mut data as *mut WINTRUST_DATA as *mut core::ffi::c_void,
            )
        };
        let publisher = if status == 0 {
            unsafe { state_publisher(data.hWVTStateData) }
        } else {
            None
        };

        // The state data is allocated even for a failed verification.
        data.dwStateAction = WTD_STATEACTION_CLOSE;
        let mut action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
        unsafe {
            let _ = WinVerifyTrust(
                HWND::default(),
                &mut action,
                &mut data as *mut WINTRUST_DATA as *mut core::ffi::c_void,
            );
        }
        publisher
    }

    /// Signer named by a catalog that covers the image.
    ///
    /// The catalog is located by the file's own hash, and the same hash is used as
    /// the member tag, so the signature that is verified is the one the catalog
    /// holds for exactly this image.
    pub(super) fn catalog_publisher(path: &Path) -> Option<String> {
        use std::os::windows::io::AsRawHandle;
        use windows::Win32::Foundation::HWND;
        use windows::Win32::Security::Cryptography::Catalog::{
            CryptCATAdminAcquireContext2, CryptCATAdminCalcHashFromFileHandle2,
            CryptCATAdminEnumCatalogFromHash, CryptCATCatalogInfoFromContext, CATALOG_INFO,
        };
        use windows::Win32::Security::WinTrust::{
            WinVerifyTrust, WINTRUST_ACTION_GENERIC_VERIFY_V2, WINTRUST_CATALOG_INFO,
            WINTRUST_DATA, WINTRUST_DATA_0, WTD_CACHE_ONLY_URL_RETRIEVAL, WTD_CHOICE_CATALOG,
            WTD_DISABLE_MD2_MD4, WTD_REVOKE_NONE, WTD_STATEACTION_CLOSE, WTD_STATEACTION_VERIFY,
            WTD_UI_NONE,
        };

        let file = std::fs::File::open(path).ok()?;
        let handle = HANDLE(file.as_raw_handle());

        let mut raw_admin: isize = 0;
        // A null hash algorithm selects the default, and the subsystem and
        // strong-signature policy are left to theirs.
        unsafe {
            CryptCATAdminAcquireContext2(&mut raw_admin, None, PCWSTR::null(), None, None).ok()?;
        }
        let admin = CatalogAdmin(raw_admin);

        // The first call only measures the hash the catalog indexes the file by.
        let mut hash_length = 0u32;
        unsafe {
            let _ =
                CryptCATAdminCalcHashFromFileHandle2(admin.0, handle, &mut hash_length, None, None);
        }
        if hash_length == 0 || hash_length > 128 {
            return None;
        }
        let mut hash = vec![0u8; hash_length as usize];
        unsafe {
            CryptCATAdminCalcHashFromFileHandle2(
                admin.0,
                handle,
                &mut hash_length,
                Some(hash.as_mut_ptr()),
                None,
            )
            .ok()?;
        }
        hash.truncate(hash_length as usize);

        let context = unsafe { CryptCATAdminEnumCatalogFromHash(admin.0, &hash, None, None) };
        if context == 0 {
            return None;
        }
        let _context = CatalogContext {
            admin: admin.0,
            context,
        };

        let mut info = CATALOG_INFO {
            cbStruct: std::mem::size_of::<CATALOG_INFO>() as u32,
            ..Default::default()
        };
        unsafe { CryptCATCatalogInfoFromContext(context, &mut info, 0).ok()? };
        let catalog_length = info.wszCatalogFile.iter().position(|unit| *unit == 0)?;
        let catalog_path: Vec<u16> = info.wszCatalogFile[..=catalog_length].to_vec();

        // The member tag is the uppercase hexadecimal spelling of the hash the
        // catalog was located by.
        let tag: Vec<u16> = hash
            .iter()
            .map(|byte| format!("{byte:02X}"))
            .collect::<String>()
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        let file_path: Vec<u16> = path
            .as_os_str()
            .to_string_lossy()
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();

        let mut catalog_info = WINTRUST_CATALOG_INFO {
            cbStruct: std::mem::size_of::<WINTRUST_CATALOG_INFO>() as u32,
            dwCatalogVersion: 0,
            pcwszCatalogFilePath: PCWSTR(catalog_path.as_ptr()),
            pcwszMemberTag: PCWSTR(tag.as_ptr()),
            pcwszMemberFilePath: PCWSTR(file_path.as_ptr()),
            hMemberFile: handle,
            pbCalculatedFileHash: hash.as_mut_ptr(),
            cbCalculatedFileHash: hash.len() as u32,
            pcCatalogContext: std::ptr::null_mut(),
            hCatAdmin: admin.0,
        };
        let mut data = WINTRUST_DATA {
            cbStruct: std::mem::size_of::<WINTRUST_DATA>() as u32,
            dwUIChoice: WTD_UI_NONE,
            fdwRevocationChecks: WTD_REVOKE_NONE,
            dwUnionChoice: WTD_CHOICE_CATALOG,
            Anonymous: WINTRUST_DATA_0 {
                pCatalog: &mut catalog_info,
            },
            dwStateAction: WTD_STATEACTION_VERIFY,
            dwProvFlags: WTD_CACHE_ONLY_URL_RETRIEVAL | WTD_DISABLE_MD2_MD4,
            ..Default::default()
        };

        let mut action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
        let status = unsafe {
            WinVerifyTrust(
                HWND::default(),
                &mut action,
                &mut data as *mut WINTRUST_DATA as *mut core::ffi::c_void,
            )
        };
        let publisher = if status == 0 {
            unsafe { state_publisher(data.hWVTStateData) }
        } else {
            None
        };

        data.dwStateAction = WTD_STATEACTION_CLOSE;
        let mut action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
        unsafe {
            let _ = WinVerifyTrust(
                HWND::default(),
                &mut action,
                &mut data as *mut WINTRUST_DATA as *mut core::ffi::c_void,
            );
        }
        publisher
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
                // The address and port are stored in network byte order: for
                // 127.0.0.1 the first address byte is 0x7F and the port occupies
                // the low 16 bits, byte-swapped.
                let port = u16::from_be((local_port & 0xffff) as u16);
                if owning_pid == pid && reachable_at_loopback(local_address) && port != 0 {
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

    /// A WinHTTP call failure that keeps the stage and the HRESULT, so a caller
    /// can tell a retryable resend signal from a real failure.
    #[derive(Debug)]
    pub(super) struct WinHttpFailure {
        pub(super) stage: &'static str,
        pub(super) code: u32,
    }

    /// The documented WinHTTP failures this adapter distinguishes.
    ///
    /// WinHTTP reports `ERROR_WINHTTP_*` (12000..12200); the HRESULT form is
    /// `0x8007_0000 | code`, so the numeric value alone says nothing.
    ///
    /// `CONNECTION_ERROR` (12030) and `RESEND_REQUEST` (12032) are adjacent and
    /// easy to swap. They are not interchangeable: 12030 is a connection that
    /// failed, while 12032 is the server retiring a connection *after* the request
    /// went out, which is the only one worth sending again.
    const ERROR_WINHTTP_TIMEOUT: u32 = 0x8007_2EE2; // 12002
    const ERROR_WINHTTP_NAME_NOT_RESOLVED: u32 = 0x8007_2EE7; // 12007
    const ERROR_WINHTTP_CANNOT_CONNECT: u32 = 0x8007_2EFD; // 12029
    const ERROR_WINHTTP_CONNECTION_ERROR: u32 = 0x8007_2EFE; // 12030
    const ERROR_WINHTTP_RESEND_REQUEST: u32 = 0x8007_2F00; // 12032
    const ERROR_WINHTTP_SECURE_FAILURE: u32 = 0x8007_2F8F; // 12175

    impl WinHttpFailure {
        /// The server retired the connection before the response completed, so the
        /// request may be sent again unchanged.
        ///
        /// Only `RESEND_REQUEST` qualifies. `CONNECTION_ERROR` looks similar and is
        /// a different thing: the connection never carried the request, so
        /// resending it is not the documented remedy and is not attempted here.
        pub(super) fn requests_resend(&self) -> bool {
            self.code == ERROR_WINHTTP_RESEND_REQUEST
        }

        pub(super) fn summary(&self) -> &'static str {
            match self.code {
                ERROR_WINHTTP_TIMEOUT => "timed out",
                ERROR_WINHTTP_CANNOT_CONNECT => "could not connect",
                ERROR_WINHTTP_CONNECTION_ERROR => "connection failed",
                ERROR_WINHTTP_NAME_NOT_RESOLVED => "name not resolved",
                ERROR_WINHTTP_RESEND_REQUEST => "asked for a resend",
                ERROR_WINHTTP_SECURE_FAILURE => "TLS negotiation failed",
                _ => "failed",
            }
        }
    }

    impl std::fmt::Display for WinHttpFailure {
        fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            write!(
                formatter,
                "{} {} (0x{:08X})",
                self.stage,
                self.summary(),
                self.code
            )
        }
    }

    impl std::error::Error for WinHttpFailure {}

    fn call<T>(stage: &'static str, result: windows::core::Result<T>) -> anyhow::Result<T> {
        result.map_err(|error| {
            anyhow::Error::new(WinHttpFailure {
                stage,
                code: error.code().0 as u32,
            })
        })
    }

    /// One request/response exchange. Headers are set on every attempt so a retry
    /// is indistinguishable from the first try.
    unsafe fn exchange_loopback(
        handle: *mut core::ffi::c_void,
        request: &LoopbackRequest,
        content_type: &[u16],
        protocol: &[u16],
        csrf: &[u16],
    ) -> anyhow::Result<LoopbackResponse> {
        // ADD|REPLACE is "set this header": REPLACE alone fails with
        // ERROR_WINHTTP_HEADER_NOT_FOUND when the header is not present.
        let set_header = WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE;
        call(
            "WinHttpAddRequestHeaders",
            WinHttpAddRequestHeaders(handle, content_type, set_header),
        )?;
        call(
            "WinHttpAddRequestHeaders",
            WinHttpAddRequestHeaders(handle, protocol, set_header),
        )?;
        call(
            "WinHttpAddRequestHeaders",
            WinHttpAddRequestHeaders(handle, csrf, set_header),
        )?;
        call(
            "WinHttpSendRequest",
            WinHttpSendRequest(
                handle,
                None,
                Some(request.body.as_ptr() as *const core::ffi::c_void),
                request.body.len() as u32,
                request.body.len() as u32,
                0,
            ),
        )?;
        call(
            "WinHttpReceiveResponse",
            WinHttpReceiveResponse(handle, std::ptr::null_mut()),
        )?;
        let mut status = 0u32;
        let mut status_length = std::mem::size_of::<u32>() as u32;
        call(
            "WinHttpQueryHeaders",
            WinHttpQueryHeaders(
                handle,
                WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                PCWSTR::null(),
                Some(&mut status as *mut u32 as *mut core::ffi::c_void),
                &mut status_length,
                std::ptr::null_mut(),
            ),
        )?;
        let mut body = Vec::new();
        let mut chunk = [0u8; 8192];
        loop {
            let mut read = 0u32;
            call(
                "WinHttpReadData",
                WinHttpReadData(
                    handle,
                    chunk.as_mut_ptr() as *mut core::ffi::c_void,
                    chunk.len() as u32,
                    &mut read,
                ),
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
    }

    /// The only paths this transport will ever request.
    ///
    /// The macOS transport validates the same thing on the URL it is handed: the
    /// last path component has to be one of the two methods. A prefix test is
    /// broader than that contract — it would accept any sibling under the service
    /// root — so the match is exact.
    pub(super) fn allowed_service_path(path: &str) -> bool {
        ALLOWED_METHODS
            .iter()
            .any(|method| path == format!("{}{}", SERVICE_PATH, method))
    }

    pub(super) fn native_transport_call(
        request: &LoopbackRequest,
    ) -> anyhow::Result<LoopbackResponse> {
        anyhow::ensure!(
            allowed_service_path(&request.path),
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
                // With NO_PROXY the proxy name is unused, and the documented value
                // is WINHTTP_NO_PROXY_NAME. Passing the host here would read as a
                // proxy being configured.
                PCWSTR::null(),
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
            let outcome = exchange_with_resend_retry(|_| {
                exchange_loopback(handle, request, &content_type, &protocol, &csrf)
            });
            let _ = WinHttpCloseHandle(handle);
            let _ = WinHttpCloseHandle(connect);
            let _ = WinHttpCloseHandle(session);
            outcome
        }
    }

    /// Attempts one request is allowed before a resend signal is reported.
    const RESEND_ATTEMPTS: u32 = 2;

    /// Send the request, repeating it once when WinHTTP asks for a resend.
    ///
    /// `ERROR_WINHTTP_RESEND_REQUEST` is a documented outcome rather than a
    /// failure: the server retired the connection after the request went out and
    /// WinHTTP asks for the request again, so the same request handle is reused.
    /// One repeat is enough — a second signal means the endpoint is not answering
    /// and looping would only hold the read open.
    ///
    /// Every other failure is returned at once, including the neighbouring
    /// `ERROR_WINHTTP_CONNECTION_ERROR`: that connection never carried the request,
    /// so resending it is not the documented remedy.
    ///
    /// The repeat itself has only ever been exercised against an injected exchange,
    /// not against a real Antigravity. Nothing here has been verified in a signed-in
    /// Antigravity environment.
    pub(super) fn exchange_with_resend_retry<F>(mut attempt: F) -> anyhow::Result<LoopbackResponse>
    where
        F: FnMut(u32) -> anyhow::Result<LoopbackResponse>,
    {
        let mut taken = 0u32;
        loop {
            taken += 1;
            match attempt(taken) {
                Ok(response) => return Ok(response),
                Err(error) => {
                    let resend = error
                        .downcast_ref::<WinHttpFailure>()
                        .map(WinHttpFailure::requests_resend)
                        .unwrap_or(false);
                    if !resend || taken >= RESEND_ATTEMPTS {
                        return Err(error);
                    }
                }
            }
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

    /// The macOS fixture, replayed here.
    ///
    /// `tests/AntigravityCLIQuotaFixture.swift` drives the other platform's reader
    /// with these exact payloads, at the same fixed instant, and asserts these exact
    /// numbers. Feeding the same input through this parser is what separates "the
    /// rules read the same" from "the two produce the same answer".
    #[test]
    fn the_macos_fixture_produces_the_same_answer_here() {
        // The instant the macOS fixture pins, so the reset-time comparisons line up.
        let now = Utc.timestamp_opt(1_800_000_000, 0).single().unwrap();

        // `status(includeQuota: true)`.
        let status = serde_json::json!({
            "userStatus": {
                "email": "fixture@example.invalid",
                "userTier": { "name": "AI Pro" },
                "cascadeModelConfigData": { "clientModelConfigs": [{
                    "label": "Gemini Pro",
                    "quotaInfo": { "remainingFraction": 0.65, "resetTime": "2030-01-02T03:04:05Z" }
                }] }
            }
        })
        .to_string()
        .into_bytes();
        let parsed = parse_status(&status, now).unwrap();
        assert_eq!(parsed.identity.as_deref(), Some("fixture@example.invalid"));
        assert_eq!(parsed.plan.as_deref(), Some("AI Pro"));
        assert_eq!(parsed.windows.len(), 1);
        assert_eq!(parsed.windows[0].id, "model-0");
        assert_eq!(parsed.windows[0].label, "Gemini Pro");
        assert!((parsed.windows[0].used_percent - 35.0).abs() < 1e-9);
        assert!(parsed.windows[0].resets_at.is_some());
        // The other side asserts this mask for the same identity.
        assert_eq!(
            crate::local_cli::masked_identity("fixture@example.invalid"),
            "f***@example.invalid"
        );

        // `summary()`.
        let summary = serde_json::json!({
            "response": { "groups": [{
                "displayName": "Gemini Models",
                "buckets": [
                    { "bucketId": "five-hour", "displayName": "5-hour",
                      "remainingFraction": 0.72, "resetTime": "2030-01-02T03:04:05.123Z" },
                    { "bucketId": "weekly", "displayName": "Weekly",
                      "remaining": { "case": "remainingFraction", "value": 0.31 } },
                    { "bucketId": "missing", "displayName": "Unknown" },
                    { "bucketId": "disabled", "displayName": "Disabled",
                      "remainingFraction": 0.0, "disabled": true }
                ]
            }] }
        })
        .to_string()
        .into_bytes();
        let windows = parse_summary(&summary, now).unwrap();
        assert_eq!(
            windows.len(),
            2,
            "the bucket with no fraction and the disabled one are both excluded"
        );
        assert_eq!(windows[0].id, "group-0-bucket-0");
        assert_eq!(windows[0].label, "Gemini Models · 5-hour");
        assert!((windows[0].used_percent - 28.0).abs() < 0.001);
        assert!(windows[0].resets_at.is_some());
        assert_eq!(windows[1].id, "group-0-bucket-1");
        assert_eq!(windows[1].label, "Gemini Models · Weekly");
        // The `oneof` spelling of the same field has to read identically.
        assert_eq!(windows[1].used_percent, 69.0);
        assert!(
            windows[1].resets_at.is_none(),
            "a bucket with no reset time stays unknown"
        );
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

        let found = cache_file(temp.path()).expect("the cache inside the root must be found");
        // `cache_file` returns the resolved path, and resolving also expands an
        // 8.3 short name — a CI runner's `%TEMP%` is `RUNNER~1`, not
        // `runneradmin`. Compare the resolved forms so the assertion is about the
        // file rather than about how the temp directory happens to be spelled.
        assert_eq!(
            std::fs::canonicalize(&found).unwrap(),
            std::fs::canonicalize(storage.join("state.vscdb")).unwrap()
        );
        assert_eq!(found.file_name().unwrap(), "state.vscdb");
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

    fn find_subsequence(haystack: &[u8], needle: &[u8]) -> Option<usize> {
        haystack
            .windows(needle.len())
            .position(|window| window == needle)
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
            // Consume the whole request (headers plus the declared body) before
            // answering. Answering after a single partial read leaves the client
            // with an unfinished send, and WinHTTP then reports
            // ERROR_WINHTTP_RESEND_REQUEST instead of the response.
            let mut request = Vec::new();
            let mut chunk = [0u8; 1024];
            loop {
                let read = stream.read(&mut chunk).expect("read request");
                if read == 0 {
                    break;
                }
                request.extend_from_slice(&chunk[..read]);
                let Some(headers_end) = find_subsequence(&request, b"\r\n\r\n") else {
                    continue;
                };
                let head = String::from_utf8_lossy(&request[..headers_end]).to_lowercase();
                let expected = head
                    .lines()
                    .find_map(|line| line.strip_prefix("content-length:"))
                    .and_then(|value| value.trim().parse::<usize>().ok())
                    .unwrap_or(0);
                if request.len() >= headers_end + 4 + expected {
                    break;
                }
            }
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

    /// The transport used to accept anything under the service root, which is
    /// broader than the macOS contract: that side requires the last path component
    /// to be one of the two methods.
    #[cfg(windows)]
    #[test]
    fn only_the_two_service_methods_are_accepted() {
        for method in ALLOWED_METHODS {
            let path = format!("{}{}", SERVICE_PATH, method);
            assert!(win32::allowed_service_path(&path), "{path}");
        }
        for path in [
            // A sibling under the same prefix is not one of the two methods.
            format!("{}SomethingElse", SERVICE_PATH),
            // Neither is the bare service root, nor a deeper path.
            SERVICE_PATH.to_string(),
            format!("{}GetUserStatus/extra", SERVICE_PATH),
            // Nor a look-alike service name.
            "/exa.language_server_pb.LanguageServerServiceOther/GetUserStatus".to_string(),
            "/etc/passwd".to_string(),
            String::new(),
        ] {
            assert!(!win32::allowed_service_path(&path), "{path}");
        }
        // The refusal reaches the transport, not just the helper.
        let error = native_transport(&LoopbackRequest {
            scheme: EndpointScheme::Http,
            port: 1,
            path: format!("{}SomethingElse", SERVICE_PATH),
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

    #[test]
    fn loopback_matching_accepts_only_the_wildcard_and_127_0_0_1() {
        // 127.0.0.1 in network byte order.
        assert!(reachable_at_loopback(0x0100_007f));
        // The IPv4 wildcard, which mirrors a `*:` listener on macOS.
        assert!(reachable_at_loopback(0));
        // 127.0.0.2 and any other host in 127/8 cannot be reached at 127.0.0.1.
        assert!(!reachable_at_loopback(0x0200_007f));
        // A LAN address, in network byte order.
        assert!(!reachable_at_loopback(0x0100_a8c0));
        // An IPv6-mapped or otherwise unrelated value must not slip through.
        assert!(!reachable_at_loopback(0xffff_ffff));
    }

    #[test]
    fn install_root_matching_uses_path_components_not_string_prefixes() {
        let root = Path::new(r"C:\Program Files");
        assert!(path_starts_with(
            Path::new(r"C:\Program Files\Antigravity\language_server.exe"),
            root
        ));
        // Separators and case do not matter.
        assert!(path_starts_with(
            Path::new("c:/program files/Antigravity/language_server.exe"),
            root
        ));
        // A sibling directory whose name merely starts like the root must fail.
        assert!(!path_starts_with(
            Path::new(r"C:\Program Files Elsewhere\Antigravity\language_server.exe"),
            root
        ));
        assert!(!path_starts_with(Path::new(r"C:\Program"), root));
        // The root itself matches, but nothing above it does.
        assert!(path_starts_with(root, root));
        assert!(!path_starts_with(
            root,
            Path::new(r"C:\Program Files\Antigravity")
        ));
    }

    #[test]
    fn character_truncation_never_splits_a_code_point() {
        // Four-byte characters, where a byte-offset slice would panic.
        let value = "🛰️🛰️🛰️🛰️";
        let truncated = truncate_chars(value, 2);
        assert_eq!(truncated.chars().count(), 2);
        assert!(value.starts_with(&truncated));
        assert_eq!(truncate_chars(value, 0), "");
        assert_eq!(truncate_chars(value, 99), value);
        // Mixed-width input stays valid UTF-8.
        assert_eq!(truncate_chars("aé漢🛰️b", 3), "aé漢");
    }

    #[test]
    fn canonical_paths_are_returned_without_the_verbatim_prefix() {
        // Only Windows adds the prefix, so the assertion is Windows-only.
        #[cfg(windows)]
        {
            assert_eq!(
                without_verbatim_prefix(PathBuf::from(r"\\?\C:\Users\example\.codex")),
                PathBuf::from(r"C:\Users\example\.codex")
            );
            assert_eq!(
                without_verbatim_prefix(PathBuf::from(r"\\?\UNC\server\share\dir")),
                PathBuf::from(r"\\server\share\dir")
            );
            // A verbatim volume path has no plain spelling and stays as it is.
            assert_eq!(
                without_verbatim_prefix(PathBuf::from(r"\\?\Volume{9f0d}\dir")),
                PathBuf::from(r"\\?\Volume{9f0d}\dir")
            );
        }
        // A path that never had the prefix is returned unchanged.
        assert_eq!(
            without_verbatim_prefix(PathBuf::from(r"C:\Users\example")),
            PathBuf::from(r"C:\Users\example")
        );
    }

    #[test]
    fn a_linked_cache_directory_is_never_followed() {
        let temp = tempfile::tempdir().unwrap();
        let real = temp.path().join("real");
        let storage = real.join("globalStorage");
        std::fs::create_dir_all(&storage).unwrap();
        std::fs::write(storage.join("state.vscdb"), b"sqlite").unwrap();

        // A junction or symlink named `User` must be refused even though the
        // file behind it exists and is a real file.
        #[cfg(windows)]
        let linked = std::os::windows::fs::symlink_dir(&real, temp.path().join("User"));
        #[cfg(not(windows))]
        let linked = std::os::unix::fs::symlink(&real, temp.path().join("User"));

        match linked {
            Ok(()) => assert_eq!(
                cache_file(temp.path()),
                None,
                "a link in the chain must not be followed"
            ),
            // Creating a link needs a privilege this account may not hold, and
            // the check itself is still exercised by the happy path below.
            Err(_) => eprintln!("skipping the link case: the account cannot create links"),
        }

        // Without the link the same tree is accepted.
        std::fs::remove_dir_all(temp.path().join("User")).ok();
        std::fs::rename(&real, temp.path().join("User")).unwrap();
        assert!(cache_file(temp.path()).is_some());
    }

    #[cfg(windows)]
    #[test]
    fn named_winhttp_failures_explain_themselves() {
        for (code, expected, resend) in [
            (0x8007_2EE2, "timed out", false),
            (0x8007_2EE7, "name not resolved", false),
            (0x8007_2EFD, "could not connect", false),
            (0x8007_2EFE, "connection failed", false),
            (0x8007_2F00, "asked for a resend", true),
            (0x8007_2F8F, "TLS negotiation failed", false),
        ] {
            let failure = win32::WinHttpFailure {
                stage: "receive response",
                code,
            };
            assert_eq!(failure.summary(), expected, "code {code:#010x}");
            assert_eq!(failure.requests_resend(), resend, "code {code:#010x}");
            // The rendered message keeps both the stage and the reason.
            let message = failure.to_string();
            assert!(message.contains("receive response"), "{message}");
            assert!(message.contains(expected), "{message}");
        }
        // An unrecognised HRESULT still reports the stage.
        let unknown = win32::WinHttpFailure {
            stage: "send request",
            code: 0x8007_0001,
        };
        assert_eq!(unknown.summary(), "failed");
        assert!(!unknown.requests_resend());
    }

    /// `CONNECTION_ERROR` and `RESEND_REQUEST` are adjacent codes that were once
    /// swapped here, so the distinction is pinned rather than assumed.
    #[cfg(windows)]
    #[test]
    fn a_connection_error_is_not_a_resend_request() {
        // The HRESULT form is `0x8007_0000 | code`, and the two codes are 12030 and
        // 12032 — one apart, which is what made the mistake easy.
        assert_eq!(0x8007_0000u32 | 12030u32, 0x8007_2EFEu32);
        assert_eq!(0x8007_0000u32 | 12032u32, 0x8007_2F00u32);
        assert_ne!(12030u32, 12032u32);

        let connection = win32::WinHttpFailure {
            stage: "receive response",
            code: 0x8007_2EFE,
        };
        let resend = win32::WinHttpFailure {
            stage: "receive response",
            code: 0x8007_2F00,
        };
        assert_eq!(connection.summary(), "connection failed");
        assert_eq!(resend.summary(), "asked for a resend");
        // 12030 is a connection that never carried the request; only 12032 asks for
        // the request to be sent again.
        assert!(!connection.requests_resend());
        assert!(resend.requests_resend());
    }

    /// The resend path end to end, with the exchange injected so it is the retry
    /// that is under test rather than WinHTTP.
    #[cfg(windows)]
    #[test]
    fn a_resend_signal_is_repeated_once_and_can_succeed() {
        let answered = || LoopbackResponse {
            status: 200,
            body: b"ok".to_vec(),
        };
        let failure = |code: u32| {
            anyhow::Error::new(win32::WinHttpFailure {
                stage: "receive response",
                code,
            })
        };

        // The first attempt is asked for a resend, the repeat is answered.
        let mut calls = 0u32;
        let outcome = win32::exchange_with_resend_retry(|attempt| {
            calls += 1;
            assert!(attempt <= 2, "the retry loop ran {attempt} times");
            if attempt == 1 {
                Err(failure(0x8007_2F00))
            } else {
                Ok(answered())
            }
        })
        .expect("the repeated request must be accepted");
        assert_eq!(calls, 2, "a resend signal must be repeated exactly once");
        assert_eq!(outcome.status, 200);
        assert_eq!(outcome.body, b"ok");

        // A first-attempt success is never repeated.
        let mut calls = 0u32;
        win32::exchange_with_resend_retry(|_| {
            calls += 1;
            Ok(answered())
        })
        .unwrap();
        assert_eq!(calls, 1);

        // A second resend signal is reported instead of looping.
        let mut calls = 0u32;
        let error = win32::exchange_with_resend_retry(|_| {
            calls += 1;
            Err(failure(0x8007_2F00))
        })
        .expect_err("a second resend signal must be reported");
        assert_eq!(calls, 2, "the loop must stop after one repeat");
        assert_eq!(
            error
                .downcast_ref::<win32::WinHttpFailure>()
                .map(win32::WinHttpFailure::summary),
            Some("asked for a resend")
        );

        // The neighbouring connection error is reported at once, not repeated.
        let mut calls = 0u32;
        let error = win32::exchange_with_resend_retry(|_| {
            calls += 1;
            Err(failure(0x8007_2EFE))
        })
        .expect_err("a connection error must be reported at once");
        assert_eq!(calls, 1, "a connection error must not be repeated");
        assert_eq!(
            error
                .downcast_ref::<win32::WinHttpFailure>()
                .map(win32::WinHttpFailure::summary),
            Some("connection failed")
        );
    }

    /// Real-machine Authenticode check.
    ///
    /// The pure tests cannot reach the WinTrust plumbing: it needs a genuinely
    /// signed image and a chain this machine trusts. Windows has two Authenticode
    /// forms — embedded, which travels inside the image, and catalog, which lives
    /// in a system catalog and references the image by hash — and a check that
    /// knows only the first rejects the second with `TRUST_E_NOSIGNATURE`. That is
    /// exactly what this test caught: every `System32` image on a current Windows
    /// install is catalog-signed, so the publisher came back empty for all of them.
    #[cfg(windows)]
    #[test]
    fn a_trusted_signer_is_read_in_either_authenticode_form() {
        let system_root = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".to_string());
        let system32 = Path::new(&system_root).join("System32");
        let image = ["notepad.exe", "cmd.exe", "where.exe"]
            .into_iter()
            .map(|name| system32.join(name))
            .find(|path| path.is_file())
            .expect("no System32 image was available to check");

        // The two forms are tried in order, and the second is reached exactly when
        // the first has nothing to say.
        let publisher = match win32::embedded_publisher(&image) {
            Some(embedded) => embedded,
            None => win32::catalog_publisher(&image)
                .expect("a System32 image carries an embedded or a catalog signature"),
        };
        assert_eq!(
            publisher_of(&image).as_deref(),
            Some(publisher.as_str()),
            "the dispatcher disagreed with the form that answered"
        );

        // Whichever form answered, the signer must not pass as an official
        // publisher. This is the property that keeps a binary merely dropped under
        // an install root from being accepted.
        assert!(
            !publisher.to_lowercase().contains("google"),
            "{publisher} must not be treated as an official publisher"
        );
        assert!(!is_officially_signed(&image));

        // An unsigned file has no publisher in either form, and is therefore never
        // accepted either.
        let temp = tempfile::tempdir().unwrap();
        let unsigned = temp.path().join("unsigned.exe");
        std::fs::write(&unsigned, b"not a signed image").unwrap();
        assert_eq!(publisher_of(&unsigned), None);
        assert_eq!(win32::catalog_publisher(&unsigned), None);
        assert!(!is_officially_signed(&unsigned));

        // A path that does not exist is handled the same way.
        assert_eq!(publisher_of(&temp.path().join("missing.exe")), None);
    }

    /// Real-machine honesty check.
    ///
    /// Ignored by default because the second half depends on what this machine has
    /// installed; run it with `--ignored` on the machine under test. The first half
    /// is deterministic everywhere: a linked directory that does not exist can
    /// never produce a quota, must not borrow the running application's account,
    /// and must not fall back to the default directory's cache.
    #[cfg(windows)]
    #[ignore = "depends on what this machine has installed; run with --ignored"]
    #[test]
    fn a_real_machine_read_never_invents_a_quota() {
        use crate::local_cli::PlatformDirectories;
        use crate::readers::read_local_cli_quota;

        let directories = PlatformDirectories::detect();
        let now = Utc::now();
        let absent = directories.home.join("antigravity-does-not-exist");

        // The shared dispatcher refuses a directory it cannot recognise, before
        // any platform reader runs.
        let dispatched = read_local_cli_quota(LocalCliKind::Antigravity, &absent, false, now);
        assert_eq!(dispatched.state, LocalCliQuotaState::Unavailable);
        assert!(dispatched.windows.is_empty());
        assert!(dispatched.masked_identity.is_none());
        assert_eq!(
            dispatched.message_code.as_deref(),
            Some("local_cli_directory_not_recognized")
        );

        // Asked directly, the adapter says it has nothing rather than borrowing the
        // default directory's cache or the running application's account.
        let linked = AntigravityReader::native().load(&absent, false, now);
        assert_eq!(linked.state, LocalCliQuotaState::Unavailable);
        assert!(linked.windows.is_empty());
        assert!(linked.masked_identity.is_none());
        assert_eq!(
            linked.message_code.as_deref(),
            Some("local_cli_antigravity_linked_cache_only")
        );

        // Whatever this machine has, the result must describe itself honestly.
        let shared_root = directories.default_directory(LocalCliKind::Antigravity);
        let shared = read_local_cli_quota(LocalCliKind::Antigravity, &shared_root, true, now);
        eprintln!(
            "[antigravity] root={} exists={} state={:?} code={:?} windows={} source={:?}",
            shared_root.display(),
            shared_root.is_dir(),
            shared.state,
            shared.message_code,
            shared.windows.len(),
            shared.source_label,
        );

        if shared.state == LocalCliQuotaState::Available {
            // Only a live read may be available, and it must carry both a window
            // and the masked identity that window belongs to.
            assert!(!shared.windows.is_empty(), "available without a window");
            assert!(
                shared.masked_identity.is_some(),
                "available without an identity"
            );
            assert!(
                !shared.source_label.contains("cached"),
                "a cached source must not be reported as available: {}",
                shared.source_label
            );
        }
        // A default directory that does not exist cannot be a quota.
        if !shared_root.is_dir() {
            assert_ne!(shared.state, LocalCliQuotaState::Available);
            assert!(shared.windows.is_empty());
        }
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
