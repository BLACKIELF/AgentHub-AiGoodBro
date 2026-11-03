import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
const context = vm.createContext({ exports: {}, TextEncoder });
vm.runInContext(ts.transpileModule(readFileSync(new URL('../src/utils/personalWeChatText.ts', import.meta.url), 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText, context);
const { validPersonalText, personalTextBytes, parsePersonalTextReceipt } = context.exports;
test('manual text preserves body semantics and counts the exact Mac source suffix in UTF-8', () => {
  assert.equal(validPersonalText('  hello\r\n\tworld  '), true);
  assert.equal(personalTextBytes('中'), 18);
  assert.equal(validPersonalText('a'.repeat(4081)), true);
  assert.equal(validPersonalText('a'.repeat(4082)), false);
  for (const invalid of ['', ' \r\n\t', 'hi\0there', '中'.repeat(1361)]) assert.equal(validPersonalText(invalid), false);
});
test('only exact request and observed binding receipts are accepted; unknown never equals accepted', () => {
  const id = 'a'.repeat(32), row = { requestId: id, revision: 4, state: 'accepted', checkedAt: 1800000000, failureCode: null };
  assert.equal(parsePersonalTextReceipt(row, id, 4).state, 'accepted');
  assert.equal(parsePersonalTextReceipt({ ...row, state: 'uncertain' }, id, 4).state, 'uncertain');
  for (const bad of [{ ...row, requestId: 'b'.repeat(32) }, { ...row, revision: 3 }, { ...row, state: 'read' }, { ...row, text: 'no body in receipts' }, { ...row, failureCode: 'network_timeout' }]) assert.throws(() => parsePersonalTextReceipt(bad, id, 4));
});
