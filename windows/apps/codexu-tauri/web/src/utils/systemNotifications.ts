import type { NotificationReceipt } from './notificationChannels';
export interface SystemNotificationState{enabled:boolean;permission:'enabled'|'disabled_app'|'disabled_user'|'disabled_policy'|'disabled_manifest'|'unavailable';phase:string;lastAcceptedAt:number|null;failureCode:string|null}
export type SystemNotificationReceipt=Omit<NotificationReceipt,'channel'>&{channel:'system'};
const bad=():never=>{throw Error('system_notifications_unavailable');};
function object(raw:unknown,keys:string[]){if(!raw||typeof raw!=='object'||Array.isArray(raw)||Object.keys(raw).some(key=>!keys.includes(key)))return bad();return raw as Record<string,unknown>;}
const code=(value:unknown)=>value===null||typeof value==='string'&&/^[a-z0-9_]{1,80}$/.test(value)?value as string|null:bad();
const time=(value:unknown)=>typeof value==='number'&&Number.isSafeInteger(value)&&value>0?value:bad();
export function parseSystemNotificationState(raw:unknown):SystemNotificationState{
 const v=object(raw,['enabled','permission','phase','lastAcceptedAt','failureCode']);
 if(typeof v.enabled!=='boolean'||!['enabled','disabled_app','disabled_user','disabled_policy','disabled_manifest','unavailable'].includes(v.permission as string)||code(v.phase)===null)bad();
 if(v.lastAcceptedAt!==null)time(v.lastAcceptedAt);code(v.failureCode);return v as unknown as SystemNotificationState;
}
export function parseSystemNotificationReceipt(raw:unknown):SystemNotificationReceipt{
 const v=object(raw,['channel','eventId','state','checkedAt','remoteMessageId','failureCode']);
 if(v.channel!=='system'||typeof v.eventId!=='string'||!/^[a-f0-9]{64}$/.test(v.eventId)||!['accepted','rejected','uncertain','duplicate_skipped','not_sent'].includes(v.state as string)||v.remoteMessageId!==null)bad();time(v.checkedAt);code(v.failureCode);return v as unknown as SystemNotificationReceipt;
}
