//! Local CLI quota results and presentation rules.
//!
//! Faithful port of the parts of `Domain/LocalCLIAccount.swift` that define what
//! a workbench may display: the quota state, the bounded presentation
//! helpers, and the retention rule for a failed refresh.
//!
//! The rules come from `docs/local-cli-accounts.md`:
//!
//! * A failed refresh keeps the account's own last valid snapshot and marks it.
//!   "No data" means 暂未读到 or 暂未接通; it is never推算成 0.
//! * Shared quota is only suggested when the same identity is *confirmed*; with
//!   no reliable identity the answer is unknown, not a guess.
//! * Adapters use bounded network and file readers with a total timeout and a
//!   response size cap, and cookies, redirects and automatic retries are off.
//! * The workbench stores only a linked name and a config directory; it never
//!   copies another CLI's login credentials.
//! * An unknown login, model or quota state stays unknown. A command exit code
//!   is never treated as proof of success.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::account::LocalCliKind;

/// Outcome of one quota read.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LocalCliQuotaState {
    Available,
    Unavailable,
    NeedsLogin,
    Unsupported,
    RateLimited,
}

impl LocalCliQuotaState {
    pub fn id(self) -> &'static str {
        match self {
            LocalCliQuotaState::Available => "available",
            LocalCliQuotaState::Unavailable => "unavailable",
            LocalCliQuotaState::NeedsLogin => "needs_login",
            LocalCliQuotaState::Unsupported => "unsupported",
            LocalCliQuotaState::RateLimited => "rate_limited",
        }
    }

    /// Whether this read produced data the workbench may show.
    pub fn has_data(self) -> bool {
        matches!(self, LocalCliQuotaState::Available)
    }
}

/// One quota window reported by a CLI.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LocalCliQuotaWindow {
    pub id: String,
    pub label: String,
    pub used_percent: f64,
    #[serde(with = "chrono::serde::ts_milliseconds_option")]
    pub resets_at: Option<DateTime<Utc>>,
}

/// A reset card.
///
/// `expires_at` is only ever a real reset-card expiry. Billing-period or
/// quota-cycle dates are different facts and must never be mapped onto it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalCliResetCard {
    pub id: String,
    #[serde(with = "chrono::serde::ts_milliseconds_option")]
    pub expires_at: Option<DateTime<Utc>>,
}

/// The bounded read policy every CLI adapter shares.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CliReadPolicy {
    pub total_timeout_secs: u64,
    pub max_response_bytes: usize,
    pub cookies_enabled: bool,
    pub redirects_enabled: bool,
    pub auto_retry_enabled: bool,
}

impl Default for CliReadPolicy {
    /// Windows-side defaults. Cookies, redirects and automatic retries are off
    /// because a followed redirect or a silent retry can carry credentials to a
    /// host the user did not choose.
    fn default() -> Self {
        Self {
            total_timeout_secs: 20,
            max_response_bytes: 256 * 1024,
            cookies_enabled: false,
            redirects_enabled: false,
            auto_retry_enabled: false,
        }
    }
}

/// The result of one read for one CLI profile.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalCliQuotaResult {
    pub state: LocalCliQuotaState,
    #[serde(with = "chrono::serde::ts_milliseconds")]
    pub fetched_at: DateTime<Utc>,
    pub masked_identity: Option<String>,
    /// Anonymous fingerprint used only to compare two reads of the same login.
    pub identity_fingerprint: Option<String>,
    pub plan_label: Option<String>,
    pub windows: Vec<LocalCliQuotaWindow>,
    /// The official figure as returned. The workbench must not relabel it as a
    /// currency the source did not state, and must not add it to reset cards.
    pub balance: Option<f64>,
    pub balance_currency: Option<String>,
    pub source_label: String,
    pub message_code: Option<String>,
    /// `None` means the official response carried no reset-card fields. A
    /// non-empty list comes only from officially documented exact evidence;
    /// quota reset dates never fill it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reset_cards: Option<Vec<LocalCliResetCard>>,
    /// Read time for `reset_cards`, kept apart from `fetched_at` so an omitted
    /// card field cannot make an older known set look freshly observed.
    #[serde(
        default,
        with = "chrono::serde::ts_milliseconds_option",
        skip_serializing_if = "Option::is_none"
    )]
    pub reset_cards_observed_at: Option<DateTime<Utc>>,
    /// When the shown windows and balance were actually observed, if they are
    /// being retained from an earlier read.
    #[serde(
        default,
        with = "chrono::serde::ts_milliseconds_option",
        skip_serializing_if = "Option::is_none"
    )]
    pub retained_from: Option<DateTime<Utc>>,
}

impl LocalCliQuotaResult {
    /// Whether the displayed numbers are from this read or an earlier one.
    pub fn is_retained(&self) -> bool {
        self.retained_from.is_some()
    }

    /// The time the displayed numbers were actually observed.
    pub fn observed_at(&self) -> DateTime<Utc> {
        self.retained_from.unwrap_or(self.fetched_at)
    }
}

/// Keep the account's own last valid snapshot when a refresh fails.
///
/// Windows, balance and identity carry forward from the last available read, and
/// `retained_from` records when they were seen so a retained figure can never be
/// mistaken for a fresh one. Reset cards are deliberately *not* carried: they
/// have their own observation time, and a quota refresh that omits them must not
/// make an older set look new.
///
/// Nothing here ever invents a zero. When there is no previous snapshot the
/// result stays as it is, with an explicit state the UI renders as 暂未读到 or
/// 暂未接通.
pub fn retain_last_valid_result(
    previous: Option<&LocalCliQuotaResult>,
    mut next: LocalCliQuotaResult,
) -> LocalCliQuotaResult {
    if next.state.has_data() {
        next.retained_from = None;
        return next;
    }
    let Some(previous) = previous else {
        return next;
    };
    if !previous.state.has_data() {
        return next;
    }

    next.windows = previous.windows.clone();
    next.balance = previous.balance;
    next.balance_currency = previous.balance_currency.clone();
    next.plan_label = previous.plan_label.clone();
    next.masked_identity = previous.masked_identity.clone();
    next.identity_fingerprint = previous.identity_fingerprint.clone();
    next.retained_from = Some(previous.fetched_at);
    next
}

/// Whether two reads provably belong to the same login.
///
/// Different CLI families cannot share a login record, so that is a certain
/// `false`. Within one family the answer is only known when both sides carry a
/// fingerprint; otherwise it is `None`, and the workbench must not guess that
/// two accounts share quota.
pub fn shares_login(
    kind_a: LocalCliKind,
    fingerprint_a: Option<&str>,
    kind_b: LocalCliKind,
    fingerprint_b: Option<&str>,
) -> Option<bool> {
    if kind_a != kind_b {
        return Some(false);
    }
    match (fingerprint_a, fingerprint_b) {
        (Some(a), Some(b)) => Some(a == b),
        _ => None,
    }
}

/// Presentation bounds shared by every CLI.
pub struct LocalCliPresentation;

impl LocalCliPresentation {
    /// Trim a label, rejecting empty, oversized or control-bearing values.
    pub fn bounded_label(value: Option<&str>, maximum_utf8_bytes: usize) -> Option<String> {
        let raw = value?;
        let trimmed = raw.trim();
        if trimmed.is_empty() || raw.len() > maximum_utf8_bytes {
            return None;
        }
        if raw.chars().any(char::is_control) {
            return None;
        }
        Some(trimmed.to_string())
    }

    /// Accept an identity only when it is a plain name or a well-formed address.
    pub fn valid_identity(value: Option<&str>) -> Option<String> {
        let value = Self::bounded_label(value, 254)?;
        if value.contains('@') {
            let mut parts = value.split('@');
            let local = parts.next().unwrap_or("");
            let domain = parts.next().unwrap_or("");
            if parts.next().is_some() || local.is_empty() {
                return None;
            }
            let domain = Self::bounded_label(Some(domain), 128)?;
            if !domain
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-')
            {
                return None;
            }
        }
        Some(value)
    }

    /// Mask an identity for display.
    ///
    /// An address keeps its domain, which is why a masked email is still too
    /// identifying to send through a message channel.
    pub fn masked_identity(value: &str) -> String {
        if let Some((local, domain)) = value.split_once('@') {
            let first: String = local.chars().take(1).collect();
            return format!("{first}***@{domain}");
        }
        let chars: Vec<char> = value.chars().collect();
        if chars.len() > 4 {
            let head: String = chars.iter().take(2).collect();
            let tail: String = chars.iter().skip(chars.len() - 2).collect();
            return format!("{head}***{tail}");
        }
        "*".repeat(chars.len().max(3))
    }

    /// Whether a window list is structurally safe to render.
    pub fn valid_windows(windows: &[LocalCliQuotaWindow]) -> bool {
        windows.len() <= 256
            && {
                let mut ids: Vec<&str> = windows.iter().map(|w| w.id.as_str()).collect();
                let count = ids.len();
                ids.sort_unstable();
                ids.dedup();
                ids.len() == count
            }
            && windows.iter().all(|window| {
                Self::bounded_label(Some(&window.id), 128).is_some()
                    && Self::bounded_label(Some(&window.label), 128).is_some()
                    && window.used_percent.is_finite()
                    && (0.0..=100.0).contains(&window.used_percent)
            })
    }

    /// Whether a reset-card list is structurally safe to render.
    pub fn valid_reset_cards(cards: &[LocalCliResetCard]) -> bool {
        cards.len() <= 256
            && {
                let mut ids: Vec<&str> = cards.iter().map(|c| c.id.as_str()).collect();
                let count = ids.len();
                ids.sort_unstable();
                ids.dedup();
                ids.len() == count
            }
            && cards
                .iter()
                .all(|card| Self::bounded_label(Some(&card.id), 128).is_some())
    }
}

/// What the workbench keeps about a linked CLI environment.
///
/// Only a name and a directory: never a copy of the vendor's credentials.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalCliProfile {
    pub id: String,
    pub kind: LocalCliKind,
    pub display_name: String,
    /// Directory *label* only. The absolute path is never sent across IPC.
    pub config_directory_label: String,
    pub is_default: bool,
}

impl LocalCliProfile {
    /// Build a profile, rejecting an empty id or an unusable display name.
    pub fn build(
        id: &str,
        kind: LocalCliKind,
        display_name: &str,
        config_directory_label: &str,
        is_default: bool,
    ) -> Option<Self> {
        let id = id.trim();
        let display = LocalCliPresentation::bounded_label(Some(display_name), 64)?;
        let directory = LocalCliPresentation::bounded_label(Some(config_directory_label), 256)?;
        if id.is_empty() {
            return None;
        }
        Some(Self {
            id: id.to_string(),
            kind,
            display_name: display,
            config_directory_label: directory,
            is_default,
        })
    }
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

    fn window(id: &str, used_percent: f64) -> LocalCliQuotaWindow {
        LocalCliQuotaWindow {
            id: id.to_string(),
            label: "Window".to_string(),
            used_percent,
            resets_at: Some(at(600)),
        }
    }

    fn result(state: LocalCliQuotaState, at_seconds: i64) -> LocalCliQuotaResult {
        LocalCliQuotaResult {
            state,
            fetched_at: at(at_seconds),
            masked_identity: Some("a***@example.com".to_string()),
            identity_fingerprint: Some("fp-1".to_string()),
            plan_label: Some("pro".to_string()),
            windows: vec![window("w1", 40.0)],
            balance: Some(12.5),
            balance_currency: None,
            source_label: "official".to_string(),
            message_code: None,
            reset_cards: None,
            reset_cards_observed_at: None,
            retained_from: None,
        }
    }

    #[test]
    fn only_an_available_read_counts_as_data() {
        assert!(LocalCliQuotaState::Available.has_data());
        for state in [
            LocalCliQuotaState::Unavailable,
            LocalCliQuotaState::NeedsLogin,
            LocalCliQuotaState::Unsupported,
            LocalCliQuotaState::RateLimited,
        ] {
            assert!(!state.has_data(), "{state:?}");
        }
    }

    #[test]
    fn a_failed_refresh_retains_the_last_valid_snapshot_and_marks_it() {
        let previous = result(LocalCliQuotaState::Available, 0);
        let failed = result(LocalCliQuotaState::Unavailable, 600);

        let shown = retain_last_valid_result(Some(&previous), failed);
        assert_eq!(shown.state, LocalCliQuotaState::Unavailable);
        // The numbers survive...
        assert_eq!(shown.windows.len(), 1);
        assert_eq!(shown.balance, Some(12.5));
        assert_eq!(shown.plan_label.as_deref(), Some("pro"));
        // ...but they are marked as observed earlier, not now.
        assert!(shown.is_retained());
        assert_eq!(shown.retained_from, Some(at(0)));
        assert_eq!(shown.observed_at(), at(0));
        assert_eq!(shown.fetched_at, at(600));
    }

    #[test]
    fn retention_never_invents_a_zero_when_there_is_no_previous_snapshot() {
        let failed = result(LocalCliQuotaState::NeedsLogin, 600);
        let mut failed = failed;
        failed.windows.clear();
        failed.balance = None;
        failed.plan_label = None;

        let shown = retain_last_valid_result(None, failed.clone());
        assert!(shown.windows.is_empty());
        assert_eq!(shown.balance, None);
        assert!(!shown.is_retained());
        // The state still says what happened, so the UI can say 暂未读到.
        assert_eq!(shown.state, LocalCliQuotaState::NeedsLogin);
    }

    #[test]
    fn retention_does_not_carry_a_previously_failed_read_forward() {
        let previous_failed = result(LocalCliQuotaState::Unavailable, 0);
        let failed = result(LocalCliQuotaState::RateLimited, 600);

        let shown = retain_last_valid_result(Some(&previous_failed), failed);
        assert!(!shown.is_retained());
    }

    #[test]
    fn a_successful_read_clears_the_retained_marker() {
        let mut fresh = result(LocalCliQuotaState::Available, 600);
        fresh.retained_from = Some(at(0));
        let shown = retain_last_valid_result(None, fresh);
        assert!(!shown.is_retained());
        assert_eq!(shown.observed_at(), at(600));
    }

    #[test]
    fn retention_leaves_reset_cards_alone() {
        // A quota refresh that omits card fields must not make an older known
        // set look freshly observed.
        let mut previous = result(LocalCliQuotaState::Available, 0);
        previous.reset_cards = Some(vec![LocalCliResetCard {
            id: "card-1".to_string(),
            expires_at: Some(at(3600)),
        }]);
        previous.reset_cards_observed_at = Some(at(0));

        let failed = result(LocalCliQuotaState::Unavailable, 600);
        let shown = retain_last_valid_result(Some(&previous), failed);

        assert!(shown.reset_cards.is_none());
        assert!(shown.reset_cards_observed_at.is_none());
        assert!(shown.windows.len() == 1, "windows still carry forward");
    }

    #[test]
    fn shared_login_is_only_claimed_when_identity_is_confirmed() {
        assert_eq!(
            shares_login(LocalCliKind::Grok, Some("fp-1"), LocalCliKind::Grok, Some("fp-1")),
            Some(true)
        );
        assert_eq!(
            shares_login(LocalCliKind::Grok, Some("fp-1"), LocalCliKind::Grok, Some("fp-2")),
            Some(false)
        );
        // Different CLI families cannot share a login record.
        assert_eq!(
            shares_login(LocalCliKind::Grok, Some("fp-1"), LocalCliKind::Kimi, Some("fp-1")),
            Some(false)
        );
        // No reliable identity -> unknown, not a guess.
        assert_eq!(shares_login(LocalCliKind::Grok, None, LocalCliKind::Grok, Some("fp-1")), None);
        assert_eq!(shares_login(LocalCliKind::Grok, Some("fp-1"), LocalCliKind::Grok, None), None);
        assert_eq!(shares_login(LocalCliKind::Grok, None, LocalCliKind::Grok, None), None);
    }

    #[test]
    fn a_bounded_label_rejects_empty_oversized_and_control_values() {
        assert_eq!(
            LocalCliPresentation::bounded_label(Some("  hi  "), 64),
            Some("hi".to_string())
        );
        assert_eq!(LocalCliPresentation::bounded_label(Some("   "), 64), None);
        assert_eq!(LocalCliPresentation::bounded_label(None, 64), None);
        assert_eq!(LocalCliPresentation::bounded_label(Some("hi\nthere"), 64), None);
        // The byte bound is on the raw value, not the trimmed one.
        assert_eq!(LocalCliPresentation::bounded_label(Some("aaaa"), 3), None);
    }

    #[test]
    fn an_identity_is_accepted_only_in_a_recognised_shape() {
        assert_eq!(
            LocalCliPresentation::valid_identity(Some("alice@example.com")),
            Some("alice@example.com".to_string())
        );
        assert_eq!(
            LocalCliPresentation::valid_identity(Some(" plain-name ")),
            Some("plain-name".to_string())
        );
        for raw in ["a@@b.com", "@example.com", "a@exa mple.com", "a@example.com@x"] {
            assert_eq!(
                LocalCliPresentation::valid_identity(Some(raw)),
                None,
                "{raw} must be rejected"
            );
        }
    }

    #[test]
    fn masking_keeps_the_domain_for_emails_and_both_ends_otherwise() {
        assert_eq!(
            LocalCliPresentation::masked_identity("alice@example.com"),
            "a***@example.com"
        );
        assert_eq!(LocalCliPresentation::masked_identity("abcdef"), "ab***ef");
        // Short values are fully masked, with a floor of three stars: the star
        // count follows the value length, so masking stays stable per identity.
        assert_eq!(LocalCliPresentation::masked_identity("ab"), "***");
        assert_eq!(LocalCliPresentation::masked_identity("abcd"), "****");
        assert_eq!(LocalCliPresentation::masked_identity("abcde"), "ab***de");
    }

    #[test]
    fn window_lists_are_validated_by_structure_and_range() {
        assert!(LocalCliPresentation::valid_windows(&[window("w1", 0.0)]));
        assert!(LocalCliPresentation::valid_windows(&[window("w1", 100.0)]));

        let mut duplicate = vec![window("w1", 10.0), window("w1", 20.0)];
        assert!(!LocalCliPresentation::valid_windows(&duplicate));

        duplicate = vec![window("w1", 101.0)];
        assert!(!LocalCliPresentation::valid_windows(&duplicate));

        duplicate = vec![window("w1", f64::NAN)];
        assert!(!LocalCliPresentation::valid_windows(&duplicate));

        let mut empty_id = window("", 10.0);
        assert!(!LocalCliPresentation::valid_windows(&[empty_id.clone()]));
        empty_id.id.clear();
        assert!(!LocalCliPresentation::valid_windows(&[empty_id]));
    }

    #[test]
    fn reset_card_lists_are_validated_by_structure() {
        let cards = vec![
            LocalCliResetCard { id: "c1".to_string(), expires_at: Some(at(60)) },
            LocalCliResetCard { id: "c2".to_string(), expires_at: None },
        ];
        assert!(LocalCliPresentation::valid_reset_cards(&cards));

        let duplicate = vec![
            LocalCliResetCard { id: "c1".to_string(), expires_at: None },
            LocalCliResetCard { id: "c1".to_string(), expires_at: None },
        ];
        assert!(!LocalCliPresentation::valid_reset_cards(&duplicate));

        let empty_id = vec![LocalCliResetCard { id: String::new(), expires_at: None }];
        assert!(!LocalCliPresentation::valid_reset_cards(&empty_id));
    }

    #[test]
    fn the_read_policy_disables_cookies_redirects_and_retries() {
        let policy = CliReadPolicy::default();
        assert!(!policy.cookies_enabled);
        assert!(!policy.redirects_enabled);
        assert!(!policy.auto_retry_enabled);
        assert!(policy.total_timeout_secs > 0);
        assert!(policy.max_response_bytes > 0);
    }

    #[test]
    fn a_profile_keeps_only_a_name_and_a_directory_label() {
        let profile = LocalCliProfile::build(
            "p1",
            LocalCliKind::Grok,
            "  Work Grok  ",
            ".grok-work",
            false,
        )
        .expect("profile");
        assert_eq!(profile.display_name, "Work Grok");
        assert_eq!(profile.config_directory_label, ".grok-work");
        assert!(!profile.is_default);

        assert!(LocalCliProfile::build("p1", LocalCliKind::Grok, "   ", ".grok", false).is_none());
        assert!(LocalCliProfile::build("  ", LocalCliKind::Grok, "name", ".grok", false).is_none());
    }

    #[test]
    fn a_quota_result_round_trips_through_json() {
        let mut built = result(LocalCliQuotaState::Available, 0);
        built.reset_cards = Some(vec![LocalCliResetCard {
            id: "card-1".to_string(),
            expires_at: Some(at(3600)),
        }]);
        built.reset_cards_observed_at = Some(at(0));
        built.retained_from = Some(at(-60));

        let encoded = serde_json::to_string(&built).expect("serialise");
        let decoded: LocalCliQuotaResult = serde_json::from_str(&encoded).expect("deserialise");
        assert_eq!(decoded, built);
    }
}
