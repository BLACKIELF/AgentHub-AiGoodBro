//! Display receipts only. This module has no filesystem, credential, runtime,
//! transport or admission dependency. A getter never refreshes anything.
use super::{
    super::{fail, AccountResult},
    ClaudeSubscriptionQuotaDto,
};
use crate::readers::local_cli_quota::{LocalCliQuotaResult, LocalCliQuotaState};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Mutex,
    },
};

#[derive(Clone, Debug)]
pub struct ClaudeQuotaDisplaySnapshot {
    pub account_id: String,
    pub record_revision: u64,
    pub identity_hash: String,
    /// Historical successful response; never advance its original timestamp.
    pub last_success: Option<ClaudeSubscriptionQuotaDto>,
    /// Current display state comes from this attempt, including 429/unknown.
    pub last_attempt: Option<ClaudeSubscriptionQuotaDto>,
}
#[derive(Clone)]
pub(super) struct Scope {
    pub id: String,
    pub revision: u64,
    pub identity: String,
    pub generation: String,
    pub masked: Option<String>,
}
impl Scope {
    fn same(&self, other: &Self) -> bool {
        self.id == other.id
            && self.revision == other.revision
            && self.identity == other.identity
            && self.generation == other.generation
    }
}
struct Entry {
    scope: Scope,
    success: Option<ClaudeSubscriptionQuotaDto>,
    attempt: Option<ClaudeSubscriptionQuotaDto>,
    active: Option<u64>,
    epoch: u64,
}
pub(super) struct Attempt {
    id: String,
    number: u64,
    epoch: u64,
    scope: Scope,
}
#[derive(Default)]
pub(super) struct DisplayCache {
    entries: Mutex<HashMap<String, Entry>>,
    epoch: AtomicU64,
    next: AtomicU64,
    sealed: AtomicBool,
}
fn unknown(scope: &Scope, state: LocalCliQuotaState) -> ClaudeSubscriptionQuotaDto {
    let mut quota = LocalCliQuotaResult::new(
        state,
        chrono::Utc::now(),
        "Anthropic OAuth usage",
        Some(if state == LocalCliQuotaState::NeedsLogin {
            "local_cli_needs_login"
        } else {
            "local_cli_unavailable"
        }),
    );
    quota.masked_identity = scope.masked.clone();
    quota.identity_fingerprint = Some(scope.identity.clone());
    ClaudeSubscriptionQuotaDto {
        quota,
        server_retry_at: None,
    }
}
impl DisplayCache {
    fn invalidate_epoch(&self) {
        if self
            .epoch
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |v| v.checked_add(1))
            .is_err()
        {
            self.sealed.store(true, Ordering::Release);
        }
    }
    pub(super) fn snapshot(&self, id: &str) -> AccountResult<Option<ClaudeQuotaDisplaySnapshot>> {
        if self.sealed.load(Ordering::Acquire) {
            return Err(fail("account_service_exiting"));
        }
        let epoch = self.epoch.load(Ordering::Acquire);
        let cache = self
            .entries
            .try_lock()
            .map_err(|_| fail("claude_quota_cache_busy"))?;
        let result =
            cache
                .get(id)
                .filter(|e| e.epoch == epoch)
                .map(|e| ClaudeQuotaDisplaySnapshot {
                    account_id: e.scope.id.clone(),
                    record_revision: e.scope.revision,
                    identity_hash: e.scope.identity.clone(),
                    last_success: e.success.clone(),
                    last_attempt: e.attempt.clone(),
                });
        if self.sealed.load(Ordering::Acquire) || self.epoch.load(Ordering::Acquire) != epoch {
            return Ok(None);
        }
        Ok(result)
    }
    pub(super) fn begin(&self, scope: Scope) -> Option<Attempt> {
        if self.sealed.load(Ordering::Acquire) {
            return None;
        }
        let epoch = self.epoch.load(Ordering::Acquire);
        let Ok(mut cache) = self.entries.try_lock() else {
            self.invalidate_epoch();
            return None;
        };
        if self.epoch.load(Ordering::Acquire) != epoch {
            return None;
        }
        cache.retain(|_, e| e.epoch == epoch);
        if !cache.contains_key(&scope.id) && cache.len() >= 64 {
            self.invalidate_epoch();
            return None;
        }
        let Ok(number) = self
            .next
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| n.checked_add(1))
        else {
            self.sealed.store(true, Ordering::Release);
            return None;
        };
        let entry = cache.entry(scope.id.clone()).or_insert_with(|| Entry {
            scope: scope.clone(),
            success: None,
            attempt: None,
            active: None,
            epoch,
        });
        if !entry.scope.same(&scope) {
            entry.success = None;
        }
        entry.scope = scope.clone();
        entry.attempt = Some(unknown(&scope, LocalCliQuotaState::Unavailable));
        entry.active = Some(number);
        Some(Attempt {
            id: scope.id.clone(),
            number,
            epoch,
            scope,
        })
    }
    pub(super) fn finish(&self, attempt: Attempt, value: &ClaudeSubscriptionQuotaDto) {
        if self.sealed.load(Ordering::Acquire)
            || attempt.epoch != self.epoch.load(Ordering::Acquire)
        {
            return;
        }
        let Ok(mut cache) = self.entries.try_lock() else {
            self.invalidate_epoch();
            return;
        };
        let Some(entry) = cache.get_mut(&attempt.id).filter(|e| {
            e.epoch == attempt.epoch
                && e.active == Some(attempt.number)
                && e.scope.same(&attempt.scope)
        }) else {
            return;
        };
        if matches!(
            value.quota.state,
            LocalCliQuotaState::Available | LocalCliQuotaState::RateLimited
        ) && value.quota.identity_fingerprint.as_deref() != Some(entry.scope.identity.as_str())
        {
            cache.remove(&attempt.id);
            return;
        }
        if value.quota.state == LocalCliQuotaState::Available {
            entry.success = Some(value.clone());
        }
        entry.attempt = Some(value.clone());
        entry.active = None;
    }
    pub(super) fn invalidate(&self, id: &str) {
        match self.entries.try_lock() {
            Ok(mut cache) => {
                cache.remove(id);
            }
            Err(_) => self.invalidate_epoch(),
        }
    }
    pub(super) fn invalidate_all(&self) {
        self.invalidate_epoch();
        if let Ok(mut cache) = self.entries.try_lock() {
            cache.clear();
        }
    }
    pub(super) fn fail_existing(&self, id: &str, needs_login: bool) {
        let Ok(mut cache) = self.entries.try_lock() else {
            self.invalidate_epoch();
            return;
        };
        if let Some(entry) = cache.get_mut(id) {
            entry.attempt = Some(unknown(
                &entry.scope,
                if needs_login {
                    LocalCliQuotaState::NeedsLogin
                } else {
                    LocalCliQuotaState::Unavailable
                },
            ));
            entry.active = None;
        }
    }
    pub(super) fn degrade_all(&self) {
        let Ok(mut cache) = self.entries.try_lock() else {
            self.invalidate_epoch();
            return;
        };
        for entry in cache.values_mut() {
            entry.attempt = Some(unknown(&entry.scope, LocalCliQuotaState::Unavailable));
            entry.active = None;
        }
    }
    pub(super) fn sync_catalog(&self, scopes: &[(Scope, bool)], unknown_state: bool) {
        let Ok(mut cache) = self.entries.try_lock() else {
            self.invalidate_epoch();
            return;
        };
        let epoch = self.epoch.load(Ordering::Acquire);
        cache.retain(|id, e| {
            e.epoch == epoch && scopes.iter().any(|(s, _)| s.id == *id && s.same(&e.scope))
        });
        for (scope, pending) in scopes {
            if let Some(e) = cache.get_mut(&scope.id) {
                if unknown_state || *pending {
                    e.attempt = Some(unknown(
                        &e.scope,
                        if *pending {
                            LocalCliQuotaState::NeedsLogin
                        } else {
                            LocalCliQuotaState::Unavailable
                        },
                    ));
                    e.active = None;
                }
            }
        }
    }
    pub(super) fn seal(&self) {
        self.sealed.store(true, Ordering::Release);
        self.invalidate_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn scope(id: &str) -> Scope {
        Scope {
            id: id.into(),
            revision: 1,
            identity: "a".repeat(64),
            generation: "b".repeat(32),
            masked: Some("s***@fixture.invalid".into()),
        }
    }
    fn receipt(scope: &Scope, state: LocalCliQuotaState) -> ClaudeSubscriptionQuotaDto {
        let mut q =
            LocalCliQuotaResult::new(state, chrono::Utc::now(), "Anthropic OAuth usage", None);
        q.identity_fingerprint = Some(scope.identity.clone());
        ClaudeSubscriptionQuotaDto {
            quota: q,
            server_retry_at: (state == LocalCliQuotaState::RateLimited).then_some(4_102_444_800),
        }
    }
    #[test]
    fn claude_cache_keeps_last_success_and_original_time_when_latest_attempt_is_429() {
        let c = DisplayCache::default();
        let s = scope("fixture");
        let success = receipt(&s, LocalCliQuotaState::Available);
        c.finish(c.begin(s.clone()).unwrap(), &success);
        let limited = receipt(&s, LocalCliQuotaState::RateLimited);
        c.finish(c.begin(s).unwrap(), &limited);
        let cache = c.snapshot("fixture").unwrap().unwrap();
        assert_eq!(
            cache.last_success.unwrap().quota.fetched_at,
            success.quota.fetched_at
        );
        assert_eq!(
            cache.last_attempt.unwrap().server_retry_at,
            limited.server_retry_at
        );
    }
    #[test]
    fn claude_cache_unknown_keeps_history_and_cancels_inflight_receipt() {
        let c = DisplayCache::default();
        let s = scope("fixture");
        let success = receipt(&s, LocalCliQuotaState::Available);
        c.finish(c.begin(s.clone()).unwrap(), &success);
        let late = c.begin(s).unwrap();
        c.fail_existing("fixture", false);
        c.finish(late, &success);
        let cache = c.snapshot("fixture").unwrap().unwrap();
        assert!(cache.last_success.is_some());
        assert_eq!(
            cache.last_attempt.unwrap().quota.state,
            LocalCliQuotaState::Unavailable
        );
    }
    #[test]
    fn claude_cache_revision_identity_and_generation_never_reuse_another_success() {
        for field in 0..3 {
            let c = DisplayCache::default();
            let mut s = scope("fixture");
            let q = receipt(&s, LocalCliQuotaState::Available);
            c.finish(c.begin(s.clone()).unwrap(), &q);
            match field {
                0 => s.revision += 1,
                1 => s.identity = "c".repeat(64),
                _ => s.generation = "d".repeat(32),
            };
            c.begin(s);
            assert!(c
                .snapshot("fixture")
                .unwrap()
                .unwrap()
                .last_success
                .is_none());
        }
    }
    #[test]
    fn claude_cache_getter_lock_contention_is_immediate_and_invalidation_revokes_late_put() {
        let c = DisplayCache::default();
        let s = scope("fixture");
        let q = receipt(&s, LocalCliQuotaState::Available);
        let attempt = c.begin(s).unwrap();
        let held = c.entries.lock().unwrap();
        assert_eq!(
            c.snapshot("fixture").err().unwrap().code,
            "claude_quota_cache_busy"
        );
        c.invalidate("fixture");
        drop(held);
        c.finish(attempt, &q);
        assert!(c.snapshot("fixture").unwrap().is_none());
    }
    #[test]
    fn claude_cache_wrong_identity_cannot_replace_scope_or_other_account() {
        let c = DisplayCache::default();
        let a = scope("first");
        let b = scope("second");
        let q = receipt(&a, LocalCliQuotaState::Available);
        c.finish(c.begin(a.clone()).unwrap(), &q);
        c.finish(c.begin(b).unwrap(), &q);
        let mut wrong = receipt(&a, LocalCliQuotaState::Available);
        wrong.quota.identity_fingerprint = Some("f".repeat(64));
        c.finish(c.begin(a).unwrap(), &wrong);
        assert!(c.snapshot("first").unwrap().is_none());
        assert!(c
            .snapshot("second")
            .unwrap()
            .unwrap()
            .last_success
            .is_some());
    }
    #[test]
    fn claude_cache_catalog_sync_drops_changed_revision_but_recovery_only_degrades_history() {
        let c = DisplayCache::default();
        let mut a = scope("first");
        let q = receipt(&a, LocalCliQuotaState::Available);
        c.finish(c.begin(a.clone()).unwrap(), &q);
        c.sync_catalog(&[(a.clone(), false)], true);
        let cached = c.snapshot("first").unwrap().unwrap();
        assert!(cached.last_success.is_some());
        assert_eq!(
            cached.last_attempt.unwrap().quota.state,
            LocalCliQuotaState::Unavailable
        );
        a.revision += 1;
        c.sync_catalog(&[(a, false)], false);
        assert!(c.snapshot("first").unwrap().is_none());
    }
    #[test]
    fn claude_cache_exit_seals_while_lock_is_held_and_never_admits_late_result() {
        let c = DisplayCache::default();
        let a = scope("first");
        let q = receipt(&a, LocalCliQuotaState::Available);
        let attempt = c.begin(a).unwrap();
        let held = c.entries.lock().unwrap();
        c.seal();
        drop(held);
        c.finish(attempt, &q);
        assert_eq!(
            c.snapshot("first").err().unwrap().code,
            "account_service_exiting"
        );
    }
    #[test]
    fn claude_cache_has_catalog_bound_and_contains_only_safe_receipts() {
        let c = DisplayCache::default();
        for i in 0..64 {
            let a = scope(&format!("fixture-{i}"));
            c.begin(a);
        }
        assert_eq!(c.entries.lock().unwrap().len(), 64);
        assert!(c.begin(scope("extra")).is_none());
        assert!(c.entries.lock().unwrap().len() <= 64);
    }
}
