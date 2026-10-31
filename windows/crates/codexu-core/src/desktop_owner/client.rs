use super::{
    protocol::{self, Socket},
    *,
};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

pub(super) trait Peer: Send {
    fn recheck(&self) -> OwnerResult<()>;
}
pub(super) struct Connection {
    pub socket: Box<dyn Socket>,
    pub peer: Box<dyn Peer>,
}

pub struct DesktopOwnerClient {
    connection: Option<Connection>,
    epoch: String,
    client_id: String,
    attempts: HashSet<String>,
    revisions: HashMap<String, (u64, String)>,
}
impl DesktopOwnerClient {
    /// Connects only to the existing official local pipe. Unsupported installs
    /// fail explicitly; this never launches or reconnects an official process.
    pub async fn connect(timeout: Duration, cancel: &Cancellation) -> OwnerResult<Self> {
        let budget = Budget::new(timeout, cancel)?;
        let connection = native::connect(&budget).await?;
        Self::initialize(connection, &budget).await
    }
    pub fn close(&mut self) {
        self.connection.take();
    }
    pub fn is_connected(&self) -> bool {
        self.connection.is_some()
    }

    pub(super) async fn initialize(
        mut connection: Connection,
        budget: &Budget,
    ) -> OwnerResult<Self> {
        let epoch = random_id()?;
        let id = random_id()?;
        let reply = exchange(
            &mut connection,
            "initializing-client",
            &id,
            "initialize",
            json!({"clientType":"aigoodbro-owner-client"}),
            None,
            budget,
        )
        .await?;
        let result = protocol::success(&reply, &id, "initialize", None)?;
        let client = result["clientId"]
            .as_str()
            .filter(|x| protocol::uuid(x))
            .ok_or(OwnerError::UnexpectedResponse)?;
        if reply["handledByClientId"] != client {
            return Err(OwnerError::UnexpectedResponse);
        }
        Ok(Self {
            connection: Some(connection),
            epoch,
            client_id: client.to_owned(),
            attempts: HashSet::new(),
            revisions: HashMap::new(),
        })
    }
    pub async fn discover(
        &mut self,
        conversation: &str,
        timeout: Duration,
        cancel: &Cancellation,
    ) -> OwnerResult<OwnerTicket> {
        if !protocol::uuid(conversation) {
            return Err(OwnerError::InvalidRequest);
        }
        let budget = Budget::new(timeout, cancel)?;
        // Taking the socket makes cancellation/drop fail closed, even when the
        // caller drops this future rather than setting its Cancellation.
        let mut c = self.connection.take().ok_or(OwnerError::Disconnected)?;
        let id = random_id()?;
        let reply = exchange(
            &mut c,
            &self.client_id,
            &id,
            protocol::DISCOVER,
            json!({"conversationId":conversation,"hostId":"local"}),
            None,
            &budget,
        )
        .await?;
        let r = protocol::success(&reply, &id, protocol::DISCOVER, None)?;
        if r["supportsUntrustedAppInput"] != true {
            return Err(OwnerError::OwnerUnavailable);
        }
        let owner = reply["handledByClientId"].as_str().unwrap().to_owned();
        self.connection = Some(c);
        Ok(OwnerTicket {
            conversation: conversation.to_owned(),
            owner,
            epoch: self.epoch.clone(),
            expires: Instant::now() + Duration::from_secs(15),
        })
    }
    fn ticket(&self, t: &OwnerTicket) -> OwnerResult<()> {
        if t.epoch != self.epoch || Instant::now() >= t.expires {
            Err(OwnerError::StaleTicket)
        } else {
            Ok(())
        }
    }
    pub async fn snapshot(
        &mut self,
        t: &OwnerTicket,
        timeout: Duration,
        cancel: &Cancellation,
    ) -> OwnerResult<OwnerSnapshot> {
        self.ticket(t)?;
        let budget = Budget::new(timeout, cancel)?;
        let mut c = self.connection.take().ok_or(OwnerError::Disconnected)?;
        let revision_key = format!("{}:{}", t.owner, t.conversation);
        let bytes = protocol::frame(&protocol::following(&self.client_id, &t.conversation, true))?;
        c.peer.recheck()?;
        budget.check()?;
        budget
            .wait(protocol::write(c.socket.as_mut(), &bytes))
            .await?;
        let result = loop {
            let v = budget.wait(protocol::read(c.socket.as_mut())).await?;
            c.peer.recheck()?;
            budget.check()?;
            if let Some(value) =
                protocol::snapshot(&v, &self.client_id, t, self.revisions.get(&revision_key))
            {
                break value;
            }
            auxiliary(&mut c, &v, &budget).await?;
        };
        let bytes = protocol::frame(&protocol::following(
            &self.client_id,
            &t.conversation,
            false,
        ))?;
        budget
            .wait(protocol::write(c.socket.as_mut(), &bytes))
            .await?;
        self.revisions.insert(
            revision_key,
            (result.revision, protocol::state_digest(&result.state)),
        );
        self.connection = Some(c);
        Ok(result)
    }
    pub async fn start_text(
        &mut self,
        t: &OwnerTicket,
        operation_id: &str,
        text: &str,
        timeout: Duration,
        cancel: &Cancellation,
    ) -> ActionOutcome {
        if text.trim().is_empty() || text.len() > 4096 || text.contains('\0') {
            return ActionOutcome::NotSent(OwnerError::InvalidRequest);
        }
        let params = json!({"conversationId":t.conversation,"turnStart":{"request":{"threadId":t.conversation,
            "clientUserMessageId":operation_id,"input":[{"type":"text","text":text,"text_elements":[]}]},
            "context":{"inheritThreadSettings":true}}});
        self.mutate(
            t,
            operation_id,
            protocol::START,
            params,
            None,
            timeout,
            cancel,
        )
        .await
    }
    pub async fn interrupt(
        &mut self,
        t: &OwnerTicket,
        operation_id: &str,
        expected_turn_id: &str,
        timeout: Duration,
        cancel: &Cancellation,
    ) -> ActionOutcome {
        if !protocol::uuid(expected_turn_id) {
            return ActionOutcome::NotSent(OwnerError::InvalidRequest);
        }
        let params = json!({"conversationId":t.conversation,"mode":"user-stop","expectedTurnId":expected_turn_id});
        self.mutate(
            t,
            operation_id,
            protocol::INTERRUPT,
            params,
            Some(expected_turn_id),
            timeout,
            cancel,
        )
        .await
    }
    async fn mutate(
        &mut self,
        t: &OwnerTicket,
        id: &str,
        method: &str,
        params: Value,
        turn: Option<&str>,
        timeout: Duration,
        cancel: &Cancellation,
    ) -> ActionOutcome {
        let prepared = (|| {
            self.ticket(t)?;
            if !protocol::uuid(id) {
                return Err(OwnerError::InvalidRequest);
            }
            if self.attempts.contains(id) || self.attempts.len() >= 256 {
                return Err(OwnerError::AlreadyAttempted);
            }
            Budget::new(timeout, cancel)
        })();
        let budget = match prepared {
            Ok(x) => x,
            Err(e) => return ActionOutcome::NotSent(e),
        };
        let mut c = match self.connection.take() {
            Some(x) => x,
            None => return ActionOutcome::NotSent(OwnerError::Disconnected),
        };
        // Fresh targeted owner/capability check immediately before admission.
        // Failure here is local non-submission of the mutation, not a remote
        // mutation error guessed to be safe from its text.
        let preflight = async {
            let check_id = random_id()?;
            let reply = exchange(
                &mut c,
                &self.client_id,
                &check_id,
                protocol::DISCOVER,
                json!({"hostId":"local","conversationId":t.conversation}),
                Some(&t.owner),
                &budget,
            )
            .await?;
            let r = protocol::success(&reply, &check_id, protocol::DISCOVER, Some(&t.owner))?;
            if r["supportsUntrustedAppInput"] != true {
                return Err(OwnerError::OwnerUnavailable);
            }
            self.ticket(t)?;
            c.peer.recheck()?;
            budget.check()?;
            protocol::frame(&protocol::request(
                &self.client_id,
                id,
                method,
                params,
                Some(&t.owner),
                budget.millis()?,
            ))
        }
        .await;
        let bytes = match preflight {
            Ok(x) => x,
            Err(e) => return ActionOutcome::NotSent(e),
        };
        if let Err(e) = budget.check() {
            return ActionOutcome::NotSent(e);
        }
        self.attempts.insert(id.to_owned());
        // Conservatively mark attempted BEFORE polling write; a dropped future
        // or any error thereafter may have sent bytes. Never replay the ID.
        let result = async {
            budget
                .wait(protocol::write(c.socket.as_mut(), &bytes))
                .await?;
            let reply = response(&mut c, id, &budget).await?;
            c.peer.recheck()?;
            budget.check()?;
            let result = protocol::success(&reply, id, method, Some(&t.owner))?;
            let turn_id = if method == protocol::START {
                result
                    .get("result")
                    .unwrap_or(result)
                    .get("turn")
                    .and_then(|x| x.get("id"))
                    .and_then(Value::as_str)
            } else {
                if result["ok"] != true || result["interruptedTurnId"] != turn.unwrap_or("") {
                    return Err(OwnerError::UnexpectedResponse);
                }
                result["interruptedTurnId"].as_str()
            }
            .filter(|x| protocol::uuid(x))
            .ok_or(OwnerError::UnexpectedResponse)?;
            Ok(turn_id.to_owned())
        }
        .await;
        match result {
            Ok(turn_id) => {
                self.connection = Some(c);
                ActionOutcome::Accepted { turn_id }
            }
            Err(_) => ActionOutcome::Unknown,
        }
    }
}
async fn exchange(
    c: &mut Connection,
    source: &str,
    id: &str,
    method: &str,
    params: Value,
    target: Option<&str>,
    budget: &Budget,
) -> OwnerResult<Value> {
    c.peer.recheck()?;
    budget.check()?;
    let bytes = protocol::frame(&protocol::request(
        source,
        id,
        method,
        params,
        target,
        budget.millis()?,
    ))?;
    budget
        .wait(protocol::write(c.socket.as_mut(), &bytes))
        .await?;
    response(c, id, budget).await
}
async fn response(c: &mut Connection, id: &str, budget: &Budget) -> OwnerResult<Value> {
    // A bounded message count protects against a flood even within the deadline.
    for _ in 0..256 {
        let v = budget.wait(protocol::read(c.socket.as_mut())).await?;
        c.peer.recheck()?;
        budget.check()?;
        if v["type"] == "response" {
            if v["requestId"] != id {
                return Err(OwnerError::UnexpectedResponse);
            }
            return Ok(v);
        }
        auxiliary(c, &v, budget).await?;
    }
    Err(OwnerError::UnexpectedResponse)
}
async fn auxiliary(c: &mut Connection, v: &Value, budget: &Budget) -> OwnerResult<()> {
    if v["type"] == "client-discovery-request" {
        let id = v["requestId"]
            .as_str()
            .filter(|x| protocol::uuid(x))
            .ok_or(OwnerError::InvalidFrame)?;
        let bytes = protocol::frame(
            &json!({"type":"client-discovery-response","requestId":id,"response":{"canHandle":false}}),
        )?;
        budget
            .wait(protocol::write(c.socket.as_mut(), &bytes))
            .await?;
    } else if v["type"] != "broadcast" {
        return Err(OwnerError::UnexpectedResponse);
    }
    Ok(())
}
