import { useState } from 'react';
import { useI18n } from '../i18n/I18nProvider';
import type { Notice } from '../utils/publicFeeds';
const dayKey = (date: number) => new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit' }).format(date);

export function ResetHistory({ notices }: { notices: Notice[] }) {
  const { language } = useI18n();
  const zh = language === 'zh-Hans';
  const today = dayKey(Date.now());
  const [month, setMonth] = useState(today.slice(0, 7));
  const [selected, setSelected] = useState(today);
  const [year, number] = month.split('-').map(Number);
  const first = new Date(Date.UTC(year, number - 1, 1));
  const offset = (first.getUTCDay() + 6) % 7;
  const days = new Date(Date.UTC(year, number, 0)).getUTCDate();
  const earliest = notices.length ? dayKey(Math.min(...notices.map(item => item.publishedAt))).slice(0, 7) : today.slice(0, 7);
  const selectedNotices = notices.filter(item => dayKey(item.publishedAt) === selected);
  const move = (delta: number) => setMonth(new Date(Date.UTC(year, number - 1 + delta, 1)).toISOString().slice(0, 7));
  return <div className="space-y-3 pt-3" aria-label={zh ? '历史公告日历' : 'Reset history calendar'}>
    <div className="flex items-center justify-between gap-3 text-sm">
      <button className="glass-button px-3 py-1" disabled={month <= earliest} onClick={() => move(-1)} aria-label={zh ? '上个月' : 'Previous month'}>←</button>
      <strong>{new Intl.DateTimeFormat(zh ? 'zh-CN' : 'en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(first)}</strong>
      <button className="glass-button px-3 py-1" disabled={month >= today.slice(0, 7)} onClick={() => move(1)} aria-label={zh ? '下个月' : 'Next month'}>→</button>
    </div>
    <div className="grid grid-cols-7 gap-1 text-center text-xs">
      {(zh ? ['一', '二', '三', '四', '五', '六', '日'] : ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']).map(day => <span key={day} className="py-1 text-tertiary">{day}</span>)}
      {Array.from({ length: offset }, (_, i) => <span key={'blank-' + i} />)}
      {Array.from({ length: days }, (_, i) => {
        const date = `${month}-${String(i + 1).padStart(2, '0')}`;
        const count = notices.filter(item => dayKey(item.publishedAt) === date).length;
        return <button key={date} type="button" aria-label={`${date}${count ? (zh ? '，有公告' : ', announcement') : ''}`} aria-pressed={selected === date}
          disabled={date > today} onClick={() => setSelected(date)} className={`rounded-lg py-2 ${selected === date ? 'bg-blue-600 text-white' : 'glass-button'} ${date === today ? 'font-bold' : ''}`}>
          {i + 1}<span className={`block mx-auto mt-1 w-1 h-1 rounded-full ${count ? 'bg-blue-400' : 'bg-transparent'}`} />
        </button>;
      })}
    </div>
    <p className="text-xs text-secondary">{selected} · {zh ? '北京时间' : 'Beijing time'}</p>
    {selectedNotices.length === 0 ? <p className="text-sm text-secondary">{zh ? '这一天没有已记录的公告。' : 'No recorded announcements on this date.'}</p> :
      <ul className="space-y-2">{selectedNotices.map(item => <li key={item.id} className="rounded-lg border border-theme p-3 space-y-1">
        <strong className="text-xs text-primary">{item.title}</strong><p className="text-sm text-secondary whitespace-pre-wrap break-words">{item.body}</p>
        {item.source && <a href={item.source} target="_blank" rel="noreferrer" className="text-xs text-accent underline">{zh ? '来源原文' : 'Original source'}</a>}
      </li>)}</ul>}
  </div>;
}
