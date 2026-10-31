import {test, expect} from '@playwright/test';
import {installTauriStub} from './tauri-stub.mjs';
import {SYNTHETIC_SETTINGS, SYNTHETIC_DASHBOARD} from './synthetic-fixtures.mjs';

async function setup(page, options = {}) {
  await installTauriStub(page, {settings: {...SYNTHETIC_SETTINGS, language: 'en'}, dashboard: SYNTHETIC_DASHBOARD}, () => {
    const original = window.__TAURI_INTERNALS__.invoke;
    window.companionCalls = []; window.companionListeners = new Map();
    const files = [{path: 'SKILL.md', status: 'missing'}, {path: '使用说明.md', status: 'missing'}, {path: 'bin/next-dispatch.py', status: 'missing'}, {path: 'config/runtime-paths.json', status: 'missing'}];
    window.companionView = {state: 'missing', issueCode: null, files, planId: null, backupAvailable: false};
    window.companionPrepared = {...window.companionView, planId: 'a'.repeat(64)};
    window.companionReady = {...window.companionView, state: 'ready', files: files.map(f => ({...f, status: 'same'})), backupAvailable: true};
    window.companionEmit = () => { for (const [id, handler] of window.companionListeners) window['_' + handler]({event: 'companion-setup:changed', payload: null, id}); };
    window.__TAURI_INTERNALS__.invoke = async (command, args) => {
      if (command === 'plugin:event|listen' && args.event === 'companion-setup:changed') {
        if (window.companionListenFails) throw 'synthetic_subscription_failure';
        const id = await original(command, args); window.companionListeners.set(id, args.handler); return id;
      }
      if (command === 'plugin:event|unlisten') window.companionListeners.delete(args.eventId);
      if (!['inspect_companion_setup', 'prepare_companion_setup', 'confirm_companion_setup'].includes(command)) return original(command, args);
      window.companionCalls.push({command, args});
      if (window.companionError === command) throw 'synthetic_lost_reply';
      if (command === 'inspect_companion_setup') return structuredClone(window.companionView);
      if (window.companionHold === command) return new Promise(resolve => { window.companionRelease = value => resolve(structuredClone(value)); });
      if (command === 'prepare_companion_setup') return structuredClone(window.companionPrepared);
      window.companionView = structuredClone(window.companionReady);
      if (window.companionLoseConfirm) throw 'synthetic_lost_confirmation_receipt';
      return structuredClone(window.companionView);
    };
  });
  await page.goto('/');
  await page.evaluate(async options => {
    Object.assign(window, options);
    document.getElementById('root').hidden = true;
    const element = document.createElement('div'); element.id = 'companion-fixture';
    element.style.cssText = 'max-width:800px;margin:24px auto;padding:20px'; document.body.append(element);
    window.unmountCompanion = (await import('/tests/visual/companion-setup-component.fixture.tsx')).mountCompanionSetup(element);
  }, options);
  return page.locator('#companion-fixture');
}
const prepare = panel => panel.getByRole('button', {name: 'Prepare installation or update', exact: true});
const confirm = panel => panel.getByRole('button', {name: 'Confirm installation or update', exact: true});
const check = panel => panel.getByRole('button', {name: 'Check again', exact: true});

test('Companion inspects only on mount and requires a distinct reviewed confirmation', async ({page}) => {
  const panel = await setup(page);
  await expect(panel.getByRole('status')).toHaveText('Not installed');
  expect((await page.evaluate(() => window.companionCalls)).map(c => c.command)).toEqual(['inspect_companion_setup']);
  await prepare(panel).click(); await expect(confirm(panel)).toBeVisible();
  await expect(panel).toContainText('4 differences');
  await expect(panel).toContainText('使用说明.md');
  await expect(panel).toHaveScreenshot('companion-setup-confirm.png');
  expect(await page.evaluate(() => window.companionCalls.filter(c => c.command === 'confirm_companion_setup').length)).toBe(0);
  await confirm(panel).click();
  await expect(panel).toContainText('Companion files and connection are verified ready; no task was started here.');
  await expect(panel).toContainText('The content replaced in this operation has a backup.');
  expect(await page.evaluate(() => window.companionCalls.at(-1))).toEqual({command: 'confirm_companion_setup', args: {planId: 'a'.repeat(64)}});
});
test('Companion cancel never submits and a state change removes a prior plan', async ({page}) => {
  const panel = await setup(page); await prepare(panel).click();
  await panel.getByRole('button', {name: 'Cancel', exact: true}).click();
  await expect(confirm(panel)).toHaveCount(0);
  expect(await page.evaluate(() => window.companionCalls.filter(c => c.command === 'confirm_companion_setup').length)).toBe(0);
  await prepare(panel).click(); await expect(confirm(panel)).toBeVisible();
  await page.evaluate(() => { window.companionView = {state: 'unavailable', issueCode: 'companion_exit_in_progress', files: [], planId: null, backupAvailable: false}; window.companionEmit(); });
  await expect(confirm(panel)).toHaveCount(0); await expect(panel.getByRole('status')).toHaveText('Unavailable');
});
test('Companion committed installation with a lost reply clears Ready and only checks the actual result', async ({page}) => {
  const panel = await setup(page); await prepare(panel).click();
  await page.evaluate(() => window.companionLoseConfirm = true); await confirm(panel).click();
  await expect(panel.getByRole('alert')).toContainText('files may already have changed');
  await expect(panel.getByRole('status')).toHaveText('Not checked');
  await expect(prepare(panel)).toBeDisabled(); await expect(confirm(panel)).toHaveCount(0);
  expect(await page.evaluate(() => window.companionCalls.filter(c => c.command === 'confirm_companion_setup').length)).toBe(1);
  await check(panel).click(); await expect(panel.getByRole('status')).toHaveText('Ready');
  await expect(panel).not.toContainText('Companion files and connection are verified ready');
  expect(await page.evaluate(() => window.companionCalls.filter(c => c.command === 'confirm_companion_setup').length)).toBe(1);
});
test('Companion changed event during prepare discards the late plan and serializes a read-only recheck', async ({page}) => {
  const panel = await setup(page); await page.evaluate(() => window.companionHold = 'prepare_companion_setup');
  await prepare(panel).click(); await expect.poll(() => page.evaluate(() => typeof window.companionRelease)).toBe('function');
  await page.evaluate(() => { window.companionView = {state: 'unavailable', issueCode: 'companion_runtime_changed', files: [], planId: null, backupAvailable: false}; window.companionEmit(); });
  expect(await page.evaluate(() => window.companionCalls.filter(c => c.command === 'inspect_companion_setup').length)).toBe(1);
  await page.evaluate(() => window.companionRelease(window.companionPrepared));
  await expect(panel.getByRole('status')).toHaveText('Unavailable'); await expect(confirm(panel)).toHaveCount(0);
  expect((await page.evaluate(() => window.companionCalls)).map(c => c.command)).toEqual(['inspect_companion_setup', 'prepare_companion_setup', 'inspect_companion_setup']);
});
test('Companion late confirmation cannot resurrect Ready after a connection state change', async ({page}) => {
  const panel = await setup(page); await prepare(panel).click();
  await page.evaluate(() => window.companionHold = 'confirm_companion_setup'); await confirm(panel).click();
  await expect.poll(() => page.evaluate(() => typeof window.companionRelease)).toBe('function');
  await page.evaluate(() => { window.companionView = {state: 'unavailable', issueCode: 'companion_cleanup_unconfirmed', files: [], planId: null, backupAvailable: false}; window.companionEmit(); window.companionRelease(window.companionReady); });
  await expect(panel.getByRole('status')).toHaveText('Unavailable');
  await expect(panel).not.toContainText('Companion files and connection are verified ready');
  await expect(confirm(panel)).toHaveCount(0);
  expect(await page.evaluate(() => window.companionCalls.filter(c => c.command === 'confirm_companion_setup').length)).toBe(1);
});
test('Companion unchanged files still require the native connection confirmation plan', async ({page}) => {
  const panel = await setup(page);
  await page.evaluate(() => window.companionPrepared = {...window.companionReady, state: 'unavailable', issueCode: 'companion_confirmation_required', backupAvailable: false, planId: 'b'.repeat(64)});
  await prepare(panel).click(); await expect(panel).toContainText('0 differences');
  await expect(panel.getByRole('status')).toHaveText('Unavailable'); await expect(confirm(panel)).toBeVisible();
  await confirm(panel).click(); await expect(panel).toContainText('Companion files and connection are verified ready');
  expect((await page.evaluate(() => window.companionCalls.at(-1))).args).toEqual({planId: 'b'.repeat(64)});
});
test('Companion failed inspection removes prior Ready and unmounted late prepare cannot submit', async ({page}) => {
  const panel = await setup(page); await page.evaluate(() => window.companionView = window.companionReady);
  await check(panel).click(); await expect(panel.getByRole('status')).toHaveText('Ready');
  await page.evaluate(() => window.companionError = 'inspect_companion_setup'); await check(panel).click();
  await expect(panel.getByRole('status')).toHaveText('Not checked'); await expect(prepare(panel)).toBeDisabled();
  await page.evaluate(() => window.companionError = null); await check(panel).click();
  await page.evaluate(() => window.companionHold = 'prepare_companion_setup'); await prepare(panel).click();
  await expect.poll(() => page.evaluate(() => typeof window.companionRelease)).toBe('function');
  await page.evaluate(() => { window.unmountCompanion(); window.companionRelease(window.companionPrepared); });
  await expect(panel).toBeEmpty();
  expect(await page.evaluate(() => window.companionCalls.filter(c => c.command === 'confirm_companion_setup').length)).toBe(0);
});
test('Companion cannot report Ready when native state subscription fails', async ({page}) => {
  const panel = await setup(page, {companionListenFails: true});
  await expect(panel.getByRole('alert')).toContainText('status updates are unavailable');
  await expect(prepare(panel)).toBeDisabled(); await expect(check(panel)).toBeDisabled();
  expect(await page.evaluate(() => window.companionCalls)).toEqual([]);
});
