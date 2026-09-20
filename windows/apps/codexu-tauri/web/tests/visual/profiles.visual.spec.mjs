import { test, expect } from '@playwright/test';
import { FIXED_NOW_ISO, SYNTHETIC_DASHBOARD, SYNTHETIC_SETTINGS } from './synthetic-fixtures.mjs';
import { installTauriStub } from './tauri-stub.mjs';

test.beforeEach(async ({ page }) => {
  await page.clock.setFixedTime(new Date(FIXED_NOW_ISO));
  await installTauriStub(page, { settings: SYNTHETIC_SETTINGS, dashboard: SYNTHETIC_DASHBOARD });
  await page.addInitScript(() => {
    const invoke = window.__TAURI_INTERNALS__.invoke;
    window.profileCalls = [];
    window.failProfileSave = false;
    window.cancelProfilePick = false;
    window.holdNextUsage = false;
    let selected = '1';
    let rows = [
      { id: '1', label: 'Synthetic A', selected: true },
      { id: '2', label: 'Synthetic B', selected: false },
    ];
    window.__TAURI_INTERNALS__.invoke = async (cmd, args) => {
      if (cmd === 'get_local_usage' || cmd === 'refresh_usage') {
        const snapshot = structuredClone(await invoke(cmd, args));
        snapshot.messages = [selected === '1' ? 'Synthetic source A' : 'Synthetic source B'];
        if (window.holdNextUsage) {
          window.holdNextUsage = false;
          return new Promise(resolve => { window.releaseOldUsage = () => resolve(snapshot); });
        }
        return snapshot;
      }
      if (cmd === 'list_profiles') return structuredClone(rows);
      if (cmd === 'plugin:dialog|open') return window.cancelProfilePick ? null : 'C:\\Synthetic\\codex-home';
      if (cmd !== 'update_profile') return invoke(cmd, args);
      window.profileCalls.push(structuredClone(args.action));
      if (window.failProfileSave) throw new Error('synthetic failure');
      const a = args.action, index = rows.findIndex(p => p.id === a.id);
      if (a.kind === 'rename') rows[index].label = a.label;
      if (a.kind === 'move') [rows[index], rows[index + a.delta]] = [rows[index + a.delta], rows[index]];
      if (a.kind === 'view') {
        selected = a.id;
        rows = rows.map(p => ({ ...p, selected: p.id === a.id }));
      }
      if (a.kind === 'remove') rows = rows.filter(p => p.id !== a.id);
      if (a.kind === 'link') rows.push({ id: '3', label: a.label, selected: false });
      return structuredClone(rows);
    };
  });
  await page.goto('/');
  await expect(page.getByTestId('profile-1')).toBeVisible();
});

test('late response from previous source cannot overwrite the selected source', async ({ page }) => {
  await expect(page.getByText('Synthetic source A', { exact: false })).toBeVisible();
  await page.evaluate(() => { window.holdNextUsage = true; });
  await page.locator('header').first().getByRole('button', { name: 'Refresh', exact: true }).click();
  await expect.poll(() => page.evaluate(() => typeof window.releaseOldUsage)).toBe('function');
  await page.getByTestId('profile-2').getByRole('button', { name: 'View usage' }).click();
  await expect(page.getByText('Synthetic source B', { exact: false })).toBeVisible();
  await page.evaluate(() => window.releaseOldUsage());
  await expect(page.getByText('Synthetic source A', { exact: false })).toHaveCount(0);
  await expect(page.getByText('Synthetic source B', { exact: false })).toBeVisible();
});

const panel = page => page.getByRole('region', { name: 'Account directories', exact: true });
test('stable order, one-step move, view selection and no paths', async ({ page }) => {
  const region = panel(page);
  await expect(region).toContainText('does not switch Codex login');
  await expect(region).not.toContainText('C:\\');
  await expect(page.getByTestId('profile-1').getByRole('button', { name: 'Move up' })).toBeDisabled();
  await page.getByTestId('profile-2').getByRole('button', { name: 'Move up' }).click();
  await expect(region.locator('li').first()).toContainText('Synthetic B');
  await page.getByTestId('profile-2').getByRole('button', { name: 'View usage' }).click();
  await expect(page.getByTestId('profile-2').getByRole('button', { name: 'Viewing' })).toBeDisabled();
  await expect(region).toHaveScreenshot('profiles-selected.png');
});

test('failed save keeps editor, retry saves without moving row', async ({ page }) => {
  await page.getByTestId('profile-1').getByRole('button', { name: 'Rename' }).click();
  await page.getByRole('textbox', { name: 'Alias (not email)' }).fill('Renamed');
  await page.evaluate(() => { window.failProfileSave = true; });
  await panel(page).getByRole('button', { name: 'Save', exact: true }).click();
  await expect(panel(page).getByRole('alert')).toBeVisible();
  await expect(page.getByRole('textbox', { name: 'Alias (not email)' })).toHaveValue('Renamed');
  await expect(panel(page)).toHaveScreenshot('profiles-save-failed.png');
  await page.evaluate(() => { window.failProfileSave = false; });
  await panel(page).getByRole('button', { name: 'Save', exact: true }).click();
  await expect(panel(page).locator('li').first()).toContainText('Renamed');
  await expect(panel(page).getByRole('textbox')).toHaveCount(0);
});

test('link cancellation does not write; remove requires confirmation', async ({ page }) => {
  await panel(page).getByRole('button', { name: 'Link existing directory' }).click();
  await page.getByRole('textbox', { name: 'Alias (not email)' }).fill('Synthetic C');
  await page.evaluate(() => { window.cancelProfilePick = true; });
  await panel(page).getByRole('button', { name: 'Choose directory and link' }).click();
  expect(await page.evaluate(() => window.profileCalls.length)).toBe(0);
  await page.evaluate(() => { window.cancelProfilePick = false; });
  await panel(page).getByRole('button', { name: 'Choose directory and link' }).click();
  await expect(page.getByTestId('profile-3')).toBeVisible();
  await page.getByTestId('profile-3').getByRole('button', { name: 'Remove', exact: true }).click();
  await expect(panel(page)).toContainText('Keep files, credentials and login unchanged');
  await expect(panel(page)).toHaveScreenshot('profiles-remove-confirm.png');
  await panel(page).getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(page.getByTestId('profile-3')).toBeVisible();
  await page.getByTestId('profile-3').getByRole('button', { name: 'Remove', exact: true }).click();
  await panel(page).getByRole('button', { name: 'Confirm removal', exact: true }).click();
  await expect(page.getByTestId('profile-3')).toHaveCount(0);
});
