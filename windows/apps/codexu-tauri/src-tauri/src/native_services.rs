//! Windows-only composition. Failure in a new service must not disable existing
//! usage, profile or settings views; no fallback account/lease is synthesized.
use crate::commands::{
    account_lifecycle::{ClaudeSubscriptionState, ManagedAccountState},
    local_proxy::{LocalProxyDesktopState, LocalProxyState},
    notifications::NotificationState,
    token_monitor::TokenMonitorAppState,
};
use codexu_core::{
    accounts::{claude::ClaudeSubscriptionManager, AccountManager},
    managed_proxy::{ManagedActivityGuard, ManagedProxyGate, ManagedProxySecrets},
    notifications::{NotificationMonitor, NotificationService},
    proxy::{LocalProxyService, ProxyDesktopConnector, ProxyDesktopMonitor, ProxyRecoveryMonitor},
    token_monitor::TokenMonitorService,
};
use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};
use tauri::{App, Emitter, Manager};

pub struct NativeServices {
    pub gate: Result<Arc<ManagedProxyGate>, &'static str>,
    accounts: Result<Arc<AccountManager>, &'static str>,
    claude: Result<Arc<ClaudeSubscriptionManager>, &'static str>,
    proxy: Result<Arc<LocalProxyService>, &'static str>,
    desktop: Result<Arc<ProxyDesktopConnector>, &'static str>,
    statistics: Result<Arc<TokenMonitorService>, &'static str>,
    notifications: Result<Arc<NotificationService>, &'static str>,
    monitor: Mutex<Option<ProxyRecoveryMonitor>>,
    desktop_monitor: Mutex<Option<ProxyDesktopMonitor>>,
    notification_monitor: Mutex<Option<NotificationMonitor>>,
}
impl NativeServices {
    pub fn statistics_accounts(&self) -> Result<Arc<AccountManager>, String> {
        self.accounts.as_ref().cloned().map_err(|e| (*e).to_owned())
    }
    pub fn reserve_terminal(&self, auth: &[u8]) -> Result<ManagedActivityGuard, String> {
        let identity = codexu_core::accounts::AccountIdentity::from_auth(auth)
            .map_err(|e| e.code.to_owned())?;
        self.gate
            .as_ref()
            .map_err(|e| e.to_string())?
            .reserve_terminal(&identity.identity_hash())
            .map_err(|e| e.code().to_owned())
    }
    pub fn proxy_blocks_normal_exit(&self) -> bool {
        self.accounts
            .as_ref()
            .is_ok_and(|service| service.has_inflight_operation())
            || self
                .claude
                .as_ref()
                .is_ok_and(|service| service.has_inflight_operation())
            || self
                .proxy
                .as_ref()
                .is_ok_and(|service| service.requires_exit_confirmation())
            || self
                .desktop
                .as_ref()
                .is_ok_and(|service| service.requires_exit_confirmation())
    }
    /// Synchronous no-I/O fence applied in the confirmation callback itself.
    pub fn seal_accounts_for_exit(&self) {
        if let Ok(accounts) = &self.accounts {
            accounts.cancel_inflight_for_exit();
        }
        if let Ok(claude) = &self.claude {
            claude.cancel_inflight_for_exit();
        }
        if let Ok(notifications) = &self.notifications {
            notifications.cancel_inflight_for_exit();
        }
    }
    pub fn force_stop_owned(&self) {
        self.seal_accounts_for_exit();
        self.cancel_monitor();
        if let Ok(desktop) = &self.desktop {
            let _ = desktop.force_stop_owned();
        }
        if let Ok(proxy) = &self.proxy {
            let _ = proxy.force_stop_owned();
        }
        self.stop_passive_services();
    }
    /// Background statistics do not count as an interactive task. A normal
    /// exit still closes their owned process tree without an extra prompt.
    pub fn stop_passive_services(&self) {
        if let Ok(notifications) = &self.notifications {
            notifications.cancel_inflight_for_exit();
        }
        if let Ok(monitor) = self.notification_monitor.try_lock() {
            if let Some(monitor) = monitor.as_ref() {
                monitor.cancel();
            }
        }
        if let Ok(statistics) = &self.statistics {
            statistics.cancel_for_exit();
        }
    }
    pub fn cancel_monitor(&self) {
        if let Ok(monitor) = self.monitor.try_lock() {
            if let Some(monitor) = monitor.as_ref() {
                monitor.cancel();
            }
        }
        if let Ok(monitor) = self.desktop_monitor.try_lock() {
            if let Some(monitor) = monitor.as_ref() {
                monitor.cancel();
            }
        }
    }
}
fn make_proxy(
    root: &Path,
    resources: &Path,
    manager: &Arc<AccountManager>,
    gate: Arc<ManagedProxyGate>,
) -> Result<Arc<LocalProxyService>, &'static str> {
    let path = resources.join("proxy");
    let models_path = path.join("models.json");
    let meta = std::fs::symlink_metadata(&models_path).map_err(|_| "proxy_resources_missing")?;
    if !meta.is_file() || meta.file_type().is_symlink() || meta.len() > 32 * 1024 {
        return Err("proxy_resources_invalid");
    }
    let models: Vec<String> = serde_json::from_slice(
        &std::fs::read(&models_path).map_err(|_| "proxy_resources_missing")?,
    )
    .map_err(|_| "proxy_resources_invalid")?;
    let service = LocalProxyService::new(
        root.join("proxy-preferences-v1.json"),
        root.join("proxy-state"),
        path.join("aigoodbro-local-proxy.exe"),
        models,
        gate,
        Arc::new(ManagedProxySecrets(Arc::downgrade(manager))),
    )
    .map_err(|e| e.code())?;
    Ok(Arc::new(service))
}
pub fn install(app: &mut App, root: PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    let notifications = NotificationService::native(root.clone()).map_err(|e| e.code());
    let (notifications, notification_monitor) = match notifications {
        Ok(service) => {
            let handle = app.handle().clone();
            match service.start_monitor_with_listener(Arc::new(move || {
                let _ = handle.emit("notification-channels:changed", ());
            })) {
                Ok(monitor) => (Ok(service), Some(monitor)),
                Err(error) => (Err(error.code()), None),
            }
        }
        Err(error) => (Err(error), None),
    };
    let accounts = AccountManager::native(root.clone()).map_err(|e| e.code);
    let gate = accounts.as_ref().map_err(|e| *e).and_then(|accounts| {
        let gate = ManagedProxyGate::new(root.join("dispatch"), accounts).map_err(|e| e.code())?;
        accounts
            .install_occupancy_gate(gate.clone())
            .map_err(|e| e.code)?;
        Ok(gate)
    });
    let claude = ClaudeSubscriptionManager::native(root.clone())
        .map_err(|e| e.code)
        .and_then(|claude| {
            claude
                .install_occupancy_gate(gate.as_ref().map_err(|e| *e)?.clone())
                .map_err(|e| e.code)?;
            Ok(claude)
        });
    let proxy = accounts.as_ref().map_err(|e| *e).and_then(|accounts| {
        let gate = gate.as_ref().map_err(|e| *e)?.clone();
        let resources = app
            .path()
            .resource_dir()
            .map_err(|_| "proxy_resources_missing")?;
        make_proxy(&root, &resources, accounts, gate)
    });
    let (proxy, monitor) = match proxy {
        Ok(proxy) => match proxy.start_recovery_monitor() {
            Ok(monitor) => (Ok(proxy), Some(monitor)),
            Err(_) => (Err("proxy_monitor_unavailable"), None),
        },
        Err(error) => (Err(error), None),
    };
    let desktop = accounts.as_ref().map_err(|e| *e).and_then(|accounts| {
        let proxy = proxy.as_ref().map_err(|e| *e)?;
        ProxyDesktopConnector::native(proxy, accounts.clone(), root.join("desktop-receipts"))
            .map_err(|e| e.code())
    });
    let (desktop, desktop_monitor) = match desktop {
        Ok(desktop) => match desktop.start_lifecycle_monitor() {
            Ok(monitor) => (Ok(desktop), Some(monitor)),
            Err(_) => (Err("desktop_monitor_unavailable"), None),
        },
        Err(error) => (Err(error), None),
    };
    let statistics = accounts.as_ref().map_err(|e| *e).and_then(|accounts| {
        let config = crate::app_state::AppConfig::load(&root);
        let sources = crate::statistics_sources::collect(&config, accounts)
            .map_err(|_| "statistics_sources_unavailable")?;
        let resources = app
            .path()
            .resource_dir()
            .map_err(|_| "statistics_resources_unavailable")?;
        TokenMonitorService::native(
            resources.join("token-monitor"),
            root.join("token-monitor-v1"),
            sources,
            String::new(),
        )
        .map_err(|e| e.code())
    });
    if gate.is_ok() {
        if let Ok(accounts) = &accounts {
            let accounts = accounts.clone();
            let claude = claude.clone().ok();
            let proxy = proxy.clone().ok();
            let desktop = desktop.clone().ok();
            // Separate native ownership proofs are required for helper and GUI.
            // Recovery imports/cleans only; it never starts an official process.
            let _ = std::thread::Builder::new()
                .name("agb-owned-recovery".into())
                .spawn(move || {
                    let helper_recovered = proxy.as_ref().is_some_and(|service| {
                        match service.recover_stale_owned_run() {
                            Ok(()) => true,
                            Err(error) => {
                                tracing::warn!(
                                    code = error.code(),
                                    "Proxy ownership recovery deferred"
                                );
                                false
                            }
                        }
                    });
                    if helper_recovered {
                        if let Some(desktop) = desktop {
                            if let Err(error) = desktop.recover_stale_owned() {
                                tracing::warn!(
                                    code = error.code(),
                                    "Desktop ownership recovery deferred"
                                );
                            }
                        }
                    }
                    let _ = accounts.recover_pending_switch();
                    if let Some(claude) = claude {
                        let _ = claude.recover_pending_switch();
                    }
                });
        }
    }
    app.manage(ManagedAccountState(accounts.clone()));
    app.manage(ClaudeSubscriptionState(claude.clone()));
    app.manage(LocalProxyState(proxy.clone()));
    app.manage(LocalProxyDesktopState(desktop.clone()));
    app.manage(TokenMonitorAppState(statistics.clone()));
    app.manage(NotificationState(notifications.clone()));
    app.manage(NativeServices {
        gate,
        accounts,
        claude,
        proxy,
        desktop,
        statistics,
        notifications,
        monitor: Mutex::new(monitor),
        desktop_monitor: Mutex::new(desktop_monitor),
        notification_monitor: Mutex::new(notification_monitor),
    });
    Ok(())
}
