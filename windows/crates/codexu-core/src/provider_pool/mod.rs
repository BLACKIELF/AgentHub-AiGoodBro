//! Explicit, isolated host for the pinned multi-provider OAuth helper.
//! This module never imports a CLI/browser credential or discovers other processes.
mod domain;
pub mod client;
mod host;
mod process;
mod storage;

pub use domain::{AccountState, AccountView, AuthorizationView, Phase, PoolSnapshot, Provider};
pub use host::{AuthorizationBrowser, NativeConnection, ProviderPool};
pub use process::HelperResource;

#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
#[error("{code}")]
pub struct Error {
    pub code: &'static str,
}
pub type Result<T> = std::result::Result<T, Error>;
fn fail(code: &'static str) -> Error {
    Error { code }
}
fn nonce() -> Result<String> {
    use base64::Engine;
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).map_err(|_| fail("provider_pool_unavailable"))?;
    Ok(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes))
}

#[cfg(test)]
mod tests;
