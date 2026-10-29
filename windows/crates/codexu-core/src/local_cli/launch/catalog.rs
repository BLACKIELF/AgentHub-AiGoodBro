use super::*;
use crate::{accounts::storage, profiles::ProfileCatalog};
/// Rollback owns only newly-created empty directories and its own marker.
/// A concurrent writer's new content is never recursively removed.
pub struct PreparedProfile {
    root: PathBuf,
    owned: Vec<PathBuf>,
    marker: PathBuf,
    marker_bytes: Vec<u8>,
    committed: bool,
}
impl PreparedProfile {
    pub fn create(
        app_data: &Path,
        kind: LocalCliKind,
        edition: Option<Edition>,
        label: &str,
        catalog: &ProfileCatalog,
    ) -> Result<Self> {
        if !matches!(
            kind,
            LocalCliKind::Grok
                | LocalCliKind::OpenCode
                | LocalCliKind::Kimi
                | LocalCliKind::WorkBuddy
        ) || (edition.is_some() && kind != LocalCliKind::WorkBuddy)
        {
            return Err(fail("platform_not_supported"));
        }
        crate::profiles::validate_label(label).map_err(|_| fail("invalid_label"))?;
        catalog
            .validate()
            .map_err(|_| fail("settings_unavailable"))?;
        if catalog.entries.len() >= 50 {
            return Err(fail("account_limit"));
        }
        if catalog
            .entries
            .iter()
            .any(|r| r.kind == kind && r.label.eq_ignore_ascii_case(label))
        {
            return Err(fail("duplicate_label"));
        }
        check_path(app_data)?;
        let parent = app_data.join("local-cli-profiles").join(kind.id());
        storage::secure_directory(&parent).map_err(|_| fail("profile_create_failed"))?;
        let slot =
            parent.join(crate::accounts::nonce().map_err(|_| fail("profile_create_failed"))?);
        storage::create_private_directory(&slot).map_err(|_| fail("profile_create_failed"))?;
        let root = match kind {
            LocalCliKind::OpenCode => slot.join("data/opencode"),
            LocalCliKind::WorkBuddy => slot.join(edition.unwrap_or_default().directory()),
            _ => slot.clone(),
        };
        let marker = root.join(".aigoodbro-profile.json");
        let mut result = Self {
            root,
            owned: vec![slot.clone()],
            marker,
            marker_bytes: vec![],
            committed: false,
        };
        let relatives: Vec<&str> = match kind {
            LocalCliKind::OpenCode => vec!["data", "data/opencode", "config", "state", "cache"],
            LocalCliKind::WorkBuddy => vec![edition.unwrap_or_default().directory()],
            _ => vec![],
        };
        for relative in relatives {
            let directory = slot.join(relative);
            storage::create_private_directory(&directory)
                .map_err(|_| fail("profile_create_failed"))?;
            result.owned.push(directory);
        }
        let marker = serde_json::to_vec(&serde_json::json!({"schema":1,"platform":kind.id()}))
            .map_err(|_| fail("profile_create_failed"))?;
        storage::atomic_write(&result.marker, &marker)
            .map_err(|_| fail("profile_create_failed"))?;
        result.marker_bytes = marker;
        Ok(result)
    }
    pub fn root(&self) -> &Path {
        &self.root
    }
    pub fn keep(mut self) {
        self.committed = true;
    }
}
impl Drop for PreparedProfile {
    fn drop(&mut self) {
        if self.committed {
            return;
        }
        if check_path(&self.marker).is_ok()
            && std::fs::read(&self.marker).ok().as_deref() == Some(result_marker(self))
        {
            let _ = std::fs::remove_file(&self.marker);
        }
        for dir in self.owned.iter().rev() {
            if check_path(dir).is_ok() {
                let _ = std::fs::remove_dir(dir);
            }
        }
    }
}
fn result_marker(profile: &PreparedProfile) -> &[u8] {
    &profile.marker_bytes
}
