//! Explicit local Python selection for the companion. Never installs Python,
//! imports user code, changes PATH, or uses a Codex CLI capability probe.
use super::{fail, PinnedExecutable, Probe, Result, RuntimeView, SelectionStore};
use serde::Deserialize;
use std::path::{Path, PathBuf};

/// The native process adapter permits exactly these arguments. This is not a
/// general Python/script execution API. Isolated mode ignores PYTHONPATH and
/// user site packages; -B prevents writing bytecode into an installed runtime.
pub(crate) const PROBE_SCRIPT: &str = r#"import importlib,json,sys
checks={}
for name in ('ssl','sqlite3','ctypes','msvcrt'):
    try:
        importlib.import_module(name)
        checks[name]=True
    except Exception:
        checks[name]=False
try:
    import zoneinfo
    zoneinfo.ZoneInfo('Asia/Shanghai')
    timezone=True
except Exception:
    timezone=False
print(json.dumps({'version':list(sys.version_info[:3]),'executable':sys.executable,'platform':sys.platform,'stdlib':checks,'timezone':timezone},separators=(',',':')))
"#;
pub(crate) fn probe_args() -> [&'static str; 4] {
    ["-I", "-B", "-c", PROBE_SCRIPT]
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Libraries {
    ssl: bool,
    sqlite3: bool,
    ctypes: bool,
    msvcrt: bool,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Report {
    version: [u32; 3],
    executable: PathBuf,
    platform: String,
    stdlib: Libraries,
    timezone: bool,
}
fn parse_report(bytes: &[u8], selected: &Path) -> Result<String> {
    if bytes.len() > 8192 {
        return Err(fail("python_probe_invalid"));
    }
    let report: Report = serde_json::from_slice(bytes).map_err(|_| fail("python_probe_invalid"))?;
    if report.version[0] != 3 || report.version[1] < 9 || report.version[2] > 1_000_000 {
        return Err(fail("python_version_unsupported"));
    }
    if report.platform != "win32"
        || !report.executable.is_absolute()
        || report
            .executable
            .components()
            .any(|p| matches!(p, std::path::Component::ParentDir))
        || report.executable.canonicalize().ok().as_deref() != Some(selected)
    {
        return Err(fail("python_interpreter_changed"));
    }
    if !(report.stdlib.ssl && report.stdlib.sqlite3 && report.stdlib.ctypes && report.stdlib.msvcrt)
    {
        return Err(fail("python_stdlib_missing"));
    }
    if !report.timezone {
        return Err(fail("python_timezone_missing"));
    }
    Ok(format!(
        "{}.{}.{}",
        report.version[0], report.version[1], report.version[2]
    ))
}

pub struct NativePythonProbe;
impl Probe for NativePythonProbe {
    fn inspect(&self, path: &Path, isolated_home: &Path) -> Result<String> {
        let bytes = crate::accounts::NativeAccountRuntime::runtime_probe(
            path,
            isolated_home,
            &probe_args(),
            8192,
            2,
        )?;
        parse_report(&bytes, path)
    }
}

/// Reuses the exact existing held-PE, hash, private writer, lock and cleanup
/// implementation in a separate namespace. The backing record is private to
/// this service; its legacy cliVersion field simply holds the probed version.
#[derive(Clone)]
pub struct PythonSelection {
    selection: SelectionStore,
}
impl PythonSelection {
    pub fn new(app_data: &Path) -> Result<Self> {
        Ok(Self {
            selection: SelectionStore::new(&app_data.join("python-runtime-v1"))?,
        })
    }
    pub fn inspect(&self, candidates: &[PathBuf]) -> RuntimeView {
        self.selection.inspect(candidates, &NativePythonProbe)
    }
    pub fn choose(&self, path: &Path) -> Result<RuntimeView> {
        self.selection.choose(path, &NativePythonProbe)
    }
    /// Native companion consumers use this immediately before starting their
    /// fixed operation and retain the image guard until process creation. A
    /// saved path alone is insufficient; recheck Python capabilities and hash.
    /// No automatic fallback can override an invalid explicit selection.
    pub fn for_companion(&self, candidates: &[PathBuf]) -> Result<PinnedExecutable> {
        self.for_companion_with(candidates, &NativePythonProbe)
    }
    fn for_companion_with(
        &self,
        candidates: &[PathBuf],
        probe: &dyn Probe,
    ) -> Result<PinnedExecutable> {
        self.selection.resolve_with(candidates, probe)
    }
}

/// Fixed likely install locations plus bounded PATH entries. No launcher,
/// registry mutation, recursive profile scan, download or package installation.
pub fn automatic_candidates() -> Vec<PathBuf> {
    let mut result = Vec::new();
    if let Some(root) = std::env::var_os("LOCALAPPDATA") {
        let root = PathBuf::from(root);
        if root.is_absolute() {
            for minor in (9..=15).rev() {
                result.push(root.join(format!("Programs/Python/Python3{minor}/python.exe")));
            }
        }
    }
    if let Some(paths) = std::env::var_os("PATH") {
        result.extend(
            std::env::split_paths(&paths)
                .filter(|p| p.is_absolute())
                .take(100)
                .map(|p| p.join("python.exe")),
        );
    }
    result
}

#[cfg(test)]
#[path = "python_tests.rs"]
mod tests;
