use super::super::{fail, Failure, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use url::Url;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Source {
    pub kind: String,
    pub author: Option<String>,
    pub url: Option<String>,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Announcement {
    pub id: String,
    pub banked: bool,
    pub at: i64,
    pub text: String,
    pub source: Source,
}
impl Announcement {
    pub fn valid(&self, now: i64) -> bool {
        let id = &self.id;
        if id.is_empty()
            || id.chars().count() > 64
            || !id
                .chars()
                .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
            || self.text.is_empty()
            || self.text.len() > 16384
            || self.at <= 1_700_000_000_000
            || self.at > now + 300000
        {
            return false;
        }
        match self.source.kind.as_str() {
            "x_post" => {
                self.source.author.as_deref() == Some("thsottiaux")
                    && self
                        .source
                        .url
                        .as_deref()
                        .is_some_and(|u| history_source_id(u).as_deref() == Some(id.as_str()))
                    && id.bytes().all(|b| b.is_ascii_digit())
            }
            "observed" => {
                self.source.author.is_none()
                    && id.starts_with("observed-")
                    && self
                        .source
                        .url
                        .as_deref()
                        .is_none_or(|u| history_source_id(u).is_some())
            }
            _ => false,
        }
    }
    pub fn has_text(&self) -> bool {
        !self.text.trim().is_empty() && self.text != "public-announcement"
    }
    pub fn safe(&self) -> Self {
        let mut a = self.clone();
        a.text = safe_public_text(&a.text);
        if a.text.is_empty() {
            a.text = "public-announcement".into();
        }
        a
    }
}
#[derive(Clone)]
pub(crate) struct Page {
    pub rows: Vec<Announcement>,
    pub has_more: bool,
    pub cursor: Option<String>,
}
fn date(s: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|d| d.timestamp_millis())
}
pub(crate) fn cursor_valid(s: &str) -> bool {
    !s.is_empty() && s.len() <= 2048 && !s.chars().any(char::is_control)
}
pub(crate) fn page(bytes: &[u8], now: i64) -> Result<Page> {
    #[derive(Deserialize)]
    struct Meta {
        api_version: String,
        generated_at: String,
    }
    #[derive(Deserialize)]
    struct Pagination {
        has_more: bool,
        next_cursor: Option<String>,
    }
    #[derive(Deserialize)]
    struct RawSource {
        #[serde(rename = "type")]
        kind: String,
        author: Option<String>,
        url: Option<String>,
    }
    #[derive(Deserialize)]
    struct Row {
        id: String,
        reset_type: String,
        announced_at: String,
        text: String,
        source: RawSource,
    }
    #[derive(Deserialize)]
    struct Raw {
        data: Vec<Row>,
        pagination: Pagination,
        meta: Meta,
    }
    if bytes.len() > 512 * 1024 {
        return fail("public_reset_invalid_response");
    }
    let p: Raw =
        serde_json::from_slice(bytes).map_err(|_| Failure("public_reset_invalid_response"))?;
    if p.meta.api_version != "v1"
        || date(&p.meta.generated_at).is_none_or(|at| now.abs_diff(at) > 86400000)
        || p.data.len() > 100
        || p.pagination
            .next_cursor
            .as_ref()
            .is_some_and(|c| !cursor_valid(c))
    {
        return fail("public_reset_invalid_response");
    }
    let mut seen = BTreeSet::new();
    let mut rows = Vec::new();
    for r in p.data {
        let banked = match r.reset_type.as_str() {
            "regular" => false,
            "banked" => true,
            _ => return fail("public_reset_invalid_response"),
        };
        let a = Announcement {
            id: r.id,
            banked,
            at: date(&r.announced_at).ok_or(Failure("public_reset_invalid_response"))?,
            text: r.text,
            source: Source {
                kind: r.source.kind,
                author: r.source.author,
                url: r.source.url,
            },
        };
        if !a.valid(now) || !seen.insert(a.id.clone()) {
            return fail("public_reset_invalid_response");
        }
        rows.push(a);
    }
    Ok(Page {
        rows,
        has_more: p.pagination.has_more,
        cursor: p.pagination.next_cursor,
    })
}
fn history_source_id(s: &str) -> Option<String> {
    source_path_id(s, 64)
}
fn source_path_id(s: &str, max: usize) -> Option<String> {
    let u = Url::parse(s).ok()?;
    if u.scheme() != "https"
        || u.host_str() != Some("x.com")
        || !u.username().is_empty()
        || u.password().is_some()
        || u.port().is_some()
        || u.query().is_some()
        || u.fragment().is_some()
    {
        return None;
    }
    let id = u.path().strip_prefix("/thsottiaux/status/")?;
    if id.is_empty() || id.len() > max || !id.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    if s != format!("https://x.com/thsottiaux/status/{id}") {
        return None;
    }
    Some(id.into())
}
pub(crate) fn source_id(s: &str) -> Option<String> {
    let id = source_path_id(s, 20)?;
    id.parse::<u64>().ok()?;
    Some(id)
}
pub(crate) fn post_at(id: &str) -> Option<i64> {
    let n = id.parse::<u64>().ok()?;
    i64::try_from((n >> 22).checked_add(1_288_834_974_657)?).ok()
}
pub(crate) fn safe_public_text(s: &str) -> String {
    let clean = s
        .chars()
        .filter_map(|c| {
            if c.is_control() {
                c.is_whitespace().then_some(' ')
            } else {
                Some(c)
            }
        })
        .collect::<String>();
    let mut text = clean
        .split_whitespace()
        .filter(|word| {
            !word.contains([
                '@', '/', '\\', ':', '.', '．', '｡', '。', '\u{200C}', '\u{200D}',
            ])
        })
        .collect::<Vec<_>>()
        .join(" ");
    while text.len() > 720 || text.chars().count() > 240 {
        text.pop();
    }
    text
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Forecast {
    pub id: String,
    pub at: i64,
    pub latest_by: Option<i64>,
    pub source_url: String,
    pub fetched_at: i64,
}
impl Forecast {
    pub fn valid(&self, now: i64) -> bool {
        source_id(&self.source_url).as_deref() == Some(self.id.as_str())
            && post_at(&self.id) == Some(self.at)
            && self.at > 1_700_000_000_000
            && self.at <= self.fetched_at + 300000
            && self.at >= self.fetched_at - 90 * 86400000
            && self.fetched_at <= now + 300000
            && self.latest_by.is_none_or(|at| {
                at >= self.at - 300000
                    && at <= self.fetched_at + 14 * 86400000
                    && at <= now + 14 * 86400000
            })
    }
}
#[derive(Clone)]
pub(crate) enum ForecastPage {
    Forecast(Forecast),
    SiteWatch,
    None,
}
// Bounded, inert HTML tokenisation. It does not execute scripts or accept
// arbitrary DOM/text as a forecast source. Duplicate attributes fail closed.
fn attrs(tag: &str) -> Result<(String, std::collections::BTreeMap<String, String>)> {
    let b = tag.as_bytes();
    let mut i = 1;
    while i < b.len() && b[i].is_ascii_whitespace() {
        i += 1;
    }
    let start = i;
    while i < b.len() && (b[i].is_ascii_alphanumeric() || b"-_:".contains(&b[i])) {
        i += 1;
    }
    if i == start {
        return fail("public_forecast_invalid_response");
    }
    let name = tag[start..i].to_ascii_lowercase();
    let mut values = std::collections::BTreeMap::new();
    while i < b.len() {
        while i < b.len() && b[i].is_ascii_whitespace() {
            i += 1;
        }
        if i == b.len() || matches!(b[i], b'>' | b'/') {
            break;
        }
        let start = i;
        while i < b.len() && !b[i].is_ascii_whitespace() && !b"=>/".contains(&b[i]) {
            i += 1;
        }
        if i == start {
            return fail("public_forecast_invalid_response");
        }
        let key = tag[start..i].to_ascii_lowercase();
        while i < b.len() && b[i].is_ascii_whitespace() {
            i += 1;
        }
        let mut value = String::new();
        if i < b.len() && b[i] == b'=' {
            i += 1;
            while i < b.len() && b[i].is_ascii_whitespace() {
                i += 1;
            }
            if i >= b.len() {
                return fail("public_forecast_invalid_response");
            }
            let quote = b[i];
            if quote != b'\'' && quote != b'"' {
                return fail("public_forecast_invalid_response");
            }
            i += 1;
            let start = i;
            while i < b.len() && b[i] != quote {
                i += 1;
            }
            if i == b.len() {
                return fail("public_forecast_invalid_response");
            }
            value = tag[start..i]
                .replace("&amp;", "&")
                .replace("&quot;", "\"")
                .replace("&#39;", "'");
            i += 1;
        }
        if values.insert(key, value).is_some() {
            return fail("public_forecast_invalid_response");
        }
    }
    Ok((name, values))
}
pub(crate) fn forecast(bytes: &[u8], now: i64) -> Result<ForecastPage> {
    if bytes.len() > 1024 * 1024 {
        return fail("public_forecast_invalid_response");
    }
    let html =
        std::str::from_utf8(bytes).map_err(|_| Failure("public_forecast_invalid_response"))?;
    let lower = html.to_ascii_lowercase();
    if html.contains('\0')
        || !lower.contains("<html")
        || !lower.contains("codex-resets")
        || !lower.contains("hero-figure")
    {
        return fail("public_forecast_invalid_response");
    }
    let mut banners = Vec::new();
    let mut empties = 0;
    let mut offset = 0;
    while let Some(relative) = html[offset..].find('<') {
        let start = offset + relative;
        if html[start..].starts_with("<!--") {
            offset = html[start + 4..]
                .find("-->")
                .map(|n| start + 4 + n + 3)
                .ok_or(Failure("public_forecast_invalid_response"))?;
            continue;
        }
        if html[start..].starts_with("</") || html[start..].starts_with("<!") {
            offset = start + 1;
            continue;
        }
        let Some(end) = html[start..].find('>').map(|n| start + n + 1) else {
            return fail("public_forecast_invalid_response");
        };
        if end - start > 8192 {
            return fail("public_forecast_invalid_response");
        }
        let tag = &html[start..end];
        let name = tag[1..]
            .split(|c: char| c.is_whitespace() || c == '>' || c == '/')
            .next()
            .unwrap_or("")
            .to_ascii_lowercase();
        if matches!(name.as_str(), "script" | "style") {
            let closing = format!("</{name}>");
            offset = lower[end..]
                .find(&closing)
                .map(|n| end + n + closing.len())
                .ok_or(Failure("public_forecast_invalid_response"))?;
            continue;
        }
        if !tag.to_ascii_lowercase().contains("data-role") {
            offset = end;
            continue;
        }
        let (name, a) = attrs(tag)?;
        if let Some(role) = a.get("data-role") {
            let closing = format!("</{name}>");
            let close = lower[end..]
                .find(&closing)
                .map(|n| end + n)
                .ok_or(Failure("public_forecast_invalid_response"))?;
            if matches!(role.as_str(), "scheduled-reset" | "reset-watch") {
                if close + closing.len() - start > 65536 {
                    return fail("public_forecast_invalid_response");
                }
                banners.push((role.clone(), name, a, start, end, close));
            } else if role == "pending-reset" && name == "div" && html[end..close].trim().is_empty()
            {
                empties += 1;
            }
        }
        offset = end;
    }
    if banners.len() > 1 {
        return fail("public_forecast_invalid_response");
    }
    let Some((role, name, a, _, start, end)) = banners.pop() else {
        return if empties == 1 {
            Ok(ForecastPage::None)
        } else {
            fail("public_forecast_invalid_response")
        };
    };
    let raw = a.get(if role == "scheduled-reset" {
        "data-scheduled-for"
    } else {
        "data-expires-at"
    });
    let latest_by = match raw {
        Some(s) if s.is_empty() && role == "scheduled-reset" => None,
        Some(s) => Some(date(s).ok_or(Failure("public_forecast_invalid_response"))?),
        None if role == "reset-watch" => None,
        _ => return fail("public_forecast_invalid_response"),
    };
    let inner = &html[start..end];
    let mut links = BTreeSet::new();
    let mut anchors = 0;
    let mut rumor = 0;
    let mut pos = 0;
    while let Some(rel) = inner[pos..].find('<') {
        let s = pos + rel;
        if inner[s..].starts_with("<!--") {
            pos = inner[s + 4..]
                .find("-->")
                .map(|n| s + 4 + n + 3)
                .ok_or(Failure("public_forecast_invalid_response"))?;
            continue;
        }
        let Some(e) = inner[s..].find('>').map(|n| s + n + 1) else {
            break;
        };
        if !inner[s..].starts_with("</") && !inner[s..].starts_with("<!") {
            let (n, a) = attrs(&inner[s..e])?;
            if matches!(n.as_str(), "script" | "style") {
                let closing = format!("</{n}>");
                pos = inner.to_ascii_lowercase()[e..]
                    .find(&closing)
                    .map(|r| e + r + closing.len())
                    .ok_or(Failure("public_forecast_invalid_response"))?;
                continue;
            }
            if n == "a" {
                anchors += 1;
                if let Some(u) = a.get("href") {
                    if source_id(u).is_some() {
                        links.insert(u.clone());
                    }
                }
            }
            if n == "p"
                && a.get("class")
                    .is_some_and(|s| s.split_whitespace().any(|c| c == "watch-rumor"))
            {
                rumor += 1;
            }
        }
        pos = e;
    }
    if links.is_empty()
        && role == "reset-watch"
        && name == "section"
        && latest_by.is_some()
        && anchors == 0
        && rumor == 1
    {
        if latest_by.is_none_or(|at| at < now - 72 * 3600000 || at > now + 14 * 86400000) {
            return fail("public_forecast_invalid_response");
        }
        return Ok(ForecastPage::SiteWatch);
    }
    if links.len() != 1 {
        return fail("public_forecast_invalid_response");
    }
    let source_url = links.pop_first().unwrap();
    let id = source_id(&source_url).unwrap();
    let f = Forecast {
        at: post_at(&id).ok_or(Failure("public_forecast_invalid_response"))?,
        id,
        latest_by,
        source_url,
        fetched_at: now,
    };
    if !f.valid(now) {
        return fail("public_forecast_invalid_response");
    }
    Ok(ForecastPage::Forecast(f))
}
