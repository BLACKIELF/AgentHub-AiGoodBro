use super::*;
pub(super) struct NativeRuntime;
impl ActionRuntime for NativeRuntime {
    fn review(
        &self,
        home: &Path,
        credential: &StoredCredential,
        admit: &dyn Fn() -> AccountResult<()>,
    ) -> AccountResult<Value> {
        admit()?;
        let verified = NativeAccountRuntime.verify(home, &credential.identity)?;
        admit()?;
        if verified.identity != credential.identity {
            return Err(fail("manual_action_identity_changed"));
        }
        Ok(verified.quota)
    }
    fn consume(
        &self,
        home: &Path,
        credential: &StoredCredential,
        card: &str,
        expiry: i64,
        key: &str,
        admit: &dyn Fn() -> AccountResult<()>,
    ) -> AccountResult<&'static str> {
        let claim = |actual: &maintenance::Card| {
            if actual.id != card || actual.expires_at_ms != expiry {
                return Err(maintenance::Failure::IdentityChanged);
            }
            admit().map_err(|_| maintenance::Failure::Cancelled)?;
            Ok(format!(
                "{}-{}-{}-{}-{}",
                &key[..8],
                &key[8..12],
                &key[12..16],
                &key[16..20],
                &key[20..]
            ))
        };
        let check = || admit().map_err(|_| maintenance::Failure::Cancelled);
        let result = maintenance::manual_consume(home, credential, &claim, &check);
        Ok(match result.outcome {
            maintenance::Outcome::Reset => "reset",
            maintenance::Outcome::NothingToReset => "nothingToReset",
            maintenance::Outcome::NoCredit => "noCredit",
            maintenance::Outcome::AlreadyRedeemed => "alreadyRedeemed",
            _ => "unknown",
        })
    }
    fn http(
        &self,
        credential: &StoredCredential,
        request: &HttpRequest,
        admit: &dyn Fn() -> AccountResult<()>,
    ) -> AccountResult<HttpResponse> {
        #[cfg(windows)]
        {
            http::request(credential, request, admit)
        }
        #[cfg(not(windows))]
        {
            let _ = (credential, request, admit);
            Err(fail("windows_required"))
        }
    }
}
#[cfg(windows)]
#[path = "http.rs"]
mod http;
