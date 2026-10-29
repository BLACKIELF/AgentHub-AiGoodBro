import { useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { ArrowRightLeft, Check, Copy, ExternalLink, LayoutGrid, List, LogIn, Plus, RefreshCw, X } from 'lucide-react';
import { useI18n } from '../i18n/I18nProvider';
import { isLoginPending, parseAccountOperation, parseLoginAttempt, parseManagedAccount, parseManagedAccounts, parsePreparedSwitch, type LoginAttempt, type ManagedAccount } from '../utils/managedAccounts';
import { readChoice, saveChoice, type AccountCardSize } from '../utils/workspacePreferences';
import { ManagedAccountMenu } from './ManagedAccountMenu';

type Text = (zh: string, en: string) => string;
type Confirmation = { accountId: string; label: string; identity: string | null; expiresAt: number; mode: 'ready' | 'expired' | 'failed' | 'cancel_unconfirmed'; errorCode?: string };
const failureCode = (error: unknown): string => {
  const value = typeof error === 'string' ? error : error instanceof Error ? error.message : '';
  return /^[a-z_]{1,80}$/.test(value) ? value : 'operation_failed';
};
function failureText(code: string, text: Text): string {
  const messages: Record<string, [string, string]> = {
    invalid_label: ['请使用 64 字节以内的简短昵称。', 'Use a short alias of up to 64 bytes.'], duplicate_label: ['这个昵称已存在，请换一个。', 'That alias already exists. Choose another.'], account_limit: ['托管账号已达到数量上限。', 'The managed account limit has been reached.'],
    cli_unavailable: ['Codex 命令行暂不可用。', 'The Codex CLI is unavailable.'], platform_not_supported: ['此平台暂不支持托管登录。', 'Managed login is unavailable for this platform.'],
    occupancy_unknown: ['任务占用尚未确认，暂不能切换。', 'Task occupancy is unconfirmed. Switching is unavailable.'], account_busy: ['账号正在执行其他操作，请稍后重试。', 'Another account operation is in progress. Try again shortly.'],
    login_in_progress: ['另一个登录仍在进行，请完成或取消。', 'Another login is in progress. Complete or cancel it first.'], switch_in_progress: ['另一个切换仍在确认，请先完成或取消。', 'Another switch awaits confirmation. Complete or cancel it first.'],
    login_required: ['请先登录并完成身份验证。', 'Sign in and verify the account first.'], login_page_unavailable: ['登录页已失效，请重新开始登录。', 'This login page is no longer available. Start a new login.'], login_attempt_not_found: ['登录进度已失效，请重新开始。', 'This login attempt is no longer available. Start again.'],
    identity_mismatch: ['身份与原账号不一致，操作未完成。', 'The identity differs from the original account. The operation did not complete.'], account_changed: ['账号已发生变化，请重新检查后再试。', 'The account changed. Check it again before retrying.'], target_changed: ['当前 Codex 身份或配置已变化，请重新检查。', 'The current Codex identity or settings changed. Check again.'],
    switch_ticket_expired: ['切换确认已过期，请重新检查。', 'The switch confirmation expired. Check again.'], switch_ticket_invalid: ['切换确认已失效，请重新检查。', 'The switch confirmation is no longer valid. Check again.'],
    recovery_required: ['账号状态需要恢复，暂不可操作。', 'The account state needs recovery. Actions are unavailable.'], account_already_exists: ['此身份已保存在其他托管账号中。', 'This identity is already saved in another managed account.'],
    system_busy: ['Codex 正在使用中，暂不能切换。', 'Codex is in use. Switching is unavailable.'], login_cancelled: ['登录已取消。', 'Login cancelled.'],
    account_is_current: ['此账号或同身份保存项正在系统中使用，请先切换到其他已验证身份。', 'This account or a saved alias is current. Switch to another verified identity first.'],
    account_identity_unverified: ['当前系统登录身份未确认，已保留保存的账号。', 'The current system identity is unconfirmed. The saved account is retained.'],
    login_progress_unavailable: ['登录进度暂不可读取，请重试取消或刷新。', 'Login progress is unavailable. Retry cancellation or refresh.'],
  };
  const message = messages[code];
  return message ? text(...message) : text('操作未完成，请刷新状态后重试。', 'The operation did not complete. Refresh status and retry.');
}

export function ManagedAccountsPanel() {
  const { language } = useI18n();
  const text: Text = (zh, en) => language === 'zh-Hans' ? zh : en;
  const [accounts, setAccounts] = useState<ManagedAccount[] | null>(null);
  const [fresh, setFresh] = useState(false);
  const [label, setLabel] = useState('');
  const [pending, setPending] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [readError, setReadError] = useState(false);
  const [notice, setNotice] = useState('');
  const [attempt, setAttempt] = useState<LoginAttempt | null>(null);
  const [promptRevoked, setPromptRevoked] = useState(false);
  const [confirmation, setConfirmation] = useState<Confirmation | null>(null);
  const [now, setNow] = useState(Date.now());
  const [layout, setLayout] = useState<'cards' | 'list'>(() => readChoice('aigoodbro.managed.accounts.layout', ['cards', 'list'], 'cards'));
  const [size, setSize] = useState<AccountCardSize>(() => readChoice('aigoodbro.managed.accounts.size', ['small', 'medium', 'large'], 'small'));
  const alive = useRef(false), listEpoch = useRef(0), loginEpoch = useRef(0), pollingLogin = useRef(false);
  const operation = useRef<{ name: string; token: object } | null>(null);
  const currentAttempt = useRef<LoginAttempt | null>(null);
  const ticket = useRef<{ value: string; accountId: string; expiresAt: number } | null>(null);
  const dialog = useRef<HTMLDialogElement>(null);
  const panel = useRef<HTMLElement>(null), switchInvoker = useRef<HTMLButtonElement | null>(null);

  async function loadAccounts(): Promise<boolean> {
    const epoch = ++listEpoch.current;
    try {
      const result = parseManagedAccounts(await invoke('list_managed_accounts'));
      if (alive.current && epoch === listEpoch.current) { setAccounts(result); setFresh(true); setReadError(false); }
      return true;
    } catch {
      if (alive.current && epoch === listEpoch.current) { setFresh(false); setReadError(true); }
      return false;
    }
  }
  function applyAttempt(next: LoginAttempt) {
    currentAttempt.current = next; setAttempt(next);
    if (next.phase === 'verified') { setNotice(text('登录验证已完成。', 'Login verification completed.')); void loadAccounts(); }
    else if (next.phase === 'cancelled') { setNotice(text('登录已取消。', 'Login cancelled.')); void loadAccounts(); }
    else if (next.phase === 'failed') { setError(next.error_code ?? 'operation_failed'); void loadAccounts(); }
  }
  useEffect(() => {
    alive.current = true;
    let disposed = false, unlisten: (() => void) | undefined;
    async function initialize() {
      try {
        const release = await listen('managed-accounts:changed', () => { if (!disposed) void loadAccounts(); });
        if (disposed) { release(); return; }
        unlisten = release;
      } catch { /* Explicit reads and commands remain available. */ }
      if (!disposed) await loadAccounts();
    }
    void initialize();
    const listTimer = setInterval(() => { if (!disposed && !operation.current) void loadAccounts(); }, 3000);
    const loginTimer = setInterval(async () => {
      const current = currentAttempt.current;
      if (disposed || !isLoginPending(current) || !current || pollingLogin.current || operation.current?.name === 'cancel-login') return;
      const epoch = loginEpoch.current;
      pollingLogin.current = true;
      try {
        const next = parseLoginAttempt(await invoke('get_login_attempt', { attemptId: current.attempt_id }), current.account_id, current.attempt_id);
        if (!disposed && alive.current && epoch === loginEpoch.current && currentAttempt.current?.attempt_id === current.attempt_id) applyAttempt(next);
      } catch {
        if (!disposed && alive.current && epoch === loginEpoch.current) { setPromptRevoked(true); setError('login_progress_unavailable'); }
      } finally { pollingLogin.current = false; }
    }, 750);
    return () => {
      disposed = true; alive.current = false; listEpoch.current++; loginEpoch.current++;
      clearInterval(listTimer); clearInterval(loginTimer); unlisten?.();
      const ownedAttempt = currentAttempt.current;
      if (isLoginPending(ownedAttempt) && ownedAttempt) void invoke('cancel_account_login', { attemptId: ownedAttempt.attempt_id }).catch(() => undefined);
      const ownedTicket = ticket.current;
      if (ownedTicket && operation.current?.name !== 'commit-switch') void invoke('cancel_account_switch', { ticket: ownedTicket.value }).catch(() => undefined);
    };
    // The panel stays mounted across navigation so owned login/cancellation
    // remains observable; component teardown cancels only its own attempt/ticket.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    if (!confirmation) return;
    const timer = setInterval(() => setNow(Date.now()), 250);
    return () => clearInterval(timer);
  }, [confirmation?.accountId]);
  useEffect(() => {
    if (confirmation || pending || !switchInvoker.current) return;
    const invoker = switchInvoker.current;
    switchInvoker.current = null;
    if (invoker.isConnected && !invoker.disabled) invoker.focus();
    else panel.current?.querySelector<HTMLButtonElement>('button:not(:disabled)')?.focus();
  }, [confirmation, pending]);
  useEffect(() => {
    const current = ticket.current;
    if (!current || now < current.expiresAt * 1000 || operation.current?.name === 'commit-switch') return;
    ticket.current = null;
    setConfirmation(previous => previous ? { ...previous, mode: 'expired' } : null);
    // Expiry prevents commit locally even if transport cleanup cannot confirm.
    void invoke('cancel_account_switch', { ticket: current.value }).catch(() => undefined);
  }, [now]);
  useEffect(() => {
    const node = dialog.current;
    if (!confirmation || !node) return;
    const previousFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    if (!node.open) node.showModal();
    return () => { if (node.open) node.close(); if (previousFocus?.isConnected) previousFocus.focus(); };
  }, [confirmation?.accountId]);

  async function run(name: string, action: () => Promise<void>) {
    if (operation.current) return false;
    const token = {};
    operation.current = { name, token }; setPending(name); setError(null); setNotice('');
    try { await action(); return true; }
    catch (failure) { if (alive.current) setError(failureCode(failure)); return false; }
    finally { if (alive.current && operation.current?.token === token) { operation.current = null; setPending(null); } }
  }
  async function editAccount(account: ManagedAccount, action: 'rename' | 'remove', alias?: string) {
    if (!fresh) return false;
    return run(action, async () => {
      parseAccountOperation(await invoke(action === 'rename' ? 'rename_managed_account' : 'remove_managed_account', { accountId: account.id, ...(action === 'rename' ? { label: alias } : {}) }), account.id, action === 'rename' ? 'renamed' : 'removed');
      if (!alive.current) return;
      setAccounts(previous => action === 'remove' ? previous?.filter(row => row.id !== account.id) ?? null : previous?.map(row => row.id === account.id ? { ...row, label: alias! } : row) ?? null);
      setNotice(action === 'remove' ? text('已移除此应用保存的账号。', 'The saved account was removed.') : text('账号昵称已保存。', 'The account alias was saved.'));
      await loadAccounts();
    });
  }
  async function create() {
    await run('create', async () => {
      const alias = label.trim();
      if (!alias || new TextEncoder().encode(alias).length > 64 || /[\x00-\x1f\x7f@/\\:]/.test(alias)) throw Error('invalid_label');
      const result = parseManagedAccount(await invoke('create_managed_account', { label: alias, platform: 'codex' }));
      if (result.platform !== 'codex') throw Error('invalid_response');
      if (!alive.current) return;
      setAccounts(previous => previous?.some(account => account.id === result.id) ? previous : [...previous ?? [], result]);
      setLabel(''); setNotice(text('托管账号已创建。', 'Managed account created.')); await loadAccounts();
    });
  }
  async function beginLogin(account: ManagedAccount) {
    if (operation.current || !fresh || !account.can_login || account.platform !== 'codex' || isLoginPending(currentAttempt.current) || ticket.current) return;
    const epoch = ++loginEpoch.current;
    currentAttempt.current = null; setAttempt(null); setPromptRevoked(false);
    await run('begin-login', async () => {
      const result = parseLoginAttempt(await invoke('begin_account_login', { accountId: account.id }), account.id);
      if (!alive.current) { if (isLoginPending(result)) void invoke('cancel_account_login', { attemptId: result.attempt_id }).catch(() => undefined); return; }
      if (epoch === loginEpoch.current) { applyAttempt(result); await loadAccounts(); }
    });
  }
  async function cancelLogin() {
    const current = currentAttempt.current;
    if (!current || !isLoginPending(current) || operation.current) return;
    const epoch = ++loginEpoch.current;
    setPromptRevoked(true);
    await run('cancel-login', async () => {
      const result = parseLoginAttempt(await invoke('cancel_account_login', { attemptId: current.attempt_id }), current.account_id, current.attempt_id);
      if (alive.current && epoch === loginEpoch.current) applyAttempt(result);
    });
  }
  async function authorizationAction(kind: 'open' | 'url' | 'code') {
    const current = currentAttempt.current;
    if (!current || current.phase !== 'waiting' || promptRevoked || !current.verification_url || !current.user_code) return;
    const epoch = loginEpoch.current;
    await run(`authorization-${kind}`, async () => {
      if (kind === 'open') await invoke('open_account_login_page', { attemptId: current.attempt_id });
      else await navigator.clipboard.writeText(kind === 'url' ? current.verification_url! : current.user_code!);
      if (alive.current && epoch === loginEpoch.current && currentAttempt.current?.phase === 'waiting') setNotice(kind === 'open' ? text('已交给系统浏览器打开官方登录页。', 'The official login page was handed to the system browser.') : kind === 'url' ? text('登录地址已复制。', 'Login URL copied.') : text('配对码已复制。', 'Pairing code copied.'));
    });
  }
  async function prepareSwitch(account: ManagedAccount, invoker: HTMLButtonElement) {
    if (!fresh || !account.can_switch || account.platform !== 'codex' || isLoginPending(currentAttempt.current) || ticket.current) return;
    switchInvoker.current = invoker;
    await run('prepare-switch', async () => {
      const result = parsePreparedSwitch(await invoke('prepare_account_switch', { accountId: account.id }), account.id);
      if (!alive.current) { if (result.ticket) void invoke('cancel_account_switch', { ticket: result.ticket }).catch(() => undefined); return; }
      if (result.phase === 'blocked') { setError(result.reason_code ?? 'operation_failed'); await loadAccounts(); return; }
      ticket.current = { value: result.ticket!, accountId: account.id, expiresAt: result.expires_at! };
      setNow(Date.now());
      setConfirmation({ accountId: account.id, label: account.label, identity: account.masked_identity, expiresAt: result.expires_at!, mode: 'ready' });
      await loadAccounts();
    });
  }
  async function cancelSwitch() {
    if (operation.current) return;
    const current = ticket.current;
    if (!current) { setConfirmation(null); return; }
    setConfirmation(previous => previous ? { ...previous, mode: 'cancel_unconfirmed' } : null);
    await run('cancel-switch', async () => {
      try {
        parseAccountOperation(await invoke('cancel_account_switch', { ticket: current.value }), current.accountId, 'cancelled');
        if (alive.current) { ticket.current = null; setConfirmation(null); setNotice(text('切换已取消。', 'Switch cancelled.')); await loadAccounts(); }
      } catch (failure) {
        const code = failureCode(failure);
        if (alive.current && ['switch_ticket_invalid', 'switch_ticket_expired'].includes(code)) { ticket.current = null; setConfirmation(previous => previous ? { ...previous, mode: 'expired' } : null); }
        throw failure;
      }
    });
  }
  async function commitSwitch() {
    const current = ticket.current;
    if (!current || confirmation?.mode !== 'ready' || current.expiresAt * 1000 <= Date.now()) return;
    await run('commit-switch', async () => {
      try {
        const result = parseAccountOperation(await invoke('commit_account_switch', { ticket: current.value }), current.accountId, 'committed');
        if (result.error_code) throw Error(result.error_code);
        if (alive.current) { ticket.current = null; setConfirmation(null); setNotice(text('切换操作已完成，当前身份以回读结果为准。', 'The switch completed. The reported identity confirms the current account.')); await loadAccounts(); }
      } catch (failure) {
        const code = failureCode(failure);
        let released = false;
        try { parseAccountOperation(await invoke('cancel_account_switch', { ticket: current.value }), current.accountId, 'cancelled'); released = true; }
        catch (cleanup) { released = ['switch_ticket_invalid', 'switch_ticket_expired'].includes(failureCode(cleanup)); }
        if (alive.current) {
          if (released) ticket.current = null;
          setConfirmation(previous => previous ? { ...previous, mode: released ? 'failed' : 'cancel_unconfirmed', errorCode: code } : null);
          await loadAccounts();
        }
        throw failure;
      }
    });
  }

  const loginPending = isLoginPending(attempt);
  const blocked = pending !== null || loginPending || confirmation !== null;
  const loginLabels = { starting: text('正在准备登录…', 'Preparing login…'), waiting: text('等待在官方页面完成登录。', 'Complete the login on the official page.'), verifying: text('正在验证登录身份…', 'Verifying the login identity…'), cancelling: text('正在取消并等待清理完成…', 'Cancelling and waiting for cleanup…'), verified: text('登录验证已完成。', 'Login verification completed.'), cancelled: text('登录已取消。', 'Login cancelled.'), failed: text('登录未完成。', 'Login did not complete.') };
  const secondsLeft = confirmation ? Math.max(0, Math.ceil((confirmation.expiresAt * 1000 - now) / 1000)) : 0;
  const loginAccount = accounts?.find(account => account.id === attempt?.account_id);
  return <section ref={panel} className="managed-accounts-panel" aria-label={text('托管账号', 'Managed accounts')}>
    <header><div><h2>{text('托管账号', 'Managed accounts')}</h2><p>{text('独立保存登录身份；下方账号目录仍用于查看用量。', 'Keep login identities separately. Account directories below remain available for viewing usage.')}</p></div><button type="button" className="icon-action" disabled={pending !== null} aria-label={text('刷新托管账号', 'Refresh managed accounts')} title={text('刷新托管账号', 'Refresh managed accounts')} onClick={() => void loadAccounts()}><RefreshCw size={15} /></button></header>
    <form className="managed-create" onSubmit={event => { event.preventDefault(); if (!blocked && fresh) void create(); }}><label htmlFor="managed-account-label">{text('Codex 账号昵称', 'Codex account alias')}</label><input id="managed-account-label" value={label} maxLength={64} disabled={blocked || !fresh} placeholder={text('简短昵称', 'Short alias')} onChange={event => setLabel(event.target.value)} /><button type="submit" className="glass-button-solid proxy-action" disabled={blocked || !fresh || !label.trim()}><Plus size={14} />{text('新建账号', 'Create account')}</button></form>
    {readError && <p className="proxy-feedback is-error" role="alert">{text('托管账号暂不可读取，请刷新后重试。', 'Managed accounts are unavailable. Refresh and retry.')}</p>}
    {error && <p className="proxy-feedback is-error" role="alert">{failureText(error, text)}</p>}{notice && <p className="proxy-feedback" role="status">{notice}</p>}
    {attempt && <section className="managed-login" aria-label={text('登录进度', 'Login progress')} data-login-phase={attempt.phase}><header><h3>{loginAccount?.label ?? text('账号登录', 'Account login')}</h3><span role="status">{pending === 'cancel-login' ? text('正在请求取消…', 'Requesting cancellation…') : loginLabels[attempt.phase]}</span></header>
      {attempt.phase === 'waiting' && !promptRevoked && attempt.verification_url && attempt.user_code && <div className="managed-pairing"><code>{attempt.verification_url}</code><strong>{attempt.user_code}</strong><div className="managed-pairing-actions"><button type="button" className="glass-button-solid proxy-action" disabled={pending !== null} onClick={() => void authorizationAction('open')}><ExternalLink size={13} />{text('打开官方登录页', 'Open official login page')}</button><button type="button" className="glass-button proxy-action" disabled={pending !== null} onClick={() => void authorizationAction('code')}><Copy size={13} />{text('复制配对码', 'Copy pairing code')}</button><button type="button" className="glass-button proxy-action" disabled={pending !== null} onClick={() => void authorizationAction('url')}><Copy size={13} />{text('复制登录地址', 'Copy login URL')}</button></div></div>}
      {loginPending && <button type="button" className="glass-button proxy-action" disabled={pending !== null || attempt.phase === 'cancelling'} onClick={() => void cancelLogin()}><X size={13} />{text('取消登录', 'Cancel login')}</button>}
    </section>}
    {accounts && accounts.length > 0 && <div className="managed-view-options"><div className="account-layout-switch" role="group" aria-label={text('托管账号布局', 'Managed account layout')}><button type="button" aria-pressed={layout === 'cards'} aria-label={text('托管账号卡片', 'Managed cards')} title={text('卡片', 'Cards')} onClick={() => { setLayout('cards'); saveChoice('aigoodbro.managed.accounts.layout', 'cards'); }}><LayoutGrid size={14} /></button><button type="button" aria-pressed={layout === 'list'} aria-label={text('托管账号列表', 'Managed list')} title={text('列表', 'List')} onClick={() => { setLayout('list'); saveChoice('aigoodbro.managed.accounts.layout', 'list'); }}><List size={14} /></button></div><label className="profile-size-picker">{text('托管卡片大小', 'Managed card size')}<select value={size} onChange={event => { const value = event.target.value as AccountCardSize; setSize(value); saveChoice('aigoodbro.managed.accounts.size', value); }}><option value="small">{text('小', 'Small')}</option><option value="medium">{text('中', 'Medium')}</option><option value="large">{text('大', 'Large')}</option></select></label></div>}
    {accounts === null && !readError && <p className="proxy-note" role="status">{text('正在读取托管账号…', 'Reading managed accounts…')}</p>}
    {accounts?.length === 0 && <p className="proxy-note">{text('暂无托管账号。创建后可在官方页面登录。', 'No managed accounts yet. Create one to sign in on the official page.')}</p>}
    <div className={`managed-account-grid is-${layout} is-size-${size}`}>{accounts?.map((account, index) => <article className="managed-account-card" key={account.id} data-testid={`managed-account-${account.id}`}><header><span className="account-directory-number">{String(index + 1).padStart(2, '0')}</span><h3 title={account.label}>{account.label}</h3>{fresh && account.active_state === 'verified' && <span className="managed-active"><Check size={11} />{text('当前身份已核实', 'Current identity verified')}</span>}<ManagedAccountMenu label={account.label} disabled={blocked || !fresh} error={error ? failureText(error, text) : null} onRename={alias => editAccount(account, 'rename', alias)} onRemove={() => editAccount(account, 'remove')} /></header><div className="managed-account-identity"><span>{account.platform === 'codex' ? 'Codex' : account.platform}</span><p>{account.masked_identity ?? text('尚无已验证身份', 'No verified identity yet')}</p>{account.plan_type && <span title={text('上次验证的套餐，不代表当前可用额度。', 'Last verified plan; this does not confirm current quota.')}>{account.plan_type}</span>}</div><p className="managed-account-state">{account.login_state === 'verified' ? text('已登录', 'Signed in') : account.login_state === 'signing_in' ? text('登录中', 'Signing in') : account.login_state === 'needs_reauth' ? text('需要重新登录', 'Sign in again') : text('未登录', 'Signed out')}{(!fresh || account.active_state !== 'verified') && <span> · {account.active_state === 'stale' && fresh ? text('当前身份已变化', 'Current identity changed') : text('当前使用状态未确认', 'Current use unconfirmed')}</span>}</p>{account.recovery_required && <p className="proxy-note">{failureText('recovery_required', text)}</p>}<div className="managed-account-actions"><button type="button" className="glass-button proxy-action" disabled={blocked || !fresh || !account.can_login || account.platform !== 'codex'} onClick={() => void beginLogin(account)}><LogIn size={13} />{text('登录', 'Sign in')}</button><button type="button" className="glass-button proxy-action" disabled={blocked || !fresh || !account.can_switch || account.platform !== 'codex'} title={account.switch_block_reason ? failureText(account.switch_block_reason, text) : undefined} onClick={event => void prepareSwitch(account, event.currentTarget)}><ArrowRightLeft size={13} />{text('切换当前 Codex', 'Switch current Codex')}</button></div>{!account.can_switch && account.switch_block_reason && <p className="proxy-note">{failureText(account.switch_block_reason, text)}</p>}</article>)}</div>
    {confirmation && <dialog ref={dialog} className="managed-switch-dialog" aria-label={text('确认账号切换', 'Confirm account switch')} onCancel={event => { event.preventDefault(); if (!operation.current) void cancelSwitch(); }}><h2>{text('切换到 ', 'Switch to ')}{confirmation.label}</h2>{confirmation.identity && <p>{confirmation.identity}</p>}<p>{text('确认后将更新当前 Codex 登录身份。', 'Confirming updates the current Codex login identity.')}</p>{confirmation.mode === 'ready' ? <p className="managed-confirm-countdown" role="status">{text(`请在 ${secondsLeft} 秒内确认。`, `Confirm within ${secondsLeft} seconds.`)}</p> : <p className="proxy-feedback is-error" role="alert">{confirmation.mode === 'expired' ? failureText('switch_ticket_expired', text) : confirmation.mode === 'cancel_unconfirmed' ? text('取消尚未确认，请重试或等待确认到期。', 'Cancellation is unconfirmed. Retry or wait for expiry.') : failureText(confirmation.errorCode ?? 'operation_failed', text)}</p>}<div><button type="button" className="glass-button proxy-action" disabled={pending !== null} onClick={() => void cancelSwitch()}>{ticket.current ? text('取消切换', 'Cancel switch') : text('关闭', 'Close')}</button>{confirmation.mode === 'ready' && <button type="button" className="glass-button-solid proxy-action" disabled={pending !== null || secondsLeft <= 0} onClick={() => void commitSwitch()}>{pending === 'commit-switch' ? text('正在切换…', 'Switching…') : text('确认切换', 'Confirm switch')}</button>}</div></dialog>}
  </section>;
}
