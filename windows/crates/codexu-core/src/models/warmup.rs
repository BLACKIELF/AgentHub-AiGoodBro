//! Warm-up scheduling policy.
//!
//! Faithful port of `CodexWarmUpPolicy` in
//! `Sources/CodexUsageWidget/Services/CodexProfileStore.swift`. The policy only
//! decides *whether* and *when* a warm-up request may be sent; sending it is the
//! runtime's job.
//!
//! Product rules that must not be relaxed:
//!
//! * A warm-up never increases quota and never redeems a reset credit.
//! * A missed or failed read keeps the deadline pending with bounded retry
//!   frequency; it does not silently drop the schedule.
//! * A successful warm-up anchors its own interval even when usage still rounds
//!   to zero, so a full-looking window is not warmed again every minute.
//! * Dispatch participation controls task assignment, not quota-window
//!   maintenance.
//! * Missing data for a *selected* window stays fail-closed: another window's
//!   value is not evidence that this one is idle.

use std::collections::{BTreeMap, BTreeSet};

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

use super::account::AccountRecord;
use super::quota::{AccountQuotaSnapshot, QuotaWindowKind, QuotaWindowSnapshot};

/// Grace period added after an official reset time before acting.
pub const RESET_GRACE_SECS: i64 = 8;
/// A successful 5-hour warm-up anchors the next attempt this far out.
pub const FIVE_HOUR_SUCCESS_INTERVAL_SECS: i64 = 5 * 60 * 60;
/// A successful 7-day warm-up anchors the next attempt this far out.
pub const SEVEN_DAY_SUCCESS_INTERVAL_SECS: i64 = 7 * 24 * 60 * 60;
/// Retry spacing after a failed attempt.
pub const FAILURE_RETRY_INTERVAL_SECS: i64 = 5 * 60;
/// Maximum age of a quota observation that still counts as current evidence.
pub const MAXIMUM_QUOTA_AGE_SECS: i64 = 15 * 60;
/// Usage below this percent counts as an idle window.
pub const IDLE_USED_PERCENT_THRESHOLD: f64 = 0.5;
/// Usage drop that counts as an unexpected reset within the same window.
pub const UNEXPECTED_RESET_DROP: f64 = 8.0;
/// Remaining weekly percent below which the 5-hour window yields to the weekly.
pub const MINIMUM_WEEKLY_REMAINING: f64 = 0.0;
/// Tolerance when matching a window start against the previous reset time.
pub const RESET_START_TOLERANCE_SECS: i64 = 10 * 60;
/// Tolerance for treating two reset times as the same window.
const SAME_WINDOW_TOLERANCE_SECS: i64 = 120;
/// Usage drop required when the reset time moved by more than the tolerance.
const MOVED_WINDOW_DROP: f64 = 3.0;
/// Clock-skew allowance when judging freshness.
const FUTURE_SKEW_ALLOWANCE_SECS: i64 = 60;

fn secs(value: i64) -> Duration {
    Duration::seconds(value)
}

/// The two independently selectable warm-up windows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WarmUpWindowKind {
    FiveHour,
    SevenDay,
}

impl WarmUpWindowKind {
    pub const ALL: [WarmUpWindowKind; 2] =
        [WarmUpWindowKind::FiveHour, WarmUpWindowKind::SevenDay];

    pub fn id(self) -> &'static str {
        match self {
            WarmUpWindowKind::FiveHour => "five_hour",
            WarmUpWindowKind::SevenDay => "seven_day",
        }
    }

    pub fn quota_window_kind(self) -> QuotaWindowKind {
        match self {
            WarmUpWindowKind::FiveHour => QuotaWindowKind::FiveHour,
            WarmUpWindowKind::SevenDay => QuotaWindowKind::SevenDay,
        }
    }

    pub fn success_interval_secs(self) -> i64 {
        match self {
            WarmUpWindowKind::FiveHour => FIVE_HOUR_SUCCESS_INTERVAL_SECS,
            WarmUpWindowKind::SevenDay => SEVEN_DAY_SUCCESS_INTERVAL_SECS,
        }
    }
}

/// Which windows the user enabled. Warm-up is opt-in per window.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct WarmUpSelection {
    pub five_hour: bool,
    pub seven_day: bool,
}

impl WarmUpSelection {
    pub const NONE: Self = Self {
        five_hour: false,
        seven_day: false,
    };
    pub const ALL: Self = Self {
        five_hour: true,
        seven_day: true,
    };

    pub fn is_enabled(self) -> bool {
        self.five_hour || self.seven_day
    }

    pub fn is_selected(self, kind: WarmUpWindowKind) -> bool {
        match kind {
            WarmUpWindowKind::FiveHour => self.five_hour,
            WarmUpWindowKind::SevenDay => self.seven_day,
        }
    }

    pub fn selected_kinds(self) -> BTreeSet<WarmUpWindowKind> {
        WarmUpWindowKind::ALL
            .into_iter()
            .filter(|kind| self.is_selected(*kind))
            .collect()
    }
}

/// One warm-up attempt, kept as history.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WarmUpAttempt {
    #[serde(with = "chrono::serde::ts_milliseconds")]
    pub at: DateTime<Utc>,
    pub succeeded: bool,
    pub failure_reason: Option<String>,
}

/// Per-account warm-up state.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct WarmUpState {
    pub snapshot: Option<AccountQuotaSnapshot>,
    #[serde(with = "chrono::serde::ts_milliseconds_option")]
    pub last_warm_up_at: Option<DateTime<Utc>>,
    pub last_warm_up_succeeded: Option<bool>,
    #[serde(with = "chrono::serde::ts_milliseconds_option")]
    pub last_quota_read_failure_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub history: Vec<WarmUpAttempt>,
}

/// Keep at most this many attempts in the history.
pub const MAX_WARM_UP_HISTORY: usize = 20;

impl WarmUpState {
    /// Record an attempt and update the scheduling anchors.
    pub fn record_attempt(&mut self, attempt: WarmUpAttempt) {
        self.last_warm_up_at = Some(attempt.at);
        self.last_warm_up_succeeded = Some(attempt.succeeded);
        self.history.push(attempt);
        if self.history.len() > MAX_WARM_UP_HISTORY {
            let excess = self.history.len() - MAX_WARM_UP_HISTORY;
            self.history.drain(0..excess);
        }
    }

    /// Record that the quota read itself failed. This keeps a pending deadline
    /// pending rather than treating the account as fresh.
    pub fn record_quota_read_failure(&mut self, at: DateTime<Utc>) {
        self.last_quota_read_failure_at = Some(at);
    }

    /// Replace the observation.
    pub fn apply_snapshot(&mut self, snapshot: AccountQuotaSnapshot) {
        self.snapshot = Some(snapshot);
    }
}

/// The account-level facts the policy needs.
#[derive(Debug, Clone, Copy)]
pub struct WarmUpSubject<'a> {
    pub account_id: &'a str,
    pub is_signed_in: bool,
    pub participates_in_dispatch: bool,
    pub state: &'a WarmUpState,
}

impl<'a> WarmUpSubject<'a> {
    pub fn new(account: &'a AccountRecord, state: &'a WarmUpState) -> Self {
        Self {
            account_id: &account.identity.id,
            is_signed_in: account.identity.is_signed_in,
            participates_in_dispatch: account.participates_in_dispatch,
            state,
        }
    }
}

/// Why a warm-up is not being sent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "reason", content = "detail")]
pub enum WarmUpBlock {
    /// Both windows are switched off.
    Disabled,
    /// The account has no verified login.
    NotSignedIn,
    /// No fresh, official, non-failed quota observation exists.
    NoFreshQuotaEvidence,
    /// At least one known subscription window is exhausted. A balance never
    /// grants permission to fall back to paid credits.
    ExhaustedSubscriptionWindow(QuotaWindowKind),
    /// A selected window has no data at all. Fail closed rather than assume.
    MissingSelectedWindow(WarmUpWindowKind),
    /// No reset is scheduled, so there is nothing to warm toward.
    NoResetScheduled,
}

/// What the runtime should do next for one account.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "decision")]
pub enum WarmUpDecision {
    /// Send one minimal request for exactly these windows.
    Send { kinds: BTreeSet<WarmUpWindowKind> },
    /// Not due yet; re-evaluate at this time.
    WaitUntil(DateTime<Utc>),
    /// Do not act; the reason is surfaced instead of being silently swallowed.
    Blocked(WarmUpBlock),
}

impl WarmUpDecision {
    pub fn is_send(&self) -> bool {
        matches!(self, WarmUpDecision::Send { .. })
    }
}

/// Maintenance refresh cadence, in seconds.
pub fn maintenance_refresh_interval_secs(
    warm_up_enabled: bool,
    quota_notifications_enabled: bool,
) -> i64 {
    if quota_notifications_enabled {
        60
    } else if warm_up_enabled {
        10 * 60
    } else {
        30 * 60
    }
}

/// Dispatch participation controls task assignment, not quota-window
/// maintenance, so it never changes the selection.
pub fn effective_selection(selection: WarmUpSelection) -> WarmUpSelection {
    selection
}

/// A window is idle when it reports essentially no usage.
///
/// A missing window counts as idle, because there is nothing that proves it is
/// busy.
pub fn is_window_idle(window: Option<&QuotaWindowSnapshot>) -> bool {
    match window {
        Some(window) => window.used_percent < IDLE_USED_PERCENT_THRESHOLD,
        None => true,
    }
}

fn same_window(previous: &QuotaWindowSnapshot, current: &QuotaWindowSnapshot) -> bool {
    match (previous.resets_at, current.resets_at) {
        (Some(previous_reset), Some(current_reset)) => {
            (current_reset - previous_reset).num_seconds().abs() <= SAME_WINDOW_TOLERANCE_SECS
        }
        _ => false,
    }
}

/// Whether the window recovered without a scheduled reset.
pub fn did_reset_unexpectedly(
    previous: Option<&QuotaWindowSnapshot>,
    current: Option<&QuotaWindowSnapshot>,
) -> bool {
    let (Some(previous), Some(current)) = (previous, current) else {
        return false;
    };
    if is_window_idle(Some(previous)) {
        return false;
    }
    if is_window_idle(Some(current)) {
        return true;
    }
    if current.used_percent + UNEXPECTED_RESET_DROP <= previous.used_percent {
        return true;
    }
    if previous.resets_at.is_some()
        && current.resets_at.is_some()
        && !same_window(previous, current)
        && current.used_percent + MOVED_WINDOW_DROP <= previous.used_percent
    {
        return true;
    }
    false
}

/// Whether a reset credit appears to have been consumed.
///
/// Distinguishes "official early or manual reset" from "the window simply rolled
/// over": within one window a large drop counts; across windows, a start time
/// that clearly departs from the previous reset counts.
pub fn did_consume_reset(
    previous: Option<&QuotaWindowSnapshot>,
    current: Option<&QuotaWindowSnapshot>,
) -> bool {
    let (Some(previous), Some(current)) = (previous, current) else {
        return false;
    };
    if previous.used_percent < 1.0 {
        return false;
    }
    if previous.resets_at.is_none() || current.resets_at.is_none() {
        return false;
    }

    if same_window(previous, current) {
        return current.used_percent + UNEXPECTED_RESET_DROP <= previous.used_percent;
    }

    let Some(duration_mins) = current.window_duration_mins else {
        return false;
    };
    if duration_mins <= 0 {
        return false;
    }
    let (Some(previous_reset), Some(current_reset)) = (previous.resets_at, current.resets_at) else {
        return false;
    };
    let implied_start = current_reset - Duration::minutes(duration_mins);
    (implied_start - previous_reset).num_seconds().abs() > RESET_START_TOLERANCE_SECS
}

/// The 5-hour window yields to the weekly one when the weekly is nearly spent.
pub fn should_skip_five_hour_to_protect_weekly(subject: &WarmUpSubject<'_>) -> bool {
    let Some(weekly) = subject.state.snapshot.as_ref().and_then(|s| s.seven_day.as_ref()) else {
        return false;
    };
    if is_window_idle(Some(weekly)) {
        return false;
    }
    100.0 - weekly.used_percent <= MINIMUM_WEEKLY_REMAINING
}

/// Whether any known subscription window is exhausted.
pub fn has_exhausted_subscription_window(state: &WarmUpState) -> bool {
    exhausted_window(state).is_some()
}

/// Whether the observation is fresh, official, and not invalidated by a later
/// failed read.
pub fn has_fresh_quota_evidence(subject: &WarmUpSubject<'_>, now: DateTime<Utc>) -> bool {
    let state = subject.state;
    let Some(snapshot) = state.snapshot.as_ref() else {
        return false;
    };
    if !subject.is_signed_in {
        return false;
    }
    if snapshot.quota_read_succeeded != Some(true) {
        return false;
    }
    if let Some(failure_at) = state.last_quota_read_failure_at {
        if failure_at >= snapshot.fetched_at {
            return false;
        }
    }
    let age = (now - snapshot.fetched_at).num_seconds();
    age >= -FUTURE_SKEW_ALLOWANCE_SECS && age <= MAXIMUM_QUOTA_AGE_SECS
}

/// Whether a warm-up request may be sent at all.
pub fn can_send_warm_up_request(subject: &WarmUpSubject<'_>, now: DateTime<Utc>) -> bool {
    if !has_fresh_quota_evidence(subject, now) {
        return false;
    }
    let Some(snapshot) = subject.state.snapshot.as_ref() else {
        return false;
    };
    if !snapshot.has_any_window() {
        return false;
    }
    !has_exhausted_subscription_window(subject.state)
}

/// Re-check mutable lifecycle state after an asynchronous lookup.
///
/// A late result must not start a request after the service stopped.
pub fn can_continue_after_async_check(
    service_is_running: bool,
    request_is_current: bool,
    warm_up_is_enabled: bool,
    account_operation_is_idle: bool,
) -> bool {
    service_is_running && request_is_current && warm_up_is_enabled && account_operation_is_idle
}

/// Whether a previous failure is still unresolved for a selected window.
///
/// Unlike the macOS original this takes no `now`, because the window-idle test it
/// uses does not depend on the clock.
pub fn has_unresolved_failure(subject: &WarmUpSubject<'_>, selection: WarmUpSelection) -> bool {
    let state = subject.state;
    if state.last_warm_up_succeeded != Some(false) {
        return false;
    }
    let Some(attempted_at) = state.last_warm_up_at else {
        return false;
    };
    let Some(snapshot) = state.snapshot.as_ref() else {
        return true;
    };
    if snapshot.fetched_at <= attempted_at {
        return true;
    }
    (selection.five_hour && is_window_idle(snapshot.five_hour.as_ref()))
        || (selection.seven_day && is_window_idle(snapshot.seven_day.as_ref()))
}

fn selected_window<'a>(
    snapshot: &'a AccountQuotaSnapshot,
    kind: WarmUpWindowKind,
) -> Option<&'a QuotaWindowSnapshot> {
    snapshot.window(kind.quota_window_kind())
}

/// The next time one selected window may be warmed.
///
/// Returns `None` when the window has no data, or when its reset time is unknown
/// and it is not idle. Both cases stay fail-closed rather than being guessed.
pub fn next_date_for_kind(
    subject: &WarmUpSubject<'_>,
    selection: WarmUpSelection,
    kind: WarmUpWindowKind,
    unexpected: bool,
    now: DateTime<Utc>,
) -> Option<DateTime<Utc>> {
    let state = subject.state;
    let snapshot = state.snapshot.as_ref()?;
    let window = selected_window(snapshot, kind)?;

    let block_idle_retry = has_unresolved_failure(subject, selection);
    if block_idle_retry {
        if let Some(last_warm_up_at) = state.last_warm_up_at {
            if unexpected || is_window_idle(Some(window)) {
                let retry_at = last_warm_up_at + secs(FAILURE_RETRY_INTERVAL_SECS);
                return Some(if retry_at > now { retry_at } else { now });
            }
        }
    }

    if unexpected {
        return Some(now);
    }

    if is_window_idle(Some(window)) {
        if state.last_warm_up_succeeded == Some(true) {
            if let Some(last_warm_up_at) = state.last_warm_up_at {
                let retry_at = last_warm_up_at
                    + secs(kind.success_interval_secs() + RESET_GRACE_SECS);
                if retry_at > now {
                    return Some(retry_at);
                }
            }
        }
        return Some(now);
    }

    match window.resets_at {
        Some(resets_at) if resets_at > now => Some(resets_at + secs(RESET_GRACE_SECS)),
        _ => None,
    }
}

/// The earliest time any selected window may be warmed.
pub fn next_eligible_date(
    subject: &WarmUpSubject<'_>,
    selection: WarmUpSelection,
    unexpected: &BTreeSet<WarmUpWindowKind>,
    now: DateTime<Utc>,
) -> Option<DateTime<Utc>> {
    if !selection.is_enabled() || has_exhausted_subscription_window(subject.state) {
        return None;
    }
    if !subject.is_signed_in {
        return None;
    }

    let mut dates: Vec<DateTime<Utc>> = Vec::new();
    if selection.five_hour && !should_skip_five_hour_to_protect_weekly(subject) {
        if let Some(date) = next_date_for_kind(
            subject,
            selection,
            WarmUpWindowKind::FiveHour,
            unexpected.contains(&WarmUpWindowKind::FiveHour),
            now,
        ) {
            dates.push(date);
        }
    }
    if selection.seven_day {
        if let Some(date) = next_date_for_kind(
            subject,
            selection,
            WarmUpWindowKind::SevenDay,
            unexpected.contains(&WarmUpWindowKind::SevenDay),
            now,
        ) {
            dates.push(date);
        }
    }
    dates.into_iter().min()
}

/// Whether a warm-up is due right now.
pub fn is_due(
    subject: &WarmUpSubject<'_>,
    selection: WarmUpSelection,
    unexpected: &BTreeSet<WarmUpWindowKind>,
    now: DateTime<Utc>,
) -> bool {
    if !can_send_warm_up_request(subject, now) {
        return false;
    }
    next_eligible_date(subject, selection, unexpected, now)
        .map(|date| date <= now)
        .unwrap_or(false)
}

/// The next scheduled reset, ignoring whether a request may be sent.
pub fn next_scheduled_reset_date(
    subject: &WarmUpSubject<'_>,
    selection: WarmUpSelection,
    now: DateTime<Utc>,
) -> Option<DateTime<Utc>> {
    if !selection.is_enabled() || !subject.is_signed_in {
        return None;
    }
    let snapshot = subject.state.snapshot.as_ref()?;

    let mut dates: Vec<DateTime<Utc>> = Vec::new();
    if selection.five_hour {
        if should_skip_five_hour_to_protect_weekly(subject) {
            if let Some(resets_at) = snapshot.seven_day.as_ref().and_then(|w| w.resets_at) {
                if resets_at > now {
                    dates.push(resets_at + secs(RESET_GRACE_SECS));
                }
            }
        } else if let Some(resets_at) = snapshot.five_hour.as_ref().and_then(|w| w.resets_at) {
            if resets_at > now {
                dates.push(resets_at + secs(RESET_GRACE_SECS));
            }
        }
    }
    if selection.seven_day {
        if let Some(resets_at) = snapshot.seven_day.as_ref().and_then(|w| w.resets_at) {
            if resets_at > now {
                dates.push(resets_at + secs(RESET_GRACE_SECS));
            }
        }
    }
    dates.into_iter().min()
}

/// When to re-read quota after a reset.
///
/// Reading a reset is independent of permission to send a warm-up request. A
/// failed read keeps the deadline pending with bounded retry frequency.
pub fn next_quota_reset_refresh_date(
    subject: &WarmUpSubject<'_>,
    last_attempt_at: Option<DateTime<Utc>>,
    now: DateTime<Utc>,
) -> Option<DateTime<Utc>> {
    let state = subject.state;
    let snapshot = state.snapshot.as_ref()?;

    let mut dates: Vec<DateTime<Utc>> = Vec::new();
    for window in [
        snapshot.five_hour.as_ref(),
        snapshot.seven_day.as_ref(),
        snapshot.monthly.as_ref(),
    ]
    .into_iter()
    .flatten()
    {
        let Some(resets_at) = window.resets_at else {
            continue;
        };
        let deadline = resets_at + secs(RESET_GRACE_SECS);
        if !(snapshot.fetched_at < deadline || window.used_percent >= 100.0) {
            continue;
        }
        let observed_at = [
            snapshot.fetched_at,
            state.last_quota_read_failure_at.unwrap_or(DateTime::<Utc>::MIN_UTC),
            last_attempt_at.unwrap_or(DateTime::<Utc>::MIN_UTC),
        ]
        .into_iter()
        .max()
        .unwrap_or(snapshot.fetched_at);

        if observed_at >= deadline {
            let retry_at = observed_at + secs(60);
            dates.push(if retry_at > now { retry_at } else { now });
        } else {
            dates.push(if deadline > now { deadline } else { now });
        }
    }
    dates.into_iter().min()
}

/// Combine the gate and the schedule into one decision for the runtime.
pub fn warm_up_decision(
    subject: &WarmUpSubject<'_>,
    selection: WarmUpSelection,
    unexpected: &BTreeSet<WarmUpWindowKind>,
    now: DateTime<Utc>,
) -> WarmUpDecision {
    let selection = effective_selection(selection);

    if !selection.is_enabled() {
        return WarmUpDecision::Blocked(WarmUpBlock::Disabled);
    }
    if !subject.is_signed_in {
        return WarmUpDecision::Blocked(WarmUpBlock::NotSignedIn);
    }
    if !has_fresh_quota_evidence(subject, now) {
        return WarmUpDecision::Blocked(WarmUpBlock::NoFreshQuotaEvidence);
    }
    if let Some(kind) = exhausted_window(subject.state) {
        return WarmUpDecision::Blocked(WarmUpBlock::ExhaustedSubscriptionWindow(kind));
    }

    // A selected window with no data at all must not be assumed idle.
    if let Some(snapshot) = subject.state.snapshot.as_ref() {
        for kind in selection.selected_kinds() {
            if selected_window(snapshot, kind).is_none() {
                return WarmUpDecision::Blocked(WarmUpBlock::MissingSelectedWindow(kind));
            }
        }
    }

    let mut due: BTreeSet<WarmUpWindowKind> = BTreeSet::new();
    let mut next: Option<DateTime<Utc>> = None;

    for kind in selection.selected_kinds() {
        if kind == WarmUpWindowKind::FiveHour && should_skip_five_hour_to_protect_weekly(subject) {
            continue;
        }
        match next_date_for_kind(subject, selection, kind, unexpected.contains(&kind), now) {
            Some(date) if date <= now => {
                due.insert(kind);
            }
            Some(date) => {
                next = Some(next.map_or(date, |current| current.min(date)));
            }
            None => {
                next = None;
                break;
            }
        }
    }

    if !due.is_empty() {
        return WarmUpDecision::Send { kinds: due };
    }
    match next {
        Some(date) => WarmUpDecision::WaitUntil(date),
        None => WarmUpDecision::Blocked(WarmUpBlock::NoResetScheduled),
    }
}

fn exhausted_window(state: &WarmUpState) -> Option<QuotaWindowKind> {
    let snapshot = state.snapshot.as_ref()?;
    QuotaWindowKind::TRACKED
        .into_iter()
        .chain(std::iter::once(QuotaWindowKind::Monthly))
        .find(|kind| {
            snapshot
                .window(*kind)
                .map(|window| window.used_percent >= 100.0)
                .unwrap_or(false)
        })
}

/// Ticket-based acknowledgement of reset events.
///
/// A successful request acknowledges the reset event it actually handled even
/// when quota usage still rounds to zero, so a later reset keeps its own ticket.
#[derive(Debug, Clone, Default)]
pub struct WarmUpResetTracker {
    events: BTreeMap<String, BTreeMap<WarmUpWindowKind, u64>>,
    next_ticket: u64,
}

impl WarmUpResetTracker {
    pub fn ticket(&self, account: &str) -> BTreeMap<WarmUpWindowKind, u64> {
        self.events.get(account).cloned().unwrap_or_default()
    }

    pub fn kinds(&self, account: &str) -> BTreeSet<WarmUpWindowKind> {
        self.events
            .get(account)
            .map(|tickets| tickets.keys().copied().collect())
            .unwrap_or_default()
    }

    /// Note that these windows saw a reset event.
    pub fn note(&mut self, kinds: &BTreeSet<WarmUpWindowKind>, account: &str) {
        for kind in kinds {
            self.next_ticket += 1;
            self.events
                .entry(account.to_string())
                .or_default()
                .insert(*kind, self.next_ticket);
        }
    }

    /// Acknowledge only the tickets that are still current.
    pub fn acknowledge(&mut self, handled: &BTreeMap<WarmUpWindowKind, u64>, account: &str) {
        let Some(tickets) = self.events.get_mut(account) else {
            return;
        };
        for (kind, ticket) in handled {
            if tickets.get(kind) == Some(ticket) {
                tickets.remove(kind);
            }
        }
        if tickets.is_empty() {
            self.events.remove(account);
        }
    }

    pub fn remove_all(&mut self) {
        self.events.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::account::{AccountIdentity, ExecutionPreference};
    use crate::models::quota::{QuotaSourceQuality, QuotaWindowSnapshot};
    use chrono::TimeZone;

    fn at(minutes: i64) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 9, 11, 12, 0, 0)
            .single()
            .expect("valid timestamp")
            + Duration::minutes(minutes)
    }

    fn window(used_percent: f64, resets_in_minutes: Option<i64>) -> QuotaWindowSnapshot {
        QuotaWindowSnapshot {
            used_percent,
            window_duration_mins: Some(300),
            resets_at: resets_in_minutes.map(at),
        }
    }

    fn snapshot(five: Option<QuotaWindowSnapshot>, seven: Option<QuotaWindowSnapshot>) -> AccountQuotaSnapshot {
        AccountQuotaSnapshot {
            account_id: "acc-1".to_string(),
            limit_id: None,
            limit_name: None,
            five_hour: five,
            seven_day: seven,
            monthly: None,
            available_reset_credits: None,
            reset_credit_expiries: None,
            credit_balance: None,
            credit_balance_unlimited: None,
            fetched_at: at(0),
            app_server_version: None,
            quota_read_succeeded: Some(true),
            quality: QuotaSourceQuality::Official,
        }
    }

    fn warm_state(five: Option<QuotaWindowSnapshot>, seven: Option<QuotaWindowSnapshot>) -> WarmUpState {
        WarmUpState {
            snapshot: Some(snapshot(five, seven)),
            ..WarmUpState::default()
        }
    }

    fn account() -> AccountRecord {
        AccountRecord {
            identity: AccountIdentity {
                id: "acc-1".to_string(),
                label: "work".to_string(),
                masked_email: Some("a***@example.com".to_string()),
                plan_label: None,
                is_signed_in: true,
            },
            home_dir_label: "profile-a".to_string(),
            preference: ExecutionPreference::default(),
            participates_in_dispatch: true,
            order: 0,
            pinned_first: false,
            is_system_profile: false,
        }
    }

    fn subject<'a>(account: &'a AccountRecord, state: &'a WarmUpState) -> WarmUpSubject<'a> {
        WarmUpSubject::new(account, state)
    }

    fn no_unexpected() -> BTreeSet<WarmUpWindowKind> {
        BTreeSet::new()
    }

    #[test]
    fn maintenance_cadence_matches_the_product() {
        assert_eq!(maintenance_refresh_interval_secs(false, false), 1800);
        assert_eq!(maintenance_refresh_interval_secs(true, false), 600);
        assert_eq!(maintenance_refresh_interval_secs(false, true), 60);
        assert_eq!(maintenance_refresh_interval_secs(true, true), 60);
    }

    #[test]
    fn dispatch_participation_never_changes_the_selection() {
        let account = account();
        let mut opted_out = account.clone();
        opted_out.participates_in_dispatch = false;
        let state = warm_state(Some(window(0.0, Some(60))), None);

        // Both subjects select the same windows; participation is not consulted.
        assert_eq!(
            effective_selection(WarmUpSelection::ALL),
            WarmUpSelection::ALL
        );
        assert!(subject(&account, &state).participates_in_dispatch);
        assert!(!subject(&opted_out, &state).participates_in_dispatch);
    }

    #[test]
    fn a_missing_window_counts_as_idle_and_a_tiny_usage_too() {
        assert!(is_window_idle(None));
        assert!(is_window_idle(Some(&window(0.0, None))));
        assert!(is_window_idle(Some(&window(0.49, None))));
        assert!(!is_window_idle(Some(&window(0.5, None))));
        assert!(!is_window_idle(Some(&window(80.0, None))));
    }

    #[test]
    fn an_idle_window_is_never_warmed_again_inside_its_success_interval() {
        // The rule behind "a full-looking window is not warmed every minute".
        let account = account();
        let mut state = warm_state(Some(window(0.0, None)), None);
        state.last_warm_up_at = Some(at(0));
        state.last_warm_up_succeeded = Some(true);

        let next = next_date_for_kind(
            &subject(&account, &state),
            WarmUpSelection::ALL,
            WarmUpWindowKind::FiveHour,
            false,
            at(1),
        )
        .expect("a next date exists");
        // 5h interval plus the reset grace, anchored at the last success.
        assert_eq!(next, at(0) + secs(FIVE_HOUR_SUCCESS_INTERVAL_SECS + RESET_GRACE_SECS));
        assert!(!is_due(
            &subject(&account, &state),
            WarmUpSelection::ALL,
            &no_unexpected(),
            at(1)
        ));
    }

    #[test]
    fn an_idle_window_is_due_immediately_when_never_warmed() {
        let account = account();
        let state = warm_state(Some(window(0.0, None)), None);
        assert!(is_due(
            &subject(&account, &state),
            WarmUpSelection::ALL,
            &no_unexpected(),
            at(1)
        ));
    }

    #[test]
    fn a_busy_window_waits_for_its_reset_plus_grace() {
        let account = account();
        let state = warm_state(Some(window(50.0, Some(60))), None);
        let next = next_date_for_kind(
            &subject(&account, &state),
            WarmUpSelection::ALL,
            WarmUpWindowKind::FiveHour,
            false,
            at(0),
        )
        .expect("a next date exists");
        assert_eq!(next, at(60) + secs(RESET_GRACE_SECS));
    }

    #[test]
    fn a_busy_window_without_a_reset_time_stays_fail_closed() {
        let account = account();
        let state = warm_state(Some(window(50.0, None)), None);
        let five_only = WarmUpSelection {
            five_hour: true,
            seven_day: false,
        };
        assert_eq!(
            next_date_for_kind(
                &subject(&account, &state),
                five_only,
                WarmUpWindowKind::FiveHour,
                false,
                at(0),
            ),
            None
        );
        assert_eq!(
            warm_up_decision(&subject(&account, &state), five_only, &no_unexpected(), at(0)),
            WarmUpDecision::Blocked(WarmUpBlock::NoResetScheduled)
        );
    }

    #[test]
    fn an_unexpected_reset_is_due_immediately() {
        let account = account();
        let state = warm_state(Some(window(50.0, Some(60))), None);
        let mut unexpected = BTreeSet::new();
        unexpected.insert(WarmUpWindowKind::FiveHour);

        assert!(is_due(
            &subject(&account, &state),
            WarmUpSelection::ALL,
            &unexpected,
            at(0)
        ));
    }

    #[test]
    fn an_exhausted_window_blocks_the_request() {
        let account = account();
        let state = warm_state(Some(window(100.0, Some(60))), Some(window(50.0, Some(600))));

        assert!(has_exhausted_subscription_window(&state));
        assert!(!can_send_warm_up_request(&subject(&account, &state), at(0)));
        assert_eq!(
            warm_up_decision(
                &subject(&account, &state),
                WarmUpSelection::ALL,
                &no_unexpected(),
                at(0)
            ),
            WarmUpDecision::Blocked(WarmUpBlock::ExhaustedSubscriptionWindow(
                QuotaWindowKind::FiveHour
            ))
        );
    }

    #[test]
    fn stale_evidence_blocks_the_request() {
        let account = account();
        let state = warm_state(Some(window(0.0, None)), None);

        // Within the freshness window it is allowed...
        assert!(can_send_warm_up_request(&subject(&account, &state), at(10)));
        // ...past it, it is not.
        assert!(!can_send_warm_up_request(&subject(&account, &state), at(20)));
        assert_eq!(
            warm_up_decision(
                &subject(&account, &state),
                WarmUpSelection::ALL,
                &no_unexpected(),
                at(20)
            ),
            WarmUpDecision::Blocked(WarmUpBlock::NoFreshQuotaEvidence)
        );
    }

    #[test]
    fn a_later_failed_read_invalidates_otherwise_fresh_evidence() {
        let account = account();
        let mut state = warm_state(Some(window(0.0, None)), None);
        state.record_quota_read_failure(at(5));

        assert!(!has_fresh_quota_evidence(&subject(&account, &state), at(6)));
        // A failure older than the observation does not invalidate it.
        let mut state = warm_state(Some(window(0.0, None)), None);
        state.record_quota_read_failure(at(-30));
        assert!(has_fresh_quota_evidence(&subject(&account, &state), at(1)));
    }

    #[test]
    fn a_failed_read_never_reports_success_and_a_non_official_source_blocks() {
        let account = account();
        let mut state = warm_state(Some(window(0.0, None)), None);
        if let Some(snapshot) = state.snapshot.as_mut() {
            snapshot.quota_read_succeeded = Some(false);
        }
        assert!(!has_fresh_quota_evidence(&subject(&account, &state), at(1)));

        let mut state = warm_state(Some(window(0.0, None)), None);
        if let Some(snapshot) = state.snapshot.as_mut() {
            snapshot.quota_read_succeeded = None;
        }
        assert!(!has_fresh_quota_evidence(&subject(&account, &state), at(1)));
    }

    #[test]
    fn a_signed_out_account_never_warms() {
        let mut account = account();
        account.identity.is_signed_in = false;
        let state = warm_state(Some(window(0.0, None)), None);

        assert!(!can_send_warm_up_request(&subject(&account, &state), at(0)));
        assert_eq!(
            warm_up_decision(
                &subject(&account, &state),
                WarmUpSelection::ALL,
                &no_unexpected(),
                at(0)
            ),
            WarmUpDecision::Blocked(WarmUpBlock::NotSignedIn)
        );
    }

    #[test]
    fn a_disabled_selection_blocks_before_anything_else() {
        let mut account = account();
        account.identity.is_signed_in = false;
        let state = warm_state(Some(window(0.0, None)), None);

        assert_eq!(
            warm_up_decision(
                &subject(&account, &state),
                WarmUpSelection::NONE,
                &no_unexpected(),
                at(0)
            ),
            WarmUpDecision::Blocked(WarmUpBlock::Disabled)
        );
    }

    #[test]
    fn a_selected_window_with_no_data_blocks_instead_of_being_assumed_idle() {
        let account = account();
        // Only the 5h window is reported, but both windows are selected.
        let state = warm_state(Some(window(0.0, None)), None);

        assert_eq!(
            warm_up_decision(
                &subject(&account, &state),
                WarmUpSelection::ALL,
                &no_unexpected(),
                at(0)
            ),
            WarmUpDecision::Blocked(WarmUpBlock::MissingSelectedWindow(
                WarmUpWindowKind::SevenDay
            ))
        );

        // Selecting only the reported window is fine.
        let decision = warm_up_decision(
            &subject(&account, &state),
            WarmUpSelection {
                five_hour: true,
                seven_day: false,
            },
            &no_unexpected(),
            at(0),
        );
        assert_eq!(
            decision,
            WarmUpDecision::Send {
                kinds: [WarmUpWindowKind::FiveHour].into_iter().collect()
            }
        );
    }

    #[test]
    fn only_the_due_windows_are_included_in_a_send() {
        let account = account();
        // 5h idle (due now), 7d busy until +600.
        let state = warm_state(Some(window(0.0, None)), Some(window(50.0, Some(600))));

        assert_eq!(
            warm_up_decision(
                &subject(&account, &state),
                WarmUpSelection::ALL,
                &no_unexpected(),
                at(0)
            ),
            WarmUpDecision::Send {
                kinds: [WarmUpWindowKind::FiveHour].into_iter().collect()
            }
        );
    }

    #[test]
    fn a_wait_until_is_reported_when_nothing_is_due_yet() {
        let account = account();
        // Both busy; the earliest reset wins.
        let state = warm_state(Some(window(50.0, Some(600))), Some(window(50.0, Some(120))));

        assert_eq!(
            warm_up_decision(
                &subject(&account, &state),
                WarmUpSelection::ALL,
                &no_unexpected(),
                at(0)
            ),
            WarmUpDecision::WaitUntil(at(120) + secs(RESET_GRACE_SECS))
        );
    }

    #[test]
    fn an_unresolved_failure_retries_on_the_failure_interval() {
        let account = account();
        let mut state = warm_state(Some(window(0.0, None)), None);
        state.last_warm_up_at = Some(at(0));
        state.last_warm_up_succeeded = Some(false);

        assert!(has_unresolved_failure(
            &subject(&account, &state),
            WarmUpSelection::ALL
        ));
        let next = next_date_for_kind(
            &subject(&account, &state),
            WarmUpSelection::ALL,
            WarmUpWindowKind::FiveHour,
            false,
            at(1),
        )
        .expect("a retry date exists");
        assert_eq!(next, at(0) + secs(FAILURE_RETRY_INTERVAL_SECS));
    }

    #[test]
    fn a_failure_without_a_snapshot_stays_unresolved() {
        let account = account();
        let mut state = WarmUpState::default();
        state.last_warm_up_at = Some(at(0));
        state.last_warm_up_succeeded = Some(false);
        assert!(has_unresolved_failure(
            &subject(&account, &state),
            WarmUpSelection::ALL
        ));
    }

    #[test]
    fn a_fresh_observation_after_the_failure_resolves_it() {
        let account = account();
        let mut state = warm_state(Some(window(50.0, Some(60))), Some(window(50.0, Some(600))));
        state.last_warm_up_at = Some(at(-30));
        state.last_warm_up_succeeded = Some(false);
        // Both windows are busy, so nothing is idle and the failure is resolved.
        assert!(!has_unresolved_failure(
            &subject(&account, &state),
            WarmUpSelection::ALL
        ));
    }

    #[test]
    fn the_five_hour_window_yields_when_the_weekly_is_spent() {
        let account = account();
        // Weekly fully used, 5h idle.
        let state = warm_state(Some(window(0.0, None)), Some(window(100.0, Some(600))));

        assert!(should_skip_five_hour_to_protect_weekly(&subject(
            &account, &state
        )));
        // The decision is blocked anyway because a window is exhausted, which is
        // the stronger rule.
        assert_eq!(
            warm_up_decision(
                &subject(&account, &state),
                WarmUpSelection::ALL,
                &no_unexpected(),
                at(0)
            ),
            WarmUpDecision::Blocked(WarmUpBlock::ExhaustedSubscriptionWindow(
                QuotaWindowKind::SevenDay
            ))
        );
    }

    #[test]
    fn the_scheduled_reset_prefers_the_weekly_when_the_five_hour_yields() {
        let account = account();
        let state = warm_state(Some(window(0.0, Some(30))), Some(window(100.0, Some(600))));
        let next = next_scheduled_reset_date(&subject(&account, &state), WarmUpSelection::ALL, at(0))
            .expect("a scheduled reset exists");
        assert_eq!(next, at(600) + secs(RESET_GRACE_SECS));
    }

    #[test]
    fn the_quota_refresh_deadline_is_independent_of_permission_to_send() {
        let account = account();
        // Busy 5h window with a reset at +60.
        let state = warm_state(Some(window(50.0, Some(60))), None);

        assert_eq!(
            next_quota_reset_refresh_date(&subject(&account, &state), None, at(0)),
            Some(at(60) + secs(RESET_GRACE_SECS))
        );
        // An exhausted window keeps the deadline pending too.
        let state = warm_state(Some(window(100.0, Some(60))), None);
        assert!(next_quota_reset_refresh_date(&subject(&account, &state), None, at(0)).is_some());
    }

    #[test]
    fn a_missed_deadline_retries_at_a_bounded_frequency() {
        let account = account();
        // The reset is at +10 and the observation is at 0, so the deadline is
        // still pending. A later attempt at +30 lands past it, which must bound
        // the next retry to one minute after that attempt rather than dropping
        // the schedule.
        let state = warm_state(Some(window(50.0, Some(10))), None);

        let next = next_quota_reset_refresh_date(&subject(&account, &state), Some(at(30)), at(0))
            .expect("a retry exists");
        assert_eq!(next, at(30) + secs(60));
    }

    #[test]
    fn a_window_whose_deadline_already_passed_is_not_rescheduled() {
        let account = account();
        // The reset was 30 minutes before the observation, so this window is
        // already accounted for; only a fully used window keeps a deadline.
        let state = warm_state(Some(window(50.0, Some(-30))), None);
        assert_eq!(
            next_quota_reset_refresh_date(&subject(&account, &state), None, at(0)),
            None
        );

        let exhausted = warm_state(Some(window(100.0, Some(-30))), None);
        assert!(next_quota_reset_refresh_date(&subject(&account, &exhausted), None, at(0)).is_some());
    }

    #[test]
    fn a_deadline_without_a_reset_time_is_not_scheduled() {
        let account = account();
        let state = warm_state(Some(window(50.0, None)), None);
        assert_eq!(
            next_quota_reset_refresh_date(&subject(&account, &state), None, at(0)),
            None
        );
    }

    #[test]
    fn reset_detection_requires_a_previously_busy_window() {
        // An idle previous window means "never used", not "reset".
        assert!(!did_reset_unexpectedly(
            Some(&window(0.0, Some(60))),
            Some(&window(0.0, Some(60)))
        ));
        // A large drop within the same window is a reset.
        assert!(did_reset_unexpectedly(
            Some(&window(80.0, Some(60))),
            Some(&window(10.0, Some(60)))
        ));
        // Returning to idle is a reset.
        assert!(did_reset_unexpectedly(
            Some(&window(80.0, Some(60))),
            Some(&window(0.0, Some(60)))
        ));
        // A small drop is not.
        assert!(!did_reset_unexpectedly(
            Some(&window(80.0, Some(60))),
            Some(&window(75.0, Some(60)))
        ));
        // Missing data on either side is not a reset.
        assert!(!did_reset_unexpectedly(None, Some(&window(0.0, None))));
        assert!(!did_reset_unexpectedly(Some(&window(80.0, None)), None));
    }

    #[test]
    fn reset_consumption_distinguishes_a_rollover_from_a_reset() {
        // Same window with a large drop -> a credit was consumed.
        assert!(did_consume_reset(
            Some(&window(80.0, Some(60))),
            Some(&window(10.0, Some(60)))
        ));
        // Same window with a small drop -> not a credit.
        assert!(!did_consume_reset(
            Some(&window(80.0, Some(60))),
            Some(&window(75.0, Some(60)))
        ));
        // Never-used previous window -> not a credit.
        assert!(!did_consume_reset(
            Some(&window(0.0, Some(60))),
            Some(&window(0.0, Some(60)))
        ));
        // Missing reset times -> cannot tell, so no claim.
        assert!(!did_consume_reset(
            Some(&window(80.0, None)),
            Some(&window(10.0, None))
        ));
    }

    #[test]
    fn async_recheck_refuses_a_late_result_after_shutdown() {
        assert!(can_continue_after_async_check(true, true, true, true));
        assert!(!can_continue_after_async_check(false, true, true, true));
        assert!(!can_continue_after_async_check(true, false, true, true));
        assert!(!can_continue_after_async_check(true, true, false, true));
        assert!(!can_continue_after_async_check(true, true, true, false));
    }

    #[test]
    fn recording_attempts_updates_the_anchors_and_bounds_the_history() {
        let mut state = WarmUpState::default();
        for index in 0..(MAX_WARM_UP_HISTORY + 5) {
            state.record_attempt(WarmUpAttempt {
                at: at(index as i64),
                succeeded: index % 2 == 0,
                failure_reason: None,
            });
        }
        assert_eq!(state.history.len(), MAX_WARM_UP_HISTORY);
        assert_eq!(
            state.last_warm_up_at,
            Some(at((MAX_WARM_UP_HISTORY + 4) as i64))
        );
        assert_eq!(state.last_warm_up_succeeded, Some(true));
        // The oldest entries were dropped, not the newest.
        assert_eq!(state.history[0].at, at(5));
    }

    #[test]
    fn the_reset_tracker_acknowledges_only_current_tickets() {
        let mut tracker = WarmUpResetTracker::default();
        let mut kinds = BTreeSet::new();
        kinds.insert(WarmUpWindowKind::FiveHour);
        tracker.note(&kinds, "acc-1");

        let stale = tracker.ticket("acc-1");
        assert_eq!(tracker.kinds("acc-1").len(), 1);

        // A newer reset replaces the ticket, so the stale one is not honoured.
        tracker.note(&kinds, "acc-1");
        tracker.acknowledge(&stale, "acc-1");
        assert_eq!(tracker.kinds("acc-1").len(), 1);

        // The current ticket is honoured.
        let current = tracker.ticket("acc-1");
        tracker.acknowledge(&current, "acc-1");
        assert!(tracker.kinds("acc-1").is_empty());
    }

    #[test]
    fn the_reset_tracker_is_scoped_per_account() {
        let mut tracker = WarmUpResetTracker::default();
        let mut kinds = BTreeSet::new();
        kinds.insert(WarmUpWindowKind::SevenDay);
        tracker.note(&kinds, "acc-1");

        assert_eq!(tracker.kinds("acc-1").len(), 1);
        assert!(tracker.kinds("acc-2").is_empty());

        tracker.acknowledge(&tracker.ticket("acc-2"), "acc-2");
        assert_eq!(tracker.kinds("acc-1").len(), 1);

        tracker.remove_all();
        assert!(tracker.kinds("acc-1").is_empty());
    }

    #[test]
    fn warm_up_state_round_trips_through_json() {
        let mut state = warm_state(Some(window(0.0, None)), Some(window(50.0, Some(600))));
        state.last_warm_up_at = Some(at(0));
        state.last_warm_up_succeeded = Some(true);
        state.record_attempt(WarmUpAttempt {
            at: at(0),
            succeeded: true,
            failure_reason: None,
        });

        let encoded = serde_json::to_string(&state).expect("serialise");
        let decoded: WarmUpState = serde_json::from_str(&encoded).expect("deserialise");
        assert_eq!(decoded, state);
    }
}
