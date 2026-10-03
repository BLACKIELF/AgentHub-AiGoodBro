'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { createHostBridge, embeddedLaunchMode, parentHostForDirectOpen, nativeParentMatches } = require('./hostBridge.cjs');

function requiredAbsolutePath(name) {
  const value = process.env[name];
  if (typeof value !== 'string' || !path.isAbsolute(value) || value.includes('\0')) {
    throw new Error(`${name} must be an absolute path`);
  }
  return value;
}

if (!process.versions.electron) {
  process.exit(1);
} else {
  const { app } = require('electron');
  const mode = embeddedLaunchMode(process.env);
  if (mode === 'direct-open') {
    // Launch Services may reopen the nested helper itself after login or a
    // Finder click. Only the exact helper inside its matching parent app may
    // hand that action back to AiGoodBro; it never starts collectors here.
    const host = parentHostForDirectOpen(process.execPath);
    const result = host && spawnSync('/usr/bin/open', ['-a', host], { timeout: 5000, stdio: 'ignore' });
    app.exit(result?.status === 0 ? 0 : 1);
  } else if (mode === 'reject') {
    app.exit(1);
  } else {
    try {
      const userData = requiredAbsolutePath('AIGOODBRO_TOKEN_MONITOR_USER_DATA');
      const socketPath = requiredAbsolutePath('AIGOODBRO_TOKEN_MONITOR_SOCKET');
      const hostSocketPath = requiredAbsolutePath('AIGOODBRO_TOKEN_MONITOR_HOST_SOCKET');
      const sharedDir = requiredAbsolutePath('TOKEN_MONITOR_SHARED_DIR');
      const parentPID = Number(process.env.AIGOODBRO_TOKEN_MONITOR_PARENT_PID);
      if (!Number.isSafeInteger(parentPID) || parentPID <= 1 || process.ppid !== parentPID) {
        throw new Error('Native parent mismatch');
      }
      const host = parentHostForDirectOpen(process.execPath);
      if (!nativeParentMatches(parentPID, host)) throw new Error('Native parent executable mismatch');
      if (!/^[a-z0-9_-]{1,100}$/.test(process.env.TOKEN_MONITOR_DEVICE_ID || '')) {
        throw new Error('Invalid device ID');
      }
      for (const directory of [userData, sharedDir]) {
        const stat = fs.lstatSync(directory);
        if (!stat.isDirectory() || stat.isSymbolicLink() || (stat.mode & 0o077) !== 0
          || (typeof process.getuid === 'function' && stat.uid !== process.getuid())) {
          throw new Error('Private data directory mismatch');
        }
      }
      app.setPath('userData', userData);
      const bridge = createHostBridge({ socketPath, hostSocketPath, app, logger: (message) => console.warn(`[aigoodbro-desktop] ${message}`) });
      globalThis.__AIGOODBRO_TOKEN_MONITOR_BRIDGE__ = bridge;
      const parentWatch = setInterval(() => {
        if (process.ppid !== parentPID) app.quit();
      }, 3000);
      parentWatch.unref();
      app.once('before-quit', () => { clearInterval(parentWatch); bridge.close(); });

      // Keep the upstream tree at its original relative path in the package.
      const packagedMain = path.resolve(__dirname, '..', 'src', 'electron', 'main.js');
      const sourceMain = path.resolve(__dirname, '..', 'TokenMonitorEngine', 'upstream', 'src', 'electron', 'main.js');
      const upstreamMain = fs.existsSync(packagedMain) ? packagedMain : sourceMain;
      if (!fs.existsSync(upstreamMain)) throw new Error('Embedded upstream main.js is missing');
      bridge.start().then(() => { require(upstreamMain); }).catch((error) => {
        console.error(`[aigoodbro-desktop] Could not start private control socket: ${error.code || 'unavailable'}`);
        bridge.close();
        app.exit(1);
      });
    } catch (_) {
      // Malformed or spoofed launch data never creates a renderer or user-data path.
      app.exit(1);
    }
  }
}
