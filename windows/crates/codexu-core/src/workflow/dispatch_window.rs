//! Mac DispatchParticipationWindow semantics for admitting new work only.
//! Existing work, quota reads and account maintenance do not consult this gate.
use chrono::{Datelike, TimeZone, Timelike, Utc};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DispatchMode {
    #[default]
    Unrestricted,
    OnlyWithin,
    ExceptWithin,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DispatchInterval {
    pub start_minute: u16,
    pub end_minute: u16,
    pub all_days: bool,
    pub weekdays: BTreeSet<u8>,
    pub all_day: bool,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DispatchWindow {
    pub mode: DispatchMode,
    pub time_zone_identifier: String,
    pub intervals: Vec<DispatchInterval>,
}
impl Default for DispatchWindow {
    fn default() -> Self {
        Self {
            mode: DispatchMode::Unrestricted,
            time_zone_identifier: "UTC".into(),
            intervals: vec![],
        }
    }
}
impl DispatchWindow {
    pub fn validate(&self) -> anyhow::Result<()> {
        anyhow::ensure!(
            self.time_zone_identifier.len() <= 100
                && self.time_zone_identifier != "Local"
                && self.time_zone_identifier.parse::<chrono_tz::Tz>().is_ok(),
            "Invalid time zone"
        );
        anyhow::ensure!(self.intervals.len() <= 32, "Too many time intervals");
        for interval in &self.intervals {
            anyhow::ensure!(
                interval.start_minute < 1440
                    && interval.end_minute < 1440
                    && (interval.all_day || interval.start_minute != interval.end_minute)
                    && interval.weekdays.iter().all(|day| (1..=7).contains(day))
                    && (interval.all_days || !interval.weekdays.is_empty()),
                "Invalid time interval"
            );
        }
        Ok(())
    }
    pub fn allows_at_ms(&self, timestamp_ms: i64) -> bool {
        if self.validate().is_err() {
            return false;
        }
        let Some(utc) = Utc.timestamp_millis_opt(timestamp_ms).single() else {
            return false;
        };
        if self.mode == DispatchMode::Unrestricted {
            return true;
        }
        let Ok(zone) = self.time_zone_identifier.parse::<chrono_tz::Tz>() else {
            return false;
        };
        let local = utc.with_timezone(&zone);
        let day = local.weekday().number_from_monday() as u8;
        let previous = if day == 1 { 7 } else { day - 1 };
        let minute = (local.hour() * 60 + local.minute()) as u16;
        let matched = self.intervals.iter().any(|interval| {
            let today = interval.all_days || interval.weekdays.contains(&day);
            if interval.all_day {
                return today;
            }
            if interval.start_minute < interval.end_minute {
                today && minute >= interval.start_minute && minute < interval.end_minute
            } else {
                let yesterday = interval.all_days || interval.weekdays.contains(&previous);
                (today && minute >= interval.start_minute)
                    || (yesterday && minute < interval.end_minute)
            }
        });
        if self.mode == DispatchMode::OnlyWithin {
            matched
        } else {
            !matched
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn at(value: &str) -> i64 {
        chrono::DateTime::parse_from_rfc3339(value)
            .unwrap()
            .timestamp_millis()
    }
    fn interval(start: u16, end: u16) -> DispatchInterval {
        DispatchInterval {
            start_minute: start,
            end_minute: end,
            all_days: false,
            weekdays: [1].into(),
            all_day: false,
        }
    }
    #[test]
    fn overnight_uses_start_day_and_half_open_end() {
        let mut window = DispatchWindow {
            mode: DispatchMode::OnlyWithin,
            time_zone_identifier: "Asia/Shanghai".into(),
            intervals: vec![interval(1380, 60)],
        };
        for (time, expected) in [
            ("2026-10-26T14:59:00Z", false),
            ("2026-10-26T15:00:00Z", true),
            ("2026-10-26T16:59:00Z", true),
            ("2026-10-26T17:00:00Z", false),
            ("2026-10-27T15:00:00Z", false),
        ] {
            assert_eq!(window.allows_at_ms(at(time)), expected, "{time}");
        }
        window.mode = DispatchMode::ExceptWithin;
        assert!(!window.allows_at_ms(at("2026-10-26T16:59:00Z")));
        assert!(window.allows_at_ms(at("2026-10-26T17:00:00Z")));
    }
    #[test]
    fn empty_all_day_and_invalid_modes_fail_closed() {
        let mut window = DispatchWindow::default();
        let now = at("2026-10-26T12:00:00Z");
        assert!(window.allows_at_ms(now));
        window.mode = DispatchMode::OnlyWithin;
        assert!(!window.allows_at_ms(now));
        window.mode = DispatchMode::ExceptWithin;
        assert!(window.allows_at_ms(now));
        window.mode = DispatchMode::OnlyWithin;
        window.intervals.push(DispatchInterval {
            all_day: true,
            ..interval(0, 0)
        });
        assert!(window.allows_at_ms(now));
        window.intervals[0].weekdays.clear();
        assert!(!window.allows_at_ms(now));
        window.intervals[0].all_days = true;
        assert!(window.allows_at_ms(now));
        window.intervals[0].all_day = false;
        assert!(!window.allows_at_ms(now));
        window.mode = DispatchMode::Unrestricted;
        assert!(!window.allows_at_ms(now));
        window.intervals.clear();
        window.time_zone_identifier = "Local".into();
        assert!(!window.allows_at_ms(now));
        window.time_zone_identifier = "UTC".into();
        window.intervals = vec![interval(0, 1); 33];
        assert!(!window.allows_at_ms(now));
    }
    #[test]
    fn repeated_dst_hour_matches_both_real_instants_and_roundtrips() {
        let window = DispatchWindow {
            mode: DispatchMode::OnlyWithin,
            time_zone_identifier: "America/New_York".into(),
            intervals: vec![DispatchInterval {
                all_days: true,
                ..interval(90, 120)
            }],
        };
        assert!(window.allows_at_ms(at("2026-11-01T05:45:00Z")));
        assert!(window.allows_at_ms(at("2026-11-01T06:45:00Z")));
        assert!(!window.allows_at_ms(at("2026-11-01T07:00:00Z")));
        assert_eq!(
            serde_json::from_slice::<DispatchWindow>(&serde_json::to_vec(&window).unwrap())
                .unwrap(),
            window
        );
    }
}
