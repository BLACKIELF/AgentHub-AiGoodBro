import { useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { useI18n } from '../i18n/I18nProvider';
import { ResetCountdown } from './ResetCountdown';
import { parseLocalQuota, localQuotaStateLabel, localQuotaMessage, type LocalQuota } from '../utils/localCliQuota';

/**
 * Manual, row-local read for a non-Codex account.
 *
 * A cached or unsupported result is labelled as history/unknown. It never shows a
 * green success, and a saved sign-in is never presented as a quota reading.
 */
export function LocalProfileQuota({ profileId, disabled }: { profileId: string; disabled: boolean }) {
  const { language } = useI18n();
  const text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const [quota, setQuota] = useState<LocalQuota | null>(null);
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);
  const [now, setNow] = useState(Date.now);
  const inFlight = useRef(false);
  const generation = useRef(0);
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
      const result = parseLocalQuota(await invoke('read_profile_local_quota', { id: profileId }), profileId);
      if (epoch === generation.current) { setQuota(result); setNow(Date.now()); }
    } catch { if (epoch === generation.current) setFailed(true); }
    finally { if (epoch === generation.current) { inFlight.current = false; setBusy(false); } }
  }
  const formatTime = (value: number) => new Intl.DateTimeFormat(language === 'zh-Hans' ? 'zh-CN' : 'en-GB',
    { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(value);
  const num = (value: number) => new Intl.NumberFormat(language === 'zh-Hans' ? 'zh-CN' : 'en-US', { maximumFractionDigits: 2 }).format(value);
  const stale = quota !== null && (failed || now < quota.checked_at || now - quota.checked_at >= 300000);
  const history = quota !== null && quota.state !== 'available';
  const message = quota ? localQuotaMessage(quota.message_code, language) : null;
  return <div className="account-quota account-local-quota space-y-2 text-xs text-secondary" aria-label={text('平台额度', 'Platform quota')}>
    <div className="flex flex-wrap items-center gap-2">
      <button className="glass-button rounded-lg px-2 py-1" disabled={disabled || busy} onClick={() => void readQuota()}>
        {busy ? text('正在读取…', 'Reading…') : text('读取额度', 'Read quota')}
      </button>
      {!quota && !failed && !busy && <span>{text('尚未读取', 'Not read yet')}</span>}
      {failed && <span role="status" className="text-status-warn">{text('读取失败，可重试。', 'Read failed. You can retry.')}</span>}
      {quota && <span className={history || stale ? 'text-status-warn' : ''} data-state={quota.state}>
        {localQuotaStateLabel(quota.state, language)}{' · '}{formatTime(quota.checked_at)}
      </span>}
    </div>
    {quota && <>
      <p className="text-tertiary" data-source-label>{quota.source_label}</p>
      {message && <p className={history ? 'text-status-warn' : 'text-tertiary'}>{message}</p>}
      <div className="flex flex-wrap gap-x-3 gap-y-1">
        {quota.masked_identity && <span>{text('账号 ', 'Account ')}{quota.masked_identity}</span>}
        {quota.plan_label && <strong className="text-primary">{quota.plan_label}</strong>}
        {quota.balance !== null && <span>{text('余额 ', 'Balance ')}{num(quota.balance)}{quota.balance_currency ? ' ' + quota.balance_currency : ''}</span>}
      </div>
      {quota.windows.length > 0 && <div className="account-quota-windows">
        {quota.windows.map(window => {
          const remaining = Number(window.remaining_percent.toFixed(1));
          const used = Number((100 - remaining).toFixed(1));
          return <div key={window.id} className="account-quota-window min-w-0 space-y-1.5">
            <div className="flex flex-wrap justify-between gap-x-3 gap-y-1">
              <span>{window.label} {history ? text('历史剩余', 'history remaining') : text('剩余', 'remaining')} <strong className="text-primary">{remaining}%</strong></span>
              <span>{history ? text('历史已用', 'history used') : text('已用', 'used')} {used}%</span>
            </div>
            <div className="h-1 rounded-full bg-surface-inset overflow-hidden" aria-hidden="true">
              <div className="h-full rounded-full" style={{ width: `${remaining}%`, background: history ? 'var(--text-tertiary)' : remaining <= 20 ? 'var(--status-error)' : remaining <= 50 ? 'var(--status-warn)' : 'linear-gradient(90deg, var(--quota-primary-start), var(--quota-primary-end))' }} />
            </div>
            <p className="text-tertiary">{window.resets_at === null ? text('重置时间未知', 'Reset time unknown') : text('重置 ', 'Reset ') + formatTime(window.resets_at)}</p>
            {window.resets_at !== null && !history && <ResetCountdown deadline={window.resets_at} />}
          </div>;
        })}
      </div>}
      {quota.windows.length === 0 && <p className="text-tertiary">{text('该平台未返回周期百分比，未读取到额度，显示为未知。', 'The platform returned no period percentage, so no quota was read and it stays unknown.')}</p>}
    </>}
  </div>;
}
