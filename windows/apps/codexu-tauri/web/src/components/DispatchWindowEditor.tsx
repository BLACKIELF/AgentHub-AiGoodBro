import { useEffect, useState } from 'react';
import { defaultDispatchWindow, parseDispatchWindow, type DispatchInterval, type DispatchWindow } from '../utils/accountWorkflow';

export function DispatchWindowEditor({ value, revision, saving, chinese, onSave }: { value?: DispatchWindow | null; revision: number; saving: boolean; chinese: boolean; onSave: (window: DispatchWindow) => Promise<void> }) {
  const text = (zh: string, en: string) => chinese ? zh : en;
  const [draft, setDraft] = useState<DispatchWindow>(() => value ?? defaultDispatchWindow());
  const [expanded, setExpanded] = useState(false), [dirty, setDirty] = useState(false);
  const saved = JSON.stringify(value);
  useEffect(() => { setDraft(value ?? defaultDispatchWindow()); setDirty(false); }, [saved, revision]);
  function change(next: DispatchWindow) { setDraft(next); setDirty(true); }
  function interval(index: number, changeSet: Partial<DispatchInterval>) { change({ ...draft, intervals: draft.intervals.map((item, position) => position === index ? { ...item, ...changeSet } : item) }); }
  const clock = (minute: number) => Number.isInteger(minute) ? `${String(Math.floor(minute / 60)).padStart(2, '0')}:${String(minute % 60).padStart(2, '0')}` : '';
  const minute = (time: string) => /^\d\d:\d\d$/.test(time) ? Number(time.slice(0, 2)) * 60 + Number(time.slice(3)) : -1;
  let valid = true; try { parseDispatchWindow(draft); } catch { valid = false; }
  const modeLabel = (mode: DispatchWindow['mode']) => mode === 'onlyWithin' ? text('只在这些时段接新任务', 'Allow new work only within these windows') : mode === 'exceptWithin' ? text('这些时段不接新任务', 'Exclude these windows from new work') : text('不限制时间', 'Unrestricted');
  return <section className="rounded-xl border border-theme p-3 space-y-3" aria-label={text('调度时间段', 'Dispatch windows')}>
    <button type="button" className="flex w-full justify-between gap-3 text-left text-xs text-primary" aria-expanded={expanded} onClick={() => setExpanded(open => !open)}><span>{expanded ? '⌄' : '›'} {text('调度时间段', 'Dispatch windows')}</span><span className="text-secondary">{modeLabel(value?.mode ?? 'unrestricted')}</span></button>
    {expanded && <>
      <p className="text-xs text-secondary">{text('只控制新任务启动；已运行的任务、额度刷新和暖号不受影响。跨午夜时，星期按开始日计算。', 'Applies to new work only. Running work, allowance refresh and warm-up continue. Overnight windows use the starting weekday.')}</p>
      <label className="block text-xs text-secondary">{text('时间规则', 'Window rule')}<select aria-label={text('时间规则', 'Window rule')} className="mt-1 block w-full rounded-lg border border-theme bg-surface-inset px-2 py-2 text-primary" disabled={saving} value={draft.mode} onChange={event => change({ ...draft, mode: event.target.value as DispatchWindow['mode'] })}>{(['unrestricted', 'onlyWithin', 'exceptWithin'] as const).map(mode => <option key={mode} value={mode}>{modeLabel(mode)}</option>)}</select></label>
      <label className="block text-xs text-secondary">{text('时区', 'Time zone')}<input aria-label={text('时区', 'Time zone')} className="mt-1 block w-full rounded-lg border border-theme bg-surface-inset px-2 py-2 text-primary" maxLength={100} disabled={saving} value={draft.timeZoneIdentifier} onChange={event => change({ ...draft, timeZoneIdentifier: event.target.value })} placeholder="Asia/Shanghai" /></label>
      {draft.intervals.map((item, index) => <fieldset className="rounded-lg border border-theme p-3 space-y-2" key={index} disabled={saving}>
        <legend className="px-1 text-xs text-secondary">{text(`时段 ${index + 1}`, `Window ${index + 1}`)}</legend>
        <div className="flex flex-wrap items-center gap-3 text-xs">
          <label className="flex items-center gap-1"><input type="checkbox" checked={item.allDay} onChange={event => interval(index, { allDay: event.target.checked })} />{text('全天', 'All day')}</label>
          <label>{text('开始', 'Start')} <input type="time" aria-label={text(`开始 ${index + 1}`, `Start ${index + 1}`)} className="rounded border border-theme bg-surface-inset p-1 text-primary" disabled={item.allDay} value={clock(item.startMinute)} onChange={event => interval(index, { startMinute: minute(event.target.value) })} /></label>
          <label>{text('结束', 'End')} <input type="time" aria-label={text(`结束 ${index + 1}`, `End ${index + 1}`)} className="rounded border border-theme bg-surface-inset p-1 text-primary" disabled={item.allDay} value={clock(item.endMinute)} onChange={event => interval(index, { endMinute: minute(event.target.value) })} /></label>
          <button type="button" className="ml-auto glass-button px-2 py-1" onClick={() => change({ ...draft, intervals: draft.intervals.filter((_, position) => position !== index) })}>{text('移除', 'Remove')}</button>
        </div>
        <div className="flex flex-wrap items-center gap-2 text-xs">
          <label className="flex items-center gap-1"><input type="checkbox" checked={item.allDays} onChange={event => interval(index, { allDays: event.target.checked })} />{text('每天', 'Every day')}</label>
          {[1, 2, 3, 4, 5, 6, 7].map(day => <label className="flex items-center gap-1" key={day}><input type="checkbox" disabled={item.allDays} checked={item.weekdays.includes(day)} onChange={event => interval(index, { weekdays: event.target.checked ? [...item.weekdays, day].sort() : item.weekdays.filter(value => value !== day) })} />{chinese ? ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][day - 1] : ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][day - 1]}</label>)}
        </div>
      </fieldset>)}
      <div className="flex flex-wrap gap-2">
        <button type="button" className="glass-button px-3 py-2 text-xs" disabled={saving || draft.intervals.length >= 32} onClick={() => change({ ...draft, intervals: [...draft.intervals, { startMinute: 9 * 60, endMinute: 18 * 60, allDays: true, weekdays: [1, 2, 3, 4, 5], allDay: false }] })}>{text('添加时段', 'Add window')}</button>
        <button type="button" className="glass-button-solid px-3 py-2 text-xs" disabled={saving || !valid || !dirty} onClick={() => void onSave(parseDispatchWindow(draft))}>{text('保存时间规则', 'Save window rule')}</button>
        {dirty && <button type="button" className="glass-button px-3 py-2 text-xs" disabled={saving} onClick={() => { setDraft(value ?? defaultDispatchWindow()); setDirty(false); }}>{text('撤销更改', 'Discard changes')}</button>}
      </div>
      {!valid && <p role="alert" className="text-xs text-status-warn">{text('请检查时区、星期和起止时间；非全天时起止不能相同。', 'Check the time zone, weekdays and times. Start and end must differ unless all day.')}</p>}
      {valid && draft.mode === 'onlyWithin' && !draft.intervals.length && <p className="text-xs text-status-warn">{text('没有时段时，将不接收任何新任务。', 'With no windows, no new work will be admitted.')}</p>}
      {dirty && <p className="text-xs text-secondary">{text('尚未保存', 'Unsaved changes')}</p>}
    </>}
  </section>;
}
