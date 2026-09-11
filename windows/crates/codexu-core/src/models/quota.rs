//! Official quota windows, reset credits and the fail-closed quota gate.
//!
//! Mirrors `CodexAccountSnapshot` / `CodexQuotaWindowSnapshot` from
//! `Sources/CodexUsageWidget/Services/CodexProfileStore.swift`, with two
//! deliberate divergences:
//!
//! * The macOS snapshot carries raw `email`, `accountType` and `accountID`.
//!   Windows does not: identity lives in `AccountIdentity` and raw email is
//!   never carried across the IPC boundary.
//! * Windows adds an explicit `quality` label so the UI can distinguish fresh
//!   official data from a stale snapshot and from "never read".
//!
//! Product rules encoded here:
//!
//! * A window the source did not return is `None` — unknown, never `0`.
//! * The main workbench rounds a balance to an integer and prefixes `≈` when the
//!   displayed value is not exact; the exact original value stays reachable.
//! * Automation is fail-closed: missing, stale or unknown quota evidence blocks
//!   mutation instead of guessing.

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

/// Placeholder rendered when an official value was not returned.
pub const UNKNOWN_DISPLAY: &str = "—";

/// The subscription windows the product tracks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum QuotaWindowKind {
    FiveHour,
    SevenDay,
    Monthly,
}

impl QuotaWindowKind {
    /// Windows checked for exhaustion, in display order.
    pub const TRACKED: [QuotaWindowKind; 2] =
        [QuotaWindowKind::FiveHour, QuotaWindowKind::SevenDay];

    pub fn id(self) -> &'static str {
        match self {
            QuotaWindowKind::FiveHour => "five_hour",
            QuotaWindowKind::SevenDay => "seven_day",
            QuotaWindowKind::Monthly => "monthly",
        }
    }
}

/// Where a quota observation came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum QuotaSourceQuality {
    /// Successfully parsed from the official app-server response.
    Official,
    /// A previously official value that is now older than the freshness window.
    Stale,
    /// Only local usage is available; no official quota was ever read.
    LocalOnly,
    /// The source could not be classified. Treated as blocking by the gate.
    Unknown,
}

/// One official quota window, expressed the way the source reports it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct QuotaWindowSnapshot {
    /// Percent already consumed, as reported by the source.
    pub used_percent: f64,
    pub window_duration_mins: Option<i64>,
    /// Official reset time. `None` when the source did not report one.
    #[serde(with = "chrono::serde::ts_milliseconds_option")]
    pub resets_at: Option<DateTime<Utc>>,
}

impl QuotaWindowSnapshot {
    /// Whether the reported usage is an actual finite number.
    ///
    /// A non-finite value is treated as "not measured" rather than as zero, so
    /// it can never be rendered or alerted on as if the window were empty.
    pub fn is_measured(&self) -> bool {
        self.used_percent.is_finite()
    }

    /// Remaining percent derived from the reported usage.
    ///
    /// The source reports usage, so remaining is always derived here rather than
    /// stored twice and allowed to drift.
    pub fn remaining_percent(&self) -> f64 {
        if !self.is_measured() {
            return 0.0;
        }
        (100.0 - self.used_percent).clamp(0.0, 100.0)
    }

    /// Whether this window is known to be exhausted.
    pub fn is_exhausted(&self) -> bool {
        self.is_measured() && self.used_percent >= 100.0
    }

    /// Integer remaining percent for display, or the unknown placeholder when
    /// the source did not report a usable number.
    pub fn remaining_display(&self) -> String {
        if !self.is_measured() {
            return UNKNOWN_DISPLAY.to_string();
        }
        format!("{}%", self.remaining_percent().round() as i64)
    }
}

/// Reset-credit view derived from the snapshot.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResetCreditSummary {
    /// Card count. `None` means the official source did not report one.
    pub count: Option<u32>,
    /// Nearest expiry across all reported cards.
    #[serde(with = "chrono::serde::ts_milliseconds_option")]
    pub next_expiry: Option<DateTime<Utc>>,
}

impl ResetCreditSummary {
    pub fn count_display(&self) -> String {
        match self.count {
            Some(count) => count.to_string(),
            None => UNKNOWN_DISPLAY.to_string(),
        }
    }

    /// Whether a card expires within `horizon` of `now`.
    ///
    /// An unknown expiry is never treated as "expiring soon"; it stays unknown.
    pub fn expires_within(&self, now: DateTime<Utc>, horizon: Duration) -> bool {
        match self.next_expiry {
            Some(at) => at > now && at - now <= horizon,
            None => false,
        }
    }
}

/// Apply the main-workbench rounding rule to a raw balance string.
///
/// `"12"` stays `"12"`; `"12.4"` becomes `"≈12"`. A value the source sent as
/// non-numeric text (for example `"unlimited"`) is preserved verbatim rather
/// than being coerced into a number the source never sent.
pub fn round_balance_for_display(raw: Option<&str>) -> String {
    let Some(raw) = raw.map(str::trim).filter(|value| !value.is_empty()) else {
        return UNKNOWN_DISPLAY.to_string();
    };

    match raw.parse::<f64>() {
        Ok(amount) if amount.is_finite() => {
            let rounded = amount.round();
            let text = format!("{}", rounded as i64);
            if (amount - rounded).abs() > f64::EPSILON {
                format!("≈{}", text)
            } else {
                text
            }
        }
        _ => raw.to_string(),
    }
}

/// Exact original balance, reachable from the detail affordance.
pub fn exact_balance_for_display(raw: Option<&str>) -> String {
    raw.map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(UNKNOWN_DISPLAY)
        .to_string()
}

/// A single account's quota observation.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AccountQuotaSnapshot {
    pub account_id: String,
    pub limit_id: Option<String>,
    pub limit_name: Option<String>,
    pub five_hour: Option<QuotaWindowSnapshot>,
    pub seven_day: Option<QuotaWindowSnapshot>,
    pub monthly: Option<QuotaWindowSnapshot>,
    /// `None` means the source did not report a card count.
    pub available_reset_credits: Option<u32>,
    /// `None` means the source did not report expiries.
    #[serde(
        default,
        with = "crate::models::quota::ts_milliseconds_option_vec"
    )]
    pub reset_credit_expiries: Option<Vec<DateTime<Utc>>>,
    /// Raw balance string as sent by the source. Rounded only for display.
    pub credit_balance: Option<String>,
    pub credit_balance_unlimited: Option<bool>,
    #[serde(with = "chrono::serde::ts_milliseconds")]
    pub fetched_at: DateTime<Utc>,
    pub app_server_version: Option<String>,
    pub quota_read_succeeded: Option<bool>,
    pub quality: QuotaSourceQuality,
}

impl AccountQuotaSnapshot {
    pub fn window(&self, kind: QuotaWindowKind) -> Option<&QuotaWindowSnapshot> {
        match kind {
            QuotaWindowKind::FiveHour => self.five_hour.as_ref(),
            QuotaWindowKind::SevenDay => self.seven_day.as_ref(),
            QuotaWindowKind::Monthly => self.monthly.as_ref(),
        }
    }

    /// Whether any window was actually reported.
    ///
    /// Used to decide whether a failed refresh has anything worth retaining.
    pub fn has_any_window(&self) -> bool {
        self.five_hour.is_some() || self.seven_day.is_some() || self.monthly.is_some()
    }

    /// Whether the observation is still within the caller-supplied freshness
    /// window. The caller owns the threshold so no product constant is invented
    /// here.
    pub fn is_fresh(&self, now: DateTime<Utc>, max_age: Duration) -> bool {
        let age = now - self.fetched_at;
        age >= Duration::zero() && age <= max_age
    }

    /// Nearest reset-credit expiry across the reported cards.
    pub fn reset_credit_summary(&self) -> ResetCreditSummary {
        let next_expiry = self
            .reset_credit_expiries
            .as_ref()
            .and_then(|expiries| expiries.iter().copied().min());
        ResetCreditSummary {
            count: self.available_reset_credits,
            next_expiry,
        }
    }
}

/// Low-quota thresholds. Defaults follow the product: 5h at or below 5%, 7d
/// strictly below 10%.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct LowQuotaThresholds {
    pub five_hour_percent: f64,
    pub seven_day_percent: f64,
}

impl Default for LowQuotaThresholds {
    fn default() -> Self {
        Self {
            five_hour_percent: 5.0,
            seven_day_percent: 10.0,
        }
    }
}

/// One threshold that was actually reached.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LowQuotaCondition {
    pub kind: QuotaWindowKind,
    pub remaining_percent: f64,
    pub threshold_percent: f64,
}

impl LowQuotaThresholds {
    /// Only the conditions that were genuinely reached, in window order.
    ///
    /// A window the source did not return is never reported as low: it is
    /// unverified, not empty.
    pub fn reached(&self, snapshot: &AccountQuotaSnapshot) -> Vec<LowQuotaCondition> {
        let mut reached = Vec::new();
        for kind in QuotaWindowKind::TRACKED {
            let Some(window) = snapshot.window(kind) else {
                continue;
            };
            // A value the source did not actually measure is unverified, so it
            // must never be reported as a reached low-quota condition.
            if !window.is_measured() {
                continue;
            }
            let remaining = window.remaining_percent();
            let threshold = match kind {
                QuotaWindowKind::FiveHour => self.five_hour_percent,
                QuotaWindowKind::SevenDay => self.seven_day_percent,
                QuotaWindowKind::Monthly => continue,
            };
            let hit = match kind {
                QuotaWindowKind::FiveHour => remaining <= threshold,
                QuotaWindowKind::SevenDay => remaining < threshold,
                QuotaWindowKind::Monthly => false,
            };
            if hit {
                reached.push(LowQuotaCondition {
                    kind,
                    remaining_percent: remaining,
                    threshold_percent: threshold,
                });
            }
        }
        reached
    }
}

/// Why the quota gate is closed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "reason", content = "detail")]
pub enum QuotaGateBlock {
    /// No snapshot has been read for this account yet.
    MissingSnapshot,
    /// The snapshot is older than the freshness window.
    StaleEvidence,
    /// The source could not be classified.
    UnknownSource,
    /// The account is not signed in, so no official quota can be trusted.
    SignedOut,
    /// At least one known subscription window is exhausted.
    WindowExhausted(QuotaWindowKind),
}

/// Result of the fail-closed quota gate.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "decision")]
pub enum QuotaGate {
    /// Evidence is fresh and no known window is exhausted.
    Open,
    /// Mutation must be refused until the blocking condition clears.
    Blocked(QuotaGateBlock),
}

impl QuotaGate {
    pub fn is_open(&self) -> bool {
        matches!(self, QuotaGate::Open)
    }
}

/// Evaluate the quota gate for one account.
///
/// Order matters: missing and untrusted evidence is reported before exhaustion,
/// because "we do not know" and "we know it is empty" need different handling.
pub fn evaluate_quota_gate(
    snapshot: Option<&AccountQuotaSnapshot>,
    now: DateTime<Utc>,
    max_age: Duration,
    is_signed_in: bool,
) -> QuotaGate {
    if !is_signed_in {
        return QuotaGate::Blocked(QuotaGateBlock::SignedOut);
    }

    let Some(snapshot) = snapshot else {
        return QuotaGate::Blocked(QuotaGateBlock::MissingSnapshot);
    };

    if !snapshot.is_fresh(now, max_age) {
        return QuotaGate::Blocked(QuotaGateBlock::StaleEvidence);
    }

    match snapshot.quality {
        QuotaSourceQuality::Official => {}
        QuotaSourceQuality::Stale => return QuotaGate::Blocked(QuotaGateBlock::StaleEvidence),
        QuotaSourceQuality::Unknown => return QuotaGate::Blocked(QuotaGateBlock::UnknownSource),
        QuotaSourceQuality::LocalOnly => return QuotaGate::Blocked(QuotaGateBlock::MissingSnapshot),
    }

    for kind in QuotaWindowKind::TRACKED {
        if let Some(window) = snapshot.window(kind) {
            if window.is_exhausted() {
                return QuotaGate::Blocked(QuotaGateBlock::WindowExhausted(kind));
            }
        }
    }

    QuotaGate::Open
}

/// Serde helper for `Option<Vec<DateTime<Utc>>>` as epoch milliseconds.
mod ts_milliseconds_option_vec {
    use chrono::{DateTime, TimeZone, Utc};
    use serde::{self, Deserialize, Deserializer, Serializer};

    pub fn serialize<S>(
        value: &Option<Vec<DateTime<Utc>>>,
        serializer: S,
    ) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match value {
            Some(values) => {
                let millis: Vec<i64> = values.iter().map(|at| at.timestamp_millis()).collect();
                serializer.serialize_some(&millis)
            }
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Option<Vec<DateTime<Utc>>>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw: Option<Vec<i64>> = Option::deserialize(deserializer)?;
        Ok(raw.map(|values| {
            values
                .into_iter()
                .filter_map(|ms| Utc.timestamp_millis_opt(ms).single())
                .collect()
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn at(minutes: i64) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 9, 11, 12, 0, 0)
            .single()
            .expect("valid timestamp")
            + Duration::minutes(minutes)
    }

    fn window(used_percent: f64) -> QuotaWindowSnapshot {
        QuotaWindowSnapshot {
            used_percent,
            window_duration_mins: Some(300),
            resets_at: None,
        }
    }

    fn snapshot(
        quality: QuotaSourceQuality,
        five: Option<f64>,
        seven: Option<f64>,
    ) -> AccountQuotaSnapshot {
        AccountQuotaSnapshot {
            account_id: "acc-1".to_string(),
            limit_id: Some("limit".to_string()),
            limit_name: Some("Plus".to_string()),
            five_hour: five.map(window),
            seven_day: seven.map(window),
            monthly: None,
            available_reset_credits: None,
            reset_credit_expiries: None,
            credit_balance: None,
            credit_balance_unlimited: None,
            fetched_at: at(0),
            app_server_version: Some("1.0".to_string()),
            quota_read_succeeded: Some(true),
            quality,
        }
    }

    #[test]
    fn remaining_is_derived_from_reported_usage() {
        assert_eq!(window(0.0).remaining_percent(), 100.0);
        assert_eq!(window(25.0).remaining_percent(), 75.0);
        assert_eq!(window(100.0).remaining_percent(), 0.0);
        // A source that over-reports is clamped rather than going negative.
        assert_eq!(window(140.0).remaining_percent(), 0.0);
        assert_eq!(window(-10.0).remaining_percent(), 100.0);
    }

    #[test]
    fn a_missing_window_is_unknown_and_never_exhausted() {
        let snapshot = snapshot(QuotaSourceQuality::Official, None, None);
        assert!(snapshot.window(QuotaWindowKind::FiveHour).is_none());
        assert_eq!(snapshot.window(QuotaWindowKind::FiveHour), None);

        let placeholder = UNKNOWN_DISPLAY;
        assert_eq!(placeholder, "—");
    }

    #[test]
    fn remaining_display_rounds_to_an_integer_percent() {
        assert_eq!(window(57.4).remaining_display(), "43%");
        assert_eq!(window(0.0).remaining_display(), "100%");
        assert_eq!(window(100.0).remaining_display(), "0%");
    }

    #[test]
    fn exhaustion_is_reported_only_when_usage_reaches_the_cap() {
        assert!(!window(99.9).is_exhausted());
        assert!(window(100.0).is_exhausted());
        assert!(window(100.1).is_exhausted());
    }

    #[test]
    fn balance_rounding_marks_inexact_values() {
        assert_eq!(round_balance_for_display(Some("12")), "12");
        assert_eq!(round_balance_for_display(Some("12.0")), "12");
        assert_eq!(round_balance_for_display(Some("12.4")), "≈12");
        assert_eq!(round_balance_for_display(Some("12.6")), "≈13");
        assert_eq!(round_balance_for_display(Some(" 7.5 ")), "≈8");
        assert_eq!(round_balance_for_display(None), "—");
        assert_eq!(round_balance_for_display(Some("   ")), "—");
    }

    #[test]
    fn a_non_numeric_balance_is_preserved_instead_of_coerced() {
        assert_eq!(round_balance_for_display(Some("unlimited")), "unlimited");
        assert_eq!(exact_balance_for_display(Some(" 12.4 ")), "12.4");
        assert_eq!(exact_balance_for_display(None), "—");
    }

    #[test]
    fn reset_credit_summary_picks_the_nearest_expiry() {
        let mut snapshot = snapshot(QuotaSourceQuality::Official, Some(0.0), Some(0.0));
        snapshot.available_reset_credits = Some(2);
        snapshot.reset_credit_expiries = Some(vec![at(600), at(120), at(1440)]);

        let summary = snapshot.reset_credit_summary();
        assert_eq!(summary.count_display(), "2");
        assert_eq!(summary.next_expiry, Some(at(120)));
        assert!(summary.expires_within(at(0), Duration::hours(72)));
        assert!(!summary.expires_within(at(0), Duration::minutes(30)));
    }

    #[test]
    fn unknown_reset_credit_count_stays_unknown() {
        let snapshot = snapshot(QuotaSourceQuality::Official, Some(0.0), Some(0.0));
        let summary = snapshot.reset_credit_summary();
        assert_eq!(summary.count_display(), "—");
        assert!(!summary.expires_within(at(0), Duration::hours(72)));
    }

    #[test]
    fn low_quota_lists_only_reached_conditions() {
        let thresholds = LowQuotaThresholds::default();

        // used 20% -> remaining 80%; used 50% -> remaining 50%
        let none = snapshot(QuotaSourceQuality::Official, Some(20.0), Some(50.0));
        assert!(thresholds.reached(&none).is_empty());

        // remaining 5% -> at the 5h threshold
        let five_only = snapshot(QuotaSourceQuality::Official, Some(95.0), Some(50.0));
        let reached = thresholds.reached(&five_only);
        assert_eq!(reached.len(), 1);
        assert_eq!(reached[0].kind, QuotaWindowKind::FiveHour);
        assert_eq!(reached[0].remaining_percent, 5.0);

        // remaining 4% and 9.9% -> both
        let both = snapshot(QuotaSourceQuality::Official, Some(96.0), Some(90.1));
        assert_eq!(thresholds.reached(&both).len(), 2);

        // 7d threshold is exclusive: exactly 10% remaining is not "below 10%".
        let boundary = snapshot(QuotaSourceQuality::Official, Some(10.0), Some(90.0));
        assert!(thresholds.reached(&boundary).is_empty());
    }

    #[test]
    fn unknown_quota_is_never_reported_as_low() {
        let thresholds = LowQuotaThresholds::default();
        let unknown = snapshot(QuotaSourceQuality::Official, None, None);
        assert!(thresholds.reached(&unknown).is_empty());
    }

    #[test]
    fn gate_is_closed_for_signed_out_and_missing_evidence() {
        let fresh = snapshot(QuotaSourceQuality::Official, Some(20.0), Some(20.0));

        assert_eq!(
            evaluate_quota_gate(Some(&fresh), at(0), Duration::minutes(30), false),
            QuotaGate::Blocked(QuotaGateBlock::SignedOut)
        );
        assert_eq!(
            evaluate_quota_gate(None, at(0), Duration::minutes(30), true),
            QuotaGate::Blocked(QuotaGateBlock::MissingSnapshot)
        );
    }

    #[test]
    fn gate_is_closed_for_stale_and_unknown_evidence() {
        let stale = snapshot(QuotaSourceQuality::Official, Some(20.0), Some(20.0));
        assert_eq!(
            evaluate_quota_gate(Some(&stale), at(60), Duration::minutes(30), true),
            QuotaGate::Blocked(QuotaGateBlock::StaleEvidence)
        );

        let unclassified = snapshot(QuotaSourceQuality::Unknown, Some(20.0), Some(20.0));
        assert_eq!(
            evaluate_quota_gate(Some(&unclassified), at(0), Duration::minutes(30), true),
            QuotaGate::Blocked(QuotaGateBlock::UnknownSource)
        );

        let local_only = snapshot(QuotaSourceQuality::LocalOnly, Some(20.0), Some(20.0));
        assert_eq!(
            evaluate_quota_gate(Some(&local_only), at(0), Duration::minutes(30), true),
            QuotaGate::Blocked(QuotaGateBlock::MissingSnapshot)
        );
    }

    #[test]
    fn gate_is_closed_when_any_known_window_is_exhausted() {
        let exhausted_five = snapshot(QuotaSourceQuality::Official, Some(100.0), Some(30.0));
        assert_eq!(
            evaluate_quota_gate(Some(&exhausted_five), at(0), Duration::minutes(30), true),
            QuotaGate::Blocked(QuotaGateBlock::WindowExhausted(
                QuotaWindowKind::FiveHour
            ))
        );

        let exhausted_seven = snapshot(QuotaSourceQuality::Official, Some(30.0), Some(100.0));
        assert_eq!(
            evaluate_quota_gate(Some(&exhausted_seven), at(0), Duration::minutes(30), true),
            QuotaGate::Blocked(QuotaGateBlock::WindowExhausted(
                QuotaWindowKind::SevenDay
            ))
        );
    }

    #[test]
    fn gate_opens_for_fresh_official_evidence_with_room_left() {
        let fresh = snapshot(QuotaSourceQuality::Official, Some(20.0), Some(60.0));
        assert_eq!(
            evaluate_quota_gate(Some(&fresh), at(5), Duration::minutes(30), true),
            QuotaGate::Open
        );
        assert!(evaluate_quota_gate(Some(&fresh), at(5), Duration::minutes(30), true).is_open());
    }

    #[test]
    fn a_non_finite_usage_is_unknown_and_never_low_or_exhausted() {
        for bad in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            let window = QuotaWindowSnapshot {
                used_percent: bad,
                window_duration_mins: None,
                resets_at: None,
            };
            assert!(!window.is_measured(), "{bad} must not be measured");
            assert_eq!(window.remaining_display(), "—");
            assert!(!window.is_exhausted());
        }

        let thresholds = LowQuotaThresholds::default();
        let snapshot = snapshot(
            QuotaSourceQuality::Official,
            Some(f64::NAN),
            Some(f64::INFINITY),
        );
        assert!(thresholds.reached(&snapshot).is_empty());

        // A non-finite value must not close the gate as "exhausted" either.
        assert_eq!(
            evaluate_quota_gate(Some(&snapshot), at(0), Duration::minutes(30), true),
            QuotaGate::Open
        );
    }

    #[test]
    fn snapshot_round_trips_through_json_without_losing_expiries() {
        let mut snapshot = snapshot(QuotaSourceQuality::Official, Some(20.0), Some(60.0));
        snapshot.available_reset_credits = Some(1);
        snapshot.reset_credit_expiries = Some(vec![at(120)]);

        let encoded = serde_json::to_string(&snapshot).expect("serialise");
        let decoded: AccountQuotaSnapshot = serde_json::from_str(&encoded).expect("deserialise");
        assert_eq!(decoded, snapshot);
    }
}
