import { test, expect } from '@playwright/test';
import { FIXED_NOW_ISO, SYNTHETIC_DASHBOARD, SYNTHETIC_SETTINGS } from './synthetic-fixtures.mjs';
import { installTauriStub } from './tauri-stub.mjs';

async function updateSettings(page, language = 'en') {
  await page.clock.setFixedTime(new Date(FIXED_NOW_ISO));
  await installTauriStub(page, { settings: { ...SYNTHETIC_SETTINGS, language }, dashboard: SYNTHETIC_DASHBOARD, windowLabel: 'settings' }, () => {
    const invoke = window.__TAURI_INTERNALS__.invoke;
    const info = { current_version: '3.0.0', available_version: '3.1.0', release_notes: 'Synthetic release notes\n<img src=x onerror="window.releaseHTMLExecuted=true">', published_at: '2026-09-15T12:00:00Z', can_download: true, asset_name: 'AiGoodBro-3.1.0-windows-x86_64.msi', asset_size: 10485760, reason_code: null };
    let callback;
    let state = { phase: 'idle', info: { ...info, available_version: null, release_notes: '', asset_name: null, asset_size: null, can_download: false }, error_code: null };
    window.updateCalls = [];
    window.updateLifecycle = [];
    window.updateListenWaiters = [];
    window.emitUpdate = next => { state = next; if (callback) window[`_${callback}`]({ event: 'app-update:changed', id: 171, payload: structuredClone(next) }); };
    window.__TAURI_INTERNALS__.invoke = async (command, args) => {
      if (command === 'plugin:event|listen' && args.event === 'app-update:changed') {
        window.updateLifecycle.push('listen'); callback = args.handler;
        return new Promise(resolve => window.updateListenWaiters.push(() => resolve(171)));
      }
      if (command === 'get_app_update_state') {
        window.updateLifecycle.push('read');
        if (window.holdInitialUpdate) return new Promise(resolve => { window.releaseInitialUpdate = () => resolve({ phase: 'idle' }); });
        return structuredClone(state);
      }
      if (command.endsWith('_app_update')) {
        window.updateCalls.push(command);
        if (command === 'check_app_update') {
          if (window.holdUpdateChecks) return new Promise(resolve => {
            window.pendingUpdateChecks = window.pendingUpdateChecks || [];
            window.pendingUpdateChecks.push(() => resolve({ phase: 'available', info }));
          });
          if (window.failUpdate) throw Error('synthetic transport failure');
          state = window.noUpdate ? { phase: 'up_to_date', info: { ...info, available_version: null, can_download: false } }
            : { phase: 'available', info: { ...info, can_download: !window.unsupportedUpdate, reason_code: window.unsupportedUpdate ? 'unsupported_architecture' : null } };
          return structuredClone(state);
        }
        if (command === 'download_app_update') {
          window.emitUpdate({ phase: 'downloading', info });
          return new Promise(resolve => {
            window.finishDownload = phase => { window.emitUpdate({ phase, info }); resolve({ phase, info }); };
            window.finishOldDownload = phase => resolve({ phase, info });
          });
        }
        if (command === 'cancel_app_update') { window.emitUpdate({ phase: 'cancelled', info }); return structuredClone(state); }
        if (command === 'open_app_update') {
          window.emitUpdate({ phase: 'opening', info });
          if (window.holdInstallerOpen) return new Promise(resolve => { window.finishInstallerOpen = () => { window.emitUpdate({ phase: 'installer_opened', info }); resolve(structuredClone(state)); }; });
          window.emitUpdate({ phase: 'installer_opened', info }); return structuredClone(state);
        }
      }
      return invoke(command, args);
    };
  });
  await page.goto('/');
  await expect(page.getByRole('region', { name: language === 'en' ? 'App updates' : '应用更新', exact: true })).toHaveAttribute('data-update-phase', 'idle');
  await expect.poll(() => page.evaluate(() => window.updateListenWaiters.length)).toBeGreaterThan(0);
  await page.evaluate(() => {
    // AboutCredits reads the version independently. Require a fresh panel read
    // after listener acknowledgement, not the first read across all Settings.
    window.updateLifecycle.push('listeners-ready');
    window.updateListenWaiters.splice(0).forEach(release => release());
  });
}

test('check, download, verify and explicit installer opening stay separate; release notes remain plain text', async ({ page }) => {
  await updateSettings(page);
  const panel = page.getByRole('region', { name: 'App updates', exact: true });
  await expect.poll(() => page.evaluate(() => {
    const ready = window.updateLifecycle.indexOf('listeners-ready');
    return ready >= 0 && window.updateLifecycle.slice(ready + 1).includes('read');
  })).toBe(true);
  const lifecycle = await page.evaluate(() => window.updateLifecycle);
  const ready = lifecycle.indexOf('listeners-ready');
  expect(lifecycle.slice(0, ready)).toContain('listen');
  expect(lifecycle.indexOf('read', ready + 1)).toBeGreaterThan(ready);
  await panel.getByRole('button', { name: 'Check for updates' }).click();
  await expect(panel).toContainText('Available version 3.1.0');
  await panel.getByText('Release notes', { exact: true }).click();
  await expect(panel).toContainText('<img src=x onerror=');
  await expect(panel.locator('img')).toHaveCount(0);
  expect(await page.evaluate(() => window.releaseHTMLExecuted)).toBeUndefined();
  await expect(panel).toHaveScreenshot('app-update-available.png');
  await panel.getByRole('button', { name: 'Download update' }).click();
  await expect(panel).toHaveAttribute('data-update-phase', 'downloading');
  await expect(panel.getByRole('button', { name: 'Open installer' })).toHaveCount(0);
  await page.evaluate(() => window.emitUpdate({ phase: 'verifying', info: { current_version: '3.0.0', release_notes: '', can_download: true } }));
  await expect(panel).toHaveAttribute('data-update-phase', 'verifying');
  await expect(panel.getByRole('button', { name: 'Open installer' })).toHaveCount(0);
  await expect(panel).toHaveScreenshot('app-update-verifying.png');
  await page.evaluate(() => window.finishDownload('downloaded'));
  await expect(panel).toHaveScreenshot('app-update-downloaded.png');
  await page.evaluate(() => { window.holdInstallerOpen = true; });
  await panel.getByRole('button', { name: 'Open installer' }).click();
  await expect(panel).toHaveAttribute('data-update-phase', 'opening');
  await expect(panel).toContainText('Opening the installer');
  await expect(panel.getByRole('button', { name: /Download update|Open installer|Cancel/ })).toHaveCount(0);
  await expect(panel.getByRole('button', { name: 'Check for updates' })).toBeDisabled();
  await expect(panel).toHaveScreenshot('app-update-opening.png');
  await page.evaluate(() => window.finishInstallerOpen());
  await expect(panel).toHaveAttribute('data-update-phase', 'installer_opened');
  await expect(panel).toContainText('Continue in the Windows installer window');
  await expect(panel.getByRole('button', { name: /Download update|Open installer|Cancel/ })).toHaveCount(0);
  await expect(panel.getByRole('button', { name: 'Check for updates' })).toBeDisabled();
  expect(await page.evaluate(() => window.updateCalls)).toEqual(['check_app_update', 'download_app_update', 'open_app_update']);
  await expect(panel).toHaveScreenshot('app-update-installer-opened.png');
});

test('cancellation revokes a held download and a late completion cannot claim success', async ({ page }) => {
  await updateSettings(page);
  const panel = page.getByRole('region', { name: 'App updates', exact: true });
  await panel.getByRole('button', { name: 'Check for updates' }).click();
  await panel.getByRole('button', { name: 'Download update' }).click();
  await panel.getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(panel).toHaveAttribute('data-update-phase', 'cancelled');
  await page.evaluate(() => window.finishOldDownload('downloaded'));
  await expect(panel).toHaveAttribute('data-update-phase', 'cancelled');
  await expect(panel.getByRole('button', { name: 'Open installer' })).toHaveCount(0);
  expect(await page.evaluate(() => window.updateCalls)).toEqual(['check_app_update', 'download_app_update', 'cancel_app_update']);
  await expect(panel).toHaveScreenshot('app-update-cancelled.png');
});

test('failed or unsupported checks cannot claim latest or offer a download', async ({ page }) => {
  await updateSettings(page, 'zh-Hans');
  const panel = page.getByRole('region', { name: '应用更新', exact: true });
  await page.evaluate(() => { window.failUpdate = true; });
  await panel.getByRole('button', { name: '检查更新' }).click();
  await expect(panel).toHaveAttribute('data-update-phase', 'failed');
  await expect(panel).not.toContainText('已是最新');
  await expect(panel.getByRole('button', { name: '下载更新' })).toHaveCount(0);
  await expect(panel).toHaveScreenshot('app-update-failed-zh.png');
  await page.evaluate(() => { window.failUpdate = false; window.unsupportedUpdate = true; });
  await panel.getByRole('button', { name: '检查更新' }).click();
  await expect(panel).toHaveAttribute('data-update-phase', 'available');
  await expect(panel.getByRole('button', { name: '下载更新' })).toHaveCount(0);
  await expect(panel).toContainText('没有适用于当前 Windows 平台的安装包');
});


test('a late initial read cannot overwrite a newer reported update state', async ({ page }) => {
  await page.addInitScript(() => { window.holdInitialUpdate = true; });
  await updateSettings(page);
  const panel = page.getByRole('region', { name: 'App updates', exact: true });
  await expect.poll(() => page.evaluate(() => typeof window.releaseInitialUpdate)).toBe('function');
  await page.evaluate(() => window.emitUpdate({ phase: 'available', info: { current_version: '3.0.0', available_version: '3.1.0', release_notes: 'Synthetic current event', can_download: true } }));
  await expect(panel).toHaveAttribute('data-update-phase', 'available');
  await page.evaluate(() => window.releaseInitialUpdate());
  await expect(panel).toHaveAttribute('data-update-phase', 'available');
  await expect(panel.getByRole('button', { name: 'Download update' })).toBeVisible();
});


test('only a successful reported check may show up to date; a later failed check clears that claim', async ({ page }) => {
  await updateSettings(page);
  const panel = page.getByRole('region', { name: 'App updates', exact: true });
  await page.evaluate(() => { window.noUpdate = true; });
  await panel.getByRole('button', { name: 'Check for updates' }).click();
  await expect(panel).toHaveAttribute('data-update-phase', 'up_to_date');
  await expect(panel).toContainText('This version is up to date');
  await page.evaluate(() => { window.failUpdate = true; });
  await panel.getByRole('button', { name: 'Check for updates' }).click();
  await expect(panel).toHaveAttribute('data-update-phase', 'failed');
  await expect(panel).not.toContainText('up to date');
  await expect(panel).not.toContainText('synthetic transport failure');
  await expect(panel.getByRole('button', { name: 'Download update' })).toHaveCount(0);
});

test('an old same-command completion cannot release a newer pending operation after cancellation', async ({ page }) => {
  await updateSettings(page);
  const panel = page.getByRole('region', { name: 'App updates', exact: true });
  const check = panel.getByRole('button', { name: 'Check for updates' });
  await page.evaluate(() => { window.holdUpdateChecks = true; });
  await check.click();
  await expect.poll(() => page.evaluate(() => window.pendingUpdateChecks?.length)).toBe(1);
  await panel.getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(panel).toHaveAttribute('data-update-phase', 'cancelled');
  await check.click();
  await expect.poll(() => page.evaluate(() => window.pendingUpdateChecks?.length)).toBe(2);
  await page.evaluate(() => window.pendingUpdateChecks[0]());
  await expect(check).toBeDisabled();
  await expect(panel).toHaveAttribute('data-update-phase', 'cancelled');
  await page.evaluate(() => window.pendingUpdateChecks[1]());
  await expect(panel).toHaveAttribute('data-update-phase', 'available');
  await expect(check).toBeEnabled();
  await expect(panel.getByRole('button', { name: 'Download update' })).toBeEnabled();
});
