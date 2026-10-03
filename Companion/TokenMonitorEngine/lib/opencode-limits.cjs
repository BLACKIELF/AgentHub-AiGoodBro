'use strict';
// API-only adapter to Javis603/token-monitor ef079b6 (MIT; upstream/LICENSE).
// Credentials and their digests remain local to this invocation, never in DTOs.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const MAX_BYTES = 1_048_576;
const URL = 'https://opencode.ai/zen/go/v1/usage';
const provenance = 'token-monitor v0.62 OpenCode Go';
const fail = code => Object.assign(new Error(code), { code });
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);

// JSON.parse alone silently accepts duplicate credential/window keys. Walk the
// already syntax-checked tokens to reject ambiguous objects at every depth.
function strictJSON(text) {
  const value = JSON.parse(text);
  const tokens = text.match(/"(?:[^"\\]|\\.)*"|true|false|null|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|[{}\[\]:,]/gs) || [];
  let i = 0;
  function walk(depth) {
    if (depth > 32) throw fail('malformed_bundle');
    const token = tokens[i++];
    if (token === '{') {
      const keys = new Set();
      while (tokens[i] !== '}') {
        const key = JSON.parse(tokens[i++]);
        if (keys.has(key)) throw fail('ambiguous_json');
        keys.add(key); i++; walk(depth + 1);
        if (tokens[i] !== ',') break;
        i++;
      }
      i++;
    } else if (token === '[') {
      while (tokens[i] !== ']') {
        walk(depth + 1);
        if (tokens[i] !== ',') break;
        i++;
      }
      i++;
    }
  }
  walk(0);
  return value;
}
const generation = stat => ['dev', 'ino', 'size', 'mtimeNs', 'ctimeNs'].map(k => String(stat[k])).join(':');
function readSnapshot(target) {
  try {
    if (fs.realpathSync(target.declaredRoot || target.root) !== target.root) throw fail('target_changed');
    const directory = fs.statSync(target.root, { bigint: true });
    if (!directory.isDirectory()) throw fail('invalid_auth_file');
    const file = path.join(target.root, 'auth.json');
    const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    try {
      const before = fs.fstatSync(fd, { bigint: true });
      if (!before.isFile() || before.size > BigInt(MAX_BYTES)) throw fail('invalid_auth_file');
      const bytes = Buffer.alloc(MAX_BYTES + 1);
      let count = 0, n;
      while ((n = fs.readSync(fd, bytes, count, bytes.length - count, null)) > 0) count += n;
      if (count > MAX_BYTES || generation(before) !== generation(fs.fstatSync(fd, { bigint: true })) ||
          generation(before) !== generation(fs.lstatSync(file, { bigint: true }))) throw fail('auth_changed');
      if (fs.realpathSync(target.declaredRoot || target.root) !== target.root ||
          fs.realpathSync(file) !== file || generation(directory) !== generation(fs.statSync(target.root, { bigint: true }))) throw fail('target_changed');
      const data = bytes.subarray(0, count);
      const document = strictJSON(new TextDecoder('utf-8', { fatal: true }).decode(data));
      if (!object(document)) throw fail('malformed_bundle');
      if (!Object.hasOwn(document, 'opencode-go')) throw fail('provider_missing');
      const entry = document['opencode-go'];
      if (!object(entry) || entry.type !== 'api' || typeof entry.key !== 'string' ||
          !entry.key || entry.key.length > 16384 || /^(['"]).*\1$/.test(entry.key) || /[^\x21-\x7e]/.test(entry.key)) throw fail('malformed_bundle');
      return { key: entry.key, fingerprint: generation(directory) + ':' + generation(before) + ':' +
        crypto.createHash('sha256').update(data).digest('hex') };
    } finally { fs.closeSync(fd); }
  } catch (error) {
    if (['target_changed', 'auth_changed', 'provider_missing', 'malformed_bundle', 'ambiguous_json', 'invalid_auth_file'].includes(error.code)) throw error;
    throw fail(error.code === 'ENOENT' ? 'auth_missing' : error.code === 'ELOOP' ? 'invalid_auth_file' : 'malformed_bundle');
  }
}
function validateUsage(payload) {
  if (!object(payload) || !object(payload.usage)) throw fail('invalid_response');
  for (const key of ['rolling', 'weekly', 'monthly']) {
    if (!Object.hasOwn(payload.usage, key)) continue;
    const window = payload.usage[key];
    if (!object(window)) throw fail('invalid_response');
    if (Object.hasOwn(window, 'percent') && (typeof window.percent !== 'number' ||
        !Number.isFinite(window.percent) || window.percent < 0 || window.percent > 100)) throw fail('invalid_response');
    if (Object.hasOwn(window, 'status') && typeof window.status !== 'string') throw fail('invalid_response');
    if (Object.hasOwn(window, 'resetsAt') && (typeof window.resetsAt !== 'string' ||
        !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,3})?Z$/.test(window.resetsAt) ||
        (!Number.isFinite(Date.parse(window.resetsAt)) || new Date(window.resetsAt).toISOString().slice(0, 19) !== window.resetsAt.slice(0, 19)))) throw fail('invalid_response');
  }
  return payload;
}
function guardedFetch(key, request, deps, signal, onFailure) {
  return async (url, init = {}) => {
    try {
      if (request.options.allowProviderNetwork === false) throw fail('network_disabled');
      if (String(url) !== URL || (init.method || 'GET') !== 'GET') throw fail('endpoint_rejected');
      const response = await (deps.fetch || globalThis.fetch)(URL, {
        method: 'GET', headers: { Authorization: `Bearer ${key}`, Accept: 'application/json' },
        redirect: 'error', signal
      });
      if (response.redirected || (response.url && response.url !== URL) || (response.status >= 300 && response.status < 400)) throw fail('redirect_rejected');
      const declared = response.headers?.get('content-length');
      if (declared && (!/^\d+$/.test(declared) || Number(declared) > MAX_BYTES)) throw fail('body_limit');
      if (!response.body?.getReader) throw fail('invalid_response');
      const reader = response.body.getReader();
      const chunks = []; let size = 0;
      const cancelRead = () => { void reader.cancel().catch(() => {}); };
      signal.addEventListener('abort', cancelRead, { once: true });
      try {
        while (true) {
          if (signal.aborted) throw fail('cancelled');
          const { done, value } = await reader.read();
          if (done) break;
          size += value.byteLength;
          if (size > MAX_BYTES) throw fail('body_limit');
          chunks.push(Buffer.from(value));
        }
      } finally { signal.removeEventListener('abort', cancelRead); cancelRead(); }
      let body;
      try { body = strictJSON(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks))); }
      catch { if (response.status === 200) throw fail('invalid_response'); body = null; }
      if (response.status === 200) validateUsage(body);
      return { status: response.status, json: async () => body };
    } catch (error) {
      const codes = ['network_disabled', 'endpoint_rejected', 'redirect_rejected', 'body_limit', 'invalid_response'];
      onFailure(codes.includes(error.code) ? error.code : 'transport_failed');
      throw fail('transport_failed');
    }
  };
}
async function collectOpenCodeLimits(target, request, deps, scope) {
  const binding = JSON.stringify([target.root, target.declaredRoot, target.sourceIds, target.providerIds, target.accountId]);
  const snapshot = { updatedAt: request.now, refreshMs: 300000, providers: [] };
  const unavailable = reason => ({ ...snapshot, reasonCode: reason,
    providers: [{ provider: 'opencode', status: 'unavailable', windows: [], balanceUsd: null, source: provenance }] });
  let auth;
  try { auth = readSnapshot(target); } catch (error) { return unavailable(error.code); }
  const controller = new AbortController();
  let timer, abort, failure, apiResult;
  const aborted = new Promise((_, reject) => {
    abort = () => { controller.abort(); reject(fail('cancelled')); };
    scope.signal?.addEventListener('abort', abort, { once: true });
    timer = setTimeout(() => { controller.abort(); reject(fail('timeout')); }, Math.max(1, Math.min(request.options.timeoutMs || 15000, 60000)));
  });
  const forbidden = () => { throw fail('forbidden_collaborator'); };
  try {
    if (scope.signal?.aborted) throw fail('cancelled');
    // Loaded through the existing vendor resolver in normal engine execution.
    const api = require('../upstream/src/shared/providers/opencode/goApi.js');
    const provider = require('../upstream/src/shared/providers/opencode/limits.js');
    const { hashKey } = require('../upstream/src/shared/hashKey.js');
    const row = await Promise.race([aborted, provider.fetchOpenCodeLimits({
      limitsEnabled: true, limitProviders: ['opencode'], limitRefreshScope: { provider: 'opencode' },
      opencodeProfiles: { selected: { enabled: true, apiKey: auth.key } },
      opencodeAmbientEnabled: false, opencodeLocalLimitsEnabled: false
    }, {
      env: {}, now: () => Date.parse(request.now), signal: controller.signal,
      fetch: guardedFetch(auth.key, request, deps, controller.signal, code => { failure = code; }),
      opencodeReadGoApiKey: () => '',
      opencodeCollectGoApi: async input => { apiResult = await api.collectGoApi({ ...input, apiKey: auth.key, env: {} }); return apiResult; },
      opencodeCollectGo: forbidden, opencodeFetchGoWeb: forbidden, opencodeFetchZen: forbidden,
      readFile: forbidden, spawn: forbidden, refresh: forbidden, discover: forbidden
    })]);
    if (scope.signal?.aborted) throw fail('cancelled');
    if (binding !== JSON.stringify([target.root, target.declaredRoot, target.sourceIds, target.providerIds, target.accountId])) return unavailable('target_changed');
    try { if (readSnapshot(target).fingerprint !== auth.fingerprint) return unavailable('auth_changed'); }
    catch { return unavailable('auth_changed'); }
    if (failure) return unavailable(failure);
    if (!row || Array.isArray(row) || !['ok', 'notConfigured', 'unauthorized', 'sourceRateLimited', 'unavailable'].includes(row.status) || row.provider !== 'opencode' || row.accountKey !== hashKey('opencode', api.goApiIdentity(auth.key))) return unavailable('identity_mismatch');
    if (row.status === 'notConfigured' && apiResult?.entitled !== false) return unavailable('collection_failed');
    // Allowlist only quota data: never return upstream key hashes or account names.
    snapshot.providers = [{ provider: 'opencode', status: row.status, source: provenance, balanceUsd: null,
      windows: (row.windows || []).map(w => ({ kind: w.kind, usedPercent: w.usedPercent, resetsAt: w.resetsAt })) }];
    snapshot.reasonCode = row.status === 'notConfigured' ? 'unsupported_go_plan' : row.status === 'ok' ? 'ok' : row.status;
    return snapshot;
  } catch (error) {
    if (scope.signal?.aborted || error.code === 'cancelled') throw fail('cancelled');
    return unavailable(error.code === 'timeout' ? 'timeout' : 'collection_failed');
  } finally {
    clearTimeout(timer); scope.signal?.removeEventListener('abort', abort); controller.abort();
  }
}
module.exports = { collectOpenCodeLimits, validateUsage, strictJSON, guardedFetch, readSnapshot };
