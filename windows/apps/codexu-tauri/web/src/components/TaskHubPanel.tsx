import {validAccountDisplayLabel} from '../utils/accountMetadata';
import { useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { useI18n } from '../i18n/I18nProvider';
import { hubTerminal, parseHubView, type HubAction, type HubTask, type HubView } from '../utils/taskHub';
function ResolveTaskDialog({ task, current, onCancel, onConfirm }: { task: HubTask; current: boolean; onCancel: () => void; onConfirm: () => void }) {
  const { language } = useI18n(), text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const [step, setStep] = useState<1 | 2>(1), [checked, setChecked] = useState(false);
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => { const node = dialog.current, previous = document.activeElement; node?.showModal(); return () => { node?.close(); if (previous instanceof HTMLElement && previous.isConnected) previous.focus(); }; }, []);
  return <dialog ref={dialog} className="managed-switch-dialog" aria-label={text('确认任务进程已停止', 'Confirm task processes stopped')} onCancel={event => { event.preventDefault(); onCancel(); }}>
    <section className="space-y-3 text-sm p-1">
      <h3 className="font-semibold text-primary">{step === 1 ? text('第一次确认：核对进程状态', 'Confirmation 1: check process state') : text('第二次确认：解除任务占用', 'Confirmation 2: release task reservation')}</h3>
      <p className="break-all text-secondary">{task.id}</p>
      <p>{text('任务执行结果不确定。请先核对该任务的执行窗口和进程，确认它及其子进程均已停止。', 'The task outcome is uncertain. Check its execution window and processes, and confirm that it and its child processes have stopped.')}</p>
      <p className="text-secondary">{text('此操作不会停止进程、不会把任务记为成功，也不会自动重跑；它只在确认停止后解除占用。', 'This does not stop processes, mark the task successful or run it again. It only releases the reservation after stopped processes are confirmed.')}</p>
      {!current && <p role="alert" className="text-status-warn">{text('任务状态已变化，请取消并刷新后重新核对。', 'The task state changed. Cancel and refresh before checking again.')}</p>}
      {step === 1 && <label className="flex items-start gap-2"><input type="checkbox" checked={checked} disabled={!current} onChange={event => setChecked(event.target.checked)} />{text('我已核对，该任务及子进程均已停止', 'I checked that this task and its child processes have stopped')}</label>}
      <div className="flex gap-2"><button className="glass-button px-3 py-2" onClick={onCancel}>{text('取消', 'Cancel')}</button>{step === 1 ? <button className="glass-button-solid px-3 py-2" disabled={!current || !checked} onClick={() => setStep(2)}>{text('已核对，进入最后确认', 'Checked; continue to final confirmation')}</button> : <button className="glass-button px-3 py-2 is-danger" disabled={!current} onClick={onConfirm}>{text('确认已停止并解除占用', 'Confirm stopped and release reservation')}</button>}</div>
    </section>
  </dialog>;
}
export function TaskHubPanel() {
  const { language } = useI18n(), text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const [view, setView] = useState<HubView | null>(null), [accounts, setAccounts] = useState<{id:string;label:string;platform:string}[]>([]), [profileId, setProfileId] = useState(''), [prompt, setPrompt] = useState(''), [busy, setBusy] = useState(false), [error, setError] = useState(''), [review, setReview] = useState<HubTask | null>(null), [messages, setMessages] = useState<{role:string;text:string}[]>([]), [resume, setResume] = useState<string | null>(null), [pending, setPending] = useState<HubAction | null>(null);
  const alive = useRef(false), running = useRef(false), reviewEpoch = useRef(0), accountsEpoch = useRef(0);
  const [accountsFresh, setAccountsFresh] = useState(false), [accountsFailed, setAccountsFailed] = useState(false);
  const [recovery, setRecovery] = useState<HubTask | null>(null);
  const label = (state:string) => ({awaiting_approval:text('待批准','Awaiting approval'),starting:text('正在启动','Starting'),running:text('进行中','Running'),cancel_requested:text('取消中','Cancelling'),succeeded:text('已完成','Completed'),failed:text('失败','Failed'),cancelled:text('已取消','Cancelled'),uncertain:text('需核对执行状态','Check execution state'),blocked_configuration:text('启动被阻止','Start blocked')}[state] ?? state);
  function message(e:unknown) {
    const code = typeof e === 'string' ? e : '';
    if (code === 'hub_model_required') return text('请先在账号的调度设置中选择模型和推理强度。','Choose a model and effort in the account scheduling settings first.');
    if (code.includes('dispatch_disabled')) return text('此账号未参与调度，或当前不在允许时间段。','This account is opted out or outside its allowed dispatch window.');
    if (code.includes('registration_required')) return text('请使用已登记并关联到主界面的 Codex 账号。','Use a registered Codex account linked to the Home view.');
    if (code.includes('quota')) return text('官方额度未满足派单条件，请刷新账号额度。','Provider allowance does not meet the dispatch requirement. Refresh account allowance.');
    if (code.includes('busy')) return text('账号或工作目录正在使用，请稍后重试。','The account or working directory is in use. Try again later.');
    if (code === 'hub_request_unconfirmed') return text('尚未收到操作回执。先刷新状态；重试会沿用同一个请求编号。','No operation receipt was received. Refresh status first; a retry uses the same request ID.');
    return text('任务操作未完成，请刷新状态后重试。','The task operation did not complete. Refresh status before retrying.');
  }
  async function call(command:string,args?:Record<string,unknown>,action?:HubAction) {
    if(running.current) return; running.current=true;setBusy(true);setError('');
    try {const result=parseHubView(await invoke(command,args));if(alive.current){setView(result); if(action){setPending(null);setReview(null);reviewEpoch.current++;if(action.kind==='create'||action.kind==='resume'){setPrompt('');setResume(null);}}}}
    catch(e){if(alive.current){setError(message(e));if(action)setPending(typeof e==='string'&&['hub_invalid_request','hub_not_found','hub_project_busy','hub_account_busy','hub_account_quota_reserve','hub_account_dispatch_disabled','hub_dispatch_policy_unavailable','hub_conflict','hub_dispatch_disabled','hub_model_required','hub_task_changed','source_changed'].includes(e)?null:action);}}
    finally{running.current=false;if(alive.current)setBusy(false);}
  }
  async function readAccounts() {
    const epoch = ++accountsEpoch.current; setAccountsFresh(false);
    try {
      const rows = await invoke<{id:string;label:string;platform:string}[]>('list_profiles');
      if (!Array.isArray(rows) || rows.length > 50 || rows.some(row => !row || typeof row.id !== 'string' || !/^[1-9][0-9]{0,19}$/.test(row.id) || !validAccountDisplayLabel(row.label) || typeof row.platform !== 'string') || new Set(rows.map(row => row.id)).size !== rows.length) throw Error('invalid_profiles');
      if (alive.current && epoch === accountsEpoch.current) {
        const codex = rows.filter(row => row.platform === 'codex'); setAccounts(codex); setAccountsFresh(true); setAccountsFailed(false);
        setProfileId(current => codex.some(row => row.id === current) ? current : '');
      }
    } catch { if (alive.current && epoch === accountsEpoch.current) { setAccountsFresh(false); setAccountsFailed(true); } }
  }
  useEffect(() => {
    alive.current = true; void call('get_task_hub'); void readAccounts();
    let disposed = false, unlisten: (() => void) | undefined;
    void listen('profiles:changed', () => void readAccounts()).then(stop => { if (disposed) stop(); else { unlisten = stop; void readAccounts(); } }).catch(() => {});
    return () => { disposed = true; unlisten?.(); alive.current = false; accountsEpoch.current++; reviewEpoch.current++; };
  }, []);
  useEffect(()=>{if(!view?.connected)return;const timer=window.setInterval(()=>{if(document.visibilityState==='visible'&&!running.current)void call('get_task_hub');},5000);return()=>window.clearInterval(timer);},[view?.connected]);
  async function openReview(task:HubTask) {
    const epoch=++reviewEpoch.current;setReview(task);setMessages([]);setError('');
    try {const raw=await invoke<{taskId:string;messages:{taskId:string;role:string;text:string}[]}>('get_task_hub_messages',{taskId:task.id});
      if(!raw||raw.taskId!==task.id||!Array.isArray(raw.messages)||raw.messages.length>10000||raw.messages.some(m=>!m||!['user','assistant'].includes(m.role)||typeof m.text!=='string'||m.text.length>1000000))throw Error('hub_invalid_response');
      if(alive.current&&reviewEpoch.current===epoch)setMessages(raw.messages.filter(m=>m.taskId===task.id));
    } catch(e){if(alive.current)setError(message(e));}
  }
  const send=(action:HubAction)=>{setPending(action);void call('task_hub_action',{action},action);};
  const tasks=view?.overview?.tasks ?? [], active=tasks.some(t=>!hubTerminal(t.state));
  const approveAllowed=messages.some(m=>m.role==='user')&&view?.overview?.tasks.some(t=>t.id===review?.id&&t.version===review.version&&t.actionHash===review.actionHash)&&review?.state==='awaiting_approval'&&!review.approvalExpired&&Date.parse(review.approvalExpiresAt)>Date.now();
  return <section className="glass-panel p-4 sm:p-5 space-y-3" aria-label={text('任务派单','Task dispatch')}>
    <header className="flex items-center justify-between gap-3"><h3 className="text-sm font-semibold text-primary">{text('任务派单','Task dispatch')}</h3><button className="glass-button px-3 py-1.5 text-xs" disabled={busy} onClick={()=>{void readAccounts();void call('get_task_hub');}}>{text('刷新状态','Refresh status')}</button></header>
    {!view?.connected ? <div className="flex flex-wrap items-end gap-2"><label className="text-xs text-secondary">{text('执行账号','Account')}<select aria-label={text('执行账号','Account')} className="block rounded-lg border border-theme bg-surface-inset p-2 text-primary" value={profileId} disabled={busy||!accountsFresh} onChange={e=>setProfileId(e.target.value)}><option value="">{text('选择已登记账号','Choose a registered account')}</option>{accounts.map(a=><option key={a.id} value={a.id}>{a.label}</option>)}</select></label><button className="glass-button px-3 py-2 text-xs" disabled={busy} onClick={()=>void call('select_task_hub_workspace')}>{view?.workspace ?? text('选择工作目录','Choose working directory')}</button><button className="glass-button-solid px-3 py-2 text-xs" disabled={busy||!accountsFresh||!profileId||!view?.workspace||view.supported===false} onClick={()=>void call('connect_task_hub',{profileId})}>{text('启用任务派单','Enable task dispatch')}</button></div> : <><div className="flex flex-wrap items-center gap-2 text-xs text-secondary"><span>{accounts.find(a=>a.id===view.profileId)?.label ?? view.profileId} · {view.workspace}</span><button className="glass-button px-2 py-1" disabled={busy||active} onClick={()=>void call('disconnect_task_hub')}>{text('停止派单服务','Stop dispatch service')}</button></div><label className="block text-xs text-secondary">{resume?text('续做说明','Follow-up instruction'):text('任务内容','Task instruction')}<textarea aria-label={text('任务内容','Task instruction')} className="mt-1 w-full min-h-24 rounded-xl border border-theme bg-surface-inset p-3 text-primary" value={prompt} disabled={busy||!!pending} maxLength={60000} onChange={e=>setPrompt(e.target.value)}/></label><div className="flex gap-2"><button className="glass-button-solid px-3 py-2 text-xs" disabled={busy||!prompt.trim()||!!pending} onClick={()=>send(resume?{kind:'resume',request_id:crypto.randomUUID(),task_id:resume,prompt}:{kind:'create',request_id:crypto.randomUUID(),prompt})}>{text('创建待批准任务','Create for approval')}</button>{resume&&<button className="glass-button px-3 py-2 text-xs" disabled={busy||!!pending} onClick={()=>setResume(null)}>{text('取消续做','Cancel follow-up')}</button>}</div><p className="text-xs text-tertiary">{text('任务获批准后才会运行，并可修改所选工作目录。','Work starts only after approval and may modify the selected working directory.')}</p></>}
    {accountsFailed&&<p role="alert" className="text-xs text-status-warn">{text('账号列表读取失败，请刷新后重试。','Could not read the account list. Refresh before trying again.')}</p>}
    {error&&<p role="alert" className="text-xs text-status-warn">{error}</p>}
    {pending&&<div className="flex items-center gap-2 text-xs"><span>{text('保留上次操作编号','Previous request ID retained')}</span><button className="glass-button px-2 py-1" disabled={busy} onClick={()=>send(pending)}>{text('重试同一操作','Retry same operation')}</button></div>}
    <div className="space-y-2">{tasks.map(task=><article key={task.id} className="rounded-xl border border-theme bg-surface-inset p-3 text-xs" aria-label={`${text('任务','Task')} ${task.id}`}><div className="flex justify-between gap-3"><span className="font-medium text-primary">{label(task.state)}</span><time className="text-tertiary">{new Date(task.updatedAt).toLocaleString(language==='zh-Hans'?'zh-CN':'en-GB',{timeZone:'Asia/Shanghai'})} UTC+8</time></div><p className="mt-1 text-tertiary break-all">{task.id}</p>{task.resultNote&&<p className="mt-1 text-secondary">{task.resultNote}</p>}{task.reasonCode==='operator_confirmed_stopped'&&<p className="mt-1 text-secondary">{text('已人工确认停止，任务未标记成功。后续续做仍需重新批准。','Stopped was confirmed by the operator; the task was not marked successful. Follow-up work still requires approval.')}</p>}<div className="mt-2 flex gap-2">{task.state==='awaiting_approval'&&<button className="glass-button-solid px-2 py-1" disabled={busy||!!pending||task.approvalExpired} onClick={()=>void openReview(task)}>{task.approvalExpired?text('审批已过期','Approval expired'):text('审阅并批准','Review and approve')}</button>}{['awaiting_approval','starting','running'].includes(task.state)&&<button className="glass-button px-2 py-1" disabled={busy||!!pending} onClick={()=>send({kind:'cancel',request_id:crypto.randomUUID(),task_id:task.id,expected_version:task.version})}>{text('取消任务','Cancel task')}</button>}{task.state==='uncertain'&&<button className="glass-button px-2 py-1" disabled={busy||!!pending} onClick={()=>setRecovery(task)}>{text('核对进程并解除占用','Check stopped processes')}</button>}{task.canResume&&hubTerminal(task.state)&&<button className="glass-button px-2 py-1" disabled={busy||!!pending} onClick={()=>{setResume(task.id);setPrompt('');}}>{text('继续任务','Continue task')}</button>}</div></article>)}</div>
    {review&&<div role="dialog" aria-label={text('批准任务','Approve task')} className="rounded-xl border border-theme bg-surface-elevated p-4 space-y-2 text-xs"><p>{text('允许此账号在所选工作目录执行这个任务？','Allow this account to execute this task in the selected working directory?')}</p><p className="text-secondary">{review.id} · {view?.workspace}</p>{messages.filter(m=>m.role==='user').map((m,i)=><p key={i} className="whitespace-pre-wrap rounded-lg bg-surface-inset p-2 text-primary">{m.text}</p>)}<p className="text-tertiary break-all">{text('操作指纹','Action fingerprint')} · {review.actionHash}</p><p>{text('审批截止','Approval deadline')} · {new Date(review.approvalExpiresAt).toLocaleString()}</p><div className="flex gap-2"><button className="glass-button-solid px-3 py-2" disabled={busy||!approveAllowed||!review.actionHash||!!pending} onClick={()=>send({kind:'approve',request_id:crypto.randomUUID(),task_id:review.id,action_hash:review.actionHash!})}>{text('批准并执行','Approve and run')}</button><button className="glass-button px-3 py-2" disabled={busy} onClick={()=>{reviewEpoch.current++;setReview(null);}}>{text('返回','Back')}</button></div></div>}
    {recovery&&<ResolveTaskDialog key={`${recovery.id}:${recovery.version}`} task={recovery} current={!busy&&!pending&&!!view?.overview?.tasks.some(t=>t.id===recovery.id&&t.version===recovery.version&&t.state==='uncertain')} onCancel={()=>setRecovery(null)} onConfirm={()=>{if(busy||pending||!view?.overview?.tasks.some(t=>t.id===recovery.id&&t.version===recovery.version&&t.state==='uncertain'))return;setRecovery(null);send({kind:'resolve',request_id:crypto.randomUUID(),task_id:recovery.id,expected_version:recovery.version,confirmed_stopped:true});}}/>}
  </section>;
}
