use super::*;
use crate::accounts::storage;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::File,
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Selection {
    version: u8,
    path: PathBuf,
    sha256: String,
    cli_version: String,
}
#[derive(Clone)]
pub struct SelectionStore {
    root: PathBuf,
}
/// Held image guard is native-only and remains alive through process creation.
pub struct PinnedExecutable {
    pub path: PathBuf,
    pub guard: File,
}
fn digest(file: &mut File) -> Result<String> {
    file.seek(SeekFrom::Start(0))
        .map_err(|_| fail("runtime_file_unavailable"))?;
    let mut h = Sha256::new();
    let mut size = 0usize;
    let mut buf = [0; 65536];
    loop {
        let n = file
            .read(&mut buf)
            .map_err(|_| fail("runtime_file_unavailable"))?;
        if n == 0 {
            break;
        }
        size += n;
        if size > 512 * 1024 * 1024 {
            return Err(fail("runtime_file_invalid"));
        }
        h.update(&buf[..n]);
    }
    if size < 64 {
        return Err(fail("runtime_file_invalid"));
    }
    Ok(format!("{:x}", h.finalize()))
}
fn hold(path: &Path) -> Result<PinnedExecutable> {
    if !path.is_absolute()
        || path
            .components()
            .any(|p| matches!(p, std::path::Component::ParentDir))
        || !path
            .extension()
            .and_then(|v| v.to_str())
            .is_some_and(|v| v.eq_ignore_ascii_case("exe"))
    {
        return Err(fail("runtime_path_invalid"));
    }
    // Resolve an explicitly chosen OS alias once, then retain and verify the
    // canonical local image. Stored selections never silently follow a new link.
    let path = path
        .canonicalize()
        .map_err(|_| fail("runtime_file_unavailable"))?;
    storage::ensure_no_links(&path).map_err(|_| fail("runtime_path_invalid"))?;
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.share_mode(1).custom_flags(0x00200000);
    }
    let mut guard = options
        .open(&path)
        .map_err(|_| fail("runtime_file_unavailable"))?;
    let meta = guard
        .metadata()
        .map_err(|_| fail("runtime_file_unavailable"))?;
    if !meta.is_file() || meta.len() > 512 * 1024 * 1024 {
        return Err(fail("runtime_file_invalid"));
    }
    let mut header = [0; 64];
    guard
        .read_exact(&mut header)
        .map_err(|_| fail("runtime_file_invalid"))?;
    if &header[..2] != b"MZ" {
        return Err(fail("runtime_file_invalid"));
    }
    let offset = u32::from_le_bytes(header[60..64].try_into().unwrap()) as u64;
    if offset.checked_add(26).is_none_or(|n| n > meta.len()) {
        return Err(fail("runtime_file_invalid"));
    }
    guard
        .seek(SeekFrom::Start(offset))
        .map_err(|_| fail("runtime_file_invalid"))?;
    let mut pe = [0; 26];
    guard
        .read_exact(&mut pe)
        .map_err(|_| fail("runtime_file_invalid"))?;
    let machine = if cfg!(target_arch = "aarch64") {
        0xaa64u16
    } else {
        0x8664
    };
    if &pe[..4] != b"PE\0\0"
        || u16::from_le_bytes(pe[4..6].try_into().unwrap()) != machine
        || &pe[24..26] != b"\x0b\x02"
    {
        return Err(fail("runtime_file_invalid"));
    }
    Ok(PinnedExecutable { path, guard })
}
impl SelectionStore {
    pub fn new(app_data: &Path) -> Result<Self> {
        if !app_data.is_absolute()
            || app_data
                .components()
                .any(|p| matches!(p, std::path::Component::ParentDir))
        {
            return Err(fail("runtime_storage_unavailable"));
        }
        let root = app_data.join("runtime-setup-v1");
        storage::ensure_no_links(&root).map_err(|_| fail("runtime_storage_unavailable"))?;
        Ok(Self { root })
    }
    fn saved(&self) -> Result<Option<Selection>> {
        let Some(bytes) = storage::read_bound_optional(&self.root.join("codex.json"), 32768, true)
            .map_err(|_| fail("runtime_storage_unavailable"))?
        else {
            return Ok(None);
        };
        let s: Selection =
            serde_json::from_slice(&bytes).map_err(|_| fail("runtime_selection_invalid"))?;
        if s.version != 1
            || s.sha256.len() != 64
            || !s
                .sha256
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
            || !super::probe::valid_version(&s.cli_version)
        {
            return Err(fail("runtime_selection_invalid"));
        }
        Ok(Some(s))
    }
    pub fn selected(&self) -> Result<Option<PinnedExecutable>> {
        let Some(s) = self.saved()? else {
            return Ok(None);
        };
        let mut image = hold(&s.path)?;
        if image.path != s.path || digest(&mut image.guard)? != s.sha256 {
            return Err(fail("runtime_selection_changed"));
        }
        Ok(Some(image))
    }
    fn in_probe_home<T>(&self, work: impl FnOnce(&Path) -> Result<T>) -> Result<T> {
        storage::secure_directory(&self.root).map_err(|_| fail("runtime_storage_unavailable"))?;
        let home = storage::private_tempdir(&self.root, "probe-")
            .map_err(|_| fail("runtime_storage_unavailable"))?;
        let result = work(home.path());
        // Keep unknown-cleanup evidence and never remove a potentially live home.
        if matches!(&result,Err(e)if e.code=="cleanup_unconfirmed") {
            home.keep();
        }
        result
    }
    pub fn resolve_cli(&self) -> Result<(PathBuf, File)> {
        self.in_probe_home(|home| {
            crate::accounts::NativeAccountRuntime::selected_executable(home, self)
        })
    }
    fn inspect_image(&self, image: &mut PinnedExecutable, probe: &dyn Probe) -> Result<String> {
        let before = digest(&mut image.guard)?;
        let version = self.in_probe_home(|home| probe.inspect(&image.path, home))?;
        if !super::probe::valid_version(&version) || digest(&mut image.guard)? != before {
            return Err(fail("runtime_selection_changed"));
        }
        Ok(version)
    }
    pub fn choose(&self, path: &Path, probe: &dyn Probe) -> Result<RuntimeView> {
        // Validate before touching the prior setting. Serialize the bounded
        // probe and save with other explicit selections across app instances.
        let mut image = hold(path)?;
        let _lock =
            storage::StoreLock::acquire(&self.root).map_err(|_| fail("runtime_setup_busy"))?;
        let version = self.inspect_image(&mut image, probe)?;
        let value = Selection {
            version: 1,
            path: image.path.clone(),
            sha256: digest(&mut image.guard)?,
            cli_version: version.clone(),
        };
        let bytes = serde_json::to_vec(&value).map_err(|_| fail("runtime_selection_invalid"))?;
        storage::atomic_write(&self.root.join("codex.json"), &bytes)
            .map_err(|_| fail("runtime_save_failed"))?;
        Ok(RuntimeView::ready(version, true))
    }
    /// Return the same held image that passed the probe. Explicit selection
    /// and automatic discovery share the selection lock through this decision;
    /// a failed saved selection never falls back to another executable.
    pub(crate) fn resolve_with(
        &self,
        candidates: &[PathBuf],
        probe: &dyn Probe,
    ) -> Result<PinnedExecutable> {
        let _lock =
            storage::StoreLock::acquire(&self.root).map_err(|_| fail("runtime_setup_busy"))?;
        if let Some(mut image) = self.selected()? {
            self.inspect_image(&mut image, probe)?;
            return Ok(image);
        }
        let deadline = Instant::now() + Duration::from_secs(15);
        let mut seen = std::collections::HashSet::new();
        for path in candidates.iter().take(12) {
            if Instant::now() >= deadline {
                break;
            }
            let Ok(mut image) = hold(path) else { continue };
            if !seen.insert(image.path.clone()) {
                continue;
            }
            match self.inspect_image(&mut image, probe) {
                Ok(_) => return Ok(image),
                Err(e) if e.code == "cleanup_unconfirmed" => return Err(e),
                _ => {}
            }
        }
        Err(fail("runtime_not_found"))
    }
    pub fn inspect(&self, candidates: &[PathBuf], probe: &dyn Probe) -> RuntimeView {
        let selected = match self.selected() {
            Ok(Some(mut image)) => {
                return match self.inspect_image(&mut image, probe) {
                    Ok(v) => RuntimeView::ready(v, true),
                    Err(e) => RuntimeView::failed(e.code, true),
                }
            }
            Ok(None) => false,
            Err(e) => return RuntimeView::failed(e.code, true),
        };
        let deadline = Instant::now() + Duration::from_secs(15);
        let mut seen = std::collections::HashSet::new();
        for path in candidates.iter().take(12) {
            if Instant::now() >= deadline {
                break;
            }
            let Ok(mut image) = hold(path) else { continue };
            if !seen.insert(image.path.clone()) {
                continue;
            }
            match self.inspect_image(&mut image, probe) {
                Ok(v) => return RuntimeView::ready(v, selected),
                Err(e) if e.code == "cleanup_unconfirmed" => {
                    return RuntimeView::failed(e.code, false)
                }
                _ => {}
            }
        }
        RuntimeView::failed("runtime_not_found", false)
    }
}
