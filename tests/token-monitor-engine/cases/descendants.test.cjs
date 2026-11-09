'use strict';
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const test = require('node:test');
const cp = require('node:child_process');
let nextChild;
// A process collaborator only: never signal a real PID in these boundary cases.
cp.spawn = () => nextChild;
const descendants = require('../lib/runtime/descendants.cjs');
descendants.install();

function child(behavior) {
  const value = new EventEmitter();
  value.pid = 12345;
  value.exitCode = null;
  value.signalCode = null;
  value.signals = [];
  value.kill = signal => { value.signals.push(signal); behavior(value, signal); return true; };
  nextChild = value;
  return cp.spawn();
}

test('a termination error is not evidence that a spawned child exited', async () => {
  const value = child(current => current.emit('error', new Error('synthetic signal failure')));
  try {
    assert.equal(await descendants.killAll(5, 10), false);
    assert.deepEqual(value.signals, ['SIGTERM', 'SIGKILL']);
    assert.equal(descendants.trackCount(), 1);
    assert.equal(value.listenerCount('exit'), 1, 'only the registry listener remains');
  } finally {
    value.exitCode = 0;
    value.emit('exit', 0);
  }
  assert.equal(descendants.trackCount(), 0);
});

test('exit confirmation cancels escalation and releases termination listeners', async () => {
  const value = child((current, signal) => {
    process.nextTick(() => { current.signalCode = signal; current.emit('exit', null, signal); });
  });
  assert.equal(await descendants.killAll(5, 10), true);
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.deepEqual(value.signals, ['SIGTERM']);
  assert.equal(value.listenerCount('exit'), 0);
  assert.equal(descendants.trackCount(), 0);
  assert.equal(await descendants.killAll(), true);
});

test('repeated cancellation retains the first reason and cleanup promise', async () => {
  const { createRequestScope } = require('../lib/runtime/scope.cjs');
  const value = child((current, signal) => {
    process.nextTick(() => { current.signalCode = signal; current.emit('exit', null, signal); });
  });
  const scope = createRequestScope({ timeoutMs: 2000 }).start();
  try {
    scope.cancel();
    const firstCleanup = scope.waitForCleanup();
    const firstReason = scope.signal.reason;
    scope.cancel();
    scope.abort(new Error('late synthetic reason'));
    assert.equal(scope.waitForCleanup(), firstCleanup);
    assert.equal(scope.signal.reason, firstReason);
    assert.equal(firstReason.code, 'cancelled');
    assert.equal(await firstCleanup, true);
    assert.deepEqual(value.signals, ['SIGTERM']);
  } finally { scope.dispose(); }
});
