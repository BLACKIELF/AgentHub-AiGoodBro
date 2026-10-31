import assert from 'node:assert/strict';
import test from 'node:test';
import {readFileSync} from 'node:fs';
import ts from 'typescript';
const code=ts.transpileModule(readFileSync(new URL('../src/utils/taskHub.ts',import.meta.url),'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.ES2020}}).outputText;
const {parseHubView,hubTerminal}=await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
const task={id:'task-1',version:1,agent:'codex',project:'workspace',state:'awaiting_approval',actionHash:'a'.repeat(64),canResume:false,createdAt:'2026-10-30T01:00:00Z',updatedAt:'2026-10-30T01:00:00Z',approvalExpiresAt:'2026-10-30T01:05:00Z',approvalExpired:false};
const view={supported:true,connected:true,workspace:'Synthetic',profileId:'1',overview:{tasks:[task],accounts:['account-1'],projects:['workspace'],agents:['codex']}};
test('Hub view rejects malformed identities, hashes, versions and state without inventing success',()=>{assert.equal(parseHubView(view).overview.tasks[0].id,'task-1');for(const patch of [{id:'../secret'},{version:Number.MAX_SAFE_INTEGER+1},{state:'ready'},{approvalExpired:null},{actionHash:'bad'},{approvalExpiresAt:'invalid'}])assert.throws(()=>parseHubView({...view,overview:{...view.overview,tasks:[{...task,...patch}]}}));assert.throws(()=>parseHubView({...view,overview:{...view.overview,tasks:[task,task]}}));assert.throws(()=>parseHubView({...view,connected:false}));assert.equal(hubTerminal('uncertain'),false);assert.equal(hubTerminal('cancelled'),true);});
