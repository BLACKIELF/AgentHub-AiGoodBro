// Fixed-scanner compatibility at the production Engine loader boundary.
'use strict';
const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
require('../lib/upstream/loader.cjs').prepare();
const { upstreamModule } = require('../lib/upstream/paths.cjs');
const { extractUsageFromTokscale, emptyPeriod } = require(upstreamModule('shared/usage.js'));
const { parseGraphResult } = require(upstreamModule('shared/history.js'));
const { applySessionUsageArchive } = require(upstreamModule('shared/usage/sessionUsageArchive.js'));
const { createSessionUsageArchiveStore } = require(upstreamModule('shared/usage/sessionUsageArchiveStore.js'));
for (const client of ['hermes', 'antigravity-extension']) {
  test(client + ' additive reasoning closes usage, output and history without changing reported cost', () => {
    const row = { client, sessionId: 'same-session', model: 'model-fixture', input: 100, output: 100,
      reasoning: 40, cacheRead: 20, cacheWrite: 10, cost: 1.25 };
    const usage = extractUsageFromTokscale({ entries: [row] });
    const history = parseGraphResult({ contributions: [{ date: '2026-10-10', clients: [{ client,
      modelId: row.model, tokens: { input: 100, output: 100, reasoning: 40, cacheRead: 20, cacheWrite: 10 }, cost: 1.25 }] }] }).contributions[0];
    assert.equal(usage.totalTokens, 270);
    assert.equal(usage.outputTokens, 140);
    assert.equal(usage.costUsd, 1.25);
    assert.equal(history.tokens, usage.totalTokens);
    assert.equal(history.outputTokens, usage.outputTokens);
    assert.equal(history.cost, usage.costUsd);
    const explicit = extractUsageFromTokscale({ entries: [{ ...row, totalTokens: 270 }] });
    assert.equal(explicit.totalTokens, 270);
  });
}
test('legacy normalized Hermes archive is replaced once by the new scanner across DAY MONTH TOTAL', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'tm-hermes-upgrade-'));
  const options = { env: { TOKEN_MONITOR_SHARED_DIR: home } };
  let store = createSessionUsageArchiveStore(options);
  try {
    const at = new Date('2026-10-10T10:00:00Z');
    const normalized = extractUsageFromTokscale({ entries: [{ client: 'hermes', sessionId: 'persisted', model: 'model-fixture',
      input: 100, output: 100, reasoning: 40, cacheRead: 20, cacheWrite: 10, cost: 1.25 }] });
    const legacy = JSON.parse(JSON.stringify(normalized));
    // The old public snapshot already folded its output family. It must not
    // be fed back through the raw scanner reasoning contract on reload.
    legacy.costUsd = 1.4;
    legacy.clientCosts.hermes = 1.4;
    legacy.modelCosts['model-fixture'] = 1.4;
    legacy.sessions['hermes:persisted'].costUsd = 1.4;
    legacy.sessions['hermes:persisted'].modelCosts['model-fixture'] = 1.4;
    const record = period => Object.fromEntries(['today', 'month', 'allTime'].map(key => [key, JSON.parse(JSON.stringify(period))]));
    assert.equal(store.capture(record(legacy), at).error, null);
    store.close();
    store = createSessionUsageArchiveStore(options);
    const old = store.refresh();
    assert.equal(old.sessions['hermes:persisted'].periods.allTime.totalTokens, 270);
    assert.equal(old.sessions['hermes:persisted'].periods.allTime.outputTokens, 140);
    const corrected = record(normalized);
    const first = store.capture(corrected, new Date(at.getTime() + 1000));
    assert.equal(first.error, null);
    const repeat = store.capture(corrected, new Date(at.getTime() + 2000));
    assert.equal(repeat.error, null);
    assert.equal(repeat.changedKeys.size, 0);
    const replay = applySessionUsageArchive(record(emptyPeriod()), repeat.archive, { now: at });
    const live = applySessionUsageArchive(corrected, repeat.archive, { now: at });
    for (const key of ['today', 'month', 'allTime']) {
      assert.equal(replay[key].totalTokens, 270);
      assert.equal(replay[key].outputTokens, 140);
      assert.equal(replay[key].costUsd, 1.25);
      assert.equal(live[key].totalTokens, 270);
      assert.equal(live[key].costUsd, 1.25);
    }
  } finally {
    store.close();
    fs.rmSync(home, { recursive: true, force: true });
  }
});
