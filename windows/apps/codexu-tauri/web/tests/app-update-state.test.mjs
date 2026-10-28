import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';

const source = readFileSync(new URL('../src/utils/appUpdate.ts', import.meta.url), 'utf8');
const context = vm.createContext({ exports: {} });
vm.runInContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText, context);
const { parseAppUpdateState } = context.exports;
const info = { current_version: '3.0.0', available_version: '3.1.0', release_notes: '<script>plain text only</script>', can_download: true, asset_name: 'AiGoodBro-3.1.0-windows-x86_64.msi', asset_size: 1234, published_at: '2026-09-15T12:00:00Z' };

test('real Rust optional fields may be null, and every reported phase stays distinct', () => {
  for (const phase of ['idle', 'checking', 'available', 'up_to_date', 'downloading', 'verifying', 'downloaded', 'cancelled', 'failed', 'opening', 'installer_opened']) {
    assert.equal(parseAppUpdateState({ phase, info, error_code: null }).phase, phase);
  }
  const parsed = parseAppUpdateState({ phase: 'available', info: { ...info, available_version: null, published_at: null, asset_name: null, asset_size: null, reason_code: null } });
  assert.equal(parsed.info.available_version, undefined);
  assert.equal(parsed.info.asset_name, undefined);
  assert.equal(parsed.info.release_notes, info.release_notes);
});

test('malformed release data never becomes a successful latest-version claim', () => {
  for (const raw of [null, {}, { phase: 'installed' }, { phase: 'up_to_date' }, { phase: 'failed', error_code: '/private/path' },
    { phase: 'available', info: { ...info, current_version: 'unknown' } },
    { phase: 'available', info: { ...info, asset_name: '../payload.exe' } },
    { phase: 'available', info: { ...info, asset_size: -1 } },
    { phase: 'available', info: { ...info, published_at: 'not a date' } },
  ]) assert.throws(() => parseAppUpdateState(raw));
});
