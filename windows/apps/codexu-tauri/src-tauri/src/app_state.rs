use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync::atomic::AtomicUsize;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex, RwLock};
use tracing::{error, info, warn};

use codexu_core::models::CodexDashboardSnapshot;
use codexu_core::readers::{
    apply_official_quota, retain_last_verified_quota, CodexAppServerQuotaSnapshot,
    CodexDashboardProvider,
};

/// User-configurable app settings.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    #[serde(default)]
    pub profiles: codexu_core::profiles::ProfileCatalog,
    /// Path to Codex data root (e.g. ~/.codex).
    pub codex_root: PathBuf,
    /// Path to the Codex Account Manager Next cache directory.
    pub cache_dir: PathBuf,
    /// Theme preference.
    #[serde(default)]
    pub theme: ThemeMode,
    /// Semantic color palette identifier.
    #[serde(default = "default_palette_id")]
    pub palette_id: String,
    /// Auto-refresh interval in seconds.
    #[serde(default = "default_refresh_interval_secs")]
    pub refresh_interval_secs: u64,
    /// Tray density mode (stored for future use).
    #[serde(default)]
    pub tray_density: TrayDensity,
    /// Interface language preference.
    #[serde(default)]
    pub language: InterfaceLanguage,
}

impl Default for AppConfig {
    fn default() -> Self {
        let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
        Self {
            profiles: Default::default(),
            codex_root: home.join(".codex"),
            cache_dir: dirs::cache_dir()
                .unwrap_or_else(|| home.join(".cache"))
                .join("CodexAccountManagerNext"),
            theme: ThemeMode::System,
            palette_id: default_palette_id(),
            refresh_interval_secs: default_refresh_interval_secs(),
            tray_density: TrayDensity::Classic,
            language: InterfaceLanguage::Auto,
        }
    }
}

fn default_refresh_interval_secs() -> u64 {
    60
}

fn default_palette_id() -> String {
    "codexu.default".to_string()
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ThemeMode {
    #[default]
    System,
    Light,
    Dark,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TrayDensity {
    Minimal,
    #[default]
    Classic,
    Rich,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum InterfaceLanguage {
    #[default]
    #[serde(rename = "auto")]
    Auto,
    #[serde(rename = "zh-Hans")]
    ZhHans,
    #[serde(rename = "en")]
    En,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ResolvedLanguage {
    #[serde(rename = "zh-Hans")]
    ZhHans,
    #[serde(rename = "en")]
    En,
}

impl InterfaceLanguage {
    pub fn resolved(self, fallback: ResolvedLanguage) -> ResolvedLanguage {
        match self {
            Self::Auto => fallback,
            Self::ZhHans => ResolvedLanguage::ZhHans,
            Self::En => ResolvedLanguage::En,
        }
    }
}

impl AppConfig {
    pub fn load(app_data_dir: &Path) -> Self {
        let path = app_data_dir.join("settings.json");
        match std::fs::read_to_string(&path) {
            Ok(text) => match serde_json::from_str::<AppConfig>(&text) {
                Ok(c) => c,
                Err(e) => {
                    warn!("Failed to parse settings file, using defaults: {}", e);
                    Self::default()
                }
            },
            Err(_) => Self::default(),
        }
    }

    pub fn save(&self, app_data_dir: &Path) -> anyhow::Result<()> {
        self.profiles.validate()?;
        let path = app_data_dir.join("settings.json");
        let text = serde_json::to_string_pretty(self)?;
        codexu_core::atomic_settings::write_json(&path, text.as_bytes(), |prior| {
            // Valid JSON with an incompatible schema also needs explicit recovery.
            let old: Self = serde_json::from_slice(prior)?;
            old.profiles.validate()
        })?;
        Ok(())
    }
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub(crate) struct DashboardSourceKey {
    codex_root: PathBuf,
    cache_dir: PathBuf,
}

impl DashboardSourceKey {
    fn from_config(config: &AppConfig) -> Self {
        Self {
            codex_root: config.codex_root.clone(),
            cache_dir: config.cache_dir.clone(),
        }
    }
}

/// Cached usage snapshot plus metadata.
#[derive(Debug, Clone)]
pub struct CachedSnapshot {
    pub dashboard: Option<CodexDashboardSnapshot>,
    pub refreshed_at: DateTime<Utc>,
    pub source_key: DashboardSourceKey,
    pub source_generation: u64,
}

/// Shared application state.
pub struct AppState {
    pub config: RwLock<AppConfig>,
    pub runtime_language: RwLock<ResolvedLanguage>,
    pub snapshot: RwLock<Option<CachedSnapshot>>,
    pub refresh_lock: Mutex<()>,
    pub app_data_dir: PathBuf,
    source_generation: AtomicU64,
    #[cfg(test)]
    pub(crate) refresh_call_count: Arc<AtomicUsize>,
    #[cfg(test)]
    refresh_attempt_hook:
        Arc<tokio::sync::Mutex<Option<std::sync::Arc<dyn Fn(Arc<Self>, usize) + Send + Sync>>>>,
}

impl AppState {
    pub fn new(app_data_dir: PathBuf) -> Self {
        let config = AppConfig::load(&app_data_dir);
        let runtime_language = config.language.resolved(ResolvedLanguage::En);
        Self {
            config: RwLock::new(config),
            runtime_language: RwLock::new(runtime_language),
            snapshot: RwLock::new(None),
            refresh_lock: Mutex::new(()),
            app_data_dir,
            source_generation: AtomicU64::new(0),
            #[cfg(test)]
            refresh_call_count: Arc::new(AtomicUsize::new(0)),
            #[cfg(test)]
            refresh_attempt_hook: Arc::new(tokio::sync::Mutex::new(None)),
        }
    }

    pub async fn set_runtime_language(&self, language: ResolvedLanguage) {
        *self.runtime_language.write().await = language;
    }

    async fn current_source_key(&self) -> DashboardSourceKey {
        let config = self.config.read().await;
        DashboardSourceKey::from_config(&config)
    }

    fn is_fresh(snapshot: &CachedSnapshot, max_age_secs: u64) -> bool {
        let age_secs = (Utc::now() - snapshot.refreshed_at).num_seconds().max(0) as u64;
        age_secs < max_age_secs
    }

    /// Get the cached usage, refreshing if the cache is missing or older than `max_age_secs`.
    pub async fn get_usage(
        self: &Arc<Self>,
        max_age_secs: u64,
    ) -> anyhow::Result<Option<CodexDashboardSnapshot>> {
        let current_source = self.current_source_key().await;

        {
            let snapshot = self.snapshot.read().await;
            if let Some(ref cached) = *snapshot {
                if cached.source_key == current_source
                    && cached.source_generation == self.source_generation.load(Ordering::SeqCst)
                    && Self::is_fresh(cached, max_age_secs)
                {
                    return Ok(cached.dashboard.clone());
                }
            }
        }

        let _guard = self.refresh_lock.lock().await;
        let current_source = self.current_source_key().await;

        {
            let snapshot = self.snapshot.read().await;
            if let Some(ref cached) = *snapshot {
                if cached.source_key == current_source
                    && cached.source_generation == self.source_generation.load(Ordering::SeqCst)
                    && Self::is_fresh(cached, max_age_secs)
                {
                    return Ok(cached.dashboard.clone());
                }
            }
        }

        self.refresh_usage_from_source(
            current_source,
            self.source_generation.load(Ordering::SeqCst),
        )
        .await
    }

    /// Force a refresh of the usage snapshot.
    pub async fn refresh_usage(self: &Arc<Self>) -> anyhow::Result<Option<CodexDashboardSnapshot>> {
        let _guard = self.refresh_lock.lock().await;
        let source = self.current_source_key().await;
        self.refresh_usage_from_source(source, self.source_generation.load(Ordering::SeqCst))
            .await
    }

    async fn refresh_usage_from_source(
        self: &Arc<Self>,
        source: DashboardSourceKey,
        expected_generation: u64,
    ) -> anyhow::Result<Option<CodexDashboardSnapshot>> {
        let mut source = source;
        let mut expected_generation = expected_generation;

        for _attempt in 0..2 {
            let previous_dashboard = {
                let snapshot = self.snapshot.read().await;
                snapshot.as_ref().and_then(|cached| {
                    (cached.source_key == source && cached.source_generation == expected_generation)
                        .then(|| cached.dashboard.clone())
                        .flatten()
                })
            };
            let provider = CodexDashboardProvider::new(&source.codex_root, &source.cache_dir);
            let now = Utc::now();
            let snapshot = match provider.load_dashboard_snapshot(now).await? {
                Some(dashboard) => {
                    let quota = codexu_core::readers::codex_app_server::read_codex_quota_for_home(
                        &source.codex_root,
                    )
                    .await
                    .unwrap_or_else(|_| CodexAppServerQuotaSnapshot::unavailable());
                    Some(retain_last_verified_quota(
                        previous_dashboard.as_ref(),
                        apply_official_quota(dashboard, quota),
                    ))
                }
                None => None,
            };

            #[cfg(test)]
            self.refresh_call_count.fetch_add(1, Ordering::SeqCst);

            #[cfg(test)]
            {
                let hook = self.refresh_attempt_hook.lock().await.clone();
                if let Some(hook) = hook {
                    hook(self.clone(), _attempt);
                }
            }

            let cache = Some(CachedSnapshot {
                dashboard: snapshot.clone(),
                refreshed_at: now,
                source_key: source.clone(),
                source_generation: expected_generation,
            });
            {
                let mut guard = self.snapshot.write().await;
                let config = self.config.read().await;
                if DashboardSourceKey::from_config(&config) == source
                    && self.source_generation.load(Ordering::SeqCst) == expected_generation
                {
                    *guard = cache;
                    if snapshot.is_some() {
                        info!("Usage snapshot refreshed");
                    } else {
                        warn!("No Codex usage data found");
                    }
                    return Ok(snapshot);
                }
            }

            if self.source_generation.load(Ordering::SeqCst) != expected_generation {
                warn!(
                    "Config source changed while refreshing dashboard snapshot; retrying with latest config"
                );
            } else {
                warn!("Could not refresh dashboard snapshot with stable source; retrying");
            }

            let latest_source = {
                let config = self.config.read().await;
                DashboardSourceKey::from_config(&config)
            };
            let latest_generation = self.source_generation.load(Ordering::SeqCst);
            source = latest_source;
            expected_generation = latest_generation;
        }

        warn!("Could not refresh usage snapshot with stable source config");
        anyhow::bail!(
            "Failed to refresh dashboard snapshot due to concurrent config source changes"
        );
    }

    /// Update config and persist to disk.
    pub async fn update_config<F>(self: &Arc<Self>, f: F) -> anyhow::Result<AppConfig>
    where
        F: FnOnce(&mut AppConfig),
    {
        self.try_update_config(|config| {
            f(config);
            Ok(())
        })
        .await
    }

    pub async fn try_update_config<F>(self: &Arc<Self>, f: F) -> anyhow::Result<AppConfig>
    where
        F: FnOnce(&mut AppConfig) -> anyhow::Result<()>,
    {
        let mut config = self.config.write().await;
        let previous_source = DashboardSourceKey::from_config(&config);
        // Apply the patch to a candidate first. Persisting the candidate
        // before replacing the in-memory config keeps a failed write from
        // silently changing the active source or refresh generation.
        let mut candidate = config.clone();
        f(&mut candidate)?;
        let current_source = DashboardSourceKey::from_config(&candidate);
        candidate.save(&self.app_data_dir)?;
        if current_source != previous_source {
            self.source_generation.fetch_add(1, Ordering::SeqCst);
        }
        *config = candidate.clone();
        Ok(candidate)
    }
}

/// Clears the Codex Account Manager Next file cache for the configured cache directory.
pub async fn clear_cache(state: &Arc<AppState>) {
    let cache_dir = {
        let config = state.config.read().await;
        config.cache_dir.clone()
    };
    let codex_cache = cache_dir.join("codex").join("session-usage-v1.json");
    let claude_cache = cache_dir.join("claude-code").join("session-usage-v1.json");
    for path in [codex_cache, claude_cache] {
        if let Err(e) = tokio::fs::remove_file(&path).await {
            if e.kind() != std::io::ErrorKind::NotFound {
                // Do not put the user-selected cache path into logs.
                error!(error = %e, "Failed to remove a Next cache file");
            }
        }
    }
    {
        let mut guard = state.snapshot.write().await;
        *guard = None;
    }
    state.source_generation.fetch_add(1, Ordering::SeqCst);
    info!("Cleared Codex Account Manager Next cache");
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    use chrono::Duration;
    use codexu_core::models::{
        AccountInfo, CodexDashboardSnapshot, CodexLeadershipSignal, LeadershipDashboardSnapshot,
        RuntimeMenuStatus, RuntimeScope, RuntimeUsageSnapshot, UsageSnapshot,
    };

    fn unique_temp_path(prefix: &str) -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default();
        std::env::temp_dir().join(format!("{}-{}", prefix, stamp))
    }

    #[test]
    fn interface_language_uses_stable_wire_values() {
        assert_eq!(
            serde_json::to_string(&InterfaceLanguage::Auto).unwrap(),
            r#""auto""#
        );
        assert_eq!(
            serde_json::to_string(&InterfaceLanguage::ZhHans).unwrap(),
            r#""zh-Hans""#
        );
        assert_eq!(
            serde_json::to_string(&InterfaceLanguage::En).unwrap(),
            r#""en""#
        );
    }

    #[test]
    fn legacy_settings_without_language_default_to_auto() {
        let app_data_dir = unique_temp_path("codexu-tauri-legacy-language");
        std::fs::create_dir_all(&app_data_dir).unwrap();
        std::fs::write(
            app_data_dir.join("settings.json"),
            r#"{
                "codex_root": "C:\\Users\\example\\.codex",
                "cache_dir": "C:\\Users\\example\\AppData\\Local\\CodexAccountManagerNext",
                "theme": "system",
                "refresh_interval_secs": 60,
                "tray_density": "classic"
            }"#,
        )
        .unwrap();

        let config = AppConfig::load(&app_data_dir);
        assert_eq!(config.language, InterfaceLanguage::Auto);
        assert_eq!(config.palette_id, "codexu.default");
    }

    #[tokio::test]
    async fn update_config_keeps_memory_unchanged_when_persistence_fails() {
        let app_data_path = unique_temp_path("codexu-tauri-settings-file");
        std::fs::write(&app_data_path, b"not-a-directory").unwrap();
        let state = Arc::new(AppState::new(app_data_path));

        let result = state
            .update_config(|config| {
                config.theme = ThemeMode::Dark;
                config.codex_root = unique_temp_path("codexu-tauri-unsaved-root");
            })
            .await;

        assert!(result.is_err());
        assert_eq!(state.config.read().await.theme, ThemeMode::System);
        assert_eq!(state.source_generation.load(Ordering::SeqCst), 0);
    }

    fn create_snapshot(now: DateTime<Utc>) -> CodexDashboardSnapshot {
        CodexDashboardSnapshot {
            codex: RuntimeUsageSnapshot {
                scope: RuntimeScope::Codex,
                snapshot: UsageSnapshot {
                    refreshed_at: now,
                    account: AccountInfo {
                        r#type: "codex-local".to_string(),
                        plan_type: None,
                        email_present: false,
                    },
                    limit_id: "codex-local".to_string(),
                    limit_name: "Codex local".to_string(),
                    quota_read_succeeded: false,
                    five_hour_quota: None,
                    seven_day_quota: None,
                    monthly_quota: None,
                    local: None,
                    task_board: None,
                    messages: vec![],
                },
                status: RuntimeMenuStatus::LocalOnly,
                quota_source_label: "Official quota unavailable on Windows".to_string(),
                usage_source_label: "Local Codex transcript data".to_string(),
            },
            leadership: CodexLeadershipSignal {
                score: None,
                evidence_coverage: 0.0,
                active_day_count: 0,
                period: "twentyEightDays".to_string(),
                model_version: "1.3-codex-interval".to_string(),
                report: Some(LeadershipDashboardSnapshot {
                    model_version: "1.3-codex-interval".to_string(),
                    refreshed_at: now,
                    reports: vec![],
                }),
            },
            refreshed_at: now,
            messages: vec!["Cached dashboard snapshot".to_string()],
        }
    }

    #[tokio::test]
    async fn get_usage_uses_cached_snapshot_before_ttl() {
        let app_data_dir = unique_temp_path("codexu-tauri-cache-test");
        let state = Arc::new(AppState::new(app_data_dir));
        let now = Utc::now();

        {
            let mut snapshot = state.snapshot.write().await;
            let source = {
                let config = state.config.read().await;
                DashboardSourceKey::from_config(&config)
            };
            *snapshot = Some(CachedSnapshot {
                dashboard: Some(create_snapshot(now - Duration::seconds(5))),
                refreshed_at: now,
                source_key: source,
                source_generation: 0,
            });
        }

        let value = state.get_usage(60).await.unwrap().unwrap();
        assert_eq!(
            value.messages,
            vec!["Cached dashboard snapshot".to_string()]
        );
        assert_eq!(value.refreshed_at, now - Duration::seconds(5));
    }

    #[tokio::test]
    async fn get_usage_uses_cached_none_and_respects_ttl() {
        let app_data_dir = unique_temp_path("codexu-tauri-cache-none-ttl");
        let state = Arc::new(AppState::new(app_data_dir));
        let now = Utc::now();
        {
            let mut snapshot = state.snapshot.write().await;
            let source = {
                let config = state.config.read().await;
                DashboardSourceKey::from_config(&config)
            };
            *snapshot = Some(CachedSnapshot {
                dashboard: None,
                refreshed_at: now,
                source_key: source,
                source_generation: 0,
            });
        }

        let value = state.get_usage(120).await.unwrap();
        assert!(value.is_none());
        assert_eq!(0, state.refresh_call_count.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn refresh_usage_stores_none_snapshot_and_keeps_ttl_entry() {
        let app_data_dir = unique_temp_path("codexu-tauri-refresh-none");
        let state = Arc::new(AppState::new(app_data_dir));
        let codex_root = unique_temp_path("codexu-tauri-codex-root-none");
        let cache_dir = unique_temp_path("codexu-tauri-cache-root-none");
        std::fs::create_dir_all(&cache_dir).unwrap();
        {
            let mut config = state.config.write().await;
            config.codex_root = codex_root;
            config.cache_dir = cache_dir;
        }

        let snapshot = state.refresh_usage().await.unwrap();
        assert!(snapshot.is_none());

        let cached = state.snapshot.read().await.clone();
        assert!(cached.is_some());
        assert!(cached.unwrap().dashboard.is_none());
    }

    #[tokio::test]
    async fn get_usage_uses_latest_source_when_cached_source_is_stale() {
        let app_data_dir = unique_temp_path("codexu-tauri-source-change");
        let state = Arc::new(AppState::new(app_data_dir));
        let old_root = unique_temp_path("codexu-tauri-old-root");
        let new_root = unique_temp_path("codexu-tauri-new-root");
        let cache_dir = unique_temp_path("codexu-tauri-source-cache");
        std::fs::create_dir_all(&old_root).unwrap();
        std::fs::create_dir_all(&new_root).unwrap();
        std::fs::create_dir_all(&cache_dir).unwrap();
        std::fs::create_dir_all(old_root.join("archived_sessions")).unwrap();
        std::fs::create_dir_all(new_root.join("archived_sessions")).unwrap();
        {
            let mut config = state.config.write().await;
            config.codex_root = old_root.clone();
            config.cache_dir = cache_dir.clone();
        }
        {
            let mut snapshot = state.snapshot.write().await;
            *snapshot = Some(CachedSnapshot {
                dashboard: None,
                refreshed_at: Utc::now() - Duration::seconds(120),
                source_key: DashboardSourceKey::from_config(&AppConfig {
                    profiles: Default::default(),
                    codex_root: old_root.clone(),
                    cache_dir: cache_dir.clone(),
                    theme: ThemeMode::System,
                    palette_id: "codexu.default".to_string(),
                    refresh_interval_secs: 60,
                    tray_density: TrayDensity::Classic,
                    language: InterfaceLanguage::Auto,
                }),
                source_generation: 0,
            });
        }

        {
            let mut config = state.config.write().await;
            config.codex_root = new_root.clone();
        }

        let _ = state.get_usage(0).await.unwrap();

        let cached = state.snapshot.read().await.clone().expect("cache exists");
        assert_eq!(cached.source_key.codex_root, new_root);
    }

    #[tokio::test]
    async fn get_usage_only_refreshes_once_for_concurrent_readers() {
        let app_data_dir = unique_temp_path("codexu-tauri-single-flight");
        let state = Arc::new(AppState::new(app_data_dir));
        {
            let mut snapshot = state.snapshot.write().await;
            let source = {
                let config = state.config.read().await;
                DashboardSourceKey::from_config(&config)
            };
            *snapshot = Some(CachedSnapshot {
                dashboard: None,
                refreshed_at: Utc::now() - Duration::seconds(120),
                source_key: source,
                source_generation: 0,
            });
        }
        {
            let mut config = state.config.write().await;
            config.codex_root = unique_temp_path("codexu-tauri-single-flight-root");
            let cache_dir = unique_temp_path("codexu-tauri-single-flight-cache");
            std::fs::create_dir_all(&config.codex_root.join("archived_sessions")).unwrap();
            std::fs::create_dir_all(&cache_dir).unwrap();
            config.cache_dir = cache_dir;
        }

        let mut handles = Vec::new();
        for _ in 0..4 {
            let state = state.clone();
            handles.push(tokio::spawn(async move { state.get_usage(60).await }));
        }

        for handle in handles {
            handle.await.unwrap().unwrap();
        }

        let value = state.get_usage(60).await.unwrap();
        assert!(value.is_none());
        assert_eq!(1, state.refresh_call_count.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn get_usage_rejects_stale_snapshot_after_source_generation_cycle() {
        let app_data_dir = unique_temp_path("codexu-tauri-generation-cycle");
        let state = Arc::new(AppState::new(app_data_dir));
        let source_a = unique_temp_path("codexu-tauri-generation-root-a");
        let source_b = unique_temp_path("codexu-tauri-generation-root-b");
        let cache_dir = unique_temp_path("codexu-tauri-generation-cache");
        std::fs::create_dir_all(&source_a).unwrap();
        std::fs::create_dir_all(&source_b).unwrap();
        std::fs::create_dir_all(&cache_dir).unwrap();
        {
            let mut config = state.config.write().await;
            config.codex_root = source_a.clone();
            config.cache_dir = cache_dir;
        }

        let stale_source = {
            let config = state.config.read().await;
            DashboardSourceKey::from_config(&config)
        };
        {
            let mut snapshot = state.snapshot.write().await;
            *snapshot = Some(CachedSnapshot {
                dashboard: Some(create_snapshot(Utc::now())),
                refreshed_at: Utc::now(),
                source_key: stale_source,
                source_generation: 0,
            });
        }

        let _ = state
            .update_config(|config| {
                config.codex_root = source_b.clone();
            })
            .await
            .unwrap();
        let _ = state
            .update_config(|config| {
                config.codex_root = source_a.clone();
            })
            .await
            .unwrap();

        let value = state.get_usage(600).await.unwrap();
        assert!(value.is_none());
        let cached = state
            .snapshot
            .read()
            .await
            .clone()
            .expect("cache refreshed");
        assert_eq!(cached.source_generation, 2);
        assert_eq!(cached.source_key.codex_root, source_a);
    }

    #[tokio::test]
    async fn refresh_usage_returns_error_after_retry_exhaustion_with_generation_toggles() {
        let app_data_dir = unique_temp_path("codexu-tauri-retry-exhaustion");
        let state = Arc::new(AppState::new(app_data_dir));
        {
            let mut config = state.config.write().await;
            config.codex_root = state.app_data_dir.join("synthetic-codex");
            config.cache_dir = state.app_data_dir.join("synthetic-cache");
        }
        {
            let mut hook = state.refresh_attempt_hook.lock().await;
            *hook = Some(std::sync::Arc::new(|state, _attempt| {
                state.source_generation.fetch_add(1, Ordering::SeqCst);
            }));
        }

        let value = state.refresh_usage().await;
        assert!(value.is_err());
        assert!(value.unwrap_err().to_string().contains(
            "Failed to refresh dashboard snapshot due to concurrent config source changes"
        ));
        assert_eq!(state.refresh_call_count.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn failed_profile_mutation_or_save_keeps_memory_and_generation() {
        let dir = unique_temp_path("codexu-profile-transaction");
        std::fs::create_dir_all(&dir).unwrap();
        let state = Arc::new(AppState::new(dir.clone()));
        let before = serde_json::to_value(&*state.config.read().await).unwrap();
        let rejected = state
            .try_update_config(|config| {
                config
                    .profiles
                    .add("Candidate".into(), dir.join("linked"))?;
                anyhow::bail!("Synthetic validation failure");
            })
            .await;
        assert!(rejected.is_err());
        assert!(!dir.join("settings.json").exists());
        // A malformed prior file must never be silently replaced with defaults.
        std::fs::write(dir.join("settings.json"), b"corrupt").unwrap();
        let failed = state
            .try_update_config(|config| {
                config
                    .profiles
                    .add("Candidate".into(), dir.join("linked"))?;
                config.codex_root = dir.join("new-source");
                Ok(())
            })
            .await;
        assert!(failed.is_err());
        assert_eq!(
            serde_json::to_value(&*state.config.read().await).unwrap(),
            before
        );
        assert_eq!(state.source_generation.load(Ordering::SeqCst), 0);
        assert_eq!(
            std::fs::read(dir.join("settings.json")).unwrap(),
            b"corrupt"
        );
        std::fs::write(
            dir.join("settings.json"),
            br#"{"profiles":"invalid schema"}"#,
        )
        .unwrap();
        assert!(state
            .try_update_config(|config| {
                config.profiles.add("Candidate".into(), dir.join("linked"))
            })
            .await
            .is_err());
        assert_eq!(
            std::fs::read(dir.join("settings.json")).unwrap(),
            br#"{"profiles":"invalid schema"}"#
        );
        assert_eq!(
            serde_json::to_value(&*state.config.read().await).unwrap(),
            before
        );
        std::fs::remove_file(dir.join("settings.json")).unwrap();
        std::fs::remove_dir(dir).unwrap();
    }
}
