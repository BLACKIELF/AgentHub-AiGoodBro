import { AccountBrowserSettings } from './AccountBrowserSettings';
import { useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { warmupFailureText, parseLocalDetails, type LocalAccountDetails } from '../utils/accountActions';
import { useI18n } from '../i18n/I18nProvider';

export type SafeAccount = {
  account_type: string;
  plan_type: string | null;
  email_present: boolean;
};

export type OfficialCredits = {
  usd: number | null;
  points: number | null;
  reset_cards: number | null;
};

export type AccountQuotaDetails = {
  account: SafeAccount | null;
  credits: OfficialCredits;
  checked_at: number;
};

export const accountPlanLabel = (plan: string | null) => {
  const normalized = plan?.trim().toLowerCase().replace(/[_-]/g, ' ') ?? '';
  if (['prolite', 'pro lite', 'codex pro lite', 'openai codex pro lite'].includes(normalized)) return 'Pro 5x';
  if (['pro', 'codex pro', 'openai codex pro'].includes(normalized)) return 'Pro';
  const known: Record<string, string> = { free: 'Free', plus: 'Plus', team: 'Team', teams: 'Team', business: 'Business', enterprise: 'Enterprise' };
  return known[normalized] ?? (plan?.trim() || '—');
};

export function AccountDetails({ profileId, profileLabel, details, current, onClose }: {
  profileId: string;
  profileLabel: string;
  details: AccountQuotaDetails | null;
  current: boolean;
  onClose: () => void;
}) {
  const { language } = useI18n();
  const text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const dialog = useRef<HTMLDialogElement>(null);
  const [local, setLocal] = useState<LocalAccountDetails | null>(null), [localState, setLocalState] = useState<'loading' | 'ready' | 'failed'>('loading'), [refreshing, setRefreshing] = useState(false), [refreshFailed, setRefreshFailed] = useState(false);
  const epoch = useRef(0), refreshPending = useRef<number | null>(null);
  const [savingMultiplier, setSavingMultiplier] = useState(false), [multiplierFailed, setMultiplierFailed] = useState(false);
  useEffect(() => {
    const generation = ++epoch.current; refreshPending.current = null; setRefreshing(false); setSavingMultiplier(false); setRefreshFailed(false); setMultiplierFailed(false); setLocal(null); setLocalState('loading');
    void invoke('get_account_local_details', { profileId }).then(raw => { const value = parseLocalDetails(raw, profileId); if (epoch.current === generation) { setLocal(value); setLocalState('ready'); } }).catch(() => { if (epoch.current === generation) setLocalState('failed'); });
  return () => { epoch.current++; };
  }, [profileId]);
  async function refreshOfficial() {
    if (refreshPending.current !== null) return;
    const generation = ++epoch.current; refreshPending.current = generation; setRefreshing(true); setRefreshFailed(false);
    try { const value = parseLocalDetails(await invoke('refresh_account_local_details', { profileId, language: language === 'zh-Hans' ? 'zh' : 'en' }), profileId); if (epoch.current === generation) { setLocal(value); setLocalState('ready'); } }
    catch { if (epoch.current === generation) setRefreshFailed(true); }
    finally { if (refreshPending.current === generation) refreshPending.current = null; if (epoch.current === generation) setRefreshing(false); }
  }
  async function saveMultiplier(value: string) {
    if (refreshPending.current !== null) return;
    const generation = ++epoch.current; refreshPending.current = generation; setSavingMultiplier(true); setMultiplierFailed(false);
    try { const next = parseLocalDetails(await invoke('set_account_pro_multiplier', { profileId, multiplier: value === '' ? null : Number(value) }), profileId); if (epoch.current === generation) setLocal(next); }
    catch { if (epoch.current === generation) setMultiplierFailed(true); }
    finally { if (refreshPending.current === generation) refreshPending.current = null; if (epoch.current === generation) setSavingMultiplier(false); }
  }
  useEffect(() => {
    const node = dialog.current;
    const previous = document.activeElement;
    node?.showModal();
    return () => { node?.close(); if (previous instanceof HTMLElement && previous.isConnected) previous.focus(); };
  }, []);
  const number = (value: number | null, digits = 2) => value === null ? '—' : new Intl.NumberFormat(
    language === 'zh-Hans' ? 'zh-CN' : 'en-US', { maximumFractionDigits: digits },
  ).format(value);
  // A linked login record is not identity-bound to an earlier quota response.
  const quotaDetails = local?.linkedLocal ? null : details;
  const currentRecord = !local?.linkedLocal && current;
  const plan = local?.planType ?? quotaDetails?.account?.plan_type ?? null;
  const proPlan = /^((openai )?codex )?pro( ?lite)?$/.test(plan?.trim().toLowerCase().replace(/[_-]/g, ' ') ?? '');
  const quotaWindows = (proPlan ? ['seven_day'] : ['five_hour', 'seven_day', ...(local?.quotaWindows.some(window => window.kind === 'monthly') ? ['monthly'] : [])]).map(kind => local?.quotaWindows.find(window => window.kind === kind) ?? { kind, usedPercent: null, resetsAtMs: null });
  const rows = [
    [text('套餐', 'Plan'), proPlan && local?.displayedProTierMultiplier ? `Pro ${local.displayedProTierMultiplier}x` : accountPlanLabel(plan)],
    [text('账号类型', 'Account type'), (local?.accountType ?? quotaDetails?.account?.account_type) === 'chatgpt' ? text('ChatGPT 订阅账号', 'ChatGPT subscription') : (local?.accountType ?? quotaDetails?.account?.account_type) === 'apiKey' ? text('API 密钥', 'API key') : '—'],
    [text('登录邮箱', 'Sign-in email'), localState === 'loading' ? text('读取中…', 'Reading…') : localState === 'failed' ? text('读取失败，请关闭后重试', 'Read failed; close and retry') : local?.email ?? text('未提供', 'Not provided')],
    [text('美元余额', 'USD balance'), quotaDetails?.credits.usd == null ? '—' : `$${number(quotaDetails.credits.usd)}`],
    [text('积分余额', 'Points balance'), number(quotaDetails?.credits.points ?? null)],
    [text('可用重置卡', 'Available reset cards'), number(local?.availableResetCards ?? quotaDetails?.credits.reset_cards ?? null, 0)],
  ];
  const date = (value: number | null | undefined) => value == null ? '—' : new Date(value).toLocaleString(language === 'zh-Hans' ? 'zh-CN' : 'en-GB', { timeZone: 'Asia/Shanghai' }) + ' UTC+8';
  const group = (title: string, values: [string, string][]) => <section className="space-y-2 border-t border-theme pt-3" aria-label={title}><h4 className="text-sm font-semibold">{title}</h4><dl className="grid grid-cols-[minmax(7rem,auto)_1fr] gap-x-4 gap-y-2 text-xs">{values.map(([label, value]) => <div className="contents" key={label}><dt className="text-secondary">{label}</dt><dd className="min-w-0 break-words text-primary">{value}</dd></div>)}</dl></section>;
  return (
    <dialog ref={dialog} aria-labelledby="account-details-title" onCancel={onClose} className="m-auto w-[calc(100%-2rem)] max-w-lg max-h-[90vh] overflow-auto rounded-2xl bg-surface text-primary p-0 backdrop:bg-black/50">
      <section aria-labelledby="account-details-title" className="glass-panel w-full max-w-lg space-y-4 p-5 shadow-2xl">
        <header className="flex items-center justify-between gap-3">
          <div className="min-w-0">
            <h3 id="account-details-title" className="font-semibold text-primary break-words">{text('账号详情', 'Account details')} · {profileLabel}</h3>
            <p className="mt-1 text-xs text-secondary">{local?.linkedLocal ? text('来源：此目录的本地登录记录；不代表当前登录或额度可用。', 'Source: this directory’s local sign-in record; current sign-in and allowance availability are not established.') : text('来源：Codex 官方账号信息', 'Source: Codex account information')}</p>
          </div>
          <button className="glass-button px-3 py-1.5 text-sm" onClick={onClose}>{text('关闭', 'Close')}</button>
        </header>
        <div className={`rounded-xl border p-3 text-sm ${currentRecord ? 'border-theme' : 'border-status-warn text-secondary'}`}>
          {currentRecord ? text('当前读取记录', 'Current read') : text('非当前记录，请重新读取额度', 'Not current; read quota again')}
        </div>
        <dl className="grid grid-cols-[minmax(7rem,auto)_1fr] gap-x-4 gap-y-2 text-sm">
          {rows.map(([label, value]) => <div className="contents" key={label}>
            <dt className="text-secondary">{label}</dt><dd className="min-w-0 break-words text-primary">{value}</dd>
          </div>)}
        </dl>
        {local && !local.linkedLocal && <button type="button" className="glass-button proxy-action" disabled={refreshing || savingMultiplier} onClick={() => void refreshOfficial()}>{refreshing ? text('正在刷新官方资料…', 'Refreshing official profile…') : text('刷新官方资料', 'Refresh official profile')}</button>}
        {refreshFailed && <p role="alert" className="text-xs text-status-warn">{text('官方资料刷新失败，保留上次记录。', 'Official profile refresh failed. The previous record is retained.')}</p>}
        {group(text('账号资料', 'Account information'), [
          [text('显示名称', 'Display name'), local?.displayName ?? '—'], [text('用户名', 'Username'), local?.username ?? '—'], [text('账号 ID', 'Account ID'), local?.maskedAccountId ?? '—'],
          [text('会员日期（登录记录）', 'Subscription date (sign-in record)'), date(local?.subscriptionActiveUntilMs)],
        ])}
        {local?.subscriptionActiveUntilMs != null && local.subscriptionActiveUntilMs < Date.now() && <p className="text-xs text-secondary">{text('记录日期已过，不能据此判断当前订阅已失效。', 'The recorded date has passed; it does not establish current subscription status.')}</p>}
        {group(text('重置卡到期', 'Reset-card expiry'), local?.resetCardExpiresAtMs.length ? [...local.resetCardExpiresAtMs].sort((a, b) => a - b).map((value, index) => [text(`第 ${index + 1} 张`, `Card ${index + 1}`), date(value) + (value <= Date.now() ? text(' · 已过记录日期', ' · Past recorded date') : (local.availableResetCards ?? 0) > 0 && local.quotaFresh && value - Date.now() <= 48 * 3600000 ? text(' · 48 小时内', ' · Within 48h') : '')]) : [[text('到期日期', 'Expiry dates'), text('官方未提供', 'Not reported')]])}
        {group(text('官方额度', 'Reported allowance'), [
          [text('额度更新', 'Allowance updated'), date(local?.quotaCheckedAtMs)],
          ...quotaWindows.map(window => [window.kind === 'five_hour' ? text('5 小时', '5 hours') : window.kind === 'seven_day' ? text('7 天', '7 days') : text('月额度', 'Monthly'), (local?.quotaFresh && (window.resetsAtMs === null || window.resetsAtMs > Date.now()) && window.usedPercent !== null ? text(`已用 ${window.usedPercent}% · 剩余 ${100 - window.usedPercent}%`, `Used ${window.usedPercent}% · Left ${100 - window.usedPercent}%`) : '—') + (window.resetsAtMs === null ? '' : text(' · 重置 ', ' · Resets ') + date(window.resetsAtMs)) + (window.resetsAtMs !== null && window.resetsAtMs <= Date.now() ? text(' · 已到重置时间，等待官方更新', ' · Reset time reached; awaiting provider data') : '')] as [string, string]),
        ])}
        {local && !local.linkedLocal && !local.quotaFresh && <p className="text-xs text-secondary">{text('额度记录待刷新，保留上次读取时间。', 'Allowance needs a refresh; the last read time is retained.')}</p>}
        {group(text('官方使用统计', 'Reported usage statistics'), [[text('累计 Token', 'Lifetime tokens'), number(local?.lifetimeTokens ?? null, 0)], [text('单日峰值 Token', 'Peak daily tokens'), number(local?.peakDailyTokens ?? null, 0)], [text('统计截至', 'Statistics as of'), date(local?.statsAsOfMs)], [text('资料更新', 'Profile fetched'), date(local?.profileFetchedAtMs)]])}
        {group(text('暖号记录', 'Warm-up history'), local?.warmupHistory.length ? [...local.warmupHistory].sort((a, b) => b.atMs - a.atMs).map((item, index) => [date(item.atMs) + ` · ${index + 1}`, item.succeeded === true ? text('成功', 'Succeeded') : item.succeeded === false ? text('未成功', 'Not successful') + ' · ' + warmupFailureText(item.failureCode, language === 'zh-Hans') : text('结果待确认', 'Result pending')]) : [[text('最近暖号', 'Last warm-up'), '—']])}
        <p className="text-xs text-secondary">{text('暖号成功表示最小请求完成；额度以官方刷新结果为准。', 'Success means the minimal request completed; allowance comes from the provider refresh.')}</p>
        {local && !local.linkedLocal && proPlan && <section className="space-y-2 border-t border-theme pt-3" aria-label={text('本地 Pro 倍率', 'Local Pro multiplier')}>
          <label className="flex items-center justify-between gap-3 text-sm">{text('Pro 倍率标记', 'Pro multiplier label')}
            <select className="rounded-lg border border-theme bg-surface-inset px-2 py-1 text-primary" value={local.proTierMultiplier ?? ''} disabled={refreshing || savingMultiplier} onChange={event => void saveMultiplier(event.target.value)}>
              <option value="">{text('自动', 'Automatic')}</option>{[5, 10, 20, 25].map(value => <option key={value} value={value}>{value}x</option>)}
            </select>
          </label><p className="text-xs text-secondary">{text('仅作为本地套餐标记，不改变官方订阅、额度或反代规则。', 'A local plan label only. Provider subscription, allowance and proxy rules stay unchanged.')}</p>
          {multiplierFailed && <p role="alert" className="text-xs text-status-warn">{text('保存失败，保留原倍率。', 'Save failed. The previous multiplier is retained.')}</p>}
        </section>}
        {group(text('本机设置', 'Local settings'), [[text('加入本机', 'Added locally'), date(local?.addedAtMs)], [text('后续任务模型', 'Model for future tasks'), local?.model ?? '—'], [text('思考强度', 'Reasoning effort'), local?.effort ?? '—'], [text('参与调度', 'Dispatch participation'), local?.participating == null ? '—' : local.participating ? text('开启', 'On') : text('关闭', 'Off')], [text('专用浏览器', 'Dedicated browser'), local?.chromeProfileName === 'Chrome · dedicated' ? text('Chrome · 专用', 'Chrome · dedicated') : local?.chromeProfileName ?? '—']])}
        {local && !local.linkedLocal && <AccountBrowserSettings profileId={profileId} profileLabel={profileLabel} onChanged={settings => setLocal(previous => previous && ({ ...previous, chromeProfileName: settings.mode === 'dedicatedChrome' ? 'Chrome · dedicated' : settings.mode === 'existingChrome' ? settings.profileDirectory : null }))} />}
        <p className="text-xs text-tertiary">{text('美元与积分按官方单位分别显示；缺失或无法验证时显示破折号，不进行金额换算。', 'USD and points are shown separately in their official units. Missing or unvalidated values remain a dash; no money is inferred or converted.')}</p>
      </section>
    </dialog>
  );
}
