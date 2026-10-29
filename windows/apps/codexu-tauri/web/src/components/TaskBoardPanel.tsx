import { Archive, CalendarClock, CircleDashed, CircleDot, ClipboardList, Clock3 } from 'lucide-react';
import type { TaskBoard, TaskItem } from '../types/models';
import { useI18n } from '../i18n/I18nProvider';
import { LiveTasksPanel } from './LiveTasksPanel';

interface TaskBoardPanelProps {
  taskBoard: TaskBoard | null;
}

const COLUMN_ICONS = {
  active: CircleDot,
  pending: Clock3,
  scheduled: CalendarClock,
  done: Archive,
} as const;

export function TaskBoardPanel({ taskBoard }: TaskBoardPanelProps) {
  return <div className="space-y-3"><LiveTasksPanel /><RecordedTaskBoard taskBoard={taskBoard} /></div>;
}
function RecordedTaskBoard({ taskBoard }: TaskBoardPanelProps) {
  const { t } = useI18n();
  if (!taskBoard) {
    return (
      <section className="glass-panel p-4 sm:p-5" aria-live="polite">
        <PanelHeading t={t} />
        <p className="text-sm text-secondary mt-2">
          {t('tasks.unavailable')}
        </p>
      </section>
    );
  }

  const itemCount = taskBoard.columns.reduce((sum, column) => sum + column.items.length, 0);
  const isEmpty = itemCount === 0;

  return (
    <section className="glass-panel p-4 sm:p-5 space-y-4" aria-label={t('tasks.ariaLabel')} aria-live="polite">
      <PanelHeading t={t} summary={taskBoardSummary(taskBoard, itemCount, t)} />
      <p className="text-xs text-tertiary">{t('tasks.recorded')}</p>
      {isEmpty ? (
        <div className="task-board-empty flex items-start gap-2 rounded-xl border border-theme bg-surface-inset px-3 py-2.5">
          <CircleDashed size={15} aria-hidden="true" className="mt-0.5 shrink-0 text-tertiary" />
          <div>
            <p className="text-sm text-secondary">{t('tasks.empty')}</p>
            <p className="mt-1 text-xs text-tertiary">
              {t('tasks.emptyDetail')}
            </p>
          </div>
        </div>
      ) : null}
      <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-3">
        {taskBoard.columns.map((column) => {
          const Icon = COLUMN_ICONS[column.id as keyof typeof COLUMN_ICONS] ?? ClipboardList;
          return (
            <section key={column.id} className="rounded-2xl border border-theme bg-surface-inset p-3 min-h-40">
              <div className="flex items-center justify-between gap-2 mb-3">
                <div className="flex items-center gap-2 min-w-0">
                  <Icon size={15} aria-hidden="true" className="text-secondary shrink-0" />
                  <h4 className="text-sm font-semibold text-primary truncate">{column.title}</h4>
                </div>
                <span className="text-xs text-tertiary tabular-nums">{column.count}</span>
              </div>
              {column.items.length === 0 ? (
                <div className="task-column-empty flex items-center gap-2 py-3 text-xs text-tertiary">
                  <CircleDashed size={13} aria-hidden="true" />
                  <span>{t('common.noRecords')}</span>
                </div>
              ) : (
                <div className="space-y-2">
                  {column.items.map((item) => (
                    <article key={item.id} className="rounded-xl border border-theme bg-surface-elevated p-3">
                      <div className="min-w-0">
                        <p
                          className="task-card-title text-sm font-medium text-primary leading-snug min-w-0 break-words min-h-10"
                          title={item.title}
                        >
                          {item.title}
                        </p>
                      </div>
                      {item.detail || factualTime(item, t) ? (
                        <div className="task-card-meta mt-2 flex min-w-0 items-center gap-2 text-xs">
                          {item.detail ? <span className="min-w-0 truncate text-secondary">{item.detail}</span> : null}
                          {factualTime(item, t) ? (
                            <time className="shrink-0 text-tertiary">{factualTime(item, t)}</time>
                          ) : null}
                        </div>
                      ) : null}
                      <footer className="task-card-footer mt-2 pt-2 border-t border-theme/30">
                        <span
                          className={`state-badge inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] ${stateBadgeClass(item)}`}
                        >
                          {(() => {
                            const StateIcon = stateIcon(item);
                            return <StateIcon size={12} aria-hidden="true" />;
                          })()}
                          {stateLabel(item, t)}
                        </span>
                      </footer>
                    </article>
                  ))}
                </div>
              )}
            </section>
          );
        })}
      </div>
    </section>
  );
}

function PanelHeading({ summary, t }: { summary?: string | null; t: ReturnType<typeof useI18n>['t'] }) {
  return (
    <div className="flex items-center justify-between gap-3">
      <div className="flex min-w-0 items-center gap-2">
        <ClipboardList size={16} aria-hidden="true" />
        <h3 className="text-sm font-semibold text-primary">{t('tasks.title')}</h3>
      </div>
      {summary ? <p className="task-board-summary shrink-0 text-right text-xs text-secondary tabular-nums">{summary}</p> : null}
    </div>
  );
}

function taskBoardSummary(taskBoard: TaskBoard, itemCount: number, t: ReturnType<typeof useI18n>['t']): string {
  const refreshedAt = formatTaskTime(taskBoard.refreshed_at);
  return refreshedAt
    ? t('tasks.summary', { count: itemCount, time: refreshedAt })
    : t('tasks.summaryCount', { count: itemCount });
}

function formatTaskTime(value: number): string | null {
  if (!Number.isFinite(value)) return null;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return null;
  return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

function stateLabel(item: TaskItem, t: ReturnType<typeof useI18n>['t']): string {
  switch (item.display_state) {
    case 'recentlyActive':
      return t('tasks.recentActivity');
    case 'continueLater':
      return t('tasks.toContinue');
    case 'archived':
      return t('tasks.archived');
    case 'scheduled':
      return t('tasks.scheduled');
    default:
      return t('tasks.recorded');
  }
}

function stateIcon(item: TaskItem) {
  switch (item.display_state) {
    case 'recentlyActive':
      return Clock3;
    case 'continueLater':
      return CircleDot;
    case 'archived':
      return Archive;
    case 'scheduled':
      return CalendarClock;
    default:
      return ClipboardList;
  }
}

function stateBadgeClass(item: TaskItem): string {
  switch (item.display_state) {
    case 'recentlyActive':
      return 'border-status-warn/30 bg-status-warn/12 text-status-warn';
    case 'scheduled':
      return 'border-accent/25 bg-accent/10 text-accent';
    case 'continueLater':
    case 'archived':
    default:
      return 'border-theme bg-surface-inset text-secondary';
  }
}

function factualTime(item: TaskItem, t: ReturnType<typeof useI18n>['t']): string | null {
  if (item.updated_at == null || !Number.isFinite(item.updated_at)) return null;
  const time = new Date(item.updated_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  const label = item.display_state === 'archived' ? t('tasks.archivedAt', { time }) : t('tasks.updated', { time });
  return label;
}
