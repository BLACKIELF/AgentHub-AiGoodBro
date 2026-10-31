'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { handleRequest } = require('../lib/handler.cjs');
const { createRequestScope } = require('../lib/runtime/scope.cjs');
const fixtures = require('./helpers/fixtures.cjs');

async function collect(request, observe) {
  const scope = createRequestScope({ timeoutMs: 20000 }).start();
  const runner = fixtures.runners();
  const original = runner.runTokscale;
  runner.runTokscale = async input => { observe(input); return original(input); };
  try { return await handleRequest(request, { scope, ...runner }); }
  finally { scope.dispose(); }
}

test('isolated scanner cache survives requests without sharing another source cache', async () => {
  const home = fixtures.makeHome();
  try {
    const first = fixtures.makeCodexHome(home, 'first');
    const second = fixtures.makeCodexHome(home, 'second');
    const request = root => fixtures.baseRequest(home, { sources: [fixtures.source({
      id: 'account', providerId: 'codex', kind: 'managedAccount', pathRole: 'codexHome', canonicalPath: root
    })] });
    let savedCache;
    let disposableHome;
    const scratch = os.tmpdir();
    const initial = await collect(request(first), input => {
      const cache = input.env.TOKSCALE_CONFIG_DIR;
      assert.ok(cache && cache.startsWith(path.join(home, 'cache') + path.sep));
      assert.equal(process.env.TOKSCALE_CONFIG_DIR, cache);
      assert.equal(input.env.CODEX_HOME, first, 'cache routing must not change log scope');
      assert.equal(input.env.TMPDIR, scratch, 'scanner scratch must keep the host-selected volume');
      savedCache = cache; disposableHome = input.homeDir;
      fs.writeFileSync(path.join(cache, 'retained-marker'), 'source-one');
    });
    assert.equal(initial.status, 'ok');
    assert.equal(fs.existsSync(disposableHome), false, 'temporary home still gets cleaned up');
    assert.equal(fs.readFileSync(path.join(savedCache, 'retained-marker'), 'utf8'), 'source-one');
    const renamed = request(first); renamed.sources[0].id = 'renamed-card';
    const repeat = await collect(renamed, input => {
      assert.equal(input.env.TOKSCALE_CONFIG_DIR, savedCache);
      assert.equal(fs.readFileSync(path.join(savedCache, 'retained-marker'), 'utf8'), 'source-one');
    });
    assert.equal(repeat.status, 'ok');
    const other = await collect(request(second), input => {
      assert.notEqual(input.env.TOKSCALE_CONFIG_DIR, savedCache);
      assert.equal(fs.existsSync(path.join(input.env.TOKSCALE_CONFIG_DIR, 'retained-marker')), false);
      assert.equal(input.env.CODEX_HOME, second);
    });
    assert.equal(other.status, 'ok');
  } finally { fixtures.cleanup(home); }
});

test('user-home retained history keeps its existing scanner cache location', async () => {
  const home = fixtures.makeHome();
  try {
    const response = await collect(fixtures.baseRequest(home, { sources: [fixtures.source({
      id: 'local', providerId: 'claude', pathRole: 'userHome', canonicalPath: home
    })] }), input => {
      assert.equal(input.homeDir, home);
      assert.equal(input.env.TOKSCALE_CONFIG_DIR, undefined);
      assert.equal(input.env.XDG_CONFIG_HOME, path.join(home, '.config'));
    });
    assert.equal(response.status, 'ok');
    assert.equal(fs.existsSync(path.join(home, 'cache', 'scanner-v1')), false);
  } finally { fixtures.cleanup(home); }
});

test('invalid cache paths are rejected before a source is scanned', async () => {
  const home = fixtures.makeHome();
  try {
    for (const cacheDirectory of ['relative-cache', path.join(home, 'cache\0suffix')]) {
      await assert.rejects(collect(fixtures.baseRequest(home, {cacheDirectory}), () => {
        assert.fail('invalid cache path reached the scanner');
      }), error => error.code === 'invalid_request');
    }
  } finally { fixtures.cleanup(home); }
});

test('a replaced scanner cache symlink cannot redirect writes', async () => {
  const home = fixtures.makeHome();
  try {
    const logs = fixtures.makeLogRoot(home);
    const request = fixtures.baseRequest(home, { sources: [fixtures.source({id:'logs',providerId:'claude',canonicalPath:logs})] });
    let cache;
    await collect(request, input => { cache = input.env.TOKSCALE_CONFIG_DIR; });
    fs.rmSync(cache, {recursive:true});
    const outside = path.join(home, 'outside'); fs.mkdirSync(outside);
    fs.symlinkSync(outside, cache);
    const temporaryHomes = () => fs.readdirSync(os.tmpdir())
      .filter(name => name.startsWith('token-monitor-next-scope-')).sort();
    const before = temporaryHomes();
    let scanned = false;
    const response = await collect(request, () => { scanned = true; });
    assert.equal(scanned, false);
    assert.equal(response.sources[0].status, 'unavailable');
    assert.deepEqual(fs.readdirSync(outside), []);
    assert.deepEqual(temporaryHomes(), before, 'failed cache setup must not leave temporary homes');
  } finally { fixtures.cleanup(home); }
});
