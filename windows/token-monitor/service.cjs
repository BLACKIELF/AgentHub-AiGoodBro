'use strict';
// Windows host adapter for the frozen engine. No Electron, HTTP, credential
// probe, implicit home, model request, install script or fixture CLI.
const path = require('node:path');
const MAX_LINE = 1024 * 1024;
const MAX_OUTPUT = 32 * 1024 * 1024;
const METRICS = ['totalTokens', 'costUsd', 'unpricedTokens', 'inputTokens', 'outputTokens', 'cacheReadTokens', 'cacheWriteTokens', 'unclassifiedTokens', 'timedTokens', 'timedOutputTokens', 'timedDurationMs'];
const HISTORY_METRICS = ['tokens', 'cost', 'unpricedTokens', 'inputTokens', 'outputTokens', 'cacheReadTokens', 'cacheWriteTokens', 'unclassifiedTokens', 'messages', 'activeTimeMs'];
function constrainModules(root, files) {
  const Module = require('node:module');
  const builtins = new Set(Module.builtinModules.map(value=>value.replace(/^node:/,'')));
  const approved = new Set(Object.keys(files).map(value=>path.resolve(root,value).toLowerCase()));
  const original = Module._resolveFilename;
  Module._resolveFilename = function(request,...arguments_) {
    const resolved = original.call(this,request,...arguments_);
    if(typeof resolved==='string'&&!builtins.has(resolved.replace(/^node:/,''))&&!approved.has(path.resolve(resolved).toLowerCase()))throw Error('unverified_module');
    return resolved;
  };
  return ()=>{Module._resolveFilename=original;};
}
function safeName(value) {
  if (value === '<synthetic>') return value;
  if (typeof value !== 'string' || !value || value.length > 128 || /[\x00-\x1f<>\\]|\.\.|:\/\//.test(value) || /[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}/.test(value) || /(?:Bearer |sk-[A-Za-z0-9]{8})/i.test(value) || /^[/]|^[a-z]:/i.test(value)) throw Error('invalid_response');
  return value;
}
function metric(value) { return value === null || value === undefined ? null : typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= Number.MAX_SAFE_INTEGER ? value : (() => { throw Error('invalid_response'); })(); }
function metrics(value, keys) { return Object.fromEntries(keys.map(key => [key, metric(value?.[key])])); }
function groups(value, keys) { return Object.fromEntries(Object.entries(value || {}).map(([key, item]) => [safeName(key), metrics(item, keys)])); }
function sessionTime(value) {
  if (typeof value !== 'string' || value.length > 64 || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value) || !Number.isFinite(Date.parse(value))) throw Error('invalid_response');
  const [year, month, day] = value.slice(0, 10).split('-').map(Number);
  const calendar = new Date(0); calendar.setUTCFullYear(year, month - 1, day);
  if (calendar.getUTCFullYear() !== year || calendar.getUTCMonth() !== month - 1 || calendar.getUTCDate() !== day) throw Error('invalid_response');
  return value;
}
// Already sanitized Engine history. No titles, paths, prompts or raw session
// identifiers leave this host; these rows are never a live-task authority.
function sessions(value) {
  if (value == null) return null;
  if (typeof value !== 'object' || Array.isArray(value) || Object.keys(value).length > 10000) throw Error('invalid_response');
  return Object.fromEntries(Object.entries(value).map(([key, raw]) => {
    if (!/^opaque-[a-f0-9]{24}$/.test(key) || !raw || typeof raw !== 'object' || Array.isArray(raw)) throw Error('invalid_response');
    const row = {};
    if (raw.client != null) row.client = safeName(raw.client);
    // The pinned upstream uses empty strings for unknown optional metadata.
    // Omit those fields while retaining validation of every nonempty value.
    if (raw.sessionKind != null && raw.sessionKind !== '') row.sessionKind = safeName(raw.sessionKind);
    for (const name of ['lastUsedAt', 'startedAt']) if (raw[name] != null && raw[name] !== '') row[name] = sessionTime(raw[name]);
    for (const name of ['totalTokens', 'costUsd']) if (Object.hasOwn(raw, name)) row[name] = metric(raw[name]);
    for (const name of ['turnEnded', 'archived', 'deleted', 'sourceDeleted']) if (raw[name] != null) {
      if (typeof raw[name] !== 'boolean') throw Error('invalid_response');
      row[name] = raw[name];
    }
    if (raw.models != null) {
      if (typeof raw.models !== 'object' || Array.isArray(raw.models) || Object.keys(raw.models).length > 10000) throw Error('invalid_response');
      row.models = Object.fromEntries(Object.entries(raw.models).map(([model, count]) => [safeName(model), metric(count)]));
    }
    return [key, row];
  }));
}
function period(value) {
  if (!value || typeof value !== 'object') return null;
  const maps = ['clients', 'clientCosts', 'clientCacheReads', 'clientCacheWrites', 'clientOutputs', 'clientUnclassifiedTokens', 'models', 'modelCosts', 'modelCacheReads', 'modelCacheWrites', 'modelOutputs', 'modelUnclassifiedTokens'];
  return { ...metrics(value, METRICS), capabilities: { throughput: value.capabilities?.throughput === true }, sessions: sessions(value.sessions),
    ...Object.fromEntries(maps.map(key => [key, Object.fromEntries(Object.entries(value[key] || {}).map(([label, number]) => [safeName(label), metric(number)]))])),
    modelThroughput: value.modelThroughput ? groups(value.modelThroughput, ['timedTokens', 'timedOutputTokens', 'timedDurationMs']) : null };
}
function history(value) {
  if (!value) return null;
  const rows = (items, key) => (items || []).map(row => {
    if (typeof row[key] !== 'string' || !(key === 'date' ? /^\d{4}-\d{2}-\d{2}$/ : /^\d{4}-\d{2}$/).test(row[key])) throw Error('invalid_response');
    return { [key]: row[key], ...metrics(row, HISTORY_METRICS), perClient: groups(row.perClient, HISTORY_METRICS), perModel: groups(row.perModel, HISTORY_METRICS) };
  });
  if ((value.daily?.length || 0) > 10000 || (value.monthly?.length || 0) > 10000) throw Error('invalid_response');
  const summary = metrics(value.summary, ['totalTokens', 'totalCost', 'activeDays', 'currentStreak', 'longestStreak', 'messages', 'peakDayTokens', 'unpricedTokens', 'activeTimeMs']);
  summary.favoriteModel = value.summary?.favoriteModel ? safeName(value.summary.favoriteModel) : null;
  summary.timeMetrics = value.summary?.timeMetrics ? metrics(value.summary.timeMetrics, ['totalActiveTimeMs', 'longestContinuousMs', 'maxConcurrentSessions', 'sessionCount']) : null;
  return { daily: rows(value.daily, 'date'), monthly: rows(value.monthly, 'month'), summary };
}
function publicSnapshot(response, historyAt) {
  if (response.engine?.commit !== '5d2db368d8313415763860d594de00e46a663418' || !['ok', 'partial', 'error'].includes(response.status)) throw Error('invalid_response');
  const aggregate = response.payload?.aggregate;
  return { schemaVersion: 1, requestId: response.requestId, engine: response.engine, collectedAt: response.collectedAt, timezone: response.timezone, status: response.status,
    sources: response.sources, coverage: response.coverage, errors: response.errors,
    historyCollectedAt: historyAt,
    payload: { aggregate: { today: period(aggregate?.today), month: period(aggregate?.month), allTime: period(aggregate?.allTime) }, history: history(response.payload?.history), costEstimates: response.payload?.costEstimates ?? null,
      usage: { historyAvailable: typeof response.payload?.usage?.historyAvailable === 'boolean' ? response.payload.usage.historyAvailable : null } } };
}

const windowsScopes = new WeakSet();
function retainWindowsEnvironment(sourceScope, environment) {
  if (windowsScopes.has(sourceScope)) return;
  const originalEnvironment = sourceScope.scopedEnvironment, originalTarget = sourceScope.withTarget;
  const plumbing = Object.fromEntries(['SystemRoot', 'TEMP', 'TMP'].filter(key => typeof environment[key] === 'string' && environment[key]).map(key => [key, environment[key]]));
  if (plumbing.SystemRoot) plumbing.WINDIR = plumbing.SystemRoot;
  const extra = home => ({ APPDATA: path.join(home, 'AppData/Roaming'), LOCALAPPDATA: path.join(home, 'AppData/Local'), ...plumbing });
  sourceScope.scopedEnvironment = (home, ...args) => ({ ...originalEnvironment(home, ...args), ...extra(home) });
  // withTarget closes over its own scopedEnvironment, so patching the export
  // alone misses real scans. Its finally still restores the outer environment.
  sourceScope.withTarget = (target, timezone, fn) => originalTarget(target, timezone, scoped => {
    const retained = extra(scoped.homeDir);
    Object.assign(scoped.env, retained);
    Object.assign(process.env, retained);
    return fn(scoped);
  });
  windowsScopes.add(sourceScope);
}

function createRuntime(engineRoot, { now = Date.now, emit = () => {}, loader: injectedLoader, handleRequest: injectedHandler, createScope: injectedScope, timer = setTimeout, clear = clearTimeout } = {}) {
  // Original source-scope consumers destructure this function at load time.
  // Retain only Windows OS plumbing, never ambient account/proxy variables.
  const scopePath = path.join(engineRoot, 'lib/runtime/source-scope.cjs');
  const sourceScope = require(scopePath);
  if (!injectedHandler && process.platform === 'win32') retainWindowsEnvironment(sourceScope, process.env);
  const descendants = require(path.join(engineRoot, 'lib/runtime/descendants.cjs'));
  descendants.install();
  const loader = injectedLoader || require(path.join(engineRoot, 'lib/upstream/loader.cjs'));
  const handleRequest = injectedHandler || require(path.join(engineRoot, 'lib/handler.cjs')).handleRequest;
  const createScope = injectedScope || require(path.join(engineRoot, 'lib/runtime/scope.cjs')).createRequestScope;
  const rates = require(path.join(engineRoot, 'upstream/src/electron/renderer/tokenRatePresentation.js'));
  let config = null, scope = null, tick = null, rateTick = null, inFlight = null, stopped = true, cleanupUnconfirmed = false;
  let tracker = null, counters = null, contextKey = null, sequence = 0, historyAt = null;
  const graphCache = new Map();
  function send(event) { emit({ ...event, contextKey }); }
  function sample() {
    const value = tracker?.getSample();
    return value ? { mode: 'burn', scope: 'local', burnPerMinute: value.burn, speedPerSecond: value.speed, sampledAt: value.sampledAt, expiresAt: value.expiresAt, idle: value.idle, revision: value.revision, contextKey } : null;
  }
  function observe(aggregate) {
    const periodValue = aggregate?.today;
    const next = METRICS.filter(key => key.startsWith('timed')).map(key => periodValue?.[key]);
    const valid = periodValue?.capabilities?.throughput !== false && next.every(value => typeof value === 'number' && Number.isFinite(value) && value >= 0);
    if (!valid) { tracker = null; counters = null; return; }
    const entries = rates.selectLiveTokenRatePeriods({ periods: aggregate }, 'local', 'local', 'device').entries;
    if (!tracker || counters && next.some((value, i) => value < counters[i])) {
      tracker = rates.createLiveTokenRateGroupTracker({ now, activeMs: 8000, clearMs: 180000 }); tracker.reset(entries);
    } else tracker.observe(entries);
    counters = next;
  }
  async function collect(forceHistory = false) {
    if (!config || stopped) return;
    if (inFlight) return inFlight;
    const epoch = contextKey;
    const request = { ...config.request, now: new Date(now()).toISOString(), requestId: `usage-${++sequence}`, options: { timeoutMs: 180000, allowPriceNetwork: false, allowSelfSync: false, allowCredentialRefresh: false, includeLiveCodexAccount: false, allowProviderNetwork: false } };
    const refreshHistory = forceHistory || historyAt === null || now() - historyAt >= 60000;
    if (refreshHistory) graphCache.clear();
    scope = createScope({ timeoutMs: request.options.timeoutMs }).start();
    const currentScope = scope;
    inFlight = (async () => {
      try {
        const upstream = loader.loadUsage();
        const response = await handleRequest(request, { scope: currentScope, loader, upstream,
          runGraph: async input => {
            // The current instant changes on each two-second usage tick, but
            // graph evidence is civil-date scoped. Keep the expensive graph
            // stable within the 60-second cache window while retaining source
            // and provider boundaries in its key.
            // Non-user-home targets receive a new disposable home each call.
            // Their engine-owned persistent cache ID binds the canonical root,
            // role and provider set; using the disposable home would miss every
            // cache hit and silently rescan history at the usage cadence.
            const rootKey = input.env?.TOKSCALE_CONFIG_DIR || input.homeDir;
            const key = JSON.stringify([input.clients, input.since, String(input.until || '').slice(0, 10), rootKey, input.customScanPaths]);
            if (!refreshHistory && graphCache.has(key)) return graphCache.get(key);
            const graph = await upstream.collector.bridgeRunGraph(input); graphCache.set(key, graph); return graph;
          } });
        currentScope.checkAborted();
        if (stopped || contextKey !== epoch) return;
        if (refreshHistory && response.status !== 'error' && response.payload?.history) historyAt = now();
        if(response.status==='error'){tracker=null;counters=null;}else observe(response.payload?.aggregate);
        send({ event: 'snapshot', snapshot: publicSnapshot(response, historyAt), rate: sample() });
      } catch (_) {
        if (!stopped && contextKey === epoch) { tracker = null; counters = null; send({ event: 'failed', code: currentScope.timedOut ? 'timeout' : 'collection_failed' }); }
      } finally {
        currentScope.dispose();
        if (!await currentScope.waitForCleanup() && !stopped) {
          send({ event: 'failed', code: 'cleanup_unconfirmed' });
          cleanupUnconfirmed = true; stopped = true; clear(tick); clear(rateTick); tracker = null; counters = null;
        }
        if (scope === currentScope) scope = null;
      }
    })().finally(() => { inFlight = null; if (!stopped && contextKey === epoch) tick = timer(() => void collect(), 2000); });
    return inFlight;
  }
  async function configure(value) {
    await stop();
    if (!/^[a-f0-9]{64}$/.test(value?.contextKey) || value.request?.operation !== 'collectUsage' || !Array.isArray(value.request?.sources) || !value.request.sources.length) throw Error('invalid_request');
    config = value; contextKey = value.contextKey; stopped = false; cleanupUnconfirmed = false; graphCache.clear(); historyAt = null; tracker = null; counters = null;
    const publishRate = () => { if (!stopped) { send({ event: 'rate', rate: sample() }); rateTick = timer(publishRate, 1000); } };
    rateTick = timer(publishRate, 1000);
    void collect(true);
  }
  async function stop() { stopped = true; clear(tick); clear(rateTick); scope?.cancel(); await inFlight; tracker = null; counters = null; if (cleanupUnconfirmed) throw Error('cleanup_unconfirmed'); }
  return { configure, collect, stop, sample };
}

async function main() {
  const fs = require('node:fs');
  const engine = path.resolve(__dirname, 'engine');
  const manifestBytes=fs.readFileSync(path.join(__dirname,'WINDOWS-RESOURCES.json'));
  if(manifestBytes.length>2*1024*1024)throw Error('invalid_resources');
  constrainModules(__dirname,JSON.parse(manifestBytes).files);
  process.emitWarning = () => {};
  // Synchronous pipe writes keep output memory bounded when the native reader
  // is slow. Its owned Job still bounds cancellation of a blocked write.
  const emit = value => { const output = Buffer.from(JSON.stringify(value) + '\n'); if (output.length > MAX_OUTPUT) throw Error('output_too_large'); let offset=0;while(offset<output.length)offset+=fs.writeSync(1,output,offset,output.length-offset); };
  const runtime = createRuntime(engine, { emit });
  let commands = Promise.resolve(), pending = Buffer.alloc(0), queued = 0, closing = false;
  const close = () => { if(closing)return;closing=true;process.stdin.pause();void runtime.stop().finally(()=>process.exit(process.exitCode||0)); };
  const line = bytes => {
    let command; try { command = JSON.parse(bytes); } catch { process.exitCode = 2; close(); return; }
    if (++queued > 4) { process.exitCode=2;close();return; }
    commands = commands.then(async () => {
      queued--;
      if(closing)return;
      if (command.command === 'configure') await runtime.configure(command);
      else if (command.command === 'refresh') void runtime.collect(true);
      else throw Error('invalid_request');
    }).catch(() => { process.exitCode = 2; close(); });
  };
  process.stdin.on('data', chunk=>{
    if(closing)return;
    let start=0;
    for(let index=0;index<chunk.length;index++)if(chunk[index]===10){
      if(pending.length+index-start>MAX_LINE){process.exitCode=2;close();return;}
      line(Buffer.concat([pending,chunk.subarray(start,index)]));pending=Buffer.alloc(0);start=index+1;
      if(closing)return;
    }
    if(pending.length+chunk.length-start>MAX_LINE){process.exitCode=2;close();return;}
    pending=Buffer.concat([pending,chunk.subarray(start)]);
  });
  process.stdin.on('end',()=>{if(pending.length)process.exitCode=2;close();});
  process.stdin.on('error',()=>{process.exitCode=2;close();});
}
if (require.main === module) main().catch(() => process.exit(1));
module.exports = { createRuntime, publicSnapshot, period, history, sessions, safeName, constrainModules, retainWindowsEnvironment };
