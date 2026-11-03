import {test, expect} from '@playwright/test';
import {installTauriStub} from './tauri-stub.mjs';
import {SYNTHETIC_SETTINGS, SYNTHETIC_DASHBOARD} from './synthetic-fixtures.mjs';

test('actual guide reaches Companion comparison without installing or starting a task', async ({page}) => {
  await installTauriStub(page, {settings: {...SYNTHETIC_SETTINGS, language: 'en'}, dashboard: SYNTHETIC_DASHBOARD}, () => {
    const original = window.__TAURI_INTERNALS__.invoke;
    window.companionGuideCalls = [];
    window.__TAURI_INTERNALS__.invoke = async (command, args) => {
      if (!['inspect_companion_setup', 'prepare_companion_setup', 'confirm_companion_setup'].includes(command)) return original(command, args);
      window.companionGuideCalls.push({command, args});
      const snapshot = {state: 'missing', issueCode: null, files: [{path: 'SKILL.md', status: 'missing'}, {path: '使用说明.md', status: 'missing'}], planId: null, backupAvailable: false};
      if (command === 'inspect_companion_setup') return snapshot;
      if (command === 'prepare_companion_setup') return {...snapshot, planId: 'c'.repeat(64)};
      throw 'unexpected_confirmation';
    };
  });
  await page.goto('/');
  await page.getByRole('button', {name: 'Getting started', exact: true}).click();
  const guide = page.getByRole('dialog', {name: 'Getting started', exact: true});
  expect(await page.evaluate(() => window.companionGuideCalls)).toEqual([]);
  await guide.getByRole('button', {name: 'Tools', exact: true}).click();
  const companion = guide.getByRole('region', {name: 'Companion Skill', exact: true});
  await expect(companion.getByRole('status')).toHaveText('Not installed');
  expect((await page.evaluate(() => window.companionGuideCalls)).map(value => value.command)).toEqual(['inspect_companion_setup']);
  await companion.getByRole('button', {name: 'Prepare installation or update', exact: true}).click();
  await expect(companion.getByRole('button', {name: 'Confirm installation or update', exact: true})).toBeVisible();
  await companion.scrollIntoViewIfNeeded();
  await page.mouse.move(0, 0);
  await expect(companion).toHaveScreenshot('companion-actual-guide-confirm.png');
  await companion.getByRole('button', {name: 'Cancel', exact: true}).click();
  await expect(companion.getByRole('button', {name: 'Confirm installation or update', exact: true})).toHaveCount(0);
  expect((await page.evaluate(() => window.companionGuideCalls)).map(value => value.command)).toEqual(['inspect_companion_setup', 'prepare_companion_setup']);
  await guide.getByRole('button', {name: 'Not now', exact: true}).click();
  await expect(guide).not.toBeVisible();
});
