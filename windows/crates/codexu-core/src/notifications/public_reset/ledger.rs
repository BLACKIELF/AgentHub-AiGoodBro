use super::{
    super::{fail, ChannelKind, Result},
    models::*,
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Phase {
    Baseline,
    Pending,
    Sending,
    Sent,
    Uncertain,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) enum Payload {
    Completed(Announcement),
    Forecast(Forecast),
}
impl Payload {
    pub fn id(&self) -> &str {
        match self {
            Self::Completed(a) => &a.id,
            Self::Forecast(f) => &f.id,
        }
    }
    pub fn at(&self) -> i64 {
        match self {
            Self::Completed(a) => a.at,
            Self::Forecast(f) => f.at,
        }
    }
    pub fn valid(&self, now: i64) -> bool {
        match self {
            Self::Completed(a) => a.valid(now),
            Self::Forecast(f) => f.valid(now),
        }
    }
    pub fn safe(&self) -> Self {
        match self {
            Self::Completed(a) => Self::Completed(a.safe()),
            Self::Forecast(f) => Self::Forecast(f.clone()),
        }
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Record {
    pub payload: Payload,
    pub phase: Phase,
}
#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Ledger {
    pub initialized: bool,
    pub records: BTreeMap<String, Record>,
    pub newest: Option<i64>,
    pub retired_through: Option<i64>,
}
impl Ledger {
    pub fn valid(&self, now: i64) -> bool {
        self.records.len() <= 500
            && self
                .records
                .iter()
                .all(|(id, r)| id == r.payload.id() && r.payload.valid(now))
    }
    pub fn recover(&mut self) {
        for r in self.records.values_mut() {
            if r.phase == Phase::Sending {
                r.phase = Phase::Uncertain;
            }
        }
    }
    pub fn observe_history(&mut self, page: &Page, baseline: bool) -> Result<()> {
        let ids = page
            .rows
            .iter()
            .map(|a| a.id.as_str())
            .collect::<BTreeSet<_>>();
        if self.initialized
            && !baseline
            && page.has_more
            && self.records.keys().all(|id| !ids.contains(id.as_str()))
        {
            return fail("public_reset_history_gap");
        }
        let mut ordered = page.rows.iter().collect::<Vec<_>>();
        ordered.sort_by_key(|a| (a.at, &a.id));
        for a in ordered {
            self.observe(Payload::Completed(a.clone()), baseline)?;
        }
        self.initialized = true;
        self.compact()
    }
    pub fn observe(&mut self, p: Payload, baseline: bool) -> Result<()> {
        let id = p.id().to_owned();
        if let Some(existing) = self.records.get_mut(&id) {
            if existing.payload.at() != p.at()
                || match (&existing.payload, &p) {
                    (Payload::Completed(a), Payload::Completed(b)) => {
                        a.banked != b.banked || a.source != b.source
                    }
                    (Payload::Forecast(a), Payload::Forecast(b)) => a.source_url != b.source_url,
                    _ => true,
                }
            {
                return fail("public_reset_source_changed");
            }
            if existing.phase == Phase::Pending {
                existing.payload = p.safe();
            }
            return Ok(());
        }
        if self.retired_through.is_some_and(|at| p.at() <= at) {
            return Ok(());
        }
        let phase = if !self.initialized || baseline || self.newest.is_some_and(|at| p.at() < at) {
            Phase::Baseline
        } else {
            Phase::Pending
        };
        self.newest = Some(self.newest.unwrap_or(p.at()).max(p.at()));
        self.records.insert(
            id,
            Record {
                payload: p.safe(),
                phase,
            },
        );
        self.compact()
    }
    fn compact(&mut self) -> Result<()> {
        if self.records.len() > 500 {
            let mut completed = self
                .records
                .iter()
                .filter(|(_, r)| matches!(r.phase, Phase::Baseline | Phase::Sent))
                .map(|(id, r)| (r.payload.at(), id.clone()))
                .collect::<Vec<_>>();
            completed.sort();
            for (at, id) in completed {
                if self.records.len() <= 500 {
                    break;
                }
                self.records.remove(&id);
                self.retired_through = Some(self.retired_through.unwrap_or(at).max(at));
            }
        }
        if self.records.len() > 500 {
            return fail("public_reset_queue_full");
        }
        Ok(())
    }
    pub fn recovery_ids(&self) -> BTreeSet<String> {
        self.records
            .iter()
            .filter(|(_, r)| {
                r.phase == Phase::Pending && matches!(&r.payload, Payload::Completed(_))
            })
            .map(|(id, _)| id.clone())
            .collect()
    }
    pub fn hydrate(&mut self, rows: &[Announcement]) -> Result<()> {
        for a in rows.iter().filter(|a| a.has_text()) {
            if let Some(r) = self.records.get_mut(&a.id) {
                if r.phase == Phase::Pending {
                    let Payload::Completed(old) = &r.payload else {
                        return fail("public_reset_source_changed");
                    };
                    if old.at != a.at || old.banked != a.banked || old.source != a.source {
                        return fail("public_reset_source_changed");
                    }
                    r.payload = Payload::Completed(a.safe());
                }
            }
        }
        Ok(())
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Checkpoint {
    pub cursor: String,
    pub oldest: Option<i64>,
    pub recent: Vec<String>,
}
impl Checkpoint {
    pub fn valid(&self) -> bool {
        cursor_valid(&self.cursor)
            && self.recent.len() <= 16
            && self.recent.iter().all(|c| cursor_valid(c))
    }
}
#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PublicData {
    pub enabled: bool,
    pub revision: u64,
    pub rebase: bool,
    pub not_before: i64,
    pub completed: BTreeMap<ChannelKind, Ledger>,
    pub forecast: Ledger,
    pub checkpoint: Option<Checkpoint>,
    #[serde(default)]
    pub checked_at: Option<i64>,
    #[serde(default)]
    pub cached_forecast: Option<Forecast>,
    #[serde(default)]
    pub cached_latest: Option<Announcement>,
}
impl PublicData {
    pub fn valid(&self, now: i64) -> bool {
        self.completed.len() <= 5
            && self.completed.values().all(|l| l.valid(now))
            && self.forecast.valid(now)
            && self.checkpoint.as_ref().is_none_or(Checkpoint::valid)
            && self.cached_forecast.as_ref().is_none_or(|f| f.valid(now))
            && self.cached_latest.as_ref().is_none_or(|a| a.valid(now))
            && self
                .checked_at
                .is_none_or(|at| at > 0 && at <= now + 300000)
    }
    pub fn recover(&mut self) {
        for l in self.completed.values_mut() {
            l.recover();
        }
        self.forecast.recover();
    }
    pub fn has_sending(&self) -> bool {
        self.completed
            .values()
            .any(|l| l.records.values().any(|r| r.phase == Phase::Sending))
            || self
                .forecast
                .records
                .values()
                .any(|r| r.phase == Phase::Sending)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn payload(i: i64) -> Payload {
        Payload::Completed(Announcement {
            id: format!("observed-{i}"),
            banked: false,
            at: 1_800_000_000_000 + i,
            text: "Synthetic public statement".into(),
            source: Source {
                kind: "observed".into(),
                author: None,
                url: None,
            },
        })
    }
    #[test]
    fn public_ledger_compacts_only_terminal_rows_and_never_replays_retired_ids() {
        let mut l = Ledger::default();
        for i in 0..501 {
            l.observe(payload(i), true).unwrap();
        }
        l.initialized = true;
        assert_eq!(l.records.len(), 500);
        assert_eq!(l.retired_through, Some(payload(0).at()));
        l.observe(payload(0), false).unwrap();
        assert!(!l.records.contains_key("observed-0"));
        l.observe(payload(501), false).unwrap();
        assert!(l.records["observed-501"].phase == Phase::Pending);
    }
    #[test]
    fn public_ledger_pending_or_uncertain_rows_are_not_discardable_capacity() {
        let mut l = Ledger {
            initialized: true,
            ..Default::default()
        };
        for i in 0..500 {
            l.observe(payload(i), false).unwrap();
        }
        l.records.get_mut("observed-0").unwrap().phase = Phase::Uncertain;
        assert_eq!(
            l.observe(payload(500), false).err().unwrap().code(),
            "public_reset_queue_full"
        );
        assert!(l.records.contains_key("observed-0"));
        assert!(l.records["observed-0"].phase == Phase::Uncertain);
    }
    #[test]
    fn public_ledger_sending_recovery_is_uncertain_but_pending_is_retained() {
        let mut l = Ledger {
            initialized: true,
            ..Default::default()
        };
        l.observe(payload(0), false).unwrap();
        l.observe(payload(1), false).unwrap();
        l.records.get_mut("observed-0").unwrap().phase = Phase::Sending;
        l.recover();
        assert!(l.records["observed-0"].phase == Phase::Uncertain);
        assert!(l.records["observed-1"].phase == Phase::Pending);
    }
}
