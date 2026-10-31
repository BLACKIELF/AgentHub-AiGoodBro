export interface ProxyAccountPolicy {
  fiveHourUsedLimit: number;
  sevenDayUsedLimit: number;
  allowsCredits: boolean;
  creditPrimaryFloor: number | null;
  creditSecondaryFloor: number | null;
}

export interface ProxyPreferences {
  schemaVersion: number;
  isEnabled: boolean;
  automaticRecoveryEnabled: boolean;
  order: string[];
  enabledIds: string[];
  knownIds: string[];
  priorityIds: string[];
  lastIds: string[];
  lastOverrides: Record<string, boolean>;
  creditFallback: boolean;
  creditPrimaryFloor: number;
  creditSecondaryFloor: number;
  accountPolicies: Record<string, ProxyAccountPolicy>;
  resetStopRules: Record<string, { identityHash: string; armedAt: number; pausedAt: number | null; previousResetAt: number | null }>;
  listenPort: number;
  clientKeyMode: 'persistent' | 'perRun';
  desktopFallback: boolean;
  networkProxy: string;
  egress: { enabled: boolean; mihomoApi: string; group: string; whitelist: string[] };
}

export type ProxyPhase = 'stopped' | 'starting' | 'running' | 'stopping' | 'failed';
export interface ProxyStatus {
  phase: ProxyPhase;
  port: number | null;
  issue: string | null;
  accounts: Record<string, { state: string; cooldownUntil: number | null; cooldownKind: string | null; probeState: string | null }>;
  lastEventAt: number | null;
  egress: { state: string; requestId: string | null; latencyMs: number | null } | null;
}

export interface ProxyAccount {
  id: string;
  label: string;
  planType: string | null;
  isLast: boolean;
  isPriority: boolean;
  isEnabled: boolean;
  quota: null | {
    fiveHourUsedPercent: number | null; fiveHourResetsAt: number | null;
    sevenDayUsedPercent: number | null; sevenDayResetsAt: number | null;
    monthlyUsedPercent: number | null; monthlyResetsAt: number | null;
    observedAt: number; creditBalancePoints: string | null;
  };
  availability: 'available' | 'unknown';
  reasonCode: string | null;
}

const fail = (): never => { throw new Error('invalid_settings'); };
const object = (value: unknown): Record<string, unknown> => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return fail();
  return value as Record<string, unknown>;
};
const bool = (value: unknown): boolean => typeof value === 'boolean' ? value : fail();
const finite = (value: unknown): number => typeof value === 'number' && Number.isFinite(value) ? value : fail();
const integer = (value: unknown, max = Number.MAX_SAFE_INTEGER): number => {
  const number = finite(value);
  return Number.isSafeInteger(number) && number >= 0 && number <= max ? number : fail();
};
const nullableNumber = (value: unknown): number | null => value === null ? null : finite(value);
const text = (value: unknown, max = 512): string => typeof value === 'string' && value.length <= max && !/[\r\n\0]/.test(value) ? value : fail();
const code = (value: unknown): string => typeof value === 'string' && /^[a-z_]{1,64}$/.test(value) ? value : fail();
const id = (value: unknown): string => typeof value === 'string' && /^[a-zA-Z0-9_-]{1,128}$/.test(value) ? value : fail();
const ids = (value: unknown): string[] => {
  if (!Array.isArray(value) || value.length > 100) return fail();
  const result = value.map(id);
  return new Set(result).size === result.length ? result : fail();
};
const keyed = <T>(value: unknown, parse: (entry: unknown) => T): Record<string, T> => {
  const entries = Object.entries(object(value));
  if (entries.length > 100) return fail();
  return Object.fromEntries(entries.map(([key, entry]) => [id(key), parse(entry)]));
};

export function parseProxyPolicy(raw: unknown): ProxyAccountPolicy {
  const value = object(raw);
  const limit = finite(value.fiveHourUsedLimit);
  // Missing in pre-1030 preferences: no new reserve, same actual cutoff.
  const sevenDayLimit = value.sevenDayUsedLimit === undefined ? 100 : finite(value.sevenDayUsedLimit);
  const primary = value.creditPrimaryFloor === null ? null : integer(value.creditPrimaryFloor);
  const secondary = value.creditSecondaryFloor === null ? null : integer(value.creditSecondaryFloor);
  if (limit < 0 || limit > 100 || (primary === null) !== (secondary === null) || (primary !== null && secondary !== null && primary <= secondary)) return fail();
  if (sevenDayLimit < 0 || sevenDayLimit > 100) return fail();
  return { fiveHourUsedLimit: limit, sevenDayUsedLimit: sevenDayLimit, allowsCredits: bool(value.allowsCredits), creditPrimaryFloor: primary, creditSecondaryFloor: secondary };
}

export function validNetworkProxy(value: string): boolean {
  if (!value) return true;
  const match = /^(?:http|socks5):\/\/([^\s/?#@\\]+):(\d+)$/.exec(value);
  return !!match && Number(match[2]) > 0 && Number(match[2]) <= 65535;
}

function parseEgress(raw: unknown): ProxyPreferences['egress'] {
  const value = object(raw);
  const enabled = bool(value.enabled);
  const mihomoApi = text(value.mihomoApi);
  const group = text(value.group, 256);
  if (!Array.isArray(value.whitelist) || value.whitelist.length > 64) return fail();
  const whitelist = value.whitelist.map(entry => text(entry));
  if (group.trim() !== group || whitelist.some(entry => !entry || entry.trim() !== entry) || new Set(whitelist).size !== whitelist.length || (enabled && !group)) return fail();
  if (mihomoApi) {
    if (!/^http:\/\/(?:127(?:\.\d{1,3}){3}|\[::1\]):\d+$/.test(mihomoApi)) return fail();
    const port = Number(mihomoApi.slice(mihomoApi.lastIndexOf(':') + 1));
    if (!port || port > 65535 || /127\.(?:\d{1,3}\.){2}(\d{1,3})/.test(mihomoApi) && mihomoApi.slice(7).split(':')[0].split('.').some(part => Number(part) > 255)) return fail();
  } else if (enabled) return fail();
  return { enabled, mihomoApi, group, whitelist };
}

// Keep every production preference, including rules this surface does not edit.
export function parseProxyPreferences(raw: unknown): ProxyPreferences {
  const value = object(raw);
  const listenPort = integer(value.listenPort, 65535);
  const primary = integer(value.creditPrimaryFloor);
  const secondary = integer(value.creditSecondaryFloor);
  const networkProxy = text(value.networkProxy);
  if (value.schemaVersion !== 1 || (listenPort !== 0 && listenPort < 1024) || primary <= secondary || !validNetworkProxy(networkProxy) || !['persistent', 'perRun'].includes(value.clientKeyMode as string)) return fail();
  return {
    schemaVersion: 1, isEnabled: bool(value.isEnabled), automaticRecoveryEnabled: bool(value.automaticRecoveryEnabled),
    order: ids(value.order), enabledIds: ids(value.enabledIds), knownIds: ids(value.knownIds), priorityIds: ids(value.priorityIds), lastIds: ids(value.lastIds),
    lastOverrides: keyed(value.lastOverrides, bool), creditFallback: bool(value.creditFallback), creditPrimaryFloor: primary, creditSecondaryFloor: secondary,
    accountPolicies: keyed(value.accountPolicies, parseProxyPolicy),
    resetStopRules: keyed(value.resetStopRules, rawRule => {
      const rule = object(rawRule);
      if (typeof rule.identityHash !== 'string' || !/^[a-fA-F0-9]{64}$/.test(rule.identityHash)) return fail();
      const armedAt = finite(rule.armedAt);
      const pausedAt = nullableNumber(rule.pausedAt);
      if (pausedAt !== null && pausedAt < armedAt) return fail();
      return { identityHash: rule.identityHash, armedAt, pausedAt, previousResetAt: nullableNumber(rule.previousResetAt) };
    }),
    listenPort, clientKeyMode: value.clientKeyMode as ProxyPreferences['clientKeyMode'], desktopFallback: bool(value.desktopFallback), networkProxy,
    egress: parseEgress(value.egress),
  };
}

export function parseProxyStatus(raw: unknown): ProxyStatus {
  const value = object(raw);
  if (!['stopped', 'starting', 'running', 'stopping', 'failed'].includes(value.phase as string)) return fail();
  const port = value.port === null ? null : integer(value.port, 65535);
  if (port === 0 || (value.phase === 'running' && port === null)) return fail();
  return {
    phase: value.phase as ProxyPhase, port, issue: value.issue === null ? null : code(value.issue),
    accounts: keyed(value.accounts, rawAccount => {
      const account = object(rawAccount);
      return { state: code(account.state), cooldownUntil: nullableNumber(account.cooldownUntil), cooldownKind: account.cooldownKind === null ? null : code(account.cooldownKind), probeState: account.probeState === null ? null : code(account.probeState) };
    }),
    lastEventAt: nullableNumber(value.lastEventAt),
    egress: value.egress === null ? null : (() => {
      const egress = object(value.egress);
      const requestId = egress.requestId === null ? null : text(egress.requestId, 36);
      if (requestId !== null && !/^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$/.test(requestId)) return fail();
      return { state: code(egress.state), requestId, latencyMs: egress.latencyMs === null ? null : integer(egress.latencyMs, 4294967295) };
    })(),
  };
}

export function parseProxyAccounts(raw: unknown): ProxyAccount[] {
  if (!Array.isArray(raw) || raw.length > 100) return fail();
  const accounts = raw.map(entry => {
    const value = object(entry);
    if (!['available', 'unknown'].includes(value.availability as string)) return fail();
    let quota: ProxyAccount['quota'] = null;
    if (value.quota !== null) {
      const q = object(value.quota);
      const percent = (input: unknown) => { const number = nullableNumber(input); return number === null || number >= 0 && number <= 100 ? number : fail(); };
      const credit = q.creditBalancePoints === null ? null : text(q.creditBalancePoints, 100);
      if (credit !== null && !/^\d+(?:\.\d+)?$/.test(credit)) return fail();
      quota = { fiveHourUsedPercent: percent(q.fiveHourUsedPercent), fiveHourResetsAt: nullableNumber(q.fiveHourResetsAt), sevenDayUsedPercent: percent(q.sevenDayUsedPercent), sevenDayResetsAt: nullableNumber(q.sevenDayResetsAt), monthlyUsedPercent: percent(q.monthlyUsedPercent), monthlyResetsAt: nullableNumber(q.monthlyResetsAt), observedAt: finite(q.observedAt), creditBalancePoints: credit };
    }
    return { id: id(value.id), label: text(value.label, 200), planType: value.planType === null ? null : text(value.planType, 64), isLast: bool(value.isLast), isPriority: bool(value.isPriority), isEnabled: bool(value.isEnabled), quota, availability: value.availability as ProxyAccount['availability'], reasonCode: value.reasonCode === null ? null : code(value.reasonCode) };
  });
  if (new Set(accounts.map(account => account.id)).size !== accounts.length) return fail();
  return accounts;
}

export function proxyAccountPolicy(preferences: ProxyPreferences, accountId: string): ProxyAccountPolicy {
  return preferences.accountPolicies[accountId] ?? { fiveHourUsedLimit: 100, sevenDayUsedLimit: 100, allowsCredits: true, creditPrimaryFloor: null, creditSecondaryFloor: null };
}
export function remainingQuotaPercent(usedLimit: number): number {
  return Number((100 - usedLimit).toFixed(10));
}
export function usedQuotaLimit(remainingPercent: number): number {
  if (!Number.isFinite(remainingPercent) || remainingPercent < 0 || remainingPercent > 100) return fail();
  return Number((100 - remainingPercent).toFixed(10));
}
export function sharedQuotaReserve(preferences: ProxyPreferences, accounts: ProxyAccount[]): { count: number; remaining: number | null; mixed: boolean } {
  const limits = accounts.flatMap(account => {
    const policy = proxyAccountPolicy(preferences, account.id);
    if (account.planType === 'plus') return [policy.fiveHourUsedLimit];
    if (account.planType === 'pro' || account.planType === 'prolite') return [policy.sevenDayUsedLimit];
    return [];
  });
  const mixed = limits.some(limit => limit !== limits[0]);
  return { count: limits.length, remaining: !limits.length || mixed ? null : remainingQuotaPercent(limits[0]), mixed };
}

// Membership never changes display order. Last-use overrides also let Pro opt out.
export function proxyParticipation(preferences: ProxyPreferences, accountId: string, field: 'enabled' | 'priority' | 'last', enabled: boolean): ProxyPreferences {
  id(accountId);
  const set = (values: string[], on: boolean) => on ? [...new Set([...values, accountId])] : values.filter(value => value !== accountId);
  if (field === 'enabled') return { ...preferences, enabledIds: set(preferences.enabledIds, enabled) };
  if (field === 'priority') return { ...preferences, priorityIds: set(preferences.priorityIds, enabled), ...(enabled ? { lastIds: set(preferences.lastIds, false), lastOverrides: { ...preferences.lastOverrides, [accountId]: false } } : {}) };
  return { ...preferences, lastIds: set(preferences.lastIds, enabled), lastOverrides: { ...preferences.lastOverrides, [accountId]: enabled }, ...(enabled ? { priorityIds: set(preferences.priorityIds, false) } : {}) };
}

export function proxyDisplayOrder<T extends { id: string }>(accounts: T[], preferences: ProxyPreferences): T[] {
  const byId = new Map(accounts.map(account => [account.id, account]));
  return [...preferences.order.flatMap(accountId => { const account = byId.get(accountId); byId.delete(accountId); return account ? [account] : []; }), ...byId.values()];
}

export function proxyConnectionText(raw: unknown): string {
  const value = object(raw);
  if (typeof value.endpoint !== 'string' || !/^http:\/\/127\.0\.0\.1:\d+\/v1$/.test(value.endpoint) || typeof value.clientKey !== 'string' || !/^[a-zA-Z0-9_-]{20,256}$/.test(value.clientKey)) return fail();
  const port = Number(value.endpoint.match(/:(\d+)\/v1$/)?.[1]);
  if (port < 1 || port > 65535) return fail();
  return `OPENAI_BASE_URL=${value.endpoint}\nOPENAI_API_KEY=${value.clientKey}`;
}
