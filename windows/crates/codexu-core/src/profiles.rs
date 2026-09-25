//! Metadata-only catalog. Never reads, copies or replaces account credentials.
use crate::local_cli::LocalCliKind;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct LinkedProfile {
    pub id: u64,
    pub label: String,
    pub root: PathBuf,
    /// Platform this directory belongs to. Catalogs written before multi-platform
    /// support only ever contained Codex directories.
    #[serde(default)]
    pub kind: LocalCliKind,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ProfileCatalog {
    next_id: u64,
    pub entries: Vec<LinkedProfile>,
}

pub fn validate_label(label: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !label.trim().is_empty()
            && label == label.trim()
            && label.len() <= 64
            && !label.chars().any(|c| c.is_control() || "@/\\:".contains(c)),
        "Use a short alias, not an email address or file path"
    );
    Ok(())
}

pub fn same_root(left: &Path, right: &Path) -> bool {
    if cfg!(windows) {
        left.to_string_lossy().to_lowercase() == right.to_string_lossy().to_lowercase()
    } else {
        left == right
    }
}

/// Canonicalize an explicitly selected directory for one platform.
pub fn normalize_root_for(kind: LocalCliKind, root: &Path) -> anyhow::Result<PathBuf> {
    kind.normalize_directory(root)
}

pub fn normalize_root(root: &Path) -> anyhow::Result<PathBuf> {
    normalize_root_for(LocalCliKind::Codex, root)
}

impl ProfileCatalog {
    pub fn validate(&self) -> anyhow::Result<()> {
        anyhow::ensure!(self.entries.len() <= 50, "Too many linked profiles");
        for (index, entry) in self.entries.iter().enumerate() {
            validate_label(&entry.label)?;
            anyhow::ensure!(
                entry.id > 0 && entry.id <= self.next_id && entry.root.is_absolute(),
                "Invalid profile catalog"
            );
            anyhow::ensure!(
                !self.entries[..index]
                    .iter()
                    .any(|other| other.id == entry.id || same_root(&other.root, &entry.root)),
                "Duplicate profile catalog entry"
            );
        }
        Ok(())
    }
    pub fn add(&mut self, kind: LocalCliKind, label: String, root: PathBuf) -> anyhow::Result<()> {
        self.validate()?;
        validate_label(&label)?;
        anyhow::ensure!(root.is_absolute(), "Select an absolute account directory");
        anyhow::ensure!(self.entries.len() < 50, "Maximum 50 linked profiles");
        anyhow::ensure!(
            !self.entries.iter().any(|p| same_root(&p.root, &root)),
            "Directory already linked"
        );
        let id = self
            .next_id
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("Profile IDs exhausted"))?;
        self.entries.push(LinkedProfile {
            id,
            label,
            root,
            kind,
        });
        self.next_id = id;
        Ok(())
    }

    /// Platform of one linked directory, or `None` when it no longer exists.
    pub fn kind_of(&self, id: u64) -> Option<LocalCliKind> {
        self.entries.iter().find(|p| p.id == id).map(|p| p.kind)
    }
    pub fn get(&self, id: u64) -> anyhow::Result<&LinkedProfile> {
        self.validate()?;
        self.entries
            .iter()
            .find(|p| p.id == id)
            .ok_or_else(|| anyhow::anyhow!("Profile no longer exists"))
    }
    pub fn rename(&mut self, id: u64, label: String) -> anyhow::Result<()> {
        self.get(id)?;
        validate_label(&label)?;
        self.entries.iter_mut().find(|p| p.id == id).unwrap().label = label;
        Ok(())
    }
    pub fn move_one(&mut self, id: u64, delta: i8) -> anyhow::Result<()> {
        self.get(id)?;
        anyhow::ensure!(delta == -1 || delta == 1, "Move one position at a time");
        let index = self.entries.iter().position(|p| p.id == id).unwrap();
        let target = index as isize + delta as isize;
        anyhow::ensure!(
            target >= 0 && target < self.entries.len() as isize,
            "Already at edge"
        );
        self.entries.swap(index, target as usize);
        Ok(())
    }
    pub fn remove(&mut self, id: u64) -> anyhow::Result<()> {
        self.get(id)?;
        self.entries.retain(|p| p.id != id);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn order_duplicate_stale_id_and_round_trip() {
        let temp = tempfile::tempdir().unwrap();
        let mut c = ProfileCatalog::default();
        c.add(LocalCliKind::Codex, "First".into(), temp.path().join("one"))
            .unwrap();
        c.add(
            LocalCliKind::Codex,
            "Second".into(),
            temp.path().join("two"),
        )
        .unwrap();
        c.rename(1, "Renamed".into()).unwrap();
        assert_eq!(c.entries[0].id, 1);
        assert!(c
            .add(
                LocalCliKind::Codex,
                "Duplicate".into(),
                temp.path().join("one")
            )
            .is_err());
        assert!(c.rename(99, "Missing".into()).is_err());
        assert!(c.move_one(1, -1).is_err());
        c.move_one(1, 1).unwrap();
        assert_eq!(c.entries[1].id, 1);
        c.remove(1).unwrap();
        c.add(
            LocalCliKind::Codex,
            "Third".into(),
            temp.path().join("three"),
        )
        .unwrap();
        assert_eq!(c.entries[1].id, 3);
        let restored: ProfileCatalog =
            serde_json::from_str(&serde_json::to_string(&c).unwrap()).unwrap();
        assert_eq!(restored.entries, c.entries);
    }
    #[test]
    fn legacy_catalogs_upgrade_to_codex_and_new_platforms_persist() {
        let legacy: ProfileCatalog = serde_json::from_str(
            r#"{"next_id":1,"entries":[{"id":1,"label":"Legacy","root":"C:/tmp/one"}]}"#,
        )
        .unwrap();
        assert_eq!(legacy.entries[0].kind, LocalCliKind::Codex);

        let temp = tempfile::tempdir().unwrap();
        let mut c = ProfileCatalog::default();
        c.add(
            LocalCliKind::Antigravity,
            "Gravity".into(),
            temp.path().join("gravity"),
        )
        .unwrap();
        assert_eq!(c.kind_of(1), Some(LocalCliKind::Antigravity));
        assert_eq!(c.kind_of(99), None);
        let json = serde_json::to_string(&c).unwrap();
        assert!(json.contains("antigravity"));
        let restored: ProfileCatalog = serde_json::from_str(&json).unwrap();
        assert_eq!(restored.entries[0].kind, LocalCliKind::Antigravity);
    }

    #[test]
    fn never_touches_credentials_or_linked_directory() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("linked");
        std::fs::create_dir(&root).unwrap();
        let auth = root.join("auth.json");
        std::fs::write(&auth, b"synthetic-not-a-real-token").unwrap();
        let mut c = ProfileCatalog::default();
        c.add(
            LocalCliKind::Codex,
            "Alias".into(),
            normalize_root(&root).unwrap(),
        )
        .unwrap();
        c.rename(1, "New alias".into()).unwrap();
        c.remove(1).unwrap();
        assert_eq!(std::fs::read(auth).unwrap(), b"synthetic-not-a-real-token");
        assert!(root.is_dir());
        assert!(normalize_root(Path::new("relative")).is_err());
        for invalid in [
            "",
            " leading",
            "email@example.invalid",
            "C:\\private",
            "a/b",
            "line\nbreak",
        ] {
            assert!(validate_label(invalid).is_err());
        }
    }
}
