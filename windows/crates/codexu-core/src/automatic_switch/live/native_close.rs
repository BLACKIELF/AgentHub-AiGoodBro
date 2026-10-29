//! WM_CLOSE is only a request. Only the retained process handle can prove exit.
use super::*;
use crate::automatic_switch::live::quiescence::CloseTarget;
use std::time::Instant;

#[link(name = "user32")]
unsafe extern "system" {
    fn EnumWindows(
        callback: Option<unsafe extern "system" fn(Handle, isize) -> i32>,
        data: isize,
    ) -> i32;
    fn GetWindowThreadProcessId(window: Handle, pid: *mut u32) -> u32;
    fn SendMessageTimeoutW(
        window: Handle,
        message: u32,
        wparam: usize,
        lparam: isize,
        flags: u32,
        timeout: u32,
        result: *mut usize,
    ) -> isize;
}
struct Windows {
    pid: u32,
    handles: Vec<usize>,
    failed: bool,
}
unsafe extern "system" fn collect(window: Handle, data: isize) -> i32 {
    let rows = unsafe { &mut *(data as *mut Windows) };
    let mut pid = 0;
    if unsafe { GetWindowThreadProcessId(window, &mut pid) } == 0 || pid == 0 {
        rows.failed = true;
        return 0;
    }
    if pid == rows.pid {
        if rows.handles.len() >= 64 {
            rows.failed = true;
            return 0;
        }
        rows.handles.push(window as usize);
    }
    1
}
fn windows(pid: u32) -> LiveResult<Vec<usize>> {
    let mut result = Windows {
        pid,
        handles: vec![],
        failed: false,
    };
    if unsafe { EnumWindows(Some(collect), (&mut result as *mut Windows) as isize) } == 0
        || result.failed
        || result.handles.is_empty()
    {
        return Err(LiveIssue::Unavailable);
    }
    result.handles.sort_unstable();
    result.handles.dedup();
    Ok(result.handles)
}
struct Target {
    process: OwnedHandle,
    pid: u32,
    created: u64,
    windows: Vec<usize>,
    _image: File,
    _directory: File,
    inventory: inventory::Inventory,
}
impl CloseTarget for Target {
    fn close_and_confirm(
        &self,
        before_close: &dyn Fn() -> LiveResult<()>,
        current: &dyn Fn() -> LiveResult<()>,
    ) -> LiveResult<()> {
        before_close()?;
        recheck_process(self.process.raw(), self.created)?;
        if windows(self.pid)? != self.windows {
            return Err(LiveIssue::Incomplete);
        }
        for &window in &self.windows {
            before_close()?;
            recheck_process(self.process.raw(), self.created)?;
            let mut owner = 0;
            if unsafe { GetWindowThreadProcessId(window as Handle, &mut owner) } == 0
                || owner != self.pid
            {
                return Err(LiveIssue::PeerUntrusted);
            }
            let mut ignored = 0usize;
            // SMTO_BLOCK | SMTO_ABORTIFHUNG | SMTO_ERRORONEXIT; no force kill.
            if unsafe {
                SendMessageTimeoutW(window as Handle, 0x0010, 0, 0, 0x0023, 250, &mut ignored)
            } == 0
            {
                return Err(LiveIssue::Unavailable);
            }
        }
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            match unsafe { WaitForSingleObject(self.process.raw(), 0) } {
                0 => return self.recheck_quiesced(&[]),
                258 => {}
                _ => return Err(LiveIssue::PeerUntrusted),
            }
            current()?;
            if Instant::now() >= deadline {
                return Err(LiveIssue::TimedOut);
            }
            std::thread::sleep(Duration::from_millis(25));
        }
    }
    fn recheck_quiesced(
        &self,
        permitted: &[crate::accounts::OwnedVerificationProcess],
    ) -> LiveResult<()> {
        inventory::recheck_quiesced(
            self.process.raw(),
            self.pid,
            self.created,
            permitted,
            &self.inventory,
        )
    }
}
pub(super) fn capture(peer: &Peer) -> LiveResult<Arc<dyn CloseTarget>> {
    peer.recheck()?;
    // A separate GUI/daemon ownership relation is not established by a parent
    // PID or publisher. The accepted peer itself must own all closeable windows.
    let windows = windows(peer.pid)?;
    let process = unsafe { OpenProcess(0x0010_1000, 0, peer.pid) };
    if process.is_null() {
        return Err(LiveIssue::PeerUntrusted);
    }
    let process = OwnedHandle(process as usize);
    recheck_process(process.raw(), peer.created)?;
    Ok(Arc::new(Target {
        process,
        pid: peer.pid,
        created: peer.created,
        windows,
        _image: peer
            ._image
            .try_clone()
            .map_err(|_| LiveIssue::Unavailable)?,
        _directory: peer
            ._directory
            .try_clone()
            .map_err(|_| LiveIssue::Unavailable)?,
        inventory: peer.inventory.clone(),
    }))
}
