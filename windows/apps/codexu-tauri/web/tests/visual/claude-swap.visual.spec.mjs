import { test, expect } from '@playwright/test';
import { FIXED_NOW_ISO, SYNTHETIC_DASHBOARD, SYNTHETIC_SETTINGS } from './synthetic-fixtures.mjs';
import { installTauriStub } from './tauri-stub.mjs';

async function open(page) {
  await page.clock.setFixedTime(new Date(FIXED_NOW_ISO));
  await installTauriStub(page, { settings: { ...SYNTHETIC_SETTINGS, language: 'en', theme: 'dark' }, dashboard: SYNTHETIC_DASHBOARD }, () => {
    const original = window.__TAURI_INTERNALS__.invoke;
    window.swapCalls = []; window.swapRows = [];
    window.swapCandidates = [{ candidate_id: 'a'.repeat(64), label: 'Claude 1', masked_identity: 'a***@synthetic.invalid', already_imported: false,
      credential: 'SYNTHETIC_SECRET_NOT_PROJECTED', path: 'SYNTHETIC_PATH_NOT_PROJECTED' },
    { candidate_id: 'b'.repeat(64), label: 'Claude 2', masked_identity: 'b***@synthetic.invalid', already_imported: false }];
    window.__TAURI_INTERNALS__.invoke = async (command, args) => {
      if (command === 'list_claude_subscriptions') return structuredClone(window.swapRows);
      if (command === 'scan_claude_swap_candidates') {
        window.swapCalls.push({ command });
        if (window.holdSwapScan) return new Promise(resolve => { const rows = structuredClone(window.swapCandidates); window.releaseSwapScan = () => resolve(rows); });
        return structuredClone(window.swapCandidates);
      }
      if (command === 'import_claude_swap_candidate') {
        window.swapCalls.push({ command, ...args });
        if (window.failSwapImport) throw window.failSwapImport;
        const row = { id: args.candidateId.slice(0, 32), label: args.candidateId.startsWith('a') ? 'Claude 1' : 'Claude 2', platform: 'claude', storage_kind: 'managed', login_state: 'verified', active_state: 'unknown', masked_identity: 'a***@synthetic.invalid', plan_type: null, can_login: true, can_switch: true, switch_block_reason: null, revision: 1, recovery_required: false, registration_pending: false };
        if (window.holdSwapImport) return new Promise(resolve => { window.releaseSwapImport = () => { window.swapRows.push(row); resolve(structuredClone(row)); }; });
        window.swapRows.push(row); return structuredClone(row);
      }
      return original(command, args);
    };
  });
  await page.goto('/');
  await page.getByRole('navigation').getByRole('button', { name: 'Accounts', exact: true }).click();
  const section = page.getByRole('region', { name: 'Add from claude-swap', exact: true });
  await expect(section).toBeVisible();
  return section;
}

test('Claude-swap scans only explicitly and projects metadata; one Add refreshes the real account list', async ({ page }) => {
  const section = await open(page);
  expect(await page.evaluate(() => window.swapCalls)).toEqual([]);
  await section.getByRole('button', { name: 'Scan claude-swap', exact: true }).click();
  await expect(section.getByRole('listitem')).toHaveCount(2);
  await expect(section).toContainText('a***@synthetic.invalid');
  await expect(page.locator('body')).not.toContainText('SYNTHETIC_SECRET_NOT_PROJECTED');
  await expect(page.locator('body')).not.toContainText('SYNTHETIC_PATH_NOT_PROJECTED');
  await section.getByRole('listitem').first().getByRole('button', { name: 'Add', exact: true }).click();
  await expect(section.getByRole('listitem').first().getByRole('button', { name: 'Added', exact: true })).toBeDisabled();
  await expect(page.getByTestId(`claude-subscription-${'a'.repeat(32)}`)).toBeVisible();
  expect(await page.evaluate(() => window.swapCalls)).toEqual([{ command: 'scan_claude_swap_candidates' }, { command: 'import_claude_swap_candidate', candidateId: 'a'.repeat(64) }]);
});

test('failed import retains candidates and never claims success or exposes arbitrary error content', async ({ page }) => {
  const section = await open(page);
  await section.getByRole('button', { name: 'Scan claude-swap', exact: true }).click();
  await page.evaluate(() => { window.failSwapImport = 'SYNTHETIC_PATH_SECRET/arbitrary'; });
  await section.getByRole('listitem').first().getByRole('button', { name: 'Add', exact: true }).click();
  await expect(section.getByRole('alert')).toContainText('Could not complete');
  await expect(section.getByRole('listitem')).toHaveCount(2);
  await expect(section.getByRole('button', { name: 'Added', exact: true })).toHaveCount(0);
  await expect(page.locator('body')).not.toContainText('SYNTHETIC_PATH_SECRET');
  await expect(page.getByTestId(`claude-subscription-${'a'.repeat(32)}`)).toHaveCount(0);
});

test('inflight Add prevents duplicate dispatch and a late scan cannot fill a remounted panel', async ({ page }) => {
  await open(page);
  await page.evaluate(async () => {
    document.getElementById('root').hidden = true;
    const element = document.createElement('div'); element.id = 'swap-fixture'; document.body.append(element);
    const { mountClaudeSwap } = await import('/tests/visual/claude-swap-component.fixture.tsx');
    window.swapHarness = mountClaudeSwap(element);
  });
  const section = page.locator('#swap-fixture').getByRole('region', { name: 'Add from claude-swap', exact: true });
  await section.getByRole('button', { name: 'Scan claude-swap', exact: true }).click();
  await page.evaluate(() => { window.holdSwapImport = true; });
  await section.getByRole('listitem').first().getByRole('button', { name: 'Add', exact: true }).click();
  await expect(section.getByRole('button', { name: 'Adding…', exact: true })).toBeDisabled();
  await expect(section.getByRole('button', { name: 'Add', exact: true })).toBeDisabled();
  expect(await page.evaluate(() => window.swapCalls.filter(x => x.command === 'import_claude_swap_candidate').length)).toBe(1);
  await page.evaluate(() => window.releaseSwapImport());
  await expect(section.getByRole('button', { name: 'Added', exact: true })).toBeDisabled();
  await page.evaluate(() => { window.holdSwapScan = true; });
  await section.getByRole('button', { name: 'Rescan claude-swap', exact: true }).click();
  await page.waitForFunction(() => typeof window.releaseSwapScan === 'function');
  await page.evaluate(() => window.swapHarness.remount());
  await expect(section.getByRole('button', { name: 'Scan claude-swap', exact: true })).toBeVisible();
  await page.evaluate(() => window.releaseSwapScan());
  await expect(section.getByRole('button', { name: 'Scan claude-swap', exact: true })).toBeVisible();
  await expect(section.getByRole('listitem')).toHaveCount(0);
  await page.evaluate(() => window.swapHarness.unmount());
});
