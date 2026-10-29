#[cfg(windows)]
use super::super::transport::TransportRequest;
use super::super::{fail, Failure, Result};
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Clone)]
pub enum PublicResetRequest {
    History { cursor: Option<String> },
    Forecast,
}
impl PublicResetRequest {
    pub fn endpoint(&self) -> Result<url::Url> {
        match self {
            Self::Forecast => url::Url::parse("https://codex-resets.com/zh-CN")
                .map_err(|_| Failure("public_reset_invalid_request")),
            Self::History { cursor } => {
                let mut u =
                    url::Url::parse("https://codex-resets.com/api/v1/resets?limit=100&order=desc")
                        .map_err(|_| Failure("public_reset_invalid_request"))?;
                if let Some(c) = cursor {
                    if !super::models::cursor_valid(c) {
                        return fail("public_reset_invalid_request");
                    }
                    u.query_pairs_mut().append_pair("cursor", c);
                }
                Ok(u)
            }
        }
    }
    pub(crate) fn limit(&self) -> usize {
        match self {
            Self::History { .. } => 512 * 1024,
            Self::Forecast => 1024 * 1024,
        }
    }
}
pub struct PublicResetResponse {
    pub status: u16,
    pub body: Vec<u8>,
    pub content_type: Option<String>,
    pub retry_after: Option<String>,
}
pub trait PublicResetSource: Send + Sync {
    fn fetch(
        &self,
        request: &PublicResetRequest,
        cancelled: &AtomicBool,
    ) -> Result<PublicResetResponse>;
}
pub struct NativePublicResetSource;
impl PublicResetSource for NativePublicResetSource {
    fn fetch(&self, r: &PublicResetRequest, c: &AtomicBool) -> Result<PublicResetResponse> {
        let url = r.endpoint()?;
        if c.load(Ordering::Acquire) {
            return fail("cancelled");
        }
        #[cfg(not(windows))]
        {
            let _ = (url, r);
            fail("windows_required")
        }
        #[cfg(windows)]
        {
            let mut request = TransportRequest::json("GET", url, serde_json::Value::Null, 20);
            request.body.clear();
            request.headers = vec![
                (
                    "Accept".into(),
                    match r {
                        PublicResetRequest::History { .. } => "application/json",
                        PublicResetRequest::Forecast => "text/html",
                    }
                    .into(),
                ),
                ("Cache-Control".into(), "no-cache, no-store".into()),
            ];
            let raw = super::super::transport::windows_send(&request, c, r.limit())?;
            Ok(PublicResetResponse {
                status: raw.response.status,
                body: raw.response.body,
                content_type: raw.content_type,
                retry_after: raw.retry_after,
            })
        }
    }
}
pub(crate) struct UnavailableSource;
impl PublicResetSource for UnavailableSource {
    fn fetch(&self, _: &PublicResetRequest, _: &AtomicBool) -> Result<PublicResetResponse> {
        fail("public_reset_source_unavailable")
    }
}
