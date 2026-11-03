use super::{domain::*, fail, nonce, Result};
use crate::accounts::{storage as fs, SecretProtector};
use base64::Engine;
use serde::{Deserialize, Serialize};
use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};
const MAX_STORE: usize = 12 * 1024 * 1024;
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Record {
    metadata: AccountView,
    sealed: String,
}
#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Vault {
    version: u8,
    client_key: Option<String>,
    accounts: Vec<Record>,
}
pub(super) struct Store {
    pub root: PathBuf,
    protector: Arc<dyn SecretProtector>,
    mutex: Mutex<()>,
}
impl Store {
    pub fn new(root: PathBuf, protector: Arc<dyn SecretProtector>) -> Result<Self> {
        if !root.is_absolute()
            || root
                .components()
                .any(|p| matches!(p, std::path::Component::ParentDir))
        {
            return Err(fail("provider_pool_storage_invalid"));
        }
        fs::ensure_no_links(&root).map_err(|_| fail("provider_pool_storage_invalid"))?;
        Ok(Self {
            root,
            protector,
            mutex: Mutex::new(()),
        })
    }
    fn path(&self) -> PathBuf {
        self.root.join("pool-v1.json")
    }
    fn read(&self) -> Result<Vault> {
        let bytes = fs::read_bound_optional(&self.path(), MAX_STORE, true)
            .map_err(|_| fail("provider_pool_storage_unavailable"))?;
        let v: Vault = match bytes {
            None => Vault {
                version: 1,
                ..Default::default()
            },
            Some(bytes) => {
                serde_json::from_slice(&bytes).map_err(|_| fail("provider_pool_storage_invalid"))?
            }
        };
        if v.version != 1
            || v.accounts.len() > 100
            || v.client_key.as_ref().is_some_and(|s| s.len() > 1024)
        {
            return Err(fail("provider_pool_storage_invalid"));
        }
        let views: Vec<_> = v.accounts.iter().map(|r| r.metadata.clone()).collect();
        validate_rows(&views)?;
        if v.accounts
            .iter()
            .any(|r| r.sealed.len() > 96 * 1024 || r.sealed.is_empty())
        {
            return Err(fail("provider_pool_storage_invalid"));
        }
        Ok(v)
    }
    fn change<T>(&self, f: impl FnOnce(&mut Vault) -> Result<T>) -> Result<T> {
        let _mutex = self.mutex.lock().map_err(|_| fail("provider_pool_busy"))?;
        let _lock = fs::StoreLock::acquire(&self.root)
            .map_err(|_| fail("provider_pool_storage_unavailable"))?;
        let mut v = self.read()?;
        let result = f(&mut v)?;
        let bytes = serde_json::to_vec(&v).map_err(|_| fail("provider_pool_storage_invalid"))?;
        if bytes.len() > MAX_STORE {
            return Err(fail("provider_pool_capacity"));
        }
        fs::atomic_write(&self.path(), &bytes)
            .map_err(|_| fail("provider_pool_storage_unavailable"))?;
        Ok(result)
    }
    fn seal(&self, context: &str, b: &[u8]) -> Result<String> {
        let data = self
            .protector
            .seal(context, b)
            .map_err(|_| fail("provider_pool_secret_store_unavailable"))?;
        Ok(base64::engine::general_purpose::STANDARD.encode(data))
    }
    fn unseal(&self, context: &str, s: &str) -> Result<Vec<u8>> {
        let b = base64::engine::general_purpose::STANDARD
            .decode(s)
            .map_err(|_| fail("provider_pool_storage_invalid"))?;
        self.protector
            .unseal(context, &b)
            .map_err(|_| fail("provider_pool_secret_store_unavailable"))
    }
    fn context(c: &Credential) -> String {
        format!(
            "AiGoodBro.Windows.provider-pool.v1:{}:{}:{}",
            c.provider.id(),
            c.account_id,
            c.generation
        )
    }
    pub fn list(&self) -> Result<Vec<AccountView>> {
        Ok(self
            .read()?
            .accounts
            .into_iter()
            .map(|r| r.metadata.stopped())
            .collect())
    }
    pub fn bootstrap(&self) -> Result<(String, Vec<(AccountView, Credential)>)> {
        self.change(|v| {
            let key = match &v.client_key {
                Some(s) => String::from_utf8(
                    self.unseal("AiGoodBro.Windows.provider-pool.client-key.v1", s)?,
                )
                .map_err(|_| fail("provider_pool_storage_invalid"))?,
                None => {
                    let key = nonce()?;
                    v.client_key = Some(self.seal(
                        "AiGoodBro.Windows.provider-pool.client-key.v1",
                        key.as_bytes(),
                    )?);
                    key
                }
            };
            if !opaque(&key) || key.len() < 32 {
                return Err(fail("provider_pool_storage_invalid"));
            }
            let mut rows = Vec::new();
            for r in &v.accounts {
                let context = format!(
                    "AiGoodBro.Windows.provider-pool.v1:{}:{}:{}",
                    r.metadata.provider.id(),
                    r.metadata.id,
                    r.metadata.generation
                );
                let c: Credential = serde_json::from_slice(&self.unseal(&context, &r.sealed)?)
                    .map_err(|_| fail("provider_pool_storage_invalid"))?;
                c.validate()?;
                if c.provider != r.metadata.provider
                    || c.account_id != r.metadata.id
                    || c.generation != r.metadata.generation
                    || c.masked_identity != r.metadata.masked_identity
                {
                    return Err(fail("provider_pool_identity_changed"));
                }
                rows.push((r.metadata.clone(), c));
            }
            Ok((key, rows))
        })
    }
    pub fn persist(&self, c: &Credential, add: bool) -> Result<()> {
        c.validate()?;
        self.change(|v| {
            let existing = v
                .accounts
                .iter()
                .position(|r| r.metadata.id == c.account_id);
            if add && (existing.is_some() || v.accounts.len() >= 100) {
                return Err(fail("provider_pool_account_exists"));
            }
            if !add && existing.is_none() {
                return Err(fail("provider_pool_identity_changed"));
            }
            if let Some(i) = existing {
                let m = &v.accounts[i].metadata;
                if m.provider != c.provider
                    || m.generation != c.generation
                    || m.masked_identity != c.masked_identity
                {
                    return Err(fail("provider_pool_identity_changed"));
                }
            }
            let bytes =
                serde_json::to_vec(c).map_err(|_| fail("provider_pool_invalid_credential"))?;
            let sealed = self.seal(&Self::context(c), &bytes)?;
            if self.unseal(&Self::context(c), &sealed)? != bytes {
                return Err(fail("provider_pool_secret_store_unavailable"));
            }
            if let Some(i) = existing {
                v.accounts[i].sealed = sealed;
            } else {
                v.accounts.push(Record {
                    metadata: c.view(),
                    sealed,
                });
            }
            Ok(())
        })
    }
    pub fn enabled(&self, id: &str, generation: &str, enabled: bool) -> Result<AccountView> {
        self.change(|v| {
            let row = v
                .accounts
                .iter_mut()
                .find(|r| r.metadata.id == id && r.metadata.generation == generation)
                .ok_or_else(|| fail("provider_pool_identity_changed"))?;
            row.metadata.enabled = enabled;
            Ok(row.metadata.stopped())
        })
    }
    pub fn remove(&self, id: &str, generation: &str) -> Result<()> {
        self.change(|v| {
            let n = v.accounts.len();
            v.accounts
                .retain(|r| r.metadata.id != id || r.metadata.generation != generation);
            if n == v.accounts.len() {
                return Err(fail("provider_pool_identity_changed"));
            }
            Ok(())
        })
    }
    pub fn cooldowns(&self, rows: &[AccountView]) -> Result<()> {
        let v = self.read()?;
        if !rows.iter().any(|r| {
            v.accounts.iter().any(|old| {
                old.metadata.id == r.id
                    && old.metadata.generation == r.generation
                    && old.metadata.cooldown_until != r.cooldown_until
            })
        }) {
            return Ok(());
        }
        self.change(|v| {
            for row in rows {
                if let Some(r) = v.accounts.iter_mut().find(|r| {
                    r.metadata.id == row.id
                        && r.metadata.generation == row.generation
                        && r.metadata.provider == row.provider
                }) {
                    r.metadata.cooldown_until = row.cooldown_until;
                }
            }
            Ok(())
        })
    }
    pub fn owner(&self) -> Result<fs::StoreLock> {
        fs::StoreLock::acquire(&self.root.join("owner"))
            .map_err(|_| fail("provider_pool_owned_elsewhere"))
    }
}
pub(super) fn checked_root(root: &Path) -> Result<PathBuf> {
    fs::ensure_no_links(root).map_err(|_| fail("provider_pool_storage_invalid"))?;
    root.canonicalize()
        .map_err(|_| fail("provider_pool_storage_unavailable"))
}
