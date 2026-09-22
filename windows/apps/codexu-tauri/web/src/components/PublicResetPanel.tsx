import { useCallback, useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { useI18n } from '../i18n/I18nProvider';
import { parseForecast, parseNotices, type Forecast, type Notice } from '../utils/publicFeeds';
import { ResetCountdown } from './ResetCountdown';
import { HomeSection } from './HomeSection';
import { ResetHistory } from './ResetHistory';

type Feed = 'forecast' | 'history' | 'messages';
type State = { checkedAt: number; forecast: Forecast | null; notices: Notice[]; cached: boolean; failed: boolean };
const empty = (): State => ({ checkedAt: 0, forecast: null, notices: [], cached: false, failed: false });
const parse = (feed: Feed, raw: string, checkedAt: number): State => ({ checkedAt, forecast: feed === 'forecast' ? parseForecast(raw, checkedAt) : null,
  notices: feed === 'forecast' ? [] : parseNotices(raw, checkedAt, feed === 'messages'), cached: false, failed: false });

function usePublicFeed(feed: Feed) {
  const key = `aigoodbro.public.${feed}.v1`;
  const [state, setState] = useState<State>(empty);
  const [busy, setBusy] = useState(false);
  const inFlight = useRef(false);
  const generation = useRef(0);
  const refresh = useCallback(async () => {
    if (inFlight.current) return;
    const epoch = ++generation.current;
    inFlight.current = true; setBusy(true);
    try {
      const raw = await invoke<string>('read_public_feed', { feed });
      if (typeof raw !== 'string') throw new Error('Missing response');
      const checkedAt = Date.now();
      const next = parse(feed, raw, checkedAt);
      if (epoch !== generation.current) return;
      // A failed save must not overwrite the previously confirmed observation.
      localStorage.setItem(key, JSON.stringify({ raw, checkedAt }));
      setState(next);
    } catch {
      if (epoch === generation.current) setState(previous => ({ ...previous, cached: previous.checkedAt > 0, failed: true }));
    } finally {
      if (epoch === generation.current) { inFlight.current = false; setBusy(false); }
    }
  }, [feed, key]);
  useEffect(() => {
    let recent = false;
    try {
      const cache = localStorage.getItem(key);
      if (cache && cache.length < 1100000) {
        const { raw, checkedAt } = JSON.parse(cache);
        const age = Date.now() - checkedAt;
        if (typeof raw === 'string' && Number.isFinite(checkedAt) && age >= 0 && age <= 72 * 3600000) {
          const saved = parse(feed, raw, checkedAt);
          saved.notices = saved.notices.filter(item => item.expiresAt === undefined || item.expiresAt > Date.now());
          setState({ ...saved, cached: true }); recent = age < 300000;
        }
      }
    } catch { /* Corrupt cache cannot replace verified public data. */ }
    if (!recent) void refresh();
    return () => { generation.current++; inFlight.current = false; };
  }, [feed, key, refresh]);
  return { ...state, busy, refresh };
}

function NoticeList({ notices }: { notices: Notice[] }) {
  const { language } = useI18n();
  return <ul className="space-y-3">{notices.map(item => <li key={item.id} className="border-t border-theme pt-3 space-y-1">
    <div className="flex flex-wrap justify-between gap-2 text-xs"><strong className="text-primary">{item.title}</strong><time className="text-tertiary">{new Date(item.publishedAt).toLocaleString(language === 'zh-Hans' ? 'zh-CN' : 'en-GB')}</time></div>
    <p className="text-sm text-secondary whitespace-pre-wrap break-words">{item.body}</p>
    {item.source && <a className="text-xs text-accent underline" href={item.source} target="_blank" rel="noreferrer">{language === 'zh-Hans' ? '来源原文' : 'Original source'}</a>}
  </li>)}</ul>;
}

export function PublicResetPanel() {
  const { language } = useI18n();
  const text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const forecast = usePublicFeed('forecast');
  const history = usePublicFeed('history');
  const deadline = forecast.forecast?.deadline;
  return <HomeSection id="resets" title={text('重置消息', 'Reset updates')}><section className="glass-panel p-4 space-y-3" aria-label={text('公开重置消息', 'Public reset updates')}>
    <div className="flex justify-between items-center gap-3"><h2 className="text-sm font-semibold text-primary">{text('Codex 重置预告', 'Codex reset forecast')}</h2><button className="glass-button px-3 py-1 text-xs" disabled={forecast.busy || history.busy} onClick={() => { void forecast.refresh(); void history.refresh(); }}>{text('刷新', 'Refresh')}</button></div>
    {forecast.forecast ? <div className="rounded-xl border border-status-warn/30 bg-status-warn/8 p-3 space-y-2">
      <span className="text-xs text-status-warn">{text('公开预告 · 待确认', 'Public forecast · unconfirmed')}{forecast.cached && text(' · 缓存', ' · cached')}</span>
      <p className="font-semibold text-primary">{deadline === null ? text('时间待公布', 'Time to be announced') : text('预计最晚 ', 'Expected by ') + new Intl.DateTimeFormat(language === 'zh-Hans' ? 'zh-CN' : 'en-GB', { timeZone: 'Asia/Shanghai', year: 'numeric', month: 'short', day: 'numeric', weekday: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(deadline) + text(' · 北京时间', ' · Beijing time')}</p>
      <p className="font-semibold text-status-warn"><ResetCountdown deadline={deadline ?? null} kind="forecast" /></p>
      <p className="text-xs text-secondary">{text('实际到账以账号额度为准。到点不代表已完成重置。', 'Account quota confirms delivery. Reaching the deadline does not confirm a reset.')}</p>
      <a className="text-xs underline" href={forecast.forecast.source} target="_blank" rel="noreferrer">{text('来源公告', 'Source announcement')}</a>
    </div> : <p className="text-sm text-secondary">{forecast.busy ? text('正在读取公开预告…', 'Checking public forecast…') : forecast.checkedAt ? text('暂无待确认的重置预告', 'No pending forecast') : text('公开预告暂不可用', 'Public forecast unavailable')}</p>}
    {forecast.failed && <p className="text-xs text-status-warn" role="status">{text('本次预告无法确认；保留有效的上次记录。', 'Forecast could not be verified; the last valid record is retained.')}</p>}
    <details><summary className="text-xs text-secondary cursor-pointer">{text('最近 3 条历史记录', 'Latest 3 historical records')}</summary><NoticeList notices={history.notices.slice(0, 3)} />{history.failed && <p className="text-xs text-status-warn">{text('历史读取失败，可刷新重试。', 'History unavailable. Refresh to retry.')}</p>}</details>
    <details><summary className="text-xs text-secondary cursor-pointer">{text('展开日历与详情', 'Calendar and details')}</summary><ResetHistory notices={history.notices} /></details>
    {forecast.checkedAt > 0 && <p className="text-xs text-tertiary">{text('预告检查：', 'Forecast checked: ')}{new Date(forecast.checkedAt).toLocaleString()}</p>}
  </section></HomeSection>;
}

export function PublisherMessagePanel() {
  const { language } = useI18n();
  const feed = usePublicFeed('messages');
  const zh = language === 'zh-Hans';
  return <HomeSection id="messages" title={zh ? 'AiGoodBro 消息' : 'AiGoodBro messages'}><section className="glass-panel p-4 space-y-3" aria-label={zh ? '维护者公告' : 'Publisher announcements'}>
    <div className="flex justify-between items-center"><p className="text-xs text-secondary">{zh ? '最近 3 条有效公告' : 'Latest 3 active announcements'}</p><button className="glass-button px-3 py-1 text-xs" disabled={feed.busy} onClick={() => void feed.refresh()}>{zh ? '刷新' : 'Refresh'}</button></div>
    <NoticeList notices={feed.notices.slice(0, 3)} />
    {feed.notices.length === 0 && <p className="text-sm text-secondary">{feed.busy ? (zh ? '正在读取…' : 'Loading…') : feed.failed ? (zh ? '公告暂不可用，可刷新重试。' : 'Announcements unavailable. Refresh to retry.') : (zh ? '暂无有效公告' : 'No active announcements')}</p>}
  </section></HomeSection>;
}
