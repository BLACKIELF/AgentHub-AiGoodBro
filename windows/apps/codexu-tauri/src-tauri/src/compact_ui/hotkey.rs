//! One owned Win32 hotkey/message thread. No hooks, plugins or business process.
use super::model::ShortcutStatus;
use std::sync::Arc;

#[cfg(windows)]
mod native {
    use super::*;
    use std::{
        ffi::c_void,
        sync::{
            atomic::{AtomicBool, AtomicU32, Ordering},
            mpsc, Mutex,
        },
        thread,
        time::Duration,
    };
    const ID: i32 = 0x4147;
    const RETRY: u32 = 0x8001;
    const WM_QUIT: u32 = 0x0012;
    const WM_HOTKEY: u32 = 0x0312;
    const MOD_CONTROL: u32 = 0x0002;
    const MOD_NOREPEAT: u32 = 0x4000;
    #[derive(Clone, Copy)]
    struct Key {
        modifiers: u32,
        code: u32,
    }
    const DOCK_KEY: Key = Key {
        modifiers: MOD_CONTROL | MOD_NOREPEAT,
        code: 0x49,
    };
    #[repr(C)]
    #[derive(Default)]
    struct Point {
        x: i32,
        y: i32,
    }
    #[repr(C)]
    #[derive(Default)]
    struct Message {
        hwnd: *mut c_void,
        message: u32,
        wparam: usize,
        lparam: isize,
        time: u32,
        point: Point,
        private: u32,
    }
    #[link(name = "user32")]
    extern "system" {
        fn RegisterHotKey(hwnd: *mut c_void, id: i32, modifiers: u32, key: u32) -> i32;
        fn UnregisterHotKey(hwnd: *mut c_void, id: i32) -> i32;
        fn PeekMessageW(
            message: *mut Message,
            hwnd: *mut c_void,
            first: u32,
            last: u32,
            remove: u32,
        ) -> i32;
        fn GetMessageW(message: *mut Message, hwnd: *mut c_void, first: u32, last: u32) -> i32;
        fn PostThreadMessageW(thread: u32, message: u32, wparam: usize, lparam: isize) -> i32;
    }
    #[link(name = "kernel32")]
    extern "system" {
        fn GetCurrentThreadId() -> u32;
        fn GetLastError() -> u32;
    }
    fn register(key: Key) -> ShortcutStatus {
        if unsafe { RegisterHotKey(std::ptr::null_mut(), ID, key.modifiers, key.code) } != 0 {
            ShortcutStatus::Registered
        } else if unsafe { GetLastError() } == 1409 {
            ShortcutStatus::Occupied
        } else {
            ShortcutStatus::Failed
        }
    }
    pub struct Owner {
        thread_id: Arc<AtomicU32>,
        stopping: Arc<AtomicBool>,
        reply: Arc<Mutex<Option<mpsc::SyncSender<ShortcutStatus>>>>,
        operation: Mutex<()>,
        done: Mutex<mpsc::Receiver<bool>>,
        join: Mutex<Option<thread::JoinHandle<()>>>,
    }
    impl Owner {
        pub fn start(
            toggle: Arc<dyn Fn() + Send + Sync>,
            status: Arc<dyn Fn(ShortcutStatus) + Send + Sync>,
        ) -> Result<Self, &'static str> {
            Self::start_key(DOCK_KEY, toggle, status)
        }
        fn start_key(
            key: Key,
            toggle: Arc<dyn Fn() + Send + Sync>,
            status: Arc<dyn Fn(ShortcutStatus) + Send + Sync>,
        ) -> Result<Self, &'static str> {
            let thread_id = Arc::new(AtomicU32::new(0));
            let stopping = Arc::new(AtomicBool::new(false));
            let reply: Arc<Mutex<Option<mpsc::SyncSender<ShortcutStatus>>>> =
                Arc::new(Mutex::new(None));
            let (ready_tx, ready_rx) = mpsc::sync_channel(1);
            let (done_tx, done_rx) = mpsc::sync_channel(1);
            let (id, stop, pending) = (thread_id.clone(), stopping.clone(), reply.clone());
            let join = thread::Builder::new()
                .name("compact-owned-shortcut".into())
                .spawn(move || {
                    let mut message = Message::default();
                    // Create this thread's message queue before publishing its ID.
                    unsafe {
                        PeekMessageW(&mut message, std::ptr::null_mut(), 0, 0, 0);
                    }
                    id.store(unsafe { GetCurrentThreadId() }, Ordering::Release);
                    if ready_tx.send(()).is_err() || stop.load(Ordering::Acquire) {
                        let _ = done_tx.send(true);
                        return;
                    }
                    let mut current = register(key);
                    let notify = |value| {
                        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                            status(value)
                        }));
                    };
                    notify(current);
                    let mut clean = true;
                    while !stop.load(Ordering::Acquire) {
                        let result =
                            unsafe { GetMessageW(&mut message, std::ptr::null_mut(), 0, 0) };
                        if result <= 0 {
                            clean &= result == 0;
                            break;
                        }
                        if message.message == WM_HOTKEY
                            && message.wparam == ID as usize
                            && current == ShortcutStatus::Registered
                        {
                            if !stop.load(Ordering::Acquire)
                                && std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                                    toggle()
                                }))
                                .is_err()
                            {
                                clean = false;
                                break;
                            }
                        } else if message.message == RETRY {
                            if current != ShortcutStatus::Registered {
                                current = register(key);
                            }
                            notify(current);
                            if let Ok(mut pending) = pending.lock() {
                                if let Some(reply) = pending.take() {
                                    let _ = reply.send(current);
                                }
                            }
                        }
                    }
                    if !stop.load(Ordering::Acquire) {
                        notify(ShortcutStatus::Failed);
                    }
                    if current == ShortcutStatus::Registered {
                        clean &= unsafe { UnregisterHotKey(std::ptr::null_mut(), ID) } != 0;
                    }
                    stop.store(true, Ordering::Release);
                    let _ = done_tx.send(clean);
                })
                .map_err(|_| "compact_shortcut_unavailable")?;
            if ready_rx.recv_timeout(Duration::from_secs(2)).is_err() {
                stopping.store(true, Ordering::Release);
                let id = thread_id.load(Ordering::Acquire);
                if id != 0 {
                    unsafe {
                        PostThreadMessageW(id, WM_QUIT, 0, 0);
                    }
                }
                return Err("compact_shortcut_unavailable");
            }
            Ok(Self {
                thread_id,
                stopping,
                reply,
                operation: Mutex::new(()),
                done: Mutex::new(done_rx),
                join: Mutex::new(Some(join)),
            })
        }
        pub fn retry(&self) -> Result<ShortcutStatus, &'static str> {
            let _operation = self
                .operation
                .lock()
                .map_err(|_| "compact_shortcut_unavailable")?;
            if self.stopping.load(Ordering::Acquire) {
                return Err("compact_shortcut_unavailable");
            }
            let (sent, received) = mpsc::sync_channel(1);
            *self
                .reply
                .lock()
                .map_err(|_| "compact_shortcut_unavailable")? = Some(sent);
            if unsafe { PostThreadMessageW(self.thread_id.load(Ordering::Acquire), RETRY, 0, 0) }
                == 0
            {
                if let Ok(mut pending) = self.reply.lock() {
                    pending.take();
                }
                return Err("compact_shortcut_unavailable");
            }
            received
                .recv_timeout(Duration::from_secs(2))
                .map_err(|_| "compact_shortcut_unavailable")
        }
        pub fn shutdown(&self) -> bool {
            let Ok(_operation) = self.operation.lock() else {
                return false;
            };
            let Ok(mut join) = self.join.lock() else {
                return false;
            };
            if join.is_none() {
                return true;
            }
            self.stopping.store(true, Ordering::Release);
            if unsafe { PostThreadMessageW(self.thread_id.load(Ordering::Acquire), WM_QUIT, 0, 0) }
                == 0
            {
                return false;
            }
            let clean = self
                .done
                .lock()
                .ok()
                .and_then(|done| done.recv_timeout(Duration::from_secs(2)).ok());
            match clean {
                Some(clean) => join.take().is_some_and(|thread| thread.join().is_ok()) && clean,
                None => false,
            }
        }
    }
    impl Drop for Owner {
        fn drop(&mut self) {
            let _ = self.shutdown();
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::sync::atomic::AtomicUsize;
        #[test]
        fn native_registration_conflict_retry_callback_and_owned_cleanup() {
            // Isolated non-product chord; no actual keyboard input is injected.
            let key = Key {
                modifiers: MOD_CONTROL | MOD_NOREPEAT | 0x0001 | 0x0004,
                code: 0x87,
            };
            let calls = Arc::new(AtomicUsize::new(0));
            let count = calls.clone();
            let first = Owner::start_key(
                key,
                Arc::new(move || {
                    count.fetch_add(1, Ordering::AcqRel);
                }),
                Arc::new(|_| {}),
            )
            .unwrap();
            assert_eq!(first.retry().unwrap(), ShortcutStatus::Registered);
            let second = Owner::start_key(key, Arc::new(|| {}), Arc::new(|_| {})).unwrap();
            assert_eq!(second.retry().unwrap(), ShortcutStatus::Occupied);
            unsafe {
                assert_ne!(
                    PostThreadMessageW(
                        first.thread_id.load(Ordering::Acquire),
                        WM_HOTKEY,
                        ID as usize,
                        0
                    ),
                    0
                );
            }
            // This acknowledged command runs after the posted hotkey on its queue.
            assert_eq!(first.retry().unwrap(), ShortcutStatus::Registered);
            assert_eq!(calls.load(Ordering::Acquire), 1);
            assert!(first.shutdown());
            assert!(first.retry().is_err());
            assert_eq!(second.retry().unwrap(), ShortcutStatus::Registered);
            assert!(second.shutdown());
        }
    }
}
#[cfg(windows)]
pub use native::Owner;

#[cfg(not(windows))]
pub struct Owner;
#[cfg(not(windows))]
impl Owner {
    pub fn start(
        _toggle: Arc<dyn Fn() + Send + Sync>,
        _status: Arc<dyn Fn(ShortcutStatus) + Send + Sync>,
    ) -> Result<Self, &'static str> {
        Err("windows_required")
    }
    pub fn retry(&self) -> Result<ShortcutStatus, &'static str> {
        Err("windows_required")
    }
    pub fn shutdown(&self) -> bool {
        true
    }
}
