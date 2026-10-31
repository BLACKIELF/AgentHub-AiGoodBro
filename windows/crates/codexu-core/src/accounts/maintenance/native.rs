use super::*;
pub(super) struct NativeRuntime {
    pub selection: crate::runtime_setup::SelectionStore,
}
impl Runtime for NativeRuntime {
    fn available(&self) -> bool {
        cfg!(windows)
    }
    fn warmup(
        &self,
        credential: &super::super::super::identity::StoredCredential,
        admit: &dyn Fn() -> Result<()>,
    ) -> Execution {
        Execution {
            outcome: warmup(credential, admit),
            verified: None,
        }
    }
    fn reset(
        &self,
        home: &Path,
        credential: &super::super::super::identity::StoredCredential,
        claim: &dyn Fn(&Card) -> Result<String>,
        admit: &dyn Fn() -> Result<()>,
    ) -> Execution {
        #[cfg(windows)]
        {
            reset(home, credential, claim, admit, true, Some(&self.selection))
        }
        #[cfg(not(windows))]
        {
            let _ = (home, credential, claim, admit);
            Execution {
                outcome: Outcome::NotSent,
                verified: None,
            }
        }
    }
}
pub(super) fn manual_reset(
    home: &Path,
    credential: &super::super::super::identity::StoredCredential,
    claim: &dyn Fn(&Card) -> Result<String>,
    admit: &dyn Fn() -> Result<()>,
    selection: Option<&crate::runtime_setup::SelectionStore>,
) -> Execution {
    #[cfg(windows)]
    {
        reset(home, credential, claim, admit, false, selection)
    }
    #[cfg(not(windows))]
    {
        let _ = (home, credential, claim, admit, selection);
        Execution {
            outcome: Outcome::NotSent,
            verified: None,
        }
    }
}
fn card_unchanged(selected: &Card, latest: &Card, require_unchanged_quota: bool) -> bool {
    selected.id == latest.id
        && selected.expires_at_ms == latest.expires_at_ms
        && (!require_unchanged_quota || selected.fingerprint == latest.fingerprint)
}
#[cfg(not(windows))]
fn warmup(
    _: &super::super::super::identity::StoredCredential,
    _: &dyn Fn() -> Result<()>,
) -> Outcome {
    Outcome::NotSent
}
#[cfg(windows)]
#[path = "http.rs"]
mod http;
#[cfg(windows)]
fn warmup(
    credential: &super::super::super::identity::StoredCredential,
    admit: &dyn Fn() -> Result<()>,
) -> Outcome {
    let Ok(auth) = serde_json::from_slice::<Value>(&credential.auth) else {
        return Outcome::NotSent;
    };
    let Some(token) = auth["tokens"]["access_token"].as_str() else {
        return Outcome::NotSent;
    };
    http::warmup(token, &credential.identity.account_id, admit)
}
#[cfg(windows)]
fn reset(
    home: &Path,
    credential: &super::super::super::identity::StoredCredential,
    claim: &dyn Fn(&Card) -> Result<String>,
    admit: &dyn Fn() -> Result<()>,
    require_unchanged_quota: bool,
    selection: Option<&crate::runtime_setup::SelectionStore>,
) -> Execution {
    use super::super::super::native::{maintenance_executable, process};
    let not_sent = || Execution {
        outcome: Outcome::NotSent,
        verified: None,
    };
    if admit().is_err() {
        return not_sent();
    }
    let Ok((executable, _image)) = maintenance_executable(home, selection) else {
        return not_sent();
    };
    let Ok(mut version) = process::Child::start(&executable, home, &["--version".into()]) else {
        return not_sent();
    };
    let mut output = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(2);
    let mut accepted = false;
    while Instant::now() < deadline {
        if admit().is_err() {
            break;
        }
        if let Ok(bytes) = version.read_available() {
            output.extend(bytes);
        } else {
            break;
        }
        if output.len() > 4096 {
            break;
        }
        if let Ok(Some(0)) = version.exit_code() {
            accepted = version_supported(std::str::from_utf8(&output).unwrap_or(""));
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    if version.stop_confirmed().is_err() || !accepted {
        return not_sent();
    }
    let Ok(runtime) = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    else {
        return not_sent();
    };
    runtime.block_on(reset_async(
        &executable,
        home,
        credential,
        claim,
        admit,
        require_unchanged_quota,
    ))
}
#[cfg(windows)]
async fn reset_async(
    executable: &Path,
    home: &Path,
    credential: &super::super::super::identity::StoredCredential,
    claim: &dyn Fn(&Card) -> Result<String>,
    admit: &dyn Fn() -> Result<()>,
    require_unchanged_quota: bool,
) -> Execution {
    use super::super::super::native::process;
    use futures_util::{SinkExt, StreamExt};
    use serde_json::json;
    use tokio_tungstenite::tungstenite::{protocol::WebSocketConfig, Message};
    let mut outcome = Outcome::NotSent;
    let mut account = None;
    let mut quota = None;
    let socket = match tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)).await {
        Ok(s) => s,
        Err(_) => {
            return Execution {
                outcome,
                verified: None,
            }
        }
    };
    let port = socket.local_addr().unwrap().port();
    drop(socket);
    let endpoint = format!("ws://127.0.0.1:{port}");
    let mut args = crate::workflow::official_arguments();
    args.extend(["app-server".into(), "--listen".into(), endpoint.clone()]);
    let mut child = match process::Child::start(executable, home, &args) {
        Ok(c) => c,
        Err(_) => {
            return Execution {
                outcome,
                verified: None,
            }
        }
    };
    let result=tokio::time::timeout(Duration::from_secs(25),async{
  let deadline=Instant::now()+Duration::from_secs(5);
  let mut socket=loop{
   admit()?;
   if process::owns_loopback_listener(child.pid(),port).map_err(account_error)?{
    let config=WebSocketConfig::default().max_message_size(Some(1024*1024)).max_frame_size(Some(1024*1024));
    if let Ok((socket,_))=tokio_tungstenite::connect_async_with_config(&endpoint,Some(config),false).await{break socket;}
   }
   if Instant::now()>=deadline||child.exit_code().map_err(account_error)?.is_some(){return Err(Failure::Unavailable);}
   tokio::time::sleep(Duration::from_millis(25)).await;
  };
  let mut id=1i64;
  macro_rules! rpc{($method:expr,$params:expr)=>{{
   let request_id=id;id+=1;
   socket.send(Message::Text(json!({"id":request_id,"method":$method,"params":$params}).to_string().into())).await.map_err(|_|Failure::ProtocolUnknown)?;
   loop{let message=tokio::select! { message=socket.next()=>message.ok_or(Failure::ProtocolUnknown)?.map_err(|_|Failure::ProtocolUnknown)?, _=tokio::time::sleep(Duration::from_millis(100))=>{admit()?;continue;} };let Message::Text(text)=message else{if matches!(message,Message::Close(_)){return Err(Failure::ProtocolUnknown);}continue;};if text.len()>1024*1024{return Err(Failure::ProtocolUnknown);}let value:Value=serde_json::from_str(&text).map_err(|_|Failure::ProtocolUnknown)?;if value.get("method").is_some()&&value.get("id").is_some(){return Err(Failure::ProtocolUnknown);}if value.get("id").and_then(Value::as_i64)!=Some(request_id){continue;}if value.get("error").is_some(){return Err(Failure::ProtocolUnknown);}break value.get("result").cloned().ok_or(Failure::ProtocolUnknown)?;}
  }}}
  let _=rpc!("initialize",json!({"clientInfo":{"name":"aigoodbro-maintenance","version":env!("CARGO_PKG_VERSION")},"capabilities":{"experimentalApi":false}}));
  socket.send(Message::Text(json!({"method":"initialized"}).to_string().into())).await.map_err(|_|Failure::ProtocolUnknown)?;
  let a=rpc!("account/read",json!({"refreshToken":false}));
  let q=rpc!("account/rateLimits/read",Value::Null);
  let auth=storage::read_optional(&home.join("auth.json"),super::super::super::identity::MAX_AUTH_BYTES).map_err(account_error)?.ok_or(Failure::IdentityChanged)?;
  let verified=super::super::super::VerifiedCredential::from_official_read(auth,&a,q.clone()).map_err(account_error)?;
  if verified.identity!=credential.identity{return Err(Failure::IdentityChanged);}account=Some(a);quota=Some(q.clone());
  let selected=card(&q,&credential.identity.account_id,now())?;let key=claim(&selected)?;
  // Re-read the exact card/account and quota in this same owned connection.
  let q2=rpc!("account/rateLimits/read",Value::Null);let latest=card(&q2,&credential.identity.account_id,now())?;
  if !card_unchanged(&selected,&latest,require_unchanged_quota){return Err(Failure::IdentityChanged);}quota=Some(q2);
  admit()?;outcome=Outcome::Unknown;
  let value=rpc!("account/rateLimitResetCredit/consume",json!({"idempotencyKey":key,"creditId":selected.id}));
  outcome=match value.get("outcome").and_then(Value::as_str){Some("reset")=>Outcome::Reset,Some("nothingToReset")=>Outcome::NothingToReset,Some("noCredit")=>Outcome::NoCredit,Some("alreadyRedeemed")=>Outcome::AlreadyRedeemed,_=>Outcome::Unknown};
  Ok::<(),Failure>(())
 }).await;
    let cleanup = child.stop_confirmed();
    let verified = match (
        account,
        quota,
        storage::read_optional(
            &home.join("auth.json"),
            super::super::super::identity::MAX_AUTH_BYTES,
        ),
    ) {
        (Some(a), Some(q), Ok(Some(auth))) => {
            super::super::super::VerifiedCredential::from_official_read(auth, &a, q)
                .ok()
                .filter(|v| v.identity == credential.identity)
        }
        _ => None,
    };
    if cleanup.is_err() {
        outcome = Outcome::Unknown;
    }
    let _ = result;
    Execution { outcome, verified }
}
fn version_supported(value: &str) -> bool {
    let Some(v) = value.trim().strip_prefix("codex-cli ") else {
        return false;
    };
    let mut p = v.split('.');
    matches!((p.next().and_then(|v|v.parse::<u64>().ok()),p.next().and_then(|v|v.parse::<u64>().ok())),(Some(major),Some(minor))if major>0||minor>=154)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn manual_card_freshness_allows_concurrent_quota_usage_but_auto_stays_strict() {
        let a = Card {
            id: "synthetic-card".into(),
            expires_at_ms: 1000,
            fingerprint: "a".repeat(64),
        };
        let mut b = Card {
            id: a.id.clone(),
            expires_at_ms: a.expires_at_ms,
            fingerprint: "b".repeat(64),
        };
        assert!(!card_unchanged(&a, &b, true));
        assert!(card_unchanged(&a, &b, false));
        b.id = "different-card".into();
        assert!(!card_unchanged(&a, &b, false));
        b.id = a.id.clone();
        b.expires_at_ms = 1001;
        assert!(!card_unchanged(&a, &b, false));
    }
    #[test]
    fn reset_cli_version_is_actual_and_minimum_154() {
        assert!(version_supported("codex-cli 0.154.0"));
        assert!(!version_supported("codex-cli 0.153.9"));
        assert!(!version_supported("anything 999"));
    }
}
