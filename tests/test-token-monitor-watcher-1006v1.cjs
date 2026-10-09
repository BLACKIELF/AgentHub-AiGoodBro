'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const { fork } = require('node:child_process');
const { INPUT_SHA256 } = require('../Companion/TokenMonitorDesktop/transform-stage.cjs');

const upstreamRoot = path.resolve(__dirname, '../Companion/TokenMonitorEngine/upstream');
const nodeModules = process.env.TOKEN_MONITOR_TEST_NODE_MODULES
  || path.resolve(__dirname, '../build/AiGoodBro.app/Contents/Resources/TokenMonitorEngine/vendor/node_modules');
const shared = path.join(upstreamRoot, 'src/shared');

function stageWatcher(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agb-watcher-1006-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.cpSync(shared, path.join(root, 'src/shared'), { recursive: true });
  fs.copyFileSync(path.join(upstreamRoot, 'package.json'), path.join(root, 'package.json'));
  assert.ok(fs.existsSync(path.join(nodeModules, 'chokidar/package.json')), 'existing frozen chokidar runtime is required');
  fs.symlinkSync(nodeModules, path.join(root, 'node_modules'), 'dir');
  return root;
}

function loadCoordinator(stage) {
  const hostPath = path.join(stage, 'src/shared', 'watcherHost.js');
  const localRequire = createRequire(hostPath);
  const children = [], lifecycle = [];
  const observedFork = (...args) => {
    const child = fork(...args);
    children.push(child);
    lifecycle.push({ type: 'spawn', pid: child.pid });
    child.on('message', message => lifecycle.push({ type: 'message', pid: child.pid, message }));
    child.once('exit', () => lifecycle.push({ type: 'exit', pid: child.pid }));
    return child;
  };
  const requireObserved = (name) => name === 'node:child_process' ? { fork: observedFork } : localRequire(name);
  requireObserved.resolve = localRequire.resolve;
  const context = { module: { exports: {} }, require: requireObserved, process, setTimeout, clearTimeout };
  vm.runInNewContext(fs.readFileSync(hostPath, 'utf8'), context, { filename: hostPath });
  const api = context.module.exports;
  return {
    api, children, lifecycle,
    async restore() {
      for (const child of children) {
        if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
      }
      assert.ok(await until(() => children.every(child => child.exitCode !== null || child.signalCode !== null)), 'test child did not exit');
    }
  };
}

function tree(t, label) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), `agb-watcher-${label}-`));
  fs.mkdirSync(path.join(root, 'nested'), { recursive: true });
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

const wait = (ms) => new Promise(resolve => setTimeout(resolve, ms));
async function until(predicate, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await wait(25);
  }
  return false;
}

test('merged process watchers remain exact frozen upstream without duplicate transforms', () => {
  const pins = JSON.parse(fs.readFileSync(path.join(upstreamRoot, '../SOURCE.json'))).finalSource.files;
  for (const relative of ['src/shared/watcherHost.js', 'src/shared/watcherWorker.js']) {
    const sourcePath = path.join(upstreamRoot, relative);
    assert.equal(crypto.createHash('sha256').update(fs.readFileSync(sourcePath)).digest('hex'), pins['upstream/' + relative]);
    assert.equal(Object.hasOwn(INPUT_SHA256, relative), false);
  }
});

test('staging hash failure rejects collector drift before writing any prepared outputs', (t) => {
  const { INPUT_SHA256: stageHashes, transformStage } = require('../Companion/TokenMonitorDesktop/transform-stage.cjs');
  const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'agb-watcher-hash-'));
  t.after(() => fs.rmSync(stage, { recursive: true, force: true }));
  for (const relative of Object.keys(stageHashes)) {
    const target = path.join(stage, relative);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.copyFileSync(path.join(upstreamRoot, relative), target);
  }
  const watcher = path.join(stage, 'src/shared/collector.js');
  fs.appendFileSync(watcher, '\n// synthetic source drift\n');
  const before = Object.fromEntries(Object.keys(stageHashes).map(relative => [relative, fs.readFileSync(path.join(stage, relative), 'utf8')]));
  assert.throws(() => transformStage(stage), /Pinned upstream hash changed: src\/shared\/collector.js/);
  for (const [relative, source] of Object.entries(before)) {
    assert.equal(fs.readFileSync(path.join(stage, relative), 'utf8'), source, `hash rejection partially wrote ${relative}`);
  }
});

test('real fork and IPC track existing sessions, then reconfigure latest owner after exit barrier', async (t) => {
  const stage = stageWatcher(t);
  const rootA = tree(t, 'a');
  const rootB = tree(t, 'b');
  const firstFile = path.join(rootA, 'nested', 'first.jsonl');
  const fresh = path.join(rootB, 'nested', 'fresh.jsonl');
  // Existing sessions receive appended records in production. Seed them before
  // ready so this lifecycle test does not depend on the OS's first add to an
  // empty directory. Other tests still exercise new-file discovery.
  fs.writeFileSync(firstFile, 'initial-a\n');
  fs.writeFileSync(fresh, 'initial-b\n');
  const loaded = loadCoordinator(stage);
  const seen = [];
  const changes = [];
  let ready = 0;
  let active;
  const coordinator = loaded.api.createWatcherCoordinator();
  const handlers = { onReady: () => { ready += 1; }, onEvent: (event, filePath) => {
    seen.push(filePath);
    if (event === 'change') changes.push(filePath);
  } };
  try {
    const first = coordinator.acquire({ dirs: [rootA], clients: 'claude', usePolling: false }, handlers);
    active = first;
    assert.equal(first.kind, 'worker');
    assert.ok(await until(() => ready >= 1), 'forked watcher did not report ready');
    assert.equal(loaded.children.length, 1);
    const retiring = loaded.children[0];
    assert.equal(seen.length, 0, 'initial session scan must not count as a live event');
    fs.appendFileSync(firstFile, 'first\n');
    assert.ok(await until(() => seen.includes(firstFile)), 'forked watcher did not deliver IPC event: '
      + JSON.stringify({ expected: firstFile, seen, state: coordinator.inspect(), lifecycle: loaded.lifecycle }));
    assert.ok(changes.includes(firstFile), 'existing session append did not deliver a change event');

    first.close();
    ready = 0;
    seen.length = 0;
    changes.length = 0;
    const second = coordinator.acquire({ dirs: [rootB], clients: 'claude', usePolling: false }, handlers);
    active = second;
    assert.equal(coordinator.inspect().terminating, true, 'replacement must wait for old process exit');
    assert.ok(await until(() => ready >= 1 && coordinator.inspect().terminating === false), 'replacement never became ready');
    assert.equal(loaded.children.length, 2);
    assert.notEqual(loaded.children[1].pid, retiring.pid);
    assert.ok(loaded.lifecycle.findIndex(event => event.type === 'exit' && event.pid === retiring.pid)
      < loaded.lifecycle.findIndex(event => event.type === 'spawn' && event.pid === loaded.children[1].pid), 'replacement spawned before old process confirmed exit');
    assert.equal(seen.length, 0, 'replacement initial scan must not count as a live event');
    fs.appendFileSync(fresh, 'fresh\n');
    assert.ok(await until(() => seen.includes(fresh)), 'latest root was not watched');
    assert.ok(changes.includes(fresh), 'latest session append did not deliver a change event');
    const stale = path.join(rootA, 'nested', 'stale.jsonl');
    fs.writeFileSync(stale, 'stale');
    await wait(500);
    assert.equal(seen.includes(stale), false, 'old process/root still delivered after reconfigure');
    second.close({ skipClose: true });
    assert.ok(await until(() => loaded.children.every(child => child.signalCode !== null || child.exitCode !== null)), 'quit did not terminate child process');
  } finally {
    active?.close();
    await loaded.restore();
  }
});

test('rapid owner changes are latest-wins and leave no residual watcher after quit', async (t) => {
  const stage = stageWatcher(t);
  const roots = [tree(t, 'one'), tree(t, 'two'), tree(t, 'three')];
  const loaded = loadCoordinator(stage);
  const coordinator = loaded.api.createWatcherCoordinator();
  let ready = 0;
  const seen = [];
  let active;
  try {
    const a = coordinator.acquire({ dirs: [roots[0]], clients: 'claude', usePolling: false }, { onReady: () => { ready += 1; } });
    active = a;
    a.close();
    const b = coordinator.acquire({ dirs: [roots[1]], clients: 'claude', usePolling: false }, { onReady: () => { ready += 1; } });
    active = b;
    b.close();
    const c = coordinator.acquire({ dirs: [roots[2]], clients: 'claude', usePolling: false }, {
      onReady: () => { ready += 1; }, onEvent: (_event, filePath) => seen.push(filePath)
    });
    active = c;
    assert.ok(await until(() => ready >= 1 && coordinator.inspect().terminating === false), 'latest owner did not become ready');
    assert.equal(coordinator.inspect().hasWorker, true);
    const latestFile = path.join(roots[2], 'nested/latest.jsonl');
    fs.writeFileSync(latestFile, 'latest');
    assert.ok(await until(() => seen.includes(latestFile)), 'latest owner roots did not deliver');
    for (const staleRoot of roots.slice(0, 2)) fs.writeFileSync(path.join(staleRoot, 'nested/stale.jsonl'), 'stale');
    await wait(200);
    assert.equal(seen.some(file => file.endsWith('stale.jsonl')), false);
    c.close({ skipClose: true });
    assert.ok(await until(() => loaded.children.every(child => child.signalCode !== null || child.exitCode !== null)), 'quit left a watcher process');
    await wait(150);
    assert.equal(coordinator.inspect().inProcess, false);
  } finally {
    active?.close();
    await loaded.restore();
  }
});

test('a broken worker module emits an observable fallback and does not leave the failed child active', async (t) => {
  const stage = stageWatcher(t);
  const root = tree(t, 'fallback');
  const loaded = loadCoordinator(stage);
  const fallbacks = [];
  const errors = [];
  const seen = [];
  let ready = false;
  let host;
  try {
    const coordinator = loaded.api.createWatcherCoordinator({ workerPath: path.join(stage, 'src/shared', 'missing-watcher-worker.js') });
    host = coordinator.acquire({ dirs: [root], clients: 'claude', usePolling: false }, {
      onHostFallback: error => fallbacks.push(error),
      onError: error => errors.push(error),
      onReady: () => { ready = true; },
      onEvent: (_event, filePath) => seen.push(filePath)
    });
    assert.equal(host.kind, 'worker');
    assert.ok(await until(() => coordinator.inspect().inProcess), 'worker failure did not activate fallback');
    assert.equal(fallbacks.length, 1);
    assert.equal(coordinator.inspect().workerDisabled, true);
    assert.ok(await until(() => ready), 'fallback watcher did not become ready');
    const file = path.join(root, 'nested/fallback.jsonl');
    fs.writeFileSync(file, 'synthetic');
    assert.ok(await until(() => seen.includes(file)), 'observable fallback did not actually watch files');
    host.close();
    assert.equal(coordinator.inspect().inProcess, false);
    assert.equal(errors.length, 0, 'module-load fallback should not report a watcher runtime event');
  } finally {
    host?.close();
    await loaded.restore();
  }
});

test('real watcher child exits on IPC disconnect without residual processes', async (t) => {
  const stage = stageWatcher(t);
  const root = tree(t, 'disconnect');
  const workerPath = path.join(stage, 'src/shared/watcherWorker.js');
  const child = fork(workerPath, [], { execArgv: [], stdio: ['ignore', 'ignore', 'ignore', 'ipc'] });
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
    assert.ok(await until(() => child.exitCode !== null || child.signalCode !== null));
  });
  let ready = false;
  child.on('message', message => { if (message.type === 'ready') ready = true; });
  child.send({ type: 'configure', revision: 1, config: { dirs: [root], clients: 'claude', usePolling: false } });
  assert.ok(await until(() => ready), 'real child did not become ready');
  child.disconnect();
  assert.ok(await until(() => child.exitCode !== null), 'disconnect left real watcher child alive');
  assert.equal(child.exitCode, 0);
  assert.throws(() => process.kill(child.pid, 0), /ESRCH/);
});

test('watcher process cannot survive a killed owner process', async (t) => {
  const stage = stageWatcher(t);
  const root = tree(t, 'owner-exit');
  const ownerPath = path.join(stage, 'synthetic-owner.cjs');
  fs.writeFileSync(ownerPath, `const { fork } = require('node:child_process');
const child = fork(require.resolve('./src/shared/watcherWorker.js'), [], {
  execArgv: [], stdio: ['ignore', 'ignore', 'ignore', 'ipc']
});
child.on('message', message => {
  if (message.type === 'ready') process.send({ watcherPid: child.pid });
});
process.on('message', config => child.send({ type: 'configure', revision: 1, config }));
`);
  const owner = fork(ownerPath, [], { execArgv: [], stdio: ['ignore', 'ignore', 'ignore', 'ipc'] });
  let watcherPid;
  t.after(async () => {
    if (owner.exitCode === null && owner.signalCode === null) owner.kill('SIGKILL');
    if (watcherPid) { try { process.kill(watcherPid, 'SIGKILL'); } catch (_) {} }
    assert.ok(await until(() => owner.exitCode !== null || owner.signalCode !== null));
  });
  owner.on('message', message => { watcherPid = message.watcherPid; });
  owner.send({ dirs: [root], clients: 'claude', usePolling: false });
  assert.ok(await until(() => Number.isInteger(watcherPid)), 'owner never reported watcher readiness');
  process.kill(watcherPid, 0);
  owner.kill('SIGKILL');
  assert.ok(await until(() => {
    try { process.kill(watcherPid, 0); return false; } catch (error) { return error.code === 'ESRCH'; }
  }), 'watcher survived its killed owner');
});
