import { test, expect } from '@playwright/test';
import { installTauriStub } from './tauri-stub.mjs';
import { FIXED_NOW_ISO, FIXED_NOW_MS, SYNTHETIC_DASHBOARD, SYNTHETIC_SETTINGS } from './synthetic-fixtures.mjs';

const BATCH_ID = 'f'.repeat(32);

function preferences(overrides = {}) {
  return {
    enabled: false,
    fiveHourRemainingThreshold: 5,
    sevenDayRemainingThreshold: 10,
    excludedProfileIds: [],
    pauseAtOnePercent: false,
    resumeAfterSwitch: false,
    ...overrides,
  };
}

function status(overrides = {}) {
  return {
    phase: 'blocked',
    issueCode: 'automatic_switch_task_unknown',
    sourceAccountId: null,
    targetAccountId: null,
    lastAttemptAtMs: FIXED_NOW_MS - 60_000,
    lastSucceededAtMs: null,
    nextEligibleAtMs: null,
    liveTasksAvailable: false,
    pauseResumeAvailable: true,
    resumeAfterSwitchAvailable: false,
    lastSwitchRestored: null,
    ...overrides,
  };
}

function recoveryState(overrides = {}) {
  return {
    batchId: BATCH_ID,
    phase: 'ready',
    pendingCount: 3,
    uncertainCount: 0,
    canResume: true,
    canClear: true,
    busy: false,
    ...overrides,
  };
}

async function openAutomaticSwitch(page, { saved = preferences(), automatic = status(), quota = recoveryState() } = {}) {
  await page.clock.install({ time: new Date(FIXED_NOW_ISO) });
  await page.route('**/*', route => new URL(route.request().url()).hostname === '127.0.0.1' ? route.continue() : route.abort());
  await installTauriStub(page, {
    settings: { ...SYNTHETIC_SETTINGS, language: 'en', theme: 'dark' },
    dashboard: SYNTHETIC_DASHBOARD,
    windowLabel: 'settings',
  }, () => {
    const original = window.__TAURI_INTERNALS__.invoke;
    window.m06Calls = [];
    window.automaticPreferences = {
      enabled: false,
      fiveHourRemainingThreshold: 5,
      sevenDayRemainingThreshold: 10,
      excludedProfileIds: [],
      pauseAtOnePercent: false,
      resumeAfterSwitch: false,
    };
    window.automaticStatus = {
      phase: 'blocked',
      issueCode: 'automatic_switch_task_unknown',
      sourceAccountId: null,
      targetAccountId: null,
      lastAttemptAtMs: Date.now() - 60_000,
      lastSucceededAtMs: null,
      nextEligibleAtMs: null,
      liveTasksAvailable: false,
      pauseResumeAvailable: true,
      resumeAfterSwitchAvailable: false,
      lastSwitchRestored: null,
    };
    window.quotaResumeState = {
      batchId: 'ffffffffffffffffffffffffffffffff',
      phase: 'ready',
      pendingCount: 3,
      uncertainCount: 0,
      canResume: true,
      canClear: true,
      busy: false,
    };
    window.quotaResumeAfterAttempt = {
      batchId: 'ffffffffffffffffffffffffffffffff',
      phase: 'recovery',
      pendingCount: 1,
      uncertainCount: 2,
      canResume: false,
      canClear: true,
      busy: false,
    };
    window.__TAURI_INTERNALS__.invoke = async (command, args) => {
      if (command === 'get_automatic_switch_preferences') return structuredClone(window.automaticPreferences);
      if (command === 'get_automatic_switch_status') return structuredClone(window.automaticStatus);
      if (command === 'list_managed_accounts') return [];
      if (command === 'set_automatic_switch_preferences') {
        window.m06Calls.push({ command, args: structuredClone(args) });
        window.automaticPreferences = structuredClone(args.preferences);
        return structuredClone(window.automaticPreferences);
      }
      if (command === 'get_quota_resume_state') return structuredClone(window.quotaResumeState);
      if (command === 'resume_quota_tasks') {
        window.m06Calls.push({ command, args: structuredClone(args) });
        window.quotaResumeState = structuredClone(window.quotaResumeAfterAttempt);
        return structuredClone(window.quotaResumeState);
      }
      if (command === 'clear_quota_resume') {
        window.m06Calls.push({ command, args: structuredClone(args) });
        window.quotaResumeState = {
          batchId: null,
          phase: 'empty',
          pendingCount: 0,
          uncertainCount: 0,
          canResume: false,
          canClear: false,
          busy: false,
        };
        return structuredClone(window.quotaResumeState);
      }
      return original(command, args);
    };
  });
  await page.goto('/');
  await page.evaluate(({ savedPreferences, automaticStatus, quotaState, afterAttempt }) => {
    window.automaticPreferences = savedPreferences;
    window.automaticStatus = automaticStatus;
    window.quotaResumeState = quotaState;
    window.quotaResumeAfterAttempt = afterAttempt;
  }, { savedPreferences: saved, automaticStatus: automatic, quotaState: quota, afterAttempt: {
    batchId: BATCH_ID,
    phase: 'recovery',
    pendingCount: 1,
    uncertainCount: 2,
    canResume: false,
    canClear: true,
    busy: false,
  } });
  await page.getByText('Low quota and automatic switching', { exact: true }).click();
  const panel = page.locator('.automatic-switch-body');
  const recovery = page.getByRole('region', { name: 'Paused task recovery', exact: true });
  await expect(panel.getByRole('status').first()).toContainText('Blocked');
  await expect(recovery).toBeVisible();
  return { panel, recovery };
}

test('quota recovery stays explicit under unknown status and pause at one percent is opt-in', async ({ page }) => {
  const { panel, recovery } = await openAutomaticSwitch(page);
  const pauseAtOnePercent = panel.getByLabel('Pause and switch at 1%', { exact: true });
  const restore = panel.getByLabel('Restore the current conversation after switching', { exact: true });
  await expect(panel.getByRole('alert')).toContainText('Task activity is unknown');
  await expect(pauseAtOnePercent).toBeEnabled();
  await expect(pauseAtOnePercent).not.toBeChecked();
  await expect(restore).toBeDisabled();
  await expect(panel).toContainText('Conversation restoration is unverified on this device');
  await expect(restore).not.toBeChecked();
  await expect(panel).toHaveScreenshot('automatic-switch-blocked-explicit-pause.png');

  await pauseAtOnePercent.check();
  expect(await page.evaluate(() => window.m06Calls.filter(call => call.command === 'set_automatic_switch_preferences'))).toHaveLength(0);
  await panel.getByRole('button', { name: 'Save automatic switch settings', exact: true }).click();
  await expect(panel).toContainText('Automatic switch settings saved');
  expect(await page.evaluate(() => window.m06Calls.filter(call => call.command === 'set_automatic_switch_preferences').at(-1).args.preferences)).toMatchObject({ pauseAtOnePercent: true, resumeAfterSwitch: false });

  await expect(recovery).toContainText('3 original tasks are paused');
  await expect(recovery.getByRole('button', { name: 'Continue original tasks', exact: true })).toBeEnabled();
  expect(await page.evaluate(() => window.m06Calls.filter(call => call.command === 'resume_quota_tasks'))).toHaveLength(0);
  await expect(recovery).toHaveScreenshot('quota-resume-ready-explicit-action.png');

  await recovery.getByRole('button', { name: 'Continue original tasks', exact: true }).click();
  await expect(recovery).toContainText('2 request outcomes are uncertain and will not be retried automatically');
  await expect(recovery.getByRole('button', { name: 'Continue original tasks', exact: true })).toHaveCount(0);
  await expect(recovery).toHaveScreenshot('quota-resume-unknown-result.png');
  expect(await page.evaluate(() => window.m06Calls.filter(call => call.command === 'resume_quota_tasks'))).toEqual([
    { command: 'resume_quota_tasks', args: { batchId: BATCH_ID } },
  ]);

  await page.clock.runFor(6_000);
  await expect(recovery).toContainText('2 request outcomes are uncertain and will not be retried automatically');
  expect(await page.evaluate(() => window.m06Calls.filter(call => call.command === 'resume_quota_tasks'))).toHaveLength(1);
});

test('clearing a quota recovery batch requires confirmation and can be cancelled', async ({ page }) => {
  const { recovery } = await openAutomaticSwitch(page, {
    quota: recoveryState({ phase: 'recovery', pendingCount: 1, uncertainCount: 2, canResume: false }),
  });
  await recovery.getByRole('button', { name: 'Clear recovery records', exact: true }).click();
  await expect(recovery).toContainText('Clearing removes this batch from recovery here. The original chats and running tasks are retained.');
  await expect(recovery.getByRole('button', { name: 'Confirm clearing records', exact: true })).toBeVisible();
  await expect(recovery).toHaveScreenshot('quota-resume-clear-confirmation.png');

  await recovery.getByRole('button', { name: 'Keep records', exact: true }).click();
  expect(await page.evaluate(() => window.m06Calls.filter(call => call.command === 'clear_quota_resume'))).toHaveLength(0);
  await expect(recovery).toBeVisible();

  await recovery.getByRole('button', { name: 'Clear recovery records', exact: true }).click();
  await recovery.getByRole('button', { name: 'Confirm clearing records', exact: true }).click();
  await expect(recovery).toHaveCount(0);
  expect(await page.evaluate(() => window.m06Calls.filter(call => call.command === 'clear_quota_resume'))).toEqual([
    { command: 'clear_quota_resume', args: { batchId: BATCH_ID } },
  ]);
});
