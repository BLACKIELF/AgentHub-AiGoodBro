'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createHash } = require('node:crypto');

// Original readers also consult process.env/cwd. The bridge handles one request
// serially; callers of the library must likewise serialize collections.
function scopedEnvironment(home, codexHome, timezone) {
  return { HOME: home, USERPROFILE: home, CODEX_HOME: codexHome || path.join(home, '.codex'),
    XDG_CONFIG_HOME: path.join(home, '.config'), XDG_DATA_HOME: path.join(home, '.local/share'),
    XDG_CACHE_HOME: path.join(home, '.cache'), TOKSCALE_PRICING_CACHE_ONLY: '1',
    TOKSCALE_AUTOSUBMIT_SKIP_SCHEDULER: '1', TMPDIR: os.tmpdir(), PATH: '', TZ: timezone || 'UTC' };
}
function enter(env, cwd) {
  const previous = { ...process.env };
  const previousCwd = process.cwd();
  for (const key of Object.keys(process.env)) delete process.env[key];
  Object.assign(process.env, env);
  process.chdir(cwd);
  return () => {
    process.chdir(previousCwd);
    for (const key of Object.keys(process.env)) delete process.env[key];
    Object.assign(process.env, previous);
  };
}
async function withTarget(target, timezone, fn) {
  if (!target.scopeOptions) {
    // Isolated homes are disposable; their scanner cache must survive a request.
    // Retain the existing userHome cache/retained history without migrating it.
    // Prepare it before allocating a home, so failed setup cannot leak a home
    // when the history phase retries this target.
    let scannerCache;
    if (target.pathRole !== 'userHome' && target.cacheDirectory) {
      const identity = createHash('sha256').update(JSON.stringify([
        target.pathRole, target.root, target.providerIds
      ])).digest('hex');
      const cache = path.join(target.cacheDirectory, 'scanner-v1', identity);
      fs.mkdirSync(cache, { recursive: true, mode: 0o700 });
      const cacheStat = fs.lstatSync(cache);
      if (!cacheStat.isDirectory() || cacheStat.isSymbolicLink()) {
        throw new Error('invalid-scanner-cache');
      }
      scannerCache = cache;
    }
    target.temporaryHome = target.pathRole !== 'userHome'
      ? fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'token-monitor-next-scope-'))) : null;
    const homeDir = target.temporaryHome || target.root;
    const env = scopedEnvironment(homeDir, target.pathRole === 'codexHome' ? target.root : null, timezone);
    if (scannerCache) env.TOKSCALE_CONFIG_DIR = scannerCache;
    target.scopeOptions = { homeDir, env, cwdDir: homeDir,
      ...(target.pathRole === 'logRoot' ? { customScanPaths: { [target.providerIds[0]]: [target.root] } } : {}) };
  }
  const options = target.scopeOptions;
  const restore = enter(options.env, options.cwdDir);
  try { return await fn(options); } finally { restore(); }
}
function disposeTarget(target) {
  if (target.temporaryHome) fs.rmSync(target.temporaryHome, { recursive: true, force: true });
  delete target.scopeOptions;
  delete target.temporaryHome;
}
function withEnvironmentSync(env, cwd, fn) {
  const restore = enter(env, cwd);
  try { return fn(); } finally { restore(); }
}
module.exports = { scopedEnvironment, withTarget, withEnvironmentSync, disposeTarget };
