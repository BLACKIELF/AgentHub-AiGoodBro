//! Manual per-directory quota reads, independent of local transcript availability.
//! No credentials, raw account metadata or source paths cross the WebView boundary.
use crate::app_state::AppState;
use codexu_core::profiles::normalize_root;
use codexu_core::readers::codex_app_server::{
    read_codex_quota_for_home, CodexAppServerQuotaSnapshot,
};
use std::{future::Future, path::PathBuf, sync::Arc};
use tauri::State;

const READ_FAILED: &str = "Quota unavailable; check Codex CLI, directory login and retry";
const SOURCE_CHANGED: &str = "Linked directory changed or was removed; result discarded";

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "snake_case")]
enum WindowKind {
    FiveHour,
    SevenDay,
    Monthly,
}

#[derive(Debug, serde::Serialize)]
struct QuotaWindowDto {
    kind: WindowKind,
    remaining_percent: f64,
    resets_at: Option<i64>,
}

#[derive(Debug, serde::Serialize)]
pub struct ProfileQuotaDto {
    profile_id: String,
    checked_at: i64,
    windows: Vec<QuotaWindowDto>,
}

fn project(id: u64, quota: CodexAppServerQuotaSnapshot) -> Result<ProfileQuotaDto, String> {
    if !quota.quota_read_succeeded {
        return Err(READ_FAILED.into());
    }
    let mut windows = Vec::new();
    for (kind, window) in [
        (WindowKind::FiveHour, quota.five_hour_quota),
        (WindowKind::SevenDay, quota.seven_day_quota),
        (WindowKind::Monthly, quota.monthly_quota),
    ] {
        if let Some(window) = window {
            // Reject malformed values instead of making them look like 0% or 100%.
            if !window.used_percent.is_finite() || !(0.0..=100.0).contains(&window.used_percent) {
                return Err(READ_FAILED.into());
            }
            windows.push(QuotaWindowDto {
                kind,
                remaining_percent: 100.0 - window.used_percent,
                resets_at: window.resets_at.map(|date| date.timestamp_millis()),
            });
        }
    }
    if windows.is_empty() {
        return Err(READ_FAILED.into());
    }
    Ok(ProfileQuotaDto {
        profile_id: id.to_string(),
        checked_at: chrono::Utc::now().timestamp_millis(),
        windows,
    })
}

async fn check_root(root: PathBuf) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        normalize_root(&root).is_ok_and(|canonical| canonical == root)
    })
    .await
    .map_err(|_| SOURCE_CHANGED.to_string())?
    .then_some(())
    .ok_or_else(|| SOURCE_CHANGED.to_string())
}

async fn read_with<F, Fut>(
    state: &Arc<AppState>,
    id: u64,
    reader: F,
) -> Result<ProfileQuotaDto, String>
where
    F: FnOnce(PathBuf) -> Fut,
    Fut: Future<Output = anyhow::Result<CodexAppServerQuotaSnapshot>>,
{
    let _permit = state
        .profile_quota_slots
        .try_acquire()
        .map_err(|_| "Two quota reads are already running; retry after they finish".to_string())?;
    let root = state
        .config
        .read()
        .await
        .profiles
        .get(id)
        .map_err(|_| SOURCE_CHANGED.to_string())?
        .root
        .clone();
    check_root(root.clone()).await?;
    // Only explicit user clicks reach this reader. No snapshot/usage scan is required.
    let quota = reader(root.clone())
        .await
        .map_err(|_| READ_FAILED.to_string())?;
    check_root(root.clone()).await?;
    let config = state.config.read().await;
    if config.profiles.get(id).map(|profile| &profile.root).ok() != Some(&root) {
        return Err(SOURCE_CHANGED.into());
    }
    project(id, quota)
}

#[tauri::command]
pub async fn read_profile_quota(
    state: State<'_, Arc<AppState>>,
    id: String,
) -> Result<ProfileQuotaDto, String> {
    let id = id.parse::<u64>().map_err(|_| SOURCE_CHANGED.to_string())?;
    read_with(&state, id, |root| async move {
        read_codex_quota_for_home(&root).await
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use codexu_core::models::RateWindow;
    use std::sync::atomic::{AtomicU64, Ordering};

    fn quota(used: f64) -> CodexAppServerQuotaSnapshot {
        let mut value = CodexAppServerQuotaSnapshot::unavailable();
        value.quota_read_succeeded = true;
        value.seven_day_quota = Some(RateWindow {
            used_percent: used,
            window_duration_mins: Some(10080),
            resets_at: None,
        });
        value
    }

    struct Fixture {
        dir: PathBuf,
        state: Arc<AppState>,
        roots: Vec<PathBuf>,
    }
    impl Fixture {
        async fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let dir = std::env::temp_dir().join(format!(
                "codexu-row-quota-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::SeqCst)
            ));
            let state = Arc::new(AppState::new(dir.join("settings")));
            let mut roots = Vec::new();
            for name in ["one", "two"] {
                let root = dir.join(name);
                std::fs::create_dir_all(&root).unwrap();
                // Synthetic auth marker, deliberately no sessions or state DB.
                std::fs::write(root.join("auth.json"), b"synthetic marker").unwrap();
                let root = normalize_root(&root).unwrap();
                state
                    .config
                    .write()
                    .await
                    .profiles
                    .add(name.into(), root.clone())
                    .unwrap();
                roots.push(root);
            }
            Self { dir, state, roots }
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            // Only this fixture's named files are removed; no recursive delete.
            for root in &self.roots {
                let _ = std::fs::remove_file(root.join("auth.json"));
                let _ = std::fs::remove_dir(root);
            }
            let _ = std::fs::remove_dir(&self.dir);
        }
    }

    #[test]
    fn projection_omits_missing_windows_and_raw_metadata() {
        let mut value = quota(41.0);
        value.limit_id = Some("synthetic-private-metadata".into());
        let dto = project(7, value).unwrap();
        let json = serde_json::to_value(dto).unwrap();
        assert_eq!(json["profile_id"], "7");
        assert_eq!(json["windows"].as_array().unwrap().len(), 1);
        assert_eq!(json["windows"][0]["kind"], "seven_day");
        assert_eq!(json["windows"][0]["remaining_percent"], 59.0);
        assert_eq!(json.as_object().unwrap().len(), 3);
        assert!(!json.to_string().contains("synthetic-private"));
        assert!(project(7, CodexAppServerQuotaSnapshot::unavailable()).is_err());
        let mut no_windows = quota(0.0);
        no_windows.seven_day_quota = None;
        assert!(project(7, no_windows).is_err());
        for used in [-1.0, 101.0, f64::NAN, f64::INFINITY] {
            assert!(project(7, quota(used)).is_err());
        }
        assert_eq!(
            project(7, quota(100.0)).unwrap().windows[0].remaining_percent,
            0.0
        );
    }

    #[tokio::test]
    async fn reads_correct_home_without_sessions_or_changing_active_source() {
        let fixture = Fixture::new().await;
        let original = fixture.state.config.read().await.codex_root.clone();
        for id in [1, 2] {
            let expected = fixture.roots[id as usize - 1].clone();
            let result = read_with(&fixture.state, id, |root| async move {
                assert_eq!(root, expected);
                assert!(!root.join("sessions").exists());
                Ok(quota(id as f64 * 20.0))
            })
            .await
            .unwrap();
            assert_eq!(result.profile_id, id.to_string());
            assert_eq!(
                result.windows[0].remaining_percent,
                100.0 - id as f64 * 20.0
            );
        }
        assert_eq!(fixture.state.config.read().await.codex_root, original);
        assert!(!fixture.dir.join("settings/settings.json").exists());
    }

    #[tokio::test]
    async fn removed_or_retargeted_profile_discards_late_result() {
        let fixture = Fixture::new().await;
        let state = fixture.state.clone();
        let removed = read_with(&fixture.state, 1, |_| async {
            state.config.write().await.profiles.remove(1).unwrap();
            Ok(quota(1.0))
        })
        .await;
        assert_eq!(removed.unwrap_err(), SOURCE_CHANGED);
        let changed = read_with(&fixture.state, 2, |_| async {
            state.config.write().await.profiles.entries[0].root = fixture.roots[0].clone();
            Ok(quota(1.0))
        })
        .await;
        assert_eq!(changed.unwrap_err(), SOURCE_CHANGED);
    }

    #[tokio::test]
    async fn limits_concurrency_and_releases_permits_on_errors() {
        let fixture = Fixture::new().await;
        let permit = fixture
            .state
            .profile_quota_slots
            .acquire_many(2)
            .await
            .unwrap();
        assert!(
            read_with(&fixture.state, 1, |_| async { panic!("Must not start") })
                .await
                .is_err()
        );
        drop(permit);
        assert_eq!(
            read_with(&fixture.state, 1, |_| async {
                anyhow::bail!("Synthetic private OS error")
            })
            .await
            .unwrap_err(),
            READ_FAILED
        );
        assert_eq!(fixture.state.profile_quota_slots.available_permits(), 2);
        assert!(
            read_with(&fixture.state, 999, |_| async { panic!("Unknown ID") })
                .await
                .is_err()
        );
        assert_eq!(fixture.state.profile_quota_slots.available_permits(), 2);
    }

    #[tokio::test]
    async fn cancelling_a_read_releases_its_slot() {
        let fixture = Fixture::new().await;
        let state = fixture.state.clone();
        let (started, receiver) = tokio::sync::oneshot::channel();
        let task = tokio::spawn(async move {
            read_with(&state, 1, |_| async move {
                let _ = started.send(());
                std::future::pending().await
            })
            .await
        });
        tokio::time::timeout(std::time::Duration::from_secs(5), receiver)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(fixture.state.profile_quota_slots.available_permits(), 1);
        task.abort();
        assert!(task.await.unwrap_err().is_cancelled());
        assert_eq!(fixture.state.profile_quota_slots.available_permits(), 2);
    }
}
