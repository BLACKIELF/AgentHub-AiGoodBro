'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const f = require('./helpers/fixtures.cjs');
const workspace = path.resolve(__dirname, '../..');

test('copied flat resource root uses its own Node, upstream and vendor; production ignores fixture and upstream overrides', () => {
  const temporary = f.makeHome();
  try {
    const root = path.join(temporary, 'Resources/TokenMonitorEngine');
    fs.mkdirSync(path.join(root, 'runtime'), { recursive: true });
    // Electron's executable needs its signed adjacent Frameworks; standalone Node is relocatable.
    const runtime = process.versions.electron ? process.execPath : path.join(root, 'runtime/node');
    if (!process.versions.electron) fs.copyFileSync(process.execPath, runtime);
    for (const file of ['bridge.cjs', 'lib', 'hooks', 'vendor', 'provenance.json']) {
      fs.cpSync(path.join(workspace, 'engine', file), path.join(root, file), { recursive: true });
    }
    fs.cpSync(path.join(workspace, 'upstream'), path.join(root, 'upstream'), { recursive: true });
    const trap = path.join(temporary, 'trap.cjs');
    fs.writeFileSync(trap, "throw new Error('illegal-fixture-loaded');");
    const env = { HOME: path.join(temporary, 'unapproved-do-not-read'), PATH: '',
      ...(process.versions.electron ? { ELECTRON_RUN_AS_NODE: '1' } : {}),
      TOKEN_MONITOR_UPSTREAM_ROOT: trap, TOKEN_MONITOR_ENGINE_ALLOW_FIXTURES: '1', TOKEN_MONITOR_ENGINE_FIXTURES: trap };
    for (const operation of ['capabilities', 'collectUsage', 'collectLimits']) {
      const request = f.baseRequest(temporary, { operation });
      const result = spawnSync(runtime, [path.join(root, 'bridge.cjs')], {
        cwd: root, env, encoding: 'utf8', input: JSON.stringify(request), timeout: 20000
      });
      assert.equal(result.status, 0, 'copied process exits successfully');
      const response = JSON.parse(result.stdout);
      assert.equal(response.engine.commit, '5d2db368d8313415763860d594de00e46a663418');
      assert.equal(response.requestId, request.requestId);
      assert.ok(!result.stdout.includes(workspace) && !result.stdout.includes(temporary));
      assert.ok(!result.stderr.includes('illegal-fixture-loaded'));
      if (operation !== 'capabilities') assert.deepEqual(response.coverage.days, []);
    }
    // Require resolution itself proves the closure is internal, with no source-layout preload.
    const inspect = spawnSync(runtime, ['-e', `
      const loader = require('./lib/upstream/loader.cjs');
      const u = loader.loadUsage(); loader.loadLimits();
      const binary = u.collector.resolvePlatformBinary();
      if (!binary.path.startsWith(process.cwd() + '/vendor/')) process.exit(2);
      for (const filename of Object.keys(require.cache)) if (!filename.startsWith(process.cwd() + '/')) process.exit(3);
      process.stdout.write('closure-ok');
    `], { cwd: root, env, encoding: 'utf8', timeout: 20000 });
    assert.equal(inspect.status, 0);
    assert.equal(inspect.stdout, 'closure-ok');
  } finally { f.cleanup(temporary); }
});
