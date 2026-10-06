'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const { createRequire } = require('node:module');
const { INPUT_SHA256, patchSessionDetail, patchSessionDetailResolver } = require('../Companion/TokenMonitorDesktop/backports/session-detail-1006v1.cjs');

const upstream = path.resolve(__dirname, '../Companion/TokenMonitorEngine/upstream');
const detailPath = path.join(upstream, 'src/shared/sessionDetail.js');
const detailSource = fs.readFileSync(detailPath, 'utf8');
const resolverPath = path.join(upstream, 'src/shared/sessionDetailResolver.js');
const resolverSource = fs.readFileSync(resolverPath, 'utf8');

function loadDetail(source = patchSessionDetail(detailSource), filePath) {
  const localRequire = createRequire(detailPath);
  const context = { module: { exports: {} }, Buffer, require(name) {
    if (name === './sessionFiles') return { resolveSessionFile: () => filePath };
    return localRequire(name);
  } };
  vm.runInNewContext(source, context, { filename: 'staged-sessionDetail.js' });
  return { api: context.module.exports, lines: context.readTranscriptLines };
}

function tempFile(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agb-session-stream-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return path.join(root, 'synthetic.jsonl');
}

function codexPrompt(text, timestamp = '2026-10-06T01:00:00Z') {
  return { type: 'event_msg', timestamp, payload: { type: 'user_message', message: text } };
}

function codexTurn(timestamp = '2026-10-06T01:00:01Z') {
  return { type: 'event_msg', timestamp, payload: { type: 'token_count', info: {
    last_token_usage: { input_tokens: 10, cached_input_tokens: 3, output_tokens: 5, reasoning_output_tokens: 2 }
  } } };
}

function trackedFs(overrides = {}) {
  let opened = 0, closed = 0;
  return { module: { ...fs, ...overrides,
    openSync(...args) { opened++; return fs.openSync(...args); },
    closeSync(...args) { closed++; return fs.closeSync(...args); }
  }, counts: () => ({ opened, closed }) };
}

test('hashes pin unchanged 0.62 sources and anchors reject drift or repeated application', () => {
  for (const [relative, expected] of Object.entries(INPUT_SHA256)) {
    assert.equal(crypto.createHash('sha256').update(fs.readFileSync(path.join(upstream, relative))).digest('hex'), expected);
  }
  assert.throws(() => patchSessionDetail(detailSource.replace('function parseClaudeTranscript(text)', 'function changed(text)')), /source anchor/);
  assert.throws(() => patchSessionDetail(patchSessionDetail(detailSource)), /source anchor/);
  assert.throws(() => patchSessionDetailResolver(patchSessionDetailResolver(resolverSource)), /source anchor/);
});

test('production parser APIs preserve complete ordered Codex rows, malformed skips and costs', (t) => {
  const file = tempFile(t);
  const records = [codexPrompt('first'), codexTurn(), codexPrompt('second'), codexTurn()];
  const text = records.slice(0, 2).map(JSON.stringify).join('\r\n') + '\r\n{broken}\r\nnull\r\n42\r\n'
    + records.slice(2).map(JSON.stringify).join('\r\n');
  fs.writeFileSync(file, text);
  const { api } = loadDetail(undefined, file);
  const detail = api.readSessionDetail({ client: 'codex', sessionId: 'synthetic', sessionCost: 6 });
  assert.equal(detail.found, true);
  assert.deepEqual(Array.from(detail.exchanges, ex => ex.promptPreview), ['first', 'second']);
  assert.equal(detail.totals.totalTokens, 30);
  assert.equal(detail.totals.turnCount, 2);
  assert.equal(detail.totals.costUsd, 6);
  assert.equal(detail.exchanges[0].costEstimate, 3);
  assert.equal(api.parseCodexTranscript(text).length, 4, 'public text parser stays synchronous');
  assert.equal(detail.error, undefined);
  assert.equal(detail.truncated, undefined, 'streaming is not a partial-tail feature');
});

test('Claude replay and split-block deduplication survive streaming, including malformed rows', (t) => {
  const file = tempFile(t);
  const prompt = { type: 'user', uuid: 'u', timestamp: '2026-10-06T01:00:00Z', message: { content: 'hello' } };
  const reply = { type: 'assistant', uuid: 'a', timestamp: '2026-10-06T01:00:01Z', message: {
    id: 'message-1', usage: { input_tokens: 2, output_tokens: 3, cache_read_input_tokens: 4 },
    content: [{ type: 'tool_use', name: 'one' }]
  } };
  const secondBlock = { ...reply, uuid: 'b', message: { ...reply.message, content: [{ type: 'tool_use', name: 'two' }] } };
  const text = [prompt, reply, reply, secondBlock].map(JSON.stringify).join('\n') + '\n{bad}\nnull';
  fs.writeFileSync(file, text);
  const { api } = loadDetail(undefined, file);
  const detail = api.readSessionDetail({ client: 'claude', sessionId: 'synthetic' });
  assert.equal(detail.totals.totalTokens, 9);
  assert.equal(detail.totals.turnCount, 1);
  assert.deepEqual(Array.from(detail.exchanges[0].tools), ['one', 'two']);
  assert.equal(api.parseClaudeTranscript(text).length, 2);
});

test('large meaningful transcripts retain every row in source order and preserve period/cost APIs', (t) => {
  const file = tempFile(t);
  const records = [];
  for (let i = 0; i < 6000; i++) {
    const timestamp = i % 2 === 0 ? '2026-10-06T01:00:00Z' : '2026-10-05T01:00:00Z';
    records.push(JSON.stringify(codexPrompt(`prompt-${i}`, timestamp)), JSON.stringify(codexTurn(timestamp)));
  }
  fs.writeFileSync(file, records.join('\n'));
  const { api } = loadDetail(undefined, file);
  const detail = api.readSessionDetail({ client: 'codex', sessionId: 'synthetic', sessionCost: 60 });
  assert.equal(detail.exchanges.length, 6000, 'no local tail cap changes session totals');
  assert.equal(detail.totals.totalTokens, 90000);
  assert.equal(detail.exchanges[0].promptPreview, 'prompt-0');
  assert.equal(detail.exchanges.at(-1).promptPreview, 'prompt-5999');
  const month = api.readSessionDetail({ client: 'codex', sessionId: 'synthetic', period: 'month', sessionCost: 60,
    deps: { now: () => Date.parse('2026-10-06T12:00:00Z') } });
  assert.equal(month.exchanges.length, 6000);
  assert.equal(month.totals.totalTokens, 90000);
  assert.equal(month.exchanges[0].costEstimate, 0.01);
});

test('64 KiB chunk boundaries preserve UTF-8, CRLF and unterminated final records', (t) => {
  const file = tempFile(t);
  const lines = ['x'.repeat(65535) + '中文', JSON.stringify(codexPrompt('末行'))];
  fs.writeFileSync(file, lines.join('\r\n'));
  const tracked = trackedFs();
  const { lines: readLines } = loadDetail(undefined, file);
  assert.deepEqual(Array.from(readLines(file, tracked.module)), [lines[0] + '\r', lines[1]]);
  assert.deepEqual(tracked.counts(), { opened: 1, closed: 1 });
});

test('oversized records and read failures discard partial results and close every descriptor', (t) => {
  const file = tempFile(t);
  const fd = fs.openSync(file, 'w');
  fs.writeSync(fd, JSON.stringify(codexPrompt('must disappear')) + '\n' + JSON.stringify(codexTurn()) + '\n');
  const chunk = Buffer.alloc(1024 * 1024, 120);
  for (let i = 0; i < 17; i++) fs.writeSync(fd, chunk);
  fs.closeSync(fd);
  const { api } = loadDetail(undefined, file);
  const tracked = trackedFs();
  const tooLarge = api.readSessionDetail({ client: 'codex', sessionId: 'synthetic', deps: { fsModule: tracked.module } });
  assert.equal(tooLarge.error, 'line-too-large');
  assert.equal(tooLarge.found, false);
  assert.equal(tooLarge.exchanges.length, 0);
  assert.equal(tooLarge.totals.totalTokens, 0);
  assert.deepEqual(tracked.counts(), { opened: 1, closed: 1 });
  let reads = 0;
  const failing = trackedFs({ readSync(...args) {
    if (++reads === 2) throw Object.assign(new Error('synthetic read error'), { code: 'EIO' });
    return fs.readSync(...args);
  } });
  const failed = api.readSessionDetail({ client: 'claude', sessionId: 'synthetic', deps: { fsModule: failing.module } });
  assert.equal(failed.error, 'read-failed');
  assert.equal(failed.exchanges.length, 0);
  assert.deepEqual(failing.counts(), { opened: 1, closed: 1 });
});

test('exact 16 MiB line is accepted; aborting iteration releases the descriptor', (t) => {
  const file = tempFile(t);
  fs.writeFileSync(file, Buffer.alloc(16 * 1024 * 1024, 32));
  const tracked = trackedFs();
  const { lines: readLines } = loadDetail(undefined, file);
  assert.equal(Array.from(readLines(file, tracked.module))[0].length, 16 * 1024 * 1024);
  fs.writeFileSync(file, 'one\ntwo\n');
  for (const line of readLines(file, tracked.module)) { assert.equal(line, 'one'); break; }
  assert.deepEqual(tracked.counts(), { opened: 2, closed: 2 });
});

test('ENOENT stays missing while actual errors stop native and WSL fallback searches', (t) => {
  const file = tempFile(t);
  const missing = loadDetail(undefined, file).api.readSessionDetail({ client: 'codex', sessionId: 'missing' });
  assert.equal(missing.found, false);
  assert.equal(missing.error, undefined);
  const context = { module: { exports: {} }, require: createRequire(resolverPath), process, setTimeout, clearTimeout };
  vm.runInNewContext(patchSessionDetailResolver(resolverSource), context);
  const resolve = context.module.exports.resolveSessionDetailForPlatform;
  let searches = 0, reads = 0;
  const native = resolve({ client: 'codex' }, {
    platform: 'win32', homedir: () => 'native',
    readSessionDetail: () => ({ found: false, error: 'line-too-large' }),
    wslUsageHomes: () => { searches++; return ['wsl']; }
  });
  assert.equal(native.error, 'line-too-large');
  assert.equal(searches, 0);
  const fallback = resolve({ client: 'claude' }, {
    platform: 'win32', homedir: () => 'native', wslUsageHomes: () => ['first', 'second'],
    readSessionDetail: () => (++reads === 1 ? { found: false } : { found: false, error: 'read-failed' })
  });
  assert.equal(fallback.error, 'read-failed');
  assert.equal(reads, 2);
});

test('synthetic transcript beyond V8 string length streams fully; unchanged vendor is the negative control', (t) => {
  const file = tempFile(t);
  const fd = fs.openSync(file, 'w');
  try {
    fs.writeSync(fd, JSON.stringify(codexPrompt('first')) + '\n' + JSON.stringify(codexTurn()) + '\n');
    fs.writeSync(fd, JSON.stringify({ type: 'user', timestamp: '2026-10-06T01:00:00Z', message: { content: 'first-Claude' } }) + '\n');
    fs.writeSync(fd, JSON.stringify({ type: 'assistant', timestamp: '2026-10-06T01:00:01Z', message: { usage: { input_tokens: 2, output_tokens: 3 } } }) + '\n');
    const noise = Buffer.from(JSON.stringify({ type: 'noise', padding: 'x'.repeat(1024 * 1024) }) + '\n');
    const copies = Math.ceil(require('node:buffer').constants.MAX_STRING_LENGTH / noise.length) + 1;
    for (let i = 0; i < copies; i++) fs.writeSync(fd, noise);
    fs.writeSync(fd, JSON.stringify(codexPrompt('last')) + '\n' + JSON.stringify(codexTurn()) + '\n');
    fs.writeSync(fd, JSON.stringify({ type: 'user', timestamp: '2026-10-06T02:00:00Z', message: { content: 'last-Claude' } }) + '\n');
    fs.writeSync(fd, JSON.stringify({ type: 'assistant', timestamp: '2026-10-06T02:00:01Z', message: { usage: { input_tokens: 2, output_tokens: 3 } } }));
  } finally { fs.closeSync(fd); }
  assert.ok(fs.statSync(file).size > require('node:buffer').constants.MAX_STRING_LENGTH);
  const old = loadDetail(detailSource, file).api.readSessionDetail({ client: 'codex', sessionId: 'synthetic' });
  assert.equal(old.found, false, 'unchanged vendor cannot decode a string beyond the V8 limit');
  const current = loadDetail(undefined, file).api.readSessionDetail({ client: 'codex', sessionId: 'synthetic', sessionCost: 4 });
  assert.equal(current.found, true);
  assert.deepEqual(Array.from(current.exchanges, ex => ex.promptPreview), ['first', 'last']);
  assert.equal(current.totals.totalTokens, 30);
  assert.equal(current.totals.costUsd, 4);
  const oldClaude = loadDetail(detailSource, file).api.readSessionDetail({ client: 'claude', sessionId: 'synthetic' });
  assert.equal(oldClaude.found, false);
  const currentClaude = loadDetail(undefined, file).api.readSessionDetail({ client: 'claude', sessionId: 'synthetic' });
  assert.equal(currentClaude.found, true);
  assert.deepEqual(Array.from(currentClaude.exchanges, ex => ex.promptPreview), ['first-Claude', 'last-Claude']);
  assert.equal(currentClaude.totals.totalTokens, 10);
});
