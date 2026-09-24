import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import ts from 'typescript';

const source = await readFile(new URL('../src/utils/localCliQuota.ts', import.meta.url), 'utf8');
const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ES2020 } }).outputText;
const {
  parsePlatforms, parseLocalQuota, localQuotaStateLabel, localQuotaMessage, localIsolationNotice,
} = await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);

const platform = {
  id: 'antigravity', name: 'Antigravity', command: 'antigravity',
  default_directory: 'C:\\Users\\example\\AppData\\Roaming\\Antigravity',
  isolation: 'unsupported', quota_supported: true, desktop: true,
};
const quota = {
  profile_id: '4', platform: 'antigravity', platform_name: 'Antigravity', state: 'available',
  checked_at: 1_700_000_000_000, masked_identity: 'u***@example.invalid', plan_label: 'Pro',
  windows: [{ id: 'model-0', label: 'Gemini', used_percent: 25, remaining_percent: 75, resets_at: null }],
  balance: null, balance_currency: null, source_label: 'Antigravity · official desktop quota',
  message_code: null, period_resets_at: null,
};

test('a platform catalogue is validated and de-duplicated', () => {
  assert.equal(parsePlatforms([platform])[0].id, 'antigravity');
  for (const value of [null, [], [platform, platform], [{ ...platform, id: 'invented' }],
    [{ ...platform, isolation: 'magic' }], [{ ...platform, name: '' }],
    [{ ...platform, quota_supported: 'yes' }]]) {
    assert.throws(() => parsePlatforms(value));
  }
});

test('a local quota result must belong to its own row and platform', () => {
  assert.equal(parseLocalQuota(quota, '4').state, 'available');
  for (const value of [null, { ...quota, profile_id: '9' }, { ...quota, platform: 'codex' },
    { ...quota, platform: 'invented' }, { ...quota, state: 'great' },
    { ...quota, checked_at: Number.NaN }, { ...quota, masked_identity: 'user@example.invalid' },
    { ...quota, source_label: '' }, { ...quota, balance: -1 }, { ...quota, balance_currency: 'USD$' },
    { ...quota, windows: [{ id: 'a', label: 'a', used_percent: 20, remaining_percent: 20, resets_at: null }] },
    { ...quota, windows: [{ id: 'a', label: 'a', used_percent: 25, remaining_percent: 75, resets_at: null },
      { id: 'a', label: 'b', used_percent: 25, remaining_percent: 75, resets_at: null }] },
    { ...quota, windows: [{ id: 'a', label: 'a', used_percent: 101, remaining_percent: -1, resets_at: null }] }]) {
    assert.throws(() => parseLocalQuota(value, '4'));
  }
});

test('history and unsupported results stay explicitly non-successful', () => {
  const cached = {
    ...quota, state: 'unavailable', masked_identity: null, plan_label: null,
    source_label: 'Antigravity · cached IDE quota',
    message_code: 'local_cli_antigravity_cached_quota', checked_at: 1_699_000_000_000,
  };
  assert.equal(parseLocalQuota(cached, '4').state, 'unavailable');
  const unsupported = { ...quota, state: 'unsupported', windows: [], message_code: 'local_cli_quota_not_exposed_by_platform' };
  assert.equal(parseLocalQuota(unsupported, '4').windows.length, 0);
  assert.equal(parseLocalQuota({ ...quota, state: 'needs_login', windows: [] }, '4').state, 'needs_login');
});

test('every state and known message has honest wording', () => {
  for (const state of ['available', 'unavailable', 'needs_login', 'unsupported', 'rate_limited']) {
    assert.ok(localQuotaStateLabel(state, 'en').length > 0);
    assert.ok(localQuotaStateLabel(state, 'zh-Hans').length > 0);
  }
  assert.match(localQuotaMessage('local_cli_antigravity_cached_quota', 'en'), /not the current quota/);
  assert.match(localQuotaMessage('local_cli_quota_not_exposed_by_platform', 'en'), /stays unknown/);
  assert.match(localQuotaMessage('local_cli_antigravity_account_changed', 'en'), /discarded/);
  assert.equal(localQuotaMessage(null, 'en'), null);
  // An unknown code is never echoed back to the interface.
  assert.doesNotMatch(localQuotaMessage('local_cli_private_runtime_detail', 'en'), /private runtime detail/);
});

test('isolation wording never promises isolation a platform cannot provide', () => {
  assert.match(localIsolationNotice('managed', 'en'), /never rewritten/);
  assert.match(localIsolationNotice('default_only', 'en'), /only supports its default directory/);
  assert.match(localIsolationNotice('unsupported', 'en'), /cannot be isolated on Windows/);
  assert.ok(localIsolationNotice('unsupported', 'zh-Hans').length > 0);
});
