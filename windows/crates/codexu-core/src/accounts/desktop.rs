use super::{fail, AccountResult};
use std::path::{Path, PathBuf};

/// Native-only receipt, never serialized into a browser command return value.
pub struct DesktopHomeCleanup {
    pub retained_home: Option<PathBuf>,
}

/// Persistent private managed Desktop home. Its lifecycle belongs to the held
/// owned Job plus durable writer claim, never to a temporary directory Drop.
/// Deliberately not Debug/Serialize and never a standalone admission lease.
pub struct ProxyDesktopHome {
    path: PathBuf,
    profile_id: String,
    identity_hash: String,
    token_generation: String,
    writer_id: String,
    pub(crate) finalized: bool,
    pub(crate) completed: bool,
}
impl ProxyDesktopHome {
    pub(crate) fn new(
        path: PathBuf,
        profile_id: String,
        identity_hash: String,
        token_generation: String,
        writer_id: String,
    ) -> Self {
        Self {
            path,
            profile_id,
            identity_hash,
            token_generation,
            writer_id,
            finalized: false,
            completed: false,
        }
    }
    pub fn path(&self) -> &Path {
        &self.path
    }
    pub fn profile_id(&self) -> &str {
        &self.profile_id
    }
    pub fn identity_hash(&self) -> &str {
        &self.identity_hash
    }
    pub fn token_generation(&self) -> &str {
        &self.token_generation
    }
    pub(crate) fn writer_id(&self) -> &str {
        &self.writer_id
    }
    /// Only the per-run local proxy key is disposable. Account auth, config and
    /// every newly written rollout remain for a future verified managed open.
    /// The caller first confirms Job exit and imports the sole writer's auth.
    pub fn cleanup_after_confirmed_exit(&mut self) -> AccountResult<DesktopHomeCleanup> {
        let path = self.path.join("desktop-connection.json");
        super::storage::ensure_no_links(&path)?;
        match std::fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.is_file() => {
                std::fs::remove_file(&path).map_err(|_| fail("desktop_home_cleanup_failed"))?
            }
            Ok(_) => return Err(fail("desktop_home_cleanup_failed")),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
            Err(_) => return Err(fail("desktop_home_cleanup_failed")),
        }
        Ok(DesktopHomeCleanup {
            retained_home: Some(self.path.clone()),
        })
    }
}
