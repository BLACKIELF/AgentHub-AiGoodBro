'use strict';
// Test-only source-layout binding. Production paths never inspect environment.
const path = require('node:path');
const fs = require('node:fs');
const root = path.resolve(__dirname, '../../..', 'upstream');
const target = require.resolve('../../lib/upstream/paths.cjs');
require.cache[target] = { id: target, filename: target, loaded: true, exports: {
  upstreamRoot: () => root, upstreamSrcRoot: () => path.join(root, 'src'),
  upstreamModule: name => path.join(root, 'src', name)
} };
const home = fs.mkdtempSync('/tmp/token-monitor-next-test-');
const { scopedEnvironment } = require('../../lib/runtime/source-scope.cjs');
const mode = process.env.TOKEN_MONITOR_ENGINE_FIXTURES_MODE;
const testContext = process.env.NODE_TEST_CONTEXT;
for (const key of Object.keys(process.env)) delete process.env[key];
Object.assign(process.env, scopedEnvironment(home));
if (process.versions.electron) process.env.ELECTRON_RUN_AS_NODE = '1';
if (testContext) process.env.NODE_TEST_CONTEXT = testContext;
if (mode) process.env.TOKEN_MONITOR_ENGINE_FIXTURES_MODE = mode;
process.on('exit', () => fs.rmSync(home, { recursive: true, force: true }));
globalThis.fetch = async () => { throw new Error('test-network-forbidden'); };
