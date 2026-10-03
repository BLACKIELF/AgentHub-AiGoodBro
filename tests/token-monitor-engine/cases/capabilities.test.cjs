'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const { handleRequest } = require('../lib/handler.cjs');
const { createRequestScope } = require('../lib/runtime/scope.cjs');
const loader = require('../lib/upstream/loader.cjs');
const { upstreamModule, upstreamSrcRoot } = require('../lib/upstream/paths.cjs');
const descendants = require('../lib/runtime/descendants.cjs');
const capabilities = require('../lib/upstream/capabilities.cjs');
const fixtures = require('./helpers/fixtures.cjs');

const HOOKS_DIR = path.resolve(__dirname, '..', 'hooks');

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function scopeFor() {
  return createRequestScope({ timeoutMs: 20000 }).start();
}

async function collect(request, deps = {}) {
  const scope = scopeFor();
  try {
    return await handleRequest(request, { scope, signal: scope.signal, ...deps });
  } finally {
    scope.dispose();
  }
}

test('the pinned upstream commit and version are reported verbatim', () => {
  const engine = loader.describeEngine();
  assert.equal(engine.repository, 'Javis603/token-monitor');
  assert.equal(engine.commit, 'dcccfb01557e2786888fd5479552f392ac6c0d32');
  assert.equal(engine.version, '0.62.0');
  assert.equal(engine.pinned, true);
});

test('every capability hook names an unmodified upstream file and an existing overlay', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(HOOKS_DIR, 'manifest.json'), 'utf8'));
  assert.ok(manifest.hooks.length >= 3);
  for (const hook of manifest.hooks) {
    const overlayPath = path.join(HOOKS_DIR, path.basename(hook.overlay));
    assert.ok(fs.existsSync(overlayPath), `overlay missing for ${hook.id}`);
    const upstreamPath = path.join(path.resolve(upstreamSrcRoot(), '..'), hook.upstreamFile);
    assert.ok(fs.existsSync(upstreamPath), `upstream file missing for ${hook.id}`);
    assert.equal(sha256(upstreamPath), hook.upstreamSha256, `upstream drift for ${hook.id}`);
    assert.ok(typeof hook.capability === 'string' && hook.capability.length > 0);
  }

  const applied = loader.prepare().overlays;
  assert.deepStrictEqual(applied.map((entry) => entry.applied), [true, true, true]);
});

test('the overlays replace exactly the hooked exports and pass the rest through', () => {
  loader.prepare();
  const providerHelpers = require(upstreamModule('shared/limits/providerHelpers.js'));
  const raw = require('../lib/upstream/vendor.cjs').loadFresh(upstreamModule('shared/limits/providerHelpers.js'));

  assert.notStrictEqual(providerHelpers.fetchJson, raw.fetchJson, 'fetchJson must be the gated wrapper');
  assert.notStrictEqual(providerHelpers.runProcessText, raw.runProcessText, 'runProcessText must be the gated wrapper');

  // Untouched exports come from the overlay's own fresh copy of the real
  // module, so they are compared by behaviour rather than by identity.
  assert.equal(providerHelpers.parseBoolean('true'), raw.parseBoolean('true'));
  assert.equal(providerHelpers.errorWithStatus('unauthorized', 'x').status, 'unauthorized');
  assert.equal(providerHelpers.cleanSecret('  a b  '), raw.cleanSecret('  a b  '));
  assert.deepStrictEqual(
    Object.keys(providerHelpers).sort(),
    Object.keys(raw).sort(),
    'the overlay must not add or drop exports'
  );
});

test('credential-refresh endpoints are refused unless the caller authorises them', async () => {
  loader.prepare();
  const providerHelpers = require(upstreamModule('shared/limits/providerHelpers.js'));
  const tokenUrl = 'https://console.anthropic.com/v1/oauth/token';

  capabilities.resetCapabilities();
  capabilities.setCapabilities({ allowCredentialRefresh: false, allowProviderNetwork: true });
  await assert.rejects(
    () => providerHelpers.fetchJson(tokenUrl, {}, { fetch: async () => { throw new Error('must not be reached'); } }),
    (error) => error.status === 'unauthorized'
  );
  assert.ok(capabilities.takeSuppressions().blocked.includes('credential_refresh_disabled'));

  // A usage endpoint is unaffected: collectLimits depends on it.
  capabilities.resetCapabilities();
  capabilities.setCapabilities({ allowCredentialRefresh: false, allowProviderNetwork: true });
  const response = await providerHelpers.fetchJson('https://api.anthropic.com/api/oauth/usage', {}, {
    fetch: async () => ({ ok: true, status: 200, json: async () => ({ ok: true }) })
  });
  assert.deepStrictEqual(response, { ok: true });
});

test('the provider CLI credential refresh is refused unless authorised', async () => {
  loader.prepare();
  const providerHelpers = require(upstreamModule('shared/limits/providerHelpers.js'));

  capabilities.resetCapabilities();
  capabilities.setCapabilities({ allowCredentialRefresh: false });
  await assert.rejects(
    () => providerHelpers.runProcessText('claude', ['/status'], { spawn: () => { throw new Error('must not be reached'); } }),
    (error) => error.code === 'CAPABILITY_DISABLED'
  );

  // A non-credential CLI still spawns normally: the gate is on the credential
  // refresh, not on process spawning in general.
  capabilities.resetCapabilities();
  capabilities.setCapabilities({ allowCredentialRefresh: false });
  const output = await providerHelpers.runProcessText('/bin/echo', ['hello'], { timeoutMs: 5000 });
  assert.match(String(output), /hello/);
});

test('self-sync is suppressed and recorded when the caller does not authorise it', async () => {
  const home = fixtures.makeHome();
  try {
    const layout = fixtures.twoToolsTwoHomes(home);
    const request = fixtures.baseRequest(home, {
      sources: [
        layout.sources[0],
        fixtures.source({ id: 'cursor-logs', providerId: 'cursor', pathRole: 'userHome', canonicalPath: fixtures.makeLogRoot(home, 'cursor-logs') })
      ]
    });

    const before = descendants.trackCount();
    const response = await collect(request, fixtures.runners());
    assert.equal(descendants.trackCount(), before, 'a fixture collect must spawn nothing');

    assert.ok(response.payload.suppressed.includes('self_sync_disabled:cursor'));
    assert.ok(!response.payload.suppressed.includes('self_sync_disabled:antigravity'), 'only the requested client is reported');
  } finally {
    fixtures.cleanup(home);
  }
});

test('a fixture collect performs no network access and mutates no credentials', async () => {
  const home = fixtures.makeHome();
  const realFetch = globalThis.fetch;
  let fetchCalls = 0;
  globalThis.fetch = async () => {
    fetchCalls += 1;
    throw new Error('network must not be used in fixture mode');
  };
  try {
    const layout = fixtures.twoToolsTwoHomes(home);
    const request = fixtures.baseRequest(home, { sources: layout.sources });
    const before = snapshotTree(home);

    const response = await collect(request, fixtures.runners());

    assert.equal(fetchCalls, 0, 'no outbound request may be made');
    assert.equal(response.status, 'ok');
    assert.deepStrictEqual(snapshotTree(home), before, 'the fixture home must not be written to');
    assert.ok(response.payload.suppressed === undefined, 'nothing was suppressed for a non-self-syncing client set');
  } finally {
    globalThis.fetch = realFetch;
    fixtures.cleanup(home);
  }
});

test('the price lookup is gated by allowPriceNetwork and by injection', async () => {
  const home = fixtures.makeHome();
  try {
    const base = fixtures.baseRequest(home, { sources: [] });
    const collectModule = require('../lib/collect.cjs');

    // Withheld: the injected lookup rejects, so upstream falls back to its
    // on-disk catalog instead of spawning `tokscale pricing`.
    const gated = collectModule.buildPriceLookup(base, {});
    assert.equal(typeof gated, 'function');
    await assert.rejects(() => gated('some-model'), (error) => error.code === 'CAPABILITY_DISABLED');

    // Authorised: no substitution at all — upstream's own lookup is used.
    const authorised = collectModule.buildPriceLookup(
      { ...base, options: { ...base.options, allowPriceNetwork: true } },
      {}
    );
    assert.equal(authorised, undefined);

    // An explicitly injected lookup always wins.
    const injected = async () => ({ input: 1 });
    assert.strictEqual(collectModule.buildPriceLookup(base, { lookupModelPricing: injected }), injected);
  } finally {
    fixtures.cleanup(home);
  }
});

test('allowPriceNetwork alone proves no model price and does not change token coverage', async () => {
  const home = fixtures.makeHome();
  try {
    const layout = fixtures.twoToolsTwoHomes(home);
    const base = fixtures.baseRequest(home, { sources: [layout.sources[0]] });
    const withheld = await collect(base, fixtures.runners());
    const withPricing = await collect({
      ...base,
      options: { ...base.options, allowPriceNetwork: true }
    }, fixtures.runners());

    assert.equal(withheld.coverage.cost, 'unknown');
    assert.equal(withheld.sources[0].coverage, 'known');
    assert.equal(withPricing.coverage.cost, 'unknown');
    assert.equal(withPricing.sources[0].coverage, 'known');

    // The usage figures are identical either way: the flag only changes what the
    // engine is willing to claim, never what it collected.
    assert.equal(withheld.payload.usage.today.totalTokens, withPricing.payload.usage.today.totalTokens);
    assert.equal(withheld.payload.usage.today.costUsd, withPricing.payload.usage.today.costUsd);
  } finally {
    fixtures.cleanup(home);
  }
});

function snapshotTree(root) {
  const entries = [];
  const walk = (dir) => {
    for (const name of fs.readdirSync(dir).sort()) {
      const full = path.join(dir, name);
      const stats = fs.statSync(full);
      entries.push(`${path.relative(root, full)}:${stats.isDirectory() ? 'd' : stats.size}`);
      if (stats.isDirectory()) walk(full);
    }
  };
  walk(root);
  return entries;
}
