import { test, expect } from '@playwright/test';
import { FIXED_NOW_ISO, SYNTHETIC_DASHBOARD, SYNTHETIC_SETTINGS } from './synthetic-fixtures.mjs';
import { installTauriStub } from './tauri-stub.mjs';
async function setup(page) {
  await page.clock.setFixedTime(new Date(FIXED_NOW_ISO));
  await installTauriStub(page, { settings: { ...SYNTHETIC_SETTINGS, language: 'en' }, dashboard: SYNTHETIC_DASHBOARD }, () => {
    const original = window.__TAURI_INTERNALS__.invoke;
    window.registrationCalls = []; window.registrationMode = 'hold';
    window.registrationAccount = { id: 'a'.repeat(32), label: 'Registration fixture', platform: 'codex', storage_kind: 'managed', login_state: 'verified', active_state: 'unknown', masked_identity: 'r***@example.invalid', plan_type: 'plus', can_login: true, can_switch: false, switch_block_reason: 'system_busy', revision: 1, recovery_required: false, registration_pending: true };
    window.__TAURI_INTERNALS__.invoke = async (command, args) => {
      if (command === 'list_managed_accounts') return [structuredClone(window.registrationAccount)];
      if (command === 'register_managed_account') {
        window.registrationCalls.push({ command, ...args });
        if (window.registrationMode === 'failure') throw 'registration_persistence_failed';
        if (window.registrationMode === 'wrong') return { accountId: 'b'.repeat(32), status: 'registered', profileId: '2' };
        return new Promise(resolve => { window.finishRegistration = () => { window.registrationAccount.registration_pending = false; resolve({ accountId: args.accountId, status: 'registered', profileId: '2' }); }; });
      }
      if (command === 'set_local_proxy_preferences' || command === 'begin_account_login' || command === 'prepare_account_switch') { window.registrationCalls.push({ command, ...args }); throw 'unexpected_action'; }
      return original(command, args);
    };
  });
  await page.goto('/');
  await page.getByRole('navigation').getByRole('button', { name: 'Accounts', exact: true }).click();
  return page.getByTestId('managed-account-' + 'a'.repeat(32));
}
async function open(row) { await row.getByLabel('More actions for Registration fixture', { exact: true }).click(); }
test('managed registration is explicit, one in flight, and does not toggle proxy or switch', async ({ page }) => {
  const row = await setup(page);
  await expect(row).toContainText('Home and Tasks registration is pending');
  expect(await page.evaluate(() => window.registrationCalls)).toEqual([]);
  await open(row); await row.getByRole('button', { name: 'Retry Home and Tasks registration', exact: true }).click();
  await expect.poll(() => page.evaluate(() => window.registrationCalls.length)).toBe(1);
  await expect(row.getByLabel('More actions for Registration fixture')).toHaveAttribute('aria-disabled', 'true');
  await page.evaluate(() => window.finishRegistration());
  await expect(page.getByRole('region', { name: 'Managed accounts', exact: true })).toContainText('Registered for Home and Tasks.');
  await expect(row).not.toContainText('registration is pending');
  expect(await page.evaluate(() => window.registrationCalls.map(row => row.command))).toEqual(['register_managed_account']);
});
test('registration failure or wrong identity never reports success or clears pending', async ({ page }) => {
  const row = await setup(page);
  for (const mode of ['failure', 'wrong']) {
    await page.evaluate(mode => { window.registrationMode = mode; }, mode);
    await open(row); await row.getByRole('button', { name: 'Retry Home and Tasks registration', exact: true }).click();
    await expect(page.getByRole('region', { name: 'Managed accounts', exact: true }).getByRole('alert')).toBeVisible();
    await expect(row).toContainText('Home and Tasks registration is pending');
    await expect(page.getByRole('region', { name: 'Managed accounts', exact: true })).not.toContainText('Registered for Home and Tasks.');
  }
  expect(await page.evaluate(() => window.registrationCalls.length)).toBe(2);
});
