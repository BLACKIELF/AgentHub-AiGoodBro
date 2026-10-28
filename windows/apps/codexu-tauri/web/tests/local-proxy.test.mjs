import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';

const source = readFileSync(new URL('../src/utils/localProxy.ts', import.meta.url), 'utf8');
const context = vm.createContext({ exports: {} });
vm.runInContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText, context);
const { parseProxyPreferences, parseProxyStatus, parseProxyAccounts, proxyParticipation, proxyDisplayOrder, proxyConnectionText } = context.exports;
const preferences = () => ({ schemaVersion: 1, isEnabled: false, automaticRecoveryEnabled: false, order: ['b', 'a'], enabledIds: ['a'], knownIds: ['a', 'b'], priorityIds: [], lastIds: ['b'], lastOverrides: {}, creditFallback: false, creditPrimaryFloor: 2000, creditSecondaryFloor: 1500, accountPolicies: { a: { fiveHourUsedLimit: 80, allowsCredits: true, creditPrimaryFloor: null, creditSecondaryFloor: null } }, resetStopRules: { a: { identityHash: '0'.repeat(64), armedAt: 100, pausedAt: null, previousResetAt: null } }, listenPort: 18080, clientKeyMode: 'persistent', desktopFallback: false, networkProxy: '', egress: { enabled: false, mihomoApi: '', group: '', whitelist: [] } });
const plain = value => JSON.parse(JSON.stringify(value));

test('preferences round trip every production field without dropping reset-stop or network rules', () => {
  const original = preferences();
  assert.deepEqual(plain(parseProxyPreferences(original)), original);
  for (const patch of [{ listenPort: 1000 }, { listenPort: 65536 }, { networkProxy: 'http://user:secret@localhost:7890' }, { networkProxy: 'http://localhost:7890/path' }, { order: ['a', 'a'] }, { creditPrimaryFloor: 1500 }, { egress: { enabled: true, mihomoApi: 'http://example.com:9090', group: 'test', whitelist: [] } }]) {
    assert.throws(() => parseProxyPreferences({ ...original, ...patch }));
  }
});

test('participation preserves manual order; priority and use-last exclude each other, including explicit Pro opt-out', () => {
  const original = parseProxyPreferences(preferences());
  const enabled = proxyParticipation(original, 'b', 'enabled', true);
  assert.deepEqual(plain(enabled.order), ['b', 'a']);
  assert.deepEqual(plain({ ...enabled, enabledIds: original.enabledIds }), plain(original));
  const priority = proxyParticipation(original, 'b', 'priority', true);
  assert.equal(priority.lastOverrides.b, false);
  assert.equal(priority.lastIds.includes('b'), false);
  const last = proxyParticipation(priority, 'b', 'last', true);
  assert.equal(last.priorityIds.includes('b'), false);
  assert.equal(last.lastOverrides.b, true);
  assert.equal(proxyParticipation(last, 'b', 'last', false).lastOverrides.b, false);
  assert.deepEqual(plain(proxyDisplayOrder([{ id: 'a' }, { id: 'b' }, { id: 'c' }], enabled)), [{ id: 'b' }, { id: 'a' }, { id: 'c' }]);
});

test('only reported state and valid account quota enter the surface; connection credentials require a loopback endpoint', () => {
  assert.throws(() => parseProxyStatus({ phase: 'running', port: null, issue: null, accounts: {}, lastEventAt: null }));
  assert.throws(() => parseProxyStatus({ phase: 'installed', port: null, issue: null, accounts: {}, lastEventAt: null }));
  const status = { phase: 'running', port: 18080, issue: null, accounts: {}, lastEventAt: null, egress: { state: 'healthy', requestId: '00000000-0000-0000-0000-000000000000', latencyMs: 0 } };
  assert.equal(parseProxyStatus(status).egress.latencyMs, 0);
  assert.throws(() => parseProxyStatus({ ...status, egress: { ...status.egress, requestId: '/private/unknown' } }));
  const account = { id: 'a', label: 'Synthetic account', planType: 'plus', isLast: false, isPriority: false, isEnabled: true, quota: null, availability: 'unknown', reasonCode: 'quota_unknown' };
  assert.equal(parseProxyAccounts([account])[0].quota, null);
  assert.throws(() => parseProxyAccounts([account, account]));
  assert.throws(() => parseProxyAccounts([{ ...account, availability: 'confirmed_by_guess' }]));
  assert.throws(() => proxyConnectionText({ endpoint: 'https://example.com/v1', clientKey: 'SYNTHETIC_KEY_NOT_REAL_123456789' }));
  assert.equal(proxyConnectionText({ endpoint: 'http://127.0.0.1:18080/v1', clientKey: 'SYNTHETIC_KEY_NOT_REAL_123456789' }), 'OPENAI_BASE_URL=http://127.0.0.1:18080/v1\nOPENAI_API_KEY=SYNTHETIC_KEY_NOT_REAL_123456789');
});
