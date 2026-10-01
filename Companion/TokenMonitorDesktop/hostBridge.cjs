'use strict';

const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');

const MAX_REQUEST_BYTES = 4096;
const VIEWS = new Set(['home', 'tool', 'status', 'device', 'model', 'project', 'session', 'limits', 'trends']);
const COMMANDS = new Set(['showDashboard', 'showHome', 'showSettings', 'showView', 'status', 'quit']);
const HOST_COMMANDS = new Set(['openWorkbench', 'openAccounts', 'openTasks', 'openSettings', 'openEdgeDockSettings', 'checkForUpdates', 'quitHost', 'switchCodexAccount', 'getManagedCodexAccounts']);
const SETTINGS_SECTIONS = new Set(['menuBar', 'floatingBubble']);
const EMBEDDED_ENV = new Set([
  'AIGOODBRO_TOKEN_MONITOR_EMBEDDED', 'AIGOODBRO_TOKEN_MONITOR_USER_DATA',
  'AIGOODBRO_TOKEN_MONITOR_SOCKET', 'AIGOODBRO_TOKEN_MONITOR_HOST_SOCKET',
  'AIGOODBRO_TOKEN_MONITOR_PARENT_PID', 'AIGOODBRO_TOKEN_MONITOR_LANGUAGE',
  'TOKEN_MONITOR_SHARED_DIR', 'TOKEN_MONITOR_DEVICE_ID'
]);

function embeddedLaunchMode(env) {
  const keys = Object.keys(env).filter((key) => key.startsWith('AIGOODBRO_TOKEN_MONITOR_')
    || key === 'TOKEN_MONITOR_SHARED_DIR' || key === 'TOKEN_MONITOR_DEVICE_ID');
  if (keys.length === 0) return 'direct-open';
  if (env.AIGOODBRO_TOKEN_MONITOR_EMBEDDED !== '1' || keys.some((key) => !EMBEDDED_ENV.has(key))) return 'reject';
  return 'embedded';
}

function parentHostForDirectOpen(executable) {
  if (typeof executable !== 'string' || !path.isAbsolute(executable)) return null;
  const helper = path.resolve(path.dirname(executable), '../..');
  const host = path.resolve(helper, '../../..');
  if (executable !== path.join(helper, 'Contents/MacOS/AiGoodBro Token Core')
    || helper !== path.join(host, 'Contents/Helpers/AiGoodBro Token Core.app')
    || path.basename(host) !== 'AiGoodBro.app') return null;
  try {
    if (fs.realpathSync(executable) !== executable || fs.realpathSync(host) !== host) return null;
    const plist = path.join(host, 'Contents/Info.plist');
    const helperPlist = path.join(helper, 'Contents/Info.plist');
    for (const file of [plist, helperPlist]) {
      const stat = fs.lstatSync(file);
      if (!stat.isFile() || stat.isSymbolicLink()) return null;
    }
    const value = (file, key) => execFileSync('/usr/libexec/PlistBuddy', ['-c', `Print :${key}`, file], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 1000
    }).trim();
    if (value(plist, 'CFBundleIdentifier') !== 'com.blackielf.codex-account-manager-next'
      || value(plist, 'CFBundleExecutable') !== 'AiGoodBro'
      || value(helperPlist, 'CFBundleIdentifier') !== 'com.blackielf.codex-account-manager-next.token-core'
      || value(helperPlist, 'CFBundleExecutable') !== 'AiGoodBro Token Core') return null;
    fs.accessSync(path.join(host, 'Contents/MacOS/AiGoodBro'), fs.constants.X_OK);
    return host;
  } catch (_) { return null; }
}

function nativeParentMatches(parentPID, host, readProcessPath = (pid) => execFileSync('/bin/ps', [
  '-p', String(pid), '-o', 'comm='
], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 1000 }).trim()) {
  if (!Number.isSafeInteger(parentPID) || parentPID <= 1 || !host) return false;
  try {
    return fs.realpathSync(readProcessPath(parentPID)) === fs.realpathSync(path.join(host, 'Contents/MacOS/AiGoodBro'));
  } catch (_) { return false; }
}

function validatePrivateSocketPath(socketPath) {
  if (typeof socketPath !== 'string' || !path.isAbsolute(socketPath) || socketPath.includes('\0')) {
    throw new Error('A private absolute Unix socket path is required');
  }
  // macOS sockaddr_un.sun_path has 104 bytes including its trailing NUL.
  if (Buffer.byteLength(socketPath) > 103) throw new Error('Unix socket path is too long for macOS');
  const directory = path.dirname(socketPath);
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('Socket directory must be a real directory');
  if ((stat.mode & 0o077) !== 0) throw new Error('Socket directory must be private (0700)');
  if (typeof process.getuid === 'function' && stat.uid !== process.getuid()) {
    throw new Error('Socket directory must belong to the current user');
  }
  if (fs.existsSync(socketPath)) throw new Error('Unix socket path already exists');
  return socketPath;
}

function validateHostSocketPath(socketPath) {
  if (typeof socketPath !== 'string' || !path.isAbsolute(socketPath) || Buffer.byteLength(socketPath) > 103) {
    throw new Error('Host socket path is invalid');
  }
  const directory = fs.lstatSync(path.dirname(socketPath));
  const socket = fs.lstatSync(socketPath);
  const uid = typeof process.getuid === 'function' ? process.getuid() : null;
  if (!directory.isDirectory() || directory.isSymbolicLink() || (directory.mode & 0o077) !== 0
    || (uid !== null && directory.uid !== uid)
    || !socket.isSocket() || socket.isSymbolicLink() || (socket.mode & 0o077) !== 0
    || (uid !== null && socket.uid !== uid)) {
    throw new Error('Host socket is not private');
  }
  return socketPath;
}

function parseRequest(line) {
  let request;
  try { request = JSON.parse(line); }
  catch (_) { throw new Error('invalid-json'); }
  if (!request || typeof request !== 'object' || Array.isArray(request)) throw new Error('invalid-request');
  if (typeof request.id !== 'string' || !/^[A-Za-z0-9._-]{1,64}$/.test(request.id)) {
    throw new Error('invalid-id');
  }
  if (typeof request.cmd !== 'string' || !COMMANDS.has(request.cmd)) throw new Error('invalid-command');
  const keys = Object.keys(request);
  const allowed = request.cmd === 'showView' ? new Set(['id', 'cmd', 'view'])
    : request.cmd === 'showSettings' ? new Set(['id', 'cmd', 'section']) : new Set(['id', 'cmd']);
  if (keys.some((key) => !allowed.has(key))) throw new Error('unexpected-field');
  if (request.cmd === 'showView' && !VIEWS.has(request.view)) throw new Error('invalid-view');
  if (request.cmd === 'showSettings' && request.section !== undefined && !SETTINGS_SECTIONS.has(request.section)) throw new Error('invalid-section');
  return request;
}

function createHostBridge({ socketPath, hostSocketPath = null, app, logger = () => {} }) {
  if (!app || typeof app.quit !== 'function' || typeof app.getVersion !== 'function') {
    throw new Error('Electron app is required');
  }
  validatePrivateSocketPath(socketPath);
  let routes = null;
  let server = null;
  let socketIdentity = null;
  let closed = false;

  function status() {
    let allTimeCostUsd = null;
    try {
      const cost = routes?.getAllTimeCostUsd?.();
      if (typeof cost === 'number' && Number.isFinite(cost) && cost >= 0) allTimeCostUsd = cost;
    } catch (_) {}
    return {
      ready: routes !== null,
      trayVisible: routes !== null && typeof routes.isTrayVisible === 'function' && routes.isTrayVisible() === true,
      pid: process.pid,
      version: app.getVersion(),
      allTimeCostUsd
    };
  }

  function reply(socket, payload, afterWrite) {
    if (socket.destroyed) return;
    socket.end(`${JSON.stringify(payload)}\n`, afterWrite);
  }

  async function dispatch(request, socket) {
    const { id, cmd } = request;
    if (cmd === 'status') return reply(socket, { id, ok: true, ...status() });
    if (!routes) return reply(socket, { id, ok: false, error: 'not-ready' });
    try {
      if (cmd === 'showDashboard') await routes.showDashboard();
      else if (cmd === 'showHome') await routes.showView('home');
      else if (cmd === 'showSettings') await routes.showSettings(request.section);
      else if (cmd === 'showView') await routes.showView(request.view);
      else if (cmd === 'quit') {
        return reply(socket, { id, ok: true }, () => { setImmediate(() => routes.quit()); });
      }
      return reply(socket, { id, ok: true });
    } catch (_) {
      logger('Host route failed');
      return reply(socket, { id, ok: false, error: 'route-failed' });
    }
  }

  function accept(socket) {
    let buffer = Buffer.alloc(0);
    let handled = false;
    socket.setTimeout(10000, () => socket.destroy());
    socket.on('data', (chunk) => {
      if (handled) return;
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length > MAX_REQUEST_BYTES) {
        handled = true;
        return reply(socket, { id: null, ok: false, error: 'request-too-large' });
      }
      const lineEnd = buffer.indexOf(10);
      if (lineEnd < 0) return;
      handled = true;
      if (buffer.subarray(lineEnd + 1).some((byte) => byte !== 10 && byte !== 13)) {
        return reply(socket, { id: null, ok: false, error: 'multiple-requests' });
      }
      let request;
      try { request = parseRequest(buffer.subarray(0, lineEnd).toString('utf8')); }
      catch (error) { return reply(socket, { id: null, ok: false, error: error.message }); }
      void dispatch(request, socket);
    });
    socket.on('error', () => {});
  }

  async function start() {
    if (closed || server) throw new Error('Host bridge cannot start twice');
    validatePrivateSocketPath(socketPath);
    server = net.createServer(accept);
    try {
      await new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(socketPath, () => {
          server.removeListener('error', reject);
          resolve();
        });
      });
      fs.chmodSync(socketPath, 0o600);
      const stat = fs.lstatSync(socketPath);
      if (!stat.isSocket()) throw new Error('Host bridge did not create a Unix socket');
      socketIdentity = { dev: stat.dev, ino: stat.ino };
      server.on('error', (error) => logger(`Host bridge socket error: ${error.code || 'unknown'}`));
      return status();
    } catch (error) {
      server.close();
      server = null;
      throw error;
    }
  }

  function bind(nextRoutes) {
    if (routes) throw new Error('Host routes are already bound');
    for (const key of ['showDashboard', 'showView', 'showSettings', 'quit']) {
      if (typeof nextRoutes?.[key] !== 'function') throw new Error(`Missing host route ${key}`);
    }
    routes = Object.freeze({ ...nextRoutes });
  }

  function close() {
    if (closed) return;
    closed = true;
    server?.close();
    server = null;
    if (!socketIdentity) return;
    try {
      const stat = fs.lstatSync(socketPath);
      if (stat.isSocket() && stat.dev === socketIdentity.dev && stat.ino === socketIdentity.ino) {
        fs.unlinkSync(socketPath);
      }
    } catch (error) {
      if (error.code !== 'ENOENT') logger(`Host bridge cleanup failed: ${error.code || 'unknown'}`);
    }
  }

  function requestHost(command, payload = {}, timeoutMs = 3000) {
    if (!hostSocketPath || !HOST_COMMANDS.has(command)) {
      return Promise.resolve({ ok: false, error: 'native-host-unavailable' });
    }
    try { validateHostSocketPath(hostSocketPath); }
    catch (_) { return Promise.resolve({ ok: false, error: 'native-host-unavailable' }); }
    const id = crypto.randomUUID();
    return new Promise((resolve) => {
      const socket = net.createConnection(hostSocketPath);
      let settled = false;
      let buffer = Buffer.alloc(0);
      const finish = (value) => {
        if (settled) return;
        settled = true;
        socket.destroy();
        resolve(value);
      };
      socket.setTimeout(timeoutMs, () => finish({ ok: false, error: 'native-host-timeout' }));
      socket.on('connect', () => socket.write(`${JSON.stringify({ id, cmd: command, ...payload })}\n`));
      socket.on('data', (chunk) => {
        buffer = Buffer.concat([buffer, chunk]);
        const maxReplyBytes = command === 'getManagedCodexAccounts' ? 262144 : 8192;
        if (buffer.length > maxReplyBytes) return finish({ ok: false, error: 'native-host-invalid-reply' });
        const end = buffer.indexOf(10);
        if (end < 0) return;
        try {
          const reply = JSON.parse(buffer.subarray(0, end).toString('utf8'));
          if (reply?.id !== id || typeof reply.ok !== 'boolean') throw new Error('invalid-reply');
          finish(reply.ok
            ? command === 'getManagedCodexAccounts'
              ? { ok: true, accounts: Array.isArray(reply.accounts) ? reply.accounts : null }
              : { ok: true, accountId: typeof reply.accountId === 'string' ? reply.accountId : null }
            : { ok: false, error: reply.error === 'operation-in-progress' ? 'operation-in-progress' : 'AiGoodBro declined this action.' });
        } catch (_) { finish({ ok: false, error: 'native-host-invalid-reply' }); }
      });
      socket.on('error', () => finish({ ok: false, error: 'native-host-unavailable' }));
      socket.on('end', () => finish({ ok: false, error: 'native-host-invalid-reply' }));
    });
  }

  function requestCodexSwitch({ vendorAccountId, recordedAccountKey }) {
    if (typeof vendorAccountId !== 'string' || !/^[A-Za-z0-9._-]{1,100}$/.test(vendorAccountId)
      || typeof recordedAccountKey !== 'string' || !/^sha256:[0-9a-f]{64}$/.test(recordedAccountKey)) {
      return Promise.resolve({ ok: false, error: 'Codex account identity is unavailable.' });
    }
    if (!hostSocketPath) return Promise.resolve({ ok: false, error: 'AiGoodBro account switch bridge is unavailable.' });
    return requestHost('switchCodexAccount', { vendorAccountId, recordedAccountKey }, 240000);
  }

  return { start, bind, close, status, requestHost, requestCodexSwitch };
}

module.exports = { createHostBridge, parseRequest, validatePrivateSocketPath, validateHostSocketPath, embeddedLaunchMode, parentHostForDirectOpen, nativeParentMatches, VIEWS };
