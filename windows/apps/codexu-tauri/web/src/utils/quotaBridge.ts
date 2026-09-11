/**
 * Bridge from the existing dashboard usage snapshot to the account workbench
 * quota shape.
 *
 * The dashboard pipeline already reads the system login's official quota. This
 * module re-expresses it in the workbench contract so the account panel can show
 * a real 5h/7d reading without a second read path.
 *
 * Managed profiles have no quota source yet, so they stay `null` and render as
 * unknown rather than as zero.
 */

import type { AccountQuotaSnapshot, QuotaWindowSnapshot } from '../types/accounts';
import type { RateWindow, UsageSnapshot } from '../types/models';

/** The system login is addressed by this id, matching the Rust reader. */
export const SYSTEM_ACCOUNT_ID = 'system';

function toWindow(rate: RateWindow | null | undefined): QuotaWindowSnapshot | null {
  if (!rate) return null;
  return {
    used_percent: rate.used_percent,
    window_duration_mins: rate.window_duration_mins ?? null,
    resets_at: rate.resets_at ?? null,
  };
}

/**
 * Map a dashboard usage snapshot to the workbench quota contract.
 *
 * A read that succeeded but returned no window is classified as `local_only`,
 * not as an official zero-quota result.
 */
export function quotaSnapshotFromUsage(
  snapshot: UsageSnapshot | null | undefined,
): AccountQuotaSnapshot | null {
  if (!snapshot) return null;

  const fiveHour = toWindow(snapshot.five_hour_quota);
  const sevenDay = toWindow(snapshot.seven_day_quota);
  const monthly = toWindow(snapshot.monthly_quota);
  const readSucceeded = snapshot.quota_read_succeeded === true;
  const hasAnyWindow = Boolean(fiveHour || sevenDay || monthly);
  const quality = readSucceeded && hasAnyWindow
    ? 'official'
    : hasAnyWindow
      ? 'stale'
      : 'local_only';

  return {
    account_id: SYSTEM_ACCOUNT_ID,
    limit_id: snapshot.limit_id ?? null,
    limit_name: snapshot.limit_name ?? null,
    five_hour: fiveHour,
    seven_day: sevenDay,
    monthly,
    // The dashboard pipeline does not read reset credits or balance yet.
    available_reset_credits: null,
    reset_credit_expiries: null,
    credit_balance: null,
    credit_balance_unlimited: null,
    fetched_at: snapshot.refreshed_at,
    app_server_version: null,
    quota_read_succeeded: snapshot.quota_read_succeeded ?? null,
    quality,
  };
}

/** Index the system login's quota by account id for the panel lookup. */
export function quotaIndexFromUsage(
  snapshot: UsageSnapshot | null | undefined,
): Record<string, AccountQuotaSnapshot> {
  const mapped = quotaSnapshotFromUsage(snapshot);
  return mapped ? { [SYSTEM_ACCOUNT_ID]: mapped } : {};
}

/**
 * Resolve the quota to render for one account.
 *
 * The live dashboard value wins over the value carried by the account DTO,
 * because the dashboard refreshes on every usage event while the account list is
 * loaded on demand. A missing entry stays `undefined` so the caller renders the
 * unknown placeholder instead of a zero.
 */
export function resolveAccountQuota(
  accountId: string,
  live: Record<string, AccountQuotaSnapshot | undefined> | undefined,
  fromDto: Record<string, AccountQuotaSnapshot> | undefined,
): AccountQuotaSnapshot | undefined {
  return live?.[accountId] ?? fromDto?.[accountId];
}
