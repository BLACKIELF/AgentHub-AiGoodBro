'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const antigravityOAuth = require('../../src/shared/providers/antigravity/oauth');

test('Antigravity OAuth entry points fail closed before discovery or network activity', async () => {
  let fetchCalls = 0;
  const fetch = async () => { fetchCalls += 1; throw new Error('unexpected network request'); };
  const expectDisabled = (error) => error?.code === 'antigravity_oauth_disabled' && error?.status === 'unsupported';

  assert.throws(() => antigravityOAuth._officialOAuthClient(), expectDisabled);
  assert.throws(() => antigravityOAuth.discoverOAuthClient({ env: {}, applicationRoots: [] }), expectDisabled);
  assert.throws(() => antigravityOAuth.parseClientFromText('fixture only'), expectDisabled);
  assert.throws(() => antigravityOAuth.authorizationUrl({}), expectDisabled);
  await assert.rejects(antigravityOAuth.exchangeAuthorizationCode({}, { fetch }), expectDisabled);
  await assert.rejects(antigravityOAuth.fetchGoogleIdentity({}, { fetch }), expectDisabled);
  await assert.rejects(antigravityOAuth.refreshCredential({}, { fetch }), expectDisabled);
  await assert.rejects(antigravityOAuth.fetchRemoteSnapshot({}, { fetch }), expectDisabled);

  assert.equal(fetchCalls, 0, 'disabled auth paths must not send HTTP requests');
  assert.deepEqual(antigravityOAuth.candidateOAuthArtifacts(), [], 'client discovery must not inspect local apps');
});

test('Antigravity managed account metadata remains normalizable without credentials', () => {
  const accounts = antigravityOAuth.normalizeManagedAccounts([
    { id: 'fixture-account', email: 'Fixture@Example.test', credentials: { accessToken: 'secret' } }
  ]);
  assert.equal(accounts.length, 1);
  assert.equal(accounts[0].accountEmail, 'fixture@example.test');
  assert.equal(Object.hasOwn(accounts[0], 'credentials'), false);
});
