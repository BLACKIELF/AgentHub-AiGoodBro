'use strict';

const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const test = require('node:test');
const { fetchCursorLimits } = require('../../src/shared/providers/cursor/limits');
const { createLimitsRuntime } = require('../../src/shared/limits/runtime');
const JSON_NULL = Symbol('valid JSON null');

// Every request goes through this fixture. Unknown paths and null responses fail
// locally, so these tests cannot reach Cursor or use a real session.
function fakeHttps(payloads, calls = []) {
  return {
    request(options, callback) {
      const call = { path: options.path, method: options.method, body: '' };
      calls.push(call);
      const response = new EventEmitter();
      const payload = payloads[options.path];
      response.statusCode = payload === undefined || payload === null ? 500 : 200;
      setImmediate(() => {
        callback(response);
        if (response.statusCode === 200) setImmediate(() => {
          response.emit('data', Buffer.from(JSON.stringify(payload === JSON_NULL ? null : payload)));
          response.emit('end');
        });
      });
      return {
        on() {},
        end() {},
        write(chunk) { call.body += String(chunk); },
        setTimeout() {},
        destroy() {}
      };
    }
  };
}

const account = { id: 'fixture-account', userId: 'fixture-user', sessionToken: 'fixture-token' };
const summaryZeros = { individualUsage: { plan: { autoPercentUsed: 0, apiPercentUsed: 0 } } };

function fetchWith(payloads, calls = []) {
  return fetchCursorLimits({}, { readActiveAccount: () => account, httpsLib: fakeHttps(payloads, calls) });
}

test('unknown plan: failed plan-info and sand never turn zeros into full model pools', async () => {
  const calls = [];
  const row = await fetchWith({ '/api/usage-summary': summaryZeros }, calls);
  assert.equal(row.status, 'unavailable');
  assert.deepEqual(row.windows, []);
  assert.equal(calls.find((call) => call.path === '/api/dashboard/get-plan-info')?.method, 'POST');
  assert.equal(calls.find((call) => call.path === '/api/dashboard/get-plan-info')?.body, '{}');
});

test('malformed successful dashboard payloads do not identify a legacy plan', async () => {
  for (const payload of [JSON_NULL, [], { isMerged: 'true' }, { error: 'fixture failure' }]) {
    const row = await fetchWith({
      '/api/usage-summary': summaryZeros,
      '/api/dashboard/get-plan-info': payload
    });
    assert.equal(row.status, 'unavailable');
    assert.deepEqual(row.windows, []);
  }
  const invalidSand = await fetchWith({
    '/api/usage-summary': summaryZeros,
    '/api/dashboard/get-sand-usage-status': { isUnified: 'false' }
  });
  assert.equal(invalidSand.status, 'unavailable');
  assert.deepEqual(invalidSand.windows, []);
});

test('unknown plan: team pool and on-demand data survive while legacy seat fallbacks do not', async () => {
  const row = await fetchWith({
    '/api/auth/me': { sub: 'fixture-user' },
    '/api/usage?user=fixture-user': { 'gpt-4': { numRequestsTotal: 0, maxRequestUsage: 500 } },
    '/api/usage-summary': {
      individualUsage: {
        plan: { autoPercentUsed: 0, apiPercentUsed: 0 },
        overall: { used: 1000, limit: 2000 },
        onDemand: { used: 0, limit: 1000 }
      },
      teamUsage: { pooled: { used: 7500, limit: 10000 } }
    }
  });
  assert.equal(row.status, 'ok');
  assert.deepEqual(row.windows.map((window) => window.label), ['Team pool', 'On-demand spend']);
  assert.equal(row.windows[0].usedPercent, 75);
  assert.equal(row.windows[1].used, 0);
  assert.equal(row.windows[1].limit, 10);
});

test('unknown plan: neither request nor overall fallback establishes a seat quota', async () => {
  for (const request of [{ 'gpt-4': { numRequestsTotal: 0, maxRequestUsage: 500 } }, {}]) {
    const row = await fetchWith({
      '/api/auth/me': { sub: 'fixture-user' },
      '/api/usage?user=fixture-user': request,
      '/api/usage-summary': { individualUsage: { overall: { used: 0, limit: 2000 } } }
    });
    assert.equal(row.status, 'unavailable');
    assert.deepEqual(row.windows, []);
  }
});

test('missing team and on-demand usage is not inferred to be zero', async () => {
  const missing = await fetchWith({
    '/api/usage-summary': {
      individualUsage: { onDemand: { limit: 1000 } },
      teamUsage: { pooled: { limit: 10000 } }
    }
  });
  assert.equal(missing.status, 'unavailable');
  assert.deepEqual(missing.windows, []);
  const zero = await fetchWith({
    '/api/usage-summary': {
      individualUsage: { onDemand: { used: 0, limit: 1000 } },
      teamUsage: { pooled: { used: 0, limit: 10000 } }
    }
  });
  assert.equal(zero.status, 'ok');
  assert.deepEqual(zero.windows.map((window) => [window.label, window.used, window.remaining]), [
    ['Team pool', 0, 100], ['On-demand spend', 0, 10]
  ]);
});

test('a team amount without a denominator is retained without a percentage meter', async () => {
  const row = await fetchWith({ '/api/usage-summary': { teamUsage: { pooled: { used: 0 } } } });
  assert.equal(row.status, 'ok');
  assert.equal(row.windows[0].label, 'Team pool');
  assert.equal(row.windows[0].used, 0);
  assert.equal(row.windows[0].usedPercent, null);
  assert.equal(row.windows[0].showMeter, false);
});

test('successful proto3 legacy plan lookup retains genuine zero quotas', async () => {
  for (const [planInfo, sand] of [[{}, null], [null, {}], [{}, { isUnified: true, usagePercent: 40 }]]) {
    const row = await fetchWith({
      '/api/usage-summary': summaryZeros,
      '/api/dashboard/get-plan-info': planInfo,
      '/api/dashboard/get-sand-usage-status': sand
    });
    assert.equal(row.status, 'ok');
    assert.deepEqual(row.windows.map((window) => [window.label, window.usedPercent]), [
      ['Cursor Models', 0], ['Other Models', 0]
    ]);
  }
});

test('confirmed legacy plan keeps optional Grok Bot and zero-valued team usage', async () => {
  const row = await fetchWith({
    '/api/usage-summary': { ...summaryZeros, teamUsage: { pooled: { used: 0, limit: 10000 } } },
    '/api/dashboard/get-plan-info': {},
    '/api/dashboard/get-sand-usage-status': { usagePercent: 100, hasNonZeroIncludedLimit: true }
  });
  assert.equal(row.status, 'ok');
  assert.deepEqual(row.windows.map((window) => window.label), ['Cursor Models', 'Other Models', 'Grok Bot', 'Team pool']);
  assert.equal(row.windows[2].usedPercent, 100);
  assert.equal(row.windows[3].usedPercent, 0);
});

test('confirmed unified plan exposes measured zero without manufacturing legacy pools', async () => {
  const row = await fetchWith({
    '/api/usage-summary': summaryZeros,
    '/api/dashboard/get-plan-info': { isMerged: true, planInfo: { includedUsagePeriod: 'INCLUDED_USAGE_PERIOD_WEEKLY' } },
    '/api/dashboard/get-sand-usage-status': { isUnified: true, usagePercent: 0 }
  });
  assert.equal(row.status, 'ok');
  assert.deepEqual(row.windows.map((window) => [window.label, window.usedPercent]), [['Included usage', 0]]);
  assert.equal(row.windows[0].kind, 'weekly');
  assert.equal(row.windows[0].windowMinutes, 10080);
});

test('unified usage without a confirmed period does not invent a weekly window', async () => {
  const row = await fetchWith({
    '/api/usage-summary': summaryZeros,
    '/api/dashboard/get-plan-info': { isMerged: true },
    '/api/dashboard/get-sand-usage-status': { isUnified: true, usagePercent: 0 }
  });
  assert.equal(row.status, 'unavailable');
  assert.deepEqual(row.windows, []);
});

test('unified sand dates can establish a real seven-day period', async () => {
  const row = await fetchWith({
    '/api/usage-summary': summaryZeros,
    '/api/dashboard/get-sand-usage-status': {
      isUnified: true, usagePercent: 0,
      currentPeriodStart: '2026-05-25T00:00:00Z',
      nextResetTimestampUtc: '2026-06-01T00:00:00Z'
    }
  });
  assert.equal(row.status, 'ok');
  assert.deepEqual(row.windows.map((window) => [window.label, window.usedPercent, window.kind, window.windowMinutes, window.resetsAt]), [
    ['Included usage', 0, 'weekly', 10080, '2026-06-01T00:00:00.000Z']
  ]);
});

test('a weekly sand value cannot replace an explicitly monthly unified summary', async () => {
  const row = await fetchWith({
    '/api/usage-summary': { individualUsage: { plan: { totalPercentUsed: 35 } } },
    '/api/dashboard/get-plan-info': { isMerged: true, planInfo: { includedUsagePeriod: 'INCLUDED_USAGE_PERIOD_MONTHLY' } },
    '/api/dashboard/get-sand-usage-status': {
      isUnified: true, usagePercent: 99,
      currentPeriodStart: '2026-05-25T00:00:00Z',
      nextResetTimestampUtc: '2026-06-01T00:00:00Z'
    }
  });
  assert.deepEqual(row.windows.map((window) => [window.label, window.usedPercent, window.kind]), [['Included usage', 35, 'billing']]);
});

test('unified summary fallback requires an explicitly monthly period and a real total', async () => {
  const get = (period, plan) => fetchWith({
    '/api/usage-summary': { individualUsage: { plan } },
    '/api/dashboard/get-plan-info': { isMerged: true, planInfo: { includedUsagePeriod: period } }
  });
  const weekly = await get('INCLUDED_USAGE_PERIOD_WEEKLY', { totalPercentUsed: 0 });
  assert.equal(weekly.status, 'unavailable');
  assert.deepEqual(weekly.windows, []);
  const missing = await get('INCLUDED_USAGE_PERIOD_MONTHLY', { autoPercentUsed: 0, apiPercentUsed: 0 });
  assert.equal(missing.status, 'unavailable');
  assert.deepEqual(missing.windows, []);
  const monthly = await get('INCLUDED_USAGE_PERIOD_MONTHLY', { totalPercentUsed: 0 });
  assert.equal(monthly.status, 'ok');
  assert.deepEqual(monthly.windows.map((window) => [window.label, window.usedPercent]), [['Included usage', 0]]);
});

test('unknown plan invalidates only this account legacy cache and does not revive it after a failure', async (t) => {
  const seed = await fetchWith({
    '/api/usage-summary': summaryZeros,
    '/api/dashboard/get-plan-info': {}
  });
  const other = { ...seed, accountKey: 'other-account' };
  const payloads = { '/api/usage-summary': summaryZeros };
  const runtime = createLimitsRuntime({
    limitProviders: ['cursor'],
    previousLimits: { providers: [seed, other] }
  }, {
    autoStart: false,
    autoRetry: false,
    probeProvider: async () => [await fetchWith(payloads)]
  });
  t.after(() => runtime.stop());
  const scope = { provider: 'cursor', accountKey: seed.accountKey };
  const otherBefore = runtime.getSnapshot().providers.find((row) => row.accountKey === other.accountKey);
  await runtime.refresh(scope, 'credential-change');
  let snapshot = runtime.getSnapshot();
  let row = snapshot.providers.find((value) => value.accountKey === seed.accountKey);
  assert.equal(row.status, 'unavailable');
  assert.deepEqual(row.windows, []);
  assert.deepEqual(snapshot.providers.find((value) => value.accountKey === other.accountKey), otherBefore);
  assert.equal(JSON.stringify(snapshot).includes('invalidateCachedWindowLabels'), false);
  payloads['/api/usage-summary'] = null;
  await runtime.refresh(scope, 'credential-change');
  snapshot = runtime.getSnapshot();
  row = snapshot.providers.find((value) => value.accountKey === seed.accountKey);
  assert.deepEqual(row.windows, []);
  payloads['/api/usage-summary'] = summaryZeros;
  payloads['/api/dashboard/get-plan-info'] = {};
  await runtime.refresh(scope, 'credential-change');
  row = runtime.getSnapshot().providers.find((value) => value.accountKey === seed.accountKey);
  assert.equal(row.status, 'ok');
  assert.deepEqual(row.windows.map((window) => window.usedPercent), [0, 0]);
});

test('stale legacy windows stay invalidated after snapshot restoration', async (t) => {
  const seed = await fetchWith({ '/api/usage-summary': summaryZeros, '/api/dashboard/get-plan-info': {} });
  seed.status = 'unavailable';
  const runtime = createLimitsRuntime({ limitProviders: ['cursor'], previousLimits: { providers: [seed] } }, {
    autoStart: false,
    autoRetry: false,
    probeProvider: async () => [await fetchWith({ '/api/usage-summary': summaryZeros })]
  });
  t.after(() => runtime.stop());
  await runtime.refresh({ provider: 'cursor', accountKey: seed.accountKey }, 'credential-change');
  const snapshot = runtime.getSnapshot();
  assert.equal(snapshot.providers[0].status, 'unavailable');
  assert.deepEqual(snapshot.providers[0].windows, []);
  const restored = createLimitsRuntime({ limitProviders: ['cursor'], previousLimits: snapshot }, {
    autoStart: false, autoRetry: false
  });
  t.after(() => restored.stop());
  assert.equal(restored.getSnapshot().providers[0].status, 'unavailable');
  assert.deepEqual(restored.getSnapshot().providers[0].windows, []);
});

test('partial unknown-plan refresh preserves a stale included quota with new independent data', async (t) => {
  const seed = await fetchWith({ '/api/usage-summary': summaryZeros, '/api/dashboard/get-plan-info': {} });
  const oldTime = '2026-06-01T00:00:00.000Z';
  seed.updatedAt = oldTime;
  seed.windows = [
    { kind: 'weekly', label: 'Included usage', usedPercent: 40 },
    { kind: 'billing', label: 'Cursor Models', usedPercent: 0 },
    { kind: 'billing', label: 'Team pool', usedPercent: 20 }
  ];
  const payloads = {
    '/api/usage-summary': {
      individualUsage: { plan: { autoPercentUsed: 0, apiPercentUsed: 0 }, onDemand: { used: 300, limit: 1000 } },
      teamUsage: { pooled: { used: 7500, limit: 10000 } }
    }
  };
  const events = [];
  const runtime = createLimitsRuntime({ limitProviders: ['cursor'], previousLimits: { providers: [seed] } }, {
    autoStart: false,
    autoRetry: false,
    onEvent: (event) => events.push(event),
    probeProvider: async () => [await fetchWith(payloads)]
  });
  t.after(() => runtime.stop());
  const scope = { provider: 'cursor', accountKey: seed.accountKey };
  for (let i = 0; i < 2; i += 1) {
    await runtime.refresh(scope, 'credential-change');
    const row = runtime.getSnapshot().providers[0];
    assert.equal(row.status, 'unavailable');
    assert.equal(row.updatedAt, oldTime);
    assert.deepEqual(row.windows.map((window) => [window.label, window.usedPercent]), [
      ['Included usage', 40], ['Team pool', 75], ['On-demand spend', 30]
    ]);
  }
  assert.ok(events.some((event) => event.type === 'retry-scheduled' && event.reason === 'unavailable'));
  payloads['/api/usage-summary'] = summaryZeros;
  payloads['/api/dashboard/get-plan-info'] = { isMerged: true, planInfo: { includedUsagePeriod: 'INCLUDED_USAGE_PERIOD_WEEKLY' } };
  payloads['/api/dashboard/get-sand-usage-status'] = { isUnified: true, usagePercent: 55 };
  await runtime.refresh(scope, 'credential-change');
  const recovered = runtime.getSnapshot().providers[0];
  assert.equal(recovered.status, 'ok');
  assert.notEqual(recovered.updatedAt, oldTime);
  assert.deepEqual(recovered.windows.map((window) => [window.label, window.usedPercent]), [['Included usage', 55]]);
});

test('unkeyed invalidation cannot clear a provider lane or another provider', async (t) => {
  const seed = await fetchWith({ '/api/usage-summary': summaryZeros, '/api/dashboard/get-plan-info': {} });
  const other = { ...seed, accountKey: 'other-account' };
  const kimi = { ...seed, provider: 'kimi', accountKey: 'kimi-account' };
  const runtime = createLimitsRuntime({
    limitProviders: ['cursor', 'kimi'], previousLimits: { providers: [seed, other, kimi] }
  }, {
    autoStart: false,
    autoRetry: false,
    probeProvider: async () => [{
      provider: 'cursor', status: 'unavailable', windows: [],
      invalidateCachedWindowLabels: ['Cursor Models', 'Other Models']
    }]
  });
  t.after(() => runtime.stop());
  const before = runtime.getSnapshot();
  await runtime.refresh({ provider: 'cursor' }, 'credential-change');
  const after = runtime.getSnapshot();
  for (const key of [seed.accountKey, other.accountKey]) {
    const row = after.providers.find((item) => item.accountKey === key);
    assert.equal(row.status, 'unavailable');
    assert.deepEqual(row.windows.map((window) => window.label), ['Cursor Models', 'Other Models']);
  }
  assert.deepEqual(after.providers.find((row) => row.provider === 'kimi'),
    before.providers.find((row) => row.provider === 'kimi'));
});

test('another account cannot invalidate or replace a scoped Cursor account', async (t) => {
  const seed = await fetchWith({ '/api/usage-summary': summaryZeros, '/api/dashboard/get-plan-info': {} });
  const other = { ...seed, accountKey: 'other-account' };
  const runtime = createLimitsRuntime({
    limitProviders: ['cursor'], previousLimits: { providers: [seed, other] }
  }, {
    autoStart: false,
    autoRetry: false,
    probeProvider: async () => [{
      ...other, status: 'unavailable', windows: [],
      invalidateCachedWindowLabels: ['Cursor Models', 'Other Models']
    }]
  });
  t.after(() => runtime.stop());
  const before = runtime.getSnapshot();
  await runtime.refresh({ provider: 'cursor', accountKey: seed.accountKey }, 'credential-change');
  const after = runtime.getSnapshot();
  const target = after.providers.find((row) => row.accountKey === seed.accountKey);
  assert.equal(target.status, 'unavailable');
  assert.deepEqual(target.windows, before.providers.find((row) => row.accountKey === seed.accountKey).windows);
  assert.deepEqual(after.providers.find((row) => row.accountKey === other.accountKey),
    before.providers.find((row) => row.accountKey === other.accountKey));
});

test('unauthorized refresh clears the matching account without changing another account', async (t) => {
  const seed = await fetchWith({ '/api/usage-summary': summaryZeros, '/api/dashboard/get-plan-info': {} });
  const other = { ...seed, accountKey: 'other-account' };
  const runtime = createLimitsRuntime({ limitProviders: ['cursor'], previousLimits: { providers: [seed, other] } }, {
    autoStart: false,
    autoRetry: false,
    probeProvider: async () => [await fetchCursorLimits({}, {
      readActiveAccount: () => account,
      probe: async () => ({ ok: false, error: { kind: 'unauthorized' } })
    })]
  });
  t.after(() => runtime.stop());
  const otherBefore = runtime.getSnapshot().providers.find((row) => row.accountKey === other.accountKey);
  await runtime.refresh({ provider: 'cursor', accountKey: seed.accountKey }, 'credential-change');
  const rows = runtime.getSnapshot().providers;
  const target = rows.find((row) => row.accountKey === seed.accountKey);
  assert.equal(target.status, 'unauthorized');
  assert.deepEqual(target.windows, []);
  assert.deepEqual(rows.find((row) => row.accountKey === other.accountKey), otherBefore);
});

test('a scoped multi-account probe clears only the account whose authentication failed', async (t) => {
  const accounts = [
    { id: 'first', userId: 'user_first', sessionToken: 'first-fixture' },
    { id: 'second', userId: 'user_second', sessionToken: 'second-fixture' }
  ];
  let firstUnauthorized = false;
  const current = async () => fetchCursorLimits({}, {
    listAccounts: () => accounts,
    probe: async (token) => token === 'first-fixture' && firstUnauthorized
      ? { ok: false, error: { kind: 'unauthorized' } }
      : {
        ok: true,
        usage: { planInfo: { isMerged: false }, autoPercent: 0, apiPercent: 0 },
        user: { sub: token === 'first-fixture' ? 'auth0|user_first' : 'auth0|user_second' }
      }
  });
  const [first, second] = await current();
  const runtime = createLimitsRuntime({ limitProviders: ['cursor'], previousLimits: { providers: [first, second] } }, {
    autoStart: false, autoRetry: false, probeProvider: current
  });
  t.after(() => runtime.stop());
  const secondBefore = runtime.getSnapshot().providers.find((row) => row.accountKey === second.accountKey);
  firstUnauthorized = true;
  await runtime.refresh({ provider: 'cursor', accountKey: first.accountKey }, 'credential-change');
  const rows = runtime.getSnapshot().providers;
  assert.equal(rows.find((row) => row.accountKey === first.accountKey).status, 'unauthorized');
  assert.deepEqual(rows.find((row) => row.accountKey === first.accountKey).windows, []);
  assert.deepEqual(rows.find((row) => row.accountKey === second.accountKey), secondBefore);
});

test('email-scoped refresh updates its canonical account without duplicating another', async (t) => {
  const makeRow = (key, email, percent) => ({
    provider: 'cursor', accountKey: key, accountEmail: email, status: 'ok', source: 'web',
    updatedAt: '2026-06-01T00:00:00.000Z',
    windows: [{ kind: 'billing', label: 'Cursor Models', usedPercent: percent }]
  });
  const first = makeRow('first', 'first@fixture.invalid', 10);
  const second = makeRow('second', 'second@fixture.invalid', 20);
  const runtime = createLimitsRuntime({ limitProviders: ['cursor'], previousLimits: { providers: [first, second] } }, {
    autoStart: false, autoRetry: false,
    probeProvider: async () => [makeRow('first', 'first@fixture.invalid', 11), makeRow('second', 'second@fixture.invalid', 99)]
  });
  t.after(() => runtime.stop());
  await runtime.refresh({ provider: 'cursor', accountEmail: 'first@fixture.invalid' }, 'credential-change');
  const rows = runtime.getSnapshot().providers;
  assert.equal(rows.length, 2);
  assert.equal(rows.find((row) => row.accountKey === 'first').windows[0].usedPercent, 11);
  assert.equal(rows.find((row) => row.accountKey === 'second').windows[0].usedPercent, 20);
});

test('email-scoped failed lookup invalidates the known key even when the response has no email', async (t) => {
  const first = {
    provider: 'cursor', accountKey: 'first', accountEmail: 'first@fixture.invalid', status: 'ok', source: 'web',
    windows: [{ kind: 'billing', label: 'Cursor Models', usedPercent: 0 }, { kind: 'weekly', label: 'Included usage', usedPercent: 40 }]
  };
  const second = { ...first, accountKey: 'second', accountEmail: 'second@fixture.invalid' };
  const runtime = createLimitsRuntime({ limitProviders: ['cursor'], previousLimits: { providers: [first, second] } }, {
    autoStart: false, autoRetry: false,
    probeProvider: async () => [{
      provider: 'cursor', accountKey: 'first', status: 'unavailable', windows: [],
      invalidateCachedWindowLabels: ['Cursor Models']
    }, { ...second, windows: [] }]
  });
  t.after(() => runtime.stop());
  const before = runtime.getSnapshot();
  await runtime.refresh({ provider: 'cursor', accountEmail: 'first@fixture.invalid' }, 'credential-change');
  const rows = runtime.getSnapshot().providers;
  assert.equal(rows.length, 2);
  assert.equal(rows.find((row) => row.accountKey === 'first').status, 'unavailable');
  assert.deepEqual(rows.find((row) => row.accountKey === 'first').windows.map((window) => window.label), ['Included usage']);
  assert.deepEqual(rows.find((row) => row.accountKey === 'second'), before.providers.find((row) => row.accountKey === 'second'));
});

test('an email match with a different canonical key cannot replace the known account', async (t) => {
  const first = {
    provider: 'cursor', accountKey: 'known', accountEmail: 'same@fixture.invalid', status: 'ok', source: 'web',
    windows: [{ kind: 'billing', label: 'Cursor Models', usedPercent: 10 }]
  };
  const runtime = createLimitsRuntime({ limitProviders: ['cursor'], previousLimits: { providers: [first] } }, {
    autoStart: false, autoRetry: false,
    probeProvider: async () => [{ ...first, accountKey: 'different', windows: [{ kind: 'billing', label: 'Cursor Models', usedPercent: 99 }] }]
  });
  t.after(() => runtime.stop());
  await runtime.refresh({ provider: 'cursor', accountEmail: 'same@fixture.invalid' }, 'credential-change');
  const rows = runtime.getSnapshot().providers;
  assert.equal(rows.length, 1);
  assert.equal(rows[0].accountKey, 'known');
  assert.equal(rows[0].status, 'unavailable');
  assert.equal(rows[0].windows[0].usedPercent, 10);
});

test('an unkeyed successful response cannot replace a scoped Cursor identity', async (t) => {
  const first = {
    provider: 'cursor', accountKey: 'known', accountEmail: 'same@fixture.invalid', status: 'ok', source: 'web',
    windows: [{ kind: 'billing', label: 'Cursor Models', usedPercent: 10 }]
  };
  const runtime = createLimitsRuntime({ limitProviders: ['cursor'], previousLimits: { providers: [first] } }, {
    autoStart: false, autoRetry: false,
    probeProvider: async () => [{ provider: 'cursor', status: 'ok', windows: [{ kind: 'billing', label: 'Cursor Models', usedPercent: 99 }] }]
  });
  t.after(() => runtime.stop());
  await runtime.refresh({ provider: 'cursor', accountEmail: 'same@fixture.invalid' }, 'credential-change');
  const rows = runtime.getSnapshot().providers;
  assert.equal(rows.length, 1);
  assert.equal(rows[0].accountKey, 'known');
  assert.equal(rows[0].status, 'unavailable');
  assert.equal(rows[0].windows[0].usedPercent, 10);
});

test('ambiguous email scope keeps account values separate and marks them unavailable', async (t) => {
  const first = {
    provider: 'cursor', accountKey: 'first', accountEmail: 'shared@fixture.invalid', status: 'ok', source: 'web',
    windows: [{ kind: 'billing', label: 'Cursor Models', usedPercent: 10 }]
  };
  const second = { ...first, accountKey: 'second', windows: [{ kind: 'billing', label: 'Cursor Models', usedPercent: 20 }] };
  const runtime = createLimitsRuntime({ limitProviders: ['cursor'], previousLimits: { providers: [first, second] } }, {
    autoStart: false, autoRetry: false,
    probeProvider: async () => [{ ...first, windows: [{ kind: 'billing', label: 'Cursor Models', usedPercent: 90 }] }, second]
  });
  t.after(() => runtime.stop());
  await runtime.refresh({ provider: 'cursor', accountEmail: 'shared@fixture.invalid' }, 'credential-change');
  const rows = runtime.getSnapshot().providers;
  assert.equal(rows.length, 2);
  assert.deepEqual(rows.map((row) => [row.accountKey, row.status, row.windows[0].usedPercent]), [
    ['first', 'unavailable', 10], ['second', 'unavailable', 20]
  ]);
});

test('an unidentified terminal error cannot clear every account with an ambiguous email', async (t) => {
  const first = {
    provider: 'cursor', accountKey: 'first', accountEmail: 'shared@fixture.invalid', status: 'ok', source: 'web',
    windows: [{ kind: 'billing', label: 'Cursor Models', usedPercent: 10 }]
  };
  const second = { ...first, accountKey: 'second', windows: [{ kind: 'billing', label: 'Cursor Models', usedPercent: 20 }] };
  const runtime = createLimitsRuntime({ limitProviders: ['cursor'], previousLimits: { providers: [first, second] } }, {
    autoStart: false, autoRetry: false,
    probeProvider: async () => { const error = new Error('fixture'); error.status = 'unauthorized'; throw error; }
  });
  t.after(() => runtime.stop());
  await runtime.refresh({ provider: 'cursor', accountEmail: 'shared@fixture.invalid' }, 'credential-change');
  const rows = runtime.getSnapshot().providers;
  assert.deepEqual(rows.map((row) => [row.accountKey, row.status, row.windows[0]?.usedPercent]), [
    ['first', 'unavailable', 10], ['second', 'unavailable', 20]
  ]);
});

test('another account failure cannot defer a successful scoped Cursor refresh', async (t) => {
  const makeRow = (key, status, percent) => ({
    provider: 'cursor', accountKey: key, status, source: 'web', updatedAt: '2026-06-01T00:00:00.000Z',
    windows: status === 'ok' ? [{ kind: 'billing', label: 'Cursor Models', usedPercent: percent }] : []
  });
  const events = [];
  const runtime = createLimitsRuntime({
    limitProviders: ['cursor'], previousLimits: { providers: [makeRow('first', 'ok', 10), makeRow('second', 'ok', 20)] }
  }, {
    autoStart: false, autoRetry: false, onEvent: (event) => events.push(event),
    probeProvider: async () => [makeRow('first', 'ok', 11), makeRow('second', 'unavailable')]
  });
  t.after(() => runtime.stop());
  await runtime.refresh({ provider: 'cursor', accountKey: 'first' }, 'credential-change');
  assert.equal(events.some((event) => event.type === 'retry-scheduled'), false);
  assert.notEqual((await runtime.refresh({ provider: 'cursor', accountKey: 'second' }, 'manual')).deferred, true);
});
