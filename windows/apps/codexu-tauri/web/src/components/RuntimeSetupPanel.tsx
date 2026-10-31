import {useEffect,useRef,useState} from 'react';
import {invoke} from '@tauri-apps/api/core';
import {open} from '@tauri-apps/plugin-dialog';
import {useI18n} from '../i18n/I18nProvider';
import {parseRuntimeComponent,parseRuntimeSetup,type RuntimeComponent} from '../utils/runtimeSetup';
export function RuntimeSetupPanel({onOpenTasks}:{onOpenTasks:()=>void|Promise<void>}){
 const {language}=useI18n(),text=(zh:string,en:string)=>language==='zh-Hans'?zh:en;
 const [codex,setCodex]=useState<RuntimeComponent|null>(null),[hub,setHub]=useState<boolean|null>(null),[busy,setBusy]=useState(false),[error,setError]=useState(false),[saved,setSaved]=useState(false);
 const alive=useRef(false),pending=useRef(false),generation=useRef(0);
 useEffect(()=>{alive.current=true;return()=>{alive.current=false;generation.current++;};},[]);
 const act=async(kind:'check'|'choose'|'guide'|'tasks')=>{
  if(pending.current)return;pending.current=true;const epoch=++generation.current;setBusy(true);setError(false);setSaved(false);
  try{
   if(kind==='check'){setCodex(null);setHub(null);const result=parseRuntimeSetup(await invoke('inspect_runtime_setup'));if(alive.current&&epoch===generation.current){setCodex(result.codex);setHub(result.hubVerified);}}
   else if(kind==='choose'){const path=await open({directory:false,multiple:false,filters:[{name:'Codex CLI',extensions:['exe']}]});if(!path||!alive.current||epoch!==generation.current)return;setCodex(null);const result=parseRuntimeComponent(await invoke('select_runtime_codex',{path}));if(result.state!=='ready'||!result.selected)throw Error('runtime_response_invalid');if(alive.current&&epoch===generation.current){setCodex(result);setSaved(true);}}
   else if(kind==='guide')await invoke('open_codex_installation_guide');
   else await onOpenTasks();
  }catch{if(alive.current&&epoch===generation.current)setError(true);}finally{pending.current=false;if(alive.current&&epoch===generation.current)setBusy(false);}
 };
 return <section aria-label={text('运行环境','Runtime setup')} className="space-y-3">
  <p>{text('先检查已有 Codex CLI；检查仅验证本地版本与命令能力，不验证登录或额度。','Check an existing Codex CLI. Checks verify local version and command capabilities, not sign-in or quota.')}</p>
  <dl><dt>Codex CLI</dt><dd data-testid="runtime-codex-state">{codex?.state==='ready'?`${text('可执行','Executable')} · ${codex.version}${codex.selected?text(' · 已选择',' · Selected'):''}`:codex?.state==='missing'?text('未找到','Not found'):codex?text('不可用，请重新检查或选择','Unavailable; check or select again'):text('待检查','Not checked')}</dd><dt>{text('本机调度组件','Local dispatch component')}</dt><dd>{hub===null?text('待检查','Not checked'):hub?text('随包组件完整性已验证','Bundled component integrity verified'):text('随包组件不可用','Bundled component unavailable')}</dd></dl>
  <div className="flex flex-wrap gap-2"><button type="button" className="glass-button" disabled={busy} onClick={()=>void act('check')}>{text('重新检查','Check again')}</button><button type="button" className="glass-button" disabled={busy} onClick={()=>void act('choose')}>{text('选择已安装的 Codex CLI…','Choose installed Codex CLI…')}</button><button type="button" className="glass-button" disabled={busy} onClick={()=>void act('guide')}>{text('打开官方安装指南','Open official installation guide')}</button><button type="button" className="glass-button" disabled={busy} onClick={()=>void act('tasks')}>{text('打开工具与任务','Open tools and tasks')}</button></div>
  {busy&&<p role="status">{text('正在检查…','Checking…')}</p>}{saved&&<p role="status">{text('程序已验证并保存。','Executable verified and saved.')}</p>}{error&&<p role="alert">{text('本次操作结果未确认。请重新检查后再决定是否重试。','The outcome of this operation is unconfirmed. Check again before deciding whether to retry.')}</p>}
  <p>{text('选择用于后续账号与任务的 CLI 查找，不重启正在运行的程序。Desktop 专用连接仍优先使用其受验证的随包 CLI。Windows 内置调度无需 Python；macOS 配套 Skill 安装器不适用于此处。','The selection is used for future account and task CLI discovery; running programs are not restarted. Desktop connections retain their verified bundled CLI preference. Built-in Windows dispatch needs no Python; the macOS companion Skill installer does not apply here.')}</p>
  <p>{text('组件完整不等于本机服务已连接。工作目录、账号身份、额度和任务批准仍在任务页分别验证。','Component integrity does not mean a local service is connected. Workspace, identity, quota and task approval are checked separately in Tasks.')}</p>
 </section>;
}
