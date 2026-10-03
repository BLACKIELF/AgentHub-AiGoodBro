import { useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { useI18n } from '../i18n/I18nProvider';
import { AccountDetails, type SafeAccount, type OfficialCredits, accountPlanLabel } from './AccountDetails';
import { ResetCountdown } from './ResetCountdown';

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
export function ProfileQuota({ profileId, profileLabel, disabled }: { profileId: string; profileLabel: string; disabled: boolean }) {
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
  const formatTime = (value: number) => new Intl.DateTimeFormat(language === 'zh-Hans' ? 'zh-CN' : 'en-GB',
    { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(value);
  const old = quota !== null && (failed || now < quota.checked_at || now - quota.checked_at >= 300000
    || quota.windows.some(window => window.resets_at !== null && window.resets_at <= now));
  const labels: Record<Kind, string> = { five_hour: text('5 小时', '5-hour'), seven_day: text('每周', 'Weekly'), monthly: text('每月', 'Monthly') };
  const credits = quota?.credits ?? { usd: null, points: null, reset_cards: null };
  const num = (value: number | null) => value === null ? '—' : new Intl.NumberFormat(language === 'zh-Hans' ? 'zh-CN' : 'en-US', { maximumFractionDigits: 2 }).format(value);
  return <div className="account-quota space-y-2 text-xs text-secondary" aria-label={text('目录额度', 'Directory quota')}>
    <div className="flex flex-wrap items-center gap-2">
      <button className="glass-button rounded-lg px-2 py-1" disabled={disabled || busy} onClick={() => void readQuota()}>{busy ? text('正在读取…', 'Reading…') : text('读取额度', 'Read quota')}</button>
      {!quota && !failed && !busy && <span>{text('尚未读取', 'Not read yet')}</span>}
      {failed && <span role="status" className="text-status-warn">{text('读取失败，可重试。', 'Read failed. You can retry.')}</span>}
      {quota && <><span className={old ? 'text-status-warn' : ''}>{old ? text('上次记录，需重读', 'Previous record; read again') : text('读取记录，非实时', 'Read snapshot, not live')}{' · '}{formatTime(quota.checked_at)}</span>
        <button className="glass-button px-2 py-1" onClick={() => setDetails(true)}>{text('账号详情', 'Account details')}</button></>}
    </div>
    {quota && <>
      <div className="flex flex-wrap gap-x-3 gap-y-1">
        {quota.account?.plan_type && <strong className="text-primary">{accountPlanLabel(quota.account.plan_type)}</strong>}
        {credits.usd !== null && <span>{text('美元 ', 'USD ')}{num(credits.usd)}</span>}{credits.points !== null && <span>{text('点数 ', 'Points ')}{num(credits.points)}</span>}{credits.reset_cards !== null && <span>{text('重置卡 ', 'Reset cards ')}{num(credits.reset_cards)}</span>}
      </div>
      <div className="account-quota-windows">
        {quota.windows.map(window => {
          const remaining = Number(window.remaining_percent.toFixed(1));
          const used = Number((100 - remaining).toFixed(1));
          return <div key={window.kind} className="account-quota-window min-w-0 space-y-1.5">
            <div className="flex flex-wrap justify-between gap-x-3 gap-y-1"><span>{labels[window.kind]} {old ? text('上次剩余', 'previously remaining') : text('剩余', 'remaining')} <strong className="text-primary">{remaining}%</strong></span><span>{old ? text('上次已用', 'previously used') : text('已用', 'used')} {used}%</span></div>
            <div className="h-1 rounded-full bg-surface-inset overflow-hidden" aria-hidden="true"><div className="h-full rounded-full" style={{ width: `${remaining}%`, background: old ? 'var(--text-tertiary)' : remaining <= 20 ? 'var(--status-error)' : remaining <= 50 ? 'var(--status-warn)' : window.kind === 'seven_day' ? 'linear-gradient(90deg, var(--quota-secondary-start), var(--quota-secondary-end))' : 'linear-gradient(90deg, var(--quota-primary-start), var(--quota-primary-end))' }} /></div>
            <p className="text-tertiary">{window.resets_at === null ? text('重置时间未知', 'Reset time unknown') : text('重置 ', 'Reset ') + formatTime(window.resets_at)}</p>
            {window.resets_at !== null && <ResetCountdown deadline={window.resets_at} />}
          </div>;
        })}
      </div>
      {quota.windows.length === 0 && <p className="text-tertiary">{text('官方未提供周期百分比与重置时间，余额和重置卡分别显示。', 'The provider did not report period percentages or reset times. Balances and reset cards are shown separately.')}</p>}
    </>}
    {!quota && <div className="account-quota-windows" aria-label={text('额度尚未读取', 'Quota not read yet')}>
      {(['five_hour', 'seven_day'] as Kind[]).map(kind => <div key={kind} className="account-quota-window space-y-1.5"><div className="flex justify-between gap-2"><span>{labels[kind]}</span><strong className="text-primary">—</strong></div><div className="h-1 rounded-full bg-surface-inset" /><p className="text-tertiary">{text('重置时间待读取', 'Read for reset time')}</p></div>)}
    </div>}
    {details && <AccountDetails profileLabel={profileLabel} details={quota ? { account: quota.account ?? null, credits, checked_at: quota.checked_at } : null} current={!old} onClose={() => setDetails(false)} />}
  </div>;
}
