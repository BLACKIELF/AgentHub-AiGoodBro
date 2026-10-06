'use strict';

// PR 930's bounded JSONL reader, adapted to the pinned 0.62 synchronous API.
// Apply only to disposable staging sources; the vendor inventory stays immutable.
// PR 932's asynchronous compressed DSH pipeline is intentionally not transplanted.
const INPUT_SHA256 = Object.freeze({
  'src/shared/sessionDetail.js': '8cf7ac6a52ef9fe8a822b4621bfb00294040ce018072371c632c6ebada8882b9',
  'src/shared/sessionDetailResolver.js': '32f23b73b71665c8e307fb699df458893a2d234f8d1c22bfe461459c46cd1b72'
});

function replaceOne(source, anchor, replacement, label) {
  const at = source.indexOf(anchor);
  if (at < 0 || source.indexOf(anchor, at + anchor.length) >= 0) {
    throw new Error(`${label}: expected exactly one source anchor`);
  }
  return source.slice(0, at) + replacement + source.slice(at + anchor.length);
}

function* readTranscriptLines(filePath, fsModule = fs) {
  const fd = fsModule.openSync(filePath, 'r');
  let parts = [];
  let lineBytes = 0;
  try {
    for (;;) {
      const buffer = Buffer.allocUnsafe(64 * 1024);
      const bytesRead = fsModule.readSync(fd, buffer, 0, buffer.length, null);
      if (bytesRead === 0) break;
      const chunk = buffer.subarray(0, bytesRead);
      let start = 0;
      while (start < chunk.length) {
        const newline = chunk.indexOf(10, start);
        const end = newline === -1 ? chunk.length : newline;
        lineBytes += end - start;
        if (lineBytes > 16 * 1024 * 1024) {
          throw Object.assign(new Error('Session detail record exceeds 16 MiB'), { code: 'SESSION_DETAIL_LINE_TOO_LARGE' });
        }
        parts.push(chunk.subarray(start, end));
        if (newline === -1) break;
        yield Buffer.concat(parts, lineBytes).toString('utf8');
        parts = [];
        lineBytes = 0;
        start = newline + 1;
      }
    }
    if (lineBytes) yield Buffer.concat(parts, lineBytes).toString('utf8');
  } finally {
    fsModule.closeSync(fd);
  }
}

function patchSessionDetail(source) {
  let text = replaceOne(source,
    "const fs = require('node:fs');\n",
    "const fs = require('node:fs');\n\n" + readTranscriptLines.toString() + '\n',
    'session detail streaming reader');
  for (const client of ['Claude', 'Codex']) {
    text = replaceOne(text,
      `function parse${client}Transcript(text) {`,
      `function parse${client}Transcript(text) {\n  return parse${client}TranscriptLines(String(text || '').split(/\\r?\\n/));\n}\n\nfunction parse${client}TranscriptLines(lines) {`,
      `${client} iterable parser`);
    // Restrict the identical loop replacement to its own parser body.
    const start = text.indexOf(`function parse${client}TranscriptLines(lines) {`);
    const end = text.indexOf('\nfunction ', start + 1);
    let body = text.slice(start, end);
    body = replaceOne(body, "for (const line of String(text || '').split(/\\r?\\n/)) {",
      'for (const line of lines) {', `${client} streaming lines`);
    body = replaceOne(body,
      '    try { obj = JSON.parse(trimmed); } catch (_) { continue; }',
      '    try { obj = JSON.parse(trimmed); } catch (_) { continue; }\n    if (!obj || typeof obj !== \'object\') continue;',
      `${client} malformed record guard`);
    text = text.slice(0, start) + body + text.slice(end);
  }
  text = replaceOne(text,
    "  let text;\n  try { text = fs.readFileSync(filePath, 'utf8'); } catch (_) {\n    return { found: false, client, sessionId, period, exchanges: [], totals: totalsOf([], sessionCost) };\n  }\n  const events = parseByClient(client, text);",
    `  let events;
  try {
    const lines = readTranscriptLines(filePath, deps.fsModule || fs);
    events = client === 'codex' ? parseCodexTranscriptLines(lines) : parseClaudeTranscriptLines(lines);
  } catch (error) {
    const missing = { found: false, client, sessionId, period, exchanges: [], totals: totalsOf([], sessionCost) };
    if (error.code === 'ENOENT') return missing;
    return { ...missing, error: error.code === 'SESSION_DETAIL_LINE_TOO_LARGE' ? 'line-too-large' : 'read-failed' };
  }`,
    'session detail fail closed streaming read');
  return text;
}

function patchSessionDetailResolver(source) {
  let text = replaceOne(source,
    "  if (nativeDetail.found || platform !== 'win32' || !WSL_FALLBACK_CLIENTS.has(args.client)) {",
    "  if (nativeDetail.found || nativeDetail.error || platform !== 'win32' || !WSL_FALLBACK_CLIENTS.has(args.client)) {",
    'native detail read error stops fallback');
  text = replaceOne(text,
    '    if (detail.found) return detail;',
    '    if (detail.found || detail.error) return detail;',
    'fallback detail read error stops search');
  return text;
}

module.exports = { INPUT_SHA256, patchSessionDetail, patchSessionDetailResolver };
