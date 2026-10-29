//! Windows subscription accounts. OAuth stays in the official CLI and native
//! encrypted vault; this module never starts a model request or returns secrets.
mod cache;
mod identity;
mod native;
mod service;
mod storage;

pub use cache::ClaudeQuotaDisplaySnapshot;
pub use identity::{parse_claude_usage, ClaudeVerifiedCredential};
pub use native::NativeClaudeRuntime;
pub use service::{ClaudeOpenScope, ClaudeSubscriptionManager};
pub use storage::ClaudeAccountPaths;

use super::{AccountResult, ManagedAccountDto};
use crate::readers::local_cli_quota::LocalCliQuotaResult;
use serde::Serialize;
use std::{path::Path, sync::atomic::AtomicBool};

pub type ClaudeSubscriptionDto = ManagedAccountDto;
#[derive(Clone, Debug, Serialize)]
pub struct ClaudeLoginAttemptDto {
    pub attempt_id: String,
    pub phase: &'static str,
    pub error_code: Option<&'static str>,
}
#[derive(Clone, Debug, Serialize)]
pub struct ClaudeSubscriptionQuotaDto {
    #[serde(flatten)]
    pub quota: LocalCliQuotaResult,
    pub server_retry_at: Option<i64>,
}
/// Raw response remains Rust-only. Native transport is fixed to Anthropic,
/// rejects redirects and enforces certificate validation and bounded bodies.
pub struct ClaudeUsageResponse {
    pub status: u16,
    pub body: Vec<u8>,
    pub retry_after: Option<String>,
}
pub trait ClaudeSubscriptionRuntime: Send + Sync {
    fn available(&self) -> bool;
    /// Uses only the supplied private CLAUDE_CONFIG_DIR and owned child Job.
    fn login(
        &self,
        directory: &Path,
        cancelled: &AtomicBool,
        waiting: &mut dyn FnMut(),
    ) -> AccountResult<ClaudeVerifiedCredential>;
    fn verify(
        &self,
        credential: &[u8],
        oauth_account: &serde_json::Value,
    ) -> AccountResult<ClaudeVerifiedCredential>;
    fn usage(&self, credential: &[u8]) -> AccountResult<ClaudeUsageResponse>;
    /// May consume a rotating refresh grant, even if the response is lost.
    fn refresh(&self, credential: &[u8]) -> AccountResult<Vec<u8>>;
    fn require_system_idle(&self) -> AccountResult<()>;
    fn validate_environment(&self) -> AccountResult<()>;
}
