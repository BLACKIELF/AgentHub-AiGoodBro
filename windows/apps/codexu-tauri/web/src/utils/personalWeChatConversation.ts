export interface PersonalConversationBinding {
  expectedScopeId: string;
  threadId: string;
}

export interface PersonalConversationState {
  binding: PersonalConversationBinding | null;
  revision: number;
  enabled: boolean;
  phase: 'channel_unavailable' | 'unbound' | 'needs_confirmation' | 'enabled' | 'disabled';
  needsConfirmation: boolean;
}

const fail = (): never => { throw Error('notification_invalid_response'); };

export function parsePersonalConversationState(raw: unknown): PersonalConversationState {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return fail();
  const value = raw as Record<string, unknown>;
  if (Object.keys(value).sort().join('|') !== ['binding', 'revision', 'enabled', 'phase', 'needsConfirmation'].sort().join('|')
    || !Number.isSafeInteger(value.revision) || Number(value.revision) < 0
    || typeof value.enabled !== 'boolean' || typeof value.needsConfirmation !== 'boolean'
    || !['channel_unavailable', 'unbound', 'needs_confirmation', 'enabled', 'disabled'].includes(String(value.phase))) return fail();

  let binding: PersonalConversationBinding | null = null;
  if (value.binding !== null) {
    if (!value.binding || typeof value.binding !== 'object' || Array.isArray(value.binding)) return fail();
    const rawBinding = value.binding as Record<string, unknown>;
    if (Object.keys(rawBinding).sort().join('|') !== ['expectedScopeId', 'threadId'].sort().join('|')
      || typeof rawBinding.expectedScopeId !== 'string' || !/^[a-f0-9]{64}$/.test(rawBinding.expectedScopeId)
      || typeof rawBinding.threadId !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(rawBinding.threadId)) return fail();
    binding = { expectedScopeId: rawBinding.expectedScopeId, threadId: rawBinding.threadId };
  }
  if (value.enabled !== (value.phase === 'enabled')
    || value.phase === 'enabled' && (!binding || value.needsConfirmation)
    || value.phase === 'unbound' && (binding !== null || value.needsConfirmation)
    || value.phase === 'disabled' && (!binding || value.needsConfirmation)
    || value.phase === 'needs_confirmation' && (!binding || !value.needsConfirmation)) return fail();
  return { binding, revision: Number(value.revision), enabled: value.enabled, phase: value.phase as PersonalConversationState['phase'], needsConfirmation: value.needsConfirmation };
}
