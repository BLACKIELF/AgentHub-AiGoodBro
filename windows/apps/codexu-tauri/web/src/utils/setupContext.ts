export interface SetupContext { version: string; eventId: string | null; status: 'pending' | 'completed' | 'deferred' | 'unavailable'; audience: 'new' | 'returning' | null; shouldPresent: boolean; failureCode: string | null }
export function parseSetupContext(raw: unknown): SetupContext {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw Error('setup_invalid_response');
  const v = raw as Record<string, unknown>;
  if (Object.keys(v).some(key => !['version', 'eventId', 'status', 'audience', 'shouldPresent', 'failureCode'].includes(key)) || typeof v.version !== 'string' || !/^[0-9A-Za-z.+-]{1,80}$/.test(v.version) || !['pending', 'completed', 'deferred', 'unavailable'].includes(String(v.status)) || ![null, 'new', 'returning'].includes(v.audience as null | string) || typeof v.shouldPresent !== 'boolean' || v.failureCode !== null && (typeof v.failureCode !== 'string' || !/^[a-z0-9_]{1,80}$/.test(v.failureCode))) throw Error('setup_invalid_response');
  if (v.status === 'unavailable' ? v.eventId !== null || v.shouldPresent : typeof v.eventId !== 'string' || !/^files:v1:[a-z0-9:]{1,183}$/.test(v.eventId) || v.shouldPresent !== (v.status === 'pending')) throw Error('setup_invalid_response');
  if (v.status === 'completed' && v.audience === null) throw Error('setup_invalid_response');
  return v as unknown as SetupContext;
}
