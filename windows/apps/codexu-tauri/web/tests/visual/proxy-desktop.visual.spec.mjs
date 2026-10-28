import { test, expect } from '@playwright/test';
import { FIXED_NOW_ISO, SYNTHETIC_DASHBOARD, SYNTHETIC_SETTINGS } from './synthetic-fixtures.mjs';
import { installTauriStub } from './tauri-stub.mjs';

async function desktopPage(page, { language = 'en', theme = 'dark' } = {}) {
  await page.clock.setFixedTime(new Date(FIXED_NOW_ISO));
  await installTauriStub(page, { settings: { ...SYNTHETIC_SETTINGS, language, theme }, dashboard: SYNTHETIC_DASHBOARD }, () => {
    const original = window.__TAURI_INTERNALS__.invoke;
    window.desktopCalls = [];
    window.desktopState = { phase: 'stopped', launchId: null, accountId: null, issue: null, routingVerified: null };
    const preferences = { schemaVersion: 1, isEnabled: true, automaticRecoveryEnabled: false, order: ['managed_a'], enabledIds: ['managed_a'], knownIds: ['managed_a'], priorityIds: [], lastIds: [], lastOverrides: {}, creditFallback: false, creditPrimaryFloor: 2000, creditSecondaryFloor: 1500, accountPolicies: {}, resetStopRules: {}, listenPort: 18080, clientKeyMode: 'persistent', desktopFallback: false, networkProxy: '', egress: { enabled: false, mihomoApi: '', group: '', whitelist: [] } };
    const now = Date.now() / 1000;
    window.desktopProxyState = { phase: 'running', port: 18080, issue: null, accounts: {}, lastEventAt: now, egress: null };
    const account = { id: 'managed_a', label: 'Synthetic Managed Desktop', planType: 'plus', isLast: false, isPriority: false, isEnabled: true, quota: { fiveHourUsedPercent: 25, fiveHourResetsAt: now + 3600, sevenDayUsedPercent: 50, sevenDayResetsAt: now + 86400, monthlyUsedPercent: null, monthlyResetsAt: null, observedAt: now, creditBalancePoints: null }, availability: 'available', reasonCode: null };
    const launched = () => { window.desktopState = { phase: 'launched', launchId: 'synthetic_launch_0123456789', accountId: 'managed_a', issue: null, routingVerified: null }; return structuredClone(window.desktopState); };
    window.__TAURI_INTERNALS__.invoke = async (command, args) => {
      if (command === 'get_local_proxy_status') return structuredClone(window.desktopProxyState);
      if (command === 'get_local_proxy_preferences') return structuredClone(preferences);
      if (command === 'get_local_proxy_accounts') return [structuredClone(account)];
      if (command === 'get_local_proxy_desktop_status') {
        if (window.failDesktopRead) throw 'desktop_state_unknown';
        if (window.holdDesktopPoll) { window.holdDesktopPoll = false; const old = structuredClone(window.desktopState); return new Promise(resolve => { window.releaseDesktopPoll = () => resolve(old); }); }
        return structuredClone(window.desktopState);
      }
      if (command === 'connect_local_proxy_desktop') {
        window.desktopCalls.push({ command, ...args });
        if (args.accountId !== 'managed_a') throw 'identity';
        if (window.failDesktopConnect) throw window.failDesktopConnect;
        if (window.holdDesktopConnect) return new Promise(resolve => { window.finishOldDesktopConnect = () => resolve(launched()); });
        return launched();
      }
      if (command === 'launch_local_proxy_desktop') {
        window.desktopCalls.push({ command, ...args });
        if (args.ticket !== window.desktopState.launchId) throw 'identity';
        if (window.failDesktopLaunch) { window.desktopState.phase = 'failed'; window.desktopState.issue = window.failDesktopLaunch; throw window.failDesktopLaunch; }
        return launched();
      }
      if (command === 'cancel_local_proxy_desktop') {
        window.desktopCalls.push({ command });
        if (window.failDesktopCancel) throw 'lease_cleanup_unconfirmed';
        window.desktopState = { phase: 'stopped', launchId: null, accountId: null, issue: null, routingVerified: null }; return structuredClone(window.desktopState);
      }
      if (command === 'stop_local_proxy') {
        window.desktopCalls.push({ command }); window.desktopProxyState.phase = 'stopped'; window.desktopProxyState.port = null;
        if (window.desktopState.phase === 'launched') window.desktopState.issue = 'desktop_connection_stale';
        return structuredClone(window.desktopProxyState);
      }
      return original(command, args);
    };
  });
  await page.goto('/');
  await page.getByRole('navigation').getByRole('button', { name: language === 'zh-Hans' ? '反代' : 'Proxy', exact: true }).click();
  const panel = page.getByRole('region', { name: language === 'zh-Hans' ? '桌面接入' : 'Desktop connection', exact: true });
  await expect(panel).toHaveAttribute('data-desktop-phase', 'stopped');
  await expect(panel.getByRole('combobox')).toContainText('Synthetic Managed Desktop');
  return panel;
}

test('Connect uses one actual managed account, with no extra confirmation or inferred routing success', async ({ page }) => {
  const panel = await desktopPage(page);
  await expect(panel.getByRole('button', { name: 'Connect Desktop', exact: true })).toBeDisabled();
  await panel.getByRole('combobox', { name: 'Desktop account' }).selectOption('managed_a');
  await panel.getByRole('button', { name: 'Connect Desktop', exact: true }).click();
  await expect(panel).toHaveAttribute('data-desktop-phase', 'launched');
  await expect(panel).toContainText('Desktop launched');
  await expect(panel).toContainText('Routing has not been verified.');
  await expect(panel).not.toContainText('Native routing verification was reported.');
  await expect(page.getByRole('dialog')).toHaveCount(0);
  expect(await page.evaluate(() => window.desktopCalls)).toEqual([{ command: 'connect_local_proxy_desktop', accountId: 'managed_a' }]);
  await expect(panel).toHaveScreenshot('proxy-desktop-launched.png');
});

test('existing or unknown Desktop is rejected without a stop command or a launched claim', async ({ page }) => {
  const panel = await desktopPage(page);
  await panel.getByRole('combobox').selectOption('managed_a');
  await page.evaluate(() => { window.failDesktopConnect = 'desktop_running'; });
  await panel.getByRole('button', { name: 'Connect Desktop', exact: true }).click();
  await expect(panel).toContainText('Quit the running Codex Desktop yourself');
  await expect(panel).toHaveAttribute('data-desktop-phase', 'stopped');
  await expect(panel.getByRole('button', { name: 'Stop Desktop launched by this app' })).toHaveCount(0);
  await page.evaluate(() => { window.failDesktopConnect = 'desktop_state_unknown'; });
  await panel.getByRole('button', { name: 'Connect Desktop', exact: true }).click();
  await expect(panel).toContainText('The existing Desktop state is unconfirmed.');
  expect(await page.evaluate(() => window.desktopCalls.some(call => call.command === 'cancel_local_proxy_desktop'))).toBe(false);
});

test('cancelling an outstanding connection also cleans a late launch before allowing a new connection', async ({ page }) => {
  const panel = await desktopPage(page);
  await panel.getByRole('combobox').selectOption('managed_a');
  await page.evaluate(() => { window.holdDesktopConnect = true; });
  await panel.getByRole('button', { name: 'Connect Desktop', exact: true }).click();
  await expect(panel).toContainText('Connecting Desktop…');
  await panel.getByRole('button', { name: 'Stop Desktop launched by this app', exact: true }).click();
  await expect(panel).toContainText('Completing cancellation…');
  await expect(panel.getByRole('button', { name: 'Connect Desktop', exact: true })).toBeDisabled();
  await expect(panel).not.toContainText('This Desktop connection is stopped.');
  await page.evaluate(() => window.finishOldDesktopConnect());
  await expect(panel).toHaveAttribute('aria-busy', 'false');
  await expect(panel).toHaveAttribute('data-desktop-phase', 'stopped');
  await expect(panel).toContainText('This Desktop connection is stopped.');
  await expect(panel.getByRole('button', { name: 'Connect Desktop', exact: true })).toBeEnabled();
  expect(await page.evaluate(() => window.desktopCalls.map(call => call.command))).toEqual(['connect_local_proxy_desktop', 'cancel_local_proxy_desktop', 'cancel_local_proxy_desktop']);
});

test('a real prepared status stays unlaunched until its reported launch ticket succeeds', async ({ page }) => {
  const panel = await desktopPage(page);
  await page.evaluate(() => { window.desktopState = { phase: 'prepared', launchId: 'synthetic_preparation_0123456789', accountId: 'managed_a', issue: null, routingVerified: null }; });
  await panel.getByRole('button', { name: 'Refresh Desktop status' }).click();
  await expect(panel).toContainText('Prepared, not started');
  await expect(panel.locator('header > [role="status"]')).not.toHaveText('Desktop launched');
  await expect(panel).toHaveScreenshot('proxy-desktop-prepared.png');
  await panel.getByRole('button', { name: 'Launch Desktop', exact: true }).click();
  await expect(panel).toHaveAttribute('data-desktop-phase', 'launched');
  expect(await page.evaluate(() => window.desktopCalls)).toEqual([{ command: 'launch_local_proxy_desktop', ticket: 'synthetic_preparation_0123456789' }]);
});

test('expired preparation never claims launch and its confirmed cleanup permits a fresh connection', async ({ page }) => {
  const panel = await desktopPage(page);
  await page.evaluate(() => { window.desktopState = { phase: 'prepared', launchId: 'synthetic_preparation_0123456789', accountId: 'managed_a', issue: null, routingVerified: null }; window.failDesktopLaunch = 'desktop_preparation_expired'; });
  await panel.getByRole('button', { name: 'Refresh Desktop status' }).click();
  await panel.getByRole('button', { name: 'Launch Desktop', exact: true }).click();
  await expect(panel).toHaveAttribute('data-desktop-phase', 'failed');
  await expect(panel).toContainText('Desktop preparation expired.');
  await expect(panel.locator('header > [role="status"]')).not.toHaveText('Desktop launched');
  await panel.getByRole('button', { name: 'Stop Desktop launched by this app', exact: true }).click();
  await expect(panel).toHaveAttribute('data-desktop-phase', 'stopped');
  await panel.getByRole('combobox').selectOption('managed_a');
  await expect(panel.getByRole('button', { name: 'Connect Desktop', exact: true })).toBeEnabled();
});

test('stopping the proxy preserves the owned Desktop and reports a stale connection until explicit Desktop stop', async ({ page }) => {
  const panel = await desktopPage(page);
  await panel.getByRole('combobox').selectOption('managed_a');
  await panel.getByRole('button', { name: 'Connect Desktop', exact: true }).click();
  await page.getByRole('region', { name: 'Local proxy', exact: true }).getByRole('button', { name: 'Stop', exact: true }).click();
  await panel.getByRole('button', { name: 'Refresh Desktop status', exact: true }).click();
  await expect(panel).toHaveAttribute('data-desktop-phase', 'launched');
  await expect(panel).toContainText('The proxy connection changed.');
  expect(await page.evaluate(() => window.desktopCalls.some(call => call.command === 'cancel_local_proxy_desktop'))).toBe(false);
  await expect(panel).toHaveScreenshot('proxy-desktop-stale.png');
  await panel.getByRole('button', { name: 'Stop Desktop launched by this app', exact: true }).click();
  await expect(panel).toHaveAttribute('data-desktop-phase', 'stopped');
  await expect(panel.getByRole('button', { name: 'Connect Desktop', exact: true })).toBeDisabled();
});

test('failed stop never claims cleanup and a successful retry clears that uncertainty', async ({ page }) => {
  const panel = await desktopPage(page);
  await panel.getByRole('combobox').selectOption('managed_a');
  await panel.getByRole('button', { name: 'Connect Desktop', exact: true }).click();
  await page.evaluate(() => { window.failDesktopCancel = true; });
  await panel.getByRole('button', { name: 'Stop Desktop launched by this app', exact: true }).click();
  await expect(panel).toContainText('Stopping is unconfirmed.');
  await expect(panel).not.toContainText('This Desktop connection is stopped.');
  await expect(panel.getByRole('button', { name: 'Connect Desktop', exact: true })).toBeDisabled();
  await page.evaluate(() => { window.failDesktopCancel = false; });
  await panel.getByRole('button', { name: 'Stop Desktop launched by this app', exact: true }).click();
  await expect(panel).toContainText('This Desktop connection is stopped.');
  await expect(panel).not.toContainText('Stopping is unconfirmed.');
});

test('a late status read cannot erase a newer launch and navigation preserves this connection state', async ({ page }) => {
  const panel = await desktopPage(page);
  await panel.getByRole('combobox').selectOption('managed_a');
  await page.evaluate(() => { window.holdDesktopPoll = true; });
  await expect.poll(() => page.evaluate(() => typeof window.releaseDesktopPoll)).toBe('function');
  await panel.getByRole('button', { name: 'Connect Desktop', exact: true }).click();
  await expect(panel).toHaveAttribute('data-desktop-phase', 'launched');
  await page.evaluate(() => window.releaseDesktopPoll());
  await expect(panel).toHaveAttribute('data-desktop-phase', 'launched');
  await page.getByRole('navigation').getByRole('button', { name: 'Home', exact: true }).click();
  await page.getByRole('navigation').getByRole('button', { name: 'Proxy', exact: true }).click();
  await expect(panel).toHaveAttribute('data-desktop-phase', 'launched');
  expect(await page.evaluate(() => window.desktopCalls.length)).toBe(1);
});

test('unavailable status removes the launch claim but preserves the explicit owned-process stop action', async ({ page }) => {
  const panel = await desktopPage(page);
  await panel.getByRole('combobox').selectOption('managed_a');
  await panel.getByRole('button', { name: 'Connect Desktop', exact: true }).click();
  await page.evaluate(() => { window.failDesktopRead = true; });
  await panel.getByRole('button', { name: 'Refresh Desktop status' }).click();
  await expect(panel).toHaveAttribute('data-desktop-phase', 'unknown');
  await expect(panel.locator('header > [role="status"]')).toHaveText('Status unconfirmed');
  await expect(panel.getByRole('button', { name: 'Connect Desktop', exact: true })).toBeDisabled();
  await panel.getByRole('button', { name: 'Stop Desktop launched by this app', exact: true }).click();
  await expect(panel).toHaveAttribute('data-desktop-phase', 'stopped');
});

for (const scenario of [{ language: 'zh-Hans', theme: 'light', width: 1280 }, { language: 'zh-Hans', theme: 'dark', width: 480 }]) {
  test(`Desktop layout ${scenario.language} ${scenario.theme} ${scenario.width}`, async ({ page }) => {
    await page.setViewportSize({ width: scenario.width, height: 1000 });
    const panel = await desktopPage(page, scenario);
    await panel.getByRole('combobox').selectOption('managed_a');
    await panel.getByRole('button', { name: '接入桌面', exact: true }).click();
    await expect(panel).toContainText('Desktop 已启动');
    await expect(panel).toContainText('路由尚未验证。');
    expect(await page.locator('body').evaluate(node => node.scrollWidth <= innerWidth)).toBe(true);
    await expect(panel).toHaveScreenshot(`proxy-desktop-${scenario.theme}-${scenario.language}-${scenario.width}.png`);
  });
}
