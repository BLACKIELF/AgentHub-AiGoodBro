import assert from 'node:assert/strict';
import test from 'node:test';

import {
  DEFAULT_LOW_QUOTA_THRESHOLDS,
  UNKNOWN_DISPLAY,
  accountTitle,
  exactBalance,
  formatBalance,
  formatRemainingPercent,
  formatResetCreditCount,
  formatResetTime,
  isExhausted,
  isLowQuota,
  isLowQuotaForWindow,
  isMeasuredUsage,
  planLabel,
  remainingPercent,
} from '../src/utils/quotaDisplay.ts';

test('remaining percent is derived from the reported usage', () => {
  assert.equal(remainingPercent(0), 100);
  assert.equal(remainingPercent(25), 75);
  assert.equal(remainingPercent(100), 0);
  // An over-reporting source is clamped rather than going negative.
  assert.equal(remainingPercent(140), 0);
  assert.equal(remainingPercent(-10), 100);
});

test('a window the source did not return is unknown, never zero', () => {
  for (const missing of [null, undefined]) {
    assert.equal(isMeasuredUsage(missing), false);
    assert.equal(formatRemainingPercent(missing), UNKNOWN_DISPLAY);
    assert.equal(isExhausted(missing), false);
  }
});

test('a non-finite usage is unknown and never low or exhausted', () => {
  for (const bad of [Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY]) {
    assert.equal(isMeasuredUsage(bad), false, `${bad} must not be measured`);
    assert.equal(formatRemainingPercent(bad), UNKNOWN_DISPLAY);
    assert.equal(isExhausted(bad), false);
    assert.equal(isLowQuota(bad, 5, true), false);
  }
});

test('remaining percent renders as an integer', () => {
  assert.equal(formatRemainingPercent(57.4), '43%');
  assert.equal(formatRemainingPercent(0), '100%');
  assert.equal(formatRemainingPercent(100), '0%');
});

test('exhaustion is reported only when usage reaches the cap', () => {
  assert.equal(isExhausted(99.9), false);
  assert.equal(isExhausted(100), true);
  assert.equal(isExhausted(100.1), true);
});

test('balance rounding marks inexact values', () => {
  assert.equal(formatBalance('12'), '12');
  assert.equal(formatBalance('12.0'), '12');
  assert.equal(formatBalance('12.4'), '≈12');
  assert.equal(formatBalance('12.6'), '≈13');
  assert.equal(formatBalance(' 7.5 '), '≈8');
  assert.equal(formatBalance(null), UNKNOWN_DISPLAY);
  assert.equal(formatBalance('   '), UNKNOWN_DISPLAY);
  assert.equal(formatBalance(undefined), UNKNOWN_DISPLAY);
});

test('a non-numeric balance is preserved instead of coerced', () => {
  assert.equal(formatBalance('unlimited'), 'unlimited');
  assert.equal(exactBalance(' 12.4 '), '12.4');
  assert.equal(exactBalance(null), UNKNOWN_DISPLAY);
});

test('balance rounding matches Rust half-away-from-zero on negatives', () => {
  // Math.round(-12.5) would be -12; the Rust implementation returns -13.
  assert.equal(formatBalance('-12.5'), '≈-13');
});

test('reset credit count is unknown when the source did not report one', () => {
  assert.equal(formatResetCreditCount(2), '2');
  assert.equal(formatResetCreditCount(0), '0');
  assert.equal(formatResetCreditCount(null), UNKNOWN_DISPLAY);
  assert.equal(formatResetCreditCount(undefined), UNKNOWN_DISPLAY);
});

test('reset time is rendered in the product time zone', () => {
  // 2026-09-11T12:00:00Z is 20:00 in Asia/Shanghai.
  const formatted = formatResetTime(Date.UTC(2026, 8, 11, 12, 0, 0));
  assert.match(formatted, /20:00/);
  assert.equal(formatResetTime(null), UNKNOWN_DISPLAY);
  assert.equal(formatResetTime(Number.NaN), UNKNOWN_DISPLAY);
});

test('low quota thresholds match the product: 5h inclusive, 7d exclusive', () => {
  // remaining 5% (used 95%) is at the 5h threshold
  assert.equal(isLowQuota(95, 5, true), true);
  assert.equal(isLowQuota(94.9, 5, true), false);

  // remaining 10% (used 90%) is not below the 7d threshold
  assert.equal(isLowQuota(90, 10, false), false);
  assert.equal(isLowQuota(90.1, 10, false), true);
});

test('an unmeasured window is never reported as low', () => {
  assert.equal(isLowQuota(null, 5, true), false);
  assert.equal(isLowQuota(undefined, 10, false), false);
});

test('the window-aware check applies the right comparison per window', () => {
  // 5h is inclusive: remaining exactly 5% counts.
  assert.equal(isLowQuotaForWindow('five_hour', 95), true);
  assert.equal(isLowQuotaForWindow('five_hour', 94.9), false);

  // 7d is exclusive: remaining exactly 10% does not count.
  assert.equal(isLowQuotaForWindow('seven_day', 90), false);
  assert.equal(isLowQuotaForWindow('seven_day', 90.1), true);
});

test('the default thresholds match the Rust defaults', () => {
  assert.equal(DEFAULT_LOW_QUOTA_THRESHOLDS.fiveHourPercent, 5);
  assert.equal(DEFAULT_LOW_QUOTA_THRESHOLDS.sevenDayPercent, 10);
});

test('adjusted thresholds are honoured instead of the built-in defaults', () => {
  const thresholds = { fiveHourPercent: 20, sevenDayPercent: 30 };

  // remaining 15% is below a 20% 5h threshold, but not below the default 5%.
  assert.equal(isLowQuotaForWindow('five_hour', 85, thresholds), true);
  assert.equal(isLowQuotaForWindow('five_hour', 85), false);

  // remaining 25% is below a 30% 7d threshold, but not below the default 10%.
  assert.equal(isLowQuotaForWindow('seven_day', 75, thresholds), true);
  assert.equal(isLowQuotaForWindow('seven_day', 75), false);
});

test('an unmeasured window is never low regardless of the window kind', () => {
  assert.equal(isLowQuotaForWindow('five_hour', null), false);
  assert.equal(isLowQuotaForWindow('seven_day', Number.NaN), false);
  assert.equal(isLowQuotaForWindow('five_hour', undefined, { fiveHourPercent: 99, sevenDayPercent: 99 }), false);
});

test('account title prefers the remark, then the masked email, then the id', () => {
  assert.equal(
    accountTitle({
      id: 'profile-a',
      label: '工作号',
      masked_email: 'a***@example.com',
      plan_label: 'plus',
      is_signed_in: true,
    }),
    '工作号',
  );
  assert.equal(
    accountTitle({
      id: 'profile-a',
      label: '',
      masked_email: 'a***@example.com',
      plan_label: null,
      is_signed_in: true,
    }),
    'a***@example.com',
  );
  assert.equal(
    accountTitle({
      id: 'profile-a',
      label: '',
      masked_email: null,
      plan_label: null,
      is_signed_in: false,
    }),
    'profile-a',
  );
  assert.equal(accountTitle(null), UNKNOWN_DISPLAY);
});

test('a missing plan stays unknown rather than being guessed', () => {
  assert.equal(planLabel({ id: 'a', label: 'a', masked_email: null, plan_label: null, is_signed_in: true }), null);
  assert.equal(planLabel({ id: 'a', label: 'a', masked_email: null, plan_label: '  ', is_signed_in: true }), null);
  assert.equal(planLabel({ id: 'a', label: 'a', masked_email: null, plan_label: 'plus', is_signed_in: true }), 'plus');
  assert.equal(planLabel(null), null);
});
