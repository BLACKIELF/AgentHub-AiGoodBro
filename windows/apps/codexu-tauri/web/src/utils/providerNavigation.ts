// Navigation preferences only. This store cannot mutate accounts or runtimes.
export const PROVIDER_NAVIGATION_KEY = 'AiGoodBro.providerNavigation.v1';
export const PROVIDER_NAVIGATION_EVENT = 'aigoodbro:provider-navigation';
export interface NavigationStorage { getItem(key: string): string | null; setItem(key: string, value: string): void }
export interface NavigationSnapshot { raw: string | null; ids: string[]; invalid: boolean }
const validID = (id: unknown): id is string => typeof id === 'string' && /^[a-z][a-z0-9_-]{0,47}$/.test(id) && !['all', 'home', 'add', 'manage', 'more'].includes(id);
export function navigationIDs(raw: unknown): string[] {
  if (!Array.isArray(raw) || raw.length > 32 || !raw.every(validID) || new Set(raw).size !== raw.length) throw Error('navigation_invalid');
  return [...raw];
}
export function defaultNavigation(ids: string[]): string[] { return navigationIDs([...new Set(ids)]); }
export function readNavigation(storage: NavigationStorage, defaults: string[]): NavigationSnapshot {
  const raw = storage.getItem(PROVIDER_NAVIGATION_KEY);
  if (raw === null) return { raw, ids: defaultNavigation(defaults), invalid: false };
  try {
    if (raw.length > 8192) throw Error('navigation_invalid');
    const value = JSON.parse(raw);
    if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).sort().join(',') !== 'ids,schema' || value.schema !== 1) throw Error('navigation_invalid');
    return { raw, ids: navigationIDs(value.ids), invalid: false };
  } catch { return { raw, ids: defaultNavigation(defaults), invalid: true }; }
}
/** Compare with the current stored result before saving or undoing; never
 * silently replace an intervening edit. No cross-process atomicity is claimed. */
export function saveNavigation(storage: NavigationStorage, expected: NavigationSnapshot, ids: string[]): NavigationSnapshot {
  if (storage.getItem(PROVIDER_NAVIGATION_KEY) !== expected.raw) throw Error('navigation_changed');
  const next = { schema: 1, ids: navigationIDs(ids) }, raw = JSON.stringify(next);
  if (expected.invalid && expected.raw !== null) storage.setItem(`${PROVIDER_NAVIGATION_KEY}.backup`, expected.raw);
  storage.setItem(PROVIDER_NAVIGATION_KEY, raw);
  if (storage.getItem(PROVIDER_NAVIGATION_KEY) !== raw) throw Error('navigation_save_failed');
  return { raw, ids: next.ids, invalid: false };
}
export function moveNavigation(ids: string[], id: string, destination: number): string[] {
  navigationIDs(ids);
  const from = ids.indexOf(id);
  if (from < 0 || !Number.isInteger(destination) || destination < 0 || destination >= ids.length) throw Error('navigation_invalid_move');
  const next = [...ids]; next.splice(from, 1); next.splice(destination, 0, id); return next;
}
