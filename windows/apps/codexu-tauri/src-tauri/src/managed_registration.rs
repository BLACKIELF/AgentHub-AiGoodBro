//! Native first-login registration. The vault owns retry intent; settings and
//! workflow files contain their existing schemas, not a second journal.
use crate::{
    app_state::AppState,
    commands::{
        account_lifecycle::ManagedAccountState,
        cli_workflow::{ensure_registered_profile, WorkflowState},
    },
};
use codexu_core::{
    accounts::{registration::RegistrationProgress, AccountError, AccountManager},
    local_cli::LocalCliKind,
    profiles::same_root,
};
use std::{path::Path, sync::Arc};
use tauri::{Emitter, Manager};

fn failed() -> AccountError {
    AccountError {
        code: "registration_persistence_failed",
    }
}

async fn persist_mapping(
    state: &Arc<AppState>,
    workflow: &WorkflowState,
    root: &Path,
    label: &str,
    progress: &RegistrationProgress<'_>,
) -> Result<u64, AccountError> {
    let mut registered = None;
    let mut created_by_intent = false;
    state
        .try_update_config(|config| {
            config.profiles.validate()?;
            let planned = progress.planned_profile_id()?;
            let matches: Vec<_> = config
                .profiles
                .entries
                .iter()
                .filter(|entry| {
                    entry
                        .root
                        .canonicalize()
                        .ok()
                        .as_ref()
                        .is_some_and(|existing| same_root(existing, root))
                })
                .collect();
            anyhow::ensure!(matches.len() <= 1, "Ambiguous registration root");
            if let Some(existing) = matches.first() {
                anyhow::ensure!(
                    existing.kind == LocalCliKind::Codex && same_root(&existing.root, root),
                    "Registration platform or canonical root changed"
                );
                anyhow::ensure!(
                    planned.is_none_or(|id| id == existing.id),
                    "Registration catalog changed"
                );
                registered = Some(existing.id);
                created_by_intent = planned.is_some();
                return Ok(());
            }
            // Plan the exact monotonic catalog ID before the catalog can commit.
            // A different intervening entry must not be adopted on retry.
            config
                .profiles
                .add(LocalCliKind::Codex, label.into(), root.to_path_buf())?;
            let id = config.profiles.entries.last().unwrap().id;
            anyhow::ensure!(
                planned.is_none_or(|expected| expected == id),
                "Registration catalog changed"
            );
            progress.plan_profile(id)?;
            registered = Some(id);
            created_by_intent = true;
            Ok(())
        })
        .await
        .map_err(|_| failed())?;
    let id = registered.ok_or_else(failed)?;
    if created_by_intent {
        ensure_registered_profile(state, workflow, id, root)
            .await
            .map_err(|_| failed())?;
    }
    Ok(id)
}

fn finish_pending(
    accounts: &AccountManager,
    state: &Arc<AppState>,
    workflow: &WorkflowState,
    id: &str,
) -> Result<Option<u64>, AccountError> {
    let mut profile_id = None;
    accounts.register_pending_account(id, |root, label, progress| {
        profile_id = Some(tauri::async_runtime::block_on(persist_mapping(
            state, workflow, root, label, progress,
        ))?);
        Ok(())
    })?;
    Ok(profile_id)
}

/// Called from the existing login/maintenance blocking workers only. A failed
/// attempt keeps its vault intent; no new timer or network refresh is created.
pub(crate) fn retry_pending(app: &tauri::AppHandle, accounts: &AccountManager) {
    let (Some(state), Some(workflow)) = (
        app.try_state::<Arc<AppState>>(),
        app.try_state::<WorkflowState>(),
    ) else {
        return;
    };
    let Ok(ids) = accounts.pending_registration_ids() else {
        return;
    };
    for id in ids {
        if finish_pending(accounts, &state, &workflow, &id).is_ok_and(|p| p.is_some()) {
            let _ = app.emit("profiles:changed", ());
            let _ = app.emit("managed-accounts:changed", ());
        }
    }
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RegistrationReceipt {
    account_id: String,
    status: &'static str,
    profile_id: String,
}

/// Explicit repair for legacy verified slots. It creates the same identity-bound
/// pending intent but does not enroll/enable the reverse proxy or switch Desktop.
#[tauri::command]
pub async fn register_managed_account(
    app: tauri::AppHandle,
    accounts: tauri::State<'_, ManagedAccountState>,
    account_id: String,
) -> Result<RegistrationReceipt, String> {
    let accounts = accounts.manager()?;
    tauri::async_runtime::spawn_blocking(move || {
        let state = app
            .try_state::<Arc<AppState>>()
            .ok_or("registration_unavailable")?;
        let workflow = app
            .try_state::<WorkflowState>()
            .ok_or("registration_unavailable")?;
        accounts
            .request_account_registration(&account_id)
            .map_err(|e| e.code)?;
        accounts
            .refresh_registration_evidence(&account_id)
            .map_err(|e| e.code)?;
        let profile_id = finish_pending(&accounts, &state, &workflow, &account_id)
            .map_err(|e| e.code)?
            .ok_or("registration_unavailable")?;
        let _ = app.emit("profiles:changed", ());
        let _ = app.emit("managed-accounts:changed", ());
        Ok(RegistrationReceipt {
            account_id,
            status: "registered",
            profile_id: profile_id.to_string(),
        })
    })
    .await
    .map_err(|_| "registration_unavailable".to_owned())?
    .map_err(str::to_owned)
}

#[cfg(test)]
#[path = "managed_registration_tests.rs"]
mod tests;
