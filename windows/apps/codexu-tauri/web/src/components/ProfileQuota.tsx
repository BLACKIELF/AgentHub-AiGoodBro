import { useEffect, useRef, useState, type ReactNode } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { useI18n } from '../i18n/I18nProvider';
import { AccountDetails, type SafeAccount, type OfficialCredits, accountPlanLabel } from './AccountDetails';
import { ResetCountdown } from './ResetCountdown';
import { RefreshCw, Info } from 'lucide-react';
import { QuotaRing } from './QuotaRing';

type Kind = 'five_hour' | 'seven_day' | 'monthly';
type QuotaWindow = { kind: Kind; remaining_percent: number; used_percent?: number; resets_at: number | null };
type Quota = { profile_id: string; checked_at: number; windows: QuotaWindow[]; account?: SafeAccount | null; credits?: OfficialCredits };
const kinds: Kind[] = ['five_hour', 'seven_day', 'monthly'];
const validTime = (value: unknown): value is number => typeof value === 'number' && Number.isFinite(value) && !Number.isNaN(new Date(value).valueOf());
const safeLabel = (value: unknown): value is string => typeof value === 'string' && value.length > 0 && value.length <= 64 && !/[@/\\:\x00-\x1f]/.test(value);
const balance = (value: unknown) => value === null || (typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1e9);
function validQuota(value: Quota, id: string): boolean {
  if (!value || value.profile_id !== id || !validTime(value.checked_at) || !Array.isArray(value.windows)
    || value.windows.length > 3
    || new Set(value.windows.map(window => window?.kind)).size !== value.windows.length) return false;
  if (value.account !== undefined && value.account !== null && (!safeLabel(value.account.account_type)
    || !(value.account.plan_type === null || safeLabel(value.account.plan_type)) || typeof value.account.email_present !== 'boolean')) return false;
  if (value.credits !== undefined && (!value.credits || !balance(value.credits.usd) || !balance(value.credits.points)
    || !(value.credits.reset_cards === null || (Number.isSafeInteger(value.credits.reset_cards) && value.credits.reset_cards >= 0 && value.credits.reset_cards <= 1e6)))) return false;
  if (value.windows.length === 0 && (!value.credits
    || (value.credits.usd === null && value.credits.points === null && value.credits.reset_cards === null))) return false;
  return value.windows.every(window => window && kinds.includes(window.kind)
    && Number.isFinite(window.remaining_percent) && window.remaining_percent >= 0 && window.remaining_percent <= 100
    && (window.used_percent === undefined || (Number.isFinite(window.used_percent) && Math.abs(window.used_percent + window.remaining_percent - 100) < 0.001))
    && (window.resets_at === null || validTime(window.resets_at)));
}

/** Explicit row-local official read. The clock ages labels without making API requests. */
export function ProfileQuota({ profileId, profileLabel, disabled, refreshToken = 0, platformLabel, toolbar }: { profileId: string; profileLabel: string; disabled: boolean; refreshToken?: number; platformLabel?: string; toolbar?: ReactNode }) {
  const { language } = useI18n();
  const text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const [quota, setQuota] = useState<Quota | null>(null);
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);
  const [details, setDetails] = useState(false);
  const [now, setNow] = useState(Date.now);
  const inFlight = useRef(false), generation = useRef(0);
  useEffect(() => {
    const tick = () => setNow(Date.now());
    const timer = window.setInterval(tick, 1000);
    window.addEventListener('focus', tick);
    return () => { window.clearInterval(timer); window.removeEventListener('focus', tick); generation.current++; };
  }, []);
  async function readQuota() {
    if (inFlight.current || disabled) return;
    const epoch = ++generation.current;
    inFlight.current = true; setBusy(true); setFailed(false);
    try {
      const result = await invoke<Quota>('read_profile_quota', { id: profileId });
      if (!validQuota(result, profileId)) throw new Error('Invalid quota result');
      if (epoch === generation.current) { setQuota(result); setNow(Date.now()); }
    } catch { if (epoch === generation.current) setFailed(true); }
    finally { if (epoch === generation.current) { inFlight.current = false; setBusy(false); } }
  }
  useEffect(() => { if (refreshToken > 0) void readQuota(); }, [refreshToken]);
  const formatTime = (value: number) => new Intl.DateTimeFormat(language === 'zh-Hans' ? 'zh-CN' : 'en-GB',
    { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(value);
  const formatFullTime = (value: number) => new Intl.DateTimeFormat(language === 'zh-Hans' ? 'zh-CN' : 'en-GB',
    { year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(value);
  const old = quota !== null && (failed || now < quota.checked_at || now - quota.checked_at >= 300000
    || quota.windows.some(window => window.resets_at !== null && window.resets_at <= now));
  const labels: Record<Kind, string> = { five_hour: text('5 小时', '5-hour'), seven_day: text('每周', 'Weekly'), monthly: text('每月', 'Monthly') };
  const credits = quota?.credits ?? { usd: null, points: null, reset_cards: null };
  const num = (value: number | null) => value === null ? '—' : new Intl.NumberFormat(language === 'zh-Hans' ? 'zh-CN' : 'en-US', { maximumFractionDigits: 2 }).format(value);
  return <div className="account-quota space-y-2 text-xs text-secondary" aria-label={text('目录额度', 'Directory quota')}>
    <div className="account-quota-summary">
      <div className="account-quota-plan-and-balance">
        {platformLabel && <span className="account-quota-platform-label">{platformLabel}</span>}
        {quota?.account?.plan_type && <strong className="text-primary">{accountPlanLabel(quota.account.plan_type)}</strong>}
        {credits.usd !== null && <span>{text('美元 ', 'USD ')}{num(credits.usd)}</span>}{credits.points !== null && <span>{text('点数 ', 'Points ')}{num(credits.points)}</span>}{credits.reset_cards !== null && <span>{text('重置卡 ', 'Reset cards ')}{num(credits.reset_cards)}</span>}
      </div>
      <div className="account-quota-controls">
        {toolbar}
        <button type="button" className="icon-action" aria-label={busy ? text('正在读取…', 'Reading…') : text('读取额度', 'Read quota')} title={text('读取额度', 'Read quota')} disabled={disabled || busy} onClick={() => void readQuota()}><RefreshCw size={14} className={busy ? 'animate-spin' : ''} aria-hidden="true" /></button>
        <button type="button" className="icon-action" aria-label={text('账号详情', 'Account details')} title={text('账号详情', 'Account details')} onClick={() => setDetails(true)}><Info size={14} aria-hidden="true" /></button>
      </div>
    </div>
    {quota && <>
      <div className="account-quota-windows">
        {quota.windows.map(window => {
          const remaining = Number(window.remaining_percent.toFixed(1));
          const used = Number((100 - remaining).toFixed(1));
          const fullResetTime = window.resets_at === null ? null : formatFullTime(window.resets_at);
          return <div key={window.kind} className="account-quota-window min-w-0">
            <QuotaRing label="" remaining={remaining} stale={old} secondary={window.kind === 'seven_day'}
              description={`${labels[window.kind]} ${old ? text('上次剩余', 'previously remaining') : text('剩余', 'remaining')} ${remaining}% · ${old ? text('上次已用', 'previously used') : text('已用', 'used')} ${used}%`} />
            <div className="account-quota-window-copy">
              <span className="account-quota-window-label">{labels[window.kind]}</span>
              {window.resets_at === null
                ? <span className="account-quota-window-reset text-tertiary">{text('重置时间未知', 'Reset time unknown')}</span>
                : <span className="account-quota-window-reset" title={text('重置 ', 'Reset ') + fullResetTime} aria-label={text('重置 ', 'Reset ') + fullResetTime}>
                  <ResetCountdown deadline={window.resets_at} />
                  <time className="sr-only" dateTime={new Date(window.resets_at).toISOString()}>{fullResetTime}</time>
                </span>}
            </div>
          </div>;
        })}
      </div>
      {quota.windows.length === 0 && <p className="text-tertiary">{text('官方未提供周期百分比与重置时间，余额和重置卡分别显示。', 'The provider did not report period percentages or reset times. Balances and reset cards are shown separately.')}</p>}
    </>}
    {!quota && <div className="account-quota-windows" aria-label={text('额度尚未读取', 'Quota not read yet')}>
      {(['five_hour', 'seven_day'] as Kind[]).map(kind => <div key={kind} className="account-quota-window">
        <QuotaRing label="" remaining={null} description={labels[kind] + ' · ' + text('额度尚未读取', 'Quota not read yet')} secondary={kind === 'seven_day'} />
        <div className="account-quota-window-copy">
          <span className="account-quota-window-label">{labels[kind]}</span>
          <span className="account-quota-window-reset text-tertiary">{text('重置时间待读取', 'Read for reset time')}</span>
        </div>
      </div>)}
    </div>}
    <div className="account-quota-reading-status">
      {busy && <span role="status">{text('正在读取…', 'Reading…')}</span>}
      {!quota && !failed && !busy && <span>{text('尚未读取', 'Not read yet')}</span>}
      {failed && <span role="status" className="text-status-warn">{text('读取失败，可重试。', 'Read failed. You can retry.')}</span>}
      {quota && <span className={`quota-read-status ${old ? 'text-status-warn' : ''}`}>{old ? text('上次记录，需重读', 'Previous record; read again') : text('读取记录，非实时', 'Read snapshot, not live')} <time className="quota-read-time" dateTime={new Date(quota.checked_at).toISOString()}>{formatTime(quota.checked_at)}</time></span>}
    </div>
    {details && <AccountDetails profileId={profileId} profileLabel={profileLabel} details={quota ? { account: quota.account ?? null, credits, checked_at: quota.checked_at } : null} current={quota !== null && !old} onClose={() => setDetails(false)} />}
  </div>;
}
