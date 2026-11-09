'use strict';

// Child-process registry.
//
// "Kill descendant processes on cancel" cannot be honoured by killing the
// bridge alone: a tokscale scan is a separate process, and a provider CLI
// fallback may be a grandchild. The bridge therefore records every process it
// spawns and terminates them when the request is cancelled or times out.
//
// The patch must be installed before any upstream module is loaded, because
// upstream modules destructure `spawn` at load time (shared/collector.js,
// shared/limits/providerHelpers.js) and would otherwise capture the original.
// loader.prepare() installs it first for exactly that reason.

const childProcess = require('node:child_process');

let originalSpawn = null;
const tracked = new Set();

function install() {
  if (originalSpawn) return false;
  originalSpawn = childProcess.spawn;
  childProcess.spawn = function spawn(...args) {
    const child = originalSpawn.apply(this, args);
    if (child && typeof child.kill === 'function') {
      tracked.add(child);
      const forget = () => tracked.delete(child);
      child.once('exit', forget);
      child.once('error', () => { if (!child.pid) forget(); });
    }
    return child;
  };
  return true;
}

function isInstalled() {
  return originalSpawn !== null;
}

function trackCount() {
  return tracked.size;
}

// Confirm exit before the bridge exits; merely scheduling SIGKILL lets
// process.exit() discard the timer and orphan a child that ignores SIGTERM.
// The second deadline bounds an unconfirmed kernel/process failure.
function killAll(escalateMs = 250, confirmMs = 500) {
  const victims = [...tracked];
  if (victims.length === 0) return Promise.resolve(true);
  return new Promise(resolve => {
    const pending = new Set(victims);
    const listeners = new Map();
    let escalation;
    let deadline;
    let settled = false;
    const finish = confirmed => {
      if (settled) return;
      settled = true;
      clearTimeout(escalation);
      clearTimeout(deadline);
      for (const [child, listener] of listeners) {
        child.removeListener('exit', listener);
        child.removeListener('error', listener);
      }
      resolve(confirmed);
    };
    for (const child of victims) {
      const observe = () => {
        if (child.exitCode != null || child.signalCode != null || !child.pid) {
          pending.delete(child);
          if (pending.size === 0) finish(true);
        }
      };
      listeners.set(child, observe);
      child.once('exit', observe);
      child.on('error', observe);
      observe();
    }
    if (settled) return;
    escalation = setTimeout(() => {
      for (const child of pending) {
        try { child.kill('SIGKILL'); } catch (_) { /* await exit or the deadline */ }
      }
    }, escalateMs);
    deadline = setTimeout(() => finish(false), escalateMs + confirmMs);
    for (const child of pending) {
      try { child.kill('SIGTERM'); } catch (_) { /* still require exit confirmation */ }
    }
  });
}

module.exports = { install, isInstalled, trackCount, killAll };
