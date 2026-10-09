'use strict';
// Execute inside the final signed helper ASAR as Node, with synthetic HOME only.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const childProcess = require('node:child_process');
const root = path.resolve(process.argv[2] || '');
assert.ok(fs.existsSync(path.join(root, 'src/shared/collector.js')), 'supply final ASAR or staging root');
const home = fs.mkdtempSync(path.join(os.tmpdir(), 'tm-embedded-policy-'));
process.env.HOME = home;
process.env.CODEX_HOME = path.join(home, '.codex');
process.env.TOKEN_MONITOR_SHARED_DIR = path.join(home, 'shared');
process.env.AIGOODBRO_TOKEN_MONITOR_EMBEDDED = '1';
process.env.TOKEN_MONITOR_CODEX_LOCAL_USAGE = '1';
let forbidden = 0;
const forbiddenCalls = [];
const deny = () => { forbidden++; forbiddenCalls.push('privileged-hook'); throw new Error('closed embedded capability invoked'); };
globalThis.fetch = deny;
for (const name of ['spawn', 'spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync']) childProcess[name] = (...args) => {
  forbiddenCalls.push([name, String(args[0])]);
  return deny();
};
const sourceModule = require(path.join(root, 'src/shared/providers/codex/localUsageSource.js'));
const localUsage = require(path.join(root, 'src/shared/providers/codex/localUsage.js'));
sourceModule.createLocalUsageSource = deny;
localUsage.readLocalUsageView = deny;
const collector = require(path.join(root, 'src/shared/collector.js'));
collector.selfSyncThrottle.claim = deny;
const dependencies = { selfSyncThrottle: new Proxy({}, { get: () => deny }), tokscaleCommand: deny };
const cursor = require(path.join(root, 'src/shared/providers/cursor/selfSync.js')).createCursorSelfSync(dependencies);
const antigravity = require(path.join(root, 'src/shared/providers/antigravity/selfSync.js')).createAntigravitySelfSync(dependencies);

async function main() {
  let runtime;
  let scans = 0;
  const summaries = [];
  const options = {
    clients: 'codex,cursor,antigravity', homeDir: home, env: { ...process.env },
    codexDotsEnabled: true, codexDotsVisible: true, codexLocalUsageEnabled: true,
    allTimeSince: '2025-01-01', deviceId: 'embedded-policy-fixture',
    osInfo: null,
    projectsEnabled: false, historyEnabled: false, watchEnabled: false,
    anchorPersistenceEnabled: false, sessionUsageArchiveEnabled: false,
    intervalMs: 60000, forceSelfSync: true,
    runTokscale: async () => { scans++; return { entries: [] }; },
    runGraph: async () => ({ contributions: [] }), lookupModelPricing: async () => ({}),
    onUpdate: (summary) => summaries.push(summary)
  };
  try {
    await cursor.maybeSyncCursor('cursor', deny, { force: true });
    await antigravity.maybeSyncAntigravity('antigravity', deny, home, { run: deny, force: true });
    const once = await collector.collectUsageOnce(options);
    assert.equal(once.today.totalTokens, 0);
    assert.equal(once.allTime.totalTokens, 0);
    runtime = collector.startCollector(options);
    await runtime.whenIdle();
    await runtime.tick('manual', { forceSelfSync: true });
    await runtime.setCodexDotsVisible(true);
    assert.ok(scans > 0, 'ordinary collection continues while privileged capabilities are closed');
    assert.ok(summaries.length > 0);
    assert.ok(summaries.every((summary) => summary.today.totalTokens === 0));
    assert.equal(forbidden, 0, 'no source, cache view, throttle, credential/network/spawn entry point was reached: ' + JSON.stringify(forbiddenCalls));
    console.log(JSON.stringify({ ok: true, electron: process.versions.electron || null,
      checks: ['hostile-inherited-dots-opt-in', 'explicit-dots-runtime-options', 'live-and-one-shot-collection',
        'visibility-toggle', 'forced-manual-self-sync', 'cursor-and-antigravity-factory-gates',
        'ordinary-collection-retained', 'zero-observer-credential-network-spawn-calls'],
      scope: 'production staged modules; synthetic empty sources only' }));
  } finally {
    runtime?.stop();
    await runtime?.whenIdle();
    fs.rmSync(home, { recursive: true, force: true });
  }
}
main().catch((error) => { console.error(JSON.stringify({ ok: false, error: error.message, stack: error.stack })); process.exitCode = 1; });
