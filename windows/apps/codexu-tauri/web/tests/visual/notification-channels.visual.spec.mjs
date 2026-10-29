import { test, expect } from '@playwright/test';
import path from 'node:path';
import { FIXED_NOW_ISO, SYNTHETIC_DASHBOARD, SYNTHETIC_SETTINGS } from './synthetic-fixtures.mjs';
import { installTauriStub } from './tauri-stub.mjs';

const artifactRoot = process.env.CODEXU_VISUAL_ARTIFACT_ROOT || path.resolve('.local-artifacts/visual');
const evidence = (name) => path.join(artifactRoot, 'notifications', name);
const card = (page, kind) => page.getByTestId(`notification-${kind}`);
const panel = (page) => page.locator('.notification-settings');
async function settings(page, { language = 'en', theme = 'dark', open = true } = {}) {
  await page.clock.setFixedTime(new Date(FIXED_NOW_ISO));
  await page.route('**/*', route => new URL(route.request().url()).hostname === '127.0.0.1' ? route.continue() : route.abort());
  await installTauriStub(page, { settings: { ...SYNTHETIC_SETTINGS, language, theme }, dashboard: SYNTHETIC_DASHBOARD, windowLabel: 'settings' }, () => {
    const native = window.__TAURI_INTERNALS__.invoke;
    const clone = value => structuredClone(value);
    const kinds = ['feishu', 'telegram', 'wechat', 'personal-wechat'];
    const options = { includesAgentName: false, includesAccountLabel: true, includesQuotas: true, includesResetTimes: true, includesResetCredits: true, resetExpiryDetail: 'nearest', notifiesFiveHourReset: true, notifiesSevenDayReset: true };
    window.notificationRows = kinds.map(channel => ({ channel, enabled: false, phase: 'disabled', revision: 1, credentialPresent: false, targetPresent: false, lastAcceptedAt: null, failureCode: null, options: clone(options) }));
    window.notificationCalls = [];
    window.notificationReads = 0;
    window.notificationLogin = null;
    window.notificationHeld = {};
    window.notificationFailures = {};
    window.notificationHold = {};
    let listener;
    window.notificationEmit = () => { if (listener) window[`_${listener}`]({ event: 'notification-channels:changed', id: 777, payload: null }); };
    window.notificationConfigure = (kind, patch) => { Object.assign(window.notificationRows.find(row => row.channel === kind), patch); };
    const response = (command, value) => window.notificationHold[command] ? new Promise((resolve, reject) => { (window.notificationHeld[command] ||= []).push({ resolve: () => resolve(clone(value)), reject: () => reject(Error('transport_failed')) }); }) : clone(value);
    window.__TAURI_INTERNALS__.invoke = async (command, args) => {
      if (command === 'plugin:event|listen' && args.event === 'notification-channels:changed') { listener = args.handler; return 777; }
      if (command === 'get_notification_channels' || command === 'restore_notification_channels') {
        window.notificationReads++;
        if (window.notificationFailures[command]) throw Error(window.notificationFailures[command]);
        return response(command, window.notificationRows);
      }
      if (command.includes('notification_channel') || command.includes('personal_wechat')) {
        window.notificationCalls.push({ command, args: clone(args || {}) });
        if (window.notificationFailures[command]) throw Error(window.notificationFailures[command]);
        const row = window.notificationRows.find(value => value.channel === args?.channel);
        if (command === 'set_notification_channel_enabled') { row.enabled = args.enabled; row.revision++; row.phase = !row.enabled ? 'disabled' : row.credentialPresent ? 'pending_verification' : 'needs_setup'; return response(command, row); }
        if (command === 'save_notification_channel') { row.credentialPresent = true; row.targetPresent = args.channel === 'telegram'; row.revision++; row.phase = row.enabled ? 'pending_verification' : 'disabled'; return response(command, row); }
        if (command === 'set_notification_channel_options') {
          for (const value of window.notificationRows.filter(value => ['wechat', 'personal-wechat'].includes(args.channel) ? ['wechat', 'personal-wechat'].includes(value.channel) : value.channel === args.channel)) { value.options = clone(args.options); value.revision++; }
          return response(command, row);
        }
        if (command === 'forget_notification_channel') { Object.assign(row, { enabled: false, phase: 'disabled', credentialPresent: false, targetPresent: false, lastAcceptedAt: null, failureCode: null, revision: row.revision + 1 }); return response(command, row); }
        if (command === 'cancel_notification_channel') {
          if (args.channel === 'personal-wechat' && window.notificationLogin) window.notificationLogin = { ...window.notificationLogin, phase: 'cancelled', qrContent: null };
          return response(command, row);
        }
        if (command === 'test_notification_channel') {
          const state = window.notificationTestState || 'accepted';
          if (state === 'accepted' && !window.notificationHold[command]) { row.phase = 'ready'; row.lastAcceptedAt = Math.floor(Date.now() / 1000); }
          return response(command, { channel: args.channel, eventId: 'a'.repeat(64), state, checkedAt: Math.floor(Date.now() / 1000), remoteMessageId: state === 'accepted' ? 'synthetic-receipt' : null, failureCode: state === 'rejected' ? 'rejected' : state === 'uncertain' ? 'transport_failed' : null });
        }
        if (command === 'begin_personal_wechat_login') {
          window.notificationLogin = { attemptId: `synthetic-${window.notificationCalls.length}`, phase: window.notificationBeginPhase || 'waiting', qrContent: 'SYNTHETIC_QR_ONLY_NOT_A_LOGIN', expiresAt: Math.floor(Date.now() / 1000) + (window.notificationExpiresIn || 300) };
          return response(command, window.notificationLogin);
        }
        if (command === 'get_personal_wechat_login' || command === 'poll_personal_wechat_login') {
          const value = window.notificationPollResult || window.notificationLogin;
          window.notificationLogin = clone(value);
          return response(command, value);
        }
        if (command === 'refresh_personal_wechat_context') {
          const current = window.notificationRows.find(value => value.channel === 'personal-wechat');
          current.phase = 'pending_verification'; current.targetPresent = true; return response(command, current);
        }
        throw Error('notification_invalid_response');
      }
      return native(command, args);
    };
  });
  await page.goto('/');
  await expect(panel(page)).toBeVisible();
  if (open) { await panel(page).locator(':scope > summary').click(); await expect(card(page, 'feishu')).toBeVisible(); }
}
async function configured(page, kind = 'feishu') {
  await page.evaluate(kind => { window.notificationConfigure(kind, { enabled: true, phase: 'pending_verification', credentialPresent: true, targetPresent: ['telegram', 'personal-wechat'].includes(kind) }); window.notificationEmit(); }, kind);
  await expect(card(page, kind).getByRole('button', { name: 'Send test message', exact: true })).toBeEnabled();
}
async function startPersonal(page) {
  await page.evaluate(() => { window.notificationConfigure('personal-wechat', { enabled: true, phase: 'needs_setup' }); window.notificationEmit(); });
  const personal = card(page, 'personal-wechat');
  await personal.getByRole('button', { name: 'Connect with QR', exact: true }).click();
  await expect(personal.getByRole('img', { name: 'WeChat connection QR' })).toBeVisible();
  return personal;
}

test('four compact channels stay ordered, disabled until opt-in; no unfinished capabilities appear', async ({ page }) => {
  await settings(page);
  expect(await panel(page).locator('.notification-channel').evaluateAll(nodes => nodes.map(node => node.dataset.testid))).toEqual(['notification-feishu', 'notification-telegram', 'notification-wechat', 'notification-personal-wechat']);
  for (const kind of ['feishu', 'telegram', 'wechat', 'personal-wechat']) await expect(card(page, kind).getByRole('button', { name: 'Send test message', exact: true })).toBeDisabled();
  await expect(panel(page).getByText('WeChat notification content and alerts', { exact: true })).toHaveCount(1);
  await expect(card(page, 'telegram').getByText('Message content and alerts', { exact: true })).toHaveCount(0);
  await expect(panel(page).locator('textarea')).toHaveCount(0);
  await expect(panel(page)).not.toContainText('Task completed');
  await panel(page).screenshot({ path: evidence('notifications-en-dark.png') });
});

test('save failure preserves a password draft; save does not enable or claim acceptance', async ({ page }) => {
  await settings(page);
  const feishu = card(page, 'feishu');
  await feishu.getByText('Set up credential', { exact: true }).click();
  const input = feishu.getByLabel('Bot webhook', { exact: true });
  await input.fill('synthetic-secret-not-a-real-webhook');
  await page.evaluate(() => { window.notificationFailures.save_notification_channel = 'invalid_credential'; });
  await feishu.getByRole('button', { name: 'Save credential', exact: true }).click();
  await expect(feishu.getByRole('alert')).toContainText('Your input has been kept');
  await expect(input).toHaveValue('synthetic-secret-not-a-real-webhook');
  await expect(input).toHaveAttribute('type', 'password');
  await page.evaluate(() => { delete window.notificationFailures.save_notification_channel; });
  await feishu.getByRole('button', { name: 'Save credential', exact: true }).click();
  await expect(input).toHaveValue('');
  await expect(feishu).toContainText('Credential saved locally');
  await expect(feishu.getByRole('button', { name: 'Enable', exact: true })).toHaveAttribute('aria-pressed', 'false');
  await expect(feishu.getByRole('button', { name: 'Send test message', exact: true })).toBeDisabled();
  expect(await page.evaluate(() => window.notificationCalls.map(value => value.command))).toEqual(['save_notification_channel', 'save_notification_channel']);
  await feishu.getByRole('button', { name: 'Enable', exact: true }).click();
  await expect(feishu.getByRole('button', { name: 'Enabled', exact: true })).toHaveClass(/is-enabled/);
  await expect(feishu.getByRole('button', { name: 'Send test message', exact: true })).toBeEnabled();
});

test('API accepted, rejected, uncertain, skipped and unsent receipts remain distinct; no automatic resend', async ({ page }) => {
  await settings(page); await configured(page);
  const feishu = card(page, 'feishu');
  for (const [state, label] of [['accepted', 'delivery and reading are unconfirmed'], ['rejected', 'The API rejected this test'], ['uncertain', 'no automatic retry will occur'], ['duplicate_skipped', 'No additional message was sent'], ['not_sent', 'This test was not sent']]) {
    await page.evaluate(state => { window.notificationTestState = state; }, state);
    await feishu.getByRole('button', { name: 'Send test message', exact: true }).click();
    await expect(feishu.locator('.notification-receipt')).toContainText(label);
    await expect(feishu.locator('.notification-receipt')).toHaveClass(new RegExp(`is-${state}`));
    if (state === 'accepted') await feishu.screenshot({ path: evidence('notifications-api-accepted.png') });
    if (state === 'uncertain') await feishu.screenshot({ path: evidence('notifications-uncertain.png') });
  }
  await page.waitForTimeout(2100);
  expect(await page.evaluate(() => window.notificationCalls.filter(value => value.command === 'test_notification_channel').length)).toBe(5);
  await feishu.screenshot({ path: evidence('notifications-unsent.png') });
});

test('disabling while a test is pending fences a late API acceptance', async ({ page }) => {
  await settings(page); await configured(page);
  const feishu = card(page, 'feishu');
  await page.evaluate(() => { window.notificationHold.test_notification_channel = true; });
  await feishu.getByRole('button', { name: 'Send test message', exact: true }).click();
  await expect.poll(() => page.evaluate(() => window.notificationHeld.test_notification_channel?.length)).toBe(1);
  await feishu.getByRole('button', { name: 'Enabled', exact: true }).click();
  await expect(feishu.getByRole('button', { name: 'Enable', exact: true })).toHaveAttribute('aria-pressed', 'false');
  await page.evaluate(() => window.notificationHeld.test_notification_channel[0].resolve());
  await expect(feishu.locator('.notification-receipt')).toHaveCount(0);
  await expect(feishu.locator('.notification-phase')).toHaveText('Disabled');
});

test('event readback beats a late earlier state and read saved configuration does not test', async ({ page }) => {
  await settings(page);
  await page.evaluate(() => { window.notificationHold.get_notification_channels = true; });
  await panel(page).getByRole('button', { name: 'Read notification status', exact: true }).click();
  await expect.poll(() => page.evaluate(() => window.notificationHeld.get_notification_channels?.length)).toBe(1);
  await page.evaluate(() => { delete window.notificationHold.get_notification_channels; window.notificationConfigure('feishu', { enabled: true, phase: 'needs_setup', revision: 2 }); window.notificationEmit(); });
  await expect(card(page, 'feishu').getByRole('button', { name: 'Enabled', exact: true })).toBeVisible();
  await page.evaluate(() => window.notificationHeld.get_notification_channels[0].resolve());
  await expect(card(page, 'feishu').getByRole('button', { name: 'Enabled', exact: true })).toBeVisible();
  await panel(page).getByRole('button', { name: 'Read saved configuration', exact: true }).click();
  await expect(panel(page)).toContainText('Saved configuration was read again');
  expect(await page.evaluate(() => window.notificationCalls)).toEqual([]);
});

test('WeChat shared presets preserve reset opt-outs; failed save keeps draft and successful save reads both channels', async ({ page }) => {
  await settings(page);
  await page.evaluate(() => { for (const kind of ['wechat', 'personal-wechat']) { const row = window.notificationRows.find(value => value.channel === kind); row.options.notifiesFiveHourReset = false; } window.notificationEmit(); });
  const editor = page.getByTestId('notification-options-shared-wechat');
  await editor.locator(':scope > summary').click();
  await editor.getByRole('button', { name: 'Compact', exact: true }).click();
  await expect(editor.getByLabel('5-hour window reset alerts', { exact: true })).not.toBeChecked();
  await expect(editor.getByLabel('7-day window reset alerts', { exact: true })).toBeChecked();
  await page.evaluate(() => { window.notificationFailures.set_notification_channel_options = 'notification_store_unavailable'; });
  await editor.getByRole('button', { name: 'Save content options', exact: true }).click();
  await expect(card(page, 'wechat').getByRole('alert')).toContainText('configuration is unavailable');
  await expect(editor.getByRole('button', { name: 'Compact', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await expect(editor.getByText('Content options saved', { exact: true })).toHaveCount(0);
  await page.evaluate(() => { delete window.notificationFailures.set_notification_channel_options; });
  await editor.getByRole('button', { name: 'Save content options', exact: true }).click();
  await expect(editor.getByText('Content options saved', { exact: true })).toBeVisible();
  expect(await page.evaluate(() => window.notificationRows.filter(value => ['wechat', 'personal-wechat'].includes(value.channel)).map(value => ({ enabled: value.enabled, options: value.options })))).toEqual(Array.from({ length: 2 }, () => ({ enabled: false, options: { includesAgentName: false, includesAccountLabel: true, includesQuotas: false, includesResetTimes: false, includesResetCredits: true, resetExpiryDetail: 'none', notifiesFiveHourReset: false, notifiesSevenDayReset: true } })));
  await editor.screenshot({ path: evidence('notifications-shared-options.png') });
});

test('forget requires a concrete confirmation and only native success clears the saved binding', async ({ page }) => {
  await settings(page); await configured(page, 'telegram');
  const telegram = card(page, 'telegram');
  await telegram.getByLabel('More channel actions', { exact: true }).click();
  await telegram.getByRole('button', { name: 'Remove saved credential', exact: true }).click();
  const dialog = telegram.getByRole('dialog');
  await expect(dialog).toBeVisible();
  expect(await page.evaluate(() => window.notificationCalls)).toEqual([]);
  await dialog.getByRole('button', { name: 'Keep configuration', exact: true }).click();
  await expect(dialog).not.toBeVisible();
  await telegram.getByRole('button', { name: 'Remove saved credential', exact: true }).click();
  await page.evaluate(() => { window.notificationFailures.forget_notification_channel = 'notification_store_unavailable'; });
  await dialog.getByRole('button', { name: 'Remove', exact: true }).click();
  await expect(dialog).toBeVisible();
  await expect(telegram).toContainText('Credential saved locally');
  await page.evaluate(() => { delete window.notificationFailures.forget_notification_channel; });
  await dialog.getByRole('button', { name: 'Remove', exact: true }).click();
  await expect(dialog).not.toBeVisible();
  await expect(telegram).toContainText('No saved credential');
  await expect(telegram.getByRole('button', { name: 'Enable', exact: true })).toBeVisible();
});

test('QR is rendered locally without requests or persisted pairing content; closing cancels the owned attempt', async ({ page }) => {
  const requests = []; page.on('request', request => requests.push(request.url()));
  await settings(page); const personal = await startPersonal(page);
  await expect(personal.locator('svg[role=img] path')).toHaveAttribute('d', /^M/);
  await expect(personal.locator('img, canvas, iframe')).toHaveCount(0);
  await expect(personal).not.toContainText('SYNTHETIC_QR_ONLY_NOT_A_LOGIN');
  await personal.getByRole('img', { name: 'WeChat connection QR' }).screenshot({ path: evidence('synthetic-pairing-qr.png') });
  expect(await page.evaluate(() => JSON.stringify({ local: { ...localStorage }, session: { ...sessionStorage } }))).not.toContain('SYNTHETIC_QR_ONLY_NOT_A_LOGIN');
  expect(requests.every(url => new URL(url).hostname === '127.0.0.1')).toBe(true);
  await panel(page).locator(':scope > summary').click();
  await expect.poll(() => page.evaluate(() => window.notificationCalls.filter(value => value.command === 'cancel_notification_channel').length)).toBe(1);
  await expect(personal).toHaveCount(0);
});

test('a pending begin can be cancelled and its late QR can never reappear', async ({ page }) => {
  await settings(page);
  await page.evaluate(() => { window.notificationConfigure('personal-wechat', { enabled: true, phase: 'needs_setup' }); window.notificationHold.begin_personal_wechat_login = true; window.notificationEmit(); });
  const personal = card(page, 'personal-wechat');
  await personal.getByRole('button', { name: 'Connect with QR', exact: true }).click();
  await expect.poll(() => page.evaluate(() => window.notificationHeld.begin_personal_wechat_login?.length)).toBe(1);
  await personal.getByRole('button', { name: 'Cancel pairing', exact: true }).click();
  await page.evaluate(() => window.notificationHeld.begin_personal_wechat_login[0].resolve());
  await expect(personal.getByRole('img', { name: 'WeChat connection QR', exact: true })).toHaveCount(0);
  await expect(personal.getByRole('button', { name: 'Connect with QR', exact: true })).toBeEnabled();
});

test('cancel failure hides QR but blocks reuse; a late poll cannot confirm, retry acknowledges cancellation', async ({ page }) => {
  await settings(page); const personal = await startPersonal(page);
  await page.evaluate(() => { window.notificationHold.poll_personal_wechat_login = true; window.notificationPollResult = { ...window.notificationLogin, phase: 'confirmed', qrContent: null }; });
  await expect.poll(() => page.evaluate(() => window.notificationHeld.poll_personal_wechat_login?.length), { timeout: 5000 }).toBe(1);
  await page.evaluate(() => { window.notificationFailures.cancel_notification_channel = 'transport_failed'; });
  await personal.getByRole('button', { name: 'Cancel pairing', exact: true }).click();
  await expect(personal).toContainText('Cancellation is unconfirmed');
  await expect(personal.getByRole('img', { name: 'WeChat connection QR', exact: true })).toHaveCount(0);
  await expect(personal.getByRole('button', { name: 'Connect with QR', exact: true })).toBeDisabled();
  await page.evaluate(() => window.notificationHeld.poll_personal_wechat_login[0].resolve());
  await expect(personal).not.toContainText('QR pairing was saved');
  await page.evaluate(() => { delete window.notificationFailures.cancel_notification_channel; });
  await personal.getByRole('button', { name: 'Cancel pairing', exact: true }).click();
  await expect(personal).toContainText('Pairing was cancelled');
  await expect(personal.getByRole('button', { name: 'Connect with QR', exact: true })).toBeEnabled();
});

test('verification waits for explicit bounded code, clears it on confirmed binding and refreshes real context separately', async ({ page }) => {
  await settings(page);
  await page.evaluate(() => { window.notificationBeginPhase = 'verification_required'; });
  const personal = await startPersonal(page);
  const input = personal.getByLabel('Pairing code shown on your phone', { exact: true });
  await input.fill('abcd');
  await expect(personal.getByRole('button', { name: 'Confirm pairing code', exact: true })).toBeDisabled();
  await page.waitForTimeout(2100);
  expect(await page.evaluate(() => window.notificationCalls.filter(value => value.command === 'poll_personal_wechat_login').length)).toBe(0);
  await input.fill('123456');
  await page.evaluate(() => { window.notificationPollResult = { ...window.notificationLogin, phase: 'confirmed', qrContent: null }; window.notificationConfigure('personal-wechat', { enabled: true, credentialPresent: true, targetPresent: false, phase: 'context_required' }); });
  await personal.getByRole('button', { name: 'Confirm pairing code', exact: true }).click();
  await expect(input).toHaveCount(0);
  await expect(personal).toContainText('QR pairing was saved');
  await expect(personal).toContainText('Send a message to the paired bot');
  await expect(personal.getByRole('button', { name: 'Send test message', exact: true })).toBeDisabled();
  await personal.getByRole('button', { name: 'Check WeChat context', exact: true }).click();
  await expect(personal.getByRole('button', { name: 'Send test message', exact: true })).toBeEnabled();
  expect(await page.evaluate(() => window.notificationCalls.find(value => value.command === 'refresh_personal_wechat_context').args)).toEqual({});
  await personal.screenshot({ path: evidence('notifications-personal-context.png') });
});

test('expired QR disappears and is cancelled, without a fabricated success or automatic new login', async ({ page }) => {
  await settings(page);
  await page.evaluate(() => { window.notificationExpiresIn = 1; });
  const personal = await startPersonal(page);
  await page.clock.setFixedTime(new Date(Date.parse('2026-09-16T03:30:00.000Z') + 5000));
  await expect(personal).toContainText('This pairing attempt timed out', { timeout: 5000 });
  await expect(personal.getByRole('img', { name: 'WeChat connection QR', exact: true })).toHaveCount(0);
  expect(await page.evaluate(() => window.notificationCalls.filter(value => value.command === 'begin_personal_wechat_login').length)).toBe(1);
  await expect(personal).not.toContainText('QR pairing was saved');
});

test('unavailable native state offers no ready channel, credential action or raw provider text', async ({ page }) => {
  await settings(page, { open: false });
  await page.evaluate(() => { window.notificationFailures.get_notification_channels = 'secret://raw-provider-failure'; });
  await panel(page).locator(':scope > summary').click();
  await expect(panel(page).getByRole('alert')).toContainText('Read status again');
  await expect(panel(page)).not.toContainText('raw-provider-failure');
  await expect(panel(page).locator('.notification-channel')).toHaveCount(0);
  await expect(panel(page).getByRole('button', { name: 'Read notification status', exact: true })).toBeEnabled();
});

test('Chinese light narrow layout keeps all four cards and shared options inside the window', async ({ page }) => {
  await page.setViewportSize({ width: 480, height: 900 });
  await settings(page, { language: 'zh-Hans', theme: 'light' });
  await expect(card(page, 'feishu').getByRole('button', { name: '启用', exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: '浅色', exact: true })).toHaveClass(/glass-button-solid/);
  await page.getByTestId('notification-options-shared-wechat').locator(':scope > summary').click();
  for (const kind of ['feishu', 'telegram', 'wechat', 'personal-wechat']) {
    const bounds = await card(page, kind).boundingBox(); expect(bounds.x).toBeGreaterThanOrEqual(0); expect(bounds.x + bounds.width).toBeLessThanOrEqual(480);
  }
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(480);
  await page.setViewportSize({ width: 480, height: 1800 });
  await panel(page).screenshot({ path: evidence('notifications-zh-light-narrow.png') });
});

test('disabling supersedes a held personal cancellation without leaving a stuck cancelling state', async ({ page }) => {
  await settings(page); const personal = await startPersonal(page);
  await page.evaluate(() => { window.notificationHold.cancel_notification_channel = true; });
  await personal.getByRole('button', { name: 'Cancel pairing', exact: true }).click();
  await expect.poll(() => page.evaluate(() => window.notificationHeld.cancel_notification_channel?.length)).toBe(1);
  await personal.getByRole('button', { name: 'Enabled', exact: true }).click();
  await expect(personal.locator('.notification-phase')).toHaveText('Disabled');
  await page.evaluate(() => window.notificationHeld.cancel_notification_channel[0].resolve());
  await personal.getByRole('button', { name: 'Enable', exact: true }).click();
  await expect(personal.getByRole('button', { name: 'Connect with QR', exact: true })).toBeEnabled();
  await expect(personal).not.toContainText('Confirming pairing cancellation');
});

test('failed forget hides the active QR but retains cancellation control and the real saved binding', async ({ page }) => {
  await settings(page); const personal = await startPersonal(page);
  await page.evaluate(() => { window.notificationConfigure('personal-wechat', { credentialPresent: true, targetPresent: true, phase: 'pending_verification', revision: 2 }); window.notificationEmit(); });
  await expect(personal).toContainText('Credential saved locally');
  await personal.getByLabel('More channel actions', { exact: true }).click();
  await personal.getByRole('button', { name: 'Remove WeChat pairing', exact: true }).click();
  await page.evaluate(() => { window.notificationFailures.forget_notification_channel = 'notification_store_unavailable'; });
  await personal.getByRole('dialog').getByRole('button', { name: 'Remove', exact: true }).click();
  await expect(personal).toContainText('configuration is unavailable');
  await personal.getByRole('dialog').getByRole('button', { name: 'Keep configuration', exact: true }).click();
  await expect(personal.getByRole('img', { name: 'WeChat connection QR', exact: true })).toHaveCount(0);
  await expect(personal.getByRole('button', { name: 'Scan again', exact: true })).toBeDisabled();
  await personal.getByRole('button', { name: 'Cancel pairing', exact: true }).click();
  await expect(personal).toContainText('Pairing was cancelled');
  await expect(personal).toContainText('Credential saved locally');
  await expect(personal.getByRole('button', { name: 'Scan again', exact: true })).toBeEnabled();
});
