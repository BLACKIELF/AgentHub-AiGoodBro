//! State isolation for the existing task-owned background capture entry point.
//! Windows Known Folders do not follow per-process APPDATA overrides.
use crate::app_state::AppConfig;
use std::ffi::OsString;
use std::path::{Component, Path, PathBuf};

pub const ROOT_ENV: &str = "AIGOODBRO_NATIVE_CAPTURE_ROOT";

fn regular_directory_tree(path: &Path) -> bool {
    path.ancestors().all(|ancestor| {
        let Ok(metadata) = std::fs::symlink_metadata(ancestor) else {
            return false;
        };
        #[cfg(windows)]
        {
            use std::os::windows::fs::MetadataExt;
            if metadata.file_attributes() & 0x400 != 0 {
                return false;
            }
        }
        metadata.is_dir() && !metadata.file_type().is_symlink()
    })
}

fn valid_root(path: &Path) -> bool {
    if !path.is_absolute()
        || path
            .components()
            .any(|part| matches!(part, Component::ParentDir))
        || path.file_name().is_none_or(|name| name != "fullscreen")
        || path
            .parent()
            .and_then(Path::file_name)
            .is_none_or(|name| name != "runtime")
    {
        return false;
    }
    #[cfg(windows)]
    if !matches!(path.components().next(), Some(Component::Prefix(prefix))
        if matches!(prefix.kind(), std::path::Prefix::Disk(_) | std::path::Prefix::VerbatimDisk(_)))
    {
        return false;
    }
    path.ancestors().skip(3).any(|ancestor| {
        ancestor
            .file_name()
            .is_some_and(|name| name == "windows-visual-captures")
            && ancestor
                .parent()
                .and_then(Path::file_name)
                .is_some_and(|name| name == ".local-artifacts")
    }) && regular_directory_tree(path)
}

pub fn initialize(
    background_capture: bool,
    root: Option<OsString>,
) -> Result<Option<PathBuf>, &'static str> {
    // Normal launches retain their existing Known Folder behavior, even if a
    // parent process happens to carry this capture-only environment variable.
    if !background_capture {
        return Ok(None);
    }
    let root = PathBuf::from(root.ok_or("capture_storage_root_required")?);
    if !valid_root(&root) {
        return Err("capture_storage_root_invalid");
    }
    let root = root
        .canonicalize()
        .map_err(|_| "capture_storage_root_invalid")?;
    let state = root.join("app-state");
    // Never reopen or reset a prior run's settings. The capture driver creates
    // the surrounding runtime tree; this process must claim a new state leaf.
    std::fs::create_dir(&state).map_err(|_| "capture_storage_state_not_fresh")?;
    if !regular_directory_tree(&state) || state.canonicalize().ok().as_ref() != Some(&state) {
        return Err("capture_storage_root_changed");
    }
    let mut config = AppConfig::default();
    config.codex_root = state.join("codex");
    config.cache_dir = state.join("cache");
    std::fs::create_dir(&config.codex_root).map_err(|_| "capture_storage_codex_unavailable")?;
    std::fs::create_dir(&config.cache_dir).map_err(|_| "capture_storage_cache_unavailable")?;
    config
        .save(&state)
        .map_err(|_| "capture_storage_settings_unavailable")?;
    Ok(Some(state))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn root(base: &Path, run: &str) -> PathBuf {
        let path = base
            .join(".local-artifacts/windows-visual-captures")
            .join(run)
            .join("runtime/fullscreen");
        std::fs::create_dir_all(&path).unwrap();
        path.canonicalize().unwrap()
    }

    #[test]
    fn independent_roots_keep_deferred_onboarding_and_cache_separate() {
        let temporary = tempfile::tempdir().unwrap();
        let first_root = root(temporary.path(), "first");
        let first = initialize(true, Some(first_root.clone().into_os_string()))
            .unwrap()
            .unwrap();
        let mut saved = serde_json::to_value(AppConfig::load(&first)).unwrap();
        saved["installation_onboarding"] = serde_json::json!({
            "eventId": "files:v1:1:2:3:4:5:6", "status": "deferred", "audience": null
        });
        serde_json::from_value::<AppConfig>(saved)
            .unwrap()
            .save(&first)
            .unwrap();
        let first_bytes = std::fs::read(first.join("settings.json")).unwrap();
        let second_root = root(temporary.path(), "second");
        let second = initialize(true, Some(second_root.into_os_string()))
            .unwrap()
            .unwrap();
        let one = AppConfig::load(&first);
        let two = AppConfig::load(&second);
        assert_eq!(
            serde_json::to_value(one.installation_onboarding).unwrap()["status"],
            "deferred"
        );
        assert_eq!(
            serde_json::to_value(two.installation_onboarding).unwrap()["status"],
            "pending"
        );
        assert_eq!(one.cache_dir, first.join("cache"));
        assert_eq!(two.cache_dir, second.join("cache"));
        assert_ne!(one.cache_dir, two.cache_dir);
        assert_eq!(one.codex_root, first.join("codex"));
        assert_eq!(two.codex_root, second.join("codex"));
        assert_ne!(one.codex_root, two.codex_root);
        assert_eq!(std::fs::read_dir(one.codex_root).unwrap().count(), 0);
        assert_eq!(std::fs::read_dir(two.codex_root).unwrap().count(), 0);
        assert_eq!(
            std::fs::read(first.join("settings.json")).unwrap(),
            first_bytes
        );
        assert_eq!(
            initialize(true, Some(first_root.into_os_string())),
            Err("capture_storage_state_not_fresh")
        );
        assert_eq!(
            std::fs::read(first.join("settings.json")).unwrap(),
            first_bytes
        );
    }

    #[test]
    fn ordinary_launch_ignores_capture_root_and_capture_requires_it() {
        let temporary = tempfile::tempdir().unwrap();
        let path = root(temporary.path(), "ordinary");
        assert_eq!(
            initialize(false, Some(path.clone().into_os_string())),
            Ok(None)
        );
        assert!(!path.join("app-state").exists());
        assert_eq!(initialize(true, None), Err("capture_storage_root_required"));
    }

    #[test]
    fn invalid_or_existing_paths_never_overwrite_settings() {
        let temporary = tempfile::tempdir().unwrap();
        let outside = temporary.path().canonicalize().unwrap();
        assert_eq!(
            initialize(true, Some(outside.clone().into_os_string())),
            Err("capture_storage_root_invalid")
        );
        assert_eq!(
            initialize(true, Some("runtime/fullscreen".into())),
            Err("capture_storage_root_invalid")
        );
        let path = root(&outside, "invalid");
        // PathBuf::push normalizes .. for Windows verbatim paths returned by
        // canonicalize. Build raw input so this tests the rejection boundary.
        let mut traversal = path.as_os_str().to_os_string();
        traversal.push(std::path::MAIN_SEPARATOR_STR);
        traversal.push("..");
        traversal.push(std::path::MAIN_SEPARATOR_STR);
        traversal.push("fullscreen");
        assert!(Path::new(&traversal)
            .components()
            .any(|part| matches!(part, Component::ParentDir)));
        assert!(!path.join("app-state").exists());
        assert_eq!(
            initialize(true, Some(traversal)),
            Err("capture_storage_root_invalid")
        );
        assert!(!path.join("app-state").exists());
        std::fs::write(path.join("app-state"), b"preserve").unwrap();
        assert_eq!(
            initialize(true, Some(path.clone().into_os_string())),
            Err("capture_storage_state_not_fresh")
        );
        assert_eq!(std::fs::read(path.join("app-state")).unwrap(), b"preserve");
    }

    #[cfg(unix)]
    #[test]
    fn redirected_runtime_root_is_rejected_without_writing_the_target() {
        let temporary = tempfile::tempdir().unwrap();
        let path = root(temporary.path(), "redirect");
        let target = temporary.path().join("protected");
        std::fs::create_dir(&target).unwrap();
        std::fs::remove_dir(&path).unwrap();
        std::os::unix::fs::symlink(&target, &path).unwrap();
        assert_eq!(
            initialize(true, Some(path.into_os_string())),
            Err("capture_storage_root_invalid")
        );
        assert_eq!(std::fs::read_dir(target).unwrap().count(), 0);
    }
}
