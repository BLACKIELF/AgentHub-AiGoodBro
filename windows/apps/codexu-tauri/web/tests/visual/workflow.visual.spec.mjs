import { test, expect } from '@playwright/test';
import { SYNTHETIC_DASHBOARD, SYNTHETIC_SETTINGS, FIXED_NOW_ISO } from './synthetic-fixtures.mjs';
import { installTauriStub } from './tauri-stub.mjs';

test.beforeEach(async ({ page }) => {
  await page.clock.setFixedTime(new Date(FIXED_NOW_ISO));
  await installTauriStub(page, { settings: SYNTHETIC_SETTINGS, dashboard: SYNTHETIC_DASHBOARD }, () => {
    const base = window.__TAURI_INTERNALS__.invoke;
    const stored = localStorage.getItem('synthetic-workflow');
    let state = stored ? JSON.parse(stored) : { profile_id: '1', preference: { participating: true, model: null, effort: null, revision: 0 }, phase: 'idle', started_at: null, supported: true };
    window.workflowCalls = [];
    window.workflowSaveFails = false;
    window.workflowStartPending = false;
    window.workflowStartFails = false;
    window.__TAURI_INTERNALS__.invoke = async (cmd, args) => {
      if (cmd === 'list_profiles') return [{ id: '1', label: 'Synthetic workflow', selected: true, platform: 'codex', platform_name: 'Codex', can_view_usage: true }];
      if (cmd === 'get_account_workflow') return structuredClone(state);
      if (cmd === 'read_workflow_models') return [{ id: 'synthetic-model', label: 'Synthetic model', efforts: ['low', 'high'], default_effort: 'high', is_default: true }];
      if (cmd === 'plugin:dialog|open') return 'C:\\Synthetic\\workspace';
      if (cmd === 'set_account_workflow') {
        window.workflowCalls.push({ cmd, action: structuredClone(args.action) });
        if (window.workflowSaveFails) throw 'save_failed';
        if (args.action.kind === 'participation') state.preference.participating = args.action.value;
        else if (args.action.kind === 'dispatch_window') state.preference.dispatch_window = structuredClone(args.action.window);
        else { state.preference.model = args.action.model; state.preference.effort = args.action.effort; }
        state.preference.revision++;
        localStorage.setItem('synthetic-workflow', JSON.stringify(state));
        return structuredClone(state);
      }
      if (cmd === 'start_account_terminal') {
        window.workflowCalls.push({ cmd });
        if (window.workflowStartFails) throw 'quota_or_identity_unavailable';
        state.phase = 'checking';
        if (window.workflowStartPending) return new Promise((resolve, reject) => { window.finishWorkflowStart = () => {
          if (!state.preference.participating) { state.phase = 'failed'; reject('launch_disabled'); }
          else { state.phase = 'running'; resolve(structuredClone(state)); }
        }; });
        state.phase = 'running'; return structuredClone(state);
      }
      if (cmd === 'stop_account_terminal') { window.workflowCalls.push({ cmd }); state.phase = 'stopped'; return structuredClone(state); }
      return base(cmd, args);
    };
  });
  await page.goto('/');
  await expect(page.getByTestId('account-workflow-1')).toBeVisible();
  await page.getByTestId('account-workflow-1').getByRole('button', { name: /Model and scheduling/ }).click();
});

test('compact card reveals scheduling, saves opt-out without quota and retains it after reload', async ({ page }) => {
  const section = page.getByTestId('account-workflow-1');
  await expect(section.getByRole('button', { name: /Model and scheduling/ })).toHaveAttribute('aria-expanded', 'true');
  const toggle = section.getByRole('switch', { name: 'Participate in scheduling' });
  await expect(toggle).toBeChecked();
  await toggle.uncheck();
  await expect(toggle).not.toBeChecked();
  await expect(section.getByRole('button', { name: 'Choose workspace and open Codex' })).toBeDisabled();
  expect(await page.evaluate(() => window.workflowCalls)).toEqual([{ cmd: 'set_account_workflow', action: { kind: 'participation', value: false } }]);
  await page.reload();
  await page.getByTestId('account-workflow-1').getByRole('button', { name: /Model and scheduling/ }).click();
  await expect(page.getByTestId('account-workflow-1').getByRole('switch')).not.toBeChecked();
  await expect(page.getByTestId('account-workflow-1')).toHaveScreenshot('workflow-opted-out.png');
});

test('can opt out while launch preflight is pending and a failed save keeps prior state', async ({ page }) => {
  const section = page.getByTestId('account-workflow-1'), toggle = section.getByRole('switch');
  await page.evaluate(() => { window.workflowSaveFails = true; });
  await toggle.click(); // A failed save deliberately restores the checked state.
  await expect(toggle).toBeChecked();
  await expect(section.getByRole('alert')).toContainText('previous setting was retained');
  await page.evaluate(() => { window.workflowSaveFails = false; window.workflowStartPending = true; });
  await section.getByRole('button', { name: 'Choose workspace and open Codex' }).click();
  await expect.poll(() => page.evaluate(() => typeof window.finishWorkflowStart)).toBe('function');
  await toggle.uncheck();
  await expect(toggle).not.toBeChecked();
  await page.evaluate(() => window.finishWorkflowStart());
  await expect(section.getByRole('alert')).toContainText('No terminal was started');
  await expect(toggle).not.toBeChecked();
  await expect(section).toHaveScreenshot('workflow-cancelled-during-preflight.png');
});

test('real model choices, unavailable quota, and explicit owned-terminal stop', async ({ page }) => {
  const section = page.getByTestId('account-workflow-1');
  await section.getByRole('button', { name: 'Read available models' }).click();
  await section.getByRole('combobox', { name: 'Model', exact: true }).selectOption('synthetic-model');
  await expect(section.getByRole('combobox', { name: 'Reasoning effort' })).toHaveValue('high');
  await section.getByRole('combobox', { name: 'Reasoning effort' }).selectOption('low');
  await expect(section.getByRole('combobox', { name: 'Reasoning effort' })).toHaveValue('low');
  await page.evaluate(() => { window.workflowStartFails = true; });
  await section.getByRole('button', { name: 'Choose workspace and open Codex' }).click();
  await expect(section.getByRole('alert')).toContainText('current available quota');
  await page.evaluate(() => { window.workflowStartFails = false; });
  await section.getByRole('button', { name: 'Choose workspace and open Codex' }).click();
  await expect(section).toContainText('Terminal running');
  await section.getByRole('button', { name: 'Stop this terminal' }).click();
  await expect(section).toHaveScreenshot('workflow-owned-stop-confirmation.png');
  await section.getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(section).toContainText('Terminal running');
  await section.getByRole('button', { name: 'Stop this terminal' }).click();
  await section.getByRole('button', { name: 'Confirm stop' }).click();
  await expect(section).toContainText('Stopped');
  expect(await page.evaluate(() => window.workflowCalls.filter(call => call.cmd === 'stop_account_terminal').length)).toBe(1);
});

test('dispatch windows save explicit timezone and overnight weekdays, retain dirty draft after failed save and reload saved rule', async ({ page }) => {
  const workflow = page.getByTestId('account-workflow-1'), window = workflow.getByRole('region', { name: 'Dispatch windows' });
  await window.getByRole('button', { name: /Dispatch windows/ }).click();
  await window.getByRole('combobox', { name: 'Window rule' }).selectOption('onlyWithin'); await window.getByRole('textbox', { name: 'Time zone' }).fill('Asia/Shanghai');
  await expect(window).toContainText('With no windows, no new work will be admitted.');
  await window.getByRole('button', { name: 'Add window' }).click();
  await window.getByRole('checkbox', { name: 'Every day', exact: true }).uncheck();
  for (const day of ['Tue', 'Wed', 'Thu', 'Fri']) await window.getByRole('checkbox', { name: day, exact: true }).uncheck();
  await window.getByLabel('Start 1', { exact: true }).fill('23:00'); await window.getByLabel('End 1', { exact: true }).fill('01:00');
  await page.evaluate(() => { window.workflowSaveFails = true; }); await window.getByRole('button', { name: 'Save window rule' }).click();
  await expect(workflow.getByRole('alert')).toContainText('previous setting was retained'); await expect(window.getByLabel('Start 1')).toHaveValue('23:00'); await expect(window).toContainText('Unsaved changes');
  await page.evaluate(() => { window.workflowSaveFails = false; }); await window.getByRole('button', { name: 'Save window rule' }).click(); await expect(window).not.toContainText('Unsaved changes');
  expect((await page.evaluate(() => window.workflowCalls.at(-1))).action.window).toEqual({ mode: 'onlyWithin', timeZoneIdentifier: 'Asia/Shanghai', intervals: [{ startMinute: 1380, endMinute: 60, allDays: false, weekdays: [1], allDay: false }] });
  await expect(window).toHaveScreenshot('workflow-overnight-window.png');
  await window.getByLabel('End 1').fill('23:00'); await expect(window.getByRole('button', { name: 'Save window rule' })).toBeDisabled(); await window.getByRole('checkbox', { name: 'All day', exact: true }).check(); await expect(window.getByRole('button', { name: 'Save window rule' })).toBeEnabled();
  await window.getByRole('textbox', { name: 'Time zone' }).fill('Unknown/Timezone'); await expect(window.getByRole('button', { name: 'Save window rule' })).toBeDisabled();
  await page.reload(); await page.getByTestId('account-workflow-1').getByRole('button', { name: /Model and scheduling/ }).click();
  await page.getByRole('region', { name: 'Dispatch windows' }).getByRole('button', { name: /Dispatch windows/ }).click();
  await expect(page.getByLabel('Start 1')).toHaveValue('23:00'); await expect(page.getByLabel('End 1')).toHaveValue('01:00');
});
test('reusing the workflow component cannot move a dirty schedule draft or late save into another account', async ({ page }) => {
  await page.evaluate(async () => {
    document.getElementById('root').style.display = 'none';
    const original = window.__TAURI_INTERNALS__.invoke;
    window.__TAURI_INTERNALS__.invoke = async (command, args) => {
      if (command === 'get_account_workflow') return { profile_id: args.id, preference: { participating: true, model: null, effort: null, revision: 0 }, phase: 'idle', started_at: null, supported: true };
      if (command === 'set_account_workflow') { window.workflowCalls.push({ cmd: command, id: args.id, action: structuredClone(args.action) }); return new Promise(resolve => { window.releaseWorkflow = () => resolve({ profile_id: args.id, preference: { participating: true, model: null, effort: null, revision: 1, dispatch_window: args.action.window }, phase: 'idle', started_at: null, supported: true }); }); }
      return original(command, args);
    };
    const { mountAccountComponent } = await import('/tests/visual/account-actions-component.fixture.tsx'); window.workflowFixture = mountAccountComponent('workflow', 'A');
  });
  const fixture = page.getByTestId('account-component-fixture');
  await fixture.getByRole('region', { name: 'Dispatch windows' }).getByRole('button', { name: /Dispatch windows/ }).click();
  await fixture.getByRole('combobox', { name: 'Window rule' }).selectOption('onlyWithin');
  await fixture.getByRole('button', { name: 'Save window rule' }).click(); await expect.poll(() => page.evaluate(() => typeof window.releaseWorkflow)).toBe('function');
  await page.evaluate(() => window.workflowFixture.render('B'));
  await expect(fixture.getByTestId('account-workflow-B')).toBeVisible();
  await fixture.getByRole('region', { name: 'Dispatch windows' }).getByRole('button', { name: /Dispatch windows/ }).click();
  await expect(fixture.getByRole('combobox', { name: 'Window rule' })).toHaveValue('unrestricted'); await expect(fixture.getByRole('button', { name: 'Save window rule' })).toBeDisabled();
  await page.evaluate(() => window.releaseWorkflow());
  await expect(fixture.getByRole('combobox', { name: 'Window rule' })).toHaveValue('unrestricted'); expect(await page.evaluate(() => window.workflowCalls.filter(call => call.id === 'B'))).toHaveLength(0);
});
