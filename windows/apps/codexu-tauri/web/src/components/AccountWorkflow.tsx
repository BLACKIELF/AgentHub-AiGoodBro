import { useCallback, useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { open } from '@tauri-apps/plugin-dialog';
import { useI18n } from '../i18n/I18nProvider';
import { acceptWorkflowState, parseWorkflowModels, parseWorkflowState, workflowError, type AccountWorkflowState, type WorkflowModel } from '../utils/accountWorkflow';

export function AccountWorkflow({ profileId, initiallyExpanded = true }: { profileId: string; initiallyExpanded?: boolean }) {
  const { language } = useI18n();
  const chinese = language === 'zh-Hans';
  const text = (zh: string, en: string) => chinese ? zh : en;
  const [state, setState] = useState<AccountWorkflowState | null>(null);
  const [models, setModels] = useState<WorkflowModel[]>([]);
  const [expanded, setExpanded] = useState(initiallyExpanded);
  const [saving, setSaving] = useState(false);
  const [starting, setStarting] = useState(false);
  const [readingModels, setReadingModels] = useState(false);
  const [stopping, setStopping] = useState(false);
  const [confirmStop, setConfirmStop] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const alive = useRef(false), savePending = useRef(false), launchPending = useRef(false), modelsPending = useRef(false);
  const apply = useCallback((raw: unknown) => {
    const result = parseWorkflowState(raw, profileId);
    if (alive.current) setState(previous => acceptWorkflowState(previous, result));
  }, [profileId]);
  const reload = useCallback(async () => {
    try { apply(await invoke('get_account_workflow', { id: profileId })); }
    catch (failure) { if (alive.current) setError(failure); }
  }, [profileId, apply]);
  useEffect(() => {
    alive.current = true; setState(null); setModels([]); setError(null); void reload();
    return () => { alive.current = false; };
  }, [reload]);
  useEffect(() => {
    if (!state || !['running', 'checking'].includes(state.phase)) return;
    const timer = window.setInterval(() => { void reload(); }, 2000);
    return () => window.clearInterval(timer);
  }, [state?.phase, reload]);
  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | undefined;
    void listen('workflow:exit-blocked', () => {
      if (alive.current && (state?.phase === 'running' || state?.phase === 'checking' || launchPending.current)) {
        setExpanded(true); setError('exit_blocked');
      }
    }).then(release => { if (disposed) release(); else unlisten = release; }).catch(() => {});
    return () => { disposed = true; unlisten?.(); };
  }, [state?.phase]);

  async function save(action: Record<string, unknown>) {
    if (savePending.current) return;
    savePending.current = true; setSaving(true); setError(null);
    try { apply(await invoke('set_account_workflow', { id: profileId, action })); }
    catch (failure) { if (alive.current) setError(failure); }
    finally { savePending.current = false; if (alive.current) setSaving(false); }
  }
  async function readModels() {
    if (modelsPending.current) return;
    modelsPending.current = true; setReadingModels(true); setError(null);
    try { const rows = parseWorkflowModels(await invoke('read_workflow_models', { id: profileId })); if (alive.current) setModels(rows); }
    catch (failure) { if (alive.current) setError(failure); }
    finally { modelsPending.current = false; if (alive.current) setReadingModels(false); }
  }
  async function start() {
    if (launchPending.current) return;
    launchPending.current = true; setStarting(true); setError(null);
    try {
      const workspace = await open({ directory: true, multiple: false, title: text('选择这次任务的工作目录', 'Choose a workspace for this session') });
      if (!workspace || !alive.current) return;
      apply(await invoke('start_account_terminal', { id: profileId, workspace }));
    } catch (failure) { if (alive.current) setError(failure); }
    finally { launchPending.current = false; if (alive.current) { setStarting(false); void reload(); } }
  }
  async function stop() {
    if (stopping) return;
    setStopping(true); setError(null);
    try { apply(await invoke('stop_account_terminal', { id: profileId })); if (alive.current) setConfirmStop(false); }
    catch (failure) { if (alive.current) setError(failure); }
    finally { if (alive.current) setStopping(false); }
  }
  const preference = state?.preference;
  const active = state?.phase === 'running' || state?.phase === 'checking';
  const selected = models.find(model => model.id === preference?.model) ?? (preference?.model === null ? models.find(model => model.is_default) : undefined);
  const phase = state?.phase;
  const status = phase === 'running' ? text('终端运行中', 'Terminal running') : phase === 'checking' || starting ? text('启动检查中…', 'Checking before launch…')
    : phase === 'stopped' ? text('已结束', 'Stopped') : phase === 'exited' ? text('终端已退出', 'Terminal exited') : text('未运行', 'Not running');
  return <section className="w-full min-w-0 border-t border-theme pt-3 mt-1" data-testid={`account-workflow-${profileId}`} aria-label={text('模型与调度', 'Model and scheduling')}>
    <button type="button" className="flex w-full items-center justify-between gap-3 text-left text-xs font-semibold text-primary" aria-expanded={expanded} aria-controls={`workflow-content-${profileId}`} onClick={() => setExpanded(value => !value)}>
      <span>{expanded ? '⌄' : '›'} {text('模型与调度', 'Model and scheduling')}</span><span className="font-normal text-secondary">{status}</span>
    </button>
    {expanded && <div id={`workflow-content-${profileId}`} className="pt-3 space-y-3">
      {state ? <>
        <div className="flex flex-wrap items-center justify-between gap-x-6 gap-y-3">
          <label className="flex items-center gap-2 text-sm text-primary">
            <input type="checkbox" role="switch" className="accent-blue-500 h-4 w-4" checked={preference?.participating ?? false} disabled={saving} onChange={event => void save({ kind: 'participation', value: event.target.checked })} />
            {text('参与调度', 'Participate in scheduling')}
          </label>
          <span className="text-xs text-secondary">{saving ? text('正在保存…', 'Saving…') : text('关闭后停止接收新启动；已打开的终端可单独结束。', 'Off prevents new launches; open terminals can be stopped separately.')}</span>
        </div>
        <div className="flex flex-wrap items-end gap-2">
          <label className="min-w-0 flex-1 basis-48 text-xs text-secondary">{text('模型', 'Model')}
            <select className="mt-1 block w-full rounded-lg border border-theme bg-surface-inset px-2 py-2 text-sm text-primary" aria-label={text('模型', 'Model')} value={preference?.model ?? ''} disabled={saving || readingModels || models.length === 0} onChange={event => {
              const model = models.find(row => row.id === event.target.value);
              void save({ kind: 'selection', model: model?.id ?? null, effort: model?.default_effort ?? null });
            }}>
              <option value="">{text('使用官方默认模型', 'Use official default model')}</option>
              {preference?.model && !models.some(model => model.id === preference.model) && <option value={preference.model}>{preference.model}</option>}
              {models.map(model => <option key={model.id} value={model.id}>{model.label}</option>)}
            </select>
          </label>
          <label className="text-xs text-secondary">{text('思考强度', 'Reasoning effort')}
            <select className="mt-1 block rounded-lg border border-theme bg-surface-inset px-2 py-2 text-sm text-primary" aria-label={text('思考强度', 'Reasoning effort')} value={preference?.effort ?? selected?.default_effort ?? ''} disabled={saving || !selected} onChange={event => void save({ kind: 'selection', model: selected?.id, effort: event.target.value })}>
              {!selected && <option value={preference?.effort ?? ''}>{preference?.effort ?? '—'}</option>}
              {selected?.efforts.map(effort => <option key={effort} value={effort}>{effort}</option>)}
            </select>
          </label>
          <button type="button" className="glass-button px-3 py-2 text-xs" disabled={readingModels || !state.supported} onClick={() => void readModels()}>{readingModels ? text('读取中…', 'Reading…') : text('读取可用模型', 'Read available models')}</button>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <button type="button" className="glass-button-solid px-3 py-2 text-xs" disabled={!state.supported || !preference?.participating || active || starting || saving} onClick={() => void start()}>{starting ? text('正在准备…', 'Preparing…') : text('选择工作目录并打开 Codex', 'Choose workspace and open Codex')}</button>
          {(active || starting) && <button type="button" className="glass-button px-3 py-2 text-xs" disabled={stopping} onClick={() => setConfirmStop(true)}>{text('结束此终端', 'Stop this terminal')}</button>}
          <button type="button" className="glass-button px-3 py-2 text-xs" onClick={() => { setError(null); void reload(); }}>{text('刷新状态', 'Refresh status')}</button>
        </div>
        <p className="text-xs leading-relaxed text-secondary">{text('使用此账号目录打开独立终端，由你在终端中输入任务；这里不会自动提交提示词。模型设置用于下一次启动。退出 AiGoodBro 前，请先在终端中退出或在此结束终端。', 'Opens an independent terminal for this account directory; enter your task there. No prompt is submitted automatically. Model settings apply to the next launch. Exit the terminal or stop it here before quitting AiGoodBro.')}</p>
        {!state.supported && <p className="text-xs text-secondary">{text('启动功能仅在 Windows 桌面版可用。', 'Terminal launch is available in the Windows desktop app.')}</p>}
      </> : <p className="text-xs text-secondary">{text('正在读取调度设置…', 'Reading workflow settings…')} <button className="underline" onClick={() => { setError(null); void reload(); }}>{text('重新读取', 'Reload')}</button></p>}
      {confirmStop && <div role="group" aria-label={text('确认结束终端', 'Confirm terminal stop')} className="rounded-lg border border-theme p-3 space-y-2 text-xs" onKeyDown={event => { if (event.key === 'Escape') setConfirmStop(false); }}>
        <p>{text('将结束本应用为此账号打开的终端及其子进程，未完成的任务会中断。', 'Closes this app’s terminal for the account and its child processes. Unfinished work will be interrupted.')}</p>
        <button className="glass-button px-3 py-1 mr-2" disabled={stopping} onClick={() => void stop()}>{text('确认结束', 'Confirm stop')}</button>
        <button className="glass-button px-3 py-1" disabled={stopping} onClick={() => setConfirmStop(false)}>{text('取消', 'Cancel')}</button>
      </div>}
      {error !== null && <p role="alert" className="text-xs text-status-error">{workflowError(error, chinese)}</p>}
    </div>}
  </section>;
}
