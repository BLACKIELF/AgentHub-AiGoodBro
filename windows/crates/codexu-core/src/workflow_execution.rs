//! Pure native dispatch rules over the existing workflow-preferences authority.
//! No storage, account inference, approval or execution is performed here.
use crate::{
    local_cli::LocalCliKind,
    profiles::ProfileCatalog,
    workflow::{
        resolve_selection, valid_effort, valid_model, DispatchMode, WorkflowModel,
        WorkflowPreference, WorkflowPreferences,
    },
};
use anyhow::{ensure, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ServiceTier {
    #[default]
    Default,
    Fast,
}
impl ServiceTier {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::Fast => "fast",
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ExecutionOverrides {
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub effort: Option<String>,
    #[serde(default)]
    pub service_tier: Option<ServiceTier>,
}
impl ExecutionOverrides {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.model.as_deref().is_none_or(valid_model)
                && self.effort.as_deref().is_none_or(valid_effort),
            "workflow_override_invalid"
        );
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResolvedExecution {
    pub profile_id: u64,
    pub model: String,
    pub effort: String,
    pub service_tier: ServiceTier,
    pub workflow_revision: u64,
    pub not_after_ms: Option<i64>,
    pub binding_sha256: String,
}

pub fn valid_dispatch_code(code: &str) -> bool {
    code.len() == 1 && code.as_bytes()[0].is_ascii_uppercase()
}

fn valid_plan(plan: &str) -> bool {
    !plan.is_empty()
        && plan.len() <= 128
        && plan == plan.trim()
        && !plan.chars().any(char::is_control)
}

/// Called by the owning workflow schema validator; never calls it recursively.
/// Unknown plan names remain valid values, not a new static plan allowlist.
pub fn validate_extensions(preferences: &WorkflowPreferences) -> Result<()> {
    ensure!(
        preferences.excluded_plan_types.len() <= 100
            && preferences
                .excluded_plan_types
                .iter()
                .all(|p| valid_plan(p)),
        "workflow_plan_policy_invalid"
    );
    let mut codes = BTreeSet::new();
    for (id, p) in &preferences.profiles {
        ensure!(*id > 0, "workflow_profile_invalid");
        if let Some(code) = &p.dispatch_code {
            ensure!(
                valid_dispatch_code(code) && codes.insert(code),
                "workflow_dispatch_code_invalid"
            );
        }
        ensure!(
            p.not_after_ms
                .is_none_or(|v| (0..=9_007_199_254_740_991).contains(&v)),
            "workflow_deadline_invalid"
        );
    }
    Ok(())
}

/// Return the existing code, or the next code after the highest ever retained.
/// The caller persists it in its existing atomic registration transaction.
/// All preferences, including removed profiles/tombstones, reserve their code.
pub fn next_dispatch_code(profile_id: u64, preferences: &WorkflowPreferences) -> Result<String> {
    ensure!(profile_id > 0, "workflow_profile_invalid");
    preferences.validate()?;
    validate_extensions(preferences)?;
    if let Some(code) = preferences
        .profiles
        .get(&profile_id)
        .and_then(|p| p.dispatch_code.as_ref())
    {
        return Ok(code.clone());
    }
    let highest = preferences
        .profiles
        .values()
        .filter_map(|p| p.dispatch_code.as_ref().map(|c| c.as_bytes()[0]))
        .max()
        .unwrap_or(b'A' - 1);
    ensure!(highest < b'Z', "workflow_dispatch_code_capacity");
    Ok(char::from(highest + 1).to_string())
}

/// Resolve only a persisted code and a current Codex catalog ID. No assignment,
/// label matching or selection by the catalog's visible order is allowed.
pub fn resolve_dispatch_code(
    code: &str,
    catalog: &ProfileCatalog,
    preferences: &WorkflowPreferences,
) -> Result<u64> {
    ensure!(valid_dispatch_code(code), "workflow_dispatch_code_invalid");
    catalog.validate()?;
    preferences.validate()?;
    validate_extensions(preferences)?;
    let id = preferences
        .profiles
        .iter()
        .find(|(_, p)| p.dispatch_code.as_deref() == Some(code))
        .map(|(id, _)| *id)
        .ok_or_else(|| anyhow::anyhow!("workflow_dispatch_code_missing"))?;
    ensure!(
        catalog.get(id)?.kind == LocalCliKind::Codex,
        "workflow_profile_unsupported"
    );
    Ok(id)
}

fn check_policy(
    preference: &WorkflowPreference,
    excluded_plan_types: &[String],
    official_plan: &str,
    now_ms: i64,
) -> Result<()> {
    ensure!(valid_plan(official_plan), "workflow_plan_unavailable");
    ensure!(
        (0..=9_007_199_254_740_991).contains(&now_ms),
        "workflow_clock_invalid"
    );
    ensure!(
        preference.allows_new_work_at_ms(now_ms),
        "workflow_dispatch_disabled"
    );
    let plan = official_plan.to_lowercase();
    ensure!(
        !excluded_plan_types.iter().any(|p| p.to_lowercase() == plan),
        "workflow_plan_excluded"
    );
    ensure!(
        preference
            .not_after_ms
            .is_none_or(|deadline| now_ms < deadline),
        "workflow_deadline_elapsed"
    );
    Ok(())
}

fn validate_models(models: &[WorkflowModel]) -> Result<()> {
    ensure!(
        !models.is_empty() && models.len() <= 100,
        "workflow_models_unavailable"
    );
    let mut ids = BTreeSet::new();
    for m in models {
        ensure!(
            valid_model(&m.id)
                && ids.insert(&m.id)
                && !m.efforts.is_empty()
                && m.efforts.len() <= 8
                && m.efforts.iter().all(|e| valid_effort(e))
                && m.efforts.iter().collect::<BTreeSet<_>>().len() == m.efforts.len()
                && m.efforts.contains(&m.default_effort),
            "workflow_models_invalid"
        );
    }
    Ok(())
}

/// Re-run this with freshly read authority/models/official plan before spawn.
/// The caller must also keep its existing identity/root/lease/freshness gates.
/// This is standard saved-strategy execution, not a subagent-preset resolver.
pub fn resolve_execution(
    profile_id: u64,
    preferences: &WorkflowPreferences,
    models: &[WorkflowModel],
    official_plan: &str,
    now_ms: i64,
    overrides: &ExecutionOverrides,
) -> Result<ResolvedExecution> {
    preferences.validate()?;
    validate_extensions(preferences)?;
    overrides.validate()?;
    validate_models(models)?;
    let preference = preferences
        .profiles
        .get(&profile_id)
        .ok_or_else(|| anyhow::anyhow!("workflow_profile_missing"))?;
    check_policy(
        preference,
        &preferences.excluded_plan_types,
        official_plan,
        now_ms,
    )?;
    let (saved_model, saved_effort) = resolve_selection(preference, models)?;
    let mut requested = preference.clone();
    requested.model = Some(overrides.model.clone().unwrap_or(saved_model));
    // Mac retains the saved effective effort when only the model is overridden.
    // It must fit the new model; choosing that model's default would hide failure.
    requested.effort = Some(overrides.effort.clone().unwrap_or(saved_effort));
    let (model, effort) = resolve_selection(&requested, models)?;
    let tier = overrides
        .service_tier
        .or(preference.service_tier)
        .unwrap_or_default();
    ensure!(
        !(model == "gpt-5.2" && tier == ServiceTier::Fast),
        "workflow_tier_unsupported"
    );
    let binding_sha256 = binding(
        profile_id,
        preference,
        &preferences.excluded_plan_types,
        official_plan,
        overrides,
        &model,
        &effort,
        tier,
    );
    Ok(ResolvedExecution {
        profile_id,
        model,
        effort,
        service_tier: tier,
        workflow_revision: preference.revision,
        not_after_ms: preference.not_after_ms,
        binding_sha256,
    })
}

/// The native caller compares the whole frozen result; a request-supplied hash
/// alone is never authority. Time itself is not hashed, so it is checked again.
pub fn revalidate_execution(
    expected: &ResolvedExecution,
    preferences: &WorkflowPreferences,
    models: &[WorkflowModel],
    official_plan: &str,
    now_ms: i64,
    overrides: &ExecutionOverrides,
) -> Result<()> {
    let current = resolve_execution(
        expected.profile_id,
        preferences,
        models,
        official_plan,
        now_ms,
        overrides,
    )?;
    ensure!(&current == expected, "workflow_execution_changed");
    Ok(())
}

// Cross-language recipe: each UTF-8 field is prefixed with its byte length as
// u64 big endian, numbers are decimal and bools are true/false. Option adds a
// none/some field. Lists add their decimal count, preserving stored order;
// weekdays use BTreeSet ascending order. No JSON/float/map-order dependence.
struct Binding(Sha256);
impl Binding {
    fn field(&mut self, value: &str) {
        self.0.update((value.len() as u64).to_be_bytes());
        self.0.update(value.as_bytes());
    }
    fn optional(&mut self, value: Option<&str>) {
        self.field(if value.is_some() { "some" } else { "none" });
        if let Some(value) = value {
            self.field(value);
        }
    }
}
#[allow(clippy::too_many_arguments)]
fn binding(
    id: u64,
    p: &WorkflowPreference,
    plans: &[String],
    official_plan: &str,
    overrides: &ExecutionOverrides,
    model: &str,
    effort: &str,
    tier: ServiceTier,
) -> String {
    let mut h = Binding(Sha256::new());
    h.field("aigoodbro.workflow-execution.v1");
    h.field(&id.to_string());
    h.field(&p.revision.to_string());
    h.field(if p.participating { "true" } else { "false" });
    h.optional(p.model.as_deref());
    h.optional(p.effort.as_deref());
    h.optional(p.service_tier.map(ServiceTier::as_str));
    h.optional(p.dispatch_code.as_deref());
    h.optional(p.not_after_ms.map(|v| v.to_string()).as_deref());
    h.field(if p.dispatch_window.is_some() {
        "some"
    } else {
        "none"
    });
    if let Some(window) = &p.dispatch_window {
        h.field(match window.mode {
            DispatchMode::Unrestricted => "unrestricted",
            DispatchMode::OnlyWithin => "onlyWithin",
            DispatchMode::ExceptWithin => "exceptWithin",
        });
        h.field(&window.time_zone_identifier);
        h.field(&window.intervals.len().to_string());
        for interval in &window.intervals {
            h.field(&interval.start_minute.to_string());
            h.field(&interval.end_minute.to_string());
            h.field(if interval.all_days { "true" } else { "false" });
            h.field(if interval.all_day { "true" } else { "false" });
            h.field(&interval.weekdays.len().to_string());
            for day in &interval.weekdays {
                h.field(&day.to_string());
            }
        }
    }
    h.field(&plans.len().to_string());
    for plan in plans {
        h.field(plan);
    }
    h.field(official_plan);
    h.optional(overrides.model.as_deref());
    h.optional(overrides.effort.as_deref());
    h.optional(overrides.service_tier.map(ServiceTier::as_str));
    h.field(model);
    h.field(effort);
    h.field(tier.as_str());
    format!("{:x}", h.0.finalize())
}

#[cfg(test)]
#[path = "workflow_execution_tests.rs"]
mod tests;
