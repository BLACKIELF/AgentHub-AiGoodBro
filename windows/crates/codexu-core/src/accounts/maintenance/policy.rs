use super::*;
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Window {
    pub duration: i64,
    pub used: f64,
    pub reset_ms: Option<i64>,
}
pub(super) fn windows(value: &Value, observed: i64, time: i64) -> Result<Vec<Window>> {
    if observed <= 0 || observed > time + 60000 || time - observed > 15 * 60000 {
        return Err(Failure::QuotaUnknown);
    }
    let parsed = crate::readers::CodexAppServerQuotaSnapshot::from_rate_limit_response(value);
    if !parsed.quota_read_succeeded {
        return Err(Failure::QuotaUnknown);
    }
    let result = [
        parsed.five_hour_quota,
        parsed.seven_day_quota,
        parsed.monthly_quota,
    ]
    .into_iter()
    .flatten()
    .map(|w| Window {
        duration: w.window_duration_mins.unwrap_or(-1) * 60000,
        used: w.used_percent,
        reset_ms: w.resets_at.map(|t| t.timestamp_millis()),
    })
    .collect::<Vec<_>>();
    if result.is_empty()
        || result
            .iter()
            .any(|w| !w.used.is_finite() || !(0.0..=100.0).contains(&w.used) || w.duration <= 0)
    {
        return Err(Failure::QuotaUnknown);
    }
    Ok(result)
}
fn selected(settings: &Settings, duration: i64) -> bool {
    (settings.five_hour_warmup && duration == 5 * 3600000)
        || (settings.seven_day_warmup && duration == 7 * 24 * 3600000)
}
fn advanced(old: &Window, new: &Window, started: i64, time: i64) -> bool {
    matches!((old.reset_ms,new.reset_ms),(Some(old_reset),Some(new_reset)) if old_reset>started&&time>=old_reset+8000&&new_reset>old_reset&&new_reset-new.duration>=old_reset-60000)
}
pub(super) fn warmup_due(
    settings: &Settings,
    current: &[Window],
    prior: Option<&MaintenanceEntry>,
    time: i64,
) -> bool {
    if current.iter().any(|w| w.used >= 100.0) {
        return false;
    }
    if let Some(prior) = prior {
        if prior.phase != "succeeded" {
            // Every previously selected window must advance, not just its percentage.
            if prior
                .window_baseline
                .iter()
                .filter(|w| selected(settings, w.duration))
                .any(|old| {
                    !current
                        .iter()
                        .find(|w| w.duration == old.duration)
                        .is_some_and(|new| {
                            advanced(old, new, prior.last_attempt_at_ms.unwrap_or(time), time)
                        })
                })
            {
                return false;
            }
        }
    }
    current
        .iter()
        .filter(|w| selected(settings, w.duration))
        .any(|window| {
            if window.used < 0.5 {
                return prior
                    .and_then(|p| p.last_succeeded_at_ms)
                    .is_none_or(|at| time >= at + window.duration + 8000);
            }
            window.reset_ms.is_some_and(|reset| time >= reset + 8000)
                && prior.is_none_or(|p| {
                    p.window_baseline
                        .iter()
                        .find(|w| w.duration == window.duration)
                        .is_some_and(|old| {
                            advanced(old, window, p.last_attempt_at_ms.unwrap_or(time), time)
                        })
                })
        })
}
pub(super) fn card(value: &Value, expected: &str, time: i64) -> Result<Card> {
    if value.get("accountId").and_then(Value::as_str) != Some(expected) {
        return Err(Failure::IdentityChanged);
    }
    let summary = value
        .get("rateLimitResetCredits")
        .ok_or(Failure::ProtocolUnknown)?;
    let count = summary
        .get("availableCount")
        .and_then(Value::as_u64)
        .filter(|n| *n <= 1000000)
        .ok_or(Failure::ProtocolUnknown)?;
    let details = summary
        .get("credits")
        .and_then(Value::as_array)
        .filter(|rows| rows.len() <= 1024)
        .ok_or(Failure::ProtocolUnknown)?;
    let mut seen = std::collections::BTreeSet::new();
    let mut cards = Vec::new();
    for row in details {
        let id = row
            .get("id")
            .and_then(Value::as_str)
            .filter(|v| !v.is_empty() && v.len() <= 512 && !v.chars().any(char::is_control))
            .ok_or(Failure::ProtocolUnknown)?;
        if !seen.insert(id) {
            return Err(Failure::ProtocolUnknown);
        }
        let kind = row
            .get("resetType")
            .and_then(Value::as_str)
            .ok_or(Failure::ProtocolUnknown)?;
        let status = row
            .get("status")
            .and_then(Value::as_str)
            .ok_or(Failure::ProtocolUnknown)?;
        let expiry = match row.get("expiresAt") {
            Some(Value::Null) => None,
            Some(n) => Some(
                n.as_i64()
                    .and_then(|v| v.checked_mul(1000))
                    .filter(|v| *v > 0)
                    .ok_or(Failure::ProtocolUnknown)?,
            ),
            None => return Err(Failure::ProtocolUnknown),
        };
        if kind == "codexRateLimits" && status == "available" && expiry.is_some_and(|at| at > time)
        {
            cards.push((expiry.unwrap(), id));
        }
    }
    if count == 0 || cards.is_empty() {
        return Err(Failure::QuotaUnknown);
    }
    cards.sort();
    let parsed = windows(value, time, time)?;
    let fingerprint = auth_digest(
        serde_json::to_vec(&parsed)
            .map_err(|_| Failure::ProtocolUnknown)?
            .as_slice(),
    );
    Ok(Card {
        id: cards[0].1.into(),
        expires_at_ms: cards[0].0,
        fingerprint,
    })
}
pub(super) fn sse_completed(bytes: &[u8]) -> bool {
    if bytes.len() > 1024 * 1024 {
        return false;
    }
    let Ok(text) = std::str::from_utf8(bytes) else {
        return false;
    };
    for event in text.replace("\r\n", "\n").split("\n\n") {
        let mut terminal = false;
        for line in event.lines() {
            let value = line
                .strip_prefix("event:")
                .map(|s| s.trim().to_owned())
                .or_else(|| {
                    line.strip_prefix("data:")
                        .and_then(|data| serde_json::from_str::<Value>(data.trim()).ok())
                        .and_then(|v| v.get("type").and_then(Value::as_str).map(str::to_owned))
                });
            if let Some(value) = value.as_deref() {
                if matches!(value, "error" | "response.failed" | "response.incomplete") {
                    return false;
                }
                terminal |= matches!(value, "response.completed" | "response.done");
            }
            terminal |= line.trim() == "data: [DONE]";
        }
        if terminal {
            return true;
        }
    }
    false
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn missing_selected_window_exhausted_or_stale_never_send() {
        let s = Settings {
            five_hour_warmup: true,
            ..Settings::default()
        };
        let w = Window {
            duration: 604800000,
            used: 0.0,
            reset_ms: Some(999999999),
        };
        assert!(!warmup_due(&s, &[w], None, 1));
        assert!(windows(&json!({}), 1, 1000000).is_err());
        assert!(!warmup_due(
            &s,
            &[Window {
                duration: 18000000,
                used: 100.0,
                reset_ms: None
            }],
            None,
            1
        ));
    }
    #[test]
    fn warmup_success_anchors_selected_window_and_unknown_needs_advanced_window() {
        let settings = Settings {
            five_hour_warmup: true,
            ..Settings::default()
        };
        let window = Window {
            duration: 18000000,
            used: 0.0,
            reset_ms: Some(20000000),
        };
        assert!(warmup_due(&settings, &[window.clone()], None, 1000));
        let mut prior = MaintenanceEntry {
            profile_id: "a".repeat(32),
            kind: "warmup".into(),
            phase: "succeeded".into(),
            issue_code: None,
            last_attempt_at_ms: Some(1000),
            last_succeeded_at_ms: Some(1000),
            next_eligible_at_ms: None,
            identity: "b".repeat(64),
            generation: "c".repeat(32),
            window_baseline: vec![window.clone()],
            card_hash: None,
            idempotency_key: None,
            quota_fingerprint: None,
        };
        assert!(!warmup_due(
            &settings,
            &[window.clone()],
            Some(&prior),
            1100
        ));
        prior.phase = "uncertain".into();
        assert!(!warmup_due(&settings, &[window], Some(&prior), 21000000));
    }
    #[test]
    fn card_count_without_details_unknown_account_or_nonexpiring_never_authorizes() {
        let mut value = json!({"accountId":"synthetic-account","rateLimits":{"primary":{"usedPercent":50,"windowDurationMins":300,"resetsAt":2000000000}},"rateLimitResetCredits":{"availableCount":1,"credits":null}});
        assert!(card(&value, "synthetic-account", 1000).is_err());
        value["rateLimitResetCredits"]["credits"] = json!([{"id":"synthetic-card","resetType":"codexRateLimits","status":"available","expiresAt":2000000000}]);
        assert!(card(&value, "other-account", 1000).is_err());
        assert!(card(&value, "synthetic-account", 1000).is_ok());
        value["rateLimitResetCredits"]["credits"][0]["expiresAt"] = Value::Null;
        assert!(card(&value, "synthetic-account", 1000).is_err());
    }
    #[test]
    fn http_200_eof_or_incomplete_is_not_warmup_success() {
        assert!(!sse_completed(b"data: {}\n\n"));
        assert!(!sse_completed(b"event: response.incomplete\n\n"));
        assert!(sse_completed(
            b"data: {\"type\":\"response.completed\"}\n\n"
        ));
    }
}
