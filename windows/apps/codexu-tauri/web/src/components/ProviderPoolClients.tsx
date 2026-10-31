import {useEffect,useRef,useState} from 'react';
import {invoke} from '@tauri-apps/api/core';
import {listen} from '@tauri-apps/api/event';
import {open} from '@tauri-apps/plugin-dialog';
import {useI18n} from '../i18n/I18nProvider';
import type {PoolProvider,PoolSnapshot} from '../utils/providerPool';
import {parsePoolClient,parsePoolClients,type PoolClient,type PoolClientKind} from '../utils/providerPoolClient';

type Request={requestId:string;runId:string;provider:PoolProvider;kind:PoolClientKind;model:string;workspace:string};
export function ProviderPoolClients({snapshot,provider,disabled}:{snapshot:PoolSnapshot|null;provider:PoolProvider;disabled:boolean}){
 const {language}=useI18n(),t=(zh:string,en:string)=>language==='zh-Hans'?zh:en;
 const [kind,setKind]=useState<PoolClientKind>('codex'),[model,setModel]=useState(''),[workspace,setWorkspace]=useState('');
 const [rows,setRows]=useState<PoolClient[]>([]),[busy,setBusy]=useState(false),[unconfirmed,setUnconfirmed]=useState(false),[stopId,setStopId]=useState<string|null>(null);
 const alive=useRef(false),operation=useRef(false),reading=useRef(false),epoch=useRef(0),pending=useRef<Request|null>(null);
 const binding=`${snapshot?.runId??''}\0${provider}`,current=useRef(binding);current.current=binding;
 const models=snapshot?.providerModels[provider]??[],chosen=models.includes(model)?model:(models[0]??'');
 const running=snapshot?.phase==='running'&&!!snapshot.runId,nativeUnavailable=kind==='native'&&provider==='antigravity';
 const live=useRef({snapshot,provider,disabled,kind,chosen,workspace});live.current={snapshot,provider,disabled,kind,chosen,workspace};
 async function read(){
  if(reading.current||operation.current)return;reading.current=true;const own=epoch.current;
  try{const next=parsePoolClients(await invoke('get_provider_pool_clients'));if(!alive.current||own!==epoch.current)return;setRows(next);
   if(!pending.current||next.some(r=>r.requestId===pending.current?.requestId)){pending.current=null;setUnconfirmed(false);}
  }catch{if(alive.current&&own===epoch.current)setUnconfirmed(true);}finally{reading.current=false;}
 }
 useEffect(()=>{alive.current=true;let stop:(()=>void)|undefined;void listen('provider-pool-clients:changed',()=>void read()).then(fn=>{if(!alive.current)fn();else{stop=fn;void read();}}).catch(()=>void read());return()=>{alive.current=false;epoch.current++;stop?.();};},[]);
 async function choose(){
  if(operation.current||disabled||pending.current)return;operation.current=true;setBusy(true);const at=current.current;
  try{const path=await open({directory:true,multiple:false});if(alive.current&&at===current.current&&typeof path==='string')setWorkspace(path);}
  catch{if(alive.current&&at===current.current)setUnconfirmed(true);}finally{operation.current=false;if(alive.current)setBusy(false);}
 }
 async function start(){
  const v=live.current,s=v.snapshot;
  if(operation.current||pending.current||v.disabled||s?.phase!=='running'||!s.runId||!v.workspace||!v.chosen||!(s.providerModels[v.provider]??[]).includes(v.chosen)||(v.kind==='native'&&v.provider==='antigravity'))return;
  const request:Request={requestId:crypto.randomUUID().replace(/-/g,''),runId:s.runId,provider:v.provider,kind:v.kind,model:v.chosen,workspace:v.workspace};
  pending.current=request;operation.current=true;const own=++epoch.current;setBusy(true);setUnconfirmed(false);
  try{const result=parsePoolClient(await invoke('start_provider_pool_client',{request}));if(result.requestId!==request.requestId||result.runId!==request.runId||result.provider!==request.provider||result.kind!==request.kind||result.model!==request.model)throw Error('mismatched_client');
   if(alive.current&&own===epoch.current){setRows(old=>[...old.filter(r=>r.requestId!==result.requestId),result]);pending.current=null;}
  }catch{if(alive.current&&own===epoch.current)setUnconfirmed(true);}finally{operation.current=false;if(alive.current&&own===epoch.current)setBusy(false);}
 }
 async function stop(){
  const id=stopId;if(!id||operation.current)return;operation.current=true;const own=++epoch.current;setBusy(true);setStopId(null);
  try{const result=parsePoolClient(await invoke('stop_provider_pool_client',{requestId:id,confirmed:true}));if(result.requestId!==id)throw Error('mismatched_client');if(alive.current&&own===epoch.current){setRows(old=>old.map(r=>r.requestId===id?result:r));setUnconfirmed(false);}}
  catch{if(alive.current&&own===epoch.current)setUnconfirmed(true);}finally{operation.current=false;if(alive.current&&own===epoch.current)setBusy(false);}
 }
 const stateText=(state:PoolClient['state'])=>({checking:t('检查中','Checking'),running:t('运行中','Running'),exited:t('已退出','Exited'),stopped:t('已停止','Stopped'),failed:t('未能启动','Start failed'),cleanupUnconfirmed:t('退出清理尚未确认','Cleanup unconfirmed')})[state];
 return <div className="space-y-3 border-t border-theme pt-3" aria-label={t('账号池客户端','Account pool clients')}>
  <p className="text-xs text-secondary">{t('使用独立目录连接当前账号池；不会改写已关联 CLI 账号。模型须由本次运行实际确认，客户端是否可用仍以启动结果为准。','Connect through a private directory without changing linked CLI accounts. The current pool must confirm the selected model; client availability is checked on launch.')}</p>
  <div className="flex flex-wrap items-end gap-2"><label className="text-xs">{t('客户端','Client')}<select aria-label={t('客户端','Client')} className="glass-input block p-2" value={kind} disabled={busy||!!pending.current} onChange={e=>setKind(e.target.value as PoolClientKind)}><option value="codex">Codex CLI</option><option value="native">{t('服务原生 CLI','Provider CLI')}</option></select></label>
   <label className="text-xs">{t('已观测模型','Observed model')}<select aria-label={t('已观测模型','Observed model')} className="glass-input block p-2" value={chosen} disabled={busy||!!pending.current||!models.length} onChange={e=>setModel(e.target.value)}>{!models.length&&<option value="">{t('尚无模型','No models observed')}</option>}{models.map(m=><option key={m} value={m}>{m}</option>)}</select></label>
   <button className="glass-button px-3 py-2 text-xs" disabled={busy||disabled||!!pending.current} onClick={()=>void choose()}>{workspace?t('更换工作目录','Change working directory'):t('选择工作目录','Choose working directory')}</button>
   <button className="glass-button-solid px-3 py-2 text-xs" disabled={busy||disabled||!!pending.current||!running||!workspace||!chosen||nativeUnavailable} onClick={()=>void start()}>{t('启动客户端','Launch client')}</button>
   <button className="glass-button px-3 py-2 text-xs" disabled={busy} onClick={()=>void read()}>{t('读取客户端状态','Read client state')}</button>
  </div>
  {workspace&&<p className="text-xs text-secondary">{t('工作目录','Working directory')} · {workspace.split('\\').join('/').split('/').filter(Boolean).slice(-1)[0]}</p>}
  {nativeUnavailable&&<p className="text-xs text-status-warn">{t('Windows Antigravity 原生 CLI 尚未验证；可使用 Codex CLI。','The Windows Antigravity CLI is not yet verified. Codex CLI is available as a choice.')}</p>}
  {unconfirmed&&<p role="alert" className="text-xs text-status-warn">{t('操作结果尚未确认。请读取状态；不会自动再次启动。','The result is unconfirmed. Read the state; launch will not be repeated automatically.')}</p>}
  <div className="space-y-2">{rows.map(row=><div key={row.requestId} className="rounded-lg border border-theme p-2 text-xs"><span>{row.provider} · {row.kind==='codex'?'Codex CLI':t('服务原生 CLI','Provider CLI')} · {row.model} · {stateText(row.state)}</span>{row.issueCode&&<p className="text-status-warn">{t('请检查所选工具、工作目录与账号池状态。退出未确认时，本应用会保留占用保护。','Check the selected tool, working directory and pool state. Unconfirmed cleanup retains the ownership guard.')}</p>}{['running','checking','cleanupUnconfirmed'].includes(row.state)&&<button className="glass-button ml-2 px-2 py-1" disabled={busy} onClick={()=>setStopId(row.requestId)}>{t('停止此客户端','Stop this client')}</button>}</div>)}</div>
  {stopId&&<div role="dialog" aria-label={t('确认停止客户端','Confirm client stop')} className="rounded-lg border border-theme p-3 text-xs space-y-2"><p>{t('将停止本应用启动的客户端及其子进程，未完成工作会中断。','Stop this app’s client and its child processes. Unfinished work will be interrupted.')}</p><button className="glass-button px-2 py-1 mr-2" onClick={()=>setStopId(null)}>{t('取消','Cancel')}</button><button className="glass-button px-2 py-1" disabled={busy} onClick={()=>void stop()}>{t('确认停止','Confirm stop')}</button></div>}
 </div>;
}
