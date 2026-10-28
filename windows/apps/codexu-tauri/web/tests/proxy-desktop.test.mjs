import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
const source = readFileSync(new URL('../src/utils/proxyDesktop.ts', import.meta.url), 'utf8');
const context = vm.createContext({ exports: {} });
vm.runInContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText, context);
const { parseProxyDesktopStatus } = context.exports;
const status = { phase: 'launched', launchId: 'synthetic_launch', accountId: 'managed_a', issue: null, routingVerified: null };

test('Desktop preparation, launch and routing evidence remain independent reported fields', () => {
  assert.equal(parseProxyDesktopStatus({ ...status, phase: 'prepared' }).phase, 'prepared');
  assert.equal(parseProxyDesktopStatus(status).routingVerified, null);
  assert.equal(parseProxyDesktopStatus({ ...status, routingVerified: false }).routingVerified, false);
  assert.throws(() => parseProxyDesktopStatus({ ...status, phase: 'prepared', routingVerified: true }));
  assert.throws(() => parseProxyDesktopStatus({ ...status, issue: 'desktop_connection_stale', routingVerified: true }));
});

test('invalid ownership/state cannot become an active Desktop; private paths do not enter the projected state', () => {
  for (const invalid of [{ ...status, phase: 'connected' }, { ...status, accountId: null }, { ...status, launchId: '../private/path' }, { ...status, issue: '/private/diagnostic' }, { ...status, routingVerified: 'true' }]) assert.throws(() => parseProxyDesktopStatus(invalid));
  assert.equal(Object.hasOwn(parseProxyDesktopStatus({ ...status, clientKey: 'synthetic_not_a_real_key' }), 'clientKey'), false);
});
