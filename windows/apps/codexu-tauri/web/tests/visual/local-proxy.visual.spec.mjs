import { test, expect } from '@playwright/test';
import { FIXED_NOW_ISO, SYNTHETIC_DASHBOARD, SYNTHETIC_SETTINGS } from './synthetic-fixtures.mjs';
import { installTauriStub } from './tauri-stub.mjs';

async function proxyPage(page, { language = 'en', theme = 'dark' } = {}) {
  await page.clock.setFixedTime(new Date(FIXED_NOW_ISO));
  await installTauriStub(page, { settings: { ...SYNTHETIC_SETTINGS, language, theme }, dashboard: SYNTHETIC_DASHBOARD }, () => {
    const original = window.__TAURI_INTERNALS__.invoke;
    const now = Date.now() / 1000;
    window.proxyPrefs = { schemaVersion: 1, isEnabled: false, automaticRecoveryEnabled: false, order: ['b', 'a', 'c'], enabledIds: ['a', 'b'], knownIds: ['a', 'b', 'c'], priorityIds: [], lastIds: [], lastOverrides: {}, creditFallback: false, creditPrimaryFloor: 2000, creditSecondaryFloor: 1500, accountPolicies: { a: { fiveHourUsedLimit: 80, allowsCredits: true, creditPrimaryFloor: null, creditSecondaryFloor: null } }, resetStopRules: { a: { identityHash: '0'.repeat(64), armedAt: now - 10, pausedAt: null, previousResetAt: null } }, listenPort: 18080, clientKeyMode: 'persistent', desktopFallback: false, networkProxy: '', egress: { enabled: false, mihomoApi: '', group: '', whitelist: [] } };
    window.proxyState = { phase: 'stopped', port: null, issue: null, accounts: { a: { state: 'ready', cooldownUntil: null, cooldownKind: null, probeState: null }, b: { state: 'future_unknown_state', cooldownUntil: null, cooldownKind: null, probeState: null }, c: { state: 'quota_unknown', cooldownUntil: null, cooldownKind: null, probeState: null } }, lastEventAt: now, egress: null };
    window.proxyCatalog = [
      { id: 'a', label: 'Synthetic Plus A', planType: 'plus', quota: { fiveHourUsedPercent: 29, fiveHourResetsAt: now + 3600, sevenDayUsedPercent: 63, sevenDayResetsAt: now + 86400, monthlyUsedPercent: null, monthlyResetsAt: null, observedAt: now, creditBalancePoints: '2400' }, availability: 'available', reasonCode: null },
      { id: 'b', label: 'Synthetic Pro B', planType: 'pro', quota: { fiveHourUsedPercent: null, fiveHourResetsAt: null, sevenDayUsedPercent: 0, sevenDayResetsAt: now + 86400, monthlyUsedPercent: null, monthlyResetsAt: null, observedAt: now, creditBalancePoints: '6000' }, availability: 'available', reasonCode: null },
      { id: 'c', label: 'Synthetic Plus C', planType: 'plus', quota: null, availability: 'unknown', reasonCode: 'quota_unknown' },
    ];
    window.proxyWrites = [];
    window.proxyReads = [];
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: async value => { window.proxyCopied = value; } } });
    const accounts = () => window.proxyCatalog.map(a => ({ ...a, isEnabled: window.proxyPrefs.enabledIds.includes(a.id), isPriority: window.proxyPrefs.priorityIds.includes(a.id), isLast: window.proxyPrefs.lastOverrides[a.id] ?? (window.proxyPrefs.lastIds.includes(a.id) || ['pro', 'prolite'].includes(a.planType)) }));
    window.__TAURI_INTERNALS__.invoke = async (command, args) => {
      if (['get_local_proxy_status', 'get_local_proxy_preferences', 'get_local_proxy_accounts', 'refresh_local_proxy_accounts', 'get_local_proxy_connection'].includes(command)) window.proxyReads.push(command);
      if (command === 'get_local_proxy_status') {
        if (window.failProxyStatus) throw Error('synthetic private path must stay hidden');
        if (window.holdProxyPoll) { window.holdProxyPoll = false; const old = structuredClone(window.proxyState); return new Promise(resolve => { window.releaseProxyPoll = () => resolve(old); }); }
        return structuredClone(window.proxyState);
      }
      if (command === 'get_local_proxy_desktop_status') return { phase: 'stopped', launchId: null, accountId: null, issue: null, routingVerified: null };
      if (command === 'get_local_proxy_preferences') return structuredClone(window.proxyPrefs);
      if (command === 'get_local_proxy_accounts' || command === 'refresh_local_proxy_accounts') { if (window.failProxyAccounts) throw 'account_service_unavailable'; return structuredClone(accounts()); }
      if (command === 'set_local_proxy_preferences') {
        window.proxyWrites.push({ command, preferences: structuredClone(args.preferences) });
        if (window.failProxySave) throw 'save_failed';
        if (window.holdProxySave) return new Promise(resolve => { window.finishProxySave = () => { window.proxyPrefs = structuredClone(args.preferences); resolve(structuredClone(window.proxyPrefs)); }; });
        window.proxyPrefs = structuredClone(args.preferences); return structuredClone(window.proxyPrefs);
      }
      if (command === 'set_local_proxy_plus_five_hour_used_limit') {
        window.proxyWrites.push({ command, limit: args.limit });
        for (const a of window.proxyCatalog.filter(a => a.planType === 'plus')) window.proxyPrefs.accountPolicies[a.id] = { fiveHourUsedLimit: args.limit, allowsCredits: true, creditPrimaryFloor: null, creditSecondaryFloor: null };
        return structuredClone(window.proxyPrefs);
      }
      if (command === 'start_local_proxy' || command === 'stop_local_proxy') {
        window.proxyWrites.push({ command });
        if (command === 'start_local_proxy' && window.failProxyStart) throw 'helper_unavailable';
        window.proxyState = { ...window.proxyState, phase: command === 'start_local_proxy' ? 'running' : 'stopped', port: command === 'start_local_proxy' ? 18080 : null };
        return structuredClone(window.proxyState);
      }
      if (command === 'get_local_proxy_connection') return { endpoint: 'http://127.0.0.1:18080/v1', clientKey: 'SYNTHETIC_CLIENT_KEY_NOT_REAL_0123456789' };
      if (command === 'local_proxy_network_command') { window.proxyWrites.push({ command, request: args.command, requestId: args.requestId }); return null; }
      return original(command, args);
    };
  });
  await page.goto('/');
  await page.getByRole('navigation').getByRole('button', { name: language === 'zh-Hans' ? '反代' : 'Proxy', exact: true }).click();
  const panel = page.getByRole('region', { name: language === 'zh-Hans' ? '本地反代' : 'Local proxy', exact: true });
  await expect(panel).toHaveAttribute('data-proxy-phase', 'stopped');
  await expect(panel.getByTestId('proxy-account-b')).toBeVisible();
  return panel;
}

test('real cached fields render stable manual order, used-to-remaining quota and unknown states', async ({ page }) => {
  const panel = await proxyPage(page);
  const a = panel.getByTestId('proxy-account-a'), b = panel.getByTestId('proxy-account-b'), c = panel.getByTestId('proxy-account-c');
  expect(await panel.locator('.proxy-account').evaluateAll(rows => rows.map(row => row.dataset.testid))).toEqual(['proxy-account-b', 'proxy-account-a', 'proxy-account-c']);
  await expect(b.locator('.account-directory-number')).toHaveText('01');
  await expect(a.getByRole('img', { name: '5h · 71% remaining', exact: true })).toBeVisible();
  await expect(a.getByRole('img', { name: '7d · 37% remaining', exact: true })).toBeVisible();
  await expect(a.locator('.quota-ring')).toHaveCount(2);
  await expect(a).toHaveAttribute('data-availability', 'available');
  await expect(a.locator('.quota-ring.is-stale')).toHaveCount(0);
  await expect(b).toContainText('5h · No window');
  await expect(b).toContainText('Unconfirmed');
  await expect(b).not.toContainText('future_unknown_state');
  await expect(c.locator('.quota-ring[data-known="false"]')).toHaveCount(2);
  await expect(c).not.toContainText('No window');
  await expect(c).not.toContainText('∞');
  expect(await b.getByRole('button', { name: 'Enabled', exact: true }).evaluate(node => getComputedStyle(node).backgroundColor)).toBe('rgb(37, 99, 235)');
  expect(await c.getByRole('button', { name: 'Disabled', exact: true }).evaluate(node => getComputedStyle(node).backgroundColor)).not.toBe('rgb(37, 99, 235)');
  expect(await page.evaluate(() => window.proxyReads.includes('refresh_local_proxy_accounts'))).toBe(false);
  await expect(panel).toHaveScreenshot('local-proxy-dark-en.png');
});

test('participation never reorders cards; Pro last-use is cancellable and excludes priority', async ({ page }) => {
  const panel = await proxyPage(page);
  const b = panel.getByTestId('proxy-account-b'), c = panel.getByTestId('proxy-account-c');
  const before = await page.evaluate(() => structuredClone(window.proxyPrefs));
  await c.getByRole('button', { name: 'Disabled', exact: true }).click();
  await expect(c.getByRole('button', { name: 'Enabled', exact: true })).toBeEnabled();
  const after = await page.evaluate(() => structuredClone(window.proxyPrefs));
  expect(after.enabledIds).toEqual(['a', 'b', 'c']);
  expect({ ...after, enabledIds: before.enabledIds }).toEqual(before);
  await expect(b.getByRole('checkbox', { name: 'Use last', exact: true })).toBeChecked();
  await b.getByRole('checkbox', { name: 'Use last', exact: true }).uncheck();
  await expect(b.getByRole('checkbox', { name: 'Use last', exact: true })).not.toBeChecked();
  expect(await page.evaluate(() => window.proxyPrefs.lastOverrides.b)).toBe(false);
  await b.getByRole('checkbox', { name: 'Priority', exact: true }).check();
  await expect(b.getByRole('checkbox', { name: 'Priority', exact: true })).toBeChecked();
  await expect(b.getByRole('checkbox', { name: 'Use last', exact: true })).not.toBeChecked();
  await b.getByRole('checkbox', { name: 'Use last', exact: true }).check();
  await expect(b.getByRole('checkbox', { name: 'Priority', exact: true })).not.toBeChecked();
  await expect(b.getByRole('checkbox', { name: 'Use last', exact: true })).toBeChecked();
  expect(await page.evaluate(() => window.proxyPrefs.order)).toEqual(['b', 'a', 'c']);
  expect(await panel.locator('.proxy-account').evaluateAll(rows => rows.map(row => row.dataset.testid))).toEqual(['proxy-account-b', 'proxy-account-a', 'proxy-account-c']);
  await b.locator('.account-more > summary').click();
  await b.getByRole('button', { name: 'Move down' }).click();
  expect(await panel.locator('.proxy-account').evaluateAll(rows => rows.map(row => row.dataset.testid))).toEqual(['proxy-account-a', 'proxy-account-b', 'proxy-account-c']);
});

test('a failed rule save keeps the draft; only a successful reply changes the committed limit', async ({ page }) => {
  const panel = await proxyPage(page);
  const a = panel.getByTestId('proxy-account-a');
  await a.locator('.proxy-rule-editor > summary').click();
  await a.getByLabel('5h used limit %', { exact: true }).fill('25');
  await page.evaluate(() => { window.failProxySave = true; });
  await a.getByRole('button', { name: 'Save rules', exact: true }).click();
  await expect(a).toContainText('Saving failed. The draft has been kept.');
  await expect(a.locator('.proxy-rule-editor > summary')).toContainText('Saved limit 80%');
  await expect(a.getByLabel('5h used limit %', { exact: true })).toHaveValue('25');
  await expect(a).not.toContainText('Rules saved.');
  await expect(a).toHaveScreenshot('local-proxy-rule-failed.png');
  await page.evaluate(() => { window.failProxySave = false; });
  await panel.getByTestId('proxy-account-c').getByRole('button', { name: 'Disabled', exact: true }).click();
  await expect(a.getByLabel('5h used limit %', { exact: true })).toHaveValue('25');
  await expect(a.locator('.proxy-rule-editor > summary')).toContainText('Saved limit 80%');
  await page.evaluate(() => { window.failProxySave = false; window.holdProxySave = true; });
  await a.getByRole('button', { name: 'Save rules', exact: true }).click();
  await expect(a.getByLabel('5h used limit %', { exact: true })).toBeDisabled();
  await expect(a.locator('.proxy-rule-editor > summary')).toContainText('Saved limit 80%');
  await page.evaluate(() => window.finishProxySave());
  await expect(a.locator('.proxy-rule-editor > summary')).toContainText('Saved limit 25%');
  await expect(a).toContainText('Rules saved.');
  expect(await page.evaluate(() => window.proxyPrefs.resetStopRules.a.identityHash)).toBe('0'.repeat(64));
});

test('Plus shared limit uses the native bulk command and leaves other plans unchanged', async ({ page }) => {
  const panel = await proxyPage(page);
  await panel.getByLabel('Shared Plus 5h used limit %', { exact: true }).fill('65');
  await panel.getByRole('button', { name: 'Apply to Plus' }).click();
  await expect(panel).toContainText('The Plus 5h used limit is saved.');
  await expect(panel.getByTestId('proxy-account-a')).toContainText('Saved limit 65%');
  await expect(panel.getByTestId('proxy-account-c')).toContainText('Saved limit 65%');
  await expect(panel.getByTestId('proxy-account-b')).toContainText('Saved limit 100%');
  expect(await page.evaluate(() => window.proxyWrites)).toEqual([{ command: 'set_local_proxy_plus_five_hour_used_limit', limit: 65 }]);
});

test('start, explicit copy, submitted self-check and stop follow real command results without exposing credentials', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 1050 });
  const panel = await proxyPage(page);
  expect(await page.evaluate(() => window.proxyReads.includes('get_local_proxy_connection'))).toBe(false);
  await panel.getByRole('button', { name: 'Start', exact: true }).click();
  await expect(panel).toHaveAttribute('data-proxy-phase', 'running');
  await expect(panel).toContainText('http://127.0.0.1:18080/v1');
  await panel.locator('.proxy-settings > summary').click();
  await expect(panel.getByLabel('Listen port', { exact: true })).toBeDisabled();
  await panel.getByRole('button', { name: 'Network self-check' }).click();
  await expect(panel).toContainText('Self-check requested. Refer to the reported status for results.');
  await expect(panel).not.toContainText('Self-check passed');
  const selfCheck = await page.evaluate(() => window.proxyWrites.find(write => write.command === 'local_proxy_network_command'));
  expect(selfCheck.request).toBe('self_check');
  expect(selfCheck.requestId).toMatch(/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/);
  await page.evaluate(() => { window.proxyState.egress = { state: 'healthy', requestId: '00000000-0000-0000-0000-000000000000', latencyMs: 1 }; });
  await expect(panel).toContainText('Waiting for this self-check result.');
  await expect(panel).not.toContainText('This self-check · Reachable');
  await page.evaluate(requestId => { window.proxyState.egress = { state: 'healthy', requestId, latencyMs: 12 }; }, selfCheck.requestId);
  await expect(panel).toContainText('This self-check · Reachable · 12 ms');
  await panel.locator('.proxy-settings > summary').click();
  await expect(panel).toHaveScreenshot('local-proxy-self-check-result.png');
  await panel.getByRole('button', { name: 'Copy connection', exact: true }).click();
  expect(await page.evaluate(() => window.proxyCopied)).toBe('OPENAI_BASE_URL=http://127.0.0.1:18080/v1\nOPENAI_API_KEY=SYNTHETIC_CLIENT_KEY_NOT_REAL_0123456789');
  await expect(panel).not.toContainText('SYNTHETIC_CLIENT_KEY');
  expect(await page.evaluate(() => JSON.stringify(localStorage))).not.toContain('SYNTHETIC_CLIENT_KEY');
  await panel.getByRole('button', { name: 'Stop', exact: true }).click();
  await expect(panel).toHaveAttribute('data-proxy-phase', 'stopped');
  await expect(panel.getByRole('button', { name: 'Copy connection', exact: true })).toBeDisabled();
  expect((await page.evaluate(() => window.proxyWrites)).slice(0, 2).map(write => write.command)).toEqual(['set_local_proxy_preferences', 'start_local_proxy']);
});

test('failed startup cannot claim running; invalid and failed settings saves preserve the draft and existing fields', async ({ page }) => {
  const panel = await proxyPage(page);
  await page.evaluate(() => { window.failProxyStart = true; });
  await panel.getByRole('button', { name: 'Start', exact: true }).click();
  await expect(panel).toContainText('The proxy helper is unavailable');
  await expect(panel).toHaveAttribute('data-proxy-phase', 'stopped');
  await expect(panel.getByRole('button', { name: 'Copy connection', exact: true })).toBeDisabled();
  await panel.locator('.proxy-settings > summary').click();
  await panel.getByLabel('Listen port', { exact: true }).fill('1000');
  await panel.getByRole('button', { name: 'Save settings' }).click();
  await expect(panel).toContainText('Invalid settings.');
  expect(await page.evaluate(() => window.proxyPrefs.listenPort)).toBe(18080);
  await panel.getByLabel('Listen port', { exact: true }).fill('19080');
  await page.evaluate(() => { window.failProxySave = true; });
  await panel.getByRole('button', { name: 'Save settings' }).click();
  await expect(panel).toContainText('Saving failed. Your edits have been kept.');
  await expect(panel.getByLabel('Listen port', { exact: true })).toHaveValue('19080');
  await expect(panel).not.toContainText('Settings saved.');
  expect(await page.evaluate(() => window.proxyPrefs.listenPort)).toBe(18080);
  await page.evaluate(() => { window.failProxySave = false; });
  await panel.getByRole('button', { name: 'Save settings' }).click();
  await expect(panel).toContainText('Settings saved.');
  expect(await page.evaluate(() => window.proxyPrefs.listenPort)).toBe(19080);
  expect(await page.evaluate(() => window.proxyPrefs.resetStopRules.a.identityHash)).toBe('0'.repeat(64));
});

test('a late status poll cannot overwrite a newer start result, and unavailable polling clears the running claim', async ({ page }) => {
  const panel = await proxyPage(page);
  await page.evaluate(() => { window.holdProxyPoll = true; });
  await expect.poll(() => page.evaluate(() => typeof window.releaseProxyPoll)).toBe('function');
  await panel.getByRole('button', { name: 'Start', exact: true }).click();
  await expect(panel).toHaveAttribute('data-proxy-phase', 'running');
  await page.evaluate(() => window.releaseProxyPoll());
  await expect(panel).toHaveAttribute('data-proxy-phase', 'running');
  await page.evaluate(() => { window.failProxyStatus = true; });
  await expect(panel).toHaveAttribute('data-proxy-phase', 'unknown');
  await expect(panel).toContainText('Status unconfirmed');
  await expect(panel.getByRole('button', { name: 'Copy connection', exact: true })).toBeDisabled();
  await expect(panel).not.toContainText('synthetic private path');
});

test('only an explicit quota refresh requests official reads; projection failures mark the last real values as stale', async ({ page }) => {
  const panel = await proxyPage(page);
  const a = panel.getByTestId('proxy-account-a');
  await page.evaluate(() => { window.proxyCatalog[0].quota.monthlyUsedPercent = 20; });
  await panel.getByRole('button', { name: 'Refresh quota', exact: true }).click();
  await expect(a.getByRole('img', { name: 'Monthly · 80% remaining', exact: true })).toBeVisible();
  expect(await page.evaluate(() => window.proxyReads.filter(command => command === 'refresh_local_proxy_accounts').length)).toBe(1);
  await page.evaluate(() => { window.failProxyAccounts = true; });
  await expect(a).toHaveAttribute('data-availability', 'unknown');
  await expect(a.locator('.quota-ring.is-stale[data-known="true"]')).toHaveCount(3);
  await expect(a.getByRole('img', { name: 'Last snapshot · Monthly · 80% remaining', exact: true })).toBeVisible();
  await expect(a).toContainText('Refresh to confirm available quota.');
  expect(await page.evaluate(() => window.proxyReads.filter(command => command === 'refresh_local_proxy_accounts').length)).toBe(1);
});

test('a real stale snapshot retains quota and reset times without claiming current availability or credits', async ({ page }) => {
  const panel = await proxyPage(page);
  await page.evaluate(() => { window.proxyCatalog[0].availability = 'unknown'; window.proxyCatalog[0].reasonCode = 'evidence_stale'; });
  await panel.getByRole('button', { name: 'Refresh proxy status', exact: true }).click();
  const a = panel.getByTestId('proxy-account-a'), c = panel.getByTestId('proxy-account-c');
  await expect(a).toHaveAttribute('data-availability', 'unknown');
  await expect(a.getByRole('img', { name: 'Last snapshot · 5h · 71% remaining', exact: true })).toBeVisible();
  await expect(a.getByRole('img', { name: 'Last snapshot · 7d · 37% remaining', exact: true })).toBeVisible();
  await expect(a.locator('.quota-ring.is-stale[data-known="true"]')).toHaveCount(2);
  await expect(a).toContainText('Snapshot reset');
  await a.locator('.proxy-info > summary').click();
  await expect(a).not.toContainText('Credits 2400');
  await expect(c.locator('.quota-ring[data-known="false"]')).toHaveCount(2);
  expect(await page.evaluate(() => window.proxyReads.includes('refresh_local_proxy_accounts'))).toBe(false);
  await expect(a).toHaveScreenshot('local-proxy-stale-snapshot.png');
});

for (const scenario of [{ language: 'zh-Hans', theme: 'light', width: 1280 }, { language: 'zh-Hans', theme: 'dark', width: 480 }]) {
  test(`proxy translated layout ${scenario.language} ${scenario.theme} ${scenario.width}`, async ({ page }) => {
    await page.setViewportSize({ width: scenario.width, height: 1000 });
    const panel = await proxyPage(page, scenario);
    await panel.locator('.proxy-settings > summary').click();
    expect(await page.locator('body').evaluate(node => node.scrollWidth <= innerWidth)).toBe(true);
    expect(await panel.locator('.account-directory-number').first().evaluate(node => node.scrollHeight <= node.clientHeight)).toBe(true);
    await expect(panel.getByTestId('proxy-account-a').getByRole('img', { name: '5h · 剩余 71%', exact: true })).toBeVisible();
    await expect(panel.locator('.proxy-settings')).toHaveScreenshot(`local-proxy-${scenario.language}-${scenario.theme}-${scenario.width}-settings.png`);
    if (scenario.width < 600) {
      await page.locator('.workspace-main').evaluate(node => { node.scrollTop = 0; });
      await expect(page).toHaveScreenshot(`local-proxy-${scenario.language}-${scenario.theme}-${scenario.width}-top.png`);
    } else { await panel.locator('.proxy-settings > summary').click(); await expect(panel).toHaveScreenshot(`local-proxy-${scenario.language}-${scenario.theme}-${scenario.width}.png`); }
  });
}
