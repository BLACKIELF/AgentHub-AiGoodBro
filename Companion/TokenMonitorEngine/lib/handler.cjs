'use strict';

const { CODES, BridgeError, structuredError } = require('./errors.cjs');
const { validateRequest, engineIdentity } = require('./protocol.cjs');
const capabilities = require('./upstream/capabilities.cjs');
const sourcesModule = require('./sources.cjs');
const coverageModule = require('./coverage.cjs');
const collect = require('./collect.cjs');
const { sanitize } = require('./sanitize.cjs');
const customModule = require('./custom.cjs');

// The pure request handler.
//
// It takes a decoded request object and a dependency bag, and returns the
// response object. It never reads stdin, writes stdout, exits the process or
// installs signal handlers — that is bridge.cjs's job. Fixture tests call this
// directly, which is what makes them fast and deterministic.

function defaultUpstream() {
  // Required lazily so a caller that injects its own upstream bundle never
  // pays for (or depends on) the pinned checkout being present.
  return require('./upstream/loader.cjs');
}

function sourceCoverageStatus(source, options) {
  return source.coverage || 'unknown';
}

function publicSource(source, options) {
  const entry = {
    id: source.id,
    providerId: source.providerId,
    status: source.status,
    coverage: sourceCoverageStatus(source, options)
  };
  if (source.reasonCode) entry.reasonCode = source.reasonCode;
  return entry;
}

function capabilityPayload(engine) {
  return {
    protocolVersion: 1,
    operations: ['collectUsage', 'collectLimits', 'capabilities'],
    upstream: engine,
    hooks: engine.hooks.slice(),
    vendorPackages: engine.vendorPackages.slice(),
    node: process.version,
    defaults: { ...capabilities.DEFAULTS },
    capabilities: {
      allowSelfSync: false,
      allowPriceNetwork: false,
      allowCredentialRefresh: false,
      allowProviderNetwork: true,
      includeLiveCodexAccount: false
    },
    notes: [
      'collect never calls a login or export path',
      'includeLiveCodexAccount requires an explicitly supplied managedAccount/codexHome source',
      'no implicit system home is read'
    ]
  };
}

function abortReasonOf(signal) {
  return signal?.reason instanceof Error ? signal.reason : new BridgeError(CODES.CANCELLED);
}

// A collection is raced against the scope's abort signal. Upstream checks its
// signal between scans, but a single stuck child (or an injected runner that
// never settles) would otherwise hold the request open past its deadline. The
// race guarantees the deadline is a real ceiling, not an aspiration.
function raceWithAbort(promise, scope) {
  const signal = scope?.signal;
  if (!signal) return promise;
  if (signal.aborted) return Promise.reject(abortReasonOf(signal));
  return new Promise((resolve, reject) => {
    const onAbort = () => reject(abortReasonOf(signal));
    signal.addEventListener('abort', onAbort, { once: true });
    promise.then(
      (value) => {
        signal.removeEventListener('abort', onAbort);
        resolve(value);
      },
      (error) => {
        signal.removeEventListener('abort', onAbort);
        reject(error);
      }
    );
  });
}

async function executeRequest(rawRequest, deps) {
  const request = validateRequest(rawRequest);
  const loader = deps.loader || defaultUpstream();
  const engine = loader.describeEngine();

  // Authorisation is applied before anything upstream runs, and the overlays
  // read it at call time.
  capabilities.resetCapabilities();
  capabilities.setCapabilities({
    allowSelfSync: false,
    allowPriceNetwork: request.options.allowPriceNetwork,
    allowCredentialRefresh: false,
    allowProviderNetwork: request.options.allowProviderNetwork
  });

  const errors = [];
  const todayKey = coverageModule.civilDate(new Date(request.now), request.timezone);

  // ---- capabilities -------------------------------------------------------
  if (request.operation === 'capabilities') {
    return {
      schemaVersion: 1,
      requestId: request.requestId,
      engine: engineIdentity(engine),
      collectedAt: request.now,
      timezone: request.timezone,
      status: 'ok',
      sources: [],
      payload: { capabilities: capabilityPayload(engine) },
      coverage: { entries: [], days: [], cost: 'unknown' },
      errors: []
    };
  }

  // ---- source resolution --------------------------------------------------
  const catalog = loader.loadCatalog();
  const clientIds = new Set(catalog.knownClientIds);
  const resolvedSources = sourcesModule.resolveSources(request, { clientIds, catalog });
  errors.push(...resolvedSources.errors);

  const liveAccountError = sourcesModule.checkLiveCodexAccount(request, resolvedSources.sources);
  if (liveAccountError) {
    throw new BridgeError(CODES.INVALID_SOURCE);
  }

  const targets = sourcesModule.buildTargets(resolvedSources.sources);
  deps.targetResources.push(...targets);


  // ---- custom sources -----------------------------------------------------
  const upstreamSourceIds = new Set(resolvedSources.sources.map((source) => source.id));
  const hasUpstreamTotals = resolvedSources.sources.some((source) => source.authority === 'upstream');
  const resolvedCustom = customModule.resolveCustomSources(request, { upstreamSourceIds, hasUpstreamTotals });
  errors.push(...resolvedCustom.errors);
  const customContributions = customModule.buildContributions(resolvedCustom.accepted);

  // ---- operation ----------------------------------------------------------
  // Only the half of the upstream graph this operation needs is loaded; see
  // loader.loadUsage/loadLimits.
  const upstream = deps.upstream
    || (request.operation === 'collectLimits' ? loader.loadLimits() : loader.loadUsage());
  const scope = deps.scope || { signal: deps.signal, checkAborted: () => {} };
  const runnerDeps = {
    runTokscale: deps.runTokscale,
    runGraph: deps.runGraph,
    collectWslUsage: deps.collectWslUsage,
    probeWslState: deps.probeWslState,
    runAntigravitySync: deps.runAntigravitySync,
    lookupModelPricing: deps.lookupModelPricing,
    limitsDeps: deps.limitsDeps,
    now: deps.now,
    fetch: deps.fetch
  };

  let payload = {};
  let limitsSnapshot = null;
  let history = null;
  let costEstimates = null;

  if (request.operation === 'collectUsage') {
    const usageResults = await raceWithAbort(
      collect.collectUsagePerTarget(upstream, targets, request, runnerDeps, scope, todayKey, errors),
      scope
    );
    const historyResult = await raceWithAbort(
      collect.collectHistoryPerTarget(upstream, targets, request, runnerDeps, scope, todayKey, errors),
      scope
    );
    history = historyResult.history;
    costEstimates = historyResult.costEstimates;
    payload.usage = collect.buildUsageBundle(upstream, usageResults);
    payload.history = history;
    payload.costEstimates = costEstimates;
    const aggregate = collect.buildAggregate(upstream, usageResults, customContributions);
    aggregate.customSources = {
      accepted: resolvedCustom.accepted.map((record) => ({ sourceId: record.sourceId, providerId: record.providerId, period: record.period })),
      excluded: resolvedCustom.excluded.map((record) => ({ sourceId: record.sourceId, reasonCode: record.reasonCode }))
    };
    payload.aggregate = aggregate;
  } else if (request.operation === 'collectLimits') {
    try {
      limitsSnapshot = await raceWithAbort(
        collect.collectLimitsOnce(upstream, request, runnerDeps, scope, targets),
        scope
      );
    } catch (error) {
      if (scope.signal?.aborted) throw error;
      errors.push(structuredError(CODES.LIMITS_FAILED));
      limitsSnapshot = null;
    }
    payload.limits = limitsSnapshot;
  }

  for (const target of targets) {
    for (const id of target.sourceIds) {
      const source = resolvedSources.sources.find(source => source.id === id);
      source.evidence = target.evidence;
      if (target.evidence.usageFailed || target.evidence.limitsUnavailable ||
          (request.operation === 'collectUsage' && !target.evidence.historySucceeded)) {
        source.status = 'unavailable';
        source.reasonCode = 'collection_incomplete';
      }
    }
  }

  const suppressions = capabilities.takeSuppressions();
  if (suppressions.blocked.length > 0) payload.suppressed = suppressions.blocked;

  const coverage = coverageModule.computeCoverage({
    sources: resolvedSources.sources,
    acceptedCustom: resolvedCustom.accepted,
    excludedCustom: resolvedCustom.excluded,
    history,
    limitsSnapshot,
    timezone: request.timezone,
    todayKey,
    options: request.options
  });

  for (const source of resolvedSources.sources) {
    source.coverage = coverageModule.reduceStatuses(coverage.entries.filter(entry => entry.sourceId === source.id
      && entry.metric === (request.operation === 'collectLimits' ? 'quota' : 'tokens')).map(entry => entry.status));
  }

  const operationFailed = request.operation === 'collectLimits' && limitsSnapshot === null
    && errors.some((error) => error.code === CODES.LIMITS_FAILED);

  return {
    schemaVersion: 1,
    requestId: request.requestId,
    engine: engineIdentity(engine),
    collectedAt: request.now,
    timezone: request.timezone,
    status: collect.deriveStatus(resolvedSources.sources, errors, operationFailed),
    sources: resolvedSources.sources.map((source) => publicSource(source, request.options)),
    payload: sanitize(payload),
    coverage: { entries: coverage.entries, days: coverage.days, cost: coverage.cost },
    errors
  };
}

async function handleRequest(rawRequest, deps = {}) {
  const targetResources = [];
  try { return await executeRequest(rawRequest, { ...deps, targetResources }); }
  finally {
    const { disposeTarget } = require('./runtime/source-scope.cjs');
    for (const target of targetResources) disposeTarget(target);
  }
}

module.exports = { handleRequest, capabilityPayload, publicSource, sourceCoverageStatus };
