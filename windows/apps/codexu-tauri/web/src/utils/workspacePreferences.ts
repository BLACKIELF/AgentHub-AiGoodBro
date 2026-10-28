export type WorkspacePage = 'home' | 'accounts' | 'usage' | 'proxy' | 'tools';
export type WorkspaceMode = 'professional' | 'simple';
export type AccountCardSize = 'small' | 'medium' | 'large';

export function readChoice<T extends string>(key: string, choices: readonly T[], fallback: T): T {
  try {
    const saved = localStorage.getItem(key);
    return choices.includes(saved as T) ? saved as T : fallback;
  } catch { return fallback; }
}

export function saveChoice(key: string, value: string): void {
  try { localStorage.setItem(key, value); } catch { /* The choice still applies to this session. */ }
}
