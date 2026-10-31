export type WorkbenchOutcome='unknown'|'incomplete'|'candidate'|'awaitingAcceptance'|'complete';
export type WorkbenchDecision='none'|'paused'|'cancelled'|'completed';
export interface WorkbenchInventory {threadID:string;project:string;outcome:WorkbenchOutcome;remaining:string[];nextStep:string;artifacts:{title:string;reference:string}[];evidence:string;checkedAtMs:number;sourceTurnID:string|null}
export interface WorkbenchItem {threadId:string;title:string;project:string;updatedAtMs:number|null;archived:boolean;executionState:'recorded';outcome:WorkbenchOutcome;decision:WorkbenchDecision;decisionAtMs:number|null;inventoryIsStale:boolean;needsAttention:boolean;inventory:WorkbenchInventory|null}
export interface WorkbenchSnapshot {scopeId:string;checkedAtMs:number;sourceAvailable:boolean;truncated:boolean;items:WorkbenchItem[]}
const outcomes=['unknown','incomplete','candidate','awaitingAcceptance','complete'],decisions=['none','paused','cancelled','completed'];
function fail():never {throw new Error('workbench_invalid');}
function record(v:unknown):Record<string,unknown>{return v!==null&&typeof v==='object'&&!Array.isArray(v)?v as Record<string,unknown>:fail();}
function string(v:unknown,max:number):string{return typeof v==='string'&&new TextEncoder().encode(v).length<=max&&!/[\u0000-\u0008\u000b-\u001f\u007f]/.test(v)?v:fail();}
function id(v:unknown):string{const s=string(v,36);return /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(s)?s:fail();}
function time(v:unknown):number{return typeof v==='number'&&Number.isSafeInteger(v)&&v>=0&&v<=8_640_000_000_000_000?v:fail();}
function flag(v:unknown):boolean{return typeof v==='boolean'?v:fail();}
function outcome(v:unknown):WorkbenchOutcome{return typeof v==='string'&&outcomes.includes(v)?v as WorkbenchOutcome:fail();}
function decision(v:unknown):WorkbenchDecision{return typeof v==='string'&&decisions.includes(v)?v as WorkbenchDecision:fail();}
export function parseWorkbench(raw:unknown):WorkbenchSnapshot {
 const r=record(raw),scopeId=string(r.scopeId,64);if(!/^[a-f0-9]{64}$/.test(scopeId)||!Array.isArray(r.items)||r.items.length>1000)fail();
 const seen=new Set<string>();
 const items=(r.items as unknown[]).map(raw=>{const v=record(raw),threadId=id(v.threadId);if(seen.has(threadId)||v.executionState!=='recorded')fail();seen.add(threadId);let inventory:WorkbenchInventory|null=null;
  if(v.inventory!==null){const i=record(v.inventory);if(i.threadID!==threadId||!Array.isArray(i.remaining)||i.remaining.length>8||!Array.isArray(i.artifacts)||i.artifacts.length>8)fail();inventory={threadID:threadId,project:string(i.project,160),outcome:outcome(i.outcome),remaining:(i.remaining as unknown[]).map(s=>string(s,800)),nextStep:string(i.nextStep,800),artifacts:(i.artifacts as unknown[]).map(a=>{const x=record(a);return {title:string(x.title,160),reference:string(x.reference,2048)};}),evidence:string(i.evidence,1600),checkedAtMs:time(i.checkedAtMs),sourceTurnID:i.sourceTurnID===null?null:id(i.sourceTurnID)};}
  const result={threadId,title:string(v.title,512),project:string(v.project,160),updatedAtMs:v.updatedAtMs===null?null:time(v.updatedAtMs),archived:flag(v.archived),executionState:'recorded' as const,outcome:outcome(v.outcome),decision:decision(v.decision),decisionAtMs:v.decisionAtMs===null?null:time(v.decisionAtMs),inventoryIsStale:flag(v.inventoryIsStale),needsAttention:flag(v.needsAttention),inventory};
  if(result.outcome==='complete'&&result.decision!=='completed')fail();return result;
 });
 return {scopeId,checkedAtMs:time(r.checkedAtMs),sourceAvailable:flag(r.sourceAvailable),truncated:flag(r.truncated),items};
}
