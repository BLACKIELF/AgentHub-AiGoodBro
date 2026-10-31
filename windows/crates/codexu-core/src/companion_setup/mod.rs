//! Explicit, bounded installation of the bundled companion Skill.
//! This module never executes a task, installs Python, or grants dispatch authority.
//! Native callers provide the pinned bundle and a verified platform adapter;
//! until that adapter exists, inspection reports unavailable and apply cannot write.
mod manifest;
mod store;
#[cfg(test)]
mod tests;

pub use manifest::BundlePin;
use serde::Serialize;
pub use store::SetupStore;

#[derive(Debug, thiserror::Error)]
#[error("{code}")]
pub struct Error {
    pub code: &'static str,
}
pub type Result<T> = std::result::Result<T, Error>;
fn fail(code: &'static str) -> Error {
    Error { code }
}

/// Native-only readiness, not a user approval token or a WebView-settable flag.
/// The implementation must hold/verify the selected Python and App bridge ABI.
/// Dispatch authorization remains with the separate native dispatch boundary.
pub trait PlatformAdapter {
    fn verify(&self, bundle_sha256: &str, abi: u32) -> Result<RuntimeBinding>;
}

/// Never serialized to the WebView: contains local executable paths.
pub struct RuntimeBinding {
    pub(crate) fingerprint: String,
    pub(crate) paths_json: String,
    pub(crate) python_line: String,
}
impl RuntimeBinding {
    /// `bridge_root` is the native app-data/companion-bridge-v1 directory,
    /// never an IPC selector. The adapter must verify its live private receiver
    /// and App-source binding; construction alone does not grant readiness.
    pub fn new(
        fingerprint: String,
        python: &std::path::Path,
        bridge_root: &std::path::Path,
        abi: u32,
    ) -> Result<Self> {
        if !manifest::is_hash(&fingerprint)
            || abi != 1
            || [python, bridge_root].iter().any(|path| {
                !path.is_absolute()
                    || path
                        .components()
                        .any(|p| matches!(p, std::path::Component::ParentDir))
            })
        {
            return Err(fail("companion_adapter_invalid"));
        }
        crate::accounts::storage::check_existing_owned_path(bridge_root)
            .map_err(|_| fail("companion_adapter_invalid"))?;
        if !bridge_root.is_dir() || bridge_root.canonicalize().ok().as_deref() != Some(bridge_root)
        {
            return Err(fail("companion_adapter_invalid"));
        }
        let value = python
            .to_str()
            .filter(|s| !s.contains(['\0', '\n', '\r']))
            .ok_or_else(|| fail("companion_adapter_invalid"))?;
        let root = bridge_root
            .to_str()
            .filter(|s| !s.contains(['\0', '\n', '\r']))
            .ok_or_else(|| fail("companion_adapter_invalid"))?;
        let paths_json = serde_json::to_string(&serde_json::json!({
            "schemaVersion": 1, "python": value, "adapterABI": abi,
            "bridgeRoot": root,
        }))
        .map_err(|_| fail("companion_adapter_invalid"))?
            + "\n";
        // Bind the generated configuration even if an adapter accidentally
        // reuses its capability fingerprint after a native root/path change.
        let fingerprint = manifest::hash(
            &serde_json::to_vec(&("companion-runtime-binding-v1", fingerprint, &paths_json))
                .map_err(|_| fail("companion_adapter_invalid"))?,
        );
        Ok(Self {
            fingerprint,
            paths_json,
            python_line: value.to_owned() + "\n",
        })
    }
}

#[derive(Serialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum State {
    Missing,
    Outdated,
    Conflict,
    Ready,
    Unavailable,
}
#[derive(Serialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum FileState {
    Missing,
    Same,
    Changed,
}
#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct FileStatus {
    pub path: String,
    pub status: FileState,
}
#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub state: State,
    pub issue_code: Option<&'static str>,
    pub files: Vec<FileStatus>,
    pub plan_id: Option<String>,
    pub backup_available: bool,
}
impl Snapshot {
    fn unavailable(code: &'static str) -> Self {
        Self {
            state: State::Unavailable,
            issue_code: Some(code),
            files: vec![],
            plan_id: None,
            backup_available: false,
        }
    }
}
