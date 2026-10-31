export type HubTask = { id: string; version: number; agent: string; project: string; accountAlias?: string; state: string; actionHash?: string; canResume: boolean; reasonCode?: string; resultNote?: string; createdAt: string; updatedAt: string; approvalExpiresAt: string; approvalExpired: boolean };
export type HubView = { supported: boolean; connected: boolean; workspace: string | null; profileId: string | null; overview: { tasks: HubTask[]; accounts: string[]; projects: string[]; agents: string[] } | null };
export type HubAction = { kind: 'create'; request_id: string; prompt: string } | { kind: 'approve'; request_id: string; task_id: string; action_hash: string } | { kind: 'cancel'; request_id: string; task_id: string; expected_version: number } | { kind: 'resume'; request_id: string; task_id: string; prompt: string } | { kind: 'resolve'; request_id: string; task_id: string; expected_version: number; confirmed_stopped: true };
const states = ['awaiting_approval','starting','running','cancel_requested','succeeded','failed','cancelled','uncertain','blocked_configuration'];
export function parseHubView(raw: unknown): HubView {
  if (!raw || typeof raw !== 'object') throw Error('hub_invalid_response');
  const value = raw as HubView;
  if (typeof value.supported !== 'boolean' || typeof value.connected !== 'boolean' || (value.workspace !== null && (typeof value.workspace !== 'string' || value.workspace.length > 512)) || (value.profileId !== null && typeof value.profileId !== 'string') || value.connected !== (value.overview !== null)) throw Error('hub_invalid_response');
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
