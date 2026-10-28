'use strict';

// Cursor limits provider: per-account billing and on-demand windows, using the
// session/auth helpers in this folder. Reached through providerFetchers() in
// src/shared/limits/collector.js.

const cursorAuth = require('./auth');
const cursorProbe = require('./probe');
const { hashKey } = require('../../hashKey');
const {
  cleanPlanText,
  displayPlanText
} = require('../../limits/providerHelpers');

function hashCursorAccountKey(account, resolvedUserId = '') {
  const accountId = String(account?.id || '').trim();
  const canonicalUserId = [resolvedUserId, account?.userId, accountId]
    .map(cursorAuth.canonicalCursorUserId)
    .find(Boolean) || '';
  if (canonicalUserId) return hashKey('cursor', canonicalUserId);
  return hashKey('cursor-local', accountId || 'unknown');
}

function formatCursorMembership(type) {
  if (!type || typeof type !== 'string') return '';
  const raw = type.trim().toLowerCase();
  if (!raw) return '';
  if (raw === 'pro+' || raw === 'pro_plus') return 'Pro+';
  return displayPlanText(cleanPlanText(raw, []), Infinity);
}

function finiteNumber(value) {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

function percentFromUsedLimit(used, limit) {
  const safeUsed = finiteNumber(used);
  const safeLimit = finiteNumber(limit);
  if (safeUsed === null || safeLimit === null || safeLimit <= 0) return null;
  return Math.max(0, Math.min(100, (safeUsed / safeLimit) * 100));
}

function cursorResetIso(usage) {
  if (!usage.billingCycleEnd) return null;
  const date = new Date(usage.billingCycleEnd);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

function cursorBillingWindow(label, fields = {}) {
  return {
    kind: 'billing',
    label,
    ...fields
  };
}

function cursorPlanType(usage) {
  if (usage.planInfo) return usage.planInfo.isMerged === true ? 'unified' : 'legacy';
  if (usage.grokBot) return usage.grokBot.isUnified === true ? 'unified' : 'legacy';
  return 'unknown';
}

function cursorIncludedWindow(usage, billingResetsAt) {
  if (finiteNumber(usage.planPercent) === null) return null;
  const period = usage.planInfo?.includedUsagePeriod;
  const weekly = period === 'weekly' || (!period && usage.grokBot?.isUnified === true && usage.grokBot.windowMinutes === 10080);
  if (!weekly && period !== 'monthly') return null;
  return {
    kind: weekly ? 'weekly' : 'billing',
    label: 'Included usage',
    usedPercent: usage.planPercent,
    resetsAt: weekly
      ? usage.planInfo?.includedUsageResetsAt || (usage.grokBot?.isUnified === true ? usage.grokBot.resetsAt : null) || null
      : billingResetsAt,
    windowMinutes: weekly ? 7 * 24 * 60 : null,
    resetDescription: '',
    showMeter: true
  };
}

function cursorOnDemandWindow(usage, resetsAt) {
  const personalLimit = finiteNumber(usage.onDemandLimitUsd);
  const teamLimit = finiteNumber(usage.teamOnDemandLimitUsd);
  const personalRemaining = finiteNumber(usage.onDemandRemainingUsd);
  const teamRemaining = finiteNumber(usage.teamOnDemandRemainingUsd);
  const inferredUsed = (limit, remaining) => limit !== null && remaining !== null
    && limit >= 0 && remaining >= 0 && remaining <= limit ? limit - remaining : null;
  const personalUsed = finiteNumber(usage.onDemandUsedUsd) ?? inferredUsed(personalLimit, personalRemaining);
  const teamUsed = finiteNumber(usage.teamOnDemandUsedUsd) ?? inferredUsed(teamLimit, teamRemaining);
  let used;
  let limit = null;
  let remaining = null;

  if (personalLimit !== null && personalLimit > 0 && personalUsed !== null) {
    used = personalUsed;
    limit = personalLimit;
    remaining = personalRemaining;
  } else if (teamLimit !== null && teamLimit > 0 && teamUsed !== null) {
    used = teamUsed;
    limit = teamLimit;
    remaining = teamRemaining;
  } else if (personalUsed > 0) {
    used = personalUsed;
  } else if (teamUsed > 0) {
    used = teamUsed;
  } else {
    return null;
  }

  if (limit !== null && remaining === null) remaining = Math.max(0, limit - used);
  return cursorBillingWindow('On-demand spend', {
    metric: 'spend',
    currency: 'USD',
    usedPercent: percentFromUsedLimit(used, limit),
    used,
    limit,
    remaining,
    resetsAt,
    windowMinutes: null,
    resetDescription: '',
    showMeter: false
  });
}

async function fetchCursorAccountLimits(account, deps = {}) {
  const nowMs = (deps.now || Date.now)();
  const updatedAt = new Date(nowMs).toISOString();
  const probe = deps.probe || cursorProbe.probe;
  if (!account) {
    return {
      provider: 'cursor',
      accountKey: '',
      accountLabel: '',
      status: 'notConfigured',
      source: 'web',
      updatedAt,
      windows: []
    };
  }

  const result = await probe(account.sessionToken, deps);
  if (!result.ok) {
    const kind = result.error?.kind === 'unauthorized' ? 'unauthorized' : 'unavailable';
    return {
      provider: 'cursor',
      accountKey: hashCursorAccountKey(account),
      accountLabel: account.label || '',
      status: kind,
      source: 'web',
      updatedAt,
      windows: []
    };
  }

  const { usage } = result;
  const resetsAt = cursorResetIso(usage) || usage.planInfo?.billingCycleEnd || null;
  const planType = cursorPlanType(usage);
  const hasRequestUsage = finiteNumber(usage.requestsUsed) !== null
    && finiteNumber(usage.requestsLimit) !== null
    && usage.requestsLimit > 0;
  const windows = [];

  if (planType === 'unified') {
    const includedWindow = cursorIncludedWindow(usage, resetsAt);
    if (includedWindow) windows.push(includedWindow);
  } else if (planType === 'legacy' && hasRequestUsage) {
    windows.push(cursorBillingWindow('Requests', {
      usedPercent: percentFromUsedLimit(usage.requestsUsed, usage.requestsLimit),
      used: usage.requestsUsed,
      limit: usage.requestsLimit,
      remaining: Math.max(0, usage.requestsLimit - usage.requestsUsed),
      resetsAt,
      windowMinutes: null,
      resetDescription: usage.membershipType ? `Cursor ${usage.membershipType}` : ''
    }));
  } else if (planType === 'legacy' && (finiteNumber(usage.autoPercent) !== null || finiteNumber(usage.apiPercent) !== null)) {
    if (finiteNumber(usage.autoPercent) !== null) windows.push(cursorBillingWindow('Cursor Models', {
      usedPercent: usage.autoPercent,
      resetsAt,
      windowMinutes: null
    }));
    if (finiteNumber(usage.apiPercent) !== null) windows.push(cursorBillingWindow('Other Models', {
      usedPercent: usage.apiPercent,
      resetsAt,
      windowMinutes: null
    }));
  } else if (planType === 'legacy' && usage.hasOverallUsage && finiteNumber(usage.planPercent) !== null) {
    windows.push(cursorBillingWindow('Overall', {
      usedPercent: usage.planPercent,
      used: usage.planUsedUsd,
      limit: usage.planLimitUsd,
      remaining: usage.planRemainingUsd,
      resetsAt,
      windowMinutes: null
    }));
  }

  if (planType === 'legacy' && usage.grokBot?.hasNonZeroIncludedLimit === true && finiteNumber(usage.grokBot.usedPercent) !== null) {
    windows.push({
      kind: 'weekly',
      label: 'Grok Bot',
      usedPercent: usage.grokBot.usedPercent,
      resetsAt: usage.grokBot.resetsAt || null,
      windowMinutes: finiteNumber(usage.grokBot.windowMinutes),
      resetDescription: '',
      showMeter: true
    });
  }

  const teamLimit = finiteNumber(usage.teamPooledLimitUsd);
  const teamRemaining = finiteNumber(usage.teamPooledRemainingUsd);
  const teamUsed = finiteNumber(usage.teamPooledUsedUsd)
    ?? (teamLimit !== null && teamRemaining !== null && teamLimit >= 0 && teamRemaining >= 0 && teamRemaining <= teamLimit
      ? teamLimit - teamRemaining : null);
  const teamPercent = finiteNumber(usage.teamPooledPercent) ?? percentFromUsedLimit(teamUsed, teamLimit);
  if (teamUsed !== null || teamRemaining !== null || teamPercent !== null) {
    const remaining = teamRemaining ?? (teamLimit !== null && teamUsed !== null ? Math.max(0, teamLimit - teamUsed) : null);
    windows.push(cursorBillingWindow('Team pool', {
      usedPercent: teamPercent,
      used: teamUsed,
      limit: usage.teamPooledLimitUsd,
      remaining,
      resetsAt,
      windowMinutes: null,
      showMeter: teamPercent !== null,
      resetDescription: 'Shared team usage pool.'
    }));
  }

  const onDemandWindow = cursorOnDemandWindow(usage, resetsAt);
  if (onDemandWindow) windows.push(onDemandWindow);

  return {
    provider: 'cursor',
    accountKey: hashCursorAccountKey(account, result.user?.sub),
    accountLabel: result.user?.email || account.label || formatCursorMembership(usage.membershipType) || '',
    accountEmail: result.user?.email || '',
    planLabel: formatCursorMembership(usage.membershipType),
    status: planType !== 'legacy' && windows.length === 0 ? 'unavailable' : 'ok',
    source: 'web',
    updatedAt,
    windows,
    // Internal runtime hint: unverified legacy seats must not return from cache.
    ...(planType === 'unknown' || (planType === 'unified' && !windows.some((window) => window.label === 'Included usage')) ? {
      invalidateCachedWindowLabels: [
        'Requests', 'Cursor Models', 'Other Models', 'Overall',
        ...(planType === 'unified' ? ['Grok Bot'] : [])
      ]
    } : {})
  };
}

async function fetchCursorLimits(options = {}, deps = {}) {
  let accounts;
  if (typeof deps.listAccounts === 'function') {
    accounts = deps.listAccounts();
  } else if (typeof deps.readActiveAccount === 'function') {
    accounts = [deps.readActiveAccount()].filter(Boolean);
  } else {
    accounts = cursorAuth.listAccounts();
  }
  if (!Array.isArray(accounts) || accounts.length === 0) {
    return fetchCursorAccountLimits(null, deps);
  }
  const disabled = new Set((Array.isArray(options.cursorDisabledAccountIds) ? options.cursorDisabledAccountIds : [])
    .map((id) => String(id || '').trim())
    .filter(Boolean));
  const enabledAccounts = accounts.filter((account) => !disabled.has(account.id));
  if (enabledAccounts.length === 0) return fetchCursorAccountLimits(null, deps);
  const providers = await Promise.all(enabledAccounts.map((account) => fetchCursorAccountLimits(account, deps)));
  return providers.length === 1 ? providers[0] : providers;
}

module.exports = {
  fetchCursorLimits
};
