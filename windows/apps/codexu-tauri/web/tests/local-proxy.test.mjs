import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';

const source = readFileSync(new URL('../src/utils/localProxy.ts', import.meta.url), 'utf8');
const context = vm.createContext({ exports: {} });
vm.runInContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText, context);
const { parseProxyPreferences, parseProxyPolicy, parseProxyStatus, parseProxyAccounts, proxyParticipation, proxyDisplayOrder, proxyConnectionText, remainingQuotaPercent, usedQuotaLimit, sharedQuotaReserve } = context.exports;
const preferences = () => ({ schemaVersion: 1, isEnabled: false, automaticRecoveryEnabled: false, order: ['b', 'a'], enabledIds: ['a'], knownIds: ['a', 'b'], priorityIds: [], lastIds: ['b'], lastOverrides: {}, creditFallback: false, creditPrimaryFloor: 2000, creditSecondaryFloor: 1500, accountPolicies: { a: { fiveHourUsedLimit: 80, allowsCredits: true, creditPrimaryFloor: null, creditSecondaryFloor: null } }, resetStopRules: { a: { identityHash: '0'.repeat(64), armedAt: 100, pausedAt: null, previousResetAt: null } }, listenPort: 18080, clientKeyMode: 'persistent', desktopFallback: false, networkProxy: '', egress: { enabled: false, mihomoApi: '', group: '', whitelist: [] } });
const plain = value => JSON.parse(JSON.stringify(value));

test('preferences round trip every production field without dropping reset-stop or network rules', () => {
  const original = preferences();
  assert.deepEqual(plain(parseProxyPreferences(original)), { ...original, accountPolicies: { a: { ...original.accountPolicies.a, sevenDayUsedLimit: 100 } } });
  for (const patch of [{ listenPort: 1000 }, { listenPort: 65536 }, { networkProxy: 'http://user:secret@localhost:7890' }, { networkProxy: 'http://localhost:7890/path' }, { order: ['a', 'a'] }, { creditPrimaryFloor: 1500 }, { egress: { enabled: true, mihomoApi: 'http://example.com:9090', group: 'test', whitelist: [] } }]) {
    assert.throws(() => parseProxyPreferences({ ...original, ...patch }));
  }
});

test('remaining quota input converts once and legacy policies preserve their used cutoff', () => {
  const old = preferences().accountPolicies.a;
  old.fiveHourUsedLimit = 20;
  const parsed = parseProxyPolicy(old);
  assert.equal(parsed.fiveHourUsedLimit, 20);
  assert.equal(remainingQuotaPercent(parsed.fiveHourUsedLimit), 80);
  assert.equal(parsed.sevenDayUsedLimit, 100);
  assert.equal(remainingQuotaPercent(parsed.sevenDayUsedLimit), 0);
  for (const [remaining, used] of [[20, 80], [0, 100], [100, 0], [20.1, 79.9]]) {
    assert.equal(usedQuotaLimit(remaining), used);
    assert.equal(remainingQuotaPercent(used), remaining);
  }
  for (const invalid of [-1, 101, NaN, Infinity, null]) {
    assert.throws(() => parseProxyPolicy({ ...old, sevenDayUsedLimit: invalid }));
  }
  for (const invalid of [-1, 101, NaN, Infinity]) assert.throws(() => usedQuotaLimit(invalid));
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

test('shared reserve state uses Plus five-hour and Pro family seven-day windows only', () => {
  const p = parseProxyPreferences(preferences());
  p.accountPolicies.a.sevenDayUsedLimit = 17;
  p.accountPolicies.b = { fiveHourUsedLimit: 3, sevenDayUsedLimit: 80, allowsCredits: false, creditPrimaryFloor: null, creditSecondaryFloor: null };
  const accounts = [{ id: 'a', planType: 'plus' }, { id: 'b', planType: 'pro' }, { id: 'unknown', planType: null }, { id: 'free', planType: 'free' }];
  assert.deepEqual(plain(sharedQuotaReserve(p, accounts)), { count: 2, remaining: 20, mixed: false });
  p.accountPolicies.b.sevenDayUsedLimit = 79.9;
  assert.deepEqual(plain(sharedQuotaReserve(p, accounts)), { count: 2, remaining: null, mixed: true });
  accounts[1].planType = 'prolite';
  p.accountPolicies.b.sevenDayUsedLimit = 80;
  assert.equal(sharedQuotaReserve(p, accounts).mixed, false);
  assert.deepEqual(plain(sharedQuotaReserve(p, [])), { count: 0, remaining: null, mixed: false });
});
