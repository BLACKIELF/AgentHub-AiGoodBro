use super::{
    domain::*,
    fail,
    storage::{ChannelConfig, PersonalBinding},
    transport::*,
    Failure, Result,
};
use serde_json::{json, Value};
use url::Url;

pub(crate) fn valid_token(s: &str, max: usize) -> bool {
    !s.is_empty() && s.len() <= max && s.bytes().all(|b| (33..=126).contains(&b))
}
pub(crate) fn ilink_id(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 256
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"@._-".contains(&b))
}
pub(crate) fn ilink_base(s: &str) -> Result<Url> {
    let u = Url::parse(s).map_err(|_| Failure("invalid_wechat_endpoint"))?;
    let h = u.host_str().unwrap_or("");
    let part = h
        .strip_prefix("ilink")
        .and_then(|s| s.strip_suffix(".weixin.qq.com"));
    if u.scheme() != "https"
        || !u.username().is_empty()
        || u.password().is_some()
        || u.port_or_known_default() != Some(443)
        || u.query().is_some()
        || u.fragment().is_some()
        || !matches!(u.path(), "" | "/")
        || part.is_none_or(|s| {
            !s.bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        })
    {
        return fail("invalid_wechat_endpoint");
    }
    Ok(u)
}
fn feishu_url(s: &str) -> Result<Url> {
    let u = Url::parse(s).map_err(|_| Failure("invalid_credential"))?;
    let token = u
        .path()
        .strip_prefix("/open-apis/bot/v2/hook/")
        .unwrap_or("");
    if s.len() > 512
        || s.chars().any(char::is_whitespace)
        || u.scheme() != "https"
        || !matches!(u.host_str(), Some("open.feishu.cn" | "open.larksuite.com"))
        || !u.username().is_empty()
        || u.password().is_some()
        || u.port_or_known_default() != Some(443)
        || u.query().is_some()
        || u.fragment().is_some()
        || !(16..=256).contains(&token.len())
        || !token
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_".contains(&b))
    {
        return fail("invalid_credential");
    }
    Ok(u)
}
pub(crate) fn validate_credential(
    kind: ChannelKind,
    secret: &str,
    target: Option<&str>,
    binding: Option<&PersonalBinding>,
) -> Result<()> {
    match kind {
        ChannelKind::Feishu => {
            feishu_url(secret)?;
        }
        ChannelKind::Telegram => {
            let Some((id, token)) = secret.split_once(':') else {
                return fail("invalid_credential");
            };
            if !(5..=12).contains(&id.len())
                || !id.bytes().all(|b| b.is_ascii_digit())
                || !(30..=64).contains(&token.len())
                || !token
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
            {
                return fail("invalid_credential");
            }
            let t = target.ok_or(Failure("missing_target"))?;
            let digits = t.strip_prefix('-').unwrap_or(t);
            let number = !digits.is_empty()
                && digits.len() <= 15
                && digits.bytes().all(|b| b.is_ascii_digit())
                && digits != "0";
            let user = t.strip_prefix('@').unwrap_or(t);
            let username = (4..=32).contains(&user.len())
                && user.as_bytes()[0].is_ascii_alphabetic()
                && user.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_');
            if !number && !username {
                return fail("invalid_target");
            }
        }
        ChannelKind::WeCom => {
            if secret.len() != 36
                || secret.bytes().enumerate().any(|(i, b)| {
                    if [8, 13, 18, 23].contains(&i) {
                        b != b'-'
                    } else {
                        !b.is_ascii_digit() && !(b'a'..=b'f').contains(&b)
                    }
                })
            {
                return fail("invalid_credential");
            }
        }
        ChannelKind::PersonalWeChat => {
            if !valid_token(secret, 4096) {
                return fail("invalid_credential");
            }
            let b = binding.ok_or(Failure("wechat_binding_required"))?;
            ilink_base(&b.base_url)?;
            if !ilink_id(&b.bot_id)
                || !ilink_id(&b.user_id)
                || target != Some(b.user_id.as_str())
                || b.cursor.len() > 8192
                || b.context_token
                    .as_ref()
                    .is_some_and(|s| !valid_token(s, 8192))
            {
                return fail("invalid_wechat_binding");
            }
        }
    }
    Ok(())
}
pub(crate) fn send_request(
    kind: ChannelKind,
    c: &ChannelConfig,
    event: &NotificationEvent,
) -> Result<TransportRequest> {
    let secret = c.secret.as_deref().ok_or(Failure("missing_credential"))?;
    validate_credential(kind, secret, c.target.as_deref(), c.binding.as_ref())?;
    let options = if kind == ChannelKind::Telegram {
        MessageOptions::default()
    } else {
        c.options.clone()
    };
    let (title, template, lines) = event.content(&options);
    let mut all = vec![title.clone()];
    all.extend(lines.clone());
    let text = format!("{}\n\n消息来源：aigoodbro.com", all.join("\n"));
    if text.len() > 4096 || text.encode_utf16().count() > 4096 {
        return fail("message_too_long");
    }
    let (url, body) = match kind {
        ChannelKind::Feishu => {
            let mut sections = lines;
            sections.push("aigoodbro.com".into());
            (
                feishu_url(secret)?,
                json!({"msg_type":"interactive","card":{"config":{"wide_screen_mode":true},"header":{"template":template,"title":{"tag":"plain_text","content":title}},"elements":[{"tag":"div","text":{"tag":"lark_md","content":sections.join("\n\n")}}]}}),
            )
        }
        ChannelKind::Telegram => {
            let target = c.target.as_ref().unwrap();
            let numeric = target
                .strip_prefix('-')
                .unwrap_or(target)
                .bytes()
                .all(|b| b.is_ascii_digit());
            let target = if !target.starts_with('@') && !numeric {
                format!("@{target}")
            } else {
                target.clone()
            };
            (
                Url::parse(&format!("https://api.telegram.org/bot{secret}/sendMessage"))
                    .map_err(|_| Failure("invalid_credential"))?,
                json!({"chat_id":target,"text":text,"disable_web_page_preview":true}),
            )
        }
        ChannelKind::WeCom => (
            Url::parse(&format!(
                "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key={secret}"
            ))
            .map_err(|_| Failure("invalid_credential"))?,
            json!({"msgtype":"markdown","markdown":{"content":text}}),
        ),
        ChannelKind::PersonalWeChat => {
            let b = c.binding.as_ref().unwrap();
            let ctx = b
                .context_token
                .as_deref()
                .ok_or(Failure("wechat_context_required"))?;
            if super::now() - event.at > 120 {
                return fail("stale_notification");
            }
            if b.context_checked_at.is_none_or(|at| at > super::now() + 60) {
                return fail("wechat_context_required");
            }
            let req = ilink_request(
                &b.base_url,
                "sendmessage",
                Some(secret),
                json!({"msg":{"from_user_id":"","to_user_id":b.user_id,"client_id":format!("aigoodbro-{}",event.key),"message_type":2,"message_state":2,"context_token":ctx,"item_list":[{"type":1,"text_item":{"text":text}}]}}),
                false,
            )?;
            return Ok(req);
        }
    };
    Ok(TransportRequest::json("POST", url, body, 12))
}
pub(crate) fn ilink_request(
    base: &str,
    method: &str,
    token: Option<&str>,
    mut body: Value,
    no_info: bool,
) -> Result<TransportRequest> {
    if !matches!(
        method,
        "get_bot_qrcode" | "get_qrcode_status" | "getupdates" | "sendmessage"
    ) {
        return fail("invalid_wechat_method");
    }
    let mut url = ilink_base(base)?;
    url.set_path(&format!("/ilink/bot/{method}"));
    if !no_info {
        body["base_info"] = json!({"channel_version":"2.4.9","bot_agent":"AiGoodBro/9.6.45"});
    }
    let mut r = TransportRequest::json(
        "POST",
        url,
        body,
        if matches!(method, "getupdates" | "get_qrcode_status") {
            40
        } else {
            12
        },
    );
    r.headers.push(("iLink-App-Id".into(), "bot".into()));
    r.headers.push((
        "iLink-App-ClientVersion".into(),
        ((2u32 << 16) | (4 << 8) | 9).to_string(),
    ));
    if let Some(token) = token {
        if !valid_token(token, 4096) {
            return fail("invalid_credential");
        }
        r.headers
            .push(("AuthorizationType".into(), "ilink_bot_token".into()));
        r.headers
            .push(("Authorization".into(), format!("Bearer {token}")));
        let mut random = [0u8; 4];
        getrandom::fill(&mut random).map_err(|_| Failure("entropy_unavailable"))?;
        use base64::Engine;
        r.headers.push((
            "X-WECHAT-UIN".into(),
            base64::engine::general_purpose::STANDARD
                .encode(u32::from_le_bytes(random).to_string()),
        ));
    }
    Ok(r)
}
pub(crate) enum Accepted {
    Ok(Option<String>),
    Rejected(Failure),
    Uncertain(Failure),
}
pub(crate) fn parse_response(kind: ChannelKind, r: TransportResponse) -> Accepted {
    if r.body.len() > 65536 {
        return Accepted::Uncertain(Failure("invalid_response"));
    }
    if (300..400).contains(&r.status) {
        return Accepted::Uncertain(Failure("redirected"));
    }
    if r.status == 429 {
        return Accepted::Rejected(Failure("rate_limited"));
    }
    if !(200..300).contains(&r.status) {
        return Accepted::Uncertain(Failure("http_status"));
    }
    let Ok(v) = serde_json::from_slice::<Value>(&r.body) else {
        return Accepted::Uncertain(Failure("invalid_response"));
    };
    match kind {
        ChannelKind::Telegram => match v["ok"].as_bool() {
            Some(true) if v["result"].is_object() => {
                Accepted::Ok(v["result"]["message_id"].as_i64().map(|i| i.to_string()))
            }
            Some(false) if v["error_code"].as_i64().is_some() => Accepted::Rejected(Failure(
                if v["parameters"]["retry_after"].as_u64().is_some() {
                    "rate_limited"
                } else {
                    "rejected"
                },
            )),
            _ => Accepted::Uncertain(Failure("invalid_response")),
        },
        ChannelKind::WeCom => match v["errcode"].as_i64() {
            Some(0) => Accepted::Ok(None),
            Some(45009) => Accepted::Rejected(Failure("rate_limited")),
            Some(_) => Accepted::Rejected(Failure("rejected")),
            _ => Accepted::Uncertain(Failure("invalid_response")),
        },
        ChannelKind::Feishu => match v["code"].as_i64().or_else(|| v["StatusCode"].as_i64()) {
            Some(0) => Accepted::Ok(None),
            Some(_) => Accepted::Rejected(Failure("rejected")),
            _ => Accepted::Uncertain(Failure("invalid_response")),
        },
        ChannelKind::PersonalWeChat => match ilink_response(&v, true) {
            Ok(()) => Accepted::Ok(None),
            Err(e) if e.0 == "invalid_response" => Accepted::Uncertain(e),
            Err(e) => Accepted::Rejected(e),
        },
    }
}
pub(crate) fn ilink_response(v: &Value, requires_acceptance: bool) -> Result<()> {
    let Some(object) = v.as_object() else {
        return fail("invalid_response");
    };
    for key in ["ret", "errcode"] {
        if let Some(code) = v.get(key) {
            match code.as_i64() {
                Some(0) => (),
                Some(-14) => return fail("wechat_session_expired"),
                Some(_) => return fail("rejected"),
                None => return fail("invalid_response"),
            }
        }
    }
    let id = v["message_id"].as_u64().is_some_and(|n| n > 0)
        || v["message_id"]
            .as_str()
            .is_some_and(|s| valid_token(s, 256));
    if requires_acceptance
        && !object.is_empty()
        && v.get("ret").is_none()
        && v.get("errcode").is_none()
        && !id
    {
        return fail("invalid_response");
    }
    Ok(())
}
