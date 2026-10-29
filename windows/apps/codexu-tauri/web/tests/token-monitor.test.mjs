import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
const source=readFileSync(new URL('../src/utils/tokenMonitor.ts',import.meta.url),'utf8');
const context=vm.createContext({exports:{},Intl,Date});vm.runInContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,context);
const {parseStatisticsState,visibleStatisticsRate,statisticsChartSnapshot,statisticsHasEvidence,parseChartPreferences,durationText}=context.exports;
const snapshot=JSON.parse(readFileSync(new URL('../../../../token-monitor/tests/fixtures/handler-snapshot.json',import.meta.url),'utf8'));
const state=()=>({phase:'ready',revision:1,contextKey:'a'.repeat(64),timezone:'Asia/Shanghai',sources:[{id:'codex-synthetic',providerId:'codex',label:'Codex synthetic',enabled:true},{id:'claude-synthetic',providerId:'claude',label:'Claude synthetic',enabled:true}],snapshot:structuredClone(snapshot),tokenRate:null,failureCode:null});
const plain=value=>JSON.parse(JSON.stringify(value));
test('the actual pinned multi-source handler projection crosses the frontend DTO unchanged',()=>{
 const parsed=parseStatisticsState(state());assert.equal(parsed.snapshot.payload.aggregate.today.totalTokens,300);assert.equal(parsed.snapshot.payload.history.daily[0].tokens,100);assert.equal(parsed.snapshot.payload.history.daily[0].cost,10);assert.equal(statisticsHasEvidence(parsed.snapshot),true);
});
test('all-time cards retain same-engine TOTAL while chart dates and original history stay unchanged',()=>{
 const original=state().snapshot;assert.equal(original.payload.history.summary.totalTokens,100);const projected=statisticsChartSnapshot(original);
 assert.equal(projected.payload.history.summary.totalTokens,300);assert.equal(original.payload.history.summary.totalTokens,100);assert.deepEqual(plain(projected.payload.history.daily),plain(original.payload.history.daily));assert.equal(projected.authority,undefined);
 original.payload.aggregate.allTime.totalTokens=null;assert.equal(statisticsChartSnapshot(original).payload.history.summary.totalTokens,null);
 original.payload.aggregate.allTime.totalTokens=0;assert.equal(statisticsChartSnapshot(original).payload.history.summary.totalTokens,0);
 original.coverage.entries=[];assert.equal(statisticsHasEvidence(original),false);assert.equal(statisticsChartSnapshot(original).payload.history.summary.totalTokens,null);
});
test('private fields, wrong source, timezone, stale provenance and unknown response fields fail closed',()=>{
 for(const change of [s=>s.snapshot.payload.history.daily[0].prompt='private',s=>s.snapshot.payload.aggregate.today.models['user@example.invalid']=1,s=>s.snapshot.timezone='UTC',s=>s.snapshot.engine.commit='old',s=>s.snapshot.sources[0].id='unregistered',s=>s.snapshot.payload.aggregate.today.totalTokens=-1,s=>s.unknown=true]){const value=state();change(value);assert.throws(()=>parseStatisticsState(value));}
 const value=state();value.snapshot.payload.aggregate.today.models['public/model@route']=0;assert.equal(parseStatisticsState(value).snapshot.payload.aggregate.today.models['public/model@route'],0);
});
test('masked session history preserves missing versus empty and rejects private or invalid rows',()=>{
 const value=state(),period=value.snapshot.payload.aggregate.month,key='opaque-'+'a'.repeat(24);
 period.sessions=null;assert.equal(parseStatisticsState(value).snapshot.payload.aggregate.month.sessions,null);
 period.sessions={};assert.deepEqual(plain(parseStatisticsState(value).snapshot.payload.aggregate.month.sessions),{});
 const row={client:'codex',models:{'public/model':0},totalTokens:0,costUsd:null,lastUsedAt:'2026-09-13T02:00:00Z',turnEnded:false};
 period.sessions={[key]:row};assert.deepEqual(plain(parseStatisticsState(value).snapshot.payload.aggregate.month.sessions[key]),row);
 for(const invalid of [{raw:row},{[key]:{...row,title:'private'}},{[key]:{...row,client:'private@example.invalid'}},{[key]:{...row,turnEnded:'false'}},{[key]:{...row,lastUsedAt:'2026-02-30T02:00:00Z'}},{[key]:{...row,totalTokens:-1}}]){period.sessions=invalid;assert.throws(()=>parseStatisticsState(value));}
});
test('live rate must match the current scope and expire according to the actual sample',()=>{
 const value=state(),now=Date.now();value.tokenRate={mode:'burn',scope:'local',burnPerMinute:0,speedPerSecond:0,sampledAt:now,expiresAt:now+8000,idle:false,revision:1,contextKey:value.contextKey};
 const parsed=parseStatisticsState(value);assert.equal(visibleStatisticsRate(parsed,now).burnPerMinute,0);assert.equal(visibleStatisticsRate(parsed,now+8000),null);assert.equal(visibleStatisticsRate({...parsed,phase:'failed'},now),null);
 value.tokenRate.contextKey='b'.repeat(64);assert.throws(()=>parseStatisticsState(value));value.tokenRate.contextKey=value.contextKey;value.tokenRate.expiresAt=now+9000;assert.throws(()=>parseStatisticsState(value));
});
test('chart preferences preserve existing controls without persisting unknown payloads',()=>{
 const prefs=parseChartPreferences({range:'all',mode:'kline',stackBy:'model',heatmapMetric:'tokens',heatmapStart:'2026-01-01',splitRatio:.4,summaryWidths:{totalTokens:.3,privatePath:.7},extra:'private'});
 assert.deepEqual(plain(prefs),{range:'all',mode:'kline',stackBy:'model',heatmapMetric:'tokens',heatmapStart:'2026-01-01',splitRatio:.4,summaryWidths:{totalTokens:.3}});assert.equal(durationText(7000,'en-GB'),'7 s');assert.equal(durationText(null,'en-GB'),'—');
});
