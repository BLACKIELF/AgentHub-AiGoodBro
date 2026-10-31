//! Explicit local Codex CLI selection. No account, model or installation action.
mod probe;
mod store;
use crate::accounts::{AccountError, AccountResult};
pub use probe::{automatic_candidates, NativeProbe, Probe};
use serde::Serialize;
pub use store::{PinnedExecutable, SelectionStore};
pub type Result<T> = AccountResult<T>;
pub(crate) fn fail(code: &'static str) -> AccountError {
    AccountError { code }
}
/// Any failure of the final root/Job proof is uncertain, regardless of the
/// underlying query or permit error. Scratch cleanup must not infer termination.
pub(crate) fn require_confirmed_cleanup(result: Result<()>) -> Result<()> {
    result.map_err(|_| fail("cleanup_unconfirmed"))
}
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeView {
    pub state: &'static str,
    pub version: Option<String>,
    pub selected: bool,
    pub issue_code: Option<&'static str>,
}
impl RuntimeView {
    fn ready(version: String, selected: bool) -> Self {
        Self {
            state: "ready",
            version: Some(version),
            selected,
            issue_code: None,
        }
    }
    fn failed(code: &'static str, selected: bool) -> Self {
        Self {
            state: if code == "runtime_not_found" {
                "missing"
            } else {
                "unavailable"
            },
            version: None,
            selected,
            issue_code: Some(code),
        }
    }
}
#[cfg(test)]
mod tests;
