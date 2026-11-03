use super::*;
use std::collections::BTreeMap;

const KEY: &str = "synthetic_gateway_key_abcdefghijklmnopqrstuvwxyz";

fn connection() -> NativeConnection<'static> {
    NativeConnection {
        endpoint: "http://127.0.0.1:18081/providers/antigravity".into(),
        client_key: KEY,
        run_id: "synthetic-run",
    }
}

#[test]
fn plan_uses_mac_gemini_dir_contract_private_settings_and_env_only_key() {
    let dir = tempfile::tempdir().unwrap();
    let app = dir.path().canonicalize().unwrap();
    let root = app.join("provider-clients-v1");
    let home = root.join("agy-antigravity");
    storage::secure_directory(&root).unwrap();
    storage::secure_directory(&home).unwrap();
    storage::secure_directory(&home.join("antigravity-cli")).unwrap();
    let settings = home.join("antigravity-cli/settings.json");
    storage::atomic_write(
        &settings,
        br#"{"customSetting":"preserved","modelProvider":"other"}"#,
    )
    .unwrap();

    let (args, environment) = prepare(&home, &connection(), Provider::Antigravity).unwrap();
    assert_eq!(
        args,
        vec![format!("--gemini_dir={}", home.to_string_lossy())]
    );
    assert!(args.iter().all(|arg| !arg.contains(KEY)));

    let env: BTreeMap<_, _> = environment
        .apply([
            ("GEMINI_API_KEY".into(), "stale-secret".into()),
            (
                "GOOGLE_GEMINI_BASE_URL".into(),
                "https://wrong.invalid".into(),
            ),
            ("OPENAI_API_KEY".into(), "must-not-inherit".into()),
            ("ANTHROPIC_AUTH_TOKEN".into(), "must-not-inherit".into()),
            ("HTTP_PROXY".into(), "must-not-inherit".into()),
            ("NODE_OPTIONS".into(), "must-not-inherit".into()),
        ])
        .unwrap()
        .into_iter()
        .map(|(k, v)| {
            (
                k.to_string_lossy().into_owned(),
                v.to_string_lossy().into_owned(),
            )
        })
        .collect();
    assert_eq!(env["GEMINI_API_KEY"], KEY);
    assert_eq!(
        env["GOOGLE_GEMINI_BASE_URL"],
        "http://127.0.0.1:18081/providers/antigravity"
    );
    assert_eq!(env["HOME"], home.to_string_lossy());
    assert_eq!(env["USERPROFILE"], home.to_string_lossy());
    assert!(!env.values().any(|value| value.contains("must-not-inherit")));

    let saved: serde_json::Value =
        serde_json::from_slice(&std::fs::read(settings).unwrap()).unwrap();
    assert_eq!(saved["customSetting"], "preserved");
    assert_eq!(saved["modelProvider"], "gemini");
    assert!(!saved.to_string().contains(KEY));
}

#[test]
fn agy_plan_rejects_wrong_provider_endpoint_and_short_key() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().canonicalize().unwrap();
    assert!(prepare(&home, &connection(), Provider::Claude).is_err());

    let mut wrong = connection();
    wrong.endpoint = "https://example.invalid".into();
    assert!(prepare(&home, &wrong, Provider::Antigravity).is_err());
    let mut wrong = connection();
    wrong.client_key = "short";
    assert!(prepare(&home, &wrong, Provider::Antigravity).is_err());
    assert!(!home.join("antigravity-cli/settings.json").exists());
}
