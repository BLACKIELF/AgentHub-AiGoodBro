'use strict';
// Frozen production server + real Swift URLSession. Only synthetic loopback IO.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const http = require('node:http');
const path = require('node:path');
const { once } = require('node:events');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const runFile = promisify(execFile);
const { createServer } = require(path.resolve(process.argv[2], 'server.cjs'));

async function main() {
  const binary = path.resolve(process.argv[3]);
  const folder = path.resolve(process.argv[4]);
  const receiptPath = path.resolve(process.argv[5]);
  await fs.mkdir(folder, { recursive: true, mode: 0o700 });
  const desktopToken = 'synthetic-desktop-http-token-'.repeat(3);
  const sessionSecret = 'synthetic-session-http-secret-'.repeat(3);
  let now = 1_800_000_000_000;
  let checks = 0;
  let sequence = 0;
  const assertions = [];
  const trace = [];
  const results = [];
  const check = (actual, expected, label) => { assert.deepEqual(actual, expected, label); checks++; assertions.push(label); };
  const storage = path.join(folder, 'state');
  const options = {
    desktopToken, sessionSecret, storageDir: storage, clock: () => now,
    checkIntervalMs: 0, publicFeedCheckIntervalMs: 0,
    code2Session: async code => ({ openid: 'synthetic-client-user-' + code })
  };
  const servers = new Set();
  const start = async server => {
    servers.add(server);
    if (server.ready) await server.ready;
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    return `http://127.0.0.1:${server.address().port}/`;
  };
  const close = async server => {
    if (!server.listening) return;
    const ended = once(server, 'close');
    server.close(); server.closeIdleConnections?.();
    await ended; servers.delete(server);
  };
  const runSwift = async (endpoint, action, snapshot) => {
    assert.equal(new URL(endpoint).hostname, '127.0.0.1');
    const inputPath = path.join(folder, `swift-input-${sequence++}.json`);
    await fs.writeFile(inputPath, JSON.stringify({ endpoint, token: desktopToken, action, now: now / 1000, snapshot }), { mode: 0o600 });
    const { stdout, stderr } = await runFile(binary, ['http', inputPath], {
      timeout: 15_000, maxBuffer: 64 * 1024, env: { PATH: process.env.PATH || '/usr/bin:/bin' }
    });
    assert.equal(stderr.trim(), '', 'Swift HTTP fixture must not emit credentials or diagnostics');
    assert.ok(!stdout.includes(desktopToken), 'Swift output must redact credentials');
    const result = JSON.parse(stdout.trim());
    // Pairing codes are consumed inside the fixture and never kept in receipts.
    results.push({ action, kind: result.kind, statusCode: result.statusCode, reason: result.reason });
    return result;
  };
  const request = async (endpoint, route, method, body, token) => {
    const response = await fetch(new URL(route, endpoint), {
      method, redirect: 'error', signal: AbortSignal.timeout(5000),
      headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body)
    });
    return { status: response.status, data: await response.json(), cache: response.headers.get('cache-control') };
  };
  const syntheticSnapshot = () => ({
    accountRef: 'a'.repeat(64), label: '账号 aaaaaaaa', scope: 'b'.repeat(64),
    observedAt: new Date(now).toISOString(), status: 'ok', availableResetCredits: 2,
    resetCards: [{ id: 'c'.repeat(64), expiresAt: new Date(now + 3_600_000).toISOString() }]
  });
  try {
    let server = createServer(options);
    server.on('request', request => {
      if (!request.url.startsWith('/v1/desktop/')) return;
      const row = { path: request.url, authorizationPresent: Boolean(request.headers.authorization) };
      trace.push(row);
      const chunks = [];
      request.on('data', bytes => chunks.push(bytes));
      request.on('end', () => {
        const body = Buffer.concat(chunks).toString();
        row.bodyContainsBearer = body.includes(desktopToken);
        try { row.bodyKeys = Object.keys(JSON.parse(body)).sort(); } catch { row.bodyKeys = []; }
      });
    });
    let endpoint = await start(server);
    const pairing = await runSwift(endpoint, 'pairing');
    check(pairing.kind, 'accepted', 'real Swift pairing creation');
    const login = await request(endpoint, '/v1/session', 'POST', { code: 'A' });
    check(login.status, 200, 'synthetic mini session');
    const sessionToken = login.data.token;
    check((await request(endpoint, '/v1/pair', 'POST', { code: pairing.code }, sessionToken)).status, 200, 'pair the synthetic session');
    const snapshot = syntheticSnapshot();
    const sent = await runSwift(endpoint, 'upload', snapshot);
    check(sent.kind, 'accepted', 'real Swift V1 upload accepted');
    check(sent.accepted, true, 'acknowledgement is explicit');
    check(Number.isInteger(sent.eventCount), true, 'acknowledgement event count parsed');
    check(await runSwift(endpoint, 'upload', snapshot), { kind: 'rejected', statusCode: 409 }, 'identical observation conflicts without replay');
    let companion = await request(endpoint, '/v1/companion', 'GET', undefined, sessionToken);
    check(companion.data.accounts[0].availableResetCredits, 2, 'server stores V1 count');
    check(companion.data.accounts[0].resetCards, snapshot.resetCards, 'server stores source cards');
    check(companion.cache, 'no-store', 'companion private read is not cached');
    const failed = { ...snapshot, status: 'failed', availableResetCredits: null, resetCards: [] };
    check((await runSwift(endpoint, 'upload', failed)).kind, 'accepted', 'equal-time failed observation invalidates success');
    companion = await request(endpoint, '/v1/companion', 'GET', undefined, sessionToken);
    check(companion.data.accounts[0].status, 'failed', 'equal-time failure status persisted');
    check(companion.data.accounts[0].availableResetCredits, null, 'equal-time failure does not retain count');
    check(companion.data.accounts[0].resetCards, [], 'equal-time failure revokes cards');
    check(await runSwift(endpoint, 'upload', snapshot), { kind: 'rejected', statusCode: 409 }, 'same-time success does not revive failed facts');
    await close(server);
    server = createServer(options); endpoint = await start(server);
    companion = await request(endpoint, '/v1/companion', 'GET', undefined, sessionToken);
    check(companion.status, 200, 'pair/session survive isolated server restart');
    check(companion.data.accounts[0].status, 'failed', 'failure watermark survives restart');
    check(companion.data.accounts[0].observedAt, snapshot.observedAt, 'source timestamp survives restart');
    now++;
    check((await runSwift(endpoint, 'upload', syntheticSnapshot())).kind, 'accepted', 'newer explicit observation can restore facts');
    await close(server);
    check(trace.every(row => row.authorizationPresent && row.bodyContainsBearer === false), true, 'bearer only in request header');
    check(trace.filter(row => row.path === '/v1/desktop/snapshots').every(row =>
      JSON.stringify(row.bodyKeys) === JSON.stringify(['accountRef', 'availableResetCredits', 'label', 'observedAt', 'resetCards', 'scope', 'status'])), true, 'real HTTP upload has exact V1 keys and no overview');

    const redirectCases = [];
    for (const status of [302, 307, 308]) {
      let redirectedRequests = 0;
      let redirectedAuthorization = false;
      const second = http.createServer((request, response) => {
        redirectedRequests++; redirectedAuthorization ||= Boolean(request.headers.authorization);
        response.setHeader('Content-Type', 'application/json');
        response.end(JSON.stringify({ code: 'redirected-synthetic-code', expiresAt: new Date(now + 600_000).toISOString() }));
      });
      const secondEndpoint = await start(second);
      let firstRequests = 0;
      const first = http.createServer((request, response) => {
        firstRequests++; request.resume();
        response.writeHead(status, { Location: new URL('/v1/desktop/pairings', secondEndpoint).href }); response.end();
      });
      const redirectOutcome = await runSwift(await start(first), 'pairing');
      check(redirectOutcome.kind, 'unconfirmed', `${status} redirect is not an accepted pairing`);
      check(firstRequests, 1, `${status} redirect origin receives one request`);
      check(redirectedRequests, 0, `${status} URLSession does not follow redirect`);
      check(redirectedAuthorization, false, `${status} bearer never reaches redirect destination`);
      redirectCases.push({ status, firstRequests, redirectedRequests, redirectedAuthorization });
      await close(first); await close(second);
    }

    for (const mode of ['oversize-length', 'oversize-chunked', 'invalid-json', 'server-error', 'transport-disconnect']) {
      let count = 0;
      const bad = http.createServer((request, response) => {
        count++; request.resume();
        if (mode === 'transport-disconnect') { request.socket.destroy(); return; }
        response.setHeader('Content-Type', 'application/json');
        const body = mode.startsWith('oversize') ? JSON.stringify({ code: 'oversize-synthetic-code', expiresAt: new Date(now + 600_000).toISOString() }) + ' '.repeat(35_000) : 'not-json';
        if (mode === 'server-error') response.statusCode = 500;
        if (mode === 'oversize-length') response.setHeader('Content-Length', Buffer.byteLength(body));
        if (mode === 'oversize-chunked') { response.write(body.slice(0, 10_000)); response.end(body.slice(10_000)); }
        else response.end(body);
      });
      const result = await runSwift(await start(bad), 'pairing');
      check(result.kind, 'unconfirmed', `${mode} never claims success`);
      check(count, 1, `${mode} is not automatically replayed`);
      if (mode === 'server-error') check(result.reason, 'serverError', 'server error classification');
      if (mode === 'invalid-json') check(result.reason, 'invalidResponse', 'invalid JSON classification');
      await close(bad);
    }
    const receipt = { version: '1015v1', ok: true, checks, assertions, results, requests: trace,
      realAccountIO: false, externalNetworkSends: 0, serverRestarted: true,
      redirectCases, redirectDestinationRequests: redirectCases.reduce((sum, row) => sum + row.redirectedRequests, 0),
      redirectDestinationAuthorization: redirectCases.some(row => row.redirectedAuthorization) };
    await fs.writeFile(receiptPath, JSON.stringify(receipt, null, 2) + '\n');
    console.log(`PASS real Swift-to-Node desktop HTTP: ${checks} checks; loopback only`);
  } finally {
    for (const server of [...servers]) await close(server);
  }
}
main().catch(error => { console.error(error.stack); process.exitCode = 1; });
