// Synthetic visual tests only. Never record error text, URLs, IPC bodies,
// environment variables or process command lines. Hashes correlate redacted errors.
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import { createHash } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { test } from '@playwright/test';

export function errorIdentity(error) {
  const message = String(error?.message ?? error ?? '');
  const name = ['Error', 'TypeError', 'RangeError', 'ReferenceError', 'SyntaxError', 'TimeoutError'].includes(error?.name)
    ? error.name : 'Error';
  return {
    name,
    networkCode: message.match(/\bnet::(ERR_[A-Z0-9_]{1,64})\b/)?.[1] ?? null,
    messageSHA256: createHash('sha256').update(message).digest('hex'),
  };
}

export function collectTaskResources(capturePhase = 'test-end-after-fixture-teardown') {
  const result = { at: new Date().toISOString(), platform: process.platform,
    capturePhase, runnerPid: process.pid,
    nodeMemory: process.memoryUsage(), nodeResourceUsage: process.resourceUsage(),
    hostMemory: { freeBytes: os.freemem(), totalBytes: os.totalmem() } };
  if (process.platform !== 'win32') return { ...result, processAggregation: 'windows-only' };
  try {
    // One bounded query per failed case, never a background sampler. The script
    // emits descendants of this exact runner only, with no paths or argv.
    const output = execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-File',
      fileURLToPath(new URL('./task-resources.ps1', import.meta.url)), '-RootProcessId', String(process.pid)],
    { encoding: 'utf8', timeout: 5000, maxBuffer: 64 * 1024, windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'] });
    return { ...result, task: JSON.parse(output) };
  } catch { return { ...result, processAggregation: 'unavailable-or-deadline' }; }
}

const pages = new WeakSet();
const states = new WeakMap();
export function installFailureDiagnostics(page) {
  // Pure bridge-order unit tests supply only addInitScript; they have no browser.
  if (typeof page.on !== 'function' || pages.has(page)) return;
  const info = test.info();
  pages.add(page);
  let state = states.get(info);
  if (!state) {
    state = { schemaVersion: 1, syntheticOnly: true, workerPid: process.pid, events: [], dropped: 0 };
    states.set(info, state);
  }
  const record = (kind, error) => {
    const browser = page.context().browser();
    const contexts = browser?.contexts() ?? [];
    const row = { kind, at: new Date().toISOString(), error: errorIdentity(error),
      contexts: contexts.length, pages: contexts.reduce((n, c) => n + c.pages().length, 0),
      nodeMemory: process.memoryUsage() };
    if (!state.failureResources && (kind === 'page-crash' || row.error.networkCode === 'ERR_NO_BUFFER_SPACE')) {
      state.failureResources = collectTaskResources('immediate-browser-resource-error');
    }
    if (state.events.length < 32) state.events.push(row);
    else state.dropped++;
    try {
      mkdirSync(info.outputDir, { recursive: true });
      writeFileSync(path.join(info.outputDir, 'page-errors.redacted.json'), JSON.stringify(state, null, 2));
    } catch { /* Evidence failures must not replace the original test failure. */ }
  };
  page.on('pageerror', error => record('pageerror', error));
  page.on('crash', () => record('page-crash', 'page-crash'));
  page.on('requestfailed', request => record('requestfailed', request.failure()?.errorText));
}
