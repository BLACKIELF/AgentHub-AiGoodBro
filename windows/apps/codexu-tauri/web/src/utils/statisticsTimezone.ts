export const STATISTICS_TIMEZONE_KEY = 'aigoodbro.statistics.timezone.v1';
export interface StatisticsTimezonePreference { selection: 'system' | 'utc' | 'fixed'; fixedIdentifier: string }
export const defaultStatisticsTimezone = (): StatisticsTimezonePreference => ({ selection: 'system', fixedIdentifier: 'UTC' });
function validateIdentifier(value: unknown): string {
  if (typeof value !== 'string' || !value || value.length > 64 || !/^[A-Za-z0-9_+./-]+$/.test(value)) throw Error('invalid_statistics_timezone');
  try { new Intl.DateTimeFormat('en', { timeZone: value }); } catch { throw Error('invalid_statistics_timezone'); }
  return value;
}
export function parseStatisticsTimezone(raw: unknown): StatisticsTimezonePreference {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw Error('invalid_statistics_timezone');
  const value = raw as Record<string, unknown>;
  if (Object.keys(value).some(key => !['selection', 'fixedIdentifier'].includes(key)) || !['system', 'utc', 'fixed'].includes(String(value.selection))) throw Error('invalid_statistics_timezone');
  return { selection: value.selection as StatisticsTimezonePreference['selection'], fixedIdentifier: validateIdentifier(value.fixedIdentifier) };
}
export function readStatisticsTimezone(): StatisticsTimezonePreference {
  try {
    const raw = localStorage.getItem(STATISTICS_TIMEZONE_KEY);
    if (raw === null) return defaultStatisticsTimezone();
    if (raw.length > 256) throw Error();
    return parseStatisticsTimezone(JSON.parse(raw));
  } catch { throw Error('statistics_timezone_preferences_unavailable'); }
}
export function resolveStatisticsTimezone(preference: StatisticsTimezonePreference): string {
  const valid = parseStatisticsTimezone(preference);
  if (valid.selection === 'utc') return 'UTC';
  if (valid.selection === 'fixed') return valid.fixedIdentifier;
  const system = Intl.DateTimeFormat().resolvedOptions().timeZone;
  if (!system) throw Error('statistics_timezone_required');
  return validateIdentifier(system);
}
export function saveStatisticsTimezone(preference: StatisticsTimezonePreference): void {
  const value = parseStatisticsTimezone(preference);
  try { localStorage.setItem(STATISTICS_TIMEZONE_KEY, JSON.stringify(value)); }
  catch { throw Error('statistics_timezone_save_failed'); }
}
