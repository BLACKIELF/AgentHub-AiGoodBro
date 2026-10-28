'use strict';

// Runner module for spawned-bridge tests. The bridge only reads this when
// TOKEN_MONITOR_ENGINE_ALLOW_FIXTURES=1 is set alongside the path.
//
//   TOKEN_MONITOR_ENGINE_FIXTURES=<this file>
//   TOKEN_MONITOR_ENGINE_FIXTURES_MODE=normal|hang

const MODE = process.env.TOKEN_MONITOR_ENGINE_FIXTURES_MODE || 'normal';

function hang() {
  return new Promise(() => {});
}

async function runTokscale(input) {
  if (MODE === 'hang' || MODE === 'cleanup-unconfirmed') return hang();
  if (MODE === 'stubborn-child') {
    const marker = require('node:path').join(input.env.TOKSCALE_CONFIG_DIR, 'fixture-child.pid');
    require('node:child_process').spawn(process.execPath, ['-e',
      "process.on('SIGTERM', () => {}); require('node:fs').writeFileSync(process.argv[1], String(process.pid)); setInterval(() => {}, 1000);",
      marker], { env: { ...input.env, ELECTRON_RUN_AS_NODE: '1' }, stdio: 'ignore' });
    return hang();
  }
  return {
    entries: [{
      client: 'claude',
      model: 'vendor-x/ultra-long-context-preview-2026-09-13:free',
      input: 100,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      reasoning: 0,
      cost: 1.5,
      messages: 1
    }]
  };
}

async function runGraph() {
  if (MODE === 'hang') return hang();
  return {
    contributions: [{
      date: '2026-09-13',
      clients: [{
        client: 'claude',
        modelId: 'vendor-x/ultra-long-context-preview-2026-09-13:free',
        tokens: { input: 10, output: 20, cacheRead: 0, cacheWrite: 0, reasoning: 0 },
        cost: 1.5,
        messages: 2
      }]
    }]
  };
}

module.exports = { runTokscale, runGraph, mode: MODE };
