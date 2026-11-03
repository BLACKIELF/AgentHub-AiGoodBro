use super::*;
use std::path::{Path, PathBuf};
pub trait Probe: Send + Sync {
    fn inspect(&self, path: &Path, isolated_home: &Path) -> Result<String>;
}
pub struct NativeProbe;
pub(crate) fn valid_version(text: &str) -> bool {
    !text.is_empty()
        && text.len() <= 64
        && text
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b".-+".contains(&c))
}
impl Probe for NativeProbe {
    fn inspect(&self, path: &Path, isolated_home: &Path) -> Result<String> {
        inspect_with(|args, limit, seconds| {
            crate::accounts::NativeAccountRuntime::runtime_probe(
                path,
                isolated_home,
                args,
                limit,
                seconds,
            )
        })
    }
}
pub(super) fn inspect_with(
    mut run: impl FnMut(&[&str], usize, u64) -> Result<Vec<u8>>,
) -> Result<String> {
    let bytes = run(&["--version"], 1024, 2)?;
    let version = std::str::from_utf8(&bytes)
        .ok()
        .and_then(|s| s.trim().strip_prefix("codex-cli "))
        .filter(|s| valid_version(s))
        .ok_or_else(|| fail("runtime_version_invalid"))?
        .to_owned();
    let bytes = run(&["exec", "--help"], 65536, 3)?;
    let help = std::str::from_utf8(&bytes).map_err(|_| fail("runtime_capability_missing"))?;
    if !["--output-last-message", "--sandbox", "--model"]
        .iter()
        .all(|flag| help.contains(flag))
    {
        return Err(fail("runtime_capability_missing"));
    }
    Ok(version)
}
pub fn automatic_candidates() -> Vec<PathBuf> {
    let (package, triple) = if cfg!(target_arch = "aarch64") {
        ("codex-win32-arm64", "aarch64-pc-windows-msvc")
    } else {
        ("codex-win32-x64", "x86_64-pc-windows-msvc")
    };
    let mut result = vec![];
    if let Some(root) = std::env::var_os("APPDATA") {
        result.push(
            PathBuf::from(root)
                .join("npm/node_modules/@openai/codex/node_modules/@openai")
                .join(package)
                .join("vendor")
                .join(triple)
                .join("bin/codex.exe"),
        );
    }
    if let Some(root) = std::env::var_os("LOCALAPPDATA") {
        result.push(PathBuf::from(root).join("Microsoft/WinGet/Links/codex.exe"));
    }
    if let Some(paths) = std::env::var_os("PATH") {
        result.extend(
            std::env::split_paths(&paths)
                .filter(|p| p.is_absolute())
                .take(100)
                .map(|p| p.join("codex.exe")),
        );
    }
    result
}
