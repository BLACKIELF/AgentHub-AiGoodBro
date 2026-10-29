//! Memory-only receipts from existing explicit quota reads. Never a login,
//! scheduling or notification authority; no collector, filesystem or network I/O.
use crate::compact_ui::cache::{Account, QuotaWindow};
use codexu_core::profiles::LinkedProfile;
use std::collections::BTreeMap;

#[derive(Clone, Debug)]
pub(crate) struct Reading {
    pub observed_at: i64,
    pub available: bool,
    pub reason: Option<String>,
    pub plan: Option<String>,
    pub windows: Vec<QuotaWindow>,
    pub usd: Option<f64>,
    pub points: Option<String>,
    pub reset_cards: Option<u32>,
}
#[derive(Clone)]
struct Entry {
    profile: LinkedProfile,
    sequence: u64,
    last_success: Option<Reading>,
    last_attempt: Option<Reading>,
    failure: Option<String>,
}
#[derive(Default)]
pub(crate) struct LinkedQuotaDisplayCache {
    sequence: u64,
    entries: BTreeMap<u64, Entry>,
}
impl LinkedQuotaDisplayCache {
    pub fn begin(&mut self, profile: &LinkedProfile, catalog: &[LinkedProfile]) -> Option<u64> {
        self.entries.retain(|id, entry| {
            catalog
                .iter()
                .any(|p| *id == p.id && same_source(p, &entry.profile))
        });
        self.sequence = self.sequence.checked_add(1)?;
        let sequence = self.sequence;
        let entry = self.entries.entry(profile.id).or_insert_with(|| Entry {
            profile: profile.clone(),
            sequence,
            last_success: None,
            last_attempt: None,
            failure: None,
        });
        entry.profile = profile.clone();
        entry.sequence = sequence;
        Some(sequence)
    }
    pub fn finish(
        &mut self,
        profile: &LinkedProfile,
        sequence: u64,
        result: Result<Reading, &str>,
    ) {
        let Some(entry) = self
            .entries
            .get_mut(&profile.id)
            .filter(|e| e.sequence == sequence && same_source(profile, &e.profile))
        else {
            return;
        };
        match result {
            Ok(reading) => {
                if reading.available {
                    entry.last_success = Some(reading.clone());
                }
                entry.failure = reading.reason.clone();
                entry.last_attempt = Some(reading);
            }
            Err(code) => entry.failure = Some(code.to_owned()),
        }
    }
    pub fn project(&self, profiles: &[LinkedProfile], now: i64) -> Vec<Account> {
        profiles
            .iter()
            .map(|profile| {
                let entry = self
                    .entries
                    .get(&profile.id)
                    .filter(|e| same_source(profile, &e.profile));
                let latest = entry.and_then(|e| e.last_attempt.as_ref());
                let previous = entry.and_then(|e| e.last_success.as_ref());
                let reading = latest.filter(|r| r.available).or(previous).or(latest);
                let failure = entry.and_then(|e| e.failure.clone()).or_else(|| {
                    latest
                        .filter(|r| !r.available)
                        .map(|_| "quota_unavailable".into())
                });
                let available = failure.is_none() && reading.is_some_and(|r| current(r, now));
                Account {
                    id: format!("linked-{}", profile.id),
                    provider_id: profile.kind.id().to_owned(),
                    label: profile.label.clone(),
                    logged_in: available,
                    active: None,
                    observed_at: reading.map(|r| r.observed_at),
                    available,
                    reason_code: failure.or_else(|| {
                        (!available).then(|| {
                            if reading.is_some() {
                                "quota_stale"
                            } else {
                                "quota_not_read"
                            }
                            .into()
                        })
                    }),
                    plan_type: reading.and_then(|r| r.plan.clone()),
                    windows: reading.map(|r| r.windows.clone()).unwrap_or_default(),
                    credits_usd: reading.and_then(|r| r.usd),
                    credit_points: reading.and_then(|r| r.points.clone()),
                    reset_cards: reading.and_then(|r| r.reset_cards),
                }
            })
            .collect()
    }
}
fn same_source(a: &LinkedProfile, b: &LinkedProfile) -> bool {
    a.id == b.id && a.kind == b.kind && a.root == b.root
}
/// Existing main-window quota display contract (300 seconds), not a new poll.
pub(crate) fn current(reading: &Reading, now: i64) -> bool {
    let dated: Vec<_> = reading.windows.iter().filter_map(|w| w.resets_at).collect();
    reading.available
        && reading.observed_at > 0
        && now >= reading.observed_at
        && now - reading.observed_at < 300_000
        && (dated.is_empty() || dated.iter().any(|at| *at > now))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn profile(id: u64) -> LinkedProfile {
        LinkedProfile {
            id,
            label: "Synthetic alias".into(),
            root: format!("/synthetic/{id}").into(),
            kind: codexu_core::local_cli::LocalCliKind::Codex,
        }
    }
    fn reading(at: i64, used: f64) -> Reading {
        Reading {
            observed_at: at,
            available: true,
            reason: None,
            plan: None,
            windows: vec![QuotaWindow {
                id: "seven_day".into(),
                label: "7d".into(),
                used_percent: Some(used),
                resets_at: None,
            }],
            usd: None,
            points: None,
            reset_cards: None,
        }
    }
    #[test]
    fn late_read_cannot_replace_newer_attempt_or_retargeted_directory() {
        let mut cache = LinkedQuotaDisplayCache::default();
        let p = profile(1);
        let first = cache.begin(&p, &[p.clone()]).unwrap();
        let second = cache.begin(&p, &[p.clone()]).unwrap();
        cache.finish(&p, second, Ok(reading(1000, 20.)));
        cache.finish(&p, first, Ok(reading(1001, 80.)));
        assert_eq!(
            cache.project(&[p.clone()], 1002)[0].windows[0].used_percent,
            Some(20.)
        );
        let mut moved = p.clone();
        moved.root = "/synthetic/different".into();
        assert!(cache.project(&[moved.clone()], 1002)[0].windows.is_empty());
        cache.begin(&moved, &[moved.clone()]).unwrap();
        cache.finish(&p, second, Ok(reading(1003, 90.)));
        assert!(cache.project(&[moved], 1004)[0].windows.is_empty());
    }
    #[test]
    fn failure_keeps_history_but_never_current_quota_or_login_proof() {
        let mut cache = LinkedQuotaDisplayCache::default();
        let p = profile(1);
        let seq = cache.begin(&p, &[p.clone()]).unwrap();
        cache.finish(&p, seq, Ok(reading(1000, 20.)));
        let seq = cache.begin(&p, &[p.clone()]).unwrap();
        cache.finish(&p, seq, Err("quota_read_failed"));
        let row = cache.project(&[p], 1002).remove(0);
        assert!(!row.available && !row.logged_in);
        assert_eq!(row.observed_at, Some(1000));
        assert_eq!(row.windows[0].used_percent, Some(20.));
        assert_eq!(row.reason_code.as_deref(), Some("quota_read_failed"));
    }
    #[test]
    fn unknown_expired_clock_and_reset_values_never_become_zero_or_live() {
        let p = profile(1);
        let mut cache = LinkedQuotaDisplayCache::default();
        let row = cache.project(&[p.clone()], 1000).remove(0);
        assert!(row.windows.is_empty() && row.observed_at.is_none() && !row.available);
        let mut r = reading(1000, 0.);
        assert!(!current(&r, 999));
        assert!(!current(&r, 301000));
        assert!(current(&r, 1001));
        r.windows[0].resets_at = Some(1001);
        assert!(!current(&r, 1001));
        let seq = cache.begin(&p, &[p.clone()]).unwrap();
        cache.finish(&p, seq, Ok(r));
        assert_eq!(
            cache.project(&[p], 1001)[0].windows[0].used_percent,
            Some(0.)
        );
    }
}
