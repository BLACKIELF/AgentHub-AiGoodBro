//! Windows host for the shared LocalProxy engine. Credentials are wire-only.
mod desktop;
mod gate;
mod host;
mod policy;
mod process;
mod recovery;

pub use desktop::{
    ProxyDesktopConnector, ProxyDesktopMonitor, ProxyDesktopPhase, ProxyDesktopStatus,
};
pub use gate::*;
pub use host::{BridgeReply, BridgeRequest, ProxyHost};
pub use policy::*;
pub use process::{
    LocalProxyService, ProxyConnection, ProxyEvent, ProxyPhase, ProxyRecoveryMonitor, ProxyStatus,
};
pub use recovery::{DesktopRecoveryKind, DesktopRecoveryProof, ProxyHelperRecoveryProof};

#[cfg(test)]
mod tests;
