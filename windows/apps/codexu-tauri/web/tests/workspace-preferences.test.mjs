import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';

const source = readFileSync(new URL('../src/utils/workspacePreferences.ts', import.meta.url), 'utf8');
function preferences(storage) {
  const output = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText;
  const context = vm.createContext({ exports: {}, localStorage: storage });
  vm.runInContext(output, context);
  return context.exports;
}

test('saved display choices reject obsolete values and survive inaccessible storage', () => {
  const read = preferences({ getItem: () => 'obsolete' }).readChoice;
  assert.equal(read('mode', ['professional', 'simple'], 'professional'), 'professional');
  assert.equal(preferences({ getItem: () => 'simple' }).readChoice('mode', ['professional', 'simple'], 'professional'), 'simple');
  assert.equal(preferences({ getItem() { throw Error('denied'); } }).readChoice('size', ['small', 'large'], 'small'), 'small');
});

test('display persistence writes only its chosen key and tolerates a denied write', () => {
  const writes = [];
  preferences({ setItem: (...args) => writes.push(args) }).saveChoice('aigoodbro.workspace.mode', 'simple');
  assert.deepEqual(writes, [['aigoodbro.workspace.mode', 'simple']]);
  assert.doesNotThrow(() => preferences({ setItem() { throw Error('denied'); } }).saveChoice('mode', 'simple'));
});
