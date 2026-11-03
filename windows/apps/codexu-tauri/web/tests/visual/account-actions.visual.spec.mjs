import { test, expect } from '@playwright/test';
import { FIXED_NOW_ISO, SYNTHETIC_DASHBOARD, SYNTHETIC_SETTINGS } from './synthetic-fixtures.mjs';
import { installTauriStub } from './tauri-stub.mjs';
async function setup(page, language = 'en') {
  await page.clock.setFixedTime(new Date(FIXED_NOW_ISO));
  await installTauriStub(page, { settings: { ...SYNTHETIC_SETTINGS, language }, dashboard: SYNTHETIC_DASHBOARD }, () => {
    const original = window.__TAURI_INTERNALS__.invoke;
    window.actionCalls = []; window.actionMode = 'success'; window.cardReview = null; window.referralReview = null;
    const account = { id: 'managed_a', label: 'Synthetic account', platform: 'codex', storage_kind: 'managed', login_state: 'verified', active_state: 'unknown', masked_identity: 's***@example.invalid', plan_type: 'plus', can_login: true, can_switch: false, switch_block_reason: 'system_busy', revision: 1, recovery_required: false };
    window.__TAURI_INTERNALS__.invoke = async (command, args) => {
      if (command === 'list_managed_accounts') return [structuredClone(account)];
      if (command === 'list_profiles') return [{ id: '1', label: 'Synthetic account', selected: true, platform: 'codex', platform_name: 'Codex', can_view_usage: true }];
      if (command === 'read_profile_quota') return { profile_id: args.id, checked_at: Date.now(), windows: [{ kind: 'five_hour', remaining_percent: 22, resets_at: null }], account: { account_type: 'chatgpt', plan_type: 'plus', email_present: true }, credits: { usd: null, points: 0, reset_cards: 2 } };
      if (command === 'get_account_local_details' || command === 'refresh_account_local_details' || command === 'set_account_pro_multiplier') {
        window.actionCalls.push({ command, ...args }); if (command === 'set_account_pro_multiplier') { if (window.failMultiplier) throw 'save_failed'; window.multiplier = args.multiplier; } if (command === 'refresh_account_local_details' && window.failDetailsRefresh) throw 'profile_unavailable';
        if (window.linkedOnly && command === 'get_account_local_details') return { profileId: args.profileId, linkedLocal: true, email: 'linked.account@example.invalid', accountType: 'chatgpt', planType: 'plus', quotaFresh: false };
        return { profileId: window.actionMode === 'wrong_identity' ? 'other' : args.profileId, email: 'synthetic.account@example.invalid', displayName: command === 'refresh_account_local_details' ? 'Refreshed synthetic' : 'Synthetic official name', username: 'synthetic_name', maskedAccountId: 'acc***', accountType: 'chatgpt', planType: window.detailPlan ?? 'pro', proTierMultiplier: window.multiplier ?? null, displayedProTierMultiplier: window.multiplier ?? null, subscriptionActiveUntilMs: Date.now() - 86400000, lifetimeTokens: 12000, peakDailyTokens: 3000, statsAsOfMs: Date.now() - 1000, profileFetchedAtMs: Date.now() - 1000, addedAtMs: null, model: 'gpt-synthetic', effort: 'high', participating: true, chromeProfileName: null, availableResetCards: 2, resetCardExpiresAtMs: [Date.now() + 86400000], quotaCheckedAtMs: Date.now() - 1000, quotaFresh: true, quotaWindows: [{ kind: 'five_hour', usedPercent: 10, resetsAtMs: Date.now() + 60000 }, { kind: 'seven_day', usedPercent: 80, resetsAtMs: Date.now() + (window.expiredQuota ? -1000 : 60000) }], warmupHistory: [{ atMs: Date.now() - 1000, succeeded: true, failureCode: null, phase: 'succeeded' }, { atMs: Date.now() - 2000, succeeded: null, failureCode: null, phase: 'unknown' }, { atMs: Date.now() - 3000, succeeded: false, failureCode: 'maintenance_cancelled', phase: 'cancelled' }] };
      }
      if (command === 'get_account_browser_settings' || command === 'set_account_browser_settings') {
        window.actionCalls.push({ command, ...args });
        if (command === 'set_account_browser_settings') { if (window.failBrowserSave) throw 'browser_profile_unavailable'; window.browserMode = args.mode; window.browserProfile = args.profileDirectory; }
        return { profileId: args.profileId, mode: window.browserMode ?? 'systemDefault', profileDirectory: window.browserProfile ?? null, chromeAvailable: !window.chromeMissing, profileScanIssue: window.browserScanFailed ? 'browser_profiles_unavailable' : null, profiles: window.browserScanFailed ? [] : [{ directoryName: 'Default', displayName: 'Personal' }, { directoryName: 'Profile 2', displayName: 'Work' }] };
      }
      if (command === 'rename_managed_account') { account.label = args.label; window.actionCalls.push({ command, ...args }); return { account_id: args.accountId, phase: 'renamed', error_code: null }; }
      if (command === 'begin_manual_reset_review') {
        window.actionCalls.push({ command, ...args }); window.cardStage = 1;
        const result = { profileId: args.profileId, reviewId: 'review_a', checkedAtMs: Date.now(), expiresAtMs: Date.now() + 30000, availableCount: 2, cardExpiresAtMs: Date.now() + 86400000 };
        window.cardReview = result;
        if (window.actionMode === 'wrong_identity') return { ...result, profileId: 'other' };
        if (window.actionMode === 'delayed') return new Promise(resolve => { window.releaseCard = () => resolve(result); });
        return result;
      }
      if (command === 'confirm_manual_reset_review') { window.actionCalls.push({ command, ...args }); if (window.cardStage !== 1 || args.reviewId !== 'review_a') throw 'confirmation_required'; window.cardStage = 2; return window.cardReview; }
      if (command === 'consume_manual_reset_credit') { window.actionCalls.push({ command, ...args }); if (window.cardStage !== 2) throw 'confirmation_required'; window.cardStage = 3; return { profileId: args.profileId, outcome: window.actionMode === 'unknown' ? 'unknown' : 'reset', issueCode: window.actionMode === 'receipt_failed' ? 'notification_receipt_save_failed' : null }; }
      if (command === 'cancel_manual_reset_review') { window.actionCalls.push({ command, ...args }); window.cardStage = 0; return null; }
      if (command === 'get_account_referral_eligibility') {
        window.actionCalls.push({ command, ...args });
        const result = { profileId: args.profileId, reviewId: 'referral_a', checkedAtMs: Date.now(), expiresAtMs: Date.now() + 300000, shouldShow: true, title: 'Synthetic official offer', description: 'Invite eligible friends.', rules: ['Rewards follow the official terms.'], creditAmount: 250, invitationCapacity: 5, remainingSendCapacity: 5, remainingRewardCapacity: 5, requiresExplicitConfirmation: true };
        window.referralReview = result; return result;
      }
      if (command === 'send_account_referral_invites') { window.actionCalls.push({ command, ...args }); return { profileId: args.profileId, sent: window.actionMode === 'mixed' ? [0] : [], failed: window.actionMode === 'mixed' ? [1] : [], uncertain: window.actionMode === 'mixed' ? [2] : args.emails.map((_, index) => index) }; }
      if (command === 'check_account_referral_outcome') { window.actionCalls.push({ command, ...args }); return { profileId: args.profileId, sent: [0], failed: [1], uncertain: [2] }; }
      if (command === 'get_account_referral_tracking') { window.actionCalls.push({ command, ...args }); return { profileId: args.profileId, items: [{ id: args.cursor ? 'record_b' : 'record_a', maskedEmail: args.cursor ? 'b***@example.invalid' : 'a***@example.invalid', status: args.cursor ? 'redeemed' : 'pending' }], cursor: args.cursor ? null : 'page_2' }; }
      return original(command, args);
    };
  });
  await page.goto('/');
  await expect(page.getByTestId('profile-1')).toBeVisible();
}
async function managed(page, language = 'en') {
  await page.getByRole('navigation').getByRole('button', { name: language === 'zh-Hans' ? '平台账号' : 'Accounts', exact: true }).click();
  return page.getByTestId('managed-account-managed_a');
}
const calls = (page, command) => page.evaluate(command => window.actionCalls.filter(call => call.command === command), command);

test('home reset requires two distinct confirmations and stays usable while account switching is busy', async ({ page }) => {
  await setup(page); const row = page.getByTestId('profile-1');
  await row.getByRole('button', { name: 'Use reset card', exact: true }).click();
  let dialog = page.getByRole('dialog', { name: 'Confirmation 1: verify account and reset card', exact: true });
  await expect(dialog).toBeVisible(); await expect(dialog).toHaveScreenshot('account-actions-reset-review.png');
  expect(await calls(page, 'consume_manual_reset_credit')).toHaveLength(0);
  await dialog.getByRole('button', { name: 'I verified the account and card', exact: true }).click();
  dialog = page.getByRole('dialog', { name: 'Confirmation 2: consume one reset card', exact: true });
  await expect(dialog).toContainText('This cannot be undone.'); await expect(dialog).toHaveScreenshot('account-actions-reset-consume.png');
  expect(await calls(page, 'consume_manual_reset_credit')).toHaveLength(0);
  await dialog.getByRole('button', { name: 'Consume this reset card', exact: true }).click();
  await expect(row.getByRole('status')).toContainText('Manually used 1 reset card');
  expect(await calls(page, 'consume_manual_reset_credit')).toHaveLength(1);
  const account = await managed(page); await expect(account.getByRole('button', { name: 'Switch current Codex', exact: true })).toBeDisabled();
  await expect(account.getByRole('button', { name: 'Use reset card', exact: true })).toBeEnabled(); await expect(account.getByRole('button', { name: 'Invite friends', exact: true })).toBeEnabled();
});
test('cancel, expiry, wrong identity and unknown result cannot consume again', async ({ page }) => {
  await setup(page); const row = page.getByTestId('profile-1');
  await row.getByRole('button', { name: 'Use reset card', exact: true }).click();
  await page.getByRole('dialog').getByRole('button', { name: 'Cancel', exact: true }).click();
  expect(await calls(page, 'cancel_manual_reset_review')).toHaveLength(1); expect(await calls(page, 'consume_manual_reset_credit')).toHaveLength(0);
  await row.getByRole('button', { name: 'Use reset card', exact: true }).click(); await page.clock.setFixedTime(new Date(new Date(FIXED_NOW_ISO).valueOf() + 60000));
  await expect(page.getByRole('dialog').getByRole('button', { name: 'I verified the account and card', exact: true })).toBeDisabled();
  await page.getByRole('dialog').getByRole('button', { name: 'Cancel', exact: true }).click();
  await page.evaluate(() => { window.actionMode = 'wrong_identity'; }); await row.getByRole('button', { name: 'Use reset card', exact: true }).click();
  await expect(page.getByRole('dialog')).toHaveCount(0); await expect(row.getByRole('alert')).toBeVisible();
  await page.evaluate(() => { window.actionMode = 'unknown'; }); await row.getByRole('button', { name: 'Use reset card', exact: true }).click();
  await page.getByRole('dialog').getByRole('button', { name: 'I verified the account and card', exact: true }).click(); await page.getByRole('dialog').getByRole('button', { name: 'Consume this reset card', exact: true }).click();
  await expect(row.getByRole('button', { name: 'Use reset card', exact: true })).toBeDisabled(); expect(await calls(page, 'consume_manual_reset_credit')).toHaveLength(1);
});
test('late reset review after leaving home is cancelled instead of opening in another account surface', async ({ page }) => {
  await setup(page); await page.evaluate(() => { window.actionMode = 'delayed'; });
  await page.getByTestId('profile-1').getByRole('button', { name: 'Use reset card', exact: true }).click();
  await expect.poll(() => page.evaluate(() => typeof window.releaseCard)).toBe('function');
  await page.getByRole('navigation').getByRole('button', { name: 'Workspace', exact: true }).click();
  await page.evaluate(() => window.releaseCard());
  await expect.poll(() => calls(page, 'cancel_manual_reset_review')).toHaveLength(1); await expect(page.getByRole('dialog')).toHaveCount(0);
});
test('referral validates recipients and consent, preserves uncertain results when history cannot bind this send', async ({ page }) => {
  await setup(page); await page.evaluate(() => { window.actionMode = 'mixed'; }); const row = await managed(page);
  await row.getByRole('button', { name: 'Invite friends', exact: true }).click(); const dialog = page.getByRole('dialog', { name: 'Invite friends', exact: true });
  await expect(dialog.getByRole('region', { name: 'Official invitation offer' })).toBeVisible(); await expect(dialog).toHaveScreenshot('account-actions-referral-offer.png');
  const input = dialog.getByRole('textbox', { name: 'Recipient emails; multiple addresses supported' }), send = dialog.getByRole('button', { name: 'Send invitations', exact: true });
  await input.fill('invalid'); await expect(send).toBeDisabled();
  await input.fill('one@example.invalid;ONE@example.invalid\ntwo@example.invalid three@example.invalid'); await expect(send).toBeDisabled();
  await dialog.getByRole('checkbox', { name: 'I have consent from all recipients', exact: true }).check(); await send.click();
  expect((await calls(page, 'send_account_referral_invites'))[0].emails).toEqual(['one@example.invalid', 'two@example.invalid', 'three@example.invalid']);
  await expect(dialog.getByRole('region', { name: 'Invitation results' })).toContainText('Result unconfirmed'); await expect(input).toBeDisabled(); await expect(send).toBeDisabled(); await expect(dialog).toHaveScreenshot('account-actions-referral-mixed.png');
  await dialog.getByRole('button', { name: 'Check invitation records', exact: true }).click();
  await expect(input).toHaveValue('one@example.invalid;ONE@example.invalid\ntwo@example.invalid three@example.invalid'); await expect(input).toBeDisabled(); await expect(send).toBeDisabled();
  expect(await calls(page, 'send_account_referral_invites')).toHaveLength(1); expect(await calls(page, 'check_account_referral_outcome')).toHaveLength(1);
  await dialog.getByRole('button', { name: 'View invitations', exact: true }).click(); await dialog.getByRole('button', { name: 'Load more', exact: true }).click();
  await expect(dialog.getByRole('region', { name: 'Invitation history' })).toContainText('2 loaded'); await expect(dialog.getByRole('region', { name: 'Invitation history' })).toContainText('Accepted'); await expect(dialog).toHaveScreenshot('account-actions-referral-history.png');
});
test('full email is available in home and managed details; direct rename is discoverable', async ({ page }) => {
  await setup(page); const row = page.getByTestId('profile-1'); await row.getByRole('button', { name: 'Read quota', exact: true }).click(); await row.getByRole('button', { name: 'Account details', exact: true }).click();
  let dialog = page.getByRole('dialog'); await expect(dialog).toContainText('synthetic.account@example.invalid'); await expect(dialog).not.toContainText('address hidden'); await expect(dialog).toHaveScreenshot('account-actions-home-details.png'); await dialog.getByRole('button', { name: 'Close', exact: true }).click();
  const account = await managed(page); await account.getByRole('button', { name: 'Account details', exact: true }).click(); dialog = page.getByRole('dialog'); await expect(dialog).toContainText('synthetic.account@example.invalid'); await expect(dialog).toHaveScreenshot('account-actions-managed-details.png'); await dialog.getByRole('button', { name: 'Close', exact: true }).click();
  await account.getByRole('button', { name: 'Customize name', exact: true }).click(); dialog = page.getByRole('dialog', { name: 'Rename account', exact: true }); await dialog.getByRole('textbox', { name: 'Account alias', exact: true }).fill('Renamed synthetic'); await dialog.getByRole('button', { name: 'Save alias', exact: true }).click(); await expect(account.locator('h3')).toHaveText('Renamed synthetic');
});
test('Chinese manual account actions render the same real component flow', async ({ page }) => {
  await setup(page, 'zh-Hans'); const row = await managed(page, 'zh-Hans');
  await row.getByRole('button', { name: '邀请好友', exact: true }).click(); const dialog = page.getByRole('dialog', { name: '邀请好友', exact: true }); await expect(dialog.getByRole('button', { name: '关闭', exact: true })).toBeVisible(); await expect(dialog).toHaveScreenshot('account-actions-referral-zh.png');
});

test('official details load locally, refresh explicitly and retain their record after refresh failure', async ({ page }) => {
  await setup(page); const account = await managed(page); await account.getByRole('button', { name: 'Account details', exact: true }).click(); const dialog = page.getByRole('dialog');
  await expect(dialog).toContainText('Synthetic official name'); expect(await calls(page, 'refresh_account_local_details')).toHaveLength(0);
  await expect(dialog.getByRole('region', { name: 'Reported usage statistics' })).toContainText('12,000');
  await expect(dialog.getByRole('region', { name: 'Reported allowance' })).toContainText('Used 80% · Left 20%');
  await expect(dialog.getByRole('region', { name: 'Reset-card expiry' })).toContainText('Within 48h');
  await expect(dialog.getByRole('region', { name: 'Warm-up history' })).toContainText('Result pending');
  await expect(dialog).not.toContainText('Pro 20x');
  await dialog.getByRole('button', { name: 'Refresh official profile', exact: true }).click(); await expect(dialog).toContainText('Refreshed synthetic');
  await page.evaluate(() => { window.failDetailsRefresh = true; }); await dialog.getByRole('button', { name: 'Refresh official profile', exact: true }).click(); await expect(dialog.getByRole('alert')).toContainText('previous record is retained'); await expect(dialog).toContainText('Refreshed synthetic');
  await expect(dialog.getByRole('region', { name: 'Reported usage statistics' })).toHaveScreenshot('account-actions-official-statistics.png');
});

async function component(page, kind, id) {
  await page.evaluate(async ({ kind, id }) => {
    document.getElementById('root').style.display = 'none';
    const { mountAccountComponent } = await import('/tests/visual/account-actions-component.fixture.tsx');
    window.accountFixture = mountAccountComponent(kind, id);
  }, { kind, id });
  return page.getByTestId('account-component-fixture');
}
test('real component profile reuse drops late reset and invitation responses from the previous account', async ({ page }) => {
  await setup(page); const fixture = await component(page, 'actions', 'A');
  await page.evaluate(() => { window.actionMode = 'delayed'; });
  await fixture.getByRole('button', { name: 'Use reset card', exact: true }).click();
  await expect.poll(() => page.evaluate(() => typeof window.releaseCard)).toBe('function');
  await page.evaluate(() => window.accountFixture.render('B'));
  await expect(fixture.getByTestId('account-actions-B')).toBeVisible();
  await page.evaluate(() => window.releaseCard());
  await expect.poll(() => calls(page, 'cancel_manual_reset_review')).toEqual([{ command: 'cancel_manual_reset_review', profileId: 'A', reviewId: 'review_a' }]);
  await expect(fixture.getByRole('dialog')).toHaveCount(0);
  await page.evaluate(() => {
    const original = window.__TAURI_INTERNALS__.invoke;
    window.__TAURI_INTERNALS__.invoke = async (command, args) => {
      const value = await original(command, args);
      if (command === 'get_account_referral_eligibility' && args.profileId === 'B') return new Promise(resolve => { window.releaseOffer = () => resolve({ ...value, title: 'Offer only for B' }); });
      return value;
    };
  });
  await fixture.getByRole('button', { name: 'Invite friends', exact: true }).click();
  await expect.poll(() => page.evaluate(() => typeof window.releaseOffer)).toBe('function');
  await page.evaluate(() => window.accountFixture.render('C'));
  await fixture.getByRole('button', { name: 'Invite friends', exact: true }).click();
  await expect(fixture.getByRole('dialog')).toContainText('Synthetic C');
  await page.evaluate(() => window.releaseOffer());
  await expect(fixture.getByRole('dialog')).not.toContainText('Offer only for B');
  await expect(fixture.getByRole('textbox')).toHaveValue('');
});
test('Pro label is local, Pro shows seven-day quota, and failed multiplier save retains the prior value', async ({ page }) => {
  await setup(page); const account = await managed(page); await account.getByRole('button', { name: 'Account details', exact: true }).click(); const dialog = page.getByRole('dialog');
  await expect(dialog.getByRole('region', { name: 'Reported allowance' })).not.toContainText('5 hours');
  await expect(dialog.getByRole('region', { name: 'Warm-up history' })).toContainText('Warm-up was cancelled');
  const multiplier = dialog.getByRole('combobox', { name: 'Pro multiplier label' });
  await multiplier.selectOption('25'); await expect(dialog.locator('dd').filter({ hasText: /^Pro 25x$/ })).toBeVisible();
  expect((await calls(page, 'set_account_pro_multiplier'))[0].multiplier).toBe(25);
  await page.evaluate(() => { window.failMultiplier = true; }); await multiplier.selectOption('10'); await expect(multiplier).toHaveValue('25'); await expect(dialog.getByRole('alert')).toContainText('previous multiplier is retained');
  await page.evaluate(() => { window.failMultiplier = false; window.detailPlan = 'plus'; window.expiredQuota = true; });
  await dialog.getByRole('button', { name: 'Refresh official profile' }).click();
  await expect(dialog.locator('dd').filter({ hasText: /^Plus$/ })).toBeVisible(); await expect(dialog).not.toContainText('Pro 25x'); await expect(multiplier).toHaveCount(0);
  const quota = dialog.getByRole('region', { name: 'Reported allowance' }); await expect(quota).not.toContainText('Used 80%'); await expect(quota).toContainText('Reset time reached; awaiting provider data'); await expect(quota).toContainText('Used 10%');
  await expect(quota).toHaveScreenshot('account-details-expired-window.png');
});
test('details profile change clears busy state while old refresh and multiplier replies cannot overwrite the new account', async ({ page }) => {
  await setup(page); const fixture = await component(page, 'details', 'A');
  await expect(fixture.getByRole('dialog')).toContainText('Synthetic A');
  await page.evaluate(() => {
    const original = window.__TAURI_INTERNALS__.invoke;
    window.__TAURI_INTERNALS__.invoke = async (command, args) => {
      const value = await original(command, args);
      if (command === 'refresh_account_local_details' && args.profileId === 'A') return new Promise(resolve => { window.releaseDetails = () => resolve({ ...value, displayName: 'Stale A official name' }); });
      if (command === 'set_account_pro_multiplier' && args.profileId === 'B') return new Promise(resolve => { window.releaseMultiplier = () => resolve(value); });
      return value;
    };
  });
  await fixture.getByRole('button', { name: 'Refresh official profile' }).click(); await expect.poll(() => page.evaluate(() => typeof window.releaseDetails)).toBe('function');
  await page.evaluate(() => window.accountFixture.render('B'));
  await expect(fixture.getByRole('button', { name: 'Refresh official profile' })).toBeEnabled();
  await fixture.getByRole('combobox', { name: 'Pro multiplier label' }).selectOption('10'); await expect.poll(() => page.evaluate(() => typeof window.releaseMultiplier)).toBe('function');
  await page.evaluate(() => window.releaseDetails()); await expect(fixture.getByRole('combobox')).toBeDisabled(); await expect(fixture).not.toContainText('Stale A official name');
  await page.evaluate(() => window.accountFixture.render('C'));
  await expect(fixture.getByRole('button', { name: 'Refresh official profile' })).toBeEnabled();
  await page.evaluate(() => window.releaseMultiplier()); await expect(fixture.getByRole('dialog')).toContainText('Synthetic C'); await expect(fixture.getByRole('button', { name: 'Refresh official profile' })).toBeEnabled();
});

test('browser selection saves per-account routing without opening login or changing the current account', async ({ page }) => {
  await setup(page); const row = await managed(page); await row.getByRole('button', { name: 'Browser settings', exact: true }).click(); const dialog = page.getByRole('dialog', { name: 'Account browser' });
  const mode = dialog.getByRole('combobox', { name: 'Open login page with' }); await expect(mode).toHaveValue('systemDefault');
  await mode.selectOption('dedicatedChrome'); await dialog.getByRole('button', { name: 'Save browser settings' }).click(); await expect(dialog.getByRole('status')).toContainText('Saved for the next time');
  await mode.selectOption('existingChrome'); await expect(dialog.getByRole('button', { name: 'Save browser settings' })).toBeDisabled(); await dialog.getByRole('combobox', { name: 'Chrome profile', exact: true }).selectOption('Profile 2');
  await page.evaluate(() => { window.failBrowserSave = true; }); await dialog.getByRole('button', { name: 'Save browser settings' }).click(); await expect(dialog.getByRole('alert')).toContainText('selected Chrome profile is unavailable');
  await dialog.getByRole('button', { name: 'Read again' }).click(); await expect(mode).toHaveValue('dedicatedChrome');
  await page.evaluate(() => { window.failBrowserSave = false; }); await mode.selectOption('existingChrome'); await dialog.getByRole('combobox', { name: 'Chrome profile', exact: true }).selectOption('Profile 2'); await dialog.getByRole('button', { name: 'Save browser settings' }).click();
  expect((await calls(page, 'set_account_browser_settings')).at(-1)).toEqual({ command: 'set_account_browser_settings', profileId: 'managed_a', mode: 'existingChrome', profileDirectory: 'Profile 2' });
  await expect(dialog).toHaveScreenshot('account-browser-existing-profile.png');
  expect(await calls(page, 'begin_account_login')).toHaveLength(0); expect(await calls(page, 'open_account_login_page')).toHaveLength(0);
  await page.evaluate(() => { window.chromeMissing = true; }); await dialog.getByRole('button', { name: 'Read again' }).click(); await expect(dialog.getByRole('button', { name: 'Save browser settings' })).toBeDisabled();
  await mode.selectOption('systemDefault'); await expect(dialog.getByRole('button', { name: 'Save browser settings' })).toBeEnabled();
});

test('official reset success with notification receipt failure stays success and cannot be consumed again', async ({ page }) => {
  await setup(page); await page.evaluate(() => { window.actionMode = 'receipt_failed'; }); const row = page.getByTestId('profile-1');
  await row.getByRole('button', { name: 'Use reset card', exact: true }).click(); await page.getByRole('dialog').getByRole('button', { name: 'I verified the account and card' }).click(); await page.getByRole('dialog').getByRole('button', { name: 'Consume this reset card' }).click();
  await expect(row.getByRole('status')).toContainText('Reset succeeded; the notification record could not be saved.'); await expect(row.getByRole('button', { name: 'Use reset card', exact: true })).toBeDisabled(); expect(await calls(page, 'consume_manual_reset_credit')).toHaveLength(1);
});

test('unreadable Chrome profile metadata keeps the saved route visible and permits an explicit system-default save', async ({ page }) => {
  await setup(page); const row = await managed(page); await page.evaluate(() => { window.browserScanFailed = true; window.browserMode = 'existingChrome'; window.browserProfile = 'Profile 2'; });
  await row.getByRole('button', { name: 'Browser settings', exact: true }).click(); const dialog = page.getByRole('dialog', { name: 'Account browser' });
  await expect(dialog.getByRole('status')).toContainText('Existing Chrome profiles could not be read');
  await expect(dialog.getByRole('combobox', { name: 'Open login page with' })).toHaveValue('existingChrome');
  await expect(dialog.getByRole('button', { name: 'Save browser settings' })).toBeDisabled();
  await dialog.getByRole('combobox', { name: 'Open login page with' }).selectOption('systemDefault');
  await dialog.getByRole('button', { name: 'Save browser settings' }).click();
  await expect(dialog.getByText('Saved for the next time you open the login page.')).toBeVisible();
  expect(await page.evaluate(() => window.actionCalls.filter(c => c.command === 'set_account_browser_settings').at(-1))).toEqual({ command: 'set_account_browser_settings', profileId: 'managed_a', mode: 'systemDefault', profileDirectory: null });
});


test('linked directory i shows full local email before any quota read and offers no managed-only action', async ({ page }) => {
  await setup(page);
  await page.evaluate(() => {
    window.linkedOnly = true; window.linkedForbiddenCalls = [];
    const invoke = window.__TAURI_INTERNALS__.invoke;
    window.__TAURI_INTERNALS__.invoke = (command, args) => {
      if (['read_profile_quota', 'refresh_account_local_details', 'set_account_pro_multiplier', 'get_account_browser_settings', 'set_account_browser_settings', 'begin_manual_reset_review', 'get_account_referral_eligibility'].includes(command)) window.linkedForbiddenCalls.push(command);
      return invoke(command, args);
    };
  });
  await page.getByTestId('profile-1').getByRole('button', { name: 'Account details', exact: true }).click();
  const dialog = page.getByRole('dialog');
  await expect(dialog).toContainText('linked.account@example.invalid');
  await expect(dialog).toContainText('local sign-in record');
  await expect(dialog.getByRole('button', { name: 'Refresh official profile', exact: true })).toHaveCount(0);
  await expect(dialog.getByRole('region', { name: 'Local Pro multiplier' })).toHaveCount(0);
  expect(await page.evaluate(() => window.linkedForbiddenCalls)).toEqual([]);
  await expect(dialog).toHaveScreenshot('linked-local-account-details.png');
  await dialog.getByRole('button', { name: 'Close', exact: true }).click();
  await page.getByTestId('profile-1').getByRole('button', { name: 'Account details', exact: true }).click();
  await expect(page.getByRole('dialog')).toContainText('linked.account@example.invalid');
});
