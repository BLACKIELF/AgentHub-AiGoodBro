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
    window.quotaCalls = [];
    window.quotaMode = 'success';
    window.wrongQuotaId = false;
    let selected = '1';
    let rows = [
      { id: '1', label: 'Synthetic A', selected: true },
      { id: '2', label: 'Synthetic B', selected: false },
    ];
    window.__TAURI_INTERNALS__.invoke = async (cmd, args) => {
      if (cmd === 'read_profile_quota') {
        window.quotaCalls.push(args.id);
        if (window.quotaMode === 'fail') throw new Error('Synthetic private failure');
        const result = {
          profile_id: window.wrongQuotaId ? '999' : args.id,
          checked_at: Date.now(),
          windows: [{ kind: 'seven_day', remaining_percent: args.id === '1' ? 59 : 80, resets_at: null }],
        };
        if (window.quotaMode === 'metadata' || window.quotaMode === 'invalid-metadata') {
          result.account = { account_type: 'chatgpt', plan_type: 'prolite', email_present: true };
          result.credits = { usd: null, points: window.quotaMode === 'metadata' ? 0 : -1, reset_cards: 2 };
        }
        if (window.quotaMode === 'credits-only' || window.quotaMode === 'empty-credits') {
          result.windows = [];
          result.credits = window.quotaMode === 'credits-only'
            ? { usd: 0, points: null, reset_cards: 0 }
            : { usd: null, points: null, reset_cards: null };
        }
        if (window.quotaMode === 'old') result.checked_at -= 600000;
        if (window.quotaMode === 'all') result.windows = [
          { kind: 'five_hour', remaining_percent: 100, resets_at: Date.now() + 18000000 },
          { kind: 'seven_day', remaining_percent: 59, resets_at: Date.now() + 604800000 },
          { kind: 'monthly', remaining_percent: 0, resets_at: Date.now() + 2592000000 },
        ];
        if (window.quotaMode === 'pending') return new Promise(resolve => { window.releaseProfileQuota = () => resolve(result); });
        return result;
      }
      if (cmd === 'get_local_usage' || cmd === 'refresh_usage') {
        if (window.noLocalUsage) return null;
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
test('credit-only quota preserves true zero without inventing a percentage or reset time', async ({ page }) => {
  const first = page.getByTestId('profile-1');
  await page.evaluate(() => { window.quotaMode = 'credits-only'; });
  await first.getByRole('button', { name: 'Read quota', exact: true }).click();
  await expect(first).toContainText('USD 0');
  await expect(first).toContainText('Reset cards 0');
  await expect(first).not.toContainText('Points 0');
  await expect(first).not.toContainText('0%');
  await expect(first).not.toContainText('Read failed');
  await expect(first).toContainText('did not report period percentages or reset times');
  await expect(first).toHaveScreenshot('profile-quota-credits-only.png');
});

test('missing windows and wholly unknown credits stay an unavailable result', async ({ page }) => {
  const first = page.getByTestId('profile-1');
  await page.evaluate(() => { window.quotaMode = 'empty-credits'; });
  await first.getByRole('button', { name: 'Read quota', exact: true }).click();
  await expect(first).toContainText('Read failed');
  await expect(first).not.toContainText('USD 0');
  await expect(first).not.toContainText('Reset cards 0');
});

test('card and list layouts keep account controls and the saved preference', async ({ page }) => {
  const region = panel(page);
  await expect(region.locator('ul.account-directory-grid')).toHaveClass(/is-cards/);
  await region.getByRole('button', { name: 'List', exact: true }).click();
  await expect(region.locator('ul.account-directory-grid')).toHaveClass(/is-list/);
  await expect(region.getByTestId('profile-1').getByRole('button', { name: 'Read quota' })).toBeVisible();
  await expect(region).toHaveScreenshot('profiles-list.png');
  await page.reload();
  await expect(panel(page).locator('ul.account-directory-grid')).toHaveClass(/is-list/);
  await panel(page).getByRole('button', { name: 'Cards', exact: true }).click();
  await expect(panel(page).locator('ul.account-directory-grid')).toHaveClass(/is-cards/);
});

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

test('quota is manual, scoped to its row, and stable across reorder', async ({ page }) => {
  const first = page.getByTestId('profile-1'), second = page.getByTestId('profile-2');
  expect(await page.evaluate(() => window.quotaCalls)).toEqual([]);
  await expect(first).toContainText('Not read yet');
  await first.getByRole('button', { name: 'Read quota', exact: true }).click();
  await expect(first).toContainText('Weekly remaining 59%');
  await expect(first).toContainText('Reset time unknown');
  await expect(first).not.toContainText('5-hour');
  await expect(first).not.toContainText('Monthly');
  await expect(second).toContainText('Not read yet');
  await second.getByRole('button', { name: 'Read quota', exact: true }).click();
  await expect(second).toContainText('Weekly remaining 80%');
  await second.getByRole('button', { name: 'Move up' }).click();
  await expect(panel(page).locator('li').first()).toContainText('Synthetic B');
  await expect(first).toContainText('Weekly remaining 59%');
  expect(await page.evaluate(() => window.quotaCalls)).toEqual(['1', '2']);
  expect(await page.evaluate(() => window.profileCalls.some(call => call.kind === 'view'))).toBe(false);
  await expect(panel(page)).toHaveScreenshot('profiles-quota-rows.png');
});

test('quota failures never become zero and preserve only explicitly old records', async ({ page }) => {
  const first = page.getByTestId('profile-1');
  await page.evaluate(() => { window.quotaMode = 'fail'; });
  await first.getByRole('button', { name: 'Read quota', exact: true }).click();
  await expect(first).toContainText('Read failed');
  await expect(first).not.toContainText('0%');
  await expect(panel(page)).toHaveScreenshot('profiles-quota-unavailable.png');
  await page.evaluate(() => { window.quotaMode = 'success'; });
  await first.getByRole('button', { name: 'Read quota', exact: true }).click();
  await expect(first).toContainText('Weekly remaining 59%');
  await page.evaluate(() => { window.quotaMode = 'fail'; });
  await first.getByRole('button', { name: 'Read quota', exact: true }).click();
  await expect(first).toContainText('Previous record; read again');
  await expect(first).toContainText('Weekly previously remaining 59%');
  await expect(panel(page)).toHaveScreenshot('profiles-quota-stale.png');
  await page.evaluate(() => { window.quotaMode = 'old'; });
  await first.getByRole('button', { name: 'Read quota', exact: true }).click();
  await expect(first).not.toContainText('Read failed');
  await expect(first).toContainText('Previous record; read again');
});

test('pending quota cannot be duplicated or restored after unlink', async ({ page }) => {
  const first = page.getByTestId('profile-1');
  await page.evaluate(() => { window.quotaMode = 'pending'; });
  await first.getByRole('button', { name: 'Read quota', exact: true }).click();
  await expect(first.getByRole('button', { name: 'Reading…', exact: true })).toBeDisabled();
  expect(await page.evaluate(() => window.quotaCalls)).toEqual(['1']);
  await expect(panel(page)).toHaveScreenshot('profiles-quota-reading.png');
  await first.getByRole('button', { name: 'Remove', exact: true }).click();
  await panel(page).getByRole('button', { name: 'Confirm removal', exact: true }).click();
  await expect(first).toHaveCount(0);
  await page.evaluate(() => window.releaseProfileQuota());
  await expect(first).toHaveCount(0);
  await expect(page.getByTestId('profile-2')).toContainText('Not read yet');
  await expect(panel(page)).not.toContainText('Weekly remaining 59%');
});

test('mismatched quota identity is rejected rather than displayed on the wrong row', async ({ page }) => {
  await page.evaluate(() => { window.wrongQuotaId = true; });
  const first = page.getByTestId('profile-1');
  await first.getByRole('button', { name: 'Read quota', exact: true }).click();
  await expect(first).toContainText('Read failed');
  await expect(first).not.toContainText('remaining');
  expect(await page.evaluate(() => window.quotaCalls)).toEqual(['1']);
});

test('quota remains accessible with no local usage snapshot', async ({ page }) => {
  await page.evaluate(() => { window.noLocalUsage = true; });
  await page.locator('header').first().getByRole('button', { name: 'Refresh', exact: true }).click();
  await expect(page.getByText('Synthetic source A', { exact: false })).toHaveCount(0);
  const first = page.getByTestId('profile-1');
  await first.getByRole('button', { name: 'Read quota', exact: true }).click();
  await expect(first).toContainText('Weekly remaining 59%');
  expect(await page.evaluate(() => window.profileCalls.length)).toBe(0);
});

test('all quota windows wrap within a narrow desktop without an inner scroller', async ({ page }) => {
  await page.setViewportSize({ width: 900, height: 900 });
  await page.evaluate(() => { window.quotaMode = 'all'; });
  await page.getByTestId('profile-1').getByRole('button', { name: 'Read quota', exact: true }).click();
  const first = page.getByTestId('profile-1');
  await expect(first).toContainText('5-hour remaining 100%');
  await expect(first).toContainText('Weekly remaining 59%');
  await expect(first).toContainText('Monthly remaining 0%');
  expect(await panel(page).evaluate(element => element.scrollWidth <= element.clientWidth)).toBe(true);
  expect(await panel(page).evaluate(element => ['auto', 'scroll'].includes(getComputedStyle(element).overflowY))).toBe(false);
  await expect(panel(page)).toHaveScreenshot('profiles-quota-narrow.png');
});


test('account metadata shows official units, details close and guide focuses correctly', async ({ page }) => {
  await page.evaluate(() => { window.quotaMode = 'metadata'; });
  const first = page.getByTestId('profile-1');
  await first.getByRole('button', { name: 'Read quota', exact: true }).click();
  await expect(first).toContainText('Pro 5x');
  await expect(first).not.toContainText('USD —');
  await expect(first).toContainText('Points 0');
  await expect(first).toContainText('Reset cards 2');
  await first.getByRole('button', { name: 'Account details', exact: true }).click();
  const dialog = page.getByRole('dialog');
  await expect(dialog).toBeVisible();
  await expect(dialog).toHaveAccessibleName('Account details · Synthetic A');
  await expect(dialog).not.toContainText('@');
  await expect(dialog.getByRole('button', { name: 'Close', exact: true })).toBeFocused();
  await expect(dialog).toHaveScreenshot('account-details.png');
  await page.keyboard.press('Escape');
  await expect(dialog).toHaveCount(0);
  await expect(first.getByRole('button', { name: 'Account details', exact: true })).toBeFocused();
  await page.getByRole('button', { name: 'Add account guide', exact: true }).click();
  await expect(page.getByRole('dialog')).toContainText('codex login');
  await expect(page.getByRole('dialog')).toHaveScreenshot('account-guide.png');
  await page.getByRole('dialog').getByRole('button', { name: 'Close', exact: true }).click();
  await expect(page.getByRole('dialog')).toHaveCount(0);
});

test('account details keep the matching alias after reorder and rename', async ({ page }) => {
  const first = page.getByTestId('profile-1'), second = page.getByTestId('profile-2');
  await first.getByRole('button', { name: 'Read quota', exact: true }).click();
  await second.getByRole('button', { name: 'Read quota', exact: true }).click();
  await second.getByRole('button', { name: 'Move up', exact: true }).click();
  await second.getByRole('button', { name: 'Rename', exact: true }).click();
  await page.getByRole('textbox', { name: 'Alias (not email)' }).fill('Renamed B');
  await panel(page).getByRole('button', { name: 'Save', exact: true }).click();
  await expect(panel(page).locator('li').first()).toContainText('Renamed B');
  await expect(second).toContainText('Weekly remaining 80%');
  await second.getByRole('button', { name: 'Account details', exact: true }).click();
  const dialog = page.getByRole('dialog');
  await expect(dialog).toHaveAccessibleName('Account details · Renamed B');
  await expect(dialog).not.toContainText('Synthetic A');
  await expect(dialog).toHaveScreenshot('account-details-renamed.png');
  await dialog.getByRole('button', { name: 'Close', exact: true }).click();
  await first.getByRole('button', { name: 'Account details', exact: true }).click();
  await expect(dialog).toHaveAccessibleName('Account details · Synthetic A');
  await expect(dialog).not.toContainText('Renamed B');
  expect(await page.evaluate(() => window.quotaCalls)).toEqual(['1', '2']);
  expect(await page.evaluate(() => window.profileCalls)).toEqual([
    { kind: 'move', id: '2', delta: -1 },
    { kind: 'rename', id: '2', label: 'Renamed B' },
  ]);
});

test('malformed official credits do not erase the previous observation', async ({ page }) => {
  const first = page.getByTestId('profile-1');
  await first.getByRole('button', { name: 'Read quota', exact: true }).click();
  await page.evaluate(() => { window.quotaMode = 'invalid-metadata'; });
  await first.getByRole('button', { name: 'Read quota', exact: true }).click();
  await expect(first).toContainText('Read failed');
  await expect(first).toContainText('Weekly previously remaining 59%');
  await expect(first).not.toContainText('Points -1');
});
