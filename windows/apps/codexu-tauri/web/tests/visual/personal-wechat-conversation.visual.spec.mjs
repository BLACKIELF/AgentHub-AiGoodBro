import { test, expect } from '@playwright/test';
import { installTauriStub } from './tauri-stub.mjs';
import { SYNTHETIC_DASHBOARD, SYNTHETIC_SETTINGS } from './synthetic-fixtures.mjs';

const scopeId = 'a'.repeat(64);
const threadId = '123e4567-e89b-42d3-a456-426614174000';
const options = { includesAgentName: false, includesAccountLabel: true, includesQuotas: true, includesResetTimes: true, includesResetCredits: true, resetExpiryDetail: 'nearest', notifiesFiveHourReset: true, notifiesSevenDayReset: true };
const channels = ['feishu', 'telegram', 'wechat', 'personal-wechat'].map(channel => ({
  channel,
  enabled: channel === 'personal-wechat',
  phase: channel === 'personal-wechat' ? 'pending_verification' : 'disabled',
  revision: 1,
  credentialPresent: channel === 'personal-wechat',
  targetPresent: channel === 'personal-wechat',
  lastAcceptedAt: null,
  failureCode: null,
  options,
}));
const workbench = {
  scopeId,
  checkedAtMs: 1_800_000_000_000,
  sourceAvailable: true,
  truncated: false,
  items: [{
    threadId,
    title: 'Synthetic original chat',
    project: 'Local project',
    updatedAtMs: 1_800_000_000_000,
    archived: false,
    executionState: 'recorded',
    outcome: 'incomplete',
    decision: 'none',
    decisionAtMs: null,
    inventoryIsStale: false,
    needsAttention: false,
    inventory: null,
  }],
};

test('N02 consent selects an existing local chat and does not send before confirmation', async ({ page }) => {
  await page.clock.setFixedTime(new Date('2026-11-02T02:00:00Z'));
  await page.route('**/*', route => new URL(route.request().url()).hostname === '127.0.0.1' ? route.continue() : route.abort());
  const customize = new Function(`
    const base = window.__TAURI_INTERNALS__.invoke;
    window.n02Calls = [];
    window.n02Listeners = [];
    window.n02HeldReads = [];
    window.n02Conversation = { binding: null, revision: 1, enabled: false, phase: 'unbound', needsConfirmation: false };
    window.__TAURI_INTERNALS__.invoke = async (command, args = {}) => {
      window.n02Calls.push({ command, args: structuredClone(args) });
      if (command === 'plugin:event|listen' && args.event === 'notification-channels:changed') window.n02Listeners.push(args.handler);
      if (command === 'get_notification_channels') return structuredClone(${JSON.stringify(channels)});
      if (command === 'get_personal_wechat_conversation_state') {
        const value = structuredClone(window.n02Conversation);
        if (window.n02HoldReads) return new Promise(resolve => window.n02HeldReads.push(() => resolve(value)));
        return value;
      }
      if (command === 'get_task_workbench') return structuredClone(${JSON.stringify(workbench)});
      if (command === 'bind_personal_wechat_conversation') {
        window.n02Conversation = { binding: { expectedScopeId: args.expectedScopeId, threadId: args.threadId }, revision: window.n02Conversation.revision + 2, enabled: true, phase: 'enabled', needsConfirmation: false };
        return structuredClone(window.n02Conversation);
      }
      return base(command, args);
    };
  `);
  await installTauriStub(page, { settings: { ...SYNTHETIC_SETTINGS, language: 'en', theme: 'dark' }, dashboard: SYNTHETIC_DASHBOARD, windowLabel: 'settings' }, customize);
  await page.goto('/');
  const notifications = page.getByText('Message notifications', { exact: true });
  await notifications.click();
  const consent = page.getByTestId('personal-wechat-conversation');
  await expect(consent).toBeVisible();
  await consent.locator(':scope > summary').click();
  await consent.getByRole('button', { name: 'Read local chats', exact: true }).click();
  await consent.getByRole('combobox', { name: 'Select original chat' }).selectOption(threadId);
  await consent.getByRole('checkbox').check();
  const confirm = consent.getByRole('button', { name: 'Confirm and enable', exact: true });
  await expect(confirm).toBeEnabled();
  expect(await page.evaluate(() => window.n02Calls.some(call => ['bind_personal_wechat_conversation', 'set_personal_wechat_conversation_enabled', 'unbind_personal_wechat_conversation', 'send_personal_wechat_text'].includes(call.command)))).toBe(false);
  await expect(consent).toHaveScreenshot('personal-wechat-consent-ready.png');

  // A changed binding/credential revision needs fresh consent; an old checked
  // box cannot silently authorize the new recipient configuration.
  await page.evaluate(() => {
    window.n02Conversation.revision = 2;
    for (const handler of window.n02Listeners) window[`_${handler}`]?.({ event: 'notification-channels:changed', payload: null });
  });
  await expect(consent.getByRole('checkbox')).not.toBeChecked();
  await expect(confirm).toBeDisabled();
  await consent.getByRole('checkbox').check();
  // An older delayed status read must not overwrite the explicit save result.
  await page.evaluate(() => {
    window.n02HoldReads = true;
    for (const handler of window.n02Listeners) window[`_${handler}`]?.({ event: 'notification-channels:changed', payload: null });
  });
  await expect.poll(() => page.evaluate(() => window.n02HeldReads.length)).toBeGreaterThan(0);

  await confirm.click();
  await expect(consent.getByTestId('personal-wechat-bound-thread')).toContainText('Synthetic original chat');
  await page.evaluate(() => { window.n02HoldReads = false; window.n02HeldReads.splice(0).forEach(resolve => resolve()); });
  await expect(consent.getByRole('button', { name: 'Pause auto replies', exact: true })).toBeVisible();
  expect(await page.evaluate(() => window.n02Calls.filter(call => call.command === 'bind_personal_wechat_conversation').at(-1).args)).toEqual({ expectedRevision: 2, expectedScopeId: scopeId, threadId, confirmed: true });
  expect(await page.evaluate(() => window.n02Calls.some(call => call.command === 'send_personal_wechat_text'))).toBe(false);
});
