mod ledger;
mod models;
mod source;
mod worker;
pub(crate) use ledger::PublicData;
pub use source::{
    NativePublicResetSource, PublicResetRequest, PublicResetResponse, PublicResetSource,
};
use std::sync::{
    atomic::{AtomicBool, AtomicI64},
    Arc, Mutex, RwLock,
};
pub use worker::{PublicResetAnnouncementDto, PublicResetDeliveryState, PublicResetForecastDto};
pub(crate) struct Runtime {
    pub source: RwLock<Arc<dyn PublicResetSource>>,
    pub active: Mutex<Option<Arc<AtomicBool>>>,
    pub requested: AtomicBool,
    pub checking: AtomicBool,
    pub next_check: AtomicI64,
    pub view: Mutex<worker::View>,
}
impl Default for Runtime {
    fn default() -> Self {
        Self {
            source: RwLock::new(Arc::new(source::UnavailableSource)),
            active: Mutex::new(None),
            requested: AtomicBool::new(false),
            checking: AtomicBool::new(false),
            next_check: AtomicI64::new(0),
            view: Mutex::new(worker::View::default()),
        }
    }
}
impl Runtime {
    pub fn cancel(&self) {
        if let Ok(active) = self.active.try_lock() {
            if let Some(c) = active.as_ref() {
                c.store(true, std::sync::atomic::Ordering::Release);
            }
        }
    }
}
