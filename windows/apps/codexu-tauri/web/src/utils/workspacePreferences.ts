export type WorkspacePage = 'home' | 'accounts' | 'usage' | 'proxy' | 'tools';
export type WorkspaceMode = 'professional' | 'simple';
export type AccountCardSize = 'small' | 'medium' | 'large';
export interface WorkspaceNavigation { page: WorkspacePage; toolTab?: 'tasks' }

export function parseWorkspaceNavigation(raw: unknown): WorkspaceNavigation | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const value = raw as Record<string, unknown>;
  if (Object.keys(value).some(key => key !== 'page' && key !== 'toolTab')
    || typeof value.page !== 'string' || !['home', 'accounts', 'usage', 'proxy', 'tools'].includes(value.page)
    || (value.toolTab !== undefined && (value.page !== 'tools' || value.toolTab !== 'tasks'))) return null;
  return { page: value.page as WorkspacePage, ...(value.toolTab === 'tasks' ? { toolTab: 'tasks' as const } : {}) };
}

export function readChoice<T extends string>(key: string, choices: readonly T[], fallback: T): T {
  try {
    const saved = localStorage.getItem(key);
    return choices.includes(saved as T) ? saved as T : fallback;
  } catch { return fallback; }
}

export function saveChoice(key: string, value: string): void {
  try { localStorage.setItem(key, value); } catch { /* The choice still applies to this session. */ }
}
