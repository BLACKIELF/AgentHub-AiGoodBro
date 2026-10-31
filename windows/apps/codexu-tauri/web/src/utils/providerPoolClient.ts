import {POOL_PROVIDERS,type PoolProvider} from './providerPool';

export type PoolClientKind='codex'|'native';
export interface PoolClient {
 requestId:string;runId:string;provider:PoolProvider;kind:PoolClientKind;model:string;
 state:'checking'|'running'|'exited'|'stopped'|'failed'|'cleanupUnconfirmed';issueCode:string|null;
}
const invalid=():never=>{throw Error('provider_pool_client_invalid_response');};
export function parsePoolClient(value:unknown):PoolClient {
 if(!value||typeof value!=='object'||Array.isArray(value))return invalid();
 const o=value as Record<string,unknown>;
 if(Object.keys(o).sort().join('|')!==['requestId','runId','provider','kind','model','state','issueCode'].sort().join('|'))return invalid();
 if(typeof o.requestId!=='string'||! /^[a-f0-9]{32}$/.test(o.requestId)||typeof o.runId!=='string'||! /^[A-Za-z0-9_-]{20,128}$/.test(o.runId)
  ||!POOL_PROVIDERS.includes(o.provider as PoolProvider)||!['codex','native'].includes(String(o.kind))
  ||typeof o.model!=='string'||! /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(o.model)
  ||!['checking','running','exited','stopped','failed','cleanupUnconfirmed'].includes(String(o.state)))return invalid();
 if(o.issueCode!==null&&(typeof o.issueCode!=='string'||! /^(provider_pool_[a-z_]{1,90}|launch_cancelled)$/.test(o.issueCode)))return invalid();
 return o as unknown as PoolClient;
}
export function parsePoolClients(value:unknown):PoolClient[]{
 if(!Array.isArray(value)||value.length>256)return invalid();
 const rows=value.map(parsePoolClient);
 if(new Set(rows.map(x=>x.requestId)).size!==rows.length)return invalid();
 return rows;
}
