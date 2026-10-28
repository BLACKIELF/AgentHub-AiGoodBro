export interface ClaudeLoginAttempt { attempt_id: string; phase: 'starting' | 'waiting' | 'verified' | 'failed' | 'cancelling' | 'cancelled' | 'saved'; error_code: string | null }
export interface ClaudeQuota {
  state: 'available' | 'unavailable' | 'needs_login' | 'unsupported' | 'rate_limited';
  fetched_at: number;
  masked_identity: string | null;
  identity_fingerprint: string | null;
  plan_label: string | null;
  windows: { id: string; label: string; used_percent: number; resets_at: number | null }[];
  balance: null; balance_currency: null; source_label: string; message_code: string | null; period_resets_at: null; server_retry_at: number | null;
}
export interface ClaudePreparedSwitch { account_id: string; phase: 'ready' | 'already_current'; ticket: string | null; reason_code: string | null; expires_at: number | null }
const fail = (): never => { throw new Error('invalid_response'); };
const object = (raw: unknown): Record<string, unknown> => raw && typeof raw === 'object' && !Array.isArray(raw) ? raw as Record<string, unknown> : fail();
const string = (raw: unknown, max: number): string => typeof raw === 'string' && raw.length > 0 && raw.length <= max && !/[\x00-\x1f\x7f]/.test(raw) ? raw : fail();
const id = (raw: unknown): string => typeof raw === 'string' && /^[a-zA-Z0-9_-]{1,128}$/.test(raw) ? raw : fail();
const code = (raw: unknown): string | null => raw === null ? null : typeof raw === 'string' && /^[a-z_]{1,80}$/.test(raw) ? raw : fail();
const time = (raw: unknown): number => typeof raw === 'number' && Number.isFinite(raw) && !Number.isNaN(new Date(raw).valueOf()) ? raw : fail();

export function parseClaudeLogin(raw: unknown, expectedAttempt?: string): ClaudeLoginAttempt {
  const value = object(raw), attemptId = id(value.attempt_id);
  if (expectedAttempt && attemptId !== expectedAttempt || !['starting', 'waiting', 'verified', 'failed', 'cancelling', 'cancelled', 'saved'].includes(value.phase as string)) return fail();
  const errorCode = code(value.error_code);
  if (['verified', 'saved'].includes(value.phase as string) && errorCode) return fail();
  return { attempt_id: attemptId, phase: value.phase as ClaudeLoginAttempt['phase'], error_code: errorCode };
}

export function parseClaudeQuota(raw: unknown): ClaudeQuota {
  const value = object(raw);
  if (!['available', 'unavailable', 'needs_login', 'unsupported', 'rate_limited'].includes(value.state as string) || value.balance !== null || value.balance_currency !== null || value.period_resets_at !== null || value.source_label !== 'Anthropic OAuth usage' || !Array.isArray(value.windows) || value.windows.length > 256) return fail();
  const windows = value.windows.map(rawWindow => {
    const window = object(rawWindow);
    if (typeof window.used_percent !== 'number' || !Number.isFinite(window.used_percent) || window.used_percent < 0 || window.used_percent > 100) return fail();
    return { id: string(window.id, 128), label: string(window.label, 128), used_percent: window.used_percent, resets_at: window.resets_at === null ? null : time(window.resets_at) };
  });
  if (value.state === 'available' && value.message_code !== null) return fail();
  if (new Set(windows.map(window => window.id)).size !== windows.length) return fail();
  const fingerprint = value.identity_fingerprint === null ? null : string(value.identity_fingerprint, 128);
  const identity = value.masked_identity === null ? null : string(value.masked_identity, 254);
  if (identity !== null && (!identity.includes('*') || /[\s\\/]/.test(identity))) return fail();
  const retry = value.server_retry_at === null ? null : time(value.server_retry_at);
  if (retry !== null && (!Number.isSafeInteger(retry) || retry <= 0)) return fail();
  return { state: value.state as ClaudeQuota['state'], fetched_at: time(value.fetched_at), masked_identity: identity, identity_fingerprint: fingerprint, plan_label: value.plan_label === null ? null : string(value.plan_label, 64), windows, balance: null, balance_currency: null, source_label: 'Anthropic OAuth usage', message_code: code(value.message_code), period_resets_at: null, server_retry_at: retry };
}

export function parseClaudePreparedSwitch(raw: unknown, expectedAccount: string): ClaudePreparedSwitch {
  const value = object(raw);
  if (id(value.account_id) !== expectedAccount || !['ready', 'already_current'].includes(value.phase as string)) return fail();
  const ticket = value.ticket === null ? null : id(value.ticket);
  const expiresAt = value.expires_at === null ? null : time(value.expires_at);
  const reason = code(value.reason_code);
  if (value.phase === 'ready' && (!ticket || expiresAt === null || !Number.isSafeInteger(expiresAt) || expiresAt <= 0 || reason !== null) || value.phase === 'already_current' && (ticket !== null || expiresAt !== null || reason !== 'already_current')) return fail();
  return { account_id: expectedAccount, phase: value.phase as ClaudePreparedSwitch['phase'], ticket, reason_code: reason, expires_at: expiresAt };
}
export const isClaudeLoginPending = (attempt: ClaudeLoginAttempt | null) => !!attempt && ['starting', 'waiting', 'cancelling'].includes(attempt.phase);
