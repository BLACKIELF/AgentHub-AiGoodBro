export const APPEARANCE_KEY = 'aigoodbro.appearance.v1';
export const APPEARANCE_EVENT = 'aigoodbro:appearance-changed';
export interface AppearancePreference {
  version: 1;
  revision: number;
  systemGlass: boolean;
  opacity: number;
  depth: number;
  ringMotion: 'default' | 'powerSaving';
}
export type AppearancePatch = Partial<Pick<AppearancePreference, 'systemGlass' | 'opacity' | 'depth' | 'ringMotion'>>;
export const defaultAppearance = (): AppearancePreference => ({version: 1, revision: 0, systemGlass: true, opacity: 68, depth: 32, ringMotion: 'default'});
export function parseAppearance(value: unknown): AppearancePreference {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw Error('appearance_invalid');
  const v = value as Record<string, unknown>;
  if (Object.keys(v).sort().join('|') !== 'depth|opacity|revision|ringMotion|systemGlass|version'
    || v.version !== 1 || !Number.isSafeInteger(v.revision) || Number(v.revision) < 0
    || typeof v.systemGlass !== 'boolean' || !['default', 'powerSaving'].includes(String(v.ringMotion))
    || ![v.opacity, v.depth].every(n => typeof n === 'number' && Number.isInteger(n) && n >= 0 && n <= 100)) throw Error('appearance_invalid');
  return {...v} as unknown as AppearancePreference;
}
export function readAppearance(): AppearancePreference {
  try {
    const raw = localStorage.getItem(APPEARANCE_KEY);
    if (raw === null) return defaultAppearance();
    if (raw.length > 1024) throw Error();
    return parseAppearance(JSON.parse(raw));
  } catch { throw Error('appearance_unavailable'); }
}
export async function saveAppearance(patch: AppearancePatch): Promise<AppearancePreference> {
  if (!navigator.locks?.request) throw Error('appearance_save_unavailable');
  return navigator.locks.request(APPEARANCE_KEY, () => {
    if (Object.keys(patch).some(k => !['systemGlass', 'opacity', 'depth', 'ringMotion'].includes(k))) throw Error('appearance_invalid');
    const previous = readAppearance();
    const next = parseAppearance({...previous, ...patch, revision: previous.revision + 1});
    const encoded = JSON.stringify(next);
    localStorage.setItem(APPEARANCE_KEY, encoded);
    if (localStorage.getItem(APPEARANCE_KEY) !== encoded) throw Error('appearance_save_unavailable');
    window.dispatchEvent(new Event(APPEARANCE_EVENT));
    return next;
  });
}
