export const PERSONAL_TEXT_FOOTER = '\n\naigoodbro.com';
export const personalTextBytes = (text: string) => new TextEncoder().encode(text + PERSONAL_TEXT_FOOTER).length;
export const validPersonalText = (text: string) => text.trim().length > 0 && !/[\x00-\x08\x0b\x0c\x0e-\x1f]/.test(text) && personalTextBytes(text) <= 4096;
export interface PersonalTextReceipt { requestId: string; revision: number; state: 'accepted' | 'rejected' | 'uncertain' | 'not_sent'; checkedAt: number; failureCode: string | null }
export function parsePersonalTextReceipt(raw: unknown, requestId: string, revision: number): PersonalTextReceipt {
  const fail = (): never => { throw Error('notification_invalid_response'); };
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return fail();
  const value = raw as Record<string, unknown>;
  if (Object.keys(value).some(key => !['requestId', 'revision', 'state', 'checkedAt', 'failureCode'].includes(key))
    || typeof value.requestId !== 'string' || !/^[a-f0-9]{32}$/.test(value.requestId) || value.requestId !== requestId
    || value.revision !== revision || !Number.isSafeInteger(value.revision) || revision < 0
    || !['accepted', 'rejected', 'uncertain', 'not_sent'].includes(String(value.state))
    || !Number.isSafeInteger(value.checkedAt) || Number(value.checkedAt) <= 0
    || value.failureCode !== null && (typeof value.failureCode !== 'string' || !/^[a-z_]{1,64}$/.test(value.failureCode))
    || value.state === 'accepted' && value.failureCode !== null) return fail();
  return value as unknown as PersonalTextReceipt;
}
