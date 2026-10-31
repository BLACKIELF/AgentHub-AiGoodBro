import { test, expect } from '@playwright/test';
import { FIXED_NOW_ISO, SYNTHETIC_DASHBOARD, SYNTHETIC_SETTINGS } from './synthetic-fixtures.mjs';
import { installTauriStub } from './tauri-stub.mjs';

async function managedPage(page, { language = 'en', theme = 'dark' } = {}) {
  await page.clock.setFixedTime(new Date(FIXED_NOW_ISO));
  await installTauriStub(page, { settings: { ...SYNTHETIC_SETTINGS, language, theme }, dashboard: SYNTHETIC_DASHBOARD }, () => {
    const original = window.__TAURI_INTERNALS__.invoke;
    const account = (id, label, loggedIn) => ({ id, label, platform: 'codex', storage_kind: 'managed', login_state: loggedIn ? 'verified' : 'signed_out', active_state: 'unknown', masked_identity: loggedIn ? 's***@synthetic.invalid' : null, can_login: true, can_switch: loggedIn, switch_block_reason: loggedIn ? null : 'login_required', revision: 1, recovery_required: false });
    window.managedRows = [account('managed_a', 'Synthetic Managed A', true), account('managed_b', 'Synthetic Managed B', false), { ...account('managed_blocked', 'Synthetic Gate Blocked', true), can_switch: false, switch_block_reason: 'occupancy_unknown' }];
    window.managedCalls = [];
    const callbacks = [];
    window.emitManagedChange = () => callbacks.forEach(callback => window[`_${callback}`]({ event: 'managed-accounts:changed', id: 291, payload: null }));
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: async value => { if (window.failManagedClipboard) throw Error('synthetic clipboard denied'); window.managedClipboard = value; } } });
    const login = phase => ({ attempt_id: 'synthetic_attempt_0123456789', account_id: 'managed_b', phase, verification_url: phase === 'waiting' ? 'https://auth.openai.com/codex/device' : null, user_code: phase === 'waiting' ? 'SYNTHETIC-CODE' : null, error_code: null });
    window.advanceManagedLogin = phase => {
      window.managedLogin = login(phase);
      const row = window.managedRows.find(row => row.id === 'managed_b');
      row.login_state = phase === 'verified' ? 'verified' : ['cancelled', 'failed'].includes(phase) ? 'signed_out' : 'signing_in';
      row.can_login = ['verified', 'cancelled', 'failed'].includes(phase);
      row.can_switch = phase === 'verified'; row.switch_block_reason = phase === 'verified' ? null : 'login_in_progress';
      if (phase === 'verified') { row.masked_identity = 'v***@synthetic.invalid'; row.revision++; }
    };
    const commit = id => {
      window.managedRows.forEach(row => { row.active_state = row.id === id ? 'verified' : 'unknown'; });
      return { account_id: id, phase: 'committed', error_code: null };
    };
    window.__TAURI_INTERNALS__.invoke = async (command, args) => {
      if (command === 'plugin:event|listen' && args.event === 'managed-accounts:changed') { callbacks.push(args.handler); return 291; }
      if (command === 'list_profiles') return [{ id: 'linked_only', label: 'Synthetic Linked Directory', platform: 'codex', platform_name: 'Codex', selected: true, can_view_usage: false }];
      if (command === 'list_managed_accounts') {
        if (window.failManagedRead) throw 'account_service_unavailable';
        if (window.holdManagedRead) { window.holdManagedRead = false; const old = structuredClone(window.managedRows); return new Promise(resolve => { window.releaseManagedRead = () => resolve(old); }); }
        return structuredClone(window.managedRows);
      }
      if (command === 'create_managed_account') {
        window.managedCalls.push({ command, ...args });
        if (window.failManagedCreate) throw 'duplicate_label';
        const created = account('managed_new', args.label, false); window.managedRows.push(created); window.emitManagedChange(); return structuredClone(created);
      }
      if (command === 'rename_managed_account' || command === 'remove_managed_account') {
        window.managedCalls.push({ command, ...args });
        if (window.failManagedEdit) throw window.failManagedEdit;
        if (command === 'rename_managed_account') window.managedRows.find(row => row.id === args.accountId).label = args.label;
        else window.managedRows = window.managedRows.filter(row => row.id !== args.accountId);
        window.emitManagedChange(); return { account_id: args.accountId, phase: command === 'rename_managed_account' ? 'renamed' : 'removed', error_code: null };
      }
      if (command === 'begin_account_login') {
        window.managedCalls.push({ command, ...args });
        if (args.accountId !== 'managed_b') throw 'account_not_found';
        window.advanceManagedLogin('starting');
        if (window.holdManagedBegin) return new Promise(resolve => { window.releaseManagedBegin = () => resolve(structuredClone(window.managedLogin)); });
        return structuredClone(window.managedLogin);
      }
      if (command === 'get_login_attempt') {
        if (window.holdLoginPoll) { window.holdLoginPoll = false; const old = structuredClone(window.managedLogin); return new Promise(resolve => { window.releaseLoginPoll = () => resolve(old); }); }
        return structuredClone(window.managedLogin);
      }
      if (command === 'cancel_account_login') {
        window.managedCalls.push({ command, ...args });
        if (window.failLoginCancel) throw 'account_busy';
        window.advanceManagedLogin('cancelling'); return structuredClone(window.managedLogin);
      }
      if (command === 'open_account_login_page') {
        window.managedCalls.push({ command, ...args });
        if (window.failManagedOpen || window.managedLogin?.phase !== 'waiting' || args.attemptId !== window.managedLogin.attempt_id) throw 'login_page_unavailable';
        return null;
      }
      if (command === 'prepare_account_switch') {
        window.managedCalls.push({ command, ...args });
        if (!window.managedRows.some(row => row.id === args.accountId)) throw 'account_not_found';
        if (window.blockManagedSwitch) return { account_id: args.accountId, phase: 'blocked', ticket: null, expires_at: null, reason_code: 'account_busy' };
        window.managedTicket = { accountId: args.accountId, value: 'SYNTHETIC_SWITCH_TICKET_0123456789', expires: Math.floor(Date.now() / 1000) + 30 };
        return { account_id: args.accountId, phase: 'ready', ticket: window.managedTicket.value, expires_at: window.managedTicket.expires, reason_code: null };
      }
      if (command === 'cancel_account_switch') {
        window.managedCalls.push({ command, ...args });
        if (window.failSwitchCancel) throw 'account_service_unavailable';
        if (!window.managedTicket || args.ticket !== window.managedTicket.value) throw 'switch_ticket_invalid';
        const id = window.managedTicket.accountId; window.managedTicket = null; return { account_id: id, phase: 'cancelled', error_code: null };
      }
      if (command === 'commit_account_switch') {
        window.managedCalls.push({ command, ...args });
        if (!window.managedTicket || args.ticket !== window.managedTicket.value) throw 'switch_ticket_invalid';
        const id = window.managedTicket.accountId; window.managedTicket = null;
        if (window.failManagedCommit) throw 'identity_mismatch';
        if (window.holdManagedCommit) return new Promise(resolve => { window.finishManagedCommit = () => resolve(commit(id)); });
        return commit(id);
      }
      return original(command, args);
    };
  });
  await page.goto('/');
  await page.getByRole('navigation').getByRole('button', { name: language === 'zh-Hans' ? '平台账号' : 'Accounts', exact: true }).click();
  const panel = page.getByRole('region', { name: language === 'zh-Hans' ? '托管账号' : 'Managed accounts', exact: true });
  await expect(panel.getByTestId('managed-account-managed_a')).toBeVisible();
  return panel;
}

async function waitingLogin(page, panel) {
  await panel.getByTestId('managed-account-managed_b').getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(panel.getByRole('region', { name: 'Login progress' })).toHaveAttribute('data-login-phase', 'starting');
  await page.evaluate(() => window.advanceManagedLogin('waiting'));
  await expect(panel.getByRole('region', { name: 'Login progress' })).toHaveAttribute('data-login-phase', 'waiting');
}

test('managed identity is distinct from linked selection; unavailable gate blocks switch and create uses the managed command', async ({ page }) => {
  const panel = await managedPage(page);
  await expect(page.getByTestId('profile-linked_only')).toBeVisible();
  await expect(panel).not.toContainText('Current identity verified');
  await expect(panel.getByTestId('managed-account-managed_blocked').getByRole('button', { name: 'Switch current Codex' })).toBeDisabled();
  await expect(panel).toContainText('Task occupancy is unconfirmed.');
  await panel.getByLabel('Codex account alias', { exact: true }).fill('Synthetic New');
  await panel.getByRole('button', { name: 'Create account', exact: true }).click();
  await expect(panel.getByTestId('managed-account-managed_new')).toContainText('Synthetic New');
  expect(await page.evaluate(() => window.managedCalls)).toEqual([{ command: 'create_managed_account', label: 'Synthetic New', platform: 'codex' }]);
  await expect(panel).toHaveScreenshot('managed-accounts-dark-en.png');
});

test('failed creation preserves alias without inventing an account', async ({ page }) => {
  const panel = await managedPage(page);
  await page.evaluate(() => { window.failManagedCreate = true; });
  await panel.getByLabel('Codex account alias', { exact: true }).fill('Synthetic Duplicate');
  await panel.getByRole('button', { name: 'Create account', exact: true }).click();
  await expect(panel.getByLabel('Codex account alias', { exact: true })).toHaveValue('Synthetic Duplicate');
  await expect(panel).toContainText('That alias already exists.');
  await expect(panel.locator('.managed-account-card')).toHaveCount(3);
});

test('saved account menu renames only after acknowledgement and retains a denied removal', async ({ page }) => {
  const panel = await managedPage(page), row = panel.getByTestId('managed-account-managed_a');
  await row.getByLabel('More actions for Synthetic Managed A', { exact: true }).click();
  await row.getByRole('button', { name: 'Rename', exact: true }).click();
  let editor = page.getByRole('dialog', { name: 'Rename account', exact: true });
  await editor.getByLabel('Account alias', { exact: true }).fill('Synthetic Renamed');
  await page.evaluate(() => { window.failManagedEdit = 'duplicate_label'; });
  await editor.getByRole('button', { name: 'Save alias', exact: true }).click();
  await expect(editor.getByRole('alert')).toContainText('already exists');
  await expect(editor.getByLabel('Account alias', { exact: true })).toHaveValue('Synthetic Renamed');
  await expect(row.locator('h3')).toHaveText('Synthetic Managed A');
  await page.evaluate(() => { window.failManagedEdit = null; });
  await editor.getByRole('button', { name: 'Save alias', exact: true }).click();
  await expect(editor).toHaveCount(0); await expect(row.locator('h3')).toHaveText('Synthetic Renamed');
  await row.getByLabel('More actions for Synthetic Renamed', { exact: true }).click();
  await row.getByRole('button', { name: 'Remove saved account', exact: true }).click();
  editor = page.getByRole('dialog', { name: 'Remove saved account', exact: true });
  await expect(editor).toContainText('system sign-in, Desktop settings and history are retained');
  await page.evaluate(() => { window.failManagedEdit = 'account_is_current'; });
  await editor.getByRole('button', { name: 'Remove account', exact: true }).click();
  await expect(editor.getByRole('alert')).toContainText('saved alias is current');
  await expect(row).toHaveCount(1);
  await expect(editor).toHaveScreenshot('managed-account-remove-denied.png');
  await editor.getByRole('button', { name: 'Cancel', exact: true }).click();
  expect(await page.evaluate(() => window.managedCalls.map(call => call.command))).toEqual(['rename_managed_account', 'rename_managed_account', 'remove_managed_account']);
});

test('official pairing opens only by attempt command; clipboard and failed open have separate real receipts', async ({ page }) => {
  const panel = await managedPage(page);
  await waitingLogin(page, panel);
  await expect(panel).toContainText('https://auth.openai.com/codex/device');
  await expect(panel).toContainText('SYNTHETIC-CODE');
  await page.evaluate(() => { window.failManagedClipboard = true; });
  await panel.getByRole('button', { name: 'Copy pairing code' }).click();
  await expect(panel).not.toContainText('Pairing code copied.');
  expect(await page.evaluate(() => window.managedClipboard)).toBeUndefined();
  await page.evaluate(() => { window.failManagedClipboard = false; });
  await panel.getByRole('button', { name: 'Copy pairing code' }).click();
  expect(await page.evaluate(() => window.managedClipboard)).toBe('SYNTHETIC-CODE');
  await panel.getByRole('button', { name: 'Copy login URL' }).click();
  expect(await page.evaluate(() => window.managedClipboard)).toBe('https://auth.openai.com/codex/device');
  await page.evaluate(() => { window.failManagedOpen = true; });
  await panel.getByRole('button', { name: 'Open official login page' }).click();
  await expect(panel).toContainText('This login page is no longer available.');
  await expect(panel).not.toContainText('opened with the account browser setting');
  await page.evaluate(() => { window.failManagedOpen = false; });
  await panel.getByRole('button', { name: 'Open official login page' }).click();
  await expect(panel).toContainText('The official login page was opened with the account browser setting.');
  const calls = await page.evaluate(() => window.managedCalls.filter(call => call.command === 'open_account_login_page'));
  expect(calls).toEqual([{ command: 'open_account_login_page', attemptId: 'synthetic_attempt_0123456789' }, { command: 'open_account_login_page', attemptId: 'synthetic_attempt_0123456789' }]);
  expect(await page.evaluate(() => JSON.stringify(localStorage))).not.toContain('SYNTHETIC-CODE');
  await expect(panel).toHaveScreenshot('managed-login-waiting.png');
});

test('cancel acknowledgement waits for cleanup; a late poll cannot restore the revoked pairing prompt', async ({ page }) => {
  const panel = await managedPage(page);
  await waitingLogin(page, panel);
  await page.evaluate(() => { window.holdLoginPoll = true; });
  await expect.poll(() => page.evaluate(() => typeof window.releaseLoginPoll)).toBe('function');
  await panel.getByRole('button', { name: 'Cancel login', exact: true }).click();
  await expect(panel.getByRole('region', { name: 'Login progress' })).toHaveAttribute('data-login-phase', 'cancelling');
  await expect(panel).not.toContainText('SYNTHETIC-CODE');
  await expect(panel.getByRole('button', { name: 'Open official login page' })).toHaveCount(0);
  await page.evaluate(() => window.releaseLoginPoll());
  await expect(panel.getByRole('region', { name: 'Login progress' })).toHaveAttribute('data-login-phase', 'cancelling');
  await expect(panel).not.toContainText('Login cancelled.');
  await page.evaluate(() => window.advanceManagedLogin('cancelled'));
  await expect(panel.getByRole('region', { name: 'Login progress' })).toHaveAttribute('data-login-phase', 'cancelled');
  await expect(panel).toContainText('Login cancelled.');
});

test('a failed cancellation keeps the attempt pending and never reopens the previous prompt', async ({ page }) => {
  const panel = await managedPage(page);
  await waitingLogin(page, panel);
  await page.evaluate(() => { window.failLoginCancel = true; });
  await panel.getByRole('button', { name: 'Cancel login', exact: true }).click();
  await expect(panel).toContainText('Another account operation is in progress.');
  await expect(panel).not.toContainText('Login cancelled.');
  await expect(panel).not.toContainText('SYNTHETIC-CODE');
  await expect(panel.getByTestId('managed-account-managed_a').getByRole('button', { name: 'Sign in', exact: true })).toBeDisabled();
  await page.waitForTimeout(900);
  await expect(panel).not.toContainText('SYNTHETIC-CODE');
});

test('an untrusted pairing URL is rejected before display or any browser-open action', async ({ page }) => {
  const panel = await managedPage(page);
  await panel.getByTestId('managed-account-managed_b').getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.evaluate(() => { window.advanceManagedLogin('waiting'); window.managedLogin.verification_url = 'https://auth.openai.com.evil.invalid/codex/device'; });
  await expect(panel).toContainText('Login progress is unavailable.');
  await expect(panel).not.toContainText('evil.invalid');
  await expect(panel.getByRole('button', { name: 'Open official login page' })).toHaveCount(0);
  expect(await page.evaluate(() => window.managedCalls.some(call => call.command === 'open_account_login_page'))).toBe(false);
});

test('duplicate begin clicks are serialized and login verification does not switch the current identity', async ({ page }) => {
  const panel = await managedPage(page);
  await page.evaluate(() => { window.holdManagedBegin = true; });
  const signIn = panel.getByTestId('managed-account-managed_b').getByRole('button', { name: 'Sign in', exact: true });
  await signIn.click();
  await signIn.dispatchEvent('click');
  expect(await page.evaluate(() => window.managedCalls.filter(call => call.command === 'begin_account_login').length)).toBe(1);
  await page.evaluate(() => window.releaseManagedBegin());
  await expect(panel.getByRole('region', { name: 'Login progress' })).toHaveAttribute('data-login-phase', 'starting');
  await page.evaluate(() => window.advanceManagedLogin('verified'));
  await expect(panel.getByRole('region', { name: 'Login progress' })).toHaveAttribute('data-login-phase', 'verified');
  await expect(panel.getByTestId('managed-account-managed_b')).toContainText('Signed in');
  await expect(panel).not.toContainText('Current identity verified');
  expect(await page.evaluate(() => window.managedCalls.some(call => call.command === 'commit_account_switch'))).toBe(false);
});

test('blocked preflight does not offer confirmation or commit', async ({ page }) => {
  const panel = await managedPage(page);
  await page.evaluate(() => { window.blockManagedSwitch = true; });
  await panel.getByTestId('managed-account-managed_a').getByRole('button', { name: 'Switch current Codex' }).click();
  await expect(panel).toContainText('Another account operation is in progress.');
  await expect(page.getByRole('dialog')).toHaveCount(0);
  expect(await page.evaluate(() => window.managedCalls.some(call => call.command === 'commit_account_switch'))).toBe(false);
});

test('switch confirmation is time bounded, cancellation releases its ticket and never commits', async ({ page }) => {
  const panel = await managedPage(page);
  const switchButton = panel.getByTestId('managed-account-managed_a').getByRole('button', { name: 'Switch current Codex' });
  await switchButton.click();
  const dialog = page.getByRole('dialog', { name: 'Confirm account switch' });
  await expect(dialog).toContainText('Confirm within 30 seconds.');
  await expect(dialog.getByRole('button', { name: 'Confirm switch', exact: true })).toBeEnabled();
  await expect(dialog).not.toContainText('SYNTHETIC_SWITCH_TICKET');
  expect(await page.evaluate(() => JSON.stringify(localStorage))).not.toContain('SYNTHETIC_SWITCH_TICKET');
  await expect(dialog).toHaveScreenshot('managed-switch-confirm.png');
  await page.keyboard.press('Escape');
  await expect(dialog).toHaveCount(0);
  await expect(panel).toContainText('Switch cancelled.');
  expect(await page.evaluate(() => window.managedTicket)).toBeNull();
  expect(await page.evaluate(() => window.managedCalls.map(call => call.command))).toEqual(['prepare_account_switch', 'cancel_account_switch']);
  await expect(switchButton).toBeFocused();
});

test('an expired switch ticket is revoked locally and cannot be committed', async ({ page }) => {
  const panel = await managedPage(page);
  await panel.getByTestId('managed-account-managed_a').getByRole('button', { name: 'Switch current Codex' }).click();
  const dialog = page.getByRole('dialog', { name: 'Confirm account switch' });
  await expect(dialog).toBeVisible();
  await page.clock.setSystemTime(new Date(new Date(FIXED_NOW_ISO).getTime() + 31000));
  await expect(dialog).toContainText('The switch confirmation expired.');
  await expect(dialog.getByRole('button', { name: 'Confirm switch', exact: true })).toHaveCount(0);
  await dialog.getByRole('button', { name: 'Close', exact: true }).click();
  expect(await page.evaluate(() => window.managedCalls.some(call => call.command === 'commit_account_switch'))).toBe(false);
  expect(await page.evaluate(() => window.managedTicket)).toBeNull();
});

test('failed cancellation retains the ticket until a confirmed retry and blocks accidental commit', async ({ page }) => {
  const panel = await managedPage(page);
  await panel.getByTestId('managed-account-managed_a').getByRole('button', { name: 'Switch current Codex' }).click();
  const dialog = page.getByRole('dialog', { name: 'Confirm account switch' });
  await page.evaluate(() => { window.failSwitchCancel = true; });
  await dialog.getByRole('button', { name: 'Cancel switch', exact: true }).click();
  await expect(dialog).toContainText('Cancellation is unconfirmed.');
  await expect(dialog.getByRole('button', { name: 'Confirm switch', exact: true })).toHaveCount(0);
  expect(await page.evaluate(() => window.managedTicket !== null)).toBe(true);
  await page.evaluate(() => { window.failSwitchCancel = false; });
  await dialog.getByRole('button', { name: 'Cancel switch', exact: true }).click();
  await expect(dialog).toHaveCount(0);
  expect(await page.evaluate(() => window.managedTicket)).toBeNull();
});

test('identity changes fail the commit without marking an active identity or reusing a consumed ticket', async ({ page }) => {
  const panel = await managedPage(page);
  await page.evaluate(() => { window.failManagedCommit = true; });
  await panel.getByTestId('managed-account-managed_a').getByRole('button', { name: 'Switch current Codex' }).click();
  const dialog = page.getByRole('dialog', { name: 'Confirm account switch' });
  await dialog.getByRole('button', { name: 'Confirm switch', exact: true }).click();
  await expect(dialog).toContainText('The identity differs from the original account.');
  await expect(dialog.getByRole('button', { name: 'Confirm switch', exact: true })).toHaveCount(0);
  await expect(panel).not.toContainText('Current identity verified');
  expect(await page.evaluate(() => window.managedCalls.filter(call => call.command === 'commit_account_switch').length)).toBe(1);
  await expect(dialog).toHaveScreenshot('managed-switch-identity-failed.png');
  await dialog.getByRole('button', { name: 'Close', exact: true }).click();
});

test('only the returned commit and fresh identity proof can mark current; stale reads cannot restore old identity', async ({ page }) => {
  const panel = await managedPage(page);
  await page.evaluate(() => { window.holdManagedRead = true; window.holdManagedCommit = true; });
  await panel.getByRole('button', { name: 'Refresh managed accounts' }).click();
  await expect.poll(() => page.evaluate(() => typeof window.releaseManagedRead)).toBe('function');
  await panel.getByTestId('managed-account-managed_a').getByRole('button', { name: 'Switch current Codex' }).click();
  const dialog = page.getByRole('dialog', { name: 'Confirm account switch' });
  await dialog.getByRole('button', { name: 'Confirm switch', exact: true }).click();
  await expect(dialog.getByRole('button', { name: 'Switching…', exact: true })).toBeDisabled();
  await expect(panel).not.toContainText('Current identity verified');
  await page.evaluate(() => window.finishManagedCommit());
  await expect(dialog).toHaveCount(0);
  await expect(panel.getByTestId('managed-account-managed_a')).toContainText('Current identity verified');
  await page.evaluate(() => window.releaseManagedRead());
  await expect(panel.getByTestId('managed-account-managed_a')).toContainText('Current identity verified');
  await page.evaluate(() => { window.managedRows[0].active_state = 'stale'; window.emitManagedChange(); });
  await expect(panel).not.toContainText('Current identity verified');
  await expect(panel).toContainText('Current identity changed');
});

for (const scenario of [{ language: 'zh-Hans', theme: 'light', width: 1280 }, { language: 'zh-Hans', theme: 'dark', width: 480 }]) {
  test(`managed translated cards and list ${scenario.language} ${scenario.theme} ${scenario.width}`, async ({ page }) => {
    await page.setViewportSize({ width: scenario.width, height: 1000 });
    const panel = await managedPage(page, scenario);
    await expect(panel).toHaveScreenshot(`managed-accounts-${scenario.theme}-${scenario.language}-${scenario.width}.png`);
    await panel.getByRole('button', { name: '托管账号列表', exact: true }).click();
    expect(await page.locator('body').evaluate(node => node.scrollWidth <= innerWidth)).toBe(true);
    expect(await panel.locator('.account-directory-number').first().evaluate(node => node.scrollHeight <= node.clientHeight)).toBe(true);
    await expect(panel).toHaveScreenshot(`managed-list-${scenario.theme}-${scenario.language}-${scenario.width}.png`);
    await page.reload();
    await expect(panel.getByRole('button', { name: '托管账号列表', exact: true })).toHaveAttribute('aria-pressed', 'true');
  });
}
