'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { handleRequest } = require('../lib/handler.cjs');
const f = require('./helpers/fixtures.cjs');
const { sanitize } = require('../lib/sanitize.cjs');
const qa = path.resolve(__dirname, '../../qa');
function save(name, request, response) {
  fs.mkdirSync(qa, { recursive: true });
  fs.writeFileSync(path.join(qa, `compat-${name}-request.json`), JSON.stringify(request, null, 2) + '\n');
  fs.writeFileSync(path.join(qa, `compat-${name}-response.json`), JSON.stringify(response, null, 2) + '\n');
}
function boundRunners() {
  const seen = [];
  function read(input, graph) {
    const root = input.customScanPaths?.[input.clients]?.[0] || (input.clients === 'codex' ? input.env.CODEX_HOME : input.homeDir);
    assert.equal(process.env.HOME, input.homeDir);
    assert.equal(process.cwd(), input.cwdDir);
    assert.equal(input.env.PATH, '');
    assert.equal(input.env.TOKEN_MONITOR_ENGINE_FIXTURES, undefined);
    seen.push({ root, graph, client: input.clients });
    const fixture = JSON.parse(fs.readFileSync(path.join(root, 'scan-fixture.json')));
    if (fixture.fail) throw new Error('synthetic-scan-failed');
    if (graph) return f.historyGraph(fixture.date, fixture.tokens, { client: input.clients });
    const usage = f.usageSnapshot(fixture.tokens, { client: input.clients, modelName: 'public/model@route' });
    Object.assign(usage.entries[0], { sessionId: 'synthetic-session', projectId: 'synthetic-project',
      projectLabel: 'synthetic-private-project', sessionTitle: 'synthetic private title',
      startedAt: '2026-09-13T00:00:00Z', lastUsedAt: '2026-09-13T01:00:00Z' });
    return usage;
  }
  return { seen, runTokscale: input => read(input, false), runGraph: input => read(input, true) };
}
function writeScan(root, tokens, date = '2026-09-13', fail = false) {
  fs.writeFileSync(path.join(root, 'scan-fixture.json'), JSON.stringify({ tokens, date, fail }));
}

test('real upstream usage/history bind two homes; missing days and failed targets remain unknown', async () => {
  const home = f.makeHome();
  try {
    const layout = f.twoToolsTwoHomes(home);
    writeScan(layout.codexA, 11, '2026-09-12');
    writeScan(layout.codexB, 22, '2026-09-13');
    const historySources = layout.sources.slice(1).map(({ accountId, ...source }) => source);
    const request = f.baseRequest(home, { sources: historySources });
    assert.ok(request.sources.every(source => !Object.hasOwn(source, 'accountId')));
    const runners = boundRunners();
    const response = await handleRequest(request, runners);
    assert.equal(response.payload.aggregate.today.totalTokens, 33);
    assert.deepEqual(response.payload.history.daily.map(day => day.tokens), [11, 22]);
    assert.equal(runners.seen.filter(call => call.graph && call.root === layout.codexA).length, 1);
    const bPrevious = response.coverage.entries.find(entry => entry.sourceId === 'codex-b' && entry.date === '2026-09-12' && entry.metric === 'tokens');
    assert.equal(bPrevious.status, 'unknown');
    assert.ok(response.coverage.entries.filter(entry => entry.metric === 'tokens').every(entry => !entry.accountId));
    assert.equal(response.coverage.cost, 'unknown');
    assert.equal(response.coverage.days.find(day => day.date === '2026-09-13').status, 'known');
    assert.equal(response.payload.usage.targets[0].today.models['public/model@route'], 11);
    assert.ok(Object.keys(response.payload.usage.targets[0].today.sessions).length > 0);
    assert.ok(Object.keys(response.payload.aggregate.today.projects).length > 0);
    assert.ok(!JSON.stringify(response).includes('/tmp/synthetic-private'));
    save('usage', request, response);
    writeScan(layout.codexB, 0, '2026-09-13', true);
    const failed = await handleRequest(request, boundRunners());
    assert.equal(failed.sources[1].status, 'unavailable');
    assert.equal(failed.coverage.days.find(day => day.date === '2026-09-13').status, 'partial');
    assert.ok(failed.errors.length > 0);
    save('usage-unavailable', request, failed);
  } finally { f.cleanup(home); }
});

test('same userHome independent tools; same tool aliases and actual nested scopes excluded once', async () => {
  const home = f.makeHome();
  try {
    fs.mkdirSync(path.join(home, '.claude/projects'), { recursive: true });
    fs.mkdirSync(path.join(home, '.codex/sessions'), { recursive: true });
    const alias = path.join(home, 'alias'); fs.symlinkSync(path.join(home, '.claude/projects'), alias);
    const sources = ['claude', 'codex'].map(providerId => f.source({ id: providerId, providerId, canonicalPath: home, pathRole: 'userHome' }));
    sources.push(f.source({ id: 'same-claude', providerId: 'claude', canonicalPath: alias }));
    const seen = [];
    const response = await handleRequest(f.baseRequest(home, { sources }), {
      runTokscale: async input => { seen.push(input.clients); return f.usageSnapshot(1, { client: input.clients }); },
      runGraph: async input => f.historyGraph('2026-09-13', 1, { client: input.clients })
    });
    assert.deepEqual(response.sources.map(source => source.status), ['ok', 'ok', 'excluded']);
    assert.deepEqual(seen, ['claude','claude','claude','codex','codex','codex']);
    assert.equal(response.payload.aggregate.today.totalTokens, 2);
  } finally { f.cleanup(home); }
});

test('exact logRoot passes original extra-root option under empty home and never authorizes quota', async () => {
  const home = f.makeHome();
  try {
    const logs = f.makeLogRoot(home); writeScan(logs, 0);
    const request = f.baseRequest(home, { sources: [f.source({ id: 'logs', providerId: 'codex', canonicalPath: logs })] });
    const runner = boundRunners();
    const response = await handleRequest(request, runner);
    assert.ok(runner.seen.every(call => call.root === logs));
    assert.equal(response.payload.aggregate.today.totalTokens, 0);
    assert.equal(response.coverage.days[0].status, 'known');
    let reads = 0;
    const limits = await handleRequest({ ...request, operation: 'collectLimits' }, { limitsDeps: { readFileSync: () => { reads++; throw Error(); } } });
    assert.equal(reads, 0);
    assert.equal(limits.sources[0].status, 'unavailable');
    assert.deepEqual(limits.payload.limits.targets, []);
  } finally { f.cleanup(home); }
});

test('original managed Codex HTTP mapper returns independent reset credits and per-target quota', async () => {
  const home = f.makeHome();
  try {
    const layout = f.twoToolsTwoHomes(home);
    const request = f.baseRequest(home, { operation: 'collectLimits', sources: layout.sources.slice(1) });
    const reads = [], probes = [];
    const deps = {
      limitsDeps: {
        readFileSync: file => {
          const root = path.dirname(file);
          assert.ok(root === layout.codexA || root === layout.codexB, 'only authorized managed root');
          reads.push(path.basename(file));
          if (path.basename(file) !== 'auth.json') throw Error('synthetic-missing');
          return JSON.stringify({ tokens: { access_token: root === layout.codexA ? 'synthetic-only-a' : 'synthetic-only-b' } });
        }
      },
      fetch: async (url, init) => {
        const a = new Headers(init.headers).get('authorization') === 'Bearer synthetic-only-a';
        const endpoint = new URL(url).pathname;
        probes.push(endpoint);
        if (endpoint.endsWith('/rate-limit-reset-credits')) return { ok: true, status: 200, json: async () => ({ available_count: a ? 2 : 7, credits: [] }) };
        assert.ok(endpoint.endsWith('/usage'));
        return { ok: true, status: 200, json: async () => ({ rateLimits: { primary: { usedPercent: a ? 12 : 67, windowDurationMins: 300, resetsAt: 1790000000 } }, account: { email: 'synthetic@example.invalid' } }) };
      }
    };
    const response = await handleRequest(request, deps);
    assert.equal(response.payload.limits.targets.length, 2);
    assert.deepEqual(response.payload.limits.targets.map(target => target.snapshot.providers[0].resetCredits.availableCount), [2, 7]);
    assert.deepEqual(response.payload.limits.targets.map(target => target.snapshot.providers[0].windows[0].usedPercent), [12, 67]);
    assert.ok(response.coverage.entries.filter(entry => entry.metric === 'quota').every(entry => entry.status === 'known'));
    const encoded = JSON.stringify(response);
    assert.ok(!encoded.includes('synthetic@example.invalid') && !encoded.includes('synthetic-only') && !encoded.includes(home));
    assert.equal(probes.filter(endpoint => endpoint.endsWith('/rate-limit-reset-credits')).length, 2);
    assert.ok(reads.length > 0);
    save('limits', request, response);
    const unavailable = await handleRequest(request, { ...deps, fetch: async (url, init) => {
      if (new Headers(init.headers).get('authorization') === 'Bearer synthetic-only-b') return { ok: false, status: 401, json: async () => ({}) };
      return deps.fetch(url, init);
    } });
    assert.deepEqual(unavailable.coverage.entries.filter(entry => entry.metric === 'quota').map(entry => entry.status), ['known', 'unknown']);
    save('limits-unavailable', request, unavailable);
  } finally { f.cleanup(home); }
});

test('private session/project dimensions retain structure and stable joins; public model@route survives', () => {
  const raw = { sessions: { '/tmp/private/session': { sessionId: '/tmp/private/session', projectId: '/tmp/private/project', title: 'private text', totalTokens: 9,
    models: { 'vendor/model@route': 9 }, prompt: 'private prompt', response: 'private response', accessToken: 'synthetic' } },
    projects: { '/tmp/private/project': { totalTokens: 9, label: 'synthetic@example.invalid' } } };
  const clean = sanitize(raw);
  assert.equal(Object.keys(clean.sessions).length, 1);
  const session = Object.values(clean.sessions)[0];
  assert.equal(session.totalTokens, 9);
  assert.equal(session.models['vendor/model@route'], 9);
  assert.equal(session.projectId, Object.keys(clean.projects)[0]);
  assert.deepEqual(clean, sanitize(raw));
  assert.ok(!JSON.stringify(clean).includes('private') && !JSON.stringify(clean).includes('@example'));
});

test('additional-only original Codex windows remain payload data but cannot certify canonical quota', async () => {
  const home = f.makeHome();
  try {
    const layout = f.twoToolsTwoHomes(home);
    const response = await handleRequest(f.baseRequest(home, { operation: 'collectLimits', sources: [layout.sources[1]] }), {
      limitsDeps: { readFileSync: () => JSON.stringify({ tokens: { access_token: 'synthetic-only' } }) },
      fetch: async url => ({ ok: true, status: 200, json: async () => new URL(url).pathname.endsWith('/usage')
        ? { additional_rate_limits: [{ metered_feature: 'review', rate_limit: { primary_window: { used_percent: 30, limit_window_seconds: 18000, reset_at: 1790000000 } } }] }
        : { available_count: 0, credits: [] } })
    });
    const provider = response.payload.limits.targets[0].snapshot.providers[0];
    assert.ok(provider.windows.length > 0);
    assert.ok(provider.windows.every(window => window.additional === true));
    assert.equal(response.coverage.entries.find(entry => entry.metric === 'quota').status, 'unknown');
  } finally { f.cleanup(home); }
});

test('pinned fork parses Proma from each explicit userHome without module-load home leakage', async () => {
  const home = f.makeHome();
  try {
    const sources = [];
    for (const [id, tokens] of [['a', 4], ['b', 9]]) {
      const root = path.join(home, id);
      const logs = path.join(root, '.proma/agent-sessions'); fs.mkdirSync(logs, { recursive: true });
      fs.writeFileSync(path.join(logs, 'synthetic.jsonl'), JSON.stringify({ type: 'assistant', _createdAt: '2026-09-13T00:00:00Z',
        message: { id: 'synthetic-message', model: 'public/model@route', usage: { input_tokens: tokens, output_tokens: 0 } } }) + '\n');
      sources.push(f.source({ id, providerId: 'proma', canonicalPath: root, pathRole: 'userHome' }));
    }
    const result = await handleRequest(f.baseRequest(home, { sources }));
    assert.equal(result.payload.aggregate.allTime.totalTokens, 13);
    assert.deepEqual(result.payload.usage.targets.map(target => target.allTime.totalTokens), [4, 9]);
    assert.equal(result.payload.history.daily[0].tokens, 13);
    assert.equal(result.coverage.days[0].status, 'known');
  } finally { f.cleanup(home); }
});

// Host integration regression: history is valid without assigning today's login.
test('unattributed managed home collects usage but cannot authorize limits or implicit auth reads', async () => {
  const home = f.makeHome();
  try {
    const layout = f.twoToolsTwoHomes(home);
    writeScan(layout.codexA, 0);
    const { accountId, ...source } = layout.sources[1];
    const request = f.baseRequest(home, { sources: [source] });
    const usage = await handleRequest(request, boundRunners());
    assert.equal(usage.sources[0].status, 'ok');
    assert.equal(usage.payload.aggregate.today.totalTokens, 0);
    assert.equal(usage.coverage.days[0].status, 'known');
    let reads = 0;
    const limits = await handleRequest({ ...request, operation: 'collectLimits' }, { limitsDeps: {
      readFileSync: () => { reads++; throw Error('read-forbidden'); }
    } });
    assert.equal(reads, 0);
    assert.equal(limits.sources[0].status, 'error');
    assert.deepEqual(limits.payload.limits.targets, []);
  } finally { f.cleanup(home); }
});
