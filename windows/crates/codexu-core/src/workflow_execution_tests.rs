use super::*;
use crate::workflow::{DispatchInterval, DispatchWindow};
use serde_json::json;

const NOW: i64 = 1_800_000_000_000;

fn preference(code: Option<&str>) -> WorkflowPreference {
    WorkflowPreference {
        participating: true,
        model: Some("gpt-6-astra".into()),
        effort: Some("high".into()),
        revision: 7,
        dispatch_code: code.map(str::to_owned),
        not_after_ms: Some(NOW + 100_000),
        ..Default::default()
    }
}
fn prefs() -> WorkflowPreferences {
    let mut p = WorkflowPreferences::default();
    p.profiles.insert(11, preference(Some("C")));
    p.excluded_plan_types = vec!["PRO".into(), "企业".into()];
    p
}
fn models() -> Vec<WorkflowModel> {
    crate::workflow::parse_models(&json!({"nextCursor":null,"data":[
        {"model":"gpt-6-astra","displayName":"Astra","isDefault":true,"defaultReasoningEffort":"low","supportedReasoningEfforts":[{"reasoningEffort":"low"},{"reasoningEffort":"high"},{"reasoningEffort":"ultra"}]},
        {"model":"gpt-5.5","displayName":"5.5","defaultReasoningEffort":"low","supportedReasoningEfforts":[{"reasoningEffort":"low"},{"reasoningEffort":"high"},{"reasoningEffort":"xhigh"}]},
        {"model":"gpt-5.2","displayName":"5.2","defaultReasoningEffort":"low","supportedReasoningEfforts":[{"reasoningEffort":"low"},{"reasoningEffort":"high"}]}
    ]})).unwrap()
}
fn resolve(p: &WorkflowPreferences, o: &ExecutionOverrides) -> Result<ResolvedExecution> {
    resolve_execution(11, p, &models(), "plus", NOW, o)
}
fn catalog() -> (tempfile::TempDir, ProfileCatalog) {
    let temp = tempfile::tempdir().unwrap();
    let mut c = ProfileCatalog::default();
    for id in 1..=11 {
        c.add(
            LocalCliKind::Codex,
            format!("Account {id}"),
            temp.path().join(id.to_string()),
        )
        .unwrap();
    }
    (temp, c)
}

#[test]
fn dispatch_code_is_persisted_identity_not_order_name_or_participation() {
    let (_temp, mut c) = catalog();
    let mut p = prefs();
    let before = serde_json::to_vec(&p).unwrap();
    assert_eq!(resolve_dispatch_code("C", &c, &p).unwrap(), 11);
    c.rename(11, "New name".into()).unwrap();
    c.move_one(11, -1).unwrap();
    assert_eq!(resolve_dispatch_code("C", &c, &p).unwrap(), 11);
    assert_eq!(serde_json::to_vec(&p).unwrap(), before);
    p.set_participating(11, false).unwrap();
    assert_eq!(resolve_dispatch_code("C", &c, &p).unwrap(), 11);
    assert_eq!(next_dispatch_code(11, &p).unwrap(), "C");
    assert!(resolve(&p, &ExecutionOverrides::default()).is_err());
    p.set_participating(11, true).unwrap();
    assert_eq!(next_dispatch_code(11, &p).unwrap(), "C");
    let reopened: WorkflowPreferences =
        serde_json::from_slice(&serde_json::to_vec(&p).unwrap()).unwrap();
    assert_eq!(resolve_dispatch_code("C", &c, &reopened).unwrap(), 11);
}

#[test]
fn allocation_never_reuses_holes_or_deleted_account_code() {
    let (_temp, mut c) = catalog();
    let mut p = prefs();
    p.profiles.insert(1, preference(Some("A")));
    let before = serde_json::to_vec(&p).unwrap();
    assert_eq!(next_dispatch_code(12, &p).unwrap(), "D");
    c.remove(11).unwrap();
    assert!(resolve_dispatch_code("C", &c, &p).is_err());
    assert_eq!(next_dispatch_code(12, &p).unwrap(), "D");
    assert_eq!(serde_json::to_vec(&p).unwrap(), before);
    p.profiles.insert(12, preference(Some("Z")));
    assert_eq!(next_dispatch_code(12, &p).unwrap(), "Z");
    assert_eq!(
        next_dispatch_code(13, &p).unwrap_err().to_string(),
        "workflow_dispatch_code_capacity"
    );
}

#[test]
fn malformed_duplicate_or_foreign_provider_codes_cannot_resolve() {
    let (_temp, mut c) = catalog();
    for invalid in ["", "a", "AA", "1", "Ａ", " C", "C\n"] {
        assert!(resolve_dispatch_code(invalid, &c, &prefs()).is_err());
    }
    let mut p = prefs();
    p.profiles.insert(1, preference(Some("C")));
    assert!(resolve_dispatch_code("C", &c, &p).is_err());
    assert!(next_dispatch_code(12, &p).is_err());
    c.entries.iter_mut().find(|p| p.id == 11).unwrap().kind = LocalCliKind::ClaudeCode;
    assert!(resolve_dispatch_code("C", &c, &prefs()).is_err());
    assert!(next_dispatch_code(0, &prefs()).is_err());
}

#[test]
fn explicit_overrides_are_one_call_and_keep_saved_bytes() {
    let p = prefs();
    let before = serde_json::to_vec(&p).unwrap();
    let saved = resolve(&p, &ExecutionOverrides::default()).unwrap();
    let options = ExecutionOverrides {
        model: Some("gpt-5.5".into()),
        effort: Some("xhigh".into()),
        service_tier: Some(ServiceTier::Fast),
    };
    let changed = resolve(&p, &options).unwrap();
    assert_eq!(
        (&*changed.model, &*changed.effort, changed.service_tier),
        ("gpt-5.5", "xhigh", ServiceTier::Fast)
    );
    assert_eq!(
        (&*saved.model, &*saved.effort, saved.service_tier),
        ("gpt-6-astra", "high", ServiceTier::Default)
    );
    assert_ne!(changed.binding_sha256, saved.binding_sha256);
    assert_eq!(resolve(&p, &ExecutionOverrides::default()).unwrap(), saved);
    assert_eq!(serde_json::to_vec(&p).unwrap(), before);
}

#[test]
fn model_only_inherits_effective_saved_effort_and_never_falls_back() {
    let mut p = prefs();
    let model_only = ExecutionOverrides {
        model: Some("gpt-5.5".into()),
        ..Default::default()
    };
    assert_eq!(resolve(&p, &model_only).unwrap().effort, "high");
    p.profiles.get_mut(&11).unwrap().effort = Some("ultra".into());
    assert!(resolve(&p, &model_only).is_err());
    let with_effort = ExecutionOverrides {
        effort: Some("xhigh".into()),
        ..model_only
    };
    assert_eq!(resolve(&p, &with_effort).unwrap().effort, "xhigh");
    p.profiles.get_mut(&11).unwrap().model = Some("unadvertised".into());
    assert!(resolve(&p, &with_effort).is_err());
}

#[test]
fn saved_tier_is_inherited_and_explicit_default_is_one_call_only() {
    let mut p = prefs();
    p.profiles.get_mut(&11).unwrap().service_tier = Some(ServiceTier::Fast);
    let before = serde_json::to_vec(&p).unwrap();
    let inherited = resolve(&p, &ExecutionOverrides::default()).unwrap();
    assert_eq!(inherited.service_tier, ServiceTier::Fast);
    let ordinary = ExecutionOverrides {
        service_tier: Some(ServiceTier::Default),
        ..Default::default()
    };
    let overridden = resolve(&p, &ordinary).unwrap();
    assert_eq!(overridden.service_tier, ServiceTier::Default);
    assert_eq!(serde_json::to_vec(&p).unwrap(), before);
    assert_eq!(
        resolve(&p, &ExecutionOverrides::default()).unwrap(),
        inherited
    );
    let reopened: WorkflowPreferences = serde_json::from_slice(&before).unwrap();
    assert_eq!(
        resolve(&reopened, &ExecutionOverrides::default()).unwrap(),
        inherited
    );

    p.profiles.get_mut(&11).unwrap().service_tier = Some(ServiceTier::Default);
    assert!(revalidate_execution(
        &inherited,
        &p,
        &models(),
        "plus",
        NOW,
        &ExecutionOverrides::default()
    )
    .is_err());
    // Even with the same effective explicit override, changed saved authority
    // invalidates the original binding rather than being hidden by the override.
    assert!(revalidate_execution(&overridden, &p, &models(), "plus", NOW, &ordinary).is_err());
    let explicit_default = resolve(&p, &ordinary).unwrap();
    p.profiles.get_mut(&11).unwrap().service_tier = None;
    assert_eq!(
        resolve(&p, &ordinary).unwrap().service_tier,
        ServiceTier::Default
    );
    assert_ne!(
        resolve(&p, &ordinary).unwrap().binding_sha256,
        explicit_default.binding_sha256
    );
}

#[test]
fn saved_fast_obeys_effective_model_restriction_and_tier_schema() {
    let mut p = prefs();
    p.profiles.get_mut(&11).unwrap().service_tier = Some(ServiceTier::Fast);
    let to_52 = ExecutionOverrides {
        model: Some("gpt-5.2".into()),
        ..Default::default()
    };
    assert_eq!(
        resolve(&p, &to_52).unwrap_err().to_string(),
        "workflow_tier_unsupported"
    );
    let allowed = ExecutionOverrides {
        service_tier: Some(ServiceTier::Default),
        ..to_52
    };
    assert_eq!(
        resolve(&p, &allowed).unwrap().service_tier,
        ServiceTier::Default
    );
    p.profiles.get_mut(&11).unwrap().model = Some("gpt-5.2".into());
    assert!(resolve(&p, &ExecutionOverrides::default()).is_err());
    assert_eq!(
        resolve(&p, &allowed).unwrap().service_tier,
        ServiceTier::Default
    );
    let mut bad = serde_json::to_value(&p).unwrap();
    bad["profiles"]["11"]["service_tier"] = json!("priority");
    assert!(serde_json::from_value::<WorkflowPreferences>(bad).is_err());
}

#[test]
fn request_must_match_real_model_catalog_and_tier_contract() {
    let p = prefs();
    for o in [
        ExecutionOverrides {
            model: Some("unknown".into()),
            ..Default::default()
        },
        ExecutionOverrides {
            effort: Some("max".into()),
            ..Default::default()
        },
        ExecutionOverrides {
            model: Some("gpt-5.2".into()),
            service_tier: Some(ServiceTier::Fast),
            ..Default::default()
        },
    ] {
        assert!(resolve(&p, &o).is_err());
    }
    let ordinary = ExecutionOverrides {
        model: Some("gpt-5.2".into()),
        ..Default::default()
    };
    assert_eq!(
        resolve(&p, &ordinary).unwrap().service_tier,
        ServiceTier::Default
    );
    let mut invalid = models();
    invalid.push(invalid[0].clone());
    assert!(resolve_execution(11, &p, &invalid, "plus", NOW, &ordinary).is_err());
    assert!(resolve_execution(11, &p, &[], "plus", NOW, &ordinary).is_err());
    for raw in [
        r#"{"serviceTier":"priority"}"#,
        r#"{"approved":true}"#,
        r#"{"effort":17}"#,
    ] {
        assert!(serde_json::from_str::<ExecutionOverrides>(raw).is_err());
    }
}

#[test]
fn plan_policy_is_case_insensitive_global_and_preserves_unknown_plan_names() {
    let p = prefs();
    let o = ExecutionOverrides::default();
    for plan in ["pro", "Pro", "PRO", "企业"] {
        assert_eq!(
            resolve_execution(11, &p, &models(), plan, NOW, &o)
                .unwrap_err()
                .to_string(),
            "workflow_plan_excluded"
        );
    }
    assert!(resolve_execution(11, &p, &models(), "new-valid-plan", NOW, &o).is_ok());
    for invalid in ["", " plus", "plus\n"] {
        assert!(resolve_execution(11, &p, &models(), invalid, NOW, &o).is_err());
    }
    let mut corrupt = p.clone();
    corrupt.excluded_plan_types.push("".into());
    assert!(resolve(&corrupt, &o).is_err());
    let mut future = p.clone();
    future.excluded_plan_types.push("new-valid-plan".into());
    assert!(resolve_execution(11, &future, &models(), "new-valid-plan", NOW, &o).is_err());
}

#[test]
fn deadline_is_an_exclusive_new_work_boundary_not_a_running_task_stop() {
    let p = prefs();
    let o = ExecutionOverrides::default();
    let frozen = resolve(&p, &o).unwrap();
    assert!(revalidate_execution(&frozen, &p, &models(), "plus", NOW + 99_999, &o).is_ok());
    assert_eq!(
        revalidate_execution(&frozen, &p, &models(), "plus", NOW + 100_000, &o)
            .unwrap_err()
            .to_string(),
        "workflow_deadline_elapsed"
    );
    assert!(revalidate_execution(&frozen, &p, &models(), "plus", NOW + 100_001, &o).is_err());
    let mut invalid = p.clone();
    invalid.profiles.get_mut(&11).unwrap().not_after_ms = Some(-1);
    assert!(resolve(&invalid, &o).is_err());
    assert!(resolve_execution(11, &p, &models(), "plus", -1, &o).is_err());
}

#[test]
fn recurring_window_and_absolute_deadline_both_apply() {
    let mut p = prefs();
    let o = ExecutionOverrides::default();
    p.profiles.get_mut(&11).unwrap().dispatch_window = Some(DispatchWindow {
        mode: DispatchMode::OnlyWithin,
        ..Default::default()
    });
    assert!(resolve(&p, &o).is_err());
    p.profiles
        .get_mut(&11)
        .unwrap()
        .dispatch_window
        .as_mut()
        .unwrap()
        .intervals
        .push(DispatchInterval {
            start_minute: 0,
            end_minute: 0,
            all_days: true,
            all_day: true,
            weekdays: BTreeSet::new(),
        });
    let frozen = resolve(&p, &o).unwrap();
    assert!(revalidate_execution(&frozen, &p, &models(), "plus", NOW + 100_000, &o).is_err());
}

#[test]
fn final_recheck_rejects_authority_changes_without_relying_on_revision_only() {
    let p = prefs();
    let o = ExecutionOverrides::default();
    let frozen = resolve(&p, &o).unwrap();
    let changes: Vec<Box<dyn Fn(&mut WorkflowPreferences)>> = vec![
        Box::new(|p| p.profiles.get_mut(&11).unwrap().revision += 1),
        Box::new(|p| p.profiles.get_mut(&11).unwrap().dispatch_code = Some("D".into())),
        Box::new(|p| p.profiles.get_mut(&11).unwrap().not_after_ms = Some(NOW + 200_000)),
        Box::new(|p| p.profiles.get_mut(&11).unwrap().model = Some("gpt-5.5".into())),
        Box::new(|p| p.profiles.get_mut(&11).unwrap().effort = Some("low".into())),
        Box::new(|p| {
            p.profiles.get_mut(&11).unwrap().dispatch_window = Some(DispatchWindow::default())
        }),
        Box::new(|p| p.excluded_plan_types.push("another-plan".into())),
        Box::new(|p| p.profiles.get_mut(&11).unwrap().participating = false),
    ];
    for change in changes {
        let mut changed = p.clone();
        change(&mut changed);
        assert!(revalidate_execution(&frozen, &changed, &models(), "plus", NOW, &o).is_err());
    }
    assert!(revalidate_execution(&frozen, &p, &models(), "enterprise", NOW, &o).is_err());
    let mut no_profile = p.clone();
    no_profile.profiles.remove(&11);
    assert!(revalidate_execution(&frozen, &no_profile, &models(), "plus", NOW, &o).is_err());
}

#[test]
fn binding_distinguishes_explicit_same_value_options_and_profile_id() {
    let mut p = prefs();
    let none = resolve(&p, &ExecutionOverrides::default()).unwrap();
    for o in [
        ExecutionOverrides {
            model: Some(none.model.clone()),
            ..Default::default()
        },
        ExecutionOverrides {
            effort: Some(none.effort.clone()),
            ..Default::default()
        },
        ExecutionOverrides {
            service_tier: Some(ServiceTier::Default),
            ..Default::default()
        },
    ] {
        assert_ne!(resolve(&p, &o).unwrap().binding_sha256, none.binding_sha256);
        assert!(revalidate_execution(&none, &p, &models(), "plus", NOW, &o).is_err());
    }
    let mut other = p.profiles[&11].clone();
    other.dispatch_code = None;
    p.profiles.insert(12, other);
    assert_ne!(
        resolve_execution(
            12,
            &p,
            &models(),
            "plus",
            NOW,
            &ExecutionOverrides::default()
        )
        .unwrap()
        .binding_sha256,
        none.binding_sha256
    );
    let mut forged = none;
    forged.model = "gpt-5.5".into();
    assert!(revalidate_execution(
        &forged,
        &p,
        &models(),
        "plus",
        NOW,
        &ExecutionOverrides::default()
    )
    .is_err());
}

#[test]
fn binding_is_length_framed_and_includes_stored_policy_order_and_window() {
    let mut a = Binding(Sha256::new());
    a.field("ab");
    a.field("c");
    let mut b = Binding(Sha256::new());
    b.field("a");
    b.field("bc");
    assert_ne!(a.0.finalize(), b.0.finalize());
    let p = prefs();
    let o = ExecutionOverrides::default();
    let a = resolve(&p, &o).unwrap();
    let mut reversed = p.clone();
    reversed.excluded_plan_types.reverse();
    assert_ne!(
        resolve(&reversed, &o).unwrap().binding_sha256,
        a.binding_sha256
    );
    let mut window = p.clone();
    window.profiles.get_mut(&11).unwrap().dispatch_window = Some(DispatchWindow::default());
    let b = resolve(&window, &o).unwrap();
    assert_ne!(a.binding_sha256, b.binding_sha256);
    window
        .profiles
        .get_mut(&11)
        .unwrap()
        .dispatch_window
        .as_mut()
        .unwrap()
        .time_zone_identifier = "Asia/Shanghai".into();
    assert_ne!(
        resolve(&window, &o).unwrap().binding_sha256,
        b.binding_sha256
    );
}

#[test]
fn cross_language_binding_vector_has_explicit_null_unicode_and_override_fields() {
    let o = ExecutionOverrides {
        model: Some("gpt-5.5".into()),
        effort: Some("xhigh".into()),
        service_tier: Some(ServiceTier::Fast),
    };
    let got = resolve(&prefs(), &o).unwrap();
    // Independently constructed length-prefixed UTF-8 vector, intended for the
    // Go final-spawn adapter tests; not a hash supplied as authorization.
    assert_eq!(
        got.binding_sha256,
        "41a9feb4a5623db2e17b01ea2d26bb14e2cc061bd285f26ffa313adcc861ecc7"
    );
}

#[test]
fn legacy_preferences_need_explicit_registration_before_code_resolution() {
    let legacy:WorkflowPreferences=serde_json::from_value(json!({"profiles":{"11":{"participating":true,"model":"gpt-6-astra","effort":"high","revision":0}}})).unwrap();
    let (_temp, c) = catalog();
    let before = serde_json::to_vec(&legacy).unwrap();
    assert!(resolve_dispatch_code("A", &c, &legacy).is_err());
    assert_eq!(next_dispatch_code(11, &legacy).unwrap(), "A");
    assert!(resolve(&legacy, &ExecutionOverrides::default()).is_ok());
    assert_eq!(serde_json::to_vec(&legacy).unwrap(), before);
}
