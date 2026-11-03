//! Private native activity receipts. A caller-provided idle flag cannot mint one.
use super::*;
use std::time::Instant;

pub(super) const ACTIVITY_MAX_AGE_MS: u64 = 1_500;

pub(super) struct PeerActivity {
    pub observed_at_unix_ms: u64,
    pub observed_at: Instant,
    pub inactive_since_unix_ms: Option<u64>,
    pub legacy_manager_running: bool,
}
impl PeerActivity {
    pub fn current(&self, now: u64) -> bool {
        self.observed_at.elapsed().as_millis() <= u128::from(ACTIVITY_MAX_AGE_MS)
            && is_fresh(self.observed_at_unix_ms, ACTIVITY_MAX_AGE_MS, now)
    }
}

pub(super) struct BoundActivity {
    pub peer: PeerActivity,
    pub connection_generation: String,
}

/// No serialized process/path/owner fields leave the native observer. The full
/// OS enumeration is required even when the accepted Codex domain has one peer.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) struct ProcessIdentity {
    pub pid: u32,
    pub created: u64,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum ProcessClass {
    Independent,
    OfficialPeer,
    LegacyManager,
    Unknown,
}
pub(super) struct ProcessObservation {
    pub identity: ProcessIdentity,
    pub class: ProcessClass,
}

pub(super) fn validate_inventory(
    rows: &[ProcessObservation],
    peer: ProcessIdentity,
) -> LiveResult<bool> {
    let mut seen = std::collections::BTreeSet::new();
    let mut found = false;
    let mut legacy = false;
    if rows.is_empty() || rows.len() > 65_536 || peer.pid == 0 || peer.created == 0 {
        return Err(LiveIssue::Incomplete);
    }
    for row in rows {
        if row.identity.pid == 0 || row.identity.created == 0 || !seen.insert(row.identity.pid) {
            return Err(LiveIssue::Incomplete);
        }
        if row.identity.pid == peer.pid && row.identity != peer {
            return Err(LiveIssue::PeerUntrusted);
        }
        match row.class {
            ProcessClass::OfficialPeer if row.identity == peer => found = true,
            ProcessClass::OfficialPeer | ProcessClass::Unknown => {
                return Err(LiveIssue::Incomplete)
            }
            ProcessClass::LegacyManager => legacy = true,
            ProcessClass::Independent if row.identity == peer => {
                return Err(LiveIssue::PeerUntrusted)
            }
            ProcessClass::Independent => {}
        }
    }
    if !found {
        return Err(LiveIssue::Incomplete);
    }
    Ok(legacy)
}
pub(super) fn validate_quiesced_inventory(rows: &[ProcessObservation]) -> LiveResult<()> {
    let mut seen = std::collections::BTreeSet::new();
    if rows.len() > 65_536 {
        return Err(LiveIssue::Incomplete);
    }
    for row in rows {
        if row.identity.pid == 0
            || row.identity.created == 0
            || !seen.insert(row.identity.pid)
            || row.class != ProcessClass::Independent
        {
            return Err(LiveIssue::Incomplete);
        }
    }
    Ok(())
}

/// Names and paths only reject potential extra owners. They never authenticate
/// a peer or authorize a second backend's tasks as globally idle.
pub(super) fn potential_codex(value: &str) -> bool {
    let value = value.to_ascii_lowercase();
    value.contains("codex") || value.contains("chatgpt") || value.contains("openai")
}
pub(super) fn legacy_manager(value: &str) -> bool {
    let value = value.to_ascii_lowercase();
    value.contains("codexaccountmanager")
        || matches!(
            value.as_str(),
            "cc-switch.exe" | "claude-swap.exe" | "cswap.exe"
        )
}
pub(super) fn related_codex(name: &str, image_path: &str, same_verified_image: bool) -> bool {
    potential_codex(name)
        || legacy_manager(name)
        || potential_codex(image_path)
        || same_verified_image
}

#[cfg(test)]
mod tests {
    use super::*;
    fn observation(pid: u32, created: u64, class: ProcessClass) -> ProcessObservation {
        ProcessObservation {
            identity: ProcessIdentity { pid, created },
            class,
        }
    }
    #[test]
    fn complete_inventory_requires_exact_peer_and_rejects_unknown_additional_and_reused_pid() {
        let peer = ProcessIdentity {
            pid: 12,
            created: 42,
        };
        let make = || {
            vec![
                observation(12, 42, ProcessClass::OfficialPeer),
                observation(21, 51, ProcessClass::Independent),
            ]
        };
        assert_eq!(validate_inventory(&make(), peer), Ok(false));
        let mut rows = make();
        rows.push(observation(22, 52, ProcessClass::LegacyManager));
        assert_eq!(validate_inventory(&rows, peer), Ok(true));
        for class in [ProcessClass::Unknown, ProcessClass::OfficialPeer] {
            let mut rows = make();
            rows.push(observation(22, 52, class));
            assert_eq!(validate_inventory(&rows, peer), Err(LiveIssue::Incomplete));
        }
        assert_eq!(validate_inventory(&[], peer), Err(LiveIssue::Incomplete));
        assert_eq!(
            validate_inventory(&make()[1..], peer),
            Err(LiveIssue::Incomplete)
        );
        assert_eq!(
            validate_inventory(&[observation(12, 43, ProcessClass::OfficialPeer)], peer),
            Err(LiveIssue::PeerUntrusted)
        );
        let mut rows = make();
        rows.push(observation(21, 54, ProcessClass::Independent));
        assert_eq!(validate_inventory(&rows, peer), Err(LiveIssue::Incomplete));
    }
    #[test]
    fn unfamiliar_owner_spelling_and_script_hosts_only_add_rejection_evidence() {
        for name in [
            "CODEX.exe",
            "codex-daemon.exe",
            "ChatGPT.exe",
            "C:\\Apps\\OpenAI\\renamed.exe",
        ] {
            assert!(potential_codex(name));
        }
        assert!(legacy_manager("CodexAccountManagerNext.exe"));
        assert!(!related_codex(
            "node.exe",
            "C:\\UnrelatedTool\\node.exe",
            false
        ));
        assert!(!related_codex(
            "unsigned-tool.exe",
            "C:\\UnrelatedTool\\unsigned-tool.exe",
            false
        ));
        assert!(related_codex(
            "renamed.exe",
            "C:\\UnrelatedTool\\renamed.exe",
            true
        ));
        assert!(related_codex(
            "node.exe",
            "C:\\OpenAI\\Codex\\node.exe",
            false
        ));
        assert!(!potential_codex("notepad.exe"));
    }
    #[test]
    fn quiescence_inventory_cannot_reuse_live_peer_or_accept_any_new_unknown_owner() {
        assert!(
            validate_quiesced_inventory(&[observation(21, 51, ProcessClass::Independent)]).is_ok()
        );
        for class in [
            ProcessClass::OfficialPeer,
            ProcessClass::Unknown,
            ProcessClass::LegacyManager,
        ] {
            assert_eq!(
                validate_quiesced_inventory(&[observation(12, 42, class)]),
                Err(LiveIssue::Incomplete)
            );
        }
    }
}
