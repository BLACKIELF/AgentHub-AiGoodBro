'use strict';
// Production scanner + bridge, synthetic homes only. No GUI or real credentials.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const charts = require('../Resources/UpstreamCharts/desktop/usageCharts.js');

const engine = path.resolve(process.argv[2] || '');
assert.ok(fs.existsSync(path.join(engine, 'RUNTIME.json')), 'supply the staged shared-runtime Engine');
const helper = path.resolve(engine, '../../Helpers/AiGoodBro Token Core.app/Contents/MacOS/AiGoodBro Token Core');
const base = fs.mkdtempSync(path.join(os.tmpdir(), 'tm-native-upgrade-1008-'));
const privateHome = path.join(base, 'driver-home');
fs.mkdirSync(privateHome);
const request = {
  schemaVersion: 1, requestId: 'fixed-fork-cache-test', operation: 'collectUsage',
  now: new Date().toISOString(), timezone: 'UTC', cacheDirectory: path.join(base, 'bridge-cache'),
  options: { timeoutMs: 30000, allowPriceNetwork: false, allowProviderNetwork: false,
    allowSelfSync: false, allowCredentialRefresh: false, includeLiveCodexAccount: false },
  customSources: []
};
function collect(sources) {
  const processResult = spawnSync(helper, [path.join(engine, 'bridge.cjs')], {
    cwd: privateHome, env: { HOME: privateHome, TMPDIR: base, PATH: '', TZ: 'UTC', ELECTRON_RUN_AS_NODE: '1' },
    input: JSON.stringify({ ...request, sources }), encoding: 'utf8', timeout: 40000
  });
  assert.equal(processResult.status, 0, processResult.stderr);
  const response = JSON.parse(processResult.stdout);
  assert.equal(response.engine.commit, '5d2db368d8313415763860d594de00e46a663418');
  assert.equal(response.status, 'ok', JSON.stringify(response.errors));
  return response;
}
const source = (id, providerId, canonicalPath) => ({ id, providerId, canonicalPath,
  kind: 'agentLogs', pathRole: 'userHome', authority: 'upstream', enabled: true });
function assistant(block, usage, timestamp = '2026-10-08T00:00:01Z') {
  return { type: 'assistant', apiBlockIndex: block, timestamp, requestId: 'request-cache-split',
    message: { id: 'message-cache-split', model: 'claude-3-5-sonnet',
      content: [{ type: block ? 'text' : 'thinking', ...(block ? { text: 'synthetic text' } : { thinking: 'synthetic thought' }) }], usage } };
}
function assertPeriod(response, input, cacheRead, output) {
  const period = response.payload.aggregate.allTime;
  assert.equal(period.totalTokens, input + cacheRead + output);
  assert.equal(period.cacheReadTokens, cacheRead);
  assert.equal(period.outputTokens, output);
  assert.equal(response.payload.history.daily.reduce((sum, day) => sum + day.tokens, 0), period.totalTokens);
  assert.equal(Object.keys(period.sessions).length, 1, 'streaming copies must remain one conversation');
  const chart = charts.dailyBarsChart(response.payload.history.daily, { metric: 'tokens', stackBy: 'client' });
  assert.equal(chart.bars.reduce((sum, bar) => sum + bar.total, 0), period.totalTokens,
    'retained 0.62 UpstreamCharts accepts actual normalized 0.68 history without dropping or double-counting');
  assert.deepEqual(chart.keys, ['claude']);
}
try {
  const home = path.join(base, 'claude-home');
  const logs = path.join(home, '.claude/projects/synthetic-project');
  fs.mkdirSync(logs, { recursive: true });
  const file = path.join(logs, 'cache-regression.jsonl');
  const snapshot = assistant(0, { input_tokens: 42494, output_tokens: 0 });
  const split = assistant(1, { input_tokens: 265, output_tokens: 120, cache_read_input_tokens: 42000, cache_creation_input_tokens: 0 });
  fs.writeFileSync(file, [snapshot, split].map(JSON.stringify).join('\n') + '\n');
  const declaration = [source('claude-fixture', 'claude', home)];
  for (let warm = 0; warm < 3; warm++) assertPeriod(collect(declaration), 265, 42000, 120);
  const corrected = assistant(1, { input_tokens: 330, output_tokens: 125, cache_read_input_tokens: 40000, cache_creation_input_tokens: 0 });
  fs.writeFileSync(file, JSON.stringify(corrected) + '\n');
  const changed = collect(declaration);
  assert.equal(changed.payload.aggregate.today.totalTokens, 40455, 'changed source invalidates native message cache');
  assert.equal(changed.payload.aggregate.today.cacheReadTokens, 40000);
  // The original upstream archive deliberately retains component high-water
  // marks for month/allTime when an existing transcript is rewritten smaller.
  assertPeriod(changed, 330, 42000, 125);
  const reverseHome = path.join(base, 'claude-reverse-home');
  const reverseLogs = path.join(reverseHome, '.claude/projects/synthetic-project');
  fs.mkdirSync(reverseLogs, { recursive: true });
  fs.writeFileSync(path.join(reverseLogs, 'reverse.jsonl'), [corrected, snapshot].map(JSON.stringify).join('\n') + '\n');
  assertPeriod(collect([source('claude-reverse-fixture', 'claude', reverseHome)]), 330, 40000, 125);

  const sources = [];
  for (const [id, count] of [['a', 4], ['b', 9]]) {
    const root = path.join(base, 'proma-' + id);
    const dir = path.join(root, '.proma/agent-sessions');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'proma-fixture.jsonl'), JSON.stringify({ type: 'assistant', _createdAt: '2026-10-08T00:00:02Z',
      message: { id: 'proma-message', model: 'claude-sonnet-4-5', usage: { input_tokens: count, output_tokens: 0 } } }) + '\n');
    sources.push(source('proma-' + id, 'proma', root));
  }
  const proma = collect(sources);
  assert.equal(proma.payload.aggregate.allTime.totalTokens, 13);
  assert.deepEqual(proma.payload.usage.targets.map(target => target.allTime.totalTokens), [4, 9]);
  assert.equal(proma.payload.history.daily.reduce((sum, day) => sum + day.tokens, 0), 13);
  console.log(JSON.stringify({ ok: true, forkRelease: 'token-monitor-d5e8ad9b',
    checks: ['claude-cache-split-dedup', 'three-warm-cache-rereads', 'source-correction-invalidates-native-cache',
      'original-upstream-archive-high-water-mark-retained',
      'reverse-stream-order', 'proma-independent-user-homes', 'native-usage-history-parity',
      'retained-0.62-chart-data-compatibility', 'network-capabilities-off'],
    scope: 'actual signed bridge and pinned native fork; synthetic fixtures only' }));
} finally { fs.rmSync(base, { recursive: true, force: true }); }
