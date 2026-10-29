export const TOKEN_MONITOR_COMMIT = '5d2db368d8313415763860d594de00e46a663418';
export interface StatisticsSource { id:string; providerId:string; label:string; enabled:boolean }
export interface StatisticsSession { client?:string;models?:Record<string,number|null>;totalTokens?:number|null;costUsd?:number|null;lastUsedAt?:string;startedAt?:string;turnEnded?:boolean;sessionKind?:string;archived?:boolean;deleted?:boolean;sourceDeleted?:boolean }
export interface StatisticsPeriod { totalTokens:number|null;costUsd:number|null;timedTokens:number|null;timedOutputTokens:number|null;timedDurationMs:number|null;clients:Record<string,number|null>;models:Record<string,number|null>;capabilities:{throughput:boolean};sessions?:Record<string,StatisticsSession>|null }
export interface StatisticsHistory {daily:Array<{date:string;tokens:number|null;cost:number|null;activeTimeMs:number|null;perClient:Record<string,unknown>;perModel:Record<string,unknown>}>;monthly:unknown[];summary:{totalTokens:number|null;totalCost:number|null;activeTimeMs:number|null;activeDays:number|null;messages:number|null;favoriteModel:string|null}}
export interface StatisticsSnapshot {schemaVersion:1;requestId:string;engine:{repository:string;commit:string;version:string};collectedAt:string;timezone:string;status:'ok'|'partial'|'error';sources:Array<{id:string;providerId:string;status:string;coverage:string}>;coverage:{cost:string;entries:unknown[];days:unknown[]};errors:unknown[];historyCollectedAt:number|null;payload:{aggregate:{today:StatisticsPeriod|null;month:StatisticsPeriod|null;allTime:StatisticsPeriod|null};history:StatisticsHistory|null;costEstimates:unknown}}
export interface StatisticsRate {mode:'burn';scope:'local';burnPerMinute:number;speedPerSecond:number;sampledAt:number;expiresAt:number;idle:boolean;revision:number;contextKey:string}
export interface StatisticsState {phase:'idle'|'loading'|'ready'|'partial'|'failed'|'stopped';revision:number;contextKey:string|null;sources:StatisticsSource[];timezone:string|null;snapshot:StatisticsSnapshot|null;tokenRate:StatisticsRate|null;failureCode:string|null}
export interface ChartPreferences {heatmapStart?:string;heatmapMetric?:'cost'|'tokens';range?:string;mode?:'bars'|'kline';stackBy?:'client'|'model';height?:number;splitRatio?:number;summaryWidths?:Record<string,number>}
const fail=():never=>{throw Error('statistics_invalid_response');};
const object=(value:unknown):Record<string,unknown>=>value!==null&&typeof value==='object'&&!Array.isArray(value)?value as Record<string,unknown>:fail();
const keys=(value:Record<string,unknown>,allowed:string[])=>{if(Object.keys(value).some(key=>!allowed.includes(key)))fail();};
const finite=(value:unknown):number=>typeof value==='number'&&Number.isFinite(value)&&value>=0&&value<=Number.MAX_SAFE_INTEGER?value:fail();
const count=(value:unknown):number=>Number.isSafeInteger(finite(value))?value as number:fail();
const nullable=(value:unknown):number|null=>value===null?null:finite(value);
const string=(value:unknown,max=128):string=>typeof value==='string'&&value.length<=max&&!/[\x00-\x1f]/.test(value)?value:fail();
const id=(value:unknown):string=>/^[a-zA-Z0-9._:-]{1,128}$/.test(string(value))?value as string:fail();
const context=(value:unknown):string|null=>value===null?null:/^[a-f0-9]{64}$/.test(string(value))?value as string:fail();
const bool=(value:unknown):boolean=>typeof value==='boolean'?value:fail();
function privacy(value:unknown,key='',depth=0):void{
  if(depth>20||['auth','authorization','credential','credentials','token','access_token','refresh_token','api_key','password','cookie','email','prompt','response','content','text','transcript','path','cwd','directory','homedir','hostname','title'].includes(key.toLowerCase()))fail();
  if(typeof value==='number'){finite(value);return;}
  if(typeof value==='string'){string(value,256);if(/[\\\x00]|:\/\/|^[a-z]:[/\\]|^\/|[\w.+-]+@[\w.-]+\.[a-z]{2,}|Bearer |sk-[a-z0-9]{8}/i.test(value))fail();return;}
  if(Array.isArray(value)){if(value.length>100000)fail();value.forEach(item=>privacy(item,key,depth+1));return;}
  if(value&&typeof value==='object'){const entries=Object.entries(value);if(entries.length>10000)fail();entries.forEach(([name,item])=>{privacy(name,'',depth+1);privacy(item,name,depth+1);});}
}
function parsePeriod(raw:unknown):StatisticsPeriod|null{
  if(raw===null)return null;const value=object(raw);
  const numeric=['totalTokens','costUsd','unpricedTokens','inputTokens','outputTokens','cacheReadTokens','cacheWriteTokens','unclassifiedTokens','timedTokens','timedOutputTokens','timedDurationMs'];
  const maps=['clients','clientCosts','clientCacheReads','clientCacheWrites','clientOutputs','clientUnclassifiedTokens','models','modelCosts','modelCacheReads','modelCacheWrites','modelOutputs','modelUnclassifiedTokens'];
  keys(value,[...numeric,...maps,'capabilities','modelThroughput','sessions']);numeric.forEach(key=>nullable(value[key]));
  maps.forEach(key=>Object.entries(object(value[key])).forEach(([name,number])=>{string(name);nullable(number);}));
  const capability=object(value.capabilities);keys(capability,['throughput']);bool(capability.throughput);
  if(value.modelThroughput!==null)Object.values(object(value.modelThroughput)).forEach(item=>{const metrics=object(item);keys(metrics,['timedTokens','timedOutputTokens','timedDurationMs']);Object.values(metrics).forEach(nullable);});
  if(value.sessions!=null){
    const rows=Object.entries(object(value.sessions));if(rows.length>10000)fail();
    for(const [id,rawRow] of rows){
      if(!/^opaque-[a-f0-9]{24}$/.test(id))fail();const row=object(rawRow);
      keys(row,['client','models','totalTokens','costUsd','lastUsedAt','startedAt','turnEnded','sessionKind','archived','deleted','sourceDeleted']);
      for(const name of ['client','sessionKind'])if(name in row&&!string(row[name]).length)fail();
      for(const name of ['totalTokens','costUsd'])if(name in row)nullable(row[name]);
      for(const name of ['turnEnded','archived','deleted','sourceDeleted'])if(name in row)bool(row[name]);
      for(const name of ['lastUsedAt','startedAt'])if(name in row){
        const time=string(row[name],64);
        if(!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(time)||!Number.isFinite(Date.parse(time)))fail();
        const [year,month,day]=time.slice(0,10).split('-').map(Number),calendar=new Date(0);calendar.setUTCFullYear(year,month-1,day);
        if(calendar.getUTCFullYear()!==year||calendar.getUTCMonth()!==month-1||calendar.getUTCDate()!==day)fail();
      }
      if('models'in row){const models=Object.entries(object(row.models));if(models.length>10000)fail();for(const [name,amount] of models){if(!string(name).length)fail();nullable(amount);}}
    }
  }
  return value as unknown as StatisticsPeriod;
}
export function parseStatisticsState(raw:unknown):StatisticsState{
  const value=object(raw);keys(value,['phase','revision','contextKey','sources','timezone','snapshot','tokenRate','failureCode']);
  if(!['idle','loading','ready','partial','failed','stopped'].includes(string(value.phase)))fail();count(value.revision);context(value.contextKey);
  if(value.timezone!==null){const timezone=string(value.timezone,64);try{new Intl.DateTimeFormat('en',{timeZone:timezone});}catch{fail();}}
  if(!Array.isArray(value.sources)||value.sources.length>256)fail();
  const sourceIds=new Set<string>();for(const rawSource of value.sources as unknown[]){const source=object(rawSource);keys(source,['id','providerId','label','enabled']);const sourceId=id(source.id);if(sourceIds.has(sourceId))fail();sourceIds.add(sourceId);id(source.providerId);string(source.label);bool(source.enabled);privacy(source.label);}
  if(value.failureCode!==null&&!/^[a-z_]{1,64}$/.test(string(value.failureCode)))fail();
  if(value.snapshot!==null){const snapshot=object(value.snapshot);keys(snapshot,['schemaVersion','requestId','engine','collectedAt','timezone','status','sources','coverage','errors','historyCollectedAt','payload']);
    const engine=object(snapshot.engine);keys(engine,['repository','commit','version']);if(snapshot.schemaVersion!==1||engine.repository!=='Javis603/token-monitor'||engine.commit!==TOKEN_MONITOR_COMMIT||engine.version!=='0.68.0'||snapshot.timezone!==value.timezone||!['ok','partial','error'].includes(string(snapshot.status))||!Number.isFinite(Date.parse(string(snapshot.collectedAt))))fail();
    id(snapshot.requestId);nullable(snapshot.historyCollectedAt);privacy(snapshot);
    const payload=object(snapshot.payload);keys(payload,['aggregate','history','costEstimates']);const aggregate=object(payload.aggregate);keys(aggregate,['today','month','allTime']);['today','month','allTime'].forEach(key=>parsePeriod(aggregate[key]));
    if(!Array.isArray(snapshot.sources)||snapshot.sources.length>256||!Array.isArray(snapshot.errors))fail();
    for(const returned of snapshot.sources as unknown[]){const source=object(returned);if(!sourceIds.has(id(source.id)))fail();}
    const coverage=object(snapshot.coverage);if(!['known','partial','unknown'].includes(string(coverage.cost))||!Array.isArray(coverage.entries)||!Array.isArray(coverage.days))fail();
    if(payload.history!==null){const history=object(payload.history);keys(history,['daily','monthly','summary']);for(const kind of ['daily','monthly']){if(!Array.isArray(history[kind])||(history[kind] as unknown[]).length>10000)fail();}
      const dates=new Set();for(const row of history.daily as unknown[]){const day=object(row);const date=string(day.date);if(!/^\d{4}-\d{2}-\d{2}$/.test(date)||!Number.isFinite(Date.parse(date+'T00:00:00Z'))||dates.has(date))fail();dates.add(date);nullable(day.tokens);nullable(day.cost);object(day.perClient);object(day.perModel);}object(history.summary);
    }
  }
  if(value.tokenRate!==null){const rate=object(value.tokenRate);keys(rate,['mode','scope','burnPerMinute','speedPerSecond','sampledAt','expiresAt','idle','revision','contextKey']);
    if(rate.mode!=='burn'||rate.scope!=='local'||context(rate.contextKey)!==value.contextKey)fail();finite(rate.burnPerMinute);finite(rate.speedPerSecond);count(rate.sampledAt);count(rate.expiresAt);bool(rate.idle);count(rate.revision);
    const lifetime=(rate.expiresAt as number)-(rate.sampledAt as number);if(lifetime<=0||lifetime>(rate.idle?180000:8000))fail();
  }
  return value as unknown as StatisticsState;
}
export function visibleStatisticsRate(state:StatisticsState|null|undefined,now=Date.now()):StatisticsRate|null{
  const rate=state?.tokenRate;return rate&&state?.phase!=='failed'&&state?.phase!=='stopped'&&rate.expiresAt>now&&rate.sampledAt<=now+1000&&rate.contextKey===state.contextKey?rate:null;
}
export function parseChartPreferences(raw:unknown):ChartPreferences{
  const value=object(raw),result:ChartPreferences={};
  if(typeof value.heatmapStart==='string'&&/^(?:|\d{4}-\d{2}-\d{2})$/.test(value.heatmapStart))result.heatmapStart=value.heatmapStart;
  if(value.heatmapMetric==='tokens'||value.heatmapMetric==='cost')result.heatmapMetric=value.heatmapMetric;
  if(['7','30','90','365','all'].includes(String(value.range)))result.range=String(value.range);
  if(value.mode==='bars'||value.mode==='kline')result.mode=value.mode;
  if(value.stackBy==='client'||value.stackBy==='model')result.stackBy=value.stackBy;
  if(typeof value.height==='number'&&Number.isSafeInteger(value.height)&&value.height>=260&&value.height<=900)result.height=value.height;
  if(typeof value.splitRatio==='number'&&Number.isFinite(value.splitRatio)&&value.splitRatio>=.28&&value.splitRatio<=.72)result.splitRatio=value.splitRatio;
  if(value.summaryWidths&&typeof value.summaryWidths==='object')result.summaryWidths=Object.fromEntries(Object.entries(value.summaryWidths).filter(([key,width])=>['totalTokens','totalCost','activeDays','currentStreak','activeTimeMs','peakDayTokens','favoriteModel','messages'].includes(key)&&typeof width==='number'&&Number.isFinite(width)&&width>=.02&&width<=1)) as Record<string,number>;
  return result;
}
export function statisticsFailure(raw:unknown):string{const value=raw&&typeof raw==='object'&&'message'in raw&&typeof raw.message==='string'?raw.message:String(raw);return /^[a-z_]{1,64}$/.test(value)?value:'statistics_unavailable';}
export function durationText(milliseconds:number|null|undefined,locale:string):string{
  if(milliseconds==null||!Number.isFinite(milliseconds)||milliseconds<0)return '—';
  const seconds=milliseconds/1000;if(seconds<60)return new Intl.NumberFormat(locale,{maximumFractionDigits:1}).format(seconds)+' s';
  const minutes=seconds/60;if(minutes<60)return new Intl.NumberFormat(locale,{maximumFractionDigits:1}).format(minutes)+' min';
  return new Intl.NumberFormat(locale,{maximumFractionDigits:1}).format(minutes/60)+' h';
}
export function statisticsHasEvidence(snapshot:StatisticsSnapshot):boolean{
  return snapshot.sources.some(source=>source.status==='ok'&&snapshot.coverage.entries.some(raw=>{const entry=raw as {sourceId?:unknown;providerId?:unknown;metric?:unknown;status?:unknown};return entry.sourceId===source.id&&entry.providerId===source.providerId&&entry.metric==='tokens'&&entry.status==='known';}));
}
/** Same-engine TOTAL owns the total cards; the graph retains its actual range. */
export function statisticsChartSnapshot(snapshot:StatisticsSnapshot):StatisticsSnapshot{
  const history=snapshot.payload.history;if(!history)return snapshot;
  const total=statisticsHasEvidence(snapshot)?snapshot.payload.aggregate.allTime:null;
  return {...snapshot,payload:{...snapshot.payload,history:{...history,summary:{...history.summary,totalTokens:total?.totalTokens??null,totalCost:total?.costUsd??null}}}};
}
