'use strict';

// Apply the small AiGoodBro host adapter only to a disposable Electron staging
// copy. The pinned upstream source tree and its inventory remain untouched.
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const INPUT_SHA256 = Object.freeze({
  'src/shared/collector.js': '7c76f724e9b8ccd32d76b6640456ec87cfe3a25cc51386fab14de816b80c383b',
  'src/shared/usage/deviceRuntime.js': 'f91fbde1b03220f171bd460c657cb41148f738d35ee4f89c0258b3c5e8babce0',
  'src/shared/sessionDetail.js': '5445afa37b277d992c2c46f63dc29bcec4804a2ef86d398f4c52577211398546',
  'src/shared/providers/cursor/selfSync.js': 'd85903c15f9b7881e6afb1e54b4100aea6297f96c6f91273e2e49c0d42c8b734',
  'src/shared/providers/antigravity/selfSync.js': '0fd43baf9d818557644ef730edec1eb8968d4811d74d344c98eb0f79efca99b6',
  'src/electron/main.js': 'd9ac675becf19d11f1ea95e0c8766c3d2081d2e743910b2339312807538af1c1',
  'src/electron/edgeDock/controller.js': '9be6e6cf46757edf367644b7e6b788afeef5de2ca5bf49e35d613c45b27c383a',
  'src/electron/discordRpc.js': 'bcd2a36e03a54c04ceadf23a433d7f961684bd1a4265bfd9f5546a7d556c402d',
  'src/electron/preload.js': '05b8ffc8c1eff34aa2249829c9394bdc8dc92357afb686615127b669948a3687',
  'src/shared/appUpdater.js': '1c437d8ca2c05322ec97327f197105547f0db2451f37525c3251315340b8b852',
  'src/electron/renderer/index.html': '01a9dfb19def0fba854493484ab3552d45ff78b9c1b0ba74a78ba630c69b6c2e',
  'src/electron/renderer/i18n.js': '82ffac80a8fe3bb719254b1e1089322f2d642ac3bac66509258e5da903ab14b4',
  'src/electron/renderer/edgeDock/index.html': '6f8542791c01f67d5c28429b4a7271d3c5145cf53ef6ad15ff33b20cbb40088c',
  'src/electron/renderer/styles.css': 'd6788eae0b0ff6c660fb3a8568f8d47e21926771aee8f197a998c2b0ed04c95a',
  'src/electron/renderer/app.js': '8b2620f5c5439237160ce38655eda198e0a6b6a67df0e71b5ebdd0e4a0511025',
  'src/electron/renderer/trayComposer.js': '3c2a3c4ad01c10fd0a6eda7f0893de568a2169d307a8a16f99d74e4790af5ef4',
  'src/electron/tray.js': 'bd8559cefbac6e9caea401f6514856d882f4d67ba23d30a5f93e4e6284eb3bd3'
});

function replaceOne(content, needle, replacement, label) {
  const first = content.indexOf(needle);
  if (first < 0 || content.indexOf(needle, first + needle.length) >= 0) {
    throw new Error(`${label}: expected exactly one source anchor`);
  }
  return content.slice(0, first) + replacement + content.slice(first + needle.length);
}

function patchMain(source) {
  let text = replaceOne(source,
    "const APP_NAME = 'Token Monitor';",
    "const IS_AIGOODBRO_EMBEDDED = process.env.AIGOODBRO_TOKEN_MONITOR_EMBEDDED === '1';\nconst APP_NAME = IS_AIGOODBRO_EMBEDDED ? 'AiGoodBro' : 'Token Monitor';",
    'main brand');
  text = replaceOne(text,
    "const { normalizeCompactTokenUnits } = require('../shared/compactTokens');",
    "const { normalizeCompactTokenUnits, formatCompactTokens } = require('../shared/compactTokens');",
    'shared upstream compact rate formatter');
  text = replaceOne(text,
    "    tokenRateMode: 'speed',",
    "    tokenRateMode: IS_AIGOODBRO_EMBEDDED ? 'burn' : 'speed',",
    'embedded TPM preference default');
  text = replaceOne(text,
    '  rendererViewState = normalizeInitialRendererViewState(settings.lastViewState, rendererViewState);',
    `  if (IS_AIGOODBRO_EMBEDDED && !(Number.isSafeInteger(settings.aigoodbroTokenRatePreferenceVersion)
    && settings.aigoodbroTokenRatePreferenceVersion >= 1)) {
    settings.tokenRateMode = 'burn';
    settings.aigoodbroTokenRatePreferenceVersion = 1;
    if (!saveSettings()) {
      // Keep the requested framing in memory and retry the marker with the next
      // ordinary save; a failed preference write must not enable any service.
      settings.tokenRateMode = 'burn';
      settings.aigoodbroTokenRatePreferenceVersion = 1;
    }
  }
  rendererViewState = normalizeInitialRendererViewState(settings.lastViewState, rendererViewState);`,
    'one-time embedded TPM migration preserves later speed choices');
  text = replaceOne(text,
    'const allTimeSessionsCache = createStatsPresentationCache();',
    `// AiGoodBro's renderer and native sidebar share this one matched-counter
// cache. Reads project expiry only; observing happens on existing stats paths.
let aigoodbroTokenRateTracker = null;
let aigoodbroTokenRateSettingsContext = '';
let aigoodbroTokenRateSourceContext = '';
let aigoodbroTokenRateContextGeneration = 0;
let aigoodbroTokenRateCounters = new Map();
let aigoodbroTokenRatePublishedSignature = 'null';

function aigoodbroTokenRateSettingsKey() {
  const day = new Date();
  return JSON.stringify([mode, hubModeGeneration, settings?.hubMode || '',
    settings?.hubUrl || '', settings?.deviceId || '', settings?.clients || '',
    settings?.liveTokenRateScope || 'all', day.getFullYear(), day.getMonth(),
    day.getDate(), day.getTimezoneOffset()]);
}

function resetAiGoodBroTokenRate() {
  if (!IS_AIGOODBRO_EMBEDDED) return;
  aigoodbroTokenRateTracker = null;
  aigoodbroTokenRateSettingsContext = '';
  aigoodbroTokenRateSourceContext = '';
  aigoodbroTokenRateCounters = new Map();
  aigoodbroTokenRateContextGeneration += 1;
}

function aigoodbroFormattedTokenRate(value) {
  const rate = Math.max(0, Number(value) || 0);
  if (rate > 0 && rate < 0.1) return '<0.1';
  const locale = trayMenuLocale();
  if (rate > 0 && rate < 1) {
    return rate.toLocaleString(locale, { maximumFractionDigits: 1 });
  }
  return formatCompactTokens(rate, settings?.compactTokenUnits, locale);
}

function aigoodbroTokenRateSnapshot() {
  if (!IS_AIGOODBRO_EMBEDDED) return null;
  if (aigoodbroTokenRateSettingsContext
    && aigoodbroTokenRateSettingsContext !== aigoodbroTokenRateSettingsKey()) resetAiGoodBroTokenRate();
  const sample = aigoodbroTokenRateTracker?.getSample();
  const snapshot = sample ? {
    mode: settings?.tokenRateMode === 'speed' ? 'speed' : 'burn',
    formattedValue: aigoodbroFormattedTokenRate(settings?.tokenRateMode === 'speed' ? sample.speed : sample.burn),
    scope: tokenRateApi.isSharedSyncMode(settings?.hubMode)
      && settings?.liveTokenRateScope !== 'device' ? 'all' : 'local',
    burnPerMinute: sample.burn, speedPerSecond: sample.speed,
    sampledAt: sample.sampledAt, expiresAt: sample.expiresAt,
    idle: sample.idle === true, revision: sample.revision,
    contextKey: 'rate-' + process.pid + '-' + aigoodbroTokenRateContextGeneration
  } : null;
  const signature = JSON.stringify(snapshot);
  if (signature !== aigoodbroTokenRatePublishedSignature) {
    aigoodbroTokenRatePublishedSignature = signature;
    sendMainWindowEvent('stats:push', { event: 'aigoodbro:tokenRate', data: { tokenRate: snapshot } },
      () => aigoodbroTokenRatePublishedSignature === signature);
  }
  return snapshot;
}

function observeAiGoodBroTokenRate(stats) {
  if (!IS_AIGOODBRO_EMBEDDED) return;
  if (!stats || stats.aigoodbroUsagePending === true) {
    resetAiGoodBroTokenRate();
    aigoodbroTokenRateSnapshot();
    return;
  }
  const settingsKey = aigoodbroTokenRateSettingsKey();
  const scope = tokenRateApi.isSharedSyncMode(settings?.hubMode)
    && settings?.liveTokenRateScope !== 'device' ? 'all' : 'device';
  const selection = tokenRateApi.selectLiveTokenRatePeriods(stats, settings?.deviceId, settings?.hubMode, scope);
  const sourceKey = JSON.stringify([settingsKey, selection.source,
    selection.entries.map((entry) => [entry.id, entry.period?.capabilities?.throughput !== false]).sort()]);
  const counters = new Map(selection.entries.map((entry) => [entry.id,
    ['timedTokens', 'timedOutputTokens', 'timedDurationMs'].map((field) => {
      const value = entry.period?.[field];
      return value === null || value === undefined || value === '' ? null : Number(value);
    })]));
  const regressed = [...counters].some(([id, values]) => {
    const previous = aigoodbroTokenRateCounters.get(id);
    return previous && values.some((value, i) => Number.isFinite(value)
      && Number.isFinite(previous[i]) && value < previous[i]);
  });
  if (!aigoodbroTokenRateTracker || sourceKey !== aigoodbroTokenRateSourceContext || regressed) {
    resetAiGoodBroTokenRate();
    aigoodbroTokenRateTracker = tokenRateApi.createLiveTokenRateGroupTracker({
      now: Date.now, activeMs: 8000, clearMs: 180000
    });
    aigoodbroTokenRateTracker.reset(selection.entries);
    aigoodbroTokenRateSettingsContext = settingsKey;
    aigoodbroTokenRateSourceContext = sourceKey;
  } else {
    aigoodbroTokenRateTracker.observe(selection.entries);
  }
  aigoodbroTokenRateCounters = counters;
  aigoodbroTokenRateSnapshot();
}

function aigoodbroRendererStats(stats) {
  const result = rendererStats(stats);
  return IS_AIGOODBRO_EMBEDDED && result && typeof result === 'object'
    ? { ...result, aigoodbroTokenRate: aigoodbroTokenRateSnapshot() } : result;
}

const allTimeSessionsCache = createStatsPresentationCache();`,
    'single shared live token rate cache');
  text = replaceOne(text,
    '    const visibleStats = electronPresentationStats(latestStats);\n    migrateCodexAdditionalLimits(visibleStats);',
    '    const visibleStats = electronPresentationStats(latestStats);\n    observeAiGoodBroTokenRate(visibleStats);\n    migrateCodexAdditionalLimits(visibleStats);',
    'observe existing stats publications without additional collection');
  text = replaceOne(text,
    '    return rendererSnapshots.stamp(stats, rendererStats(electronPresentationStats(stats)));',
    `    const visibleStats = electronPresentationStats(stats);
    observeAiGoodBroTokenRate(visibleStats);
    return rendererSnapshots.stamp(stats, aigoodbroRendererStats(visibleStats));`,
    'existing stats reads share the presentation rate cache');
  // Both the real stats publication and cached presentation refresh carry the
  // same cache DTO. These are the two pinned call sites, not a new IPC reader.
  const rendererRateAnchor = 'rendererStats(visibleStats)';
  for (let i = 0; i < 2; i += 1) {
    const index = text.indexOf(rendererRateAnchor);
    if (index < 0) throw new Error('shared renderer rate: missing source anchor');
    text = text.slice(0, index) + 'aigoodbroRendererStats(visibleStats)' + text.slice(index + rendererRateAnchor.length);
  }
  text = replaceOne(text,
    "  const envHubUrl = process.env.TOKEN_MONITOR_HUB_URL || '';",
    "  const envHubUrl = IS_AIGOODBRO_EMBEDDED ? '' : process.env.TOKEN_MONITOR_HUB_URL || '';",
    'embedded settings failure cannot inherit Cloud opt-in');
  text = replaceOne(text,
    '    hubHostPort: Math.max(1, Math.min(65535, Number(process.env.TOKEN_MONITOR_PORT) || HUB_DEFAULT_PORT)),',
    '    hubHostPort: IS_AIGOODBRO_EMBEDDED ? HUB_DEFAULT_PORT : Math.max(1, Math.min(65535, Number(process.env.TOKEN_MONITOR_PORT) || HUB_DEFAULT_PORT)),',
    'embedded Cloud port defaults require saved settings');
  for (const field of ['hubHostSecret', 'secret']) {
    text = replaceOne(text,
      `    ${field}: process.env.TOKEN_MONITOR_SECRET || '',`,
      `    ${field}: IS_AIGOODBRO_EMBEDDED ? '' : process.env.TOKEN_MONITOR_SECRET || '',`,
      `embedded Cloud ${field} defaults require saved credentials`);
  }
  text = replaceOne(text,
    '    hubSyncSessionTitles: parseBoolean(process.env.TOKEN_MONITOR_SYNC_SESSION_TITLES, false),',
    '    hubSyncSessionTitles: IS_AIGOODBRO_EMBEDDED ? false : parseBoolean(process.env.TOKEN_MONITOR_SYNC_SESSION_TITLES, false),',
    'embedded title sync defaults require saved settings');
  text = replaceOne(text,
    'function stopLocalCollector(options = {}) {',
    `let aigoodbroPendingLimits = null;
function stopLocalCollector(options = {}) {
  aigoodbroPendingLimits = null;
  resetAiGoodBroTokenRate();
  aigoodbroTokenRateSnapshot();
  if (IS_AIGOODBRO_EMBEDDED) {
    sendMainWindowEvent('stats:push', { event: 'aigoodbro:limits', data: { limits: null } },
      () => aigoodbroPendingLimits === null);
  }`,
    'limits source epoch reset');
  text = replaceOne(text,
    '    progressive: true,',
    `    progressive: true,
    onLimits: IS_AIGOODBRO_EMBEDDED ? (limits) => {
      aigoodbroPendingLimits = limits;
      sendMainWindowEvent('stats:push', { event: 'aigoodbro:limits', data: { limits } },
        () => aigoodbroPendingLimits === limits && deviceRuntimeHandle != null);
    } : undefined,`,
    'cold start limits reach renderer without fabricated usage');
  text = replaceOne(text,
    '      const reason = meta.reason;',
    '      aigoodbroPendingLimits = null;\n      const reason = meta.reason;',
    'real collection supersedes deferred limits');
  text = replaceOne(text,
    '    return withHistoryPreview(aggregateDevices(localDevice ? [localDevice] : [], 0), localDevice ? [localDevice] : []);',
    `    const bootstrapStats = withHistoryPreview(aggregateDevices(localDevice ? [localDevice] : [], 0), localDevice ? [localDevice] : []);
    if (IS_AIGOODBRO_EMBEDDED && !localDevice) bootstrapStats.aigoodbroUsagePending = true;
    return bootstrapStats;`,
    'local bootstrap is distinct from a real zero-usage record');
  text = replaceOne(text,
    "  win.webContents.on('did-finish-load', () => {\n    sendFloatingBubbleState();",
    `  win.webContents.on('did-finish-load', () => {
    if (IS_AIGOODBRO_EMBEDDED && aigoodbroPendingLimits && deviceRuntimeHandle) {
      const limits = aigoodbroPendingLimits;
      sendMainWindowEvent('stats:push', { event: 'aigoodbro:limits', data: { limits } },
        () => aigoodbroPendingLimits === limits && deviceRuntimeHandle != null);
    }
    sendFloatingBubbleState();`,
    'renderer reload replays only the current pending quota epoch');
  text = replaceOne(text,
    '  const mode = macActivationPolicyMode(settings, { mainWindowVisible });',
    "  const mode = IS_AIGOODBRO_EMBEDDED ? 'accessory' : macActivationPolicyMode(settings, { mainWindowVisible });",
    'embedded helper never owns a second Dock icon');
  text = replaceOne(text,
    '    onToggleRateMode: () => {',
    "    onOpenMainWindow: IS_AIGOODBRO_EMBEDDED ? () => openViewFromTray('home') : undefined,\n    onToggleRateMode: () => {",
    'embedded sidebar opens the existing floating home');
  text = replaceOne(text,
    "const TRAY_OPEN_VIEW_IDS = new Set(['home', 'project', 'session', 'limits', 'trends', 'status']);",
    "const TRAY_OPEN_VIEW_IDS = new Set(['home', 'tool', 'status', 'device', 'model', 'project', 'session', 'limits', 'trends']);",
    'all upstream views through host route');
  text = replaceOne(text,
    "    language: 'auto',",
    "    language: IS_AIGOODBRO_EMBEDDED && ['zh-CN', 'en'].includes(process.env.AIGOODBRO_TOKEN_MONITOR_LANGUAGE)\n      ? process.env.AIGOODBRO_TOKEN_MONITOR_LANGUAGE : 'auto',",
    'initial host language');
  text = replaceOne(text,
    '  return macWidgetRuntimeSupport({ platform, osRelease }).supported;',
    '  return !IS_AIGOODBRO_EMBEDDED && macWidgetRuntimeSupport({ platform, osRelease }).supported;',
    'native WidgetKit is unavailable without AiGoodBro entitlements');
  text = replaceOne(text,
    '  const widgetRuntimeSupported = widgetRuntime.supported;',
    '  const widgetRuntimeSupported = !IS_AIGOODBRO_EMBEDDED && widgetRuntime.supported;',
    'skip embedded WidgetKit registration and publication');
  text = replaceOne(text,
    "    : Promise.resolve({ status: 'skipped', reason: widgetRuntime.reason });",
    "    : Promise.resolve({ status: 'skipped', reason: IS_AIGOODBRO_EMBEDDED ? 'host-widget-unavailable' : widgetRuntime.reason });",
    'embedded WidgetKit status reason');
  text = replaceOne(text,
    'function hydrateCodexManagedAccounts(value) {',
    `// Host-managed profiles stay in memory. The original settings file never
// becomes an owner of AiGoodBro credentials or their home directories.
let aigoodbroManagedCodexAccounts = [];
let aigoodbroManagedCodexSync = null;

function effectiveCodexManagedAccounts() {
  const own = normalizeCodexManagedAccounts(settings?.codexManagedAccounts);
  if (!IS_AIGOODBRO_EMBEDDED) return own;
  const hostKeys = new Set(aigoodbroManagedCodexAccounts.map((account) => account.accountKey));
  const hostIDs = new Set(aigoodbroManagedCodexAccounts.map((account) => account.id));
  return [...aigoodbroManagedCodexAccounts, ...own.filter((account) => !hostKeys.has(account.accountKey) && !hostIDs.has(account.id))];
}

function applyAiGoodBroManagedCodexAccounts(accounts) {
  const changed = JSON.stringify(accounts) !== JSON.stringify(aigoodbroManagedCodexAccounts);
  if (!changed) return;
  aigoodbroManagedCodexAccounts = accounts;
  if (mainWindow && !mainWindow.isDestroyed()) pushSettingsToRenderer();
  if (deviceRuntimeHandle) {
    deviceRuntimeHandle.reconfigureLimits(electronLimitsConfig());
    void queueLimitInvalidation({ provider: 'codex' }, 'aigoodbro-managed-accounts', { clear: true, refresh: true });
  }
}

async function refreshAiGoodBroManagedCodexAccounts() {
  if (!IS_AIGOODBRO_EMBEDDED) return true;
  if (aigoodbroManagedCodexSync) return aigoodbroManagedCodexSync;
  aigoodbroManagedCodexSync = (async () => {
    const fail = () => { applyAiGoodBroManagedCodexAccounts([]); return false; };
    let reply;
    try {
      reply = await globalThis.__AIGOODBRO_TOKEN_MONITOR_BRIDGE__?.requestHost('getManagedCodexAccounts', {}, 5000);
    } catch (_) { return fail(); }
    if (!reply?.ok || !Array.isArray(reply.accounts) || reply.accounts.length > 128) return fail();
    const accounts = [];
    const seenIDs = new Set();
    const seenKeys = new Set();
    for (const item of reply.accounts) {
      const id = String(item?.id || '');
      const accountKey = String(item?.accountKey || '');
      const homePath = String(item?.homePath || '');
      const workspaceAccountId = normalizeWorkspaceId(item?.workspaceAccountId);
      if (!/^aigoodbro-[A-Za-z0-9._-]{1,100}$/.test(id) || !/^sha256:[a-f0-9]{64}$/.test(accountKey)
        || !workspaceAccountId || !path.isAbsolute(homePath) || homePath.includes('\\0')
        || Buffer.byteLength(homePath) > 1024 || seenIDs.has(id) || seenKeys.has(accountKey)) return fail();
      const authPath = path.join(homePath, 'auth.json');
      try {
        const directory = fs.lstatSync(homePath);
        if (!directory.isDirectory() || directory.isSymbolicLink() || directory.uid !== process.getuid()) return fail();
        const auth = JSON.parse(readRegularFileNoFollow(authPath, { fs, description: 'AiGoodBro Codex auth', encoding: 'utf8' }));
        const identity = codexAuthIdentity(auth);
        if (identity.accountKey !== accountKey || identity.workspaceAccountId !== workspaceAccountId) return fail();
      } catch (_) { return fail(); }
      seenIDs.add(id);
      seenKeys.add(accountKey);
      const hostAlias = String(item.alias || '').replace(/[\\u0000-\\u001f\\u007f]/g, ' ').trim().slice(0, 100) || 'AiGoodBro account';
      accounts.push({ id, email: '', accountKey, accountLabel: '', workspaceAccountId,
        workspaceLabel: '', workspaceKind: '', homePath, authPath, hostAlias, hostManaged: true, enabled: true });
    }
    applyAiGoodBroManagedCodexAccounts(accounts);
    return true;
  })().finally(() => { aigoodbroManagedCodexSync = null; });
  return aigoodbroManagedCodexSync;
}

function hydrateCodexManagedAccounts(value) {`,
    'private native managed Codex profile projection');
  text = replaceOne(text,
    '  return normalizeCodexManagedAccounts(settings?.codexManagedAccounts).map(({\n    id, email, accountKey, accountLabel, workspaceAccountId, workspaceLabel, workspaceKind, addedAt, updatedAt, enabled\n  }) => ({',
    '  return effectiveCodexManagedAccounts().map(({\n    id, email, accountKey, accountLabel, workspaceAccountId, workspaceLabel, workspaceKind, addedAt, updatedAt, enabled, hostAlias, hostManaged\n  }) => ({',
    'render native managed Codex aliases');
  text = replaceOne(text,
    '  return effectiveCodexManagedAccounts().map(({\n    id, email, accountKey, accountLabel, workspaceAccountId, workspaceLabel, workspaceKind, addedAt, updatedAt, enabled, hostAlias, hostManaged\n  }) => ({\n    id,\n    email,',
    '  return effectiveCodexManagedAccounts().map(({\n    id, email, accountKey, accountLabel, workspaceAccountId, workspaceLabel, workspaceKind, addedAt, updatedAt, enabled, hostAlias, hostManaged\n  }) => ({\n    id,\n    email: hostManaged ? hostAlias : email,',
    'display native alias without exposing email');
  text = replaceOne(text,
    '    workspaceKind,\n    addedAt,\n    updatedAt,\n    enabled\n  }));\n}\n\nfunction codexManagedAccountsForCollector() {',
    '    workspaceKind,\n    addedAt,\n    updatedAt,\n    enabled,\n    hostAlias: hostManaged ? hostAlias : undefined,\n    hostManaged: hostManaged === true\n  }));\n}\n\nfunction codexManagedAccountsForCollector() {',
    'render native managed Codex account marker');
  text = replaceOne(text,
    'function codexManagedAccountsForCollector() {\n  return normalizeCodexManagedAccounts(settings?.codexManagedAccounts);\n}',
    'function codexManagedAccountsForCollector() {\n  return effectiveCodexManagedAccounts();\n}',
    'collect native managed Codex accounts');
  text = replaceOne(text,
    "  const account = accounts.find((entry) => entry.id === accountId);\n  if (!account) return { ok: false, error: 'Account not found' };\n  settings.codexManagedAccounts = accounts.filter((entry) => entry.id !== accountId);",
    "  const account = accounts.find((entry) => entry.id === accountId);\n  if (IS_AIGOODBRO_EMBEDDED && aigoodbroManagedCodexAccounts.some((entry) => entry.id === accountId)) {\n    void globalThis.__AIGOODBRO_TOKEN_MONITOR_BRIDGE__?.requestHost('openAccounts');\n    return { ok: false, error: 'Manage this account in AiGoodBro.' };\n  }\n  if (!account) return { ok: false, error: 'Account not found' };\n  settings.codexManagedAccounts = accounts.filter((entry) => entry.id !== accountId);",
    'native account remove guard');
  text = replaceOne(text,
    "function setCodexManagedAccountEnabled(id, enabled) {\n  const accountId = String(id || '').trim();\n  const accounts = normalizeCodexManagedAccounts(settings.codexManagedAccounts);\n  const account = accounts.find((entry) => entry.id === accountId);\n  if (!account) return { ok: false, error: 'Account not found' };\n  account.enabled = Boolean(enabled);",
    "function setCodexManagedAccountEnabled(id, enabled) {\n  const accountId = String(id || '').trim();\n  const accounts = normalizeCodexManagedAccounts(settings.codexManagedAccounts);\n  const account = accounts.find((entry) => entry.id === accountId);\n  if (IS_AIGOODBRO_EMBEDDED && aigoodbroManagedCodexAccounts.some((entry) => entry.id === accountId)) {\n    void globalThis.__AIGOODBRO_TOKEN_MONITOR_BRIDGE__?.requestHost('openAccounts');\n    return { ok: false, error: 'Manage this account in AiGoodBro.' };\n  }\n  if (!account) return { ok: false, error: 'Account not found' };\n  account.enabled = Boolean(enabled);",
    'native account enabled guard');
  text = replaceOne(text,
    "  const accounts = normalizeCodexManagedAccounts(settings.codexManagedAccounts);\n  const account = accounts.find((entry) => entry.id === accountId);\n  if (!account) return { ok: false, error: 'Account not found' };\n  if (account.enabled === false) return { ok: false, error: 'Account is disabled' };\n  if (!deviceRuntimeHandle) return { ok: false, error: 'Limits runtime is not ready' };",
    "  const accounts = effectiveCodexManagedAccounts();\n  const account = accounts.find((entry) => entry.id === accountId);\n  if (!account) return { ok: false, error: 'Account not found' };\n  if (account.enabled === false) return { ok: false, error: 'Account is disabled' };\n  if (!deviceRuntimeHandle) return { ok: false, error: 'Limits runtime is not ready' };",
    'native managed Codex targeted refresh');
  text = replaceOne(text,
    'app.whenReady().then(() => {\n  if (process.platform',
    'app.whenReady().then(async () => {\n  if (process.platform',
    'host profile snapshot before first renderer and collector');
  text = replaceOne(text,
    '  ensureSettingsLoaded();\n  // Switching the OS',
    '  ensureSettingsLoaded();\n  if (IS_AIGOODBRO_EMBEDDED) await refreshAiGoodBroManagedCodexAccounts();\n  // Switching the OS',
    'load native accounts before original UI');
  text = replaceOne(text,
    "  ipcMain.handle('codex:accounts', () => codexAccountsForRenderer());",
    "  ipcMain.handle('codex:accounts', async () => {\n    if (IS_AIGOODBRO_EMBEDDED) await refreshAiGoodBroManagedCodexAccounts();\n    return codexAccountsForRenderer();\n  });",
    'refresh native account roster when settings opens');
  text = replaceOne(text,
    "  ipcMain.handle('codex:addAccount', async (event, request = {}) => {",
    "  ipcMain.handle('codex:addAccount', async (event, request = {}) => {\n    if (IS_AIGOODBRO_EMBEDDED) {\n      void globalThis.__AIGOODBRO_TOKEN_MONITOR_BRIDGE__?.requestHost('openAccounts');\n      return { ok: false, error: 'Add Codex accounts in AiGoodBro.' };\n    }",
    'native account creation ownership');
  text = replaceOne(text,
    'async function switchCodexSystemAccount(id) {',
    `async function switchCodexAccountThroughAiGoodBro(id) {
  const account = effectiveCodexManagedAccounts()
    .find((entry) => entry.id === String(id || '').trim());
  if (!account || account.enabled === false) return { ok: false, error: 'Codex account is unavailable.' };
  const bridge = globalThis.__AIGOODBRO_TOKEN_MONITOR_BRIDGE__;
  if (!bridge?.requestCodexSwitch) return { ok: false, error: 'AiGoodBro account switch bridge is unavailable.' };
  const response = await bridge.requestCodexSwitch({
    vendorAccountId: account.id,
    recordedAccountKey: account.accountKey
  });
  if (!response?.ok) return { ok: false, error: response?.error || 'AiGoodBro declined this account switch.' };
  if (response.accountId !== account.id) return { ok: false, error: 'AiGoodBro account confirmation did not match.' };
  return {
    ok: true,
    activeAccountId: account.id,
    activeAccount: codexAccountsForRenderer().find((entry) => entry.id === account.id) || null
  };
}

async function switchCodexSystemAccount(id) {`,
    'Codex native mutation handoff');
  text = replaceOne(text,
    '    const result = await performCodexSystemAccountSwitch(id);',
    `    const result = IS_AIGOODBRO_EMBEDDED
      ? await switchCodexAccountThroughAiGoodBro(id)
      : await performCodexSystemAccountSwitch(id);`,
    'Codex mutation through native transaction guard');
  const guards = [
    ['function loginItemEnabledHere() {', '  if (IS_AIGOODBRO_EMBEDDED) return false;'],
    ['async function checkAppUpdateProvider() {', '  if (IS_AIGOODBRO_EMBEDDED) return { ok: false, newer: false, latest: null, error: "managed-by-aigoodbro", errorKind: "host-managed", checkedAt: null };'],
    ['async function runAppUpdateCheck({ force = false, bypassCooldown = false } = {}) {', '  if (IS_AIGOODBRO_EMBEDDED) return deriveAppUpdateState();'],
    ['function maybeRunBackgroundUpdateCheck() {', '  if (IS_AIGOODBRO_EMBEDDED) return;'],
    ['function startAppUpdateBackgroundChecks() {', '  if (IS_AIGOODBRO_EMBEDDED) return;'],
    ['async function downloadAndPrepareAppUpdate() {', '  if (IS_AIGOODBRO_EMBEDDED) return deriveAppUpdateState();'],
    ['async function installDownloadedAppUpdate() {', '  if (IS_AIGOODBRO_EMBEDDED) return deriveAppUpdateState();']
  ];
  for (const [anchor, guard] of guards) text = replaceOne(text, anchor, `${anchor}\n${guard}`, `main ${anchor}`);
  text = replaceOne(text,
    '  startAppUpdateBackgroundChecks();\n});',
    `  startAppUpdateBackgroundChecks();
  if (IS_AIGOODBRO_EMBEDDED) {
    const hostBridge = globalThis.__AIGOODBRO_TOKEN_MONITOR_BRIDGE__;
    if (!hostBridge) throw new Error('AiGoodBro desktop host bridge is missing');
    hostBridge.bind({
      showDashboard: async () => { await refreshAiGoodBroManagedCodexAccounts(); createDashboardWindow(); },
      showView: async (viewId) => { await refreshAiGoodBroManagedCodexAccounts(); openViewFromTray(viewId); },
      showSettings: async (section) => { await refreshAiGoodBroManagedCodexAccounts(); focusExistingWindow(); sendMainWindowEvent('settings:open', section); },
      isTrayVisible: () => Boolean(tray && !tray.isDestroyed()),
      getAllTimeUsage: () => {
        const stats = electronPresentationStats(latestStats || localStats);
        return stats?.aigoodbroUsagePending === true ? null : stats?.periods?.allTime;
      },
      getTokenRate: () => aigoodbroTokenRateSnapshot(),
      quit: () => requestAppQuit()
    });
  }
});`,
    'main host route binding');
  text = replaceOne(text,
    'function pushSettingsToRenderer() {\n  const payload = settingsForRenderer();',
    'function pushSettingsToRenderer() {\n  aigoodbroTokenRateSnapshot();\n  const payload = settingsForRenderer();',
    'rate framing and source changes publish from the same cache');
  text = replaceOne(text,
    "  ipcMain.handle('settings:get', () => settingsForRenderer());",
    `  ipcMain.handle('aigoodbro:openHost', async (event, action) => {
    if (!IS_AIGOODBRO_EMBEDDED || event.sender !== mainWindow?.webContents
      || !['openWorkbench', 'openAccounts', 'openSettings', 'openEdgeDockSettings', 'checkForUpdates'].includes(action)) {
      return { ok: false, error: 'unsupported-action' };
    }
    const result = await globalThis.__AIGOODBRO_TOKEN_MONITOR_BRIDGE__.requestHost(action);
    if (result?.ok && mainWindow && !mainWindow.isDestroyed()) mainWindow.hide();
    return result;
  });
  ipcMain.handle('settings:get', () => settingsForRenderer());`,
    'renderer to native workspace routes');
  text = replaceOne(text,
    'function syncEdgeDock(rendererSettings) {\n  if (!settings) return;',
    'function syncEdgeDock(rendererSettings) {\n  if (IS_AIGOODBRO_EMBEDDED) { edgeDockController?.stop(); return; }\n  if (!settings) return;',
    'one screen-edge dock owned by the native host');
  text = replaceOne(text,
    'function setEdgeDockFromMenu(patch = {}) {',
    "function setEdgeDockFromMenu(patch = {}) {\n  if (IS_AIGOODBRO_EMBEDDED) { void globalThis.__AIGOODBRO_TOKEN_MONITOR_BRIDGE__?.requestHost('openEdgeDockSettings'); return; }",
    'tray edge dock action opens its native settings');
  text = replaceOne(text,
    "  if (parsed.hostname === 'github.com' && parsed.pathname.startsWith('/Javis603/token-monitor')) return true;",
    "  if (parsed.hostname === 'github.com' && (parsed.pathname === '/BLACKIELF/AgentHub-AiGoodBro' || parsed.pathname.startsWith('/BLACKIELF/AgentHub-AiGoodBro/'))) return true;",
    'AiGoodBro repository external link');
  text = replaceOne(text,
    "  if (\n    (parsed.hostname === 'javis-ai.com' || parsed.hostname === 'www.javis-ai.com')\n    && (parsed.pathname === '/token-monitor' || parsed.pathname.startsWith('/token-monitor/'))\n  ) return true;",
    "  if (parsed.hostname === 'aigoodbro.com' && (parsed.pathname === '' || parsed.pathname === '/')) return true;",
    'AiGoodBro website external link');
  text = replaceOne(text,
    '        appVersion: appVersion(),',
    '        appVersion: appVersion(),\n        embeddedHost: IS_AIGOODBRO_EMBEDDED,',
    'host tray state');
  text = replaceOne(text,
    '    onOpenSettings: openSettingsFromTray,\n    onQuit: requestAppQuit,',
    `    onOpenSettings: openSettingsFromTray,
    onOpenWorkbench: () => { void globalThis.__AIGOODBRO_TOKEN_MONITOR_BRIDGE__?.requestHost('openWorkbench'); },
    onOpenAccounts: () => { void globalThis.__AIGOODBRO_TOKEN_MONITOR_BRIDGE__?.requestHost('openAccounts'); },
    onOpenTasks: () => { void globalThis.__AIGOODBRO_TOKEN_MONITOR_BRIDGE__?.requestHost('openTasks'); },
    onOpenHostSettings: () => { void globalThis.__AIGOODBRO_TOKEN_MONITOR_BRIDGE__?.requestHost('openSettings'); },
    onCheckHostUpdates: () => { void globalThis.__AIGOODBRO_TOKEN_MONITOR_BRIDGE__?.requestHost('checkForUpdates'); },
    onQuit: IS_AIGOODBRO_EMBEDDED
      ? () => {
          const bridge = globalThis.__AIGOODBRO_TOKEN_MONITOR_BRIDGE__;
          if (!bridge) return requestAppQuit();
          void bridge.requestHost('quitHost').then((reply) => { if (!reply?.ok) requestAppQuit(); });
        }
      : requestAppQuit,`,
    'host tray actions');
  return text;
}

function patchUpdater(source) {
  let text = replaceOne(source,
    "const GITHUB_REPO = 'Javis603/token-monitor';",
    "const GITHUB_REPO = 'BLACKIELF/AgentHub-AiGoodBro';",
    'updater repository metadata');
  return replaceOne(text,
    "} = {}) {\n  if (!isPackaged) return { supported: false, reason: 'unpackaged' };",
    "} = {}) {\n  if (env?.AIGOODBRO_TOKEN_MONITOR_EMBEDDED === '1') return { supported: false, reason: 'managed-by-aigoodbro' };\n  if (!isPackaged) return { supported: false, reason: 'unpackaged' };",
    'updater host ownership');
}

function patchPreload(source) {
  let text = replaceOne(source,
    "  getSettings: () => ipcRenderer.invoke('settings:get'),",
    "  embeddedHost: process.env.AIGOODBRO_TOKEN_MONITOR_EMBEDDED === '1',\n  openAiGoodBroHost: (action) => ipcRenderer.invoke('aigoodbro:openHost', action),\n  getSettings: () => ipcRenderer.invoke('settings:get'),",
    'private native workspace action');
  return replaceOne(text,
    "  onOpenSettings: (callback) => {\n    const listener = () => { try { callback(); } catch (_) {} };",
    "  onOpenSettings: (callback) => {\n    const listener = (_event, section) => { try { callback(['menuBar', 'floatingBubble'].includes(section) ? section : undefined); } catch (_) {} };",
    'bounded settings target');
}

function patchI18n(source) {
  let text = source.replaceAll('Token Monitor', 'AiGoodBro');
  if (text === source) throw new Error('i18n brand anchor missing');
  const upstreamSourceLabel = "'settings.appUpdate.source': 'GitHub releases'";
  if (text.split(upstreamSourceLabel).length !== 6) throw new Error('Expected five upstream update source labels');
  text = text.replaceAll(upstreamSourceLabel, "'settings.appUpdate.source': 'AiGoodBro'");
  const descriptions = [
    ["'settings.about.description': 'Open-source AI tool token usage monitor, licensed under MIT.',",
      'Built-in Token Monitor engine v{version} (MIT).',
      'AiGoodBro manages application and built-in engine updates.',
      'AiGoodBro', 'Workbench', 'Accounts & auto-resume', 'App settings', 'Check for updates', 'AiGoodBro is unavailable. Try again.'],
    ["'settings.about.description': '開源的 AI 工具 Token 用量監控器，採用 MIT 授權。',",
      '內建 Token Monitor 引擎 v{version}（MIT）。',
      '應用程式和內建引擎更新由 AiGoodBro 管理。',
      'AiGoodBro', '工作台', '帳號與自動續做', '應用程式設定', '檢查更新', '無法打開 AiGoodBro，請重試。'],
    ["'settings.about.description': '开源的 AI 工具 Token 用量监控器，采用 MIT 许可。',",
      '内置 Token Monitor 引擎 v{version}（MIT）。',
      '应用及内置引擎更新由 AiGoodBro 管理。',
      'AiGoodBro', '工作台', '账号与自动续做', '应用设置', '检查更新', '无法打开 AiGoodBro，请重试。'],
    ["'settings.about.description': 'MIT 라이선스로 제공되는 오픈 소스 AI 도구 토큰 사용량 모니터입니다.',",
      '내장 Token Monitor 엔진 v{version} (MIT).',
      '앱과 내장 엔진 업데이트는 AiGoodBro에서 관리합니다.',
      'AiGoodBro', '작업 공간', '계정 및 자동 재개', '앱 설정', '업데이트 확인', 'AiGoodBro를 열 수 없습니다. 다시 시도하세요.'],
    ["'settings.about.description': 'MIT ライセンスで提供されるオープンソースの AI ツール用トークン使用量モニターです。',",
      '内蔵 Token Monitor エンジン v{version}（MIT）。',
      'アプリと内蔵エンジンの更新は AiGoodBro が管理します。',
      'AiGoodBro', 'ワークスペース', 'アカウントと自動再開', 'アプリ設定', 'アップデートを確認', 'AiGoodBro を開けません。もう一度お試しください。']
  ];
  for (const [anchor, engine, updates, hostTitle, workbench, accounts, hostSettings, checkUpdates, unavailable] of descriptions) {
    text = replaceOne(text, anchor,
      `${anchor}\n      'settings.about.embeddedEngine': ${JSON.stringify(engine)},\n      'settings.appUpdate.managedByHost': ${JSON.stringify(updates)},\n      'settings.host.title': ${JSON.stringify(hostTitle)},\n      'settings.host.workbench': ${JSON.stringify(workbench)},\n      'settings.host.accounts': ${JSON.stringify(accounts)},\n      'settings.host.settings': ${JSON.stringify(hostSettings)},\n      'settings.host.checkUpdates': ${JSON.stringify(checkUpdates)},\n      'settings.host.unavailable': ${JSON.stringify(unavailable)},`,
      'localized embedded engine and host update explanation');
  }
  const reportLabels = ['Issues & feedback', '問題與回饋', '问题与反馈', '문제 및 피드백', '問題とフィードバック'];
  for (const label of reportLabels) {
    const sourceLabels = ['Report an issue', '回報問題', '报告问题', '문제 신고', '問題を報告'];
    const original = sourceLabels[reportLabels.indexOf(label)];
    text = replaceOne(text, `'settings.about.reportIssue': '${original}'`,
      `'settings.about.reportIssue': ${JSON.stringify(label)}`, 'AiGoodBro issues and feedback label');
  }
  return text;
}

function patchIndex(source) {
  let text = source.replaceAll('Token Monitor', 'AiGoodBro');
  if (text === source) throw new Error('index brand text anchor missing');
  text = replaceOne(text,
    '      <section id="settingsPanel" class="settings-panel hidden">',
    `      <section id="settingsPanel" class="settings-panel hidden">
        <div class="settings-group aigoodbro-host-navigation">
          <div class="settings-group-header"><span data-i18n="settings.host.title">AiGoodBro</span></div>
          <div class="about-settings-links">
            <button class="inline-link" type="button" data-aigoodbro-host-action="openWorkbench" data-i18n="settings.host.workbench">工作台</button>
            <button class="inline-link" type="button" data-aigoodbro-host-action="openAccounts" data-i18n="settings.host.accounts">账号与自动续做</button>
            <button class="inline-link" type="button" data-aigoodbro-host-action="openSettings" data-i18n="settings.host.settings">应用设置</button>
          </div>
          <span id="aigoodbroHostNavigationStatus" class="settings-note" role="status"></span>
        </div>`,
    'original floating settings to native workspace links');
  text = replaceOne(text,
    '<div class="settings-subgroup maintenance-section app-update-settings">\n              <div class="settings-group-header maintenance-header"><span data-i18n="settings.appUpdate.title">App Updates</span><span data-i18n="settings.appUpdate.source">GitHub releases</span></div>',
    '<div class="settings-subgroup maintenance-section app-update-settings aigoodbro-host-updates">\n              <div class="settings-group-header maintenance-header"><span data-i18n="settings.appUpdate.title">App Updates</span><span data-i18n="settings.appUpdate.source">AiGoodBro</span></div>\n              <p class="settings-note aigoodbro-managed-updates-note" data-i18n="settings.appUpdate.managedByHost">AiGoodBro manages application and built-in engine updates.</p>\n              <button class="inline-link aigoodbro-host-update-action" type="button" data-aigoodbro-host-action="checkForUpdates" data-i18n="settings.host.checkUpdates">Check for updates</button>',
    'host-managed update explanation');
  text = replaceOne(text,
    '<div class="settings-group-header"><span data-i18n="settings.about.title">About AiGoodBro</span><span id="aboutVersion">—</span></div>',
    '<div class="settings-group-header"><span data-i18n="settings.about.title">About AiGoodBro</span><span id="aboutVersion">—</span></div>\n              <p id="aboutEngineVersion" class="settings-note"></p>',
    'public product and embedded engine versions');
  text = replaceOne(text,
    '              <div id="edgeDockFeature" class="presence-feature">',
    '              <div id="edgeDockFeature" class="presence-feature" hidden style="display: none">',
    'hide replaced embedded edge dock controls');
  text = replaceOne(text,
    '              <div id="edgeDockFeature" class="presence-feature" hidden style="display: none">',
    '              <button class="inline-link" type="button" data-aigoodbro-host-action="openEdgeDockSettings" data-i18n="settings.display.edgeDock">Edge Dock</button>\n              <div id="edgeDockFeature" class="presence-feature" hidden style="display: none">',
    'native edge dock settings entry');
  text = replaceOne(text,
    '<span class="app-title-mark" aria-hidden="true">Σ</span>',
    '<span class="app-title-mark" aria-hidden="true"><img class="aigoodbro-title-mark-icon" src="../../../assets/icon.png" alt="" /></span>',
    'index collapsed brand mark');
  text = replaceOne(text,
    '<span id="floatingBubbleContent" aria-hidden="true">Σ</span>',
    '<span id="floatingBubbleContent" aria-hidden="true"><img class="aigoodbro-floating-bubble-icon" src="../../../assets/icon.png" alt="" /></span>',
    'index bubble brand mark');
  return text;
}

function patchApp(source) {
  let text = replaceOne(source,
    "const TOKEN_MONITOR_REPOSITORY_URL = 'https://github.com/Javis603/token-monitor';\nconst TOKEN_MONITOR_ISSUES_URL = `${TOKEN_MONITOR_REPOSITORY_URL}/issues/new/choose`;\nconst TOKEN_MONITOR_WEBSITE_URL = 'https://javis-ai.com/token-monitor/';\nconst TOKEN_MONITOR_WSL_SQLITE_GUIDE_URL = `${TOKEN_MONITOR_REPOSITORY_URL}/blob/main/docs/wsl-sqlite-setup.md`;",
    "const TOKEN_MONITOR_REPOSITORY_URL = 'https://github.com/BLACKIELF/AgentHub-AiGoodBro';\nconst TOKEN_MONITOR_ISSUES_URL = `${TOKEN_MONITOR_REPOSITORY_URL}/issues`;\nconst TOKEN_MONITOR_WEBSITE_URL = 'https://aigoodbro.com/';\nconst TOKEN_MONITOR_WSL_SQLITE_GUIDE_URL = `${TOKEN_MONITOR_REPOSITORY_URL}/blob/main/docs/usage-guide.md`;",
    'AiGoodBro product links');
  text = replaceOne(text,
    'function currentTokenRateValue() {',
    `const isAiGoodBroSharedTokenRate = window.tokenMonitor.embeddedHost === true;
function aigoodbroRendererTokenRate() {
  const sample = state.aigoodbroTokenRate;
  return sample ? { ...sample, burn: sample.burnPerMinute, speed: sample.speedPerSecond } : null;
}
function receiveAiGoodBroTokenRate(sample) {
  const next = sample || null;
  if (state.stats) state.stats.aigoodbroTokenRate = next;
  if (JSON.stringify(state.aigoodbroTokenRate || null) === JSON.stringify(next)) return;
  state.aigoodbroTokenRate = next;
  renderTokenRate();
}
function currentTokenRateValue() {
  if (isAiGoodBroSharedTokenRate) {
    const sample = aigoodbroRendererTokenRate();
    const burn = (sample?.mode || state.settings?.tokenRateMode) !== 'speed';
    return { burn, mode: burn ? 'burn' : 'speed', rate: sample ? (burn ? sample.burn : sample.speed) : null };
  }`,
    'title rate reads the shared live sample instead of a period average');
  text = replaceOne(text,
    "  canStart: () => els.shell?.classList.contains('title-icon-only') || els.shell?.classList.contains('title-collapsed'),",
    "  canStart: () => !isAiGoodBroSharedTokenRate && (els.shell?.classList.contains('title-icon-only') || els.shell?.classList.contains('title-collapsed')),",
    'embedded title hold cannot boost real consumption');
  text = replaceOne(text,
    'function observeLiveTokenRate(stats) {\n  if (state.settings?.showLiveTokenRate !== true) return;',
    `function observeLiveTokenRate(stats) {
  if (isAiGoodBroSharedTokenRate) {
    receiveAiGoodBroTokenRate(stats?.aigoodbroTokenRate);
    return;
  }
  if (state.settings?.showLiveTokenRate !== true) return;`,
    'embedded footer does not create an independent tracker or timer');
  text = replaceOne(text,
    "  const burn = state.settings?.tokenRateMode === 'burn';\n  const sample = liveTokenRateTracker.getSample();",
    `  const sample = isAiGoodBroSharedTokenRate ? aigoodbroRendererTokenRate() : liveTokenRateTracker.getSample();
  const burn = isAiGoodBroSharedTokenRate ? (sample?.mode || state.settings?.tokenRateMode) !== 'speed'
    : state.settings?.tokenRateMode === 'burn';`,
    'footer framing uses the same published DTO as the title and native host');
  text = replaceOne(text,
    "  const value = rate === null ? '—' : formatLiveTokenRate(rate);",
    "  const value = isAiGoodBroSharedTokenRate ? sample?.formattedValue || '—' : rate === null ? '—' : formatLiveTokenRate(rate);",
    'footer uses the one upstream-formatted presentation value');
  text = replaceOne(text,
    'function tokenRateText(rate, burn) {',
    `function tokenRateText(rate, burn) {
  if (isAiGoodBroSharedTokenRate) return (state.aigoodbroTokenRate?.formattedValue || '—') + (burn ? ' TPM' : ' tok/s');`,
    'shared rate labels keep real zero and unknown distinct');
  text = replaceOne(text,
    '    const boost = tokenRateBoost.getSnapshot();',
    '    const boost = isAiGoodBroSharedTokenRate ? null : tokenRateBoost.getSnapshot();',
    'embedded title always shows the cached measurement');
  text = replaceOne(text,
    "window.tokenMonitor.onStatsPush?.((payload) => {\n  if (!payload) return;",
    `window.tokenMonitor.onStatsPush?.((payload) => {
  if (!payload) return;
  if (payload.event === 'aigoodbro:tokenRate') {
    if (isAiGoodBroSharedTokenRate) receiveAiGoodBroTokenRate(payload.data?.tokenRate);
    return;
  }
  if (payload.event === 'aigoodbro:limits') {
    state.aigoodbroLimits = payload.data?.limits || null;
    state.limitPanelRenderSignature = '';
    render();
    return;
  }
  if (payload.data?.stats && payload.data.stats.aigoodbroUsagePending !== true) state.aigoodbroLimits = null;`,
    'quota-only presentation never seeds usage with zero');
  text = replaceOne(text,
    "  if (!state.stats) return;\n  allTimeSessions.ensure();",
    `  if (!state.stats || state.stats.aigoodbroUsagePending === true) {
    renderViewSwitcher();
    els.totalTokens.textContent = '—';
    els.totalTokensCompact.textContent = '—';
    els.cost.textContent = '';
    hidePeriodContentForMessage(t('periodRange.loading'));
    els.shell.classList.toggle('home-mode', state.breakdown === 'home');
    els.shell.classList.toggle('session-mode', state.breakdown === 'session');
    els.viewBackRow?.classList.toggle('hidden', state.breakdown === 'home' || !state.homeReturnVisible);
    if (state.breakdown === 'home') {
      hideHomeActivityTooltip();
      state.homeActivityResizeObserver?.disconnect();
      state.homeActivityResizeObserver = null;
      const showQuotas = state.settings?.limitsEnabled !== false && homeModuleIds().includes('limits');
      els.homePanel.replaceChildren(...(showQuotas ? [renderHomeLimitModule()] : []));
      els.homePanel.classList.remove('hidden');
    } else if (state.breakdown === 'limits' && state.aigoodbroLimits) {
      renderLimits();
      els.fixedPeriodMessage.classList.add('hidden');
      els.limitsPanel.classList.remove('hidden');
    }
    signalContentReady();
    return;
  }
  allTimeSessions.ensure();`,
    'cold quota view preserves unknown usage and selected navigation');
  text = replaceOne(text,
    '  if (contentReadySignaled || !state.settings || !state.stats) return;',
    `  const usagePending = !state.stats || state.stats.aigoodbroUsagePending === true;
  const quotaContentVisible = usagePending
    && state.settings?.limitsEnabled !== false
    && state.aigoodbroLimits?.providers?.some((provider) => enabledLimitProviderSet().has(provider.provider))
    && ((state.breakdown === 'limits'
      && state.limitPanelRenderSignature
      && els.limitsPanel?.children.length > 0
      && !els.limitsPanel.classList.contains('hidden'))
      || (state.breakdown === 'home'
        && homeLimitRows().length > 0
        && els.homePanel?.querySelector('.home-limit-account')
        && !els.homePanel.classList.contains('hidden')))
    && visibleStatsSurface() === 'main'
    && !isSettingsPanelOpen();
  if (contentReadySignaled || !state.settings || (usagePending && !quotaContentVisible)) return;`,
    'content ready requires visible quota content or real usage');
  text = replaceOne(text,
    '    state.stats = sessionStatsForDisplay(allTimeSessions.attach(nextStats));',
    '    if (nextStats?.aigoodbroUsagePending !== true) state.aigoodbroLimits = null;\n    state.stats = sessionStatsForDisplay(allTimeSessions.attach(nextStats));',
    'real pulled history supersedes quota-only presentation');
  text = replaceOne(text,
    'providers: (state.stats?.limits?.providers || []).map((provider) => ({',
    'providers: ((state.aigoodbroLimits || state.stats?.limits)?.providers || []).map((provider) => ({',
    'home quota rows reuse cold-start provider limits');
  text = replaceOne(text,
    'const providers = providersByLimitProviderId(state.stats?.limits?.providers || []);',
    'const providers = providersByLimitProviderId((state.aigoodbroLimits || state.stats?.limits)?.providers || []);',
    'render cold-start provider limits');
  text = replaceOne(text,
    "window.tokenMonitor.onOpenView?.(openViewFromTray);",
    `window.tokenMonitor.onOpenView?.((viewId) => {
  if (viewId === 'home') setPeriod('allTime');
  openViewFromTray(viewId);
});`,
    'home entry always opens the total usage overview');
  text = replaceOne(text,
    "window.tokenMonitor.onOpenSettings?.(openSettingsPanel);",
    `for (const button of document.querySelectorAll('[data-aigoodbro-host-action]')) {
  button.addEventListener('click', async () => {
    button.disabled = true;
    const status = document.getElementById('aigoodbroHostNavigationStatus');
    if (status) status.textContent = '';
    try {
      const result = await window.tokenMonitor.openAiGoodBroHost(button.dataset.aigoodbroHostAction);
      if (!result?.ok && status) status.textContent = t('settings.host.unavailable');
    } catch (_) {
      if (status) status.textContent = t('settings.host.unavailable');
    } finally { button.disabled = false; }
  });
}

window.tokenMonitor.onOpenSettings?.((section) => {
  openSettingsPanel();
  const target = section === 'menuBar' ? 'showTrayIconInput' : section === 'floatingBubble' ? 'floatingBubbleInput' : null;
  if (!target) return;
  setSettingsSectionExpanded('window', true);
  requestAnimationFrame(() => {
    const input = document.getElementById(target);
    input?.closest('.presence-feature')?.scrollIntoView({ block: 'start', behavior: 'instant' });
    input?.focus({ preventScroll: true });
  });
});`,
    'native workspace links in original settings');
  text = replaceOne(text,
    'function renderFloatingBubbleContent() {',
    `function renderAiGoodBroBubbleIcon(el) {
  el.classList.add('bars');
  const img = new Image();
  img.alt = '';
  img.style.width = '24px';
  img.style.height = '24px';
  img.style.objectFit = 'contain';
  img.src = '../../../assets/icon.png';
  el.replaceChildren(img);
}

function renderFloatingBubbleContent() {`,
    'bubble brand renderer');
  text = replaceOne(text,
    '  i18n.applyTranslations(document, currentLocale());\n  setThirdPartyAdapterFields();',
    "  i18n.applyTranslations(document, currentLocale());\n  const embeddedEngineVersion = document.getElementById('aboutEngineVersion');\n  if (embeddedEngineVersion) embeddedEngineVersion.textContent = t('settings.about.embeddedEngine', { version: state.appInfo?.version || '0.68.0' });\n  setThirdPartyAdapterFields();",
    'localize embedded engine version after language changes');
  text = replaceOne(text,
    "      input.checked = account.enabled !== false;\n      input.setAttribute('aria-label', t('settings.codex.toggleAccount', {",
    "      input.checked = account.enabled !== false;\n      input.disabled = account.hostManaged === true;\n      input.setAttribute('aria-label', t('settings.codex.toggleAccount', {",
    'host-owned account cannot be toggled in helper');
  text = replaceOne(text,
    "      remove.textContent = '✕';\n      remove.title = t('settings.codex.remove');\n      let confirmingRemove = false;\n      remove.addEventListener('click', async () => {",
    "      remove.textContent = account.hostManaged ? '↗' : '✕';\n      remove.title = account.hostManaged ? 'Manage in AiGoodBro' : t('settings.codex.remove');\n      let confirmingRemove = false;\n      remove.addEventListener('click', async () => {\n        if (account.hostManaged) {\n          await window.tokenMonitor.codex.removeAccount(account.id);\n          return;\n        }",
    'native account management button');
  text = replaceOne(text,
    "    el.textContent = (state.stats && window.TokenMonitorTrayText.formatTrayText(state.stats, mode, currentCurrency(), compactTokenDisplayOptions())) || 'Σ';",
    "    if (state.stats) el.textContent = window.TokenMonitorTrayText.formatTrayText(state.stats, mode, currentCurrency(), compactTokenDisplayOptions()) || '0';\n    else renderAiGoodBroBubbleIcon(el);",
    'bubble no-data brand');
  text = replaceOne(text,
    "    el.textContent = 'Σ';",
    '    renderAiGoodBroBubbleIcon(el);',
    'bubble icon mode');
  text = replaceOne(text,
    "  if (mode === 'icon') return { text: 'Σ' };",
    "  if (mode === 'icon') return { src: '../../../assets/icon.png' };",
    'bubble icon preview');
  text = replaceOne(text,
    "  if (id === 'app') return '../../../assets/icons/tray-token-monitor.png';",
    "  if (id === 'app') return '../../../assets/tray-curve.png';",
    'tray composer app icon');
  text = replaceOne(text,
    "  sources.app = '../../../assets/icons/tray-token-monitor.png';",
    "  sources.app = '../../../assets/tray-curve.png';",
    'tray provider app icon');
  text = replaceOne(text,
    "ctx.fillText(value === 'app' ? 'Σ' : String(value || '?').slice(0, 1).toUpperCase(), x + size / 2, y + size / 2 + 1);",
    "ctx.fillText(value === 'app' ? 'A' : String(value || '?').slice(0, 1).toUpperCase(), x + size / 2, y + size / 2 + 1);",
    'custom tray text fallback');
  text = replaceOne(text,
    "  if (els.aboutVersion) els.aboutVersion.textContent = state.appInfo?.version ? `v${state.appInfo.version}` : '—';",
    "  if (els.aboutVersion) els.aboutVersion.textContent = 'v2.3';\n  const embeddedEngineVersion = document.getElementById('aboutEngineVersion');\n  if (embeddedEngineVersion) embeddedEngineVersion.textContent = t('settings.about.embeddedEngine', { version: state.appInfo?.version || '0.68.0' });",
    'public version and bundled engine version');
  return text;
}

function patchStyles(source) {
  let text = replaceOne(source,
    '.settings-group { display: grid; min-width: 0; gap: 8px; }',
    '.settings-group { display: grid; min-width: 0; gap: 8px; }\n.aigoodbro-host-navigation { padding: 9px 12px; border-bottom: 1px solid rgba(var(--line-rgb), 0.075); }',
    'native workspace links without changing floating window geometry');
  text = replaceOne(text,
    '.app-update-settings > .app-update-notes {\n  margin-top: 4px;\n}',
    '.app-update-settings > .app-update-notes {\n  margin-top: 4px;\n}\n.app-update-settings.aigoodbro-host-updates > :not(.settings-group-header):not(.aigoodbro-managed-updates-note):not(.aigoodbro-host-update-action) {\n  display: none !important;\n}',
    'hide independent upstream updater controls');
  text = replaceOne(text,
    '.row-icon-token-monitor { -webkit-mask-image: url(../../../assets/icons/token-monitor.svg); mask-image: url(../../../assets/icons/token-monitor.svg); }',
    '.row-icon-token-monitor { background: url(../../../assets/icon.png) center / contain no-repeat; -webkit-mask-image: none; mask-image: none; }',
    'app mark asset');
  text = replaceOne(text,
    '.app-title-mark {\n  display: none;\n  font-weight: 700;\n  line-height: 1;\n}',
    '.app-title-mark {\n  display: none;\n  font-weight: 700;\n  line-height: 1;\n}\n.app-title-mark .aigoodbro-title-mark-icon {\n  display: inline-block;\n  width: 1em;\n  height: 1em;\n  object-fit: contain;\n  vertical-align: -0.08em;\n}',
    'CSP-safe title brand icon dimensions');
  return replaceOne(text,
    '.floating-bubble-tab span.bars img {\n  display: block;\n  width: auto;\n  height: 24px;\n}',
    '.floating-bubble-tab span.bars img {\n  display: block;\n  width: auto;\n  height: 24px;\n}\n.floating-bubble-tab .aigoodbro-floating-bubble-icon {\n  display: block;\n  width: 24px;\n  height: 24px;\n  object-fit: contain;\n  flex-shrink: 0;\n}',
    'CSP-safe bubble brand icon dimensions');
}

function patchTray(source) {
  let text = replaceOne(source,
    "const TRAY_ICON_PATH = path.join(__dirname, '..', '..', 'assets', 'icons', 'tray-token-monitor.png');",
    "const TRAY_ICON_PATH = path.join(__dirname, '..', '..', 'assets', 'tray-curve.png');",
    'mac tray brand icon');
  text = replaceOne(text,
    "return platform === 'darwin' && (isGeneratedTrayIconMode(id) || !showProviderBadge);",
    "return platform === 'darwin' && id !== 'app' && id !== 'custom' && (isGeneratedTrayIconMode(id) || !showProviderBadge);",
    'preserve color in the app and custom tray artwork');
  text = replaceOne(text,
    '    sized.setTemplateImage(true);',
    '    sized.setTemplateImage(false);',
    'mac tray full-color icon');
  text = replaceOne(text,
    "  const codexAccounts = Array.isArray(state.codexAccounts) ? state.codexAccounts : [];",
    `  const hostLabel = (zh, en) => String(state.locale || '').startsWith('zh') ? zh : en;
  const codexAccounts = Array.isArray(state.codexAccounts) ? state.codexAccounts : [];`,
    'localized native host menu labels');
  text = replaceOne(text,
    "    ...(edgeDockItem ? [edgeDockItem] : []),\n    { type: 'separator' },",
    `    ...(edgeDockItem ? [edgeDockItem] : []),
    ...(state.embeddedHost ? [
      { type: 'separator' },
      { label: hostLabel('打开 AiGoodBro 工作台', 'Open AiGoodBro Workbench'), click: callback('onOpenWorkbench') },
      { label: hostLabel('账号', 'Accounts'), click: callback('onOpenAccounts') },
      { label: hostLabel('任务', 'Tasks'), click: callback('onOpenTasks') },
      { label: hostLabel('AiGoodBro 设置', 'AiGoodBro Settings'), click: callback('onOpenHostSettings') },
      { label: hostLabel('检查 AiGoodBro 更新', 'Check AiGoodBro Updates'), click: callback('onCheckHostUpdates') }
    ] : []),
    { type: 'separator' },`,
    'native host tray menu');
  text = replaceOne(text,
    '  onOpenSettings,\n  onOpenView,\n  onQuit,',
    '  onOpenSettings,\n  onOpenView,\n  onOpenWorkbench,\n  onOpenAccounts,\n  onOpenTasks,\n  onOpenHostSettings,\n  onCheckHostUpdates,\n  onQuit,',
    'tray callback parameters');
  text = replaceOne(text,
    '    onOpenSettings,\n    onOpenView,\n    onQuit,',
    '    onOpenSettings,\n    onOpenView,\n    onOpenWorkbench,\n    onOpenAccounts,\n    onOpenTasks,\n    onOpenHostSettings,\n    onCheckHostUpdates,\n    onQuit,',
    'tray callback forwarding');
  return replaceOne(text,
    "tray.setToolTip('Token Monitor');",
    "tray.setToolTip('AiGoodBro');",
    'tray tooltip');
}

function patchEdgeDockController(source) {
  let text = replaceOne(source,
    '    onToggleRateMode,',
    '    onToggleRateMode,\n    onOpenMainWindow,',
    'sidebar host navigation callback');
  return replaceOne(text,
    '      if (bubbleCell !== index) {',
    `      if (onOpenMainWindow) {
        applyEffects(intent.retract());
        onOpenMainWindow();
        return;
      }
      if (bubbleCell !== index) {`,
    'sidebar click opens home while hover keeps the original detail cards');
}

function patchDiscordRpc(source) {
  let text = replaceOne(source,
    "const GITHUB_URL = 'https://github.com/Javis603/token-monitor';",
    "const GITHUB_URL = 'https://github.com/BLACKIELF/AgentHub-AiGoodBro';",
    'Discord product link');
  text = replaceOne(text, "    largeImageText: 'Token Monitor',", "    largeImageText: 'AiGoodBro',", 'Discord product label');
  return replaceOne(text, "    return { ...base, details: 'Token Monitor', state: 'No usage today' };",
    "    return { ...base, details: 'AiGoodBro', state: 'No usage today' };", 'Discord empty-state label');
}

function patchDeviceRuntime(source) {
  return replaceOne(source,
    "      deviceState.updateLimits(summary, 'limits', { epoch });",
    `      // Quota delivery must not wait for a multi-minute usage baseline.
      // This channel never creates a zero-usage record or a Hub upload.
      try { options.onLimits?.(structuredClone(summary)); }
      catch (error) { try { options.onError?.(error, 'limits-presentation'); } catch (_) {} }
      deviceState.updateLimits(summary, 'limits', { epoch });`,
    'independent limits delivery');
}

function patchCollector(source) {
  // v0.68 supplies monotonic bounded debounce and child-process watching.
  // Preserve AGB's additional idle interval after expensive scans, without
  // replacing the new upstream deadline, targeted queues or termination gate.
  let text = replaceOne(source,
    'async function collectUsageOnce(options) {',
    `async function collectUsageOnce(options) {
  if (process.env.AIGOODBRO_TOKEN_MONITOR_EMBEDDED === '1') {
    options = { ...options, codexLocalUsageEnabled: false, codexDotsEnabled: false, codexDotsVisible: false };
  }`,
    'embedded one-shot Dots capability remains closed');
  text = replaceOne(text,
    'function startCollector(options) {',
    `function startCollector(options) {
  if (process.env.AIGOODBRO_TOKEN_MONITOR_EMBEDDED === '1') {
    options = { ...options, codexLocalUsageEnabled: false, codexDotsEnabled: false, codexDotsVisible: false };
  }`,
    'embedded live Dots capability remains closed');
  text = replaceOne(text,
    '    const delayMs = watchDeadlineAt === 0',
    '    const debounceDelayMs = watchDeadlineAt === 0',
    'retain upstream bounded debounce');
  text = replaceOne(text,
    '      : Math.max(1, Math.min(watchDebounceMs, watchDeadlineAt - nowMs));',
    `      : Math.max(1, Math.min(watchDebounceMs, watchDeadlineAt - nowMs));
    const restUntil = Math.max(lastTickSuccessAt, lastTickFailureAt) + Math.min(lastTickDurationMs || 0, 30000);
    const delayMs = Math.max(debounceDelayMs, restUntil - Date.now());`,
    'idle interval after expensive scans');
  return replaceOne(text,
    `      // There is deliberately no cooldown on top of the debounce: the product
      // promises 3–5 s updates, and a cooldown would break that promise.
      if (tickInFlight) { scheduleTick(reason); return; }`,
    `      if (tickInFlight) { scheduleTick(reason); return; }
      // An independent refresh may have completed after this timer was armed.
      if (Date.now() < Math.max(lastTickSuccessAt, lastTickFailureAt) + Math.min(lastTickDurationMs || 0, 30000)) {
        scheduleTick(reason);
        return;
      }`,
    'preserve pending events until the scan can run');
}

function patchSessionMalformedRecords(source) {
  let text = source;
  for (const parser of ['parseClaudeTranscriptLines', 'parseCodexTranscriptData']) {
    const start = text.indexOf(`function ${parser}(`);
    const end = text.indexOf('\nfunction ', start + 1);
    if (start < 0 || end < 0) throw new Error(`${parser}: expected a bounded parser body`);
    const body = replaceOne(text.slice(start, end),
      '    try { obj = JSON.parse(trimmed); } catch (_) { continue; }',
      '    try { obj = JSON.parse(trimmed); } catch (_) { continue; }\n    if (!obj || typeof obj !== \'object\') continue;',
      `${parser} retained malformed record guard`);
    text = text.slice(0, start) + body + text.slice(end);
  }
  return text;
}

function patchEmbeddedSelfSync(source, provider) {
  const title = provider === 'cursor' ? 'Cursor' : 'Antigravity';
  const signature = provider === 'cursor' ? '{ selfSyncThrottle }' : '{ selfSyncThrottle, tokscaleCommand }';
  return replaceOne(source,
    `function create${title}SelfSync(${signature}) {`,
    `function create${title}SelfSync(${signature}) {
  // Embedded collection shares the native host's closed self-sync policy.
  // Preserve the upstream implementation for an independently launched app.
  if (process.env.AIGOODBRO_TOKEN_MONITOR_EMBEDDED === '1') {
    return { async maybeSync${title}() {} };
  }`,
    `${provider} embedded automatic self-sync capability remains closed`);
}

const TRANSFORMS = Object.freeze({
  'src/shared/collector.js': patchCollector,
  'src/shared/usage/deviceRuntime.js': patchDeviceRuntime,
  'src/shared/sessionDetail.js': patchSessionMalformedRecords,
  'src/shared/providers/cursor/selfSync.js': (source) => patchEmbeddedSelfSync(source, 'cursor'),
  'src/shared/providers/antigravity/selfSync.js': (source) => patchEmbeddedSelfSync(source, 'antigravity'),
  'src/electron/main.js': patchMain,
  'src/electron/edgeDock/controller.js': patchEdgeDockController,
  'src/electron/discordRpc.js': patchDiscordRpc,
  'src/electron/preload.js': patchPreload,
  'src/shared/appUpdater.js': patchUpdater,
  'src/electron/renderer/index.html': patchIndex,
  'src/electron/renderer/i18n.js': patchI18n,
  'src/electron/renderer/edgeDock/index.html': (source) => replaceOne(source, '<title>Token Monitor Dock</title>', '<title>AiGoodBro Dock</title>', 'dock title'),
  'src/electron/renderer/styles.css': patchStyles,
  'src/electron/renderer/app.js': patchApp,
  'src/electron/renderer/trayComposer.js': (source) => replaceOne(source, "content.textContent = preview.text || 'Σ';", "content.textContent = preview.text || 'A';", 'tray preview fallback'),
  'src/electron/tray.js': patchTray
});

function transformStage(stageRoot) {
  if (!stageRoot || !path.isAbsolute(stageRoot)) throw new Error('Expected an absolute staging app root');
  const changed = [];
  // Validate and prepare every output before touching staging, so a changed
  // upstream anchor or hash cannot leave a half-branded app behind.
  for (const [relativePath, transform] of Object.entries(TRANSFORMS)) {
    const target = path.join(stageRoot, relativePath);
    const source = fs.readFileSync(target, 'utf8');
    const actual = crypto.createHash('sha256').update(source).digest('hex');
    if (actual !== INPUT_SHA256[relativePath]) throw new Error(`Pinned upstream hash changed: ${relativePath}`);
    const output = transform(source);
    if (output === source) throw new Error(`No staged change produced: ${relativePath}`);
    changed.push({ target, output, relativePath });
  }
  for (const { target, output } of changed) fs.writeFileSync(target, output, 'utf8');
  return changed.map(({ relativePath }) => relativePath);
}

if (require.main === module) {
  try {
    const stageRoot = process.argv[2];
    const changed = transformStage(stageRoot);
    console.log(JSON.stringify({ ok: true, changed }));
  } catch (error) {
    console.error(`AiGoodBro desktop staging transform failed: ${error.message}`);
    process.exitCode = 1;
  }
}

module.exports = { transformStage, replaceOne, INPUT_SHA256, patchSessionMalformedRecords };
