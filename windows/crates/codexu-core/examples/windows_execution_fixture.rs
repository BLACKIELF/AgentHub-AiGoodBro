use codexu_core::{
    workflow::{WorkflowModel, WorkflowPreference, WorkflowPreferences},
    workflow_execution::{resolve_execution, ExecutionOverrides, ResolvedExecution, ServiceTier},
};
use serde::Serialize;
use std::{collections::BTreeMap, error::Error};

const PROFILE_ID: u64 = 42;
const PLAN: &str = "plus";
const NOW_MS: i64 = 1_000_000;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ExecutionRequest {
    workflow_revision: u64,
    #[serde(rename = "bindingSHA256")]
    binding_sha256: String,
    overrides: ExecutionOverrides,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ExecutionAuthority {
    profile_id: u64,
    preference: WorkflowPreference,
    excluded_plan_types: Vec<String>,
    official_plan: String,
    models: Vec<WorkflowModel>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct EffectiveExecution {
    profile_id: u64,
    model: String,
    effort: String,
    service_tier: ServiceTier,
    workflow_revision: u64,
    not_after_ms: Option<i64>,
    #[serde(rename = "bindingSHA256")]
    binding_sha256: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Case {
    name: &'static str,
    request: ExecutionRequest,
    authority: ExecutionAuthority,
    now_ms: i64,
    expected: Option<EffectiveExecution>,
    expected_args: Vec<String>,
    reject: bool,
}

fn models() -> Vec<WorkflowModel> {
    vec![
        WorkflowModel {
            id: "gpt-6-astra".into(),
            label: "Astra fixture".into(),
            efforts: vec!["low".into(), "high".into(), "ultra".into()],
            default_effort: "low".into(),
            is_default: true,
        },
        WorkflowModel {
            id: "gpt-5.5".into(),
            label: "5.5 fixture".into(),
            efforts: vec!["low".into(), "high".into(), "xhigh".into()],
            default_effort: "low".into(),
            is_default: false,
        },
        WorkflowModel {
            id: "gpt-5.2".into(),
            label: "5.2 fixture".into(),
            efforts: vec!["low".into(), "high".into()],
            default_effort: "low".into(),
            is_default: false,
        },
    ]
}

fn preferences(preference: WorkflowPreference) -> WorkflowPreferences {
    WorkflowPreferences {
        profiles: BTreeMap::from([(PROFILE_ID, preference)]),
        excluded_plan_types: vec!["enterprise".into()],
    }
}

fn preference(
    model: &str,
    effort: &str,
    tier: Option<ServiceTier>,
    not_after_ms: Option<i64>,
) -> WorkflowPreference {
    WorkflowPreference {
        participating: true,
        model: Some(model.into()),
        effort: Some(effort.into()),
        service_tier: tier,
        revision: 7,
        dispatch_window: None,
        dispatch_code: Some("G".into()),
        not_after_ms,
    }
}

fn effective(value: &ResolvedExecution) -> EffectiveExecution {
    EffectiveExecution {
        profile_id: value.profile_id,
        model: value.model.clone(),
        effort: value.effort.clone(),
        service_tier: value.service_tier,
        workflow_revision: value.workflow_revision,
        not_after_ms: value.not_after_ms,
        binding_sha256: value.binding_sha256.clone(),
    }
}

fn codex_arguments(value: &ResolvedExecution) -> Vec<String> {
    let mut args = vec![
        "-m".into(),
        value.model.clone(),
        "-c".into(),
        format!(r#"model_reasoning_effort="{}""#, value.effort),
        "-c".into(),
        format!(r#"service_tier="{}""#, value.service_tier.as_str()),
    ];
    if value.service_tier == ServiceTier::Fast {
        args.extend(["--enable".into(), "fast_mode".into()]);
    } else {
        args.extend(["--disable".into(), "fast_mode".into()]);
    }
    args
}

fn case(
    name: &'static str,
    preference: WorkflowPreference,
    overrides: ExecutionOverrides,
    binding_at_ms: i64,
    now_ms: i64,
    reject: bool,
) -> Result<Case, Box<dyn Error>> {
    let preferences = preferences(preference);
    let models = models();
    let binding = resolve_execution(
        PROFILE_ID,
        &preferences,
        &models,
        PLAN,
        binding_at_ms,
        &overrides,
    )?;
    let resolved = resolve_execution(PROFILE_ID, &preferences, &models, PLAN, now_ms, &overrides);
    let expected = match (reject, resolved) {
        (false, Ok(value)) => Some(value),
        (true, Err(_)) => None,
        (false, Err(error)) => return Err(error.into()),
        (true, Ok(_)) => return Err("case expected to be rejected".into()),
    };
    let expected_args = expected.as_ref().map(codex_arguments).unwrap_or_default();
    let request = ExecutionRequest {
        workflow_revision: binding.workflow_revision,
        binding_sha256: binding.binding_sha256,
        overrides,
    };
    Ok(Case {
        name,
        request,
        authority: ExecutionAuthority {
            profile_id: PROFILE_ID,
            preference: preferences.profiles[&PROFILE_ID].clone(),
            excluded_plan_types: preferences.excluded_plan_types,
            official_plan: PLAN.into(),
            models,
        },
        now_ms,
        expected: expected.as_ref().map(effective),
        expected_args,
        reject,
    })
}

fn exact_unicode_override_vector() -> Result<Case, Box<dyn Error>> {
    const PROFILE_ID: u64 = 11;
    const NOW_MS: i64 = 1_800_000_000_000;
    let preference = WorkflowPreference {
        participating: true,
        model: Some("gpt-6-astra".into()),
        effort: Some("high".into()),
        revision: 7,
        dispatch_code: Some("C".into()),
        not_after_ms: Some(NOW_MS + 100_000),
        ..Default::default()
    };
    let preferences = WorkflowPreferences {
        profiles: BTreeMap::from([(PROFILE_ID, preference.clone())]),
        excluded_plan_types: vec!["PRO".into(), "企业".into()],
    };
    let models = vec![
        WorkflowModel {
            id: "gpt-6-astra".into(),
            label: "Astra".into(),
            efforts: vec!["low".into(), "high".into(), "ultra".into()],
            default_effort: "low".into(),
            is_default: true,
        },
        WorkflowModel {
            id: "gpt-5.5".into(),
            label: "5.5".into(),
            efforts: vec!["low".into(), "high".into(), "xhigh".into()],
            default_effort: "low".into(),
            is_default: false,
        },
        WorkflowModel {
            id: "gpt-5.2".into(),
            label: "5.2".into(),
            efforts: vec!["low".into(), "high".into()],
            default_effort: "low".into(),
            is_default: false,
        },
    ];
    let overrides = ExecutionOverrides {
        model: Some("gpt-5.5".into()),
        effort: Some("xhigh".into()),
        service_tier: Some(ServiceTier::Fast),
    };
    let resolved = resolve_execution(
        PROFILE_ID,
        &preferences,
        &models,
        "plus",
        NOW_MS,
        &overrides,
    )?;
    let expected_args = codex_arguments(&resolved);
    let request = ExecutionRequest {
        workflow_revision: resolved.workflow_revision,
        binding_sha256: resolved.binding_sha256.clone(),
        overrides,
    };
    Ok(Case {
        name: "exact_unicode_override_vector",
        request,
        authority: ExecutionAuthority {
            profile_id: PROFILE_ID,
            preference,
            excluded_plan_types: preferences.excluded_plan_types,
            official_plan: "plus".into(),
            models,
        },
        now_ms: NOW_MS,
        expected: Some(effective(&resolved)),
        expected_args,
        reject: false,
    })
}

fn main() -> Result<(), Box<dyn Error>> {
    let expires_at = NOW_MS + 100_000;
    let cases = vec![
        case(
            "saved_fast",
            preference(
                "gpt-5.5",
                "high",
                Some(ServiceTier::Fast),
                Some(NOW_MS + 300_000),
            ),
            ExecutionOverrides::default(),
            NOW_MS,
            NOW_MS,
            false,
        )?,
        case(
            "one_call_override",
            preference(
                "gpt-6-astra",
                "high",
                Some(ServiceTier::Default),
                Some(NOW_MS + 300_000),
            ),
            ExecutionOverrides {
                model: Some("gpt-5.5".into()),
                effort: Some("xhigh".into()),
                service_tier: Some(ServiceTier::Fast),
            },
            NOW_MS,
            NOW_MS,
            false,
        )?,
        case(
            "expired_saved_preference",
            preference(
                "gpt-5.5",
                "high",
                Some(ServiceTier::Default),
                Some(expires_at),
            ),
            ExecutionOverrides::default(),
            expires_at - 1,
            expires_at,
            true,
        )?,
        exact_unicode_override_vector()?,
    ];
    serde_json::to_writer(
        std::io::stdout().lock(),
        &serde_json::json!({ "cases": cases }),
    )?;
    println!();
    Ok(())
}
