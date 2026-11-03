import {test, expect} from '@playwright/test';
import {installTauriStub} from './tauri-stub.mjs';
import {SYNTHETIC_SETTINGS, SYNTHETIC_DASHBOARD} from './synthetic-fixtures.mjs';

test('actual guide exposes explicit Python checks and the fixed timezone instructions', async ({page}) => {
  await installTauriStub(page, {settings: {...SYNTHETIC_SETTINGS, language: 'en'}, dashboard: SYNTHETIC_DASHBOARD}, () => {
    const original = window.__TAURI_INTERNALS__.invoke;
    window.pythonIntegrationCalls = [];
    window.__TAURI_INTERNALS__.invoke = async (command, args) => {
      if (!['inspect_python_runtime', 'select_python_runtime', 'open_python_installation_guide'].includes(command)) return original(command, args);
      window.pythonIntegrationCalls.push({command, args});
      if (command === 'inspect_python_runtime') return {state: 'unavailable', version: null, selected: true, issueCode: 'python_timezone_missing'};
      if (command === 'open_python_installation_guide') return;
      throw 'unexpected_selection';
    };
  });
  await page.goto('/');
  await page.getByRole('button', {name: 'Getting started', exact: true}).click();
  const guide = page.getByRole('dialog', {name: 'Getting started', exact: true});
  await guide.getByRole('button', {name: 'Tools', exact: true}).click();
  const python = guide.getByRole('region', {name: 'Python companion runtime', exact: true});
  await expect(python).toContainText('Not checked');
  expect(await page.evaluate(() => window.pythonIntegrationCalls)).toEqual([]);
  await python.getByRole('button', {name: 'Check Python', exact: true}).click();
  await expect(python.getByRole('alert')).toContainText('Asia/Shanghai timezone data is unavailable');
  await expect(python).not.toContainText('Python verified and saved');
  await python.scrollIntoViewIfNeeded();
  await page.mouse.move(0, 0);
  await expect(python).toHaveScreenshot('python-actual-guide-timezone.png');
  await python.getByRole('button', {name: 'Open official Python instructions', exact: true}).click();
  expect(await page.evaluate(() => window.pythonIntegrationCalls)).toEqual([
    {command: 'inspect_python_runtime', args: {}},
    {command: 'open_python_installation_guide', args: {topic: 'timezone'}},
  ]);
});
