use super::{
    domain::*, fail, protocol, service::NotificationService, storage::PersonalBinding, Failure,
    Result,
};
use serde::Serialize;
use serde_json::{json, Value};
use std::sync::{atomic::Ordering, Arc};

pub(crate) struct LoginAttempt {
    pub id: String,
    pub phase: &'static str,
    pub reference: String,
    pub qr: String,
    pub base: String,
    pub revision: u64,
    pub expires_at: i64,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PersonalLoginDto {
    pub attempt_id: String,
    pub phase: &'static str,
    pub qr_content: Option<String>,
    pub expires_at: i64,
}
impl LoginAttempt {
    fn dto(&self) -> PersonalLoginDto {
        PersonalLoginDto {
            attempt_id: self.id.clone(),
            phase: self.phase,
            qr_content: (!self.qr.is_empty()
                && matches!(self.phase, "waiting" | "scanned" | "verification_required"))
            .then(|| self.qr.clone()),
            expires_at: self.expires_at,
        }
    }
}
fn object(response: super::TransportResponse) -> Result<Value> {
    if (300..400).contains(&response.status) {
        return fail("redirected");
    }
    if response.status == 429 {
        return fail("rate_limited");
    }
    if !(200..300).contains(&response.status) || response.body.len() > 65536 {
        return fail("invalid_response");
    }
    let value = serde_json::from_slice(&response.body).map_err(|_| Failure("invalid_response"))?;
    protocol::ilink_response(&value, false)?;
    Ok(value)
}

impl NotificationService {
    pub fn begin_personal_wechat_login(self: &Arc<Self>) -> Result<PersonalLoginDto> {
        let (op, _) = self.operation(ChannelKind::PersonalWeChat)?;
        {
            let mut state = self
                .state
                .lock()
                .map_err(|_| Failure("notification_busy"))?;
            if self.personal_text_active.load(Ordering::Acquire) {
                return fail("notification_busy");
            }
            if state.login.as_ref().is_some_and(|a| {
                a.expires_at > super::now()
                    && matches!(
                        a.phase,
                        "starting" | "waiting" | "scanned" | "verification_required"
                    )
            }) {
                return fail("wechat_login_in_progress");
            }
            state.login = Some(LoginAttempt {
                id: op.id.clone(),
                phase: "starting",
                reference: String::new(),
                qr: String::new(),
                base: "https://ilinkai.weixin.qq.com".into(),
                revision: op.revision,
                expires_at: super::now() + 300,
            });
        }
        let result = (|| {
            let mut request = protocol::ilink_request(
                "https://ilinkai.weixin.qq.com",
                "get_bot_qrcode",
                None,
                json!({"local_token_list":[]}),
                true,
            )?;
            request.url.query_pairs_mut().append_pair("bot_type", "3");
            let response = object(self.transport.send(&request, &op.cancelled)?)?;
            op.current()?;
            let reference = response["qrcode"]
                .as_str()
                .filter(|s| protocol::valid_token(s, 4096))
                .ok_or(Failure("invalid_response"))?;
            let qr = response["qrcode_img_content"]
                .as_str()
                .filter(|s| !s.is_empty() && s.len() <= 4096 && !s.chars().any(char::is_control))
                .ok_or(Failure("invalid_response"))?;
            let mut state = self
                .state
                .lock()
                .map_err(|_| Failure("notification_busy"))?;
            op.current()?;
            let attempt = state
                .login
                .as_mut()
                .filter(|a| a.id == op.id && a.phase == "starting")
                .ok_or(Failure("wechat_login_not_current"))?;
            attempt.phase = "waiting";
            attempt.reference = reference.into();
            attempt.qr = qr.into();
            Ok(attempt.dto())
        })();
        if result.is_err() {
            if let Ok(mut state) = self.state.lock() {
                if let Some(a) = state
                    .login
                    .as_mut()
                    .filter(|a| a.id == op.id && a.phase == "starting")
                {
                    a.phase = "failed";
                    a.reference.clear();
                    a.qr.clear();
                }
            }
        }
        result
    }
    pub fn personal_wechat_login(&self, attempt_id: &str) -> Result<PersonalLoginDto> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| Failure("notification_busy"))?;
        let a = state
            .login
            .as_mut()
            .filter(|a| a.id == attempt_id)
            .ok_or(Failure("wechat_login_not_found"))?;
        if super::now() > a.expires_at
            && matches!(a.phase, "waiting" | "scanned" | "verification_required")
        {
            a.phase = "local_timeout";
            a.reference.clear();
            a.qr.clear();
        }
        Ok(a.dto())
    }
    pub fn poll_personal_wechat_login(
        self: &Arc<Self>,
        attempt_id: &str,
        verification_code: Option<String>,
    ) -> Result<PersonalLoginDto> {
        if verification_code
            .as_ref()
            .is_some_and(|s| !(4..=10).contains(&s.len()) || !s.bytes().all(|b| b.is_ascii_digit()))
        {
            return fail("invalid_verification_code");
        }
        let (op, _) = self.operation(ChannelKind::PersonalWeChat)?;
        let (base, reference) = {
            let state = self
                .state
                .lock()
                .map_err(|_| Failure("notification_busy"))?;
            let a = state
                .login
                .as_ref()
                .filter(|a| {
                    a.id == attempt_id
                        && a.revision == op.revision
                        && a.expires_at > super::now()
                        && matches!(a.phase, "waiting" | "scanned" | "verification_required")
                })
                .ok_or(Failure("wechat_login_not_current"))?;
            (a.base.clone(), a.reference.clone())
        };
        let mut request =
            protocol::ilink_request(&base, "get_qrcode_status", None, json!({}), true)?;
        request.method = "GET";
        request.body.clear();
        request
            .url
            .query_pairs_mut()
            .append_pair("qrcode", &reference);
        if let Some(code) = verification_code {
            request
                .url
                .query_pairs_mut()
                .append_pair("verify_code", &code);
        }
        let value = object(self.transport.send(&request, &op.cancelled)?)?;
        op.current()?;
        let mut state = self
            .state
            .lock()
            .map_err(|_| Failure("notification_busy"))?;
        let a = state
            .login
            .as_mut()
            .filter(|a| {
                a.id == attempt_id
                    && a.revision == op.revision
                    && !matches!(a.phase, "cancelled" | "confirmed")
            })
            .ok_or(Failure("wechat_login_not_current"))?;
        op.current()?;
        a.phase = match value["status"].as_str() {
            Some("wait") => "waiting",
            Some("scaned") => "scanned",
            Some("expired") => "expired",
            Some("need_verifycode") => "verification_required",
            Some("verify_code_blocked") => "verification_blocked",
            Some("binded_redirect") => "already_bound",
            Some("scaned_but_redirect") => {
                let host = value["redirect_host"]
                    .as_str()
                    .ok_or(Failure("invalid_response"))?;
                let base = format!("https://{host}");
                protocol::ilink_base(&base)?;
                a.base = base;
                "scanned"
            }
            Some("confirmed") => {
                let token = value["bot_token"]
                    .as_str()
                    .ok_or(Failure("invalid_response"))?
                    .to_owned();
                let bot = value["ilink_bot_id"]
                    .as_str()
                    .ok_or(Failure("invalid_response"))?
                    .to_owned();
                let user = value["ilink_user_id"]
                    .as_str()
                    .ok_or(Failure("invalid_response"))?
                    .to_owned();
                let base = value["baseurl"]
                    .as_str()
                    .unwrap_or("https://ilinkai.weixin.qq.com")
                    .to_owned();
                let binding = PersonalBinding {
                    base_url: base,
                    bot_id: bot,
                    user_id: user.clone(),
                    context_token: None,
                    context_checked_at: None,
                    cursor: String::new(),
                };
                protocol::validate_credential(
                    ChannelKind::PersonalWeChat,
                    &token,
                    Some(&user),
                    Some(&binding),
                )?;
                self.storage.change(|v| {
                    let c = v
                        .configs
                        .get_mut(&ChannelKind::PersonalWeChat)
                        .filter(|c| c.enabled && c.revision == op.revision)
                        .ok_or(Failure("configuration_changed"))?;
                    c.secret = Some(token);
                    c.target = Some(user);
                    c.binding = Some(binding);
                    c.session_expired = false;
                    c.revision = c
                        .revision
                        .checked_add(1)
                        .ok_or(Failure("notification_store_invalid"))?;
                    Ok(())
                })?;
                "confirmed"
            }
            _ => return fail("invalid_response"),
        };
        if !matches!(a.phase, "waiting" | "scanned" | "verification_required") {
            a.reference.clear();
            a.qr.clear();
        }
        Ok(a.dto())
    }
    /// Updates bind notification context only to this scanner's own user/bot.
    /// Incoming conversation text is intentionally neither returned nor stored
    /// by this notification backend; it cannot issue account/model commands.
    pub fn refresh_personal_wechat_context(self: &Arc<Self>) -> Result<ChannelState> {
        self.refresh_personal_wechat_context_owned(
            &std::sync::atomic::AtomicBool::new(false),
            &std::sync::Mutex::new(None),
        )
    }
    pub(crate) fn refresh_personal_wechat_context_owned(
        self: &Arc<Self>,
        stop: &std::sync::atomic::AtomicBool,
        active: &std::sync::Mutex<Option<Arc<std::sync::atomic::AtomicBool>>>,
    ) -> Result<ChannelState> {
        let (op, c) = self.operation(ChannelKind::PersonalWeChat)?;
        *active.lock().map_err(|_| Failure("notification_busy"))? = Some(op.cancelled.clone());
        if stop.load(std::sync::atomic::Ordering::Acquire) {
            op.cancelled
                .store(true, std::sync::atomic::Ordering::Release);
            return fail("cancelled");
        }
        if c.session_expired {
            return fail("wechat_session_expired");
        }
        let secret = c.secret.as_deref().ok_or(Failure("missing_credential"))?;
        let b = c
            .binding
            .as_ref()
            .ok_or(Failure("wechat_binding_required"))?;
        protocol::validate_credential(
            ChannelKind::PersonalWeChat,
            secret,
            c.target.as_deref(),
            Some(b),
        )?;
        let request = protocol::ilink_request(
            &b.base_url,
            "getupdates",
            Some(secret),
            json!({"get_updates_buf":b.cursor}),
            false,
        )?;
        let value = match object(self.transport.send(&request, &op.cancelled)?) {
            Ok(v) => v,
            Err(e) => {
                if e.0 == "wechat_session_expired" {
                    self.expire_personal_session(c.revision)?;
                }
                return Err(e);
            }
        };
        op.current()?;
        if value.get("msgs").is_some_and(|v| !v.is_array())
            || value.get("get_updates_buf").is_some_and(|v| !v.is_string())
        {
            return fail("invalid_response");
        }
        let messages = value["msgs"].as_array().map(Vec::as_slice).unwrap_or(&[]);
        if messages.len() > 256 {
            return fail("invalid_response");
        }
        let mut next = b.clone();
        for m in messages {
            if m["message_type"].as_i64() != Some(1)
                || m["from_user_id"].as_str() != Some(&b.user_id)
                || m.get("to_user_id")
                    .is_some_and(|s| s.as_str() != Some(&b.bot_id))
            {
                continue;
            }
            let Some(token) = m["context_token"]
                .as_str()
                .filter(|s| protocol::valid_token(s, 8192))
            else {
                continue;
            };
            let Some(ms) = m["create_time_ms"].as_i64().filter(|n| *n > 0) else {
                continue;
            };
            let at = ms / 1000;
            if at > super::now() + 60 || next.context_checked_at.is_some_and(|old| at < old) {
                continue;
            }
            next.context_token = Some(token.into());
            next.context_checked_at = Some(at);
        }
        if let Some(cursor) = value["get_updates_buf"].as_str().filter(|s| !s.is_empty()) {
            if !protocol::valid_token(cursor, 8192) {
                return fail("invalid_response");
            }
            next.cursor = cursor.into();
        }
        {
            let _state = self
                .state
                .lock()
                .map_err(|_| Failure("notification_busy"))?;
            op.current()?;
            self.storage.change(|v| {
                let current = v
                    .configs
                    .get_mut(&ChannelKind::PersonalWeChat)
                    .filter(|r| r.enabled && r.revision == op.revision)
                    .ok_or(Failure("configuration_changed"))?;
                if current.binding.as_ref() != Some(b) {
                    return fail("wechat_context_changed");
                }
                current.binding = Some(next);
                Ok(())
            })?;
        }
        self.channel_state(ChannelKind::PersonalWeChat)
    }
}
