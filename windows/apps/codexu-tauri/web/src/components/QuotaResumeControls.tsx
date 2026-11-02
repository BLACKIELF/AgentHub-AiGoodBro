import { useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { useI18n } from '../i18n/I18nProvider';
import { automaticFailureText } from '../utils/automaticSwitch';
import { localCliFailure } from '../utils/localCliActions';

export interface QuotaResumeState {
  batchId: string | null;
  phase: 'empty' | 'ready' | 'recovery' | 'submitted' | 'abandoned';
  pendingCount: number;
  uncertainCount: number;
  canResume: boolean;
  canClear: boolean;
  busy: boolean;
}

function parse(raw: unknown): QuotaResumeState {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw Error('automatic_switch_unavailable');
  const value = raw as Record<string, unknown>;
  if (Object.keys(value).some(key => !['batchId', 'phase', 'pendingCount', 'uncertainCount', 'canResume', 'canClear', 'busy'].includes(key))
    || value.batchId !== null && (typeof value.batchId !== 'string' || !/^[a-f0-9]{32}$/.test(value.batchId))
    || !['empty', 'ready', 'recovery', 'submitted', 'abandoned'].includes(String(value.phase))
    || ['pendingCount', 'uncertainCount'].some(key => !Number.isInteger(value[key]) || Number(value[key]) < 0 || Number(value[key]) > 128)
    || ['canResume', 'canClear', 'busy'].some(key => typeof value[key] !== 'boolean')) throw Error('automatic_switch_unavailable');
  return value as unknown as QuotaResumeState;
}

export function QuotaResumeControls({ available }: { available: boolean }) {
  const { language } = useI18n();
  const text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const [state, setState] = useState<QuotaResumeState | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [confirmClear, setConfirmClear] = useState(false);
  const alive = useRef(false), sequence = useRef(0), pending = useRef<object | null>(null);
  const read = async () => {
    if (!alive.current || pending.current) return;
    const id = ++sequence.current;
    try {
      const next = parse(await invoke('get_quota_resume_state'));
      if (alive.current && sequence.current === id && !pending.current) { setState(next); setError(null); }
    } catch (failure) { if (alive.current && sequence.current === id) setError(localCliFailure(failure)); }
  };
  useEffect(() => {
    if (!available) return;
    alive.current = true;
    let disposed = false, unlisten: (() => void) | undefined;
    void read();
    void listen('automatic-switch:changed', () => void read()).then(fn => { if (disposed) fn(); else unlisten = fn; });
    const timer = window.setInterval(() => void read(), 3000);
    return () => { disposed = true; alive.current = false; sequence.current++; window.clearInterval(timer); unlisten?.(); };
  }, [available]);
  useEffect(() => { setConfirmClear(false); }, [state?.batchId, state?.phase]);
  const run = async (command: 'resume_quota_tasks' | 'clear_quota_resume' | 'cancel_quota_resume') => {
    if (!state?.batchId || pending.current && command !== 'cancel_quota_resume') return;
    const token = {}, id = ++sequence.current;
    pending.current = token; setBusy(true); setError(null); setConfirmClear(false);
    try {
      const next = parse(await invoke(command, command === 'cancel_quota_resume' ? {} : { batchId: state.batchId }));
      if (alive.current && sequence.current === id) setState(next);
    } catch (failure) { if (alive.current && sequence.current === id) setError(localCliFailure(failure)); }
    finally {
      if (pending.current === token) { pending.current = null; if (alive.current) { setBusy(false); void read(); } }
    }
  };
  if (!available || !state && !error || state?.phase === 'empty' || state?.phase === 'abandoned') return null;
  return <section className="glass-panel p-3" data-testid="quota-resume-controls" aria-label={text('暂停任务续做', 'Paused task recovery')}>
    <p className="font-medium text-sm">{text('暂停任务续做', 'Paused task recovery')}</p>
    {state?.phase === 'ready' && <p className="proxy-note">{text(`${state.pendingCount} 个原任务已暂停。打开切换后的 Codex 原聊天，再继续任务。`, `${state.pendingCount} original tasks are paused. Open their original chats in Codex under the switched account, then continue.`)}</p>}
    {state?.phase === 'recovery' && <p className="proxy-note">{text('暂停或切换尚未完整确认。请先检查原聊天；记录会保留，任务不会自动重跑。', 'The pause or switch is not fully confirmed. Check the original chats. Records are retained and tasks are not replayed automatically.')}</p>}
    {state?.phase === 'submitted' && <p role="status" className="proxy-note">{text('续做请求已处理，请在原聊天查看进度。', 'Continuation requests have been handled. Check progress in the original chats.')}</p>}
    {!!state?.uncertainCount && <p className="proxy-note">{text(`${state.uncertainCount} 项请求结果未确认，不会自动重试。`, `${state.uncertainCount} request outcomes are uncertain and will not be retried automatically.`)}</p>}
    {error && <p className="proxy-note" role="alert">{automaticFailureText(error, text)}</p>}
    <div className="flex flex-wrap gap-2">
      {state?.canResume && <button className="glass-button-solid proxy-action" disabled={busy || state.busy} onClick={() => void run('resume_quota_tasks')}>{text('继续原任务', 'Continue original tasks')}</button>}
      {(busy || state?.busy) && <button className="glass-button proxy-action" onClick={() => void run('cancel_quota_resume')}>{text('停止后续续做', 'Stop further continuations')}</button>}
      {state?.canClear && !confirmClear && <button className="glass-button proxy-action" disabled={busy || state.busy} onClick={() => setConfirmClear(true)}>{text('清除续做记录', 'Clear recovery records')}</button>}
    </div>
    {confirmClear && <div className="mt-2"><p className="proxy-note">{text('清除后，这批任务不会再由此处续做。原聊天和正在运行的任务会保留。', 'Clearing removes this batch from recovery here. The original chats and running tasks are retained.')}</p><div className="flex gap-2"><button className="glass-button proxy-action" disabled={busy || state?.busy} onClick={() => void run('clear_quota_resume')}>{text('确认清除记录', 'Confirm clearing records')}</button><button className="glass-button proxy-action" onClick={() => setConfirmClear(false)}>{text('保留记录', 'Keep records')}</button></div></div>}
  </section>;
}
