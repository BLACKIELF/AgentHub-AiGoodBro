//! Windows-only, synthetic end-to-end coverage for the actual Python client,
//! native Receiver, Tauri AppBackend, and owned Hub sessions. All accounts,
//! Hub responses, and app-server evidence are local fixtures; no model or
//! external account is contacted.
#[path = "../../../../../test-support/native_desktop.rs"]
mod native_desktop;

use super::*;
use crate::commands::cli_workflow::console::LaunchWindow;
use codexu_core::{
    accounts::{
        hub_snapshot::HubFiles, AccountError, AccountIdentity, AccountLoginSpawner,
        AccountOccupancyGate, AccountPaths, AccountResult, AccountRuntime, CredentialWriteLease,
        CredentialWritePurpose, LoginAuthorization, SecretProtector, SwitchMaintenanceLease,
        VerifiedCredential,
    },
    automatic_switch::live::OwnedProcessDomains,
    companion_bridge::{
        native_windows::{prepare_private_root, CurrentAppBinding, Receiver},
        Bridge,
    },
    local_cli::LocalCliKind,
    managed_proxy::ManagedProxyGate,
    runtime_setup::{NativeProbe, PinnedExecutable, SelectionStore},
    workflow::{WorkflowPreference, WorkflowPreferences},
    workflow_reader::WorkflowProbeOwner,
};
use native_desktop::NativeDesktop;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    ffi::c_void,
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    net::SocketAddr,
    os::windows::ffi::OsStrExt,
    path::{Path, PathBuf},
    ptr,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Mutex, OnceLock,
    },
    thread,
    time::{Duration, Instant},
};

const CLIENT_WRAPPER: &str = r#"import io,json,os,runpy,sys
c=json.load(open(sys.argv[1],encoding='utf-8'))
sys.argv=c['argv']
sys.stdin=io.TextIOWrapper(io.BytesIO(c['stdin'].encode('utf-8')))
diagnostic_path=c.get('failure_diagnostic')
previous_trace=sys.gettrace()
if diagnostic_path:
    launcher_path=os.path.abspath(sys.argv[0])
    def observe(frame,event,arg):
        if event=='call' and frame.f_code.co_name=='fail' and os.path.abspath(frame.f_code.co_filename)==launcher_path:
            code=frame.f_locals.get('code')
            if isinstance(code,str) and code.startswith('companion_') and len(code)<=96 and all(ch in 'abcdefghijklmnopqrstuvwxyz0123456789_' for ch in code):
                try:
                    with open(diagnostic_path,'w',encoding='ascii') as f:
                        f.write(json.dumps({'code':code},separators=(',',':')))
                except OSError:
                    pass
        return None
    sys.settrace(observe)
try:
    runpy.run_path(sys.argv[0],run_name='__main__')
finally:
    if diagnostic_path:
        sys.settrace(previous_trace)
"#;
const SYNTHETIC_HUB: &str = r#"
import hashlib, json, os, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ready, log, post_seen, release, alias, token, block = sys.argv[1:]
class Server(HTTPServer):
    def __init__(self, address):
        super().__init__(address, Handler)
        self.records = {}
        self.tasks = {}
        self.block_create = block == '1'
class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.0'
    def log_message(self, *_):
        pass
    def record(self, kind, **fields):
        with open(log, 'a', encoding='utf-8') as f:
            f.write(json.dumps({'kind': kind, **fields}, separators=(',', ':')) + '\n')
            f.flush()
    def respond(self, status, value):
        data = json.dumps(value, separators=(',', ':')).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(data)
        try:
            self.record('response', status=status)
        except OSError:
            pass
    def authorized(self):
        return self.headers.get('Authorization') == 'Bearer ' + token
    def do_GET(self):
        if not self.authorized():
            return self.respond(401, {'error':'unauthorized'})
        if self.path == '/api/overview':
            self.record('overview')
            return self.respond(200, {'tasks':list(self.server.tasks.values())})
        if self.path.startswith('/api/requests/'):
            key = self.path.rsplit('/', 1)[-1]
            self.record('lookup', requestHash=key)
            ack = self.server.records.get(key)
            if ack is None:
                return self.respond(404, {'error':'not_found'})
            return self.respond(200, ack)
        return self.respond(404, {'error':'not_found'})
    def do_POST(self):
        if not self.authorized():
            return self.respond(401, {'error':'unauthorized'})
        length = int(self.headers.get('Content-Length', '0'))
        data = json.loads(self.rfile.read(length).decode('utf-8'))
        if self.path == '/api/tasks':
            if data.get('accountAlias') != alias:
                return self.respond(409, {'error':'account_mismatch'})
            request_id = data['requestId']
            execution = data['windowsExecution']
            prompt_hash = hashlib.sha256(data['prompt'].encode('utf-8')).hexdigest()
            def h(*parts):
                return hashlib.sha256('\0'.join(parts).encode('utf-8')).hexdigest()
            old_body = h('create', 'codex', 'workspace', alias, prompt_hash, '')
            body_hash = h(old_body, 'windows-execution-v1', execution['bindingSha256'])
            task_id = 'synthetic-task-' + alias
            task = {'id':task_id, 'agent':'codex', 'project':'workspace',
                    'accountAlias':alias, 'actionHash':'d' * 64,
                    'state':'awaiting_approval', 'approvalExpired':False, 'version':1}
            self.server.tasks[task_id] = task
            request_hash = hashlib.sha256(request_id.encode('utf-8')).hexdigest()
            ack = {'requestHash':request_hash, 'bodyHash':body_hash, 'task':task}
            self.server.records[request_hash] = ack
            self.record('create', requestId=request_id, accountAlias=alias)
            if self.server.block_create:
                self.server.block_create = False
                Path(post_seen).write_text('received', encoding='ascii')
                while not Path(release).exists():
                    time.sleep(0.01)
            return self.respond(200, task)
        if self.path.endswith('/approve'):
            self.record('approve', path=self.path)
            task_id = self.path.split('/')[-2]
            task = self.server.tasks[task_id]
            task['state'] = 'running'
            task['version'] += 1
            return self.respond(200, task)
        return self.respond(404, {'error':'not_found'})

server = Server(('127.0.0.1', 0))
ready_tmp = ready + '.tmp'
Path(ready_tmp).write_text(json.dumps({'port':server.server_port}), encoding='ascii')
Path(ready_tmp).replace(ready)
server.serve_forever(poll_interval=0.02)
"#;

static UNCONFIRMED_OWNERS: OnceLock<Mutex<Vec<Box<dyn OwnedProcess>>>> = OnceLock::new();
static UNCONFIRMED_RECEIVERS: OnceLock<Mutex<Vec<Receiver>>> = OnceLock::new();
static UNCONFIRMED_HUBS: OnceLock<Mutex<Vec<HubState>>> = OnceLock::new();

fn retain_owner(owner: Box<dyn OwnedProcess>) {
    UNCONFIRMED_OWNERS
        .get_or_init(|| Mutex::new(Vec::new()))
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .push(owner);
}

struct FixtureProtector;
impl SecretProtector for FixtureProtector {
    fn seal(&self, context: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
        Ok([context.as_bytes(), &[0], bytes].concat())
    }
    fn unseal(&self, context: &str, bytes: &[u8]) -> AccountResult<Vec<u8>> {
        let prefix = [context.as_bytes(), &[0]].concat();
        bytes
            .strip_prefix(prefix.as_slice())
            .map(|value| value.to_vec())
            .ok_or(AccountError {
                code: "fixture_context",
            })
    }
}

#[derive(Default)]
struct DeferredLogin(Mutex<Option<Box<dyn FnOnce() + Send>>>);
impl AccountLoginSpawner for DeferredLogin {
    fn spawn(&self, worker: Box<dyn FnOnce() + Send>) -> AccountResult<()> {
        *self.0.lock().unwrap_or_else(|e| e.into_inner()) = Some(worker);
        Ok(())
    }
}
impl DeferredLogin {
    fn run(&self) {
        let worker = self
            .0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .take()
            .expect("synthetic login worker was not queued");
        worker();
    }
}

struct FixtureOccupancyLease;
impl CredentialWriteLease for FixtureOccupancyLease {
    fn recheck(&self) -> AccountResult<()> {
        Ok(())
    }
}

/// Allows managed fixture credential writes only; all other maintenance stays fail-closed.
struct FixtureOccupancyGate;
impl AccountOccupancyGate for FixtureOccupancyGate {
    fn acquire_switch_maintenance(
        &self,
        _: &str,
        _: &str,
    ) -> AccountResult<Box<dyn SwitchMaintenanceLease>> {
        Err(AccountError {
            code: "fixture_occupancy_purpose_unsupported",
        })
    }

    fn acquire_credential_write(
        &self,
        _: &str,
        purpose: CredentialWritePurpose,
    ) -> AccountResult<Box<dyn CredentialWriteLease>> {
        if matches!(purpose, CredentialWritePurpose::Managed) {
            Ok(Box::new(FixtureOccupancyLease))
        } else {
            Err(AccountError {
                code: "fixture_occupancy_purpose_unsupported",
            })
        }
    }
}

#[derive(Default)]
struct FixtureRuntime {
    logins: AtomicUsize,
    names: Mutex<BTreeMap<String, String>>,
}
impl AccountRuntime for FixtureRuntime {
    fn available(&self) -> bool {
        true
    }
    fn login(
        &self,
        _: &Path,
        _: &std::sync::atomic::AtomicBool,
        _: &mut dyn FnMut(LoginAuthorization),
    ) -> AccountResult<VerifiedCredential> {
        let name = match self.logins.fetch_add(1, Ordering::SeqCst) {
            0 => "synthetic-a",
            1 => "synthetic-b",
            _ => {
                return Err(AccountError {
                    code: "fixture_login_limit",
                })
            }
        };
        let identity = AccountIdentity::from_auth(&fixture_auth(name))?;
        self.names
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(identity.identity_hash(), name.to_owned());
        Ok(fixture_credential(name))
    }
    fn verify(&self, _: &Path, expected: &AccountIdentity) -> AccountResult<VerifiedCredential> {
        let name = self
            .names
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&expected.identity_hash())
            .cloned()
            .ok_or(AccountError {
                code: "fixture_identity_missing",
            })?;
        Ok(fixture_credential(&name))
    }
    fn require_system_idle(&self) -> AccountResult<()> {
        panic!("synthetic Companion fixture must not inspect or switch the system account")
    }
    fn validate_target_configuration(&self, _: &Path) -> AccountResult<()> {
        Ok(())
    }
}

fn b64url_no_pad(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut output = String::new();
    let mut index = 0;
    while index + 3 <= bytes.len() {
        let word = ((bytes[index] as u32) << 16)
            | ((bytes[index + 1] as u32) << 8)
            | bytes[index + 2] as u32;
        output.push(TABLE[((word >> 18) & 63) as usize] as char);
        output.push(TABLE[((word >> 12) & 63) as usize] as char);
        output.push(TABLE[((word >> 6) & 63) as usize] as char);
        output.push(TABLE[(word & 63) as usize] as char);
        index += 3;
    }
    match bytes.len() - index {
        1 => {
            let word = (bytes[index] as u32) << 16;
            output.push(TABLE[((word >> 18) & 63) as usize] as char);
            output.push(TABLE[((word >> 12) & 63) as usize] as char);
        }
        2 => {
            let word = ((bytes[index] as u32) << 16) | ((bytes[index + 1] as u32) << 8);
            output.push(TABLE[((word >> 18) & 63) as usize] as char);
            output.push(TABLE[((word >> 12) & 63) as usize] as char);
            output.push(TABLE[((word >> 6) & 63) as usize] as char);
        }
        _ => {}
    }
    output
}

fn fixture_auth(name: &str) -> Vec<u8> {
    let email = format!("{name}@fixture.invalid");
    let payload = serde_json::to_vec(&json!({
        "email":email,
        "account_id":name,
        "exp":4102444800i64,
        "jti":"synthetic-no-login"
    }))
    .unwrap();
    let token = format!("synthetic.{}.fixture", b64url_no_pad(&payload));
    serde_json::to_vec(&json!({"tokens":{
        "access_token":token,
        "id_token":token,
        "refresh_token":"synthetic-refresh-not-a-credential",
        "account_id":name
    }}))
    .unwrap()
}

fn fixture_credential(name: &str) -> VerifiedCredential {
    let email = format!("{name}@fixture.invalid");
    VerifiedCredential::from_official_read(
        fixture_auth(name),
        &json!({"account":{"type":"chatgpt","email":email,"planType":"fixture-plan"}}),
        json!({"rateLimits":{"planType":"fixture-plan",
            "primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":4102444800i64},
            "secondary":{"usedPercent":1,"windowDurationMins":10080,"resetsAt":4102444800i64}}}),
    )
    .unwrap()
}

struct ProfileFixture {
    managed_id: String,
    profile_id: u64,
    home: PathBuf,
    alias: String,
    identity: String,
    code: &'static str,
}

fn register_fixture_profile(
    manager: &Arc<codexu_core::accounts::AccountManager>,
    login: &DeferredLogin,
    app_data: &Path,
    label: &str,
    code: &'static str,
) -> ProfileFixture {
    let account = manager
        .create_managed_account(label.to_owned(), "codex".into())
        .unwrap();
    let attempt = manager.begin_account_login(account.id.clone()).unwrap();
    login.run();
    assert_eq!(
        manager
            .get_login_attempt(&attempt.attempt_id)
            .unwrap()
            .phase,
        "verified"
    );
    let profile_id = Mutex::new(0u64);
    assert!(manager
        .register_pending_account(&account.id, |root, label, progress| {
            let mut config = crate::app_state::AppConfig::load(app_data);
            config
                .profiles
                .add(LocalCliKind::Codex, label.to_owned(), root.to_owned())
                .map_err(|_| AccountError {
                    code: "fixture_catalog_failed",
                })?;
            let id = config
                .profiles
                .entries
                .last()
                .map(|profile| profile.id)
                .ok_or(AccountError {
                    code: "fixture_catalog_failed",
                })?;
            progress.plan_profile(id)?;
            config.save(app_data).map_err(|_| AccountError {
                code: "fixture_settings_failed",
            })?;
            *profile_id.lock().unwrap_or_else(|e| e.into_inner()) = id;
            Ok(())
        })
        .unwrap());
    let home = manager
        .managed_history_roots()
        .unwrap()
        .into_iter()
        .find(|(id, _)| id == &account.id)
        .map(|(_, home)| home)
        .unwrap();
    let identity = manager
        .hub_account_snapshot(&account.id)
        .unwrap()
        .identity_hash;
    let profile_id = *profile_id.lock().unwrap_or_else(|e| e.into_inner());
    ProfileFixture {
        managed_id: account.id,
        profile_id,
        home,
        alias: format!("account-{profile_id}"),
        identity,
        code,
    }
}

struct SyntheticHub {
    endpoint: SocketAddr,
    log: PathBuf,
    post_seen: PathBuf,
    release: PathBuf,
    owner: Option<OwnedConsole>,
    owner_resource: std::sync::Weak<SyntheticHubOwnerResource>,
}
struct SyntheticHubOwnerResource;
impl SyntheticHub {
    fn start(
        root: &Path,
        python: &PinnedExecutable,
        workspace: &Path,
        home: &Path,
        alias: &str,
        token: &str,
        block_first_create: bool,
        domains: Arc<OwnedProcessDomains>,
    ) -> Self {
        let stem = alias.replace('-', "_");
        let script = root.join(format!("synthetic_hub_{stem}.py"));
        let ready = root.join(format!("synthetic_hub_{stem}.ready"));
        let log = root.join(format!("synthetic_hub_{stem}.jsonl"));
        let post_seen = root.join(format!("synthetic_hub_{stem}.post_seen"));
        let release = root.join(format!("synthetic_hub_{stem}.release"));
        fs::write(&script, SYNTHETIC_HUB).unwrap();
        let args = vec![
            "-I".into(),
            "-B".into(),
            script.to_string_lossy().into_owned(),
            ready.to_string_lossy().into_owned(),
            log.to_string_lossy().into_owned(),
            post_seen.to_string_lossy().into_owned(),
            release.to_string_lossy().into_owned(),
            alias.to_owned(),
            token.to_owned(),
            if block_first_create { "1" } else { "0" }.into(),
        ];
        let environment = codexu_core::local_cli::launch::Environment::codex(home).unwrap();
        let owner_resource = Arc::new(SyntheticHubOwnerResource);
        let owner_resource_weak = Arc::downgrade(&owner_resource);
        let resources: Arc<dyn Send + Sync> = owner_resource;
        let mut owner = start_owned_console(
            &python.path,
            workspace,
            &args,
            python.guard.try_clone().unwrap(),
            &environment,
            "Synthetic Companion Hub fixture",
            Some(domains),
            Some(resources),
            None,
            LaunchWindow::NoWindow,
        );
        let ready_stage = if block_first_create {
            "hub-a-ready"
        } else {
            "hub-b-ready"
        };
        wait_for_file(&ready, Duration::from_secs(10), ready_stage, || {
            owned_process_diagnostic("hub", &mut owner)
        });
        assert!(
            !owner.has_exited().unwrap(),
            "synthetic Hub exited before ready"
        );
        let port = serde_json::from_slice::<Value>(&fs::read(&ready).unwrap()).unwrap()["port"]
            .as_u64()
            .unwrap() as u16;
        Self {
            endpoint: SocketAddr::from(([127, 0, 0, 1], port)),
            log,
            post_seen,
            release,
            owner: Some(owner),
            owner_resource: owner_resource_weak,
        }
    }
    fn records(&self) -> Vec<Value> {
        fs::read_to_string(&self.log)
            .unwrap_or_default()
            .lines()
            .filter_map(|line| serde_json::from_str(line).ok())
            .collect()
    }
    fn wait_for_post(
        &self,
        client: &mut ClientProcess,
        hub_state: &HubState,
        hub_session_id: &str,
    ) {
        wait_for_file(
            &self.post_seen,
            Duration::from_secs(20),
            "first-create-post-seen",
            || {
                format!(
                    "{}; {}; {}; {}; {}",
                    hub_owner_diagnostic(hub_state, hub_session_id),
                    client.owner_diagnostic(),
                    client_output_diagnostic(&client.output_path),
                    client_failure_code_diagnostic(client.failure_code_path.as_deref()),
                    self.event_diagnostic(),
                )
            },
        );
    }
    fn event_diagnostic(&self) -> String {
        let mut kinds = [0usize; 5];
        let mut statuses = BTreeMap::<u64, usize>::new();
        let snapshot = read_diagnostic_snapshot(&self.log)
            .map(|snapshot| snapshot.bytes)
            .unwrap_or_default();
        for line in snapshot.split(|byte| *byte == b'\n') {
            let Ok(record) = serde_json::from_slice::<Value>(line) else {
                continue;
            };
            match record.get("kind").and_then(Value::as_str) {
                Some("overview") => kinds[0] += 1,
                Some("lookup") => kinds[1] += 1,
                Some("create") => kinds[2] += 1,
                Some("approve") => kinds[3] += 1,
                Some("response") => kinds[4] += 1,
                _ => {}
            }
            if let Some(status) = record.get("status").and_then(Value::as_u64) {
                *statuses.entry(status).or_default() += 1;
            }
        }
        let status_counts = if statuses.is_empty() {
            "none".to_owned()
        } else {
            statuses
                .iter()
                .map(|(status, count)| format!("{status}:{count}"))
                .collect::<Vec<_>>()
                .join(",")
        };
        format!(
            "hub_kind_counts=overview:{},lookup:{},create:{},approve:{},response:{} hub_status_counts={status_counts}",
            kinds[0], kinds[1], kinds[2], kinds[3], kinds[4]
        )
    }
    fn release_post_response(&self) {
        fs::write(&self.release, b"release").unwrap();
    }
    fn wait_for_lookups(&self, count: usize) {
        let deadline = Instant::now() + Duration::from_secs(15);
        while Instant::now() < deadline {
            if self
                .records()
                .iter()
                .filter(|v| v["kind"] == "lookup")
                .count()
                >= count
            {
                return;
            }
            thread::sleep(Duration::from_millis(20));
        }
        panic!("synthetic Hub did not observe {count} exact-request lookups");
    }
}
impl Drop for SyntheticHub {
    fn drop(&mut self) {
        if let Some(mut owner) = self.owner.take() {
            if owner.stop().is_err() || !owner.has_exited().is_ok_and(|exited| exited) {
                retain_owner(Box::new(owner));
            }
        }
    }
}

#[track_caller]
fn wait_for_file(
    path: &Path,
    duration: Duration,
    stage: &'static str,
    timeout_diagnostic: impl FnOnce() -> String,
) {
    let deadline = Instant::now() + duration;
    while Instant::now() < deadline {
        if path.is_file() {
            return;
        }
        thread::sleep(Duration::from_millis(10));
    }
    let caller = std::panic::Location::caller();
    panic!(
        "synthetic marker stage={stage} did not appear (line={}); {}",
        caller.line(),
        timeout_diagnostic()
    );
}

fn owned_process_diagnostic(label: &str, owner: &mut dyn OwnedProcess) -> String {
    match owner.has_exited() {
        Ok(true) => format!(
            "{label}_owner_has_exited=true {label}_owner_exit_success={}",
            owner
                .exit_success()
                .map(|success| success.to_string())
                .unwrap_or_else(|_| "unknown".to_owned())
        ),
        Ok(false) => format!("{label}_owner_has_exited=false"),
        Err(_) => format!("{label}_owner_has_exited=unknown"),
    }
}

fn hub_owner_diagnostic(hub_state: &HubState, session_id: &str) -> String {
    let mut inner = match hub_state.inner.try_lock() {
        Ok(inner) => inner,
        Err(std::sync::TryLockError::Poisoned(error)) => error.into_inner(),
        Err(std::sync::TryLockError::WouldBlock) => {
            return "hub_owner_has_exited=unknown".to_owned()
        }
    };
    let Some(session) = inner
        .sessions
        .values_mut()
        .find(|session| session.session_id == session_id)
    else {
        return "hub_owner_has_exited=unknown".to_owned();
    };
    owned_process_diagnostic("hub", session.process.as_mut())
}

const MAX_DIAGNOSTIC_SNAPSHOT_BYTES: usize = 64 * 1024;

struct DiagnosticSnapshot {
    bytes: Vec<u8>,
    file_bytes: Option<u64>,
    truncated: bool,
}

fn read_diagnostic_snapshot(path: &Path) -> io::Result<DiagnosticSnapshot> {
    let file = File::open(path)?;
    let file_bytes = file.metadata().ok().map(|metadata| metadata.len());
    let mut limited = Read::take(file, MAX_DIAGNOSTIC_SNAPSHOT_BYTES as u64);
    let mut snapshot = Vec::with_capacity(MAX_DIAGNOSTIC_SNAPSHOT_BYTES);
    let mut buffer = [0u8; 4096];
    loop {
        match limited.read(&mut buffer) {
            Ok(0) => break,
            Ok(read) => snapshot.extend_from_slice(&buffer[..read]),
            Err(error) => return Err(error),
        }
    }
    let truncated = snapshot.len() == MAX_DIAGNOSTIC_SNAPSHOT_BYTES
        || file_bytes.is_some_and(|bytes| bytes > MAX_DIAGNOSTIC_SNAPSHOT_BYTES as u64);
    Ok(DiagnosticSnapshot {
        bytes: snapshot,
        file_bytes,
        truncated,
    })
}

fn client_output_diagnostic(path: &Path) -> String {
    let snapshot = match read_diagnostic_snapshot(path) {
        Ok(snapshot) => snapshot,
        Err(_) => return "client_output_bytes=unknown client_output_json=unavailable".to_owned(),
    };
    let file_bytes = snapshot
        .file_bytes
        .map(|bytes| bytes.to_string())
        .unwrap_or_else(|| "unknown".to_owned());
    let parsed = if snapshot.truncated {
        None
    } else {
        serde_json::from_slice::<Value>(&snapshot.bytes).ok()
    };
    let parseability = if snapshot.truncated {
        "truncated"
    } else if snapshot.bytes.is_empty() {
        "empty"
    } else if parsed.is_some() {
        "valid"
    } else {
        "invalid"
    };
    let issue = diagnostic_issue_code(parsed.as_ref().and_then(|value| value.get("issueCode")));
    let state = diagnostic_state(
        parsed
            .as_ref()
            .and_then(|value| value.get("result"))
            .and_then(|result| result.get("state")),
    );
    format!(
        "client_output_bytes={file_bytes} client_output_json={parseability} client_issue_code={issue} client_state={state}"
    )
}

fn diagnostic_issue_code(value: Option<&Value>) -> String {
    let Some(value) = value.and_then(Value::as_str) else {
        return "none".to_owned();
    };
    if value.starts_with("companion_")
        && value.len() <= 96
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
    {
        value.to_owned()
    } else {
        "other".to_owned()
    }
}

fn client_failure_code_diagnostic(path: Option<&Path>) -> String {
    let Some(path) = path else {
        return "client_fail_code=disabled".to_owned();
    };
    let snapshot = match read_diagnostic_snapshot(path) {
        Ok(snapshot) if !snapshot.truncated => snapshot,
        Ok(_) => return "client_fail_code=unknown".to_owned(),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            return "client_fail_code=none".to_owned()
        }
        Err(_) => return "client_fail_code=unknown".to_owned(),
    };
    let parsed = serde_json::from_slice::<Value>(&snapshot.bytes).ok();
    let code = diagnostic_issue_code(parsed.as_ref().and_then(|value| value.get("code")));
    format!("client_fail_code={code}")
}

fn diagnostic_state(value: Option<&Value>) -> String {
    let Some(state) = value.and_then(Value::as_str) else {
        return "none".to_owned();
    };
    match state {
        "unknown" | "missing" | "cancelled" | "ready" | "reserved" | "created" | "accepted" => {
            state.to_owned()
        }
        _ => "other".to_owned(),
    }
}

fn wait_for_created_journal(path: &Path, operation_id: &str, duration: Duration) {
    let deadline = Instant::now() + duration;
    while Instant::now() < deadline {
        if let Ok(bytes) = fs::read(path) {
            if let Ok(journal) = serde_json::from_slice::<Value>(&bytes) {
                if journal["schema"] == 1 && journal["entries"][operation_id]["phase"] == "created"
                {
                    return;
                }
            }
        }
        thread::sleep(Duration::from_millis(10));
    }
    panic!("synthetic Companion create receipt was not persisted");
}

fn rewrite_journal_as_legacy_v1(path: &Path, operation_id: &str) {
    let mut journal: Value = serde_json::from_slice(&fs::read(path).unwrap()).unwrap();
    assert_eq!(journal["schema"], 1, "Companion journal schema changed");
    let entry = journal["entries"]
        .get_mut(operation_id)
        .expect("numeric operation claim was not in the durable journal");
    assert_eq!(
        entry["phase"], "created",
        "operation was not durably created"
    );
    let binding = entry["binding"]
        .as_object_mut()
        .expect("journal binding was not an object");
    assert!(
        binding.remove("windowsExecution").is_some(),
        "current journal entry omitted the optional execution extension"
    );
    fs::write(path, serde_json::to_vec(&journal).unwrap()).unwrap();
    let reopened: Value = serde_json::from_slice(&fs::read(path).unwrap()).unwrap();
    assert!(reopened["entries"][operation_id]["binding"]
        .get("windowsExecution")
        .is_none());
}

fn start_owned_console(
    executable: &Path,
    workspace: &Path,
    args: &[String],
    guard: File,
    environment: &codexu_core::local_cli::launch::Environment,
    title: &str,
    domains: Option<Arc<OwnedProcessDomains>>,
    resources: Option<Arc<dyn Send + Sync>>,
    capture: Option<&File>,
    window: LaunchWindow,
) -> OwnedConsole {
    match OwnedConsole::start_registered_owned_with_window(
        executable,
        workspace,
        args,
        guard,
        environment,
        title,
        domains,
        resources,
        capture,
        window,
    ) {
        Ok(owner) => owner,
        Err(failure) => {
            let (error, owner) = failure.into_parts();
            if let Some(mut owner) = owner {
                if owner.stop().is_err() || !owner.has_exited().is_ok_and(|exited| exited) {
                    retain_owner(owner);
                }
            }
            panic!("could not start test-owned process: {error}");
        }
    }
}

struct ClientProcess {
    owner: Option<OwnedConsole>,
    owner_resource: std::sync::Weak<()>,
    output_path: PathBuf,
    failure_code_path: Option<PathBuf>,
    output: Option<File>,
}
impl ClientProcess {
    fn owner_diagnostic(&mut self) -> String {
        match self.owner.as_mut() {
            Some(owner) => owned_process_diagnostic("client", owner),
            None => "client_owner_has_exited=unknown".to_owned(),
        }
    }
    fn wait_output(mut self) -> Value {
        let owner = self.owner.as_mut().expect("client owner missing");
        wait_for_owner(owner, Duration::from_secs(35));
        assert!(
            owner.exit_success().unwrap(),
            "one-shot Python client failed"
        );
        self.owner.take();
        self.output.take();
        assert!(
            self.owner_resource.upgrade().is_none(),
            "client OwnedConsole registration remained after confirmed exit"
        );
        serde_json::from_slice(&fs::read(&self.output_path).unwrap()).unwrap()
    }
    fn cancel_and_confirm(&mut self) {
        let owner = self.owner.as_mut().expect("client owner missing");
        owner.stop().unwrap();
        assert!(
            owner.has_exited().unwrap(),
            "cancelled Python Job is not empty"
        );
        self.owner.take();
        self.output.take();
        assert!(
            self.owner_resource.upgrade().is_none(),
            "cancelled client OwnedConsole registration remained after confirmed cleanup"
        );
    }
}
impl Drop for ClientProcess {
    fn drop(&mut self) {
        if let Some(mut owner) = self.owner.take() {
            if owner.stop().is_err() || !owner.has_exited().is_ok_and(|exited| exited) {
                retain_owner(Box::new(owner));
            }
        }
    }
}

fn wait_for_owner(owner: &mut impl OwnedProcess, duration: Duration) {
    let deadline = Instant::now() + duration;
    loop {
        if owner.has_exited().unwrap() {
            return;
        }
        assert!(Instant::now() < deadline, "owned test process did not exit");
        thread::sleep(Duration::from_millis(10));
    }
}

fn client_process(
    root: &Path,
    launcher: &Path,
    python: &PinnedExecutable,
    home: &Path,
    workspace: &Path,
    domains: Arc<OwnedProcessDomains>,
    call_name: &str,
    request_id: &str,
    command: &str,
    selector: Option<(&str, String)>,
    extra: &[(&str, String)],
    stdin: &str,
) -> ClientProcess {
    let config_path = root.join(format!("client-{call_name}.json"));
    let output_path = root.join(format!("client-{call_name}.stdout"));
    let failure_code_path =
        (command == "run").then(|| root.join(format!("client-{call_name}.failure.json")));
    let mut argv = vec![
        launcher.to_string_lossy().into_owned(),
        command.into(),
        "--request-id".into(),
        request_id.into(),
    ];
    if let Some((flag, value)) = selector {
        argv.extend([flag.into(), value]);
    }
    if !matches!(command, "status" | "cancel-reservation") {
        argv.extend(["--project".into(), workspace.to_string_lossy().into_owned()]);
    }
    for (flag, value) in extra {
        argv.extend([(*flag).into(), value.clone()]);
    }
    let mut config = json!({"argv":argv,"stdin":stdin});
    if let Some(path) = &failure_code_path {
        config["failure_diagnostic"] = json!(path.to_string_lossy().into_owned());
    }
    fs::write(&config_path, serde_json::to_vec(&config).unwrap()).unwrap();
    let output = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&output_path)
        .unwrap();
    let environment = codexu_core::local_cli::launch::Environment::codex(home).unwrap();
    let owner_resource = Arc::new(());
    let owner_resource_weak = Arc::downgrade(&owner_resource);
    let args = vec![
        "-I".into(),
        "-B".into(),
        "-c".into(),
        CLIENT_WRAPPER.into(),
        config_path.to_string_lossy().into_owned(),
    ];
    let owner = start_owned_console(
        &python.path,
        workspace,
        &args,
        python.guard.try_clone().unwrap(),
        &environment,
        "Synthetic Companion one-shot client",
        Some(domains),
        Some(owner_resource),
        Some(&output),
        LaunchWindow::NoWindow,
    );
    ClientProcess {
        owner: Some(owner),
        owner_resource: owner_resource_weak,
        output_path,
        failure_code_path,
        output: Some(output),
    }
}

fn json_scope(value: &Value) -> &str {
    assert_eq!(
        value["result"]["state"], "ready",
        "Python preflight did not return Ready: {value}"
    );
    value["result"]["scopeSha256"].as_str().unwrap()
}

struct ReceiverOwner(Option<Receiver>);
impl ReceiverOwner {
    fn start(
        private_root: PathBuf,
        python: PinnedExecutable,
        bridge: Arc<Bridge<companion_bridge_backend::AppBackend>>,
    ) -> Self {
        let (receiver, ready) = Receiver::start_owned(private_root, python, bridge).unwrap();
        ready.unwrap();
        Self(Some(receiver))
    }
    fn stop_confirmed(&mut self) {
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            let receiver = self.0.as_mut().expect("Receiver owner missing");
            match receiver.stop() {
                Ok(()) => {
                    assert!(!receiver.active());
                    self.0.take();
                    return;
                }
                Err(_) if Instant::now() < deadline => thread::sleep(Duration::from_millis(25)),
                Err(error) => {
                    let receiver = self.0.take().unwrap();
                    UNCONFIRMED_RECEIVERS
                        .get_or_init(|| Mutex::new(Vec::new()))
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .push(receiver);
                    panic!("Receiver stop was not confirmed: {}", error.code);
                }
            }
        }
    }
}
impl Drop for ReceiverOwner {
    fn drop(&mut self) {
        if let Some(mut receiver) = self.0.take() {
            if receiver.stop().is_err() || receiver.active() {
                UNCONFIRMED_RECEIVERS
                    .get_or_init(|| Mutex::new(Vec::new()))
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .push(receiver);
            }
        }
    }
}

struct HubOwner(Option<HubState>);
impl HubOwner {
    fn new() -> Self {
        Self(Some(HubState::default()))
    }
    fn get(&self) -> &HubState {
        self.0.as_ref().unwrap()
    }
    fn stop_confirmed(&mut self) {
        let hub = self.0.as_ref().unwrap();
        force_stop_owned(hub);
        if !hub
            .inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .sessions
            .is_empty()
        {
            let hub = self.0.take().unwrap();
            UNCONFIRMED_HUBS
                .get_or_init(|| Mutex::new(Vec::new()))
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push(hub);
            panic!("synthetic Hub Jobs were not confirmed empty");
        }
        self.0.take();
    }
}
impl Drop for HubOwner {
    fn drop(&mut self) {
        if let Some(hub) = self.0.take() {
            force_stop_owned(&hub);
            if !hub
                .inner
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .sessions
                .is_empty()
            {
                UNCONFIRMED_HUBS
                    .get_or_init(|| Mutex::new(Vec::new()))
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .push(hub);
            }
        }
    }
}

fn app_backend(
    application: Arc<crate::app_state::AppState>,
    manager: Arc<codexu_core::accounts::AccountManager>,
    gate: Arc<ManagedProxyGate>,
    hub: &HubState,
    domains: Arc<OwnedProcessDomains>,
    python: &PinnedExecutable,
) -> Arc<companion_bridge_backend::AppBackend> {
    Arc::new(
        companion_bridge_backend::AppBackend::new(
            application,
            manager,
            gate,
            hub,
            domains,
            PinnedExecutable {
                path: python.path.clone(),
                guard: python.guard.try_clone().unwrap(),
            },
        )
        .unwrap(),
    )
}

fn read_log(path: &Path) -> Vec<Value> {
    fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect()
}

const NATIVE_E2E_PROOF_ENV: &str = "AIGB_WINDOWS_PYTHON_RECEIVER_E2E_PROOF";
const NATIVE_E2E_PROOF: &[u8] = b"synthetic-python-receiver-native-e2e-pass\n";
const NATIVE_E2E_FILTER: &str = "commands::task_hub::companion_bridge_integration_tests::windows_python_receiver_app_backend_routes_two_sessions_and_status_after_disconnect_does_not_repost";
const NATIVE_E2E_TIMEOUT: Duration = Duration::from_secs(180);

fn validated_executable_env(key: &str) -> PathBuf {
    let requested = std::env::var_os(key)
        .unwrap_or_else(|| panic!("{key} must point at a test-only executable"));
    let path = PathBuf::from(requested)
        .canonicalize()
        .unwrap_or_else(|error| panic!("{key} path is unavailable: {error}"));
    assert!(
        path.is_file(),
        "{key} must be a regular file: {}",
        path.display()
    );
    path
}

fn validated_python_test_path() -> PathBuf {
    let path = validated_executable_env("AIGB_WINDOWS_COMPANION_TEST_PYTHON");
    assert!(
        path.extension()
            .and_then(|extension| extension.to_str())
            .is_some_and(|extension| extension.eq_ignore_ascii_case("exe")),
        "Python test path must be a Windows executable"
    );
    path
}

type NativeHandle = *mut c_void;

#[repr(C)]
#[derive(Clone, Copy)]
struct NativeSidAndAttributes {
    sid: *mut c_void,
    attributes: u32,
}

#[repr(C)]
struct NativeSid {
    revision: u8,
    sub_authority_count: u8,
    identifier_authority: [u8; 6],
    medium_integrity_rid: u32,
}

#[repr(C)]
struct NativeTokenMandatoryLabelBuffer {
    label: NativeSidAndAttributes,
    sid: NativeSid,
}

#[repr(C)]
#[derive(Clone, Copy, PartialEq, Eq)]
struct NativeLuid {
    low_part: u32,
    high_part: i32,
}

#[repr(C)]
struct NativeGenericMapping {
    generic_read: u32,
    generic_write: u32,
    generic_execute: u32,
    generic_all: u32,
}

#[repr(C)]
struct NativeTokenDefaultDacl {
    default_dacl: *mut c_void,
}

#[repr(C)]
struct NativeTokenPrimaryGroup {
    primary_group: *mut c_void,
}

#[repr(C)]
struct NativeAclHeader {
    revision: u8,
    sbz1: u8,
    size: u16,
    ace_count: u16,
    sbz2: u16,
}

#[repr(C)]
struct NativeAclSizeInformation {
    ace_count: u32,
    acl_bytes_in_use: u32,
    acl_bytes_free: u32,
}

#[repr(C)]
struct NativeAceHeader {
    ace_type: u8,
    ace_flags: u8,
    ace_size: u16,
}

#[repr(C)]
struct NativeSecurityDescriptor {
    revision: u8,
    sbz1: u8,
    control: u16,
    owner: *mut c_void,
    group: *mut c_void,
    sacl: *mut c_void,
    dacl: *mut c_void,
}

struct NativePrivilegeStatus {
    present: bool,
    enabled: bool,
}

fn native_test_environment(proof: &Path, fake_cli: &Path, python: &Path) -> Vec<u16> {
    let mut entries = vec![
        (
            NATIVE_E2E_PROOF_ENV.to_owned(),
            proof.as_os_str().to_os_string(),
        ),
        (
            "AIGB_WINDOWS_FAKECLI_PATH".to_owned(),
            fake_cli.as_os_str().to_os_string(),
        ),
        (
            "AIGB_WINDOWS_COMPANION_TEST_PYTHON".to_owned(),
            python.as_os_str().to_os_string(),
        ),
    ];
    for key in ["SystemRoot", "WINDIR", "TEMP", "TMP"] {
        if let Some(value) = std::env::var_os(key) {
            entries.push((key.to_owned(), value));
        }
    }
    entries.sort_by(|left, right| left.0.to_lowercase().cmp(&right.0.to_lowercase()));
    let mut environment = Vec::new();
    for (key, value) in entries {
        environment.extend(key.encode_utf16());
        environment.push(b'=' as u16);
        environment.extend(value.encode_wide());
        environment.push(0);
    }
    environment.push(0);
    environment
}

fn native_token_is_elevated(token: NativeHandle) -> bool {
    let mut value = 1u32;
    let mut needed = 0u32;
    let result = unsafe {
        GetTokenInformation(
            token,
            20,
            (&mut value as *mut u32).cast(),
            std::mem::size_of::<u32>() as u32,
            &mut needed,
        )
    };
    assert_ne!(result, 0, "read native test token elevation state");
    value != 0
}

fn try_native_token_information(token: NativeHandle, class: u32) -> Option<Vec<u8>> {
    let mut needed = 0u32;
    let first = unsafe { GetTokenInformation(token, class, ptr::null_mut(), 0, &mut needed) };
    if first != 0 || needed == 0 {
        return None;
    }
    let mut information = vec![0u8; needed as usize];
    let mut returned = 0u32;
    let ok = unsafe {
        GetTokenInformation(
            token,
            class,
            information.as_mut_ptr().cast(),
            information.len() as u32,
            &mut returned,
        )
    };
    if ok == 0 || returned as usize > information.len() {
        return None;
    }
    information.truncate(returned as usize);
    Some(information)
}

fn native_token_information(token: NativeHandle, class: u32) -> Vec<u8> {
    try_native_token_information(token, class).unwrap_or_else(|| {
        panic!(
            "read native test token information class {class}: {}",
            io::Error::last_os_error()
        )
    })
}

fn native_tokens_share_user_sid(left: NativeHandle, right: NativeHandle) -> bool {
    let left_information = native_token_information(left, 1);
    let right_information = native_token_information(right, 1);
    assert!(
        left_information.len() >= std::mem::size_of::<NativeSidAndAttributes>()
            && right_information.len() >= std::mem::size_of::<NativeSidAndAttributes>(),
        "native test token user information is truncated"
    );
    let left_user =
        unsafe { ptr::read_unaligned(left_information.as_ptr().cast::<NativeSidAndAttributes>()) };
    let right_user =
        unsafe { ptr::read_unaligned(right_information.as_ptr().cast::<NativeSidAndAttributes>()) };
    assert!(!left_user.sid.is_null() && !right_user.sid.is_null());
    unsafe { EqualSid(left_user.sid, right_user.sid) != 0 }
}

fn native_token_session_id(token: NativeHandle) -> u32 {
    let information = native_token_information(token, 12);
    assert!(
        information.len() >= std::mem::size_of::<u32>(),
        "native test token session information is truncated"
    );
    unsafe { ptr::read_unaligned(information.as_ptr().cast::<u32>()) }
}

fn native_assert_medium_integrity(token: NativeHandle) {
    let information = native_token_information(token, 25);
    assert!(
        information.len() >= std::mem::size_of::<NativeSidAndAttributes>(),
        "native test token integrity information is truncated"
    );
    let label =
        unsafe { ptr::read_unaligned(information.as_ptr().cast::<NativeSidAndAttributes>()) };
    assert!(!label.sid.is_null());
    assert_ne!(
        label.attributes & 0x20,
        0,
        "token integrity SID is not enabled"
    );
    let medium_sid = NativeSid {
        revision: 1,
        sub_authority_count: 1,
        identifier_authority: [0, 0, 0, 0, 0, 16],
        medium_integrity_rid: 0x2000,
    };
    assert_ne!(
        unsafe {
            EqualSid(
                label.sid,
                (&medium_sid as *const NativeSid).cast_mut().cast(),
            )
        },
        0,
        "native test child token integrity is not Medium"
    );
}

fn native_validate_child_token(parent: NativeHandle, child: NativeHandle) {
    assert!(
        native_tokens_share_user_sid(parent, child),
        "native test child token user SID differs from its parent"
    );
    assert_eq!(
        native_token_session_id(child),
        native_token_session_id(parent),
        "native test child token is in a different session"
    );
    assert!(
        !native_token_is_elevated(child),
        "native test child token is still elevated"
    );
    native_assert_medium_integrity(child);
}

fn native_token_default_dacl(token: NativeHandle) -> (Vec<u8>, NativeHandle) {
    let information = native_token_information(token, 6);
    assert!(information.len() >= std::mem::size_of::<NativeTokenDefaultDacl>());
    let token_dacl =
        unsafe { ptr::read_unaligned(information.as_ptr().cast::<NativeTokenDefaultDacl>()) };
    let acl = token_dacl.default_dacl;
    if !acl.is_null() {
        let start = information.as_ptr() as usize;
        let end = start
            .checked_add(information.len())
            .expect("native token default DACL buffer end overflowed");
        let address = acl as usize;
        let acl_minimum = start
            .checked_add(std::mem::size_of::<NativeTokenDefaultDacl>())
            .expect("native token default DACL offset overflowed");
        assert!(
            address >= acl_minimum && address < end,
            "native token default DACL points outside its returned buffer"
        );
        let mut acl_size = NativeAclSizeInformation {
            ace_count: 0,
            acl_bytes_in_use: 0,
            acl_bytes_free: 0,
        };
        assert_ne!(
            unsafe {
                GetAclInformation(
                    acl,
                    (&mut acl_size as *mut NativeAclSizeInformation).cast(),
                    std::mem::size_of::<NativeAclSizeInformation>() as u32,
                    2,
                )
            },
            0,
            "read native token default DACL size"
        );
        let acl_total = acl_size
            .acl_bytes_in_use
            .checked_add(acl_size.acl_bytes_free)
            .expect("native token default DACL total size overflowed");
        let header = unsafe { ptr::read_unaligned(acl.cast::<NativeAclHeader>()) };
        assert_eq!(header.size as u32, acl_total);
        let acl_end = address
            .checked_add(acl_total as usize)
            .expect("native token default DACL end overflowed");
        assert!(acl_size.acl_bytes_in_use >= 8);
        assert!(acl_end <= end, "native token default DACL is truncated");
    }
    (information, acl)
}

fn native_restricted_sid_count(token: NativeHandle) -> u32 {
    let information = native_token_information(token, 11);
    assert!(information.len() >= std::mem::size_of::<u32>());
    let count = unsafe { ptr::read_unaligned(information.as_ptr().cast::<u32>()) } as usize;
    assert!(
        count <= u32::MAX as usize,
        "native restricted SID count is invalid"
    );
    let attributes_offset = std::mem::size_of::<u32>()
        .div_ceil(std::mem::align_of::<NativeSidAndAttributes>())
        * std::mem::align_of::<NativeSidAndAttributes>();
    let entries_size = count
        .checked_mul(std::mem::size_of::<NativeSidAndAttributes>())
        .and_then(|size| attributes_offset.checked_add(size))
        .expect("native restricted SID list size overflowed");
    if count > 0 {
        assert!(
            entries_size <= information.len(),
            "native restricted SID list is truncated"
        );
    }
    count as u32
}

fn native_mapped_dacl_copy(dacl: NativeHandle) -> (Vec<usize>, NativeHandle) {
    if dacl.is_null() {
        return (Vec::new(), ptr::null_mut());
    }
    let mut size = NativeAclSizeInformation {
        ace_count: 0,
        acl_bytes_in_use: 0,
        acl_bytes_free: 0,
    };
    assert_ne!(
        unsafe {
            GetAclInformation(
                dacl,
                (&mut size as *mut NativeAclSizeInformation).cast(),
                std::mem::size_of::<NativeAclSizeInformation>() as u32,
                2,
            )
        },
        0,
        "read native fixture DACL size for access check"
    );
    let total = size
        .acl_bytes_in_use
        .checked_add(size.acl_bytes_free)
        .expect("native fixture DACL size overflowed");
    assert!((8..=u16::MAX as u32).contains(&total));
    assert!((8..=total).contains(&size.acl_bytes_in_use));
    let mut storage = vec![0usize; (total as usize).div_ceil(std::mem::size_of::<usize>())];
    let mapped = storage.as_mut_ptr().cast::<c_void>();
    unsafe {
        ptr::copy_nonoverlapping(dacl.cast::<u8>(), mapped.cast::<u8>(), total as usize);
    }
    let header = unsafe { ptr::read_unaligned(mapped.cast::<NativeAclHeader>()) };
    assert_eq!(header.size as u32, total);
    assert_eq!(header.ace_count as u32, size.ace_count);
    let mapping = NativeGenericMapping {
        generic_read: 0x0012_0089,
        generic_write: 0x0012_0116,
        generic_execute: 0x0012_00a0,
        generic_all: 0x001f_01ff,
    };
    let start = mapped as usize;
    let end = start
        .checked_add(total as usize)
        .expect("native fixture DACL copy end overflowed");
    let used_end = start
        .checked_add(size.acl_bytes_in_use as usize)
        .expect("native fixture DACL used end overflowed");
    let first_ace_minimum = start
        .checked_add(std::mem::size_of::<NativeAclHeader>())
        .expect("native fixture first ACE offset overflowed");
    for index in 0..size.ace_count {
        let mut ace = ptr::null_mut();
        assert_ne!(
            unsafe { GetAce(mapped, index, &mut ace) },
            0,
            "read native fixture DACL ACE for access check"
        );
        let ace_start = ace as usize;
        let ace_header_end = ace_start
            .checked_add(std::mem::size_of::<NativeAceHeader>())
            .expect("native fixture ACE header end overflowed");
        assert!(
            ace_start >= first_ace_minimum && ace_header_end <= used_end,
            "native fixture ACE header is outside the DACL copy"
        );
        let header = unsafe { ptr::read_unaligned(ace.cast::<NativeAceHeader>()) };
        let ace_end = ace_start
            .checked_add(header.ace_size as usize)
            .expect("native fixture ACE end overflowed");
        assert!(
            header.ace_size as usize >= std::mem::size_of::<NativeAceHeader>() + 4 + 8
                && ace_end <= used_end
                && ace_end <= end,
            "native fixture ACE is truncated or outside the DACL copy"
        );
        assert!(
            matches!(header.ace_type, 0 | 1),
            "native fixture DACL contains an unsupported ACE type"
        );
        let mask_address = ace_header_end;
        let sid_address = mask_address
            .checked_add(std::mem::size_of::<u32>())
            .expect("native fixture ACE SID offset overflowed");
        let sid_length = unsafe { GetLengthSid(sid_address as NativeHandle) };
        assert_ne!(sid_length, 0, "read native fixture ACE SID length");
        assert_eq!(
            header.ace_size as usize,
            std::mem::size_of::<NativeAceHeader>()
                + std::mem::size_of::<u32>()
                + sid_length as usize,
            "native fixture ACE SID length does not match ACE size"
        );
        let mut mask = unsafe { ptr::read_unaligned(mask_address as *const u32) };
        unsafe { MapGenericMask(&mut mask, &mapping) };
        unsafe { ptr::write_unaligned(mask_address as *mut u32, mask) };
    }
    (storage, mapped)
}

fn native_access_check_for_pipe_rights(dacl: NativeHandle, token: NativeHandle) -> (bool, bool) {
    let owner_information = native_token_information(token, 4);
    assert!(owner_information.len() >= std::mem::size_of::<NativeHandle>());
    let owner = unsafe { ptr::read_unaligned(owner_information.as_ptr().cast::<NativeHandle>()) };
    assert!(
        !owner.is_null(),
        "native fixture token has no default owner SID"
    );
    let group_information = native_token_information(token, 5);
    assert!(group_information.len() >= std::mem::size_of::<NativeTokenPrimaryGroup>());
    let primary_group = unsafe {
        ptr::read_unaligned(group_information.as_ptr().cast::<NativeTokenPrimaryGroup>())
            .primary_group
    };
    assert!(
        !primary_group.is_null(),
        "native fixture token has no primary group SID"
    );
    let (mapped_dacl_storage, mapped_dacl) = native_mapped_dacl_copy(dacl);
    let mut descriptor = NativeSecurityDescriptor {
        revision: 1,
        sbz1: 0,
        control: 0x0004, // SE_DACL_PRESENT
        owner,
        group: primary_group,
        sacl: ptr::null_mut(),
        dacl: mapped_dacl,
    };
    let mut impersonation = ptr::null_mut();
    assert_ne!(
        unsafe { DuplicateTokenEx(token, 0x0008, ptr::null(), 2, 2, &mut impersonation) },
        0,
        "duplicate native fixture token for pipe access check"
    );
    let impersonation = NativeHandleOwner(impersonation);
    let mapping = NativeGenericMapping {
        generic_read: 0x0012_0089,
        generic_write: 0x0012_0116,
        generic_execute: 0x0012_00a0,
        generic_all: 0x001f_01ff,
    };
    let mut check = |generic_access: u32| {
        let mut desired_access = generic_access;
        unsafe { MapGenericMask(&mut desired_access, &mapping) };
        let mut privileges = [0u64; 128];
        let mut privileges_length = std::mem::size_of_val(&privileges) as u32;
        let mut granted = 0u32;
        let mut access_status = 0i32;
        let checked = unsafe {
            AccessCheck(
                (&mut descriptor as *mut NativeSecurityDescriptor).cast(),
                impersonation.0,
                desired_access,
                &mapping,
                privileges.as_mut_ptr().cast(),
                &mut privileges_length,
                &mut granted,
                &mut access_status,
            )
        };
        if checked == 0 {
            let error = unsafe { GetLastError() };
            panic!("check native fixture anonymous-pipe access failed (code=0x{error:08x})");
        }
        access_status != 0
    };
    let allowed = (check(0x8000_0000), check(0x4000_0000)); // GENERIC_READ and GENERIC_WRITE
    drop(mapped_dacl_storage);
    allowed
}

fn native_assert_private_default_dacl(
    acl: NativeHandle,
    user_sid: NativeHandle,
    system_sid: NativeHandle,
) {
    assert!(!acl.is_null(), "native fixture token has no default DACL");
    let mut acl_size = NativeAclSizeInformation {
        ace_count: 0,
        acl_bytes_in_use: 0,
        acl_bytes_free: 0,
    };
    assert_ne!(
        unsafe {
            GetAclInformation(
                acl,
                (&mut acl_size as *mut NativeAclSizeInformation).cast(),
                std::mem::size_of::<NativeAclSizeInformation>() as u32,
                2,
            )
        },
        0,
        "read normalized native fixture DACL"
    );
    assert_eq!(
        acl_size.ace_count, 2,
        "native fixture DACL must have two ACEs"
    );
    let mut user_found = false;
    let mut system_found = false;
    let mut expected_size = 8usize;
    for index in 0..acl_size.ace_count {
        let mut ace = ptr::null_mut();
        assert_ne!(
            unsafe { GetAce(acl, index, &mut ace) },
            0,
            "read normalized native fixture DACL ACE"
        );
        assert!(!ace.is_null());
        let header = unsafe { ptr::read_unaligned(ace.cast::<NativeAceHeader>()) };
        assert_eq!(
            header.ace_type, 0,
            "native fixture DACL contains a non-allow ACE"
        );
        assert_eq!(header.ace_flags, 0, "native fixture DACL ACE has flags");
        let minimum_size = std::mem::size_of::<NativeAceHeader>() + std::mem::size_of::<u32>() + 8;
        assert!(header.ace_size as usize >= minimum_size);
        let mask = unsafe {
            ptr::read_unaligned(
                (ace as *const u8)
                    .add(std::mem::size_of::<NativeAceHeader>())
                    .cast::<u32>(),
            )
        };
        assert_eq!(
            mask, 0x1000_0000,
            "native fixture DACL ACE is not GENERIC_ALL"
        );
        let sid = unsafe {
            (ace as *mut u8)
                .add(std::mem::size_of::<NativeAceHeader>() + std::mem::size_of::<u32>())
                .cast::<c_void>()
        };
        let sid_size = unsafe { GetLengthSid(sid) };
        assert_ne!(
            sid_size, 0,
            "read normalized native fixture DACL SID length"
        );
        assert_eq!(
            header.ace_size as usize,
            std::mem::size_of::<NativeAceHeader>() + std::mem::size_of::<u32>() + sid_size as usize,
            "native fixture DACL ACE has trailing or truncated data"
        );
        expected_size = expected_size
            .checked_add(header.ace_size as usize)
            .expect("native fixture DACL size overflowed");
        let is_user = unsafe { EqualSid(sid, user_sid) } != 0;
        let is_system = unsafe { EqualSid(sid, system_sid) } != 0;
        assert_ne!(
            is_user, is_system,
            "native fixture DACL contains an unexpected SID"
        );
        if is_user {
            assert!(!user_found, "native fixture DACL repeats the user ACE");
            user_found = true;
        } else {
            assert!(!system_found, "native fixture DACL repeats the SYSTEM ACE");
            system_found = true;
        }
    }
    assert!(
        user_found && system_found,
        "native fixture DACL is missing a required ACE"
    );
    assert_eq!(
        acl_size.acl_bytes_in_use as usize, expected_size,
        "native fixture DACL contains unused or unverified bytes"
    );
}

fn native_set_private_default_dacl(token: NativeHandle) {
    let user_information = native_token_information(token, 1);
    assert!(user_information.len() >= std::mem::size_of::<NativeSidAndAttributes>());
    let user =
        unsafe { ptr::read_unaligned(user_information.as_ptr().cast::<NativeSidAndAttributes>()) };
    assert!(!user.sid.is_null(), "native fixture token has no user SID");
    let user_sid_size = unsafe { GetLengthSid(user.sid) };
    assert_ne!(user_sid_size, 0, "read native fixture user SID length");

    let mut system_sid_storage = [0u64; 9];
    let mut system_sid_size = 68u32;
    assert_ne!(
        unsafe {
            CreateWellKnownSid(
                22, // WinLocalSystemSid
                ptr::null_mut(),
                system_sid_storage.as_mut_ptr().cast(),
                &mut system_sid_size,
            )
        },
        0,
        "create fixture SYSTEM SID"
    );
    let system_sid = system_sid_storage.as_mut_ptr().cast::<c_void>();
    let acl_header_size = 8usize;
    let ace_prefix_size = std::mem::size_of::<NativeAceHeader>() + std::mem::size_of::<u32>();
    let system_sid_length = unsafe { GetLengthSid(system_sid) };
    assert_ne!(system_sid_length, 0, "read fixture SYSTEM SID length");
    assert_eq!(system_sid_length, system_sid_size);
    let acl_length = acl_header_size
        .checked_add(ace_prefix_size + user_sid_size as usize)
        .and_then(|length| length.checked_add(ace_prefix_size + system_sid_length as usize))
        .expect("private native fixture DACL size overflowed");
    assert!(
        acl_length <= u16::MAX as usize,
        "private native fixture DACL is too large"
    );
    let mut acl_storage = vec![0usize; acl_length.div_ceil(std::mem::size_of::<usize>())];
    let acl = acl_storage.as_mut_ptr().cast::<c_void>();
    assert_ne!(
        unsafe { InitializeAcl(acl, acl_length as u32, 2) },
        0,
        "initialize private native fixture DACL"
    );
    assert_ne!(
        unsafe { AddAccessAllowedAce(acl, 2, 0x1000_0000, user.sid) },
        0,
        "add fixture user to private default DACL"
    );
    assert_ne!(
        unsafe { AddAccessAllowedAce(acl, 2, 0x1000_0000, system_sid) },
        0,
        "add SYSTEM to private default DACL"
    );
    let default_dacl = NativeTokenDefaultDacl { default_dacl: acl };
    assert_ne!(
        unsafe {
            SetTokenInformation(
                token,
                6, // TokenDefaultDacl
                (&default_dacl as *const NativeTokenDefaultDacl).cast(),
                std::mem::size_of::<NativeTokenDefaultDacl>() as u32,
            )
        },
        0,
        "set private native fixture token default DACL"
    );

    let (_readback, readback_acl) = native_token_default_dacl(token);
    native_assert_private_default_dacl(readback_acl, user.sid, system_sid);
    let (read_allowed, write_allowed) = native_access_check_for_pipe_rights(readback_acl, token);
    assert!(
        read_allowed && write_allowed,
        "normalized native fixture token cannot access both anonymous-pipe ends"
    );
    eprintln!(
        "native E2E normalized token DACL: pipe_read={read_allowed} pipe_write={write_allowed} ace_count=2"
    );
}

fn native_diagnose_and_normalize_token_dacl(token: NativeHandle) {
    let (_original_information, original_acl) = native_token_default_dacl(token);
    let restricted_sid_count = native_restricted_sid_count(token);
    let (original_read, original_write) = native_access_check_for_pipe_rights(original_acl, token);
    eprintln!(
        "native E2E restricted token default DACL: present={} pipe_read={original_read} pipe_write={original_write} restricted_sid_count={restricted_sid_count}",
        !original_acl.is_null()
    );
    native_set_private_default_dacl(token);
}

fn native_non_elevated_child_token(original: NativeHandle) -> NativeHandleOwner {
    let mut restricted = ptr::null_mut();
    assert_ne!(
        unsafe {
            CreateRestrictedToken(
                original,
                5,
                0,
                ptr::null(),
                0,
                ptr::null(),
                0,
                ptr::null(),
                &mut restricted,
            )
        },
        0,
        "create non-elevated native test token: {}",
        io::Error::last_os_error()
    );
    let token = NativeHandleOwner(restricted);
    native_diagnose_and_normalize_token_dacl(token.0);
    let mut integrity = NativeTokenMandatoryLabelBuffer {
        label: NativeSidAndAttributes {
            sid: ptr::null_mut(),
            attributes: 0x20,
        },
        sid: NativeSid {
            revision: 1,
            sub_authority_count: 1,
            identifier_authority: [0, 0, 0, 0, 0, 16],
            medium_integrity_rid: 0x2000,
        },
    };
    integrity.label.sid = (&mut integrity.sid as *mut NativeSid).cast();
    assert_ne!(
        unsafe {
            SetTokenInformation(
                token.0,
                25,
                (&integrity as *const NativeTokenMandatoryLabelBuffer).cast(),
                (std::mem::size_of::<NativeSidAndAttributes>() + std::mem::size_of::<NativeSid>())
                    as u32,
            )
        },
        0,
        "set restricted native test token integrity to Medium: {}",
        io::Error::last_os_error()
    );
    native_validate_child_token(original, token.0);
    token
}

struct NativeHandleOwner(NativeHandle);

impl Drop for NativeHandleOwner {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { CloseHandle(self.0) };
        }
    }
}

fn native_token_type_name(token: NativeHandle) -> Result<&'static str, u32> {
    let mut token_type = 0u32;
    let mut returned = 0u32;
    if unsafe {
        GetTokenInformation(
            token,
            8,
            (&mut token_type as *mut u32).cast(),
            std::mem::size_of::<u32>() as u32,
            &mut returned,
        )
    } == 0
    {
        return Err(unsafe { GetLastError() });
    }
    if returned < std::mem::size_of::<u32>() as u32 {
        return Err(13);
    }
    Ok(match token_type {
        1 => "primary",
        2 => "impersonation",
        _ => "other",
    })
}

fn native_token_privilege_status(
    token: NativeHandle,
    privilege_name: &str,
) -> Result<NativePrivilegeStatus, u32> {
    let privilege_name: Vec<u16> = privilege_name.encode_utf16().chain(Some(0)).collect();
    let mut requested_luid = NativeLuid {
        low_part: 0,
        high_part: 0,
    };
    if unsafe { LookupPrivilegeValueW(ptr::null(), privilege_name.as_ptr(), &mut requested_luid) }
        == 0
    {
        return Err(unsafe { GetLastError() });
    }

    let mut needed = 0u32;
    let initial = unsafe { GetTokenInformation(token, 3, ptr::null_mut(), 0, &mut needed) };
    if initial == 0 {
        let error = unsafe { GetLastError() };
        if error != 122 {
            return Err(error);
        }
    }
    if needed < std::mem::size_of::<u32>() as u32 {
        return Err(13);
    }

    let unit_size = std::mem::size_of::<u64>();
    let Some(storage_units) = (needed as usize)
        .checked_add(unit_size - 1)
        .map(|size| size / unit_size)
    else {
        return Err(8);
    };
    let mut storage = vec![0u64; storage_units];
    let mut returned = 0u32;
    if unsafe { GetTokenInformation(token, 3, storage.as_mut_ptr().cast(), needed, &mut returned) }
        == 0
    {
        return Err(unsafe { GetLastError() });
    }

    let capacity = storage.len() * unit_size;
    if returned < 4 || returned as usize > capacity {
        return Err(13);
    }
    let bytes =
        unsafe { std::slice::from_raw_parts(storage.as_ptr().cast::<u8>(), returned as usize) };
    let count = u32::from_ne_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) as usize;
    if count > (bytes.len() - 4) / 12 {
        return Err(13);
    }

    for index in 0..count {
        let offset = 4 + index * 12;
        let luid = NativeLuid {
            low_part: u32::from_ne_bytes([
                bytes[offset],
                bytes[offset + 1],
                bytes[offset + 2],
                bytes[offset + 3],
            ]),
            high_part: i32::from_ne_bytes([
                bytes[offset + 4],
                bytes[offset + 5],
                bytes[offset + 6],
                bytes[offset + 7],
            ]),
        };
        if luid == requested_luid {
            let attributes = u32::from_ne_bytes([
                bytes[offset + 8],
                bytes[offset + 9],
                bytes[offset + 10],
                bytes[offset + 11],
            ]);
            return Ok(NativePrivilegeStatus {
                present: true,
                enabled: attributes & 0x2 != 0,
            });
        }
    }

    Ok(NativePrivilegeStatus {
        present: false,
        enabled: false,
    })
}

fn native_executable_access_check(token: NativeHandle, executable: &Path) -> Result<bool, u32> {
    let mut impersonation_token = ptr::null_mut();
    if unsafe { DuplicateTokenEx(token, 0x0008, ptr::null(), 2, 2, &mut impersonation_token) } == 0
    {
        return Err(unsafe { GetLastError() });
    }
    // AccessCheck needs an impersonation token; this duplicate is never applied to the thread.
    let impersonation_token = NativeHandleOwner(impersonation_token);

    let file_name: Vec<u16> = executable
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect();
    let security_information = 0x0000_0001 | 0x0000_0002 | 0x0000_0004; // OWNER | GROUP | DACL
    let mut needed = 0u32;
    let initial = unsafe {
        GetFileSecurityW(
            file_name.as_ptr(),
            security_information,
            ptr::null_mut(),
            0,
            &mut needed,
        )
    };
    if initial == 0 {
        let error = unsafe { GetLastError() };
        if error != 122 {
            return Err(error);
        }
    }
    if needed == 0 {
        return Err(13);
    }

    let unit_size = std::mem::size_of::<u64>();
    let Some(descriptor_units) = (needed as usize)
        .checked_add(unit_size - 1)
        .map(|size| size / unit_size)
    else {
        return Err(8);
    };
    let mut descriptor = vec![0u64; descriptor_units];
    let descriptor_capacity = descriptor.len() * unit_size;
    let mut descriptor_size = 0u32;
    if unsafe {
        GetFileSecurityW(
            file_name.as_ptr(),
            security_information,
            descriptor.as_mut_ptr().cast(),
            needed,
            &mut descriptor_size,
        )
    } == 0
    {
        return Err(unsafe { GetLastError() });
    }
    if descriptor_size as usize > descriptor_capacity {
        return Err(122);
    }

    let mapping = NativeGenericMapping {
        generic_read: 0x0012_0089,
        generic_write: 0x0012_0116,
        generic_execute: 0x0012_00a0,
        generic_all: 0x001f_01ff,
    };
    let mut desired_access = 0x8000_0000 | 0x2000_0000;
    unsafe { MapGenericMask(&mut desired_access, &mapping) };

    let mut privilege_set = [0u64; 128];
    let mut privilege_set_length = std::mem::size_of_val(&privilege_set) as u32;
    let mut granted_access = 0u32;
    let mut access_status = 0i32;
    if unsafe {
        AccessCheck(
            descriptor.as_mut_ptr().cast(),
            impersonation_token.0,
            desired_access,
            &mapping,
            privilege_set.as_mut_ptr().cast(),
            &mut privilege_set_length,
            &mut granted_access,
            &mut access_status,
        )
    } == 0
    {
        return Err(unsafe { GetLastError() });
    }
    Ok(access_status != 0)
}

fn native_format_token_type(result: Result<&'static str, u32>) -> String {
    match result {
        Ok(token_type) => token_type.to_owned(),
        Err(error) => format!("error:{error}"),
    }
}

fn native_format_privilege_status(result: Result<NativePrivilegeStatus, u32>) -> String {
    match result {
        Ok(status) => format!("present={} enabled={}", status.present, status.enabled),
        Err(error) => format!("error:{error}"),
    }
}

fn native_format_access_status(result: Result<bool, u32>) -> String {
    match result {
        Ok(true) => "allowed".to_owned(),
        Ok(false) => "denied".to_owned(),
        Err(error) => format!("error:{error}"),
    }
}

fn report_native_launch_diagnostics(
    original_token: NativeHandle,
    child_token: NativeHandle,
    executable: &Path,
) {
    let original_type = native_format_token_type(native_token_type_name(original_token));
    let child_type = native_format_token_type(native_token_type_name(child_token));
    let impersonate = native_format_privilege_status(native_token_privilege_status(
        original_token,
        "SeImpersonatePrivilege",
    ));
    let increase_quota = native_format_privilege_status(native_token_privilege_status(
        original_token,
        "SeIncreaseQuotaPrivilege",
    ));
    let executable_access =
        native_format_access_status(native_executable_access_check(child_token, executable));
    let _ = writeln!(
        io::stderr(),
        "native E2E launch diagnostics: original_token_type={original_type} child_token_type={child_type} se_impersonate={impersonate} se_increase_quota={increase_quota} executable_dacl_read_execute={executable_access}"
    );
}

#[repr(C)]
struct NativeStartupInfo {
    size: u32,
    reserved: *mut u16,
    desktop: *mut u16,
    title: *mut u16,
    x: u32,
    y: u32,
    x_size: u32,
    y_size: u32,
    x_chars: u32,
    y_chars: u32,
    fill: u32,
    flags: u32,
    show: u16,
    reserved_size: u16,
    reserved_bytes: *mut u8,
    stdin: NativeHandle,
    stdout: NativeHandle,
    stderr: NativeHandle,
}

#[repr(C)]
struct NativeProcessInfo {
    process: NativeHandle,
    thread: NativeHandle,
    process_id: u32,
    thread_id: u32,
}

#[repr(C)]
#[derive(Default)]
struct NativeBasicLimits {
    process_time: i64,
    job_time: i64,
    flags: u32,
    min_working_set: usize,
    max_working_set: usize,
    active_process_limit: u32,
    affinity: usize,
    priority: u32,
    scheduling: u32,
}

#[repr(C)]
#[derive(Default)]
struct NativeExtendedLimits {
    basic: NativeBasicLimits,
    io: [u64; 6],
    process_memory: usize,
    job_memory: usize,
    peak_process_memory: usize,
    peak_job_memory: usize,
}

#[repr(C)]
#[derive(Default)]
struct NativeJobAccounting {
    user_time: i64,
    kernel_time: i64,
    period_user_time: i64,
    period_kernel_time: i64,
    page_faults: u32,
    total_processes: u32,
    active_processes: u32,
    terminated_processes: u32,
}

#[link(name = "advapi32")]
unsafe extern "system" {
    fn OpenProcessToken(process: NativeHandle, access: u32, token: *mut NativeHandle) -> i32;
    fn GetTokenInformation(
        token: NativeHandle,
        class: u32,
        buffer: *mut c_void,
        size: u32,
        needed: *mut u32,
    ) -> i32;
    fn LookupPrivilegeValueW(
        system_name: *const u16,
        name: *const u16,
        luid: *mut NativeLuid,
    ) -> i32;
    fn DuplicateTokenEx(
        existing: NativeHandle,
        desired_access: u32,
        attributes: *const c_void,
        impersonation_level: u32,
        token_type: u32,
        duplicate: *mut NativeHandle,
    ) -> i32;
    fn GetFileSecurityW(
        file_name: *const u16,
        requested_information: u32,
        descriptor: *mut c_void,
        length: u32,
        needed: *mut u32,
    ) -> i32;
    fn MapGenericMask(access: *mut u32, mapping: *const NativeGenericMapping);
    fn AccessCheck(
        descriptor: *const c_void,
        client_token: NativeHandle,
        desired_access: u32,
        mapping: *const NativeGenericMapping,
        privilege_set: *mut c_void,
        privilege_set_length: *mut u32,
        granted_access: *mut u32,
        access_status: *mut i32,
    ) -> i32;
    fn CreateWellKnownSid(
        sid_type: u32,
        domain_sid: NativeHandle,
        sid: NativeHandle,
        sid_size: *mut u32,
    ) -> i32;
    fn GetAclInformation(
        acl: NativeHandle,
        information: *mut c_void,
        information_length: u32,
        information_class: u32,
    ) -> i32;
    fn InitializeAcl(acl: NativeHandle, length: u32, revision: u32) -> i32;
    fn AddAccessAllowedAce(acl: NativeHandle, revision: u32, mask: u32, sid: NativeHandle) -> i32;
    fn GetAce(acl: NativeHandle, index: u32, ace: *mut NativeHandle) -> i32;
    fn GetLengthSid(sid: NativeHandle) -> u32;
    fn SetTokenInformation(
        token: NativeHandle,
        class: u32,
        information: *const c_void,
        size: u32,
    ) -> i32;
    fn EqualSid(left: NativeHandle, right: NativeHandle) -> i32;
    fn CreateRestrictedToken(
        token: NativeHandle,
        flags: u32,
        disable_count: u32,
        disable: *const c_void,
        delete_count: u32,
        delete: *const c_void,
        restrict_count: u32,
        restrict: *const c_void,
        result: *mut NativeHandle,
    ) -> i32;
    fn CreateProcessAsUserW(
        token: NativeHandle,
        application: *const u16,
        command: *mut u16,
        process_attributes: *const c_void,
        thread_attributes: *const c_void,
        inherit_handles: i32,
        flags: u32,
        environment: *const c_void,
        directory: *const u16,
        startup: *mut NativeStartupInfo,
        info: *mut NativeProcessInfo,
    ) -> i32;
}

#[link(name = "kernel32")]
unsafe extern "system" {
    fn GetCurrentProcess() -> NativeHandle;
    fn GetLastError() -> u32;
    fn CloseHandle(handle: NativeHandle) -> i32;
    fn CreateJobObjectW(attributes: *const c_void, name: *const u16) -> NativeHandle;
    fn SetInformationJobObject(
        job: NativeHandle,
        class: i32,
        information: *const c_void,
        size: u32,
    ) -> i32;
    fn QueryInformationJobObject(
        job: NativeHandle,
        class: i32,
        information: *mut c_void,
        size: u32,
        returned: *mut u32,
    ) -> i32;
    fn AssignProcessToJobObject(job: NativeHandle, process: NativeHandle) -> i32;
    fn ResumeThread(thread: NativeHandle) -> u32;
    fn CreateProcessW(
        application: *const u16,
        command: *mut u16,
        process_attributes: *const c_void,
        thread_attributes: *const c_void,
        inherit_handles: i32,
        flags: u32,
        environment: *const c_void,
        directory: *const u16,
        startup: *mut NativeStartupInfo,
        info: *mut NativeProcessInfo,
    ) -> i32;
    fn WaitForSingleObject(handle: NativeHandle, milliseconds: u32) -> u32;
    fn GetExitCodeProcess(process: NativeHandle, code: *mut u32) -> i32;
    fn TerminateProcess(process: NativeHandle, code: u32) -> i32;
    fn TerminateJobObject(job: NativeHandle, code: u32) -> i32;
}

struct NativeTestJob {
    job: NativeHandle,
    process: NativeHandle,
    thread: NativeHandle,
    assigned: bool,
    confirmed_empty: bool,
    desktop: Option<NativeDesktop>,
    proof_directory: Option<tempfile::TempDir>,
}

static UNCONFIRMED_NATIVE_TEST_JOBS: OnceLock<Mutex<Vec<[usize; 4]>>> = OnceLock::new();

fn retain_native_test_job(
    job: NativeHandle,
    process: NativeHandle,
    thread: NativeHandle,
    desktop: usize,
) {
    UNCONFIRMED_NATIVE_TEST_JOBS
        .get_or_init(|| Mutex::new(Vec::new()))
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .push([job as usize, process as usize, thread as usize, desktop]);
}

fn native_job_active_processes(job: NativeHandle) -> Option<u32> {
    let mut accounting = NativeJobAccounting::default();
    let ok = unsafe {
        QueryInformationJobObject(
            job,
            1,
            (&mut accounting as *mut NativeJobAccounting).cast(),
            std::mem::size_of::<NativeJobAccounting>() as u32,
            ptr::null_mut(),
        )
    };
    (ok != 0).then_some(accounting.active_processes)
}

fn wait_native_job_empty(job: NativeHandle, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        if native_job_active_processes(job) == Some(0) {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        thread::sleep(Duration::from_millis(20));
    }
}

impl NativeTestJob {
    fn retain_unknown(&mut self) {
        let desktop = self
            .desktop
            .take()
            .map(NativeDesktop::into_raw_handle)
            .unwrap_or_default();
        retain_native_test_job(self.job, self.process, self.thread, desktop);
        self.job = ptr::null_mut();
        self.process = ptr::null_mut();
        self.thread = ptr::null_mut();
        if let Some(directory) = self.proof_directory.take() {
            let _ = directory.keep();
        }
    }

    fn confirm_empty(&mut self) -> bool {
        if wait_native_job_empty(self.job, Duration::from_secs(5)) {
            self.confirmed_empty = true;
            true
        } else {
            false
        }
    }

    fn terminate_and_confirm_empty(&mut self) -> bool {
        let _ = unsafe { TerminateJobObject(self.job, 1) };
        self.confirm_empty()
    }
}

impl Drop for NativeTestJob {
    fn drop(&mut self) {
        if self.job.is_null() {
            return;
        }
        if self.assigned && !self.confirmed_empty {
            if !wait_native_job_empty(self.job, Duration::ZERO) {
                let _ = unsafe { TerminateJobObject(self.job, 1) };
                if !wait_native_job_empty(self.job, Duration::from_secs(5)) {
                    self.retain_unknown();
                    return;
                }
            }
        } else if !self.assigned && !self.process.is_null() {
            if unsafe { WaitForSingleObject(self.process, 0) } != 0 {
                let _ = unsafe { TerminateProcess(self.process, 1) };
                if unsafe { WaitForSingleObject(self.process, 5000) } != 0 {
                    self.retain_unknown();
                    return;
                }
            }
        }
        unsafe {
            if !self.process.is_null() {
                CloseHandle(self.process);
            }
            if !self.thread.is_null() {
                CloseHandle(self.thread);
            }
            CloseHandle(self.job);
        }
    }
}

fn launch_native_e2e_child(fake_cli: &Path, python: &Path, proof_directory: tempfile::TempDir) {
    let proof = proof_directory.path().join("native-e2e-proof.txt");
    assert!(proof.is_absolute() && !proof.exists());
    assert_eq!(
        proof.file_name(),
        Some(std::ffi::OsStr::new("native-e2e-proof.txt"))
    );
    let environment = native_test_environment(&proof, fake_cli, python);
    let executable = std::env::current_exe().unwrap();
    let application: Vec<u16> = executable
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect();
    let command_line = format!(
        "\"{}\" --exact {NATIVE_E2E_FILTER} --nocapture",
        executable.display()
    );
    let mut command: Vec<u16> = command_line.encode_utf16().chain(Some(0)).collect();
    let mut startup: NativeStartupInfo = unsafe { std::mem::zeroed() };
    startup.size = std::mem::size_of::<NativeStartupInfo>() as u32;
    let mut info: NativeProcessInfo = unsafe { std::mem::zeroed() };
    let job = unsafe { CreateJobObjectW(ptr::null(), ptr::null()) };
    assert!(
        !job.is_null(),
        "create native test Job: {}",
        io::Error::last_os_error()
    );
    let mut owned = NativeTestJob {
        job,
        process: ptr::null_mut(),
        thread: ptr::null_mut(),
        assigned: false,
        confirmed_empty: false,
        desktop: None,
        proof_directory: Some(proof_directory),
    };
    let mut limits = NativeExtendedLimits::default();
    limits.basic.flags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    assert_ne!(
        unsafe {
            SetInformationJobObject(
                owned.job,
                9,
                (&limits as *const NativeExtendedLimits).cast(),
                std::mem::size_of::<NativeExtendedLimits>() as u32,
            )
        },
        0,
        "configure native test Job: {}",
        io::Error::last_os_error()
    );

    let mut original_token = ptr::null_mut();
    assert_ne!(
        unsafe { OpenProcessToken(GetCurrentProcess(), 0x008b, &mut original_token) },
        0,
        "open native test runner token: {}",
        io::Error::last_os_error()
    );
    let original_token = NativeHandleOwner(original_token);
    let elevated = native_token_is_elevated(original_token.0);
    let token = if elevated {
        native_non_elevated_child_token(original_token.0)
    } else {
        native_validate_child_token(original_token.0, original_token.0);
        NativeHandleOwner(ptr::null_mut())
    };
    if elevated {
        // Diagnostics are fail-open and never gate the real, Job-isolated child launch.
        report_native_launch_diagnostics(original_token.0, token.0, &executable);
    }
    let child_token = if elevated { token.0 } else { original_token.0 };
    owned.desktop = Some(
        NativeDesktop::create(original_token.0, child_token)
            .unwrap_or_else(|error| panic!("create isolated native test desktop: {error}")),
    );
    startup.desktop = owned
        .desktop
        .as_ref()
        .expect("isolated native test desktop was not retained")
        .lp_desktop();
    let creation_flags = 0x0000_0004 | 0x0000_0400; // Match the core fixture; the private desktop provides isolation.
    let launch_api = if elevated {
        "CreateProcessAsUserW"
    } else {
        "CreateProcessW"
    };
    let created = if elevated {
        unsafe {
            CreateProcessAsUserW(
                token.0,
                application.as_ptr(),
                command.as_mut_ptr(),
                ptr::null(),
                ptr::null(),
                0,
                creation_flags,
                environment.as_ptr().cast(),
                ptr::null(),
                &mut startup,
                &mut info,
            )
        }
    } else {
        unsafe {
            CreateProcessW(
                application.as_ptr(),
                command.as_mut_ptr(),
                ptr::null(),
                ptr::null(),
                0,
                creation_flags,
                environment.as_ptr().cast(),
                ptr::null(),
                &mut startup,
                &mut info,
            )
        }
    };
    let launch_error = if created == 0 {
        unsafe { GetLastError() }
    } else {
        0
    };
    assert_ne!(
        created,
        0,
        "launch isolated native test child via {launch_api} (elevated_parent={elevated}): {}",
        io::Error::from_raw_os_error(launch_error as i32)
    );
    owned.process = info.process;
    owned.thread = info.thread;
    let mut actual_child_token = ptr::null_mut();
    assert_ne!(
        unsafe { OpenProcessToken(owned.process, 0x0008, &mut actual_child_token) },
        0,
        "open native test child token: {}",
        io::Error::last_os_error()
    );
    let actual_child_token = NativeHandleOwner(actual_child_token);
    native_validate_child_token(original_token.0, actual_child_token.0);
    assert_ne!(
        unsafe { AssignProcessToJobObject(owned.job, owned.process) },
        0,
        "assign native test child to owned Job: {}",
        io::Error::last_os_error()
    );
    owned.assigned = true;
    assert_ne!(
        unsafe { ResumeThread(owned.thread) },
        u32::MAX,
        "resume native test child: {}",
        io::Error::last_os_error()
    );

    let wait = unsafe { WaitForSingleObject(owned.process, NATIVE_E2E_TIMEOUT.as_millis() as u32) };
    if wait == 258 {
        assert!(
            owned.terminate_and_confirm_empty(),
            "native E2E timed out and its complete Job could not be confirmed empty"
        );
        panic!("native E2E child exceeded its bounded timeout");
    }
    assert_eq!(wait, 0, "wait for native E2E child");
    let mut exit_code = 1;
    assert_ne!(
        unsafe { GetExitCodeProcess(owned.process, &mut exit_code) },
        0,
        "read native E2E child exit code"
    );
    let empty_before_cleanup = owned.confirm_empty();
    if !empty_before_cleanup {
        if !owned.terminate_and_confirm_empty() {
            owned.retain_unknown();
            panic!("native E2E child left processes; its Job, desktop, and proof directory were retained");
        }
        panic!("native E2E child exited while its owned Job still contained processes");
    }
    assert_eq!(exit_code, 0, "native E2E child failed");
    assert_eq!(
        fs::read(proof).unwrap_or_default(),
        NATIVE_E2E_PROOF,
        "native E2E child did not finish the test body and write its proof"
    );
    owned.confirmed_empty = true;
    owned
        .desktop
        .take()
        .expect("isolated native test desktop was not retained through Job cleanup")
        .close()
        .unwrap_or_else(|error| panic!("close isolated native test desktop: {error}"));
}

#[test]
fn windows_python_receiver_app_backend_routes_two_sessions_and_status_after_disconnect_does_not_repost(
) {
    if let Some(proof) = std::env::var_os(NATIVE_E2E_PROOF_ENV) {
        let proof = PathBuf::from(proof);
        assert!(proof.is_absolute() && !proof.exists());
        assert_eq!(
            proof.file_name(),
            Some(std::ffi::OsStr::new("native-e2e-proof.txt")),
            "only the owned native launcher may enter the proof child path"
        );
        run_windows_python_receiver_e2e();
        fs::write(proof, NATIVE_E2E_PROOF).unwrap();
        return;
    }

    let fake_cli = validated_executable_env("AIGB_WINDOWS_FAKECLI_PATH");
    assert!(
        fake_cli
            .file_stem()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.eq_ignore_ascii_case("windows_fake_cli")),
        "AIGB_WINDOWS_FAKECLI_PATH must be the test-only windows_fake_cli example"
    );
    let python = validated_python_test_path();
    let proof_directory = tempfile::tempdir().unwrap();
    launch_native_e2e_child(&fake_cli, &python, proof_directory);
}

fn run_windows_python_receiver_e2e() {
    let temporary = tempfile::tempdir().unwrap();
    let root = temporary.path().canonicalize().unwrap();
    let app_data = root.join("synthetic-app-data");
    let workspace = root.join("synthetic-workspace");
    fs::create_dir_all(&app_data).unwrap();
    fs::create_dir_all(&workspace).unwrap();

    let paths = AccountPaths::isolated(
        root.join("synthetic-vault"),
        root.join("synthetic-system-home"),
    )
    .unwrap();
    fs::create_dir_all(&paths.system_home).unwrap();
    let login = Arc::new(DeferredLogin::default());
    let manager = codexu_core::accounts::AccountManager::with_components_and_spawner(
        paths,
        Arc::new(FixtureProtector),
        Arc::new(FixtureRuntime::default()),
        Some(Arc::new(FixtureOccupancyGate)),
        login.clone(),
    )
    .unwrap();
    let mut initial = crate::app_state::AppConfig::default();
    initial.codex_root = root.join("synthetic-codex-root");
    initial.cache_dir = root.join("synthetic-cache");
    initial.save(&app_data).unwrap();
    let profile_a = register_fixture_profile(&manager, &login, &app_data, "Synthetic A", "A");
    let profile_b = register_fixture_profile(&manager, &login, &app_data, "Synthetic B", "B");
    assert_eq!(profile_a.profile_id, 1);
    assert_eq!(profile_b.profile_id, 2);

    let mut preferences = WorkflowPreferences::default();
    preferences.profiles.insert(
        profile_a.profile_id,
        WorkflowPreference {
            participating: true,
            model: Some("windows-fake-model".into()),
            effort: Some("high".into()),
            revision: 1,
            dispatch_code: Some(profile_a.code.into()),
            ..Default::default()
        },
    );
    preferences.profiles.insert(
        profile_b.profile_id,
        WorkflowPreference {
            participating: true,
            model: Some("windows-fake-model".into()),
            effort: Some("low".into()),
            revision: 1,
            dispatch_code: Some(profile_b.code.into()),
            ..Default::default()
        },
    );
    super::super::cli_workflow::save_preferences(&app_data, &preferences).unwrap();
    let preferences_path = app_data.join("workflow-preferences-v1.json");
    let preferences_before = fs::read(&preferences_path).unwrap();
    let application = Arc::new(crate::app_state::AppState::new(app_data.clone()));

    let fake_cli = std::env::var_os("AIGB_WINDOWS_FAKECLI_PATH")
        .map(PathBuf::from)
        .expect("AIGB_WINDOWS_FAKECLI_PATH must point at the test-only fake CLI example")
        .canonicalize()
        .unwrap();
    assert!(fake_cli.is_file());
    SelectionStore::new(&app_data)
        .unwrap()
        .choose(&fake_cli, &NativeProbe)
        .unwrap();

    let python_selection =
        codexu_core::runtime_setup::python::PythonSelection::new(&app_data).unwrap();
    let mut python_candidates = codexu_core::runtime_setup::python::automatic_candidates();
    if let Some(path) = std::env::var_os("AIGB_WINDOWS_COMPANION_TEST_PYTHON") {
        python_candidates.insert(0, PathBuf::from(path));
    }
    let python = python_selection
        .for_companion(&python_candidates)
        .unwrap_or_else(|error| {
            panic!(
                "native Python needed for the actual one-shot client was unavailable: {}",
                error.code
            )
        });
    assert_eq!(
        python.path,
        PathBuf::from(std::env::var_os("AIGB_WINDOWS_COMPANION_TEST_PYTHON").unwrap())
            .canonicalize()
            .unwrap(),
        "native E2E must use the explicitly validated Python path from its clean child environment"
    );

    let private_root = prepare_private_root(&app_data.join("companion-bridge-v1")).unwrap();
    let current_app = CurrentAppBinding::inspect().unwrap();
    current_app.bind_confirmed(&private_root).unwrap();
    let launcher_source = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../..")
        .join("windows/companion/next-dispatch.py")
        .canonicalize()
        .unwrap();
    let synthetic_home = prepare_private_root(&root.join("synthetic-home")).unwrap();
    let install = synthetic_home
        .join(".codex")
        .join("skills")
        .join("multi-agent-management");
    assert!(
        !install.starts_with(&private_root),
        "synthetic installed client must remain outside the bridge root"
    );
    fs::create_dir_all(install.join("bin")).unwrap();
    fs::create_dir_all(install.join("config")).unwrap();
    let launcher = install.join("bin/next-dispatch.py");
    fs::copy(&launcher_source, &launcher).unwrap();
    fs::write(
        install.join("config/runtime-paths.json"),
        serde_json::to_vec(&json!({
            "schemaVersion":1,
            "python":python.path,
            "adapterABI":1,
            "bridgeRoot":private_root
        }))
        .unwrap(),
    )
    .unwrap();

    let gate = ManagedProxyGate::new(root.join("synthetic-dispatch-registry"), &manager).unwrap();
    let domains = OwnedProcessDomains::new();
    let token_a = "synthetic-token-a";
    let token_b = "synthetic-token-b";
    let mut synthetic_a = SyntheticHub::start(
        &root,
        &python,
        &workspace,
        &profile_a.home,
        &profile_a.alias,
        token_a,
        true,
        domains.clone(),
    );
    let mut synthetic_b = SyntheticHub::start(
        &root,
        &python,
        &workspace,
        &profile_b.home,
        &profile_b.alias,
        token_b,
        false,
        domains.clone(),
    );
    let mut hub = HubOwner::new();
    let hub_state = hub.get();
    let mut session_ids = BTreeMap::new();
    for (profile, token, service, active) in [
        (&profile_a, token_a, &mut synthetic_a, false),
        (&profile_b, token_b, &mut synthetic_b, true),
    ] {
        let files = Arc::new(HubFiles::open(&app_data, &workspace, &profile.managed_id).unwrap());
        let session_id = hub_state
            .insert_session_for_test(
                TestSessionInput {
                    profile_id: profile.profile_id,
                    dispatch_code: profile.code.into(),
                    managed_id: profile.managed_id.clone(),
                    alias: profile.alias.clone(),
                    identity: profile.identity.clone(),
                    home: profile.home.clone(),
                    workspace: workspace.clone(),
                    files,
                    endpoint: service.endpoint,
                    token: token.into(),
                    process: service
                        .owner
                        .take()
                        .map(|owner| Box::new(owner) as Box<dyn OwnedProcess>)
                        .unwrap(),
                },
                active,
            )
            .unwrap();
        session_ids.insert(profile.profile_id, session_id);
    }
    {
        let inner = hub_state.inner.lock().unwrap_or_else(|e| e.into_inner());
        assert_eq!(
            inner.active_session_id.as_deref(),
            session_ids.get(&profile_b.profile_id).map(String::as_str),
            "test precondition requires UI selection B"
        );
        assert_ne!(
            inner.active_session_id.as_deref(),
            session_ids.get(&profile_a.profile_id).map(String::as_str),
            "profile A must remain a non-active Session"
        );
    }
    assert!(synthetic_a.owner_resource.upgrade().is_some());
    assert!(synthetic_b.owner_resource.upgrade().is_some());

    let backend = app_backend(
        application.clone(),
        manager.clone(),
        gate.clone(),
        hub_state,
        domains.clone(),
        &python,
    );
    let bridge = Arc::new(Bridge::new(private_root.clone(), backend.clone()).unwrap());
    let mut receiver = ReceiverOwner::start(
        private_root.clone(),
        PinnedExecutable {
            path: python.path.clone(),
            guard: python.guard.try_clone().unwrap(),
        },
        bridge.clone(),
    );

    let preflight = |name: &str, request: &str, selection: (&str, String)| {
        client_process(
            &root,
            &launcher,
            &python,
            &profile_a.home,
            &workspace,
            domains.clone(),
            name,
            request,
            "preflight",
            Some(selection),
            &[],
            "",
        )
        .wait_output()
    };
    let code_a = preflight("code-a", &"1".repeat(64), ("--dispatch-code", "A".into()));
    let numeric_a = preflight("numeric-a", &"2".repeat(64), ("--profile-id", "1".into()));
    let code_b = preflight("code-b", &"3".repeat(64), ("--dispatch-code", "B".into()));
    let numeric_b = preflight("numeric-b", &"4".repeat(64), ("--profile-id", "2".into()));
    assert_eq!(
        json_scope(&code_a),
        json_scope(&numeric_a),
        "dispatch code A did not resolve to legacy profile 1"
    );
    assert_eq!(
        json_scope(&code_b),
        json_scope(&numeric_b),
        "dispatch code B did not resolve to legacy profile 2"
    );
    assert_ne!(
        json_scope(&code_a),
        json_scope(&code_b),
        "the two synthetic Sessions were not isolated"
    );
    assert_eq!(
        fs::read(&preferences_path).unwrap(),
        preferences_before,
        "read-only selectors mutated stored dispatch codes"
    );
    {
        let inner = hub_state.inner.lock().unwrap_or_else(|e| e.into_inner());
        assert_eq!(
            inner.active_session_id.as_deref(),
            session_ids.get(&profile_b.profile_id).map(String::as_str),
            "Python selector A changed the UI's active Session"
        );
    }

    let prompt = "Synthetic approval-gated draft. No model execution.";
    let reserve = client_process(
        &root,
        &launcher,
        &python,
        &profile_a.home,
        &workspace,
        domains.clone(),
        "reserve-legacy-a",
        &"5".repeat(64),
        "reserve",
        Some(("--profile-id", "1".into())),
        &[],
        prompt,
    )
    .wait_output();
    assert_eq!(
        reserve["result"]["state"], "reserved",
        "legacy numeric reserve failed: {reserve}"
    );
    let lease = reserve["result"]["leaseId"].as_str().unwrap().to_owned();
    let run_id = "6".repeat(64);
    let mut disconnected = client_process(
        &root,
        &launcher,
        &python,
        &profile_a.home,
        &workspace,
        domains.clone(),
        "disconnect-after-create-post",
        &run_id,
        "run",
        Some(("--profile-id", "1".into())),
        &[("--lease-id", lease)],
        prompt,
    );
    synthetic_a.wait_for_post(
        &mut disconnected,
        hub_state,
        session_ids
            .get(&profile_a.profile_id)
            .expect("profile A Hub session missing"),
    );
    disconnected.cancel_and_confirm();
    synthetic_a.release_post_response();
    synthetic_a.wait_for_lookups(1);
    let journal_path = private_root.join("companion-requests-v1.json");
    wait_for_created_journal(&journal_path, &run_id, Duration::from_secs(15));
    rewrite_journal_as_legacy_v1(&journal_path, &run_id);
    assert!(
        should_block_exit(hub_state),
        "the created synthetic task lost its owned Session fence"
    );
    assert!(
        gate.reserve_terminal(&profile_a.identity).is_err(),
        "disconnected create released the profile A activity guard"
    );

    // A normal Receiver stop followed by a fresh Bridge/Receiver models a
    // cancelled/retried local runtime. The durable operation is looked up;
    // neither the client nor the Receiver may issue a second create POST.
    receiver.stop_confirmed();
    drop(bridge);
    drop(backend);
    let backend_after_restart = app_backend(
        application,
        manager,
        gate.clone(),
        hub_state,
        domains.clone(),
        &python,
    );
    let bridge_after_restart =
        Arc::new(Bridge::new(private_root.clone(), backend_after_restart.clone()).unwrap());
    receiver = ReceiverOwner::start(
        private_root,
        PinnedExecutable {
            path: python.path.clone(),
            guard: python.guard.try_clone().unwrap(),
        },
        bridge_after_restart.clone(),
    );
    let status = client_process(
        &root,
        &launcher,
        &python,
        &profile_a.home,
        &workspace,
        domains.clone(),
        "status-after-restart",
        &"7".repeat(64),
        "status",
        None,
        &[("--operation-id", run_id.clone())],
        "",
    )
    .wait_output();
    assert_eq!(
        status["result"]["state"], "created",
        "legacy numeric claim/journal did not read back its created receipt: {status}"
    );
    {
        let inner = hub_state.inner.lock().unwrap_or_else(|e| e.into_inner());
        assert_eq!(
            inner.active_session_id.as_deref(),
            session_ids.get(&profile_b.profile_id).map(String::as_str),
            "status recovery changed the UI's active Session"
        );
    }
    synthetic_a.wait_for_lookups(2);
    let records_a = synthetic_a.records();
    assert_eq!(
        records_a.iter().filter(|v| v["kind"] == "create").count(),
        1,
        "restart/status repeated the create POST: {records_a:?}"
    );
    assert_eq!(
        records_a.iter().filter(|v| v["kind"] == "approve").count(),
        0,
        "a disconnected client caused an approval POST: {records_a:?}"
    );
    assert!(
        synthetic_b.records().is_empty(),
        "profile A call reached the synthetic B Hub"
    );
    let legacy_after_status: Value =
        serde_json::from_slice(&fs::read(&journal_path).unwrap()).unwrap();
    assert!(
        legacy_after_status["entries"][run_id.as_str()]["binding"]
            .get("windowsExecution")
            .is_none(),
        "status rewrote the legacy journal shape"
    );

    receiver.stop_confirmed();
    drop(bridge_after_restart);
    drop(backend_after_restart);
    hub.stop_confirmed();
    assert!(
        gate.reserve_terminal(&profile_a.identity).is_ok(),
        "profile A activity guard was not released after the owned Hub Job emptied"
    );
    // Each domain receipt pins its owner's resource until confirmed cleanup;
    // client receipts are checked individually in ClientProcess as they exit.
    assert!(
        synthetic_a.owner_resource.upgrade().is_none()
            && synthetic_b.owner_resource.upgrade().is_none(),
        "test OwnedConsole registrations remain after confirmed cleanup"
    );
}
