// Contract helpers for non-Codex accounts.
//
// The rule these helpers enforce: a platform that does not expose a balance is
// shown as unknown or unsupported. It is never rendered as 0%, 100% or "signed in".
// Unknown message codes are never echoed to the interface.

export type LocalQuotaState = 'available' | 'unavailable' | 'needs_login' | 'unsupported' | 'rate_limited';
export type IsolationMode = 'managed' | 'default_only' | 'unsupported';

export type LocalQuotaWindow = {
  id: string;
  label: string;
  used_percent: number;
  remaining_percent: number;
  resets_at: number | null;
};

export type LocalQuota = {
  profile_id: string;
  platform: string;
  platform_name: string;
  state: LocalQuotaState;
  checked_at: number;
  masked_identity: string | null;
  plan_label: string | null;
  windows: LocalQuotaWindow[];
  balance: number | null;
  balance_currency: string | null;
  source_label: string;
  message_code: string | null;
  period_resets_at: number | null;
};

export type Platform = {
  id: string;
  name: string;
  command: string;
  default_directory: string | null;
  isolation: IsolationMode;
  quota_supported: boolean;
  desktop: boolean;
};

const states: LocalQuotaState[] = ['available', 'unavailable', 'needs_login', 'unsupported', 'rate_limited'];
const isolations: IsolationMode[] = ['managed', 'default_only', 'unsupported'];
const platforms = ['codex', 'claude_code', 'grok', 'open_code', 'trae', 'work_buddy', 'kimi', 'mimo', 'zcode', 'gemini', 'antigravity'];

const isText = (value: unknown, max: number): value is string =>
  typeof value === 'string' && value.length > 0 && value.length <= max && !/[\x00-\x1f]/.test(value);
const isTime = (value: unknown): value is number =>
  typeof value === 'number' && Number.isFinite(value) && !Number.isNaN(new Date(value).valueOf());
const isMoney = (value: unknown): value is number | null =>
  value === null || (typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1e9);
/** A masked identity may only contain a masked local part and a domain. */
const isMaskedIdentity = (value: unknown): value is string | null =>
  value === null || (isText(value, 254) && !/[\s\\/]/.test(value) && (value.includes('***') || value.includes('*')));

function validWindow(value: unknown): value is LocalQuotaWindow {
  if (!value || typeof value !== 'object') return false;
  const window = value as Record<string, unknown>;
  return isText(window.id, 128) && isText(window.label, 128)
    && typeof window.used_percent === 'number' && Number.isFinite(window.used_percent)
    && window.used_percent >= 0 && window.used_percent <= 100
    && typeof window.remaining_percent === 'number' && Number.isFinite(window.remaining_percent)
    && Math.abs(window.remaining_percent + window.used_percent - 100) < 0.001
    && (window.resets_at === null || isTime(window.resets_at));
}

export function parsePlatforms(value: unknown): Platform[] {
  if (!Array.isArray(value) || value.length === 0 || value.length > 32) throw new Error('Invalid platform list');
  const seen = new Set<string>();
  return value.map(entry => {
    if (!entry || typeof entry !== 'object') throw new Error('Invalid platform entry');
    const row = entry as Record<string, unknown>;
    if (typeof row.id !== 'string' || !platforms.includes(row.id) || seen.has(row.id)) throw new Error('Invalid platform id');
    if (!isText(row.name, 64) || !isText(row.command, 64)) throw new Error('Invalid platform name');
    if (row.default_directory !== null && !isText(row.default_directory, 512)) throw new Error('Invalid default directory');
    if (typeof row.isolation !== 'string' || !isolations.includes(row.isolation as IsolationMode)) throw new Error('Invalid isolation mode');
    if (typeof row.quota_supported !== 'boolean' || typeof row.desktop !== 'boolean') throw new Error('Invalid platform flags');
    seen.add(row.id);
    return row as unknown as Platform;
  });
}

export function parseLocalQuota(value: unknown, profileId: string): LocalQuota {
  if (!value || typeof value !== 'object') throw new Error('Invalid local quota result');
  const row = value as Record<string, unknown>;
  if (row.profile_id !== profileId) throw new Error('Local quota result belongs to another account');
  if (typeof row.platform !== 'string' || !platforms.includes(row.platform) || row.platform === 'codex') throw new Error('Invalid platform');
  if (typeof row.state !== 'string' || !states.includes(row.state as LocalQuotaState)) throw new Error('Invalid state');
  if (!isTime(row.checked_at)) throw new Error('Invalid timestamp');
  if (!isMaskedIdentity(row.masked_identity)) throw new Error('Invalid identity');
  if (row.plan_label !== null && !isText(row.plan_label, 64)) throw new Error('Invalid plan label');
  if (!isText(row.platform_name, 64) || !isText(row.source_label, 128)) throw new Error('Invalid labels');
  if (row.message_code !== null && !isText(row.message_code, 64)) throw new Error('Invalid message code');
  if (!isMoney(row.balance)) throw new Error('Invalid balance');
  // A currency is a short alphabetic code; symbols or trailing text are rejected.
  if (row.balance_currency !== null && (typeof row.balance_currency !== 'string' || !/^[A-Za-z]{1,8}$/.test(row.balance_currency))) throw new Error('Invalid currency');
  if (row.period_resets_at !== null && !isTime(row.period_resets_at)) throw new Error('Invalid period reset');
  if (!Array.isArray(row.windows) || row.windows.length > 256) throw new Error('Invalid windows');
  if (!row.windows.every(validWindow)) throw new Error('Invalid quota window');
  if (new Set(row.windows.map(window => window.id)).size !== row.windows.length) throw new Error('Duplicate quota window');
  return row as unknown as LocalQuota;
}

/** How long a read may be presented as the current quota before it is history. */
export const LOCAL_QUOTA_FRESHNESS_MS = 300_000;

/**
 * Whether a reading may still be shown as the current quota.
 *
 * A reading stops being live when the platform did not report `available`, when
 * it is older than the freshness bound, when its timestamp is in the future (a
 * clock change makes the age meaningless), or when every window it carries has
 * already passed its reset moment — after that the percentages describe a period
 * that has ended. A window with no known reset never expires the reading.
 */
export function isLocalQuotaLive(quota: LocalQuota, now: number): boolean {
  if (quota.state !== 'available') return false;
  if (!Number.isFinite(now) || now < quota.checked_at) return false;
  if (now - quota.checked_at >= LOCAL_QUOTA_FRESHNESS_MS) return false;
  const dated = quota.windows.filter(window => window.resets_at !== null);
  if (dated.length > 0 && dated.every(window => (window.resets_at as number) <= now)) return false;
  return true;
}

/**
 * Why a reading that the platform did report is no longer the current quota.
 *
 * Only `available` needs the explanation: every other state already carries its
 * own wording, so `null` is returned and nothing extra is rendered.
 */
export function localQuotaExpiryNotice(state: LocalQuotaState, language: string): string | null {
  if (state !== 'available') return null;
  return language === 'zh-Hans'
    ? '该读数已过期，仅作历史参考，请重新读取。'
    : 'This reading has expired. It is history only; read again.';
}

export function localQuotaStateLabel(state: LocalQuotaState, language: string): string {
  const zh = language === 'zh-Hans';
  switch (state) {
    case 'available': return zh ? '已读取' : 'Read';
    case 'unavailable': return zh ? '暂不可用' : 'Unavailable';
    case 'needs_login': return zh ? '需要登录' : 'Sign-in required';
    case 'unsupported': return zh ? '平台未提供额度' : 'Platform does not expose quota';
    case 'rate_limited': return zh ? '已限流' : 'Rate limited';
    default: return zh ? '未知' : 'Unknown';
  }
}

const messages: Record<string, [string, string]> = {
  local_cli_directory_not_recognized: ['关联目录已不可识别，请重新关联。', 'The linked directory is no longer recognisable. Link it again.'],
  local_cli_codex_uses_official_reader: ['Codex 使用官方额度读取入口。', 'Codex uses the official quota reader.'],
  local_cli_sign_in_evidence_missing: ['未在本目录发现登录配置，请先在该目录登录。', 'No sign-in configuration was found in this directory. Sign in there first.'],
  local_cli_quota_not_exposed_by_platform: ['该平台未在本地提供额度，显示为未知。', 'This platform does not expose its quota locally; it stays unknown.'],
  local_cli_antigravity_live_unavailable: ['无法只读查询正在运行的 Antigravity，显示为未知。', 'The running Antigravity could not be queried read-only; it stays unknown.'],
  local_cli_antigravity_account_changed: ['读取期间 Antigravity 账号发生变化，结果已丢弃。', 'The Antigravity account changed during the read, so the result was discarded.'],
  local_cli_antigravity_no_quota: ['Antigravity 未返回额度窗口。', 'Antigravity returned no quota window.'],
  local_cli_antigravity_open_app: ['请先打开并登录官方 Antigravity 桌面端。', 'Open and sign in to the official Antigravity desktop app first.'],
  local_cli_antigravity_linked_cache_only: ['关联目录只能读取历史缓存，不代表当前额度。', 'A linked directory only offers history; it is not the current quota.'],
  local_cli_antigravity_cache_unavailable: ['Antigravity 历史缓存不可用。', 'The Antigravity history cache is unavailable.'],
  local_cli_antigravity_cached_quota: ['以下为历史缓存，不是当前额度或登录证明。', 'This is history, not the current quota or proof of sign-in.'],
};

export function localQuotaMessage(code: string | null, language: string): string | null {
  if (code === null) return null;
  const entry = messages[code];
  // An unrecognised code is deliberately not echoed to the interface.
  if (!entry) return language === 'zh-Hans' ? '状态未知，未读取到额度。' : 'State unknown; no quota was read.';
  return language === 'zh-Hans' ? entry[0] : entry[1];
}

export function localIsolationNotice(mode: IsolationMode, language: string): string {
  const zh = language === 'zh-Hans';
  switch (mode) {
    case 'managed':
      return zh ? '可用独立配置目录隔离多个账号，不改写全局凭据。' : 'Accounts are isolated by their own configuration directory; global credentials are never rewritten.';
    case 'default_only':
      return zh ? '该平台只支持默认目录，无法再隔离第二个账号。' : 'This platform only supports its default directory, so a second account cannot be isolated.';
    case 'unsupported':
      return zh ? 'Windows 上不支持该平台的账号隔离；可关联已有目录做只读查看。' : 'This platform cannot be isolated on Windows; you can still link an existing directory for read-only viewing.';
    default:
      return zh ? '隔离方式未知。' : 'Isolation mode unknown.';
  }
}
