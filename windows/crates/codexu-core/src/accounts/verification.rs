//! Private native process receipts for one maintenance-owned official verify.
//! No PID, handle, job or constructor is accepted from IPC or a caller fixture.
use super::AccountResult;
#[cfg(windows)]
use std::sync::Arc;

#[derive(Clone)]
pub struct OwnedVerificationProcess {
    #[cfg(windows)]
    inner: Arc<super::native::process::VerificationReceipt>,
}
impl OwnedVerificationProcess {
    #[cfg(windows)]
    pub(super) fn native(receipt: super::native::process::VerificationReceipt) -> Self {
        Self {
            inner: Arc::new(receipt),
        }
    }
    #[cfg(windows)]
    pub(crate) fn contains_process(&self, handle: usize, created: u64) -> AccountResult<bool> {
        self.inner.contains_process(handle, created)
    }
    #[cfg(windows)]
    pub(crate) fn confirmed_empty(&self) -> AccountResult<bool> {
        self.inner.confirmed_empty()
    }
    pub(crate) fn same(&self, other: &Self) -> bool {
        #[cfg(windows)]
        {
            Arc::ptr_eq(&self.inner, &other.inner)
        }
        #[cfg(not(windows))]
        {
            let _ = other;
            false
        }
    }
}

/// Runtime-only observer. A process is registered while suspended in its
/// existing kill-on-close Job; completion requires positive whole-job exit.
pub trait VerificationProcessPermit: Send + Sync {
    fn recheck(&self) -> AccountResult<()>;
    fn begin_spawn(&self) -> AccountResult<Box<dyn VerificationSpawnLease>>;
    fn register(&self, process: OwnedVerificationProcess) -> AccountResult<()>;
    fn completed(&self, process: &OwnedVerificationProcess) -> AccountResult<()>;
}
pub trait VerificationSpawnLease: Send {}
