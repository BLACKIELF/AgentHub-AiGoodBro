import assert from 'node:assert/strict';
import test from 'node:test';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
function fixture(){
 const values=new Map();const storage={getItem:k=>values.get(k)??null,setItem:(k,v)=>values.set(k,v)};let tail=Promise.resolve();
 const context=vm.createContext({exports:{},Intl,TextEncoder,structuredClone,Event,localStorage:storage,window:{dispatchEvent:()=>{}},navigator:{locks:{request:(_key,fn)=>{const result=tail.then(fn);tail=result.catch(()=>{});return result;}}}});
 vm.runInContext(ts.transpileModule(readFileSync(new URL('../src/utils/customStatistics.ts',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,context);
 return {api:context.exports,values,storage};
}
test('manual ten-thousand unit preserves Int64 exactness and truncates fractions without floating rounding',()=>{
 const {api}=fixture();
 for(const [input,want] of [['922337203685477.5807','9223372036854775807'],['900719925474.0993','9007199254740993'],['.5','5000'],['1,25','12500'],['1e2','1000000'],['0.00001','0']])assert.equal(api.tokensFromWan(input),want);
 for(const bad of ['0','-1','NaN','Infinity','922337203685477.5808','1e999','a'])assert.throws(()=>api.tokensFromWan(bad));
 assert.throws(()=>api.customTotal([{tokens:'9223372036854775807'},{tokens:'1'}]));
});
test('corrupt or conflicting saved entries are rejected without rewriting the source',()=>{
 const {api,values}=fixture(),key=api.CUSTOM_STATISTICS_KEY;
 for(const raw of ['bad',JSON.stringify({version:1,revision:0,engine:'custom',entries:[{name:'A',tokens:'1'},{name:'A',tokens:'2'}]}),JSON.stringify({version:1,revision:0,engine:'custom',entries:[{name:'A',tokens:9007199254740993}]})]){values.set(key,raw);assert.throws(()=>api.readCustomStatistics());assert.equal(values.get(key),raw);}
});
test('serialized window mutations re-read the current revision and retain both independent entries',async()=>{
 const {api}=fixture();let release,entered=false;
 const a=api.updateCustomStatistics(v=>({...v,entries:[{name:'A',tokens:'1'}]}),async()=>{entered=true;await new Promise(r=>{release=r;});});
 await Promise.resolve();assert.equal(entered,true);
 const b=api.updateCustomStatistics(v=>({...v,entries:[...v.entries,{name:'B',tokens:'2'}]}));release();await Promise.all([a,b]);
 assert.equal(api.readCustomStatistics().revision,2);assert.equal(api.customTotal(api.readCustomStatistics().entries),'3');
});
test('failed cancellation or storage write never persists a new source mode or overwrites old totals',async()=>{
 const {api,values,storage}=fixture();await api.updateCustomStatistics(v=>({...v,entries:[{name:'A',tokens:'42'}]}));const before=values.get(api.CUSTOM_STATISTICS_KEY);
 await assert.rejects(api.updateCustomStatistics(v=>({...v,engine:'custom'}),async()=>{throw Error('cancel_failed');}));assert.equal(values.get(api.CUSTOM_STATISTICS_KEY),before);
 storage.setItem=()=>{throw Error('denied');};await assert.rejects(api.updateCustomStatistics(v=>({...v,engine:'custom'})),/save_failed/);assert.equal(values.get(api.CUSTOM_STATISTICS_KEY),before);
});
