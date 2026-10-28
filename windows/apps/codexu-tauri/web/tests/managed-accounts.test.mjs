import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';

const source = readFileSync(new URL('../src/utils/managedAccounts.ts', import.meta.url), 'utf8');
const context = vm.createContext({ exports: {} });
vm.runInContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText, context);
const { parseManagedAccounts, parseLoginAttempt, parsePreparedSwitch, parseAccountOperation } = context.exports;
const account = { id: 'managed_a', label: 'Synthetic Managed', platform: 'codex', storage_kind: 'managed', login_state: 'verified', active_state: 'unknown', masked_identity: 's***@synthetic.invalid', can_login: true, can_switch: false, switch_block_reason: 'occupancy_unknown', revision: 1, recovery_required: false };
const attempt = { attempt_id: 'synthetic_attempt', account_id: 'managed_a', phase: 'waiting', verification_url: 'https://auth.openai.com/codex/device', user_code: 'SYNTHETIC-CODE', error_code: null };

test('managed accounts cannot reuse linked metadata or turn selected into an active identity', () => {
  assert.equal(parseManagedAccounts([account])[0].active_state, 'unknown');
  for (const invalid of [{ ...account, storage_kind: 'linked' }, { ...account, active_state: 'selected' }, { ...account, revision: -1 }, { ...account, can_switch: 'true' }, { ...account, masked_identity: 'unmasked@synthetic.invalid' }]) assert.throws(() => parseManagedAccounts([invalid]));
  assert.throws(() => parseManagedAccounts([account, account]));
});

test('only the exact current official device URL and matching account/attempt may expose a pairing prompt', () => {
  assert.equal(parseLoginAttempt(attempt, 'managed_a', 'synthetic_attempt').user_code, 'SYNTHETIC-CODE');
  for (const verification_url of ['https://auth.openai.com.evil.invalid/codex/device', 'https://auth.openai.com/codex/device?next=other', 'https://user@auth.openai.com/codex/device', 'javascript:alert(1)']) assert.throws(() => parseLoginAttempt({ ...attempt, verification_url }));
  assert.throws(() => parseLoginAttempt(attempt, 'another_account'));
  assert.throws(() => parseLoginAttempt(attempt, 'managed_a', 'old_attempt'));
  assert.throws(() => parseLoginAttempt({ ...attempt, phase: 'cancelled' }));
  assert.throws(() => parseLoginAttempt({ ...attempt, phase: 'verified', verification_url: null, user_code: null, error_code: 'identity_mismatch' }));
});

test('switch readiness, expiry fields and one-account result receipts stay distinct from cancellation or failure', () => {
  const ready = { account_id: 'managed_a', phase: 'ready', ticket: 'synthetic_ticket_0123456789', reason_code: null, expires_at: 2000000000 };
  assert.equal(parsePreparedSwitch(ready, 'managed_a').phase, 'ready');
  for (const invalid of [{ ...ready, ticket: null }, { ...ready, expires_at: null }, { ...ready, phase: 'blocked' }, { ...ready, account_id: 'linked_only' }, { ...ready, reason_code: 'identity_mismatch' }]) assert.throws(() => parsePreparedSwitch(invalid, 'managed_a'));
  assert.equal(parseAccountOperation({ account_id: 'managed_a', phase: 'cancelled', error_code: null }, 'managed_a', 'cancelled').phase, 'cancelled');
  assert.throws(() => parseAccountOperation({ account_id: 'managed_a', phase: 'cancelled', error_code: null }, 'managed_a', 'committed'));
  assert.throws(() => parseAccountOperation({ account_id: 'managed_a', phase: 'committed', error_code: 'identity_mismatch' }, 'managed_a', 'committed'));
});
