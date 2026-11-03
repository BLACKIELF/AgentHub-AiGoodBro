//! Typed Antigravity CLI client contract for the isolated provider pool.
//! Gateway credentials never enter settings or argv.
use super::{fail, NativeConnection, Provider, Result};
use crate::{accounts::storage, local_cli::launch::Environment};
use std::path::Path;

const MAX_SETTINGS: usize = 64 * 1024;

fn validate(connection: &NativeConnection<'_>, provider: Provider) -> Result<()> {
    if provider != Provider::Antigravity
        || connection.endpoint != "http://127.0.0.1:18081/providers/antigravity"
        || !(32..=256).contains(&connection.client_key.len())
        || !connection
            .client_key
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
    {
        return Err(fail("provider_pool_client_unavailable"));
    }
    Ok(())
}

fn prepare_settings(home: &Path) -> Result<()> {
    let directory = home.join("antigravity-cli");
    storage::secure_directory(&directory).map_err(|_| fail("provider_pool_storage_unavailable"))?;
    let path = directory.join("settings.json");
    let bytes = storage::read_bound_optional(&path, MAX_SETTINGS, true)
        .map_err(|_| fail("provider_pool_storage_unavailable"))?;
    let mut settings = match bytes {
        None => serde_json::Map::new(),
        Some(bytes) => serde_json::from_slice::<serde_json::Value>(&bytes)
            .map_err(|_| fail("provider_pool_storage_invalid"))?
            .as_object()
            .cloned()
            .ok_or_else(|| fail("provider_pool_storage_invalid"))?,
    };
    settings.insert(
        "modelProvider".into(),
        serde_json::Value::String("gemini".into()),
    );
    let bytes = serde_json::to_vec(&settings).map_err(|_| fail("provider_pool_storage_invalid"))?;
    if bytes.len() > MAX_SETTINGS {
        return Err(fail("provider_pool_capacity"));
    }
    storage::atomic_write(&path, &bytes).map_err(|_| fail("provider_pool_storage_unavailable"))
}

/// Builds a private Agy launch plan. Call only after the pool's fresh model
/// catalog check and while its connection gate remains held.
pub(super) fn prepare(
    home: &Path,
    connection: &NativeConnection<'_>,
    provider: Provider,
) -> Result<(Vec<String>, Environment)> {
    validate(connection, provider)?;
    prepare_settings(home)?;
    // Match the shipped Mac consumer: it selects the current Agy default and
    // passes only a private gemini_dir, never a guessed model override.
    let arguments = vec![format!("--gemini_dir={}", home.to_string_lossy())];
    let environment = Environment::agy_provider_pool(home, connection, provider)
        .map_err(|_| fail("provider_pool_client_invalid"))?;
    Ok((arguments, environment))
}

#[cfg(test)]
#[path = "agy_tests.rs"]
mod tests;
