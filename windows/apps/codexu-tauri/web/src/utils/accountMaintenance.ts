export interface MaintenancePreferences { fiveHourWarmup: boolean; sevenDayWarmup: boolean; resetLeadMinutes: number; resetAuthorizations: Array<{ profileId: string; authorized: boolean; identityCurrent: boolean }> }
export interface MaintenanceStatus { phase: 'disabled' | 'idle' | 'running' | 'blocked'; issueCode: string | null; runningProfileId: string | null; nativeImplementationAvailable: boolean; entries: Array<{ profileId: string; kind: 'warmup' | 'reset_credit'; phase: 'running' | 'succeeded' | 'deferred' | 'uncertain' | 'blocked' | 'cancelled'; issueCode: string | null; lastAttemptAtMs: number | null; lastSucceededAtMs: number | null; nextEligibleAtMs: number | null }> }
const bad = (): never => { throw Error('maintenance_invalid_response'); };
function obj(raw: unknown, keys: string[]) { if (!raw || typeof raw !== 'object' || Array.isArray(raw) || Object.keys(raw).some(key => !keys.includes(key))) bad(); return raw as Record<string, unknown>; }
const bool = (value: unknown) => typeof value === 'boolean' ? value : bad();
const id = (value: unknown) => typeof value === 'string' && /^[A-Za-z0-9._:-]{1,256}$/.test(value) ? value : bad();
const code = (value: unknown) => value === null || typeof value === 'string' && /^[a-z0-9_]{1,80}$/.test(value) ? value : bad();
const time = (value: unknown) => value === null || Number.isSafeInteger(value) && (value as number) >= 0 ? value : bad();
const rows = (value: unknown) => Array.isArray(value) && value.length <= 512 ? value : bad();
export function parseMaintenancePreferences(raw: unknown): MaintenancePreferences {
  const v = obj(raw, ['fiveHourWarmup', 'sevenDayWarmup', 'resetLeadMinutes', 'resetAuthorizations']); bool(v.fiveHourWarmup); bool(v.sevenDayWarmup);
  if (!Number.isInteger(v.resetLeadMinutes) || (v.resetLeadMinutes as number) < 1 || (v.resetLeadMinutes as number) > 1440) bad();
  const seen = new Set<string>(); for (const raw of rows(v.resetAuthorizations)) { const a = obj(raw, ['profileId', 'authorized', 'identityCurrent']); const key = id(a.profileId); if (seen.has(key)) bad(); seen.add(key); bool(a.authorized); bool(a.identityCurrent); }
  return v as unknown as MaintenancePreferences;
}
export function parseMaintenanceStatus(raw: unknown): MaintenanceStatus {
  const v = obj(raw, ['phase', 'issueCode', 'runningProfileId', 'entries', 'nativeImplementationAvailable']);
  if (!['disabled', 'idle', 'running', 'blocked'].includes(v.phase as string)) bad(); code(v.issueCode); if (v.runningProfileId !== null) id(v.runningProfileId); bool(v.nativeImplementationAvailable);
  for (const raw of rows(v.entries)) { const e = obj(raw, ['profileId', 'kind', 'phase', 'issueCode', 'lastAttemptAtMs', 'lastSucceededAtMs', 'nextEligibleAtMs']); id(e.profileId); if (!['warmup', 'reset_credit'].includes(e.kind as string) || !['running', 'succeeded', 'deferred', 'uncertain', 'blocked', 'cancelled'].includes(e.phase as string)) bad(); code(e.issueCode); time(e.lastAttemptAtMs); time(e.lastSucceededAtMs); time(e.nextEligibleAtMs); }
  return v as unknown as MaintenanceStatus;
}
