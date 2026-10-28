import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
const source = readFileSync(new URL('../src/utils/claudeSubscriptions.ts', import.meta.url), 'utf8');
const context = vm.createContext({ exports: {} });
vm.runInContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText, context);
const { parseClaudeLogin, parseClaudeQuota, parseClaudePreparedSwitch } = context.exports;
const quota = { state: 'available', fetched_at: 1800000000000, masked_identity: 's***@synthetic.invalid', identity_fingerprint: 'a'.repeat(64), plan_label: 'max', windows: [{ id: 'five_hour', label: '5-hour', used_percent: 25, resets_at: 1800003600000 }], balance: null, balance_currency: null, source_label: 'Anthropic OAuth usage', message_code: null, period_resets_at: null, server_retry_at: null };

test('Claude returns only actual windows, with used percentage and millisecond reset times preserved', () => {
  assert.equal(parseClaudeQuota(quota).windows[0].used_percent, 25);
  assert.equal(parseClaudeQuota(quota).windows[0].resets_at, 1800003600000);
  assert.equal(parseClaudeQuota({ ...quota, windows: [] }).windows.length, 0);
  assert.equal(parseClaudeQuota({ ...quota, state: 'rate_limited', windows: [], server_retry_at: 1800000120 }).server_retry_at, 1800000120);
  for (const invalid of [{ ...quota, balance: 0 }, { ...quota, windows: [{ ...quota.windows[0], used_percent: 101 }] }, { ...quota, windows: [...quota.windows, ...quota.windows] }, { ...quota, masked_identity: 'unmasked@synthetic.invalid' }]) assert.throws(() => parseClaudeQuota(invalid));
});

test('official login has no browser token/URL projection, and verified is not saved', () => {
  const login = { attempt_id: 'synthetic_attempt', phase: 'verified', error_code: null };
  assert.equal(parseClaudeLogin(login).phase, 'verified');
  assert.equal(parseClaudeLogin({ ...login, phase: 'saved' }).phase, 'saved');
  assert.throws(() => parseClaudeLogin(login, 'old_attempt'));
  assert.throws(() => parseClaudeLogin({ ...login, error_code: 'claude_identity_mismatch' }));
  assert.equal(Object.hasOwn(parseClaudeLogin({ ...login, oauth_url: 'https://synthetic.invalid/private' }), 'oauth_url'), false);
});

test('already-current official proof has no ticket; a ready switch needs a valid single-use ticket and expiry', () => {
  const current = { account_id: 'claude_a', phase: 'already_current', ticket: null, expires_at: null, reason_code: 'already_current' };
  assert.equal(parseClaudePreparedSwitch(current, 'claude_a').phase, 'already_current');
  assert.throws(() => parseClaudePreparedSwitch({ ...current, ticket: 'synthetic_ticket' }, 'claude_a'));
  const ready = { account_id: 'claude_a', phase: 'ready', ticket: 'synthetic_ticket', expires_at: 1800000030, reason_code: null };
  assert.equal(parseClaudePreparedSwitch(ready, 'claude_a').ticket, 'synthetic_ticket');
  assert.throws(() => parseClaudePreparedSwitch(ready, 'linked_only'));
  assert.throws(() => parseClaudePreparedSwitch({ ...ready, expires_at: null }, 'claude_a'));
});
