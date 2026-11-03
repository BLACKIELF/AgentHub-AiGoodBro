import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';

const context = vm.createContext({ exports: {} });
vm.runInContext(ts.transpileModule(readFileSync(new URL('../src/utils/personalWeChatConversation.ts', import.meta.url), 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText, context);
const { parsePersonalConversationState } = context.exports;
const binding = { expectedScopeId: 'a'.repeat(64), threadId: '123e4567-e89b-42d3-a456-426614174000' };

test('conversation consent state exposes only exact binding metadata and keeps consent separate from state', () => {
  assert.deepEqual(JSON.parse(JSON.stringify(parsePersonalConversationState({ binding: null, revision: 7, enabled: false, phase: 'unbound', needsConfirmation: false }))), {
    binding: null, revision: 7, enabled: false, phase: 'unbound', needsConfirmation: false,
  });
  assert.equal(parsePersonalConversationState({ binding, revision: 8, enabled: true, phase: 'enabled', needsConfirmation: false }).binding.threadId, binding.threadId);
  assert.equal(parsePersonalConversationState({ binding, revision: 8, enabled: false, phase: 'needs_confirmation', needsConfirmation: true }).enabled, false);
  for (const bad of [
    { binding, revision: 8, enabled: true, phase: 'enabled', needsConfirmation: true },
    { binding: null, revision: 8, enabled: true, phase: 'enabled', needsConfirmation: false },
    { binding, revision: 8, enabled: false, phase: 'enabled', needsConfirmation: false },
    { binding: { ...binding, threadId: 'not-a-thread' }, revision: 8, enabled: false, phase: 'disabled', needsConfirmation: false },
    { binding: { ...binding, secret: 'SYNTHETIC_SECRET' }, revision: 8, enabled: false, phase: 'disabled', needsConfirmation: false },
    { binding, revision: 8, enabled: false, phase: 'disabled', needsConfirmation: false, incomingText: 'SYNTHETIC_BODY' },
  ]) assert.throws(() => parsePersonalConversationState(bad));
});

test('conversation UI uses the task workbench selection and only sends binding consent commands', () => {
  const component = readFileSync(new URL('../src/components/PersonalWeChatConversation.tsx', import.meta.url), 'utf8');
  const panel = readFileSync(new URL('../src/components/NotificationChannelsPanel.tsx', import.meta.url), 'utf8');
  assert.match(component, /get_task_workbench/);
  assert.match(component, /bind_personal_wechat_conversation/);
  assert.match(component, /set_personal_wechat_conversation_enabled/);
  assert.match(component, /unbind_personal_wechat_conversation/);
  assert.match(component, /confirmed\s*:\s*true/);
  assert.match(component, /data-testid="personal-wechat-conversation"/);
  assert.match(panel, /<PersonalWeChatConversation/);
  assert.doesNotMatch(component, /invoke\s*\(\s*['"](?:send_personal_wechat_text|start_original_owner_action|confirm_original_owner_action)['"]\s*\)/);
});
