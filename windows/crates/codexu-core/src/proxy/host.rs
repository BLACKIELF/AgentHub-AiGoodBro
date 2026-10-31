use super::*;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

pub(crate) fn unix_now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BridgeRequest {
    pub schema_version: u32,
    #[serde(rename = "runID")]
    pub run_id: String,
    pub key: String,
    pub command: String,
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "profileID")]
    pub profile_id: String,
    #[serde(default, rename = "leaseID")]
    pub lease_id: Option<String>,
}
/// Never log this reply or return it through a WebView command.
#[derive(Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BridgeReply {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub order: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "deferredIDs")]
    pub deferred_ids: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "lastResortIDs")]
    pub last_resort_ids: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub credit_fallback: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "leaseID")]
    pub lease_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub access_token: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "accountID")]
    pub account_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resolution: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub quota_observed_at: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub probe_status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub probe_observed_at: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub probe_identity_hash: Option<String>,
}
impl BridgeReply {
    fn success() -> Self {
        Self {
            ok: true,
            ..Self::default()
        }
    }
    pub(crate) fn failure(e: ProxyFailure) -> Self {
        Self {
            error: Some(e.code()),
            ..Self::default()
        }
    }
}

#[derive(Clone)]
struct Membership {
    order: Vec<String>,
    deferred: Vec<String>,
    credits: bool,
    revocations: BTreeMap<String, u64>,
    captured: f64,
}

pub struct ProxyHost {
    pub(crate) preferences: ProxyPreferences,
    pub(crate) gate: Arc<dyn ProxyAccountGate>,
    run_id: String,
    control_key: String,
    running: bool,
    registered: BTreeMap<String, String>,
    memberships: BTreeMap<String, Membership>,
    revocations: BTreeMap<String, u64>,
    leases: BTreeMap<String, LeaseTuple>,
    credit_refresh_after: BTreeMap<String, f64>,
}
impl ProxyHost {
    pub fn new(
        preferences: ProxyPreferences,
        gate: Arc<dyn ProxyAccountGate>,
    ) -> Result<Self, ProxyFailure> {
        preferences.validate()?;
        Ok(Self {
            preferences,
            gate,
            run_id: String::new(),
            control_key: String::new(),
            running: false,
            registered: BTreeMap::new(),
            memberships: BTreeMap::new(),
            revocations: BTreeMap::new(),
            leases: BTreeMap::new(),
            credit_refresh_after: BTreeMap::new(),
        })
    }
    pub fn preferences(&self) -> ProxyPreferences {
        self.preferences.clone()
    }
    pub(crate) fn trusted_ids(&self) -> Result<std::collections::BTreeSet<String>, ProxyFailure> {
        let ids = self.gate.managed_profile_ids()?;
        let set: std::collections::BTreeSet<_> = ids.iter().cloned().collect();
        if ids.len() > 100 || ids.len() != set.len() || set.iter().any(|id| !policy::valid_id(id)) {
            return Err(ProxyFailure::Identity);
        }
        Ok(set)
    }
    pub(crate) fn normalize_preferences(
        &self,
        mut next: ProxyPreferences,
    ) -> Result<ProxyPreferences, ProxyFailure> {
        let ids = self.trusted_ids()?;
        if next.enabled_ids.iter().any(|id| !ids.contains(id)) {
            return Err(ProxyFailure::Identity);
        }
        next.known_ids = ids;
        self.validate_update(&next)?;
        Ok(next)
    }
    pub fn update_preferences(&mut self, next: ProxyPreferences) -> Result<(), ProxyFailure> {
        self.validate_update(&next)?;
        for id in self.preferences.enabled_ids.difference(&next.enabled_ids) {
            *self.revocations.entry(id.clone()).or_default() += 1;
        }
        self.preferences = next;
        Ok(())
    }
    pub(crate) fn validate_update(&self, next: &ProxyPreferences) -> Result<(), ProxyFailure> {
        next.validate()?;
        if self.running
            && (!next.is_enabled
                || !self.preferences.network_equal(next)
                || next
                    .enabled_ids
                    .iter()
                    .any(|id| !self.registered.contains_key(id)))
        {
            return Err(ProxyFailure::InvalidSettings);
        }
        Ok(())
    }
    pub(crate) fn plus_policy(&self, limit: f64) -> Result<ProxyPreferences, ProxyFailure> {
        self.quota_policy(limit, false)
    }
    pub(crate) fn shared_quota_policy(&self, limit: f64) -> Result<ProxyPreferences, ProxyFailure> {
        self.quota_policy(limit, true)
    }
    fn quota_policy(
        &self,
        limit: f64,
        include_pro: bool,
    ) -> Result<ProxyPreferences, ProxyFailure> {
        if !limit.is_finite() || !(0.0..=100.0).contains(&limit) {
            return Err(ProxyFailure::InvalidSettings);
        }
        let trusted = self.trusted_ids()?;
        let mut targets = vec![];
        for id in &trusted {
            let e = self.gate.evidence(id)?;
            let pro = match e.plan.as_deref() {
                Some("plus") => false,
                Some("pro" | "prolite") if include_pro => true,
                _ => continue,
            };
            if !e.identity_verified
                || e.is_system_home
                || e.profile_id != *id
                || !policy::valid_hash(&e.identity_hash)
                || (self.running && self.registered.get(id) != Some(&e.identity_hash))
            {
                return Err(ProxyFailure::Identity);
            }
            targets.push((id.clone(), pro));
        }
        if targets.is_empty() {
            return Err(ProxyFailure::Identity);
        }
        let mut next = self.preferences.clone();
        next.known_ids = trusted;
        for (id, pro) in targets {
            let policy = next.account_policies.entry(id).or_default();
            if pro {
                policy.seven_day_used_limit = limit;
            } else {
                policy.five_hour_used_limit = limit;
            }
        }
        self.validate_update(&next)?;
        Ok(next)
    }
    pub(crate) fn begin(
        &mut self,
        run_id: String,
        control_key: String,
    ) -> Result<Vec<(String, String)>, ProxyFailure> {
        if self.running || !self.run_id.is_empty() || !self.leases.is_empty() {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
        self.preferences.validate()?;
        let trusted = self.trusted_ids()?;
        if self
            .preferences
            .enabled_ids
            .iter()
            .any(|id| !trusted.contains(id))
        {
            return Err(ProxyFailure::Identity);
        }
        let mut registered = BTreeMap::new();
        for id in &trusted {
            match self.gate.registration(id) {
                Ok(e) if e.profile_id == *id && policy::valid_hash(&e.identity_hash) => {
                    registered.insert(id.clone(), e.identity_hash);
                }
                _ if self.preferences.enabled_ids.contains(id) => {
                    return Err(ProxyFailure::Identity)
                }
                _ => {}
            }
        }
        if registered.is_empty() || self.preferences.enabled_ids.is_empty() {
            return Err(ProxyFailure::Identity);
        }
        self.gate.activate_run(&run_id)?;
        self.registered = registered;
        self.memberships.clear();
        self.revocations.clear();
        self.credit_refresh_after.clear();
        self.run_id = run_id;
        self.control_key = control_key;
        self.running = true;
        Ok(self
            .registered
            .iter()
            .map(|(a, b)| (a.clone(), b.clone()))
            .collect())
    }
    pub(crate) fn stopping(&mut self) {
        self.running = false;
    }
    pub(crate) fn desktop_identity(
        &self,
        id: &str,
    ) -> Result<(String, String, String), ProxyFailure> {
        if !self.running || !self.trusted_ids()?.contains(id) {
            return Err(ProxyFailure::Unavailable);
        }
        let e = self.bound(id)?;
        if e.token_generation.is_empty() {
            return Err(ProxyFailure::Identity);
        }
        Ok((self.run_id.clone(), e.identity_hash, e.token_generation))
    }
    pub(crate) fn run_matches(&self, run: &str) -> bool {
        self.running && self.run_id == run
    }
    pub(crate) fn running_id(&self) -> Option<String> {
        self.running.then(|| self.run_id.clone())
    }
    pub(crate) fn registration_candidate(
        &self,
        id: &str,
    ) -> Result<AccountRegistration, ProxyFailure> {
        if !self.trusted_ids()?.contains(id) {
            return Err(ProxyFailure::Identity);
        }
        let candidate = self.gate.registration(id)?;
        if candidate.profile_id != id
            || !policy::valid_hash(&candidate.identity_hash)
            || candidate.identity_hash != candidate.identity_hash.to_ascii_lowercase()
            || self.registered.iter().any(|(other, identity)| {
                (other == id && identity != &candidate.identity_hash)
                    || (!self.registered.contains_key(id)
                        && other != id
                        && identity == &candidate.identity_hash)
            })
        {
            return Err(ProxyFailure::Identity);
        }
        Ok(candidate)
    }
    pub(crate) fn is_registered(&self, id: &str) -> bool {
        self.registered.contains_key(id)
    }
    /// Called only after the owned helper's matching registration acknowledgement.
    /// Existing request memberships remain frozen; new requests can discover it.
    pub(crate) fn commit_registration(
        &mut self,
        run: &str,
        id: &str,
        identity: &str,
    ) -> Result<(), ProxyFailure> {
        if !self.run_matches(run) {
            return Err(ProxyFailure::Stopping);
        }
        let current = self.registration_candidate(id)?;
        if current.identity_hash != identity || self.registered.len() >= 100 {
            return Err(ProxyFailure::Identity);
        }
        self.registered.insert(id.to_owned(), identity.to_owned());
        Ok(())
    }
    pub(crate) fn has_unretired_run(&self) -> bool {
        !self.run_id.is_empty() || !self.leases.is_empty()
    }
    pub(crate) fn retire(&mut self, confirmed: bool) -> Result<(), ProxyFailure> {
        self.running = false;
        if self.run_id.is_empty() {
            return Ok(());
        }
        self.gate.retire_run(&self.run_id, confirmed)?;
        if !confirmed {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
        self.memberships.clear();
        self.leases.clear();
        self.registered.clear();
        self.run_id.clear();
        self.control_key.clear();
        self.credit_refresh_after.clear();
        Ok(())
    }
    pub fn handle(&mut self, r: BridgeRequest) -> BridgeReply {
        self.handle_at(r, unix_now())
    }
    pub(crate) fn handle_at(&mut self, r: BridgeRequest, now: f64) -> BridgeReply {
        if r.schema_version != 1
            || r.run_id != self.run_id
            || !key_equal(&r.key, &self.control_key)
            || !valid_request_id(&r.request_id)
        {
            return BridgeReply::failure(ProxyFailure::Identity);
        }
        if r.command == "order_end" {
            if !r.profile_id.is_empty() || r.lease_id.is_some() {
                return BridgeReply::failure(ProxyFailure::Identity);
            }
            self.memberships.remove(&r.request_id);
            return BridgeReply::success();
        }
        if !self.registered.contains_key(&r.profile_id) {
            return BridgeReply::failure(ProxyFailure::Identity);
        }
        if r.command == "release" || r.command == "heartbeat" {
            let Some(id) = &r.lease_id else {
                return BridgeReply::failure(ProxyFailure::Identity);
            };
            let tuple = LeaseTuple {
                run_id: r.run_id,
                request_id: r.request_id,
                profile_id: r.profile_id,
                lease_id: id.clone(),
            };
            if self.leases.get(id) != Some(&tuple) {
                return BridgeReply::failure(ProxyFailure::Identity);
            }
            let result = if r.command == "release" {
                self.gate.release(&tuple)
            } else {
                self.gate.heartbeat(&tuple)
            };
            if let Err(e) = result {
                return BridgeReply::failure(e);
            }
            if r.command == "release" {
                self.leases.remove(id);
                self.credit_refresh_after.insert(tuple.profile_id, now);
            }
            return BridgeReply::success();
        }
        if r.lease_id.is_some() {
            return BridgeReply::failure(ProxyFailure::Identity);
        }
        if r.command == "acquire_resolve" {
            let tuple = LeaseTuple {
                run_id: r.run_id,
                request_id: r.request_id,
                profile_id: r.profile_id,
                lease_id: String::new(),
            };
            return match self.gate.resolve(&tuple) {
                Ok(AdmissionResolution::NotReserved) => BridgeReply {
                    resolution: Some("not_reserved"),
                    ..BridgeReply::success()
                },
                Ok(AdmissionResolution::RolledBack) => BridgeReply {
                    resolution: Some("abandoned"),
                    ..BridgeReply::success()
                },
                Ok(AdmissionResolution::Reserved(lease)) => {
                    if self.gate.release(&lease.tuple).is_ok() {
                        self.leases.remove(&lease.tuple.lease_id);
                        BridgeReply {
                            resolution: Some("abandoned"),
                            ..BridgeReply::success()
                        }
                    } else {
                        BridgeReply::failure(ProxyFailure::AdmissionUnknown)
                    }
                }
                _ => BridgeReply::failure(ProxyFailure::AdmissionUnknown),
            };
        }
        if !self.running {
            return BridgeReply::failure(ProxyFailure::Stopping);
        }
        if r.command == "order" {
            self.memberships
                .retain(|_, m| now >= m.captured && now - m.captured < 16.0 * 60.0);
            if !self.memberships.contains_key(&r.request_id) {
                if self.memberships.len() >= 1024 {
                    return BridgeReply::failure(ProxyFailure::ControlBusy);
                }
                let mut entries = Vec::new();
                for id in &self.preferences.enabled_ids {
                    if let Ok(e) = self.bound(id) {
                        if self.reset_paused(id, &e, now) {
                            continue;
                        }
                        let last = self.preferences.is_last(id, e.plan.as_deref());
                        let position = self
                            .preferences
                            .order
                            .iter()
                            .position(|v| v == id)
                            .unwrap_or(usize::MAX);
                        entries.push((
                            last,
                            !self.preferences.priority_ids.contains(id),
                            position,
                            id.clone(),
                        ));
                    }
                }
                entries.sort();
                let order: Vec<_> = entries.iter().map(|v| v.3.clone()).collect();
                let deferred = entries
                    .iter()
                    .filter(|v| v.0)
                    .map(|v| v.3.clone())
                    .collect();
                self.memberships.insert(
                    r.request_id.clone(),
                    Membership {
                        order,
                        deferred,
                        credits: self.preferences.credit_fallback,
                        revocations: self.revocations.clone(),
                        captured: now,
                    },
                );
            }
            let m = &self.memberships[&r.request_id];
            return BridgeReply {
                order: Some(m.order.clone()),
                deferred_ids: Some(m.deferred.clone()),
                last_resort_ids: Some(vec![]),
                credit_fallback: Some(m.credits),
                ..BridgeReply::success()
            };
        }
        if !self.preferences.enabled_ids.contains(&r.profile_id) {
            return BridgeReply::failure(ProxyFailure::NotParticipating);
        }
        if r.command == "quota_recovery" {
            return match self.bound(&r.profile_id).and_then(|e| {
                quota_admission(
                    &e,
                    &self.preferences.policy(&r.profile_id),
                    now,
                    None,
                    false,
                )?;
                Ok(e.quota.unwrap().observed_at)
            }) {
                Ok(observed) => BridgeReply {
                    quota_observed_at: Some(observed),
                    ..BridgeReply::success()
                },
                Err(e) => BridgeReply::failure(e),
            };
        }
        if r.command == "egress_probe" {
            return match self.gate.egress_probe(&r.profile_id) {
                Ok(p)
                    if matches!(p.status.as_str(), "reachable" | "forbidden")
                        && p.identity_hash == self.registered[&r.profile_id]
                        && p.observed_at.is_finite()
                        && (0.0..=120.0).contains(&(now - p.observed_at)) =>
                {
                    BridgeReply {
                        probe_status: Some(p.status),
                        probe_observed_at: Some(p.observed_at),
                        probe_identity_hash: Some(p.identity_hash),
                        ..BridgeReply::success()
                    }
                }
                _ => BridgeReply::failure(ProxyFailure::Unavailable),
            };
        }
        let pass = match r.command.as_str() {
            "acquire" => AdmissionPass::Subscription,
            "acquire_desktop" => AdmissionPass::DesktopSubscription,
            "acquire_credit_primary" => AdmissionPass::CreditPrimary,
            "acquire_credit_secondary" => AdmissionPass::CreditSecondary,
            "acquire_desktop_credit_primary" => AdmissionPass::DesktopCreditPrimary,
            "acquire_desktop_credit_secondary" => AdmissionPass::DesktopCreditSecondary,
            _ => return BridgeReply::failure(ProxyFailure::Identity),
        };
        let Some(m) = self.memberships.get(&r.request_id).cloned() else {
            return BridgeReply::failure(ProxyFailure::Identity);
        };
        if !m.order.contains(&r.profile_id) || now < m.captured || now - m.captured >= 16.0 * 60.0 {
            return BridgeReply::failure(ProxyFailure::Identity);
        }
        if m.revocations.get(&r.profile_id).copied().unwrap_or(0)
            != self.revocations.get(&r.profile_id).copied().unwrap_or(0)
        {
            return BridgeReply::failure(ProxyFailure::NotParticipating);
        }
        let evidence = match self.bound(&r.profile_id) {
            Ok(e) => e,
            Err(e) => return BridgeReply::failure(e),
        };
        if self.reset_paused(&r.profile_id, &evidence, now) {
            return BridgeReply::failure(ProxyFailure::NotParticipating);
        }
        if pass.desktop() != evidence.is_desktop
            || (pass.desktop() && !self.preferences.desktop_fallback)
        {
            return BridgeReply::failure(ProxyFailure::StageNotApplicable);
        }
        let policy = self.preferences.policy(&r.profile_id);
        let floor =
            if pass.credit() {
                if !m.credits || !self.preferences.credit_fallback || !policy.allows_credits {
                    return BridgeReply::failure(ProxyFailure::Quota);
                }
                for id in &m.order {
                    if !self.preferences.enabled_ids.contains(id)
                        || m.revocations.get(id).copied().unwrap_or(0)
                            != self.revocations.get(id).copied().unwrap_or(0)
                    {
                        continue;
                    }
                    let e = match self.bound(id) {
                        Ok(e) => e,
                        Err(e) => return BridgeReply::failure(e),
                    };
                    if self.credit_refresh_after.get(id).is_some_and(|after| {
                        e.quota.as_ref().is_none_or(|q| q.observed_at <= *after)
                    }) {
                        return BridgeReply::failure(ProxyFailure::QuotaUnknown);
                    }
                    match quota_admission(&e, &self.preferences.policy(id), now, None, true) {
                        Err(ProxyFailure::Quota | ProxyFailure::UsageLimit) => {}
                        Ok(()) => return BridgeReply::failure(ProxyFailure::SubscriptionPending),
                        Err(e) => return BridgeReply::failure(e),
                    }
                }
                if matches!(
                    pass,
                    AdmissionPass::CreditPrimary | AdmissionPass::DesktopCreditPrimary
                ) {
                    policy.credit_primary_floor
                } else {
                    policy.credit_secondary_floor
                }
            } else {
                None
            };
        if let Err(e) = quota_admission(
            &evidence,
            &policy,
            now,
            floor,
            self.preferences.credit_fallback,
        ) {
            return BridgeReply::failure(e);
        }
        let request = AdmissionRequest {
            run_id: r.run_id.clone(),
            request_id: r.request_id.clone(),
            profile_id: r.profile_id.clone(),
            expected_identity_hash: evidence.identity_hash.clone(),
            expected_generation: evidence.token_generation.clone(),
            pass,
            policy,
            credit_floor: floor,
            request_started_at_unix_ms: (m.captured * 1000.0) as u64,
            deadline_unix_ms: ((now + 18.0) * 1000.0) as u64,
        };
        match self.gate.reserve(&request) {
            Ok(lease) => {
                if lease.tuple.run_id != r.run_id
                    || lease.tuple.request_id != r.request_id
                    || lease.tuple.profile_id != r.profile_id
                    || !policy::valid_id(&lease.tuple.lease_id)
                    || lease.identity_hash != evidence.identity_hash
                    || lease.token_generation != evidence.token_generation
                    || lease.access_token.is_empty()
                    || lease.account_id.is_empty()
                    || lease.expires_at as f64 <= unix_now()
                {
                    if self.gate.release(&lease.tuple).is_err() {
                        return BridgeReply::failure(ProxyFailure::AdmissionUnknown);
                    }
                    return BridgeReply::failure(ProxyFailure::Identity);
                }
                self.leases
                    .insert(lease.tuple.lease_id.clone(), lease.tuple.clone());
                BridgeReply {
                    lease_id: Some(lease.tuple.lease_id),
                    access_token: Some(lease.access_token),
                    account_id: Some(lease.account_id),
                    expires_at: Some(lease.expires_at),
                    ..BridgeReply::success()
                }
            }
            Err(e) => BridgeReply::failure(e),
        }
    }
    fn bound(&self, id: &str) -> Result<AccountEvidence, ProxyFailure> {
        let e = self.gate.evidence(id)?;
        if e.profile_id != id
            || !e.identity_verified
            || e.is_system_home
            || self.registered.get(id) != Some(&e.identity_hash)
        {
            return Err(ProxyFailure::Identity);
        }
        Ok(e)
    }
    fn reset_paused(&self, id: &str, e: &AccountEvidence, now: f64) -> bool {
        self.preferences.reset_stop_rules.get(id).is_some_and(|r| {
            if r.identity_hash != e.identity_hash {
                return true;
            }
            r.paused_at.is_some()
                || (r.previous_reset_at.is_some_and(|reset| reset <= now)
                    && e.quota.as_ref().is_some_and(|q| {
                        q.observed_at > r.armed_at
                            && q.observed_at >= r.previous_reset_at.unwrap_or(f64::MAX)
                    }))
        })
    }
}
fn key_equal(a: &str, b: &str) -> bool {
    if a.len() != b.len() || b.len() < 24 {
        return false;
    }
    a.bytes().zip(b.bytes()).fold(0u8, |v, (a, b)| v | (a ^ b)) == 0
}
pub(crate) fn valid_request_id(s: &str) -> bool {
    s.len() == 36
        && s.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}
