import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
function fixture() {
 let data = new Map(), reject = false, queue = Promise.resolve();
 const storage = {getItem:k=>data.get(k)??null,setItem:(k,v)=>{if(reject)throw Error('denied');data.set(k,v);}};
 const sandbox=vm.createContext({exports:{},localStorage:storage,navigator:{locks:{request:(_k,fn)=>{const next=queue.then(fn);queue=next.catch(()=>{});return next;}}},window:{dispatchEvent(){}},Event:class{}});
 vm.runInContext(ts.transpileModule(readFileSync(new URL('../src/utils/appearancePreferences.ts',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,sandbox);
 return {...sandbox.exports,storage,deny(){reject=true;}};
}
test('defaults match glass 68 depth 32 and only known controls persist',()=>{
 const f=fixture();assert.deepEqual(JSON.parse(JSON.stringify(f.readAppearance())),{version:1,revision:0,systemGlass:true,opacity:68,depth:32,ringMotion:'default'});
 for(const change of [{opacity:-1},{depth:101},{ringMotion:'always'},{icon:'new'},{opacity:NaN}])assert.throws(()=>f.parseAppearance({...f.defaultAppearance(),...change}));
});
test('serialized cross-window patches reread latest and survive reload',async()=>{
 const f=fixture();await Promise.all([f.saveAppearance({opacity:0}),f.saveAppearance({depth:100}),f.saveAppearance({ringMotion:'powerSaving'})]);
 const read=f.readAppearance();assert.equal(read.revision,3);assert.equal(read.opacity,0);assert.equal(read.depth,100);assert.equal(read.ringMotion,'powerSaving');
 await f.saveAppearance({opacity:68});assert.equal(f.readAppearance().depth,100);
});
test('storage failure and corrupt saved bytes never report success or replace old data',async()=>{
 const f=fixture();await f.saveAppearance({opacity:12});const before=f.storage.getItem(f.APPEARANCE_KEY);f.deny();await assert.rejects(f.saveAppearance({depth:99}));assert.equal(f.storage.getItem(f.APPEARANCE_KEY),before);
 const g=fixture();g.storage.setItem(g.APPEARANCE_KEY,'{broken');await assert.rejects(g.saveAppearance({depth:99}));assert.equal(g.storage.getItem(g.APPEARANCE_KEY),'{broken');
});
