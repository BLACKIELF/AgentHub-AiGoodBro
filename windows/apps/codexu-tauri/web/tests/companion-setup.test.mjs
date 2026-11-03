import assert from 'node:assert/strict';
import test from 'node:test';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
const context = vm.createContext({exports: {}});
vm.runInContext(ts.transpileModule(readFileSync(new URL('../src/utils/companionSetup.ts', import.meta.url), 'utf8'), {
  compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020},
}).outputText, context);
const {parseCompanionSetup: parse} = context.exports;
const file = {path: 'SKILL.md', status: 'same'};
const ready = {state: 'ready', issueCode: null, files: [file], planId: null, backupAvailable: false};
const plan = 'a'.repeat(64);

test('Companion snapshot validates actual native states and opaque confirmation plans', () => {
  assert.equal(parse(ready).state, 'ready');
  for (const state of ['missing', 'outdated']) {
    const snapshot = {...ready, state, files: [{...file, status: 'missing'}], planId: plan};
    assert.equal(parse(snapshot).planId, plan);
    assert.equal(parse({...snapshot, planId: null}).planId, null);
  }
  assert.equal(parse({...ready, state: 'unavailable', issueCode: 'companion_confirmation_required', planId: plan}).planId, plan);
  for (const state of ['conflict', 'unavailable']) assert.equal(parse({...ready, state, issueCode: 'companion_recovery_required', files: []}).state, state);
});
test('Companion parser rejects false readiness and contradictory or private fields', () => {
  for (const value of [
    {...ready, files: []}, {...ready, files: [{...file, status: 'missing'}]},
    {...ready, planId: plan}, {...ready, issueCode: 'companion_cleanup_unconfirmed'},
    {...ready, state: 'missing'}, {...ready, state: 'unavailable'},
    {...ready, state: 'conflict', issueCode: 'companion_recovery_required', planId: plan},
    {...ready, state: 'unavailable', issueCode: 'companion_confirmation_required', planId: plan, files: []},
    {...ready, state: 'unavailable', issueCode: 'companion_scope_required', planId: plan},
    {...ready, backupAvailable: 'true'}, {...ready, path: 'C:\\private'},
    {...ready, token: 'synthetic'}, {...ready, issueCode: 'private path is not a code'},
  ]) assert.throws(() => parse(value));
});
test('Companion parser accepts only bounded fixed display paths with no duplicates or legacy authority', () => {
  for (const path of ['使用说明.md', 'bin/next-dispatch.py', 'config/runtime-paths.json', 'references/luna-presets.md']) {
    assert.equal(parse({...ready, files: [{path, status: 'same'}]}).files[0].path, path);
  }
  for (const path of ['../SKILL.md', '/private/SKILL.md', 'C:\\private\\auth.json', 'config/dispatch-policy-v1.json', 'config/dispatch-codes-v1.json', 'auth.json']) {
    assert.throws(() => parse({...ready, files: [{path, status: 'same'}]}));
  }
  assert.throws(() => parse({...ready, files: [file, file]}));
  assert.throws(() => parse({...ready, files: [{...file, sha256: 'a'.repeat(64)}]}));
  for (const planId of ['', 'A'.repeat(64), 'a'.repeat(63), 2]) assert.throws(() => parse({...ready, state: 'outdated', files: [{...file, status: 'changed'}], planId}));
});
