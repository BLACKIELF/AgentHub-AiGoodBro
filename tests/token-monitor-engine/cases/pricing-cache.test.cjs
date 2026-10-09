'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const f = require('./helpers/fixtures.cjs');
const { scopedEnvironment } = require('../lib/runtime/source-scope.cjs');
const { readTokscalePricingCatalog, tokscaleCacheDirs } = require('../lib/upstream/pricing-catalog.cjs');
const { handleRequest } = require('../lib/handler.cjs');

const rates = value => ({ input_cost_per_token: value, output_cost_per_token: value * 2,
  cache_read_input_token_cost: 0, cache_creation_input_token_cost: 0 });
function writeCatalog(directory, models, timestamp = 100) {
  fs.mkdirSync(directory, { recursive: true });
  fs.writeFileSync(path.join(directory, 'pricing-litellm.json'), JSON.stringify({ timestamp, data: models }));
}

test('read-only price evidence retains exact keys, ambiguity denial and explicit zero rates', () => {
  const home = f.makeHome('tm-price-evidence-');
  try {
    const options = { homeDir: home, env: scopedEnvironment(home), nowMs: 200000 };
    writeCatalog(tokscaleCacheDirs(options)[0], {
      'vendor-a/model': rates(1), 'vendor-b/model': rates(2), zero: rates(0)
    });
    const before = fs.readdirSync(home, { recursive: true });
    assert.equal(readTokscalePricingCatalog('vendor-a/model', options).inputCostPerToken, 1);
    assert.equal(readTokscalePricingCatalog('model', options), null, 'ambiguous bare model cannot borrow a vendor price');
    assert.equal(readTokscalePricingCatalog('vendor-c/model', options), null);
    assert.equal(readTokscalePricingCatalog('auto', options), null);
    assert.deepEqual(readTokscalePricingCatalog('zero', options), {
      inputCostPerToken: 0, outputCostPerToken: 0, cacheReadInputTokenCost: 0, cacheCreationInputTokenCost: 0
    });
    assert.deepEqual(fs.readdirSync(home, { recursive: true }), before, 'catalog checks write nothing');
  } finally { f.cleanup(home); }
});

test('canonical cache precedence, future timestamps and explicit roots remain fail closed', () => {
  const home = f.makeHome('tm-price-roots-');
  try {
    const options = { homeDir: home, env: scopedEnvironment(home), nowMs: 200000 };
    const [canonical, legacy] = tokscaleCacheDirs(options);
    writeCatalog(legacy, { exact: rates(1) });
    assert.equal(readTokscalePricingCatalog('exact', options).inputCostPerToken, 1);
    writeCatalog(canonical, { exact: rates(3) }, 300);
    assert.equal(readTokscalePricingCatalog('exact', options), null, 'future canonical cache cannot fall back to legacy');
    assert.equal(readTokscalePricingCatalog('exact', { ...options, nowMs: 300000 }).inputCostPerToken, 3);
    writeCatalog(canonical, { exact: { ...rates(4), output_cost_per_token: 'invalid' } });
    assert.equal(readTokscalePricingCatalog('exact', options), null, 'invalid canonical cache cannot borrow legacy data');
    const isolated = path.join(home, 'explicit');
    const explicit = { ...options, env: { ...options.env, TOKSCALE_CONFIG_DIR: isolated } };
    assert.deepEqual(tokscaleCacheDirs(explicit), [path.join(isolated, 'cache')]);
    assert.equal(readTokscalePricingCatalog('exact', explicit), null, 'explicit override never reaches profile fallback');
  } finally { f.cleanup(home); }
});

test('independent scoped homes never share cached model rates', () => {
  const home = f.makeHome('tm-price-targets-');
  try {
    for (const value of [2, 7, 2]) {
      const scoped = path.join(home, String(value));
      const options = { homeDir: scoped, env: scopedEnvironment(scoped), nowMs: 200000 };
      writeCatalog(tokscaleCacheDirs(options)[0], { exact: rates(value) });
      assert.equal(readTokscalePricingCatalog('exact', options).inputCostPerToken, value);
    }
  } finally { f.cleanup(home); }
});

test('valid scoped cache certifies collected cost evidence without authorizing network', async () => {
  const home = f.makeHome('tm-priced-collection-');
  try {
    const options = { homeDir: home, env: scopedEnvironment(home) };
    writeCatalog(tokscaleCacheDirs(options)[0], { [f.ARBITRARY_MODEL]: rates(0.000001) });
    const request = f.baseRequest(home, { sources: [f.source({ id: 'priced-local', providerId: 'claude',
      canonicalPath: home, pathRole: 'userHome' })] });
    let fetches = 0;
    const response = await handleRequest(request, { ...f.runners(), fetch: async () => { fetches++; throw Error('network-forbidden'); } });
    assert.equal(response.status, 'ok');
    assert.equal(response.payload.aggregate.today.totalTokens, 100);
    assert.equal(response.coverage.entries.find(entry => entry.date === '2026-09-13' && entry.metric === 'cost').status, 'known');
    assert.equal(fetches, 0);
  } finally { f.cleanup(home); }
});
