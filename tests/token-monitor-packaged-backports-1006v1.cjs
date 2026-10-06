'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const childProcess = require('node:child_process');
const { spawnSync } = childProcess;
const realFork = childProcess.fork;
const children = [];
childProcess.fork = (...args) => {
  const child = realFork(...args);
  children.push({ child, modulePath: args[0], error: null });
  child.on('error', (error) => { children.find(entry => entry.child === child).error = error; });
  return child;
};

const asar = process.argv[2];
if (!asar || !asar.endsWith('/app.asar')) throw new Error('missing app.asar argument');
const exporter = require(`${asar}/src/shared/exporter.js`);
const detail = require(`${asar}/src/shared/sessionDetail.js`);
const watcher = require(`${asar}/src/shared/watcherHost.js`);
const workerPath = `${asar}/src/shared/watcherWorker.js`;
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'tm-packaged-backport-'));
const watchedA = path.join(root, 'watch-a');
const watchedB = path.join(root, 'watch-b');
const home = path.join(root, 'home');
fs.mkdirSync(watchedA, { recursive: true });
fs.mkdirSync(watchedB, { recursive: true });
fs.mkdirSync(path.join(home, '.codex', 'sessions', '2026', '10', '06'), { recursive: true });

function poisonedSession() {
  return { client: 'codex', sessionId: 'packaged', sessionKind: 'background-review', totalTokens: 20, costUsd: 2,
    title: 'private title', sessionTitle: 'private session title', session_title: 'private session title',
    name: 'private name', preview: 'private preview', firstUserMessage: 'private prompt', first_user_message: 'private prompt',
    customTitle: 'private custom title', custom_title: 'private custom title', aiTitle: 'private ai title', ai_title: 'private ai title' };
}
function waitFor(predicate, timeout = 10000) {
  const start = Date.now();
  return new Promise((resolve, reject) => {
    const tick = () => { if (predicate()) return resolve(); if (Date.now() - start > timeout) return reject(new Error('timeout')); setTimeout(tick, 25); };
    tick();
  });
}
function exitOf(child) {
  return new Promise((resolve) => { if (child.pid === undefined || child.exitCode !== null || child.signalCode !== null) return resolve(); child.once('exit', () => resolve()); });
}
async function main() {
  let owner;
  let replacement;
  const coordinator = watcher.createWatcherCoordinator();
  const failures = [];
  const watchdog = setTimeout(() => { for (const { child } of children) child.kill('SIGKILL'); process.exit(2); }, 100000);
  try {
    const periods = { today: { totalTokens: 20, costUsd: 2, clients: { codex: 20 }, clientCosts: { codex: 2 }, sessions: { 'codex:packaged': poisonedSession() } } };
    const exported = exporter.renderExportJson({ periods, history: {} });
    assert.doesNotMatch(exported, /private /);
    const parsed = JSON.parse(exported).snapshot.today.sessions['codex:packaged'];
    assert.equal(parsed.totalTokens, 20); assert.equal(parsed.costUsd, 2); assert.equal(parsed.sessionKind, 'background-review');

    const sessionId = 'rollout-2026-10-06T01-00-00-000000-000000000000';
    const sessionPath = path.join(home, '.codex', 'sessions', '2026', '10', '06', `${sessionId}.jsonl`);
    fs.writeFileSync(sessionPath, [
      JSON.stringify({ type: 'event_msg', timestamp: '2026-10-06T01:00:00Z', payload: { type: 'user_message', message: 'packaged prompt' } }),
      JSON.stringify({ type: 'event_msg', timestamp: '2026-10-06T01:00:01Z', payload: { type: 'token_count', info: { last_token_usage: { input_tokens: 10, cached_input_tokens: 3, output_tokens: 5, reasoning_output_tokens: 2 } } } })
    ].join('\n'));
    const detailResult = detail.readSessionDetail({ client: 'codex', sessionId, home, env: { CODEX_HOME: path.join(home, '.codex') }, sessionCost: 4 });
    assert.equal(detailResult.found, true); assert.equal(detailResult.totals.totalTokens, 15); assert.equal(detailResult.exchanges.length, 1);
    const missing = detail.readSessionDetail({ client: 'codex', sessionId: 'rollout-2026-10-06T01-00-00-000000-missing', home, env: { CODEX_HOME: path.join(home, '.codex') } });
    assert.equal(missing.found, false);

    let closes = 0;
    const errored = detail.readSessionDetail({ client: 'codex', sessionId, home, env: { CODEX_HOME: path.join(home, '.codex') }, deps: { fsModule: { ...fs,
      readSync() { throw Object.assign(new Error('synthetic EIO'), { code: 'EIO' }); },
      closeSync(fd) { closes++; return fs.closeSync(fd); }
    } } });
    assert.equal(errored.error, 'read-failed'); assert.equal(errored.found, false); assert.equal(errored.exchanges.length, 0); assert.equal(closes, 1);
    fs.writeFileSync(sessionPath, Buffer.alloc(17 * 1024 * 1024, 120));
    const oversized = detail.readSessionDetail({ client: 'codex', sessionId, home, env: { CODEX_HOME: path.join(home, '.codex') } });
    assert.equal(oversized.error, 'line-too-large'); assert.equal(oversized.found, false);

    for (let i = 0; i < 10050; i++) fs.writeFileSync(path.join(watchedA, `f-${i}.json`), 'x');
    let ready = 0;
    let events = 0;
    const handlers = { onReady: () => { ready++; }, onEvent: () => { events++; }, onError: error => failures.push(error.code || error.message), onHostFallback: error => failures.push(error.message) };
    owner = coordinator.acquire({ dirs: [watchedA], clients: 'claude', usePolling: false }, handlers);
    assert.equal(owner.kind, 'worker');
    await waitFor(() => ready > 0, 15000);
    assert.equal(children.length, 1, 'coordinator must launch a real child process');
    assert.equal(children[0].modulePath, workerPath, 'watcher must resolve inside the exact ASAR');
    assert.notEqual(children[0].child.pid, process.pid);
    assert.equal(coordinator.inspect().inProcess, false);
    fs.writeFileSync(path.join(watchedA, 'f-0.json'), 'changed');
    await waitFor(() => events > 0, 10000);
    const spawned = spawnSync(process.execPath, ['-e', 'process.stdout.write("owner-spawn-ok")'], { encoding: 'utf8', env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' } });
    assert.equal(spawned.status, 0); assert.equal(spawned.stdout, 'owner-spawn-ok');
    owner.close();
    replacement = coordinator.acquire({ dirs: [watchedB], clients: 'claude', usePolling: true }, handlers);
    await waitFor(() => ready >= 2, 15000);
    assert.equal(children.length, 2, 'config replacement gets a new isolated child');
    await waitFor(() => children[0].child.exitCode !== null || children[0].child.signalCode !== null);
    replacement.close(); owner.close();
    await waitFor(() => !coordinator.inspect().hasWorker && !coordinator.inspect().terminating, 15000);
    await waitFor(() => children.every(({ child }) => child.exitCode !== null || child.signalCode !== null));

    const child = childProcess.fork(workerPath, [], { execArgv: [], env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' }, stdio: ['ignore', 'ignore', 'ignore', 'ipc'] });
    let childReady = false;
    child.on('message', (m) => { if (m && m.type === 'ready') childReady = true; });
    child.send({ type: 'configure', revision: 1, config: { dirs: [watchedB], clients: 'claude', usePolling: true } });
    await waitFor(() => childReady, 15000);
    child.disconnect(); await waitFor(() => child.exitCode !== null || child.signalCode !== null, 10000); assert.equal(child.exitCode, 0);
    assert.deepEqual(failures, []);
    for (const entry of children) {
      assert.equal(entry.error, null);
      assert.throws(() => process.kill(entry.child.pid, 0), /ESRCH/, 'test watcher child remains alive');
    }
    process.stdout.write(JSON.stringify({ ok: true, electron: process.versions.electron, watchedFiles: 10050, childCount: children.length,
      checks: ['exporter', 'sessionDetail', 'session-read-errors', '10k-watcher-files', 'owner-spawn', 'config-replace-close', 'ipc-disconnect'],
      scope: 'ASAR production modules with synthetic inputs only; FD isolation inferred from a distinct live watcher PID plus successful owner spawn, not native GUI acceptance or a process-wide FD census' }) + '\n');
  } finally {
    replacement?.close(); owner?.close();
    for (const { child } of children) if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
    await Promise.all(children.map(({ child }) => exitOf(child)));
    childProcess.fork = realFork;
    clearTimeout(watchdog);
    fs.rmSync(root, { recursive: true, force: true });
  }
}
main().catch((error) => { console.error(JSON.stringify({ ok: false, error: error.message, stack: error.stack })); process.exitCode = 1; });
