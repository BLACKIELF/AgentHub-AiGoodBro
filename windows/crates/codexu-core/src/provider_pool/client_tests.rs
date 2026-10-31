use super::*;
use std::collections::BTreeMap;

const KEY: &str = "synthetic_gateway_key_abcdefghijklmnopqrstuvwxyz";
fn connection(provider: Provider) -> NativeConnection<'static> {
    NativeConnection {
        endpoint: format!("http://127.0.0.1:18081/providers/{}", provider.id()),
        client_key: KEY,
        run_id: "synthetic-run",
    }
}
fn response(body: &str) -> Vec<u8> {
    format!(
        "HTTP/1.0 200 OK\r\nContent-Length: {}\r\n\r\n{body}",
        body.len()
    )
    .into_bytes()
}

#[test]
fn each_client_uses_private_home_and_key_only_in_clean_environment() {
    let dir = tempfile::tempdir().unwrap();
    let app = dir.path().canonicalize().unwrap();
    for provider in [
        Provider::Antigravity,
        Provider::Claude,
        Provider::Kimi,
        Provider::Xai,
    ] {
        for kind in [ClientKind::Codex, ClientKind::Native] {
            if kind == ClientKind::Native && provider == Provider::Antigravity {
                continue;
            }
            let c = connection(provider);
            let p = prepare(&app, &c, provider, kind, "synthetic-model").unwrap();
            assert!(p.home.starts_with(app.join("provider-clients-v1")));
            assert!(p.arguments.iter().all(|a| !a.contains(KEY)));
            let environment: BTreeMap<_, _> = p
                .environment
                .apply([
                    ("OPENAI_API_KEY".into(), "must-not-inherit".into()),
                    ("ANTHROPIC_AUTH_TOKEN".into(), "must-not-inherit".into()),
                    ("HTTP_PROXY".into(), "must-not-inherit".into()),
                    ("NODE_OPTIONS".into(), "must-not-inherit".into()),
                    ("SYSTEMROOT".into(), "synthetic-system".into()),
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
            assert!(!environment.values().any(|v| v == "must-not-inherit"));
            assert_eq!(environment["HOME"], p.home.to_string_lossy());
            assert_eq!(environment["USERPROFILE"], p.home.to_string_lossy());
            assert!(environment.values().any(|v| v == KEY));
            assert_eq!(environment["SYSTEMROOT"], "synthetic-system");
            assert!(!p.home.join("auth.json").exists());
        }
    }
}

#[test]
fn home_lease_blocks_a_second_client_until_whole_resource_is_released() {
    let d = tempfile::tempdir().unwrap();
    let app = d.path().canonicalize().unwrap();
    let c = connection(Provider::Claude);
    let first = prepare(
        &app,
        &c,
        Provider::Claude,
        ClientKind::Codex,
        "synthetic-model",
    )
    .unwrap();
    assert!(
        matches!(prepare(&app,&c,Provider::Claude,ClientKind::Codex,"synthetic-model"),Err(e) if e.code=="provider_pool_client_busy")
    );
    // The official native client has a distinct isolated home.
    let native = prepare(
        &app,
        &c,
        Provider::Claude,
        ClientKind::Native,
        "synthetic-model",
    )
    .unwrap();
    drop(first);
    assert!(prepare(
        &app,
        &c,
        Provider::Claude,
        ClientKind::Codex,
        "synthetic-model"
    )
    .is_ok());
    drop(native);
}

#[test]
fn wrong_endpoint_key_model_or_unsupported_agy_never_prepares_a_home() {
    let d = tempfile::tempdir().unwrap();
    let app = d.path().canonicalize().unwrap();
    let mut c = connection(Provider::Claude);
    c.endpoint = "https://example.invalid".into();
    assert!(prepare(
        &app,
        &c,
        Provider::Claude,
        ClientKind::Codex,
        "synthetic-model"
    )
    .is_err());
    let c = connection(Provider::Claude);
    assert!(prepare(
        &app,
        &c,
        Provider::Claude,
        ClientKind::Codex,
        "model\"; injected"
    )
    .is_err());
    let c = connection(Provider::Antigravity);
    assert!(prepare(
        &app,
        &c,
        Provider::Antigravity,
        ClientKind::Native,
        "gemini-synthetic"
    )
    .is_err());
    assert!(!app.join("provider-clients-v1").exists());
}

#[test]
fn bounded_catalog_rejects_redirects_chunking_duplicates_and_truncation() {
    assert_eq!(
        catalog_models(&response(
            r#"{"object":"list","data":[{"id":"synthetic-model"}]}"#
        ))
        .unwrap(),
        vec!["synthetic-model"]
    );
    for bytes in [
        b"HTTP/1.0 302 Found\r\nLocation: https://example.invalid\r\n\r\n".to_vec(),
        b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".to_vec(),
        b"HTTP/1.0 200 OK\r\nContent-Length: 999\r\n\r\n{}".to_vec(),
        response(r#"{"object":"list","data":[{"id":"same"},{"id":"same"}]}"#),
        response(r#"{"object":"list","data":[{"id":"bad model"}]}"#),
        response(r#"{"object":"other","data":[]}"#),
    ] {
        assert!(catalog_models(&bytes).is_err());
    }
}

#[test]
fn native_config_uses_actual_selected_model_and_never_persists_gateway_key() {
    let d = tempfile::tempdir().unwrap();
    let app = d.path().canonicalize().unwrap();
    let c = connection(Provider::Xai);
    let p = prepare(
        &app,
        &c,
        Provider::Xai,
        ClientKind::Native,
        "actual-selected-model",
    )
    .unwrap();
    let env = p.environment.apply([]).unwrap();
    let config = env
        .iter()
        .find(|(k, _)| k == "GROK_CONFIG")
        .unwrap()
        .1
        .to_string_lossy();
    let j: serde_json::Value = serde_json::from_str(&config).unwrap();
    assert_eq!(j["models"]["default"], "actual-selected-model");
    assert_eq!(
        j["model"]["actual-selected-model"]["env_key"],
        "AIGOODBRO_PROXY_KEY"
    );
    assert!(!config.contains(KEY));
    assert_eq!(p.arguments, vec!["--model", "actual-selected-model"]);
}
