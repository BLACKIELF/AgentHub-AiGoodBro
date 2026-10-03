// The visual suite writes two very different kinds of file, and they must never
// share a directory:
//   * baselines (`snapshotPathTemplate`) are durable and belong in the repository
//     tree under the Git-ignored `.local-artifacts/`;
//   * the per-run scratch tree (`outputDir`) is transient, is emptied when a run
//     starts, and must not be reachable by another run or by `git`.
// A collision between them either commits an artifact or makes a second run
// delete the first one's output, so both directions are asserted here.

import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFile, readdir } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const configUrl = new URL('./visual/playwright.config.mjs', import.meta.url);
const visualDir = path.dirname(fileURLToPath(configUrl));
const webRoot = path.resolve(visualDir, '..', '..');
const repoRoot = path.resolve(visualDir, '..', '..', '..', '..', '..', '..');

/** Loads the config in a fresh module registry so env changes take effect. */
let loads = 0;
async function loadConfig(env = {}) {
  const saved = {};
  for (const [key, value] of Object.entries(env)) {
    saved[key] = process.env[key];
    process.env[key] = value;
  }
  try {
    const { default: config } = await import(`${configUrl.href}?load=${++loads}`);
    return config;
  } finally {
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

const normalise = value => path.resolve(value).replace(/\\/g, '/').toLowerCase();
const isInside = (child, parent) => {
  const from = normalise(parent);
  const to = normalise(child);
  return to === from || to.startsWith(`${from}/`);
};

test('the run scratch tree can never be reached by another run or by git', async () => {
  delete process.env.CODEXU_VISUAL_SCRATCH_ROOT;
  const config = await loadConfig();

  const output = normalise(config.outputDir);
  const snapshots = normalise(config.snapshotPathTemplate);

  // Scratch is transient, so it lives in the OS temp directory, never in the tree.
  assert.ok(isInside(output, os.tmpdir()), `${output} must be under ${os.tmpdir()}`);
  assert.equal(isInside(output, repoRoot), false, 'scratch must stay out of the repository');

  // Baselines are durable, so they stay in the repository tree.
  assert.ok(isInside(snapshots, repoRoot), `${snapshots} must be under ${repoRoot}`);
  assert.equal(isInside(snapshots, os.tmpdir()), false, 'baselines must not live in temp');

  // The two trees must be disjoint in both directions.
  assert.equal(isInside(output, snapshots), false, 'scratch must not sit under the baselines');
  assert.equal(isInside(snapshots, output), false, 'baselines must not sit under scratch');
});

test('two runs never share a scratch directory', async () => {
  delete process.env.CODEXU_VISUAL_SCRATCH_ROOT;
  const here = (await loadConfig()).outputDir;

  // A second *process* is what a concurrent run actually is, so the comparison is
  // made against one rather than against a second import in this process.
  const script = `import(${JSON.stringify(configUrl.href)}).then(m => process.stdout.write(m.default.outputDir))`;
  const elsewhere = execFileSync(process.execPath, ['-e', script], {
    cwd: webRoot, encoding: 'utf8',
  }).trim();

  assert.notEqual(normalise(here), normalise(elsewhere), 'two runs resolved the same scratch directory');
  // The process id is part of the leaf, which is what keeps them apart.
  const leaf = path.basename(path.dirname(here));
  assert.ok(leaf.startsWith(`${process.pid}-`), leaf);
});

test('an explicit scratch root still wins over the per-run default', async () => {
  const chosen = path.join(os.tmpdir(), 'codexu-visual-explicit');
  const config = await loadConfig({ CODEXU_VISUAL_SCRATCH_ROOT: chosen });
  assert.ok(isInside(config.outputDir, chosen), config.outputDir);
});

test('the dev server port is overridable but reproducible by default', async () => {
  const byDefault = await loadConfig();
  assert.equal(byDefault.use.baseURL, 'http://127.0.0.1:1421');
  assert.equal(byDefault.webServer.url, byDefault.use.baseURL);
  assert.equal(byDefault.webServer.reuseExistingServer, false);

  // A machine that already holds the default port can move the whole suite; the
  // base URL and the server URL must move together.
  const moved = await loadConfig({ CODEXU_VISUAL_PORT: '1599' });
  assert.equal(moved.use.baseURL, 'http://127.0.0.1:1599');
  assert.equal(moved.webServer.url, moved.use.baseURL);
  assert.match(moved.webServer.command, /--port 1599 --strictPort/);

  // Garbage in the variable falls back to the documented default.
  for (const value of ['', 'abc', '0', '-1']) {
    const fallback = await loadConfig({ CODEXU_VISUAL_PORT: value });
    assert.equal(fallback.use.baseURL, 'http://127.0.0.1:1421', `value ${JSON.stringify(value)}`);
  }
});

test('every screenshot name maps to exactly one baseline file', async () => {
  const specs = (await readdir(visualDir)).filter(name => name.endsWith('.visual.spec.mjs'));
  assert.ok(specs.length > 0, 'no visual spec was found');

  const seen = new Map();
  const patterns = new Set();
  for (const spec of specs) {
    const source = await readFile(path.join(visualDir, spec), 'utf8');
    for (const [, argument] of source.matchAll(/toHaveScreenshot\(\s*([^),\n]+)/g)) {
      const name = argument.trim();
      // A template literal expands per case; only its shape can be compared.
      if (name.includes('${')) {
        assert.match(name, /\.png`$/, `${spec}: ${name} must resolve to a .png name`);
        patterns.add(name.replace(/\$\{[^}]*\}/g, '*'));
        continue;
      }
      const literal = name.replace(/^['"`]|['"`]$/g, '');
      assert.match(literal, /\.png$/, `${spec}: ${literal} must be a .png name`);
      // Two specs using one name would silently overwrite each other, because the
      // path template keys on the name alone.
      assert.equal(seen.has(literal), false,
        `${literal} is captured by both ${seen.get(literal)} and ${spec}`);
      seen.set(literal, spec);
    }
  }
  assert.ok(seen.size > 0, 'no screenshot name was found');
});
