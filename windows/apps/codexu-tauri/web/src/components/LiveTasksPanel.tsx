import { Activity, RefreshCw } from 'lucide-react';
import { useLiveTasks } from '../hooks/useLiveTasks';
import { useI18n } from '../i18n/I18nProvider';
import type { LiveTaskStatus } from '../utils/liveTasks';

export function LiveTasksPanel() {
  const { state, busy, read, reconnect } = useLiveTasks(), { language } = useI18n();
  const text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const label = (state: LiveTaskStatus) => ({ idle: text('空闲', 'Idle'), running: text('运行中', 'Running'), waiting_input: text('等待输入', 'Waiting for input'), recorded: text('已记录', 'Recorded'), disconnected: text('已断开', 'Disconnected'), failed: text('失败', 'Failed'), completed: text('已完成', 'Completed'), interrupted: text('已中断', 'Interrupted') })[state];
  const date = (value: number | null) => value === null ? '—' : new Date(value).toLocaleString(language === 'zh-Hans' ? 'zh-CN' : 'en-GB');
  return <section className="glass-panel live-tasks-panel p-4 sm:p-5" aria-label={text('实时任务', 'Live tasks')} data-live-phase={state.phase}>
    <header className="flex items-center justify-between gap-2"><h3 className="flex items-center gap-2 text-sm font-semibold text-primary"><Activity size={15} />{text('实时任务', 'Live tasks')}</h3><div className="flex gap-2"><button className="icon-action" type="button" aria-label={text('读取实时任务', 'Read live tasks')} disabled={busy} onClick={() => void read()}><RefreshCw size={14} /></button>{state.phase !== 'live' && <button className="glass-button proxy-action" disabled={busy} onClick={() => void reconnect()}>{busy ? text('正在连接…', 'Connecting…') : text('重新连接任务来源', 'Reconnect task source')}</button>}</div></header>
    {state.phase === 'unavailable' ? <p role="status" className="proxy-note">{state.issueCode === 'official_tasks_scope_unverified' ? text('当前系统账号尚未核实，实时任务未连接。', 'The current system identity is unconfirmed; live tasks are disconnected.') : text('实时任务来源未连接或已过期，当前占用未知。', 'Live task source is disconnected or expired. Current activity is unknown.')}</p> : <><p className="proxy-note">{text('来源采集 ', 'Source observed ')}{date(state.observedAtMs)}{!state.tasks.length && text(' · 此来源当前没有任务。', ' · This source currently has no tasks.')}</p><div className="live-task-grid">{state.tasks.map((row, index) => <article key={index} className="live-task-row" data-runtime-state={row.state}><header><strong>{text('任务 ', 'Task ')}{row.ordinal}</strong><span>{label(row.state)}</span></header>{row.turnState !== null && <p>{text('本轮记录 ', 'Turn record ')}{label(row.turnState)}</p>}{row.startedAtMs !== null && <p>{text('开始 ', 'Started ')}{date(row.startedAtMs)}</p>}{row.completedAtMs !== null && <p>{text('本轮结束 ', 'Turn ended ')}{date(row.completedAtMs)}</p>}</article>)}</div></>}
    <p className="proxy-note">{text('运行状态与本轮结束记录分别显示；序号仅表示本次快照的顺序。', 'Runtime state and turn records are separate. Numbers indicate this snapshot’s display order.')}</p>
  </section>;
}
