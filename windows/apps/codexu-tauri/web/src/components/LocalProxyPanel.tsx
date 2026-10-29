import { useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { ArrowDown, ArrowUp, Copy, Info, MoreHorizontal, Play, RefreshCw, Save, ShieldCheck, Square } from 'lucide-react';
import { useI18n } from '../i18n/I18nProvider';
import { QuotaRing } from './QuotaRing';
import { ProxyDesktopPanel } from './ProxyDesktopPanel';
import { parseProxyAccounts, parseProxyPolicy, parseProxyPreferences, parseProxyStatus, proxyAccountPolicy, proxyConnectionText, proxyDisplayOrder, proxyParticipation, type ProxyAccount, type ProxyAccountPolicy, type ProxyPreferences, type ProxyStatus } from '../utils/localProxy';

type Text = (zh: string, en: string) => string;
type NetworkDraft = { listenPort: string; clientKeyMode: ProxyPreferences['clientKeyMode']; automaticRecoveryEnabled: boolean; desktopFallback: boolean; networkProxy: string; egressEnabled: boolean; mihomoApi: string; group: string; whitelist: string; creditFallback: boolean; creditPrimaryFloor: string; creditSecondaryFloor: string };
type PolicyDraft = { limit: string; credits: boolean; primary: string; secondary: string };
const networkDraft = (p: ProxyPreferences): NetworkDraft => ({ listenPort: String(p.listenPort), clientKeyMode: p.clientKeyMode, automaticRecoveryEnabled: p.automaticRecoveryEnabled, desktopFallback: p.desktopFallback, networkProxy: p.networkProxy, egressEnabled: p.egress.enabled, mihomoApi: p.egress.mihomoApi, group: p.egress.group, whitelist: p.egress.whitelist.join('\n'), creditFallback: p.creditFallback, creditPrimaryFloor: String(p.creditPrimaryFloor), creditSecondaryFloor: String(p.creditSecondaryFloor) });
const policyDraft = (p: ProxyAccountPolicy): PolicyDraft => ({ limit: String(p.fiveHourUsedLimit), credits: p.allowsCredits, primary: p.creditPrimaryFloor === null ? '' : String(p.creditPrimaryFloor), secondary: p.creditSecondaryFloor === null ? '' : String(p.creditSecondaryFloor) });
const numeric = (raw: string): number => raw.trim() && /^\d+(?:\.\d+)?$/.test(raw) ? Number(raw) : Number.NaN;

function failureText(error: unknown, text: Text): string {
  const code = typeof error === 'string' ? error : error instanceof Error ? error.message : '';
  const messages: Record<string, [string, string]> = {
    invalid_settings: ['设置无效，请检查端口、代理地址和规则。', 'Invalid settings. Check the port, proxy address and rules.'],
    helper_unavailable: ['反代组件不可用，请检查当前安装包。', 'The proxy helper is unavailable. Check the installed package.'],
    identity: ['账号身份尚未确认，请重新登录后刷新。', 'Account identity is unconfirmed. Sign in again, then refresh.'],
    quota_unknown: ['账号额度尚未确认，请刷新额度。', 'Account quota is unconfirmed. Refresh quota first.'],
    quota: ['账号可用额度不足。', 'The account has insufficient quota.'],
    not_participating: ['没有可参与的账号，请检查参与状态。', 'No account can participate. Check account participation.'],
    account_busy: ['账号或服务正在使用中，请稍后重试。', 'The account or service is busy. Try again shortly.'],
    control_busy: ['账号正在执行其他操作，请稍后重试。', 'Another account operation is in progress. Try again shortly.'],
    save_failed: ['保存失败，编辑内容已保留。', 'Saving failed. Your edits have been kept.'],
    startup_failed: ['反代未能启动，请检查账号与网络后重试。', 'The proxy could not start. Check accounts and network, then retry.'],
    registration_failed: ['账号加入反代尚未确认，请重试参与操作。', 'Proxy enrollment is unconfirmed. Retry enabling this account.'],
    stopping: ['反代正在停止，本次加入未生效。', 'The proxy is stopping. This enrollment was not applied.'],
    lease_cleanup_unconfirmed: ['停止结果尚未确认，请刷新状态。', 'Stopping is not yet confirmed. Refresh status.'],
    login_expired: ['登录已过期，请重新登录。', 'The login has expired. Sign in again.'],
    subscription_pending: ['套餐状态尚未确认，请刷新额度。', 'The subscription is unconfirmed. Refresh quota.'],
    usage_limit: ['已达到已用额度上限。', 'The configured usage limit has been reached.'],
    listen_port_occupied: ['监听端口已被占用，请停止后修改端口。', 'The listen port is occupied. Stop the proxy before changing it.'],
    network_unavailable: ['网络暂不可用，请检查网络设置。', 'The network is unavailable. Check network settings.'],
  };
  const message = messages[code];
  return message ? text(...message) : text('操作未完成，请刷新状态后重试。', 'The operation did not complete. Refresh status and retry.');
}

function stateText(state: string | undefined, text: Text): string {
  const states: Record<string, [string, string]> = {
    ready: ['就绪', 'Ready'], active: ['使用中', 'Active'], busy: ['忙碌', 'Busy'], credentials_busy: ['认证处理中', 'Credentials busy'],
    quota: ['额度不足', 'Quota exhausted'], quota_unknown: ['额度待确认', 'Quota unconfirmed'], usage_limit: ['达到使用上限', 'Usage limit reached'],
    subscription_pending: ['套餐待确认', 'Subscription unconfirmed'], unauthorized: ['需登录', 'Sign-in required'], login_expired: ['登录过期', 'Login expired'],
    forbidden: ['访问受限', 'Access restricted'], temporary_error: ['暂时不可用', 'Temporarily unavailable'], cooldown: ['冷却中', 'Cooling down'],
    unavailable: ['不可用', 'Unavailable'], identity: ['身份待确认', 'Identity unconfirmed'], not_participating: ['未参与', 'Not participating'],
    registration_failed: ['加入未确认', 'Enrollment unconfirmed'],
  };
  const value = state ? states[state] : undefined;
  return value ? text(...value) : text('未确认', 'Unconfirmed');
}

function ProxyAccountRow({ account, index, total, preferences, status, projectionFresh, busy, text, language, save, move }: {
  account: ProxyAccount; index: number; total: number; preferences: ProxyPreferences; status: ProxyStatus | null; projectionFresh: boolean; busy: boolean; text: Text; language: string;
  save: (next: ProxyPreferences) => Promise<ProxyPreferences | null>; move: (id: string, offset: number) => void;
}) {
  const committed = proxyAccountPolicy(preferences, account.id);
  const [draft, setDraft] = useState<PolicyDraft | null>(null);
  const [error, setError] = useState('');
  const [saved, setSaved] = useState(false);
  const form = draft ?? policyDraft(committed);
  const enabled = preferences.enabledIds.includes(account.id);
  const priority = preferences.priorityIds.includes(account.id);
  const last = preferences.lastOverrides[account.id] ?? account.isLast;
  const setField = <K extends keyof PolicyDraft>(key: K, value: PolicyDraft[K]) => { setDraft({ ...form, [key]: value }); setError(''); setSaved(false); };
  const quota = account.quota;
  const fresh = projectionFresh && account.availability === 'available';
  const windows = [
    { label: '5h', used: quota?.fiveHourUsedPercent ?? null, reset: quota?.fiveHourResetsAt ?? null },
    { label: '7d', used: quota?.sevenDayUsedPercent ?? null, reset: quota?.sevenDayResetsAt ?? null },
    ...(quota?.monthlyUsedPercent !== null && quota?.monthlyUsedPercent !== undefined ? [{ label: text('月额度', 'Monthly'), used: quota.monthlyUsedPercent, reset: quota.monthlyResetsAt }] : []),
  ];
  async function savePolicy() {
    setSaved(false); setError('');
    try {
      const policy = parseProxyPolicy({ fiveHourUsedLimit: numeric(form.limit), allowsCredits: form.credits, creditPrimaryFloor: form.primary.trim() ? numeric(form.primary) : null, creditSecondaryFloor: form.secondary.trim() ? numeric(form.secondary) : null });
      const result = await save({ ...preferences, accountPolicies: { ...preferences.accountPolicies, [account.id]: policy } });
      if (result) { setDraft(null); setSaved(true); }
      else setError(text('保存失败，草稿已保留。', 'Saving failed. The draft has been kept.'));
    } catch { setError(text('请输入 0–100 的已用上限，点数两档需同时填写且第一档大于第二档。', 'Use a limit from 0–100. Enter both credit floors, with the first larger than the second.')); }
  }
  const dirty = draft !== null && JSON.stringify(draft) !== JSON.stringify(policyDraft(committed));
  return <article className="proxy-account" data-testid={`proxy-account-${account.id}`} data-availability={fresh ? 'available' : 'unknown'}>
    <header className="proxy-account-header">
      <span className="account-directory-number">{String(index + 1).padStart(2, '0')}</span>
      <div className="proxy-account-name"><h3 title={account.label}>{account.label}</h3><span>{account.planType ?? text('套餐待确认', 'Plan unconfirmed')} · {stateText(status?.accounts[account.id]?.state, text)}</span></div>
      <button type="button" className={`proxy-enabled ${enabled ? 'is-enabled' : ''}`} aria-pressed={enabled} disabled={busy} onClick={() => void save(proxyParticipation(preferences, account.id, 'enabled', !enabled))}>{enabled ? text('已参与', 'Enabled') : text('未参与', 'Disabled')}</button>
      <details className="account-more"><summary className="icon-action" aria-label={text('更多操作', 'More actions')} title={text('更多操作', 'More actions')}><MoreHorizontal size={16} /></summary><div className="account-more-content">
        <button type="button" disabled={busy || index === 0} onClick={event => { event.currentTarget.closest('details')?.removeAttribute('open'); move(account.id, -1); }}><ArrowUp size={13} />{text('上移', 'Move up')}</button>
        <button type="button" disabled={busy || index === total - 1} onClick={event => { event.currentTarget.closest('details')?.removeAttribute('open'); move(account.id, 1); }}><ArrowDown size={13} />{text('下移', 'Move down')}</button>
      </div></details>
    </header>
    <div className="proxy-account-quota">
      {windows.map((window, windowIndex) => {
        const remaining = window.used !== null ? 100 - window.used : null;
        const noWindow = window.label === '5h' && fresh && window.used === null && ['pro', 'prolite'].includes(account.planType ?? '');
        return <div key={window.label}>{noWindow ? <div className="proxy-no-window"><span>—</span><small>5h · {text('无窗口', 'No window')}</small></div> : <QuotaRing label={window.label} remaining={remaining} stale={!fresh} secondary={windowIndex > 0} description={`${!fresh && remaining !== null ? text('上次快照 · ', 'Last snapshot · ') : ''}${window.label} · ${remaining === null ? text('额度未确认', 'Quota unconfirmed') : text(`剩余 ${Number(remaining.toFixed(1))}%`, `${Number(remaining.toFixed(1))}% remaining`)}`} />}
          {window.reset !== null && <p className="proxy-reset-time">{fresh ? text('重置 ', 'Resets ') : text('快照重置 ', 'Snapshot reset ')}{new Date(window.reset * 1000).toLocaleString(language === 'zh-Hans' ? 'zh-CN' : 'en-GB', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false })}</p>}
        </div>;
      })}
    </div>
    {quota && !fresh && <p className="proxy-note">{text('上次快照 · 请刷新核实可用额度。', 'Last snapshot · Refresh to confirm available quota.')}</p>}
    <div className="proxy-account-options">
      <label><input type="checkbox" checked={priority} disabled={busy} onChange={event => void save(proxyParticipation(preferences, account.id, 'priority', event.target.checked))} />{text('优先使用', 'Priority')}</label>
      <label><input type="checkbox" checked={last} disabled={busy} onChange={event => void save(proxyParticipation(preferences, account.id, 'last', event.target.checked))} />{text('最后使用', 'Use last')}</label>
      <details className="proxy-info"><summary className="icon-action" aria-label={text('账号详情', 'Account details')} title={text('账号详情', 'Account details')}><Info size={14} /></summary><div className="proxy-info-body">
        <p>{text('已用额度达到上限时停止分配；参与勾选不会改变显示顺序。', 'Allocation stops at the used-quota limit. Participation keeps the display order.')}</p>
        {quota && <p>{text('额度观察时间 ', 'Quota observed ')}{new Date(quota.observedAt * 1000).toLocaleString(language === 'zh-Hans' ? 'zh-CN' : 'en-GB', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false })}</p>}
        {fresh && quota?.creditBalancePoints !== null && quota?.creditBalancePoints !== undefined && <p>{text('点数 ', 'Credits ')}{quota.creditBalancePoints}</p>}
        {!fresh && <p>{text('额度尚未确认，请刷新额度后重试。', 'Quota is unconfirmed. Refresh quota and try again.')}</p>}
      </div></details>
    </div>
    <details className="proxy-rule-editor"><summary>{text('账号规则', 'Account rules')}<span>{text('已保存上限 ', 'Saved limit ')}{committed.fiveHourUsedLimit}%</span></summary>
      <div className="proxy-rule-fields">
        <label>{text('5h 已用上限 %', '5h used limit %')}<input type="number" min="0" max="100" step="0.1" value={form.limit} disabled={busy} onChange={event => setField('limit', event.target.value)} /></label>
        <label className="proxy-check"><input type="checkbox" checked={form.credits} disabled={busy} onChange={event => setField('credits', event.target.checked)} />{text('允许点数', 'Allow credits')}</label>
        <label>{text('点数第一档', 'First credit floor')}<input type="number" min="0" step="1" placeholder={String(preferences.creditPrimaryFloor)} value={form.primary} disabled={busy} onChange={event => setField('primary', event.target.value)} /></label>
        <label>{text('点数第二档', 'Second credit floor')}<input type="number" min="0" step="1" placeholder={String(preferences.creditSecondaryFloor)} value={form.secondary} disabled={busy} onChange={event => setField('secondary', event.target.value)} /></label>
      </div>
      <p className="proxy-note">{text('点数两档留空时沿用全局设置。', 'Leave both credit floors blank to use global settings.')}</p>
      <button type="button" className="glass-button proxy-action" disabled={busy || !dirty} onClick={() => void savePolicy()}><Save size={13} />{text('保存规则', 'Save rules')}</button>
      {error && <p className="proxy-feedback is-error" role="alert">{error}</p>}{saved && !dirty && <p className="proxy-feedback" role="status">{text('规则已保存。', 'Rules saved.')}</p>}
    </details>
  </article>;
}

export function LocalProxyPanel() {
  const { language } = useI18n();
  const text: Text = (zh, en) => language === 'zh-Hans' ? zh : en;
  const [preferences, setPreferences] = useState<ProxyPreferences | null>(null);
  const [status, setStatus] = useState<ProxyStatus | null>(null);
  const [statusFresh, setStatusFresh] = useState(false);
  const [accounts, setAccounts] = useState<ProxyAccount[] | null>(null);
  const [accountsFresh, setAccountsFresh] = useState(false);
  const [draft, setDraft] = useState<NetworkDraft | null>(null);
  const [plusLimit, setPlusLimit] = useState('');
  const [pending, setPending] = useState<string | null>(null);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [selfCheckRequestId, setSelfCheckRequestId] = useState<string | null>(null);
  const alive = useRef(false), generation = useRef(0), operation = useRef<string | null>(null), pollPending = useRef(false);

  useEffect(() => {
    alive.current = true;
    let disposed = false;
    const epoch = ++generation.current;
    async function initialize() {
      const results = await Promise.allSettled([invoke('get_local_proxy_preferences'), invoke('get_local_proxy_status'), invoke('get_local_proxy_accounts')]);
      if (disposed || !alive.current || generation.current !== epoch) return;
      for (let index = 0; index < results.length; index++) {
        const result = results[index];
        try {
          if (result.status === 'rejected') throw result.reason;
          if (index === 0) setPreferences(parseProxyPreferences(result.value));
          else if (index === 1) { setStatus(parseProxyStatus(result.value)); setStatusFresh(true); }
          else { setAccounts(parseProxyAccounts(result.value)); setAccountsFresh(true); }
        } catch { setError(text('部分反代信息暂不可用，请刷新重试。', 'Some proxy information is unavailable. Refresh and retry.')); }
      }
    }
    void initialize();
    const timer = setInterval(async () => {
      if (disposed || operation.current || pollPending.current) return;
      pollPending.current = true;
      const current = generation.current;
      const results = await Promise.allSettled([invoke('get_local_proxy_status'), invoke('get_local_proxy_accounts'), invoke('get_local_proxy_preferences')]);
      if (!disposed && alive.current && current === generation.current) {
        try { if (results[0].status === 'rejected') throw results[0].reason; setStatus(parseProxyStatus(results[0].value)); setStatusFresh(true); } catch { setStatusFresh(false); }
        try { if (results[1].status === 'rejected') throw results[1].reason; setAccounts(parseProxyAccounts(results[1].value)); setAccountsFresh(true); } catch { setAccountsFresh(false); }
        try { if (results[2].status === 'rejected') throw results[2].reason; setPreferences(parseProxyPreferences(results[2].value)); } catch { /* Keep the last saved participation until the native snapshot succeeds. */ }
      }
      pollPending.current = false;
    }, 2000);
    return () => { disposed = true; alive.current = false; generation.current++; clearInterval(timer); };
    // Localized display strings are read during rendering; changing language
    // does not restart a native operation or silently refresh official quota.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    const escape = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return;
      const open = document.querySelector<HTMLDetailsElement>('.local-proxy-panel .account-more[open]');
      if (open) { open.open = false; open.querySelector<HTMLElement>('summary')?.focus(); }
    };
    document.addEventListener('keydown', escape);
    return () => document.removeEventListener('keydown', escape);
  }, []);

  async function run<T>(name: string, action: () => Promise<T>): Promise<T | null> {
    if (operation.current) return null;
    operation.current = name; setPending(name); setError(''); setNotice('');
    const epoch = ++generation.current;
    try { const result = await action(); return alive.current && epoch === generation.current ? result : null; }
    catch (failure) { if (alive.current && epoch === generation.current) setError(failureText(failure, text)); return null; }
    finally { if (alive.current && operation.current === name) { operation.current = null; setPending(null); } }
  }

  async function save(next: ProxyPreferences): Promise<ProxyPreferences | null> {
    return run('save', async () => {
      const saved = parseProxyPreferences(await invoke('set_local_proxy_preferences', { preferences: parseProxyPreferences(next) }));
      if (alive.current) setPreferences(saved);
      return saved;
    });
  }
  async function refresh(quota = false) {
    await run(quota ? 'quota' : 'refresh', async () => {
      const raw = await Promise.allSettled([invoke('get_local_proxy_preferences'), invoke('get_local_proxy_status'), invoke(quota ? 'refresh_local_proxy_accounts' : 'get_local_proxy_accounts')]);
      if (!alive.current) return false;
      let failure: unknown;
      try { if (raw[0].status === 'rejected') throw raw[0].reason; setPreferences(parseProxyPreferences(raw[0].value)); } catch (error) { failure = error; }
      try { if (raw[1].status === 'rejected') throw raw[1].reason; setStatus(parseProxyStatus(raw[1].value)); setStatusFresh(true); } catch (error) { setStatusFresh(false); failure = error; }
      try { if (raw[2].status === 'rejected') throw raw[2].reason; setAccounts(parseProxyAccounts(raw[2].value)); setAccountsFresh(true); } catch (error) { setAccountsFresh(false); failure = error; }
      if (failure) throw failure;
      return true;
    });
  }
  async function lifecycle(start: boolean) {
    if (!preferences) return;
    await run(start ? 'start' : 'stop', async () => {
      if (start && !preferences.isEnabled) {
        const saved = parseProxyPreferences(await invoke('set_local_proxy_preferences', { preferences: { ...preferences, isEnabled: true } }));
        if (alive.current) setPreferences(saved);
      }
      const result = parseProxyStatus(await invoke(start ? 'start_local_proxy' : 'stop_local_proxy'));
      if (alive.current) { setStatus(result); setStatusFresh(true); }
      return true;
    });
  }
  async function saveNetwork() {
    if (!preferences || !draft) return;
    try {
      const next = parseProxyPreferences({ ...preferences, listenPort: numeric(draft.listenPort), clientKeyMode: draft.clientKeyMode, automaticRecoveryEnabled: draft.automaticRecoveryEnabled, desktopFallback: draft.desktopFallback, networkProxy: draft.networkProxy.trim(), creditFallback: draft.creditFallback, creditPrimaryFloor: numeric(draft.creditPrimaryFloor), creditSecondaryFloor: numeric(draft.creditSecondaryFloor), egress: { enabled: draft.egressEnabled, mihomoApi: draft.mihomoApi.trim(), group: draft.group.trim(), whitelist: draft.whitelist.split('\n').map(value => value.trim()).filter(Boolean) } });
      if (await save(next)) { setDraft(null); setNotice(text('设置已保存。', 'Settings saved.')); }
    } catch { setError(failureText('invalid_settings', text)); }
  }
  async function copyConnection() {
    await run('copy', async () => {
      // The key exists only for this explicit clipboard action, never in state,
      // the DOM, local storage, diagnostics or a background polling response.
      await navigator.clipboard.writeText(proxyConnectionText(await invoke('get_local_proxy_connection')));
      if (alive.current) setNotice(text('连接信息已复制，请妥善保管客户端密钥。', 'Connection copied. Keep the client key private.'));
      return true;
    });
  }
  async function selfCheck() {
    await run('self-check', async () => {
      const requestId = crypto.randomUUID();
      await invoke('local_proxy_network_command', { command: 'self_check', requestId });
      if (alive.current) { setSelfCheckRequestId(requestId); setNotice(text('自检请求已提交，结果以实际状态为准。', 'Self-check requested. Refer to the reported status for results.')); }
      return true;
    });
  }
  async function applyPlusLimit() {
    await run('plus', async () => {
      const limit = numeric(plusLimit);
      if (!Number.isFinite(limit) || limit < 0 || limit > 100) throw Error('invalid_settings');
      const saved = parseProxyPreferences(await invoke('set_local_proxy_plus_five_hour_used_limit', { limit }));
      if (alive.current) { setPreferences(saved); setNotice(text('Plus 的 5h 已用上限已保存。', 'The Plus 5h used limit is saved.')); }
      return true;
    });
  }
  const sorted = preferences && accounts ? proxyDisplayOrder(accounts, preferences) : [];
  const move = (accountId: string, offset: number) => {
    if (!preferences) return;
    const target = sorted[sorted.findIndex(account => account.id === accountId) + offset];
    if (!target) return;
    const order = [...preferences.order, ...sorted.map(account => account.id).filter(account => !preferences.order.includes(account))];
    const from = order.indexOf(accountId), to = order.indexOf(target.id);
    [order[from], order[to]] = [order[to], order[from]];
    void save({ ...preferences, order });
  };
  const busy = pending !== null;
  const active = status && ['starting', 'running', 'stopping'].includes(status.phase);
  const networkLocked = busy || !statusFresh || !!active;
  const form = draft ?? (preferences ? networkDraft(preferences) : null);
  const setField = <K extends keyof NetworkDraft>(key: K, value: NetworkDraft[K]) => { if (form) setDraft({ ...form, [key]: value }); setNotice(''); };
  const phase = statusFresh ? status?.phase : null;
  const phaseLabel = phase === 'running' ? text('运行中', 'Running') : phase === 'stopped' ? text('已停止', 'Stopped') : phase === 'starting' ? text('启动中', 'Starting') : phase === 'stopping' ? text('停止中', 'Stopping') : phase === 'failed' ? text('启动或运行失败', 'Failed') : text('状态待确认', 'Status unconfirmed');
  const egress = statusFresh ? status?.egress : null;
  const egressStates: Record<string, [string, string]> = { unavailable: ['不可用', 'Unavailable'], disabled: ['未启用', 'Disabled'], unconfigured: ['未配置', 'Unconfigured'], dead: ['不可达', 'Unreachable'], healthy: ['可达', 'Reachable'], changed: ['出口已变化', 'Egress changed'], switched: ['出口已切换', 'Egress switched'] };
  const matchingSelfCheck = !!selfCheckRequestId && egress?.requestId === selfCheckRequestId;
  return <section className="local-proxy-panel" aria-label={text('本地反代', 'Local proxy')} data-proxy-phase={phase ?? 'unknown'}>
    <header className="proxy-panel-header"><div><h2>{text('本地反代', 'Local proxy')}</h2><p>{text('按账号规则分配请求，显示顺序由你调整。', 'Route requests using account rules. Arrange the display order yourself.')}</p></div>
      <button type="button" className="icon-action" aria-label={text('刷新反代状态', 'Refresh proxy status')} title={text('刷新反代状态', 'Refresh proxy status')} disabled={busy} onClick={() => void refresh()}><RefreshCw size={16} className={pending === 'refresh' ? 'animate-spin' : ''} /></button>
    </header>
    <div className="proxy-service-card"><div className="proxy-service-status"><span className={`proxy-phase ${phase === 'running' ? 'is-running' : ''}`} role="status">{phaseLabel}</span>{phase === 'running' && status?.port && <code>http://127.0.0.1:{status.port}/v1</code>}</div><div className="proxy-service-actions">
      {!active && <button type="button" className="glass-button-solid proxy-action" disabled={busy || !preferences || !statusFresh} onClick={() => void lifecycle(true)}><Play size={14} />{pending === 'start' ? text('正在请求启动…', 'Requesting start…') : text('启动', 'Start')}</button>}
      {active && <button type="button" className="glass-button proxy-action" disabled={busy} onClick={() => void lifecycle(false)}><Square size={14} />{text('停止', 'Stop')}</button>}
      <button type="button" className="glass-button proxy-action" disabled={busy || phase !== 'running'} onClick={() => void copyConnection()}><Copy size={14} />{text('复制连接', 'Copy connection')}</button>
      <button type="button" className="glass-button proxy-action" disabled={busy || phase !== 'running'} onClick={() => void selfCheck()}><ShieldCheck size={14} />{text('网络自检', 'Network self-check')}</button>
    </div></div>
    <ProxyDesktopPanel accounts={sorted} accountsFresh={accountsFresh} proxyPhase={phase ?? null} parentBusy={busy} />
    {statusFresh && status?.issue && <p className="proxy-feedback is-error" role="alert">{failureText(status.issue, text)}</p>}
    {error && <p className="proxy-feedback is-error" role="alert">{error}</p>}{notice && <p className="proxy-feedback" role="status">{notice}</p>}
    {selfCheckRequestId && !matchingSelfCheck && <p className="proxy-note" role="status">{text('等待本次自检结果。', 'Waiting for this self-check result.')}</p>}
    {egress && (!selfCheckRequestId || matchingSelfCheck) && <p className="proxy-feedback" role="status" data-egress-state={egress.state}>{matchingSelfCheck ? text('本次自检 · ', 'This self-check · ') : text('网络出口 · ', 'Network egress · ')}{egressStates[egress.state] ? text(...egressStates[egress.state]) : text('未确认', 'Unconfirmed')}{egress.latencyMs !== null && ` · ${egress.latencyMs} ms`}</p>}
    <section className="proxy-accounts" aria-label={text('反代账号', 'Proxy accounts')}><header><h3>{text('参与账号', 'Participating accounts')}{accounts && <span>{accounts.length}</span>}</h3><button type="button" className="glass-button proxy-action" disabled={busy || accounts === null} onClick={() => void refresh(true)}><RefreshCw size={13} className={pending === 'quota' ? 'animate-spin' : ''} />{text('刷新额度', 'Refresh quota')}</button></header>
      {accounts === null ? <p className="proxy-note">{text('账号列表暂不可用，请刷新状态。', 'The account list is unavailable. Refresh status.')}</p> : !accounts.length ? <p className="proxy-note">{text('暂无可参与反代的托管 Codex 账号。', 'No managed Codex account is available for the proxy.')}</p> : <div className="proxy-account-grid">{preferences && sorted.map((account, index) => <ProxyAccountRow key={account.id} account={account} index={index} total={sorted.length} preferences={preferences} status={status} projectionFresh={accountsFresh} busy={busy} text={text} language={language} save={save} move={move} />)}</div>}
      {accounts?.some(account => account.planType === 'plus') && <div className="proxy-plus-limit"><label htmlFor="proxy-plus-limit">{text('Plus 统一 5h 已用上限 %', 'Shared Plus 5h used limit %')}</label><input id="proxy-plus-limit" type="number" min="0" max="100" step="0.1" placeholder="0–100" value={plusLimit} disabled={busy} onChange={event => setPlusLimit(event.target.value)} /><button type="button" className="glass-button proxy-action" disabled={busy || !plusLimit.trim()} onClick={() => void applyPlusLimit()}>{text('应用到 Plus', 'Apply to Plus')}</button></div>}
    </section>
    {form && <details className="proxy-settings"><summary>{text('反代设置', 'Proxy settings')}</summary><p className="proxy-note">{text('更改端口、密钥方式或网络设置前需停止反代。端口 0 表示自动选择。', 'Stop the proxy before changing its port, key mode or network settings. Port 0 selects a port automatically.')}</p><fieldset disabled={networkLocked}>
      <div className="proxy-settings-grid"><label>{text('监听端口', 'Listen port')}<input type="number" min="0" max="65535" step="1" value={form.listenPort} onChange={event => setField('listenPort', event.target.value)} /></label><label>{text('客户端密钥', 'Client key')}<select value={form.clientKeyMode} onChange={event => setField('clientKeyMode', event.target.value as NetworkDraft['clientKeyMode'])}><option value="persistent">{text('固定密钥', 'Persistent key')}</option><option value="perRun">{text('每次启动更新', 'New key per run')}</option></select></label><label className="proxy-wide">{text('上游网络代理', 'Upstream network proxy')}<input type="text" placeholder="http://127.0.0.1:7890" value={form.networkProxy} onChange={event => setField('networkProxy', event.target.value)} /></label></div>
      <div className="proxy-settings-checks"><label><input type="checkbox" checked={form.automaticRecoveryEnabled} onChange={event => setField('automaticRecoveryEnabled', event.target.checked)} />{text('运行中断后自动恢复', 'Recover after an interrupted run')}</label><label><input type="checkbox" checked={form.desktopFallback} onChange={event => setField('desktopFallback', event.target.checked)} />{text('允许桌面会话兜底', 'Allow desktop session fallback')}</label><label><input type="checkbox" checked={form.creditFallback} onChange={event => setField('creditFallback', event.target.checked)} />{text('允许点数兜底', 'Allow credit fallback')}</label></div>
      <div className="proxy-settings-grid"><label>{text('全局点数第一档', 'Global first credit floor')}<input type="number" min="0" step="1" value={form.creditPrimaryFloor} onChange={event => setField('creditPrimaryFloor', event.target.value)} /></label><label>{text('全局点数第二档', 'Global second credit floor')}<input type="number" min="0" step="1" value={form.creditSecondaryFloor} onChange={event => setField('creditSecondaryFloor', event.target.value)} /></label></div>
      <details className="proxy-egress"><summary>{text('网络出口', 'Network egress')}</summary><label className="proxy-check"><input type="checkbox" checked={form.egressEnabled} onChange={event => setField('egressEnabled', event.target.checked)} />{text('启用出口切换', 'Enable egress switching')}</label><div className="proxy-settings-grid"><label>{text('Mihomo 控制地址', 'Mihomo API')}<input value={form.mihomoApi} placeholder="http://127.0.0.1:9090" onChange={event => setField('mihomoApi', event.target.value)} /></label><label>{text('代理组', 'Proxy group')}<input value={form.group} onChange={event => setField('group', event.target.value)} /></label><label className="proxy-wide">{text('允许的节点，每行一个', 'Allowed nodes, one per line')}<textarea rows={3} value={form.whitelist} onChange={event => setField('whitelist', event.target.value)} /></label></div></details>
      <button type="button" className="glass-button proxy-action" disabled={!draft} onClick={() => void saveNetwork()}><Save size={13} />{text('保存设置', 'Save settings')}</button>
    </fieldset></details>}
  </section>;
}
