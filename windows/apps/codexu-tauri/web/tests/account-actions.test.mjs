import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
const source = readFileSync(new URL('../src/utils/accountActions.ts', import.meta.url), 'utf8');
const context = vm.createContext({ exports: {}, TextEncoder });
vm.runInContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText, context);
const { parseResetReview, parseResetResult, parseReferralReview, parseReferralBatch, parseReferralPage, parseRecipients, parseLocalEmail, parseLocalDetails, warmupFailureText, parseResetReceipt } = context.exports;
const review = { profileId: 'synthetic_a', reviewId: 'review_a', checkedAtMs: 1000, expiresAtMs: 2000, availableCount: 1, cardExpiresAtMs: null };
test('reset review binds account and deadline; unknown outcome stays distinct', () => {
  assert.equal(parseResetReview(review, review.profileId).availableCount, 1);
  for (const patch of [{ profileId: 'wrong' }, { expiresAtMs: 0 }, { availableCount: -1 }, { remaining7dPercent: 101 }, { cardExpiresAtMs: 'later' }]) assert.throws(() => parseResetReview({ ...review, ...patch }, review.profileId));
  assert.equal(parseResetResult({ profileId: 'synthetic_a', outcome: 'unknown' }, 'synthetic_a'), 'unknown');
  assert.throws(() => parseResetResult({ profileId: 'synthetic_a', outcome: 'success' }, 'synthetic_a'));
});
test('recipient parser mirrors Mac separators, deduplication and capacity-independent validation', () => {
  const parsed = parseRecipients('one@example.invalid；ONE@example.invalid, two@example.invalid\ninvalid');
  assert.deepEqual([...parsed.emails], ['one@example.invalid', 'two@example.invalid']);
  assert.equal(parsed.invalid, 1); assert.equal(parsed.duplicates, 1); assert.equal(parsed.tooLong, false);
  assert.equal(parseRecipients('a'.repeat(4097)).tooLong, true);
});
test('invitation result must account for every recipient exactly once', () => {
  const result = { profileId: 'synthetic_a', sent: [0], failed: [1], uncertain: [2] };
  assert.equal(parseReferralBatch(result, 'synthetic_a', 3).uncertain[0], 2);
  for (const patch of [{ sent: [0, 1] }, { uncertain: [] }, { uncertain: [3] }, { failed: [-1] }, { profileId: 'other' }]) assert.throws(() => parseReferralBatch({ ...result, ...patch }, 'synthetic_a', 3));
});
test('official offer and tracker reject malformed evidence without creating rewards', () => {
  const offer = { ...review, shouldShow: true, title: null, description: null, rules: [], creditAmount: null, invitationCapacity: 5, remainingSendCapacity: 5, remainingRewardCapacity: 5, requiresExplicitConfirmation: true };
  assert.equal(parseReferralReview(offer, 'synthetic_a').creditAmount, null);
  assert.throws(() => parseReferralReview({ ...offer, invitationCapacity: 6 }, 'synthetic_a'));
  const item = { id: 'record_1', maskedEmail: 'o***@example.invalid', status: 'redeemed' };
  assert.equal(parseReferralPage({ profileId: 'synthetic_a', items: [item], cursor: null }, 'synthetic_a').items[0].status, 'redeemed');
  assert.throws(() => parseReferralPage({ profileId: 'synthetic_a', items: [item, item], cursor: null }, 'synthetic_a'));
});
test('full local email requires the expected account and a bounded address', () => {
  assert.equal(parseLocalEmail({ profileId: 'synthetic_a', email: 'one@example.invalid' }, 'synthetic_a'), 'one@example.invalid');
  assert.throws(() => parseLocalEmail({ profileId: 'other', email: 'one@example.invalid' }, 'synthetic_a'));
  assert.throws(() => parseLocalEmail({ profileId: 'synthetic_a', email: 'bad\n@example.invalid' }, 'synthetic_a'));
});

test('local details distinguish display identity, invite validation, exact multiplier and quota evidence', () => {
  const value = { profileId: 'synthetic_a', email: 'legacy_identity@internal', proTierMultiplier: 25, displayedProTierMultiplier: 25, resetCardExpiresAtMs: Array(1024).fill(1000), quotaWindows: [{ kind: 'seven_day', usedPercent: 80, resetsAtMs: 2000 }], warmupHistory: [{ atMs: 1000, succeeded: false, failureCode: 'maintenance_cancelled', phase: 'failed' }] };
  assert.equal(parseLocalDetails(value, 'synthetic_a').email, 'legacy_identity@internal');
  assert.equal(parseRecipients('legacy_identity@internal').invalid, 1);
  assert.equal(parseLocalDetails(value, 'synthetic_a').resetCardExpiresAtMs.length, 1024);
  for (const patch of [{ proTierMultiplier: 7 }, { displayedProTierMultiplier: '25' }, { email: 'a'.repeat(321) }, { resetCardExpiresAtMs: Array(1025).fill(1000) }, { quotaWindows: [{ kind: 'seven_day', usedPercent: 101, resetsAtMs: 2000 }] }, { warmupHistory: [{ atMs: 1000, succeeded: 'yes' }] }]) assert.throws(() => parseLocalDetails({ ...value, ...patch }, 'synthetic_a'));
  assert.match(warmupFailureText('maintenance_cancelled', false), /cancelled/);
  assert.doesNotMatch(warmupFailureText('private payload', false), /private payload/);
});

test('official reset success can carry notification storage failure without turning into an unknown outcome', () => {
  assert.equal(parseResetReceipt({ profileId: 'a', outcome: 'reset', issueCode: 'notification_receipt_save_failed' }, 'a').outcome, 'reset');
  assert.throws(() => parseResetReceipt({ profileId: 'a', outcome: 'unknown', issueCode: 'notification_receipt_save_failed' }, 'a'));
  assert.throws(() => parseResetReceipt({ profileId: 'a', outcome: 'reset', issueCode: 'sent_successfully' }, 'a'));
});
