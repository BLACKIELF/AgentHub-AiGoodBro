//! Message channel domain: the masked DTO and the delivery policy.
//!
//! Faithful port of `Sources/CodexUsageWidget/Domain/MessageChannel.swift`.
//!
//! The load-bearing idea is that **the payload is unrepresentable by
//! construction**: prompts, model responses, file paths, raw account
//! identifiers and free-form text cannot be expressed in [`MessageTaskStatus`],
//! because the labels that build it reject those shapes at construction time.
//! A channel therefore has nothing to leak even if it misbehaves.
//!
//! Rules that must not be relaxed:
//!
//! * Every channel starts disabled. Nothing enables itself, and `ready` needs a
//!   user-initiated verified send.
//! * Redirects are refused. Bot tokens and webhook keys travel in the URL, so a
//!   followed redirect is cross-origin disclosure.
//! * Outbound targets are allowlisted by host and path prefix.
//! * API acceptance is not delivery to a human.

use std::collections::{BTreeSet, VecDeque};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use url::Url;

/// Longest display name accepted for an account label.
pub const MAX_ACCOUNT_DISPLAY_NAME_CHARS: usize = 48;
/// Longest masked value accepted for an account label.
pub const MAX_ACCOUNT_MASKED_CHARS: usize = 64;
/// Longest task label accepted.
pub const MAX_TASK_LABEL_CHARS: usize = 48;
/// Bounded deduplicator history.
pub const DEDUPLICATOR_CAPACITY: usize = 128;
/// Bounded channel response body.
pub const MAX_RESPONSE_BYTES: usize = 64 * 1024;

/// Outbound relay targets for sanitized task-status messages.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MessageChannelKind {
    Feishu,
    Telegram,
    WeCom,
}

impl MessageChannelKind {
    pub const ALL: [MessageChannelKind; 3] = [
        MessageChannelKind::Feishu,
        MessageChannelKind::Telegram,
        MessageChannelKind::WeCom,
    ];

    pub fn id(self) -> &'static str {
        match self {
            MessageChannelKind::Feishu => "feishu",
            MessageChannelKind::Telegram => "telegram",
            MessageChannelKind::WeCom => "wechat",
        }
    }
}

/// Why a channel cannot be offered at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MessageChannelUnavailableReason {
    /// Personal WeChat exposes no official per-user message API.
    NoOfficialPersonalApi,
    /// Official Accounts need an approved server-side deployment.
    OfficialAccountRequiresServerApproval,
}

/// Lifecycle surfaced in the UI.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "phase", content = "reason")]
pub enum MessageChannelPhase {
    Disabled,
    NeedsSetup,
    PendingVerification,
    Ready,
    Unavailable(MessageChannelUnavailableReason),
}

impl Default for MessageChannelPhase {
    fn default() -> Self {
        MessageChannelPhase::Disabled
    }
}

impl MessageChannelPhase {
    /// Only a verified channel may actually send.
    pub fn may_send(&self) -> bool {
        matches!(self, MessageChannelPhase::Ready)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum MessageChannelError {
    #[error("the message channel is disabled; enable it in settings first")]
    ChannelDisabled,
    #[error("no credential has been saved for this channel")]
    MissingCredential,
    #[error("the saved credential is malformed")]
    InvalidCredential,
    #[error("no message target has been saved")]
    MissingTarget,
    #[error("the message target is malformed")]
    InvalidTarget,
    #[error("the task status is stale and was not sent")]
    StaleStatus,
    #[error("the task status contains unsanitized or out-of-range fields")]
    InvalidStatus,
    #[error("the message exceeds the length limit ({0})")]
    MessageTooLong(usize),
    #[error("the message send was cancelled")]
    Cancelled,
    #[error("could not create the outbound message")]
    EncodingFailed,
    #[error("the message channel request failed")]
    TransportFailed,
    #[error("the channel returned an unrecognized response")]
    InvalidResponse,
    #[error("the channel refuses redirects")]
    Redirected,
    #[error("the channel request failed (HTTP {0})")]
    HttpStatus(u16),
    #[error("rate limited; retry later")]
    RateLimited(Option<u64>),
    #[error("the channel rejected the message ({0})")]
    Rejected(i64),
}

/// Approximation of the Unicode `So` general category.
///
/// Rust's standard library does not expose general categories, so a display
/// name is restricted to the symbol and pictograph ranges that realistically
/// appear in one. Anything else is rejected, which is the safe direction.
fn is_other_symbol_approx(character: char) -> bool {
    matches!(character as u32,
        0x2190..=0x2BFF | 0x1F1E6..=0x1F1FF | 0x1F300..=0x1FAFF)
}

fn is_account_display_char(character: char) -> bool {
    character.is_alphanumeric()
        || " .-•·()（）".contains(character)
        || character == '\u{200D}'
        || character == '\u{FE0F}'
        || is_other_symbol_approx(character)
}

fn is_masked_char(character: char) -> bool {
    character.is_alphanumeric() || " ._-*•()（）".contains(character)
}

fn is_task_char(character: char) -> bool {
    character.is_alphanumeric() || " .-_·()（）".contains(character)
}

/// An account label: a UI display name or an already-masked value, never a raw
/// email, path or URL.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MessageChannelAccountLabel {
    value: String,
}

impl MessageChannelAccountLabel {
    /// Accepts a UI display name.
    pub fn from_display_name(raw: &str) -> Result<Self, MessageChannelError> {
        let name = raw.trim();
        if name.is_empty()
            || name.chars().count() > MAX_ACCOUNT_DISPLAY_NAME_CHARS
            || !name.chars().all(is_account_display_char)
        {
            return Err(MessageChannelError::InvalidStatus);
        }
        Ok(Self {
            value: name.to_string(),
        })
    }

    /// Accepts only a value that is already masked.
    ///
    /// The mask is mandatory: an unmasked identifier has no reason to travel to
    /// a messaging platform.
    pub fn from_masked_value(raw: &str) -> Result<Self, MessageChannelError> {
        let name = raw.trim();
        if name.is_empty()
            || name.chars().count() > MAX_ACCOUNT_MASKED_CHARS
            || !name.chars().all(is_masked_char)
            || !(name.contains("***") || name.contains("•••"))
        {
            return Err(MessageChannelError::InvalidStatus);
        }
        Ok(Self {
            value: name.to_string(),
        })
    }

    /// Accepts a display name or an already-masked label; nothing else.
    ///
    /// Note that a masked *email* such as `a***@example.com` is rejected: the
    /// shared label rules have no `@`, so the domain never travels to a
    /// messaging platform. Use [`account_label_from_masked_email`] to reduce one
    /// to a form a channel can carry.
    pub fn parse(raw: &str) -> Result<Self, MessageChannelError> {
        Self::from_display_name(raw).or_else(|_| Self::from_masked_value(raw))
    }

    pub fn value(&self) -> &str {
        &self.value
    }
}

/// Reduce a masked email to a form a message channel can carry.
///
/// The workbench's own masking produces `a***@example.com`, but the shared
/// message-channel label rules have no `@`, because a domain is still an
/// identifying fact. This bridges the two: `a***@example.com` becomes `a***`.
///
/// Returns `None` when the value is not a masked email, so a caller cannot
/// accidentally pass a raw address through.
pub fn account_label_from_masked_email(masked_email: &str) -> Option<MessageChannelAccountLabel> {
    let trimmed = masked_email.trim();
    let (local, domain) = trimmed.split_once('@')?;
    if domain.trim().is_empty() || !local.trim().contains("***") {
        return None;
    }
    MessageChannelAccountLabel::from_masked_value(local.trim()).ok()
}

/// A task label. `@`, `/` and `:` are rejected so emails, paths and URLs cannot
/// enter a message.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MessageChannelTaskLabel {
    value: String,
}

impl MessageChannelTaskLabel {
    pub fn parse(raw: &str) -> Result<Self, MessageChannelError> {
        let name = raw.trim();
        if name.is_empty()
            || name.chars().count() > MAX_TASK_LABEL_CHARS
            || !name.chars().all(is_task_char)
        {
            return Err(MessageChannelError::InvalidStatus);
        }
        Ok(Self {
            value: name.to_string(),
        })
    }

    pub fn value(&self) -> &str {
        &self.value
    }
}

/// The only payload a message channel may transmit.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct MessageTaskStatus {
    pub event_kind: MessageEventKind,
    pub account_label: Option<MessageChannelAccountLabel>,
    pub task_label: Option<MessageChannelTaskLabel>,
    pub task_state: Option<MessageTaskState>,
    pub five_hour_remaining_percent: Option<f64>,
    pub seven_day_remaining_percent: Option<f64>,
    pub failure_reason: Option<MessageFailureReason>,
    #[serde(with = "chrono::serde::ts_milliseconds")]
    pub occurred_at: DateTime<Utc>,
    pub event_id: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MessageEventKind {
    Test,
    LowQuotaDetected,
    QuotaReset,
    ResetCreditsAdded,
    SwitchSucceeded,
    SwitchFailed,
    TaskStateChange,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MessageFailureReason {
    NoEligibleAccount,
    AppBusy,
    ValidationFailed,
    RestartFailed,
    NetworkUnavailable,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MessageTaskState {
    Idle,
    Running,
    WaitingInput,
    Completed,
    Failed,
    Interrupted,
    Disconnected,
}

/// Language for the canonical summary.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum MessageLanguage {
    ZhHans,
    #[default]
    En,
}

impl MessageTaskStatus {
    /// Build a payload, rejecting out-of-range percentages and a payload that
    /// identifies nothing.
    #[allow(clippy::too_many_arguments)]
    pub fn build(
        event_kind: MessageEventKind,
        account_label: Option<MessageChannelAccountLabel>,
        task_label: Option<MessageChannelTaskLabel>,
        task_state: Option<MessageTaskState>,
        five_hour_remaining_percent: Option<f64>,
        seven_day_remaining_percent: Option<f64>,
        failure_reason: Option<MessageFailureReason>,
        occurred_at: DateTime<Utc>,
        event_id: &str,
    ) -> Result<Self, MessageChannelError> {
        for percent in [five_hour_remaining_percent, seven_day_remaining_percent]
            .into_iter()
            .flatten()
        {
            if !percent.is_finite() || !(0.0..=100.0).contains(&percent) {
                return Err(MessageChannelError::InvalidStatus);
            }
        }
        if event_id.trim().is_empty() {
            return Err(MessageChannelError::InvalidStatus);
        }
        // A payload must say which account or task it is about, unless it is a
        // connection test.
        if account_label.is_none() && task_label.is_none() && event_kind != MessageEventKind::Test {
            return Err(MessageChannelError::InvalidStatus);
        }
        Ok(Self {
            event_kind,
            account_label,
            task_label,
            task_state,
            five_hour_remaining_percent,
            seven_day_remaining_percent,
            failure_reason,
            occurred_at,
            event_id: event_id.to_string(),
        })
    }

    /// One canonical rendering shared by every channel.
    ///
    /// Rendering lives here so two channels cannot drift apart in what they
    /// disclose.
    pub fn summary(&self, language: MessageLanguage) -> String {
        let mut lines: Vec<String> = Vec::new();
        lines.push(match (self.event_kind, language) {
            (MessageEventKind::Test, MessageLanguage::ZhHans) => "连接测试".to_string(),
            (MessageEventKind::Test, MessageLanguage::En) => "Connection test".to_string(),
            (MessageEventKind::LowQuotaDetected, MessageLanguage::ZhHans) => "额度低于阈值".to_string(),
            (MessageEventKind::LowQuotaDetected, MessageLanguage::En) => "Quota is low".to_string(),
            (MessageEventKind::QuotaReset, MessageLanguage::ZhHans) => "额度已重置".to_string(),
            (MessageEventKind::QuotaReset, MessageLanguage::En) => "Quota reset".to_string(),
            (MessageEventKind::ResetCreditsAdded, MessageLanguage::ZhHans) => "Reset 次数增加".to_string(),
            (MessageEventKind::ResetCreditsAdded, MessageLanguage::En) => "Reset credits added".to_string(),
            (MessageEventKind::SwitchSucceeded, MessageLanguage::ZhHans) => "账号已切换".to_string(),
            (MessageEventKind::SwitchSucceeded, MessageLanguage::En) => "Account switched".to_string(),
            (MessageEventKind::SwitchFailed, MessageLanguage::ZhHans) => "切换未完成".to_string(),
            (MessageEventKind::SwitchFailed, MessageLanguage::En) => "Switch did not complete".to_string(),
            (MessageEventKind::TaskStateChange, MessageLanguage::ZhHans) => "任务状态更新".to_string(),
            (MessageEventKind::TaskStateChange, MessageLanguage::En) => "Task status update".to_string(),
        });

        if let Some(label) = &self.account_label {
            lines.push(match language {
                MessageLanguage::ZhHans => format!("账号：{}", label.value()),
                MessageLanguage::En => format!("Account: {}", label.value()),
            });
        }
        if let Some(label) = &self.task_label {
            lines.push(match language {
                MessageLanguage::ZhHans => format!("任务：{}", label.value()),
                MessageLanguage::En => format!("Task: {}", label.value()),
            });
        }
        if let Some(state) = self.task_state {
            lines.push(match language {
                MessageLanguage::ZhHans => format!("状态：{}", state_id(state)),
                MessageLanguage::En => format!("State: {}", state_id(state)),
            });
        }
        if let Some(percent) = self.five_hour_remaining_percent {
            lines.push(match language {
                MessageLanguage::ZhHans => format!("5 小时剩余 {}%", percent_text(percent)),
                MessageLanguage::En => format!("5h remaining {}%", percent_text(percent)),
            });
        }
        if let Some(percent) = self.seven_day_remaining_percent {
            lines.push(match language {
                MessageLanguage::ZhHans => format!("7 天剩余 {}%", percent_text(percent)),
                MessageLanguage::En => format!("7d remaining {}%", percent_text(percent)),
            });
        }
        if let Some(reason) = self.failure_reason {
            lines.push(match language {
                MessageLanguage::ZhHans => format!("原因：{}", reason_id(reason)),
                MessageLanguage::En => format!("Reason: {}", reason_id(reason)),
            });
        }
        lines.join("\n")
    }
}

fn state_id(state: MessageTaskState) -> &'static str {
    match state {
        MessageTaskState::Idle => "idle",
        MessageTaskState::Running => "running",
        MessageTaskState::WaitingInput => "waitingInput",
        MessageTaskState::Completed => "completed",
        MessageTaskState::Failed => "failed",
        MessageTaskState::Interrupted => "interrupted",
        MessageTaskState::Disconnected => "disconnected",
    }
}

fn reason_id(reason: MessageFailureReason) -> &'static str {
    match reason {
        MessageFailureReason::NoEligibleAccount => "noEligibleAccount",
        MessageFailureReason::AppBusy => "appBusy",
        MessageFailureReason::ValidationFailed => "validationFailed",
        MessageFailureReason::RestartFailed => "restartFailed",
        MessageFailureReason::NetworkUnavailable => "networkUnavailable",
        MessageFailureReason::Unknown => "unknown",
    }
}

/// Locale-independent percent text, matching the macOS `en_US_POSIX` precision.
fn percent_text(percent: f64) -> String {
    let rounded = (percent * 100.0).round() / 100.0;
    format!("{rounded}")
}

/// Reserve before sending to suppress concurrent duplicates.
#[derive(Debug)]
pub struct MessageEventDeduplicator {
    capacity: usize,
    order: VecDeque<String>,
    seen: BTreeSet<String>,
    in_flight: BTreeSet<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessageReservation {
    Reserved,
    Duplicate,
    AtCapacity,
}

impl MessageEventDeduplicator {
    pub fn new(capacity: usize) -> Option<Self> {
        if capacity == 0 {
            return None;
        }
        Some(Self {
            capacity,
            order: VecDeque::new(),
            seen: BTreeSet::new(),
            in_flight: BTreeSet::new(),
        })
    }

    pub fn begin(&mut self, event_id: &str) -> MessageReservation {
        if self.seen.contains(event_id) || self.in_flight.contains(event_id) {
            return MessageReservation::Duplicate;
        }
        if self.in_flight.len() >= self.capacity {
            return MessageReservation::AtCapacity;
        }
        self.in_flight.insert(event_id.to_string());
        MessageReservation::Reserved
    }

    /// Release a reservation after a failed send so it can be retried.
    pub fn release(&mut self, event_id: &str) {
        self.in_flight.remove(event_id);
    }

    pub fn has_seen(&self, event_id: &str) -> bool {
        self.seen.contains(event_id)
    }

    /// Claim a completed send. Returns false when the event was already claimed.
    pub fn claim(&mut self, event_id: &str) -> bool {
        self.in_flight.remove(event_id);
        if self.seen.contains(event_id) {
            return false;
        }
        self.seen.insert(event_id.to_string());
        self.order.push_back(event_id.to_string());
        while self.order.len() > self.capacity {
            if let Some(oldest) = self.order.pop_front() {
                self.seen.remove(&oldest);
            }
        }
        true
    }
}

impl Default for MessageEventDeduplicator {
    fn default() -> Self {
        Self::new(DEDUPLICATOR_CAPACITY).expect("a non-zero capacity")
    }
}

/// Allowlist for outbound webhook targets.
#[derive(Debug, Clone)]
pub struct WebhookTargetPolicy {
    pub allow_hosts: BTreeSet<String>,
    pub allow_path_prefixes: Vec<String>,
    pub require_https: bool,
    /// A query string is refused by default: secrets must not ride in one.
    pub allow_query: bool,
}

impl Default for WebhookTargetPolicy {
    fn default() -> Self {
        Self {
            allow_hosts: [
                "open.feishu.cn",
                "open.larksuite.com",
                "api.telegram.org",
                "qyapi.weixin.qq.com",
            ]
            .into_iter()
            .map(str::to_string)
            .collect(),
            allow_path_prefixes: vec![
                "/open-apis/bot/v2/hook/".to_string(),
                "/bot".to_string(),
                "/cgi-bin/webhook/send".to_string(),
            ],
            require_https: true,
            allow_query: false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum WebhookTargetError {
    #[error("the webhook target is not a parseable URL")]
    MalformedUrl,
    #[error("the webhook target must use https")]
    NotHttps,
    #[error("the webhook target must not carry credentials")]
    CredentialsInUrl,
    #[error("the webhook target has no host")]
    MissingHost,
    #[error("the webhook host is not allowlisted")]
    HostNotAllowlisted,
    #[error("the webhook path is not allowlisted")]
    PathNotAllowlisted,
    #[error("the webhook target must not carry a query string")]
    QueryNotAllowed,
    #[error("the webhook target must not carry a fragment")]
    FragmentNotAllowed,
}

/// Validate an outbound target and return the parsed URL.
///
/// The parsed URL is handed back so the caller cannot re-parse a string it
/// already validated and end up sending somewhere else.
pub fn validate_webhook_target(
    raw: &str,
    policy: &WebhookTargetPolicy,
) -> Result<Url, WebhookTargetError> {
    let parsed = Url::parse(raw).map_err(|_| WebhookTargetError::MalformedUrl)?;
    if policy.require_https && parsed.scheme() != "https" {
        return Err(WebhookTargetError::NotHttps);
    }
    if !parsed.username().is_empty() || parsed.password().is_some() {
        return Err(WebhookTargetError::CredentialsInUrl);
    }
    let host = parsed
        .host_str()
        .ok_or(WebhookTargetError::MissingHost)?
        .to_ascii_lowercase();
    if !policy.allow_hosts.contains(&host) {
        return Err(WebhookTargetError::HostNotAllowlisted);
    }
    if !policy
        .allow_path_prefixes
        .iter()
        .any(|prefix| parsed.path().starts_with(prefix))
    {
        return Err(WebhookTargetError::PathNotAllowlisted);
    }
    if !policy.allow_query && parsed.query().is_some() {
        return Err(WebhookTargetError::QueryNotAllowed);
    }
    if parsed.fragment().is_some() {
        return Err(WebhookTargetError::FragmentNotAllowed);
    }
    Ok(parsed)
}

/// Receipt of an accepted send.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MessageDeliveryReceipt {
    #[serde(with = "chrono::serde::ts_milliseconds")]
    pub accepted_at: DateTime<Utc>,
    /// Platform-side identifier; not a secret.
    pub remote_message_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "outcome")]
pub enum MessageDeliveryOutcome {
    Accepted(MessageDeliveryReceipt),
    /// A duplicate event was recognized and no request was issued.
    DuplicateSkipped,
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn at(seconds: i64) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 9, 11, 12, 0, 0)
            .single()
            .expect("valid timestamp")
            + chrono::Duration::seconds(seconds)
    }

    fn account() -> MessageChannelAccountLabel {
        MessageChannelAccountLabel::from_masked_value("a***").expect("masked")
    }

    fn task() -> MessageChannelTaskLabel {
        MessageChannelTaskLabel::parse("Refactor the reader").expect("task label")
    }

    #[test]
    fn a_channel_starts_disabled_and_only_ready_may_send() {
        assert_eq!(MessageChannelPhase::default(), MessageChannelPhase::Disabled);
        assert!(!MessageChannelPhase::Disabled.may_send());
        assert!(!MessageChannelPhase::NeedsSetup.may_send());
        assert!(!MessageChannelPhase::PendingVerification.may_send());
        assert!(MessageChannelPhase::Ready.may_send());
        assert!(!MessageChannelPhase::Unavailable(
            MessageChannelUnavailableReason::NoOfficialPersonalApi
        )
        .may_send());
    }

    #[test]
    fn a_display_name_accepts_ordinary_names_and_symbols() {
        assert!(MessageChannelAccountLabel::from_display_name("Work Account").is_ok());
        assert!(MessageChannelAccountLabel::from_display_name("工作号").is_ok());
        assert!(MessageChannelAccountLabel::from_display_name("A-B (team)").is_ok());
        // A bullet and a pictograph are legitimate in a display name.
        assert!(MessageChannelAccountLabel::from_display_name("Team • Ship").is_ok());
        assert!(MessageChannelAccountLabel::from_display_name("Ship \u{1F680}").is_ok());
    }

    #[test]
    fn a_display_name_rejects_everything_that_could_leak() {
        for raw in [
            "",
            "   ",
            "a***@example.com", // not a display name: masked values need the other ctor
            "alice@example.com",
            "/Users/someone/project",
            "https://example.com/hook",
            "line\nbreak",
            "x".repeat(49).as_str(),
        ] {
            assert!(
                MessageChannelAccountLabel::from_display_name(raw).is_err(),
                "{raw:?} must be rejected as a display name"
            );
        }
    }

    #[test]
    fn a_masked_value_must_actually_be_masked() {
        assert!(MessageChannelAccountLabel::from_masked_value("a***").is_ok());
        assert!(MessageChannelAccountLabel::from_masked_value("a•••").is_ok());
        // A masked *email* is not a label: the shared rules have no '@', so the
        // domain never travels outbound.
        assert!(MessageChannelAccountLabel::from_masked_value("a***@example.com").is_err());
        // An unmasked identifier is exactly what must not travel.
        assert!(MessageChannelAccountLabel::from_masked_value("alice@example.com").is_err());
        assert!(MessageChannelAccountLabel::from_masked_value("Work Account").is_err());
        assert!(MessageChannelAccountLabel::from_masked_value("").is_err());
        assert!(MessageChannelAccountLabel::from_masked_value("x***".repeat(20).as_str()).is_err());
    }

    #[test]
    fn parse_accepts_either_form_and_nothing_else() {
        assert_eq!(
            MessageChannelAccountLabel::parse("Work Account").expect("display").value(),
            "Work Account"
        );
        assert_eq!(
            MessageChannelAccountLabel::parse("a***").expect("masked").value(),
            "a***"
        );
        // A masked email satisfies neither constructor.
        assert!(MessageChannelAccountLabel::parse("a***@example.com").is_err());
        assert!(MessageChannelAccountLabel::parse("alice@example.com").is_err());
        assert!(MessageChannelAccountLabel::parse("https://example.com").is_err());
    }

    #[test]
    fn a_masked_email_is_reduced_before_it_reaches_a_channel() {
        // The seam between the workbench's masking and the outbound label rules.
        let label = account_label_from_masked_email("a***@example.com").expect("reduced");
        assert_eq!(label.value(), "a***");
        // And the reduced form is one the channel accepts.
        assert!(MessageChannelAccountLabel::parse(label.value()).is_ok());

        for raw in ["alice@example.com", "a***@", "@example.com", "no-at-sign", ""] {
            assert!(
                account_label_from_masked_email(raw).is_none(),
                "{raw:?} must not be reduced to a label"
            );
        }
    }

    #[test]
    fn a_task_label_rejects_emails_paths_and_urls() {
        assert!(MessageChannelTaskLabel::parse("Refactor the reader").is_ok());
        assert!(MessageChannelTaskLabel::parse("任务 A_1").is_ok());
        for raw in [
            "",
            "a@b.com",
            "src/app/reader.rs",
            "https://example.com/task",
            "task: review",
            "C:\\work\\task",
        ] {
            assert!(
                MessageChannelTaskLabel::parse(raw).is_err(),
                "{raw:?} must be rejected as a task label"
            );
        }
        assert!(MessageChannelTaskLabel::parse("x".repeat(49).as_str()).is_err());
    }

    #[test]
    fn a_payload_must_identify_something_unless_it_is_a_test() {
        let bare = MessageTaskStatus::build(
            MessageEventKind::TaskStateChange,
            None,
            None,
            None,
            None,
            None,
            None,
            at(0),
            "event-1",
        );
        assert_eq!(bare, Err(MessageChannelError::InvalidStatus));

        let test = MessageTaskStatus::build(
            MessageEventKind::Test,
            None,
            None,
            None,
            None,
            None,
            None,
            at(0),
            "event-test",
        );
        assert!(test.is_ok());

        let named = MessageTaskStatus::build(
            MessageEventKind::LowQuotaDetected,
            Some(account()),
            None,
            None,
            Some(4.0),
            None,
            None,
            at(0),
            "event-2",
        );
        assert!(named.is_ok());
    }

    #[test]
    fn out_of_range_percentages_are_rejected() {
        for percent in [-1.0, 101.0, f64::NAN, f64::INFINITY] {
            let built = MessageTaskStatus::build(
                MessageEventKind::LowQuotaDetected,
                Some(account()),
                None,
                None,
                Some(percent),
                None,
                None,
                at(0),
                "event-x",
            );
            assert_eq!(built, Err(MessageChannelError::InvalidStatus), "{percent}");
        }
        // The boundaries are inclusive.
        assert!(MessageTaskStatus::build(
            MessageEventKind::LowQuotaDetected,
            Some(account()),
            None,
            None,
            Some(0.0),
            Some(100.0),
            None,
            at(0),
            "event-y",
        )
        .is_ok());
    }

    #[test]
    fn an_empty_event_id_is_rejected() {
        assert_eq!(
            MessageTaskStatus::build(
                MessageEventKind::Test,
                None,
                None,
                None,
                None,
                None,
                None,
                at(0),
                "   "
            ),
            Err(MessageChannelError::InvalidStatus)
        );
    }

    #[test]
    fn the_canonical_summary_discloses_the_same_fields_in_both_languages() {
        let status = MessageTaskStatus::build(
            MessageEventKind::LowQuotaDetected,
            Some(account()),
            Some(task()),
            Some(MessageTaskState::Running),
            Some(4.0),
            Some(12.5),
            Some(MessageFailureReason::AppBusy),
            at(0),
            "event-1",
        )
        .expect("payload");

        let english = status.summary(MessageLanguage::En);
        assert!(english.starts_with("Quota is low"));
        for part in [
            "Account: a***",
            "Task: Refactor the reader",
            "State: running",
            "5h remaining 4%",
            "7d remaining 12.5%",
            "Reason: appBusy",
        ] {
            assert!(english.contains(part), "{part} missing from the English summary");
        }

        let chinese = status.summary(MessageLanguage::ZhHans);
        assert!(chinese.starts_with("额度低于阈值"));
        assert!(chinese.contains("账号：a***"));
        assert!(chinese.contains("5 小时剩余 4%"));
        assert_eq!(english.lines().count(), chinese.lines().count());
    }

    #[test]
    fn a_test_payload_summary_does_not_need_an_account() {
        let status = MessageTaskStatus::build(
            MessageEventKind::Test,
            None,
            None,
            None,
            None,
            None,
            None,
            at(0),
            "event-test",
        )
        .expect("payload");
        assert_eq!(status.summary(MessageLanguage::En), "Connection test");
    }

    #[test]
    fn the_deduplicator_reserves_releases_and_claims() {
        let mut dedupe = MessageEventDeduplicator::default();

        assert_eq!(dedupe.begin("event-1"), MessageReservation::Reserved);
        // A second begin while in flight is a duplicate, not a second send.
        assert_eq!(dedupe.begin("event-1"), MessageReservation::Duplicate);
        assert!(!dedupe.has_seen("event-1"));

        // A failed send releases so it can be retried.
        dedupe.release("event-1");
        assert_eq!(dedupe.begin("event-1"), MessageReservation::Reserved);
        assert!(dedupe.claim("event-1"));
        assert!(dedupe.has_seen("event-1"));
        assert!(!dedupe.claim("event-1"));
        assert_eq!(dedupe.begin("event-1"), MessageReservation::Duplicate);
    }

    #[test]
    fn the_deduplicator_bounds_its_history() {
        let mut dedupe = MessageEventDeduplicator::new(2).expect("capacity");
        dedupe.begin("a");
        dedupe.claim("a");
        dedupe.begin("b");
        dedupe.claim("b");
        dedupe.begin("c");
        dedupe.claim("c");
        // "a" was evicted, so it is no longer remembered as seen.
        assert!(!dedupe.has_seen("a"));
        assert!(dedupe.has_seen("c"));
    }

    #[test]
    fn the_deduplicator_refuses_work_beyond_its_capacity() {
        let mut dedupe = MessageEventDeduplicator::new(1).expect("capacity");
        assert_eq!(dedupe.begin("a"), MessageReservation::Reserved);
        assert_eq!(dedupe.begin("b"), MessageReservation::AtCapacity);
    }

    #[test]
    fn a_zero_capacity_deduplicator_cannot_be_built() {
        assert!(MessageEventDeduplicator::new(0).is_none());
    }

    #[test]
    fn allowlisted_targets_are_accepted() {
        let policy = WebhookTargetPolicy::default();
        assert!(validate_webhook_target(
            "https://open.feishu.cn/open-apis/bot/v2/hook/example-token",
            &policy
        )
        .is_ok());
        assert!(validate_webhook_target(
            "https://api.telegram.org/bot123456:ABC/sendMessage",
            &policy
        )
        .is_ok());
        assert!(validate_webhook_target(
            "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=unused",
            &WebhookTargetPolicy {
                allow_query: true,
                ..WebhookTargetPolicy::default()
            }
        )
        .is_ok());
    }

    #[test]
    fn a_target_outside_the_allowlist_is_refused() {
        let policy = WebhookTargetPolicy::default();
        for (raw, expected) in [
            ("http://open.feishu.cn/open-apis/bot/v2/hook/x", WebhookTargetError::NotHttps),
            (
                "https://attacker.example/open-apis/bot/v2/hook/x",
                WebhookTargetError::HostNotAllowlisted,
            ),
            (
                "https://open.feishu.cn/other/path",
                WebhookTargetError::PathNotAllowlisted,
            ),
            (
                "https://user:pass@open.feishu.cn/open-apis/bot/v2/hook/x",
                WebhookTargetError::CredentialsInUrl,
            ),
            ("not a url", WebhookTargetError::MalformedUrl),
        ] {
            let actual = validate_webhook_target(raw, &policy).err();
            assert_eq!(
                actual,
                Some(expected.clone()),
                "{raw} must be refused as {expected:?}, got {actual:?}"
            );
        }
    }

    #[test]
    fn a_query_string_is_refused_by_default_so_secrets_cannot_ride_in_one() {
        let policy = WebhookTargetPolicy::default();
        assert_eq!(
            validate_webhook_target(
                "https://api.telegram.org/bot123:ABC/sendMessage?token=secret",
                &policy
            )
            .err(),
            Some(WebhookTargetError::QueryNotAllowed)
        );
    }

    #[test]
    fn a_fragment_is_always_refused() {
        let policy = WebhookTargetPolicy {
            allow_query: true,
            ..WebhookTargetPolicy::default()
        };
        assert_eq!(
            validate_webhook_target(
                "https://api.telegram.org/bot123:ABC/sendMessage#frag",
                &policy
            )
            .err(),
            Some(WebhookTargetError::FragmentNotAllowed)
        );
    }

    #[test]
    fn a_host_that_only_looks_allowlisted_is_refused() {
        let policy = WebhookTargetPolicy::default();
        // The authority is the attacker host; the allowlisted name is a path
        // segment or userinfo, which a real parser separates correctly.
        assert_eq!(
            validate_webhook_target(
                "https://open.feishu.cn.attacker.example/open-apis/bot/v2/hook/x",
                &policy
            )
            .err(),
            Some(WebhookTargetError::HostNotAllowlisted)
        );
    }

    #[test]
    fn channel_kinds_keep_their_wire_ids() {
        assert_eq!(MessageChannelKind::Feishu.id(), "feishu");
        assert_eq!(MessageChannelKind::Telegram.id(), "telegram");
        assert_eq!(MessageChannelKind::WeCom.id(), "wechat");
        assert_eq!(MessageChannelKind::ALL.len(), 3);
    }

    #[test]
    fn a_receipt_round_trips_through_json() {
        let outcome = MessageDeliveryOutcome::Accepted(MessageDeliveryReceipt {
            accepted_at: at(0),
            remote_message_id: Some("12345".to_string()),
        });
        let encoded = serde_json::to_string(&outcome).expect("serialise");
        let decoded: MessageDeliveryOutcome = serde_json::from_str(&encoded).expect("deserialise");
        assert_eq!(decoded, outcome);
        assert!(encoded.contains("remote_message_id"));
    }
}
