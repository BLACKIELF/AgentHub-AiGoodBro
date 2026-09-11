//! Account identity, execution preference and local CLI accounts.
//!
//! This is the Windows counterpart of the macOS AiGoodBro account model. The
//! enums and validation rules mirror `CodexExecutionPreference` in
//! `Sources/CodexUsageWidget/Services/CodexProfileStore.swift` so that a
//! preference saved on one platform means the same thing on the other.
//!
//! Invariants that must never be relaxed:
//!
//! * No credential material, raw account email or absolute local path is stored
//!   here. Readers reduce upstream evidence before constructing these values.
//! * A blank or unsupported preference is *rejected*, never silently defaulted.
//!   A task that starts with unusable parameters has already reserved the
//!   account, which is worse than refusing up front.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// Local CLI families supported by the Windows workbench.
///
/// `MiMo` and `ZCode` native subscription quota is not wired up yet, which
/// `has_official_quota` reports so the UI can say so explicitly instead of
/// rendering a fake `0`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LocalCliKind {
    Codex,
    Grok,
    KimiCode,
    ClaudeCode,
    OpenCode,
    GeminiCli,
    MiMo,
    ZCode,
}

impl LocalCliKind {
    pub const ALL: [LocalCliKind; 8] = [
        LocalCliKind::Codex,
        LocalCliKind::Grok,
        LocalCliKind::KimiCode,
        LocalCliKind::ClaudeCode,
        LocalCliKind::OpenCode,
        LocalCliKind::GeminiCli,
        LocalCliKind::MiMo,
        LocalCliKind::ZCode,
    ];

    /// Stable identifier used across the IPC boundary.
    pub fn id(self) -> &'static str {
        match self {
            LocalCliKind::Codex => "codex",
            LocalCliKind::Grok => "grok",
            LocalCliKind::KimiCode => "kimi_code",
            LocalCliKind::ClaudeCode => "claude_code",
            LocalCliKind::OpenCode => "opencode",
            LocalCliKind::GeminiCli => "gemini_cli",
            LocalCliKind::MiMo => "mimo",
            LocalCliKind::ZCode => "zcode",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            LocalCliKind::Codex => "Codex",
            LocalCliKind::Grok => "Grok",
            LocalCliKind::KimiCode => "Kimi Code",
            LocalCliKind::ClaudeCode => "Claude Code",
            LocalCliKind::OpenCode => "OpenCode",
            LocalCliKind::GeminiCli => "Gemini CLI",
            LocalCliKind::MiMo => "MiMo",
            LocalCliKind::ZCode => "ZCode",
        }
    }

    /// Whether this CLI can currently report official subscription quota.
    pub fn has_official_quota(self) -> bool {
        !matches!(self, LocalCliKind::MiMo | LocalCliKind::ZCode)
    }

    /// Whether the Windows workbench can launch an isolated session for this CLI.
    ///
    /// Only Codex has a launch path in this slice; the rest stay read-only until
    /// their login workflow is ported.
    pub fn supports_isolated_launch(self) -> bool {
        matches!(self, LocalCliKind::Codex)
    }
}

/// Primary model selectable for an account.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum CodexModel {
    #[serde(rename = "gpt-6-astra")]
    Astra,
    #[serde(rename = "gpt-5.6-sol")]
    Sol,
    #[serde(rename = "gpt-5.6-terra")]
    Terra,
    #[serde(rename = "gpt-5.6-luna")]
    Luna,
    #[serde(rename = "gpt-5.5")]
    Gpt55,
    #[serde(rename = "gpt-5.2")]
    Gpt52,
}

const ALL_REASONING_EFFORTS: [ReasoningEffort; 6] = [
    ReasoningEffort::Low,
    ReasoningEffort::Medium,
    ReasoningEffort::High,
    ReasoningEffort::XHigh,
    ReasoningEffort::Max,
    ReasoningEffort::Ultra,
];
const LUNA_REASONING_EFFORTS: [ReasoningEffort; 5] = [
    ReasoningEffort::Low,
    ReasoningEffort::Medium,
    ReasoningEffort::High,
    ReasoningEffort::XHigh,
    ReasoningEffort::Max,
];
const LEGACY_REASONING_EFFORTS: [ReasoningEffort; 4] = [
    ReasoningEffort::Low,
    ReasoningEffort::Medium,
    ReasoningEffort::High,
    ReasoningEffort::XHigh,
];

impl CodexModel {
    pub const ALL: [CodexModel; 6] = [
        CodexModel::Astra,
        CodexModel::Sol,
        CodexModel::Terra,
        CodexModel::Luna,
        CodexModel::Gpt55,
        CodexModel::Gpt52,
    ];

    /// Wire value persisted on disk and sent to the CLI.
    pub fn raw_value(self) -> &'static str {
        match self {
            CodexModel::Astra => "gpt-6-astra",
            CodexModel::Sol => "gpt-5.6-sol",
            CodexModel::Terra => "gpt-5.6-terra",
            CodexModel::Luna => "gpt-5.6-luna",
            CodexModel::Gpt55 => "gpt-5.5",
            CodexModel::Gpt52 => "gpt-5.2",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            CodexModel::Astra => "GPT-6 Astra",
            CodexModel::Sol => "5.6 Sol",
            CodexModel::Terra => "5.6 Terra",
            CodexModel::Luna => "5.6 Luna",
            CodexModel::Gpt55 => "GPT-5.5",
            CodexModel::Gpt52 => "GPT-5.2",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        let trimmed = value.trim();
        CodexModel::ALL
            .into_iter()
            .find(|model| model.raw_value() == trimmed)
    }

    /// Reasoning levels this model actually accepts.
    pub fn supported_reasoning_efforts(self) -> &'static [ReasoningEffort] {
        match self {
            CodexModel::Astra | CodexModel::Sol | CodexModel::Terra => &ALL_REASONING_EFFORTS,
            CodexModel::Luna => &LUNA_REASONING_EFFORTS,
            CodexModel::Gpt55 | CodexModel::Gpt52 => &LEGACY_REASONING_EFFORTS,
        }
    }

    pub fn supports_reasoning_effort(self, effort: ReasoningEffort) -> bool {
        self.supported_reasoning_efforts().contains(&effort)
    }

    /// Whether Fast service tier is available for this model.
    pub fn supports_fast(self) -> bool {
        self != CodexModel::Gpt52
    }
}

/// Reasoning effort handed to the target CLI.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReasoningEffort {
    Low,
    Medium,
    High,
    XHigh,
    Max,
    Ultra,
}

impl ReasoningEffort {
    pub const ALL: [ReasoningEffort; 6] = ALL_REASONING_EFFORTS;

    pub fn raw_value(self) -> &'static str {
        match self {
            ReasoningEffort::Low => "low",
            ReasoningEffort::Medium => "medium",
            ReasoningEffort::High => "high",
            ReasoningEffort::XHigh => "xhigh",
            ReasoningEffort::Max => "max",
            ReasoningEffort::Ultra => "ultra",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            ReasoningEffort::Low => "Low",
            ReasoningEffort::Medium => "Medium",
            ReasoningEffort::High => "High",
            ReasoningEffort::XHigh => "XHigh",
            ReasoningEffort::Max => "Max",
            ReasoningEffort::Ultra => "Ultra",
        }
    }

    pub fn localized_title_zh(self) -> &'static str {
        match self {
            ReasoningEffort::Low => "低",
            ReasoningEffort::Medium => "中",
            ReasoningEffort::High => "高",
            ReasoningEffort::XHigh => "特高",
            ReasoningEffort::Max => "最高",
            ReasoningEffort::Ultra => "Ultra",
        }
    }
}

/// Service tier. `Standard` serialises as `default` to stay wire-compatible.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ServiceTier {
    #[serde(rename = "default")]
    Standard,
    #[serde(rename = "fast")]
    Fast,
}

impl ServiceTier {
    pub fn raw_value(self) -> &'static str {
        match self {
            ServiceTier::Standard => "default",
            ServiceTier::Fast => "fast",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            ServiceTier::Standard => "Standard",
            ServiceTier::Fast => "Fast",
        }
    }
}

/// Sub-agent execution style. Unknown stored values are preserved verbatim by
/// `from_raw_value` returning `None`, which validation turns into a rejection.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SubagentMode {
    Standard,
    SolLuna,
    LunaDirect,
}

impl SubagentMode {
    pub const ALL: [SubagentMode; 3] = [
        SubagentMode::Standard,
        SubagentMode::SolLuna,
        SubagentMode::LunaDirect,
    ];

    pub fn raw_value(self) -> &'static str {
        match self {
            SubagentMode::Standard => "standard",
            SubagentMode::SolLuna => "sol_luna",
            SubagentMode::LunaDirect => "luna_direct",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        let trimmed = value.trim();
        SubagentMode::ALL
            .into_iter()
            .find(|mode| mode.raw_value() == trimmed)
    }
}

/// Maximum UTF-8 byte length of a custom preset name.
pub const MAX_PRESET_NAME_BYTES: usize = 64;

/// A named, editable execution preset.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CustomPreset {
    pub name: Option<String>,
    pub use_saved_model: bool,
    pub model: CodexModel,
    pub reasoning_effort: ReasoningEffort,
    pub subagents_enabled: bool,
    pub subagent_model: CodexModel,
    pub subagent_reasoning_effort: ReasoningEffort,
}

/// The concrete parameters a launch would use.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct EffectiveStrategy {
    pub main_model: CodexModel,
    pub main_reasoning_effort: ReasoningEffort,
    pub subagent_model: Option<CodexModel>,
    pub subagent_reasoning_effort: Option<ReasoningEffort>,
    pub maximum_concurrent_subagents: u8,
}

/// Per-account execution preference.
///
/// Applied to *subsequent* tasks only. Already running tasks keep the parameters
/// they were launched with, so this value never rewrites an in-flight session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExecutionPreference {
    pub model: CodexModel,
    pub reasoning_effort: ReasoningEffort,
    pub service_tier: ServiceTier,
    #[serde(default = "default_subagent_mode")]
    pub subagent_mode: SubagentMode,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub custom_presets: BTreeMap<String, CustomPreset>,
}

fn default_subagent_mode() -> SubagentMode {
    SubagentMode::Standard
}

impl Default for ExecutionPreference {
    fn default() -> Self {
        Self {
            model: CodexModel::Astra,
            reasoning_effort: ReasoningEffort::Low,
            service_tier: ServiceTier::Standard,
            subagent_mode: SubagentMode::Standard,
            custom_presets: BTreeMap::new(),
        }
    }
}

impl ExecutionPreference {
    /// Built-in preset for a mode, before any user customisation.
    pub fn default_preset(mode: SubagentMode) -> Option<CustomPreset> {
        match mode {
            SubagentMode::Standard => Some(CustomPreset {
                name: None,
                use_saved_model: true,
                model: CodexModel::Astra,
                reasoning_effort: ReasoningEffort::Low,
                subagents_enabled: false,
                subagent_model: CodexModel::Luna,
                subagent_reasoning_effort: ReasoningEffort::Max,
            }),
            SubagentMode::SolLuna => Some(CustomPreset {
                name: None,
                use_saved_model: false,
                model: CodexModel::Sol,
                reasoning_effort: ReasoningEffort::High,
                subagents_enabled: true,
                subagent_model: CodexModel::Luna,
                subagent_reasoning_effort: ReasoningEffort::Max,
            }),
            SubagentMode::LunaDirect => Some(CustomPreset {
                name: None,
                use_saved_model: false,
                model: CodexModel::Luna,
                reasoning_effort: ReasoningEffort::Max,
                subagents_enabled: false,
                subagent_model: CodexModel::Luna,
                subagent_reasoning_effort: ReasoningEffort::Max,
            }),
        }
    }

    /// The stored preset for a mode, falling back to the built-in one.
    pub fn preset(&self, mode: SubagentMode) -> Option<CustomPreset> {
        let built_in = Self::default_preset(mode)?;
        Some(
            self.custom_presets
                .get(mode.raw_value())
                .cloned()
                .unwrap_or(built_in),
        )
    }

    pub fn custom_name(&self, mode: SubagentMode) -> Option<String> {
        self.preset(mode).and_then(|preset| preset.name)
    }

    /// Drop a user customisation and go back to the built-in preset.
    pub fn restoring_default(&self, mode: SubagentMode) -> Self {
        let mut restored = self.clone();
        restored.custom_presets.remove(mode.raw_value());
        restored
    }

    pub fn effective_strategy(&self) -> EffectiveStrategy {
        self.effective_strategy_for(self.subagent_mode)
            .unwrap_or(EffectiveStrategy {
                main_model: self.model,
                main_reasoning_effort: self.reasoning_effort,
                subagent_model: None,
                subagent_reasoning_effort: None,
                maximum_concurrent_subagents: 0,
            })
    }

    pub fn effective_strategy_for(&self, mode: SubagentMode) -> Option<EffectiveStrategy> {
        let preset = self.preset(mode)?;
        let main_model = if preset.use_saved_model {
            self.model
        } else {
            preset.model
        };
        let main_effort = if preset.use_saved_model {
            self.reasoning_effort
        } else {
            preset.reasoning_effort
        };
        Some(EffectiveStrategy {
            main_model,
            main_reasoning_effort: main_effort,
            subagent_model: preset.subagents_enabled.then_some(preset.subagent_model),
            subagent_reasoning_effort: preset
                .subagents_enabled
                .then_some(preset.subagent_reasoning_effort),
            maximum_concurrent_subagents: if preset.subagents_enabled { 1 } else { 0 },
        })
    }

    /// Full validation: stored settings plus the effective strategy.
    pub fn validate(&self) -> Result<(), PreferenceError> {
        self.validate_stored_settings()?;
        let strategy = self.effective_strategy();
        if !strategy
            .main_model
            .supports_reasoning_effort(strategy.main_reasoning_effort)
        {
            return Err(PreferenceError::UnsupportedReasoningEffort {
                model: strategy.main_model.raw_value(),
                reasoning_effort: strategy.main_reasoning_effort.raw_value(),
            });
        }
        if self.service_tier == ServiceTier::Fast {
            if !strategy.main_model.supports_fast() {
                return Err(PreferenceError::FastUnavailable {
                    model: strategy.main_model.raw_value(),
                });
            }
            if let Some(subagent_model) = strategy.subagent_model {
                if !subagent_model.supports_fast() {
                    return Err(PreferenceError::FastUnavailable {
                        model: subagent_model.raw_value(),
                    });
                }
            }
        }
        Ok(())
    }

    fn validate_stored_settings(&self) -> Result<(), PreferenceError> {
        if !self.model.supports_reasoning_effort(self.reasoning_effort) {
            return Err(PreferenceError::UnsupportedReasoningEffort {
                model: self.model.raw_value(),
                reasoning_effort: self.reasoning_effort.raw_value(),
            });
        }
        let supported_keys: Vec<&str> =
            SubagentMode::ALL.iter().map(|mode| mode.raw_value()).collect();
        if self.custom_presets.len() > supported_keys.len()
            || !self
                .custom_presets
                .keys()
                .all(|key| supported_keys.contains(&key.as_str()))
        {
            return Err(PreferenceError::UnsupportedCustomPreset);
        }
        for preset in self.custom_presets.values() {
            if let Some(name) = &preset.name {
                validate_preset_name(name)?;
            }
            if !preset.model.supports_reasoning_effort(preset.reasoning_effort) {
                return Err(PreferenceError::UnsupportedReasoningEffort {
                    model: preset.model.raw_value(),
                    reasoning_effort: preset.reasoning_effort.raw_value(),
                });
            }
            if !preset
                .subagent_model
                .supports_reasoning_effort(preset.subagent_reasoning_effort)
            {
                return Err(PreferenceError::UnsupportedReasoningEffort {
                    model: preset.subagent_model.raw_value(),
                    reasoning_effort: preset.subagent_reasoning_effort.raw_value(),
                });
            }
        }
        Ok(())
    }
}

/// Preset names must be 1–64 UTF-8 bytes with no surrounding whitespace and no
/// control characters.
pub fn validate_preset_name(name: &str) -> Result<(), PreferenceError> {
    if name.is_empty() || name.trim() != name || name.bytes().len() > MAX_PRESET_NAME_BYTES {
        return Err(PreferenceError::InvalidPresetName);
    }
    if name.chars().any(char::is_control) {
        return Err(PreferenceError::InvalidPresetName);
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PreferenceError {
    #[error("an execution preference needs a non-empty account id")]
    EmptyAccountId,
    #[error("stored execution style is not supported")]
    UnsupportedExecutionMode,
    #[error("model {model} does not support reasoning level {reasoning_effort}")]
    UnsupportedReasoningEffort {
        model: &'static str,
        reasoning_effort: &'static str,
    },
    #[error("model {model} does not support Fast mode")]
    FastUnavailable { model: &'static str },
    #[error("custom presets contain an unsupported slot")]
    UnsupportedCustomPreset,
    #[error("preset names must be 1-64 UTF-8 bytes with no surrounding whitespace or control characters")]
    InvalidPresetName,
    #[error("execution preferences cannot be saved for the system account")]
    SystemProfileUnsupported,
}

/// Model availability as observed for one local CLI account.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ModelAvailability {
    /// A local model receipt was read and lists at least one usable model.
    Available,
    /// The CLI is present but no receipt has been observed yet.
    Unknown,
    /// The CLI is present but has no usable login.
    NotConnected,
}

/// Reduced account identity. Never carries the raw email or credential material.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountIdentity {
    /// Stable opaque identifier derived from the local login, never from the email.
    pub id: String,
    /// User-facing remark. Defaults to the masked email when unset.
    pub label: String,
    /// Masked email such as `a***@example.com`. `None` when unknown.
    pub masked_email: Option<String>,
    /// Plan label as reported locally, e.g. `plus`. `None` when unknown.
    pub plan_label: Option<String>,
    pub is_signed_in: bool,
}

/// One managed account on the Windows workbench.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountRecord {
    pub identity: AccountIdentity,
    /// Directory *basename* only. The full local path is never persisted here.
    pub home_dir_label: String,
    pub preference: ExecutionPreference,
    /// Whether this account may receive new dispatched tasks.
    pub participates_in_dispatch: bool,
    /// Display order. Lower sorts first.
    pub order: i64,
    /// Whether the user pinned this account to the first position.
    pub pinned_first: bool,
    /// The system (non-isolated) login is read-only: it never stores a preference.
    pub is_system_profile: bool,
}

impl AccountRecord {
    /// Whether the account is usable for a new task at all.
    pub fn is_dispatch_eligible(&self) -> bool {
        self.identity.is_signed_in && self.participates_in_dispatch
    }

    /// The system profile keeps its preference read-only.
    pub fn can_store_preference(&self) -> bool {
        !self.is_system_profile
    }
}

/// A local CLI account discovered on disk.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalCliAccount {
    pub id: String,
    pub kind: LocalCliKind,
    pub label: String,
    /// Login directory *basename* only.
    pub login_dir_label: String,
    pub model_availability: ModelAvailability,
}

impl LocalCliAccount {
    /// Whether the UI must state that quota is unavailable rather than showing 0.
    pub fn quota_is_wired(&self) -> bool {
        self.kind.has_official_quota()
    }
}

/// Stored per-account preference overrides, keyed by account id.
///
/// The reader always produces the *default* preference; this is the layer that
/// remembers a user choice. It is deliberately fail-closed: an override that no
/// longer validates is skipped rather than applied, so a stale or hand-edited
/// file can never hand an unusable model/effort combination to a launch.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreferenceOverrides {
    #[serde(default)]
    entries: BTreeMap<String, ExecutionPreference>,
}

impl PreferenceOverrides {
    pub fn get(&self, account_id: &str) -> Option<&ExecutionPreference> {
        self.entries.get(account_id)
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Store a preference, rejecting anything that does not validate.
    pub fn set(
        &mut self,
        account_id: &str,
        preference: ExecutionPreference,
    ) -> Result<(), PreferenceError> {
        let account_id = account_id.trim();
        if account_id.is_empty() {
            return Err(PreferenceError::EmptyAccountId);
        }
        preference.validate()?;
        self.entries.insert(account_id.to_string(), preference);
        Ok(())
    }

    pub fn remove(&mut self, account_id: &str) -> bool {
        self.entries.remove(account_id).is_some()
    }

    /// Apply overrides in place and report how many were applied.
    ///
    /// Skips the system profile (read-only by contract) and skips any entry that
    /// fails validation.
    pub fn apply(&self, accounts: &mut [AccountRecord]) -> usize {
        let mut applied = 0;
        for account in accounts.iter_mut() {
            if !account.can_store_preference() {
                continue;
            }
            let Some(preference) = self.entries.get(&account.identity.id) else {
                continue;
            };
            if preference.validate().is_err() {
                continue;
            }
            account.preference = preference.clone();
            applied += 1;
        }
        applied
    }

    /// Drop entries that no longer validate, returning how many were removed.
    pub fn sanitize(&mut self) -> usize {
        let before = self.entries.len();
        self.entries
            .retain(|_, preference| preference.validate().is_ok());
        before - self.entries.len()
    }
}

/// Reduce an email address to a stable, non-reversible label.
///
/// `alice@example.com` becomes `a***@example.com`. Returns `None` for blank
/// input or input without a usable `@`, so callers never keep the raw value as a
/// fallback.
///
/// The result is lower-cased. The source compares emails case-insensitively
/// (`CodexOfficialProfileReader.normalizedEmail` lower-cases both sides), so a
/// case-preserving label would render one login as two different accounts.
pub fn mask_email(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }

    let (local, domain) = trimmed.split_once('@')?;
    let domain = domain.trim();
    if local.is_empty() || domain.is_empty() {
        return None;
    }

    let mut chars = local.chars();
    let first = chars.next()?;
    Some(format!("{}***@{}", first, domain).to_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn preset(name: Option<&str>) -> CustomPreset {
        CustomPreset {
            name: name.map(str::to_string),
            use_saved_model: false,
            model: CodexModel::Sol,
            reasoning_effort: ReasoningEffort::High,
            subagents_enabled: true,
            subagent_model: CodexModel::Luna,
            subagent_reasoning_effort: ReasoningEffort::Max,
        }
    }

    #[test]
    fn masks_email_and_never_keeps_the_local_part() {
        assert_eq!(
            mask_email("alice@example.com").as_deref(),
            Some("a***@example.com")
        );
        assert_eq!(
            mask_email("  bob.smith@corp.example  ").as_deref(),
            Some("b***@corp.example")
        );
        assert_eq!(mask_email(""), None);
        assert_eq!(mask_email("   "), None);
        assert_eq!(mask_email("no-at-sign"), None);
        assert_eq!(mask_email("@example.com"), None);
        assert_eq!(mask_email("alice@"), None);
    }

    #[test]
    fn masked_label_does_not_contain_the_original_local_part() {
        let masked = mask_email("alice@example.com").expect("masked");
        assert!(!masked.contains("lice"));
    }

    #[test]
    fn masked_label_is_lower_cased_so_one_login_cannot_render_twice() {
        assert_eq!(
            mask_email("Alice@Example.COM").as_deref(),
            Some("a***@example.com")
        );
        assert_eq!(
            mask_email("ALICE@example.com"),
            mask_email("alice@EXAMPLE.com")
        );
    }

    #[test]
    fn default_preference_matches_the_macos_default() {
        let preference = ExecutionPreference::default();
        assert_eq!(preference.model, CodexModel::Astra);
        assert_eq!(preference.model.raw_value(), "gpt-6-astra");
        assert_eq!(preference.reasoning_effort, ReasoningEffort::Low);
        assert_eq!(preference.service_tier, ServiceTier::Standard);
        assert_eq!(preference.subagent_mode, SubagentMode::Standard);
        assert!(preference.custom_presets.is_empty());
        assert_eq!(preference.validate(), Ok(()));
    }

    #[test]
    fn model_raw_values_match_the_stored_contract() {
        let pairs = [
            (CodexModel::Astra, "gpt-6-astra"),
            (CodexModel::Sol, "gpt-5.6-sol"),
            (CodexModel::Terra, "gpt-5.6-terra"),
            (CodexModel::Luna, "gpt-5.6-luna"),
            (CodexModel::Gpt55, "gpt-5.5"),
            (CodexModel::Gpt52, "gpt-5.2"),
        ];
        for (model, raw) in pairs {
            assert_eq!(model.raw_value(), raw);
            assert_eq!(CodexModel::from_raw_value(raw), Some(model));
        }
        assert_eq!(CodexModel::from_raw_value("gpt-9-unknown"), None);
        assert_eq!(CodexModel::Astra.display_name(), "GPT-6 Astra");
    }

    #[test]
    fn reasoning_support_matrix_matches_the_product() {
        for effort in ReasoningEffort::ALL {
            assert!(CodexModel::Astra.supports_reasoning_effort(effort));
            assert!(CodexModel::Sol.supports_reasoning_effort(effort));
            assert!(CodexModel::Terra.supports_reasoning_effort(effort));
        }

        assert!(CodexModel::Luna.supports_reasoning_effort(ReasoningEffort::Max));
        assert!(!CodexModel::Luna.supports_reasoning_effort(ReasoningEffort::Ultra));

        assert!(CodexModel::Gpt55.supports_reasoning_effort(ReasoningEffort::XHigh));
        assert!(!CodexModel::Gpt55.supports_reasoning_effort(ReasoningEffort::Max));
        assert!(!CodexModel::Gpt52.supports_reasoning_effort(ReasoningEffort::Ultra));
    }

    #[test]
    fn only_gpt52_lacks_fast_tier() {
        assert!(CodexModel::Astra.supports_fast());
        assert!(CodexModel::Sol.supports_fast());
        assert!(CodexModel::Terra.supports_fast());
        assert!(CodexModel::Luna.supports_fast());
        assert!(CodexModel::Gpt55.supports_fast());
        assert!(!CodexModel::Gpt52.supports_fast());
    }

    #[test]
    fn unsupported_effort_is_rejected_instead_of_defaulted() {
        let preference = ExecutionPreference {
            model: CodexModel::Luna,
            reasoning_effort: ReasoningEffort::Ultra,
            ..ExecutionPreference::default()
        };
        assert_eq!(
            preference.validate(),
            Err(PreferenceError::UnsupportedReasoningEffort {
                model: "gpt-5.6-luna",
                reasoning_effort: "ultra",
            })
        );
    }

    #[test]
    fn fast_tier_is_rejected_for_a_model_without_it() {
        let preference = ExecutionPreference {
            model: CodexModel::Gpt52,
            service_tier: ServiceTier::Fast,
            ..ExecutionPreference::default()
        };
        assert_eq!(
            preference.validate(),
            Err(PreferenceError::FastUnavailable { model: "gpt-5.2" })
        );
    }

    #[test]
    fn built_in_presets_match_the_product() {
        let standard = ExecutionPreference::default_preset(SubagentMode::Standard).expect("standard");
        assert!(standard.use_saved_model);
        assert!(!standard.subagents_enabled);
        assert_eq!(standard.subagent_model, CodexModel::Luna);
        assert_eq!(standard.subagent_reasoning_effort, ReasoningEffort::Max);

        let sol_luna = ExecutionPreference::default_preset(SubagentMode::SolLuna).expect("sol_luna");
        assert!(!sol_luna.use_saved_model);
        assert_eq!(sol_luna.model, CodexModel::Sol);
        assert_eq!(sol_luna.reasoning_effort, ReasoningEffort::High);
        assert!(sol_luna.subagents_enabled);

        let luna = ExecutionPreference::default_preset(SubagentMode::LunaDirect).expect("luna");
        assert_eq!(luna.model, CodexModel::Luna);
        assert_eq!(luna.reasoning_effort, ReasoningEffort::Max);
        assert!(!luna.subagents_enabled);
    }

    #[test]
    fn effective_strategy_follows_the_selected_mode() {
        let preference = ExecutionPreference::default();

        let standard = preference.effective_strategy();
        assert_eq!(standard.main_model, CodexModel::Astra);
        assert_eq!(standard.main_reasoning_effort, ReasoningEffort::Low);
        assert_eq!(standard.subagent_model, None);
        assert_eq!(standard.maximum_concurrent_subagents, 0);

        let sol_luna = preference
            .effective_strategy_for(SubagentMode::SolLuna)
            .expect("sol_luna");
        assert_eq!(sol_luna.main_model, CodexModel::Sol);
        assert_eq!(sol_luna.main_reasoning_effort, ReasoningEffort::High);
        assert_eq!(sol_luna.subagent_model, Some(CodexModel::Luna));
        assert_eq!(
            sol_luna.subagent_reasoning_effort,
            Some(ReasoningEffort::Max)
        );
        assert_eq!(sol_luna.maximum_concurrent_subagents, 1);
    }

    #[test]
    fn a_stored_custom_preset_overrides_the_built_in() {
        let mut preference = ExecutionPreference::default();
        preference
            .custom_presets
            .insert("sol_luna".to_string(), preset(Some("Ship it")));
        let resolved = preference.preset(SubagentMode::SolLuna).expect("preset");
        assert_eq!(resolved.name.as_deref(), Some("Ship it"));
        assert_eq!(preference.custom_name(SubagentMode::SolLuna).as_deref(), Some("Ship it"));

        let restored = preference.restoring_default(SubagentMode::SolLuna);
        assert!(restored.custom_presets.is_empty());
        assert_eq!(restored.custom_name(SubagentMode::SolLuna), None);
    }

    #[test]
    fn unknown_custom_preset_slots_are_rejected() {
        let mut preference = ExecutionPreference::default();
        preference.custom_presets.insert("mystery".to_string(), preset(None));
        assert_eq!(
            preference.validate(),
            Err(PreferenceError::UnsupportedCustomPreset)
        );
    }

    #[test]
    fn preset_names_follow_the_published_rule() {
        assert_eq!(validate_preset_name("Ship it"), Ok(()));
        assert_eq!(
            validate_preset_name(""),
            Err(PreferenceError::InvalidPresetName)
        );
        assert_eq!(
            validate_preset_name(" padded "),
            Err(PreferenceError::InvalidPresetName)
        );
        assert_eq!(
            validate_preset_name("bad\u{7}name"),
            Err(PreferenceError::InvalidPresetName)
        );
        let too_long = "a".repeat(MAX_PRESET_NAME_BYTES + 1);
        assert_eq!(
            validate_preset_name(&too_long),
            Err(PreferenceError::InvalidPresetName)
        );
        let at_limit = "a".repeat(MAX_PRESET_NAME_BYTES);
        assert_eq!(validate_preset_name(&at_limit), Ok(()));
    }

    #[test]
    fn subagent_mode_round_trips_and_rejects_unknown_values() {
        for mode in SubagentMode::ALL {
            assert_eq!(SubagentMode::from_raw_value(mode.raw_value()), Some(mode));
        }
        assert_eq!(SubagentMode::from_raw_value("legacy_mode"), None);
        assert_eq!(SubagentMode::SolLuna.raw_value(), "sol_luna");
    }

    #[test]
    fn service_tier_serialises_standard_as_default() {
        assert_eq!(ServiceTier::Standard.raw_value(), "default");
        assert_eq!(ServiceTier::Fast.raw_value(), "fast");
        assert_eq!(
            serde_json::to_string(&ServiceTier::Standard).expect("serialise"),
            "\"default\""
        );
    }

    #[test]
    fn mimo_and_zcode_report_quota_as_not_wired() {
        assert!(!LocalCliKind::MiMo.has_official_quota());
        assert!(!LocalCliKind::ZCode.has_official_quota());
        assert!(LocalCliKind::Codex.has_official_quota());
        assert!(LocalCliKind::Grok.has_official_quota());
        assert!(LocalCliKind::Codex.supports_isolated_launch());
        assert!(!LocalCliKind::GeminiCli.supports_isolated_launch());
    }

    #[test]
    fn cli_ids_are_unique_and_stable() {
        let mut ids: Vec<&str> = LocalCliKind::ALL.iter().map(|kind| kind.id()).collect();
        ids.sort_unstable();
        let count = ids.len();
        ids.dedup();
        assert_eq!(ids.len(), count);
        assert_eq!(LocalCliKind::KimiCode.id(), "kimi_code");
    }

    #[test]
    fn dispatch_eligibility_requires_login_and_participation() {
        let mut account = AccountRecord {
            identity: AccountIdentity {
                id: "acc-1".to_string(),
                label: "work".to_string(),
                masked_email: mask_email("alice@example.com"),
                plan_label: Some("plus".to_string()),
                is_signed_in: true,
            },
            home_dir_label: "profile-a".to_string(),
            preference: ExecutionPreference::default(),
            participates_in_dispatch: true,
            order: 0,
            pinned_first: false,
            is_system_profile: false,
        };
        assert!(account.is_dispatch_eligible());
        assert!(account.can_store_preference());

        account.participates_in_dispatch = false;
        assert!(!account.is_dispatch_eligible());

        account.participates_in_dispatch = true;
        account.identity.is_signed_in = false;
        assert!(!account.is_dispatch_eligible());

        account.is_system_profile = true;
        assert!(!account.can_store_preference());
    }

    fn account_record(id: &str, is_system: bool) -> AccountRecord {
        AccountRecord {
            identity: AccountIdentity {
                id: id.to_string(),
                label: id.to_string(),
                masked_email: Some("a***@example.com".to_string()),
                plan_label: None,
                is_signed_in: true,
            },
            home_dir_label: id.to_string(),
            preference: ExecutionPreference::default(),
            participates_in_dispatch: true,
            order: 0,
            pinned_first: false,
            is_system_profile: is_system,
        }
    }

    #[test]
    fn overrides_apply_only_to_isolated_profiles() {
        let mut overrides = PreferenceOverrides::default();
        let preferred = ExecutionPreference {
            model: CodexModel::Sol,
            reasoning_effort: ReasoningEffort::High,
            service_tier: ServiceTier::Fast,
            subagent_mode: SubagentMode::SolLuna,
            custom_presets: BTreeMap::new(),
        };
        overrides.set("profile-a", preferred.clone()).expect("valid");
        overrides.set("system", preferred.clone()).expect("valid");

        let mut accounts = vec![
            account_record("system", true),
            account_record("profile-a", false),
            account_record("profile-b", false),
        ];
        let applied = overrides.apply(&mut accounts);

        assert_eq!(applied, 1);
        // The system profile keeps the default: it is read-only by contract.
        assert_eq!(accounts[0].preference, ExecutionPreference::default());
        assert_eq!(accounts[1].preference, preferred);
        assert_eq!(accounts[2].preference, ExecutionPreference::default());
    }

    #[test]
    fn an_override_that_no_longer_validates_is_skipped_not_applied() {
        let mut overrides = PreferenceOverrides::default();
        // Built through the public API the value is valid...
        overrides
            .set("profile-a", ExecutionPreference::default())
            .expect("valid");
        // ...so corrupt it the way a hand-edited file could.
        let mut broken = ExecutionPreference::default();
        broken.model = CodexModel::Gpt52;
        broken.service_tier = ServiceTier::Fast;
        overrides.entries.insert("profile-a".to_string(), broken);

        let mut accounts = vec![account_record("profile-a", false)];
        assert_eq!(overrides.apply(&mut accounts), 0);
        assert_eq!(accounts[0].preference, ExecutionPreference::default());
    }

    #[test]
    fn setting_an_invalid_preference_is_rejected() {
        let mut overrides = PreferenceOverrides::default();
        let invalid = ExecutionPreference {
            model: CodexModel::Gpt52,
            service_tier: ServiceTier::Fast,
            ..ExecutionPreference::default()
        };
        assert_eq!(
            overrides.set("profile-a", invalid),
            Err(PreferenceError::FastUnavailable { model: "gpt-5.2" })
        );
        assert!(overrides.is_empty());
    }

    #[test]
    fn an_empty_account_id_is_rejected() {
        let mut overrides = PreferenceOverrides::default();
        assert_eq!(
            overrides.set("   ", ExecutionPreference::default()),
            Err(PreferenceError::EmptyAccountId)
        );
        assert!(overrides.is_empty());
    }

    #[test]
    fn sanitize_drops_only_the_invalid_entries() {
        let mut overrides = PreferenceOverrides::default();
        overrides
            .set("profile-a", ExecutionPreference::default())
            .expect("valid");
        overrides
            .set("profile-b", ExecutionPreference::default())
            .expect("valid");

        let mut broken = ExecutionPreference::default();
        broken.model = CodexModel::Luna;
        broken.reasoning_effort = ReasoningEffort::Ultra;
        overrides.entries.insert("profile-c".to_string(), broken);

        assert_eq!(overrides.len(), 3);
        assert_eq!(overrides.sanitize(), 1);
        assert_eq!(overrides.len(), 2);
        assert!(overrides.get("profile-c").is_none());
    }

    #[test]
    fn overrides_round_trip_through_json() {
        let mut overrides = PreferenceOverrides::default();
        overrides
            .set("profile-a", ExecutionPreference::default())
            .expect("valid");

        let encoded = serde_json::to_string(&overrides).expect("serialise");
        let mut decoded: PreferenceOverrides =
            serde_json::from_str(&encoded).expect("deserialise");
        assert_eq!(decoded, overrides);
        assert!(decoded.remove("profile-a"));
        assert!(decoded.is_empty());
    }
}
