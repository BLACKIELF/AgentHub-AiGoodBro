export type WorkflowPreference = { participating: boolean; model: string | null; effort: string | null; revision: number };
export type WorkflowPhase = 'idle' | 'checking' | 'running' | 'exited' | 'stopped' | 'failed';
export type AccountWorkflowState = { profile_id: string; preference: WorkflowPreference; phase: WorkflowPhase; started_at: number | null; supported: boolean };
export type WorkflowModel = { id: string; label: string; efforts: string[]; default_effort: string; is_default: boolean };

const efforts = ['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'];
const validModel = (value: unknown): value is string => typeof value === 'string' && /^[A-Za-z0-9_.-]{1,80}$/.test(value);
const validEffort = (value: unknown): value is string => typeof value === 'string' && efforts.includes(value);
export function parseWorkflowState(raw: unknown, id: string): AccountWorkflowState {
  if (!raw || typeof raw !== 'object') throw new Error('Invalid workflow');
  const value = raw as AccountWorkflowState, p = value.preference;
  if (value.profile_id !== id || typeof value.supported !== 'boolean' || !['idle', 'checking', 'running', 'exited', 'stopped', 'failed'].includes(value.phase)
    || !p || typeof p.participating !== 'boolean' || !Number.isSafeInteger(p.revision) || p.revision < 0
    || !(p.model === null || validModel(p.model)) || !(p.effort === null || validEffort(p.effort)) || (p.model === null && p.effort !== null)
    || !(value.started_at === null || Number.isSafeInteger(value.started_at))) throw new Error('Invalid workflow');
  return value;
}

export function parseWorkflowModels(raw: unknown): WorkflowModel[] {
  if (!Array.isArray(raw) || raw.length < 1 || raw.length > 100) throw new Error('Models unavailable');
  const seen = new Set<string>();
  for (const row of raw) {
    if (!row || typeof row !== 'object' || !validModel(row.id) || seen.has(row.id)
      || typeof row.label !== 'string' || row.label.length < 1 || row.label.length > 80 || /[@/\\:\x00-\x1f]/.test(row.label)
      || typeof row.is_default !== 'boolean' || !Array.isArray(row.efforts) || row.efforts.length < 1 || row.efforts.length > 8
      || !row.efforts.every(validEffort) || new Set(row.efforts).size !== row.efforts.length || !row.efforts.includes(row.default_effort)) throw new Error('Models unavailable');
    seen.add(row.id);
  }
  return raw;
}

export function acceptWorkflowState(previous: AccountWorkflowState | null, incoming: AccountWorkflowState): AccountWorkflowState {
  // A status reply started before opt-out must not put the toggle back on.
  return previous && previous.profile_id === incoming.profile_id && previous.preference.revision > incoming.preference.revision
    ? { ...incoming, preference: previous.preference } : incoming;
}

export function workflowError(code: unknown, chinese: boolean): string {
  const errors: Record<string, [string, string]> = {
    cli_unavailable: ['未找到原生 Codex CLI，请先安装官方 Windows CLI。', 'Native Codex CLI not found. Install the official Windows CLI first.'],
    source_changed: ['账号目录或登录已改变，请重新读取后再试。', 'The directory or login changed. Read it again before retrying.'],
    login_unavailable: ['此目录没有可读取的登录，请先按添加账号指引完成登录。', 'No readable login in this directory. Complete the account guide first.'],
    launch_disabled: ['已关闭参与调度，本次未启动终端。', 'Participation is off. No terminal was started.'],
    selection_changed: ['启动期间设置已改变，请按新设置重新打开。', 'Settings changed during startup. Open again with the new settings.'],
    selection_unavailable: ['所选模型或思考强度当前不可用，请重新读取模型。', 'The selected model or effort is unavailable. Read available models again.'],
    quota_or_identity_unavailable: ['暂不能启动：需确认 ChatGPT 登录、未过期的可用额度，以及明确为零且非无限的信用余额。请刷新账号信息后重试。', 'Cannot start: verify ChatGPT login, current available quota, and an explicitly zero, non-unlimited credit balance. Refresh account information and retry.'],
    already_running: ['这个账号已有本应用打开的终端。', 'This account already has a terminal opened by this app.'],
    stop_failed: ['未能确认终端结束，请重试或在该终端中退出。', 'Could not confirm the terminal closed. Retry or quit in that terminal.'],
    settings_unavailable: ['调度设置读取失败，原文件已保留。', 'Workflow settings could not be read. Existing data was retained.'],
    save_failed: ['保存失败，开关保持原状态。请重试。', 'Save failed. The previous setting was retained. Retry.'],
    workspace_unavailable: ['工作目录不可用，请重新选择。', 'Workspace unavailable. Choose it again.'],
    launch_cancelled: ['已取消启动。', 'Startup cancelled.'],
    read_busy: ['已有两项账号读取正在进行，完成后重试。', 'Two account reads are already running. Retry when they finish.'],
    exit_blocked: ['请先结束由 AiGoodBro 打开的终端，再退出应用。', 'Close terminals opened by AiGoodBro before quitting the app.'],
  };
  return errors[typeof code === 'string' ? code : '']?.[chinese ? 0 : 1]
    ?? (chinese ? '操作未完成，请重新读取后重试。' : 'Operation did not complete. Read the current state and retry.');
}
