//! Native-only evidence for a live official system daemon. This is not a
//! credential, quota freshness proof, process-exit proof or WebView DTO.
use std::path::{Path, PathBuf};

#[derive(Clone, PartialEq, Eq)]
pub struct ActiveSystemScope {
    home: PathBuf,
    profile: String,
    identity: String,
    generation: String,
    auth_digest: String,
    config_digest: String,
    established_at: u64,
}
impl ActiveSystemScope {
    pub(super) fn new(
        home: PathBuf,
        profile: String,
        identity: String,
        generation: String,
        auth_digest: String,
        config_digest: String,
        established_at: u64,
    ) -> Self {
        Self {
            home,
            profile,
            identity,
            generation,
            auth_digest,
            config_digest,
            established_at,
        }
    }
    pub fn canonical_home(&self) -> &Path {
        &self.home
    }
    pub fn profile_id(&self) -> &str {
        &self.profile
    }
    pub fn identity_hash(&self) -> &str {
        &self.identity
    }
    pub fn credential_generation(&self) -> &str {
        &self.generation
    }
    pub fn auth_digest(&self) -> &str {
        &self.auth_digest
    }
    pub fn established_at_unix_ms(&self) -> u64 {
        self.established_at
    }
}
