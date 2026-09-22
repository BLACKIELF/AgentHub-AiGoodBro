//! Directory-scoped interactive CLI preferences and preflight rules.
//! No prompts, credentials or local paths are projected into the UI.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WorkflowPreference {
    pub participating: bool,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub revision: u64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WorkflowPreferences {
    pub profiles: BTreeMap<u64, WorkflowPreference>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct WorkflowModel {
    pub id: String,
    pub label: String,
    pub efforts: Vec<String>,
    pub default_effort: String,
    pub is_default: bool,
}

pub const EXTERNAL_API_ENVIRONMENT: &[&str] = &[
    "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_BASE_URL",
    "CODEX_THREAD_ID", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "OPENAI_ORG_ID",
    "OPENAI_PROJECT_ID", "AZURE_OPENAI_API_KEY", "AZURE_OPENAI_ENDPOINT",
];

/// Subscription calls use the ChatGPT Codex endpoint, not the API-key endpoint.
/// Whole-table override also clears inherited env_key, headers and custom
/// endpoints. These flags affect this child only; no config file is edited.
pub fn official_arguments() -> Vec<String> {
    [
        "model_provider=\"openai\"",
        "model_providers={openai={name=\"OpenAI\",base_url=\"https://chatgpt.com/backend-api/codex\",wire_api=\"responses\",requires_openai_auth=true}}",
        "chatgpt_base_url=\"https://chatgpt.com/backend-api/\"",
        "forced_login_method=\"chatgpt\"",
        "cli_auth_credentials_store=\"file\"",
    ].into_iter().flat_map(|value| ["--config".to_owned(), value.to_owned()]).collect()
}

pub fn valid_model(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 80
        && value.bytes().all(|c| c.is_ascii_alphanumeric() || b"-_.".contains(&c))
}

pub fn valid_effort(value: &str) -> bool {
    matches!(value, "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max" | "ultra")
}

impl WorkflowPreferences {
    pub fn validate(&self) -> anyhow::Result<()> {
        anyhow::ensure!(self.profiles.len() <= 1000, "Too many workflow records");
        for (id, value) in &self.profiles {
            anyhow::ensure!(*id > 0, "Invalid profile ID");
            anyhow::ensure!(value.model.as_deref().is_none_or(valid_model), "Invalid model");
            anyhow::ensure!(value.effort.as_deref().is_none_or(valid_effort), "Invalid effort");
            anyhow::ensure!(value.model.is_some() || value.effort.is_none(), "Select a model first");
        }
        Ok(())
    }

    pub fn set_participating(&mut self, id: u64, value: bool) -> anyhow::Result<()> {
        self.validate()?;
        let preference = self.profiles.entry(id).or_default();
        preference.participating = value;
        preference.revision = preference.revision.checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("Preference revision exhausted"))?;
        self.validate()
    }

    pub fn set_selection(&mut self, id: u64, model: Option<String>, effort: Option<String>) -> anyhow::Result<()> {
        self.validate()?;
        let preference = self.profiles.entry(id).or_default();
        preference.model = model;
        preference.effort = effort;
        preference.revision = preference.revision.checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("Preference revision exhausted"))?;
        self.validate()
    }
}

pub fn parse_models(value: &Value) -> anyhow::Result<Vec<WorkflowModel>> {
    anyhow::ensure!(value.get("nextCursor").is_none_or(Value::is_null), "Model list incomplete");
    let rows = value.get("data").and_then(Value::as_array)
        .ok_or_else(|| anyhow::anyhow!("Model list unavailable"))?;
    anyhow::ensure!(!rows.is_empty() && rows.len() <= 100, "Model list unavailable");
    let mut models = Vec::new();
    for row in rows {
        if row.get("hidden").and_then(Value::as_bool) == Some(true) { continue; }
        let Some(id) = row.get("model").or_else(|| row.get("id")).and_then(Value::as_str).filter(|v| valid_model(v)) else { continue; };
        let Some(default_effort) = row.get("defaultReasoningEffort").and_then(Value::as_str).filter(|v| valid_effort(v)) else { continue; };
        let Some(raw_efforts) = row.get("supportedReasoningEfforts").and_then(Value::as_array) else { continue; };
        let mut efforts = Vec::new();
        for value in raw_efforts {
            if let Some(effort) = value.get("reasoningEffort").and_then(Value::as_str).filter(|v| valid_effort(v)) {
                if !efforts.iter().any(|known| known == effort) { efforts.push(effort.to_owned()); }
            }
        }
        if !efforts.iter().any(|effort| effort == default_effort) { continue; }
        let label = row.get("displayName").and_then(Value::as_str)
            .filter(|label| !label.is_empty() && label.len() <= 80 && !label.chars().any(|c| c.is_control() || "@/\\:".contains(c)))
            .unwrap_or(id).to_owned();
        anyhow::ensure!(!models.iter().any(|model: &WorkflowModel| model.id == id), "Duplicate model");
        models.push(WorkflowModel { id: id.to_owned(), label, efforts, default_effort: default_effort.to_owned(), is_default: row.get("isDefault").and_then(Value::as_bool).unwrap_or(false) });
    }
    anyhow::ensure!(!models.is_empty(), "No supported models returned");
    Ok(models)
}

pub fn resolve_selection(preference: &WorkflowPreference, models: &[WorkflowModel]) -> anyhow::Result<(String, String)> {
    let model = if let Some(id) = &preference.model {
        models.iter().find(|model| &model.id == id)
    } else {
        let defaults: Vec<_> = models.iter().filter(|model| model.is_default).collect();
        (defaults.len() == 1).then(|| defaults[0])
    }.ok_or_else(|| anyhow::anyhow!("Read models and select an available model"))?;
    let effort = preference.effort.as_deref().unwrap_or(&model.default_effort);
    anyhow::ensure!(model.efforts.iter().any(|value| value == effort), "Selected effort unavailable");
    Ok((model.id.clone(), effort.to_owned()))
}

/// The terminal is interactive: this gate authorizes opening it, never a
/// background task, credit redemption, paid fallback or quota inference.
pub fn validate_startup(account: &Value, rate_limits: &Value, now_seconds: i64) -> anyhow::Result<()> {
    anyhow::ensure!(account.pointer("/account/type").and_then(Value::as_str) == Some("chatgpt"), "ChatGPT login required");
    let limits = if let Some(buckets) = rate_limits.get("rateLimitsByLimitId").filter(|v| !v.is_null()) {
        buckets.get("codex")
    } else { rate_limits.get("rateLimits") }.ok_or_else(|| anyhow::anyhow!("Official quota unavailable"))?;
    let credits = limits.get("credits").ok_or_else(|| anyhow::anyhow!("Credit state unknown"))?;
    anyhow::ensure!(credits.get("hasCredits").and_then(Value::as_bool) == Some(false)
        && credits.get("unlimited").and_then(Value::as_bool) == Some(false), "Paid or unlimited credit fallback is not eligible");
    let balance = credits.get("balance").and_then(|value| value.as_f64().or_else(|| value.as_str()?.parse::<f64>().ok()));
    anyhow::ensure!(balance == Some(0.0), "Credit balance must be explicitly zero");
    let mut durations = std::collections::HashSet::new();
    for name in ["primary", "secondary"] {
        let Some(window) = limits.get(name).filter(|v| !v.is_null()) else { continue; };
        let used = window.get("usedPercent").and_then(Value::as_f64);
        let reset = window.get("resetsAt").and_then(Value::as_i64);
        let duration = window.get("windowDurationMins").and_then(Value::as_i64);
        anyhow::ensure!(used.is_some_and(|v| v.is_finite() && (0.0..100.0).contains(&v))
            && reset.is_some_and(|v| v > now_seconds)
            && duration.is_some_and(|v| matches!(v, 300 | 10_080) || (28 * 24 * 60..=31 * 24 * 60).contains(&v)), "Quota exhausted, stale or unknown");
        let duration = duration.unwrap();
        let kind = if duration >= 28 * 24 * 60 { "monthly" } else if duration == 300 { "five_hour" } else { "seven_day" };
        anyhow::ensure!(durations.insert(kind), "Duplicate quota window");
    }
    let plan = limits.get("planType").and_then(Value::as_str)
        .or_else(|| account.pointer("/account/planType").and_then(Value::as_str));
    anyhow::ensure!(durations.contains("five_hour") || (plan == Some("prolite") && durations.contains("seven_day")), "Required current quota window unavailable");
    Ok(())
}

pub fn interactive_arguments(model: &str, effort: &str) -> anyhow::Result<Vec<String>> {
    anyhow::ensure!(valid_model(model) && valid_effort(effort), "Invalid model selection");
    let mut args = official_arguments();
    args.extend(["--model".into(), model.into(), "--config".into(), format!("model_reasoning_effort=\"{effort}\""),
        "--config".into(), "service_tier=\"default\"".into(),
        "--sandbox".into(), "workspace-write".into(), "--ask-for-approval".into(), "on-request".into()]);
    Ok(args)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn participation_can_be_disabled_without_any_cli_or_quota_state() {
        let mut store = WorkflowPreferences::default();
        store.set_participating(1, true).unwrap();
        store.set_selection(1, Some("synthetic-model".into()), Some("high".into())).unwrap();
        store.set_participating(1, false).unwrap();
        let round_trip: WorkflowPreferences = serde_json::from_slice(&serde_json::to_vec(&store).unwrap()).unwrap();
        assert!(!round_trip.profiles[&1].participating);
        assert_eq!(round_trip.profiles[&1].revision, 3);
        assert!(round_trip.profiles[&1].model.is_some());
        assert!(store.set_selection(1, Some("bad; command".into()), Some("high".into())).is_err());
    }
    #[test]
    fn only_advertised_model_effort_pairs_can_start() {
        let response = json!({"data":[{"id":"opaque-id","model":"synthetic-model","displayName":"Example","isDefault":true,"defaultReasoningEffort":"high","supportedReasoningEfforts":[{"reasoningEffort":"high"},{"reasoningEffort":"low"}]}],"nextCursor":null});
        let models = parse_models(&response).unwrap();
        assert_eq!(resolve_selection(&WorkflowPreference::default(), &models).unwrap(), ("synthetic-model".into(), "high".into()));
        let invalid = WorkflowPreference { model: Some("synthetic-model".into()), effort: Some("max".into()), ..Default::default() };
        assert!(resolve_selection(&invalid, &models).is_err());
        assert!(parse_models(&json!({"data":response["data"],"nextCursor":"next"})).is_err());
        assert!(interactive_arguments("model; bad", "high").is_err());
        assert!(!interactive_arguments("synthetic-model", "high").unwrap().iter().any(|arg| arg == "exec" || arg == "--dangerously-bypass-approvals-and-sandbox"));
    }
    #[test]
    fn startup_requires_official_identity_future_quota_and_known_zero_credit() {
        let account = json!({"account":{"type":"chatgpt"}});
        let limits = json!({"rateLimits":{"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"primary":{"usedPercent":35,"resetsAt":200,"windowDurationMins":300}}});
        validate_startup(&account, &limits, 100).unwrap();
        for (key, value) in [("hasCredits", json!(true)), ("unlimited", json!(true)), ("balance", json!(1)), ("balance", Value::Null)] {
            let mut altered = limits.clone(); altered["rateLimits"]["credits"][key] = value;
            assert!(validate_startup(&account, &altered, 100).is_err());
        }
        assert!(validate_startup(&account, &limits, 200).is_err());
        assert!(validate_startup(&json!({"account":{"type":"apiKey"}}), &limits, 100).is_err());
        let mut exhausted = limits.clone(); exhausted["rateLimits"]["primary"]["usedPercent"] = json!(100);
        assert!(validate_startup(&account, &exhausted, 100).is_err());
        let mut malformed_map = limits.clone(); malformed_map["rateLimitsByLimitId"] = json!({"other":{}});
        assert!(validate_startup(&account, &malformed_map, 100).is_err());
        let mut weekly = limits.clone(); weekly["rateLimits"]["primary"]["windowDurationMins"] = json!(10080);
        assert!(validate_startup(&account, &weekly, 100).is_err());
        weekly["rateLimits"]["planType"] = json!("prolite");
        validate_startup(&account, &weekly, 100).unwrap();
        weekly["rateLimits"]["planType"] = json!("pro");
        assert!(validate_startup(&account, &weekly, 100).is_err());
        let mut duplicate = limits.clone(); duplicate["rateLimits"]["secondary"] = duplicate["rateLimits"]["primary"].clone();
        assert!(validate_startup(&account, &duplicate, 100).is_err());
        let mut unknown = limits.clone(); unknown["rateLimits"]["primary"]["windowDurationMins"] = json!(600);
        assert!(validate_startup(&account, &unknown, 100).is_err());
    }
    #[test]
    fn official_route_overrides_replace_the_provider_table_and_remove_external_auth() {
        let args = official_arguments();
        assert!(args.iter().any(|arg| arg.starts_with("model_providers={openai={") && arg.contains("base_url=\"https://chatgpt.com/backend-api/codex\"") && arg.contains("requires_openai_auth=true")));
        assert!(args.contains(&"chatgpt_base_url=\"https://chatgpt.com/backend-api/\"".to_owned()));
        assert!(args.contains(&"cli_auth_credentials_store=\"file\"".to_owned()));
        assert!(EXTERNAL_API_ENVIRONMENT.contains(&"CODEX_ACCESS_TOKEN"));
        assert!(EXTERNAL_API_ENVIRONMENT.contains(&"OPENAI_BASE_URL"));
    }
}
