'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { createHash } = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { createHomeUsageProvider } = require('../homeUsage.cjs');

const NOW = Date.parse('2026-10-26T04:00:00.000Z');
const scopeKey = (context) => createHash('sha256').update(context).digest('hex');
const pending = (context = 'local:1') => ({ scopeKey: scopeKey(context), pending: true });
function stats(allTime = { totalTokens: 27123456789, costUsd: 19755.13 }) {
  return { updatedAt: '2026-10-26T03:30:00.000Z', timezone: 'Asia/Shanghai', periods: { allTime } };
}
function history() {
  return {
    daily: [{ date: '2026-10-25', tokens: 150, cost: 2, messages: 3, activeTimeMs: 500,
      cacheReadTokens: 10, outputTokens: 20, unclassifiedTokens: 0,
      perClient: { codex: { tokens: 100, cost: 1.5, messages: 2 }, claude: { tokens: 50, cost: 0.5, messages: 1 } },
      perModel: { 'openai/gpt-6.1': { tokens: 100, cost: 1.5 }, 'Claude Sonnet 4.6': { tokens: 50, cost: 0.5 } } }],
    monthly: [{ month: '2026-10', tokens: 150, cost: 2, activeTimeMs: 500,
      perClient: { codex: { tokens: 100, cost: 1.5 } }, perModel: { 'openai/gpt-6.1': { tokens: 100, cost: 1.5 } } }],
    summary: { totalTokens: 150, totalCost: 2, activeDays: 1, currentStreak: 1, longestStreak: 1,
      messages: 3, peakDayTokens: 150, favoriteModel: 'openai/gpt-6.1', activeTimeMs: 500,
      timeMetrics: { totalActiveTimeMs: 500, longestContinuousMs: 400, maxConcurrentSessions: 2, sessionCount: 3 } }
  };
}
function provider(options = {}) {
  const source = stats();
  return createHomeUsageProvider({ getStats: () => source, getHistory: () => history(), getContext: () => 'local:1', now: () => NOW, ...options });
}
function data(result) {
  assert.equal(result.pending, false);
  assert.match(result.revision, /^[a-f0-9]{64}$/);
  assert.match(result.scopeKey, /^[a-f0-9]{64}$/);
  return JSON.parse(result.dashboardJSON);
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

test('headline totals match the floating presentation stats while history keeps its own graph metrics', async () => {
  const source = stats(), graph = history();
  const beforeStats = JSON.stringify(source), beforeHistory = JSON.stringify(graph);
  const output = data(await provider({ getStats: () => source, getHistory: () => graph })());
  assert.equal(output.authority, 'token-monitor-desktop');
  assert.equal(output.schemaVersion, 1);
  assert.equal(output.collectedAt, source.updatedAt);
  assert.equal(output.timezone, 'Asia/Shanghai');
  assert.deepEqual(output.coverage, { tokens: 'known', cost: 'known' });
  assert.deepEqual(output.payload.aggregate.allTime, source.periods.allTime);
  const projected = output.payload.aggregate.history;
  assert.equal(projected.summary.totalTokens, 27123456789, 'never re-sum graph daily or monthly lifetime totals');
  assert.equal(projected.summary.totalCost, 19755.13);
  assert.equal(projected.summary.activeDays, 1);
  assert.equal(projected.summary.favoriteModel, 'openai/gpt-6.1');
  assert.deepEqual(projected.summary.timeMetrics, graph.summary.timeMetrics);
  assert.equal(projected.daily[0].tokens, 150);
  assert.equal(projected.daily[0].perClient.codex.tokens, 100);
  assert.equal(projected.daily[0].perModel['Claude Sonnet 4.6'].tokens, 50);
  assert.equal(projected.monthly[0].perModel['openai/gpt-6.1'].cost, 1.5);
  assert.equal(JSON.stringify(source), beforeStats, 'projection never mutates upstream stats');
  assert.equal(JSON.stringify(graph), beforeHistory, 'projection never mutates upstream history');
  const publicModel = history(); publicModel.daily[0].perModel = { 'longcat@meituan': { tokens: 1, cost: 0 } };
  assert.equal(data(await provider({ getHistory: () => publicModel })()).payload.aggregate.history.daily[0].perModel['longcat@meituan'].tokens, 1,
    'public model namespace with a non-email at-sign is preserved');
});

test('MiMo synthetic model placeholder keeps both daily and monthly groups and their exact metrics', async () => {
  const graph = {
    daily: [
      { date: '2026-09-30', tokens: 90, cost: 1.5, activeTimeMs: 1200, messages: 9,
        perClient: { mimo: { tokens: 50, cost: 0.5 }, codex: { tokens: 40, cost: 1 } },
        perModel: { '<synthetic>': { tokens: 50, cost: 0.5, outputTokens: 5 }, 'model-a': { tokens: 40, cost: 1 } } },
      { date: '2026-10-01', tokens: 30, cost: 0.25, activeTimeMs: 400, messages: 3,
        perClient: { mimo: { tokens: 30, cost: 0.25 } },
        perModel: { '<synthetic>': { tokens: 30, cost: 0.25, outputTokens: 3 } } }
    ],
    monthly: [
      { month: '2026-09', tokens: 90, cost: 1.5, activeTimeMs: 1200,
        perClient: { mimo: { tokens: 50, cost: 0.5 }, codex: { tokens: 40, cost: 1 } },
        perModel: { '<synthetic>': { tokens: 50, cost: 0.5, outputTokens: 5 }, 'model-a': { tokens: 40, cost: 1 } } },
      { month: '2026-10', tokens: 30, cost: 0.25, activeTimeMs: 400,
        perClient: { mimo: { tokens: 30, cost: 0.25 } },
        perModel: { '<synthetic>': { tokens: 30, cost: 0.25, outputTokens: 3 } } }
    ],
    summary: { activeDays: 2, messages: 12, favoriteModel: '<synthetic>', activeTimeMs: 1600,
      timeMetrics: { totalActiveTimeMs: 1600, longestContinuousMs: 1200, maxConcurrentSessions: 2, sessionCount: 3 } }
  };
  const totals = { totalTokens: 120, costUsd: 1.75 };
  const source = stats(totals);
  const before = JSON.stringify(graph);
  const result = data(await provider({ getStats: () => source, getHistory: () => graph })());
  const output = result.payload.aggregate.history;
  assert.deepEqual(result.payload.aggregate.allTime, totals);
  for (const section of ['daily', 'monthly']) {
    assert.equal(output[section].length, 2);
    for (let i = 0; i < 2; i++) {
      const row = output[section][i], original = graph[section][i];
      assert.deepEqual(Object.keys(row.perClient).sort(), Object.keys(original.perClient).sort());
      assert.deepEqual(Object.keys(row.perModel).sort(), Object.keys(original.perModel).sort());
      for (const key of ['tokens', 'cost', 'activeTimeMs']) assert.equal(row[key], original[key]);
      for (const key of ['tokens', 'cost', 'outputTokens']) {
        assert.equal(row.perModel['<synthetic>'][key], original.perModel['<synthetic>'][key]);
      }
      for (const [key, value] of Object.entries(original.perClient)) {
        assert.equal(row.perClient[key].tokens, value.tokens);
        assert.equal(row.perClient[key].cost, value.cost);
      }
    }
  }
  assert.equal(output.summary.favoriteModel, '<synthetic>');
  assert.equal(output.summary.activeTimeMs, 1600);
  assert.deepEqual(output.summary.timeMetrics, graph.summary.timeMetrics);
  assert.equal(JSON.stringify(graph), before, 'the underlying Token Monitor history is never changed');
});

test('only the exact known model placeholder passes, never HTML, private labels or a tool label', async () => {
  const badModels = ['<script>', '<img src=x onerror=alert(1)>', '<other>', '<synthetic/>',
    '<synthetic>extra', '<SYNTHETIC>', '<synthetic@example.invalid>', '<Bearer fake>', '<Users/private>'];
  for (const name of badModels) {
    const graph = { daily: [{ date: '2026-10-25', perModel: { [name]: { tokens: 1 } } }] };
    await assert.rejects(provider({ getHistory: () => graph }), /^Error: home-usage-invalid-label$/);
  }
  await assert.rejects(provider({ getHistory: () => ({ daily: [{ date: '2026-10-25',
    perClient: { '<synthetic>': { tokens: 1 } } }] }) }), /^Error: home-usage-invalid-label$/);
  await assert.rejects(provider({ getHistory: () => ({ daily: [], summary: { favoriteModel: '<script>' } }) }),
    /^Error: home-usage-invalid-label$/);
});

test('actual home render paths display the placeholder as text and escape HTML', () => {
  const root = path.join(__dirname, '../../..');
  const html = fs.readFileSync(path.join(root, 'Resources/UpstreamCharts/home-dashboard.html'), 'utf8');
  const upstreamScript = html.indexOf('desktop/dashboard.js'), homeScript = html.indexOf('home-dashboard.js');
  assert.ok(upstreamScript >= 0 && homeScript > upstreamScript, 'home overrides follow the upstream renderer');
  const home = fs.readFileSync(path.join(root, 'Resources/UpstreamCharts/home-dashboard.js'), 'utf8');
  const start = home.indexOf('function tooltipRow('), end = home.indexOf('showHeatTooltip =', start);
  assert.ok(start >= 0 && end > start);
  class TextNodeElement {
    constructor(tag) { this.tagName = tag; this.children = []; this.style = {}; this.textContent = ''; }
    append(...nodes) { this.children.push(...nodes); }
    replaceChildren(...nodes) { this.children = nodes; }
    set innerHTML(_) { throw new Error('model label must not be interpolated into HTML'); }
  }
  const legend = new TextNodeElement('div'), tooltip = new TextNodeElement('div');
  const sandbox = { document: { createElement: tag => new TextNodeElement(tag) }, els: { legend, tooltip },
    renderLegend: null, showBarTooltip: null, colorFor: () => 'rgb(1,2,3)', fullNumber: String,
    shortDate: () => 'date', positionTooltip: () => {} };
  vm.runInNewContext(home.slice(start, end), sandbox, { filename: 'home-dashboard.js' });
  const model = { bars: [{ segments: [{ key: '<synthetic>', value: 7 }] }] };
  sandbox.renderLegend(model);
  assert.equal(legend.children[0].children[1].textContent, '<synthetic>');
  sandbox.showBarTooltip({ label: 'date', total: 7, segments: model.bars[0].segments }, {});
  assert.equal(tooltip.children[1].children[1].textContent, '<synthetic>');
  const charts = require(path.join(root, 'Resources/UpstreamCharts/desktop/usageCharts.js'));
  const cards = charts.statsCardsHtml([{ key: 'favoriteModel', value: '<synthetic>' }]);
  assert.ok(cards.includes('&lt;synthetic&gt;'));
  assert.equal(cards.includes('<synthetic>'), false);
  const desktop = fs.readFileSync(path.join(root, 'Resources/UpstreamCharts/desktop/dashboard.js'), 'utf8');
  const breakdownStart = desktop.indexOf('function renderBreakdown()');
  const breakdownEnd = desktop.indexOf('\nlet statCardMeasureCanvas', breakdownStart);
  assert.ok(breakdownStart >= 0 && breakdownEnd > breakdownStart);
  const breakdown = { innerHTML: '' };
  const context = { document: { getElementById: () => breakdown },
    state: { history: { daily: [{ tokens: 7, perModel: { '<synthetic>': { tokens: 7 } } }] }, motion: 'none' },
    charts: { modelColor: () => 'rgb(1,2,3)', clientColors: { default: 'rgb(1,2,3)' } },
    captureGeometry: () => new Map(), displayColor: x => x, t: x => x, formatCompact: String,
    applySwatchColors: () => {} };
  vm.runInNewContext(desktop.slice(breakdownStart, breakdownEnd) + '\nrenderBreakdown();', context);
  assert.ok(breakdown.innerHTML.includes('&lt;synthetic&gt;'));
  assert.equal(breakdown.innerHTML.includes('<synthetic>'), false);
});

test('same object and scope reuse serialized output without reading history again; revisions are opaque', async () => {
  let source = stats(), context = 'local:1;private@example.invalid;history=true', reads = 0, clockReads = 0;
  const read = provider({ getStats: () => source, getContext: () => context, getHistory: () => { reads++; return history(); }, now: () => { clockReads++; return NOW; } });
  const first = await read();
  assert.equal(reads, 1);
  assert.equal((await read()).dashboardJSON, first.dashboardJSON);
  assert.deepEqual(await read(first.revision), { scopeKey: first.scopeKey, revision: first.revision, unchanged: true });
  assert.equal(reads, 1, '30-second host polling does not re-read or re-serialize history');
  assert.equal(clockReads, 0, 'existing collection timestamp stays authoritative');
  assert.equal(JSON.stringify(first).includes('private@example.invalid'), false);
  assert.equal(read.scopeKey(), first.scopeKey, 'status may cheaply read the same opaque scope without history');
  assert.equal(first.scopeKey, scopeKey(context));
  context = 'sync:2;history=true';
  assert.equal(read.scopeKey(), scopeKey(context), 'a scope change is immediately visible before any history read');
  assert.equal(reads, 1, 'status scope query does not read history');
  const changedScope = await read(first.revision);
  assert.equal(reads, 2);
  assert.notEqual(changedScope.revision, first.revision, 'scope alone invalidates revision even with identical totals');
  assert.notEqual(changedScope.scopeKey, first.scopeKey);
  source = { ...source, periods: { allTime: { totalTokens: 7, costUsd: 0 } } };
  const changedStats = data(await read(changedScope.revision));
  assert.equal(reads, 3);
  assert.equal(changedStats.payload.aggregate.history.summary.totalTokens, 7);
});

test('concurrent reads share one history read and an asynchronous scope switch returns pending without retrying', async () => {
  const firstHistory = deferred();
  let source = stats(), context = 'local:1', reads = 0;
  const read = provider({ getStats: () => source, getContext: () => context, getHistory: () => { reads++; return firstHistory.promise; } });
  const first = read(), concurrent = read('older');
  assert.equal(reads, 1);
  context = 'sync:2';
  assert.deepEqual(await read(), pending('sync:2'));
  assert.equal(reads, 1, 'new scope cannot start a second scan while old one is pending');
  firstHistory.resolve(history());
  assert.deepEqual(await first, pending('local:1'));
  assert.deepEqual(await concurrent, pending('local:1'));
  assert.equal(reads, 1, 'stale callback does not recursively retry');
  const fresh = await read();
  assert.equal(reads, 2);
  data(fresh);
  assert.deepEqual(await read(fresh.revision), { scopeKey: fresh.scopeKey, revision: fresh.revision, unchanged: true });
  source = stats({ totalTokens: 8, costUsd: 1 });
  data(await read());
  assert.equal(reads, 3);
});

test('stats replaced or made pending during history resolution cannot publish an old mixed snapshot', async () => {
  for (const change of ['replace', 'pending', 'in-place']) {
    const held = deferred();
    let source = stats(), reads = 0;
    const read = provider({ getStats: () => source, getHistory: () => { reads++; return held.promise; } });
    const inFlight = read();
    if (change === 'replace') source = stats({ totalTokens: 55, costUsd: 4 });
    else if (change === 'pending') source.aigoodbroUsagePending = true;
    else source.periods.allTime.totalTokens = 55;
    held.resolve(history());
    assert.deepEqual(await inFlight, pending());
    assert.equal(reads, 1);
  }
});

test('an old scope history failure returns pending without treating the replacement scope as failed', async () => {
  const held = deferred(); let context = 'local:1', reads = 0;
  const read = provider({ getContext: () => context, getHistory: () => { reads++; return held.promise; } });
  const first = read();
  context = 'sync:2'; held.reject(new Error('old scope is gone'));
  assert.deepEqual(await first, pending('local:1'));
  assert.equal(reads, 1);
});

test('pending or missing all-time data never calls history or manufactures zero', async () => {
  let source, reads = 0;
  const read = provider({ getStats: () => source, getHistory: () => { reads++; return history(); } });
  for (source of [null, undefined, {}, { periods: {} }, { periods: { allTime: null } }, { ...stats(), aigoodbroUsagePending: true }]) {
    assert.deepEqual(await read(), pending());
  }
  assert.equal(reads, 0);
  source = stats({ totalTokens: null, costUsd: null });
  const unknown = data(await read());
  assert.deepEqual(unknown.payload.aggregate.allTime, { totalTokens: null, costUsd: null });
  assert.equal(unknown.payload.aggregate.history.summary.totalTokens, null);
  assert.equal(unknown.payload.aggregate.history.summary.totalCost, null);
  assert.deepEqual(unknown.coverage, { tokens: 'unknown', cost: 'unknown' });
  source = stats({ totalTokens: 0, costUsd: 0 });
  assert.deepEqual(data(await read()).coverage, { tokens: 'known', cost: 'known' }, 'a real zero is distinct from missing');
  source = stats({ totalTokens: 10, costUsd: 2, unpricedTokens: 3 });
  assert.deepEqual(data(await read()).coverage, { tokens: 'known', cost: 'partial' });
});

test('missing history metrics remain null; timestamps and dates come from validated source or the actual clock', async () => {
  const source = { periods: { allTime: {} } };
  const projected = data(await provider({ getStats: () => source, getHistory: () => ({ daily: [{ date: '2024-02-29' }], monthly: [{ month: '2024-02' }] }) })());
  assert.equal(projected.collectedAt, new Date(NOW).toISOString());
  assert.equal(projected.timezone, Intl.DateTimeFormat().resolvedOptions().timeZone);
  const row = projected.payload.aggregate.history.daily[0];
  assert.equal(row.tokens, null);
  assert.equal(row.cost, null);
  assert.equal(row.perClient, null);
  assert.equal(projected.payload.aggregate.history.summary.activeDays, null);
  const offset = stats(); offset.collectedAt = '2026-10-26T12:00:00+08:00';
  assert.equal(data(await provider({ getStats: () => offset })()).collectedAt, new Date(NOW).toISOString());
  const sorted = data(await provider({ getHistory: () => ({ daily: [{ date: '2026-10-26' }, { date: '2026-10-25' }] }) })());
  assert.deepEqual(sorted.payload.aggregate.history.daily.map((row) => row.date), ['2026-10-25', '2026-10-26']);
});

test('absent message counts omit the reserved native key rather than inventing zero or sending null', async () => {
  const projected = data(await provider({ getHistory: () => ({ daily: [{ date: '2026-10-26', perModel: { 'gpt-6': { tokens: 5 } } }], summary: {} }) })());
  const graph = projected.payload.aggregate.history;
  assert.equal(Object.hasOwn(graph.summary, 'messages'), false);
  assert.equal(Object.hasOwn(graph.daily[0], 'messages'), false);
  assert.equal(Object.hasOwn(graph.daily[0].perModel['gpt-6'], 'messages'), false);
  assert.equal(graph.daily[0].perModel['gpt-6'].cost, null, 'ordinary unknown numeric fields remain null');
});

test('projection drops account, device, path, message body and arbitrary unknown fields without traversing them', async () => {
  const privateText = 'private@example.invalid /Users/synthetic/private prompt body';
  const source = stats();
  source.accounts = [{ email: privateText }]; source.deviceId = privateText; source.message = privateText;
  const graph = history();
  for (const obj of [graph, graph.summary, graph.daily[0], graph.monthly[0], graph.daily[0].perClient.codex, graph.daily[0].perModel['openai/gpt-6.1']]) {
    obj.account = { email: privateText }; obj.path = privateText; obj.body = privateText; obj.messagesText = privateText;
    Object.defineProperty(obj, 'credentials', { enumerable: true, get() { throw new Error('private property must never be read'); } });
  }
  graph.deviceHistories = [{ hostname: privateText, history: graph }];
  const output = await provider({ getStats: () => source, getHistory: () => graph })();
  assert.equal(output.dashboardJSON.includes('private@example.invalid'), false);
  assert.equal(output.dashboardJSON.includes('/Users/'), false);
  assert.equal(output.dashboardJSON.includes('prompt body'), false);
  assert.equal(output.dashboardJSON.includes('credentials'), false);
  assert.equal(output.dashboardJSON.includes('deviceHistories'), false);
  assert.equal(data(output).payload.aggregate.history.daily[0].messages, 3, 'numeric message count remains a supported metric');
});

test('bad numbers, dates, labels and structures fail explicitly and never echo private input', async () => {
  for (const bad of [false, 0, 1, 'private@example.invalid', [], { periods: [] }, { periods: { allTime: 0 } }]) {
    await assert.rejects(provider({ getStats: () => bad }), /^Error: home-usage-invalid-stats$/);
  }
  for (const bad of [-1, 1.5, Number.MAX_SAFE_INTEGER + 1, Infinity, NaN, '100', { value: 'private@example.invalid' }]) {
    await assert.rejects(provider({ getStats: () => stats({ totalTokens: bad, costUsd: 1 }) }), /^Error: home-usage-invalid-number$/);
    const graph = history(); graph.daily[0].perModel['openai/gpt-6.1'].tokens = bad;
    await assert.rejects(provider({ getHistory: () => graph }), /^Error: home-usage-invalid-number$/);
  }
  for (const bad of [-1, Infinity, NaN, '1.2', {}]) {
    await assert.rejects(provider({ getStats: () => stats({ totalTokens: 1, costUsd: bad }) }), /home-usage-invalid-number/);
  }
  for (const bad of ['2026-02-29', '2026-13-01', '2026-01-32', '2026-1-01', 'private@example.invalid']) {
    await assert.rejects(provider({ getHistory: () => ({ daily: [{ date: bad }] }) }), /^Error: home-usage-invalid-date$/);
  }
  for (const bad of ['private@example.invalid', '/Users/synthetic/private', 'C:/private/file', '../secrets', 'https://example.invalid', 'model\nbody', 'model.json', '__proto__', 'sk-' + 'a'.repeat(20), 'Bearer privatevalue']) {
    const graph = history(); graph.daily[0].perModel = Object.fromEntries([[bad, { tokens: 1, cost: 0 }]]);
    await assert.rejects(provider({ getHistory: () => graph }), /^Error: home-usage-invalid-label$/);
  }
  await assert.rejects(provider({ getHistory: () => ({ daily: [{ date: '2026-10-26' }, { date: '2026-10-26' }] }) }), /home-usage-invalid-duplicate-date/);
  await assert.rejects(provider({ getHistory: () => ({ daily: 'private@example.invalid' }) }), /^Error: home-usage-invalid-history$/);
  await assert.rejects(provider({ getStats: () => ({ ...stats(), timezone: 'private@example.invalid' }) }), /^Error: home-usage-invalid-timezone$/);
  await assert.rejects(provider({ getStats: () => ({ ...stats(), updatedAt: '2026-10-26T24:00:00Z' }) }), /home-usage-invalid-timestamp/);
});

test('history and serialization limits reject the whole result rather than silently truncating', async () => {
  await assert.rejects(provider({ getHistory: () => ({ daily: Array.from({ length: 10001 }, () => ({ date: '2026-10-26' })) }) }), /home-usage-invalid-history-size/);
  const huge = history();
  huge.daily[0].perModel = Object.fromEntries(Array.from({ length: 60000 }, (_, i) => ['model-' + i, { tokens: 1, cost: 1 }]));
  await assert.rejects(provider({ getHistory: () => huge }), /^Error: home-usage-invalid-size$/);
  const exact = Array.from({ length: 10000 }, (_, index) => ({ date: new Date(Date.UTC(1990, 0, 1 + index)).toISOString().slice(0, 10), tokens: 0, cost: 0 }));
  assert.equal(data(await provider({ getHistory: () => ({ daily: exact }) })()).payload.aggregate.history.daily.length, 10000);
});

test('history errors are safe, do not poison the cache, and a later read may recover', async () => {
  const source = stats(); let calls = 0;
  const read = provider({ getStats: () => source, getHistory: () => { calls++; if (calls === 1) throw new Error('private@example.invalid'); return history(); } });
  await assert.rejects(read, /^Error: home-usage-history-read-failed$/);
  data(await read());
  assert.equal(calls, 2);
});
