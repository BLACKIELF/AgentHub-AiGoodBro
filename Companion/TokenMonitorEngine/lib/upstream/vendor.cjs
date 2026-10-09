'use strict';

const path = require('node:path');
const Module = require('node:module');

// The pinned upstream checkout has no node_modules. Instead of installing a
// full upstream dependency tree (electron, electron-updater, discord-rpc, ...)
// the engine ships exactly the closure its collect/limits call paths touch, at
// the exact versions recorded in the pinned upstream package-lock.json, and
// resolves those bare specifiers here.
//
// This is a resolution hook, not a stub: the packages are the real published
// modules. Nothing is faked and nothing is silently absent — VENDOR_PACKAGES is
// the complete list of bare specifiers reachable from src/shared during a
// bridge request, and vendor/manifest.json records the installed tree so a
// packaging step can verify it without guessing.

const VENDOR_ROOT = path.resolve(__dirname, '..', '..', 'vendor', 'node_modules');

// Reachability, established by walking src/shared requires:
//   semver   top-level require in shared/collector.js (version comparisons)
//   dotenv   lazy require in shared/config.js loadDotEnv()
//   chokidar lazy require in shared/watcherHost.js createInProcessWatcherHost()
//   undici   top-level require in shared/outboundFetch.js
//   koffi    guarded lazy require in shared/providers/claude/limits.js (Windows
//            credential store); absent on non-Windows is the upstream behaviour
//   tokscale shared/collector.js resolves 'tokscale/bin.js' at module load, and
//            the tokscale launcher is what runs a real scan
const VENDOR_PACKAGES = Object.freeze([
  'semver',
  'dotenv',
  'chokidar',
  'undici',
  'koffi',
  'tokscale'
]);

// Scoped platform binaries. The launcher resolves these lazily per platform
// inside a try/catch, so only the host's package needs to be present.
const VENDOR_SCOPES = Object.freeze(['@tokscale/']);

const VENDOR_SET = new Set(VENDOR_PACKAGES);

// Maps a request string to the package it belongs to, so a subpath require
// ('tokscale/bin.js') or a scoped package require is redirected as a whole.
function vendorPackageFor(request) {
  if (VENDOR_SET.has(request)) return request;
  for (const name of VENDOR_PACKAGES) {
    if (request.startsWith(`${name}/`)) return name;
  }
  for (const scope of VENDOR_SCOPES) {
    if (request.startsWith(scope)) {
      const parts = request.split('/');
      if (parts.length >= 2 && parts[1]) return `${parts[0]}/${parts[1]}`;
    }
  }
  return null;
}

let installed = false;

// Patches resolution rather than load, because the upstream collector calls
// require.resolve('tokscale/bin.js') at module load and that path never goes
// through Module._load.
function installVendorResolver() {
  if (installed) return VENDOR_ROOT;
  const originalResolve = Module._resolveFilename;
  Module._resolveFilename = function resolveFilename(request, parent, isMain, options) {
    const pkg = vendorPackageFor(request);
    if (pkg) {
      return originalResolve.call(this, path.join(VENDOR_ROOT, request), parent, isMain, options);
    }
    return originalResolve.call(this, request, parent, isMain, options);
  };
  installed = true;
  return VENDOR_ROOT;
}

// Load a module by absolute path without consulting (or populating) the shared
// require cache for the top-level file. Used by the capability overlays: the
// overlay needs the real implementation of the module it is replacing, and
// require() would hand back the overlay itself.
function loadFresh(absolutePath) {
  const mod = new Module(absolutePath, null);
  mod.filename = absolutePath;
  mod.paths = Module._nodeModulePaths(path.dirname(absolutePath));
  mod.load(absolutePath);
  return mod.exports;
}

module.exports = {
  VENDOR_ROOT,
  VENDOR_PACKAGES,
  VENDOR_SCOPES,
  vendorPackageFor,
  installVendorResolver,
  loadFresh
};
