//! A fixed local Codex task. Its output is advice until independent checks pass.
use super::*;
use codexu_core::local_cli::{
    dependency as setup,
    launch::{self, Edition, Environment},
    LocalCliKind,
};
use codexu_core::token_monitor::{self, VerifiedNodeRuntime};
use std::{fs::File, time::Instant};
use tauri::{AppHandle, Emitter, Manager};

#[derive(Clone, serde::Serialize)]
pub struct DependencyTaskDto {
    task_id: String,
    platform: String,
    phase: &'static str,
    prompt: String,
}
#[derive(Clone, serde::Serialize)]
pub struct DependencyStatusDto {
    task_id: String,
    platform: String,
    phase: &'static str,
    verification_state: &'static str,
    version: Option<String>,
    reason_code: Option<&'static str>,
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Step {
    Prepared,
    Codex,
    Registry,
    Version,
    Busy,
    Done,
}
struct Task {
    prepared: setup::PreparedTask,
    dto: DependencyStatusDto,
    step: Step,
    epoch: u64,
    process: Option<console::OwnedConsole>,
    activity: Option<codexu_core::managed_proxy::ManagedActivityGuard>,
    node: Option<Arc<VerifiedNodeRuntime>>,
    runtime: Option<Arc<setup::VerifiedRuntime>>,
    output: Option<File>,
    started: Instant,
}
impl Task {
    fn active(&self) -> bool {
        self.process.is_some() || self.step == Step::Busy
    }
    fn fail(&mut self, code: &'static str) {
        self.dto.phase = "failed";
        self.dto.verification_state = "failed";
        self.dto.reason_code = Some(code);
        self.step = Step::Done;
        self.activity = None;
    }
}
#[derive(Default)]
pub(super) struct DependencyState {
    tasks: Mutex<BTreeMap<String, Task>>,
    node: Mutex<Option<Arc<VerifiedNodeRuntime>>>,
}
pub(super) async fn trusted_node(
    app: &AppHandle,
    workflow: &WorkflowState,
) -> Result<Arc<VerifiedNodeRuntime>, String> {
    let mut cached = workflow.dependency.node.lock().await;
    if let Some(node) = cached.as_ref() {
        return Ok(node.clone());
    }
    let root = app
        .path()
        .resource_dir()
        .map_err(|_| "statistics_resources_unavailable")?
        .join("token-monitor");
    let node =
        tauri::async_runtime::spawn_blocking(move || token_monitor::verify_node_runtime(&root))
            .await
            .map_err(|_| "statistics_resources_unavailable")?
            .map_err(|_| "statistics_resources_unavailable")?;
    let node = Arc::new(node);
    *cached = Some(node.clone());
    Ok(node)
}
fn code<T>(r: launch::Result<T>) -> Result<T, String> {
    r.map_err(|e| e.code.to_owned())
}
fn checked_id(id: &str) -> Result<(), String> {
    if setup::valid_id(id) {
        Ok(())
    } else {
        Err("dependency_task_unavailable".into())
    }
}

#[tauri::command]
pub async fn prepare_local_cli_dependency(
    state: State<'_, Arc<AppState>>,
    workflow: State<'_, WorkflowState>,
    platform: String,
    edition: Option<Edition>,
) -> Result<DependencyTaskDto, String> {
    if workflow.quitting.load(Ordering::Acquire) {
        return Err("launch_cancelled".into());
    }
    let kind = LocalCliKind::parse(&platform).ok_or("platform_not_supported")?;
    let mut tasks = workflow.dependency.tasks.lock().await;
    if tasks
        .values()
        .any(|t| t.prepared.platform == kind && t.active())
    {
        return Err("already_running".into());
    }
    if tasks.len() >= 16 {
        let old = tasks
            .iter()
            .find(|(_, t)| !t.active() && t.step == Step::Done)
            .map(|(id, _)| id.clone());
        if let Some(id) = old {
            tasks.remove(&id);
        } else {
            return Err("session_limit".into());
        }
    }
    let prepared = code(setup::prepare(&state.app_data_dir, kind, edition))?;
    let result = DependencyTaskDto {
        task_id: prepared.id.clone(),
        platform: kind.id().into(),
        phase: "prepared",
        prompt: prepared.prompt.clone(),
    };
    let dto = DependencyStatusDto {
        task_id: prepared.id.clone(),
        platform: kind.id().into(),
        phase: "prepared",
        verification_state: "unknown",
        version: None,
        reason_code: None,
    };
    tasks.insert(
        prepared.id.clone(),
        Task {
            prepared,
            dto,
            step: Step::Prepared,
            epoch: 0,
            process: None,
            activity: None,
            node: None,
            runtime: None,
            output: None,
            started: Instant::now(),
        },
    );
    Ok(result)
}

#[tauri::command]
pub async fn begin_local_cli_dependency(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    workflow: State<'_, WorkflowState>,
    services: State<'_, crate::native_services::NativeServices>,
    task_id: String,
) -> Result<DependencyStatusDto, String> {
    checked_id(&task_id)?;
    // Reuse the existing Windows native Codex resolver and current login. This
    // task never enters the account dispatch/quota/model-selection workflow.
    let (executable, guard) = native_executable(&state.app_data_dir)
        .await
        .map_err(|_| "cli_unavailable")?;
    let mut tasks = workflow.dependency.tasks.lock().await;
    if workflow.quitting.load(Ordering::Acquire) {
        return Err("launch_cancelled".into());
    }
    if tasks.values().any(|t| t.active()) {
        return Err("already_running".into());
    }
    let task = tasks
        .get_mut(&task_id)
        .ok_or("dependency_task_unavailable")?;
    if task.step != Step::Prepared {
        return Err("dependency_task_finished".into());
    }
    let identity = launch::activity_key(LocalCliKind::Codex, &task.prepared.directory);
    let activity = services
        .gate
        .as_ref()
        .map_err(|e| (*e).to_owned())?
        .reserve_terminal(&identity)
        .map_err(|e| e.code().to_owned())?;
    let process = console::OwnedConsole::start_registered(
        &executable,
        &task.prepared.directory,
        &[task.prepared.prompt.clone()],
        guard,
        &Environment::own_codex(),
        "AiGoodBro - dependency preparation",
        Some(services.owned_domains.clone()),
        None,
        None,
    )
    .map_err(|_| "launch_failed")?;
    task.process = Some(process);
    task.activity = Some(activity);
    task.step = Step::Codex;
    task.started = Instant::now();
    task.dto.phase = "running";
    let dto = task.dto.clone();
    let _ = app.emit("local-cli-dependency:changed", ());
    Ok(dto)
}

enum Work {
    Start {
        directory: PathBuf,
        kind: LocalCliKind,
    },
    Registry {
        directory: PathBuf,
        kind: LocalCliKind,
        node: Arc<VerifiedNodeRuntime>,
        output: File,
    },
    Version {
        runtime: Arc<setup::VerifiedRuntime>,
        output: File,
    },
}
enum ResultWork {
    Registry {
        node: Arc<VerifiedNodeRuntime>,
        script: PathBuf,
        script_guard: File,
        output: File,
        environment: Environment,
    },
    Version {
        runtime: Arc<setup::VerifiedRuntime>,
        output: File,
        environment: Environment,
    },
    Ready {
        runtime: Arc<setup::VerifiedRuntime>,
    },
    NativeReady,
}

#[tauri::command]
pub async fn get_local_cli_dependency(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    workflow: State<'_, WorkflowState>,
    services: State<'_, crate::native_services::NativeServices>,
    task_id: String,
) -> Result<DependencyStatusDto, String> {
    checked_id(&task_id)?;
    let (work, epoch) = {
        let mut tasks = workflow.dependency.tasks.lock().await;
        let task = tasks
            .get_mut(&task_id)
            .ok_or("dependency_task_unavailable")?;
        if !matches!(task.step, Step::Codex | Step::Registry | Step::Version) {
            return Ok(task.dto.clone());
        }
        let process = task.process.as_mut().ok_or("dependency_task_unavailable")?;
        if task.step != Step::Codex && task.started.elapsed() > std::time::Duration::from_secs(300)
        {
            if process.stop().is_err() {
                task.dto.reason_code = Some("cleanup_unconfirmed");
                return Ok(task.dto.clone());
            }
            task.process = None;
            task.fail("dependency_verification_timeout");
            return Ok(task.dto.clone());
        }
        if !process.has_exited().map_err(|_| "process_state_unknown")? {
            return Ok(task.dto.clone());
        }
        let success = process
            .exit_success()
            .map_err(|_| "process_state_unknown")?;
        // Both the root and the whole exact Job are positively empty here.
        task.process = None;
        if !success && task.step != Step::Registry {
            task.fail("dependency_task_failed");
            return Ok(task.dto.clone());
        }
        let work = match task.step {
            Step::Codex => Work::Start {
                directory: task.prepared.directory.clone(),
                kind: task.prepared.platform,
            },
            Step::Registry => Work::Registry {
                directory: task.prepared.directory.clone(),
                kind: task.prepared.platform,
                node: task.node.take().ok_or("dependency_task_unavailable")?,
                output: task.output.take().ok_or("dependency_task_unavailable")?,
            },
            Step::Version => Work::Version {
                runtime: task.runtime.take().ok_or("dependency_task_unavailable")?,
                output: task.output.take().ok_or("dependency_task_unavailable")?,
            },
            _ => unreachable!(),
        };
        task.step = Step::Busy;
        task.dto.verification_state = "checking";
        (work, task.epoch)
    };
    let resources = app.path().resource_dir().map(|r| r.join("token-monitor"));
    let semver = resources
        .as_ref()
        .ok()
        .map(|r| r.join("engine/vendor/node_modules/semver"));
    let app_data = state.app_data_dir.clone();
    let prepared = tauri::async_runtime::spawn_blocking(move || -> launch::Result<ResultWork> {
        match work {
            Work::Start { directory, kind } => {
                if kind == LocalCliKind::ClaudeCode || kind.is_desktop_application() {
                    launch::discover(kind, &codexu_core::local_cli::PlatformDirectories::detect())?;
                    return Ok(ResultWork::NativeReady);
                }
                let resources = resources.map_err(|_| launch::Error {
                    code: "statistics_resources_unavailable",
                })?;
                let node =
                    Arc::new(token_monitor::verify_node_runtime(&resources).map_err(|_| {
                        launch::Error {
                            code: "statistics_resources_unavailable",
                        }
                    })?);
                let (script, script_guard) = setup::verifier_file(&directory)?;
                let output = setup::capture_file(&directory, "verification.json")?;
                let environment =
                    Environment::dependency_probe(&directory.join("verification-home"))?;
                Ok(ResultWork::Registry {
                    node,
                    script,
                    script_guard,
                    output,
                    environment,
                })
            }
            Work::Registry {
                directory,
                kind,
                node,
                mut output,
            } => {
                let report = setup::captured(&mut output)?;
                let runtime =
                    Arc::new(setup::accept_report(kind, &report, node)?.stage(&app_data)?);
                let output = setup::capture_file(&directory, "version.txt")?;
                let environment = Environment::dependency_probe(&directory.join("version-home"))?;
                Ok(ResultWork::Version {
                    runtime,
                    output,
                    environment,
                })
            }
            Work::Version {
                runtime,
                mut output,
            } => {
                if !setup::version_matches(runtime.version(), &setup::captured(&mut output)?) {
                    return Err(launch::Error {
                        code: "dependency_version_mismatch",
                    });
                }
                Ok(ResultWork::Ready { runtime })
            }
        }
    })
    .await
    .unwrap_or_else(|_| {
        Err(launch::Error {
            code: "dependency_verification_failed",
        })
    });
    let mut tasks = workflow.dependency.tasks.lock().await;
    let task = tasks
        .get_mut(&task_id)
        .ok_or("dependency_task_unavailable")?;
    if task.epoch != epoch || task.step != Step::Busy || workflow.quitting.load(Ordering::Acquire) {
        return Ok(task.dto.clone());
    }
    let result = (|| -> Result<(), &'static str> {
        match prepared.map_err(|e| e.code)? {
            ResultWork::Registry {
                node,
                script,
                script_guard,
                output,
                environment,
            } => {
                let semver = semver.ok_or("statistics_resources_unavailable")?;
                let args = vec![
                    script.to_string_lossy().into(),
                    task.prepared
                        .directory
                        .join("candidate.json")
                        .to_string_lossy()
                        .into(),
                    semver.to_string_lossy().into(),
                ];
                let held: Arc<dyn Send + Sync> = Arc::new((node.clone(), script_guard));
                let process = console::OwnedConsole::start_registered(
                    node.path(),
                    &task.prepared.directory,
                    &args,
                    console::lock_executable(node.path())
                        .map_err(|_| "package_file_unavailable")?,
                    &environment,
                    "AiGoodBro - dependency verification",
                    Some(services.owned_domains.clone()),
                    Some(held),
                    Some(&output),
                )
                .map_err(|_| "dependency_verification_failed")?;
                task.process = Some(process);
                task.node = Some(node);
                task.output = Some(output);
                task.step = Step::Registry;
            }
            ResultWork::Version {
                runtime,
                output,
                environment,
            } => {
                let mut args = runtime.prefix().to_vec();
                args.push("--version".into());
                let process = console::OwnedConsole::start_registered(
                    runtime.executable(),
                    &task.prepared.directory,
                    &args,
                    runtime.executable_guard().map_err(|e| e.code)?,
                    &environment,
                    "AiGoodBro - version verification",
                    Some(services.owned_domains.clone()),
                    Some(runtime.clone()),
                    Some(&output),
                )
                .map_err(|_| "dependency_verification_failed")?;
                task.process = Some(process);
                task.runtime = Some(runtime);
                task.output = Some(output);
                task.step = Step::Version;
            }
            ResultWork::Ready { runtime } => {
                runtime.persist(&state.app_data_dir).map_err(|e| e.code)?;
                task.dto.version = Some(runtime.version().into());
                task.dto.phase = "verified";
                task.dto.verification_state = "verified";
                task.step = Step::Done;
                task.activity = None;
            }
            ResultWork::NativeReady => {
                task.dto.phase = "verified";
                task.dto.verification_state = "verified";
                task.step = Step::Done;
                task.activity = None;
            }
        }
        Ok(())
    })();
    if let Err(code) = result {
        task.fail(code);
    }
    task.started = Instant::now();
    let dto = task.dto.clone();
    let _ = app.emit("local-cli-dependency:changed", ());
    Ok(dto)
}

#[tauri::command]
pub async fn cancel_local_cli_dependency(
    app: AppHandle,
    workflow: State<'_, WorkflowState>,
    task_id: String,
) -> Result<DependencyStatusDto, String> {
    checked_id(&task_id)?;
    let mut tasks = workflow.dependency.tasks.lock().await;
    let task = tasks
        .get_mut(&task_id)
        .ok_or("dependency_task_unavailable")?;
    if task.step == Step::Done {
        return Ok(task.dto.clone());
    }
    task.epoch = task.epoch.saturating_add(1);
    if let Some(process) = &mut task.process {
        process.stop().map_err(|_| "cleanup_unconfirmed")?;
    }
    task.process = None;
    task.activity = None;
    task.runtime = None;
    task.node = None;
    task.step = Step::Done;
    task.dto.phase = "cancelled";
    task.dto.verification_state = "unknown";
    task.dto.reason_code = None;
    let dto = task.dto.clone();
    let _ = app.emit("local-cli-dependency:changed", ());
    Ok(dto)
}
pub(super) fn blocks_exit(workflow: &WorkflowState) -> bool {
    workflow
        .dependency
        .tasks
        .try_lock()
        .map(|tasks| tasks.values().any(Task::active))
        .unwrap_or(true)
}
pub(super) fn force_stop(workflow: &WorkflowState) {
    let Ok(mut tasks) = workflow.dependency.tasks.try_lock() else {
        return;
    };
    for task in tasks.values_mut() {
        task.epoch = task.epoch.saturating_add(1);
        if task.process.as_mut().is_some_and(|p| p.stop().is_err()) {
            continue;
        }
        task.process = None;
        task.activity = None;
        task.step = Step::Done;
        task.dto.phase = "cancelled";
    }
}
