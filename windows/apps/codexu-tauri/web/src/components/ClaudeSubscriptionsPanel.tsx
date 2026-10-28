import { useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { ArrowRightLeft, Check, LayoutGrid, List, LogIn, RefreshCw, Save, X } from 'lucide-react';
import { useI18n } from '../i18n/I18nProvider';
import { QuotaRing } from './QuotaRing';
import { parseAccountOperation, parseManagedAccount, parseManagedAccounts, type ManagedAccount } from '../utils/managedAccounts';
import { isClaudeLoginPending, parseClaudeLogin, parseClaudePreparedSwitch, parseClaudeQuota, type ClaudeLoginAttempt, type ClaudeQuota } from '../utils/claudeSubscriptions';
import { readChoice, saveChoice, type AccountCardSize } from '../utils/workspacePreferences';

type Text = (zh: string, en: string) => string;
const failureCode = (failure: unknown) => { const code = typeof failure === 'string' ? failure : failure instanceof Error ? failure.message : ''; return /^[a-z_]{1,80}$/.test(code) ? code : 'operation_failed'; };
function failureText(code: string, text: Text) {
  const messages: Record<string, [string, string]> = {
    claude_cli_unavailable: ['未找到可验证的 Claude CLI。', 'A verified Claude CLI is unavailable.'], claude_login_required: ['请先在官方 Claude CLI 登录。', 'Sign in with the official Claude CLI first.'],
    claude_login_attempt_unavailable: ['登录记录不可保存，请重新登录。', 'This login is unavailable for saving. Sign in again.'], claude_login_attempt_expired: ['登录保存时间已过，请重新登录。', 'The verified login expired before saving. Sign in again.'],
    claude_reauthentication_required: ['订阅需要重新登录验证。', 'The subscription needs a new login verification.'], claude_credentials_expired: ['订阅登录已过期，请重新登录。', 'The subscription login expired. Sign in again.'],
    claude_identity_mismatch: ['订阅身份发生变化，操作未完成。', 'The subscription identity changed. The operation did not complete.'], claude_credentials_changed: ['读取期间订阅配置发生变化，结果未采用。', 'Subscription settings changed during the read. The result was not accepted.'],
    claude_current_account_not_saved: ['请先保存当前 Windows 订阅，再切换。', 'Save the current Windows subscription before switching.'], claude_quota_invalid: ['官方额度返回无效，请稍后重试。', 'The official quota response was invalid. Try again later.'],
    occupancy_unknown: ['任务占用尚未确认，暂不可操作。', 'Task occupancy is unconfirmed. Actions are unavailable.'], account_busy: ['另一个账号操作正在进行，请稍后重试。', 'Another account operation is in progress. Try again shortly.'],
    recovery_required: ['订阅状态需要恢复，暂不可操作。', 'The subscription state needs recovery. Actions are unavailable.'], cleanup_unconfirmed: ['取消后的清理尚未确认，请重试。', 'Cleanup after cancellation is unconfirmed. Retry.'],
    switch_ticket_expired: ['切换确认已过期，请重新检查。', 'The switch confirmation expired. Check again.'], switch_ticket_invalid: ['切换确认已失效，请重新检查。', 'The switch confirmation is no longer valid. Check again.'],
    duplicate_label: ['昵称已存在，请换一个。', 'That alias already exists. Choose another.'], invalid_label: ['请使用 64 字节以内的简短昵称。', 'Use a short alias of up to 64 bytes.'],
    claude_managed_policy_read_only: ['检测到托管策略，当前操作不可用。', 'Managed policy prevents this operation.'], claude_login_in_progress: ['官方登录仍在进行，请完成或取消。', 'The official login is in progress. Complete or cancel it.'],
  };
  const message = messages[code];
  return message ? text(...message) : text('订阅操作未完成，请刷新状态后重试。', 'The subscription operation did not complete. Refresh status and retry.');
}

function ClaudeQuotaView({ account, disabled, text, language }: { account: ManagedAccount; disabled: boolean; text: Text; language: string }) {
  const [quota, setQuota] = useState<ClaudeQuota | null>(null), [busy, setBusy] = useState(false), [failed, setFailed] = useState(false), [error, setError] = useState<string | null>(null);
  const [now, setNow] = useState(Date.now());
  const alive = useRef(false), generation = useRef(0), inFlight = useRef(false);
  useEffect(() => { alive.current = true; const timer = setInterval(() => setNow(Date.now()), 1000); return () => { alive.current = false; generation.current++; clearInterval(timer); }; }, []);
  const retryAt = quota?.server_retry_at === null || quota?.server_retry_at === undefined ? null : quota.server_retry_at * 1000;
  const retryPending = retryAt !== null && now < retryAt;
  const dated = quota?.windows.filter(window => window.resets_at !== null) ?? [];
  const current = !!quota && quota.state === 'available' && !failed && now >= quota.fetched_at && now - quota.fetched_at < 300000 && !(dated.length > 0 && dated.every(window => window.resets_at! <= now));
  const format = (value: number) => new Date(value).toLocaleString(language === 'zh-Hans' ? 'zh-CN' : 'en-GB', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false });
  async function read() {
    if (disabled || inFlight.current || retryPending) return;
    const epoch = ++generation.current;
    inFlight.current = true; setBusy(true); setError(null); setFailed(false);
    try { const next = parseClaudeQuota(await invoke('read_claude_subscription_quota', { accountId: account.id })); if (alive.current && epoch === generation.current) { setQuota(next); setNow(Date.now()); } }
    catch (failure) { if (alive.current && epoch === generation.current) { setFailed(true); setError(failureCode(failure)); } }
    finally { if (alive.current && epoch === generation.current) { inFlight.current = false; setBusy(false); } }
  }
  return <div className="claude-subscription-quota" aria-label={text('订阅额度', 'Subscription quota')}>
    <div className="claude-quota-heading"><button type="button" className="icon-action" disabled={disabled || busy || retryPending} aria-label={text('读取订阅额度', 'Read subscription quota')} title={text('读取订阅额度', 'Read subscription quota')} onClick={() => void read()}><RefreshCw size={13} className={busy ? 'animate-spin' : ''} /></button><span role="status">{busy ? text('正在读取…', 'Reading…') : !quota ? text('尚未读取', 'Not read yet') : quota.state === 'rate_limited' ? text('已限流', 'Rate limited') : quota.state === 'available' ? current ? text('已读取', 'Read') : text('上次快照', 'Last snapshot') : quota.state === 'needs_login' ? text('需要登录', 'Sign-in required') : quota.state === 'unsupported' ? text('未提供额度', 'Quota unavailable') : text('暂不可用', 'Unavailable')}</span></div>
    {error && <p className="proxy-feedback is-error" role="alert">{failureText(error, text)}</p>}
    {quota && <><p className="proxy-note">{quota.source_label} · {format(quota.fetched_at)}</p>{quota.plan_label && <p className="proxy-note">{quota.plan_label}</p>}
      {quota.windows.length > 0 ? <div className="account-quota-windows">{quota.windows.map((window, index) => <div className="account-quota-window" key={window.id}><QuotaRing label={window.label} remaining={100 - window.used_percent} stale={!current} secondary={index > 0} description={`${window.label} · ${!current ? text('上次快照剩余 ', 'Last snapshot remaining ') : text('剩余 ', 'Remaining ')}${Number((100 - window.used_percent).toFixed(1))}%`} /><p>{window.resets_at === null ? text('重置时间未知', 'Reset time unknown') : text('重置 ', 'Resets ') + format(window.resets_at)}</p></div>)}</div> : <p className="proxy-note">{text('官方未返回周期额度窗口，显示为未知。', 'No quota windows were returned by the official service. Quota remains unknown.')}</p>}
      {!current && quota.windows.length > 0 && <p className="proxy-note">{text('上次快照仅供参考，请重新读取。', 'This last snapshot is for reference. Read again.')}</p>}
      {retryAt !== null && <p className="proxy-note" role="status">{retryPending ? text('服务端要求等待至 ', 'The service requires waiting until ') : text('等待期已结束，可重新读取。上次截止 ', 'The waiting period ended; you can read again. Last deadline ')}{format(retryAt)}</p>}
    </>}
  </div>;
}

export function ClaudeSubscriptionsPanel() {
  const { language } = useI18n();
  const text: Text = (zh, en) => language === 'zh-Hans' ? zh : en;
  const [accounts, setAccounts] = useState<ManagedAccount[] | null>(null), [fresh, setFresh] = useState(false), [label, setLabel] = useState('');
  const [pending, setPending] = useState<string | null>(null), [error, setError] = useState<string | null>(null), [notice, setNotice] = useState('');
  const [attempt, setAttempt] = useState<ClaudeLoginAttempt | null>(null), [captureRevoked, setCaptureRevoked] = useState(false);
  const [confirmation, setConfirmation] = useState<{ accountId: string; label: string; expiresAt: number; mode: 'ready' | 'failed' | 'expired' | 'cancel_unconfirmed'; errorCode?: string } | null>(null);
  const [now, setNow] = useState(Date.now());
  const [layout, setLayout] = useState<'cards' | 'list'>(() => readChoice('aigoodbro.claude.subscriptions.layout', ['cards', 'list'], 'cards'));
  const [size, setSize] = useState<AccountCardSize>(() => readChoice('aigoodbro.claude.subscriptions.size', ['small', 'medium', 'large'], 'small'));
  const alive = useRef(false), listEpoch = useRef(0), loginEpoch = useRef(0), loginPolling = useRef(false);
  const operation = useRef<{ name: string; token: object } | null>(null), currentAttempt = useRef<ClaudeLoginAttempt | null>(null);
  const ticket = useRef<{ value: string; accountId: string; expiresAt: number } | null>(null), dialog = useRef<HTMLDialogElement>(null), invoker = useRef<HTMLButtonElement | null>(null);
  async function loadAccounts() {
    const epoch = ++listEpoch.current;
    try {
      const rows = parseManagedAccounts(await invoke('list_claude_subscriptions'));
      if (rows.some(row => row.platform !== 'claude')) throw Error('invalid_response');
      if (alive.current && epoch === listEpoch.current) { setAccounts(rows); setFresh(true); }
    } catch { if (alive.current && epoch === listEpoch.current) setFresh(false); }
  }
  function applyAttempt(next: ClaudeLoginAttempt) { currentAttempt.current = next; setAttempt(next); if (next.phase === 'failed' || next.error_code && next.error_code !== 'login_cancelled') setError(next.error_code ?? 'operation_failed'); }
  useEffect(() => {
    alive.current = true;
    let disposed = false, unlisten: (() => void) | undefined;
    async function initialize() {
      try { const release = await listen('claude-subscriptions:changed', () => { if (!disposed) void loadAccounts(); }); if (disposed) { release(); return; } unlisten = release; } catch { /* Explicit reads remain available. */ }
      if (!disposed) await loadAccounts();
    }
    void initialize();
    const timer = setInterval(async () => {
      if (disposed || operation.current) return;
      void loadAccounts();
      const current = currentAttempt.current;
      if (!current || !['starting', 'waiting', 'cancelling', 'verified'].includes(current.phase) || loginPolling.current) return;
      const epoch = loginEpoch.current; loginPolling.current = true;
      try { const next = parseClaudeLogin(await invoke('get_claude_subscription_login', { attemptId: current.attempt_id }), current.attempt_id); if (!disposed && alive.current && epoch === loginEpoch.current) applyAttempt(next); }
      catch { if (!disposed && alive.current && epoch === loginEpoch.current) { setCaptureRevoked(true); setError('claude_login_attempt_unavailable'); } }
      finally { loginPolling.current = false; }
    }, 1000);
    return () => { disposed = true; alive.current = false; listEpoch.current++; loginEpoch.current++; clearInterval(timer); unlisten?.(); const owned = currentAttempt.current; if (owned && (isClaudeLoginPending(owned) || owned.phase === 'verified')) void invoke('cancel_claude_subscription_login', { attemptId: owned.attempt_id }).catch(() => undefined); const ownedTicket = ticket.current; if (ownedTicket && operation.current?.name !== 'commit') void invoke('cancel_claude_subscription_switch', { ticket: ownedTicket.value }).catch(() => undefined); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useEffect(() => { if (!confirmation) return; const timer = setInterval(() => setNow(Date.now()), 250); return () => clearInterval(timer); }, [confirmation?.accountId]);
  useEffect(() => { const current = ticket.current; if (!current || now < current.expiresAt * 1000 || operation.current?.name === 'commit') return; ticket.current = null; setConfirmation(previous => previous ? { ...previous, mode: 'expired' } : null); void invoke('cancel_claude_subscription_switch', { ticket: current.value }).catch(() => undefined); }, [now]);
  useEffect(() => { const node = dialog.current; if (!confirmation || !node) return; if (!node.open) node.showModal(); return () => { if (node.open) node.close(); }; }, [confirmation?.accountId]);
  useEffect(() => { if (confirmation || pending || !invoker.current) return; const button = invoker.current; invoker.current = null; if (button.isConnected && !button.disabled) button.focus(); }, [confirmation, pending]);
  async function run(name: string, action: () => Promise<void>) {
    if (operation.current) return;
    const token = {}; operation.current = { name, token }; setPending(name); setError(null); setNotice('');
    try { await action(); } catch (failure) { if (alive.current) setError(failureCode(failure)); }
    finally { if (alive.current && operation.current?.token === token) { operation.current = null; setPending(null); } }
  }
  async function begin() {
    if (operation.current || isClaudeLoginPending(currentAttempt.current) || currentAttempt.current?.phase === 'verified' || currentAttempt.current?.error_code === 'cleanup_unconfirmed' || ticket.current) return;
    const epoch = ++loginEpoch.current; setCaptureRevoked(false); currentAttempt.current = null; setAttempt(null);
    await run('begin', async () => { const next = parseClaudeLogin(await invoke('begin_claude_subscription_login')); if (!alive.current) { void invoke('cancel_claude_subscription_login', { attemptId: next.attempt_id }).catch(() => undefined); return; } if (epoch === loginEpoch.current) applyAttempt(next); });
  }
  async function cancelLogin() {
    const current = currentAttempt.current; if (!current || operation.current) return;
    const epoch = ++loginEpoch.current; setCaptureRevoked(true);
    await run('cancel-login', async () => { const next = parseClaudeLogin(await invoke('cancel_claude_subscription_login', { attemptId: current.attempt_id }), current.attempt_id); if (alive.current && epoch === loginEpoch.current) applyAttempt(next); });
  }
  async function capture(fromLogin: boolean) {
    if (!fresh || fromLogin && (currentAttempt.current?.phase !== 'verified' || captureRevoked)) return;
    await run('capture', async () => {
      const alias = label.trim(); if (!alias || new TextEncoder().encode(alias).length > 64 || /[\x00-\x1f\x7f@/\\:]/.test(alias)) throw Error('invalid_label');
      const next = parseManagedAccount(await invoke('capture_claude_subscription', { label: alias, attemptId: fromLogin ? currentAttempt.current!.attempt_id : null }));
      if (next.platform !== 'claude') throw Error('invalid_response');
      if (!alive.current) return;
      setAccounts(previous => previous?.some(row => row.id === next.id) ? previous.map(row => row.id === next.id ? next : row) : [...previous ?? [], next]);
      setLabel(''); setNotice(text('订阅身份已保存。', 'The subscription identity is saved.'));
      if (fromLogin && currentAttempt.current) { loginEpoch.current++; applyAttempt({ ...currentAttempt.current, phase: 'saved', error_code: null }); }
      await loadAccounts();
    });
  }
  async function prepare(account: ManagedAccount, button: HTMLButtonElement) {
    if (!fresh || !account.can_switch || operation.current) return;
    invoker.current = button;
    await run('prepare', async () => {
      const next = parseClaudePreparedSwitch(await invoke('prepare_claude_subscription_switch', { accountId: account.id }), account.id);
      if (!alive.current) { if (next.ticket) void invoke('cancel_claude_subscription_switch', { ticket: next.ticket }).catch(() => undefined); return; }
      if (next.phase === 'already_current') { setNotice(text('此订阅已是当前身份，已由官方回读核实。', 'This subscription is already current, confirmed by the official readback.')); await loadAccounts(); return; }
      ticket.current = { value: next.ticket!, accountId: account.id, expiresAt: next.expires_at! }; setNow(Date.now()); setConfirmation({ accountId: account.id, label: account.label, expiresAt: next.expires_at!, mode: 'ready' }); await loadAccounts();
    });
  }
  async function cancelSwitch() {
    if (operation.current) return; const current = ticket.current; if (!current) { setConfirmation(null); return; }
    setConfirmation(previous => previous ? { ...previous, mode: 'cancel_unconfirmed' } : null);
    await run('cancel-switch', async () => { try { parseAccountOperation(await invoke('cancel_claude_subscription_switch', { ticket: current.value }), current.accountId, 'cancelled'); if (alive.current) { ticket.current = null; setConfirmation(null); setNotice(text('切换已取消。', 'Switch cancelled.')); await loadAccounts(); } } catch (failure) { if (alive.current && ['switch_ticket_invalid', 'switch_ticket_expired'].includes(failureCode(failure))) { ticket.current = null; setConfirmation(previous => previous ? { ...previous, mode: 'expired' } : null); } throw failure; } });
  }
  async function commit() {
    const current = ticket.current; if (!current || confirmation?.mode !== 'ready' || current.expiresAt * 1000 <= Date.now()) return;
    await run('commit', async () => {
      try { parseAccountOperation(await invoke('commit_claude_subscription_switch', { ticket: current.value }), current.accountId, 'verified'); if (alive.current) { ticket.current = null; setConfirmation(null); setNotice(text('订阅切换已由官方回读验证。', 'The subscription switch was verified by the official readback.')); await loadAccounts(); } }
      catch (failure) { let released = false; try { parseAccountOperation(await invoke('cancel_claude_subscription_switch', { ticket: current.value }), current.accountId, 'cancelled'); released = true; } catch (cleanup) { released = ['switch_ticket_invalid', 'switch_ticket_expired'].includes(failureCode(cleanup)); } if (alive.current) { if (released) ticket.current = null; setConfirmation(previous => previous ? { ...previous, mode: released ? 'failed' : 'cancel_unconfirmed', errorCode: failureCode(failure) } : null); await loadAccounts(); } throw failure; }
    });
  }
  const loginActive = isClaudeLoginPending(attempt), verifiedAttempt = attempt?.phase === 'verified', cleanupUnconfirmed = attempt?.error_code === 'cleanup_unconfirmed';
  const blocked = pending !== null || loginActive || verifiedAttempt || cleanupUnconfirmed || confirmation !== null;
  const seconds = confirmation ? Math.max(0, Math.ceil((confirmation.expiresAt * 1000 - now) / 1000)) : 0;
  const phases = { starting: text('正在启动官方登录…', 'Starting the official login…'), waiting: text('请在官方 CLI 打开的浏览器中完成登录。', 'Complete the login in the browser opened by the official CLI.'), verified: text('身份已验证，点击保存后才加入订阅列表。请在 120 秒内保存。', 'Identity verified. Save it to add the subscription. Save within 120 seconds.'), failed: text('登录未完成。', 'Login did not complete.'), cancelling: text('正在取消并等待清理完成…', 'Cancelling and waiting for cleanup…'), cancelled: text('登录已取消。', 'Login cancelled.'), saved: text('登录身份已保存。', 'The login identity is saved.') };
  return <section className="managed-accounts-panel claude-subscriptions-panel" aria-label={text('Claude 订阅', 'Claude subscriptions')}>
    <header><div><h2>{text('Claude 订阅', 'Claude subscriptions')}</h2><p>{text('通过官方 CLI 登录并明确保存；只展示官方返回的额度。', 'Sign in through the official CLI and explicitly save the identity. Quota displays only official returned fields.')}</p></div><button type="button" className="icon-action" disabled={pending !== null} aria-label={text('刷新 Claude 订阅', 'Refresh Claude subscriptions')} title={text('刷新 Claude 订阅', 'Refresh Claude subscriptions')} onClick={() => void loadAccounts()}><RefreshCw size={14} /></button></header>
    {!fresh && <p className="proxy-feedback is-error" role="alert">{text('订阅列表尚未确认，请刷新重试。', 'The subscription list is unconfirmed. Refresh and retry.')}</p>}
    <div className="claude-subscription-create"><label htmlFor="claude-subscription-label">{text('订阅昵称', 'Subscription alias')}</label><input id="claude-subscription-label" maxLength={64} value={label} disabled={pending !== null} onChange={event => setLabel(event.target.value)} placeholder={text('简短昵称', 'Short alias')} /><button type="button" className="glass-button proxy-action" disabled={blocked || !fresh} onClick={() => void begin()}><LogIn size={13} />{text('官方登录', 'Official sign-in')}</button><button type="button" className="glass-button proxy-action" disabled={blocked || !fresh || !label.trim()} onClick={() => void capture(false)}><Save size={13} />{text('保存当前 Windows 订阅', 'Save current Windows subscription')}</button></div>
    {attempt && <section className="managed-login" aria-label={text('Claude 登录进度', 'Claude login progress')} data-login-phase={attempt.phase}><p role="status">{cleanupUnconfirmed ? text('取消后的清理尚未确认。', 'Cleanup after cancellation is unconfirmed.') : phases[attempt.phase]}</p>{verifiedAttempt && <button type="button" className="glass-button-solid proxy-action" disabled={pending !== null || captureRevoked || !label.trim() || !fresh} onClick={() => void capture(true)}><Save size={13} />{text('保存已验证订阅', 'Save verified subscription')}</button>}{(loginActive || verifiedAttempt) && <button type="button" className="glass-button proxy-action" disabled={pending !== null || attempt.phase === 'cancelling'} onClick={() => void cancelLogin()}><X size={13} />{text('取消登录', 'Cancel login')}</button>}</section>}
    {error && <p className="proxy-feedback is-error" role="alert">{failureText(error, text)}</p>}{notice && <p className="proxy-feedback" role="status">{notice}</p>}
    {accounts?.length === 0 && <p className="proxy-note">{text('暂无已保存订阅。登录完成后需点击保存。', 'No saved subscriptions. Save after completing the login.')}</p>}
    {accounts && accounts.length > 0 && <div className="managed-view-options"><div className="account-layout-switch" role="group" aria-label={text('Claude 订阅布局', 'Claude subscription layout')}><button type="button" aria-pressed={layout === 'cards'} aria-label={text('Claude 卡片', 'Claude cards')} title={text('卡片', 'Cards')} onClick={() => { setLayout('cards'); saveChoice('aigoodbro.claude.subscriptions.layout', 'cards'); }}><LayoutGrid size={14} /></button><button type="button" aria-pressed={layout === 'list'} aria-label={text('Claude 列表', 'Claude list')} title={text('列表', 'List')} onClick={() => { setLayout('list'); saveChoice('aigoodbro.claude.subscriptions.layout', 'list'); }}><List size={14} /></button></div><label className="profile-size-picker">{text('Claude 卡片大小', 'Claude card size')}<select value={size} onChange={event => { const value = event.target.value as AccountCardSize; setSize(value); saveChoice('aigoodbro.claude.subscriptions.size', value); }}><option value="small">{text('小', 'Small')}</option><option value="medium">{text('中', 'Medium')}</option><option value="large">{text('大', 'Large')}</option></select></label></div>}
    <div className={`managed-account-grid is-${layout} is-size-${size}`}>{accounts?.map((account, index) => <article className="managed-account-card claude-subscription-card" key={account.id} data-testid={`claude-subscription-${account.id}`}><header><span className="account-directory-number">{String(index + 1).padStart(2, '0')}</span><h3 title={account.label}>{account.label}</h3>{fresh && account.active_state === 'verified' && <span className="managed-active"><Check size={11} />{text('当前身份已核实', 'Current identity verified')}</span>}</header><div className="managed-account-identity"><span>Claude</span><p>{account.masked_identity ?? text('身份未确认', 'Identity unconfirmed')}</p>{account.plan_type && <span title={text('上次验证的套餐', 'Last verified plan')}>{account.plan_type}</span>}</div><p className="managed-account-state">{account.login_state === 'verified' ? text('已保存登录', 'Saved sign-in') : text('需要重新登录', 'Sign in again')}{account.active_state === 'stale' && fresh && <span> · {text('当前身份已变化', 'Current identity changed')}</span>}</p><div className="managed-account-actions"><button type="button" className="glass-button proxy-action" disabled={blocked || !fresh || !account.can_switch} title={account.switch_block_reason ? failureText(account.switch_block_reason, text) : undefined} onClick={event => void prepare(account, event.currentTarget)}><ArrowRightLeft size={13} />{text('切换当前 Claude', 'Switch current Claude')}</button></div>{!account.can_switch && account.switch_block_reason && <p className="proxy-note">{failureText(account.switch_block_reason, text)}</p>}<ClaudeQuotaView account={account} disabled={blocked || !fresh} text={text} language={language} /></article>)}</div>
    {confirmation && <dialog ref={dialog} className="managed-switch-dialog" aria-label={text('确认 Claude 切换', 'Confirm Claude switch')} onCancel={event => { event.preventDefault(); if (!operation.current) void cancelSwitch(); }}><h2>{text('切换到 ', 'Switch to ')}{confirmation.label}</h2><p>{text('确认后更新当前 Windows Claude 订阅身份。', 'Confirming updates the current Windows Claude subscription identity.')}</p>{confirmation.mode === 'ready' ? <p role="status">{text(`请在 ${seconds} 秒内确认。`, `Confirm within ${seconds} seconds.`)}</p> : <p className="proxy-feedback is-error" role="alert">{confirmation.mode === 'expired' ? failureText('switch_ticket_expired', text) : confirmation.mode === 'cancel_unconfirmed' ? text('取消尚未确认，请重试或等待到期。', 'Cancellation is unconfirmed. Retry or wait for expiry.') : failureText(confirmation.errorCode ?? 'operation_failed', text)}</p>}<div><button type="button" className="glass-button proxy-action" disabled={pending !== null} onClick={() => void cancelSwitch()}>{ticket.current ? text('取消切换', 'Cancel switch') : text('关闭', 'Close')}</button>{confirmation.mode === 'ready' && <button type="button" className="glass-button-solid proxy-action" disabled={pending !== null || seconds <= 0} onClick={() => void commit()}>{pending === 'commit' ? text('正在切换…', 'Switching…') : text('确认切换', 'Confirm switch')}</button>}</div></dialog>}
  </section>;
}
