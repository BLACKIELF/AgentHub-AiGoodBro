export const POOL_PROVIDERS=['antigravity','claude','kimi','xai'] as const;
export type PoolProvider=typeof POOL_PROVIDERS[number];
export interface PoolAccount {id:string;provider:PoolProvider;maskedIdentity:string;generation:string;enabled:boolean;concurrencyLimit:number;inFlight:number;state:'checking'|'ready'|'busy'|'cooling'|'disabled'|'reauth_required';cooldownUntil:number|null;lastError:string|null;models:string[]}
export interface PoolSnapshot {phase:'stopped'|'starting'|'running'|'stopping'|'failed';runId:string|null;port:number|null;accounts:PoolAccount[];providers:PoolProvider[];providerModels:Partial<Record<PoolProvider,string[]>>;authorization:{attemptId:string;provider:PoolProvider;cancelling:boolean;userCode:string|null}|null;issueCode:string|null}
const invalid=():never=>{throw Error('provider_pool_invalid_response');};
const obj=(v:unknown):Record<string,unknown>=>{if(!v||typeof v!=='object'||Array.isArray(v))invalid();return v as Record<string,unknown>;};
function keys(o:Record<string,unknown>,expected:string[]){if(Object.keys(o).sort().join('|')!==[...expected].sort().join('|'))invalid();}
function text(v:unknown,max:number){if(typeof v!=='string'||v.length>max||/[\x00-\x1f\x7f]/.test(v))invalid();return v as string;}
const opaque=(v:unknown)=>{const s=text(v,128);if(!/^[A-Za-z0-9_-]{20,128}$/.test(s))invalid();return s;};
function provider(v:unknown):PoolProvider {if(!POOL_PROVIDERS.includes(v as PoolProvider))invalid();return v as PoolProvider;}
function models(v:unknown):string[]{if(!Array.isArray(v)||v.length>512||v.some(m=>typeof m!=='string'||!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(m))||new Set(v).size!==v.length)invalid();return v as string[];}
function integer(v:unknown,min:number,max:number):number{if(typeof v!=='number'||!Number.isSafeInteger(v)||v<min||v>max)invalid();return v as number;}
function bool(v:unknown):boolean{if(typeof v!=='boolean')invalid();return v as boolean;}
export function parseProviderPool(value:unknown):PoolSnapshot {
 const s=obj(value);keys(s,['phase','runId','port','accounts','providers','providerModels','authorization','issueCode']);
 if(!['stopped','starting','running','stopping','failed'].includes(String(s.phase)))invalid();
 const phase=s.phase as PoolSnapshot['phase'],runId=s.runId===null?null:opaque(s.runId),port=s.port===null?null:integer(s.port,18081,18081);
 if((phase==='running'&&(!runId||port!==18081))||(phase!=='running'&&port!==null))invalid();
 if(!Array.isArray(s.accounts)||s.accounts.length>100)invalid();
 const accounts=(s.accounts as unknown[]).map(raw=>{const a=obj(raw);keys(a,['id','provider','maskedIdentity','generation','enabled','concurrencyLimit','inFlight','state','cooldownUntil','lastError','models']);const p=provider(a.provider),id=text(a.id,64),prefix=p==='antigravity'?'ag':p;if(!new RegExp(`^${prefix}-[a-f0-9]{32}$`).test(id))invalid();const maskedIdentity=text(a.maskedIdentity,160);if(!maskedIdentity.includes('***'))invalid();if(!['checking','ready','busy','cooling','disabled','reauth_required'].includes(String(a.state)))invalid();if(a.lastError!==null&&!['','reauth_required','rate_limited','upstream_unavailable'].includes(String(a.lastError)))invalid();return {id,provider:p,maskedIdentity,generation:opaque(a.generation),enabled:bool(a.enabled),concurrencyLimit:integer(a.concurrencyLimit,1,8),inFlight:integer(a.inFlight,0,8),state:a.state as PoolAccount['state'],cooldownUntil:a.cooldownUntil===null?null:integer(a.cooldownUntil,0,253402300799),lastError:a.lastError as string|null,models:models(a.models)};});
 if(new Set(accounts.map(a=>a.id)).size!==accounts.length||!Array.isArray(s.providers)||s.providers.length>4)invalid();
 const providers=(s.providers as unknown[]).map(provider);if(new Set(providers).size!==providers.length)invalid();
 const catalogs=obj(s.providerModels),providerModels:PoolSnapshot['providerModels']={};for(const [key,value]of Object.entries(catalogs)){const p=provider(key);if(!providers.includes(p))invalid();providerModels[p]=models(value);}
 let authorization:PoolSnapshot['authorization']=null;
 if(s.authorization!==null){const a=obj(s.authorization);keys(a,['attemptId','provider','cancelling','userCode']);const p=provider(a.provider);if(phase!=='running'||!providers.includes(p))invalid();const userCode=a.userCode===null?null:text(a.userCode,32);if(userCode!==null&&!/^[A-Za-z0-9-]{1,32}$/.test(userCode))invalid();authorization={attemptId:opaque(a.attemptId),provider:p,cancelling:bool(a.cancelling),userCode};}
 const issueCode=s.issueCode===null?null:text(s.issueCode,100);if(issueCode!==null&&!/^provider_pool_[a-z_]{1,80}$/.test(issueCode))invalid();
 return {phase,runId,port,accounts,providers,providerModels,authorization,issueCode};
}
