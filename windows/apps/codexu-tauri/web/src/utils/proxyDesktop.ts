export interface ProxyDesktopStatus {
  phase: 'stopped' | 'prepared' | 'launched' | 'stopping' | 'failed';
  launchId: string | null;
  accountId: string | null;
  issue: string | null;
  routingVerified: boolean | null;
}

export function parseProxyDesktopStatus(raw: unknown): ProxyDesktopStatus {
  const fail = (): never => { throw new Error('invalid_response'); };
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return fail();
  const value = raw as Record<string, unknown>;
  if (!['stopped', 'prepared', 'launched', 'stopping', 'failed'].includes(value.phase as string)) return fail();
  const id = (input: unknown) => input === null ? null : typeof input === 'string' && /^[a-zA-Z0-9_-]{1,128}$/.test(input) ? input : fail();
  const launchId = id(value.launchId), accountId = id(value.accountId);
  if (['prepared', 'launched', 'stopping'].includes(value.phase as string) && (!launchId || !accountId)) return fail();
  if (value.routingVerified !== null && typeof value.routingVerified !== 'boolean') return fail();
  if (value.routingVerified === true && (value.phase !== 'launched' || value.issue !== null)) return fail();
  const issue = value.issue === null ? null : typeof value.issue === 'string' && /^[a-z_]{1,80}$/.test(value.issue) ? value.issue : fail();
  return { phase: value.phase as ProxyDesktopStatus['phase'], launchId, accountId, issue, routingVerified: value.routingVerified as boolean | null };
}
