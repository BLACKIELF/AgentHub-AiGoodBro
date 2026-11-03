import {useState} from 'react';
import {useI18n} from '../i18n/I18nProvider';
import {useAppearancePreferences} from '../hooks/useAppearancePreferences';
export function AppearanceControls() {
  const {language} = useI18n(), text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const prefs = useAppearancePreferences(), [saved, setSaved] = useState(false);
  const change = async (patch: Parameters<typeof prefs.save>[0]) => {setSaved(false); setSaved(await prefs.save(patch));};
  return <section className="appearance-controls space-y-4 mt-5" aria-label={text('玻璃与动效', 'Glass and motion')}>
    <div className="flex items-center gap-3"><img src="/icons/icon.png" width="40" height="40" alt="AiGoodBro"/><div><strong>AiGoodBro</strong><p className="text-xs text-secondary">{text('统一应用图标', 'App icon used throughout AiGoodBro')}</p></div></div>
    <p className="text-xs text-secondary">{text('使用 Windows 网页界面材质；系统高对比度或减少透明度时使用不透明背景，设置仍保留。', 'Uses Windows web interface materials. High contrast or reduced transparency uses an opaque background while retaining your settings.')}</p>
    {prefs.error && <p role="alert">{text('外观设置未能读取或保存。原值未被确认更改。', 'Appearance settings could not be read or saved. A change to the saved value is unconfirmed.')} <button type="button" className="glass-button px-2" onClick={prefs.read}>{text('重新读取', 'Read again')}</button></p>}
    {prefs.value && <fieldset disabled={prefs.busy} className="space-y-3">
      <label className="flex justify-between gap-3">{text('玻璃背景', 'Glass backdrop')}<select aria-label={text('玻璃背景', 'Glass backdrop')} className="glass-input p-1" value={String(prefs.value.systemGlass)} onChange={e => void change({systemGlass: e.target.value === 'true'})}><option value="true">{text('系统', 'System')}</option><option value="false">{text('透明', 'Transparent')}</option></select></label>
      {(['opacity', 'depth'] as const).map(key => <div key={key} className="flex flex-wrap items-center gap-2"><label className="flex flex-1 items-center gap-3">{key === 'opacity' ? text('玻璃浓度', 'Glass') : text('层次', 'Depth')}<input type="range" min="0" max="100" step="1" value={prefs.value![key]} onChange={e => void change({[key]: Number(e.target.value)})}/><output>{prefs.value![key]}</output></label><button type="button" className="glass-button px-2 py-1" aria-label={key === 'opacity' ? text('重置玻璃浓度', 'Reset glass') : text('重置层次', 'Reset depth')} onClick={() => void change({[key]: key === 'opacity' ? 68 : 32})}>{text('恢复默认', 'Reset')}</button></div>)}
      <p className="text-xs text-secondary">{text('层次调整边框与控件对比，不改变模糊半径。', 'Depth changes border and control contrast, not blur radius.')}</p>
      <label className="flex justify-between gap-3">{text('额度环动效', 'Ring motion')}<select aria-label={text('额度环动效', 'Ring motion')} className="glass-input p-1" value={prefs.value.ringMotion} onChange={e => void change({ringMotion: e.target.value as 'default' | 'powerSaving'})}><option value="default">{text('默认', 'Default')}</option><option value="powerSaving">{text('省电', 'Power Saving')}</option></select></label>
      <p className="text-xs text-secondary">{text('默认仅前台聚焦时播放；省电仅悬停时播放。遵循系统减少动态效果设置。', 'Default: active window only. Power Saving: pointer hover only. Respects reduced motion.')}</p>
    </fieldset>}
    {saved && !prefs.error && <p role="status">{text('外观设置已保存。', 'Appearance settings saved.')}</p>}
  </section>;
}
