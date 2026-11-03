import { useEffect, useId, useState } from 'react';
import { useI18n } from '../i18n/I18nProvider';
import type { TokenMonitorController } from '../hooks/useTokenMonitor';
import type { StatisticsTimezonePreference } from '../utils/statisticsTimezone';
export function StatisticsTimezoneSettings({ controller }: { controller: TokenMonitorController }) {
  const { language } = useI18n(), text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const { timezonePreference, selectTimezone, busy } = controller;
  const [draft, setDraft] = useState(timezonePreference), [saved, setSaved] = useState<string|null>(null);
  const id = useId();
  useEffect(() => { setDraft(timezonePreference); }, [timezonePreference.selection, timezonePreference.fixedIdentifier]);
  const dirty = draft.selection !== timezonePreference.selection || draft.fixedIdentifier !== timezonePreference.fixedIdentifier;
  const zones = (Intl as unknown as { supportedValuesOf?: (key: string) => string[] }).supportedValuesOf?.('timeZone') ?? [];
  return <details className="token-monitor-timezone"><summary>{text('统计时区', 'Usage time zone')}</summary>
    <form onSubmit={event => { event.preventDefault(); setSaved(null); const key=JSON.stringify(draft); void selectTimezone(draft).then(ok=>setSaved(ok?key:null)); }}><fieldset disabled={busy} className="flex flex-wrap items-end gap-2 py-2">
      <label className="text-xs">{text('统计时区', 'Usage time zone')}<select aria-label={text('统计时区', 'Usage time zone')} className="glass-input block p-2" value={draft.selection} onChange={event => { setSaved(null); setDraft(previous => ({ ...previous, selection: event.target.value as StatisticsTimezonePreference['selection'] })); }}><option value="system">{text('系统', 'System')}</option><option value="utc">UTC</option><option value="fixed">{text('固定', 'Fixed')}</option></select></label>
      {draft.selection === 'fixed' && <label className="text-xs">{text('固定时区', 'Fixed time zone')}<input aria-label={text('固定时区', 'Fixed time zone')} className="glass-input block p-2" list={id} maxLength={64} value={draft.fixedIdentifier} onChange={event => { setSaved(null); setDraft(previous => ({ ...previous, fixedIdentifier: event.target.value })); }} /><datalist id={id}><option value="UTC" />{zones.map(zone => <option key={zone} value={zone} />)}</datalist></label>}
      <button type="submit" className="glass-button proxy-action" disabled={!dirty || busy}>{text('保存时区', 'Save time zone')}</button>{saved===JSON.stringify(timezonePreference) && <p role="status" className="text-xs">{text('时区已保存', 'Time zone saved')}</p>}
      <p className="text-xs text-secondary">{text('按此时区划分日/月统计；固定 IANA 时区自动处理夏令时。', 'Daily/monthly statistics use this zone. Fixed IANA zones follow daylight saving time.')}</p>
    </fieldset></form></details>;
}
