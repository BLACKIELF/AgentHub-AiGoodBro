import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import { installTauriStub } from './visual/tauri-stub.mjs';

const payload = { settings: { language: 'en' }, dashboard: { total_tokens: 42 } };

function collectScripts() {
  const scripts = [];
  return { scripts, page: { addInitScript: async ({ content }) => { scripts.push(content); } } };
}

function execute(scripts) {
  const context = vm.createContext({ window: {} });
  for (const script of scripts) vm.runInContext(script, context);
  return context.window.__TAURI_INTERNALS__;
}

test('dependent visual fixture installs after its base bridge in one init script', async () => {
  const { page, scripts } = collectScripts();
  await installTauriStub(page, payload, () => {
    const base = window.__TAURI_INTERNALS__.invoke;
    window.__TAURI_INTERNALS__.invoke = async (command, args) => command === 'list_profiles'
      ? [{ id: '1', label: 'Synthetic account' }]
      : base(command, args);
  });
  assert.equal(scripts.length, 1);
  const bridge = execute(scripts);
  assert.equal((await bridge.invoke('list_profiles'))[0].id, '1');
  assert.equal((await bridge.invoke('get_local_usage')).total_tokens, 42);
});

test('latest explicit visual setup wins in either browser init-script order', async () => {
  const { page, scripts } = collectScripts();
  await installTauriStub(page, payload, () => {
    window.__TAURI_INTERNALS__.invoke = async () => 'obsolete main fixture';
  });
  await installTauriStub(page, { ...payload, windowLabel: 'settings' });
  for (const order of [scripts, [...scripts].reverse()]) {
    const bridge = execute(order);
    assert.equal(bridge.metadata.currentWindow.label, 'settings');
    assert.equal((await bridge.invoke('get_settings')).language, 'en');
    assert.equal((await bridge.invoke('list_profiles')).length, 0);
  }
});
