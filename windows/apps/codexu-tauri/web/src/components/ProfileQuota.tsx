import { useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { useI18n } from '../i18n/I18nProvider';

type Kind = 'five_hour' | 'seven_day' | 'monthly';
type QuotaWindow = { kind: Kind; remaining_percent: number; resets_at: number | null };
type Quota = { profile_id: string; checked_at: number; windows: QuotaWindow[] };
const kinds: Kind[] = ['five_hour', 'seven_day', 'monthly'];
const validTime = (value: unknown): value is number =>
  typeof value === 'number' && Number.isFinite(value) && !Number.isNaN(new Date(value).valueOf());

function validQuota(value: Quota, id: string): boolean {
  return value?.profile_id === id && validTime(value.checked_at)
    && Array.isArray(value.windows) && value.windows.length > 0 && value.windows.length <= 3
    && new Set(value.windows.map(window => window?.kind)).size === value.windows.length
    && value.windows.every(window => window && kinds.includes(window.kind)
      && Number.isFinite(window.remaining_percent)
      && window.remaining_percent >= 0 && window.remaining_percent <= 100
      && (window.resets_at === null || validTime(window.resets_at)));
}

/** A row-local, explicit read; no polling, persisted quota or automatic account action. */
export function ProfileQuota({ profileId, disabled }: { profileId: string; disabled: boolean }) {
  const { language } = useI18n();
  const text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const [quota, setQuota] = useState<Quota | null>(null);
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);
  const [now, setNow] = useState(Date.now);
  const inFlight = useRef(false);
  const generation = useRef(0);

  useEffect(() => {
    // The timer only ages the label. It never performs an IPC/API call.
    const timer = window.setInterval(() => setNow(Date.now()), 30000);
    return () => { window.clearInterval(timer); generation.current++; };
  }, []);

  async function readQuota() {
    if (inFlight.current || disabled) return;
    const epoch = ++generation.current;
    inFlight.current = true;
    setBusy(true); setFailed(false);
    try {
      const result = await invoke<Quota>('read_profile_quota', { id: profileId });
      if (!validQuota(result, profileId)) throw new Error('Invalid quota result');
      if (epoch === generation.current) { setQuota(result); setNow(Date.now()); }
    } catch {
      if (epoch === generation.current) setFailed(true);
    } finally {
      if (epoch === generation.current) { inFlight.current = false; setBusy(false); }
    }
  }

  const formatTime = (value: number) => new Intl.DateTimeFormat(
    language === 'zh-Hans' ? 'zh-CN' : 'en-GB',
    { year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' },
  ).format(value);
  const old = quota !== null && (failed || now < quota.checked_at || now - quota.checked_at >= 300000
    || quota.windows.some(window => window.resets_at !== null && window.resets_at <= now));
  const labels: Record<Kind, string> = {
    five_hour: text('5 小时', '5-hour'),
    seven_day: text('每周', 'Weekly'),
    monthly: text('每月', 'Monthly'),
  };
  return (
    <div className="basis-full flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-secondary" aria-label={text('目录额度', 'Directory quota')}>
      <button className="glass-button rounded-lg px-2 py-1" disabled={disabled || busy} onClick={() => void readQuota()}>
        {busy ? text('正在读取…', 'Reading…') : text('读取额度', 'Read quota')}
      </button>
      <div className="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1" role="status" aria-live="polite">
        {!quota && !failed && !busy && <span>{text('尚未读取', 'Not read yet')}</span>}
        {failed && <span className="text-status-warn">{text('读取失败，可重试。', 'Read failed. You can retry.')}</span>}
        {quota && <>
          <span className={old ? 'text-status-warn' : ''}>
            {old ? text('上次记录，需重读', 'Previous record; read again') : text('读取记录，非实时', 'Read snapshot, not live')}
            {' · '}{formatTime(quota.checked_at)}
          </span>
          {quota.windows.map(window => (
            <span key={window.kind}>
              {labels[window.kind]} {text('剩余', 'remaining')} {Number(window.remaining_percent.toFixed(1))}%
              <span className="text-tertiary">{' · '}{window.resets_at === null
                ? text('重置时间未知', 'Reset time unknown')
                : text('重置 ', 'Reset ') + formatTime(window.resets_at)}</span>
            </span>
          ))}
        </>}
      </div>
    </div>
  );
}
