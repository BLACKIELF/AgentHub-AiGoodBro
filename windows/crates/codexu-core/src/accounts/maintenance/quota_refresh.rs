use serde::{Deserialize, Serialize};

/// Scheduled official quota reads. Stored values match the macOS preference.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum QuotaRefreshFrequency {
    #[default]
    Automatic,
    OneMinute,
    ThreeMinutes,
    FiveMinutes,
    TenMinutes,
    ThirtyMinutes,
}

impl QuotaRefreshFrequency {
    pub const ALL: [Self; 6] = [
        Self::Automatic,
        Self::OneMinute,
        Self::ThreeMinutes,
        Self::FiveMinutes,
        Self::TenMinutes,
        Self::ThirtyMinutes,
    ];

    pub fn interval_seconds(self, foreground: bool) -> i64 {
        match self {
            Self::Automatic if foreground => 180,
            Self::Automatic => 300,
            Self::OneMinute => 60,
            Self::ThreeMinutes => 180,
            Self::FiveMinutes => 300,
            Self::TenMinutes => 600,
            Self::ThirtyMinutes => 1800,
        }
    }

    pub fn due(self, foreground: bool, last_attempt_at_ms: Option<i64>, now_ms: i64) -> bool {
        let Some(last_attempt_at_ms) = last_attempt_at_ms else {
            return true;
        };
        now_ms >= last_attempt_at_ms.saturating_add(self.interval_seconds(foreground) * 1000)
    }

    pub fn next_eligible_at_ms(self, foreground: bool, last_attempt_at_ms: i64) -> i64 {
        last_attempt_at_ms.saturating_add(self.interval_seconds(foreground) * 1000)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn automatic_frequency_tracks_foreground_and_background_defaults() {
        assert_eq!(QuotaRefreshFrequency::Automatic.interval_seconds(true), 180);
        assert_eq!(
            QuotaRefreshFrequency::Automatic.interval_seconds(false),
            300
        );
    }

    #[test]
    fn persisted_values_match_the_existing_mac_preference_and_manual_intervals() {
        let expected = [
            (QuotaRefreshFrequency::Automatic, "automatic", None),
            (QuotaRefreshFrequency::OneMinute, "oneMinute", Some(60)),
            (
                QuotaRefreshFrequency::ThreeMinutes,
                "threeMinutes",
                Some(180),
            ),
            (QuotaRefreshFrequency::FiveMinutes, "fiveMinutes", Some(300)),
            (QuotaRefreshFrequency::TenMinutes, "tenMinutes", Some(600)),
            (
                QuotaRefreshFrequency::ThirtyMinutes,
                "thirtyMinutes",
                Some(1800),
            ),
        ];
        for (frequency, value, seconds) in expected {
            assert_eq!(
                serde_json::to_string(&frequency).unwrap(),
                format!("\"{value}\"")
            );
            assert_eq!(
                serde_json::from_str::<QuotaRefreshFrequency>(&format!("\"{value}\"")).unwrap(),
                frequency
            );
            if let Some(seconds) = seconds {
                assert_eq!(frequency.interval_seconds(true), seconds);
                assert_eq!(frequency.interval_seconds(false), seconds);
            }
        }
    }

    #[test]
    fn due_check_is_per_frequency_and_never_refreshes_early() {
        let started = 1_000_000;
        assert!(QuotaRefreshFrequency::OneMinute.due(true, None, started));
        assert!(!QuotaRefreshFrequency::FiveMinutes.due(true, Some(started), started + 299_999));
        assert!(QuotaRefreshFrequency::FiveMinutes.due(true, Some(started), started + 300_000));
        assert!(!QuotaRefreshFrequency::Automatic.due(false, Some(started), started + 299_999));
        assert!(QuotaRefreshFrequency::Automatic.due(false, Some(started), started + 300_000));
        assert_eq!(
            QuotaRefreshFrequency::Automatic.next_eligible_at_ms(false, started),
            started + 300_000
        );
    }
}
