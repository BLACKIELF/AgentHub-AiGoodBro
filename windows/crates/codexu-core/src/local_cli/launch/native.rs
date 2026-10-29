use super::*;
use std::{fs::File, io::Read};
/// The read-share lock lives through the owned Job. No script/shell fallback.
pub struct VerifiedExecutable {
    path: PathBuf,
    guard: File,
}
impl VerifiedExecutable {
    pub fn path(&self) -> &Path {
        &self.path
    }
    pub fn into_parts(self) -> (PathBuf, File) {
        (self.path, self.guard)
    }
}
fn trusted_publisher(kind: LocalCliKind, publisher: &str) -> bool {
    let normalized: String = publisher
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .flat_map(char::to_lowercase)
        .collect();
    match kind {
        LocalCliKind::ClaudeCode => matches!(
            normalized.as_str(),
            "anthropic" | "anthropicpbc" | "anthropicinc"
        ),
        LocalCliKind::Grok | LocalCliKind::OpenCode | LocalCliKind::Kimi => false,
        LocalCliKind::Antigravity => matches!(normalized.as_str(), "googlellc" | "googleinc"),
        // The actual Windows signing identities for these products have not
        // been established in this task. Discovery must remain unavailable.
        _ => false,
    }
}
pub fn discover(kind: LocalCliKind, dirs: &PlatformDirectories) -> Result<VerifiedExecutable> {
    if !cfg!(windows) {
        return Err(fail("windows_required"));
    }
    if matches!(
        kind,
        LocalCliKind::Grok
            | LocalCliKind::OpenCode
            | LocalCliKind::Kimi
            | LocalCliKind::Gemini
            | LocalCliKind::WorkBuddy
            | LocalCliKind::ZCode
            | LocalCliKind::Trae
    ) {
        return Err(fail("provider_runtime_unverified"));
    }
    let filename = match kind {
        LocalCliKind::Grok => "grok.exe",
        LocalCliKind::OpenCode => "opencode.exe",
        LocalCliKind::Kimi => "kimi.exe",
        LocalCliKind::ClaudeCode => "claude.exe",
        LocalCliKind::Antigravity => "Antigravity.exe",
        _ => return Err(fail("platform_not_supported")),
    };
    let mut candidates = match kind {
        LocalCliKind::Grok => vec![dirs.home.join(".grok/bin/grok.exe")],
        LocalCliKind::Kimi => vec![
            dirs.home.join(".kimi-code/bin/kimi.exe"),
            dirs.home.join(".local/bin/kimi.exe"),
        ],
        LocalCliKind::ClaudeCode => vec![dirs.home.join(".local/bin/claude.exe")],
        LocalCliKind::OpenCode => vec![
            dirs.home.join(".opencode/bin/opencode.exe"),
            dirs.local_app_data.join("Programs/opencode/opencode.exe"),
        ],
        LocalCliKind::Antigravity => vec![dirs
            .local_app_data
            .join("Programs/Antigravity/Antigravity.exe")],
        _ => vec![],
    };
    if let Some(program) = std::env::var_os("ProgramFiles") {
        if kind == LocalCliKind::Antigravity {
            candidates.push(PathBuf::from(program).join("Antigravity/Antigravity.exe"));
        }
    }
    if !kind.is_desktop_application() {
        if let Some(paths) = std::env::var_os("PATH") {
            candidates.extend(
                std::env::split_paths(&paths)
                    .filter(|p| p.is_absolute())
                    .take(100)
                    .map(|p| p.join(filename)),
            );
        }
    }
    let mut seen = std::collections::HashSet::new();
    let mut found = false;
    for candidate in candidates.into_iter().take(128) {
        if check_path(&candidate).is_err() {
            continue;
        }
        let Ok(path) = candidate.canonicalize() else {
            continue;
        };
        if check_path(&path).is_err() || !seen.insert(path.clone()) {
            continue;
        }
        found = true;
        let mut options = std::fs::OpenOptions::new();
        options.read(true);
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            options.share_mode(1);
        }
        let Ok(mut guard) = options.open(&path) else {
            continue;
        };
        let Ok(meta) = guard.metadata() else { continue };
        if !meta.is_file() || meta.len() > 512 * 1024 * 1024 {
            continue;
        }
        let mut magic = [0; 2];
        if guard.read_exact(&mut magic).is_err() || magic != *b"MZ" {
            continue;
        }
        let Some(publisher) = crate::readers::local_cli_quota::antigravity::publisher_of(&path)
        else {
            continue;
        };
        if !trusted_publisher(kind, &publisher) {
            continue;
        }
        return Ok(VerifiedExecutable { path, guard });
    }
    Err(fail(if found {
        "executable_unverified"
    } else {
        "cli_unavailable"
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unrelated_signed_publishers_never_authorize_a_named_provider() {
        assert!(trusted_publisher(
            LocalCliKind::ClaudeCode,
            "Anthropic, PBC"
        ));
        assert!(trusted_publisher(LocalCliKind::Antigravity, "Google LLC"));
        assert!(!trusted_publisher(
            LocalCliKind::Grok,
            "Other xAI Companion LLC"
        ));
        assert!(!trusted_publisher(
            LocalCliKind::OpenCode,
            "Microsoft Corporation"
        ));
        assert!(!trusted_publisher(LocalCliKind::WorkBuddy, "Tencent"));
        assert!(!trusted_publisher(LocalCliKind::ZCode, "Unknown"));
    }
}
