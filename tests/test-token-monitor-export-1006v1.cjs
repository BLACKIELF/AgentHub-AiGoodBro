'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { INPUT_SHA256 } = require('../Companion/TokenMonitorDesktop/transform-stage.cjs');

const upstreamRoot = path.resolve(__dirname, '..', 'Companion/TokenMonitorEngine/upstream');

function transformedModules(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'token-monitor-export-privacy-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.cpSync(path.join(upstreamRoot, 'src/shared'), path.join(root, 'src/shared'), { recursive: true });
  return {
    exporter: require(path.join(root, 'src/shared/exporter.js')),
    usage: require(path.join(root, 'src/shared/usage.js')),
    archive: require(path.join(root, 'src/shared/usage/sessionUsageArchive.js'))
  };
}

function poisonedSession() {
  return {
    client: 'codex', sessionId: 'abc', sessionKind: 'background-review',
    totalTokens: 20, costUsd: 2, outputTokens: 5,
    title: 'private title', sessionTitle: 'private session title', session_title: 'private session title',
    name: 'private name', preview: 'private preview', firstUserMessage: 'private prompt',
    first_user_message: 'private prompt', customTitle: 'private custom title',
    custom_title: 'private custom title', aiTitle: 'private ai title', ai_title: 'private ai title'
  };
}

function freezeDeep(value) {
  if (value && typeof value === 'object' && !Object.isFrozen(value)) {
    for (const child of Object.values(value)) freezeDeep(child);
    Object.freeze(value);
  }
  return value;
}

function assertCleanSession(session) {
  const expected = poisonedSession();
  for (const key of ['title', 'sessionTitle', 'session_title', 'name', 'preview', 'firstUserMessage', 'first_user_message', 'customTitle', 'custom_title', 'aiTitle', 'ai_title']) {
    assert.equal(Object.hasOwn(session, key), false, `${key} must be omitted`);
    delete expected[key];
  }
  for (const [key, value] of Object.entries(expected)) assert.deepEqual(session[key], value);
}

test('merged export privacy modules remain exact frozen upstream without a duplicate backport', () => {
  const pins = JSON.parse(fs.readFileSync(path.join(upstreamRoot, '../SOURCE.json'))).finalSource.files;
  for (const file of ['src/shared/exporter.js', 'src/shared/usage.js']) {
    assert.equal(crypto.createHash('sha256').update(fs.readFileSync(path.join(upstreamRoot, file))).digest('hex'), pins['upstream/' + file]);
    assert.equal(Object.hasOwn(INPUT_SHA256, file), false);
  }
});

test('pinned 0.68 vendor exporter already removes recognized session text', () => {
  const vendor = require(path.join(upstreamRoot, 'src/shared/exporter.js'));
  const text = vendor.renderExportJson({ periods: { today: { totalTokens: 20, sessions: { 'codex:abc': poisonedSession() } } }, history: {} });
  assert.doesNotMatch(text, /private title|private prompt/);
});

test('transformed production exporter strips session text and preserves usage dimensions', (t) => {
  const { exporter } = transformedModules(t);
  const period = {
    totalTokens: 20, costUsd: 2, clients: { codex: 20 }, clientCosts: { codex: 2 },
    models: { name: 20 }, modelCosts: { name: 2 },
    clientCacheReads: { codex: 10 }, clientOutputs: { codex: 5 },
    clientModels: { codex: { name: 20 } },
    projects: { fixture: { name: 'dimension label', totalTokens: 20, costUsd: 2 } },
    sessions: { 'codex:abc': poisonedSession() }
  };
  const periods = freezeDeep({ today: structuredClone(period), month: structuredClone(period), allTime: structuredClone(period) });
  const history = freezeDeep({ daily: [{ date: '2026-10-06', tokens: 20, cost: 2, perClient: { codex: { tokens: 20, cost: 2 } }, perModel: { name: { tokens: 20, cost: 2, outputTokens: 5 } } }], monthly: [{ month: '2026-10', tokens: 20, cost: 2 }] });
  const before = JSON.stringify({ periods, history });
  const json = JSON.parse(exporter.renderExportJson({ periods, history }));
  for (const value of ['private title', 'private session title', 'private name', 'private preview', 'private prompt', 'private custom title', 'private ai title']) {
    assert.equal(JSON.stringify(json).includes(value), false, `private text leaked: ${value}`);
  }
  for (const key of ['today', 'month', 'allTime']) {
    assertCleanSession(json.snapshot[key].sessions['codex:abc']);
    for (const dimension of ['clients', 'clientCosts', 'models', 'modelCosts', 'clientCacheReads', 'clientOutputs', 'clientModels', 'projects']) {
      assert.deepEqual(json.snapshot[key][dimension], period[dimension]);
    }
  }
  assert.deepEqual(json.daily, history.daily);
  assert.deepEqual(json.monthly, history.monthly);
  const files = exporter.exportFileSet({ periods, history });
  assert.equal(files.length, 4);
  for (const file of files) assert.doesNotMatch(file.contents, /private /);
  assert.equal(JSON.stringify({ periods, history }), before, 'frozen input retains local session titles');
});

test('production device-record helper strips both recognized device period schemas', (t) => {
  const { usage } = transformedModules(t);
  const record = freezeDeep({
    deviceId: 'device-1', periods: {
      today: { totalTokens: 20, sessions: { 'codex:abc': poisonedSession() } },
      allTime: { totalTokens: 20, sessions: { 'codex:abc': poisonedSession() } }
    },
    today: { totalTokens: 20, sessions: { 'codex:abc': poisonedSession() } },
    limits: { codex: { remaining: 10 } }
  });
  const before = JSON.stringify(record);
  const stripped = usage.stripSessionTextFromDeviceRecord(record);
  assert.equal(stripped.deviceId, 'device-1');
  assert.deepEqual(stripped.limits, record.limits);
  for (const period of [stripped.today, stripped.periods.today, stripped.periods.allTime]) assertCleanSession(period.sessions['codex:abc']);
  assert.equal(JSON.stringify(record), before);
});

test('production exporter strips device aggregates and session archive projections at the export boundary', (t) => {
  const { exporter, usage, archive } = transformedModules(t);
  const now = new Date('2026-10-06T12:00:00Z');
  const device = freezeDeep({ deviceId: 'synthetic-device', hostname: 'synthetic-host', updatedAt: now.toISOString(), periods: { allTime: { totalTokens: 20, costUsd: 2, clients: { codex: 20 }, clientCosts: { codex: 2 }, sessions: { 'codex:abc': poisonedSession() } } } });
  const aggregate = usage.aggregateDevices([device], 0, now.getTime());
  assert.equal(aggregate.periods.allTime.sessions['codex:abc'].title, 'private title', 'aggregation keeps local display text');
  const syntheticArchive = freezeDeep({ version: 1, sessions: { 'codex:abc': { client: 'codex', sessionId: 'abc', capturedAt: now.toISOString(), periods: { allTime: poisonedSession() } } } });
  const projected = archive.applySessionUsageArchive({ periods: { allTime: usage.emptyPeriod() } }, syntheticArchive, { canonical: true, now });
  assert.equal(projected.periods.allTime.sessions['codex:abc'].title, 'private title', 'archive projection keeps local display text');
  for (const summary of [aggregate, projected]) {
    const before = JSON.stringify(summary);
    const text = exporter.renderExportJson({ periods: summary.periods, history: {}, devices: aggregate.devices, archive: syntheticArchive, limits: { title: 'private limits' } });
    assert.doesNotMatch(text, /private |synthetic-device|synthetic-host/);
    const exported = JSON.parse(text).snapshot.allTime;
    assert.equal(exported.totalTokens, 20);
    assert.equal(exported.costUsd, 2);
    assertCleanSession(exported.sessions['codex:abc']);
    assert.equal(JSON.stringify(summary), before);
  }
});

test('export signature ignores recognized text changes and detects usage changes', (t) => {
  const { exporter } = transformedModules(t);
  const original = { today: { totalTokens: 20, sessions: { 'codex:abc': poisonedSession() } } };
  const renamed = structuredClone(original);
  renamed.today.sessions['codex:abc'].title = 'renamed title';
  renamed.today.sessions['codex:abc'].firstUserMessage = 'renamed prompt';
  assert.equal(exporter.exportSignature(original, {}), exporter.exportSignature(renamed, {}));
  renamed.today.sessions['codex:abc'].totalTokens = 21;
  assert.notEqual(exporter.exportSignature(original, {}), exporter.exportSignature(renamed, {}));
});
