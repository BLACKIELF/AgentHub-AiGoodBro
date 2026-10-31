//! Existing Mac message-channel semantics at a native Windows boundary.
//! Secrets and raw remote responses never form a WebView DTO.
mod domain;
mod events;
mod manual_reset;
mod personal;
mod protocol;
mod public_reset;
mod service;
mod storage;
mod system;
mod task_completion;
mod transport;

pub use domain::*;
pub use events::{OfficialQuotaObservation, OfficialRateWindow, ResetCard};
pub use manual_reset::{ManualResetAuthorization, ManualResetNotice};
pub use personal::PersonalLoginDto;
pub use public_reset::{
    NativePublicResetSource, PublicResetAnnouncementDto, PublicResetDeliveryState,
    PublicResetForecastDto, PublicResetRequest, PublicResetResponse, PublicResetSource,
};
pub use service::NotificationMonitor;
pub use service::{NotificationService, PersonalTextReceipt};
pub use system::SystemNotificationPermission;
pub use task_completion::NativeTaskCompletionProducer;
pub use transport::{
    NativeNotificationTransport, NotificationTransport, TransportRequest, TransportResponse,
};

pub type Result<T> = std::result::Result<T, Failure>;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Failure(pub &'static str);
impl Failure {
    pub fn code(self) -> &'static str {
        self.0
    }
}
impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}
impl std::error::Error for Failure {}
fn fail<T>(code: &'static str) -> Result<T> {
    Err(Failure(code))
}
fn now() -> i64 {
    chrono::Utc::now().timestamp()
}
fn nonce() -> Result<String> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).map_err(|_| Failure("entropy_unavailable"))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}
fn hash(bytes: &[u8]) -> String {
    use sha2::Digest;
    format!("{:x}", sha2::Sha256::digest(bytes))
}
fn valid_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
