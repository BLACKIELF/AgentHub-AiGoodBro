//! Backend-only display projection. It has no Deserialize/API for WebView writes
//! and never performs quota, vault, transcript or network reads.
use super::model::safe_id;
use serde::Serialize;
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaWindow {
    pub id: String,
    pub label: String,
    pub used_percent: Option<f64>,
    pub resets_at: Option<i64>,
}
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    pub id: String,
    pub provider_id: String,
    pub label: String,
    pub logged_in: bool,
    pub active: Option<bool>,
    pub observed_at: Option<i64>,
    pub available: bool,
    pub reason_code: Option<String>,
    pub plan_type: Option<String>,
    pub windows: Vec<QuotaWindow>,
    pub credits_usd: Option<f64>,
    pub credit_points: Option<String>,
    pub reset_cards: Option<u32>,
}
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Proxy {
    pub phase: String,
    pub egress_state: Option<String>,
    pub active_requests: Option<u64>,
    pub observed_at: Option<i64>,
}
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CachedProjection {
    pub accounts: Vec<Account>,
    pub proxy: Option<Proxy>,
    pub session_count: Option<u64>,
}
fn label(value: &str) -> bool {
    !value.is_empty()
        && (value.len() <= 256 || codexu_core::accounts::metadata::valid_display_label(value))
        && !value.chars().any(char::is_control)
        && !value.contains(['@', '\\'])
        && !value.starts_with('/')
        && !value.contains("://")
}
fn code(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
}
impl CachedProjection {
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.accounts.len() > 256 {
            return Err("compact_invalid_projection");
        }
        let mut ids = std::collections::BTreeSet::new();
        for account in &self.accounts {
            if !safe_id(&account.id)
                || !safe_id(&account.provider_id)
                || !ids.insert(&account.id)
                || !label(&account.label)
                || account.observed_at.is_some_and(|value| value < 0)
                || account
                    .reason_code
                    .as_ref()
                    .is_some_and(|value| !code(value))
                || account
                    .plan_type
                    .as_ref()
                    .is_some_and(|value| !label(value))
                || account.windows.len() > 64
                || account
                    .credits_usd
                    .is_some_and(|value| !value.is_finite() || value < 0.)
                || account.credit_points.as_ref().is_some_and(|value| {
                    value.is_empty()
                        || value.len() > 64
                        || !value
                            .bytes()
                            .all(|byte| byte.is_ascii_digit() || byte == b'.')
                })
            {
                return Err("compact_invalid_projection");
            }
            let mut windows = std::collections::BTreeSet::new();
            for window in &account.windows {
                if !label(&window.id)
                    || !windows.insert(&window.id)
                    || !label(&window.label)
                    || window
                        .used_percent
                        .is_some_and(|value| !value.is_finite() || !(0. ..=100.).contains(&value))
                    || window.resets_at.is_some_and(|value| value < 0)
                {
                    return Err("compact_invalid_projection");
                }
            }
        }
        if self.proxy.as_ref().is_some_and(|proxy| {
            !code(&proxy.phase)
                || proxy
                    .egress_state
                    .as_ref()
                    .is_some_and(|value| !code(value))
                || proxy.observed_at.is_some_and(|value| value < 0)
        }) {
            return Err("compact_invalid_projection");
        }
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unavailable_cache_is_not_a_zero_or_a_running_session() {
        let value = serde_json::to_value(CachedProjection::default()).unwrap();
        assert!(value["accounts"].as_array().unwrap().is_empty());
        assert!(value["proxy"].is_null());
        assert!(value["sessionCount"].is_null());
    }
}
