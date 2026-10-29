export interface ManagedAccount {
  id: string;
  label: string;
  platform: string;
  storage_kind: 'managed';
  login_state: 'signed_out' | 'signing_in' | 'verified' | 'needs_reauth';
  active_state: 'unknown' | 'verified' | 'stale';
  masked_identity: string | null;
  plan_type: string | null;
  can_login: boolean;
  can_switch: boolean;
  switch_block_reason: string | null;
  revision: number;
  recovery_required: boolean;
}
export type LoginPhase = 'starting' | 'waiting' | 'verifying' | 'cancelling' | 'verified' | 'cancelled' | 'failed';
export interface LoginAttempt {
  attempt_id: string;
  account_id: string;
  phase: LoginPhase;
  verification_url: string | null;
  user_code: string | null;
  error_code: string | null;
}
export interface PreparedAccountSwitch {
  account_id: string;
  ticket: string | null;
  phase: 'ready' | 'blocked';
  reason_code: string | null;
  expires_at: number | null;
}
export interface AccountOperation { account_id: string; phase: 'committed' | 'cancelled' | 'verified' | 'renamed' | 'removed'; error_code: string | null }
export const OFFICIAL_CODEX_DEVICE_URL = 'https://auth.openai.com/codex/device';
const fail = (): never => { throw new Error('invalid_response'); };
const object = (raw: unknown): Record<string, unknown> => raw && typeof raw === 'object' && !Array.isArray(raw) ? raw as Record<string, unknown> : fail();
const string = (raw: unknown, max: number): string => typeof raw === 'string' && raw.length <= max && !/[\r\n\0]/.test(raw) ? raw : fail();
const id = (raw: unknown): string => typeof raw === 'string' && /^[a-zA-Z0-9_-]{1,128}$/.test(raw) ? raw : fail();
const boolean = (raw: unknown): boolean => typeof raw === 'boolean' ? raw : fail();
const code = (raw: unknown): string | null => raw === null ? null : typeof raw === 'string' && /^[a-z_]{1,80}$/.test(raw) ? raw : fail();
const choice = <T extends string>(raw: unknown, values: readonly T[]): T => values.includes(raw as T) ? raw as T : fail();

export function parseManagedAccount(raw: unknown): ManagedAccount {
  const value = object(raw);
  if (value.storage_kind !== 'managed' || !Number.isSafeInteger(value.revision) || Number(value.revision) < 0) return fail();
  const identity = value.masked_identity === null ? null : string(value.masked_identity, 200);
  if (identity !== null && (!identity.includes('*') || /[\s\\/]/.test(identity))) return fail();
  return { id: id(value.id), label: string(value.label, 200), platform: id(value.platform), storage_kind: 'managed', login_state: choice(value.login_state, ['signed_out', 'signing_in', 'verified', 'needs_reauth']), active_state: choice(value.active_state, ['unknown', 'verified', 'stale']), masked_identity: identity, plan_type: value.plan_type === null || value.plan_type === undefined ? null : string(value.plan_type, 64), can_login: boolean(value.can_login), can_switch: boolean(value.can_switch), switch_block_reason: code(value.switch_block_reason), revision: Number(value.revision), recovery_required: boolean(value.recovery_required) };
}

export function parseManagedAccounts(raw: unknown): ManagedAccount[] {
  if (!Array.isArray(raw) || raw.length > 64) return fail();
  const accounts = raw.map(parseManagedAccount);
  return new Set(accounts.map(account => account.id)).size === accounts.length ? accounts : fail();
}

export function parseLoginAttempt(raw: unknown, expectedAccount?: string, expectedAttempt?: string): LoginAttempt {
  const value = object(raw);
  const phase = choice<LoginPhase>(value.phase, ['starting', 'waiting', 'verifying', 'cancelling', 'verified', 'cancelled', 'failed']);
  const accountId = id(value.account_id), attemptId = id(value.attempt_id);
  if (expectedAccount && accountId !== expectedAccount || expectedAttempt && attemptId !== expectedAttempt) return fail();
  if (value.verification_url !== null && value.verification_url !== OFFICIAL_CODEX_DEVICE_URL) return fail();
  const userCode = value.user_code === null ? null : string(value.user_code, 52);
  if (userCode !== null && !/^[A-Z0-9]{2,12}(?:-[A-Z0-9]{2,12}){1,3}$/.test(userCode)) return fail();
  if (phase !== 'waiting' && (value.verification_url !== null || userCode !== null)) return fail();
  const errorCode = code(value.error_code);
  if (phase === 'verified' && errorCode !== null) return fail();
  return { attempt_id: attemptId, account_id: accountId, phase, verification_url: value.verification_url as string | null, user_code: userCode, error_code: errorCode };
}

export function parsePreparedSwitch(raw: unknown, expectedAccount: string): PreparedAccountSwitch {
  const value = object(raw);
  const accountId = id(value.account_id);
  if (accountId !== expectedAccount) return fail();
  const phase = choice(value.phase, ['ready', 'blocked']);
  const expiresAt = value.expires_at === null ? null : Number(value.expires_at);
  const ticket = value.ticket === null ? null : id(value.ticket);
  if (phase === 'ready' && (!ticket || expiresAt === null || !Number.isSafeInteger(expiresAt) || expiresAt <= 0 || value.reason_code !== null) || phase === 'blocked' && (ticket !== null || expiresAt !== null)) return fail();
  return { account_id: accountId, ticket, phase, reason_code: code(value.reason_code), expires_at: expiresAt };
}

export function parseAccountOperation(raw: unknown, expectedAccount: string, expectedPhase: AccountOperation['phase']): AccountOperation {
  const value = object(raw);
  if (id(value.account_id) !== expectedAccount || value.phase !== expectedPhase) return fail();
  const errorCode = code(value.error_code);
  if (errorCode) throw new Error(errorCode);
  return { account_id: expectedAccount, phase: expectedPhase, error_code: null };
}

export const isLoginPending = (attempt: LoginAttempt | null): boolean => !!attempt && ['starting', 'waiting', 'verifying', 'cancelling'].includes(attempt.phase);
