//! In-memory native ownership, never a substitute for dispatch/task activity.
//! A receipt can be issued only from real retained Job and root handles.
use super::{LiveIssue, LiveResult};
use std::sync::Arc;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum OwnedDomainPurpose {
    PassiveStatistics,
    ManagedConsole,
}

pub struct OwnedProcessDomains {
    #[cfg(windows)]
    state: std::sync::Mutex<Vec<Arc<native::Receipt>>>,
}
impl OwnedProcessDomains {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            #[cfg(windows)]
            state: std::sync::Mutex::new(Vec::new()),
        })
    }
    /// # Safety
    /// The native producer must own this exact kill-on-close Job and its root,
    /// and retain verified executable/resources for its fixed launch behavior.
    /// Register before the suspended root resumes (or before an inert statistics
    /// host receives configure). No handle, purpose or guard may come from IPC.
    #[cfg(windows)]
    pub unsafe fn register_native(
        self: &Arc<Self>,
        process: std::os::windows::io::BorrowedHandle<'_>,
        job: std::os::windows::io::BorrowedHandle<'_>,
        resources: Arc<dyn Send + Sync>,
        purpose: OwnedDomainPurpose,
    ) -> LiveResult<OwnedDomainRegistration> {
        let receipt = Arc::new(native::Receipt::capture(process, job, resources, purpose)?);
        let mut state = self.state.lock().map_err(|_| LiveIssue::Incomplete)?;
        state.retain(|old| !old.confirmed_empty().unwrap_or(false));
        if state.len() >= 64 {
            return Err(LiveIssue::Overflow);
        }
        state.push(receipt.clone());
        Ok(OwnedDomainRegistration {
            registry: Arc::downgrade(self),
            receipt,
        })
    }
    #[cfg(windows)]
    pub(super) fn contains(&self, process: usize, created: u64) -> LiveResult<bool> {
        let mut state = self.state.try_lock().map_err(|_| LiveIssue::Incomplete)?;
        state.retain(|receipt| !receipt.confirmed_empty().unwrap_or(false));
        let mut member = false;
        for receipt in state.iter() {
            if receipt.detached.load(std::sync::atomic::Ordering::Acquire) {
                return Err(LiveIssue::Incomplete);
            }
            member |= receipt.contains(process, created)?;
        }
        Ok(member)
    }
}

pub struct OwnedDomainRegistration {
    #[cfg(windows)]
    registry: std::sync::Weak<OwnedProcessDomains>,
    #[cfg(windows)]
    receipt: Arc<native::Receipt>,
}
impl Drop for OwnedDomainRegistration {
    fn drop(&mut self) {
        #[cfg(windows)]
        if let Some(registry) = self.registry.upgrade() {
            if self.receipt.confirmed_empty() == Ok(true) {
                if let Ok(mut state) = registry.state.lock() {
                    state.retain(|r| !Arc::ptr_eq(r, &self.receipt));
                }
            } else {
                // Dropping a failed owner must neither forget its process nor
                // treat an unconfirmed cleanup as a passive/idle domain.
                self.receipt
                    .detached
                    .store(true, std::sync::atomic::Ordering::Release);
            }
        }
    }
}

#[cfg(windows)]
mod native {
    use super::*;
    use std::{
        ffi::c_void,
        os::windows::io::{AsRawHandle, BorrowedHandle},
        sync::atomic::AtomicBool,
    };
    type Handle = *mut c_void;
    #[repr(C)]
    #[derive(Default)]
    struct Basic {
        process_time: i64,
        job_time: i64,
        flags: u32,
        min: usize,
        max: usize,
        active: u32,
        affinity: usize,
        priority: u32,
        scheduling: u32,
    }
    #[repr(C)]
    #[derive(Default)]
    struct Extended {
        basic: Basic,
        io: [u64; 6],
        process_memory: usize,
        job_memory: usize,
        peak_process: usize,
        peak_job: usize,
    }
    #[repr(C)]
    #[derive(Default)]
    struct Accounting {
        times: [i64; 4],
        faults: u32,
        total: u32,
        active: u32,
        terminated: u32,
    }
    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    struct FileTime {
        low: u32,
        high: u32,
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetCurrentProcess() -> Handle;
        fn DuplicateHandle(
            source: Handle,
            handle: Handle,
            target: Handle,
            result: *mut Handle,
            access: u32,
            inherit: i32,
            options: u32,
        ) -> i32;
        fn CloseHandle(handle: Handle) -> i32;
        fn WaitForSingleObject(handle: Handle, timeout: u32) -> u32;
        fn IsProcessInJob(process: Handle, job: Handle, value: *mut i32) -> i32;
        fn GetProcessTimes(
            process: Handle,
            created: *mut FileTime,
            exit: *mut FileTime,
            kernel: *mut FileTime,
            user: *mut FileTime,
        ) -> i32;
        fn QueryInformationJobObject(
            job: Handle,
            class: i32,
            info: *mut c_void,
            length: u32,
            returned: *mut u32,
        ) -> i32;
    }
    struct Held(usize);
    impl Held {
        fn raw(&self) -> Handle {
            self.0 as Handle
        }
    }
    impl Drop for Held {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.raw());
            }
        }
    }
    fn duplicate(handle: BorrowedHandle<'_>) -> LiveResult<Held> {
        let mut copy = std::ptr::null_mut();
        let current = unsafe { GetCurrentProcess() };
        if unsafe {
            DuplicateHandle(
                current,
                handle.as_raw_handle().cast(),
                current,
                &mut copy,
                0,
                0,
                2,
            )
        } == 0
            || copy.is_null()
        {
            return Err(LiveIssue::Incomplete);
        }
        Ok(Held(copy as usize))
    }
    fn created(process: Handle) -> LiveResult<u64> {
        let mut time = [FileTime::default(); 4];
        let ptr = time.as_mut_ptr();
        if unsafe { GetProcessTimes(process, ptr, ptr.add(1), ptr.add(2), ptr.add(3)) } == 0 {
            return Err(LiveIssue::Incomplete);
        }
        let value = (u64::from(time[0].high) << 32) | u64::from(time[0].low);
        if value == 0 {
            return Err(LiveIssue::Incomplete);
        }
        Ok(value)
    }
    pub(super) struct Receipt {
        process: Held,
        job: Held,
        created: u64,
        _resources: Arc<dyn Send + Sync>,
        _purpose: OwnedDomainPurpose,
        pub detached: AtomicBool,
    }
    impl Receipt {
        pub fn capture(
            process: BorrowedHandle<'_>,
            job: BorrowedHandle<'_>,
            resources: Arc<dyn Send + Sync>,
            purpose: OwnedDomainPurpose,
        ) -> LiveResult<Self> {
            let process = duplicate(process)?;
            let job = duplicate(job)?;
            let mut limits = Extended::default();
            if unsafe {
                QueryInformationJobObject(
                    job.raw(),
                    9,
                    (&mut limits as *mut Extended).cast(),
                    std::mem::size_of::<Extended>() as u32,
                    std::ptr::null_mut(),
                )
            } == 0
                || limits.basic.flags & 0x2000 == 0
                || limits.basic.flags & (0x800 | 0x1000) != 0
            {
                return Err(LiveIssue::Incomplete);
            }
            let birth = created(process.raw())?;
            let receipt = Self {
                process,
                job,
                created: birth,
                _resources: resources,
                _purpose: purpose,
                detached: AtomicBool::new(false),
            };
            if unsafe { WaitForSingleObject(receipt.process.raw(), 0) } != 258
                || !receipt.contains(receipt.process.0, birth)?
            {
                return Err(LiveIssue::Incomplete);
            }
            Ok(receipt)
        }
        pub fn contains(&self, process: usize, birth: u64) -> LiveResult<bool> {
            if process == 0
                || birth < self.created
                || created(self.process.raw())? != self.created
                || created(process as Handle)? != birth
            {
                return Ok(false);
            }
            let mut member = 0;
            if unsafe { IsProcessInJob(process as Handle, self.job.raw(), &mut member) } == 0 {
                return Err(LiveIssue::Incomplete);
            }
            Ok(member != 0)
        }
        pub fn confirmed_empty(&self) -> LiveResult<bool> {
            let mut info = Accounting::default();
            if unsafe {
                QueryInformationJobObject(
                    self.job.raw(),
                    1,
                    (&mut info as *mut Accounting).cast(),
                    std::mem::size_of::<Accounting>() as u32,
                    std::ptr::null_mut(),
                )
            } == 0
            {
                return Err(LiveIssue::Incomplete);
            }
            match unsafe { WaitForSingleObject(self.process.raw(), 0) } {
                0 => Ok(info.active == 0),
                258 => Ok(false),
                _ => Err(LiveIssue::Incomplete),
            }
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::{
            io::Read,
            os::windows::io::AsHandle,
            process::{Child, Command, Stdio},
            time::{Duration, Instant},
        };
        #[link(name = "kernel32")]
        unsafe extern "system" {
            fn CreateJobObjectW(attributes: *const c_void, name: *const u16) -> Handle;
            fn SetInformationJobObject(
                job: Handle,
                class: i32,
                info: *const c_void,
                length: u32,
            ) -> i32;
            fn AssignProcessToJobObject(job: Handle, process: Handle) -> i32;
        }
        const HELPER: &str =
            "automatic_switch::live::owned_domains::native::tests::owned_domain_child_fixture";
        #[test]
        fn owned_domain_child_fixture() {
            if std::env::var_os("AIGOODBRO_OWNED_DOMAIN_FIXTURE").is_some() {
                std::io::stdin().read_to_end(&mut Vec::new()).unwrap();
            }
        }
        struct ChildGuard(Child);
        impl Drop for ChildGuard {
            fn drop(&mut self) {
                let _ = self.0.kill();
                let _ = self.0.wait();
            }
        }
        fn child() -> ChildGuard {
            ChildGuard(
                Command::new(std::env::current_exe().unwrap())
                    .args(["--exact", HELPER, "--test-threads=1"])
                    .env("AIGOODBRO_OWNED_DOMAIN_FIXTURE", "1")
                    .stdin(Stdio::piped())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                    .unwrap(),
            )
        }
        #[test]
        fn owned_domain_uses_exact_job_not_same_executable_or_reused_pid_and_retains_failed_cleanup(
        ) {
            let mut own = child();
            let mut unrelated = child();
            let raw = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
            assert!(!raw.is_null());
            let job = Held(raw as usize);
            let mut limits = Extended::default();
            limits.basic.flags = 0x2000;
            assert_ne!(
                unsafe {
                    SetInformationJobObject(
                        job.raw(),
                        9,
                        (&limits as *const Extended).cast(),
                        std::mem::size_of::<Extended>() as u32,
                    )
                },
                0
            );
            assert_ne!(
                unsafe { AssignProcessToJobObject(job.raw(), own.0.as_raw_handle().cast()) },
                0
            );
            let registry = OwnedProcessDomains::new();
            let registration = unsafe {
                registry.register_native(
                    own.0.as_handle(),
                    BorrowedHandle::borrow_raw(job.raw()),
                    Arc::new(()),
                    OwnedDomainPurpose::PassiveStatistics,
                )
            }
            .unwrap();
            let birth = created(own.0.as_raw_handle().cast()).unwrap();
            assert!(registry
                .contains(own.0.as_raw_handle() as usize, birth)
                .unwrap());
            assert!(!registry
                .contains(own.0.as_raw_handle() as usize, birth + 1)
                .unwrap());
            assert!(!registry
                .contains(
                    unrelated.0.as_raw_handle() as usize,
                    created(unrelated.0.as_raw_handle().cast()).unwrap()
                )
                .unwrap());
            drop(registration);
            assert_eq!(
                registry.contains(own.0.as_raw_handle() as usize, birth),
                Err(LiveIssue::Incomplete)
            );
            drop(own.0.stdin.take());
            let deadline = Instant::now() + Duration::from_secs(5);
            while own.0.try_wait().unwrap().is_none() {
                assert!(Instant::now() < deadline);
                std::thread::sleep(Duration::from_millis(10));
            }
            assert!(!registry
                .contains(
                    unrelated.0.as_raw_handle() as usize,
                    created(unrelated.0.as_raw_handle().cast()).unwrap()
                )
                .unwrap());
            assert!(unrelated.0.try_wait().unwrap().is_none());
        }
    }
}
