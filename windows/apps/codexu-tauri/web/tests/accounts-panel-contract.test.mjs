import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const panelPath = new URL('../src/components/AccountsPanel.tsx', import.meta.url);
const dashboardPath = new URL('../src/windows/Dashboard.tsx', import.meta.url);
const messagesPath = new URL('../src/i18n/messages.ts', import.meta.url);
const displayPath = new URL('../src/utils/quotaDisplay.ts', import.meta.url);

test('builds the account workbench on the shared quota display rules', async () => {
  const [panel, dashboard, messages, display] = await Promise.all([
    readFile(panelPath, 'utf8'),
    readFile(dashboardPath, 'utf8'),
    readFile(messagesPath, 'utf8'),
    readFile(displayPath, 'utf8'),
  ]);

  // The panel must consume the shared rules rather than re-deriving them.
  assert.match(panel, /useI18n/);
  assert.match(panel, /from '\.\.\/utils\/quotaDisplay'/);
  assert.match(panel, /formatRemainingPercent/);
  assert.match(panel, /formatResetTime/);
  assert.match(panel, /formatResetCreditCount/);
  assert.match(panel, /formatBalance/);
  assert.match(panel, /isLowQuotaForWindow/);
  assert.match(panel, /isMeasuredUsage/);
  assert.match(panel, /accountTitle/);
  assert.match(panel, /planLabel/);

  // Low-quota thresholds are user-adjustable, so the view must take them as
  // input rather than baking the defaults into the JSX.
  assert.match(panel, /thresholds = DEFAULT_LOW_QUOTA_THRESHOLDS/);
  assert.doesNotMatch(panel, /lowInclusive \? 5 : 10/);
  assert.doesNotMatch(panel, /isLowQuota\(usedPercent, 5,/);

  // "Unknown" is decided from the measurement, not by comparing rendered text.
  assert.doesNotMatch(panel, /formatRemainingPercent\(usedPercent\) === UNKNOWN_DISPLAY/);

  // A value the source did not return must never be coerced to zero.
  assert.match(panel, /quota\?\.five_hour\?\.used_percent \?\? null/);
  assert.match(panel, /quota\?\.seven_day\?\.used_percent \?\? null/);
  assert.doesNotMatch(panel, /used_percent \?\? 0\b/);
  assert.doesNotMatch(panel, /resets_at \?\? Date\.now/);

  // Quota resolution goes through the shared helper, with the live dashboard
  // reading preferred over the value carried by the account DTO.
  assert.match(
    panel,
    /resolveAccountQuota\(accountId, quotaByAccountId, accounts\?\.quotas\)/,
  );

  // Both windows and the account states are exposed with locator-level hooks.
  assert.match(panel, /data-testid="accounts-panel"/);
  assert.match(panel, /data-testid=\{`account-card-\$\{record\.identity\.id\}`\}/);
  assert.match(panel, /testId=\{`account-five-hour-\$\{record\.identity\.id\}`\}/);
  assert.match(panel, /testId=\{`account-seven-day-\$\{record\.identity\.id\}`\}/);
  assert.match(panel, /data-testid=\{testId\}/);
  assert.match(panel, /data-testid=\{`account-signed-out-\$\{record\.identity\.id\}`\}/);
  assert.match(panel, /data-testid=\{`account-reset-credits-\$\{record\.identity\.id\}`\}/);

  // The system login stays read-only and is labelled as such.
  assert.match(panel, /record\.is_system_profile \? labels\.systemProfile : labels\.isolatedProfile/);
  assert.match(panel, /\{labels\.readOnly\}/);

  // The panel is mounted above the tabbed dashboard on the existing snapshot.
  assert.match(
    dashboard,
    /<AccountsPanel[\s\S]*?quotaByAccountId=\{quotaIndexFromUsage\(dashboard\?\.codex\?\.snapshot\)\}[\s\S]*?\/>[\s\S]*?<DashboardHome[\s\S]*?snapshot=\{dashboard\?\.codex\?\.snapshot\}/,
  );
  assert.match(dashboard, /useAccounts\(\)/);

  // Bilingual copy is required for every account string the panel asks for.
  // Scoped to the `accounts` block so generic keys elsewhere cannot satisfy it.
  const accountBlocks = [...messages.matchAll(/\n {2}accounts: \{([\s\S]*?)\n {2}\},/g)].map(
    (match) => match[1],
  );
  assert.equal(accountBlocks.length, 2, 'accounts must exist in both catalogues');

  for (const key of [
    'title',
    'subtitle',
    'profilesRoot',
    'refresh',
    'loading',
    'failed',
    'empty',
    'systemProfile',
    'isolatedProfile',
    'readOnly',
    'signedOut',
    'dispatchEnabled',
    'dispatchPaused',
    'windowFiveHour',
    'windowSevenDay',
    'remaining',
    'resetsAt',
    'resetCredits',
    'balance',
    'preference',
    'quotaUnknownHint',
  ]) {
    for (const [index, block] of accountBlocks.entries()) {
      assert.match(
        block,
        new RegExp(`\\b${key}:`),
        `accounts.${key} is missing from catalogue ${index === 0 ? 'en' : 'zh-Hans'}`,
      );
    }
  }

  // The unknown placeholder lives in one place.
  assert.match(display, /export const UNKNOWN_DISPLAY = '—'/);
  assert.doesNotMatch(panel, /'—'/);
});
