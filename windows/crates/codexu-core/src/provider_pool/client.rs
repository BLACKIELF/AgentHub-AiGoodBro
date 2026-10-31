//! Explicit pool-client plans. Only the local gateway key enters the child
//! environment; provider credentials, model prompts and global profiles do not.
use super::{fail, NativeConnection, Provider, Result};
use crate::{accounts::storage, local_cli::launch::Environment};
use serde::Deserialize;
use std::{
    collections::HashSet,
    io::{Read, Write},
    net::{Ipv4Addr, SocketAddr, SocketAddrV4, TcpStream},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

#[derive(Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ClientKind {
    Codex,
    Native,
}

/// No Serialize/Debug: this contains native-only environment material and the
/// exclusive home lease must live until the complete owned process tree exits.
pub struct ClientPlan {
    pub arguments: Vec<String>,
    pub environment: Environment,
    pub home: PathBuf,
    _lease: storage::StoreLock,
}

fn valid_model(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value.as_bytes()[0].is_ascii_alphanumeric()
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}

fn validate_connection(connection: &NativeConnection<'_>, provider: Provider) -> Result<()> {
    if connection.endpoint != format!("http://127.0.0.1:18081/providers/{}", provider.id())
        || !(32..=256).contains(&connection.client_key.len())
        || !connection
            .client_key
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
    {
        return Err(fail("provider_pool_connection_invalid"));
    }
    Ok(())
}

/// Called inside ProviderPool::with_connection so run/model admission cannot
/// change between the fresh catalog check and the native process creation.
pub fn confirm_model(
    connection: &NativeConnection<'_>,
    provider: Provider,
    model: &str,
) -> Result<()> {
    validate_connection(connection, provider)?;
    if !valid_model(model) {
        return Err(fail("provider_pool_models_unavailable"));
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    let address = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 18081));
    let mut stream = TcpStream::connect_timeout(&address, Duration::from_secs(2))
        .map_err(|_| fail("provider_pool_catalog_unavailable"))?;
    stream
        .set_write_timeout(Some(Duration::from_secs(2)))
        .map_err(|_| fail("provider_pool_catalog_unavailable"))?;
    // HTTP/1.0 + close avoids chunked framing. No redirect, proxy or DNS lookup.
    let request = format!("GET /providers/{}/v1/models HTTP/1.0\r\nHost: 127.0.0.1:18081\r\nAuthorization: Bearer {}\r\nConnection: close\r\n\r\n", provider.id(), connection.client_key);
    stream
        .write_all(request.as_bytes())
        .map_err(|_| fail("provider_pool_catalog_unavailable"))?;
    let mut bytes = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or_else(|| fail("provider_pool_catalog_unavailable"))?;
        stream
            .set_read_timeout(Some(remaining))
            .map_err(|_| fail("provider_pool_catalog_unavailable"))?;
        let n = stream
            .read(&mut chunk)
            .map_err(|_| fail("provider_pool_catalog_unavailable"))?;
        if n == 0 {
            break;
        }
        if bytes.len() + n > 262144 + 16384 {
            return Err(fail("provider_pool_catalog_invalid"));
        }
        bytes.extend_from_slice(&chunk[..n]);
    }
    if !catalog_models(&bytes)?.iter().any(|known| known == model) {
        return Err(fail("provider_pool_models_unavailable"));
    }
    Ok(())
}

fn catalog_models(bytes: &[u8]) -> Result<Vec<String>> {
    let at = bytes
        .windows(4)
        .position(|p| p == b"\r\n\r\n")
        .filter(|at| *at <= 16384)
        .ok_or_else(|| fail("provider_pool_catalog_invalid"))?;
    let headers =
        std::str::from_utf8(&bytes[..at]).map_err(|_| fail("provider_pool_catalog_invalid"))?;
    let mut lines = headers.split("\r\n");
    let status = lines.next().unwrap_or_default();
    if !status.starts_with("HTTP/1.0 200 ") && !status.starts_with("HTTP/1.1 200 ") {
        return Err(fail("provider_pool_catalog_unavailable"));
    }
    let body = &bytes[at + 4..];
    if body.len() > 262144 {
        return Err(fail("provider_pool_catalog_invalid"));
    }
    let mut names = HashSet::new();
    for line in lines {
        let (name, value) = line
            .split_once(':')
            .ok_or_else(|| fail("provider_pool_catalog_invalid"))?;
        let name = name.to_ascii_lowercase();
        if !names.insert(name.clone()) || name == "transfer-encoding" || name == "location" {
            return Err(fail("provider_pool_catalog_invalid"));
        }
        if name == "content-length" && value.trim().parse::<usize>().ok() != Some(body.len()) {
            return Err(fail("provider_pool_catalog_invalid"));
        }
    }
    #[derive(Deserialize)]
    struct Row {
        id: String,
    }
    #[derive(Deserialize)]
    struct Catalog {
        object: String,
        data: Vec<Row>,
    }
    let catalog: Catalog =
        serde_json::from_slice(body).map_err(|_| fail("provider_pool_catalog_invalid"))?;
    let mut unique = HashSet::new();
    if catalog.object != "list"
        || catalog.data.len() > 512
        || catalog
            .data
            .iter()
            .any(|r| !valid_model(&r.id) || !unique.insert(r.id.clone()))
    {
        return Err(fail("provider_pool_catalog_invalid"));
    }
    Ok(catalog.data.into_iter().map(|r| r.id).collect())
}

pub fn prepare(
    app_data: &Path,
    connection: &NativeConnection<'_>,
    provider: Provider,
    kind: ClientKind,
    model: &str,
) -> Result<ClientPlan> {
    validate_connection(connection, provider)?;
    if !valid_model(model) || (kind == ClientKind::Native && provider == Provider::Antigravity) {
        return Err(fail("provider_pool_client_unavailable"));
    }
    let root = app_data.join("provider-clients-v1");
    let home = root.join(format!(
        "{}-{}",
        if kind == ClientKind::Codex {
            "codex"
        } else {
            "native"
        },
        provider.id()
    ));
    if !app_data.is_absolute()
        || app_data
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return Err(fail("provider_pool_storage_invalid"));
    }
    storage::secure_directory(&root).map_err(|_| fail("provider_pool_storage_unavailable"))?;
    storage::secure_directory(&home).map_err(|_| fail("provider_pool_storage_unavailable"))?;
    let lease =
        storage::StoreLock::acquire(&home).map_err(|_| fail("provider_pool_client_busy"))?;
    let environment = Environment::provider_pool(&home, connection, provider, kind, model)
        .map_err(|_| fail("provider_pool_client_invalid"))?;
    let arguments = if kind == ClientKind::Codex {
        vec!["-m".into(), model.into(), "-c".into(), "model_provider=\"aigoodbro_local\"".into(),
            "-c".into(), format!("model_providers.aigoodbro_local={{name=\"AiGoodBro\",base_url=\"{}/v1\",env_key=\"AIGOODBRO_PROXY_KEY\",wire_api=\"responses\",requires_openai_auth=false,supports_websockets=false}}", connection.endpoint),
            "-c".into(), "features.enable_request_compression=false".into()]
    } else if provider == Provider::Kimi {
        vec![]
    } else {
        vec!["--model".into(), model.into()]
    };
    Ok(ClientPlan {
        arguments,
        environment,
        home,
        _lease: lease,
    })
}

#[cfg(test)]
#[path = "client_tests.rs"]
mod tests;
