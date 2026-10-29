export const compactSurfaces=['popover','edge_peek','edge_rail','edge_card'] as const;
export type CompactSurface=typeof compactSurfaces[number];
export type CompactShortcutStatus='unregistered'|'registered'|'occupied'|'failed'|'unavailable';
export type CompactAction='reveal'|'collapse'|'pin'|'unpin'|'close'|'select_item'|'open_workspace'|'open_accounts'|'open_running_tasks'|'open_settings'|'open_proxy'|'drag'|'page_next'|'page_previous';
export type DockMetric='today'|'week'|'last7'|'last30'|'month'|'allTime'|'liveRate'|'sessions';
export interface DockItem{id:string;type:'limit'|'stat'|'proxy';providerId:string|null;accountId:string|null;metric:DockMetric|null;hiddenAccountIds:string[];showUsage:boolean;showSessions:boolean;accountMode:'active'|'lowest';runningOnly:boolean;groupBy:'none'|'client';cellDetail:'clients'|'rate'}
export interface CompactPreferences{enabled:boolean;mode:'autoHide'|'always';side:'left'|'right';offset:number;displayId:string|null;items:DockItem[]|null;hapticEnabled:boolean;warnColors:boolean;quotaStyle:'ring'|'fish';refreshEnabled:boolean;runningIndicatorEnabled:boolean;size:'small'|'medium'|'large'|'custom';customScale:number}
export interface CompactQuotaWindow{id:string;label:string;usedPercent:number|null;resetsAt:number|null}
export interface CompactAccount{id:string;providerId:string;label:string;loggedIn:boolean;active:boolean|null;observedAt:number|null;available:boolean;reasonCode:string|null;planType:string|null;windows:CompactQuotaWindow[];creditsUsd:number|null;creditPoints:string|null;resetCards:number|null}
export interface CompactState{revision:number;windows:Array<{surface:CompactSurface;visible:boolean;pinned:boolean;collapsed:boolean}>;selectedItemId:string|null;resolvedItems:DockItem[];pageIndex:number;pageCount:number;displayAvailable:boolean;side:'left'|'right';scale:number;viewportHeight:number;preferences:CompactPreferences;displays:Array<{id:string;label:string;isPrimary:boolean;available:boolean}>;failureCode:string|null;shortcutStatus:CompactShortcutStatus;cachedProjection:{accounts:CompactAccount[];proxy:{phase:string;egressState:string|null;activeRequests:number|null;observedAt:number|null}|null;sessionCount:number|null}}
export function dockStat(metric:DockMetric):DockItem{return {id:`stat:${metric}`,type:'stat',providerId:null,accountId:null,metric,hiddenAccountIds:[],showUsage:true,showSessions:true,accountMode:'lowest',runningOnly:false,groupBy:'none',cellDetail:'clients'};}
export function dockLimit(providerId:string,accountId:string|null=null):DockItem{providerId=canonicalCompactProvider(providerId);return {...dockStat('today'),id:`limit:${providerId}${accountId?`:account:${accountId}`:''}`,type:'limit',providerId,accountId,metric:null,accountMode:providerId==='codex'?'active':'lowest',showUsage:accountId===null,showSessions:accountId===null};}
export function dockProxy():DockItem{return {...dockStat('today'),id:'proxy',type:'proxy',metric:null,showUsage:false,showSessions:false};}
const bad=():never=>{throw Error('compact_invalid_response');};
const object=(raw:unknown):Record<string,unknown>=>raw!==null&&typeof raw==='object'&&!Array.isArray(raw)?raw as Record<string,unknown>:bad();
function fields(raw:Record<string,unknown>,allowed:string[]){if(Object.keys(raw).some(key=>!allowed.includes(key)))bad();}
function string(raw:unknown,max=256):string{return typeof raw==='string'&&raw.length>0&&raw.length<=max&&!/[\x00-\x1f\x7f\\@]|:\/\/|^\/|^[a-z]:\//i.test(raw)?raw:bad();}
const bool=(raw:unknown)=>typeof raw==='boolean'?raw:bad();
const finite=(raw:unknown)=>typeof raw==='number'&&Number.isFinite(raw)&&raw>=0&&raw<=Number.MAX_SAFE_INTEGER?raw:bad();
const count=(raw:unknown)=>Number.isSafeInteger(finite(raw))?raw as number:bad();
const id=(raw:unknown)=>/^[a-zA-Z0-9._:-]{1,256}$/.test(string(raw))?raw as string:bad();
const optionalId=(raw:unknown)=>raw===null?null:id(raw);
const optionalNumber=(raw:unknown)=>raw===null?null:finite(raw);
const code=(raw:unknown)=>raw===null?null:/^[a-z0-9_]{1,64}$/.test(string(raw,64))?raw as string:bad();
const choice=<T extends string>(raw:unknown,values:readonly T[]):T=>values.includes(raw as T)?raw as T:bad();
function array(raw:unknown,max:number):unknown[]{return Array.isArray(raw)&&raw.length<=max?raw:bad();}
function item(raw:unknown):DockItem{
 const v=object(raw);fields(v,['id','type','providerId','accountId','metric','hiddenAccountIds','showUsage','showSessions','accountMode','runningOnly','groupBy','cellDetail']);id(v.id);choice(v.type,['limit','stat','proxy']);optionalId(v.providerId);optionalId(v.accountId);if(v.metric!==null)choice(v.metric,['today','week','last7','last30','month','allTime','liveRate','sessions']);array(v.hiddenAccountIds,256).forEach(id);bool(v.showUsage);bool(v.showSessions);choice(v.accountMode,['active','lowest']);bool(v.runningOnly);choice(v.groupBy,['none','client']);choice(v.cellDetail,['clients','rate']);
 const derived=v.type==='proxy'?'proxy':v.type==='stat'?`stat:${v.metric}`:`limit:${v.providerId}${v.accountId?`:account:${v.accountId}`:''}`;if(derived!==v.id||v.type==='limit'&&(!v.providerId||v.metric!==null)||v.type==='stat'&&(!v.metric||v.providerId!==null||v.accountId!==null)||v.type==='proxy'&&(v.providerId!==null||v.accountId!==null||v.metric!==null))bad();return v as unknown as DockItem;
}
function items(raw:unknown):DockItem[]{const values=array(raw,24).map(item);if(new Set(values.map(value=>value.id)).size!==values.length)bad();return values;}
export function parseCompactPreferences(raw:unknown):CompactPreferences{
 const v=object(raw);fields(v,['enabled','mode','side','offset','displayId','items','hapticEnabled','warnColors','quotaStyle','refreshEnabled','runningIndicatorEnabled','size','customScale']);bool(v.enabled);choice(v.mode,['autoHide','always']);choice(v.side,['left','right']);if(finite(v.offset)>1)bad();optionalId(v.displayId);if(v.items!==null)items(v.items);for(const key of ['hapticEnabled','warnColors','refreshEnabled','runningIndicatorEnabled'])bool(v[key]);choice(v.quotaStyle,['ring','fish']);choice(v.size,['small','medium','large','custom']);const scale=finite(v.customScale);if(scale<.75||scale>1.5||Math.abs(scale*20-Math.round(scale*20))>.000001)bad();return v as unknown as CompactPreferences;
}
export function parseCompactState(raw:unknown):CompactState{
 const v=object(raw);fields(v,['revision','windows','selectedItemId','resolvedItems','pageIndex','pageCount','displayAvailable','side','scale','viewportHeight','preferences','displays','failureCode','shortcutStatus','cachedProjection']);count(v.revision);choice(v.shortcutStatus,['unregistered','registered','occupied','failed','unavailable']);const windows=array(v.windows,4);if(windows.length!==4||new Set(windows.map(raw=>object(raw).surface)).size!==4)bad();for(const raw of windows){const w=object(raw);fields(w,['surface','visible','pinned','collapsed']);choice(w.surface,compactSurfaces);bool(w.visible);bool(w.pinned);bool(w.collapsed);}
 optionalId(v.selectedItemId);items(v.resolvedItems);count(v.pageIndex);if(count(v.pageCount)<1||(v.pageIndex as number)>=(v.pageCount as number))bad();bool(v.displayAvailable);choice(v.side,['left','right']);const scale=finite(v.scale);if(scale<.75||scale>1.5)bad();finite(v.viewportHeight);parseCompactPreferences(v.preferences);code(v.failureCode);
 for(const raw of array(v.displays,64)){const d=object(raw);fields(d,['id','label','isPrimary','available']);id(d.id);string(d.label);bool(d.isPrimary);bool(d.available);}
 const projection=object(v.cachedProjection);fields(projection,['accounts','proxy','sessionCount']);const accounts=array(projection.accounts,256);if(new Set(accounts.map(raw=>object(raw).id)).size!==accounts.length)bad();
 for(const raw of accounts){const a=object(raw);fields(a,['id','providerId','label','loggedIn','active','observedAt','available','reasonCode','planType','windows','creditsUsd','creditPoints','resetCards']);id(a.id);id(a.providerId);string(a.label);bool(a.loggedIn);if(a.active!==null)bool(a.active);optionalNumber(a.observedAt);bool(a.available);code(a.reasonCode);if(a.planType!==null)string(a.planType);optionalNumber(a.creditsUsd);if(a.creditPoints!==null&&!/^[0-9.]{1,64}$/.test(string(a.creditPoints,64)))bad();if(a.resetCards!==null)count(a.resetCards);for(const raw of array(a.windows,64)){const w=object(raw);fields(w,['id','label','usedPercent','resetsAt']);string(w.id);string(w.label);if(w.usedPercent!==null&&finite(w.usedPercent)>100)bad();optionalNumber(w.resetsAt);}}
 if(projection.proxy!==null){const p=object(projection.proxy);fields(p,['phase','egressState','activeRequests','observedAt']);if(code(p.phase)===null)bad();code(p.egressState);if(p.activeRequests!==null)count(p.activeRequests);optionalNumber(p.observedAt);}if(projection.sessionCount!==null)count(projection.sessionCount);
 return v as unknown as CompactState;
}
export function compactFailure(error:unknown):string{const code=error&&typeof error==='object'&&'message'in error?String(error.message):String(error);return /^[a-z0-9_]{1,64}$/.test(code)?code:'compact_unavailable';}

export function compactPrimaryWindow(account:CompactAccount):CompactQuotaWindow|undefined{
 if(!account.loggedIn)return undefined;
 if(canonicalCompactProvider(account.providerId)==='codex'){
  const plan=account.planType?.trim().toLowerCase().replace(/[-_]/g,'');
  const ids=plan==='pro'||plan==='prolite'?['seven-day','seven_day','sevenDay']:plan==='plus'?['five-hour','five_hour','fiveHour']:null;
  if(ids)return account.windows.find(window=>ids.includes(window.id));
 }
 return account.windows.find(window=>window.usedPercent===100)??account.windows.find(window=>window.usedPercent!==null);
}
export function compactHeadlineAccount(item:DockItem,accounts:CompactAccount[]):CompactAccount|undefined{
 const visible=accounts.filter(account=>canonicalCompactProvider(account.providerId)===canonicalCompactProvider(item.providerId??'')&&account.loggedIn&&!item.hiddenAccountIds.includes(account.id));
 if(item.accountId)return visible.find(account=>account.id===item.accountId);
 if(canonicalCompactProvider(item.providerId??'')==='codex'&&item.accountMode==='active'){
  const active=visible.filter(account=>account.active===true);return active.length===1?active[0]:undefined;
 }
 if(canonicalCompactProvider(item.providerId??'')==='claude')return visible.find(account=>account.creditsUsd!==null);
 return visible.filter(account=>compactPrimaryWindow(account)?.usedPercent!==null&&compactPrimaryWindow(account)?.usedPercent!==undefined).sort((a,b)=>(compactPrimaryWindow(b)!.usedPercent??0)-(compactPrimaryWindow(a)!.usedPercent??0))[0];
}

export function canonicalCompactProvider(value:string):string{const id=value.trim().toLowerCase();return ({claude_code:'claude','claude-code':'claude',claudecode:'claude',open_code:'opencode',work_buddy:'workbuddy',zcode:'zai'} as Record<string,string>)[id]??id;}
const DISPLAY_FRESH_MS=300_000; // Existing quota_display::current; presentation only.
export function expireCompactProjection(state:CompactState,now=Date.now()):CompactState{
 let changed=false;const accounts=state.cachedProjection.accounts.map(account=>{
  const dated=account.windows.flatMap(window=>window.resetsAt===null?[]:[window.resetsAt]);
  const fresh=account.observedAt!==null&&account.observedAt>0&&account.observedAt<=now&&now-account.observedAt<DISPLAY_FRESH_MS&&(!dated.length||dated.some(at=>at>now));
  if(!account.available||fresh)return account;changed=true;return {...account,available:false,reasonCode:'quota_stale'};
 });return changed?{...state,cachedProjection:{...state.cachedProjection,accounts}}:state;
}
export function compactProjectionDeadline(state:CompactState,now=Date.now()):number|null{
 const deadlines=state.cachedProjection.accounts.filter(account=>account.available&&account.observedAt!==null).map(account=>{const times=account.windows.flatMap(window=>window.resetsAt===null?[]:[window.resetsAt]);return Math.min(account.observedAt!+DISPLAY_FRESH_MS,...(times.length?[Math.max(...times)]:[]));}).filter(at=>at>now);
 return deadlines.length?Math.min(...deadlines):null;
}
