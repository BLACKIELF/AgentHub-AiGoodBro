export type BrowserMode = 'systemDefault' | 'dedicatedChrome' | 'existingChrome';
export type BrowserSettings = { profileId: string; mode: BrowserMode; profileDirectory: string | null; chromeAvailable: boolean; profileScanIssue?: 'browser_profiles_unavailable' | null; profiles: { directoryName: string; displayName: string }[] };
export function parseBrowserSettings(raw: unknown, profileId: string): BrowserSettings {
  const fail = (): never => { throw Error('browser_invalid_response'); };
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return fail();
  const value = raw as BrowserSettings;
  const directory = (v: unknown) => typeof v === 'string' && /^(Default|Profile [0-9]{1,10})$/.test(v);
  if ((value.profileScanIssue != null && value.profileScanIssue !== 'browser_profiles_unavailable') || value.profileId !== profileId || !['systemDefault', 'dedicatedChrome', 'existingChrome'].includes(value.mode) || typeof value.chromeAvailable !== 'boolean' || !Array.isArray(value.profiles) || value.profiles.length > 256 || (value.mode === 'existingChrome' ? !directory(value.profileDirectory) : value.profileDirectory !== null)) return fail();
  for (const row of value.profiles) if (!row || !directory(row.directoryName) || typeof row.displayName !== 'string' || !row.displayName || [...row.displayName].length > 60 || /[@/\\\x00-\x1f\x7f]/.test(row.displayName)) return fail();
  if (new Set(value.profiles.map(row => row.directoryName)).size !== value.profiles.length) return fail();
  return value;
}
