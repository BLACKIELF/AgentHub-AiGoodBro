import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
const context = vm.createContext({ exports: {} });
vm.runInContext(ts.transpileModule(readFileSync(new URL('../src/utils/claudeSwap.ts', import.meta.url), 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText, context);
const parse = context.exports.parseClaudeSwapCandidates;
const row = { candidate_id: 'a'.repeat(64), label: 'Claude 1', masked_identity: 's***@fixture.invalid', already_imported: false };
test('source candidates project only safe metadata, including explicit duplicate state', () => {
  assert.equal(parse([row])[0].already_imported, false);
  assert.equal(parse([{ ...row, already_imported: true }])[0].already_imported, true);
  const parsed = parse([{ ...row, credential: 'synthetic-secret', path: '/synthetic/source' }])[0];
  assert.equal('credential' in parsed, false); assert.equal('path' in parsed, false);
});
test('invalid or duplicate candidates and unmasked identity cannot become an import action', () => {
  for (const input of [null, [row, row], [{ ...row, candidate_id: '../1' }], [{ ...row, masked_identity: 'source@fixture.invalid' }], [{ ...row, already_imported: 'false' }], Array(65).fill(row)]) assert.throws(() => parse(input));
});
