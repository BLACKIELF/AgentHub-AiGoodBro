'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const { runAntigravityOAuthLogin, _callbackPage } = require('../../src/electron/providers/antigravity/oauthLogin');

test('disabled Antigravity login refuses before opening a browser or fetching credentials', async () => {
  let opened = false;
  let fetchCalls = 0;
  await assert.rejects(runAntigravityOAuthLogin({
    client: { clientId: 'fixture-client', clientSecret: 'fixture-secret' },
    openExternal: async () => { opened = true; },
    fetch: async () => { fetchCalls += 1; }
  }), (error) => error.code === 'antigravity_oauth_disabled');
  assert.equal(opened, false);
  assert.equal(fetchCalls, 0);
});

test('callback page remains generic and does not claim account persistence', () => {
  const page = _callbackPage(true);
  assert.match(page, /Sign-in received/);
  assert.match(page, /Return to Token Monitor to finish connecting this account/);
  assert.doesNotMatch(page, /account connected/);
});
