import { useEffect, useRef } from 'react';
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
  if (['pro', 'codex pro', 'openai codex pro'].includes(normalized)) return 'Pro 20x';
  const known: Record<string, string> = { free: 'Free', plus: 'Plus', team: 'Team', teams: 'Team', business: 'Business', enterprise: 'Enterprise' };
  return known[normalized] ?? (plan?.trim() || '—');
};

export function AccountDetails({ details, current, onClose }: {
  details: AccountQuotaDetails | null;
  current: boolean;
  onClose: () => void;
}) {
  const { language } = useI18n();
  const text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const node = dialog.current;
    const previous = document.activeElement;
    node?.showModal();
    return () => { node?.close(); if (previous instanceof HTMLElement && previous.isConnected) previous.focus(); };
  }, []);
  const number = (value: number | null, digits = 2) => value === null ? '—' : new Intl.NumberFormat(
    language === 'zh-Hans' ? 'zh-CN' : 'en-US', { maximumFractionDigits: digits },
  ).format(value);
  const rows = [
    [text('套餐', 'Plan'), accountPlanLabel(details?.account?.plan_type ?? null)],
    [text('账号类型', 'Account type'), details?.account?.account_type === 'chatgpt' ? text('ChatGPT 订阅账号', 'ChatGPT subscription') : details?.account?.account_type === 'apiKey' ? text('API 密钥', 'API key') : '—'],
    [text('邮箱状态', 'Email metadata'), details?.account ? (details.account.email_present ? text('已提供（不显示地址）', 'Present (address hidden)') : text('未提供', 'Not provided')) : '—'],
    [text('美元余额', 'USD balance'), details?.credits.usd == null ? '—' : `$${number(details.credits.usd)}`],
    [text('积分余额', 'Points balance'), number(details?.credits.points ?? null)],
    [text('可用重置卡', 'Available reset cards'), number(details?.credits.reset_cards ?? null, 0)],
  ];
  return (
    <dialog ref={dialog} aria-labelledby="account-details-title" onCancel={onClose} className="m-auto w-[calc(100%-2rem)] max-w-lg max-h-[90vh] overflow-auto rounded-2xl bg-surface text-primary p-0 backdrop:bg-black/50">
      <section aria-labelledby="account-details-title" className="glass-panel w-full max-w-lg space-y-4 p-5 shadow-2xl">
        <header className="flex items-center justify-between gap-3">
          <div>
            <h3 id="account-details-title" className="font-semibold text-primary">{text('账号详情', 'Account details')}</h3>
            <p className="mt-1 text-xs text-secondary">{text('来源：Codex 官方账号信息', 'Source: Codex account information')}</p>
          </div>
          <button className="glass-button px-3 py-1.5 text-sm" onClick={onClose}>{text('关闭', 'Close')}</button>
        </header>
        <div className={`rounded-xl border p-3 text-sm ${current ? 'border-theme' : 'border-status-warn text-secondary'}`}>
          {current ? text('当前读取记录', 'Current read') : text('非当前记录，请重新读取额度', 'Not current; read quota again')}
        </div>
        <dl className="grid grid-cols-[minmax(7rem,auto)_1fr] gap-x-4 gap-y-2 text-sm">
          {rows.map(([label, value]) => <div className="contents" key={label}>
            <dt className="text-secondary">{label}</dt><dd className="min-w-0 break-words text-primary">{value}</dd>
          </div>)}
        </dl>
        <p className="text-xs text-tertiary">{text('美元与积分按官方单位分别显示；缺失或无法验证时显示破折号，不进行金额换算。', 'USD and points are shown separately in their official units. Missing or unvalidated values remain a dash; no money is inferred or converted.')}</p>
      </section>
    </dialog>
  );
}
