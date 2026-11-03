import {test, expect} from '@playwright/test';
import {installTauriStub} from './tauri-stub.mjs';
import {SYNTHETIC_DASHBOARD, SYNTHETIC_SETTINGS} from './synthetic-fixtures.mjs';

test('actual Settings and compact window share saved appearance through the App runtime', async ({page, context}) => {
  await installTauriStub(page, {settings: {...SYNTHETIC_SETTINGS, language: 'en'}, dashboard: SYNTHETIC_DASHBOARD, windowLabel: 'settings'});
  await page.goto('/');
  const panel = page.getByRole('region', {name: 'Glass and motion', exact: true});
  await panel.getByRole('slider', {name: 'Glass', exact: true}).fill('41');
  await expect(panel.locator('p[role="status"]')).toHaveText('Appearance settings saved.');
  await expect.poll(() => page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--appearance-opacity'))).toBe('41%');
  const compact = await context.newPage();
  await installTauriStub(compact, {settings: {...SYNTHETIC_SETTINGS, language: 'en'}, dashboard: SYNTHETIC_DASHBOARD, windowLabel: 'token-monitor-popover'});
  await compact.goto('/');
  await expect.poll(() => compact.evaluate(() => document.documentElement.dataset.workspaceAppearance)).toBe('enabled');
  await expect.poll(() => compact.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--appearance-opacity'))).toBe('41%');
  await panel.getByRole('slider', {name: 'Glass', exact: true}).fill('52');
  await expect.poll(() => compact.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--appearance-opacity'))).toBe('52%');
  await compact.close();
});

test('actual Dashboard proxy entry mounts the separate pool without starting or authorizing', async ({page}) => {
  await installTauriStub(page, {settings: {...SYNTHETIC_SETTINGS, language: 'en'}, dashboard: SYNTHETIC_DASHBOARD}, () => {
    const original = window.__TAURI_INTERNALS__.invoke;
    window.poolIntegrationCalls = [];
    window.__TAURI_INTERNALS__.invoke = async (command, args) => {
      if (command.includes('provider_pool')) {
        window.poolIntegrationCalls.push(command);
        if (command !== 'get_provider_pool') throw Error('unexpected mutation');
        return {phase: 'stopped', runId: null, port: null, accounts: [], providers: [], providerModels: {}, authorization: null, issueCode: null};
      }
      return original(command, args);
    };
  });
  await page.goto('/');
  expect(await page.evaluate(() => window.poolIntegrationCalls)).toEqual([]);
  await page.getByRole('button', {name: 'Getting started', exact: true}).click();
  const guide = page.getByRole('dialog', {name: 'Getting started', exact: true});
  await guide.getByRole('button', {name: 'Features', exact: true}).click();
  await guide.getByRole('button', {name: 'Open proxy settings', exact: true}).click();
  const pool = page.getByRole('region', {name: 'Web-authorized account pool', exact: true});
  await expect(pool.getByRole('button', {name: 'Start account pool', exact: true})).toBeVisible();
  const calls = await page.evaluate(() => window.poolIntegrationCalls);
  expect(calls.length).toBeGreaterThan(0);
  expect(calls.every(command => command === 'get_provider_pool')).toBe(true);
});
