use super::model::Preferences;
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Stored {
    schema_version: u8,
    preferences: Preferences,
}
pub struct Store {
    file: PathBuf,
}
impl Store {
    pub fn new(root: &Path) -> Result<Self, &'static str> {
        if !root.is_absolute() {
            return Err("compact_preferences_unavailable");
        }
        fs::create_dir_all(root).map_err(|_| "compact_preferences_unavailable")?;
        Ok(Self {
            file: root.join("compact-ui-v1.json"),
        })
    }
    pub fn load(&self) -> Result<Preferences, &'static str> {
        let metadata = match fs::symlink_metadata(&self.file) {
            Ok(value) => value,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(Preferences::default())
            }
            Err(_) => return Err("compact_preferences_unavailable"),
        };
        if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.len() > 65536 {
            return Err("compact_preferences_invalid");
        }
        let bytes = fs::read(&self.file).map_err(|_| "compact_preferences_unavailable")?;
        let stored: Stored =
            serde_json::from_slice(&bytes).map_err(|_| "compact_preferences_invalid")?;
        if stored.schema_version != 1 {
            return Err("compact_preferences_invalid");
        }
        stored.preferences.validate()?;
        Ok(stored.preferences)
    }
    pub fn save(&self, preferences: &Preferences) -> Result<(), &'static str> {
        preferences.validate()?;
        if fs::symlink_metadata(&self.file)
            .is_ok_and(|metadata| !metadata.is_file() || metadata.file_type().is_symlink())
        {
            return Err("compact_preferences_unavailable");
        }
        let bytes = serde_json::to_vec(&Stored {
            schema_version: 1,
            preferences: preferences.clone(),
        })
        .map_err(|_| "compact_preferences_invalid")?;
        if bytes.len() > 65536 {
            return Err("compact_preferences_invalid");
        }
        let mut temporary = tempfile::NamedTempFile::new_in(
            self.file
                .parent()
                .ok_or("compact_preferences_unavailable")?,
        )
        .map_err(|_| "compact_preferences_unavailable")?;
        temporary
            .write_all(&bytes)
            .and_then(|_| temporary.as_file().sync_all())
            .map_err(|_| "compact_preferences_unavailable")?;
        temporary
            .persist(&self.file)
            .map_err(|_| "compact_preferences_unavailable")?;
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn independent_atomic_preferences_preserve_existing_app_config() {
        let root = tempfile::tempdir().unwrap();
        let other = root.path().join("config.json");
        fs::write(&other, b"existing-app-settings").unwrap();
        let store = Store::new(root.path()).unwrap();
        let mut prefs = store.load().unwrap();
        prefs.items = Some(vec![]);
        store.save(&prefs).unwrap();
        assert_eq!(store.load().unwrap(), prefs);
        assert_eq!(fs::read(other).unwrap(), b"existing-app-settings");
    }
    #[test]
    fn corrupt_or_future_preferences_do_not_become_a_successful_default() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::new(root.path()).unwrap();
        fs::write(&store.file, b"corrupt").unwrap();
        assert!(store.load().is_err());
        assert_eq!(fs::read(&store.file).unwrap(), b"corrupt");
    }
}
