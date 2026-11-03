use super::*;
#[derive(Clone, Deserialize, PartialEq)]
struct Grant {
    recipient: String,
    grant_type: String,
    amount: Option<f64>,
}
#[derive(Clone, Deserialize)]
struct Eligibility {
    should_show: bool,
    offer_id: Option<String>,
    title: Option<String>,
    description: Option<String>,
    #[serde(default)]
    rules: Vec<String>,
    #[serde(default)]
    grants: Vec<Grant>,
    remaining_send_capacity: Option<u32>,
    remaining_reward_capacity: Option<u32>,
    #[serde(default = "yes")]
    requires_explicit_confirmation: bool,
}
fn yes() -> bool {
    true
}
impl Eligibility {
    fn parse(bytes: &[u8]) -> AccountResult<Self> {
        let value: Self =
            serde_json::from_slice(bytes).map_err(|_| fail("referral_invalid_response"))?;
        if value.rules.len() > 30
            || value.grants.len() > 30
            || value
                .grants
                .iter()
                .any(|g| g.amount.is_some_and(|n| !n.is_finite() || n < 0.0))
        {
            return Err(fail("referral_invalid_response"));
        }
        Ok(value)
    }
    fn capacity(&self) -> u32 {
        let mut n = self.remaining_send_capacity.unwrap_or(0).min(5);
        if !self.grants.is_empty() || self.offer_id.as_deref().is_some_and(|v| v != "none") {
            n = n.min(self.remaining_reward_capacity.unwrap_or(0));
        }
        n
    }
    fn credit_amount(&self) -> Option<f64> {
        let amounts = self
            .grants
            .iter()
            .filter(|g| {
                g.recipient == "referrer"
                    && matches!(
                        g.grant_type.as_str(),
                        "personal_credits" | "workspace_credits"
                    )
            })
            .filter_map(|g| g.amount)
            .collect::<Vec<_>>();
        amounts
            .iter()
            .copied()
            .find(|n| *n > 0.0)
            .or_else(|| amounts.first().copied())
            .or_else(|| {
                if self.grants.is_empty() {
                    match self.offer_id.as_deref() {
                        Some("credits_250") => Some(250.0),
                        Some("credits_500") => Some(500.0),
                        Some("credits_1000") => Some(1000.0),
                        _ => None,
                    }
                } else {
                    None
                }
            })
    }
    fn same_offer(&self, other: &Self) -> bool {
        self.should_show == other.should_show
            && self.offer_id == other.offer_id
            && self.title == other.title
            && self.description == other.description
            && self.rules == other.rules
            && self.grants == other.grants
            && self.requires_explicit_confirmation == other.requires_explicit_confirmation
    }
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReferralReview {
    pub review_id: String,
    pub profile_id: String,
    pub checked_at_ms: i64,
    pub expires_at_ms: i64,
    pub should_show: bool,
    pub title: Option<String>,
    pub description: Option<String>,
    pub rules: Vec<String>,
    pub credit_amount: Option<f64>,
    pub invitation_capacity: u32,
    pub remaining_send_capacity: Option<u32>,
    pub remaining_reward_capacity: Option<u32>,
    pub requires_explicit_confirmation: bool,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReferralBatch {
    pub profile_id: String,
    pub sent: Vec<usize>,
    pub failed: Vec<usize>,
    pub uncertain: Vec<usize>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReferralRecord {
    pub id: String,
    pub masked_email: Option<String>,
    pub status: &'static str,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReferralPage {
    pub profile_id: String,
    pub items: Vec<ReferralRecord>,
    pub cursor: Option<String>,
}
#[derive(Clone)]
pub(super) struct Ticket {
    profile: String,
    identity: String,
    program: String,
    eligibility: Eligibility,
    expires: i64,
    result: Option<ReferralBatch>,
}
fn public_text(s: &str) -> String {
    s.split_whitespace()
        .map(|w| {
            if w.contains('@') || w.contains("://") || w.contains('\\') {
                "•••"
            } else {
                w
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .filter(|c| !c.is_control())
        .take(2048)
        .collect()
}
fn language(s: &str) -> AccountResult<()> {
    if matches!(s, "zh" | "en") {
        Ok(())
    } else {
        Err(fail("referral_invalid_request"))
    }
}
fn email(s: &str) -> bool {
    s.len() <= 254
        && !s.is_empty()
        && s.trim() == s
        && !s
            .chars()
            .any(|c| c.is_whitespace() || c.is_control() || ",;<>".contains(c))
        && s.matches('@').count() == 1
        && s.split_once('@').is_some_and(|(a, b)| {
            !a.is_empty() && b.contains('.') && !b.starts_with('.') && !b.ends_with('.')
        })
}
fn recipients(emails: &[String]) -> AccountResult<()> {
    let unique = emails
        .iter()
        .map(|s| s.to_lowercase())
        .collect::<BTreeSet<_>>();
    if emails.is_empty()
        || emails.len() > 5
        || unique.len() != emails.len()
        || !emails.iter().all(|s| email(s))
    {
        Err(fail("referral_invalid_email"))
    } else {
        Ok(())
    }
}
fn recipient_key(identity: &str, email: &str) -> String {
    auth_digest(format!("{identity}\0{}", email.to_lowercase()).as_bytes())
}
fn route(path: &str, query: &[(&str, &str)]) -> String {
    let mut q = url::form_urlencoded::Serializer::new(String::new());
    for (k, v) in query {
        q.append_pair(k, v);
    }
    let q = q.finish();
    if q.is_empty() {
        path.into()
    } else {
        format!("{path}?{q}")
    }
}
fn status(response: HttpResponse) -> AccountResult<Vec<u8>> {
    if (200..300).contains(&response.status) {
        return Ok(response.body);
    }
    Err(fail(match response.status {
        401 => "login_required",
        403 => "referral_permission_denied",
        409 => "referral_already_invited",
        429 => "referral_rate_limited",
        400 | 422 => "referral_invalid_email",
        _ => "referral_unavailable",
    }))
}
fn program(bytes: &[u8], account: &str) -> AccountResult<String> {
    let v: Value = serde_json::from_slice(bytes).map_err(|_| fail("referral_invalid_response"))?;
    let rows = v["accounts"]
        .as_array()
        .filter(|v| v.len() <= 1000)
        .ok_or_else(|| fail("referral_invalid_response"))?;
    let matches = rows
        .iter()
        .filter(|r| r["id"].as_str() == Some(account))
        .collect::<Vec<_>>();
    if matches.len() != 1 {
        return Err(fail("manual_action_identity_changed"));
    }
    match matches[0]["structure"]
        .as_str()
        .map(str::to_lowercase)
        .as_deref()
    {
        Some("personal") => Ok("codex_referral_consumer".into()),
        Some("workspace") => Ok("codex_referral_workspace".into()),
        _ => Err(fail("referral_unavailable")),
    }
}
fn parse_batch(
    bytes: &[u8],
    emails: &[String],
    rejection: bool,
    profile: &str,
) -> AccountResult<ReferralBatch> {
    let value: Value =
        serde_json::from_slice(bytes).map_err(|_| fail("referral_delivery_uncertain"))?;
    let object = if rejection { &value["detail"] } else { &value };
    let mut sent = BTreeSet::new();
    let mut failed = BTreeSet::new();
    if !rejection {
        let invites = object["invites"]
            .as_array()
            .filter(|v| v.len() <= emails.len())
            .ok_or_else(|| fail("referral_delivery_uncertain"))?;
        let mut ids = BTreeSet::new();
        for row in invites {
            let id = row
                .get("referral_id")
                .or_else(|| row.get("id"))
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty() && s.len() <= 512 && !s.chars().any(char::is_control))
                .ok_or_else(|| fail("referral_delivery_uncertain"))?;
            if !ids.insert(id) {
                return Err(fail("referral_delivery_uncertain"));
            }
            let address = row["email"]
                .as_str()
                .or_else(|| {
                    if emails.len() == 1 {
                        Some(emails[0].as_str())
                    } else {
                        None
                    }
                })
                .ok_or_else(|| fail("referral_delivery_uncertain"))?;
            let index = emails
                .iter()
                .position(|s| s.eq_ignore_ascii_case(address))
                .ok_or_else(|| fail("referral_delivery_uncertain"))?;
            if !sent.insert(index) {
                return Err(fail("referral_delivery_uncertain"));
            }
        }
    }
    if let Some(values) = object.get("failed_emails") {
        let rows = values
            .as_array()
            .filter(|v| v.len() <= emails.len())
            .ok_or_else(|| fail("referral_delivery_uncertain"))?;
        for row in rows {
            let address = row
                .as_str()
                .ok_or_else(|| fail("referral_delivery_uncertain"))?;
            let index = emails
                .iter()
                .position(|s| s.eq_ignore_ascii_case(address))
                .ok_or_else(|| fail("referral_delivery_uncertain"))?;
            if !failed.insert(index) || sent.contains(&index) {
                return Err(fail("referral_delivery_uncertain"));
            }
        }
    } else if rejection {
        return Err(fail("referral_delivery_uncertain"));
    }
    if rejection && failed.is_empty() {
        return Err(fail("referral_delivery_uncertain"));
    }
    Ok(ReferralBatch {
        profile_id: profile.into(),
        sent: sent.iter().copied().collect(),
        failed: failed.iter().copied().collect(),
        uncertain: (0..emails.len())
            .filter(|i| !sent.contains(i) && !failed.contains(i))
            .collect(),
    })
}
struct ParsedPage {
    dto: ReferralPage,
}
fn parse_page(bytes: &[u8], profile: &str, old_cursor: Option<&str>) -> AccountResult<ParsedPage> {
    let v: Value = serde_json::from_slice(bytes).map_err(|_| fail("referral_invalid_response"))?;
    let rows = v["items"]
        .as_array()
        .filter(|v| v.len() <= 100)
        .ok_or_else(|| fail("referral_invalid_response"))?;
    let mut ids = BTreeSet::new();
    let mut items = Vec::new();
    for row in rows {
        let id = row["referral_id"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= 512 && !s.chars().any(char::is_control))
            .ok_or_else(|| fail("referral_invalid_response"))?;
        if !ids.insert(id) {
            return Err(fail("referral_invalid_response"));
        }
        let address = match row.get("email") {
            None | Some(Value::Null) => None,
            Some(Value::String(s)) if email(s) => Some(s.clone()),
            _ => return Err(fail("referral_invalid_response")),
        };
        items.push(ReferralRecord {
            id: auth_digest(id.as_bytes()),
            masked_email: address.as_deref().map(crate::local_cli::masked_identity),
            status: match row["status"].as_str() {
                Some("pending") => "pending",
                Some("redeemed") => "redeemed",
                Some("expired") => "expired",
                _ => "unknown",
            },
        });
    }
    let cursor = match v.get("cursor") {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) if s.len() <= 2048 && !s.chars().any(char::is_control) => {
            if s.is_empty() {
                None
            } else {
                Some(s.clone())
            }
        }
        _ => return Err(fail("referral_invalid_response")),
    };
    if cursor.as_deref().is_some_and(|c| Some(c) == old_cursor) {
        return Err(fail("referral_invalid_response"));
    }
    Ok(ParsedPage {
        dto: ReferralPage {
            profile_id: profile.into(),
            items,
            cursor,
        },
    })
}
impl ManualAccountService {
    fn get_referral(&self, c: &Credential, path: String, lang: &str) -> AccountResult<Vec<u8>> {
        self.recheck(c)?;
        let response = self.runtime.http(
            &self.credential(&c.profile)?.value,
            &HttpRequest {
                path,
                method: "GET",
                body: None,
                language: lang.into(),
            },
            &|| self.recheck(c),
        )?;
        self.recheck(c)?;
        status(response)
    }
    fn load_offer(&self, c: &Credential, lang: &str) -> AccountResult<(String, Eligibility)> {
        language(lang)?;
        let p = program(
            &self.get_referral(c, "/wham/accounts/check".into(), lang)?,
            &c.value.identity.account_id,
        )?;
        let e = Eligibility::parse(&self.get_referral(
            c,
            route(
                "/referrals/invite/eligibility",
                &[("program_id", &p), ("entrypoint", "persistent")],
            ),
            lang,
        )?)?;
        Ok((p, e))
    }
    pub fn referral_eligibility(&self, profile: &str, lang: &str) -> AccountResult<ReferralReview> {
        let _operation = reserve_operation(&self.referral_operation, profile)?;
        let c = self.credential(profile)?;
        let (p, e) = self.load_offer(&c, lang)?;
        let checked = ms();
        let id = super::super::super::nonce()?;
        let dto = ReferralReview {
            review_id: id.clone(),
            profile_id: profile.into(),
            checked_at_ms: checked,
            expires_at_ms: checked + 120000,
            should_show: e.should_show,
            title: e.title.as_deref().map(public_text),
            description: e.description.as_deref().map(public_text),
            rules: e.rules.iter().map(|s| public_text(s)).collect(),
            credit_amount: e.credit_amount(),
            invitation_capacity: e.capacity(),
            remaining_send_capacity: e.remaining_send_capacity,
            remaining_reward_capacity: e.remaining_reward_capacity,
            requires_explicit_confirmation: e.requires_explicit_confirmation,
        };
        let mut ts = self
            .referrals
            .lock()
            .map_err(|_| fail("manual_action_busy"))?;
        ts.retain(|_, t| t.expires > checked || t.result.is_some());
        if ts.len() >= 64 {
            return Err(fail("manual_action_busy"));
        }
        ts.insert(
            id,
            Ticket {
                profile: profile.into(),
                identity: c.value.identity.identity_hash(),
                program: p,
                eligibility: e,
                expires: checked + 120000,
                result: None,
            },
        );
        Ok(dto)
    }
    pub fn send_referrals(
        &self,
        profile: &str,
        id: &str,
        emails: Vec<String>,
        consent: bool,
        lang: &str,
    ) -> AccountResult<ReferralBatch> {
        let _operation = reserve_operation(&self.referral_operation, profile)?;
        recipients(&emails)?;
        language(lang)?;
        let c = self.credential(profile)?;
        let t = self
            .referrals
            .lock()
            .map_err(|_| fail("manual_action_busy"))?
            .get(id)
            .cloned()
            .ok_or_else(|| fail("referral_review_expired"))?;
        if t.profile != profile || t.identity != c.value.identity.identity_hash() {
            return Err(fail("manual_action_identity_changed"));
        }
        if t.expires < ms() || t.result.is_some() {
            return Err(fail("referral_review_expired"));
        }
        let (p, e) = self.load_offer(&c, lang)?;
        if p != t.program || !e.same_offer(&t.eligibility) {
            return Err(fail("referral_offer_changed"));
        }
        if !e.should_show || emails.len() > e.capacity() as usize {
            return Err(fail("referral_capacity_reached"));
        }
        if e.requires_explicit_confirmation && !consent {
            return Err(fail("referral_consent_required"));
        }
        let keys = emails
            .iter()
            .map(|a| recipient_key(&t.identity, a))
            .collect::<Vec<_>>();
        edit_journal(&self.manager, |j| {
            if keys.iter().any(|k| j.referral_attempts.contains(k)) {
                return Err(fail("referral_reconciliation_required"));
            }
            j.referral_attempts.extend(keys.iter().cloned());
            Ok(())
        })?;
        let body = serde_json::to_vec(
            &serde_json::json!({"program_id":p,"entrypoint":"persistent","emails":emails}),
        )
        .map_err(|_| fail("referral_invalid_request"))?;
        let response = self.runtime.http(
            &self.credential(profile)?.value,
            &HttpRequest {
                path: "/referrals/invite".into(),
                method: "POST",
                body: Some(body),
                language: lang.into(),
            },
            &|| self.recheck(&c),
        );
        let uncertain = || ReferralBatch {
            profile_id: profile.into(),
            sent: Vec::new(),
            failed: Vec::new(),
            uncertain: (0..emails.len()).collect(),
        };
        let mut result = match response {
            Ok(r) if (200..300).contains(&r.status) => {
                parse_batch(&r.body, &emails, false, profile).unwrap_or_else(|_| uncertain())
            }
            Ok(r) if matches!(r.status, 400 | 422) => {
                parse_batch(&r.body, &emails, true, profile).unwrap_or_else(|_| uncertain())
            }
            Ok(r) if matches!(r.status, 401 | 403 | 409 | 429) => ReferralBatch {
                profile_id: profile.into(),
                sent: Vec::new(),
                failed: (0..emails.len()).collect(),
                uncertain: Vec::new(),
            },
            _ => uncertain(),
        };
        if self.recheck(&c).is_err() {
            result = uncertain();
        }
        // Only explicit rejected recipients may be tried again; unknown/sent stay claimed.
        edit_journal(&self.manager, |j| {
            for i in &result.failed {
                j.referral_attempts.remove(&keys[*i]);
            }
            Ok(())
        })?;
        let mut ts = self
            .referrals
            .lock()
            .map_err(|_| fail("manual_action_busy"))?;
        if let Some(t) = ts.get_mut(id) {
            t.result = Some(result.clone());
        }
        Ok(result)
    }
    fn tracking_bound(
        &self,
        c: &Credential,
        program: &str,
        period: &str,
        cursor: Option<&str>,
        lang: &str,
    ) -> AccountResult<ParsedPage> {
        if !matches!(period, "this_month" | "past_90_days")
            || cursor
                .is_some_and(|s| s.is_empty() || s.len() > 2048 || s.chars().any(char::is_control))
        {
            return Err(fail("referral_invalid_request"));
        }
        let mut query = vec![
            ("program_id", program),
            ("period", period),
            ("limit", "100"),
        ];
        if let Some(c) = cursor {
            query.push(("cursor", c));
        }
        parse_page(
            &self.get_referral(c, route("/referrals/invite/tracking", &query), lang)?,
            &c.profile,
            cursor,
        )
    }
    pub fn referral_tracking(
        &self,
        profile: &str,
        period: &str,
        cursor: Option<&str>,
        lang: &str,
    ) -> AccountResult<ReferralPage> {
        language(lang)?;
        let c = self.credential(profile)?;
        let p = program(
            &self.get_referral(&c, "/wham/accounts/check".into(), lang)?,
            &c.value.identity.account_id,
        )?;
        Ok(self.tracking_bound(&c, &p, period, cursor, lang)?.dto)
    }
    pub fn check_referral_outcome(
        &self,
        profile: &str,
        id: &str,
        lang: &str,
    ) -> AccountResult<ReferralBatch> {
        let _operation = reserve_operation(&self.referral_operation, profile)?;
        language(lang)?;
        let c = self.credential(profile)?;
        let t = self
            .referrals
            .lock()
            .map_err(|_| fail("manual_action_busy"))?
            .get(id)
            .cloned()
            .ok_or_else(|| fail("referral_reconciliation_required"))?;
        if t.profile != profile || t.identity != c.value.identity.identity_hash() {
            return Err(fail("manual_action_identity_changed"));
        }
        let mut result = t
            .result
            .ok_or_else(|| fail("referral_reconciliation_required"))?;
        let mut cursor = None;
        let mut seen = BTreeSet::new();
        for _ in 0..3 {
            let page =
                self.tracking_bound(&c, &t.program, "past_90_days", cursor.as_deref(), lang)?;
            // Tracking is historical and has no proven binding to this send.
            // Even a matching pending/redeemed email cannot confirm this attempt.
            let Some(next) = page.dto.cursor else { break };
            if !seen.insert(next.clone()) {
                return Err(fail("referral_invalid_response"));
            }
            cursor = Some(next);
        }
        result.sent.sort_unstable();
        self.recheck(&c)?;
        if let Some(t) = self
            .referrals
            .lock()
            .map_err(|_| fail("manual_action_busy"))?
            .get_mut(id)
        {
            t.result = Some(result.clone());
        }
        Ok(result)
    }
}
