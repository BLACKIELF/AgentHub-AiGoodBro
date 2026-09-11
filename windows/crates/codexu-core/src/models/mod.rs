//! Core domain models for codexU.
//!
//! Two families live here:
//!
//! * `leadership`, `runtime` and `usage` are direct translations of the Swift
//!   structs in the macOS version. They must remain semantically compatible so
//!   that the Windows UI can consume the same JSON shape produced by
//!   `codexU --dump-json` on macOS.
//! * `account`, `quota` and `occupancy` are the Windows AgentHub workbench
//!   domain. They carry the *product semantics* of the macOS workbench
//!   (unknown is not zero, heartbeat timeout is not idle, automation is
//!   fail-closed) without copying the macOS module layout.
//!
//! None of these types may carry credential material, raw account email, prompt
//! or response bodies, or absolute local paths.

pub mod account;
pub mod automatic_switch;
pub mod dispatch;
pub mod leadership;
pub mod local_cli;
pub mod messaging;
pub mod occupancy;
pub mod quota;
pub mod runtime;
pub mod usage;
pub mod warmup;

pub use account::*;
pub use automatic_switch::*;
pub use dispatch::*;
pub use leadership::*;
pub use local_cli::*;
pub use messaging::*;
pub use occupancy::*;
pub use quota::*;
pub use runtime::*;
pub use usage::*;
pub use warmup::*;
