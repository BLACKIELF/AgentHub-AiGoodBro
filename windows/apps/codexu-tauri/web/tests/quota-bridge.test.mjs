import assert from 'node:assert/strict';
import test from 'node:test';

import { SYSTEM_ACCOUNT_ID, quotaIndexFromUsage, quotaSnapshotFromUsage, resolveAccountQuota } from '../src/utils/quotaBridge.ts';

const refreshedAt = Date.UTC(2026, 8, 11, 12, 0, 0);

function usageSnapshot(overrides = {}) {
  return {
    refreshed_at: refreshedAt,
    account: { type: 'chatgpt', plan_type: 'plus', email_present: true },
    limit_id: 'limit-1',
    limit_name: 'Plus',
    quota_read_succeeded: true,
    five_hour_quota: { used_percent: 25, window_duration_mins: 300, resets_at: null },
    seven_day_quota: { used_percent: 60, window_duration_mins: 10080, resets_at: null },
    monthly_quota: null,
    local: null,
    task_board: null,
    messages: [],
    ...overrides,
  };
}

test('maps a successful official read to the workbench quota contract', () => {
  const mapped = quotaSnapshotFromUsage(usageSnapshot());

  assert.equal(mapped.account_id, SYSTEM_ACCOUNT_ID);
  assert.equal(mapped.quality, 'official');
  assert.equal(mapped.quota_read_succeeded, true);
  assert.equal(mapped.fetched_at, refreshedAt);
  assert.deepEqual(mapped.five_hour, {
    used_percent: 25,
    window_duration_mins: 300,
    resets_at: null,
  });
  assert.equal(mapped.seven_day.used_percent, 60);
  // The dashboard pipeline does not read these yet, so they stay unknown.
  assert.equal(mapped.monthly, null);
  assert.equal(mapped.available_reset_credits, null);
  assert.equal(mapped.credit_balance, null);
});

test('a read that returned no window is local-only, not an official zero', () => {
  const mapped = quotaSnapshotFromUsage(
    usageSnapshot({ five_hour_quota: null, seven_day_quota: null, monthly_quota: null }),
  );

  assert.equal(mapped.quality, 'local_only');
  assert.equal(mapped.five_hour, null);
  assert.equal(mapped.seven_day, null);
});

test('a failed official read is local-only even when a window is present', () => {
  const mapped = quotaSnapshotFromUsage(usageSnapshot({ quota_read_succeeded: false }));
  assert.equal(mapped.quality, 'local_only');
  // The window is still carried through; the quality label is what prevents it
  // from being presented as fresh official evidence.
  assert.equal(mapped.five_hour.used_percent, 25);
});

test('a missing snapshot maps to nothing rather than a zeroed snapshot', () => {
  assert.equal(quotaSnapshotFromUsage(null), null);
  assert.equal(quotaSnapshotFromUsage(undefined), null);
});

test('the index only carries the system login for now', () => {
  const index = quotaIndexFromUsage(usageSnapshot());
  assert.deepEqual(Object.keys(index), [SYSTEM_ACCOUNT_ID]);
  assert.equal(index[SYSTEM_ACCOUNT_ID].quality, 'official');

  assert.deepEqual(quotaIndexFromUsage(null), {});
});

test('the live dashboard reading wins over the value carried by the DTO', () => {
  const live = quotaSnapshotFromUsage(usageSnapshot());
  const fromDto = {
    [SYSTEM_ACCOUNT_ID]: { ...live, quality: 'stale', fetched_at: 1 },
  };

  assert.equal(resolveAccountQuota(SYSTEM_ACCOUNT_ID, { [SYSTEM_ACCOUNT_ID]: live }, fromDto), live);
  assert.equal(resolveAccountQuota(SYSTEM_ACCOUNT_ID, { [SYSTEM_ACCOUNT_ID]: live }, fromDto).quality, 'official');
});

test('the DTO value is used when no live reading exists', () => {
  const fromDto = quotaSnapshotFromUsage(usageSnapshot());

  assert.equal(resolveAccountQuota(SYSTEM_ACCOUNT_ID, {}, { [SYSTEM_ACCOUNT_ID]: fromDto }), fromDto);
  assert.equal(resolveAccountQuota(SYSTEM_ACCOUNT_ID, undefined, { [SYSTEM_ACCOUNT_ID]: fromDto }), fromDto);
});

test('a missing entry resolves to undefined so the caller renders unknown', () => {
  assert.equal(resolveAccountQuota('profile-a', {}, {}), undefined);
  assert.equal(resolveAccountQuota('profile-a', undefined, undefined), undefined);
  // A live entry for a different account must not leak across.
  assert.equal(
    resolveAccountQuota('profile-a', quotaIndexFromUsage(usageSnapshot()), undefined),
    undefined,
  );
});
