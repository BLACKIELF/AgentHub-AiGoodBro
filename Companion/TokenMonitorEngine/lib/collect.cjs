'use strict';

const { CODES, structuredError } = require('./errors.cjs');
const { civilDate } = require('./coverage.cjs');
const { isCredentialEndpoint } = require('./upstream/credential-endpoints.cjs');
const custom = require('./custom.cjs');
const { withTarget, scopedEnvironment } = require('./runtime/source-scope.cjs');

// Orchestration over the original upstream entry points.
//
// Every upstream call is made with the dependency seams upstream already
// exposes (runTokscale / runGraph / lookupModelPricing / providerFetchers /
// fetch / now). Production and fixture mode therefore run the *same* upstream
// code; only the injected collaborators differ. That is what makes the fixture
// suite meaningful: it is not a mock of the collector, it is the collector.

// Matches src/electron/main.js and src/agent/agent.js. Not exposed as a request
// option because the contract's options object is closed.
const ALL_TIME_SINCE = '2024-01-01';
const ENGINE_AGENT_VERSION = 'token-monitor-engine/0.1.0';
const DEVICE_ID = 'token-monitor-engine';
const DEFAULT_LIMITS_REFRESH_MS = 300000;

function capabilityError(code, status) {
  const error = new Error(code);
  error.code = 'CAPABILITY_DISABLED';
  if (status) error.status = status;
  return error;
}

// Price lookups are the one upstream path that reaches the network during a
// usage collect (tokscale `pricing`, which also refreshes the catalog). With
// priceNetwork off, the injected lookup rejects and upstream falls back to the
// on-disk tokscale catalog — a local read.
function buildPriceLookup(request, deps) {
  if (typeof deps.lookupModelPricing === 'function') return deps.lookupModelPricing;
  if (request.options.allowPriceNetwork) return undefined;
  return async () => {
    throw capabilityError('price-network-disabled');
  };
}

function targetEnv(target) {
  return scopedEnvironment(target.root, target.pathRole === 'codexHome' ? target.root : null);
}

// Graph costs are estimates. Inspect the raw rows before upstream history
// normalization turns a missing cost into zero; an explicit zero is evidence.
function explicitCost(value) {
  if (typeof value === 'string' && !value.replace(/[$,]/g, '').trim()) return null;
  const amount = typeof value === 'number' ? value
    : typeof value === 'string' && value.trim() ? Number(value.replace(/[$,]/g, '')) : NaN;
  return Number.isFinite(amount) && amount >= 0 ? amount : null;
}

function graphCostEvidence(graph) {
  const dates = new Map();
  for (const row of Array.isArray(graph?.contributions) ? graph.contributions : []) {
    const date = typeof row?.date === 'string' ? row.date.slice(0, 10) : '';
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || Number.isNaN(Date.parse(`${date}T00:00:00Z`))
      || new Date(`${date}T00:00:00Z`).toISOString().slice(0, 10) !== date) continue;
    const result = dates.get(date) || { date, cost: 0, recorded: 0, missing: 0 };
    const clients = Array.isArray(row.clients) ? row.clients : [];
    if (!clients.length) result.missing += 1;
    for (const client of clients) {
      const amount = explicitCost(client?.cost);
      if (amount === null) result.missing += 1;
      else { result.cost += amount; result.recorded += 1; }
    }
    dates.set(date, result);
  }
  return dates;
}

function mergeGraphCostEvidence(graphs, history, incomplete = false) {
  const dates = new Map();
  for (const graph of graphs) {
    for (const row of graphCostEvidence(graph).values()) {
      const result = dates.get(row.date) || { date: row.date, cost: 0, recorded: 0, missing: 0 };
      result.cost += row.cost;
      result.recorded += row.recorded;
      result.missing += row.missing;
      dates.set(row.date, result);
    }
  }
  const daily = (history?.daily || []).map(day => {
    const row = dates.get(day.date);
    if (!row || row.recorded === 0) {
      // A positive retained history cost is evidence even when its original
      // graph row is no longer available. Its completeness is unverified.
      const retained = explicitCost(day.cost);
      return { date: day.date, cost: retained !== null && retained > 0 ? retained : null,
        status: retained !== null && retained > 0 ? 'partial' : 'unknown' };
    }
    const retained = explicitCost(day.cost);
    const retainedExtra = retained !== null && retained > row.cost + 1e-9;
    return { date: day.date, cost: retainedExtra ? retained : row.cost,
      status: incomplete || row.missing > 0 || retainedExtra ? 'partial' : 'estimated' };
  });
  const recorded = [...dates.values()].filter(row => row.recorded > 0);
  const graphTotal = recorded.length ? recorded.reduce((sum, row) => sum + row.cost, 0) : null;
  const retainedTotal = explicitCost(history?.summary?.totalCost);
  const retainedExtra = retainedTotal !== null && retainedTotal > 0
    && (graphTotal === null || retainedTotal > graphTotal + 1e-9);
  const totalCost = retainedExtra ? retainedTotal : graphTotal;
  const retainedMonths = (history?.monthly || []).some(month =>
    (Number(month.tokens) > 0 || Number(month.cost) > 0)
      && ![...dates.keys()].some(date => date.slice(0, 7) === month.month));
  const partial = incomplete || retainedExtra || retainedMonths
    || [...dates.values()].some(row => row.missing > 0)
    || daily.some(row => row.status !== 'estimated');
  return {
    daily,
    totalCost,
    status: totalCost === null ? 'unknown' : partial ? 'partial' : 'estimated'
  };
}

// The injected network layer for provider probes. The providerHelpers overlay
// covers providers that go through fetchJson; this covers the ones that call
// deps.fetch directly.
function buildProviderFetch(request, deps) {
  const base = typeof deps.fetch === 'function' ? deps.fetch : null;
  // Only an explicit `false` disables a capability. `undefined` means the
  // caller omitted the option, and the contract defaults are provider network
  // on / credential refresh off.
  const providerNetworkOn = request.options.allowProviderNetwork !== false;
  const credentialRefreshOn = false;
  if (providerNetworkOn && credentialRefreshOn) return base || undefined;
  return async (url, init) => {
    if (!providerNetworkOn) throw capabilityError('provider-network-disabled', 'unavailable');
    if (!credentialRefreshOn && isCredentialEndpoint(url)) {
      throw capabilityError('credential-refresh-disabled', 'unauthorized');
    }
    const fetchFn = base || globalThis.fetch;
    return fetchFn(url, { ...init, redirect: 'error' });
  };
}

function usageOptionsFor(target, request, deps, scope, todayKey) {
  return {
    clients: target.providerIds.join(','),
    homeDir: target.root,
    env: targetEnv(target),
    now: new Date(request.now),
    todayKey,
    allTimeSince: ALL_TIME_SINCE,
    commandTimeoutMs: Math.max(1000, Math.min(request.options.timeoutMs, 60000)),
    deviceId: DEVICE_ID,
    agentVersion: ENGINE_AGENT_VERSION,
    signal: scope.signal,
    historyEnabled: false,
    wslScanEnabled: false,
    projectsEnabled: true,
    lookupModelPricing: buildPriceLookup(request, deps),
    logger: () => {},
    runTokscale: deps.runTokscale,
    runGraph: deps.runGraph,
    collectWslUsage: deps.collectWslUsage,
    probeWslState: deps.probeWslState,
    runAntigravitySync: deps.runAntigravitySync
  };
}

// Host identity never leaves the engine: hostname, device id, OS name/version
// and the process platform describe the machine, not the user's usage.
function sanitizeSummary(summary) {
  if (!summary || typeof summary !== 'object') return null;
  const { deviceId, hostname, platform, osName, osVersion, agentVersion, agentRuntime, ...data } = summary;
  return data;
}

function mergeClientStatus(entries) {
  const merged = {};
  for (const entry of entries) {
    for (const [client, status] of Object.entries(entry || {})) {
      if (!merged[client]) {
        merged[client] = status;
        continue;
      }
      const previous = merged[client];
      if (previous && status && typeof previous === 'object' && typeof status === 'object') {
        merged[client] = { ...previous, ...status };
      }
    }
  }
  return merged;
}

async function collectUsagePerTarget(up, targets, request, deps, scope, todayKey, errors) {
  const results = [];
  for (const target of targets) {
    scope.checkAborted();
    try {
      const summary = await withTarget(target, request.timezone, async scoped => {
        const runner = deps.runTokscale || up.collector.bridgeRunUsage;
        const options = { ...usageOptionsFor(target, request, deps, scope, todayKey), ...scoped,
          osInfo: {}, logger: () => { target.evidence.usageFailed = true; },
          runTokscale: async input => {
            const result = await runner({ ...input, ...scoped, workspaces: true });
            target.evidence.scanSucceeded = true;
            return result;
          } };
        const result = await up.collector.collectUsageOnce(options);
        target.evidence.clientStatus = result.clientStatus;
        target.evidence.today = result.today;
        target.evidence.todayKey = todayKey;
        // A cached upstream price is evidence; permission to fetch is not.
        target.evidence.pricedModels = new Set(Object.keys(result.allTime?.models || {}).filter(model =>
          (() => {
            const pricing = up.collector.readTokscalePricingCatalog(model, { env: scoped.env, homeDir: scoped.homeDir });
            return ['inputCostPerToken', 'outputCostPerToken', 'cacheReadInputTokenCost', 'cacheCreationInputTokenCost']
              .every(field => Number.isFinite(pricing?.[field]) && pricing[field] >= 0);
          })()));
        return result;
      });
      results.push({ target, summary });
    } catch (error) {
      if (scope.signal?.aborted) throw error;
      for (const sourceId of target.sourceIds) {
        errors.push(structuredError(CODES.COLLECTION_FAILED, sourceId));
      }
      target.evidence.usageFailed = true;
      results.push({ target, summary: null });
    }
  }
  return results;
}

async function collectHistoryPerTarget(up, targets, request, deps, scope, todayKey, errors) {
  const histories = [];
  const costGraphs = [];
  for (const target of targets) {
    scope.checkAborted();
    try {
      const targetGraphs = [];
      const history = await withTarget(target, request.timezone, scoped => up.collector.collectHistoryOnce({
        ...scoped,
        clients: target.providerIds[0] === 'proma' ? '' : target.providerIds.join(','),
        ...(target.providerIds[0] === 'proma' ? { promaGraph: up.proma.buildPromaHistoryGraph({ rows: up.proma.collectPromaRows() }) } : {}),
        runGraph: async input => {
          const graph = await (deps.runGraph || up.collector.bridgeRunGraph)({ ...input, ...scoped });
          targetGraphs.push(graph);
          return graph;
        },
        todayKey, capDays: 370,
        commandTimeoutMs: Math.max(1000, Math.min(request.options.timeoutMs, 60000)),
        signal: scope.signal, historyEnabled: true,
        onHistoryStatus: status => { target.evidence.historySucceeded = !!status.successAt && !status.failureCode; },
        logger: () => {}
      }));
      target.evidence.history = history;
      target.evidence.costEstimates = new Map(targetGraphs.flatMap(graph => [...graphCostEvidence(graph)]));
      if (!target.evidence.historySucceeded) {
        for (const sourceId of target.sourceIds) errors.push(structuredError(CODES.COLLECTION_FAILED, sourceId));
      }
      if (history) {
        histories.push(history);
        costGraphs.push(...targetGraphs);
      }
    } catch (error) {
      if (scope.signal?.aborted) throw error;
      for (const sourceId of target.sourceIds) {
        errors.push(structuredError(CODES.COLLECTION_FAILED, sourceId));
      }
    }
  }
  const history = histories.length === 0 ? null : histories.length === 1
    ? histories[0] : up.history.mergeHistories(histories, { todayKey });
  const incomplete = targets.some(target => !target.evidence.historySucceeded
    || target.providerIds.includes('proma'));
  return { history, costEstimates: mergeGraphCostEvidence(costGraphs, history, incomplete) };
}

async function collectLimitsOnce(up, request, deps, scope, targets) {
  const result = { updatedAt: request.now, refreshMs: DEFAULT_LIMITS_REFRESH_MS, providers: [], targets: [] };
  for (const target of targets) {
    scope.checkAborted();
    if (target.managed && target.pathRole === 'configDirectory' && target.providerIds[0] === 'opencode' && target.accountId) {
      const snapshot = await require('./opencode-limits.cjs').collectOpenCodeLimits(target, request, deps, scope);
      target.evidence.limitsUnavailable = snapshot.providers.length !== 1 || snapshot.providers[0].status !== 'ok';
      result.targets.push({ sourceId: target.sourceIds[0], providerId: 'opencode', accountId: target.accountId, snapshot });
      result.providers.push(...snapshot.providers);
      continue;
    }
    if (!target.managed || target.pathRole !== 'codexHome' || target.providerIds[0] !== 'codex' || !target.accountId) {
      target.evidence.limitsUnavailable = true;
      continue;
    }
    let snapshot;
    try {
      snapshot = await withTarget(target, request.timezone, scoped => up.limitsCollector.collectLimitsOnce({
        limitsEnabled: true, limitProviders: ['codex'], limitsRefreshMs: DEFAULT_LIMITS_REFRESH_MS,
        codexManagedAccounts: [{ id: target.accountId, homePath: target.root, enabled: true }],
        includeLiveCodexAccount: false, signal: scope.signal
      }, { ...(deps.limitsDeps || {}), now: deps.now || (() => Date.parse(request.now)),
        fetch: buildProviderFetch(request, deps), ...scoped,
        // RPC fallback can launch a CLI and refresh credentials. Reads use HTTP only.
        readCodexRpc: async () => { throw capabilityError('credential-refresh-disabled', 'unavailable'); }
      }));
    } catch (error) {
      if (scope.signal?.aborted) throw error;
      snapshot = { updatedAt: request.now, refreshMs: DEFAULT_LIMITS_REFRESH_MS, providers: [] };
    }
    const providers = snapshot.providers.filter(provider => provider.provider === 'codex');
    target.evidence.limitsUnavailable = providers.length !== 1 || providers[0].status !== 'ok';
    result.targets.push({ sourceId: target.sourceIds[0], providerId: 'codex', accountId: target.accountId, snapshot });
    result.providers.push(...snapshot.providers);
    result.updatedAt = snapshot.updatedAt;
    result.refreshMs = snapshot.refreshMs;
  }
  return result;
}

// Builds the upstream-shaped aggregate: the merged scanned periods plus the
// accepted custom records, folded through upstream's own merge so the custom
// values carry the same dimensions as everything else.
function buildAggregate(up, usageResults, customContributions) {
  const periods = { today: [], month: [], allTime: [] };
  for (const { summary } of usageResults) {
    if (!summary) continue;
    periods.today.push(summary.today);
    periods.month.push(summary.month);
    periods.allTime.push(summary.allTime);
  }
  for (const period of ['today', 'month', 'allTime']) {
    for (const contribution of customContributions[period] || []) periods[period].push(contribution);
  }
  const aggregate = {
    today: up.usage.mergePeriods(...periods.today),
    month: up.usage.mergePeriods(...periods.month),
    allTime: up.usage.mergePeriods(...periods.allTime)
  };
  for (const period of Object.values(aggregate)) {
    if (!Object.keys(period.projects || {}).length) period.projects = up.usage.projectRollupFromSessions(period.sessions);
  }
  return aggregate;
}

// The usage bundle keeps the upstream period shape at the top level (merged
// across scan targets) and, under `targets`, the untouched per-target periods.
// The per-target copy is what a fixture test compares against a direct upstream
// call, so pass-through is provable rather than asserted.
function buildUsageBundle(up, usageResults) {
  const sanitized = usageResults
    .map(({ target, summary }) => ({ target, summary: sanitizeSummary(summary) }))
    .filter((entry) => entry.summary);
  const merge = (key) => up.usage.mergePeriods(...sanitized.map((entry) => entry.summary[key]));
  return {
    ...(sanitized[0]?.summary || {}),
    updatedAt: sanitized.length > 0 ? sanitized[sanitized.length - 1].summary.updatedAt : null,
    trackedClients: [...new Set(sanitized.flatMap((entry) => entry.summary.trackedClients))],
    historyAvailable: sanitized.some((entry) => entry.summary.historyAvailable),
    clientStatus: mergeClientStatus(sanitized.map((entry) => entry.summary.clientStatus)),
    periodWindows: sanitized.length > 0 ? sanitized[0].summary.periodWindows : null,
    today: merge('today'),
    month: merge('month'),
    allTime: merge('allTime'),
    targets: sanitized.map((entry) => ({
      ...entry.summary,
      sourceIds: entry.target.sourceIds.slice(),
      providerIds: entry.target.providerIds.slice(),
      updatedAt: entry.summary.updatedAt,
      today: entry.summary.today,
      month: entry.summary.month,
      allTime: entry.summary.allTime,
      clientStatus: entry.summary.clientStatus
    }))
  };
}

function deriveStatus(sources, errors, operationFailed) {
  if (operationFailed) return 'error';
  const degraded = sources.some((source) => source.status !== 'ok');
  return degraded || errors.length > 0 ? 'partial' : 'ok';
}

module.exports = {
  ALL_TIME_SINCE,
  ENGINE_AGENT_VERSION,
  DEFAULT_LIMITS_REFRESH_MS,
  buildPriceLookup,
  buildProviderFetch,
  usageOptionsFor,
  sanitizeSummary,
  mergeClientStatus,
  collectUsagePerTarget,
  collectHistoryPerTarget,
  collectLimitsOnce,
  buildAggregate,
  buildUsageBundle,
  deriveStatus,
  targetEnv,
  civilDate,
  explicitCost,
  graphCostEvidence,
  mergeGraphCostEvidence,
  custom
};
