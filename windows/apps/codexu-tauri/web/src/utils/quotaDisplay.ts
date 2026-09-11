/**
 * Quota and balance display rules.
 *
 * Pure functions with no imports so they can be exercised directly by the Node
 * test runner, and so the rules stay identical to the Rust implementation in
 * `crates/codexu-core/src/models/quota.rs`.
 *
 * Three rules are load-bearing:
 *
 * 1. A value the source did not return is unknown (`—`), never `0`.
 * 2. A balance is shown rounded, with `≈` when the displayed value is not exact.
 * 3. A value the source did not actually measure is never reported as low and
 *    never reported as exhausted.
 */

import type { AccountIdentity } from '../types/accounts';

/** Placeholder rendered when an official value was not returned. */
export const UNKNOWN_DISPLAY = '—';

/** The product displays reset times in the Shanghai time zone. */
export const RESET_TIME_ZONE = 'Asia/Shanghai';

/**
 * Round half away from zero, matching Rust's `f64::round`.
 *
 * `Math.round` rounds half toward `+Infinity`, which disagrees on negative
 * values.
 */
function roundHalfAwayFromZero(value: number): number {
  return value < 0 ? -Math.round(-value) : Math.round(value);
}

/** Whether the reported usage is an actual finite number. */
export function isMeasuredUsage(usedPercent: number | null | undefined): boolean {
  return typeof usedPercent === 'number' && Number.isFinite(usedPercent);
}

/** Remaining percent derived from the reported usage. */
export function remainingPercent(usedPercent: number | null | undefined): number {
  if (!isMeasuredUsage(usedPercent)) return 0;
  const used = usedPercent as number;
  return Math.min(100, Math.max(0, 100 - used));
}

/** Integer remaining percent, or the unknown placeholder. */
export function formatRemainingPercent(usedPercent: number | null | undefined): string {
  if (!isMeasuredUsage(usedPercent)) return UNKNOWN_DISPLAY;
  return `${roundHalfAwayFromZero(remainingPercent(usedPercent))}%`;
}

/** Whether the window is known to be exhausted. */
export function isExhausted(usedPercent: number | null | undefined): boolean {
  return isMeasuredUsage(usedPercent) && (usedPercent as number) >= 100;
}

/**
 * Main-workbench balance. Rounded, `≈`-prefixed when inexact, `—` when absent.
 *
 * A value the source sent as non-numeric text is preserved verbatim rather than
 * being coerced into a number the source never sent.
 */
export function formatBalance(raw: string | null | undefined): string {
  const trimmed = typeof raw === 'string' ? raw.trim() : '';
  if (trimmed === '') return UNKNOWN_DISPLAY;

  const amount = Number(trimmed);
  if (!Number.isFinite(amount)) return trimmed;

  const rounded = roundHalfAwayFromZero(amount);
  return Math.abs(amount - rounded) > Number.EPSILON ? `≈${rounded}` : String(rounded);
}

/** Exact original balance, reachable from the detail affordance. */
export function exactBalance(raw: string | null | undefined): string {
  const trimmed = typeof raw === 'string' ? raw.trim() : '';
  return trimmed === '' ? UNKNOWN_DISPLAY : trimmed;
}

/** Reset-credit count, or the unknown placeholder. */
export function formatResetCreditCount(count: number | null | undefined): string {
  return typeof count === 'number' && Number.isFinite(count)
    ? String(Math.trunc(count))
    : UNKNOWN_DISPLAY;
}

/**
 * Format an official reset time in the product time zone.
 *
 * A missing timestamp is unknown, not "now".
 */
export function formatResetTime(
  resetsAt: number | null | undefined,
  language: string = 'zh-Hans',
): string {
  if (typeof resetsAt !== 'number' || !Number.isFinite(resetsAt)) return UNKNOWN_DISPLAY;

  const date = new Date(resetsAt);
  if (Number.isNaN(date.getTime())) return UNKNOWN_DISPLAY;

  try {
    return new Intl.DateTimeFormat(language === 'zh-Hans' ? 'zh-CN' : 'en-US', {
      timeZone: RESET_TIME_ZONE,
      month: 'numeric',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
      hour12: false,
    }).format(date);
  } catch {
    return date.toISOString();
  }
}

/**
 * Whether a window has reached the low-quota threshold.
 *
 * The 5h rule is inclusive (`<= 5%`), the 7d rule is exclusive (`< 10%`).
 * An unmeasured value never counts as low.
 */
export function isLowQuota(
  usedPercent: number | null | undefined,
  thresholdRemainingPercent: number,
  inclusive: boolean,
): boolean {
  if (!isMeasuredUsage(usedPercent)) return false;
  const remaining = remainingPercent(usedPercent);
  return inclusive ? remaining <= thresholdRemainingPercent : remaining < thresholdRemainingPercent;
}

/** Low-quota thresholds. The product lets the user adjust both. */
export interface LowQuotaThresholds {
  fiveHourPercent: number;
  sevenDayPercent: number;
}

/**
 * Product defaults, matching `LowQuotaThresholds::default()` in
 * `crates/codexu-core/src/models/quota.rs`.
 *
 * Views must take these as input rather than hard-coding them, because both
 * values are user-adjustable settings.
 */
export const DEFAULT_LOW_QUOTA_THRESHOLDS: LowQuotaThresholds = {
  fiveHourPercent: 5,
  sevenDayPercent: 10,
};

/** Window-aware low-quota check, applying the right comparison per window. */
export function isLowQuotaForWindow(
  kind: 'five_hour' | 'seven_day',
  usedPercent: number | null | undefined,
  thresholds: LowQuotaThresholds = DEFAULT_LOW_QUOTA_THRESHOLDS,
): boolean {
  return kind === 'five_hour'
    ? isLowQuota(usedPercent, thresholds.fiveHourPercent, true)
    : isLowQuota(usedPercent, thresholds.sevenDayPercent, false);
}

/** The label shown for an account: remark, then masked email, then profile id. */
export function accountTitle(identity: AccountIdentity | null | undefined): string {
  if (!identity) return UNKNOWN_DISPLAY;
  const label = identity.label?.trim();
  if (label) return label;
  const masked = identity.masked_email?.trim();
  if (masked) return masked;
  return identity.id || UNKNOWN_DISPLAY;
}

/** Plan chip text, or `null` when the source did not report a plan. */
export function planLabel(identity: AccountIdentity | null | undefined): string | null {
  const plan = identity?.plan_label?.trim();
  return plan ? plan : null;
}
