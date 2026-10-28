'use strict';

const { createHash } = require('node:crypto');

const MAX_BYTES = 8 * 1024 * 1024;
const MAX_DAILY = 10000;
const TOKEN_FIELDS = ['tokens', 'unpricedTokens', 'cacheReadTokens', 'cacheWriteTokens', 'inputTokens', 'outputTokens', 'unclassifiedTokens'];
const COUNT_FIELDS = ['messages'];
const TIME_FIELDS = ['activeTimeMs'];
const SUMMARY_COUNTS = ['activeDays', 'currentStreak', 'longestStreak', 'messages'];
const pending = (scopeKey) => Object.freeze({ scopeKey, pending: true });

function invalid(kind) { throw new Error('home-usage-invalid-' + kind); }
function object(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function number(value, whole = false) {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0 || (whole && !Number.isSafeInteger(value))) invalid('number');
  return value;
}

function dateKey(value, monthly = false) {
  const pattern = monthly ? /^\d{4}-(?:0[1-9]|1[0-2])$/ : /^\d{4}-\d{2}-\d{2}$/;
  if (typeof value !== 'string' || !pattern.test(value)) invalid('date');
  const day = monthly ? value + '-01' : value;
  const parsed = new Date(day + 'T00:00:00.000Z');
  if (!Number.isFinite(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== day) invalid('date');
  return value;
}

function safeName(value, client = false) {
  // Tokscale can report this exact model sentinel; keep its bucket distinct
  // without allowing arbitrary HTML-like or private labels across the bridge.
  if (!client && value === '<synthetic>') return value;
  if (typeof value !== 'string' || value !== value.trim() || !value || Buffer.byteLength(value) > 128
    || !/^[\p{L}\p{N}][\p{L}\p{N} ._+():/@-]*$/u.test(value)
    || /[a-z0-9._%+-]{1,64}@[a-z0-9.-]{1,253}\.[a-z]{2,63}/i.test(value)
    || /\b(?:Bearer\s+\S+|sk-[A-Za-z0-9_-]{16,})/i.test(value)
    || value.includes('..') || value.includes('://') || /^[a-z]:/i.test(value)
    || /(?:^|\/)(?:users|home|private|volumes|tmp|var|etc|documents|desktop|downloads)(?:\/|$)/i.test(value)
    || /\.(?:jsonl?|log|txt|md|csv|sqlite|db)(?:$|\/)/i.test(value)
    || (client && !/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(value))) invalid('label');
  return value;
}

function metrics(value) {
  if (!object(value)) invalid('metrics');
  const result = {};
  for (const field of TOKEN_FIELDS) result[field] = number(value[field], true);
  for (const field of COUNT_FIELDS) {
    const count = number(value[field], true);
    // Native validation reserves "messages" for a numeric count. Omitting an
    // unavailable count preserves unknown without weakening that privacy gate.
    if (count !== null) result[field] = count;
  }
  for (const field of TIME_FIELDS) result[field] = number(value[field]);
  result.cost = number(value.cost);
  return result;
}

function groups(value, client) {
  if (value === undefined || value === null) return null;
  if (!object(value)) invalid('groups');
  const result = Object.create(null);
  for (const [name, bucket] of Object.entries(value)) {
    const key = safeName(name, client);
    if (key === '__proto__' || key === 'constructor' || key === 'prototype') invalid('label');
    result[key] = metrics(bucket);
  }
  return result;
}

function rows(value, monthly = false) {
  if (value === undefined || value === null) return null;
  if (!Array.isArray(value)) invalid('history');
  if (value.length > MAX_DAILY) invalid('history-size');
  const key = monthly ? 'month' : 'date';
  const seen = new Set();
  const result = value.map((row) => {
    if (!object(row)) invalid('history');
    const date = dateKey(row[key], monthly);
    if (seen.has(date)) invalid('duplicate-date');
    seen.add(date);
    return {
      [key]: date,
      ...metrics(row),
      perClient: groups(row.perClient, true),
      perModel: groups(row.perModel, false)
    };
  });
  return result.sort((a, b) => a[key].localeCompare(b[key]));
}

function historySummary(value, totals) {
  if (value !== undefined && value !== null && !object(value)) invalid('summary');
  const source = value || {};
  const result = { totalTokens: totals.totalTokens, totalCost: totals.costUsd };
  for (const field of SUMMARY_COUNTS) {
    const count = number(source[field], true);
    if (field !== 'messages' || count !== null) result[field] = count;
  }
  for (const field of ['peakDayTokens', 'unpricedTokens']) result[field] = number(source[field], true);
  result.activeTimeMs = number(source.activeTimeMs);
  result.favoriteModel = source.favoriteModel === undefined || source.favoriteModel === null || source.favoriteModel === ''
    ? null : safeName(source.favoriteModel);
  if (source.timeMetrics !== undefined && source.timeMetrics !== null) {
    if (!object(source.timeMetrics)) invalid('time-metrics');
    result.timeMetrics = {
      totalActiveTimeMs: number(source.timeMetrics.totalActiveTimeMs),
      longestContinuousMs: number(source.timeMetrics.longestContinuousMs),
      maxConcurrentSessions: number(source.timeMetrics.maxConcurrentSessions, true),
      sessionCount: number(source.timeMetrics.sessionCount, true)
    };
  }
  return result;
}

function timestamp(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,3})?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$/.test(value)) invalid('timestamp');
  dateKey(value.slice(0, 10));
  const time = Date.parse(value);
  if (!Number.isFinite(time)) invalid('timestamp');
  return new Date(time).toISOString();
}

function timezone(value) {
  if (value === undefined || value === null) return Intl.DateTimeFormat().resolvedOptions().timeZone;
  if (typeof value !== 'string' || value.length > 128) invalid('timezone');
  try { return new Intl.DateTimeFormat('en-US', { timeZone: value }).resolvedOptions().timeZone; }
  catch (_) { invalid('timezone'); }
}

function statsInput(stats) {
  if (stats === undefined || stats === null) return null;
  if (!object(stats)) invalid('stats');
  if (stats.aigoodbroUsagePending === true || stats.periods === undefined || stats.periods === null) return null;
  if (!object(stats.periods)) invalid('stats');
  if (stats.periods.allTime === undefined || stats.periods.allTime === null) return null;
  if (!object(stats.periods.allTime)) invalid('stats');
  const allTime = stats.periods.allTime;
  const totalTokens = number(allTime.totalTokens, true);
  const costUsd = number(allTime.costUsd);
  const unpricedTokens = number(allTime.unpricedTokens, true);
  return {
    totalTokens, costUsd,
    coverage: { tokens: totalTokens === null ? 'unknown' : 'known', cost: costUsd === null ? 'unknown' : unpricedTokens > 0 ? 'partial' : 'known' },
    timezone: timezone(stats.timezone),
    collectedAt: stats.collectedAt !== undefined && stats.collectedAt !== null ? timestamp(stats.collectedAt)
      : stats.updatedAt !== undefined && stats.updatedAt !== null ? timestamp(stats.updatedAt) : null
  };
}

function createHomeUsageProvider({ getStats, getHistory, getContext, now = Date.now }) {
  if ([getStats, getHistory, getContext, now].some((fn) => typeof fn !== 'function')) throw new Error('home-usage-invalid-dependency');
  let cached = null;
  let inFlight = null;

  function contextValue() {
    const context = getContext();
    if (typeof context !== 'string' || Buffer.byteLength(context) > 65536) invalid('context');
    return context;
  }
  function scopeHash(context) { return createHash('sha256').update(context).digest('hex'); }
  function capture() {
    const context = contextValue();
    const stats = getStats();
    const input = statsInput(stats);
    return { stats, context, scopeKey: scopeHash(context), current: contextValue() === context,
      input, signature: input ? JSON.stringify(input) : null };
  }
  function matches(left, right) {
    return right.current && right.input && left.stats === right.stats && left.context === right.context && left.signature === right.signature;
  }
  function respond(result, ifRevision) {
    return result.pending ? result : ifRevision === result.revision ? { scopeKey: result.scopeKey, revision: result.revision, unchanged: true } : result;
  }

  const read = async function read(ifRevision) {
    const start = capture();
    if (!start.current || !start.input) { cached = null; return pending(start.scopeKey); }
    if (cached && matches(cached.key, start)) return respond(cached.result, ifRevision);
    if (inFlight) {
      // Do not start a second history scan while the prior scope is resolving.
      return matches(inFlight.key, start) ? respond(await inFlight.promise, ifRevision) : pending(start.scopeKey);
    }
    const flight = { key: start, promise: null };
    flight.promise = (async () => {
      let history;
      try { history = await getHistory(); }
      catch (_) {
        if (!matches(start, capture())) return pending(start.scopeKey);
        throw new Error('home-usage-history-read-failed');
      }
      if (!matches(start, capture())) return pending(start.scopeKey);
      if (!object(history)) invalid('history');
      const { totalTokens, costUsd, coverage } = start.input;
      let collectedAt = start.input.collectedAt;
      if (collectedAt === null) {
        const current = now();
        if (!Number.isSafeInteger(current) || current < 0 || !Number.isFinite(new Date(current).getTime())) invalid('clock');
        collectedAt = new Date(current).toISOString();
      }
      const dashboardJSON = JSON.stringify({
        schemaVersion: 1,
        authority: 'token-monitor-desktop',
        collectedAt,
        timezone: start.input.timezone,
        coverage,
        payload: { aggregate: {
          allTime: { totalTokens, costUsd },
          history: {
            daily: rows(history.daily),
            monthly: rows(history.monthly, true),
            summary: historySummary(history.summary, { totalTokens, costUsd })
          }
        } }
      });
      if (Buffer.byteLength(dashboardJSON) > MAX_BYTES) invalid('size');
      if (!matches(start, capture())) return pending(start.scopeKey);
      const revision = createHash('sha256').update(start.context).update('\0').update(dashboardJSON).digest('hex');
      const result = Object.freeze({ scopeKey: start.scopeKey, revision, dashboardJSON, pending: false });
      cached = { key: start, result };
      return result;
    })().finally(() => { if (inFlight === flight) inFlight = null; });
    inFlight = flight;
    return respond(await flight.promise, ifRevision);
  };
  read.scopeKey = () => scopeHash(contextValue());
  return read;
}

module.exports = { createHomeUsageProvider };
