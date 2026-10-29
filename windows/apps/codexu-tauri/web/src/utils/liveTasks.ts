export const LIVE_TASK_MAX_AGE_MS = 45_000; // automatic_switch::policy::TASK_MAX_AGE_MS
export const liveTaskStates = ['idle', 'running', 'waiting_input', 'recorded', 'disconnected', 'failed', 'completed', 'interrupted'] as const;
export type LiveTaskStatus = typeof liveTaskStates[number];
export interface LiveTask { ordinal: number; state: LiveTaskStatus; turnState: LiveTaskStatus | null; startedAtMs: number | null; completedAtMs: number | null }
export interface LiveTaskState { phase: 'live' | 'unavailable'; issueCode: string | null; observedAtMs: number | null; tasks: LiveTask[] }
const invalid = (): never => { throw Error('official_tasks_invalid_response'); };
const object = (raw: unknown): Record<string, unknown> => raw && typeof raw === 'object' && !Array.isArray(raw) ? raw as Record<string, unknown> : invalid();
const fields = (row: Record<string, unknown>, allowed: string[]) => { if (Object.keys(row).some(key => !allowed.includes(key))) invalid(); };
const time = (raw: unknown): number | null => raw === null ? null : Number.isSafeInteger(raw) && Number(raw) >= 0 && Number(raw) <= 8.64e15 ? Number(raw) : invalid();
const state = (raw: unknown): LiveTaskStatus => liveTaskStates.includes(raw as LiveTaskStatus) ? raw as LiveTaskStatus : invalid();
export const unavailableLiveTasks = (issueCode = 'official_tasks_unavailable'): LiveTaskState => ({ phase: 'unavailable', issueCode, observedAtMs: null, tasks: [] });
export function parseLiveTasks(raw: unknown): LiveTaskState {
  const row = object(raw); fields(row, ['phase', 'issueCode', 'observedAtMs', 'tasks']);
  if (!['live', 'unavailable'].includes(String(row.phase)) || row.issueCode !== null && (typeof row.issueCode !== 'string' || !/^[a-z_]{1,80}$/.test(row.issueCode)) || !Array.isArray(row.tasks) || row.tasks.length > 4096) invalid();
  const observedAtMs = time(row.observedAtMs), seen = new Set<number>();
  const tasks = (row.tasks as unknown[]).map(raw => {
    const value = object(raw); fields(value, ['ordinal', 'state', 'turnState', 'startedAtMs', 'completedAtMs']);
    if (!Number.isSafeInteger(value.ordinal) || Number(value.ordinal) < 1 || Number(value.ordinal) > 4096 || seen.has(Number(value.ordinal))) invalid();
    seen.add(Number(value.ordinal));
    return { ordinal: Number(value.ordinal), state: state(value.state), turnState: value.turnState === null ? null : state(value.turnState), startedAtMs: time(value.startedAtMs), completedAtMs: time(value.completedAtMs) };
  });
  if (row.phase === 'unavailable' && (tasks.length || observedAtMs !== null) || row.phase === 'live' && (observedAtMs === null || row.issueCode !== null)) invalid();
  return { phase: row.phase as LiveTaskState['phase'], issueCode: row.issueCode as string | null, observedAtMs, tasks };
}
export function currentLiveTasks(value: LiveTaskState, now = Date.now()): LiveTaskState {
  return value.phase === 'live' && (value.observedAtMs === null || value.observedAtMs > now || now - value.observedAtMs > LIVE_TASK_MAX_AGE_MS) ? unavailableLiveTasks('official_tasks_timed_out') : value;
}
