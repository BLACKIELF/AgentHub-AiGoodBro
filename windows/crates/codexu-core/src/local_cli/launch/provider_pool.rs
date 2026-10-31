use super::*;
use crate::provider_pool::{client::ClientKind, NativeConnection, Provider};

impl Environment {
    /// Typed native-only gateway wiring. No arbitrary environment or secret
    /// argument is accepted by a WebView command.
    pub fn provider_pool(
        home: &Path,
        connection: &NativeConnection<'_>,
        provider: Provider,
        client: ClientKind,
        model: &str,
    ) -> Result<Self> {
        check_path(home)?;
        if connection.endpoint != format!("http://127.0.0.1:18081/providers/{}", provider.id())
            || !(32..=256).contains(&connection.client_key.len())
            || !connection
                .client_key
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
            || model.is_empty()
            || model.len() > 128
            || !model.as_bytes()[0].is_ascii_alphanumeric()
            || !model
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        {
            return Err(fail("environment_invalid"));
        }
        // Isolate the OS-home fallbacks as well as each documented CLI home;
        // inherited provider credentials, injection flags and proxies are absent.
        let mut out = Self::dependency_probe(home)?;
        // Interactive tools need the user's tool search path. All other
        // inherited variables still pass the clean-environment allowlist.
        if let Ok(path) = std::env::var("PATH") {
            if path.len() > 32767 || path.contains('\0') {
                return Err(fail("environment_invalid"));
            }
            if let Some((_, value)) = out.bindings.iter_mut().find(|(key, _)| key == "PATH") {
                *value = path;
            }
        }
        let endpoint = &connection.endpoint;
        let key = connection.client_key;
        let mut add = |k: &str, v: String| out.bindings.push((k.into(), v));
        if client == ClientKind::Codex {
            add("CODEX_HOME", home.to_string_lossy().into());
            add("AIGOODBRO_PROXY_KEY", key.into());
        } else {
            match provider {
                Provider::Claude => {
                    add("CLAUDE_CONFIG_DIR", home.to_string_lossy().into());
                    add("ANTHROPIC_BASE_URL", endpoint.clone());
                    add("ANTHROPIC_AUTH_TOKEN", key.into());
                    add("CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY", "1".into());
                    add("CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST", "1".into());
                    add("DISABLE_AUTOUPDATER", "1".into());
                }
                Provider::Kimi => {
                    add("KIMI_CODE_HOME", home.to_string_lossy().into());
                    add("KIMI_MODEL_NAME", model.into());
                    add("KIMI_MODEL_API_KEY", key.into());
                    add("KIMI_MODEL_PROVIDER_TYPE", "kimi".into());
                    add("KIMI_MODEL_BASE_URL", format!("{endpoint}/v1"));
                    add("KIMI_SHARE_DIR", home.to_string_lossy().into());
                    add("KIMI_CLI_NO_AUTO_UPDATE", "1".into());
                }
                Provider::Xai => {
                    add("GROK_HOME", home.to_string_lossy().into());
                    add(
                        "GROK_AUTH_PATH",
                        home.join("auth.json").to_string_lossy().into(),
                    );
                    let config = serde_json::json!({"models":{"default":model},"model":{(model):{"model":model,"base_url":format!("{endpoint}/v1"),"env_key":"AIGOODBRO_PROXY_KEY","api_backend":"responses"}}});
                    add("GROK_CONFIG", config.to_string());
                    add("AIGOODBRO_PROXY_KEY", key.into());
                    add("GROK_DISABLE_AUTOUPDATER", "1".into());
                }
                Provider::Antigravity => return Err(fail("provider_runtime_unverified")),
            }
        }
        Ok(out)
    }
}
