'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { createRuntime, publicSnapshot, period, history, sessions } = require('../service.cjs');
const root = path.resolve(__dirname, '../../..');
const sourceEngine = path.join(root, 'Companion/TokenMonitorEngine');
const pinned = {repository:'Javis603/token-monitor',commit:'5d2db368d8313415763860d594de00e46a663418',version:'0.68.0'};
const contextKey = 'a'.repeat(64);
const response = (n=0) => ({schemaVersion:1,requestId:'test',engine:pinned,collectedAt:'2026-10-29T00:00:00.000Z',timezone:'Asia/Shanghai',status:'ok',sources:[],coverage:{entries:[],days:[],cost:'unknown'},errors:[],payload:{aggregate:{today:{totalTokens:100+n,timedTokens:100+n,timedOutputTokens:50+n/2,timedDurationMs:1000+n*10,capabilities:{throughput:true},models:{'public/model@route':100+n}},month:null,allTime:null},history:{daily:[],monthly:[],summary:{}}}});
const source = {id:'system-history',providerId:'codex',kind:'managedAccount',pathRole:'codexHome',authority:'upstream',enabled:true,canonicalPath:'/synthetic'};
const configure = key => ({command:'configure',contextKey:key||contextKey,request:{operation:'collectUsage',sources:[source]}});
function harness(handler) {
  let clock=Date.parse('2026-10-29T00:00:00Z'), clean=true, stopped=0;
  const events=[], timers=[];
  const runtime=createRuntime(sourceEngine,{now:()=>clock,emit:value=>events.push(value),timer:(fn,delay)=>{const timer={fn,delay,active:true};timers.push(timer);return timer;},clear:timer=>{if(timer)timer.active=false;},loader:{loadUsage:()=>({collector:{bridgeRunGraph:async()=>({})}})},handleRequest:handler,createScope:()=>({start(){return this;},checkAborted(){},dispose(){},cancel(){stopped++;},waitForCleanup:async()=>clean})});
  return {runtime,events,timers,setClock:value=>clock=value,advance:ms=>clock+=ms,setCleanup:value=>clean=value,stopped:()=>stopped};
}
async function settle(runtime){await runtime.collect();await new Promise(resolve=>setImmediate(resolve));}

test('projection preserves true zero, unknown and model identity; strips private session detail',()=>{
  const value=response();value.payload.aggregate.today.totalTokens=0;value.payload.aggregate.today.sessions={['opaque-'+'a'.repeat(24)]:{client:'codex',totalTokens:0,prompt:'must not leave host',title:'must not leave host'}};
  const projected=publicSnapshot(value,123);
  assert.equal(projected.payload.aggregate.today.totalTokens,0);
  assert.equal(projected.payload.aggregate.today.costUsd,null);
  assert.equal(projected.payload.aggregate.today.models['public/model@route'],100);
  assert.deepEqual(projected.payload.aggregate.today.sessions,{['opaque-'+'a'.repeat(24)]:{client:'codex',totalTokens:0}});
  assert.equal(projected.authority,undefined);
  assert.equal(JSON.stringify(projected).includes('must not leave host'),false);
});
test('session history distinguishes unknown and empty and retains only valid masked evidence',()=>{
  assert.equal(sessions(undefined),null);assert.equal(sessions(null),null);assert.deepEqual(sessions({}),{});
  const key='opaque-'+'b'.repeat(24),row={client:'codex',models:{'public/model':0},totalTokens:0,costUsd:null,lastUsedAt:'2026-09-13T02:00:00Z',startedAt:'2026-09-12T21:00:00+08:00',turnEnded:false,archived:true,sessionKind:'background-review'};
  assert.deepEqual(sessions({[key]:row}),{[key]:row});
  for(const value of [{raw:row},{[key]:[]},{[key]:{client:'private@example.invalid'}},{[key]:{turnEnded:'false'}},{[key]:{lastUsedAt:'2026-02-30T00:00:00Z'}},{[key]:{totalTokens:-1}},{[key]:{models:{'/private/model':1}}}])assert.throws(()=>sessions(value));
});
test('projection rejects private identities, nonfinite counters, excess history and wrong provenance',()=>{
  for(const key of ['private@example.invalid','C:\\Users\\private','/home/private','https://invalid.test','sk-abcdefghijk'])assert.throws(()=>period({models:{[key]:1}}));
  assert.throws(()=>period({totalTokens:NaN}));
  assert.throws(()=>history({daily:Array(10001).fill({date:'2026-01-01'})}));
  const wrong=response();wrong.engine={...pinned,commit:'old'};assert.throws(()=>publicSnapshot(wrong,null));
});
test('live tracker anchors initial totals then uses actual timed deltas; inactivity and midnight clear correctly',async()=>{
  let n=0;const h=harness(async()=>response(n));await h.runtime.configure(configure());await settle(h.runtime);assert.equal(h.runtime.sample(),null);
  n=100;h.advance(2000);await settle(h.runtime);
  assert.equal(h.runtime.sample().burnPerMinute,6000);assert.equal(h.runtime.sample().speedPerSecond,50);
  h.advance(9000);assert.equal(h.runtime.sample().idle,true);h.advance(180000);assert.equal(h.runtime.sample(),null);
  n=1;await settle(h.runtime);assert.equal(h.runtime.sample(),null);await h.runtime.stop();
});
test('a reconfigured scope never inherits a historical throughput sample',async()=>{
  let n=0;const h=harness(async()=>response(n));await h.runtime.configure(configure());await settle(h.runtime);n=100;h.advance(1000);await settle(h.runtime);assert.ok(h.runtime.sample());
  await h.runtime.configure(configure('b'.repeat(64)));await settle(h.runtime);assert.equal(h.runtime.sample(),null);assert.ok(h.events.at(-1).contextKey==='b'.repeat(64));await h.runtime.stop();
});
test('cancel suppresses a late collection response and no timer restarts collection',async()=>{
  let resolve;const h=harness(()=>new Promise(done=>resolve=done));await h.runtime.configure(configure());const stopping=h.runtime.stop();resolve(response());await stopping;
  assert.equal(h.events.length,0);assert.equal(h.stopped(),1);assert.equal(h.timers.some(timer=>timer.active),false);
});
test('collection errors invalidate rate while keeping fixed error codes',async()=>{
  let fail=false;const h=harness(async()=>{if(fail)throw Error('private detail');return response();});await h.runtime.configure(configure());await settle(h.runtime);fail=true;await settle(h.runtime);
  assert.equal(h.events.at(-1).event,'failed');assert.equal(h.events.at(-1).code,'collection_failed');assert.equal(JSON.stringify(h.events).includes('private detail'),false);assert.equal(h.runtime.sample(),null);await h.runtime.stop();
});
test('unconfirmed descendant cleanup fails closed and schedules no next scan',async()=>{
  const h=harness(async()=>response());h.setCleanup(false);await h.runtime.configure(configure());await settle(h.runtime);
  assert.equal(h.events.at(-1).code,'cleanup_unconfirmed');assert.equal(h.timers.some(timer=>timer.active),false);await assert.rejects(h.runtime.stop());await assert.rejects(h.runtime.configure(configure('b'.repeat(64))));
});
test('history graph work is reused for 60 seconds, refreshed explicitly and reset by scope',async()=>{
  let calls=0;const events=[],timers=[];let clock=Date.parse('2026-10-29T00:00:00Z');
  const runtime=createRuntime(sourceEngine,{now:()=>clock,emit:e=>events.push(e),timer:(fn,delay)=>{const t={fn,delay};timers.push(t);return t;},clear:()=>{},loader:{loadUsage:()=>({collector:{bridgeRunGraph:async()=>({id:++calls})}})},handleRequest:async(request,deps)=>{await deps.runGraph({clients:'codex',homeDir:'isolated',since:'2026-01-01'});return response();}});
  await runtime.configure(configure());await settle(runtime);assert.equal(calls,1);const first=events.at(-1).snapshot.historyCollectedAt;
  clock+=2000;await settle(runtime);assert.equal(calls,1);assert.equal(events.at(-1).snapshot.historyCollectedAt,first);
  clock+=60000;await settle(runtime);assert.equal(calls,2);await runtime.collect(true);assert.equal(calls,3);
  await runtime.configure(configure('b'.repeat(64)));await settle(runtime);assert.equal(calls,4);await runtime.stop();
});

test('actual pinned handler preserves two providers and independent history/cost with synthetic runners', {skip:!process.env.TOKEN_MONITOR_TEST_ENGINE}, async()=>{
  const engine=path.resolve(process.env.TOKEN_MONITOR_TEST_ENGINE);
  const loader=require(path.join(engine,'lib/upstream/loader.cjs'));
  const handler=require(path.join(engine,'lib/handler.cjs')).handleRequest;
  const fixture=require(path.join(root,'tests/token-monitor-engine/cases/helpers/fixtures.cjs'));
  const home=fs.mkdtempSync(path.join(os.tmpdir(),'tm-win-service-'));
  const logs=path.join(home,'logs'),codex=path.join(home,'codex');fs.mkdirSync(logs);fs.mkdirSync(codex);
  const events=[],calls=[];let clock=Date.parse('2026-09-13T02:00:00Z');
  const upstream=loader.loadUsage();
  const runtime=createRuntime(engine,{now:()=>clock,emit:value=>events.push(value),timer:()=>({}),clear:()=>{},loader:{...loader,loadUsage:()=>({...upstream,collector:{...upstream.collector,bridgeRunGraph:async input=>{calls.push(['graph',input.clients]);return fixture.historyGraph('2026-09-13',input.clients==='codex'?30:70,{client:input.clients,cost:input.clients==='codex'?3:7});}}})},handleRequest:(request,deps)=>handler(request,{...deps,runTokscale:async input=>{calls.push(['usage',input.clients]);return fixture.usageSnapshot(input.clients==='codex'?100:200,{client:input.clients,cost:input.clients==='codex'?1:2});}})});
  try{
    await runtime.configure({contextKey,request:fixture.baseRequest(home,{sources:[fixture.source({id:'codex-synthetic',providerId:'codex',kind:'managedAccount',pathRole:'codexHome',canonicalPath:codex}),fixture.source({id:'claude-synthetic',providerId:'claude',canonicalPath:logs})]})});await settle(runtime);
    const event=events.find(e=>e.event==='snapshot');assert.ok(event,JSON.stringify(events));const out=event.snapshot;
    assert.equal(out.status,'ok');assert.equal(out.payload.aggregate.today.totalTokens,300);assert.equal(out.payload.aggregate.today.clients.codex,100);assert.equal(out.payload.aggregate.today.clients.claude,200);
    assert.equal(out.payload.history.daily[0].tokens,100);assert.equal(out.payload.history.daily[0].perClient.codex.tokens,30);assert.equal(out.payload.history.daily[0].perClient.claude.tokens,70);assert.equal(out.payload.history.daily[0].cost,10);
    assert.ok(calls.every(([,id])=>['codex','claude'].includes(id)));const graphCalls=calls.filter(([kind])=>kind==='graph').length;assert.equal(graphCalls,2);
    clock+=2000;await settle(runtime);assert.equal(calls.filter(([kind])=>kind==='graph').length,graphCalls);
    assert.equal(out.authority,undefined);assert.equal(JSON.stringify(out).includes(home),false);
    if(process.env.TOKEN_MONITOR_FIXTURE_OUTPUT)fs.writeFileSync(process.env.TOKEN_MONITOR_FIXTURE_OUTPUT,JSON.stringify(out,null,2)+'\n');
  }finally{await runtime.stop();fs.rmSync(home,{recursive:true,force:true});}
});

test('module resolution cannot execute an added or outside module',()=>{
  const {constrainModules}=require('../service.cjs');const home=fs.mkdtempSync(path.join(os.tmpdir(),'tm-module-guard-'));
  const allowed=path.join(home,'allowed.cjs'),extra=path.join(home,'extra.cjs');fs.writeFileSync(allowed,'module.exports=71;');fs.writeFileSync(extra,'module.exports=99;');
  const restore=constrainModules(home,{'allowed.cjs':'verified-before-host-start'});
  try{assert.equal(require(allowed),71);assert.throws(()=>require(extra),/unverified_module/);assert.equal(require('node:fs'),fs);}
  finally{restore();fs.rmSync(home,{recursive:true,force:true});}
});

test('actual bundled scanner feeds history and timed delta tracker from synthetic Codex source', {skip:!process.env.TOKEN_MONITOR_TEST_NATIVE}, async()=>{
  const engine=path.resolve(process.env.TOKEN_MONITOR_TEST_ENGINE||'');
  const binary=path.join(engine,'vendor/node_modules/@tokscale/cli-'+({darwin:'darwin-arm64',win32:'win32-x64-msvc'}[process.platform]||'unsupported')+'/bin/tokscale'+(process.platform==='win32'?'.exe':''));
  const expected=process.env.TOKEN_MONITOR_TEST_SCANNER_SHA256;
  assert.match(expected||'',/^[a-f0-9]{64}$/);assert.equal(require('node:crypto').createHash('sha256').update(fs.readFileSync(binary)).digest('hex'),expected);
  const home=fs.mkdtempSync(path.join(os.tmpdir(),'tm-real-scanner-fixture-')),codex=path.join(home,'codex');fs.mkdirSync(path.join(codex,'sessions'),{recursive:true});
  const day=new Date().toISOString().slice(0,10);let clock=Date.parse(day+'T12:00:00Z');
  const file=path.join(codex,'sessions/synthetic.jsonl');const initial=fs.readFileSync(path.join(__dirname,'fixtures/codex-duration.jsonl'),'utf8').replaceAll('2040-01-01',day);fs.writeFileSync(file,initial);
  const events=[];const runtime=createRuntime(engine,{now:()=>clock,emit:e=>events.push(e),timer:()=>({}),clear:()=>{}});
  try{
    await runtime.configure({contextKey,request:{schemaVersion:1,requestId:'synthetic-native',operation:'collectUsage',timezone:'UTC',cacheDirectory:path.join(home,'cache'),sources:[{...source,canonicalPath:codex}]}});await settle(runtime);
    const first=events.find(e=>e.event==='snapshot');assert.ok(first,JSON.stringify(events));assert.equal(first.snapshot.payload.aggregate.allTime.totalTokens,160);assert.equal(first.snapshot.payload.aggregate.today.timedDurationMs,7000);assert.equal(runtime.sample(),null);
    const usage={input_tokens:150,cached_input_tokens:30,output_tokens:22,reasoning_output_tokens:10};
    fs.appendFileSync(file,JSON.stringify({timestamp:day+'T00:00:25Z',type:'turn_context',payload:{model:'codex-test-model'}})+'\n'+JSON.stringify({timestamp:day+'T00:00:27Z',type:'event_msg',payload:{type:'token_count',info:{total_token_usage:usage,last_token_usage:{input_tokens:10,cached_input_tokens:0,output_tokens:2,reasoning_output_tokens:0}}}})+'\n');
    clock+=2000;await settle(runtime);const second=events.filter(e=>e.event==='snapshot').at(-1);assert.equal(second.snapshot.payload.aggregate.today.totalTokens,172);assert.equal(second.snapshot.payload.aggregate.today.timedDurationMs,9000);
    assert.equal(runtime.sample().burnPerMinute,360);assert.equal(runtime.sample().speedPerSecond,1);assert.equal(fs.readFileSync(file,'utf8').startsWith(initial),true);assert.equal(JSON.stringify(second).includes(home),false);
  }finally{await runtime.stop();fs.rmSync(home,{recursive:true,force:true});}
});
