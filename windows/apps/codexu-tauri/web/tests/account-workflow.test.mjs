import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import ts from 'typescript';
const source = await readFile(new URL('../src/utils/accountWorkflow.ts', import.meta.url), 'utf8');
const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ES2020 } }).outputText;
const { parseWorkflowState, parseWorkflowModels, acceptWorkflowState, workflowError } = await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
const state = { profile_id: '1', preference: { participating: false, model: null, effort: null, revision: 3 }, phase: 'idle', started_at: null, supported: true };
test('a delayed status response cannot re-enable an account that opted out', () => {
  const incoming = { ...state, phase: 'checking', preference: { ...state.preference, participating: true, revision: 2 } };
  const merged = acceptWorkflowState(state, incoming);
  assert.equal(merged.phase, 'checking');
  assert.equal(merged.preference.participating, false);
  assert.equal(merged.preference.revision, 3);
});
test('reject cross-account, malformed and unbounded workflow data', () => {
  assert.deepEqual(parseWorkflowState(state, '1'), state);
  for (const value of [null, { ...state, profile_id: '2' }, { ...state, preference: { ...state.preference, revision: -1 } }, { ...state, preference: { ...state.preference, model: 'x;evil' } }, { ...state, preference: { ...state.preference, effort: 'high' } }]) {
    assert.throws(() => parseWorkflowState(value, '1'));
  }
});
test('model choices only accept complete advertised reasoning capabilities', () => {
  const row = { id: 'synthetic-model', label: 'Synthetic model', efforts: ['low', 'high'], default_effort: 'high', is_default: true };
  assert.equal(parseWorkflowModels([row])[0].default_effort, 'high');
  for (const value of [[], [row, row], [{ ...row, default_effort: 'ultra' }], [{ ...row, efforts: ['high', 'high'] }], [{ ...row, label: 'private@example.invalid' }]]) assert.throws(() => parseWorkflowModels(value));
  assert.match(workflowError('save_failed', false), /previous setting was retained/);
  assert.doesNotMatch(workflowError('private runtime data', false), /private runtime data/);
});
