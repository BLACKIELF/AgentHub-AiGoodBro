//! Protocol smoke test for the test-only native Windows fake CLI.
//! Build the `windows_fake_cli` example first and point
//! `AIGB_WINDOWS_FAKECLI_PATH` at the resulting executable.
#![cfg(windows)]

use anyhow::{Context, Result};
use codexu_core::workflow_reader;
use std::{env, path::PathBuf, time::Duration};

#[tokio::test]
async fn fake_cli_answers_the_workflow_reader_protocol() -> Result<()> {
    let executable = env::var_os("AIGB_WINDOWS_FAKECLI_PATH")
        .map(PathBuf::from)
        .context("set AIGB_WINDOWS_FAKECLI_PATH to the built windows_fake_cli executable")?;
    let home = tempfile::tempdir()?;
    let workspace = tempfile::tempdir()?;

    let evidence = workflow_reader::read_evidence_with_timeout(
        &executable,
        home.path(),
        workspace.path(),
        Duration::from_secs(10),
    )
    .await?;

    assert_eq!(evidence.models.len(), 1);
    assert_eq!(evidence.models[0].id, "windows-fake-model");
    assert_eq!(evidence.official_plan_type(), Some("fixture-plan"));
    Ok(())
}
