use super::*;
use crate::accounts::storage;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    path::{Path, PathBuf},
};

pub(super) const MAX_FILE: usize = 256 * 1024;
pub(super) const MAX_TOTAL: usize = 1024 * 1024;
pub(super) const BEGIN: &str = "<!-- next-runtime-setup:start -->";
pub(super) const END: &str = "<!-- next-runtime-setup:end -->";
// Semantic slots are fixed. The native, hash-pinned manifest determines the
// Windows launcher's filename; this does not copy the Darwin shell launcher.
pub(super) const SLOTS: &[(&str, &str, bool)] = &[
    ("skill", "SKILL.md", false),
    ("guide", "使用说明.md", false),
    ("launcher", "", true),
    ("coordination", "references/coordination.md", false),
    ("brief", "references/dispatch-brief.md", false),
    ("validation", "references/cli-validation.md", false),
    ("grok", "references/grok-cli.md", false),
    ("jev", "references/jev-coordination.md", true),
    ("update", "references/update-0927v1.md", true),
    ("local-runtime", "references/local-runtime.md", false),
    ("runtime-setup", "references/runtime-setup.md", true),
    ("luna", "references/luna-presets.md", true),
    ("onboarding", "references/onboarding-login.md", true),
    ("activity", "scripts/next_dispatch_activity.py", true),
    ("preflight", "scripts/next_dispatch_preflight.py", true),
    ("invocation", "scripts/next_dispatch_invocation.py", true),
];

pub struct BundlePin {
    pub(crate) root: PathBuf,
    pub(crate) sha256: String,
}
impl BundlePin {
    /// Native composition may compare this compiled pin; payload verification
    /// remains in Bundle::load on every inspection and install stage.
    pub fn sha256(&self) -> &str {
        &self.sha256
    }
    /// Only the native resource resolver may construct this from compiled pins.
    pub fn new(root: PathBuf, sha256: String) -> Result<Self> {
        if !root.is_absolute() || !is_hash(&sha256) {
            return Err(fail("companion_bundle_invalid"));
        }
        storage::ensure_no_links(&root).map_err(|_| fail("companion_bundle_invalid"))?;
        Ok(Self { root, sha256 })
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Manifest {
    schema_version: u8,
    platform: String,
    #[serde(rename = "adapterABI")]
    adapter_abi: u32,
    managed_note: String,
    files: Vec<Entry>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Entry {
    slot: String,
    path: String,
    sha256: String,
}
pub(super) struct Payload {
    pub path: String,
    pub text: String,
    pub managed: bool,
}
pub(super) struct Bundle {
    pub abi: u32,
    pub note: String,
    pub files: Vec<Payload>,
}
pub(super) fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
pub(super) fn is_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
pub(super) fn safe_relative(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && !value.contains(['\\', ':', '\0'])
        && value.split('/').all(|p| {
            !p.is_empty()
                && p != "."
                && p != ".."
                && !p.ends_with(['.', ' '])
                && !p.chars().any(char::is_control)
        })
}
fn text(path: &Path, max: usize) -> Result<String> {
    let bytes = storage::read_bound_optional(path, max, false)
        .map_err(|_| fail("companion_bundle_invalid"))?
        .ok_or_else(|| fail("companion_bundle_missing"))?;
    String::from_utf8(bytes).map_err(|_| fail("companion_bundle_invalid"))
}
impl Bundle {
    pub fn load(pin: &BundlePin) -> Result<Self> {
        let raw = text(&pin.root.join("manifest.json"), 32768)?;
        if hash(raw.as_bytes()) != pin.sha256 {
            return Err(fail("companion_bundle_changed"));
        }
        let m: Manifest =
            serde_json::from_str(&raw).map_err(|_| fail("companion_bundle_invalid"))?;
        if m.schema_version != 1
            || m.platform != "windows"
            || m.adapter_abi != 1
            || m.files.len() != SLOTS.len()
            || m.managed_note.len() > 8192
            || m.managed_note.contains('\0')
            || !m.managed_note.starts_with(BEGIN)
            || !m.managed_note.ends_with(END)
            || m.managed_note.matches(BEGIN).count() != 1
            || m.managed_note.matches(END).count() != 1
        {
            return Err(fail("companion_bundle_invalid"));
        }
        let mut slots = BTreeSet::new();
        let mut paths = BTreeSet::new();
        let mut files = vec![];
        let mut total = 0;
        for e in m.files {
            let spec = SLOTS
                .iter()
                .find(|x| x.0 == e.slot)
                .ok_or_else(|| fail("companion_bundle_invalid"))?;
            let launcher = e.slot == "launcher"
                && e.path.starts_with("bin/")
                && e.path.split('/').count() == 2
                && e.path
                    .trim_start_matches("bin/")
                    .starts_with("next-dispatch");
            if !safe_relative(&e.path)
                || (!launcher && e.path != spec.1)
                || !is_hash(&e.sha256)
                || !slots.insert(e.slot)
                || !paths.insert(e.path.to_lowercase())
            {
                return Err(fail("companion_bundle_invalid"));
            }
            let value = text(&pin.root.join(&e.path), MAX_FILE)?;
            total += value.len();
            if total > MAX_TOTAL || value.contains('\0') || hash(value.as_bytes()) != e.sha256 {
                return Err(fail("companion_bundle_changed"));
            }
            files.push(Payload {
                path: e.path,
                text: value,
                managed: spec.2,
            });
        }
        files.sort_by(|a, b| a.path.cmp(&b.path));
        Ok(Self {
            abi: m.adapter_abi,
            note: m.managed_note,
            files,
        })
    }
}
pub(super) fn managed_skill(old: &str, note: &str) -> Result<String> {
    let b = old.matches(BEGIN).count();
    let e = old.matches(END).count();
    if b != e || b > 1 {
        return Err(fail("companion_managed_section_conflict"));
    }
    if b == 0 {
        return Ok(format!("{old}\n\n{note}\n"));
    }
    let start = old.find(BEGIN).unwrap();
    let end = old.find(END).unwrap();
    if end < start {
        return Err(fail("companion_managed_section_conflict"));
    }
    Ok(format!(
        "{}{}{}",
        &old[..start],
        note,
        &old[end + END.len()..]
    ))
}
