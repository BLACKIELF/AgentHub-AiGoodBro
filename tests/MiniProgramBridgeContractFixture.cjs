'use strict';
// Uses frozen real server modules with synthetic identities/data on loopback.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { once } = require('node:events');
const { createServer } = require(path.resolve(process.argv[2], 'server.cjs'));

async function main() {
  const inputs = JSON.parse(await fs.readFile(process.argv[3], 'utf8'));
  let checks = 0;
  const check = (actual, expected) => { assert.deepEqual(actual, expected); checks++; };
  for (const [index, input] of inputs.entries()) {
    const token = 'isolated-desktop-secret-'.repeat(3);
    let now = Date.parse(input.observedAt);
    const server = createServer({
      desktopToken: token, sessionSecret: 'isolated-session-secret-'.repeat(3),
      storageDir: path.resolve(process.argv[4], String(index)),
      clock: () => now, checkIntervalMs: 0, publicFeedCheckIntervalMs: 0,
      code2Session: async (code) => ({openid: 'isolated-user-' + code})
    });
    try {
      await server.ready;
      server.listen(0, '127.0.0.1');
      await once(server, 'listening');
      async function request(route, method = 'GET', body, credential) {
        const response = await fetch(`http://127.0.0.1:${server.address().port}${route}`, {
          method, redirect: 'error', signal: AbortSignal.timeout(5000),
          headers: {'Content-Type':'application/json', ...(credential ? {Authorization: `Bearer ${credential}`} : {})},
          body: body === undefined ? undefined : JSON.stringify(body)
        });
        return {status:response.status, data:await response.json(), cache:response.headers.get('cache-control')};
      }
      check((await request('/v1/desktop/snapshots', 'POST', input, token)).status, 403);
      const login = await request('/v1/session', 'POST', {code:'A'});
      check(login.status, 200);
      const pairing = await request('/v1/desktop/pairings', 'POST', {}, token);
      check(pairing.status, 200);
      check((await request('/v1/pair', 'POST', {code:pairing.data.code}, login.data.token)).status, 200);
      check((await request('/v1/desktop/snapshots', 'POST', input, token)).status, 200);
      const companion = await request('/v1/companion', 'GET', undefined, login.data.token);
      check(companion.status, 200);
      check(companion.cache, 'no-store');
      check(companion.data.accounts[0].availableResetCredits, input.availableResetCredits);
      check(companion.data.accounts[0].observedAt, input.observedAt);
      check(companion.data.accounts[0].resetCards, input.resetCards);
      check((await request('/v1/desktop/snapshots', 'POST', input, token)).status, 409);
      check((await request('/v1/desktop/snapshots', 'POST', {...input, points:'100'}, token)).status, 400);
      const stranger = await request('/v1/session', 'POST', {code:'B'});
      check((await request('/v1/companion', 'GET', undefined, stranger.data.token)).status, 403);
      if (index === 0) {
        // An equal-time invalidation must revoke previously accepted facts.
        // Do not "fix" this by inventing a later source timestamp.
        const downgraded = {...input, status:'failed', availableResetCredits:null, resetCards:[]};
        check((await request('/v1/desktop/snapshots', 'POST', downgraded, token)).status, 200);
        const invalidated = await request('/v1/companion', 'GET', undefined, login.data.token);
        check(invalidated.data.accounts[0].status, 'failed');
        check(invalidated.data.accounts[0].availableResetCredits, null);
        check(invalidated.data.accounts[0].resetCards, []);
        let messages = await request('/v1/messages', 'GET', undefined, login.data.token);
        check(messages.data.items.filter(x => x.kind === 'reset_expiry').length, 0);
        check((await request('/v1/desktop/snapshots', 'POST', input, token)).status, 409);
        now++;
        const restored = {...input, observedAt:new Date(now).toISOString(), availableResetCredits:4};
        check((await request('/v1/desktop/snapshots', 'POST', restored, token)).status, 200);
        messages = await request('/v1/messages', 'GET', undefined, login.data.token);
        check(messages.data.items.filter(x => x.kind === 'reset_delta').length, 0);
        now++;
        check((await request('/v1/desktop/snapshots', 'POST', {...restored, observedAt:new Date(now).toISOString(), availableResetCredits:5}, token)).status, 200);
        messages = await request('/v1/messages', 'GET', undefined, login.data.token);
        check(messages.data.items.filter(x => x.kind === 'reset_delta').length, 1);
      }
    } finally {
      if (server.listening) {
        const closed = once(server, 'close'); server.close(); server.closeIdleConnections(); await closed;
      }
    }
  }
  console.log(`PASS Swift-to-Node V1 contract: ${checks} assertions; loopback only, isolated identities`);
}
main().catch((error) => { console.error(error.stack); process.exitCode = 1; });
