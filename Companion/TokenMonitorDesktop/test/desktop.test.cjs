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

function stagedSource(t, relativePath) {
  const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'agb-tm-behavior-'));
  t.after(() => fs.rmSync(stage, { recursive: true, force: true }));
  for (const source of Object.keys(INPUT_SHA256)) {
    const target = path.join(stage, source);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.copyFileSync(path.join(upstreamRoot, source), target);
  }
  transformStage(stage);
  return fs.readFileSync(path.join(stage, relativePath), 'utf8');
}

test('limits arrive before history without publishing invented usage, and stopped runtimes stay silent', (t) => {
  const source = stagedSource(t, 'src/shared/usage/deviceRuntime.js');
  const context = { module: { exports: {} }, structuredClone, require(name) {
    if (name === './deviceState') return require(path.join(upstreamRoot, 'src/shared/usage/deviceState'));
    return {};
  } };
  vm.runInNewContext(source, context);
  let usage, limits;
  const records = [], uploads = [], seenLimits = [];
  let observerThrows = false;
  const runtime = context.module.exports.createDeviceRuntime({
    onLimits(summary) {
      seenLimits.push(structuredClone(summary));
      summary.providers[0].remaining = 0;
      if (observerThrows) throw new Error('observer failed');
    },
    onError() { throw new Error('diagnostic observer failed'); },
    onRecord(record) { records.push(record); },
    sink: { enqueue(record) { uploads.push(record); } }
  }, {
    createUsageRuntime(options) { usage = options; return { stop() {} }; },
    createLimitsRuntime(_options, callbacks) { limits = callbacks; return { stop() {} }; }
  });
  const quota = { providers: [{ provider: 'codex', remaining: 75 }] };
  limits.onUpdate(quota);
  assert.equal(seenLimits.length, 1);
  assert.equal(quota.providers[0].remaining, 75, 'UI receives an isolated copy');
  assert.equal(runtime.getSnapshot(), null);
  assert.equal(records.length, 0);
  assert.equal(uploads.length, 0, 'quota-only events never create a Hub usage record');
  usage.onUpdate({ today: { tokens: 7 }, month: { tokens: 12 }, allTime: { tokens: 30 } }, 'baseline');
  assert.equal(records.length, 1);
  assert.equal(uploads.length, 1);
  assert.equal(records[0].today.tokens, 7);
  assert.equal(records[0].limits.providers[0].remaining, 75);
  observerThrows = true;
  assert.doesNotThrow(() => limits.onUpdate(quota));
  assert.equal(records.length, 2, 'throwing UI/diagnostic observers cannot block ordinary delivery');
  runtime.stop();
  limits.onUpdate(quota);
  usage.onUpdate({ today: { tokens: 99 } }, 'late');
  assert.equal(seenLimits.length, 2);
  assert.equal(records.length, 2, 'late callbacks from a stopped runtime cannot overwrite the new epoch');
});

test('stopping a collector clears presented quotas and invalidates deferred old quotas', (t) => {
  const source = stagedSource(t, 'src/electron/main.js');
  const stop = source.match(/let aigoodbroPendingLimits = null;\nfunction stopLocalCollector[\s\S]*?\n\}/)?.[0];
  const observer = source.match(/onLimits: IS_AIGOODBRO_EMBEDDED \? (\(limits\) => \{[\s\S]*?\n    \}) : undefined/)?.[1];
  assert.ok(stop && observer);
  const events = [];
  let stopped = 0;
  let rate = { burnPerMinute: 1200 };
  const rateStates = [];
  const context = {
    IS_AIGOODBRO_EMBEDDED: true,
    usageRuntimeReconciler: { cancel() {}, setActiveKey() {} },
    deviceRuntimeHandle: { stop() { stopped++; } },
    localDevice: {}, localStats: {},
    resetAiGoodBroTokenRate() { rate = null; },
    aigoodbroTokenRateSnapshot() { rateStates.push(rate); return rate; },
    sendMainWindowEvent(channel, payload, current) { events.push({ channel, payload, current }); }
  };
  vm.runInNewContext(`${stop}\nconst publishLimits = ${observer};\nthis.fixture = { stopLocalCollector, publishLimits };`, context);
  context.fixture.publishLimits({ providers: [{ provider: 'codex', remaining: 75 }] });
  assert.equal(events[0].current(), true);
  context.fixture.stopLocalCollector();
  assert.equal(stopped, 1);
  assert.equal(rate, null, 'a stopped collector cannot retain the prior rate sample');
  assert.deepEqual(rateStates, [null], 'source reset publishes unknown before any replacement sample');
  assert.equal(events[0].current(), false, 'a deferred old quota must never reach the renderer');
  assert.equal(events[1].payload.data.limits, null, 'already-visible quota is cleared too');
  assert.equal(events[1].current(), true);
  context.deviceRuntimeHandle = { stop() {} };
  context.fixture.publishLimits({ providers: [] });
  assert.equal(events[1].current(), false, 'a deferred clear cannot erase newer quota');
  assert.equal(events[2].current(), true);
});

test('rate-only events replace cached stats before render deduplication and cannot revive expired state', (t) => {
  const source = stagedSource(t, 'src/electron/renderer/app.js');
  const functions = ['receiveAiGoodBroTokenRate', 'observeLiveTokenRate'].map((name) => {
    const body = source.match(new RegExp('function ' + name + '\\([^\\n]*\\) \\{[\\s\\S]*?\\n\\}'))?.[0];
    assert.ok(body, name);
    return body;
  }).join('\n');
  const initial = { mode: 'burn', formattedValue: '1.3K', idle: false, revision: 1 };
  let renders = 0;
  const context = { isAiGoodBroSharedTokenRate: true,
    state: { settings: { showLiveTokenRate: true }, stats: { aigoodbroTokenRate: initial }, aigoodbroTokenRate: initial },
    renderTokenRate() { renders += 1; },
    scheduleLiveTokenRateExpiry() { throw new Error('shared rate must not add an expiry timer'); } };
  vm.runInNewContext(functions, context);
  context.receiveAiGoodBroTokenRate(null);
  context.observeLiveTokenRate(context.state.stats);
  assert.equal(context.state.stats.aigoodbroTokenRate, null);
  assert.equal(context.state.aigoodbroTokenRate, null);
  assert.equal(renders, 1, 'a settings toggle cannot resurrect the expired stats DTO');
  const idle = { ...initial, idle: true };
  const speed = { ...idle, mode: 'speed', formattedValue: '0.5' };
  for (const sample of [idle, speed]) {
    context.receiveAiGoodBroTokenRate(sample);
    context.observeLiveTokenRate(context.state.stats);
    assert.equal(context.state.aigoodbroTokenRate, sample);
  }
  const before = renders;
  context.state.stats.aigoodbroTokenRate = initial;
  context.receiveAiGoodBroTokenRate(speed);
  assert.equal(context.state.stats.aigoodbroTokenRate, speed, 'equal events still repair stale stats');
  assert.equal(renders, before, 'equal values do not repaint');
});

test('local bootstrap and renderer reload preserve only current pending quota evidence', (t) => {
  const source = stagedSource(t, 'src/electron/main.js');
  const bootstrap = source.match(/    const bootstrapStats = withHistoryPreview[\s\S]*?    return bootstrapStats;/)?.[0];
  const replay = source.match(/    if \(IS_AIGOODBRO_EMBEDDED && aigoodbroPendingLimits && deviceRuntimeHandle\) \{[\s\S]*?\n    \}/)?.[0];
  assert.ok(bootstrap && replay);
  const events = [];
  const context = { IS_AIGOODBRO_EMBEDDED: true, localDevice: null,
    aggregateDevices: devices => ({ devices, periods: { today: { totalTokens: 0 } } }), withHistoryPreview: x => x,
    aigoodbroPendingLimits: { providers: [{ provider: 'codex', remaining: 75 }] }, deviceRuntimeHandle: {},
    sendMainWindowEvent: (_channel, payload, current) => events.push({ payload, current }) };
  const pull = () => vm.runInNewContext(`(() => {${bootstrap}})()`, context);
  assert.equal(pull().aigoodbroUsagePending, true);
  const { projectLimitStatsForDisplay } = require(path.join(upstreamRoot, 'src/electron/limits/statsPresentation'));
  const { projectModelAliasStats } = require(path.join(upstreamRoot, 'src/electron/modelAliasPresentation'));
  assert.equal(projectModelAliasStats(projectLimitStatsForDisplay(pull(), { syncActive: false }), []).aigoodbroUsagePending, true, 'production display projections retain pending evidence');
  context.localDevice = { today: { tokens: 0 } };
  assert.equal(pull().aigoodbroUsagePending, undefined, 'real zero baseline is known usage');
  context.localDevice = null; context.IS_AIGOODBRO_EMBEDDED = false;
  assert.equal(pull().aigoodbroUsagePending, undefined, 'standalone/remote behavior stays intact');
  context.IS_AIGOODBRO_EMBEDDED = true;
  vm.runInNewContext(replay, context);
  assert.equal(events.length, 1);
  assert.equal(events[0].current(), true);
  context.aigoodbroPendingLimits = null;
  assert.equal(events[0].current(), false, 'baseline or stop invalidates a queued replay');
  vm.runInNewContext(replay, context);
  assert.equal(events.length, 1);
  context.aigoodbroPendingLimits = {}; context.deviceRuntimeHandle = null;
  vm.runInNewContext(replay, context);
  assert.equal(events.length, 1, 'stopped runtime cannot replay');
});

test('production quota-only rendering reveals Home and Limits without inventing usage', async (t) => {
  const source = stagedSource(t, 'src/electron/renderer/app.js');
  const extract = (name) => {
    const match = source.match(new RegExp(`function ${name}\\([^\\n]*\\) \\{[\\s\\S]*?\\n\\}`));
    assert.ok(match, name);
    return match[0];
  };
  const node = (hidden = true) => {
    const classes = new Set(hidden ? ['hidden'] : []);
    return { children: [], textContent: '0', style: { setProperty() {} },
      classList: { add: (...xs) => xs.forEach(x => classes.add(x)), remove: (...xs) => xs.forEach(x => classes.delete(x)), contains: x => classes.has(x), toggle(x, value) { if (value) classes.add(x); else classes.delete(x); } },
      append(...xs) { this.children.push(...xs); }, replaceChildren(...xs) { this.children = xs; },
      querySelector(selector) { const cls = selector.slice(1); const find = n => n.className?.split(' ').includes(cls) ? n : n.children?.map(find).find(Boolean); return this.children.map(find).find(Boolean); }
    };
  };
  const els = Object.fromEntries(['shell', 'totalTokens', 'totalTokensCompact', 'cost', 'fixedPeriodMessage', 'homePanel', 'breakdown', 'serviceStatusPanel', 'limitsPanel', 'trendsPanel', 'sessionDetail', 'sessionDetailHead', 'viewBackRow', 'settingsPanel'].map(id => [id, node()]));
  const state = { stats: null, settings: { limitsEnabled: true }, breakdown: 'home', streamConnected: false, streamFailure: { reason: 'offline' } };
  let onPush, ready = 0, surface = 'main', defer = false;
  const context = {
    state, els, Map, Set, Date, JSON,
    window: { tokenMonitor: { onStatsPush(fn) { onPush = fn; }, signalContentReady() { ready++; } } },
    document: { createElement: () => node(false) },
    visibleStatsSurface: () => surface, statsRenderScheduler: { request() {} },
    isSettingsPanelOpen: () => !els.settingsPanel.classList.contains('hidden'),
    renderViewSwitcher() {}, renderSessionPager() {}, hideHomeActivityTooltip() {}, t: key => key,
    homeModuleIds: () => ['limits', 'tool'], enabledLimitProviderSet: () => new Set(['codex']), hiddenHomeLimitProviderSet: () => new Set(),
    LIMIT_PROVIDERS: [{ id: 'codex', label: 'Codex' }], clientColors: {},
    limitProviderOrderApi: { orderedLimitProviders: rows => rows },
    limitProviderPresentationApi: { limitProviderCompactWindows: (_p, windows) => windows },
    homeOverviewApi: { homeLimitsAwaitingFirstData: require(path.join(upstreamRoot, 'src/electron/renderer/homeOverview')).homeLimitsAwaitingFirstData, homeLimitAccountsForProviders: ({ providers, hiddenProviderIds }) => providers.filter(p => !hiddenProviderIds.includes(p.provider)).map(p => ({ name: 'Codex', providerId: p.provider, windows: p.windows || [] })) },
    homeModuleShell() { const module = node(false), body = node(false); module.append(body); return { module, body }; },
    applyHomeListMark() {}, iconKindFor() {},
    limitDetailTooltipShouldHoldRender: () => false,
    codexAccountControl: { deferRender: () => defer, stateSignature: () => [] },
    providersByLimitProviderId: providers => new Map(providers.map(p => [p.provider, [p]])),
    currentLocale: () => 'en', captureLimitResetMotion() {}, animateLimitResets() {}, animateCachedLimitBarsFromZero() {},
    missingLimitProviderStatus: () => 'unavailable', limitProviderColor: () => '',
    renderLimitProviderSolo: (_id, _label, provider) => ({ provider }), renderLimitProviderGroup() {}
  };
  const handler = source.match(/window\.tokenMonitor\.onStatsPush\?\.\(\(payload\) => \{[\s\S]*?\n\}\);/)?.[0];
  vm.runInNewContext(`let contentReadySignaled = false;\n${['homeLimitRows', 'renderHomeLimitModule', 'renderLimits', 'hidePeriodContentForMessage', 'signalContentReady', 'render'].map(extract).join('\n')}\n${handler}\nthis.renderFixture = render; this.resetReady = () => { contentReadySignaled = false; };`, context);
  const limits = { providers: [{ provider: 'codex', status: 'ok', remaining: 75, windows: [] }] };
  onPush({ event: 'aigoodbro:limits', data: { limits } });
  assert.equal(state.stats, null);
  assert.equal(els.totalTokens.textContent, '—');
  assert.equal(els.totalTokensCompact.textContent, '—');
  assert.equal(els.cost.textContent, '');
  assert.ok(els.homePanel.querySelector('.home-limit-account'));
  assert.equal(els.homePanel.classList.contains('hidden'), false);
  assert.equal(els.limitsPanel.classList.contains('hidden'), true);
  assert.equal(ready, 1);
  assert.equal(state.streamConnected, false);
  assert.equal(state.streamFailure.reason, 'offline');
  state.stats = { aigoodbroUsagePending: true, periods: { today: { totalTokens: 0, costUsd: 0 } } };
  context.renderFixture();
  assert.equal(els.totalTokens.textContent, '—', 'bootstrap aggregate is still unknown usage');
  assert.ok(els.homePanel.querySelector('.home-limit-account'));
  context.resetReady(); ready = 0; state.breakdown = 'limits';
  context.renderFixture();
  assert.equal(els.limitsPanel.classList.contains('hidden'), false);
  assert.equal(els.homePanel.classList.contains('hidden'), true);
  assert.equal(els.limitsPanel.children[0].provider.remaining, 75);
  assert.equal(ready, 1);
  context.resetReady(); ready = 0; defer = true;
  onPush({ event: 'aigoodbro:limits', data: { limits } });
  assert.equal(ready, 0, 'deferred account-switch render cannot signal new content');
  defer = false;
  onPush({ event: 'aigoodbro:limits', data: { limits: null } });
  assert.equal(els.limitsPanel.classList.contains('hidden'), true);
  assert.equal(ready, 0);
  state.breakdown = 'home'; context.renderFixture();
  assert.equal(els.homePanel.querySelector('.home-limit-account'), undefined, 'clear removes home quota rows');
  state.settings.limitsEnabled = false;
  onPush({ event: 'aigoodbro:limits', data: { limits } });
  assert.equal(ready, 0);
  state.settings.limitsEnabled = true; surface = null;
  onPush({ event: 'aigoodbro:limits', data: { limits } });
  assert.equal(ready, 0, 'hidden window waits for visible paint');
  surface = 'main'; els.settingsPanel.classList.remove('hidden'); context.renderFixture();
  assert.equal(ready, 0, 'settings overlay does not count as quota content');
  els.settingsPanel.classList.add('hidden'); context.renderFixture();
  assert.equal(ready, 1);
  // Execute the real stats branch up to its scheduler, with only outer helpers stubbed.
  Object.assign(context, { allTimeSessions: { attach: x => x, invalidate() {} }, sessionStatsForDisplay: x => x, overlayAllTimeSessions: x => x, observeLiveTokenRate() {}, observeDisplayLiveTokenRates() {}, applyCodexActiveAccountFromStats() {}, fixedPeriodRangesApi: { isDerived: () => false }, warmFixedPeriodHistory() {}, maybeUpdateBarsIcon() {}, restartTimer() {} });
  const stats = { periods: { today: { totalTokens: 19, costUsd: 0.25 } }, limits };
  onPush({ event: 'stats', data: { stats, reason: 'local' } });
  assert.equal(state.stats, stats);
  assert.equal(state.aigoodbroLimits, null);
  assert.equal(state.streamConnected, false);
  if (process.env.AIGOODBRO_QUOTA_CHROMIUM === '1') {
    const { chromium } = require('playwright');
    const browser = await chromium.launch({ executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH || undefined });
    t.after(() => browser.close());
    const page = await browser.newPage({ viewport: { width: 420, height: 610 } });
    await page.route(/^https?:/, route => route.abort());
    const ids = [...Object.keys(els), 'toolDetailFooter', 'sessionPagerHost'];
    const css = fs.readFileSync(path.join(upstreamRoot, 'src/electron/renderer/styles.css'), 'utf8');
    await page.setContent(`<style>${css}</style><main class="shell" style="height:580px">${ids.filter(id => id !== 'shell').map(id => `<section id="${id}" class="${id === 'homePanel' ? 'home-panel ' : id === 'fixedPeriodMessage' ? 'fixed-period-message ' : ''}hidden"></section>`).join('')}</main>`);
    await page.locator('main').evaluate(el => { el.id = 'shell'; });
    const functions = Object.entries(context).filter(([,value]) => typeof value === 'function' && !value.toString().includes('[native code]')).map(([key,value]) => [key, value.toString()]);
    await page.evaluate(({ functions, production, handler }) => {
      window.state = { stats: null, settings: { limitsEnabled: true }, breakdown: 'home', period: 'today', streamConnected: false };
      window.els = Object.fromEntries([...document.querySelectorAll('[id]')].map(el => [el.id, el]));
      window.ready = 0;
      window.tokenMonitor = { onStatsPush(fn) { window.push = fn; }, signalContentReady() { window.ready++; } };
      for (const [key, value] of functions) window[key] = (0, eval)(`(${/^(?:async )?\w+\(/.test(value) ? 'function ' + value : value})`);
      window.visibleStatsSurface = () => 'main';
      window.isSettingsPanelOpen = () => !els.settingsPanel.classList.contains('hidden');
      window.homeModuleShell = () => { const module = document.createElement('article'), body = document.createElement('div'); module.append(body); return { module, body }; };
      window.codexAccountControl = { deferRender: () => false, stateSignature: () => [] };
      window.LIMIT_PROVIDERS = [{ id: 'codex', label: 'Codex' }]; window.clientColors = {};
      window.limitProviderOrderApi = { orderedLimitProviders: x => x };
      window.limitProviderPresentationApi = { limitProviderCompactWindows: (_p, w) => w };
      window.homeOverviewApi = { homeLimitsAwaitingFirstData: () => false, homeLimitAccountsForProviders: ({providers}) => providers.map(p => ({ name: 'Codex', providerId: p.provider, windows: [] })) };
      window.renderLimitProviderSolo = () => { const row = document.createElement('div'); row.textContent = '75%'; return row; };
      window.statsRenderScheduler = { request() {} };
      (0, eval)(`let contentReadySignaled = false;${production}\n${handler}\nwindow.paint = render;`);
    }, { functions, production: ['homeLimitRows', 'renderHomeLimitModule', 'renderLimits', 'hidePeriodContentForMessage', 'signalContentReady', 'render'].map(extract).join('\n'), handler });
    await page.evaluate(limits => push({ event: 'aigoodbro:limits', data: { limits } }), limits);
    assert.equal(await page.locator('#homePanel .home-limit-account').isVisible(), true);
    const quotaBounds = await page.locator('#homePanel .home-limit-account').boundingBox();
    assert.ok(quotaBounds.y >= 0 && quotaBounds.y + quotaBounds.height <= 610, 'cold Home quota fits inside the viewport with production CSS');
    assert.equal(await page.locator('#totalTokens').textContent(), '—');
    assert.equal(await page.evaluate(() => ready), 1);
    await page.evaluate(() => { state.stats = { aigoodbroUsagePending: true }; state.breakdown = 'limits'; paint(); });
    assert.equal(await page.locator('#limitsPanel').isVisible(), true);
    assert.equal(await page.locator('#homePanel').isVisible(), false);
    await page.evaluate(() => push({ event: 'aigoodbro:limits', data: { limits: null } }));
    assert.equal(await page.locator('#limitsPanel').isVisible(), false);
    await page.evaluate(() => {
      state.breakdown = 'home'; state.suppressInitialNumberAnimation = true;
      window.fixedPeriodRangesApi = { isDerived: () => false };
      for (const name of ['syncLiveTokenRateFooterState','renderSessionUsageArchiveStatus','ensureBreakdownVisible','cancelNumberAnimation','updateTotalCompact','renderTokenRate','setRefreshButtonState','stopServiceStatusTicker','renderFloatingBubbleContent']) window[name] = () => {};
      window.numberAnimValue = 0; window.formatNumber = n => String(n); window.formatCost = n => `$${n}`;
      window.headlineNumberIsAnimatingTo = () => false;
      window.renderHome = () => { els.homePanel.textContent = `Total ${state.stats.periods.today.totalTokens}`; };
      push({ event: 'stats', data: { stats: { periods: { today: { totalTokens: 19, costUsd: 0.25 } } }, reason: 'local' } });
      paint();
    });
    assert.equal(await page.locator('#totalTokens').textContent(), '19');
    assert.equal(await page.locator('#cost').textContent(), '$0.25');
    assert.equal(await page.locator('#fixedPeriodMessage').isVisible(), false);
    assert.equal(await page.locator('#homePanel').textContent(), 'Total 19');
    console.log('Real Chromium cold-quota visibility and real-history transition passed');
  }
});

function watchHarness(t) {
  const source = stagedSource(t, 'src/shared/collector.js');
  const begin = source.indexOf('  function recordWatchClients(');
  const end = source.indexOf("  // chokidar", begin);
  assert.ok(begin >= 0 && end > begin);
  let now = 100000, nextTimer = 0, scheduled = 0;
  const timers = new Map(), scans = [];
  const context = {
    Date: { now: () => now }, performance: { now: () => now }, Math, Set, Array,
    stopped: false, tickInFlight: false, debounceTimer: null, codexLocalSource: null,
    watchDeadlineAt: 0, watchMaxWaitMs: 10000, watchDebounceMs: 1000,
    lastTickSuccessAt: 0, lastTickFailureAt: 0, lastTickDurationMs: null,
    scheduledWatchClients: new Set(), scheduledWatchNeedsFullScan: false,
    sourceSyncQueue: { takeDue: () => [] },
    setTimeout(callback, delay) {
      const id = ++nextTimer;
      scheduled++;
      timers.set(id, { at: now + delay, callback });
      return id;
    },
    clearTimeout(id) { timers.delete(id); },
    runTick(reason, options) { scans.push({ at: now, reason, clients: [...options.targetClients] }); }
  };
  vm.runInNewContext(source.slice(begin, end), context);
  function advance(to) {
    let turns = 0;
    while (true) {
      const next = [...timers.entries()].sort((a, b) => a[1].at - b[1].at)[0];
      if (!next || next[1].at > to) break;
      assert.ok(++turns < 100, 'watcher must not spin while the collector is busy');
      now = next[1].at;
      timers.delete(next[0]);
      next[1].callback();
    }
    now = to;
  }
  return { context, scans, advance, scheduled: () => scheduled, timers, source };
}

test('continuous log writes refresh within the max wait and preserve all changed clients', (t) => {
  const h = watchHarness(t);
  for (let offset = 0; offset < 10000; offset += 500) {
    h.advance(100000 + offset);
    h.context.scheduleTick('watch', [offset % 1000 ? 'codex' : 'claude']);
  }
  assert.equal(h.scans.length, 0);
  h.advance(110000);
  assert.equal(h.scans.length, 1);
  assert.equal(h.scans[0].at, 110000);
  assert.deepEqual(h.scans[0].clients.sort(), ['claude', 'codex']);
  h.context.scheduleTick('watch', []);
  h.context.scheduleTick('watch', ['codex']);
  h.advance(111000);
  assert.deepEqual(h.scans[1].clients, [], 'unknown source still requests all clients');
});

test('slow scans get idle time, pending events survive, and shutdown cancels the catch-up', (t) => {
  const h = watchHarness(t);
  h.context.tickInFlight = true;
  h.context.scheduleTick('watch', ['codex']);
  h.context.scheduleTick('watch', ['claude']);
  h.advance(115000);
  assert.equal(h.scans.length, 0);
  assert.ok(h.scheduled() < 25, 'busy retry is bounded even after the batch deadline');
  h.context.tickInFlight = false;
  h.context.lastTickSuccessAt = 115000;
  h.context.lastTickDurationMs = 8000;
  h.advance(122999);
  assert.equal(h.scans.length, 0);
  h.advance(123000);
  assert.deepEqual(h.scans[0].clients.sort(), ['claude', 'codex']);
  h.context.scheduleTick('watch', ['codex']);
  Object.assign(h.context, {
    runtimeAbortController: { abort() {} }, intervalTimer: null,
    clearRolloverHistoryRetry() {}, closeWatchers() {}, watchedDirectoryKey: null
  });
  h.context.sourceSyncQueue.stop = () => {};
  const stop = h.source.slice(h.source.indexOf('  function stop(options = {}) {'), h.source.indexOf('  function whenIdle() {'));
  vm.runInNewContext(stop, h.context);
  h.context.stop();
  h.advance(180000);
  assert.equal(h.scans.length, 1);
  assert.equal(h.timers.size, 0);
});

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
    once() {}, quit() {}, getVersion: () => '0.68.0'
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
      TOKEN_MONITOR_CODEX_LOCAL_USAGE: '1',
      TOKEN_MONITOR_HUB_URL: 'https://inherited.invalid',
      TOKEN_MONITOR_SECRET: 'synthetic-inherited-secret',
      TOKEN_MONITOR_PORT: '19191',
      TOKEN_MONITOR_SYNC_SESSION_TITLES: '1',
      AIGOODBRO_TOKEN_MONITOR_PARENT_PID: '4321'
    };
    const outsideDots = process.env.TOKEN_MONITOR_CODEX_LOCAL_USAGE;
    const cloudKeys = ['TOKEN_MONITOR_HUB_URL', 'TOKEN_MONITOR_SECRET', 'TOKEN_MONITOR_PORT', 'TOKEN_MONITOR_SYNC_SESSION_TITLES'];
    const outsideCloud = cloudKeys.map((key) => process.env[key]);
    const trusted = runBootstrap({ env, execPath: '/fixture/AiGoodBro Token Core' });
    await new Promise((resolve) => setImmediate(resolve));
    assert.deepEqual(trusted.exit, []);
    assert.equal(trusted.bridgeStarted, 1);
    assert.equal(trusted.upstreamLoaded, 1);
    assert.deepEqual(trusted.setPath, [['userData', support]]);
    assert.equal(env.TOKEN_MONITOR_CODEX_LOCAL_USAGE, '0', 'hostile inherited opt-in is closed before upstream loads');
    assert.equal(process.env.TOKEN_MONITOR_CODEX_LOCAL_USAGE, outsideDots, 'the caller environment is never changed');
    assert.ok(cloudKeys.every((key) => env[key] === undefined), 'inherited Cloud startup fields are closed before upstream loads');
    assert.deepEqual(cloudKeys.map((key) => process.env[key]), outsideCloud, 'the caller Cloud environment is never changed');

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
  const bridge = createHostBridge({ socketPath, app: { getVersion: () => '0.68.0', quit: () => calls.push('appQuit') } });
  t.after(() => { bridge.close(); fs.rmSync(directory, { recursive: true, force: true }); });
  await bridge.start();
  assert.equal(fs.statSync(socketPath).mode & 0o777, 0o600);
  const before = await request(socketPath, { id: 'before', cmd: 'status' });
  assert.equal(before.ready, false);
  assert.equal(before.trayVisible, false);
  assert.equal(before.allTimeTokens, null);
  assert.equal(before.allTimeCostUsd, null);
  assert.deepEqual(await request(socketPath, { id: 'notready', cmd: 'showHome' }), { id: 'notready', ok: false, error: 'not-ready' });
  let totalCost = 19755.13;
  let totalTokens = 27_123_456_789;
  let usageReads = 0;
  bridge.bind({
    showDashboard: () => calls.push('dashboard'),
    showView: (view) => calls.push(`view:${view}`),
    showSettings: (section) => calls.push(section ? `settings:${section}` : 'settings'),
    isTrayVisible: () => true,
    getAllTimeUsage: () => { usageReads += 1; return { totalTokens, costUsd: totalCost }; },
    quit: () => calls.push('quit')
  });
  const ready = await request(socketPath, { id: 'ready', cmd: 'status' });
  assert.equal(ready.ready, true);
  assert.equal(ready.trayVisible, true);
  assert.equal(ready.allTimeTokens, 27_123_456_789);
  assert.equal(ready.allTimeCostUsd, 19755.13);
  assert.equal(usageReads, 1, 'both totals must come from one snapshot read');
  for (const value of [0, null, undefined, -1, NaN, Infinity, '100', { token: 'private-fixture' }]) {
    totalCost = value;
    const actual = await request(socketPath, { id: 'cost', cmd: 'status' });
    assert.equal(actual.allTimeCostUsd, value === 0 ? 0 : null);
    assert.equal(JSON.stringify(actual).includes('private-fixture'), false);
  }
  totalCost = 19755.13;
  for (const value of [0, Number.MAX_SAFE_INTEGER, null, undefined, -1, 0.5,
    Number.MAX_SAFE_INTEGER + 1, NaN, Infinity, '27123456789', { token: 'private-fixture' }]) {
    totalTokens = value;
    const readsBefore = usageReads;
    const actual = await request(socketPath, { id: 'tokens', cmd: 'status' });
    assert.equal(actual.allTimeTokens, Number.isSafeInteger(value) && value >= 0 ? value : null);
    assert.equal(actual.allTimeCostUsd, totalCost, 'missing token evidence retains the same snapshot cost');
    assert.equal(usageReads, readsBefore + 1);
    assert.equal(JSON.stringify(actual).includes('private-fixture'), false);
  }
  assert.equal((await request(socketPath, { id: 'dash', cmd: 'showDashboard' })).ok, true);
  assert.equal((await request(socketPath, { id: 'home', cmd: 'showHome' })).ok, true);
  assert.equal((await request(socketPath, { id: 'settings', cmd: 'showSettings' })).ok, true);
  for (const section of ['menuBar', 'floatingBubble']) {
    assert.equal((await request(socketPath, { id: section, cmd: 'showSettings', section })).ok, true);
  }
  assert.deepEqual(await request(socketPath, { id: 'badsection', cmd: 'showSettings', section: 'arbitrary' }), { id: null, ok: false, error: 'invalid-section' });
  assert.deepEqual(await request(socketPath, { id: 'wrongroute', cmd: 'showHome', section: 'menuBar' }), { id: null, ok: false, error: 'unexpected-field' });
  assert.equal((await request(socketPath, { id: 'tool', cmd: 'showView', view: 'tool' })).ok, true);
  assert.deepEqual(await request(socketPath, { id: 'bad', cmd: 'showView', view: 'secret' }), { id: null, ok: false, error: 'invalid-view' });
  assert.deepEqual(await request(socketPath, { id: 'extra', cmd: 'status', token: 'x' }), { id: null, ok: false, error: 'unexpected-field' });
  assert.deepEqual(calls, ['dashboard', 'view:home', 'settings', 'settings:menuBar', 'settings:floatingBubble', 'view:tool']);
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
    app: { getVersion: () => '0.68.0', quit() {} }
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

test('host managed roster failures revoke stale accounts and quotas without removing independent accounts', async (t) => {
  const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'agb-tm-roster-'));
  t.after(() => fs.rmSync(stage, { recursive: true, force: true }));
  for (const relativePath of Object.keys(INPUT_SHA256)) {
    const target = path.join(stage, relativePath);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.copyFileSync(path.join(upstreamRoot, relativePath), target);
  }
  transformStage(stage);
  const main = fs.readFileSync(path.join(stage, 'src/electron/main.js'), 'utf8');
  const begin = main.indexOf('// Host-managed profiles stay in memory.');
  const end = main.indexOf('function hydrateCodexManagedAccounts(value) {', begin);
  assert.ok(begin >= 0 && end > begin);
  const injectedFunctions = main.slice(begin, end);

  const host = {
    id: 'aigoodbro-fixture', accountKey: `sha256:${'a'.repeat(64)}`,
    workspaceAccountId: 'workspace-fixture', homePath: '/fixture/managed', alias: 'Managed fixture'
  };
  const own = { id: 'own-fixture', accountKey: `sha256:${'b'.repeat(64)}`, homePath: '/fixture/own' };
  const calls = { host: 0, settings: 0, reconfigure: 0, invalidations: [] };
  let nextReply = () => ({ ok: true, accounts: [host] });
  let localAccountKey = host.accountKey;
  const bridge = { requestHost: async () => { calls.host += 1; return nextReply(); } };
  const context = {
    IS_AIGOODBRO_EMBEDDED: true,
    settings: { codexManagedAccounts: [own] },
    normalizeCodexManagedAccounts: (value) => value || [],
    normalizeWorkspaceId: (value) => typeof value === 'string' && value.length > 0 ? value : null,
    path, Buffer,
    process: { getuid: () => 501 },
    fs: { lstatSync: () => ({ isDirectory: () => true, isSymbolicLink: () => false, uid: 501 }) },
    readRegularFileNoFollow: () => JSON.stringify({
      accountKey: localAccountKey, workspaceAccountId: host.workspaceAccountId
    }),
    codexAuthIdentity: (auth) => auth,
    mainWindow: { isDestroyed: () => false },
    pushSettingsToRenderer: () => { calls.settings += 1; },
    deviceRuntimeHandle: { reconfigureLimits: () => { calls.reconfigure += 1; } },
    electronLimitsConfig: () => ({}),
    queueLimitInvalidation: (scope, reason, options) => {
      calls.invalidations.push({ scope, reason, options });
      return Promise.resolve();
    },
    globalThis: { __AIGOODBRO_TOKEN_MONITOR_BRIDGE__: bridge }
  };
  vm.runInNewContext(`${injectedFunctions}\nglobalThis.fixture = {
    refreshAiGoodBroManagedCodexAccounts, effectiveCodexManagedAccounts
  };`, context);
  const { refreshAiGoodBroManagedCodexAccounts: refresh, effectiveCodexManagedAccounts: effective } = context.globalThis.fixture;
  const ids = () => Array.from(effective(), (account) => account.id);
  const lastInvalidation = () => calls.invalidations.at(-1);

  for (const failure of [
    { name: 'timeout', reply: () => { throw new Error('fixture timeout'); } },
    { name: 'invalid reply', reply: () => ({ ok: true, accounts: {} }) },
    { name: 'duplicate identity', reply: () => ({ ok: true, accounts: [host, host] }) },
    { name: 'local credential mismatch', reply: () => ({ ok: true, accounts: [host] }), key: `sha256:${'c'.repeat(64)}` }
  ]) {
    nextReply = () => ({ ok: true, accounts: [host] });
    localAccountKey = host.accountKey;
    assert.equal(await refresh(), true, `${failure.name}: setup`);
    assert.deepEqual(ids(), [host.id, own.id], `${failure.name}: setup roster`);
    const invalidationsBefore = calls.invalidations.length;
    nextReply = failure.reply;
    localAccountKey = failure.key || host.accountKey;
    assert.equal(await refresh(), false, failure.name);
    assert.deepEqual(ids(), [own.id], `${failure.name}: stale host account revoked`);
    assert.equal(calls.invalidations.length, invalidationsBefore + 1, `${failure.name}: stale quota invalidated`);
    assert.equal(lastInvalidation().scope.provider, 'codex');
    assert.equal(lastInvalidation().options.clear, true);
    assert.equal(await refresh(), false, `${failure.name}: repeated failure`);
    assert.equal(calls.invalidations.length, invalidationsBefore + 1, `${failure.name}: no repeated invalidation`);
  }

  nextReply = () => ({ ok: true, accounts: [host] });
  localAccountKey = host.accountKey;
  assert.equal(await refresh(), true);
  const beforeEmpty = calls.invalidations.length;
  nextReply = () => ({ ok: true, accounts: [] });
  assert.equal(await refresh(), true, 'successful empty roster');
  assert.deepEqual(ids(), [own.id]);
  assert.equal(calls.invalidations.length, beforeEmpty + 1, 'empty roster invalidates removed host quota');
  assert.equal(await refresh(), true, 'unchanged empty roster');
  assert.equal(calls.invalidations.length, beforeEmpty + 1, 'unchanged roster does not repeat invalidation');

  let resolveHost;
  nextReply = () => new Promise((resolve) => { resolveHost = resolve; });
  const hostCallsBefore = calls.host;
  const first = refresh();
  const second = refresh();
  assert.equal(calls.host, hostCallsBefore + 1, 'concurrent refreshes share one host request');
  resolveHost({ ok: true, accounts: [host] });
  assert.deepEqual(await Promise.all([first, second]), [true, true]);
  assert.deepEqual(ids(), [host.id, own.id], 'successful recovery restores host account');
  assert.equal(calls.reconfigure, calls.invalidations.length, 'each roster change reconfigures limits exactly once');
  assert.equal(calls.settings, calls.invalidations.length, 'each roster change updates the renderer exactly once');
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
  const homeRouteSource = rendererApp.match(/window\.tokenMonitor\.onOpenView\?\.\(\(viewId\) => \{[\s\S]*?\n\}\);/)?.[0];
  assert.ok(homeRouteSource);
  let openView;
  const homeCalls = [];
  vm.runInNewContext(homeRouteSource, {
    window: { tokenMonitor: { onOpenView: (handler) => { openView = handler; } } },
    setPeriod: (period) => homeCalls.push(`period:${period}`),
    openViewFromTray: (view) => homeCalls.push(`view:${view}`)
  });
  openView('home');
  assert.deepEqual(homeCalls, ['period:allTime', 'view:home']);
  homeCalls.length = 0;
  openView('limits');
  assert.deepEqual(homeCalls, ['view:limits'], 'other routes retain the selected period');
  const tray = fs.readFileSync(path.join(stage, 'src/electron/tray.js'), 'utf8');
  assert.match(main, /hostBridge\.bind\(/);
  const routeSource = rendererApp.match(/window\.tokenMonitor\.onOpenSettings\?\.\(\(section\) => \{[\s\S]*?\n\}\);/)?.[0];
  assert.ok(routeSource);
  for (const [section, target] of [['menuBar', 'showTrayIconInput'], ['floatingBubble', 'floatingBubbleInput'], [undefined, null]]) {
    const calls = [];
    let route;
    vm.runInNewContext(routeSource, {
      window: { tokenMonitor: { onOpenSettings: (handler) => { route = handler; } } },
      openSettingsPanel: () => calls.push('open'),
      setSettingsSectionExpanded: (id, expanded) => calls.push(`${id}:${expanded}`),
      requestAnimationFrame: (fn) => fn(),
      document: { getElementById: (id) => {
        assert.equal(id, target);
        assert.match(index, new RegExp(`id="${id}"`));
        return { closest: () => ({ scrollIntoView: () => calls.push('scroll') }), focus: () => calls.push('focus') };
      } }
    });
    route(section);
    assert.deepEqual(calls, target ? ['open', 'window:true', 'scroll', 'focus'] : ['open']);
  }
  const dockSync = main.match(/function syncEdgeDock\(rendererSettings\) \{[\s\S]*?\n\}\n\n(?=function refreshLimitStatsPresentation)/)?.[0];
  assert.ok(dockSync);
  let dockStops = 0;
  const stopEmbeddedDock = vm.runInNewContext(`${dockSync}; syncEdgeDock;`, {
    IS_AIGOODBRO_EMBEDDED: true, edgeDockController: { stop: () => { dockStops += 1; } }
  });
  stopEmbeddedDock({});
  assert.equal(dockStops, 1, 'embedded dock cannot open alongside native dock');

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
  assert.match(main, /\['openWorkbench', 'openAccounts', 'openSettings', 'openEdgeDockSettings', 'checkForUpdates'\]\.includes\(action\)/);
  assert.match(preload, /openAiGoodBroHost: \(action\) => ipcRenderer\.invoke\('aigoodbro:openHost', action\)/);
  assert.match(main, /isTrayVisible: \(\) => Boolean\(tray && !tray\.isDestroyed\(\)\)/);
  const usageRoute = main.match(/getAllTimeUsage: (\(\) => \{[\s\S]*?\n      \}),/)?.[1];
  assert.ok(usageRoute);
  for (const fixture of [{ totalTokens: 27_123_456_789, costUsd: 19755.13 }, { totalTokens: 0, costUsd: 0 }, {}]) {
    const stats = { periods: { allTime: fixture } };
    let projected = 0;
    const value = vm.runInNewContext(`(${usageRoute})()`, {
      latestStats: stats, localStats: null,
      electronPresentationStats: (input) => { assert.equal(input, stats); projected += 1; return input; }
    });
    assert.equal(projected, 1);
    assert.equal(value, fixture, 'both metrics retain the tray presentation source and revision');
    const fallback = vm.runInNewContext(`(${usageRoute})()`, {
      latestStats: null, localStats: stats, electronPresentationStats: input => input
    });
    assert.equal(fallback, fixture, 'local fallback is shared by both totals');
  }
  assert.equal(vm.runInNewContext(`(${usageRoute})()`, {
    latestStats: { aigoodbroUsagePending: true, periods: { allTime: { totalTokens: 0, costUsd: 0 } } },
    localStats: null, electronPresentationStats: input => input
  }), null, 'a connected quota-only bootstrap must not manufacture usage zero');
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
  assert.match(main, /limitProviderUrlAllowed\(parsed.hostname, parsed.pathname\)/);
  assert.match(main, /parsed\.pathname\.startsWith\('\/junhoyeo\/tokscale'\)/);
  const externalUrlFunction = main.match(/function isAllowedExternalUrl\(value\) \{[\s\S]*?\n\}\n\n(?=function revealWindow\()/)?.[0];
  assert.ok(externalUrlFunction);
  const isAllowedExternalUrl = vm.runInNewContext(
    `const settings = {}; const STATUS_PAGE_HOSTS = new Set(['status.openai.com']);
     const isAllowedVerificationUrl = () => false; const isAllowedCodexLoginUrl = () => false;
     ${externalUrlFunction} isAllowedExternalUrl;`,
    { URL, process: { env: {} }, limitProviderUrlAllowed: require(path.join(upstreamRoot, 'src/shared/limits/accounts')).limitProviderUrlAllowed }
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
  assert.match(rendererApp, /els\.aboutVersion\.textContent = 'v2\.3'/);
  assert.match(rendererApp, /t\('settings\.about\.embeddedEngine', \{ version: state\.appInfo\?\.version \|\| '0\.68\.0' \}\)/);
  assert.equal(i18n.translate('en', 'settings.about.embeddedEngine', { version: '0.68.0' }), 'Built-in Token Monitor engine v0.68.0 (MIT).');
  assert.equal(i18n.translate('zh-CN', 'settings.about.embeddedEngine', { version: '0.68.0' }), '内置 Token Monitor 引擎 v0.68.0（MIT）。');
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
  assert.match(rendererApp, /if \(id === 'app'\) return '\.\.\/\.\.\/\.\.\/assets\/tray-curve\.png';/);
  assert.match(rendererApp, /sources\.app = '\.\.\/\.\.\/\.\.\/assets\/tray-curve\.png';/);
  assert.doesNotMatch(rendererApp, /assets\/icons\/tray-token-monitor\.png/);
  assert.match(tray, /const TRAY_ICON_PATH = path\.join\(__dirname, '\.\.', '\.\.', 'assets', 'tray-curve\.png'\);/);
  assert.match(tray, /id !== 'app' && id !== 'custom'/);
  assert.match(tray, /sized\.setTemplateImage\(false\)/);
  assert.match(tray, /Open AiGoodBro Workbench/);
  for (const relativePath of ['src/electron/main.js', 'src/electron/discordRpc.js', 'src/electron/preload.js', 'src/shared/appUpdater.js', 'src/electron/renderer/app.js', 'src/electron/tray.js']) {
    const check = spawnSync(process.execPath, ['--check', path.join(stage, relativePath)], { encoding: 'utf8' });
    assert.equal(check.status, 0, `${relativePath}: ${check.stderr}`);
  }
  assert.throws(() => transformStage(stage), /Pinned upstream hash changed/);
});
