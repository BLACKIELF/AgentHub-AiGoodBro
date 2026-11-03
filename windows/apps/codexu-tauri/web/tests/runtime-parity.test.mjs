import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
function load(name){const context={exports:{},Date,Set,Number,Object};vm.runInNewContext(ts.transpileModule(readFileSync(new URL(`../src/utils/${name}.ts`,import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,context);return context.exports;}
const live=load('liveTasks'),cli=load('localCliActions'),auto=load('automaticSwitch');
test('live tasks preserve runtime versus turn state, reject private IDs and expire without claiming idle',()=>{
 const row={phase:'live',issueCode:null,observedAtMs:1000,tasks:[{ordinal:1,state:'running',turnState:'completed',startedAtMs:1,completedAtMs:900}]};
 assert.equal(live.parseLiveTasks(row).tasks[0].state,'running');assert.equal(live.parseLiveTasks(row).tasks[0].turnState,'completed');
 assert.equal(live.currentLiveTasks(row,46000).phase,'live');assert.equal(live.currentLiveTasks(row,46001).phase,'unavailable');assert.equal(live.currentLiveTasks(row,999).tasks.length,0);
 for(const bad of [{...row,path:'private'},{...row,tasks:[{...row.tasks[0],taskId:'private'}]},{...row,phase:'unavailable'},{...row,tasks:[row.tasks[0],row.tasks[0]]}])assert.throws(()=>live.parseLiveTasks(bad));
});
test('launcher and dependency receipts must match their platform, phase and bound opaque task',()=>{
 assert.equal(cli.parseLocalCliActions({platform:'grok',phase:'idle',can_open:true,can_login:true,reason_code:null},'grok').can_open,true);
 assert.throws(()=>cli.parseLocalCliActions({platform:'grok',phase:'idle',can_open:true,can_login:false,reason_code:'provider_runtime_unverified'},'grok'));
 const task={task_id:'a'.repeat(32),platform:'grok',phase:'prepared',prompt:'Inspect official sources\nhttps://example.invalid/'};
 assert.equal(cli.parseDependencyTask(task,'grok').task_id,task.task_id);assert.throws(()=>cli.parseDependencyTask(task,'kimi'));
 const result={task_id:task.task_id,platform:'grok',phase:'running',verification_state:'unknown',version:null,reason_code:null};
 assert.equal(cli.parseDependencyStatus(result,'grok',task.task_id).phase,'running');assert.throws(()=>cli.parseDependencyStatus({...result,phase:'verified'},'grok',task.task_id));assert.throws(()=>cli.parseDependencyStatus(result,'grok','b'.repeat(32)));
 assert.equal(cli.parseDependencyStatus({...result,phase:'verified',verification_state:'verified',version:'1.2.3'},'grok',task.task_id).version,'1.2.3');
});
test('automatic preferences and status do not invent private restore or task capabilities',()=>{
 const preferences={enabled:false,fiveHourRemainingThreshold:5,sevenDayRemainingThreshold:10,excludedProfileIds:[],pauseAtOnePercent:false,resumeAfterSwitch:true};
 assert.equal(auto.parseAutomaticPreferences(preferences).enabled,false);assert.throws(()=>auto.parseAutomaticPreferences({...preferences,fiveHourRemainingThreshold:0}));assert.throws(()=>auto.parseAutomaticPreferences({...preferences,excludedProfileIds:['private@example.invalid']}));
 const status={phase:'unsupported',issueCode:'automatic_switch_live_tasks_unavailable',sourceAccountId:null,targetAccountId:null,lastAttemptAtMs:null,lastSucceededAtMs:null,nextEligibleAtMs:null,liveTasksAvailable:false,pauseResumeAvailable:false,resumeAfterSwitchAvailable:false,lastSwitchRestored:null};
 assert.equal(auto.parseAutomaticStatus(status).resumeAfterSwitchAvailable,false);assert.throws(()=>auto.parseAutomaticStatus({...status,privatePath:'x'}));
});
