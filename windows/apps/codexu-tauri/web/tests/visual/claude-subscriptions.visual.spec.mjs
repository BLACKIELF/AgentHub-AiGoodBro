import { test, expect } from '@playwright/test';
import { FIXED_NOW_ISO, SYNTHETIC_DASHBOARD, SYNTHETIC_SETTINGS } from './synthetic-fixtures.mjs';
import { installTauriStub } from './tauri-stub.mjs';

async function claudePage(page, { language = 'en', theme = 'dark' } = {}) {
  await page.clock.setFixedTime(new Date(FIXED_NOW_ISO));
  await installTauriStub(page, { settings: { ...SYNTHETIC_SETTINGS, language, theme }, dashboard: SYNTHETIC_DASHBOARD }, () => {
    const original = window.__TAURI_INTERNALS__.invoke;
    const account = (id, label) => ({ id, label, platform: 'claude', storage_kind: 'managed', login_state: 'verified', active_state: 'unknown', masked_identity: 'c***@synthetic.invalid', plan_type: 'max', can_login: true, can_switch: true, switch_block_reason: null, revision: 1, recovery_required: false });
    const now = Date.now();
    window.claudeRows = [account('claude_a', 'Synthetic Claude A'), account('claude_b', 'Synthetic Claude B')];
    window.claudeCalls = [];
    window.claudeQuota = { state: 'available', fetched_at: now, masked_identity: 'c***@synthetic.invalid', identity_fingerprint: 'a'.repeat(64), plan_label: 'max', windows: [{ id: 'five_hour', label: '5-hour', used_percent: 25, resets_at: now + 3600000 }, { id: 'seven_day', label: '7-day', used_percent: 80, resets_at: now + 86400000 }, { id: 'synthetic_scoped', label: 'Synthetic scoped model', used_percent: 0, resets_at: null }], balance: null, balance_currency: null, source_label: 'Anthropic OAuth usage', message_code: null, period_resets_at: null, server_retry_at: null };
    const listeners = [];
    window.emitClaudeChange = () => listeners.forEach(callback => window[`_${callback}`]({ event: 'claude-subscriptions:changed', id: 381, payload: null }));
    window.advanceClaudeLogin = phase => { window.claudeAttempt = { attempt_id: 'synthetic_claude_attempt_0123456789', phase, error_code: phase === 'failed' ? 'claude_login_attempt_expired' : null }; };
    window.__TAURI_INTERNALS__.invoke = async (command, args) => {
      if (command === 'plugin:event|listen' && args.event === 'claude-subscriptions:changed') { listeners.push(args.handler); return 381; }
      if (command === 'list_claude_subscriptions') { if (window.failClaudeRead) throw 'account_service_unavailable'; return structuredClone(window.claudeRows); }
      if (command === 'rename_claude_subscription' || command === 'remove_claude_subscription') {
        window.claudeCalls.push({ command, ...args });
        if (window.failClaudeEdit) throw window.failClaudeEdit;
        if (command === 'rename_claude_subscription') window.claudeRows.find(row => row.id === args.accountId).label = args.label;
        else window.claudeRows = window.claudeRows.filter(row => row.id !== args.accountId);
        window.emitClaudeChange(); return { account_id: args.accountId, phase: command === 'rename_claude_subscription' ? 'renamed' : 'removed', error_code: null };
      }
      if (command === 'begin_claude_subscription_login') {
        window.claudeCalls.push({ command }); window.advanceClaudeLogin('starting');
        if (window.holdClaudeBegin) return new Promise(resolve => { window.finishClaudeBegin = () => resolve(structuredClone(window.claudeAttempt)); });
        return structuredClone(window.claudeAttempt);
      }
      if (command === 'get_claude_subscription_login') {
        if (window.holdClaudeLoginPoll) { window.holdClaudeLoginPoll = false; const old = structuredClone(window.claudeAttempt); return new Promise(resolve => { window.releaseClaudeLoginPoll = () => resolve(old); }); }
        return structuredClone(window.claudeAttempt);
      }
      if (command === 'cancel_claude_subscription_login') {
        window.claudeCalls.push({ command, ...args }); if (window.failClaudeLoginCancel) throw 'account_busy';
        window.advanceClaudeLogin(window.claudeAttempt.phase === 'verified' ? 'cancelled' : 'cancelling'); return structuredClone(window.claudeAttempt);
      }
      if (command === 'capture_claude_subscription') {
        window.claudeCalls.push({ command, ...args });
        if (window.failClaudeCapture) throw 'claude_login_attempt_expired';
        if (args.attemptId !== null && (window.claudeAttempt?.phase !== 'verified' || args.attemptId !== window.claudeAttempt.attempt_id)) throw 'claude_login_attempt_unavailable';
        const next = account(args.attemptId === null ? 'claude_current' : 'claude_login', args.label); window.claudeRows.push(next); if (args.attemptId) window.advanceClaudeLogin('saved'); window.emitClaudeChange(); return structuredClone(next);
      }
      if (command === 'read_claude_subscription_quota') { window.claudeCalls.push({ command, ...args }); if (window.failClaudeQuota) throw 'claude_identity_mismatch'; return structuredClone(window.claudeQuota); }
      if (command === 'prepare_claude_subscription_switch') {
        window.claudeCalls.push({ command, ...args });
        if (window.failClaudePrepare) throw 'occupancy_unknown';
        if (window.claudeAlreadyCurrent) { window.claudeRows.find(row => row.id === args.accountId).active_state = 'verified'; return { account_id: args.accountId, phase: 'already_current', ticket: null, expires_at: null, reason_code: 'already_current' }; }
        window.claudeTicket = { value: 'SYNTHETIC_CLAUDE_TICKET_0123456789', accountId: args.accountId };
        return { account_id: args.accountId, phase: 'ready', ticket: window.claudeTicket.value, expires_at: Math.floor(Date.now() / 1000) + 30, reason_code: null };
      }
      if (command === 'cancel_claude_subscription_switch') {
        window.claudeCalls.push({ command, ...args }); if (window.failClaudeSwitchCancel) throw 'account_busy';
        if (!window.claudeTicket || window.claudeTicket.value !== args.ticket) throw 'switch_ticket_invalid';
        const id = window.claudeTicket.accountId; window.claudeTicket = null; return { account_id: id, phase: 'cancelled', error_code: null };
      }
      if (command === 'commit_claude_subscription_switch') {
        window.claudeCalls.push({ command, ...args });
        if (!window.claudeTicket || window.claudeTicket.value !== args.ticket) throw 'switch_ticket_invalid';
        const id = window.claudeTicket.accountId; window.claudeTicket = null;
        if (window.failClaudeCommit) throw 'claude_identity_mismatch';
        window.claudeRows.forEach(row => { row.active_state = row.id === id ? 'verified' : 'unknown'; }); window.emitClaudeChange(); return { account_id: id, phase: 'verified', error_code: null };
      }
      return original(command, args);
    };
  });
  await page.goto('/');
  await page.getByRole('navigation').getByRole('button', { name: language === 'zh-Hans' ? '平台账号' : 'Accounts', exact: true }).click();
  const panel = page.getByRole('region', { name: language === 'zh-Hans' ? 'Claude 订阅' : 'Claude subscriptions', exact: true });
  await expect(panel.getByTestId('claude-subscription-claude_a')).toBeVisible();
  return panel;
}

test('subscription more menu preserves a failed alias and removes only after a successful receipt', async ({ page }) => {
  const panel = await claudePage(page), row = panel.getByTestId('claude-subscription-claude_b');
  await row.getByLabel('More actions for Synthetic Claude B', { exact: true }).click();
  await row.getByRole('button', { name: 'Rename', exact: true }).click();
  let editor = page.getByRole('dialog', { name: 'Rename account', exact: true });
  await editor.getByLabel('Account alias', { exact: true }).fill('Synthetic Claude Renamed');
  await page.evaluate(() => { window.failClaudeEdit = 'duplicate_label'; });
  await editor.getByRole('button', { name: 'Save alias', exact: true }).click();
  await expect(editor.getByRole('alert')).toContainText('already exists');
  await expect(editor.getByLabel('Account alias', { exact: true })).toHaveValue('Synthetic Claude Renamed');
  await expect(row.locator('h3')).toHaveText('Synthetic Claude B');
  await page.evaluate(() => { window.failClaudeEdit = null; });
  await editor.getByRole('button', { name: 'Save alias', exact: true }).click();
  await expect(editor).toHaveCount(0); await expect(row.locator('h3')).toHaveText('Synthetic Claude Renamed');
  await row.getByLabel('More actions for Synthetic Claude Renamed', { exact: true }).click();
  await row.getByRole('button', { name: 'Remove saved account', exact: true }).click();
  editor = page.getByRole('dialog', { name: 'Remove saved account', exact: true });
  await expect(editor).toContainText('system sign-in, Desktop settings and history are retained');
  await expect(editor).toHaveScreenshot('claude-subscription-remove-confirm.png');
  await editor.getByRole('button', { name: 'Remove account', exact: true }).click();
  await expect(editor).toHaveCount(0); await expect(row).toHaveCount(0);
  expect(await page.evaluate(() => window.claudeCalls.map(call => call.command))).toEqual(['rename_claude_subscription', 'rename_claude_subscription', 'remove_claude_subscription']);
});

test('official login stays separate from explicit capture and never returns OAuth URLs to the page', async ({ page }) => {
  const panel = await claudePage(page);
  await panel.getByRole('button', { name: 'Official sign-in', exact: true }).click();
  await expect(panel.getByRole('region', { name: 'Claude login progress' })).toHaveAttribute('data-login-phase', 'starting');
  await page.evaluate(() => window.advanceClaudeLogin('waiting'));
  await expect(panel).toContainText('Complete the login in the browser opened by the official CLI.');
  await expect(panel).not.toContainText('https://');
  await page.evaluate(() => window.advanceClaudeLogin('verified'));
  await expect(panel.getByRole('button', { name: 'Save verified subscription', exact: true })).toBeDisabled();
  await expect(panel.locator('.claude-subscription-card')).toHaveCount(2);
  expect(await page.evaluate(() => window.claudeCalls.some(call => call.command === 'capture_claude_subscription'))).toBe(false);
  await panel.getByLabel('Subscription alias', { exact: true }).fill('Synthetic New Login');
  await panel.getByRole('button', { name: 'Save verified subscription', exact: true }).click();
  await expect(panel.getByTestId('claude-subscription-claude_login')).toContainText('Synthetic New Login');
  expect(await page.evaluate(() => window.claudeCalls.find(call => call.command === 'capture_claude_subscription'))).toEqual({ command: 'capture_claude_subscription', label: 'Synthetic New Login', attemptId: 'synthetic_claude_attempt_0123456789' });
  expect(await page.evaluate(() => window.claudeCalls.some(call => call.command === 'commit_claude_subscription_switch'))).toBe(false);
  await expect(panel).not.toContainText('Current identity verified');
  await expect(panel).toHaveScreenshot('claude-login-explicitly-saved.png');
});

test('saving the current Windows subscription is an explicit separate action with no fabricated Codex account', async ({ page }) => {
  const panel = await claudePage(page);
  await panel.getByLabel('Subscription alias', { exact: true }).fill('Synthetic Current');
  await panel.getByRole('button', { name: 'Save current Windows subscription', exact: true }).click();
  await expect(panel.getByTestId('claude-subscription-claude_current')).toContainText('Synthetic Current');
  expect(await page.evaluate(() => window.claudeCalls)).toEqual([{ command: 'capture_claude_subscription', label: 'Synthetic Current', attemptId: null }]);
});

test('expired login capture preserves the alias and cannot invent a saved subscription', async ({ page }) => {
  const panel = await claudePage(page);
  await panel.getByRole('button', { name: 'Official sign-in', exact: true }).click();
  await page.evaluate(() => window.advanceClaudeLogin('verified'));
  await panel.getByLabel('Subscription alias', { exact: true }).fill('Synthetic Expired');
  await expect(panel.getByRole('button', { name: 'Save verified subscription', exact: true })).toBeEnabled();
  await page.evaluate(() => { window.failClaudeCapture = true; });
  await panel.getByRole('button', { name: 'Save verified subscription', exact: true }).click();
  await expect(panel).toContainText('The verified login expired before saving.');
  await expect(panel.getByLabel('Subscription alias', { exact: true })).toHaveValue('Synthetic Expired');
  await expect(panel.locator('.claude-subscription-card')).toHaveCount(2);
  await expect(panel).not.toContainText('The subscription identity is saved.');
});

test('cancelled login waits for cleanup and late verified progress cannot enable capture again', async ({ page }) => {
  const panel = await claudePage(page);
  await panel.getByRole('button', { name: 'Official sign-in', exact: true }).click();
  await page.evaluate(() => { window.advanceClaudeLogin('verified'); window.holdClaudeLoginPoll = true; });
  await expect.poll(() => page.evaluate(() => typeof window.releaseClaudeLoginPoll)).toBe('function');
  await page.evaluate(() => window.advanceClaudeLogin('waiting'));
  await panel.getByRole('button', { name: 'Cancel login', exact: true }).click();
  await expect(panel.getByRole('region', { name: 'Claude login progress' })).toHaveAttribute('data-login-phase', 'cancelling');
  await page.evaluate(() => window.releaseClaudeLoginPoll());
  await expect(panel.getByRole('button', { name: 'Save verified subscription', exact: true })).toHaveCount(0);
  await expect(panel).not.toContainText('Login cancelled.');
  await page.evaluate(() => window.advanceClaudeLogin('cancelled'));
  await expect(panel).toContainText('Login cancelled.');
});

test('failed login cancellation cannot save the revoked verified attempt or claim it was cancelled', async ({ page }) => {
  const panel = await claudePage(page);
  await panel.getByRole('button', { name: 'Official sign-in', exact: true }).click();
  await page.evaluate(() => window.advanceClaudeLogin('verified'));
  await panel.getByLabel('Subscription alias', { exact: true }).fill('Synthetic Cancel Failure');
  const save = panel.getByRole('button', { name: 'Save verified subscription', exact: true });
  await expect(save).toBeEnabled();
  await page.evaluate(() => { window.failClaudeLoginCancel = true; });
  await panel.getByRole('button', { name: 'Cancel login', exact: true }).click();
  await expect(panel).toContainText('Another account operation is in progress.');
  await expect(panel).not.toContainText('Login cancelled.');
  await expect(save).toBeDisabled();
  await page.waitForTimeout(1100);
  await expect(save).toBeDisabled();
  expect(await page.evaluate(() => window.claudeCalls.some(call => call.command === 'capture_claude_subscription'))).toBe(false);
});

test('concurrent sign-in clicks submit one native login and keep capture actions unavailable', async ({ page }) => {
  const panel = await claudePage(page);
  await page.evaluate(() => { window.holdClaudeBegin = true; });
  const signIn = panel.getByRole('button', { name: 'Official sign-in', exact: true });
  await signIn.click();
  await signIn.dispatchEvent('click');
  await expect(signIn).toBeDisabled();
  expect(await page.evaluate(() => window.claudeCalls)).toEqual([{ command: 'begin_claude_subscription_login' }]);
  await page.evaluate(() => window.finishClaudeBegin());
  await expect(panel.getByRole('region', { name: 'Claude login progress' })).toHaveAttribute('data-login-phase', 'starting');
  await expect(panel.getByRole('button', { name: 'Save current Windows subscription', exact: true })).toBeDisabled();
});

test('a cancelled phase with unconfirmed native cleanup never claims successful cancellation or permits another login', async ({ page }) => {
  const panel = await claudePage(page);
  await panel.getByRole('button', { name: 'Official sign-in', exact: true }).click();
  await panel.getByRole('button', { name: 'Cancel login', exact: true }).click();
  await page.evaluate(() => { window.advanceClaudeLogin('cancelled'); window.claudeAttempt.error_code = 'cleanup_unconfirmed'; });
  await expect(panel).toContainText('Cleanup after cancellation is unconfirmed.');
  await expect(panel).not.toContainText('Login cancelled.');
  await expect(panel.getByRole('button', { name: 'Official sign-in', exact: true })).toBeDisabled();
  await expect(panel.getByRole('button', { name: 'Save current Windows subscription', exact: true })).toBeDisabled();
});

test('returned quota is used-to-remaining, preserves true zero and includes only actual scoped windows', async ({ page }) => {
  const panel = await claudePage(page);
  const card = panel.getByTestId('claude-subscription-claude_a');
  expect(await page.evaluate(() => window.claudeCalls.some(call => call.command === 'read_claude_subscription_quota'))).toBe(false);
  await card.getByRole('button', { name: 'Read subscription quota' }).click();
  await expect(card.getByRole('img', { name: '5-hour · Remaining 75%', exact: true })).toBeVisible();
  await expect(card.getByRole('img', { name: '7-day · Remaining 20%', exact: true })).toBeVisible();
  await expect(card.getByRole('img', { name: 'Synthetic scoped model · Remaining 100%', exact: true })).toBeVisible();
  await expect(card.locator('.quota-ring')).toHaveCount(3);
  await expect(card).not.toContainText('Opus');
  await expect(card).not.toContainText('Balance');
  await expect(card).toContainText('16/09, 04:30');
  await expect(card).toHaveScreenshot('claude-subscription-actual-windows.png');
  await page.evaluate(() => { window.claudeQuota.windows = [{ id: 'five_hour', label: '5-hour', used_percent: 100, resets_at: null }]; });
  await card.getByRole('button', { name: 'Read subscription quota' }).click();
  await expect(card.getByRole('img', { name: '5-hour · Remaining 0%', exact: true })).toBeVisible();
  await expect(card.locator('.quota-ring-value')).toHaveCount(0);
});

test('empty official windows stay unknown instead of producing model rings or 100 percent', async ({ page }) => {
  const panel = await claudePage(page);
  await page.evaluate(() => { window.claudeQuota.windows = []; });
  const card = panel.getByTestId('claude-subscription-claude_a');
  await card.getByRole('button', { name: 'Read subscription quota' }).click();
  await expect(card.locator('.quota-ring')).toHaveCount(0);
  await expect(card).toContainText('No quota windows were returned by the official service.');
  await expect(card).not.toContainText('100%');
  await expect(card).not.toContainText('Synthetic scoped model');
});

test('server retry deadline is in seconds and suppresses repeated quota reads until it ends', async ({ page }) => {
  const panel = await claudePage(page);
  await page.evaluate(() => { window.claudeQuota = { ...window.claudeQuota, state: 'rate_limited', windows: [], server_retry_at: Date.now() / 1000 + 60 }; });
  const card = panel.getByTestId('claude-subscription-claude_a'), read = card.getByRole('button', { name: 'Read subscription quota' });
  await read.click();
  await expect(read).toBeDisabled();
  await expect(card).toContainText('The service requires waiting until');
  await expect(card).not.toContainText('1970');
  await read.dispatchEvent('click');
  expect(await page.evaluate(() => window.claudeCalls.filter(call => call.command === 'read_claude_subscription_quota').length)).toBe(1);
  await expect(card).toHaveScreenshot('claude-subscription-rate-limited.png');
  await page.clock.setSystemTime(new Date(new Date(FIXED_NOW_ISO).getTime() + 61000));
  await expect(read).toBeEnabled();
});

test('failed official read retains only an explicitly old quota snapshot', async ({ page }) => {
  const panel = await claudePage(page);
  const card = panel.getByTestId('claude-subscription-claude_a');
  await card.getByRole('button', { name: 'Read subscription quota' }).click();
  await page.evaluate(() => { window.failClaudeQuota = true; });
  await card.getByRole('button', { name: 'Read subscription quota' }).click();
  await expect(card).toContainText('The subscription identity changed.');
  await expect(card.getByRole('img', { name: '5-hour · Last snapshot remaining 75%', exact: true })).toBeVisible();
  await expect(card.locator('.quota-ring.is-stale')).toHaveCount(3);
  await expect(card).toContainText('This last snapshot is for reference.');
});

test('already-current official proof has no confirmation ticket or commit action', async ({ page }) => {
  const panel = await claudePage(page);
  await page.evaluate(() => { window.claudeAlreadyCurrent = true; });
  await panel.getByTestId('claude-subscription-claude_a').getByRole('button', { name: 'Switch current Claude' }).click();
  await expect(panel).toContainText('This subscription is already current, confirmed by the official readback.');
  await expect(panel.getByTestId('claude-subscription-claude_a')).toContainText('Current identity verified');
  await expect(page.getByRole('dialog', { name: 'Confirm Claude switch' })).toHaveCount(0);
  expect(await page.evaluate(() => window.claudeCalls)).toEqual([{ command: 'prepare_claude_subscription_switch', accountId: 'claude_a' }]);
});

test('single-use switch requires explicit commit and fresh verified readback before showing current identity', async ({ page }) => {
  const panel = await claudePage(page);
  await panel.getByTestId('claude-subscription-claude_b').getByRole('button', { name: 'Switch current Claude' }).click();
  const dialog = page.getByRole('dialog', { name: 'Confirm Claude switch' });
  await expect(dialog).toContainText('Confirm within 30 seconds.');
  await expect(panel).not.toContainText('Current identity verified');
  await expect(dialog).not.toContainText('SYNTHETIC_CLAUDE_TICKET');
  expect(await page.evaluate(() => JSON.stringify(localStorage))).not.toContain('SYNTHETIC_CLAUDE_TICKET');
  await dialog.getByRole('button', { name: 'Confirm switch', exact: true }).click();
  await expect(dialog).toHaveCount(0);
  await expect(panel.getByTestId('claude-subscription-claude_b')).toContainText('Current identity verified');
  expect(await page.evaluate(() => window.claudeCalls.map(call => call.command))).toEqual(['prepare_claude_subscription_switch', 'commit_claude_subscription_switch']);
});

test('expired and failed Claude switch confirmations never become current and cannot reuse their tickets', async ({ page }) => {
  const panel = await claudePage(page);
  await panel.getByTestId('claude-subscription-claude_a').getByRole('button', { name: 'Switch current Claude' }).click();
  const dialog = page.getByRole('dialog', { name: 'Confirm Claude switch' });
  await page.clock.setSystemTime(new Date(new Date(FIXED_NOW_ISO).getTime() + 31000));
  await expect(dialog).toContainText('The switch confirmation expired.');
  await expect(dialog.getByRole('button', { name: 'Confirm switch', exact: true })).toHaveCount(0);
  await dialog.getByRole('button', { name: 'Close', exact: true }).click();
  await page.evaluate(() => { window.failClaudeCommit = true; });
  await panel.getByTestId('claude-subscription-claude_b').getByRole('button', { name: 'Switch current Claude' }).click();
  await dialog.getByRole('button', { name: 'Confirm switch', exact: true }).click();
  await expect(dialog).toContainText('The subscription identity changed.');
  await expect(panel).not.toContainText('Current identity verified');
  await expect(dialog.getByRole('button', { name: 'Confirm switch', exact: true })).toHaveCount(0);
  await expect(dialog).toHaveScreenshot('claude-switch-identity-failed.png');
});

test('failed cancellation keeps confirmation blocked until a successful retry releases its ticket', async ({ page }) => {
  const panel = await claudePage(page);
  await panel.getByTestId('claude-subscription-claude_a').getByRole('button', { name: 'Switch current Claude' }).click();
  const dialog = page.getByRole('dialog', { name: 'Confirm Claude switch' });
  await page.evaluate(() => { window.failClaudeSwitchCancel = true; });
  await dialog.getByRole('button', { name: 'Cancel switch', exact: true }).click();
  await expect(dialog).toContainText('Cancellation is unconfirmed.');
  await expect(dialog.getByRole('button', { name: 'Confirm switch', exact: true })).toHaveCount(0);
  await page.evaluate(() => { window.failClaudeSwitchCancel = false; });
  await page.keyboard.press('Escape');
  await expect(dialog).toHaveCount(0);
  expect(await page.evaluate(() => window.claudeTicket)).toBeNull();
});

for (const scenario of [{ language: 'zh-Hans', theme: 'light', width: 1280 }, { language: 'zh-Hans', theme: 'dark', width: 480 }]) {
  test(`Claude card and list layout ${scenario.language} ${scenario.theme} ${scenario.width}`, async ({ page }) => {
    await page.setViewportSize({ width: scenario.width, height: 1100 });
    const panel = await claudePage(page, scenario);
    await panel.getByTestId('claude-subscription-claude_a').getByRole('button', { name: '读取订阅额度' }).click();
    await expect(panel).toHaveScreenshot(`claude-subscriptions-${scenario.theme}-${scenario.language}-${scenario.width}.png`);
    await panel.getByRole('button', { name: 'Claude 列表', exact: true }).click();
    expect(await page.locator('body').evaluate(node => node.scrollWidth <= innerWidth)).toBe(true);
    expect(await panel.locator('.account-directory-number').first().evaluate(node => node.scrollHeight <= node.clientHeight)).toBe(true);
    await expect(panel).toHaveScreenshot(`claude-subscriptions-list-${scenario.theme}-${scenario.language}-${scenario.width}.png`);
    await page.reload();
    await expect(panel.getByRole('button', { name: 'Claude 列表', exact: true })).toHaveAttribute('aria-pressed', 'true');
  });
}
