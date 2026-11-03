import assert from 'node:assert/strict';
import test from 'node:test';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';

const context=vm.createContext({exports:{},require:()=>({POOL_PROVIDERS:['antigravity','claude','kimi','xai']})});
vm.runInContext(ts.transpileModule(readFileSync(new URL('../src/utils/providerPoolClient.ts',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,context);
const {parsePoolClient}=context.exports;
const base={requestId:'a'.repeat(32),runId:'r'.repeat(43),provider:'antigravity',kind:'agy',model:'',state:'checking',issueCode:null};

test('accepts Agy only for Antigravity with the native default model',()=>{
 assert.deepEqual({...parsePoolClient(base)},base);
 assert.throws(()=>parsePoolClient({...base,model:'gemini-3.1-pro'}));
 assert.throws(()=>parsePoolClient({...base,provider:'claude'}));
});

test('Codex and provider native clients still require a confirmed model',()=>{
 assert.equal(parsePoolClient({...base,kind:'codex',model:'gpt-5'}).model,'gpt-5');
 assert.equal(parsePoolClient({...base,kind:'native',model:'claude-3.7-sonnet'}).model,'claude-3.7-sonnet');
 assert.throws(()=>parsePoolClient({...base,kind:'native',model:''}));
});
