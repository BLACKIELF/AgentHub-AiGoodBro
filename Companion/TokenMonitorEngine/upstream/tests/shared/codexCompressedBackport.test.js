// Selected v0.70 compressed-transcript regression scope, retaining the 0.68 metadata contract.
'use strict';
const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const zlib = require('node:zlib');
const { MAX_COMPRESSED_BYTES, MAX_DECODED_BYTES, readCompressedCodexTranscript } = require('../../src/shared/providers/codex/transcript');
const { resolveSessionFile, findCodexSessionFiles } = require('../../src/shared/sessionFiles');
const { readCodexSessionState } = require('../../src/shared/providers/codex/sessionContext');
const { resolveSessionMetadata } = require('../../src/shared/providers/codex/sessionMetadata');
const { applySessionMetadata } = require('../../src/shared/sessionMetadata');
const { readSessionDetail } = require('../../src/shared/sessionDetail');
const ID = 'rollout-2026-10-12T12-00-00-11111111-1111-4111-8111-111111111111';
const NOW = Date.parse('2026-10-12T12:00:04Z');
const line = (type, payload, timestamp = '2026-10-12T12:00:01Z') => JSON.stringify({ type, payload, timestamp });
const header = line('session_meta', { id: '11111111-1111-4111-8111-111111111111', cwd: '/fixture/synthetic-project' });
const usage = line('event_msg', { type: 'token_count', info: {
  last_token_usage: { input_tokens: 100, cached_input_tokens: 30, output_tokens: 40, reasoning_output_tokens: 15, total_tokens: 140 },
  total_token_usage: { input_tokens: 100, cached_input_tokens: 30, output_tokens: 40, reasoning_output_tokens: 15, total_tokens: 140 },
  model_context_window: 1000
} });
const transcript = [header, line('event_msg', { type: 'task_started' }), usage].join('\n') + '\n';
function fixture(t, root = 'sessions', id = ID) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'tm-backport-zst-'));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const codexHome = path.join(home, '.codex');
  const dir = path.join(codexHome, root, 'nested');
  fs.mkdirSync(dir, { recursive: true });
  const plain = path.join(dir, id + '.jsonl');
  const compressed = plain + '.zst';
  const write = bytes => {
    fs.writeFileSync(compressed, bytes || zlib.zstdCompressSync(Buffer.from(transcript)));
    fs.utimesSync(compressed, new Date(NOW - 1000), new Date(NOW - 1000));
  };
  write();
  return { home, codexHome, plain, compressed, write };
}
test('nested compressed live and archived metadata fallback reads the real missing-direct-path transcript', t => {
  for (const root of ['sessions', 'archived_sessions']) {
    const f = fixture(t, root);
    assert.equal(resolveSessionFile('codex', ID, f.home, { env: {} }), f.compressed);
    const periods = { today: { sessions: { ['codex:' + ID]: { client: 'codex', sessionId: ID, totalTokens: 140 } } } };
    applySessionMetadata(periods, f.home, { scopedHome: true, now: NOW,
      readCodexMeta: () => new Map(), readT3Meta: () => new Map() });
    const row = periods.today.sessions['codex:' + ID];
    assert.equal(row.totalTokens, 140);
    assert.equal(row.projectLabel, 'synthetic-project');
    assert.equal(row.lastUsedAt, '2026-10-12T12:00:01.000Z');
    assert.equal(row.contextTokens, 140);
    assert.equal(row.contextWindow, 1000);
    assert.equal(row.turnEnded, false);
    const read = () => readSessionDetail({ client: 'codex', sessionId: ID, home: f.home, env: {}, deps: { now: () => NOW } });
    const compressedDetail = read();
    assert.equal(compressedDetail.found, true);
    assert.equal(compressedDetail.totals.totalTokens, 140);
    fs.writeFileSync(f.plain, transcript);
    assert.deepEqual(read(), compressedDetail);
  }
});
test('legacy opaque compressed archive ids resolve metadata without an undefined plain-file fallback', t => {
  const f = fixture(t, 'archived_sessions', 'legacy-key');
  const seen = [];
  const result = resolveSessionMetadata(new Set(['legacy-key']), { home: f.home, metadata: new Map(), now: NOW,
    deps: { scopedHome: true, readCodexMeta: () => new Map(), readT3Meta: () => new Map() },
    fileSessionMetadata: (id, file, previous) => { seen.push([id, file]); return { ...previous, lastUsedAt: '2026-10-12T12:00:01Z' }; }
  });
  assert.deepEqual(seen, [['legacy-key', f.compressed]]);
  assert.equal(result.get('legacy-key').contextTokens, 140);
  assert.equal(result.get('legacy-key').contextWindow, 1000);
});
test('discovery prefers plain archive over compressed live copies and rejects unsafe ids/symlinks', t => {
  const f = fixture(t, 'archived_sessions', 'legacy-key');
  fs.writeFileSync(f.plain, transcript);
  const active = path.join(f.codexHome, 'sessions');
  fs.mkdirSync(active);
  fs.writeFileSync(path.join(active, 'legacy-key.jsonl.zst'), zlib.zstdCompressSync(Buffer.from(transcript)));
  assert.equal(findCodexSessionFiles(f.codexHome, ['legacy-key']).get('legacy-key'), f.plain);
  assert.equal(resolveSessionFile('codex', '../escape', f.home, { env: {} }), '');
  fs.symlinkSync(f.compressed, path.join(active, 'linked.jsonl.zst'));
  assert.equal(resolveSessionFile('codex', 'linked', f.home, { env: {} }), '');
});
test('concatenated compressed frames are complete and changed compressed state is rebuilt', t => {
  const f = fixture(t);
  const ended = line('event_msg', { type: 'task_complete' }, '2026-10-12T12:00:03Z');
  const bytes = Buffer.concat([transcript, ended].map(part => zlib.zstdCompressSync(Buffer.from(part))));
  f.write(bytes);
  assert.equal(readCompressedCodexTranscript(f.compressed).toString(), transcript + ended);
  const cache = new Map();
  const state = readCodexSessionState(f.compressed, { cache });
  assert.equal(state.turnEnded, true);
  assert.strictEqual(readCodexSessionState(f.compressed, { cache }), state);
  f.write();
  assert.equal(readCodexSessionState(f.compressed, { cache }).turnEnded, false);
});
test('torn corrupt oversized or excessive compressed frames never publish partial detail', t => {
  const f = fixture(t);
  const valid = zlib.zstdCompressSync(Buffer.from(transcript));
  const overBudget = zlib.zstdCompressSync(Buffer.alloc(MAX_DECODED_BYTES + 1, 0x61));
  const tiny = zlib.zstdCompressSync(Buffer.from('x'));
  const checked = zlib.zstdCompressSync(Buffer.from(transcript), { params: { [zlib.constants.ZSTD_c_checksumFlag]: 1 } });
  checked[checked.length - 1] ^= 0xff;
  for (const bytes of [Buffer.alloc(0), Buffer.from('invalid'), valid.subarray(0, valid.length - 1), Buffer.concat([valid, Buffer.from('tail')]), overBudget, checked, Buffer.concat(Array(4097).fill(tiny))]) {
    f.write(bytes);
    assert.throws(() => readCompressedCodexTranscript(f.compressed));
    assert.deepEqual(readCodexSessionState(f.compressed, { cache: new Map() }), {});
    const result = readSessionDetail({ client: 'codex', sessionId: ID, home: f.home, env: {} });
    assert.equal(result.found, false);
    assert.equal(result.error, 'read-failed');
    assert.equal(result.totals.totalTokens, 0);
  }
  fs.truncateSync(f.compressed, MAX_COMPRESSED_BYTES + 1);
  const reads = t.mock.method(fs, 'readSync');
  assert.throws(() => readCompressedCodexTranscript(f.compressed), /input budget/);
  assert.equal(reads.mock.callCount(), 0);
});
