/** Local-only account action DTOs. Credentials never cross this boundary. */
export type ResetReview = { reviewId: string; profileId: string; checkedAtMs: number; expiresAtMs: number; availableCount: number; cardExpiresAtMs: number | null; remaining5hPercent?: number | null; remaining7dPercent?: number | null };
export type ResetOutcome = 'reset' | 'nothingToReset' | 'noCredit' | 'alreadyRedeemed' | 'unknown';
export type ReferralReview = { reviewId: string; profileId: string; checkedAtMs: number; expiresAtMs: number; shouldShow: boolean; title: string | null; description: string | null; rules: string[]; creditAmount: number | null; invitationCapacity: number; remainingSendCapacity: number | null; remainingRewardCapacity: number | null; requiresExplicitConfirmation: boolean };
export type ReferralBatch = { profileId: string; sent: number[]; failed: number[]; uncertain: number[] };
export type ReferralPeriod = 'this_month' | 'past_90_days';
export type ReferralRecord = { id: string; maskedEmail: string | null; status: 'pending' | 'redeemed' | 'expired' | 'unknown' };
export type ReferralPage = { profileId: string; items: ReferralRecord[]; cursor: string | null };
const fail = (): never => { throw Error('invalid_response'); };
const obj = (raw: unknown): Record<string, unknown> => raw && typeof raw === 'object' && !Array.isArray(raw) ? raw as Record<string, unknown> : fail();
const str = (raw: unknown, max = 2048): string => typeof raw === 'string' && raw.length <= max && !/[\x00-\x1f\x7f]/.test(raw) ? raw : fail();
const id = (raw: unknown) => { const v = str(raw, 128); return /^[a-zA-Z0-9_-]+$/.test(v) ? v : fail(); };
const integer = (raw: unknown, max = 1e9): number => Number.isSafeInteger(raw) && Number(raw) >= 0 && Number(raw) <= max ? Number(raw) : fail();
const time = (raw: unknown) => integer(raw, 8640000000000000);
const optionalCount = (raw: unknown) => raw === null ? null : integer(raw);
const bool = (raw: unknown): boolean => typeof raw === 'boolean' ? raw : fail();
const nullableText = (raw: unknown) => raw === null ? null : str(raw);
function bound(raw: unknown, profileId: string) { const v = obj(raw); if (v.profileId !== profileId) fail(); return v; }
function review(raw: unknown, profileId: string) { const v = bound(raw, profileId); const checkedAtMs = time(v.checkedAtMs), expiresAtMs = time(v.expiresAtMs); if (expiresAtMs <= checkedAtMs) fail(); return { v, reviewId: id(v.reviewId), profileId, checkedAtMs, expiresAtMs }; }
export function parseResetReview(raw: unknown, profileId: string): ResetReview {
  const { v, ...base } = review(raw, profileId);
  const percent = (raw: unknown) => raw == null ? null : typeof raw === 'number' && Number.isFinite(raw) && raw >= 0 && raw <= 100 ? raw : fail();
  return { ...base, availableCount: integer(v.availableCount), cardExpiresAtMs: v.cardExpiresAtMs === null ? null : time(v.cardExpiresAtMs), remaining5hPercent: percent(v.remaining5hPercent), remaining7dPercent: percent(v.remaining7dPercent) };
}
export function parseResetResult(raw: unknown, profileId: string): ResetOutcome {
  const v = bound(raw, profileId); return ['reset', 'nothingToReset', 'noCredit', 'alreadyRedeemed', 'unknown'].includes(String(v.outcome)) ? v.outcome as ResetOutcome : fail();
}
export function parseResetReceipt(raw: unknown, profileId: string): { outcome: ResetOutcome; issueCode: 'notification_receipt_save_failed' | null } {
  const outcome = parseResetResult(raw, profileId), v = bound(raw, profileId);
  if (v.issueCode != null && (v.issueCode !== 'notification_receipt_save_failed' || outcome !== 'reset')) fail();
  return { outcome, issueCode: v.issueCode == null ? null : 'notification_receipt_save_failed' };
}
export function parseReferralReview(raw: unknown, profileId: string): ReferralReview {
  const { v, ...base } = review(raw, profileId);
  if (!Array.isArray(v.rules) || v.rules.length > 30) fail();
  return { ...base, shouldShow: bool(v.shouldShow), title: nullableText(v.title), description: nullableText(v.description), rules: (v.rules as unknown[]).map(x => str(x)), creditAmount: v.creditAmount === null ? null : typeof v.creditAmount === 'number' && Number.isFinite(v.creditAmount) && v.creditAmount >= 0 ? v.creditAmount : fail(), invitationCapacity: integer(v.invitationCapacity, 5), remainingSendCapacity: optionalCount(v.remainingSendCapacity), remainingRewardCapacity: optionalCount(v.remainingRewardCapacity), requiresExplicitConfirmation: bool(v.requiresExplicitConfirmation) };
}
export function parseReferralBatch(raw: unknown, profileId: string, recipientCount: number): ReferralBatch {
  const v = bound(raw, profileId);
  const indices = (raw: unknown) => Array.isArray(raw) ? raw.map(x => integer(x, recipientCount - 1)) : fail();
  const sent = indices(v.sent), failed = indices(v.failed), uncertain = indices(v.uncertain), all = [...sent, ...failed, ...uncertain];
  if (recipientCount < 1 || recipientCount > 5 || all.length !== recipientCount || new Set(all).size !== recipientCount) fail();
  return { profileId, sent, failed, uncertain };
}
export function parseReferralPage(raw: unknown, profileId: string): ReferralPage {
  const v = bound(raw, profileId); if (!Array.isArray(v.items) || v.items.length > 100) fail();
  const items = (v.items as unknown[]).map(raw => { const x = obj(raw), recordId = str(x.id, 512); if (!recordId || !['pending', 'redeemed', 'expired', 'unknown'].includes(String(x.status))) fail(); return { id: recordId, maskedEmail: nullableText(x.maskedEmail), status: x.status as ReferralRecord['status'] }; });
  if (new Set(items.map(x => x.id)).size !== items.length) fail();
  const cursor = nullableText(v.cursor); return { profileId, items, cursor: cursor || null };
}
export function parseLocalEmail(raw: unknown, profileId: string): string | null {
  const v = bound(raw, profileId); if (v.email === null) return null;
  const email = str(v.email, 320); if (!email.trim()) fail(); return email;
}
export function validRecipient(value: string): boolean { return new TextEncoder().encode(value).length <= 254 && /^[^\s@,;<>]+@[^\s@,;<>]+\.[^\s@,;<>]+$/.test(value) && !/[\x00-\x1f\x7f]/.test(value); }
export function parseRecipients(input: string) {
  if (new TextEncoder().encode(input).length > 4096) return { emails: [], invalid: 0, duplicates: 0, tooLong: true };
  const emails: string[] = [], seen = new Set<string>(); let invalid = 0, duplicates = 0;
  for (const value of input.split(/[\s,;，；]+/).filter(Boolean)) { if (!validRecipient(value)) { invalid++; continue; } const key = value.toLowerCase(); if (seen.has(key)) { duplicates++; continue; } seen.add(key); emails.push(value); }
  return { emails, invalid, duplicates, tooLong: false };
}
export type LocalAccountDetails = {
  profileId: string; email: string | null; displayName: string | null; username: string | null; maskedAccountId: string | null;
  proTierMultiplier: 5 | 10 | 20 | 25 | null; displayedProTierMultiplier: 5 | 10 | 20 | 25 | null;
  accountType: string | null; planType: string | null; subscriptionActiveUntilMs: number | null; lifetimeTokens: number | null; peakDailyTokens: number | null;
  statsAsOfMs: number | null; profileFetchedAtMs: number | null; addedAtMs: number | null; model: string | null; effort: string | null; participating: boolean | null; chromeProfileName: string | null;
  availableResetCards: number | null; resetCardExpiresAtMs: number[]; quotaCheckedAtMs: number | null; quotaFresh: boolean;
  quotaWindows: { kind: 'five_hour' | 'seven_day' | 'monthly'; usedPercent: number | null; resetsAtMs: number | null }[];
  warmupHistory: { atMs: number; succeeded: boolean | null; failureCode: string | null; phase: string | null }[];
};
export function parseLocalDetails(raw: unknown, profileId: string): LocalAccountDetails {
  const v = bound(raw, profileId), text = (key: string) => v[key] == null ? null : str(v[key]), timestamp = (key: string) => v[key] == null ? null : time(v[key]), count = (key: string) => v[key] == null ? null : integer(v[key], Number.MAX_SAFE_INTEGER);
  const multiplier = (key: string): 5 | 10 | 20 | 25 | null => v[key] == null ? null : [5, 10, 20, 25].includes(Number(v[key])) && typeof v[key] === 'number' ? v[key] as 5 | 10 | 20 | 25 : fail();
  const expiry = v.resetCardExpiresAtMs ?? [], windows = v.quotaWindows ?? [], history = v.warmupHistory ?? [];
  if (!Array.isArray(expiry) || expiry.length > 1024 || !Array.isArray(windows) || windows.length > 3 || !Array.isArray(history) || history.length > 1000) fail();
  const quotaWindows = (windows as unknown[]).map(raw => { const w = obj(raw); if (!['five_hour', 'seven_day', 'monthly'].includes(String(w.kind)) || !(w.usedPercent === null || typeof w.usedPercent === 'number' && Number.isFinite(w.usedPercent) && w.usedPercent >= 0 && w.usedPercent <= 100)) fail(); return { kind: w.kind as LocalAccountDetails['quotaWindows'][number]['kind'], usedPercent: w.usedPercent as number | null, resetsAtMs: w.resetsAtMs === null ? null : time(w.resetsAtMs) }; });
  if (new Set(quotaWindows.map(w => w.kind)).size !== quotaWindows.length) fail();
  const warmupHistory = (history as unknown[]).map(raw => { const h = obj(raw); return { atMs: time(h.atMs), succeeded: h.succeeded === null ? null : bool(h.succeeded), failureCode: h.failureCode == null ? null : str(h.failureCode, 80), phase: h.phase == null ? null : str(h.phase, 80) }; });
  return { profileId, proTierMultiplier: multiplier('proTierMultiplier'), displayedProTierMultiplier: multiplier('displayedProTierMultiplier'), email: parseLocalEmail(v, profileId), displayName: text('displayName'), username: text('username'), maskedAccountId: text('maskedAccountId'), accountType: text('accountType'), planType: text('planType'), subscriptionActiveUntilMs: timestamp('subscriptionActiveUntilMs'), lifetimeTokens: count('lifetimeTokens'), peakDailyTokens: count('peakDailyTokens'), statsAsOfMs: timestamp('statsAsOfMs'), profileFetchedAtMs: timestamp('profileFetchedAtMs'), addedAtMs: timestamp('addedAtMs'), model: text('model'), effort: text('effort'), participating: v.participating == null ? null : bool(v.participating), chromeProfileName: text('chromeProfileName'), availableResetCards: count('availableResetCards'), resetCardExpiresAtMs: (expiry as unknown[]).map(time), quotaCheckedAtMs: timestamp('quotaCheckedAtMs'), quotaFresh: v.quotaFresh === undefined ? false : bool(v.quotaFresh), quotaWindows, warmupHistory };
}

export function warmupFailureText(code: string | null, chinese: boolean): string {
  const values: Record<string, [string, string]> = {
    maintenance_unsupported: ['此环境暂不支持暖号', 'Warm-up is unavailable in this environment'],
    maintenance_invalid_settings: ['暖号设置无效', 'Warm-up settings are invalid'],
    maintenance_save_failed: ['暖号记录保存失败', 'The warm-up record could not be saved'],
    maintenance_busy: ['账号正在执行其他操作', 'Another account operation is in progress'],
    maintenance_quota_unknown: ['需要刷新官方额度', 'Refresh provider allowance'],
    maintenance_unauthorized: ['缺少暖号授权', 'Warm-up authorization is missing'],
    maintenance_identity_changed: ['账号登录身份已变化', 'The signed-in account identity changed'],
    maintenance_cancelled: ['暖号已取消', 'Warm-up was cancelled'],
    maintenance_protocol_unknown: ['官方响应暂无法识别', 'The provider response was not recognized'],
    maintenance_outcome_unknown: ['暖号结果尚未返回', 'The warm-up result is pending'],
    maintenance_recovery_required: ['需先处理账号恢复状态', 'Resolve the account recovery state first'],
  };
  return values[code ?? '']?.[chinese ? 0 : 1] ?? (chinese ? '失败原因未提供' : 'Failure reason unavailable');
}
