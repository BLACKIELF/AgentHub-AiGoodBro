import { useEffect, useRef, useState } from 'react';
import { useCompactUi } from '../hooks/useCompactUi';
import { useI18n } from '../i18n/I18nProvider';
import { bubbleMetrics, canonicalCompactProvider, mergeBubbleDraft, parseBubblePreferences, resolveBubble, type BubblePreferences, type CompactAccount } from '../utils/compactUi';
import { ProviderMark, providerName } from './ProviderMark';

export function BubblePreview({ preferences, accounts }: { preferences: BubblePreferences; accounts: CompactAccount[] }) {
  const { language } = useI18n(), text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const [now, setNow] = useState(Date.now());
  const { account, metric, percent, valueLabel, stale } = resolveBubble(preferences, accounts, now);
  useEffect(() => { const at = metric?.resetsAt; if (!at || at <= Date.now()) { setNow(Date.now()); return; } const timer = setTimeout(() => setNow(Date.now()), Math.min(at - Date.now() + 1, 2147483647)); return () => clearTimeout(timer); }, [metric?.resetsAt]);
  return <div className={'bubble-preview font-' + preferences.fontStyle} data-testid="bubble-preview">
    <div className="bubble-identity">{preferences.showIcon && <ProviderMark provider={preferences.selectedProviderId ?? ''} size={24} />}<div><strong>{preferences.selectedProviderId ? providerName(preferences.selectedProviderId) : text('选择额度', 'Choose a quota')}</strong><p>{account?.label ?? text('账号未确认', 'Account unconfirmed')}</p></div></div>
    {preferences.customText && <p className="bubble-custom-text">{preferences.customText}</p>}
    <div className="bubble-value"><span>{metric?.label ?? '—'} · {preferences.valueMode === 'used' ? text('已用', 'Used') : text('剩余', 'Remaining')}</span>{preferences.showPercent && <strong>{valueLabel ?? (percent === null ? '—' : Number(percent.toFixed(1)) + '%')}</strong>}</div>
    {preferences.showQuotaBar && <div className="bubble-quota-track" role="img" aria-label={percent === null ? text('额度未知', 'Quota unknown') : (metric?.label ?? '') + ' · ' + Number(percent.toFixed(1)) + '%'}><span style={{ width: percent === null ? 0 : percent + '%' }} /></div>}
    {preferences.showResetTime && <p className="bubble-reset">{metric?.resetsAt ? text('重置 ', 'Resets ') + new Date(metric.resetsAt).toLocaleString(language === 'zh-Hans' ? 'zh-CN' : 'en-GB', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false }) : text('重置时间未知', 'Reset time unknown')}</p>}
    {stale && <p className="bubble-evidence">{text('上次快照 · 请在账号页重新读取', 'Previous snapshot · read again in Accounts')}</p>}
    {!metric && <p className="bubble-evidence">{text('所选额度暂无可核对快照', 'No verified snapshot for the selected quota')}</p>}
    {preferences.showCost && <p className="bubble-evidence">{text('费用未知', 'Cost unconfirmed')}</p>}
  </div>;
}

export function BubblePreferencesForm({ ui, onCancel }: { ui: ReturnType<typeof useCompactUi>; onCancel?: () => void }) {
  const { language } = useI18n(), text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const [draft, setDraft] = useState<BubblePreferences | null>(null), [saved, setSaved] = useState(false), [saveFailed, setSaveFailed] = useState(false);
  const base = useRef<BubblePreferences | null>(null), signature = JSON.stringify(ui.state?.preferences.bubble ?? null);
  useEffect(() => {
    if (!ui.state || draft && JSON.stringify(draft) !== JSON.stringify(base.current) && JSON.stringify(draft) !== signature) return;
    base.current = structuredClone(ui.state.preferences.bubble); setDraft(structuredClone(base.current));
  }, [signature]);
  const accounts = ui.state?.cachedProjection.accounts ?? [];
  const providers = [...new Set(accounts.filter(account => account.loggedIn).map(account => canonicalCompactProvider(account.providerId)))];
  const selectedAccounts = accounts.filter(account => account.loggedIn && canonicalCompactProvider(account.providerId) === draft?.selectedProviderId);
  const selected = selectedAccounts.find(account => account.id === draft?.selectedProfileId);
  const metrics = selected ? bubbleMetrics(selected) : [];
  const selectedMetric = draft ? resolveBubble(draft, accounts).metric?.id ?? draft.selectedMetricId ?? '' : '';
  const change = (patch: Partial<BubblePreferences>) => { setSaved(false); setSaveFailed(false); setDraft(previous => previous ? { ...previous, ...patch } : previous); };
  const dirty = !!draft && JSON.stringify(draft) !== JSON.stringify(base.current);
  const conflict = !!draft && !!base.current && (dirty && signature !== JSON.stringify(base.current) || ui.error === 'compact_preferences_conflict');
  const mergeLatest = () => { if (!draft || !base.current || !ui.state) return; const latest = structuredClone(ui.state.preferences.bubble); setDraft(mergeBubbleDraft(base.current, draft, latest)); base.current = latest; setSaved(false); setSaveFailed(false); };
  const save = async () => { if (!draft || !base.current || conflict) return; const edited = parseBubblePreferences(draft); setSaveFailed(false); if (await ui.save({ bubble: edited }, base.current)) { base.current = structuredClone(edited); setDraft(structuredClone(edited)); setSaved(true); } else { setSaveFailed(true); await ui.read(); } };
  return <section className="bubble-editor-body" aria-label={text('悬浮额度编辑器', 'Floating quota editor')}>
    {conflict && <div className="bubble-conflict" role="alert"><p>{text('其他窗口已更改悬浮额度。你的草稿尚未保存，请先核对最新设置。', 'Another window changed floating quota. Your draft is not saved; review the latest settings first.')}</p><button type="button" className="glass-button" disabled={ui.busy} onClick={() => void ui.read()}>{text('重新读取，保留草稿', 'Read latest and keep draft')}</button><button type="button" className="glass-button" disabled={ui.busy || !ui.state} onClick={mergeLatest}>{text('将我的修改合并到最新设置', 'Merge my edits into latest settings')}</button></div>}
    {(ui.error || saveFailed) && !conflict && <p role="alert" className="text-status-error">{text('设置未保存，请重试；草稿已保留。', 'Settings could not be confirmed. Your draft is kept; retry.')}</p>}
    {ui.state?.failureCode && <p role="alert">{text('原生窗口状态未确认', 'Native window state is unconfirmed')}</p>}
    {!draft ? <p role="status">{text('正在读取…', 'Reading…')}</p> : <>
      <BubblePreview preferences={draft} accounts={accounts} />
      <fieldset disabled={ui.busy} className="bubble-fields">
        <label className="bubble-toggle"><input type="checkbox" checked={draft.enabled} onChange={event => change({ enabled: event.target.checked })} />{text('显示悬浮额度', 'Show floating quota')}</label>
        <label>{text('平台', 'Provider')}<select aria-label={text('平台', 'Provider')} value={draft.selectedProviderId ?? ''} onChange={event => change({ selectedProviderId: event.target.value || null, selectedProfileId: null, selectedMetricId: null })}><option value="">{text('请选择', 'Choose')}</option>{providers.map(id => <option key={id} value={id}>{providerName(id)}</option>)}{draft.selectedProviderId && !providers.includes(draft.selectedProviderId) && <option value={draft.selectedProviderId}>{text('已选平台暂不可用', 'Selected provider unavailable')}</option>}</select></label>
        <label>{text('账号', 'Account')}<select aria-label={text('账号', 'Account')} value={draft.selectedProfileId ?? ''} onChange={event => change({ selectedProfileId: event.target.value || null, selectedMetricId: null })}><option value="">{text('请选择', 'Choose')}</option>{selectedAccounts.map(account => <option key={account.id} value={account.id}>{account.label}</option>)}{draft.selectedProfileId && !selected && <option value={draft.selectedProfileId}>{text('已选账号暂不可用', 'Selected account unavailable')}</option>}</select></label>
        <label>{text('额度窗口', 'Quota window')}<select aria-label={text('额度窗口', 'Quota window')} value={selectedMetric} onChange={event => change({ selectedMetricId: event.target.value || null })}><option value="">{text('请选择', 'Choose')}</option>{metrics.map(metric => <option key={metric.id} value={metric.id}>{metric.label}</option>)}{selectedMetric && !metrics.some(metric => metric.id === selectedMetric) && <option value={selectedMetric}>{text('已选额度暂不可用', 'Selected quota unavailable')}</option>}</select></label>
        <label>{text('显示数值', 'Value')}<select value={draft.valueMode} onChange={event => change({ valueMode: event.target.value as BubblePreferences['valueMode'] })}><option value="remaining">{text('剩余', 'Remaining')}</option><option value="used">{text('已用', 'Used')}</option></select></label>
        <label>{text('字体', 'Font')}<select value={draft.fontStyle} onChange={event => change({ fontStyle: event.target.value as BubblePreferences['fontStyle'] })}>{[['menubar', text('菜单栏', 'Menu bar')], ['normal', text('标准', 'Normal')], ['condensed', text('紧凑', 'Condensed')], ['compactMono', text('等宽', 'Monospace')]].map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>
        <label>{text('自定义文字', 'Custom text')}<input maxLength={80} value={draft.customText} onChange={event => change({ customText: event.target.value.replace(/[\x00-\x1f\x7f-\x9f]/g, '') })} /></label>
        <div className="bubble-options">{([['showIcon', text('图标', 'Icon')], ['showQuotaBar', text('额度条', 'Quota bar')], ['showPercent', text('百分比', 'Percent')], ['showResetTime', text('重置时间', 'Reset time')]] as const).map(([key, label]) => <label key={key}><input type="checkbox" checked={draft[key]} onChange={event => change({ [key]: event.target.checked })} />{label}</label>)}</div>
      </fieldset>
      <div className="bubble-editor-actions"><button type="button" className="glass-button-solid" disabled={ui.busy || !dirty || conflict} onClick={() => void save()}>{text('保存悬浮额度', 'Save floating quota')}</button><button type="button" className="glass-button" disabled={ui.busy} onClick={() => { setDraft(base.current ? structuredClone(base.current) : null); setSaved(false); setSaveFailed(false); onCancel?.(); }}>{onCancel ? text('取消', 'Cancel') : text('撤销更改', 'Discard changes')}</button></div>
      {saved && <p role="status">{text('悬浮额度设置已保存', 'Floating quota settings saved')}</p>}
    </>}
  </section>;
}
export function FloatingBubbleSettings() {
  const { language } = useI18n(), [open, setOpen] = useState(false);
  return <details className="compact-dock-settings glass-panel" open={open} onToggle={event => setOpen(event.currentTarget.open)}><summary>{language === 'zh-Hans' ? '悬浮额度' : 'Floating quota'}</summary>{open && <BubbleSettingsBody />}</details>;
}
function BubbleSettingsBody() { const ui = useCompactUi(); return <BubblePreferencesForm ui={ui} />; }
