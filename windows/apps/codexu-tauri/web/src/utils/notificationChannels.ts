export const notificationKinds=['feishu','telegram','wechat','personal-wechat'] as const;
export type NotificationKind=typeof notificationKinds[number];
export type NotificationPhase='disabled'|'needs_setup'|'context_required'|'session_expired'|'pending_verification'|'ready';
export interface NotificationOptions {includesAgentName:boolean;includesAccountLabel:boolean;includesQuotas:boolean;includesResetTimes:boolean;includesResetCredits:boolean;resetExpiryDetail:'nearest'|'all'|'none';notifiesFiveHourReset:boolean;notifiesSevenDayReset:boolean}
export interface NotificationChannel {channel:NotificationKind;enabled:boolean;phase:NotificationPhase;revision:number;credentialPresent:boolean;targetPresent:boolean;lastAcceptedAt:number|null;failureCode:string|null;options:NotificationOptions}
export interface NotificationReceipt {channel:NotificationKind;eventId:string;state:'accepted'|'rejected'|'uncertain'|'duplicate_skipped'|'not_sent';checkedAt:number;remoteMessageId:string|null;failureCode:string|null}
export type PersonalLoginPhase='starting'|'waiting'|'scanned'|'verification_required'|'verification_blocked'|'already_bound'|'expired'|'local_timeout'|'confirmed'|'cancelled'|'failed';
export interface PersonalNotificationLogin {attemptId:string;phase:PersonalLoginPhase;qrContent:string|null;expiresAt:number}
export type NotificationPreset='compact'|'detailed'|'custom';
const fail=():never=>{throw Error('notification_invalid_response');};
const object=(value:unknown):Record<string,unknown>=>value!==null&&typeof value==='object'&&!Array.isArray(value)?value as Record<string,unknown>:fail();
function fields(value:Record<string,unknown>,names:string[]):void{if(Object.keys(value).some(name=>!names.includes(name)))fail();}
const bool=(value:unknown):boolean=>typeof value==='boolean'?value:fail();
const count=(value:unknown):number=>typeof value==='number'&&Number.isSafeInteger(value)&&value>=0?value:fail();
const text=(value:unknown,max=256):string=>typeof value==='string'&&value.length<=max&&!/[\x00-\x1f\x7f]/.test(value)?value:fail();
const code=(value:unknown):string|null=>value===null?null:/^[a-z_]{1,64}$/.test(text(value))?value as string:fail();
const kind=(value:unknown):NotificationKind=>notificationKinds.includes(value as NotificationKind)?value as NotificationKind:fail();
export function notificationError(raw:unknown):string{const value=raw&&typeof raw==='object'&&'message'in raw&&typeof raw.message==='string'?raw.message:String(raw);return /^[a-z_]{1,64}$/.test(value)?value:'notification_unavailable';}
export function parseNotificationOptions(raw:unknown):NotificationOptions{
 const value=object(raw);fields(value,['includesAgentName','includesAccountLabel','includesQuotas','includesResetTimes','includesResetCredits','resetExpiryDetail','notifiesFiveHourReset','notifiesSevenDayReset']);
 for(const key of ['includesAgentName','includesAccountLabel','includesQuotas','includesResetTimes','includesResetCredits','notifiesFiveHourReset','notifiesSevenDayReset'])bool(value[key]);
 if(!['nearest','all','none'].includes(value.resetExpiryDetail as string))fail();return value as unknown as NotificationOptions;
}
export function parseNotificationChannel(raw:unknown,expected?:NotificationKind):NotificationChannel{
 const value=object(raw);fields(value,['channel','enabled','phase','revision','credentialPresent','targetPresent','lastAcceptedAt','failureCode','options']);const channel=kind(value.channel);
 if(expected&&channel!==expected)fail();bool(value.enabled);bool(value.credentialPresent);bool(value.targetPresent);count(value.revision);code(value.failureCode);parseNotificationOptions(value.options);
 if(!['disabled','needs_setup','context_required','session_expired','pending_verification','ready'].includes(value.phase as string))fail();
 if(value.lastAcceptedAt!==null&&count(value.lastAcceptedAt)<=0)fail();
 if((value.phase==='disabled')!==(value.enabled===false))fail();
 if(['context_required','session_expired'].includes(value.phase as string)&&channel!=='personal-wechat')fail();
 if(value.phase==='ready'&&(!value.credentialPresent||value.lastAcceptedAt===null||(['telegram','personal-wechat'].includes(channel)&&!value.targetPresent)))fail();
 return value as unknown as NotificationChannel;
}
export function parseNotificationChannels(raw:unknown):NotificationChannel[]{
 if(!Array.isArray(raw)||raw.length!==notificationKinds.length)return fail();const values=raw.map(value=>parseNotificationChannel(value));
 if(new Set(values.map(value=>value.channel)).size!==notificationKinds.length)fail();
 return notificationKinds.map(channel=>values.find(value=>value.channel===channel)!);
}
export function parseNotificationReceipt(raw:unknown,expected:NotificationKind):NotificationReceipt{
 const value=object(raw);fields(value,['channel','eventId','state','checkedAt','remoteMessageId','failureCode']);
 if(kind(value.channel)!==expected||!/^[a-f0-9]{64}$/.test(text(value.eventId))||!['accepted','rejected','uncertain','duplicate_skipped','not_sent'].includes(value.state as string)||count(value.checkedAt)<=0)fail();code(value.failureCode);
 if(value.remoteMessageId!==null&&value.remoteMessageId!==undefined&&!/^[a-zA-Z0-9._:-]{1,256}$/.test(text(value.remoteMessageId)))fail();
 return {...value,remoteMessageId:value.remoteMessageId??null} as unknown as NotificationReceipt;
}
export function parsePersonalNotificationLogin(raw:unknown,expected?:string):PersonalNotificationLogin{
 const value=object(raw);fields(value,['attemptId','phase','qrContent','expiresAt']);
 if(!/^[a-zA-Z0-9_-]{1,128}$/.test(text(value.attemptId))||expected&&value.attemptId!==expected||!['starting','waiting','scanned','verification_required','verification_blocked','already_bound','expired','local_timeout','confirmed','cancelled','failed'].includes(value.phase as string)||count(value.expiresAt)<=0)fail();
 const qr=value.qrContent??null;
 if(qr!==null){text(qr,4096);if(new TextEncoder().encode(qr as string).length>4096||!['waiting','scanned','verification_required'].includes(value.phase as string))fail();}
 return {...value,qrContent:qr} as unknown as PersonalNotificationLogin;
}
export function personalNotificationLoginActive(login:PersonalNotificationLogin|null):boolean{return !!login&&['starting','waiting','scanned','verification_required'].includes(login.phase);}
export function notificationCanTest(channel:NotificationChannel):boolean{return channel.enabled&&channel.credentialPresent&&['ready','pending_verification'].includes(channel.phase)&&(!['telegram','personal-wechat'].includes(channel.channel)||channel.targetPresent);}
const contentKeys=['includesAgentName','includesAccountLabel','includesQuotas','includesResetTimes','includesResetCredits','resetExpiryDetail'] as const;
const compactContent={includesAgentName:false,includesAccountLabel:true,includesQuotas:false,includesResetTimes:false,includesResetCredits:true,resetExpiryDetail:'none'} as const;
const detailedContent={includesAgentName:false,includesAccountLabel:true,includesQuotas:true,includesResetTimes:true,includesResetCredits:true,resetExpiryDetail:'nearest'} as const;
export function notificationOptionsEqual(a:NotificationOptions,b:NotificationOptions):boolean{return [...contentKeys,'notifiesFiveHourReset','notifiesSevenDayReset'].every(key=>a[key as keyof NotificationOptions]===b[key as keyof NotificationOptions]);}
export function notificationPreset(options:NotificationOptions):NotificationPreset{
 if(contentKeys.every(key=>options[key]===compactContent[key]))return 'compact';if(contentKeys.every(key=>options[key]===detailedContent[key]))return 'detailed';return 'custom';
}
export function applyNotificationPreset(options:NotificationOptions,preset:NotificationPreset):NotificationOptions{return preset==='custom'?{...options}:{...options,...(preset==='compact'?compactContent:detailedContent)};}
export function validNotificationVerificationCode(value:string):boolean{return /^[0-9]{4,10}$/.test(value);}
export function notificationFailureText(code:string,text:(zh:string,en:string)=>string):string{
 const messages:Record<string,[string,string]>={
  channel_disabled:['通知已关闭，请先启用此渠道。','This channel is disabled. Enable it first.'],missing_credential:['尚未保存凭据，请先配置。','No credential is saved. Set up this channel first.'],missing_target:['尚未设置接收目标。','The recipient has not been set.'],invalid_credential:['凭据格式无效，输入内容已保留。','The credential format is invalid. Your input has been kept.'],invalid_target:['接收目标格式无效，输入内容已保留。','The recipient format is invalid. Your input has been kept.'],
  wechat_context_required:['请在手机微信给已绑定的机器人发一句话，再测试通知。','Send a message to the paired bot in WeChat before testing notifications.'],wechat_session_expired:['微信会话已失效，请重新扫码。','The WeChat session expired. Scan again.'],wechat_login_in_progress:['已有扫码正在进行，请完成或取消后重试。','A pairing attempt is already in progress. Complete or cancel it first.'],wechat_login_not_current:['此扫码已不可用，请取消后重新开始。','This pairing attempt is no longer current. Cancel it and start again.'],wechat_login_not_found:['此扫码已不可用，请重新开始。','This pairing attempt is unavailable. Start again.'],invalid_verification_code:['配对码应为 4–10 位数字。','The pairing code must contain 4–10 digits.'],wechat_qr_login_required:['请通过扫码连接个人微信。','Use QR pairing to connect personal WeChat.'],
  configuration_changed:['配置已变化，旧操作结果未应用。','Configuration changed. The old result was not applied.'],cancelled:['操作已取消。','The operation was cancelled.'],rejected:['接口拒绝了本次请求，请检查配置。','The API rejected this request. Check the configuration.'],rate_limited:['接口暂时限流，请稍后手动重试。','The API is rate limited. Retry manually later.'],transport_failed:['请求结果未确认，请先在接收端核对。','The request result is unconfirmed. Check the recipient first.'],redirected:['接口地址校验未通过，操作未完成。','Endpoint verification failed. The operation did not complete.'],invalid_response:['接口响应无法确认，请在接收端核对。','The API response is unconfirmed. Check the recipient.'],notification_invalid_response:['返回状态无法确认，请重新读取配置。','The returned state is unconfirmed. Read the configuration again.'],
  notification_busy:['正在处理其他操作，请稍后重试。','Another operation is in progress. Try again shortly.'],notification_store_busy:['配置正在使用中，请稍后重试。','Configuration is busy. Try again shortly.'],notification_store_unavailable:['通知配置暂不可读，请重试。','Notification configuration is unavailable. Try again.'],notification_credentials_unavailable:['本机凭据暂不可读，请重试。','Local credentials are unavailable. Try again.'],notification_queue_busy:['提醒队列正在处理，请稍后重试。','The notification queue is busy. Try again shortly.'],notification_queue_capacity:['提醒队列已满，请稍后检查。','The notification queue is full. Check again later.'],stale_notification:['本次提醒已过期，未发送。','This notification expired and was not sent.'],notification_cancel_unconfirmed:['取消结果尚未确认，请再次取消后重试。','Cancellation is unconfirmed. Cancel again before retrying.'],windows_required:['此通知服务需要 Windows。','This notification service requires Windows.'],
 };return messages[code]?text(...messages[code]):text('操作未完成，请重新读取状态后重试。','The operation did not complete. Read status again and retry.');
}
