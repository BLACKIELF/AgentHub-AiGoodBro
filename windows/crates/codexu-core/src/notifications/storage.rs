use super::{domain::*, events::Baseline, fail, Failure, Result};
use crate::accounts::{storage as fs, SecretProtector};
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, path::PathBuf, sync::Arc};

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PersonalBinding {
    pub base_url: String,
    pub bot_id: String,
    pub user_id: String,
    pub context_token: Option<String>,
    pub context_checked_at: Option<i64>,
    pub cursor: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ChannelConfig {
    pub enabled: bool,
    pub revision: u64,
    pub secret: Option<String>,
    pub target: Option<String>,
    pub binding: Option<PersonalBinding>,
    pub options: MessageOptions,
    #[serde(default)]
    pub session_expired: bool,
}
impl Default for ChannelConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            revision: 0,
            secret: None,
            target: None,
            binding: None,
            options: Default::default(),
            session_expired: false,
        }
    }
}
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Phase {
    Pending,
    Sending,
    Sent,
    Uncertain,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Delivery {
    pub phase: Phase,
    pub attempt: String,
    pub revision: u64,
    pub at: i64,
}
#[derive(Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Vault {
    pub schema: u32,
    pub configs: BTreeMap<ChannelKind, ChannelConfig>,
    pub deliveries: BTreeMap<String, Delivery>,
    pub baselines: BTreeMap<String, Baseline>,
}
impl Vault {
    fn empty() -> Self {
        Self {
            schema: 1,
            ..Default::default()
        }
    }
    fn validate(&self) -> Result<()> {
        if self.schema != 1
            || self.configs.len() > 4
            || self.deliveries.len() > 16384
            || self.baselines.len() > 512
            || self
                .deliveries
                .iter()
                .any(|(k, v)| !super::valid_hash(k) || v.at <= 0 || v.attempt.len() != 32)
        {
            return fail("notification_store_invalid");
        }
        for (kind, c) in &self.configs {
            if let Some(secret) = &c.secret {
                super::protocol::validate_credential(
                    *kind,
                    secret,
                    c.target.as_deref(),
                    c.binding.as_ref(),
                )?;
            }
        }
        Ok(())
    }
}
pub(crate) struct Storage {
    root: PathBuf,
    protector: Arc<dyn SecretProtector>,
}
impl Storage {
    pub fn new(root: PathBuf, protector: Arc<dyn SecretProtector>) -> Result<Self> {
        if !root.is_absolute() {
            return fail("notification_store_invalid");
        }
        fs::secure_directory(&root).map_err(|_| Failure("notification_store_unavailable"))?;
        let s = Self { root, protector };
        s.read(|_| Ok(()))?;
        Ok(s)
    }
    fn load(&self) -> Result<Vault> {
        let bytes = fs::read_optional(&self.root.join("channels.dpapi"), 8 * 1024 * 1024)
            .map_err(|_| Failure("notification_store_unavailable"))?;
        match bytes {
            None => Ok(Vault::empty()),
            Some(bytes) => {
                let plain = self
                    .protector
                    .unseal("AiGoodBro.Next.Windows.notifications.v1", &bytes)
                    .map_err(|_| Failure("notification_credentials_unavailable"))?;
                let v: Vault = serde_json::from_slice(&plain)
                    .map_err(|_| Failure("notification_store_invalid"))?;
                v.validate()?;
                Ok(v)
            }
        }
    }
    pub fn read<T>(&self, f: impl FnOnce(&Vault) -> Result<T>) -> Result<T> {
        let _lock =
            fs::StoreLock::acquire(&self.root).map_err(|_| Failure("notification_store_busy"))?;
        f(&self.load()?)
    }
    pub fn change<T>(&self, f: impl FnOnce(&mut Vault) -> Result<T>) -> Result<T> {
        let _lock =
            fs::StoreLock::acquire(&self.root).map_err(|_| Failure("notification_store_busy"))?;
        let mut v = self.load()?;
        let result = f(&mut v)?;
        v.validate()?;
        let plain = serde_json::to_vec(&v).map_err(|_| Failure("notification_store_invalid"))?;
        if plain.len() > 8 * 1024 * 1024 {
            return fail("notification_store_capacity");
        }
        let sealed = self
            .protector
            .seal("AiGoodBro.Next.Windows.notifications.v1", &plain)
            .map_err(|_| Failure("notification_credentials_unavailable"))?;
        fs::atomic_write(&self.root.join("channels.dpapi"), &sealed)
            .map_err(|_| Failure("notification_store_unavailable"))?;
        Ok(result)
    }
}
