'use strict';
// Full production settings bodies and currency APIs; no GUI or real settings.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(process.argv[2], 'utf8');
const packageRoot = path.resolve(process.argv[3]);
const expectVulnerable = process.argv[4] === '--expect-vulnerable';
const names = ['defaultSettings', 'readSettings', 'normalizeCurrencyOverrides', 'effectiveHubConfig'];
const definitions = names.map((name) => {
  const start = source.indexOf('function ' + name + '(');
  const end = source.indexOf('\nfunction ', start + 1);
  assert.ok(start >= 0 && end > start, name);
  return source.slice(start, end);
}).join('\n');

function check(saved, { embedded = true, failure = null } = {}) {
  let currencyVisits = 0;
  const context = { Math, Number, String, Boolean, Object, Array, Set, JSON, Date, path, console: { warn() {} } };
  for (const match of definitions.matchAll(/\b([A-Za-z_$][\w$]*)\s*\(/g)) {
    if (!(match[1] in context)) context[match[1]] = (...args) => args[0] === undefined ? [] : args[0];
  }
  for (const match of definitions.matchAll(/\b[A-Z][A-Z0-9_]+\b/g)) {
    if (!(match[0] in context)) context[match[0]] = 0;
  }
  Object.assign(context, {
    process: { env: { AIGOODBRO_TOKEN_MONITOR_EMBEDDED: embedded ? '1' : '0',
      TOKEN_MONITOR_HUB_URL: 'https://inherited.invalid', TOKEN_MONITOR_SECRET: 'synthetic-inherited-secret',
      TOKEN_MONITOR_PORT: '19191', TOKEN_MONITOR_SYNC_SESSION_TITLES: '1' }, platform: 'darwin' },
    app: { getPath: () => '/isolated/settings' },
    fs: { existsSync: () => false,
      readFileSync: () => { if (failure) throw Object.assign(new Error('synthetic settings read failure'), { code: failure }); return JSON.stringify(saved); },
      lstatSync: () => { throw new Error('isolated absent file'); } },
    fontSettingsApi: require(path.join(packageRoot, 'src/shared/fontSettings.js')),
    motionPreferenceApi: require(path.join(packageRoot, 'src/electron/motionPreference.js')),
    IS_AIGOODBRO_EMBEDDED: embedded,
    HUB_DEFAULT_PORT: 17321,
    seedSplitClients: (clients) => ({ clients, evaluated: [] }),
    loadCredentialSettings: () => ({}),
    normalizeTrayModeSettings: () => ({}),
    normalizeWindowBehaviorSettings: (settings) => settings,
    normalizeHubMode: (mode) => mode,
    normalizeCurrency: require(path.join(packageRoot, 'src/shared/currency.js')).normalizeCurrency,
    initialAccountSettings: () => ({}),
    currencyVisit: () => { currencyVisits++; }
  });
  vm.runInNewContext(definitions + '\nconst originalCurrencyOverrides = normalizeCurrencyOverrides; normalizeCurrencyOverrides = (value) => { currencyVisit(); return originalCurrencyOverrides(value); }; globalThis.observed = readSettings(); globalThis.endpoint = effectiveHubConfig(observed);', context, { timeout: 1000 });
  assert.equal(currencyVisits, 1, 'settings reached the real currency normalizer');
  return { mode: context.observed.hubMode, endpoint: context.endpoint.url,
    secret: context.observed.secret, hostSecret: context.observed.hubHostSecret,
    hostPort: context.observed.hubHostPort, syncTitles: context.observed.hubSyncSessionTitles };
}

const fresh = check({});
assert.equal(fresh.mode, 'local'); assert.equal(fresh.endpoint, null);
const local = check({ hubMode: 'local', hubUrl: '', currencyRates: { EUR: 1.1 } });
assert.equal(local.mode, 'local'); assert.equal(local.endpoint, null);
const optedIn = check({ hubMode: 'client', hubUrl: 'https://saved-opt-in.invalid', secret: 'synthetic-saved-secret' });
assert.equal(optedIn.mode, 'client'); assert.equal(optedIn.endpoint, 'https://saved-opt-in.invalid');
assert.equal(optedIn.secret, 'synthetic-saved-secret', 'saved explicit credentials retain their source');
const malformedLocal = check({ hubMode: 'local', hubUrl: '', currencyRates: { EUR: { toString: null, valueOf: null } } });
if (expectVulnerable) {
  assert.equal(malformedLocal.mode, 'client');
  assert.equal(malformedLocal.endpoint, 'https://inherited.invalid');
  console.log(JSON.stringify({ ok: true, reproducedVulnerability: true, fresh, local, optedIn, malformedLocal,
    scope: 'real pre-fix packaged settings bodies; synthetic interfaces only' }));
} else {
  assert.equal(malformedLocal.mode, 'local'); assert.equal(malformedLocal.endpoint, null);
  assert.equal(malformedLocal.secret, ''); assert.equal(malformedLocal.hostSecret, '');
  assert.equal(malformedLocal.hostPort, 17321); assert.equal(malformedLocal.syncTitles, false);
  const unreadable = check({}, { failure: 'EIO' });
  assert.equal(unreadable.mode, 'local'); assert.equal(unreadable.endpoint, null);
  const standalone = check({ hubMode: 'local', currencyRates: { EUR: { toString: null, valueOf: null } } }, { embedded: false });
  assert.equal(standalone.mode, 'client'); assert.equal(standalone.endpoint, 'https://inherited.invalid');
  console.log(JSON.stringify({ ok: true, checks: ['fresh-local', 'saved-normal-local', 'saved-explicit-client-opt-in',
    'real-currency-normalization-failure-remains-local', 'settings-read-failure-remains-local',
    'no-inherited-cloud-credentials-port-or-title-sync', 'standalone-upstream-behavior-retained'],
    fresh, local, optedIn, malformedLocal, unreadable, standalone,
    scope: 'exact production settings bodies and currency/font/motion APIs; isolated filesystem/credentials; no network' }));
}
