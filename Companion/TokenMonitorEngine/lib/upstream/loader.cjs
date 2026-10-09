'use strict';

const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const { createHash } = require('node:crypto');

const { upstreamRoot, upstreamModule } = require('./paths.cjs');
const { installVendorResolver, VENDOR_PACKAGES, VENDOR_ROOT } = require('./vendor.cjs');
const capabilities = require('./capabilities.cjs');
const descendants = require('../runtime/descendants.cjs');

const HOOKS_DIR = path.resolve(__dirname, '..', '..', 'hooks');

// The complete set of capability overlays. Each entry replaces one upstream
// module in the require cache before the collector graph is loaded. Listed in
// hooks/manifest.json with the upstream sha256 each overlay was written against.
const OVERLAYS = Object.freeze([
  { id: 'cursor-self-sync', overlay: 'cursor-self-sync.cjs', upstreamFile: 'shared/providers/cursor/selfSync.js' },
  { id: 'antigravity-self-sync', overlay: 'antigravity-self-sync.cjs', upstreamFile: 'shared/providers/antigravity/selfSync.js' },
  { id: 'limits-provider-helpers', overlay: 'limits-provider-helpers.cjs', upstreamFile: 'shared/limits/providerHelpers.js' }
]);

const EXPECTED_COMMIT = '5d2db368d8313415763860d594de00e46a663418';
const EXPECTED_REPOSITORY = 'Javis603/token-monitor';

let prepared = false;
let preparedState = null;

function resolveUpstreamModule(relativeFromSrc) {
  return require.resolve(upstreamModule(relativeFromSrc));
}

// Installs an overlay in place of an upstream module.
//
// The cache key is the upstream file's resolved path, so every upstream
// importer gets the overlay. The holder's own filename/paths point at the
// overlay file so the overlay's relative requires resolve from engine/hooks/.
// Module.prototype.load() would overwrite the filename with the path it is
// handed, which is why the compile is driven directly instead.
function seedOverlay(entry) {
  const resolved = resolveUpstreamModule(entry.upstreamFile);
  if (!fs.existsSync(resolved)) return { id: entry.id, applied: false, reason: 'upstream_file_missing' };
  const overlayPath = path.join(HOOKS_DIR, entry.overlay);
  if (!fs.existsSync(overlayPath)) return { id: entry.id, applied: false, reason: 'overlay_missing' };
  const holder = new Module(resolved, null);
  holder.filename = overlayPath;
  holder.paths = Module._nodeModulePaths(path.dirname(overlayPath));
  require.cache[resolved] = holder;
  const extension = Module._extensions[path.extname(overlayPath)] || Module._extensions['.js'];
  extension(holder, overlayPath);
  holder.loaded = true;
  return { id: entry.id, applied: true, upstreamFile: entry.upstreamFile, overlay: path.relative(HOOKS_DIR, overlayPath) };
}

function readProvenance() {
  const provenancePath = path.resolve(__dirname, '..', '..', 'provenance.json');
  let version = null;
  try {
    version = JSON.parse(fs.readFileSync(path.join(upstreamRoot(), 'package.json'), 'utf8')).version || null;
  } catch (_) {
    version = null;
  }
  let recorded = null;
  try {
    recorded = JSON.parse(fs.readFileSync(provenancePath, 'utf8'));
  } catch (_) {
    recorded = null;
  }
  return {
    repository: recorded?.repository || EXPECTED_REPOSITORY,
    commit: recorded?.commit || EXPECTED_COMMIT,
    version: version || recorded?.version || 'unknown',
    pinned: (recorded?.commit || EXPECTED_COMMIT) === EXPECTED_COMMIT,
    expectedCommit: EXPECTED_COMMIT
  };
}

// Idempotent: installs the vendor resolver and the capability overlays, then
// reports what was applied. Safe to call more than once.
function prepare() {
  if (prepared) return preparedState;
  installVendorResolver();
  // Must precede the first upstream require: upstream modules destructure
  // child_process.spawn at load time and would otherwise capture the original,
  // leaving descendants untracked and unkillable on cancel.
  descendants.install();
  const applied = OVERLAYS.map(seedOverlay);
  const missing = applied.filter((entry) => !entry.applied);
  if (missing.length > 0) {
    // A missing overlay means an upstream file moved or was renamed. Failing
    // loudly beats silently running the collector with self-sync and credential
    // refresh live when the caller asked for them off.
    const error = new Error(`capability overlay could not be applied: ${missing.map((m) => m.id).join(',')}`);
    error.code = 'HOOK_APPLY_FAILED';
    throw error;
  }
  preparedState = { overlays: applied, vendorPackages: VENDOR_PACKAGES, provenance: readProvenance() };
  prepared = true;
  return preparedState;
}

let catalog = null;
let loaded = null;

// Source validation needs the upstream client id set, and nothing else. Loaded
// separately from load() so a request that fails validation never pulls the
// whole collector graph in.
function loadCatalog() {
  prepare();
  if (catalog) return catalog;
  const clientCatalog = require(resolveUpstreamModule('shared/clientCatalog.js'));
  const clientTracking = require(resolveUpstreamModule('shared/clientTracking.js'));
  const knownClientIds = new Set(
    String(clientTracking.KNOWN_CLIENTS || '').split(',').map((entry) => entry.trim()).filter(Boolean)
  );
  for (const client of clientCatalog.CLIENT_CATALOG || []) {
    if (client && typeof client.id === 'string') knownClientIds.add(client.id);
  }
  catalog = { clientCatalog, clientTracking, knownClientIds,
    customPaths: require(resolveUpstreamModule('shared/customScanPaths.js')),
    collector: loadCollector() }; 
  return catalog;
}

let usageModules = null;
let limitsModules = null;

// Split on purpose. Upstream's module graph is large — the provider limits
// table alone pulls in ~25 provider modules and costs seconds on a cold
// process — and a collectUsage request never touches it. Loading the halves
// separately keeps the common operation from paying for the other one.
function loadCollector() {
  // Expose the pinned original private runners, without rewriting their bodies.
  const filename = resolveUpstreamModule('shared/collector.js');
  if (require.cache[filename]?.exports.bridgeRunGraph) return require.cache[filename].exports;
  const binding = JSON.parse(fs.readFileSync(path.join(HOOKS_DIR, 'manifest.json'), 'utf8')).collectorBindings;
  for (const pin of [binding]) {
    const file = path.join(upstreamRoot(), pin.upstreamFile);
    if (createHash('sha256').update(fs.readFileSync(file)).digest('hex') !== pin.upstreamSha256) {
      throw new Error('collector-binding-pin-mismatch');
    }
  }
  const mod = new Module(filename, module);
  mod.filename = filename;
  mod.bridgeVendorRoot = VENDOR_ROOT;
  mod.paths = Module._nodeModulePaths(path.dirname(filename));
  require.cache[filename] = mod;
  mod._compile(fs.readFileSync(filename, 'utf8') + '\n' + fs.readFileSync(path.join(HOOKS_DIR, 'collector-bindings.cjs'), 'utf8'), filename);
  mod.loaded = true;
  return mod.exports;
}

function loadUsage() {
  prepare();
  if (usageModules) return usageModules;
  usageModules = {
    collector: loadCollector(),
    usage: require(resolveUpstreamModule('shared/usage.js')),
    history: require(resolveUpstreamModule('shared/history.js')),
    clientCatalog: require(resolveUpstreamModule('shared/clientCatalog.js'))
  };
  return usageModules;
}

function loadLimits() {
  prepare();
  if (limitsModules) return limitsModules;
  limitsModules = {
    limitsCollector: require(resolveUpstreamModule('shared/limits/collector.js')),
    limitsRuntime: require(resolveUpstreamModule('shared/limits/runtime.js')),
    limitsCore: require(resolveUpstreamModule('shared/limits/core.js')),
    limitProviders: require(resolveUpstreamModule('shared/limits/providers.js'))
  };
  return limitsModules;
}

function load() {
  const state = prepare();
  if (loaded) return loaded;
  loaded = {
    ...loadUsage(),
    ...loadLimits(),
    overlayState: state
  };
  return loaded;
}

function describeEngine() {
  const state = prepare();
  return {
    repository: state.provenance.repository,
    commit: state.provenance.commit,
    version: state.provenance.version,
    pinned: state.provenance.pinned,
    hooks: state.overlays.map((entry) => entry.id),
    vendorPackages: state.vendorPackages.slice()
  };
}

module.exports = {
  EXPECTED_COMMIT,
  EXPECTED_REPOSITORY,
  OVERLAYS,
  prepare,
  load,
  loadUsage,
  loadLimits,
  loadCatalog,
  describeEngine,
  readProvenance,
  capabilities
};
