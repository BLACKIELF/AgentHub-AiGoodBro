use super::*;
pub const ABI: u32 = 1;
pub const MAX_FRAME: usize = 96 * 1024;

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Selector {
    pub profile_id: u64,
    pub project: String,
}
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Intent {
    pub selector: Selector,
    pub prompt: String,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub tier: Option<String>,
}
impl Intent {
    pub(super) fn validate(&self) -> Result<()> {
        self.selector.validate()?;
        if self.prompt.trim().is_empty()
            || self.prompt.len() > 64 * 1024
            || self.prompt.contains('\0')
        {
            return Err(fail("companion_invalid_prompt"));
        }
        // Current Hub consumes frozen saved preferences. Never silently ignore
        // an explicit Mac option that has not yet been ported to this backend.
        if self.model.is_some() || self.effort.is_some() || self.tier.is_some() {
            return Err(fail("companion_override_unsupported"));
        }
        Ok(())
    }
    pub(super) fn fingerprint(&self) -> Result<String> {
        self.validate()?;
        Ok(hash(
            &serde_json::to_vec(self).map_err(|_| fail("companion_invalid_request"))?,
        ))
    }
}
impl Selector {
    pub(super) fn validate(&self) -> Result<()> {
        if self.profile_id == 0
            || self.project.is_empty()
            || self.project.len() > 4096
            || self.project.contains(['\0', '\n', '\r'])
        {
            return Err(fail("companion_invalid_scope"));
        }
        // Absolute/canonical/existing directory checks belong to the native
        // scope consumer, against the actual configured App workspace.
        Ok(())
    }
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    pub abi: u32,
    pub request_id: String,
    pub method: Method,
}
#[derive(Serialize, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum Method {
    Preflight { selector: Selector },
    Refresh { selector: Selector },
    Reserve { intent: Intent },
    Run { lease_id: String, intent: Intent },
    Status { operation_id: String },
    CancelReservation { lease_id: String },
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "state",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum Reply {
    Ready {
        scope_sha256: String,
        valid_until_ms: u64,
    },
    Reserved {
        lease_id: String,
        scope_sha256: String,
        valid_until_ms: u64,
    },
    Cancelled,
    Unknown,
    /// Exact create is known; this request has no confirmed approval. The
    /// current task may separately have changed through the existing App UI.
    Created {
        task: TaskBinding,
        task_state: TaskState,
    },
    Accepted {
        task: TaskBinding,
        task_state: TaskState,
    },
    Missing,
}
impl Request {
    pub fn decode(frame: &[u8]) -> Result<Self> {
        if frame.len() < 4 || frame.len() > MAX_FRAME + 4 {
            return Err(fail("companion_invalid_frame"));
        }
        let length = u32::from_le_bytes(frame[..4].try_into().unwrap()) as usize;
        if length == 0 || length > MAX_FRAME || frame.len() != length + 4 {
            return Err(fail("companion_invalid_frame"));
        }
        let v: Self =
            serde_json::from_slice(&frame[4..]).map_err(|_| fail("companion_invalid_frame"))?;
        v.validate()?;
        Ok(v)
    }
    pub fn encode(&self) -> Result<Vec<u8>> {
        self.validate()?;
        let bytes = serde_json::to_vec(self).map_err(|_| fail("companion_invalid_frame"))?;
        if bytes.len() > MAX_FRAME {
            return Err(fail("companion_invalid_frame"));
        }
        let mut out = (bytes.len() as u32).to_le_bytes().to_vec();
        out.extend(bytes);
        Ok(out)
    }
    pub(super) fn validate(&self) -> Result<()> {
        if self.abi != ABI || !digest(&self.request_id) {
            return Err(fail("companion_invalid_request"));
        }
        match &self.method {
            Method::Preflight { selector } | Method::Refresh { selector } => selector.validate(),
            Method::Reserve { intent } => intent.validate(),
            Method::Run { lease_id, intent } => {
                if !digest(lease_id) {
                    return Err(fail("companion_invalid_lease"));
                }
                intent.validate()
            }
            Method::Status { operation_id } if digest(operation_id) => Ok(()),
            Method::CancelReservation { lease_id } if digest(lease_id) => Ok(()),
            _ => Err(fail("companion_invalid_request")),
        }
    }
}
