//! Read-only, whole-snapshot Windows process and foreground observation.
//! A second Codex owner or an unclassifiable process is never inferred idle.
use super::*;
use crate::automatic_switch::live::activity::{
    self, PeerActivity, ProcessClass, ProcessIdentity, ProcessObservation,
};
use std::{
    collections::BTreeMap,
    sync::{atomic::AtomicU64, Mutex, Weak},
    time::Instant,
};

struct IndependentImage {
    _image: File,
    path: PathBuf,
}
#[derive(Clone, Default)]
pub(super) struct Inventory(Arc<Mutex<BTreeMap<(u32, u64), IndependentImage>>>);
impl Inventory {
    fn independent(&self, pid: u32, birth: u64, path: &Path) -> LiveResult<bool> {
        let mut cache = self.0.lock().map_err(|_| LiveIssue::Incomplete)?;
        if let Some(known) = cache.get(&(pid, birth)) {
            return Ok(known.path == path);
        }
        if cache.len() >= 1_024
            || !crate::updates::safe_download_directory(path.parent().ok_or(LiveIssue::Incomplete)?)
        {
            return Err(LiveIssue::Incomplete);
        }
        let image = OpenOptions::new()
            .read(true)
            .share_mode(1)
            .custom_flags(0x0020_0000)
            .open(path)
            .map_err(|_| LiveIssue::Incomplete)?;
        let metadata = image.metadata().map_err(|_| LiveIssue::Incomplete)?;
        if !metadata.is_file() || metadata.file_attributes() & 0x400 != 0 {
            return Err(LiveIssue::Incomplete);
        }
        let publisher = crate::readers::local_cli_quota::antigravity::publisher_of(path)
            .ok_or(LiveIssue::Incomplete)?;
        let publisher = publisher
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .flat_map(char::to_lowercase)
            .collect::<String>();
        if publisher.is_empty()
            || matches!(publisher.as_str(), "openai" | "openaillc" | "openaiinc")
        {
            return Ok(false);
        }
        cache.insert(
            (pid, birth),
            IndependentImage {
                _image: image,
                path: path.to_owned(),
            },
        );
        Ok(true)
    }
}

#[repr(C)]
struct ProcessEntry {
    size: u32,
    usage: u32,
    pid: u32,
    heap: usize,
    module: u32,
    threads: u32,
    parent: u32,
    priority: i32,
    flags: u32,
    name: [u16; 260],
}
#[repr(C)]
struct Message {
    window: Handle,
    message: u32,
    wparam: usize,
    lparam: isize,
    time: u32,
    point: [i32; 2],
    private: u32,
}
#[link(name = "kernel32")]
unsafe extern "system" {
    fn CreateToolhelp32Snapshot(flags: u32, pid: u32) -> Handle;
    fn Process32FirstW(snapshot: Handle, entry: *mut ProcessEntry) -> i32;
    fn Process32NextW(snapshot: Handle, entry: *mut ProcessEntry) -> i32;
    fn GetLastError() -> u32;
    fn ProcessIdToSessionId(pid: u32, session: *mut u32) -> i32;
    fn GetCurrentThreadId() -> u32;
    fn GetTickCount64() -> u64;
}
#[link(name = "user32")]
unsafe extern "system" {
    fn GetForegroundWindow() -> Handle;
    fn GetWindowThreadProcessId(window: Handle, pid: *mut u32) -> u32;
    fn SetWinEventHook(
        event_min: u32,
        event_max: u32,
        module: Handle,
        callback: Option<unsafe extern "system" fn(Handle, u32, Handle, i32, i32, u32, u32)>,
        process: u32,
        thread: u32,
        flags: u32,
    ) -> Handle;
    fn UnhookWinEvent(hook: Handle) -> i32;
    fn PeekMessageW(message: *mut Message, window: Handle, min: u32, max: u32, remove: u32) -> i32;
    fn TranslateMessage(message: *const Message) -> i32;
    fn DispatchMessageW(message: *const Message) -> isize;
}

struct Entry {
    pid: u32,
    name: String,
}
fn processes() -> LiveResult<Vec<Entry>> {
    let raw = unsafe { CreateToolhelp32Snapshot(2, 0) };
    if raw.is_null() || raw as isize == -1 {
        return Err(LiveIssue::Incomplete);
    }
    let snapshot = OwnedHandle(raw as usize);
    let mut row: ProcessEntry = unsafe { std::mem::zeroed() };
    row.size = std::mem::size_of::<ProcessEntry>() as u32;
    if unsafe { Process32FirstW(snapshot.raw(), &mut row) } == 0 {
        return Err(LiveIssue::Incomplete);
    }
    let mut result = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    loop {
        let length = row
            .name
            .iter()
            .position(|c| *c == 0)
            .ok_or(LiveIssue::Incomplete)?;
        if row.size as usize != std::mem::size_of::<ProcessEntry>()
            || length == 0
            || !seen.insert(row.pid)
            || result.len() >= 65_536
        {
            return Err(LiveIssue::Incomplete);
        }
        result.push(Entry {
            pid: row.pid,
            name: String::from_utf16(&row.name[..length]).map_err(|_| LiveIssue::Incomplete)?,
        });
        if unsafe { Process32NextW(snapshot.raw(), &mut row) } == 0 {
            if unsafe { GetLastError() } != 18 {
                return Err(LiveIssue::Incomplete);
            }
            break;
        }
    }
    Ok(result)
}

fn session(pid: u32) -> LiveResult<u32> {
    let mut session = 0;
    if unsafe { ProcessIdToSessionId(pid, &mut session) } == 0 {
        return Err(LiveIssue::Incomplete);
    }
    Ok(session)
}
fn same_user(process: Handle, current_user: &[u64]) -> LiveResult<bool> {
    let owner = token(process)?;
    let user = token_user(owner.raw())?;
    if unsafe { EqualSid(sid(current_user), sid(&user)) } == 0 {
        return Ok(false);
    }
    not_elevated(owner.raw())?;
    Ok(true)
}

/// Retained across samples on this connection. New/removed relevant owners do
/// not silently change its authenticated domain. The process and image handles
/// already held by Peer bind its kernel identity and prevent image replacement.
fn scan(
    peer_pid: u32,
    permitted: &[crate::accounts::OwnedVerificationProcess],
    inventory: &Inventory,
) -> LiveResult<Vec<ProcessObservation>> {
    let all = processes()?;
    let current_pid = std::process::id();
    let current_session = session(current_pid)?;
    let current = token(unsafe { GetCurrentProcess() })?;
    not_elevated(current.raw())?;
    let current_user = token_user(current.raw())?;
    let mut rows = Vec::new();
    for entry in all {
        if entry.pid == 0 || entry.pid == 4 || entry.pid == current_pid {
            continue;
        }
        let named_owner = activity::potential_codex(&entry.name)
            || activity::legacy_manager(&entry.name)
            || activity::script_host(&entry.name);
        // Inspect every process in our native session, plus potential Codex or
        // script owners in other sessions. Access/session failures remain unknown.
        if session(entry.pid)? != current_session && !named_owner {
            continue;
        }
        let raw = unsafe { OpenProcess(0x0010_1000, 0, entry.pid) };
        if raw.is_null() {
            return Err(LiveIssue::Incomplete);
        }
        let process = OwnedHandle(raw as usize);
        let created = process_created(process.raw())?;
        if !same_user(process.raw(), &current_user)? {
            continue;
        }
        recheck_process(process.raw(), created)?;
        let path = process_image(process.raw())?;
        let actual_name = path
            .file_name()
            .and_then(|s| s.to_str())
            .ok_or(LiveIssue::Incomplete)?;
        if !actual_name.eq_ignore_ascii_case(&entry.name) {
            return Err(LiveIssue::Incomplete);
        }
        let mut allowed = false;
        for receipt in permitted {
            if receipt
                .contains_process(process.raw() as usize, created)
                .map_err(|_| LiveIssue::Incomplete)?
            {
                allowed = true;
                break;
            }
        }
        let class = if allowed {
            ProcessClass::Independent
        } else if entry.pid == peer_pid {
            ProcessClass::OfficialPeer
        } else if activity::legacy_manager(&entry.name) {
            ProcessClass::LegacyManager
        } else if named_owner || activity::potential_codex(&path.to_string_lossy()) {
            ProcessClass::Unknown
        } else if inventory.independent(entry.pid, created, &path)? {
            ProcessClass::Independent
        } else {
            ProcessClass::Unknown
        };
        rows.push(ProcessObservation {
            identity: ProcessIdentity {
                pid: entry.pid,
                created,
            },
            class,
        });
    }
    Ok(rows)
}
fn inventory(peer: &Peer) -> LiveResult<bool> {
    peer.recheck()?;
    let rows = scan(peer.pid, &[], &peer.inventory)?;
    peer.recheck()?;
    activity::validate_inventory(
        &rows,
        ProcessIdentity {
            pid: peer.pid,
            created: peer.created,
        },
    )
}
pub(super) fn recheck_quiesced(
    process: Handle,
    pid: u32,
    created: u64,
    permitted: &[crate::accounts::OwnedVerificationProcess],
    inventory: &Inventory,
) -> LiveResult<()> {
    // The retained kernel object, not EOF/WM_CLOSE/PID disappearance, supplies
    // positive exit evidence. A reused PID or a replacement process blocks it.
    if unsafe { WaitForSingleObject(process, 0) } != 0 || process_created(process)? != created {
        return Err(LiveIssue::PeerUntrusted);
    }
    activity::validate_quiesced_inventory(&scan(pid, permitted, inventory)?)
}

struct FocusState {
    peer_pid: u32,
    last_active_tick: AtomicU64,
    unknown: AtomicBool,
}
static FOCUS_HEALTHY: AtomicBool = AtomicBool::new(true);
fn hooks() -> &'static Mutex<BTreeMap<usize, Weak<FocusState>>> {
    static HOOKS: OnceLock<Mutex<BTreeMap<usize, Weak<FocusState>>>> = OnceLock::new();
    HOOKS.get_or_init(|| Mutex::new(BTreeMap::new()))
}
unsafe extern "system" fn foreground_event(
    hook: Handle,
    _event: u32,
    window: Handle,
    _object: i32,
    _child: i32,
    _thread: u32,
    _time: u32,
) {
    let state = match hooks().lock() {
        Ok(map) => map.get(&(hook as usize)).and_then(Weak::upgrade),
        Err(_) => {
            FOCUS_HEALTHY.store(false, Ordering::Release);
            return;
        }
    };
    let Some(state) = state else {
        FOCUS_HEALTHY.store(false, Ordering::Release);
        return;
    };
    let mut pid = 0;
    if window.is_null() || unsafe { GetWindowThreadProcessId(window, &mut pid) } == 0 || pid == 0 {
        state.unknown.store(true, Ordering::Release);
    } else if pid == state.peer_pid {
        state
            .last_active_tick
            .store(unsafe { GetTickCount64() }, Ordering::Release);
    }
}

pub(super) struct Foreground {
    hook: usize,
    thread: u32,
    state: Arc<FocusState>,
}
impl Foreground {
    pub fn new(peer_pid: u32) -> LiveResult<Self> {
        let state = Arc::new(FocusState {
            peer_pid,
            last_active_tick: AtomicU64::new(unsafe { GetTickCount64() }),
            unknown: AtomicBool::new(false),
        });
        let raw =
            unsafe { SetWinEventHook(3, 3, ptr::null_mut(), Some(foreground_event), 0, 0, 0) };
        if raw.is_null() {
            return Err(LiveIssue::Unavailable);
        }
        let result = Self {
            hook: raw as usize,
            thread: unsafe { GetCurrentThreadId() },
            state,
        };
        hooks()
            .lock()
            .map_err(|_| LiveIssue::Unavailable)?
            .insert(result.hook, Arc::downgrade(&result.state));
        Ok(result)
    }
    fn inactive_since(&self, now: u64) -> LiveResult<Option<u64>> {
        if unsafe { GetCurrentThreadId() } != self.thread || !FOCUS_HEALTHY.load(Ordering::Acquire)
        {
            return Err(LiveIssue::Incomplete);
        }
        // WinEvent out-of-context callbacks require this owning thread to pump
        // its own queue. No application UI messages are intercepted.
        let mut message: Message = unsafe { std::mem::zeroed() };
        let mut count = 0;
        while unsafe { PeekMessageW(&mut message, ptr::null_mut(), 0, 0, 1) } != 0 {
            count += 1;
            if count > 256 || message.message == 0x0012 {
                return Err(LiveIssue::Incomplete);
            }
            unsafe {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
        let window = unsafe { GetForegroundWindow() };
        let mut pid = 0;
        if window.is_null()
            || unsafe { GetWindowThreadProcessId(window, &mut pid) } == 0
            || pid == 0
            || self.state.unknown.load(Ordering::Acquire)
        {
            return Err(LiveIssue::Incomplete);
        }
        let tick = unsafe { GetTickCount64() };
        if pid == self.state.peer_pid {
            self.state.last_active_tick.store(tick, Ordering::Release);
        }
        let elapsed = tick
            .checked_sub(self.state.last_active_tick.load(Ordering::Acquire))
            .ok_or(LiveIssue::Incomplete)?;
        Ok(now.checked_sub(elapsed))
    }
}
impl Drop for Foreground {
    fn drop(&mut self) {
        if unsafe { UnhookWinEvent(self.hook as Handle) } == 0 {
            FOCUS_HEALTHY.store(false, Ordering::Release);
        }
        if let Ok(mut map) = hooks().lock() {
            map.remove(&self.hook);
        }
    }
}

pub(super) fn activity(peer: &Peer) -> LiveResult<PeerActivity> {
    let legacy = inventory(peer)?;
    let now = super::super::super::now_ms();
    let inactive_since = peer.foreground.inactive_since(now)?;
    Ok(PeerActivity {
        observed_at_unix_ms: now,
        observed_at: Instant::now(),
        inactive_since_unix_ms: inactive_since,
        legacy_manager_running: legacy,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_toolhelp_roster_reaches_real_end_and_contains_its_owned_test_process() {
        let rows = processes().unwrap();
        assert!(rows.iter().any(|row| row.pid == std::process::id()));
        assert_eq!(
            rows.iter()
                .map(|row| row.pid)
                .collect::<std::collections::BTreeSet<_>>()
                .len(),
            rows.len()
        );
    }
}
