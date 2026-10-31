import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
function fixture() {
 const values = new Map();
 const storage = { getItem: key => values.get(key) ?? null, setItem: (key,value) => values.set(key,value) };
 const context=vm.createContext({exports:{},Intl,localStorage:storage});
 vm.runInContext(ts.transpileModule(readFileSync(new URL('../src/utils/statisticsTimezone.ts',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,context);
 return {api:context.exports,storage,values};
}
test('saved fixed zone survives a new reader and UTC/system remain distinct',()=>{
 const {api}=fixture();assert.equal(api.readStatisticsTimezone().selection,'system');
 api.saveStatisticsTimezone({selection:'fixed',fixedIdentifier:'America/Los_Angeles'});
 assert.equal(api.resolveStatisticsTimezone(api.readStatisticsTimezone()),'America/Los_Angeles');
 api.saveStatisticsTimezone({selection:'utc',fixedIdentifier:'America/Los_Angeles'});
 assert.equal(api.resolveStatisticsTimezone(api.readStatisticsTimezone()),'UTC');
 assert.equal(api.readStatisticsTimezone().fixedIdentifier,'America/Los_Angeles');
});
test('corrupt saved zone and failed storage writes never become saved success',()=>{
 const {api,storage,values}=fixture();
 for(const raw of ['bad',JSON.stringify({selection:'fixed',fixedIdentifier:'Not/AZone'}),'a'.repeat(257)]){values.set(api.STATISTICS_TIMEZONE_KEY,raw);assert.throws(()=>api.readStatisticsTimezone());}
 values.clear();storage.setItem=()=>{throw Error('denied');};
 assert.throws(()=>api.saveStatisticsTimezone({selection:'utc',fixedIdentifier:'UTC'}),/statistics_timezone_save_failed/);
 assert.equal(values.size,0);
});
test('fixed IANA day boundary and daylight saving follow the selected zone',()=>{
 const {api}=fixture();api.saveStatisticsTimezone({selection:'fixed',fixedIdentifier:'America/Los_Angeles'});
 const timezone=api.resolveStatisticsTimezone(api.readStatisticsTimezone());
 const format=new Intl.DateTimeFormat('en-CA',{timeZone:timezone,year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',hourCycle:'h23'});
 assert.match(format.format(new Date('2026-03-08T07:00:00Z')),/2026-03-07.*23/);
 assert.match(format.format(new Date('2026-03-08T10:00:00Z')),/2026-03-08.*03/);
});
