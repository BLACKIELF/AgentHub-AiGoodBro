import { useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { Monitor, RefreshCw, Square } from 'lucide-react';
import { useI18n } from '../i18n/I18nProvider';
import type { ProxyAccount, ProxyPhase } from '../utils/localProxy';
import { parseProxyDesktopStatus, type ProxyDesktopStatus } from '../utils/proxyDesktop';

export function ProxyDesktopPanel({ accounts, accountsFresh, proxyPhase, parentBusy }: { accounts: ProxyAccount[] | null; accountsFresh: boolean; proxyPhase: ProxyPhase | null; parentBusy: boolean }) {
  const { language } = useI18n();
  const text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const [state, setState] = useState<ProxyDesktopStatus | null>(null);
  const [fresh, setFresh] = useState(false);
  const [selected, setSelected] = useState('');
  const [pending, setPending] = useState<'connect' | 'launch' | 'cancel' | null>(null);
  const [connecting, setConnecting] = useState(false);
  const [cancelRequested, setCancelRequested] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState('');
  const alive = useRef(false), generation = useRef(0), connectInFlight = useRef(false), cancellationIntent = useRef(false);
  const operation = useRef<object | null>(null), cancelPromise = useRef<Promise<ProxyDesktopStatus> | null>(null);
  const phase = fresh ? state?.phase : null;
  const active = phase === 'prepared' || phase === 'launched' || phase === 'stopping';
  const lastOwned = state && ['prepared', 'launched', 'stopping'].includes(state.phase);
  const accountId = lastOwned && state?.accountId ? state.accountId : selected;
  const account = accounts?.find(value => value.id === accountId);
  const errorCode = (failure: unknown) => {
    const value = typeof failure === 'string' ? failure : failure instanceof Error ? failure.message : '';
    return /^[a-z_]{1,80}$/.test(value) ? value : 'desktop_unavailable';
  };
  function apply(next: ProxyDesktopStatus) {
    setState(next); setFresh(true);
    if (next.phase === 'stopped' && cancellationIntent.current && !connectInFlight.current) { setCancelRequested(false); setError(null); setNotice(text('本次桌面接入已停止。', 'This Desktop connection is stopped.')); }
  }
  function errorText(code: string) {
    const messages: Record<string, [string, string]> = {
      desktop_running: ['请先自行退出正在运行的 Codex Desktop，再接入。', 'Quit the running Codex Desktop yourself, then connect again.'],
      desktop_state_unknown: ['无法确认现有 Desktop 状态，暂不接入。', 'The existing Desktop state is unconfirmed. Connection is unavailable.'],
      desktop_unavailable: ['未找到可验证的 Codex Desktop 或 CLI。', 'A verified Codex Desktop or CLI is unavailable.'],
      desktop_preparation_expired: ['桌面准备已过期，请重新接入。', 'Desktop preparation expired. Connect again.'],
      desktop_launch_failed: ['Desktop 未能启动，请检查后重试。', 'Desktop could not start. Check it and retry.'],
      desktop_connection_stale: ['反代连接已变化。请先停止本应用启动的 Desktop，再重新接入。', 'The proxy connection changed. Stop the Desktop launched by this app, then reconnect.'],
      lease_cleanup_unconfirmed: ['停止结果尚未确认，请刷新或重试停止。', 'Stopping is unconfirmed. Refresh or retry stopping.'],
      control_busy: ['接入流程仍在处理，请稍后重试。', 'The connection is still being processed. Try again shortly.'],
      identity: ['账号身份尚未确认，请刷新账号后重试。', 'The account identity is unconfirmed. Refresh accounts and retry.'],
      unavailable: ['反代连接暂不可用，请刷新状态后重试。', 'The proxy connection is unavailable. Refresh status and retry.'],
    };
    const message = messages[code];
    return message ? text(...message) : text('桌面操作未完成，请刷新状态后重试。', 'The Desktop operation did not complete. Refresh status and retry.');
  }
  async function readStatus() {
    const epoch = ++generation.current;
    try { const next = parseProxyDesktopStatus(await invoke('get_local_proxy_desktop_status')); if (alive.current && epoch === generation.current) apply(next); }
    catch { if (alive.current && epoch === generation.current) setFresh(false); }
  }
  useEffect(() => {
    alive.current = true;
    let disposed = false, polling = false;
    const epoch = ++generation.current;
    void invoke('get_local_proxy_desktop_status').then(raw => { if (!disposed && alive.current && epoch === generation.current) apply(parseProxyDesktopStatus(raw)); }).catch(() => { if (!disposed) setFresh(false); });
    const timer = setInterval(async () => {
      if (disposed || operation.current || polling) return;
      polling = true; await readStatus(); polling = false;
    }, 1500);
    return () => { disposed = true; alive.current = false; generation.current++; clearInterval(timer); };
    // Navigation preserves this panel. Desktop is stopped only by an explicit
    // cancel action or the app's native owned-process exit flow.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function start(kind: 'connect' | 'launch') {
    if (operation.current || connectInFlight.current || cancelRequested || !fresh || !account || !accountsFresh || proxyPhase !== 'running' || parentBusy) return;
    if (kind === 'launch' && (state?.phase !== 'prepared' || !state.launchId)) return;
    const token = {}, epoch = ++generation.current;
    operation.current = token; cancellationIntent.current = false; connectInFlight.current = true;
    setPending(kind); setConnecting(true); setCancelRequested(false); setError(null); setNotice('');
    try {
      const next = parseProxyDesktopStatus(await invoke(kind === 'connect' ? 'connect_local_proxy_desktop' : 'launch_local_proxy_desktop', kind === 'connect' ? { accountId: account.id } : { ticket: state!.launchId }));
      if (alive.current && epoch === generation.current) apply(next);
    } catch (failure) { if (alive.current && epoch === generation.current) { setError(errorCode(failure)); await readStatus(); } }
    finally {
      // Cancellation also covers a start that completes after its first cancel
      // reply. No new connect can race this bounded, connector-owned cleanup.
      if (cancellationIntent.current) {
        await cancelPromise.current?.catch(() => undefined);
        try {
          const stopped = parseProxyDesktopStatus(await invoke('cancel_local_proxy_desktop'));
          if (alive.current && cancellationIntent.current) { apply(stopped); setCancelRequested(stopped.phase !== 'stopped'); if (stopped.phase === 'stopped') setError(null); setNotice(stopped.phase === 'stopped' ? text('本次桌面接入已停止。', 'This Desktop connection is stopped.') : ''); }
        } catch (failure) { if (alive.current) { setCancelRequested(true); setError(errorCode(failure)); } }
      }
      connectInFlight.current = false;
      if (alive.current) { setConnecting(false); if (operation.current === token) { operation.current = null; setPending(null); } }
    }
  }
  async function cancel() {
    if (cancelPromise.current || connectInFlight.current && cancellationIntent.current) return;
    const token = {}, epoch = ++generation.current;
    operation.current = token; cancellationIntent.current = true;
    setPending('cancel'); setCancelRequested(true); setError(null); setNotice('');
    const request = invoke('cancel_local_proxy_desktop').then(parseProxyDesktopStatus);
    cancelPromise.current = request;
    try {
      const next = await request;
      if (alive.current && epoch === generation.current) {
        apply(next);
        if (!connectInFlight.current && next.phase === 'stopped') { setCancelRequested(false); setNotice(text('本次桌面接入已停止。', 'This Desktop connection is stopped.')); }
      }
    } catch (failure) { if (alive.current && epoch === generation.current) setError(errorCode(failure)); }
    finally {
      if (cancelPromise.current === request) cancelPromise.current = null;
      if (alive.current && operation.current === token) { operation.current = null; setPending(null); }
    }
  }

  const statusLabel = connecting ? cancelRequested ? text('正在完成取消…', 'Completing cancellation…') : text('正在接入桌面…', 'Connecting Desktop…') : !fresh ? text('状态待确认', 'Status unconfirmed') : phase === 'prepared' ? text('已准备，尚未启动', 'Prepared, not started') : phase === 'launched' ? text('Desktop 已启动', 'Desktop launched') : phase === 'stopping' ? text('正在停止', 'Stopping') : phase === 'failed' ? text('接入未完成', 'Connection incomplete') : text('未接入', 'Not connected');
  const canCancel = lastOwned || connecting || cancelRequested || state?.phase === 'failed' && !!state.launchId;
  const busy = pending !== null || connecting;
  return <section className="proxy-desktop-panel" aria-label={text('桌面接入', 'Desktop connection')} aria-busy={busy} data-desktop-phase={phase ?? 'unknown'}>
    <header><h3><Monitor size={14} />Codex Desktop</h3><span role="status">{statusLabel}</span><button type="button" className="icon-action" disabled={busy} aria-label={text('刷新桌面状态', 'Refresh Desktop status')} title={text('刷新桌面状态', 'Refresh Desktop status')} onClick={() => void readStatus()}><RefreshCw size={13} /></button></header>
    <div className="proxy-desktop-actions"><label htmlFor="proxy-desktop-account">{text('桌面账号', 'Desktop account')}</label><select id="proxy-desktop-account" value={accountId} disabled={busy || !!lastOwned || !accountsFresh || accounts === null} onChange={event => setSelected(event.target.value)}><option value="">{text('选择托管账号', 'Choose a managed account')}</option>{accounts?.map(value => <option key={value.id} value={value.id}>{value.label}</option>)}</select><button type="button" className="glass-button proxy-action" disabled={busy || cancelRequested || parentBusy || !fresh || !accountsFresh || !account || proxyPhase !== 'running' || active && phase !== 'prepared'} onClick={() => void start(phase === 'prepared' ? 'launch' : 'connect')}><Monitor size={13} />{phase === 'prepared' ? text('启动桌面', 'Launch Desktop') : text('接入桌面', 'Connect Desktop')}</button>{canCancel && <button type="button" className="glass-button proxy-action" disabled={pending === 'cancel' || connecting && cancelRequested} onClick={() => void cancel()}><Square size={13} />{phase === 'prepared' ? text('取消准备', 'Cancel preparation') : text('停止本应用启动的 Desktop', 'Stop Desktop launched by this app')}</button>}</div>
    {active && <p className="proxy-note">{state?.routingVerified === true && phase === 'launched' ? text('原生已回报路由验证。', 'Native routing verification was reported.') : state?.routingVerified === false ? text('路由验证未通过。', 'Routing verification has not passed.') : text('路由尚未验证。', 'Routing has not been verified.')}</p>}
    {proxyPhase !== 'running' && <p className="proxy-note">{text('请先启动反代，再选择账号接入桌面。', 'Start the proxy, then choose an account to connect Desktop.')}</p>}
    {canCancel && <p className="proxy-note">{text('只停止本应用启动的桌面进程。停止反代后，旧桌面连接需要重新接入。', 'Only the Desktop process launched by this app is stopped. After stopping the proxy, reconnect the old Desktop connection.')}</p>}
    {cancelRequested && !connecting && <p className="proxy-note" role="status">{text('停止结果待确认。', 'Stopping is not yet confirmed.')}</p>}
    {state?.issue && fresh && <p className="proxy-feedback is-error" role="alert">{errorText(state.issue)}</p>}{error && error !== state?.issue && <p className="proxy-feedback is-error" role="alert">{errorText(error)}</p>}{notice && <p className="proxy-note" role="status">{notice}</p>}
  </section>;
}
