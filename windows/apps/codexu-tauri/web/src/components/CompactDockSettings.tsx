import { useEffect, useRef, useState } from 'react';
import { ChevronDown, ChevronUp, RefreshCw, Save, Trash2 } from 'lucide-react';
import { useCompactUi } from '../hooks/useCompactUi';
import { useI18n } from '../i18n/I18nProvider';
import { canonicalCompactProvider, dockLimit, dockProxy, dockStat, type CompactPreferences, type DockItem, type DockMetric } from '../utils/compactUi';

const metrics: DockMetric[] = ['today', 'week', 'last7', 'last30', 'month', 'allTime', 'liveRate', 'sessions'];
type Text = (zh: string, en: string) => string;
export function CompactDockSettings() {
  const { language } = useI18n(), [open, setOpen] = useState(false);
  return <details className="compact-dock-settings glass-panel" open={open} onToggle={event => setOpen(event.currentTarget.open)}>
    <summary>{language === 'zh-Hans' ? '侧边栏与悬浮统计' : 'Edge Dock and compact statistics'}</summary>
    {open && <DockSettingsBody />}
  </details>;
}
function DockSettingsBody() {
  const ui = useCompactUi(), { language } = useI18n();
  const text: Text = (zh, en) => language === 'zh-Hans' ? zh : en;
  const [draft, setDraft] = useState<CompactPreferences | null>(null), [saved, setSaved] = useState(false), [adding, setAdding] = useState('stat:today');
  const base = useRef<CompactPreferences | null>(null), signature = JSON.stringify(ui.state?.preferences ?? null);
  useEffect(() => {
    if (!ui.state) return;
    const next = ui.state.preferences;
    // Compare against the acknowledged base before updating either value.
    // State updaters can run twice in StrictMode, so mutating this ref inside
    // an updater would make its second pass mistake a clean draft for an edit.
    if (draft && JSON.stringify(draft) !== JSON.stringify(base.current) && JSON.stringify(draft) !== signature) return;
    base.current = structuredClone(next);
    setDraft(structuredClone(next));
  }, [signature]);
  const change = (patch: Partial<CompactPreferences>) => { setSaved(false); setDraft(previous => previous ? { ...previous, ...patch } : previous); };
  const current = draft?.items ?? ui.state?.resolvedItems ?? [];
  const dirty = !!draft && JSON.stringify(draft) !== JSON.stringify(base.current);
  const accounts = ui.state?.cachedProjection.accounts ?? [];
  const providers = [...new Set(accounts.map(account => canonicalCompactProvider(account.providerId)))];
  const labels: Record<DockMetric, string> = { today: text('今天', 'Today'), week: text('本周', 'This week'), last7: text('近 7 天', 'Last 7 days'), last30: text('近 30 天', 'Last 30 days'), month: text('本月', 'This month'), allTime: text('总计', 'Total'), liveRate: text('采样速率', 'Sampled rate'), sessions: text('会话', 'Sessions') };
  const title = (item: DockItem) => item.type === 'proxy' ? text('反代入口', 'Proxy settings') : item.type === 'stat' ? labels[item.metric!] : item.accountId ? accounts.find(account => account.id === item.accountId)?.label ?? text('账号待核对', 'Account unconfirmed') : item.providerId ?? '—';
  const move = (index: number, offset: number) => {
    if (!draft?.items || index + offset < 0 || index + offset >= draft.items.length) return;
    const items = [...draft.items]; [items[index], items[index + offset]] = [items[index + offset], items[index]]; change({ items });
  };
  const updateItem = (id: string, patch: Partial<DockItem>) => change({ items: current.map(item => item.id === id ? { ...item, ...patch } : item) });
  const newItem = adding === 'proxy' ? dockProxy() : adding.startsWith('limit:') ? dockLimit(adding.slice(6)) : dockStat(adding.slice(5) as DockMetric);
  const save = async () => {
    if (!draft || !base.current) return;
    const edited = draft;
    const patch = Object.fromEntries(Object.entries(draft).filter(([key, value]) => JSON.stringify(value) !== JSON.stringify(base.current![key as keyof CompactPreferences]))) as Partial<CompactPreferences>;
    if (await ui.save(patch)) { base.current = edited; setDraft({ ...edited }); setSaved(true); }
  };
  return <div className="compact-dock-settings-body">
    <div className="compact-dock-settings-heading"><p>{text('独立显示已有额度与同源 Token Monitor 统计。', 'Show existing quotas and the same Token Monitor statistics separately.')}</p><button className="glass-button notification-icon-button" aria-label={text('重新读取侧栏设置', 'Read Edge Dock settings')} onClick={() => void ui.read()} disabled={ui.busy}><RefreshCw size={14} /></button></div>
    {ui.error && <p role="alert" className="compact-note is-error">{text('侧栏设置暂不可读，请重试。', 'Edge Dock settings are unavailable. Try again.')}</p>}
    {ui.state?.failureCode && <p role="alert" className="compact-note is-error">{text('原生窗口状态未确认，请重新读取。', 'Native window state is unconfirmed. Read the settings again.')}</p>}
    {!draft ? <p className="compact-note" role="status">{text('正在读取侧栏设置…', 'Reading Edge Dock settings…')}</p> : <fieldset disabled={ui.busy}>
      <label className="compact-dock-toggle"><input type="checkbox" checked={draft.enabled} onChange={event => change({ enabled: event.target.checked })} />{text('显示侧边栏', 'Show Edge Dock')}</label>
      <p className="compact-note" role="status" data-testid="compact-shortcut-status">{ui.state?.shortcutStatus === 'registered'
        ? text('Ctrl+I 唤出或隐藏侧栏；自动隐藏时会展开并临时固定。', 'Ctrl+I reveals or hides Edge Dock; auto-hidden docks expand and stay pinned temporarily.')
        : ui.state?.shortcutStatus === 'unregistered' ? text('正在确认 Ctrl+I 注册状态。', 'Checking Ctrl+I registration.')
        : ui.state?.shortcutStatus === 'occupied' ? text('Ctrl+I 已被占用；仍可使用显示开关。', 'Ctrl+I is occupied; use the Show toggle.')
        : ui.state?.shortcutStatus === 'failed' ? text('Ctrl+I 注册失败；仍可使用显示开关。', 'Ctrl+I could not register; use the Show toggle.')
        : text('Ctrl+I 暂不可用；仍可使用显示开关。', 'Ctrl+I is unavailable; use the Show toggle.')}</p>
      {ui.state && ['occupied', 'failed'].includes(ui.state.shortcutStatus) && <button type="button" className="glass-button notification-small-button" disabled={ui.busy} onClick={() => void ui.retryShortcut()}>{text('重试 Ctrl+I', 'Retry Ctrl+I')}</button>}
      <div className="compact-dock-fields">
        <label>{text('显示方式', 'Visibility')}<select aria-label={text('显示方式', 'Visibility')} value={draft.mode} onChange={event => change({ mode: event.target.value as CompactPreferences['mode'] })}><option value="autoHide">{text('自动隐藏', 'Auto-hide')}</option><option value="always">{text('始终显示', 'Always visible')}</option></select></label>
        <label>{text('屏幕边缘', 'Screen edge')}<select aria-label={text('屏幕边缘', 'Screen edge')} value={draft.side} onChange={event => change({ side: event.target.value as CompactPreferences['side'] })}><option value="right">{text('右侧', 'Right')}</option><option value="left">{text('左侧', 'Left')}</option></select></label>
        <label>{text('显示屏幕', 'Display')}<select aria-label={text('显示屏幕', 'Display')} value={draft.displayId ?? ''} onChange={event => change({ displayId: event.target.value || null })}><option value="">{text('跟随当前屏幕', 'Follow current screen')}</option>{ui.state?.displays.map(display => <option key={display.id} value={display.id}>{display.label}{display.isPrimary ? text(' · 主屏幕', ' · Primary') : ''}</option>)}{draft.displayId && !ui.state?.displays.some(display => display.id === draft.displayId) && <option value={draft.displayId}>{text('已选屏幕暂不可用', 'Selected display unavailable')}</option>}</select></label>
        <label>{text('侧栏大小', 'Dock size')}<select aria-label={text('侧栏大小', 'Dock size')} value={draft.size} onChange={event => change({ size: event.target.value as CompactPreferences['size'] })}><option value="small">{text('小', 'Small')}</option><option value="medium">{text('标准', 'Medium')}</option><option value="large">{text('大', 'Large')}</option><option value="custom">{text('自定义', 'Custom')}</option></select></label>
        <label>{text('额度样式', 'Quota style')}<select aria-label={text('额度样式', 'Quota style')} value={draft.quotaStyle} onChange={event => change({ quotaStyle: event.target.value as CompactPreferences['quotaStyle'] })}><option value="ring">{text('圆环', 'Rings')}</option><option value="fish">{text('小鱼', 'Fish')}</option></select></label>
      </div>
      {draft.displayId && !ui.state?.displays.some(display => display.id === draft.displayId) && <p className="compact-note">{text('目标屏幕未连接，侧边栏隐藏到它重新连接；屏幕选择会保留。', 'The dock stays hidden until the selected display reconnects. Your choice is kept.')}</p>}
      {draft.size === 'custom' && <label className="compact-dock-scale">{text('自定义大小', 'Custom size')} <input type="range" min="0.75" max="1.5" step="0.05" value={draft.customScale} onChange={event => change({ customScale: Number(event.target.value) })} /><span>{Math.round(draft.customScale * 100)}%</span></label>}
      <div className="compact-dock-checks">
        <label><input type="checkbox" checked={draft.refreshEnabled} onChange={event => change({ refreshEnabled: event.target.checked })} />{text('在侧栏显示统计刷新按钮', 'Show a statistics refresh button')}</label>
        <label><input type="checkbox" checked={draft.runningIndicatorEnabled} disabled />{text('工作运行环 · 等待实时任务来源', 'Running indicator · live task source unavailable')}</label>
        <label><input type="checkbox" checked={draft.hapticEnabled} disabled />{text('触控板轻触反馈 · Windows 暂不可用', 'Trackpad haptics · unavailable on Windows')}</label>
        <label><input type="checkbox" checked={draft.warnColors} onChange={event => change({ warnColors: event.target.checked })} />{text('额度较低时用颜色提示', 'Highlight low limits in colour')}</label>
      </div>
      <details className="compact-dock-items"><summary>{text('常驻账号', 'Pinned accounts')}</summary>
        <button className="glass-button notification-small-button" onClick={() => change({ enabled: true, mode: 'always', side: 'right' })}>{text('右侧常驻', 'Keep on right')}</button>
        <div className="compact-dock-checks">{accounts.map(account => {
          const item = dockLimit(account.providerId, account.id), checked = current.some(value => value.id === item.id);
          return <label key={account.id}><input type="checkbox" checked={checked} disabled={!checked && current.length >= 24} onChange={event => change({ items: event.target.checked ? [...current, item] : current.filter(value => value.id !== item.id) })} />{account.label} · {canonicalCompactProvider(account.providerId)}</label>;
        })}{!accounts.length && <p className="compact-note">{text('暂无已登记账号快照', 'No registered account snapshots')}</p>}</div>
      </details>
      <details className="compact-dock-items"><summary>{text('侧边栏项目', 'Dock items')}</summary>
        {draft.items === null ? <><p className="compact-note">{text('自动显示反代、今日用量、最多三个已知额度平台与采样速率。', 'Automatically show proxy settings, today, up to three known quota providers and sampled rate.')}</p><button className="glass-button notification-small-button" onClick={() => change({ items: structuredClone(current) })}>{text('自定义当前项目', 'Customize current items')}</button></> : <>
          <div className="compact-dock-item-list">{draft.items.map((item, index) => <article key={item.id} data-settings-item={item.id}>
            <div className="compact-dock-item-row"><span>{index + 1}. {title(item)}</span><button aria-label={text('上移', 'Move up')} disabled={index === 0} onClick={() => move(index, -1)}><ChevronUp size={13} /></button><button aria-label={text('下移', 'Move down')} disabled={index === draft.items!.length - 1} onClick={() => move(index, 1)}><ChevronDown size={13} /></button><button aria-label={text('移除项目', 'Remove item')} onClick={() => change({ items: draft.items!.filter(value => value.id !== item.id) })}><Trash2 size={12} /></button></div>
            {item.type === 'limit' && !item.accountId && <details className="compact-dock-item-options"><summary>{text('额度项目选项', 'Limit item options')}</summary>
              <label><input type="checkbox" checked={item.showUsage} onChange={event => updateItem(item.id, { showUsage: event.target.checked })} />{text('详情卡显示 Token 用量', 'Show token usage in card')}</label>
              {canonicalCompactProvider(item.providerId ?? '') === 'codex' && <><label><input type="checkbox" checked={item.showSessions} onChange={event => updateItem(item.id, { showSessions: event.target.checked })} />{text('详情卡显示最近会话', 'Show recent sessions in card')}</label><label>{text('额度栏显示', 'Rail value')}<select aria-label={text('额度栏显示', 'Rail value')} value={item.accountMode} onChange={event => updateItem(item.id, { accountMode: event.target.value as DockItem['accountMode'] })}><option value="active">{text('当前账号', 'Current account')}</option><option value="lowest">{text('最低额度', 'Lowest visible allowance')}</option></select></label></>}
              {accounts.filter(account => canonicalCompactProvider(account.providerId) === canonicalCompactProvider(item.providerId ?? '')).map(account => <label key={account.id}><input type="checkbox" checked={!item.hiddenAccountIds.includes(account.id)} onChange={event => updateItem(item.id, { hiddenAccountIds: event.target.checked ? item.hiddenAccountIds.filter(id => id !== account.id) : [...item.hiddenAccountIds, account.id].sort() })} />{account.label}</label>)}
            </details>}
            {item.type === 'stat' && item.metric === 'sessions' && <details className="compact-dock-item-options"><summary>{text('会话项目选项', 'Session item options')}</summary><label><input type="checkbox" checked={item.runningOnly} onChange={event => updateItem(item.id, { runningOnly: event.target.checked })} />{text('仅显示采集时活跃的会话', 'Active at collection only')}</label></details>}
          </article>)}</div>
          {!draft.items.length && <p className="compact-note">{text('侧栏目前没有项目。', 'The dock has no items.')}</p>}
          <button className="glass-button notification-small-button" onClick={() => change({ items: null })}>{text('恢复自动', 'Reset to automatic')}</button>
        </>}
        <div className="compact-dock-add"><select aria-label={text('添加侧栏项目', 'Add dock item')} value={adding} onChange={event => setAdding(event.target.value)}><option value="proxy">{text('反代入口', 'Proxy settings')}</option>{providers.map(provider => <option key={provider} value={`limit:${provider}`}>{provider}</option>)}{metrics.map(metric => <option key={metric} value={`stat:${metric}`}>{labels[metric]}</option>)}</select><button className="glass-button notification-small-button" disabled={current.length >= 24 || current.some(item => item.id === newItem.id)} onClick={() => change({ items: [...current, newItem] })}>{text('添加', 'Add')}</button></div>
      </details>
      <div className="notification-card-actions"><button className="glass-button-solid notification-small-button" disabled={!dirty || ui.busy} onClick={() => void save()}><Save size={13} />{text('保存侧栏设置', 'Save Edge Dock settings')}</button>{saved && <span role="status" className="notification-save-status">{text('侧栏设置已保存', 'Edge Dock settings saved')}</span>}</div>
    </fieldset>}
  </div>;
}
