'use strict';
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process'),assert=require('node:assert/strict');
const base=process.argv[2],shared=process.argv[3],standalone=process.argv[4];
const root=fs.mkdtempSync(path.join(base,'scanner-fixture-')), codex=path.join(root,'managed');
fs.mkdirSync(path.join(codex,'sessions/2026/09/13'),{recursive:true});
const file=path.join(codex,'sessions/2026/09/13/rollout-synthetic.jsonl');
fs.writeFileSync(file,[{type:'session_meta',timestamp:'2026-09-13T01:00:00Z',payload:{id:'synthetic-session',cwd:'/synthetic/project',originator:'codex_cli_rs',cli_version:'0.1'}},{type:'turn_context',timestamp:'2026-09-13T01:00:00Z',payload:{model:'gpt-5'}},{type:'event_msg',timestamp:'2026-09-13T01:00:01Z',payload:{type:'token_count',info:{total_token_usage:{input_tokens:100,cached_input_tokens:20,output_tokens:50,reasoning_output_tokens:10,total_tokens:150},last_token_usage:{input_tokens:100,cached_input_tokens:20,output_tokens:50,reasoning_output_tokens:10,total_tokens:150},model_context_window:100000}}}].map(v=>JSON.stringify(v)).join('\n')+'\n');
const request={schemaVersion:1,requestId:'scanner-fixture',operation:'collectUsage',now:'2026-09-13T02:00:00.000Z',timezone:'UTC',sources:[{id:'codex-fixture',providerId:'codex',kind:'managedAccount',pathRole:'codexHome',canonicalPath:codex,accountId:'card-fixture',authority:'upstream',enabled:true}],options:{timeoutMs:20000,allowPriceNetwork:false,allowSelfSync:false,allowCredentialRefresh:false,allowProviderNetwork:false,includeLiveCodexAccount:false},customSources:[]};
const output=[];
for (const [kind,app] of [['shared',shared],['standalone',standalone]]) {
 const engine=path.join(app,'Contents/Resources/TokenMonitorEngine');
 const runtime=kind==='shared'?path.join(app,'Contents/Helpers/AiGoodBro Token Core.app/Contents/MacOS/AiGoodBro Token Core'):path.join(engine,'runtime/node');
 const home=path.join(root,kind); fs.mkdirSync(home); const cache=path.join(home,'cache');fs.mkdirSync(cache);
 const env={HOME:home,TMPDIR:home,PATH:'',TZ:'UTC',...(kind==='shared'?{ELECTRON_RUN_AS_NODE:'1'}:{})};
 const p=cp.spawnSync(runtime,[path.join(engine,'bridge.cjs')],{cwd:home,env,input:JSON.stringify({...request,cacheDirectory:cache}),encoding:'utf8',timeout:30000});
 assert.equal(p.status,0,p.stderr); const result=JSON.parse(p.stdout); assert.equal(result.status,'ok');
 assert.ok(result.payload.aggregate.allTime.totalTokens>0,'actual scanner must see nonzero synthetic log');
 output.push({mode:kind,result});
}
assert.deepEqual(output[0].result.payload,output[1].result.payload);
assert.deepEqual(output[0].result.sources,output[1].result.sources);
fs.rmSync(root,{recursive:true,force:true});
console.log(JSON.stringify({status:'passed',checks:['actual-native-tokscale-log-scan','usage-and-history-shared-standalone-payload-parity','isolated-homes','no-provider-network'],totalTokens:output[0].result.payload.aggregate.allTime.totalTokens}));
