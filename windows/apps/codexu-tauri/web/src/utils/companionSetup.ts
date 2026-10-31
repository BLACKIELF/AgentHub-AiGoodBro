export type CompanionSetupState = 'missing' | 'outdated' | 'conflict' | 'ready' | 'unavailable';
export type CompanionFileState = 'missing' | 'same' | 'changed';
export interface CompanionSetupSnapshot {
  state: CompanionSetupState;
  issueCode: string | null;
  files: {path: string; status: CompanionFileState}[];
  planId: string | null;
  backupAvailable: boolean;
}

// Relative names from the fixed native bundle and its two runtime bindings.
// This is a display boundary, never a caller-selected installation destination.
const FILES = new Set([
  'SKILL.md', '使用说明.md', 'bin/next-dispatch.py',
  'references/coordination.md', 'references/dispatch-brief.md',
  'references/cli-validation.md', 'references/grok-cli.md',
  'references/jev-coordination.md', 'references/update-0927v1.md',
  'references/local-runtime.md', 'references/runtime-setup.md',
  'references/luna-presets.md', 'references/onboarding-login.md',
  'scripts/next_dispatch_activity.py', 'scripts/next_dispatch_preflight.py',
  'scripts/next_dispatch_invocation.py',
  'config/runtime-paths.json', 'config/runtime-python.txt',
]);
const invalid = (): never => { throw Error('companion_response_invalid'); };
function object(raw: unknown): Record<string, unknown> {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) invalid();
  return raw as Record<string, unknown>;
}
function keys(raw: Record<string, unknown>, expected: string[]) {
  if (Object.keys(raw).sort().join('|') !== expected.sort().join('|')) invalid();
}

export function parseCompanionSetup(raw: unknown): CompanionSetupSnapshot {
  const value = object(raw);
  keys(value, ['state', 'issueCode', 'files', 'planId', 'backupAvailable']);
  if (!['missing', 'outdated', 'conflict', 'ready', 'unavailable'].includes(String(value.state))
      || typeof value.backupAvailable !== 'boolean'
      || value.issueCode !== null && (typeof value.issueCode !== 'string'
        || !/^companion_[a-z_]{1,80}$/.test(value.issueCode))
      || value.planId !== null && (typeof value.planId !== 'string' || !/^[a-f0-9]{64}$/.test(value.planId))
      || !Array.isArray(value.files) || value.files.length > FILES.size) invalid();
  const seen = new Set<string>();
  const files = (value.files as unknown[]).map(raw => {
    const file = object(raw);
    keys(file, ['path', 'status']);
    if (typeof file.path !== 'string' || !FILES.has(file.path) || seen.has(file.path)
        || !['missing', 'same', 'changed'].includes(String(file.status))) invalid();
    seen.add(file.path as string);
    return {path: file.path as string, status: file.status as CompanionFileState};
  });
  const {state, issueCode, planId} = value;
  if (state === 'ready' && (issueCode !== null || planId !== null || !files.length || files.some(f => f.status !== 'same'))
      || ['missing', 'outdated'].includes(String(state)) && (issueCode !== null || !files.some(f => f.status !== 'same'))
      || ['conflict', 'unavailable'].includes(String(state)) && issueCode === null
      || state === 'conflict' && planId !== null
      || state === 'unavailable' && planId !== null && (issueCode !== 'companion_confirmation_required'
        || !files.length || files.some(f => f.status !== 'same'))) invalid();
  return {state: state as CompanionSetupState, issueCode: issueCode as string | null,
    files, planId: planId as string | null, backupAvailable: value.backupAvailable as boolean};
}
