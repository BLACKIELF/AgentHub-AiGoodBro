'use strict';

const assert = require('node:assert/strict');
const { spawn, spawnSync } = require('node:child_process');
const path = require('node:path');
const test = require('node:test');

const fixtures = require('./helpers/fixtures.cjs');

const ENGINE_DIR = path.resolve(__dirname, '..');
const BRIDGE = path.join(__dirname, 'helpers', 'bridge-entry.cjs');
const FIXTURE_RUNNER = path.join(__dirname, 'helpers', 'fixture-runner.cjs');
const NODE = process.execPath;

function env(extra = {}) {
  return {
    ...process.env,
    TOKEN_MONITOR_ENGINE_ALLOW_FIXTURES: '1',
    TOKEN_MONITOR_ENGINE_FIXTURES: FIXTURE_RUNNER,
    ...extra
  };
}

function runBridge(input, options = {}) {
  return spawnSync(NODE, [BRIDGE], {
    input: typeof input === 'string' ? input : JSON.stringify(input),
    env: env(options.env),
    encoding: 'utf8',
    timeout: options.timeout || 60000,
    cwd: ENGINE_DIR
  });
}

function parseStdout(result) {
  return JSON.parse(result.stdout);
}

// Parses stderr as newline-delimited JSON diagnostics and asserts none of them
// carry anything but a level, a code and optional enum fields.
function assertSanitizedDiagnostics(stderr, forbidden = []) {
  for (const line of stderr.split('\n').filter(Boolean)) {
    // Electron emits this native sandbox diagnostic before JS starts; engine diagnostics stay strict.
    if (process.versions.electron && /^\[\d+\/\d+\.\d+:ERROR:electron\/shell\/common\/mac\/codesign_util\.cc:\d+\] task_name_for_pid: \(os\/kern\) failure \(5\)$/.test(line)) continue;
    const record = JSON.parse(line);
    assert.deepStrictEqual(
      Object.keys(record).sort().filter((key) => !['level', 'code', 'phase', 'retryable'].includes(key)),
      [],
      `unexpected diagnostic field in ${line}`
    );
    for (const needle of forbidden) {
      assert.ok(!line.includes(needle), `diagnostic leaked ${needle}`);
    }
  }
}

test('bridge returns one JSON result on stdout for a fixture request', () => {
  const home = fixtures.makeHome();
  try {
    const layout = fixtures.twoToolsTwoHomes(home);
    const request = fixtures.baseRequest(home, { sources: [layout.sources[0]] });
    const result = runBridge(request);

    assert.equal(result.status, 0, result.stderr);
    const response = parseStdout(result);
    assert.equal(response.schemaVersion, 1);
    assert.equal(response.requestId, 'fixture-request');
    assert.equal(response.status, 'ok');
    assert.equal(response.engine.repository, 'Javis603/token-monitor');
    assert.equal(response.engine.commit, '5d2db368d8313415763860d594de00e46a663418');
    assert.equal(response.engine.version, '0.68.0');
    assert.equal(response.payload.usage.today.totalTokens, 100);
    assert.equal(response.payload.history.daily.length, 1);
    assert.ok(Array.isArray(response.coverage.entries));
    assert.ok(response.coverage.entries.length > 0);

    // No filesystem paths may appear anywhere in the response.
    const serialized = JSON.stringify(response);
    assert.ok(!serialized.includes(home), 'response must not echo source paths');
    assert.ok(!serialized.includes(layout.logs), 'response must not echo source paths');
    assertSanitizedDiagnostics(result.stderr, [home]);
  } finally {
    fixtures.cleanup(home);
  }
});

test('bridge answers the capabilities operation without touching sources', () => {
  const home = fixtures.makeHome();
  try {
    const request = fixtures.baseRequest(home, { operation: 'capabilities', sources: [] });
    const result = runBridge(request);
    assert.equal(result.status, 0, result.stderr);
    const response = parseStdout(result);
    assert.equal(response.status, 'ok');
    assert.deepStrictEqual(response.sources, []);
    assert.deepStrictEqual(response.payload.capabilities.operations, ['collectUsage', 'collectLimits', 'capabilities']);
    assert.deepStrictEqual(response.payload.capabilities.defaults, {
      allowSelfSync: false,
      allowPriceNetwork: false,
      allowCredentialRefresh: false,
      allowProviderNetwork: true
    });
    assert.ok(response.payload.capabilities.hooks.includes('cursor-self-sync'));
  } finally {
    fixtures.cleanup(home);
  }
});

test('malformed JSON is a structured error with a non-zero exit', () => {
  const result = runBridge('{not json');
  assert.equal(result.status, 2);
  const response = parseStdout(result);
  assert.equal(response.status, 'error');
  assert.equal(response.errors[0].code, 'invalid_request');
  assert.equal(response.errors[0].retryable, false);
  assertSanitizedDiagnostics(result.stderr);
});

test('an unsupported schema version is rejected', () => {
  const home = fixtures.makeHome();
  try {
    const result = runBridge(fixtures.baseRequest(home, { schemaVersion: 2 }));
    assert.equal(result.status, 2);
    assert.equal(parseStdout(result).errors[0].code, 'unsupported_schema_version');
  } finally {
    fixtures.cleanup(home);
  }
});

test('an unknown operation is rejected', () => {
  const home = fixtures.makeHome();
  try {
    const result = runBridge(fixtures.baseRequest(home, { operation: 'collectEverything' }));
    assert.equal(result.status, 2);
    assert.equal(parseStdout(result).errors[0].code, 'unknown_operation');
  } finally {
    fixtures.cleanup(home);
  }
});

test('an oversized request is rejected instead of buffered without limit', () => {
  const padding = 'x'.repeat(9 * 1024 * 1024);
  const result = runBridge(JSON.stringify({ schemaVersion: 1, requestId: 'big', operation: 'capabilities', padding }));
  assert.equal(result.status, 2);
  assert.equal(parseStdout(result).errors[0].code, 'request_too_large');
});

test('the total deadline produces a timeout error and a non-zero exit', () => {
  const home = fixtures.makeHome();
  try {
    const layout = fixtures.twoToolsTwoHomes(home);
    const request = fixtures.baseRequest(home, {
      sources: [layout.sources[0]],
      options: { ...fixtures.baseRequest(home).options, timeoutMs: 1500 }
    });
    const result = runBridge(request, { env: { TOKEN_MONITOR_ENGINE_FIXTURES_MODE: 'hang' } });
    assert.equal(result.status, 3, result.stderr);
    assert.equal(parseStdout(result).errors[0].code, 'timeout');
    assert.equal(parseStdout(result).errors[0].retryable, true);
    assertSanitizedDiagnostics(result.stderr, [home]);
  } finally {
    fixtures.cleanup(home);
  }
});

test('SIGTERM cancels the request, reports cancelled, and exits 4', async () => {
  const home = fixtures.makeHome();
  try {
    const layout = fixtures.twoToolsTwoHomes(home);
    const request = fixtures.baseRequest(home, { sources: [layout.sources[0]] });
    const child = spawn(NODE, [BRIDGE], {
      env: env({ TOKEN_MONITOR_ENGINE_FIXTURES_MODE: 'hang' }),
      cwd: ENGINE_DIR,
      stdio: ['pipe', 'pipe', 'pipe']
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.stdin.end(JSON.stringify(request));

    await new Promise((resolve) => setTimeout(resolve, 1200));
    child.kill('SIGTERM');

    const exitCode = await new Promise((resolve) => child.on('exit', (code) => resolve(code)));
    assert.equal(exitCode, 4, `stderr: ${stderr}`);
    const response = JSON.parse(stdout);
    assert.equal(response.errors[0].code, 'cancelled');
    assertSanitizedDiagnostics(stderr, [home]);
  } finally {
    fixtures.cleanup(home);
  }
});
