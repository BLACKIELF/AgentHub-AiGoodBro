use super::{ledger::*, models::*, source::*};
use crate::notifications::{
    self,
    domain::{EventBody, NotificationEvent},
    service::NotificationService,
    ChannelKind, Failure, Result,
};
use serde::Serialize;
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};
type Control<'a> = Option<(&'a AtomicBool, &'a Mutex<Option<Arc<AtomicBool>>>)>;
fn now() -> i64 {
    chrono::Utc::now().timestamp_millis()
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PublicResetAnnouncementDto {
    pub id: String,
    pub kind: &'static str,
    pub announced_at: i64,
    pub text: String,
    pub source_url: Option<String>,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PublicResetForecastDto {
    pub id: String,
    pub announced_at: i64,
    pub latest_by: Option<i64>,
    pub fetched_at: i64,
    pub source_url: String,
    pub phase: &'static str,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PublicResetDeliveryState {
    pub enabled: bool,
    pub phase: &'static str,
    pub checked_at: Option<i64>,
    pub next_check_at: Option<i64>,
    pub failure_code: Option<&'static str>,
    pub forecast: Option<PublicResetForecastDto>,
    pub latest: Option<PublicResetAnnouncementDto>,
    pub pending_count: usize,
    pub uncertain_count: usize,
}
#[derive(Default)]
pub(crate) struct View {
    checked: Option<i64>,
    forecast: Option<Forecast>,
    latest: Option<Announcement>,
    failure: Option<&'static str>,
}
impl NotificationService {
    pub fn public_reset_delivery_state(&self) -> Result<PublicResetDeliveryState> {
        let data = self.storage.read(|v| Ok(v.public_reset.clone()))?;
        let view = self
            .public_runtime
            .view
            .lock()
            .map_err(|_| Failure("public_reset_state_unavailable"))?;
        let now = now();
        let checked = view.checked.or(data.checked_at);
        let cached_forecast = view.forecast.as_ref().or(data.cached_forecast.as_ref());
        let cached_latest = view.latest.as_ref().or(data.cached_latest.as_ref());
        let records = data
            .completed
            .values()
            .flat_map(|l| l.records.values())
            .chain(data.forecast.records.values())
            .collect::<Vec<_>>();
        Ok(PublicResetDeliveryState {
            enabled: data.enabled,
            phase: if self.public_runtime.checking.load(Ordering::Acquire) {
                "checking"
            } else if !data.enabled {
                "disabled"
            } else if view.failure.is_some() {
                "unavailable"
            } else if self.public_runtime.requested.load(Ordering::Acquire) {
                "queued"
            } else if checked.is_some() {
                "observing"
            } else {
                "needs_baseline"
            },
            checked_at: checked,
            next_check_at: data.enabled.then(|| {
                self.public_runtime
                    .next_check
                    .load(Ordering::Acquire)
                    .max(data.not_before)
            }),
            failure_code: view.failure,
            forecast: cached_forecast
                .filter(|f| f.fetched_at >= now - 72 * 3600000)
                .map(|f| PublicResetForecastDto {
                    id: f.id.clone(),
                    announced_at: f.at,
                    latest_by: f.latest_by,
                    fetched_at: f.fetched_at,
                    source_url: f.source_url.clone(),
                    phase: if f.latest_by.is_some_and(|at| at > now) {
                        "scheduled"
                    } else {
                        "awaiting_confirmation"
                    },
                }),
            latest: cached_latest.map(|a| PublicResetAnnouncementDto {
                id: a.id.clone(),
                kind: if a.banked { "banked" } else { "regular" },
                announced_at: a.at,
                text: a.safe().text,
                source_url: a.source.url.clone(),
            }),
            pending_count: records.iter().filter(|r| r.phase == Phase::Pending).count(),
            uncertain_count: records
                .iter()
                .filter(|r| matches!(r.phase, Phase::Sending | Phase::Uncertain))
                .count(),
        })
    }
    pub fn set_public_reset_delivery_enabled(
        &self,
        enabled: bool,
    ) -> Result<PublicResetDeliveryState> {
        if self.exiting.load(Ordering::Acquire) {
            return Err(Failure("notification_exiting"));
        }
        self.storage.change(|v| {
            let d = &mut v.public_reset;
            if enabled && !d.enabled {
                d.rebase = true;
            }
            d.enabled = enabled;
            d.revision = d
                .revision
                .checked_add(1)
                .ok_or(Failure("public_reset_state_unavailable"))?;
            Ok(())
        })?;
        self.cancel_public_sends();
        self.public_runtime
            .requested
            .store(enabled, Ordering::Release);
        self.public_runtime.next_check.store(0, Ordering::Release);
        self.wake.1.notify_all();
        self.public_reset_delivery_state()
    }
    pub fn request_public_reset_check(&self) -> Result<PublicResetDeliveryState> {
        if self.exiting.load(Ordering::Acquire) {
            return Err(Failure("notification_exiting"));
        }
        self.public_runtime.requested.store(true, Ordering::Release);
        self.wake.1.notify_all();
        self.public_reset_delivery_state()
    }
    fn public_current(&self, revision: u64, enabled: bool, cancel: &AtomicBool) -> Result<()> {
        if cancel.load(Ordering::Acquire) || self.exiting.load(Ordering::Acquire) {
            return Err(Failure("cancelled"));
        }
        self.storage.read(|v| {
            if v.public_reset.revision == revision && v.public_reset.enabled == enabled {
                Ok(())
            } else {
                Err(Failure("configuration_changed"))
            }
        })
    }
    pub(crate) fn public_reset_tick(self: &Arc<Self>, control: Control<'_>) -> Result<bool> {
        let d = self.storage.read(|v| Ok(v.public_reset.clone()))?;
        let requested = self.public_runtime.requested.swap(false, Ordering::AcqRel);
        if !requested
            && (!d.enabled
                || now()
                    < self
                        .public_runtime
                        .next_check
                        .load(Ordering::Acquire)
                        .max(d.not_before))
        {
            return Ok(false);
        }
        if now() < d.not_before {
            return Ok(false);
        }
        self.public_check(control)?;
        Ok(true)
    }
    /// Worker/test entry; UI commands enqueue a request instead of waiting for
    /// network or submitting arbitrary text/source rows.
    pub fn check_public_reset_now(self: &Arc<Self>) -> Result<PublicResetDeliveryState> {
        self.public_check(None)?;
        self.public_reset_delivery_state()
    }
    fn public_check(self: &Arc<Self>, control: Control<'_>) -> Result<()> {
        if self
            .public_runtime
            .checking
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(Failure("public_reset_busy"));
        }
        struct Reset<'a>(&'a AtomicBool);
        impl Drop for Reset<'_> {
            fn drop(&mut self) {
                self.0.store(false, Ordering::Release);
            }
        }
        let _reset = Reset(&self.public_runtime.checking);
        let data = self.storage.read(|v| Ok(v.public_reset.clone()))?;
        let cancel = Arc::new(AtomicBool::new(false));
        *self
            .public_runtime
            .active
            .lock()
            .map_err(|_| Failure("public_reset_busy"))? = Some(cancel.clone());
        if let Some((stop, active)) = control {
            *active.lock().map_err(|_| Failure("public_reset_busy"))? = Some(cancel.clone());
            if stop.load(Ordering::Acquire) {
                cancel.store(true, Ordering::Release);
            }
        }
        let result = self.public_check_body(&data, &cancel, control);
        self.public_runtime
            .next_check
            .store(now() + 300000, Ordering::Release);
        if let Err(e) = result {
            if self
                .public_current(data.revision, data.enabled, &cancel)
                .is_ok()
            {
                if let Ok(mut view) = self.public_runtime.view.lock() {
                    view.failure = Some(e.0);
                }
            }
            return Err(e);
        }
        Ok(())
    }
    fn fetch_public(
        &self,
        request: PublicResetRequest,
        revision: u64,
        enabled: bool,
        cancel: &AtomicBool,
    ) -> Result<Vec<u8>> {
        self.public_current(revision, enabled, cancel)?;
        let source = self
            .public_runtime
            .source
            .read()
            .map_err(|_| Failure("public_reset_source_unavailable"))?
            .clone();
        let response = source.fetch(&request, cancel)?;
        self.public_current(revision, enabled, cancel)?;
        if response.status == 429 {
            let seconds = response
                .retry_after
                .as_deref()
                .and_then(|s| s.parse::<u64>().ok())
                .unwrap_or(900)
                .clamp(300, 86400);
            self.storage.change(|v| {
                if v.public_reset.revision != revision {
                    return Err(Failure("configuration_changed"));
                }
                v.public_reset.not_before = now() + seconds as i64 * 1000;
                Ok(())
            })?;
            return Err(Failure("public_reset_rate_limited"));
        }
        if response.status != 200 || response.body.len() > request.limit() {
            return Err(Failure(if (300..400).contains(&response.status) {
                "redirected"
            } else {
                "public_reset_source_unavailable"
            }));
        }
        if matches!(request, PublicResetRequest::History { .. })
            && !response.content_type.as_deref().is_some_and(|s| {
                s.split(';')
                    .next()
                    .unwrap_or("")
                    .trim()
                    .eq_ignore_ascii_case("application/json")
            })
        {
            return Err(Failure("public_reset_invalid_response"));
        }
        Ok(response.body)
    }
    fn public_check_body(
        self: &Arc<Self>,
        data: &PublicData,
        cancel: &AtomicBool,
        control: Control<'_>,
    ) -> Result<()> {
        if now() < data.not_before {
            return Err(Failure("public_reset_rate_limited"));
        }
        let head = page(
            &self.fetch_public(
                PublicResetRequest::History { cursor: None },
                data.revision,
                data.enabled,
                cancel,
            )?,
            now(),
        )?;
        let forecast_result = self
            .fetch_public(
                PublicResetRequest::Forecast,
                data.revision,
                data.enabled,
                cancel,
            )
            .and_then(|bytes| forecast(&bytes, now()));
        self.public_current(data.revision, data.enabled, cancel)?;
        let channels = self.storage.read(|v| {
            Ok(v.configs
                .iter()
                .filter(|(_, c)| c.enabled && c.secret.is_some() && !c.session_expired)
                .map(|(k, c)| (*k, c.revision))
                .collect::<BTreeMap<_, _>>())
        })?;
        let mut rows = head.rows.clone();
        let head_ids = head
            .rows
            .iter()
            .map(|a| a.id.clone())
            .collect::<BTreeSet<_>>();
        let ledgers = channels
            .keys()
            .filter_map(|kind| data.completed.get(kind))
            .collect::<Vec<_>>();
        let missing = ledgers
            .iter()
            .flat_map(|l| l.recovery_ids())
            .collect::<BTreeSet<_>>();
        let needs = ledgers.iter().any(|l| {
            !l.recovery_ids().is_subset(&head_ids)
                || (l.initialized
                    && !l.records.is_empty()
                    && head.has_more
                    && l.records.keys().all(|id| !head_ids.contains(id)))
        });
        let saved = if data.rebase {
            None
        } else {
            data.checkpoint.clone()
        };
        let mut cursor = if needs {
            saved
                .as_ref()
                .map(|c| c.cursor.clone())
                .or(head.cursor.clone())
        } else {
            None
        };
        let mut oldest = saved
            .as_ref()
            .and_then(|c| c.oldest)
            .or_else(|| rows.iter().map(|a| a.at).min());
        let mut recent = saved.as_ref().map(|c| c.recent.clone()).unwrap_or_default();
        let mut last = head.clone();
        let mut checkpoint = saved.clone();
        let mut recovery_error = None;
        let deadline = Instant::now() + Duration::from_secs(30);
        for _ in 0..4 {
            let ids = rows.iter().map(|a| a.id.clone()).collect::<BTreeSet<_>>();
            let overlaps = ledgers.iter().all(|l| {
                !l.initialized
                    || l.records.is_empty()
                    || l.records.keys().any(|id| ids.contains(id))
            });
            if missing.is_subset(&ids) && overlaps {
                checkpoint = None;
                break;
            }
            let Some(next) = cursor.clone() else { break };
            if Instant::now() >= deadline {
                break;
            }
            if recent.contains(&next) {
                recovery_error = Some("public_reset_invalid_response");
                checkpoint = None;
                break;
            }
            let fetched = self
                .fetch_public(
                    PublicResetRequest::History {
                        cursor: Some(next.clone()),
                    },
                    data.revision,
                    data.enabled,
                    cancel,
                )
                .and_then(|bytes| page(&bytes, now()));
            match fetched {
                Ok(p) => {
                    if rows.len() + p.rows.len() > 500
                        || p.rows.iter().any(|a| ids.contains(&a.id))
                        || p.rows
                            .iter()
                            .map(|a| a.at)
                            .max()
                            .is_some_and(|at| oldest.is_some_and(|old| at > old))
                    {
                        recovery_error = Some("public_reset_invalid_response");
                        checkpoint = Some(Checkpoint {
                            cursor: next,
                            oldest,
                            recent,
                        });
                        break;
                    }
                    oldest = p.rows.iter().map(|a| a.at).min().or(oldest);
                    rows.extend(p.rows.clone());
                    recent.push(next);
                    if recent.len() > 16 {
                        recent.remove(0);
                    }
                    cursor = if p.has_more { p.cursor.clone() } else { None };
                    checkpoint = cursor.as_ref().map(|c| Checkpoint {
                        cursor: c.clone(),
                        oldest,
                        recent: recent.clone(),
                    });
                    last = p;
                }
                Err(e) => {
                    recovery_error = Some(e.0);
                    checkpoint = Some(Checkpoint {
                        cursor: next,
                        oldest,
                        recent,
                    });
                    break;
                }
            }
        }
        let recovered_ids = rows.iter().map(|a| a.id.clone()).collect::<BTreeSet<_>>();
        if !missing.is_subset(&recovered_ids) && recovery_error.is_none() {
            recovery_error = Some("public_reset_history_gap");
        }
        self.public_current(data.revision, data.enabled, cancel)?;
        let latest = head
            .rows
            .iter()
            .max_by_key(|a| (a.at, a.id.clone()))
            .cloned();
        {
            let mut view = self
                .public_runtime
                .view
                .lock()
                .map_err(|_| Failure("public_reset_state_unavailable"))?;
            view.checked = Some(now());
            view.latest = latest;
            match &forecast_result {
                Ok(ForecastPage::Forecast(f)) => view.forecast = Some(f.clone()),
                Ok(ForecastPage::None) => view.forecast = None,
                Ok(ForecastPage::SiteWatch) => (),
                Err(_) => (),
            }
            view.failure = forecast_result
                .as_ref()
                .err()
                .map(|e| e.0)
                .or(recovery_error);
        }
        self.storage.change(|v| {
            if v.public_reset.revision != data.revision || v.public_reset.enabled != data.enabled {
                return Err(Failure("configuration_changed"));
            }
            v.public_reset.checked_at = Some(now());
            v.public_reset.cached_latest = head
                .rows
                .iter()
                .max_by_key(|a| (a.at, &a.id))
                .map(Announcement::safe);
            match &forecast_result {
                Ok(ForecastPage::Forecast(f)) => v.public_reset.cached_forecast = Some(f.clone()),
                Ok(ForecastPage::None) => v.public_reset.cached_forecast = None,
                _ => (),
            }
            Ok(())
        })?;
        if !data.enabled {
            return Ok(());
        }
        let admission = if saved.is_none() {
            Page {
                rows: rows.clone(),
                has_more: last.has_more,
                cursor: last.cursor,
            }
        } else {
            head.clone()
        };
        let mut observation_error = None;
        self.storage.change(|v| {
            if v.public_reset.revision != data.revision || !v.public_reset.enabled {
                return Err(Failure("configuration_changed"));
            }
            let d = &mut v.public_reset;
            d.checkpoint = checkpoint;
            for (kind, revision) in &channels {
                if v.configs
                    .get(kind)
                    .is_none_or(|c| !c.enabled || c.revision != *revision)
                {
                    continue;
                }
                let ledger = d.completed.entry(*kind).or_default();
                let mut next = ledger.clone();
                next.hydrate(&rows)?;
                match next.observe_history(&admission, data.rebase) {
                    Ok(()) => *ledger = next,
                    Err(e) => observation_error = Some(e.0),
                }
            }
            if let Ok(state) = &forecast_result {
                match state {
                    ForecastPage::Forecast(f) if channels.contains_key(&ChannelKind::Feishu) => {
                        d.forecast
                            .observe(Payload::Forecast(f.clone()), data.rebase)?;
                        d.forecast.initialized = true;
                        let completed = head_ids.contains(&f.id)
                            || d.completed.get(&ChannelKind::Feishu).is_some_and(|l| {
                                l.records.contains_key(&f.id)
                                    || l.retired_through.is_some_and(|at| f.at <= at)
                            });
                        if completed {
                            if let Some(r) = d.forecast.records.get_mut(&f.id) {
                                if r.phase == Phase::Pending {
                                    r.phase = Phase::Baseline;
                                }
                            }
                        }
                    }
                    ForecastPage::None if channels.contains_key(&ChannelKind::Feishu) => {
                        d.forecast.initialized = true
                    }
                    _ => (),
                }
            }
            d.rebase = false;
            Ok(())
        })?;
        if let Some(code) = observation_error {
            if let Ok(mut view) = self.public_runtime.view.lock() {
                view.failure = Some(code);
            }
        }
        // Each enable first establishes a baseline; neither a current banner
        // nor an old completed page is an invitation to replay history.
        if data.rebase {
            return Ok(());
        }
        let mut jobs = Vec::new();
        let stored = self.storage.read(|v| Ok(v.public_reset.clone()))?;
        for (kind, revision) in &channels {
            if let Some(l) = stored.completed.get(kind) {
                for (id, r) in &l.records {
                    if r.phase != Phase::Pending {
                        continue;
                    }
                    if let Payload::Completed(saved) = &r.payload {
                        if let Some(current) = rows.iter().find(|a| {
                            a.id == *id
                                && a.at == saved.at
                                && a.banked == saved.banked
                                && a.source == saved.source
                                && a.valid(now())
                                && a.has_text()
                        }) {
                            jobs.push((*kind, *revision, Payload::Completed(current.safe())));
                        }
                    }
                }
            }
        }
        if let (Ok(ForecastPage::Forecast(f)), Some(revision)) =
            (&forecast_result, channels.get(&ChannelKind::Feishu))
        {
            if stored
                .forecast
                .records
                .get(&f.id)
                .is_some_and(|r| r.phase == Phase::Pending)
            {
                jobs.push((ChannelKind::Feishu, *revision, Payload::Forecast(f.clone())));
            }
        }
        jobs.sort_by_key(|(_, _, p)| p.at());
        for (kind, revision, payload) in jobs.into_iter().take(20) {
            self.public_current(data.revision, true, cancel)?;
            let id = payload.id().to_owned();
            let forecast = matches!(payload, Payload::Forecast(_));
            let reserved = self.storage.change(|v| {
                if v.public_reset.revision != data.revision
                    || !v.public_reset.enabled
                    || v.configs
                        .get(&kind)
                        .is_none_or(|c| !c.enabled || c.revision != revision)
                {
                    return Err(Failure("configuration_changed"));
                }
                let l = if forecast {
                    &mut v.public_reset.forecast
                } else {
                    v.public_reset
                        .completed
                        .get_mut(&kind)
                        .ok_or(Failure("public_reset_state_unavailable"))?
                };
                let r = l
                    .records
                    .get_mut(&id)
                    .filter(|r| r.phase == Phase::Pending)
                    .ok_or(Failure("public_reset_not_pending"))?;
                r.phase = Phase::Sending;
                Ok(())
            });
            if reserved.is_err() {
                continue;
            }
            let event = match &payload {
                Payload::Completed(a) => NotificationEvent::public_reset(
                    &format!("public:completed:{}", a.id),
                    a.banked,
                    &a.text,
                    a.at / 1000,
                    notifications::now(),
                ),
                Payload::Forecast(f) => NotificationEvent::new(
                    &format!("public:forecast:{}", f.id),
                    None,
                    EventBody::PublicForecast {
                        announced_at: f.at / 1000,
                        latest_by: f.latest_by.map(|at| at / 1000),
                        source_url: f.source_url.clone(),
                    },
                    notifications::now(),
                ),
            };
            let result = event.and_then(|mut event| {
                event.public_revision = Some(data.revision);
                event.expected_channel_revision = Some(revision);
                self.send_event_to_controlled(kind, &event, control)
            });
            let accepted = result.as_ref().is_ok_and(|r| r.state == "accepted")
                && self.public_current(data.revision, true, cancel).is_ok();
            let retryable_forecast = forecast
                && self.public_current(data.revision, true, cancel).is_ok()
                && result.as_ref().is_ok_and(|r| r.state == "rejected");
            self.storage.change(|v| {
                let l = if forecast {
                    &mut v.public_reset.forecast
                } else {
                    v.public_reset
                        .completed
                        .get_mut(&kind)
                        .ok_or(Failure("public_reset_state_unavailable"))?
                };
                let r = l
                    .records
                    .get_mut(&id)
                    .filter(|r| r.phase == Phase::Sending)
                    .ok_or(Failure("public_reset_state_unavailable"))?;
                r.phase = if accepted {
                    Phase::Sent
                } else if retryable_forecast {
                    Phase::Pending
                } else {
                    Phase::Uncertain
                };
                Ok(())
            })?;
            if !accepted {
                if let Ok(mut view) = self.public_runtime.view.lock() {
                    view.failure = Some("public_reset_delivery_unconfirmed");
                }
                if result.is_err() {
                    break;
                }
            }
        }
        Ok(())
    }
}
