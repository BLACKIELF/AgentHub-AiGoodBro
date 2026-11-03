import { test, expect } from '@playwright/test';
import { installTauriStub } from './tauri-stub.mjs';
import { SYNTHETIC_DASHBOARD, SYNTHETIC_SETTINGS } from './synthetic-fixtures.mjs';
async function open(page) {
  await installTauriStub(page, { settings: { ...SYNTHETIC_SETTINGS, language: 'en' }, dashboard: SYNTHETIC_DASHBOARD }, () => {
    const original = window.__TAURI_INTERNALS__.invoke; window.manualTextCalls = [];
    window.__TAURI_INTERNALS__.invoke = async (command, args) => {
      if (command === 'send_personal_wechat_text') {
        window.manualTextCalls.push(structuredClone(args));
        const receipt = { requestId: args.requestId, revision: args.expectedRevision, state: window.manualOutcome ?? 'accepted', checkedAt: 1800000000, failureCode: null };
        if (window.manualHold) return new Promise(resolve => { window.releaseManual = () => resolve(receipt); });
        if (window.manualThrow) throw 'synthetic/path/secret';
        return receipt;
      }
      return original(command, args);
    };
  });
  await page.goto('/');
  await page.evaluate(async () => {
    document.getElementById('root').hidden = true;
    const element = document.createElement('div'); element.id = 'manual-text-fixture'; document.body.append(element);
    const { mountPersonalText } = await import('/tests/visual/personal-wechat-text-component.fixture.tsx');
    window.manualHarness = mountPersonalText(element, { channel: 'personal-wechat', enabled: true, phase: 'ready', revision: 7, credentialPresent: true, targetPresent: true, lastAcceptedAt: null, failureCode: null, options: {} });
  });
  const panel = page.locator('#manual-text-fixture'); await panel.locator('summary').click(); return panel;
}
test('manual send requires explicit click and usable binding, keeps original body and API-only receipt', async ({ page }) => {
  const panel = await open(page), input = panel.getByRole('textbox'), send = panel.getByRole('button', { name: 'Send to paired WeChat', exact: true });
  expect(await page.evaluate(() => window.manualTextCalls)).toEqual([]); await expect(send).toBeDisabled();
  await input.fill('  first\n\tsecond  '); await page.evaluate(() => window.manualHarness.update({ phase: 'context_required' })); await expect(send).toBeDisabled();
  await page.evaluate(() => window.manualHarness.update({ phase: 'ready' })); await send.click();
  await expect(panel.getByRole('status')).toContainText('API accepted'); await expect(panel.getByRole('status')).toContainText('receipt and reading are unconfirmed'); await expect(input).toHaveValue('');
  const calls = await page.evaluate(() => window.manualTextCalls); expect(calls).toHaveLength(1); expect(calls[0]).toMatchObject({ text: '  first\n\tsecond  ', expectedRevision: 7, confirmed: true }); expect(calls[0].requestId).toMatch(/^[a-f0-9]{32}$/);
});
test('UTF8/footer limit is enforced and uncertain or lost replies retain draft without duplicate sending', async ({ page }) => {
  const panel = await open(page), input = panel.getByRole('textbox'), send = panel.getByRole('button', { name: 'Send to paired WeChat', exact: true });
  await input.fill('中'.repeat(1361)); await expect(send).toBeDisabled(); await expect(panel).toContainText('4098 / 4096 bytes');
  await input.fill('uncertain body'); await page.evaluate(() => { window.manualOutcome = 'uncertain'; }); await send.click();
  await expect(panel.getByRole('status')).toContainText('No automatic retry'); await expect(input).toHaveValue('uncertain body'); await expect(send).toBeDisabled(); expect(await page.evaluate(() => window.manualTextCalls.length)).toBe(1);
  await page.evaluate(() => window.manualHarness.update({ revision: 8 })); await expect(send).toBeDisabled();
  await input.fill('different explicit message'); await page.evaluate(() => { window.manualThrow = true; }); await send.click(); await expect(panel.getByRole('alert')).toBeVisible(); await expect(panel).not.toContainText('synthetic/path/secret'); await expect(send).toBeDisabled(); expect(await page.evaluate(() => window.manualTextCalls.length)).toBe(2);
});
test('single flight prevents duplicates and a late old-binding success cannot clear a current draft', async ({ page }) => {
  const panel = await open(page), input = panel.getByRole('textbox'); await input.fill('retain across binding change');
  await page.evaluate(() => { window.manualHold = true; }); await panel.getByRole('button', { name: 'Send to paired WeChat', exact: true }).click();
  await expect(panel.getByRole('button', { name: 'Sending…', exact: true })).toBeDisabled();
  await page.evaluate(() => window.manualHarness.update({ revision: 8 })); await page.evaluate(() => window.releaseManual());
  await expect(input).toHaveValue('retain across binding change'); await expect(panel.getByRole('status')).toContainText('No automatic retry'); await expect(panel.getByRole('button', { name: 'Send to paired WeChat', exact: true })).toBeDisabled(); expect(await page.evaluate(() => window.manualTextCalls.length)).toBe(1);
});
test('the real settings personal-WeChat card exposes manual send and refreshes through its controller', async ({ page }) => {
  await installTauriStub(page, { settings: { ...SYNTHETIC_SETTINGS, language: 'en' }, dashboard: SYNTHETIC_DASHBOARD, windowLabel: 'settings' }, () => {
    const original = window.__TAURI_INTERNALS__.invoke; window.integratedTextCalls = [];
    const options = { includesAgentName: false, includesAccountLabel: true, includesQuotas: true, includesResetTimes: true, includesResetCredits: true, resetExpiryDetail: 'nearest', notifiesFiveHourReset: true, notifiesSevenDayReset: true };
    const rows = ['feishu', 'telegram', 'wechat', 'personal-wechat'].map(channel => ({ channel, enabled: channel === 'personal-wechat', phase: channel === 'personal-wechat' ? 'pending_verification' : 'disabled', revision: 7, credentialPresent: channel === 'personal-wechat', targetPresent: channel === 'personal-wechat', lastAcceptedAt: null, failureCode: null, options }));
    window.__TAURI_INTERNALS__.invoke = async (command, args) => {
      if (['get_notification_channels', 'restore_notification_channels'].includes(command)) return structuredClone(rows);
      if (command === 'get_personal_wechat_login') return null;
      if (command === 'send_personal_wechat_text') { window.integratedTextCalls.push(structuredClone(args)); return { requestId: args.requestId, revision: args.expectedRevision, state: 'accepted', checkedAt: 1800000000, failureCode: null }; }
      return original(command, args);
    };
  });
  await page.goto('/'); const settings = page.locator('.notification-settings'); await settings.locator(':scope > summary').click();
  const card = page.getByTestId('notification-personal-wechat'); await card.getByText('Send WeChat text', { exact: true }).click();
  const input = card.getByRole('textbox', { name: 'WeChat message text', exact: true }); await input.fill('explicit integrated send');
  expect(await page.evaluate(() => window.integratedTextCalls)).toEqual([]);
  await card.getByRole('button', { name: 'Send to paired WeChat', exact: true }).click();
  await expect(card.getByRole('status')).toContainText('API accepted'); await expect(input).toHaveValue(''); expect(await page.evaluate(() => window.integratedTextCalls.length)).toBe(1);
});
