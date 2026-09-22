import { Activity, Calendar, TrendingUp } from 'lucide-react';
import { useRef, useState, type KeyboardEvent } from 'react';
import type { CodexLeadershipSignal, UsageSnapshot } from '../types/models';
import { LeadershipOverviewCard, LeadershipPanel } from './LeadershipPanel';
import { MonthlyValueProgress } from './MonthlyValueProgress';
import { ProjectsPanel } from './ProjectsPanel';
import { QuotaOverview } from './QuotaOverview';
import { SkillsPanel } from './SkillsPanel';
import { TaskBoardPanel } from './TaskBoardPanel';
import { UsagePanel } from './UsagePanel';
import { StatCard } from './StatCard';
import { useI18n } from '../i18n/I18nProvider';
import type { MessageKey } from '../i18n/messages';
import { HomeSection } from './HomeSection';

interface DashboardHomeProps {
  snapshot: UsageSnapshot | null | undefined;
  quotaSourceLabel: string | null | undefined;
  leadershipSignal: CodexLeadershipSignal | null | undefined;
  onQuotaRefresh: () => void;
}

type DashboardContentTab = 'tasks' | 'leadership' | 'usage' | 'projects' | 'skills';

const DASHBOARD_TABS: Array<{ id: DashboardContentTab; title: string; titleKey: MessageKey }> = [
  { id: 'tasks', title: 'Tasks', titleKey: 'dashboard.tabs.tasks' },
  { id: 'leadership', title: 'AI Leadership', titleKey: 'dashboard.tabs.leadership' },
  { id: 'usage', title: 'Usage', titleKey: 'dashboard.tabs.usage' },
  { id: 'projects', title: 'Projects', titleKey: 'dashboard.tabs.projects' },
  { id: 'skills', title: 'Skills', titleKey: 'dashboard.tabs.skills' },
];

const formatUSD = (value: unknown): string => {
  if (typeof value !== 'number' || !Number.isFinite(value)) return '--';
  return value.toFixed(2);
};

export function DashboardHome({ snapshot, quotaSourceLabel, leadershipSignal, onQuotaRefresh }: DashboardHomeProps) {
  const { t, language } = useI18n();
  const usage = snapshot?.local ?? null;
  const signal = leadershipSignal ?? null;
  const detailed = usage?.detailed_usage ?? null;
  const hasUsage = usage !== null;

  const [activeDashboardTab, setActiveDashboardTab] = useState<DashboardContentTab>('tasks');
  const tabRefs = useRef<Record<DashboardContentTab, HTMLButtonElement | null>>({
    tasks: null,
    leadership: null,
    usage: null,
    projects: null,
    skills: null,
  });

  const focusTabButton = (tabId: DashboardContentTab) => {
    tabRefs.current[tabId]?.focus();
  };

  const handleLowerTabKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') {
      return;
    }

    const currentIndex = DASHBOARD_TABS.findIndex((item) => item.id === activeDashboardTab);
    if (currentIndex < 0) return;

    event.preventDefault();
    event.stopPropagation();

    const nextIndex =
      event.key === 'ArrowRight'
        ? (currentIndex + 1) % DASHBOARD_TABS.length
        : (currentIndex - 1 + DASHBOARD_TABS.length) % DASHBOARD_TABS.length;
    const nextTab = DASHBOARD_TABS[nextIndex].id;
    setActiveDashboardTab(nextTab);

    requestAnimationFrame(() => {
      focusTabButton(nextTab);
    });
  };

  return (
    <div className="space-y-4 dashboard-home">
      <HomeSection id="overview" title={language === 'zh-Hans' ? '用量与额度概览' : 'Usage and quota overview'}>
      <div className="dashboard-home-overview">
        <LeadershipOverviewCard
          signal={signal}
          hasUsage={hasUsage}
          onOpen={() => setActiveDashboardTab('leadership')}
        />

        <QuotaOverview snapshot={snapshot} sourceLabel={quotaSourceLabel} onRefresh={onQuotaRefresh} />

        <section className="dashboard-home-metrics" aria-label={t('dashboard.aria.localTokenMetrics')}>
          <StatCard
            label={t('dashboard.metrics.today')}
            value={formatNumber(hasUsage ? usage?.today_tokens ?? null : null)}
            subValue={
              detailed
                ? t('dashboard.metrics.estimated', { value: formatUSD(detailed.today.estimated_cost_usd) })
                : t('dashboard.metrics.recordInsufficient')
            }
            icon={<Activity size={16} />}
            compact
            accent="primary"
          />
          <StatCard
            label={t('dashboard.metrics.sevenDay')}
            value={formatNumber(hasUsage ? usage?.seven_day_tokens ?? null : null)}
            subValue={
              detailed
                ? t('dashboard.metrics.estimated', { value: formatUSD(detailed.seven_day.estimated_cost_usd) })
                : t('dashboard.metrics.recordInsufficient')
            }
            icon={<Calendar size={16} />}
            compact
            accent="secondary"
          />
          <StatCard
            label={t('dashboard.metrics.lifetime')}
            value={formatNumber(hasUsage ? usage?.lifetime_tokens ?? null : null)}
            subValue={
              detailed
                ? t('dashboard.metrics.estimated', { value: formatUSD(detailed.lifetime.estimated_cost_usd) })
                : t('dashboard.metrics.recordInsufficient')
            }
            icon={<TrendingUp size={16} />}
            compact
            accent="tertiary"
          />
        </section>

        <div className="dashboard-home-monthly">
          <MonthlyValueProgress usage={usage} />
        </div>
      </div>

      </HomeSection>
      <div
        onKeyDown={handleLowerTabKeyDown}
        role="tablist"
        aria-label={t('dashboard.aria.lowerTabs')}
        className="flex items-center gap-1.5 flex-wrap rounded-2xl p-1 glass-toolbar"
      >
        {DASHBOARD_TABS.map((tab) => (
          <button
            key={tab.id}
            id={`dashboard-home-tab-${tab.id}`}
            role="tab"
            aria-selected={activeDashboardTab === tab.id}
            aria-controls={`dashboard-home-panel-${tab.id}`}
            tabIndex={activeDashboardTab === tab.id ? 0 : -1}
            ref={(element) => {
              tabRefs.current[tab.id] = element;
            }}
            onClick={() => setActiveDashboardTab(tab.id)}
            className={`px-3 py-2 rounded-xl text-sm transition-all min-w-[90px] ${
              activeDashboardTab === tab.id ? 'glass-button-solid' : 'text-secondary glass-button'
            }`}
          >
            {t(tab.titleKey)}
          </button>
        ))}
      </div>

      {activeDashboardTab === 'tasks' && (
        <section
          role="tabpanel"
          id="dashboard-home-panel-tasks"
          aria-labelledby="dashboard-home-tab-tasks"
        >
          <HomeSection id="tasks" title={t('dashboard.tabs.tasks')}><TaskBoardPanel taskBoard={snapshot?.task_board ?? null} /></HomeSection>
        </section>
      )}

      {activeDashboardTab === 'leadership' && (
        <section
          role="tabpanel"
          id="dashboard-home-panel-leadership"
          aria-labelledby="dashboard-home-tab-leadership"
        >
          <HomeSection id="leadership" title={t('dashboard.tabs.leadership')}><LeadershipPanel signal={signal} /></HomeSection>
        </section>
      )}

      {activeDashboardTab === 'usage' && (
        <section
          role="tabpanel"
          id="dashboard-home-panel-usage"
          aria-labelledby="dashboard-home-tab-usage"
        >
          <HomeSection id="usage" title={t('dashboard.tabs.usage')}><UsagePanel usage={usage} /></HomeSection>
        </section>
      )}

      {activeDashboardTab === 'projects' && (
        <section
          role="tabpanel"
          id="dashboard-home-panel-projects"
          aria-labelledby="dashboard-home-tab-projects"
        >
          <HomeSection id="projects" title={t('dashboard.tabs.projects')}><ProjectsPanel
            projectBoard={usage?.project_board ?? null}
            tools={usage?.tool_usages ?? []}
          /></HomeSection>
        </section>
      )}

      {activeDashboardTab === 'skills' && (
        <section
          role="tabpanel"
          id="dashboard-home-panel-skills"
          aria-labelledby="dashboard-home-tab-skills"
        >
          <HomeSection id="skills" title={t('dashboard.tabs.skills')}><SkillsPanel skills={usage?.skill_usages ?? []} /></HomeSection>
        </section>
      )}
    </div>
  );
}

function formatNumber(value: number | null | undefined): string {
  if (value == null || !Number.isFinite(value)) return '--';
  return Math.round(value).toLocaleString();
}
