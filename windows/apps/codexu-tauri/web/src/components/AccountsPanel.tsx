import { RefreshCw, ShieldAlert, UserRound } from 'lucide-react';
import type { AccountQuotaSnapshot, AccountRecord, AccountsDto } from '../types/accounts';
import {
  DEFAULT_LOW_QUOTA_THRESHOLDS,
  UNKNOWN_DISPLAY,
  accountTitle,
  formatBalance,
  formatRemainingPercent,
  formatResetCreditCount,
  formatResetTime,
  isLowQuotaForWindow,
  isMeasuredUsage,
  planLabel,
  type LowQuotaThresholds,
} from '../utils/quotaDisplay';
import { resolveAccountQuota } from '../utils/quotaBridge';
import { useI18n } from '../i18n/I18nProvider';

interface AccountsPanelProps {
  accounts: AccountsDto | null;
  loading: boolean;
  error: string | null;
  onRefresh: () => void;
  /**
   * Live quota keyed by account id, typically derived from the dashboard
   * snapshot. Takes precedence over the value carried by the DTO because the
   * dashboard refreshes more often than the account list.
   */
  quotaByAccountId?: Record<string, AccountQuotaSnapshot | undefined>;
  /**
   * Low-quota thresholds. Both are user-adjustable settings, so the view takes
   * them as input instead of hard-coding the defaults.
   */
  thresholds?: LowQuotaThresholds;
}

/**
 * The account workbench.
 *
 * Renders the system login and every managed profile. A value the official
 * source did not return stays `—`: the panel never substitutes zero, because
 * "we do not know" and "the window is empty" need different reactions.
 */
export function AccountsPanel({
  accounts,
  loading,
  error,
  onRefresh,
  quotaByAccountId = {},
  thresholds = DEFAULT_LOW_QUOTA_THRESHOLDS,
}: AccountsPanelProps) {
  const { t, language } = useI18n();
  const records = accounts?.accounts ?? [];

  const quotaFor = (accountId: string): AccountQuotaSnapshot | undefined =>
    resolveAccountQuota(accountId, quotaByAccountId, accounts?.quotas);

  return (
    <section
      className="glass-panel p-4 md:p-5"
      role="region"
      aria-label={t('accounts.title')}
      data-testid="accounts-panel"
    >
      <div className="flex items-start justify-between gap-3 flex-wrap">
        <div className="min-w-0">
          <h2 className="text-sm font-semibold text-primary">{t('accounts.title')}</h2>
          <p className="text-xs text-tertiary mt-0.5">{t('accounts.subtitle')}</p>
        </div>
        <div className="flex items-center gap-2">
          {accounts?.profiles_root_label ? (
            <span className="chip-like text-xs text-secondary" data-testid="accounts-profiles-root">
              {t('accounts.profilesRoot')}: {accounts.profiles_root_label}
            </span>
          ) : null}
          <button
            type="button"
            onClick={onRefresh}
            disabled={loading}
            className="px-3 py-1.5 rounded-full glass-button-solid text-xs inline-flex items-center gap-1.5 disabled:opacity-60"
          >
            <RefreshCw size={12} className={loading ? 'animate-spin' : undefined} />
            {t('accounts.refresh')}
          </button>
        </div>
      </div>

      {error ? (
        <p
          className="mt-3 text-xs text-status-error bg-status-error/8 border border-status-error/30 rounded-lg p-3"
          role="alert"
        >
          {t('accounts.failed')}: {error}
        </p>
      ) : null}

      {accounts?.messages?.length ? (
        <ul className="mt-3 space-y-1" data-testid="accounts-messages">
          {accounts.messages.map((message) => (
            <li key={message} className="text-xs text-status-warn">
              {message}
            </li>
          ))}
        </ul>
      ) : null}

      {!error && records.length === 0 ? (
        <p className="mt-3 text-xs text-tertiary" data-testid="accounts-empty">
          {loading ? t('accounts.loading') : t('accounts.empty')}
        </p>
      ) : null}

      {records.length > 0 ? (
        <div className="mt-3 grid gap-3 sm:grid-cols-2 xl:grid-cols-3" data-testid="accounts-grid">
          {records.map((record) => (
            <AccountCard
              key={record.identity.id}
              record={record}
              quota={quotaFor(record.identity.id)}
              language={language}
              thresholds={thresholds}
              labels={{
                systemProfile: t('accounts.systemProfile'),
                isolatedProfile: t('accounts.isolatedProfile'),
                readOnly: t('accounts.readOnly'),
                signedOut: t('accounts.signedOut'),
                dispatchEnabled: t('accounts.dispatchEnabled'),
                dispatchPaused: t('accounts.dispatchPaused'),
                windowFiveHour: t('accounts.windowFiveHour'),
                windowSevenDay: t('accounts.windowSevenDay'),
                remaining: t('accounts.remaining'),
                resetsAt: t('accounts.resetsAt'),
                resetCredits: t('accounts.resetCredits'),
                balance: t('accounts.balance'),
                preference: t('accounts.preference'),
                quotaUnknownHint: t('accounts.quotaUnknownHint'),
              }}
            />
          ))}
        </div>
      ) : null}
    </section>
  );
}

interface AccountCardLabels {
  systemProfile: string;
  isolatedProfile: string;
  readOnly: string;
  signedOut: string;
  dispatchEnabled: string;
  dispatchPaused: string;
  windowFiveHour: string;
  windowSevenDay: string;
  remaining: string;
  resetsAt: string;
  resetCredits: string;
  balance: string;
  preference: string;
  quotaUnknownHint: string;
}

function AccountCard({
  record,
  quota,
  language,
  thresholds,
  labels,
}: {
  record: AccountRecord;
  quota: AccountQuotaSnapshot | undefined;
  language: string;
  thresholds: LowQuotaThresholds;
  labels: AccountCardLabels;
}) {
  const title = accountTitle(record.identity);
  const plan = planLabel(record.identity);

  return (
    <article
      className="bg-surface-inset rounded-xl border border-theme p-3 flex flex-col gap-2"
      data-testid={`account-card-${record.identity.id}`}
    >
      <header className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <h3 className="text-sm font-semibold text-primary truncate" title={title}>
            {title}
          </h3>
          <p className="text-[11px] text-tertiary truncate">{record.home_dir_label}</p>
        </div>
        <span
          className="chip-like text-[11px] text-secondary inline-flex items-center gap-1 shrink-0"
          data-testid={`account-kind-${record.identity.id}`}
        >
          {record.is_system_profile ? <ShieldAlert size={11} /> : <UserRound size={11} />}
          {record.is_system_profile ? labels.systemProfile : labels.isolatedProfile}
        </span>
      </header>

      <div className="flex items-center gap-1.5 flex-wrap">
        {plan ? (
          <span className="chip-like text-[11px] text-secondary" data-testid="account-plan">
            {plan}
          </span>
        ) : null}
        {record.is_system_profile ? (
          <span className="chip-like text-[11px] text-tertiary">{labels.readOnly}</span>
        ) : null}
        {!record.identity.is_signed_in ? (
          <span
            className="chip-like text-[11px] text-status-warn bg-status-warn/12 border-status-warn/30"
            data-testid={`account-signed-out-${record.identity.id}`}
          >
            {labels.signedOut}
          </span>
        ) : null}
        <span
          className={`chip-like text-[11px] ${
            record.participates_in_dispatch
              ? 'text-status-ok bg-status-ok/12 border-status-ok/30'
              : 'text-tertiary'
          }`}
        >
          {record.participates_in_dispatch ? labels.dispatchEnabled : labels.dispatchPaused}
        </span>
      </div>

      <div className="grid grid-cols-2 gap-2">
        <QuotaCell
          label={labels.windowFiveHour}
          windowKind="five_hour"
          usedPercent={quota?.five_hour?.used_percent ?? null}
          resetsAt={quota?.five_hour?.resets_at ?? null}
          language={language}
          thresholds={thresholds}
          remainingLabel={labels.remaining}
          resetsLabel={labels.resetsAt}
          unknownHint={labels.quotaUnknownHint}
          testId={`account-five-hour-${record.identity.id}`}
        />
        <QuotaCell
          label={labels.windowSevenDay}
          windowKind="seven_day"
          usedPercent={quota?.seven_day?.used_percent ?? null}
          resetsAt={quota?.seven_day?.resets_at ?? null}
          language={language}
          thresholds={thresholds}
          remainingLabel={labels.remaining}
          resetsLabel={labels.resetsAt}
          unknownHint={labels.quotaUnknownHint}
          testId={`account-seven-day-${record.identity.id}`}
        />
      </div>

      <dl className="grid grid-cols-2 gap-x-2 gap-y-1 text-[11px]">
        <div className="flex items-center justify-between gap-1">
          <dt className="text-tertiary">{labels.resetCredits}</dt>
          <dd className="text-secondary" data-testid={`account-reset-credits-${record.identity.id}`}>
            {formatResetCreditCount(quota?.available_reset_credits ?? null)}
          </dd>
        </div>
        <div className="flex items-center justify-between gap-1">
          <dt className="text-tertiary">{labels.balance}</dt>
          <dd className="text-secondary" data-testid={`account-balance-${record.identity.id}`}>
            {formatBalance(quota?.credit_balance ?? null)}
          </dd>
        </div>
      </dl>

      <p className="text-[11px] text-tertiary" data-testid={`account-preference-${record.identity.id}`}>
        {labels.preference}: {record.preference.model} · {record.preference.reasoning_effort} ·{' '}
        {record.preference.service_tier}
      </p>
    </article>
  );
}

function QuotaCell({
  label,
  windowKind,
  usedPercent,
  resetsAt,
  language,
  thresholds,
  remainingLabel,
  resetsLabel,
  unknownHint,
  testId,
}: {
  label: string;
  windowKind: 'five_hour' | 'seven_day';
  usedPercent: number | null;
  resetsAt: number | null;
  language: string;
  thresholds: LowQuotaThresholds;
  remainingLabel: string;
  resetsLabel: string;
  unknownHint: string;
  testId: string;
}) {
  const low = isLowQuotaForWindow(windowKind, usedPercent, thresholds);
  // Detected from the measurement itself, not by comparing rendered strings.
  const isUnknown = !isMeasuredUsage(usedPercent);

  return (
    <div
      className={`rounded-lg border border-theme px-2 py-1.5 ${low ? 'bg-status-warn/10' : ''}`}
      data-testid={testId}
    >
      <div className="flex items-baseline justify-between gap-1">
        <span className="text-[11px] text-tertiary">{label}</span>
        <span
          className={`text-sm font-semibold ${low ? 'text-status-warn' : 'text-primary'}`}
          title={isUnknown ? unknownHint : remainingLabel}
        >
          {formatRemainingPercent(usedPercent)}
        </span>
      </div>
      <div className="text-[11px] text-tertiary mt-0.5">
        {resetsLabel}: {isUnknown ? UNKNOWN_DISPLAY : formatResetTime(resetsAt, language)}
      </div>
    </div>
  );
}
