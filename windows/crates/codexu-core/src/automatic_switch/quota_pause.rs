//! Native-only coordination between the complete daemon roster and original
//! GUI owners. None of these inputs can be supplied over WebView IPC.
use super::{live::LiveTaskSnapshot, Result};
use crate::{accounts::ActiveSystemScope, managed_proxy::AutomaticMaintenanceLease};
use std::sync::Arc;

pub type PauseAdmission = Arc<dyn Fn() -> bool + Send + Sync>;

pub struct QuotaPauseRequest {
    pub snapshot: Arc<LiveTaskSnapshot>,
    pub source: ActiveSystemScope,
    pub target_profile_id: String,
    pub target_identity_hash: String,
    pub target_credential_generation: String,
    pub lease: AutomaticMaintenanceLease,
    pub admission: PauseAdmission,
}

pub struct QuotaPauseReceipt {
    pub batch_id: String,
}

pub trait QuotaPauseController: Send + Sync {
    /// A pending batch blocks later automatic switching even after restart or
    /// after settings select a different source. This is a bounded disk read.
    fn has_unresolved(&self) -> Result<bool>;
    /// Persist the full batch before the first interrupt. Return only after
    /// exact original turns stopped and a fresh unchanged roster is idle.
    /// Partial failure must retain the journal and uncertain native holds.
    fn pause(&self, request: QuotaPauseRequest) -> Result<Option<QuotaPauseReceipt>>;
    /// Called only after the normal guarded account transaction committed.
    /// Arming the record does not send a continuation request or open a GUI.
    fn switch_verified(
        &self,
        receipt: &QuotaPauseReceipt,
        target: &ActiveSystemScope,
        lease: &AutomaticMaintenanceLease,
    ) -> Result<()>;
}
