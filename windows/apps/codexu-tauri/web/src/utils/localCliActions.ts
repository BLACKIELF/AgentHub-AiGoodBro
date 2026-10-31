export const localCliPlatforms = ['codex', 'claude_code', 'grok', 'open_code', 'trae', 'work_buddy', 'kimi', 'mimo', 'zcode', 'gemini', 'antigravity'] as const;
export type LocalCliTarget = {kind:'profile';profileId:string}|{kind:'default';platform:string;edition:'domestic'|'international'|null}|{kind:'claude_subscription';accountId:string};
export interface LocalCliActions {platform:string;can_login:boolean;can_open:boolean;reason_code:string|null;phase:'idle'}
export interface LocalCliSession {session_id:string;platform:string;phase:'running'|'exited'|'stopped'|'failed';authentication_state:'unknown'|'configuration_changed';reason_code:string|null}
export interface LocalCliCreated {profile_id:string;platform:string;phase:'created'}
export interface DependencyTask {task_id:string;platform:string;phase:'prepared';prompt:string}
export interface DependencyStatus {task_id:string;platform:string;phase:'prepared'|'running'|'needs_user_action'|'verified'|'failed'|'cancelled';verification_state:'unknown'|'checking'|'verified'|'failed';version:string|null;reason_code:string|null}
const invalid=():never=>{throw Error('local_cli_invalid_response');};
const object=(raw:unknown):Record<string,unknown>=>raw&&typeof raw==='object'&&!Array.isArray(raw)?raw as Record<string,unknown>:invalid();
const fields=(value:Record<string,unknown>,allowed:string[])=>{if(Object.keys(value).some(key=>!allowed.includes(key)))invalid();};
const platform=(raw:unknown,expected?:string)=>typeof raw==='string'&&(localCliPlatforms as readonly string[]).includes(raw)&&(!expected||raw===expected)?raw:invalid();
const code=(raw:unknown)=>raw===null?null:typeof raw==='string'&&/^[a-z_]{1,80}$/.test(raw)?raw:invalid();
const id=(raw:unknown)=>typeof raw==='string'&&/^[a-f0-9]{32}$/.test(raw)?raw:invalid();
const choice=<T extends string>(raw:unknown,values:readonly T[]):T=>values.includes(raw as T)?raw as T:invalid();
export function parseLocalCliActions(raw:unknown,expected:string):LocalCliActions{
 const value=object(raw);fields(value,['platform','can_login','can_open','reason_code','phase']);platform(value.platform,expected);if(typeof value.can_login!=='boolean'||typeof value.can_open!=='boolean'||value.phase!=='idle')invalid();code(value.reason_code);if(value.reason_code!==null&&(value.can_open||value.can_login))invalid();return value as unknown as LocalCliActions;
}
export function parseLocalCliSession(raw:unknown,expected:string,sessionId?:string):LocalCliSession{
 const value=object(raw);fields(value,['session_id','platform','phase','authentication_state','reason_code']);if(sessionId&&value.session_id!==sessionId)invalid();id(value.session_id);platform(value.platform,expected);choice(value.phase,['running','exited','stopped','failed']);choice(value.authentication_state,['unknown','configuration_changed']);code(value.reason_code);return value as unknown as LocalCliSession;
}
export function parseLocalCliCreated(raw:unknown,expected:string):LocalCliCreated{
 const value=object(raw);fields(value,['profile_id','platform','phase']);if(typeof value.profile_id!=='string'||!/^\d{1,20}$/.test(value.profile_id)||value.phase!=='created')invalid();platform(value.platform,expected);return value as unknown as LocalCliCreated;
}
export function parseDependencyTask(raw:unknown,expected:string):DependencyTask{
 const value=object(raw);fields(value,['task_id','platform','phase','prompt']);id(value.task_id);platform(value.platform,expected);if(value.phase!=='prepared'||typeof value.prompt!=='string'||!value.prompt.trim()||value.prompt.length>12000||/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(value.prompt))invalid();return value as unknown as DependencyTask;
}
export function parseDependencyStatus(raw:unknown,expected:string,taskId:string):DependencyStatus{
 const value=object(raw);fields(value,['task_id','platform','phase','verification_state','version','reason_code']);if(id(value.task_id)!==taskId)invalid();platform(value.platform,expected);choice(value.phase,['prepared','running','needs_user_action','verified','failed','cancelled']);choice(value.verification_state,['unknown','checking','verified','failed']);if(value.version!==null&&(typeof value.version!=='string'||!/^[A-Za-z0-9.+_-]{1,64}$/.test(value.version)))invalid();code(value.reason_code);if(value.phase==='verified'&&(value.verification_state!=='verified'||value.reason_code!==null))invalid();return value as unknown as DependencyStatus;
}
export function localCliFailure(failure:unknown):string{const raw=typeof failure==='string'?failure:failure instanceof Error?failure.message:'';return /^[a-z_]{1,80}$/.test(raw)?raw:'local_cli_unavailable';}
export function localCliFailureText(code:string,text:(zh:string,en:string)=>string):string{
 const values:Record<string,[string,string]>={
  provider_runtime_unverified:['此工具尚未准备完成，可交给本机 Codex 核实并准备。','This tool needs preparation. Let your local Codex check and prepare it.'],
  cli_unavailable:['此启动入口暂不可用，请重新读取或让本机 Codex 准备依赖。','This launcher is unavailable. Read again or prepare dependencies with your local Codex.'],
  default_environment_required:['此工具使用当前系统环境，请从工具入口打开。','This tool uses its current system environment. Open it from the tool entry.'],
  use_subscription_login:['请使用上方 Claude 官方登录与订阅保存流程。','Use the Claude official sign-in and subscription save controls above.'],
  already_running:['本应用已经为此工具打开了会话。','This app already has an open session for this tool.'],
  account_busy:['账号正在使用中，请稍后重试。','The account is in use. Try again later.'],
  cleanup_unconfirmed:['结束状态尚未确认，请保留当前会话并重试。','Session cleanup is unconfirmed. Keep its state and retry.'],
  platform_not_supported:['此平台目前没有对应的本机启动方式。','This platform has no matching local launch action.'],
  account_identity_unverified:['当前系统身份未确认，请先核实账号。','The current system identity is unconfirmed. Check the account first.'],
  launch_cancelled:['启动已取消。','Launch cancelled.'],
  workspace_unavailable:['工作目录不可用，请重新选择。','The workspace is unavailable. Choose it again.'],
  invalid_label:['请输入 64 字节以内、不含邮箱或路径的昵称。','Use an alias of up to 64 bytes, without an email address or path.'],
  duplicate_label:['昵称已存在，请换一个。','That alias already exists. Choose another.'],
 };
 return values[code]?text(...values[code]):text('操作未完成，保留现有配置，请重新读取后重试。','The operation did not complete. Existing settings are retained. Read again and retry.');
}
