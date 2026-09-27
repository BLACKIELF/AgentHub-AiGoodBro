'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');
const { createHostBridge, parseRequest, embeddedLaunchMode, parentHostForDirectOpen, nativeParentMatches } = require('../hostBridge.cjs');
const { INPUT_SHA256, transformStage } = require('../transform-stage.cjs');
const { spawnSync } = require('node:child_process');

const companionRoot = path.resolve(__dirname, '..', '..');
const upstreamRoot = path.join(companionRoot, 'TokenMonitorEngine', 'upstream');

function writePlist(file, bundleID, executable) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${bundleID}</string>
<key>CFBundleExecutable</key><string>${executable}</string>
</dict></plist>`);
}

function runBootstrap({ env, execPath, ppid = 4321 }) {
  const calls = { exit: [], opened: [], setPath: [], bridgeStarted: 0, upstreamLoaded: 0 };
  const app = {
    exit: (code) => calls.exit.push(code), setPath: (...args) => calls.setPath.push(args),
    once() {}, quit() {}, getVersion: () => '0.62.0'
  };
  const bridge = {
    start: async () => { calls.bridgeStarted += 1; }, close() {}
  };
  const bootstrap = path.join(companionRoot, 'TokenMonitorDesktop', 'bootstrap.cjs');
  const source = fs.readFileSync(bootstrap, 'utf8');
  const context = {
    __dirname: path.dirname(bootstrap), console, globalThis: {},
    process: { versions: { electron: 'test' }, env, execPath, ppid, getuid: process.getuid },
    setInterval: () => ({ unref() {} }), clearInterval() {},
    require: (name) => {
      if (name === 'electron') return { app };
      if (name === 'node:child_process') return { spawnSync: (command, args) => {
        calls.opened.push({ command, args });
        return { status: 0 };
      } };
      if (name === './hostBridge.cjs') return {
        embeddedLaunchMode, parentHostForDirectOpen, nativeParentMatches: () => true,
        createHostBridge: () => bridge
      };
      if (name.endsWith('/src/electron/main.js')) {
        calls.upstreamLoaded += 1;
        return {};
      }
      return require(name);
    }
  };
  vm.runInNewContext(source, context, { filename: bootstrap });
  return calls;
}

test('direct helper open activates only its verified parent bundle, without starting upstream', () => {
  const root = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'agb-helper-open-'));
  try {
    const host = path.join(root, 'AiGoodBro.app');
    const helper = path.join(host, 'Contents/Helpers/AiGoodBro Token Core.app');
    const executable = path.join(helper, 'Contents/MacOS/AiGoodBro Token Core');
    const hostExecutable = path.join(host, 'Contents/MacOS/AiGoodBro');
    for (const file of [executable, hostExecutable]) {
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, 'fixture');
      fs.chmodSync(file, 0o755);
    }
    writePlist(path.join(host, 'Contents/Info.plist'), 'com.blackielf.codex-account-manager-next', 'AiGoodBro');
    writePlist(path.join(helper, 'Contents/Info.plist'), 'com.blackielf.codex-account-manager-next.token-core', 'AiGoodBro Token Core');
    assert.equal(parentHostForDirectOpen(executable), host);
    assert.equal(nativeParentMatches(4321, host, () => hostExecutable), true);
    assert.equal(nativeParentMatches(4321, host, () => '/bin/sh'), false);
    const direct = runBootstrap({ env: {}, execPath: executable });
    assert.equal(direct.opened.length, 1);
    assert.equal(direct.opened[0].command, '/usr/bin/open');
    assert.deepEqual(Array.from(direct.opened[0].args), ['-a', host]);
    assert.deepEqual(direct.exit, [0]);
    assert.equal(direct.upstreamLoaded, 0);

    const forged = runBootstrap({ env: { AIGOODBRO_TOKEN_MONITOR_EMBEDDED: '0' }, execPath: executable });
    assert.equal(forged.opened.length, 0);
    assert.equal(forged.upstreamLoaded, 0);
    assert.deepEqual(forged.exit, [1]);
    assert.equal(embeddedLaunchMode({ AIGOODBRO_TOKEN_MONITOR_FUTURE: '1' }), 'reject');

    writePlist(path.join(host, 'Contents/Info.plist'), 'invalid.bundle.id', 'AiGoodBro');
    const wrongParent = runBootstrap({ env: {}, execPath: executable });
    assert.equal(wrongParent.opened.length, 0);
    assert.equal(wrongParent.upstreamLoaded, 0);
    assert.deepEqual(wrongParent.exit, [1]);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test('trusted host launch keeps private paths and parent PID checks', async () => {
  const root = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'agb-helper-trusted-'));
  try {
    const support = path.join(root, 'support');
    const shared = path.join(support, 'shared');
    const ipc = path.join(root, 'ipc');
    for (const directory of [support, shared, ipc]) {
      fs.mkdirSync(directory, { recursive: true });
      fs.chmodSync(directory, 0o700);
    }
    const env = {
      AIGOODBRO_TOKEN_MONITOR_EMBEDDED: '1',
      AIGOODBRO_TOKEN_MONITOR_USER_DATA: support,
      AIGOODBRO_TOKEN_MONITOR_SOCKET: path.join(ipc, 'control.sock'),
      AIGOODBRO_TOKEN_MONITOR_HOST_SOCKET: path.join(ipc, 'host.sock'),
      TOKEN_MONITOR_SHARED_DIR: shared,
      TOKEN_MONITOR_DEVICE_ID: 'aigoodbro-test',
      AIGOODBRO_TOKEN_MONITOR_PARENT_PID: '4321'
    };
    const trusted = runBootstrap({ env, execPath: '/fixture/AiGoodBro Token Core' });
    await new Promise((resolve) => setImmediate(resolve));
    assert.deepEqual(trusted.exit, []);
    assert.equal(trusted.bridgeStarted, 1);
    assert.equal(trusted.upstreamLoaded, 1);
    assert.deepEqual(trusted.setPath, [['userData', support]]);

    const wrongParent = runBootstrap({ env, execPath: '/fixture/AiGoodBro Token Core', ppid: 9999 });
    assert.deepEqual(wrongParent.exit, [1]);
    assert.equal(wrongParent.bridgeStarted, 0);
    const missingPath = runBootstrap({ env: { ...env, TOKEN_MONITOR_SHARED_DIR: '' }, execPath: '/fixture/AiGoodBro Token Core' });
    assert.deepEqual(missingPath.exit, [1]);
    assert.equal(missingPath.upstreamLoaded, 0);
    const unknownMarker = runBootstrap({ env: { ...env, AIGOODBRO_TOKEN_MONITOR_UNKNOWN: '1' }, execPath: '/fixture/AiGoodBro Token Core' });
    assert.deepEqual(unknownMarker.exit, [1]);
    assert.equal(unknownMarker.upstreamLoaded, 0);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

function request(socketPath, body) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(socketPath);
    let received = '';
    socket.setEncoding('utf8');
    socket.on('connect', () => socket.write(`${JSON.stringify(body)}\n`));
    socket.on('data', (chunk) => { received += chunk; });
    socket.on('end', () => {
      try { resolve(JSON.parse(received.trim())); }
      catch (error) { reject(error); }
    });
    socket.on('error', reject);
  });
}

test('private control socket routes only allowlisted requests after upstream is ready', async (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'agb-tm-'));
  fs.chmodSync(directory, 0o700);
  const socketPath = path.join(directory, 'bridge.sock');
  const calls = [];
  const bridge = createHostBridge({ socketPath, app: { getVersion: () => '0.62.0', quit: () => calls.push('appQuit') } });
  t.after(() => { bridge.close(); fs.rmSync(directory, { recursive: true, force: true }); });
  await bridge.start();
  assert.equal(fs.statSync(socketPath).mode & 0o777, 0o600);
  const before = await request(socketPath, { id: 'before', cmd: 'status' });
  assert.equal(before.ready, false);
  assert.equal(before.trayVisible, false);
  assert.deepEqual(await request(socketPath, { id: 'notready', cmd: 'showHome' }), { id: 'notready', ok: false, error: 'not-ready' });
  bridge.bind({
    showDashboard: () => calls.push('dashboard'),
    showView: (view) => calls.push(`view:${view}`),
    showSettings: () => calls.push('settings'),
    isTrayVisible: () => true,
    quit: () => calls.push('quit')
  });
  const ready = await request(socketPath, { id: 'ready', cmd: 'status' });
  assert.equal(ready.ready, true);
  assert.equal(ready.trayVisible, true);
  assert.equal((await request(socketPath, { id: 'dash', cmd: 'showDashboard' })).ok, true);
  assert.equal((await request(socketPath, { id: 'home', cmd: 'showHome' })).ok, true);
  assert.equal((await request(socketPath, { id: 'settings', cmd: 'showSettings' })).ok, true);
  assert.equal((await request(socketPath, { id: 'tool', cmd: 'showView', view: 'tool' })).ok, true);
  assert.deepEqual(await request(socketPath, { id: 'bad', cmd: 'showView', view: 'secret' }), { id: null, ok: false, error: 'invalid-view' });
  assert.deepEqual(await request(socketPath, { id: 'extra', cmd: 'status', token: 'x' }), { id: null, ok: false, error: 'unexpected-field' });
  assert.deepEqual(calls, ['dashboard', 'view:home', 'settings', 'view:tool']);
  assert.equal((await request(socketPath, { id: 'quit', cmd: 'quit' })).ok, true);
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(calls.at(-1), 'quit');
});

test('path and command validation fail closed', () => {
  assert.throws(() => parseRequest('{}'), /invalid-id/);
  assert.throws(() => parseRequest('{'), /invalid-json/);
  assert.throws(() => parseRequest('{"id":"ok","cmd":"switchAccount"}'), /invalid-command/);
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'agb-tm-'));
  try {
    fs.chmodSync(directory, 0o755);
    assert.throws(() => createHostBridge({ socketPath: path.join(directory, 'bridge.sock'), app: { getVersion: () => 'x', quit() {} } }), /private/);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});

test('Codex switch reaches only the private native guard socket with an opaque identity', async (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'agb-tm-host-'));
  fs.chmodSync(directory, 0o700);
  const hostSocketPath = path.join(directory, 'host.sock');
  const calls = [];
  const server = net.createServer((socket) => {
    let body = '';
    socket.setEncoding('utf8');
    socket.on('data', (chunk) => {
      body += chunk;
      if (!body.includes('\n')) return;
      const received = JSON.parse(body.slice(0, body.indexOf('\n')));
      calls.push(received);
      const reply = received.cmd === 'getManagedCodexAccounts'
        ? { id: received.id, ok: true, accounts: Array.from({ length: 24 }, (_, index) => ({
          id: `aigoodbro-${index}`, accountKey: `sha256:${String(index).padStart(64, '0')}`,
          workspaceAccountId: `workspace-${index}`, homePath: `/private/example/${index}/${'x'.repeat(280)}`,
          alias: `Account ${index}`, enabled: true
        })) }
        : { id: received.id, ok: true, accountId: received.vendorAccountId };
      socket.end(`${JSON.stringify(reply)}\n`);
    });
  });
  t.after(() => { server.close(); fs.rmSync(directory, { recursive: true, force: true }); });
  await new Promise((resolve) => server.listen(hostSocketPath, resolve));
  fs.chmodSync(hostSocketPath, 0o600);
  const bridge = createHostBridge({
    socketPath: path.join(directory, 'control.sock'), hostSocketPath,
    app: { getVersion: () => '0.62.0', quit() {} }
  });
  assert.equal((await bridge.requestCodexSwitch({ vendorAccountId: 'bad/id', recordedAccountKey: 'sha256:x' })).ok, false);
  const key = `sha256:${'a'.repeat(64)}`;
  const result = await bridge.requestCodexSwitch({ vendorAccountId: 'codex-0123456789ab', recordedAccountKey: key });
  assert.deepEqual(result, { ok: true, accountId: 'codex-0123456789ab' });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].cmd, 'switchCodexAccount');
  assert.equal(calls[0].recordedAccountKey, key);
  assert.deepEqual(Object.keys(calls[0]).sort(), ['cmd', 'id', 'recordedAccountKey', 'vendorAccountId']);
  const accounts = await bridge.requestHost('getManagedCodexAccounts');
  assert.equal(accounts.ok, true);
  assert.equal(accounts.accounts.length, 24);
  assert.deepEqual(Object.keys(calls[1]).sort(), ['cmd', 'id']);
  assert.equal(calls[1].cmd, 'getManagedCodexAccounts');
});

test('staging patch preserves vendor source and disables its independent updater', (t) => {
  const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'agb-tm-stage-'));
  t.after(() => fs.rmSync(stage, { recursive: true, force: true }));
  for (const relativePath of Object.keys(INPUT_SHA256)) {
    const target = path.join(stage, relativePath);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.copyFileSync(path.join(upstreamRoot, relativePath), target);
  }
  const changed = transformStage(stage);
  assert.equal(changed.length, Object.keys(INPUT_SHA256).length);
  const main = fs.readFileSync(path.join(stage, 'src/electron/main.js'), 'utf8');
  const discordRpc = fs.readFileSync(path.join(stage, 'src/electron/discordRpc.js'), 'utf8');
  const preload = fs.readFileSync(path.join(stage, 'src/electron/preload.js'), 'utf8');
  const updater = fs.readFileSync(path.join(stage, 'src/shared/appUpdater.js'), 'utf8');
  const index = fs.readFileSync(path.join(stage, 'src/electron/renderer/index.html'), 'utf8');
  const stagedI18nPath = path.join(stage, 'src/electron/renderer/i18n.js');
  const stagedI18n = fs.readFileSync(stagedI18nPath, 'utf8');
  const i18n = require(stagedI18nPath);
  const styles = fs.readFileSync(path.join(stage, 'src/electron/renderer/styles.css'), 'utf8');
  const rendererApp = fs.readFileSync(path.join(stage, 'src/electron/renderer/app.js'), 'utf8');
  const tray = fs.readFileSync(path.join(stage, 'src/electron/tray.js'), 'utf8');
  assert.match(main, /hostBridge\.bind\(/);
  const activationFunction = main.match(/function applyMacActivationPolicy\(state = \{\}\) \{[\s\S]*?\n\}/)?.[0];
  assert.ok(activationFunction);
  const { macActivationPolicyMode } = require(path.join(upstreamRoot, 'src/electron/trayModeSettings.js'));
  for (const embedded of [true, false]) {
    for (const visible of [true, false]) {
      const calls = [];
      const settings = { showTrayIcon: true, trayMode: false, hideAppIcon: false };
      const applyPolicy = vm.runInNewContext(`${activationFunction}; applyMacActivationPolicy;`, {
        IS_AIGOODBRO_EMBEDDED: embedded, process: { platform: 'darwin' }, settings,
        mainWindow: { isDestroyed: () => false, isVisible: () => visible }, macActivationPolicyMode,
        app: { setActivationPolicy: (mode) => calls.push(mode), dock: {
          hide: () => calls.push('hide'), show: () => calls.push('show')
        } }
      });
      applyPolicy();
      applyPolicy({ mainWindowVisible: true });
      assert.deepEqual(calls, embedded ? ['accessory', 'hide', 'accessory', 'hide']
        : [visible ? 'regular' : 'accessory', visible ? 'show' : 'hide', 'regular', 'show']);
    }
  }
  assert.match(main, /onOpenMainWindow: IS_AIGOODBRO_EMBEDDED \? \(\) => openViewFromTray\('home'\) : undefined/);
  const dockController = fs.readFileSync(path.join(stage, 'src/electron/edgeDock/controller.js'), 'utf8');
  const clickHandler = dockController.match(/ipcMain\.on\('edgeDock:click', \(event, payload\) => \{[\s\S]*?\n    \}\);/)?.[0];
  assert.ok(clickHandler);
  for (const embedded of [true, false]) {
    let onClick;
    const calls = [];
    vm.runInNewContext(clickHandler, {
      ipcMain: { on: (_channel, handler) => { onClick = handler; } },
      surfaceFor: (sender) => sender,
      cells: [{ kind: 'provider' }, { kind: 'stat', metric: 'liveRate' }],
      bubbleCell: null, alwaysVisible: () => true,
      intent: { reveal: () => 'reveal', retract: () => 'retract', focusCell: () => calls.push('focus') },
      applyEffects: (effect) => calls.push(effect), showBubble: () => calls.push('detail'),
      onToggleRateMode: () => calls.push('rate'), logger: () => {},
      onOpenMainWindow: embedded ? () => calls.push('home') : undefined
    });
    for (const payload of [{ cellIndex: null }, { cellIndex: -1 }, { cellIndex: 2 }]) {
      onClick({ sender: 'rail' }, payload);
    }
    onClick({ sender: 'untrusted' }, { cellIndex: 0 });
    assert.deepEqual(calls, []);
    onClick({ sender: 'rail' }, { cellIndex: 0 });
    assert.deepEqual(calls, embedded ? ['retract', 'home'] : ['focus', 'detail']);
    calls.length = 0;
    onClick({ sender: 'rail' }, { cellIndex: 1 });
    assert.deepEqual(calls, ['rate']);
  }
  assert.match(main, /event\.sender !== mainWindow\?\.webContents/);
  assert.match(main, /\['openWorkbench', 'openAccounts', 'openSettings', 'checkForUpdates'\]\.includes\(action\)/);
  assert.match(preload, /openAiGoodBroHost: \(action\) => ipcRenderer\.invoke\('aigoodbro:openHost', action\)/);
  assert.match(main, /isTrayVisible: \(\) => Boolean\(tray && !tray\.isDestroyed\(\)\)/);
  assert.match(main, /if \(IS_AIGOODBRO_EMBEDDED\) return deriveAppUpdateState\(\);/);
  assert.match(main, /requestCodexSwitch\(\{\s*vendorAccountId: account\.id,\s*recordedAccountKey: account\.accountKey/);
  assert.match(main, /response\.accountId !== account\.id/);
  assert.match(main, /return !IS_AIGOODBRO_EMBEDDED && macWidgetRuntimeSupport\(\{ platform, osRelease \}\)\.supported;/);
  assert.match(main, /const widgetRuntimeSupported = !IS_AIGOODBRO_EMBEDDED && widgetRuntime\.supported;/);
  assert.match(main, /reason: IS_AIGOODBRO_EMBEDDED \? 'host-widget-unavailable'/);
  assert.match(main, /await refreshAiGoodBroManagedCodexAccounts\(\);/);
  assert.match(main, /identity\.accountKey !== accountKey \|\| identity\.workspaceAccountId !== workspaceAccountId/);
  assert.match(main, /hostManaged: true, enabled: true/);
  assert.match(main, /Manage this account in AiGoodBro/);
  assert.match(main, /email: hostManaged \? hostAlias : email/);
  assert.match(main, /TRAY_OPEN_VIEW_IDS = new Set\(\['home', 'tool', 'status', 'device', 'model', 'project', 'session', 'limits', 'trends'\]\)/);
  assert.match(updater, /reason: 'managed-by-aigoodbro'/);
  assert.match(updater, /const GITHUB_REPO = 'BLACKIELF\/AgentHub-AiGoodBro'/);
  assert.match(main, /parsed\.pathname === '\/BLACKIELF\/AgentHub-AiGoodBro'/);
  assert.match(main, /parsed\.hostname === 'aigoodbro\.com'/);
  assert.match(main, /parsed\.hostname === 'claude\.ai'/);
  assert.match(main, /parsed\.pathname\.startsWith\('\/junhoyeo\/tokscale'\)/);
  const externalUrlFunction = main.match(/function isAllowedExternalUrl\(value\) \{[\s\S]*?\n\}\n\n(?=function revealWindow\()/)?.[0];
  assert.ok(externalUrlFunction);
  const isAllowedExternalUrl = vm.runInNewContext(
    `const settings = {}; const STATUS_PAGE_HOSTS = new Set(['status.openai.com']);
     const isAllowedVerificationUrl = () => false; const isAllowedCodexLoginUrl = () => false;
     ${externalUrlFunction} isAllowedExternalUrl;`,
    { URL, process: { env: {} } }
  );
  for (const url of [
    'https://aigoodbro.com/',
    'https://github.com/BLACKIELF/AgentHub-AiGoodBro',
    'https://github.com/BLACKIELF/AgentHub-AiGoodBro/issues',
    'https://github.com/BLACKIELF/AgentHub-AiGoodBro/blob/main/docs/usage-guide.md',
    'https://claude.ai/settings', 'https://status.openai.com/',
    'https://github.com/junhoyeo/tokscale'
  ]) assert.equal(isAllowedExternalUrl(url), true, url);
  for (const url of [
    'https://github.com/Javis603/token-monitor', 'https://javis-ai.com/token-monitor/',
    'https://github.com/BLACKIELF/AgentHub-AiGoodBro-fake/issues',
    'http://aigoodbro.com/', 'https://aigoodbro.com.evil.example/'
  ]) assert.equal(isAllowedExternalUrl(url), false, url);
  assert.match(index, /AiGoodBro/);
  assert.match(index, /id="aboutVersion"/);
  assert.match(index, /id="aboutEngineVersion"/);
  assert.match(index, /class="settings-subgroup maintenance-section app-update-settings aigoodbro-host-updates"/);
  for (const action of ['openWorkbench', 'openAccounts', 'openSettings', 'checkForUpdates']) {
    assert.match(index, new RegExp(`data-aigoodbro-host-action="${action}"`));
  }
  assert.match(index, /class="inline-link aigoodbro-host-update-action"[^>]*data-aigoodbro-host-action="checkForUpdates"/);
  assert.match(rendererApp, /const TOKEN_MONITOR_REPOSITORY_URL = 'https:\/\/github\.com\/BLACKIELF\/AgentHub-AiGoodBro';/);
  assert.match(rendererApp, /const TOKEN_MONITOR_ISSUES_URL = `\$\{TOKEN_MONITOR_REPOSITORY_URL\}\/issues`;/);
  assert.match(rendererApp, /const TOKEN_MONITOR_WEBSITE_URL = 'https:\/\/aigoodbro\.com\/';/);
  assert.match(rendererApp, /const TOKEN_MONITOR_WSL_SQLITE_GUIDE_URL = `\$\{TOKEN_MONITOR_REPOSITORY_URL\}\/blob\/main\/docs\/usage-guide\.md`;/);
  assert.match(discordRpc, /const GITHUB_URL = 'https:\/\/github\.com\/BLACKIELF\/AgentHub-AiGoodBro'/);
  assert.match(discordRpc, /largeImageText: 'AiGoodBro'/);
  for (const productSource of [main, updater, rendererApp, discordRpc]) {
    assert.doesNotMatch(productSource, /Javis603\/token-monitor|javis-ai\.com\/token-monitor/);
  }
  assert.match(rendererApp, /pageUrl: 'https:\/\/status\.openai\.com'/);
  assert.match(rendererApp, /https:\/\/github\.com\/junhoyeo\/tokscale/);
  assert.match(rendererApp, /window\.tokenMonitor\.openAiGoodBroHost\(button\.dataset\.aigoodbroHostAction\)/);
  assert.match(styles, /\.aigoodbro-host-navigation \{ padding: 9px 12px; border-bottom:/);
  assert.equal(i18n.translate('zh-CN', 'settings.host.accounts'), '账号与自动续做');
  assert.equal(i18n.translate('en', 'settings.host.accounts'), 'Accounts & auto-resume');
  assert.match(index, /data-i18n="settings.appUpdate.managedByHost"/);
  assert.match(styles, /\.app-update-settings\.aigoodbro-host-updates > :not\(\.settings-group-header\):not\(\.aigoodbro-managed-updates-note\):not\(\.aigoodbro-host-update-action\) \{\s*display: none !important;/);
  assert.match(rendererApp, /els\.aboutVersion\.textContent = 'v2\.0'/);
  assert.match(rendererApp, /t\('settings\.about\.embeddedEngine', \{ version: state\.appInfo\?\.version \|\| '0\.62\.0' \}\)/);
  assert.equal(i18n.translate('en', 'settings.about.embeddedEngine', { version: '0.62.0' }), 'Built-in Token Monitor engine v0.62.0 (MIT).');
  assert.equal(i18n.translate('zh-CN', 'settings.about.embeddedEngine', { version: '0.62.0' }), '内置 Token Monitor 引擎 v0.62.0（MIT）。');
  assert.equal(i18n.translate('en', 'settings.host.title'), 'AiGoodBro');
  assert.equal(i18n.translate('zh-CN', 'settings.host.title'), 'AiGoodBro');
  assert.equal(i18n.translate('en', 'settings.host.checkUpdates'), 'Check for updates');
  assert.equal(i18n.translate('zh-CN', 'settings.host.checkUpdates'), '检查更新');
  assert.equal(i18n.translate('en', 'settings.about.reportIssue'), 'Issues & feedback');
  assert.equal(i18n.translate('zh-CN', 'settings.about.reportIssue'), '问题与反馈');
  assert.match(i18n.translate('en', 'settings.appUpdate.managedByHost'), /AiGoodBro manages application/);
  assert.match(i18n.translate('zh-CN', 'settings.appUpdate.managedByHost'), /AiGoodBro 管理/);
  assert.doesNotMatch(stagedI18n, /'settings\.appUpdate\.source': 'GitHub releases'/);
  assert.match(index, /\.\.\/\.\.\/\.\.\/assets\/icon\.png/);
  assert.match(index, /id="floatingBubbleContent"[^>]*><img class="aigoodbro-floating-bubble-icon"[^>]*src="\.\.\/\.\.\/\.\.\/assets\/icon\.png"/);
  assert.match(index, /class="aigoodbro-title-mark-icon" src="\.\.\/\.\.\/\.\.\/assets\/icon\.png"/);
  assert.doesNotMatch(index, /<img[^>]*assets\/icon\.png[^>]*style=/);
  assert.match(styles, /\.app-title-mark \.aigoodbro-title-mark-icon \{[^}]*width: 1em;[^}]*height: 1em;/);
  assert.match(styles, /\.floating-bubble-tab \.aigoodbro-floating-bubble-icon \{[^}]*width: 24px;[^}]*height: 24px;/);
  assert.doesNotMatch(index, /app-title-mark[^>]*>Σ/);
  assert.match(rendererApp, /if \(id === 'app'\) return '\.\.\/\.\.\/\.\.\/assets\/icon\.png';/);
  assert.match(rendererApp, /sources\.app = '\.\.\/\.\.\/\.\.\/assets\/icon\.png';/);
  assert.doesNotMatch(rendererApp, /assets\/icons\/tray-token-monitor\.png/);
  assert.match(tray, /const TRAY_ICON_PATH = ICON_PATH;/);
  assert.match(tray, /sized\.setTemplateImage\(false\)/);
  assert.match(tray, /Open AiGoodBro Workbench/);
  for (const relativePath of ['src/electron/main.js', 'src/electron/discordRpc.js', 'src/electron/preload.js', 'src/shared/appUpdater.js', 'src/electron/renderer/app.js', 'src/electron/tray.js']) {
    const check = spawnSync(process.execPath, ['--check', path.join(stage, relativePath)], { encoding: 'utf8' });
    assert.equal(check.status, 0, `${relativePath}: ${check.stderr}`);
  }
  assert.throws(() => transformStage(stage), /Pinned upstream hash changed/);
});
