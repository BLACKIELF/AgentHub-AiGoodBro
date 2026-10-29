import { statisticsHasEvidence, type StatisticsSnapshot, type StatisticsState } from './tokenMonitor';
import { canonicalCompactProvider } from './compactUi';
export type CompactPeriod='today'|'month'|'allTime';
export type CompactMetric='tokens'|'cost';
export interface CompactBreakdown {id:string;value:number}
export interface CompactDay {date:string;tokens:number|null;cost:number|null}
const number=(value:unknown):number|null=>typeof value==='number'&&Number.isFinite(value)&&value>=0?value:null;
const object=(value:unknown):Record<string,unknown>=>value!==null&&typeof value==='object'&&!Array.isArray(value)?value as Record<string,unknown>:{};
export function compactCalendarDate(timezone:string|null|undefined,now=Date.now()):string|null{
 if(!timezone||!Number.isFinite(now))return null;
 try{const parts=new Intl.DateTimeFormat('en-CA',{timeZone:timezone,year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(now);return ['year','month','day'].map(type=>parts.find(part=>part.type===type)?.value).join('-');}catch{return null;}
}
export function compactMetricKnown(snapshot:StatisticsSnapshot,metric:CompactMetric,date?:string):boolean{
 if(snapshot.status==='error'||!statisticsHasEvidence(snapshot)||metric==='cost'&&snapshot.coverage.cost==='unknown')return false;
 if(!date)return true;
 return snapshot.coverage.entries.some(raw=>{const entry=object(raw);return entry.date===date&&entry.metric===metric&&['known','partial'].includes(String(entry.status))&&snapshot.sources.some(source=>source.id===entry.sourceId&&source.providerId===entry.providerId&&source.status==='ok');});
}
/** Mac presentation reads the same engine aggregate; TOTAL is never a limited history sum. */
export function compactPeriodValue(state:StatisticsState|null|undefined,period:CompactPeriod,metric:CompactMetric,now=Date.now()):number|null{
 const snapshot=state?.snapshot;if(!snapshot)return null;
 const date=period==='today'?compactCalendarDate(state.timezone,now):undefined;
 if(date===null||!compactMetricKnown(snapshot,metric,date))return null;
 return number(snapshot.payload.aggregate[period]?.[metric==='tokens'?'totalTokens':'costUsd']);
}
export function compactBreakdown(state:StatisticsState|null|undefined,period:CompactPeriod,metric:CompactMetric,byModel:boolean,now=Date.now()):CompactBreakdown[]{
 const snapshot=state?.snapshot,date=period==='today'?compactCalendarDate(state?.timezone,now):undefined;if(!snapshot||date===null||!compactMetricKnown(snapshot,metric,date))return [];
 const aggregate=object(snapshot.payload.aggregate[period]);
 const key=metric==='tokens'?(byModel?'models':'clients'):(byModel?'modelCosts':'clientCosts');
 return Object.entries(object(aggregate[key])).flatMap(([id,raw])=>{const value=number(raw);return value===null?[]:[{id,value}];}).sort((a,b)=>b.value-a.value||a.id.localeCompare(b.id,undefined,{sensitivity:'base'}));
}
/** Missing days remain unknown; rendering cannot turn absent records into zero. */
export function compactHistoryDays(state:StatisticsState|null|undefined,count:number,now=Date.now()):CompactDay[]{
 const today=compactCalendarDate(state?.timezone,now),snapshot=state?.snapshot;if(!today||!snapshot?.payload.history)return [];
 const length=Number.isFinite(count)?Math.max(1,Math.min(365,Math.trunc(count))):180;
 const end=Date.parse(today+'T00:00:00Z'),rows=new Map(snapshot.payload.history.daily.map(row=>[row.date,row]));
 return Array.from({length},(_,index)=>{const date=new Date(end-(length-index-1)*86400000).toISOString().slice(0,10),row=rows.get(date);return {date,tokens:row&&compactMetricKnown(snapshot,'tokens',date)?number(row.tokens):null,cost:row&&compactMetricKnown(snapshot,'cost',date)?number(row.cost):null};});
}
export function compactSnapshotStale(state:StatisticsState|null|undefined):boolean{return !!state?.snapshot&&!['ready','partial'].includes(state.phase);}

export function compactProviderForClient(client:string):string {
 const id=client.trim().toLowerCase();
 return ({droid:'factory',zcode:'zai',qodercn:'qoder',dsh:'deepseek'} as Record<string,string>)[id]??canonicalCompactProvider(id);
}
/** Account-specific cards must never inherit provider-wide usage. */
export function compactProviderUsage(state:StatisticsState|null|undefined,provider:string,period:'today'|'month',metric:CompactMetric,now=Date.now()):number|null {
 const snapshot=state?.snapshot,date=period==='today'?compactCalendarDate(state?.timezone,now):undefined;
 if(!snapshot||date===null||!compactMetricKnown(snapshot,metric,date))return null;
 const rows=Object.entries(object(object(snapshot.payload.aggregate[period])[metric==='tokens'?'clients':'clientCosts']))
  .filter(([client])=>compactProviderForClient(client)===canonicalCompactProvider(provider));
 if(!rows.length||rows.some(([,value])=>number(value)===null))return null;
 return number(rows.reduce((sum,[,value])=>sum+(value as number),0));
}
export interface CompactSession {
 id:string;clientId:string;modelId:string|null;tokens:number|null;cost:number|null;
 lastUsedAt:number;turnEnded:boolean;runningAtCollection:boolean;
}
export interface CompactSessionIndex { known:boolean;collectedAt:number|null;rows:CompactSession[] }
/** Exactly the same collected Engine session map as Mac; no transcript or live-task reader. */
export function compactSessions(state:StatisticsState|null|undefined):CompactSessionIndex {
 const snapshot=state?.snapshot,month=object(snapshot?.payload.aggregate.month).sessions,today=object(snapshot?.payload.aggregate.today).sessions;
 const known=month!==null&&typeof month==='object'&&!Array.isArray(month);
 const collectedAt=snapshot&&Number.isFinite(Date.parse(snapshot.collectedAt))?Date.parse(snapshot.collectedAt):null;
 const source={...object(today),...object(month)};
 const rows:CompactSession[]=Object.entries(source).flatMap(([id,raw])=>{
  const value=object(raw),date=value.lastUsedAt??value.startedAt;
  if(!/^opaque-[a-f0-9]{24}$/.test(id)||value.sessionKind==='background-review'||typeof value.client!=='string'||!value.client||typeof date!=='string'||!Number.isFinite(Date.parse(date)))return [];
  const lastUsedAt=Date.parse(date),models=Object.entries(object(value.models)).filter((entry):entry is [string,number]=>number(entry[1])!==null).sort((a,b)=>b[1]-a[1]||a[0].localeCompare(b[0]));
  const archived=[value.archived,value.deleted,value.sourceDeleted].includes(true),turnEnded=value.turnEnded===true;
  return [{id,clientId:value.client,modelId:models[0]?.[0]??null,tokens:number(value.totalTokens),cost:number(value.costUsd),lastUsedAt,turnEnded,
   runningAtCollection:!archived&&!turnEnded&&collectedAt!==null&&lastUsedAt<=collectedAt&&collectedAt-lastUsedAt<=600_000}];
 }).sort((a,b)=>b.lastUsedAt-a.lastUsedAt||a.id.localeCompare(b.id));
 return {known,collectedAt,rows};
}
export function compactRecentSessions(index:CompactSessionIndex,{provider,runningOnly=false,maximum=6}:{provider?:string;runningOnly?:boolean;maximum?:number}={}):CompactSession[]{
 return index.rows.filter(row=>(!provider||compactProviderForClient(row.clientId)===canonicalCompactProvider(provider))&&(!runningOnly||row.runningAtCollection)).slice(0,maximum);
}
