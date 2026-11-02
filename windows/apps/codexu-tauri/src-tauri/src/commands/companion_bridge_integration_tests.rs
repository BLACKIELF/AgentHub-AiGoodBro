//! Windows-only, synthetic end-to-end coverage for the actual Python client,
//! native Receiver, Tauri AppBackend, and owned Hub sessions. All accounts,
//! Hub responses, and app-server evidence are local fixtures; no model or
//! external account is contacted.
use super::*;
use crate::commands::cli_workflow::console::LaunchWindow;
use codexu_core::{
    accounts::{
        hub_snapshot::HubFiles, AccountError, AccountIdentity, AccountLoginSpawner, AccountPaths,
        AccountResult, AccountRuntime, LoginAuthorization, SecretProtector, VerifiedCredential,
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
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    ffi::c_void,
    fs::{self, File, OpenOptions},
    io,
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

const CLIENT_WRAPPER: &str = "import io,json,runpy,sys\nc=json.load(open(sys.argv[1],encoding='utf-8'))\nsys.argv=c['argv']\nsys.stdin=io.TextIOWrapper(io.BytesIO(c['stdin'].encode('utf-8')))\nrunpy.run_path(sys.argv[0],run_name='__main__')\n";
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
Path(ready).write_text(json.dumps({'port':server.server_port}), encoding='ascii')
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
        wait_for_file(&ready, Duration::from_secs(10));
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
    fn wait_for_post(&self) {
        wait_for_file(&self.post_seen, Duration::from_secs(20));
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

fn wait_for_file(path: &Path, duration: Duration) {
    let deadline = Instant::now() + duration;
    while Instant::now() < deadline {
        if path.is_file() {
            return;
        }
        thread::sleep(Duration::from_millis(10));
    }
    panic!("synthetic test fixture file did not appear");
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
    output: Option<File>,
}
impl ClientProcess {
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
    fs::write(
        &config_path,
        serde_json::to_vec(&json!({"argv":argv,"stdin":stdin})).unwrap(),
    )
    .unwrap();
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
    fn CreateProcessWithTokenW(
        token: NativeHandle,
        logon: u32,
        application: *const u16,
        command: *mut u16,
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
    proof_directory: Option<tempfile::TempDir>,
}

static UNCONFIRMED_NATIVE_TEST_JOBS: OnceLock<Mutex<Vec<[usize; 3]>>> = OnceLock::new();

fn retain_native_test_job(job: NativeHandle, process: NativeHandle, thread: NativeHandle) {
    UNCONFIRMED_NATIVE_TEST_JOBS
        .get_or_init(|| Mutex::new(Vec::new()))
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .push([job as usize, process as usize, thread as usize]);
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
        retain_native_test_job(self.job, self.process, self.thread);
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
    let creation_flags = 0x0000_0004 | 0x0000_0400 | 0x0800_0000; // suspended, Unicode environment, no window
    let launch_api = if elevated {
        "CreateProcessWithTokenW"
    } else {
        "CreateProcessW"
    };
    let created = if elevated {
        unsafe {
            CreateProcessWithTokenW(
                token.0,
                0,
                application.as_ptr(),
                command.as_mut_ptr(),
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
            panic!("native E2E child left processes; its Job and proof directory were retained");
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
        None,
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
    let install = private_root.join("client");
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
    synthetic_a.wait_for_post();
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
