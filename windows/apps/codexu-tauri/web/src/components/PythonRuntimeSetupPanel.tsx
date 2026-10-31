import {useEffect,useRef,useState} from 'react';
import {invoke} from '@tauri-apps/api/core';
import {open} from '@tauri-apps/plugin-dialog';
import {useI18n} from '../i18n/I18nProvider';
import {parsePythonRuntime,type PythonRuntime} from '../utils/pythonRuntime';

/** Local companion prerequisites only. No installation or account action. */
export function PythonRuntimeSetupPanel(){
 const {language}=useI18n(),t=(zh:string,en:string)=>language==='zh-Hans'?zh:en;
 const [view,setView]=useState<PythonRuntime|null>(null),[busy,setBusy]=useState(false),[saved,setSaved]=useState(false),[issue,setIssue]=useState<string|null>(null);
 const alive=useRef(false),pending=useRef(false),epoch=useRef(0);
 useEffect(()=>{alive.current=true;return()=>{alive.current=false;epoch.current++;};},[]);
 async function act(kind:'inspect'|'choose'|'guide'){
  if(pending.current)return;pending.current=true;const own=++epoch.current;setBusy(true);setSaved(false);setIssue(null);
  try{
   if(kind==='guide'){await invoke('open_python_installation_guide',{topic:(issue??view?.issueCode)==='python_timezone_missing'?'timezone':'windows'});return;}
   let path:string|null=null;
   if(kind==='choose'){
    const selected=await open({directory:false,multiple:false,filters:[{name:'Python',extensions:['exe']}]});
    if(!selected||!alive.current||own!==epoch.current)return;
    if(typeof selected!=='string')throw Error('python_response_invalid');path=selected;
   }
   setView(null);
   const next=parsePythonRuntime(await invoke(kind==='choose'?'select_python_runtime':'inspect_python_runtime',path?{path}:undefined));
   if(!alive.current||own!==epoch.current)return;
   if(kind==='choose'&&(next.state!=='ready'||!next.selected))throw Error('python_response_invalid');
   setView(next);setSaved(kind==='choose');
  }catch(error){if(alive.current&&own===epoch.current){
   const code=typeof error==='string'?error:'';
   setIssue(['python_version_unsupported','python_stdlib_missing','python_timezone_missing','python_interpreter_changed','runtime_selection_changed','cleanup_unconfirmed'].includes(code)?code:'python_operation_unconfirmed');
  }}finally{pending.current=false;if(alive.current&&own===epoch.current)setBusy(false);}
 }
 const code=issue??view?.issueCode;
 const detail=code==='python_timezone_missing'?t('缺少 Asia/Shanghai 时区数据。请按官方说明补齐后重新检查；这里不会自动安装依赖。','Asia/Shanghai timezone data is unavailable. Follow the official instructions, then check again. No dependencies are installed here.'):
  code==='python_stdlib_missing'?t('所选 Python 缺少配套工具所需的标准库能力。','The selected Python lacks standard-library capabilities required by the companion.'):
  code==='python_version_unsupported'?t('需要 Python 3.9 或更高的 Python 3 版本。','Python 3.9 or a newer Python 3 release is required.'):
  code==='cleanup_unconfirmed'?t('尚未确认检测进程已退出，已保留现场。未确认保存新选择。','Probe cleanup is unconfirmed; its evidence was retained. No new selection is confirmed.'):
  code?t('本次操作或程序状态未确认。请重新检查实际选择；尚不能确认保存结果。','The operation or executable state is unconfirmed. Check the actual selection again; the save result is not yet confirmed.'):null;
 return <section aria-label={t('Python 配套环境','Python companion runtime')} className="space-y-3">
  <h3 className="font-semibold">Python</h3>
  <p>{t('配套 Skill 需要 Python 3.9+、标准库及可用时区数据。基本账号管理与 Windows 内置调度无需 Python。','The companion Skill requires Python 3.9+, standard libraries and timezone data. Basic account management and built-in Windows dispatch do not require Python.')}</p>
  <p role="status">{busy?t('正在处理…','Working…'):view?.state==='ready'?`${t('可用','Available')} · ${view.version}${view.selected?t(' · 已选择',' · Selected'):t(' · 自动找到',' · Detected')}`:view?.state==='missing'?t('未找到可用 Python','No usable Python found'):view?t('尚不可用','Unavailable'):t('待检查','Not checked')}</p>
  <div className="flex flex-wrap gap-2"><button className="glass-button px-2 py-1" disabled={busy} onClick={()=>void act('inspect')}>{t('检查 Python','Check Python')}</button><button className="glass-button px-2 py-1" disabled={busy} onClick={()=>void act('choose')}>{t('选择已安装的 Python…','Choose installed Python…')}</button><button className="glass-button px-2 py-1" disabled={busy} onClick={()=>void act('guide')}>{t('打开 Python 官方说明','Open official Python instructions')}</button></div>
  {saved&&<p role="status">{t('Python 已验证并保存，供后续配套工具使用。','Python verified and saved for future companion operations.')}</p>}
  {detail&&<p role="alert">{detail}</p>}
  <p className="text-xs text-secondary">{t('这里只检查已有程序。不会下载、安装 Python 或修改系统 PATH；选择不会重启现有程序，也不代表配套 Skill 已安装完成。','Only existing executables are checked. Python is not downloaded or installed, and system PATH is not changed. Selection does not restart programs or confirm companion Skill installation.')}</p>
 </section>;
}
