use super::{domain::*, fail, hash, storage::Vault, Result};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OfficialRateWindow {
    pub used_percent: f64,
    pub duration_minutes: u32,
    pub resets_at: Option<i64>,
}
impl OfficialRateWindow {
    fn valid(&self) -> bool {
        self.used_percent.is_finite()
            && (0.0..=100.0).contains(&self.used_percent)
            && self.duration_minutes > 0
            && self.resets_at.is_none_or(|v| v > 0)
    }
}
#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResetCard {
    hash: String,
    expires_at: Option<i64>,
}
impl ResetCard {
    /// IDs come from the fresh official reader; never a display index.
    pub fn from_official_id(id: &str, expires_at: Option<i64>) -> Result<Self> {
        if id.is_empty()
            || id.len() > 512
            || id.chars().any(char::is_control)
            || expires_at.is_some_and(|v| v <= 0)
        {
            return fail("invalid_reset_card");
        }
        Ok(Self {
            hash: hash(id.as_bytes()),
            expires_at,
        })
    }
}
/// Native-only input after the existing identity gate. Not a WebView request.
pub struct OfficialQuotaObservation {
    pub(crate) account_hash: String,
    pub(crate) label: String,
    pub(crate) value: Baseline,
}
#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Baseline {
    pub observed_at: i64,
    pub verified: bool,
    pub limit_hash: Option<String>,
    pub five: Option<OfficialRateWindow>,
    pub seven: Option<OfficialRateWindow>,
    pub available: Option<u32>,
    pub cards: Option<Vec<ResetCard>>,
}
impl OfficialQuotaObservation {
    /// The actual identity-verified account/rateLimits/read snapshot. This does
    /// not read auth, refresh credentials, or infer missing reset-card IDs.
    pub fn from_managed_snapshot(
        label: &str,
        snapshot: &crate::accounts::VerifiedCredentialSnapshot,
    ) -> Result<Self> {
        let q =
            crate::readers::codex_app_server::CodexAppServerQuotaSnapshot::from_rate_limit_response(
                &snapshot.official_quota,
            );
        let convert = |w: crate::models::RateWindow| -> Option<OfficialRateWindow> {
            Some(OfficialRateWindow {
                used_percent: w.used_percent,
                duration_minutes: u32::try_from(w.window_duration_mins?).ok()?,
                resets_at: w.resets_at.map(|v| v.timestamp()),
            })
        };
        let (available, cards) = parse_cards(&snapshot.official_quota).unwrap_or((None, None));
        Self::new(
            &snapshot.identity_hash,
            label,
            snapshot.observed_at,
            q.quota_read_succeeded,
            q.limit_id.as_deref(),
            q.five_hour_quota.and_then(convert),
            q.seven_day_quota.and_then(convert),
            available,
            cards,
        )
    }
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        account_id: &str,
        label: &str,
        observed_at: i64,
        identity_and_quota_verified: bool,
        limit_id: Option<&str>,
        five: Option<OfficialRateWindow>,
        seven: Option<OfficialRateWindow>,
        available: Option<u32>,
        cards: Option<Vec<ResetCard>>,
    ) -> Result<Self> {
        if account_id.is_empty()
            || account_id.len() > 512
            || account_id.chars().any(char::is_control)
            || !safe_label(label)
            || observed_at <= 0
            || five.as_ref().is_some_and(|w| !w.valid())
            || seven.as_ref().is_some_and(|w| !w.valid())
            || available.is_some_and(|n| n > 1_000_000)
            || cards.as_ref().is_some_and(|c| {
                c.len() > 1024
                    || available.is_none_or(|n| c.len() > n as usize)
                    || c.iter().map(|v| &v.hash).collect::<BTreeSet<_>>().len() != c.len()
            })
        {
            return fail("invalid_official_observation");
        }
        let limit_hash = limit_id
            .filter(|s| !s.is_empty() && s.len() <= 512 && !s.chars().any(char::is_control))
            .map(|s| hash(s.as_bytes()));
        Ok(Self {
            account_hash: hash(account_id.as_bytes()),
            label: label.into(),
            value: Baseline {
                observed_at,
                verified: identity_and_quota_verified,
                limit_hash,
                five,
                seven,
                available,
                cards,
            },
        })
    }
}
pub(crate) fn observe(
    v: &mut Vault,
    o: OfficialQuotaObservation,
    now: i64,
    thresholds: (f64, f64),
) -> Result<Vec<NotificationEvent>> {
    if now < o.value.observed_at || now - o.value.observed_at > 300 {
        return Ok(vec![]);
    }
    let previous = v.baselines.get(&o.account_hash).cloned();
    if let Some(p) = &previous {
        if o.value.observed_at < p.observed_at {
            return Ok(vec![]);
        }
        if o.value.observed_at == p.observed_at && o.value != *p {
            let mut invalid = o.value;
            invalid.verified = false;
            v.baselines.insert(o.account_hash, invalid);
            return Ok(vec![]);
        }
    }
    if v.baselines.len() >= 512 && !v.baselines.contains_key(&o.account_hash) {
        return fail("notification_store_capacity");
    }
    let current = &o.value;
    v.baselines.insert(o.account_hash.clone(), current.clone());
    if !current.verified {
        return Ok(vec![]);
    }
    let mut events = Vec::new();
    let mut push = |kind: &str, body: EventBody| -> Result<()> {
        let mut event = NotificationEvent::new(
            &format!("{}:{kind}:{}", o.account_hash, current.observed_at),
            Some(&o.label),
            body,
            current.observed_at,
        )?;
        event.proof = Some((o.account_hash.clone(), current.observed_at));
        event.facts = Some((
            current.five.as_ref().and_then(|w| w.resets_at),
            current.seven.as_ref().and_then(|w| w.resets_at),
            current.available,
        ));
        events.push(event);
        Ok(())
    };
    // Fresh official low quota, never an absent window interpreted as 100%.
    let f = current.five.as_ref().map(|w| 100.0 - w.used_percent);
    let s = current.seven.as_ref().map(|w| 100.0 - w.used_percent);
    let old_f = previous
        .as_ref()
        .filter(|p| {
            p.verified
                && current.observed_at - p.observed_at <= 2700
                && p.limit_hash == current.limit_hash
        })
        .and_then(|p| p.five.as_ref())
        .map(|w| 100.0 - w.used_percent);
    let old_s = previous
        .as_ref()
        .filter(|p| {
            p.verified
                && current.observed_at - p.observed_at <= 2700
                && p.limit_hash == current.limit_hash
        })
        .and_then(|p| p.seven.as_ref())
        .map(|w| 100.0 - w.used_percent);
    if now - current.observed_at <= 60
        && ((f.is_some_and(|n| n <= thresholds.0) && old_f.is_none_or(|n| n > thresholds.0))
            || (s.is_some_and(|n| n <= thresholds.1) && old_s.is_none_or(|n| n > thresholds.1)))
    {
        push("low", EventBody::LowQuota { five: f, seven: s })?;
    }
    if let Some(p) = previous.as_ref().filter(|p| {
        p.verified
            && current.observed_at > p.observed_at
            && current.observed_at - p.observed_at <= 2700
            && p.limit_hash.is_some()
            && p.limit_hash == current.limit_hash
    }) {
        if now - current.observed_at <= 60 {
            let five = reset(p.five.as_ref(), current.five.as_ref(), now);
            let seven = reset(p.seven.as_ref(), current.seven.as_ref(), now);
            if five || seven {
                push("quota-reset", EventBody::QuotaReset { five, seven })?;
            }
        }
    }
    // Reset-card history is account scoped, independent of the period-limit
    // bucket. Mac's durable change receipts compare known official counts even
    // when a period limit ID is absent or changes.
    if let Some(p) = previous.filter(|p| p.verified && current.observed_at > p.observed_at) {
        if let (Some(before), Some(after)) = (p.available, current.available) {
            if before != after {
                push(
                    "cards-change",
                    EventBody::CardsChanged {
                        previous: before,
                        available: after,
                        previous_at: p.observed_at,
                    },
                )?;
            }
        }
    }
    if let (Some(available), Some(cards)) = (current.available, &current.cards) {
        let mut batches = BTreeMap::<i64, u32>::new();
        let mut keys = Vec::new();
        let mut expiry_items = Vec::new();
        let mut known = 0u32;
        for card in cards {
            if let Some(expiry) = card.expires_at {
                known += 1;
                if expiry > now && expiry - now <= 86400 {
                    *batches.entry(expiry).or_default() += 1;
                    let key = hash(format!("{}:{}:{expiry}", o.account_hash, card.hash).as_bytes());
                    keys.push(key.clone());
                    expiry_items.push((key, expiry));
                }
            }
        }
        if !keys.is_empty() {
            let mut event = NotificationEvent::new(
                &format!("{}:cards-expiry", o.account_hash),
                Some(&o.label),
                EventBody::CardsExpiring {
                    batches: batches.into_iter().collect(),
                    available,
                    unknown_expiry: available.saturating_sub(known),
                },
                current.observed_at,
            )?;
            event.keys = keys;
            event.expiry_items = Some(expiry_items);
            event.proof = Some((o.account_hash, current.observed_at));
            events.push(event);
        }
    }
    Ok(events)
}
fn parse_cards(v: &serde_json::Value) -> Option<(Option<u32>, Option<Vec<ResetCard>>)> {
    let Some(reset) = v.get("rateLimitResetCredits") else {
        return Some((None, None));
    };
    let available = u32::try_from(reset["availableCount"].as_u64()?)
        .ok()
        .filter(|n| *n <= 1_000_000)?;
    let Some(rows) = reset.get("credits").filter(|v| !v.is_null()) else {
        return Some((Some(available), None));
    };
    let rows = rows.as_array()?;
    if rows.len() > 1024 {
        return None;
    }
    let mut seen = BTreeSet::new();
    let mut cards = Vec::new();
    for row in rows {
        let id = row["id"].as_str()?;
        if id.is_empty() || id.len() > 512 || id.chars().any(char::is_control) || !seen.insert(id) {
            return None;
        }
        let status = row["status"].as_str()?;
        let kind = row["resetType"].as_str()?;
        let expiry = match row.get("expiresAt") {
            None | Some(serde_json::Value::Null) => None,
            Some(v) => Some(v.as_i64()?),
        };
        if status == "available" && kind == "codexRateLimits" {
            cards.push(ResetCard::from_official_id(id, expiry).ok()?);
        }
    }
    if cards.len() > available as usize {
        return None;
    }
    Some((Some(available), Some(cards)))
}
fn reset(p: Option<&OfficialRateWindow>, c: Option<&OfficialRateWindow>, now: i64) -> bool {
    let (Some(p), Some(c)) = (p, c) else {
        return false;
    };
    let Some(pr) = p.resets_at else { return false };
    if p.duration_minutes != c.duration_minutes {
        return false;
    }
    if c.resets_at
        .is_some_and(|cr| pr <= now && cr > now && cr - pr > 120)
    {
        return true;
    }
    p.used_percent >= 1.0
        && ((c.used_percent < 0.5 && pr <= now) || c.used_percent + 8.0 <= p.used_percent)
}
