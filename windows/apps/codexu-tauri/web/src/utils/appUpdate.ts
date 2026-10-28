export const APP_UPDATE_PHASES = ['idle', 'checking', 'available', 'up_to_date', 'downloading', 'verifying', 'downloaded', 'cancelled', 'failed', 'opening', 'installer_opened'] as const;
export type AppUpdatePhase = typeof APP_UPDATE_PHASES[number];
export interface AppUpdateInfo {
  current_version: string;
  available_version?: string;
  release_notes: string;
  published_at?: string;
  can_download: boolean;
  asset_name?: string;
  asset_size?: number;
  reason_code?: string;
}
export interface AppUpdateState { phase: AppUpdatePhase; info?: AppUpdateInfo; error_code?: string }
export type AppUpdateCommand = 'check_app_update' | 'download_app_update' | 'cancel_app_update' | 'open_app_update';
const code = (value: unknown): value is string => typeof value === 'string' && /^[a-zA-Z0-9_-]{1,80}$/.test(value);
const version = (value: unknown): value is string => typeof value === 'string' && /^\d+\.\d+\.\d+(?:[-+][a-zA-Z0-9.-]+)?$/.test(value) && value.length <= 80;

/** Only structured release state enters the view; raw transport errors stay out. */
export function parseAppUpdateState(raw: unknown): AppUpdateState {
  if (!raw || typeof raw !== 'object') throw Error('invalid_update_state');
  const value = raw as Record<string, unknown>;
  if (!APP_UPDATE_PHASES.includes(value.phase as AppUpdatePhase) || (value.error_code !== undefined && value.error_code !== null && !code(value.error_code))) throw Error('invalid_update_state');
  let info: AppUpdateInfo | undefined;
  if (value.info !== undefined && value.info !== null) {
    if (typeof value.info !== 'object') throw Error('invalid_update_info');
    const source = value.info as Record<string, unknown>;
    if (!version(source.current_version) || typeof source.release_notes !== 'string' || source.release_notes.length > 524288 || typeof source.can_download !== 'boolean'
      || (source.available_version !== undefined && source.available_version !== null && !version(source.available_version))
      || (source.published_at !== undefined && source.published_at !== null && (typeof source.published_at !== 'string' || !Number.isFinite(Date.parse(source.published_at))))
      || (source.asset_name !== undefined && source.asset_name !== null && (typeof source.asset_name !== 'string' || !/^[a-zA-Z0-9_.-]{1,192}\.(msi|exe)$/i.test(source.asset_name)))
      || (source.asset_size !== undefined && source.asset_size !== null && (!Number.isSafeInteger(source.asset_size) || (source.asset_size as number) <= 0))
      || (source.reason_code !== undefined && source.reason_code !== null && !code(source.reason_code))) throw Error('invalid_update_info');
    info = {
      current_version: source.current_version, release_notes: source.release_notes, can_download: source.can_download,
      ...(typeof source.available_version === 'string' ? { available_version: source.available_version } : {}),
      ...(typeof source.published_at === 'string' ? { published_at: source.published_at } : {}),
      ...(typeof source.asset_name === 'string' ? { asset_name: source.asset_name } : {}),
      ...(typeof source.asset_size === 'number' ? { asset_size: source.asset_size } : {}),
      ...(typeof source.reason_code === 'string' ? { reason_code: source.reason_code } : {}),
    };
  }
  if (value.phase === 'up_to_date' && !info) throw Error('unverified_update_result');
  return { phase: value.phase as AppUpdatePhase, ...(info ? { info } : {}), ...(typeof value.error_code === 'string' ? { error_code: value.error_code } : {}) };
}
