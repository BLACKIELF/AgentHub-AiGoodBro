//! Native quit confirmation. An explicit force confirmation cannot be vetoed
//! later by an unavailable registry, slow cleanup, or an in-flight login.
use crate::{
    app_state::{AppState, ResolvedLanguage},
    commands,
    native_services::NativeServices,
};
use std::{
    sync::{
        atomic::{AtomicU8, Ordering},
        Arc,
    },
    time::Duration,
};
use tauri::{AppHandle, Manager};
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons, MessageDialogKind};

#[derive(Default)]
pub struct QuitState(AtomicU8);
impl QuitState {
    fn begin(&self) -> bool {
        self.0
            .compare_exchange(0, 1, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
    }
    fn answer(&self, confirmed: bool) -> bool {
        self.0
            .compare_exchange(
                1,
                if confirmed { 2 } else { 0 },
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_ok()
            && confirmed
    }
    pub fn confirmed(&self) -> bool {
        self.0.load(Ordering::Acquire) == 2
    }
}

pub fn ask(app: &AppHandle) {
    if !app.state::<QuitState>().begin() {
        return;
    }
    let zh = app
        .state::<Arc<AppState>>()
        .config
        .try_read()
        .map(|c| c.language.resolved(ResolvedLanguage::En) == ResolvedLanguage::ZhHans)
        .unwrap_or(false);
    let (title, body, force, cancel) = if zh {
        (
            "退出 AiGoodBro？",
            "反代或由 AiGoodBro 打开的任务仍在运行。强制退出会中断当前回复，未保存的内容可能丢失。",
            "强制退出",
            "取消",
        )
    } else {
        ("Quit AiGoodBro?", "The proxy or a task opened by AiGoodBro is still running. Force Quit interrupts current replies and may lose unsaved work.", "Force Quit", "Cancel")
    };
    let handle = app.clone();
    app.dialog()
        .message(body)
        .title(title)
        .kind(MessageDialogKind::Warning)
        .buttons(MessageDialogButtons::OkCancelCustom(
            force.into(),
            cancel.into(),
        ))
        .show(move |confirmed| {
            if !handle.state::<QuitState>().answer(confirmed) {
                return;
            }
            handle
                .state::<commands::cli_workflow::WorkflowState>()
                .begin_force_quit();
            handle
                .state::<commands::task_hub::HubState>()
                .begin_force_quit();
            handle.state::<NativeServices>().seal_accounts_for_exit();
            crate::compact_projection::shutdown(&handle);
            // Arm the independent exit deadline before any cleanup is attempted.
            // Only this process exits; no PID/name-based termination is used.
            let watchdog = std::thread::Builder::new()
                .name("agb-confirmed-exit".into())
                .spawn(|| {
                    std::thread::sleep(Duration::from_secs(5));
                    std::process::exit(0);
                });
            // If the OS cannot create even the independent watchdog, do not
            // enter cleanup that may wait forever. Confirmation already grants
            // process exit and owned Windows Job handles close with this process.
            if watchdog.is_err() {
                std::process::exit(0);
            }
            let cleanup_handle = handle.clone();
            let spawned = std::thread::Builder::new()
                .name("agb-exit-cleanup".into())
                .spawn(move || {
                    crate::compact_ui::shutdown(&cleanup_handle);
                    commands::task_hub::force_stop_owned(
                        &cleanup_handle.state::<commands::task_hub::HubState>(),
                    );
                    cleanup_handle.state::<NativeServices>().force_stop_owned();
                    commands::cli_workflow::force_stop_owned(
                        &cleanup_handle.state::<commands::cli_workflow::WorkflowState>(),
                    );
                    cleanup_handle.exit(0);
                });
            if spawned.is_err() {
                handle.exit(0);
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cancellation_preserves_running_work_and_can_prompt_again() {
        let state = QuitState::default();
        assert!(state.begin());
        assert!(!state.begin());
        assert!(!state.answer(false));
        assert!(!state.confirmed());
        assert!(state.begin());
        assert!(state.answer(true));
        assert!(state.confirmed());
        assert!(!state.begin());
        assert!(!state.answer(false));
        assert!(state.confirmed());
    }
    #[test]
    fn stray_confirmation_without_user_quit_does_not_authorize_exit() {
        let state = QuitState::default();
        assert!(!state.answer(true));
        assert!(!state.confirmed());
    }
}
