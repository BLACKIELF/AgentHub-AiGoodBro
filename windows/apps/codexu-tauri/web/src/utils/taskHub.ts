export type HubTask = { id: string; version: number; agent: string; project: string; accountAlias?: string; state: string; actionHash?: string; canResume: boolean; reasonCode?: string; resultNote?: string; createdAt: string; updatedAt: string; approvalExpiresAt: string; approvalExpired: boolean };
export type HubSessionView = { sessionId: string; profileId: string; dispatchCode: string; workspace: string | null };
export type HubView = { supported: boolean; connected: boolean; sessionId: string | null; workspace: string | null; selectedWorkspace: string | null; profileId: string | null; dispatchCode: string | null; sessions: HubSessionView[]; overview: { tasks: HubTask[]; accounts: string[]; projects: string[]; agents: string[] } | null };
export type HubAction = { kind: 'create'; request_id: string; prompt: string } | { kind: 'approve'; request_id: string; task_id: string; action_hash: string } | { kind: 'cancel'; request_id: string; task_id: string; expected_version: number } | { kind: 'resume'; request_id: string; task_id: string; prompt: string } | { kind: 'resolve'; request_id: string; task_id: string; expected_version: number; confirmed_stopped: true };
const states = ['awaiting_approval','starting','running','cancel_requested','succeeded','failed','cancelled','uncertain','blocked_configuration'];
export function parseHubView(raw: unknown): HubView {
  if (!raw || typeof raw !== 'object') throw Error('hub_invalid_response');
  const value = raw as HubView;
  const opaque = (id: unknown): id is string => typeof id === 'string' && /^[a-f0-9]{64}$/.test(id);
  const label = (value: unknown) => value === null || typeof value === 'string' && value.length <= 512;
  if (typeof value.supported !== 'boolean' || typeof value.connected !== 'boolean'
    || !label(value.workspace) || !label(value.selectedWorkspace)
    || !(value.profileId === null || typeof value.profileId === 'string' && /^[1-9][0-9]{0,19}$/.test(value.profileId))
    || !(value.dispatchCode === null || typeof value.dispatchCode === 'string' && /^[A-Z]$/.test(value.dispatchCode))
    || !(value.sessionId === null || opaque(value.sessionId))
    || value.connected !== (value.overview !== null) || value.connected !== (value.sessionId !== null)
    || value.connected !== (value.profileId !== null) || value.connected !== (value.dispatchCode !== null)
    || !Array.isArray(value.sessions) || value.sessions.length > 26) throw Error('hub_invalid_response');
  const sessionIds = new Set<string>();
  for (const session of value.sessions) {
    if (!session || !opaque(session.sessionId) || sessionIds.has(session.sessionId)
      || typeof session.profileId !== 'string' || !/^[1-9][0-9]{0,19}$/.test(session.profileId)
      || typeof session.dispatchCode !== 'string' || !/^[A-Z]$/.test(session.dispatchCode)
      || !label(session.workspace)) throw Error('hub_invalid_response');
    sessionIds.add(session.sessionId);
  }
  if (value.connected && !sessionIds.has(value.sessionId!)) throw Error('hub_invalid_response');
  if (value.overview) {
    if (!Array.isArray(value.overview.tasks) || value.overview.tasks.length > 10000 || !['accounts','projects','agents'].every(k => Array.isArray(value.overview![k as 'agents']) && value.overview![k as 'agents'].every(v => typeof v === 'string' && v.length < 128))) throw Error('hub_invalid_response');
    const ids = new Set();
    for (const t of value.overview.tasks) {
      if (!t || typeof t.id !== 'string' || !/^[\w.-]{1,128}$/.test(t.id) || ids.has(t.id) || !Number.isSafeInteger(t.version) || t.version <= 0 || !states.includes(t.state) || typeof t.canResume !== 'boolean' || typeof t.approvalExpired !== 'boolean' || typeof t.agent !== 'string' || typeof t.project !== 'string' || !['createdAt','updatedAt','approvalExpiresAt'].every(k => typeof t[k as 'createdAt'] === 'string' && Number.isFinite(Date.parse(t[k as 'createdAt'])))) throw Error('hub_invalid_response');
      if (t.actionHash != null && (typeof t.actionHash !== 'string' || !/^[a-f0-9]{64}$/.test(t.actionHash))) throw Error('hub_invalid_response');
      ids.add(t.id);
    }
  }
  return value;
}
export const hubTerminal = (state: string) => ['succeeded','failed','cancelled','blocked_configuration'].includes(state);
