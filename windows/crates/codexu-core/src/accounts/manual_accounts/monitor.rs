//! Durable confirmation relay only. It never performs account/network actions.
use super::*;
use std::sync::mpsc::{self, Sender};
use std::thread::JoinHandle;
use std::time::Duration;
pub struct ManualAccountMonitor {
    cancel: Sender<()>,
    join: Option<JoinHandle<()>>,
}
impl ManualAccountMonitor {
    pub fn cancel(&self) {
        let _ = self.cancel.send(());
    }
}
impl Drop for ManualAccountMonitor {
    fn drop(&mut self) {
        self.cancel();
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}
impl ManualAccountService {
    pub fn start_confirmation_monitor(
        self: &Arc<Self>,
        record: Arc<dyn Fn(&ManualResetConfirmation) -> AccountResult<()> + Send + Sync>,
    ) -> AccountResult<ManualAccountMonitor> {
        let weak = Arc::downgrade(self);
        let (tx, rx) = mpsc::channel();
        let join = std::thread::Builder::new()
            .name("manual-reset-receipts".into())
            .spawn(move || loop {
                let Some(service) = weak.upgrade() else { break };
                if service.exiting.load(Ordering::Acquire) {
                    break;
                }
                let _ = service.drain_confirmed(|event| record(event));
                drop(service);
                if rx.recv_timeout(Duration::from_secs(5)) != Err(mpsc::RecvTimeoutError::Timeout) {
                    break;
                }
            })
            .map_err(|_| fail("manual_action_unavailable"))?;
        Ok(ManualAccountMonitor {
            cancel: tx,
            join: Some(join),
        })
    }
}
