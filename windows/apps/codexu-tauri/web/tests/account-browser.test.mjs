import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import ts from 'typescript';
const code = ts.transpileModule(readFileSync(new URL('../src/utils/accountBrowser.ts', import.meta.url), 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ES2020 } }).outputText;
const { parseBrowserSettings } = await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
test('browser choices bind the account and allow only enumerated Chrome directory forms', () => {
  const settings = { profileId: '1', mode: 'existingChrome', profileDirectory: 'Profile 2', chromeAvailable: true, profiles: [{ directoryName: 'Profile 2', displayName: 'Work' }] };
  assert.deepEqual(parseBrowserSettings(settings, '1'), settings);
  for (const patch of [{ profileId: '2' }, { mode: 'unknown' }, { profileScanIssue: 'other' }, { profileDirectory: '../Other' }, { profileDirectory: 'Profile 2 --flag' }, { profiles: [settings.profiles[0], settings.profiles[0]] }, { profiles: [{ directoryName: 'Profile 2', displayName: 'private@example.invalid' }] }, { mode: 'dedicatedChrome', profileDirectory: 'Profile 2' }]) assert.throws(() => parseBrowserSettings({ ...settings, ...patch }, '1'));
});

test('profile enumeration failure preserves saved route and permits switching away', () => {
  const value = { profileId: '1', mode: 'existingChrome', profileDirectory: 'Profile 2', chromeAvailable: true, profiles: [], profileScanIssue: 'browser_profiles_unavailable' };
  assert.deepEqual(parseBrowserSettings(value, '1'), value);
  assert.deepEqual(parseBrowserSettings({ ...value, mode: 'systemDefault', profileDirectory: null }, '1').mode, 'systemDefault');
});
