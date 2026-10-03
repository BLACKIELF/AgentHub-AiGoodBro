use std::io::{Read, Write};
use std::path::Path;

/// Same-directory atomic replacement; never truncate an existing settings file.
pub fn write_json(
    path: &Path,
    bytes: &[u8],
    validate_prior: impl FnOnce(&[u8]) -> anyhow::Result<()>,
) -> anyhow::Result<()> {
    anyhow::ensure!(bytes.len() <= 1024 * 1024, "Settings exceed size limit");
    let _: serde_json::Value = serde_json::from_slice(bytes)?;
    match std::fs::symlink_metadata(path) {
        Ok(meta) => {
            anyhow::ensure!(
                meta.is_file() && !meta.file_type().is_symlink() && meta.len() <= 1024 * 1024,
                "Invalid settings file"
            );
            let mut prior = Vec::new();
            std::fs::File::open(path)?
                .take(1024 * 1024 + 1)
                .read_to_end(&mut prior)?;
            anyhow::ensure!(prior.len() <= 1024 * 1024, "Settings exceed size limit");
            let _: serde_json::Value = serde_json::from_slice(&prior)?;
            validate_prior(&prior)?;
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    let parent = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("Missing settings directory"))?;
    std::fs::create_dir_all(parent)?;
    let mut temporary = tempfile::NamedTempFile::new_in(parent)?;
    temporary.write_all(bytes)?;
    temporary.as_file().sync_all()?;
    temporary
        .persist(path)
        .map_err(|_| anyhow::anyhow!("Atomic settings replacement failed"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejected_writes_preserve_prior_bytes() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("settings.json");
        write_json(&path, br#"{"old":true}"#, |_| Ok(())).unwrap();
        assert!(write_json(&path, b"invalid", |_| Ok(())).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), br#"{"old":true}"#);
        assert!(write_json(&path, br#"{"new":true}"#, |_| anyhow::bail!(
            "Invalid schema"
        ))
        .is_err());
        assert_eq!(std::fs::read(&path).unwrap(), br#"{"old":true}"#);
        write_json(&path, br#"{"new":true}"#, |_| Ok(())).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), br#"{"new":true}"#);
        std::fs::write(&path, b"corrupt").unwrap();
        assert!(write_json(&path, br#"{}"#, |_| Ok(())).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"corrupt");
    }
}
