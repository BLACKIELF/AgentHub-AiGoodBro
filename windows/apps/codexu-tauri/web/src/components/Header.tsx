import type { ReactNode } from 'react';
import { ChevronRight, House, Users, ChartNoAxesCombined, PanelsTopLeft, Network } from 'lucide-react';
import { useI18n } from '../i18n/I18nProvider';
import type { WorkspacePage } from '../utils/workspacePreferences';

interface HeaderProps {
  page: WorkspacePage;
}

const PAGE_LABELS: Record<WorkspacePage, [string, string]> = {
  home: ['主页', 'Home'],
  accounts: ['账号目录', 'Accounts'],
  usage: ['用量统计', 'Statistics'],
  proxy: ['反代', 'Proxy'],
  tools: ['工作台', 'Workspace'],
};

export function WorkspaceNavigation({ page, onNavigate, children }: { page: WorkspacePage; onNavigate: (page: WorkspacePage) => void; children?: ReactNode }) {
  const { language } = useI18n();
  const text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const routes = {
    home: { id: 'home' as const, label: text('首页', 'Home'), icon: House },
    accounts: { id: 'accounts' as const, label: text('平台账号', 'Accounts'), icon: Users },
    usage: { id: 'usage' as const, label: text('统计', 'Statistics'), icon: ChartNoAxesCombined },
    proxy: { id: 'proxy' as const, label: text('反代', 'Proxy'), icon: Network },
    tools: { id: 'tools' as const, label: text('工作台', 'Workspace'), icon: PanelsTopLeft },
  };
  const routeButton = (item: (typeof routes)[keyof typeof routes]) => <button key={item.id} id={`workspace-nav-${item.id}`} type="button" className={`workspace-sidebar-link workspace-sidebar-link-${item.id}${page === item.id ? ' is-active' : ''}`}
    aria-label={item.label} title={item.label} aria-current={page === item.id ? 'page' : undefined} onClick={() => onNavigate(item.id)}>
    <item.icon size={20} aria-hidden="true" /><span className="sr-only">{item.label}</span>
  </button>;

  return <nav className="workspace-sidebar-routes home-navigation" aria-label={text('首页导航', 'Home navigation')}>
    <div className="workspace-sidebar-home-route">{routeButton(routes.home)}</div>
    {children}
    <div className="workspace-sidebar-secondary-routes">{routeButton(routes.accounts)}{routeButton(routes.usage)}{routeButton(routes.tools)}</div>
    <div className="workspace-sidebar-proxy-route">{routeButton(routes.proxy)}</div>
  </nav>;
}

export function Header({ page }: HeaderProps) {
  const { language } = useI18n();
  const [zh, en] = PAGE_LABELS[page];
  const pageLabel = language === 'zh-Hans' ? zh : en;
  return <header className="workspace-header">
    <div className="workspace-header-brand">
      <img src="/icons/icon.png" alt="" className="workspace-header-icon" />
      <h1>AiGoodBro</h1>
      <ChevronRight size={18} aria-hidden="true" />
      <span className="workspace-breadcrumb" aria-current="page">{pageLabel}</span>
    </div>
  </header>;
}
