import { HomeResizable } from '../components/HomeResizable';
import {ProviderNavigation} from '../components/ProviderNavigation';
import {invoke} from '@tauri-apps/api/core';
import { InstallationGuide } from '../components/InstallationGuide';
import { canonicalCompactProvider } from '../utils/compactUi';
import type { Platform } from '../utils/localCliQuota';
import { useCallback, useEffect, useRef, useState } from 'react';
import { listen } from '@tauri-apps/api/event';
import { Activity, Camera, CircleDashed, Moon, Monitor, MoreHorizontal, RefreshCw, Settings, Sun } from 'lucide-react';
import { Header, WorkspaceNavigation } from '../components/Header';
import { DashboardHome } from '../components/DashboardHome';
import { ProfilesPanel } from '../components/ProfilesPanel';
import { HomeSection } from '../components/HomeSection';
import { PublicResetPanel, PublisherMessagePanel } from '../components/PublicResetPanel';
import { RecommendedSkills } from '../components/RecommendedSkills';
import { LocalProxyPanel } from '../components/LocalProxyPanel';
import { ProviderAccountPoolPanel } from '../components/ProviderAccountPoolPanel';
import { ManagedAccountsPanel } from '../components/ManagedAccountsPanel';
import { ClaudeSubscriptionsPanel } from '../components/ClaudeSubscriptionsPanel';
import { useSettings } from '../hooks/useSettings';
import { useUsage } from '../hooks/useUsage';
import { useTokenMonitor } from '../hooks/useTokenMonitor';
import { useCustomStatistics } from '../hooks/useCustomStatistics';
import { CustomStatisticsPanel, StatisticsModeChooser } from '../components/CustomStatisticsPanel';
import { TokenMonitorPanel } from '../components/TokenMonitorPanel';
import { applyAppTheme } from '../utils/appTheme';
import { DEFAULT_PALETTE_ID, PALETTE_CATALOG, type PaletteId } from '../utils/paletteCatalog';
import { useI18n } from '../i18n/I18nProvider';
import { parseWorkspaceNavigation, readChoice, saveChoice, type WorkspaceMode, type WorkspacePage } from '../utils/workspacePreferences';
import { isTauriRuntimeAvailable } from '../utils/tauri';

export function Dashboard() {
  const { t, language } = useI18n();
  const text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const [page, setPage] = useState<WorkspacePage>(() => readChoice('aigoodbro.workspace.page', ['home', 'accounts', 'usage', 'proxy', 'tools'], 'home'));
  const [mode, setMode] = useState<WorkspaceMode>(() => readChoice('aigoodbro.workspace.mode', ['professional', 'simple'], 'professional'));
  const [managedVisited, setManagedVisited] = useState(page === 'accounts' || page === 'home');
  const [providers, setProviders] = useState<Platform[]>([]);
  const [provider, setProvider] = useState(() => { try { return localStorage.getItem('AiGoodBro.home.provider') || 'all'; } catch { return 'all'; } });
  const chooseProvider = (id: string) => { setProvider(id); try { localStorage.setItem('AiGoodBro.home.provider', id); } catch {} };
  const [proxyVisited, setProxyVisited] = useState(page === 'proxy');
  const [toolsVisited, setToolsVisited] = useState(page === 'tools');
  const [requestedToolTab, setRequestedToolTab] = useState<{ tab: 'tasks'; sequence: number }>();
  const [screenshotBusy, setScreenshotBusy] = useState(false);
  const [screenshotFeedback, setScreenshotFeedback] = useState<string | null>(null);
  const screenshotInFlight = useRef(false);
  const main = useRef<HTMLElement>(null);
  const navigate = useCallback((next: WorkspacePage) => { if (next === 'accounts' || next === 'home') setManagedVisited(true); if (next === 'proxy') setProxyVisited(true); if (next === 'tools') setToolsVisited(true); setPage(next); saveChoice('aigoodbro.workspace.page', next); main.current?.scrollTo({ top: 0 }); }, []);
  const changeMode = (next: WorkspaceMode) => { setMode(next); saveChoice('aigoodbro.workspace.mode', next); };
  const { dashboard, loading, error, refresh, changeSource } = useUsage();
  const customStatistics=useCustomStatistics();
  const upstreamStatistics=customStatistics.value?.engine==='upstream';
  const statistics=useTokenMonitor(!upstreamStatistics);
  const { settings, update, error: settingsError, paletteFallbackNotice } = useSettings();

  useEffect(() => {
    let disposed = false;
    let stop: (() => void) | undefined;
    void listen('workspace:navigate', event => {
      if (disposed) return;
      const value = parseWorkspaceNavigation(event.payload);
      if (!value) return;
      navigate(value.page);
      if (value.toolTab) setRequestedToolTab(previous => ({ tab: 'tasks', sequence: (previous?.sequence ?? 0) + 1 }));
    }).then(unlisten => { if (disposed) unlisten(); else stop = unlisten; }).catch(() => {});
    return () => { disposed = true; stop?.(); };
  }, [navigate]);

  useEffect(() => {
    applyAppTheme(
      settings?.config.theme ?? 'dark',
      settings?.config.palette_id ?? DEFAULT_PALETTE_ID,
    );
  }, [settings?.config.theme, settings?.config.palette_id]);

  const localUsage = dashboard?.codex?.snapshot?.local ?? null;
  const lastUpdated =
    dashboard?.codex?.snapshot?.refreshed_at ?? dashboard?.refreshed_at ?? localUsage?.last_updated_at ?? null;
  const quotaStatus = dashboard?.codex?.status ?? 'local_only';
  const quotaStatusLabel =
    quotaStatus === 'available'
      ? t('dashboard.status.officialQuotaActive')
      : quotaStatus === 'stale'
        ? t('dashboard.status.officialQuotaLastVerified')
        : t('dashboard.status.checkingOfficialQuota');
  const quotaStatusClass =
    quotaStatus === 'available'
      ? 'bg-status-ok/12 text-status-ok border-status-ok/30'
      : 'bg-status-warn/12 text-status-warn border-status-warn/30';

  const handleThemeChange = async (theme: 'system' | 'light' | 'dark') => {
    try {
      await update({ theme });
      applyAppTheme(theme, settings?.config.palette_id ?? DEFAULT_PALETTE_ID);
    } catch { applyAppTheme(settings?.config.theme ?? 'dark', settings?.config.palette_id ?? DEFAULT_PALETTE_ID); }
  };
  const handlePaletteChange = async (palette: PaletteId) => {
    try {
      await update({ palette_id: palette });
      applyAppTheme(settings?.config.theme ?? 'dark', palette);
    } catch { applyAppTheme(settings?.config.theme ?? 'dark', settings?.config.palette_id ?? DEFAULT_PALETTE_ID); }
  };
  const handleOpenSettings = async () => {
    if (!isTauriRuntimeAvailable()) return;
    try { await invoke('open_settings_window'); }
    catch (error) { console.error('Failed to open settings window:', error); }
  };
  const handleRefresh = () => {
    void refresh();
    if (page === 'home' || page === 'usage') {
      if (upstreamStatistics) void statistics.refresh();
      else customStatistics.read();
    }
  };
  const handleSaveScreenshot = async () => {
    if (screenshotInFlight.current) return;
    screenshotInFlight.current = true;
    setScreenshotBusy(true);
    setScreenshotFeedback(null);
    try {
      const result = await invoke<{ status: 'saved' | 'cancelled' }>('save_workspace_screenshot');
      if (result?.status === 'saved') {
        setScreenshotFeedback(language === 'zh-Hans' ? '主界面长截图已保存。' : 'Workspace screenshot saved.');
      } else if (result?.status !== 'cancelled') {
        throw new Error('Unexpected screenshot result');
      }
    } catch {
      setScreenshotFeedback(language === 'zh-Hans' ? '未能保存截图，请重试。' : 'Could not save the screenshot. Try again.');
    } finally {
      screenshotInFlight.current = false;
      setScreenshotBusy(false);
    }
  };
  const noticeTitle = language === 'zh-Hans' ? '推荐 Skills 与官方公告' : 'Recommended Skills and official notices';
  const notices = <HomeSection id="notices" title={noticeTitle} initialOpen={false}>
    <div className="space-y-3 pt-1"><PublicResetPanel /><PublisherMessagePanel /><HomeSection id="recommendations" title={language === 'zh-Hans' ? '推荐 Skills 与应用' : 'Recommended Skills and apps'}><RecommendedSkills /></HomeSection></div>
  </HomeSection>;
  const usageStatistics = <div id="windows-usage" className="workspace-page" hidden={page !== 'home' && page !== 'usage'}><HomeSection forceOpen={page === 'usage'} id="usage-summary" title={language === 'zh-Hans' ? '用量统计' : 'Usage statistics'} initialOpen={false}>
    <HomeResizable id="statistics" title={language === 'zh-Hans' ? '用量统计' : 'usage statistics'}><StatisticsModeChooser controller={customStatistics}/>{upstreamStatistics?<TokenMonitorPanel controller={statistics}/>:customStatistics.value?.engine==='custom'?<CustomStatisticsPanel controller={customStatistics}/>:null}</HomeResizable>
  </HomeSection></div>;


  return (
    <div className={`h-full workspace-shell workspace-mode-${mode}`} data-layout="mac" data-workspace-mode={mode}>
      <aside className="workspace-sidebar" aria-label={text('工作区侧栏', 'Workspace sidebar')}>
        <WorkspaceNavigation page={page} onNavigate={next => { if (next === 'home') chooseProvider('all'); navigate(next); }}>
          <ProviderNavigation providers={['codex','claude',...providers.map(value=>canonicalCompactProvider(value.id))]} selected={page === 'accounts' ? provider : 'all'} onSelect={id => { chooseProvider(id); navigate('accounts'); }}/>
        </WorkspaceNavigation>
        <div className="workspace-sidebar-footer">
          <details className="workspace-sidebar-more">
            <summary className="workspace-sidebar-action workspace-sidebar-more-trigger" aria-label={text('更多选项', 'More options')} title={text('更多选项', 'More options')}>
              <MoreHorizontal size={20} aria-hidden="true"/><span className="sr-only">{text('更多选项', 'More options')}</span>
            </summary>
            <div className="workspace-sidebar-more-menu" role="group" aria-label={text('显示与刷新', 'Display and refresh')}>
              <div className="workspace-mode-picker" role="group" aria-label={text('工作台显示', 'Workspace display')}>
                <button type="button" aria-pressed={mode === 'professional'} onClick={() => changeMode('professional')}>{text('专业', 'Professional')}</button>
                <button type="button" aria-pressed={mode === 'simple'} onClick={() => changeMode('simple')}>{text('极简', 'Simple')}</button>
              </div>
              <label className="sr-only" htmlFor="home-palette">{text('主题配色', 'Theme palette')}</label>
              <select id="home-palette" className="theme-palette-picker" value={settings?.config.palette_id ?? DEFAULT_PALETTE_ID} onChange={event => void handlePaletteChange(event.target.value as PaletteId)}>
                {PALETTE_CATALOG.map(palette => <option key={palette.id} value={palette.id}>{palette.displayName[language]}</option>)}
              </select>
              <div className="workspace-theme-controls" role="group" aria-label={text('主题', 'Theme')}>
                <button type="button" aria-label={t('common.light')} title={t('common.light')} onClick={() => void handleThemeChange('light')} className={(settings?.config.theme ?? 'dark') === 'light' ? 'glass-button-solid' : 'glass-button'}><Sun size={16} aria-hidden="true"/></button>
                <button type="button" aria-label={t('common.dark')} title={t('common.dark')} onClick={() => void handleThemeChange('dark')} className={(settings?.config.theme ?? 'dark') === 'dark' ? 'glass-button-solid' : 'glass-button'}><Moon size={16} aria-hidden="true"/></button>
                <button type="button" aria-label={t('common.system')} title={t('common.system')} onClick={() => void handleThemeChange('system')} className={(settings?.config.theme ?? 'dark') === 'system' ? 'glass-button-solid' : 'glass-button'}><Monitor size={16} aria-hidden="true"/></button>
              </div>
              <button type="button" className="workspace-sidebar-menu-control" aria-label={t('common.refresh')} title={t('common.refresh')} disabled={loading || (upstreamStatistics ? statistics.busy : customStatistics.busy)} onClick={handleRefresh}>
                <RefreshCw size={16} className={loading || (upstreamStatistics ? statistics.busy : customStatistics.busy) ? 'animate-spin' : ''} aria-hidden="true"/><span>{t('common.refresh')}</span>
              </button>
            </div>
          </details>
          <button type="button" id="workspace-screenshot" data-testid="workspace-screenshot" className="workspace-sidebar-action" onClick={handleSaveScreenshot} disabled={screenshotBusy} title={text('保存主界面长截图（PNG）', 'Save full workspace screenshot (PNG)')} aria-label={text('保存主界面长截图（PNG）', 'Save full workspace screenshot (PNG)')}>
            <Camera size={20} className={screenshotBusy ? 'animate-pulse' : ''} aria-hidden="true"/><span className="sr-only">{text('保存主界面长截图（PNG）', 'Save full workspace screenshot (PNG)')}</span>
          </button>
          <InstallationGuide onAccounts={() => navigate('accounts')} onOpenSection={async section=>{if(section==='settings')await invoke('open_settings_window');else navigate(section);}} />
          <button type="button" className="workspace-sidebar-action" onClick={() => void handleOpenSettings()} title={t('common.settings')} aria-label={t('common.settings')}>
            <Settings size={20} aria-hidden="true"/><span className="sr-only">{t('common.settings')}</span>
          </button>
        </div>
      </aside>

      <div className="workspace-canvas">
        <Header page={page}/>
        {screenshotFeedback && <div className="workspace-header-feedback"><span id="workspace-screenshot-status" role="status" aria-live="polite">{screenshotFeedback}</span></div>}
        <main ref={main} id="windows-home" className="workspace-main" data-page={page}>
          <div className="workspace-content">
          {error && page==='tools' && <div role="alert" className="workspace-error"><span>{t('dashboard.errors.failedToLoadUsage')} · {error}</span><button type="button" className="glass-button px-3 py-1" onClick={refresh}>{t('common.retry')}</button></div>}
          {!dashboard && page==='tools' && (
            <div className="glass-panel p-6 mb-6" role="status" aria-live="polite">
              {loading ? (
                <>
                  <h2 className="text-sm font-semibold text-primary">{t('dashboard.errors.loadingUsageData')}</h2>
                  <p className="text-sm text-secondary mt-1">{t('dashboard.errors.collectingLocalSnapshots')}</p>
                </>
              ) : (
                <>
                  <h2 className="text-sm font-semibold text-primary">{t('dashboard.errors.noUsageSnapshot')}</h2>
                  <p className="text-sm text-secondary mt-1">
                    {t('dashboard.errors.noLocalUsage')}
                  </p>
                  <button
                    onClick={refresh}
                    className="mt-4 px-4 py-2 rounded-full glass-button-solid text-sm"
                  >
                    {t('common.refreshNow')}
                  </button>
                </>
              )}
            </div>
          )}

          {settingsError && <p role="alert" className="text-xs text-status-warn">{language === 'zh-Hans' ? '外观设置暂不可用，请重试。' : 'Appearance settings are unavailable. Try again.'}</p>}
          {paletteFallbackNotice && <p role="status" className="text-xs text-status-warn">{language === 'zh-Hans' ? '原配色不可用，已使用经典默认配色。' : 'Saved palette is unavailable; the classic default is in use.'}</p>}
          <div className="home-notice-strip workspace-page" hidden={page !== 'home'}>{notices}</div>

          {usageStatistics}
          <div id="windows-accounts" className="workspace-page" hidden={page !== 'home' && page !== 'accounts'}>
            <HomeResizable id="accounts" title={language === 'zh-Hans' ? '账号' : 'accounts'}>
              {managedVisited && <div className="workspace-account-management" hidden={page !== 'accounts'}>
                <div className="workspace-account-management__managed" hidden={provider !== 'all' && provider !== 'codex'}><ManagedAccountsPanel /></div>
                <div className="workspace-account-management__claude" hidden={provider !== 'all' && provider !== 'claude'}><ClaudeSubscriptionsPanel /></div>
              </div>}
              <ProfilesPanel sectionId="accounts" sectionForceOpen={page === 'accounts'} onSourceChange={changeSource} providerFilter={provider} onProviderChange={chooseProvider} onPlatformsChange={setProviders}/>
            </HomeResizable>
          </div>
          {proxyVisited && <div className="workspace-page" hidden={page !== 'proxy'}><LocalProxyPanel /><ProviderAccountPoolPanel active={page === 'proxy'} /></div>}
          <div className="workspace-page flex items-center justify-between gap-2" hidden={page !== 'tools'}>
            <div className="flex items-center gap-2">
              <span className={`inline-flex items-center gap-1.5 chip-like ${quotaStatusClass}`}>
                <Activity size={12} /> {quotaStatusLabel}
              </span>
              <span className="text-xs text-tertiary">{t('dashboard.status.threads', { count: localUsage?.thread_count ?? 0 })}</span>
              {!localUsage ? (
                <span className="text-xs text-tertiary">
                  {dashboard ? t('dashboard.status.noLocalUsageDetails') : t('dashboard.status.waitingSnapshot')}
                </span>
              ) : null}
            </div>
            <span className="inline-flex items-center gap-1.5 chip-like text-xs text-secondary">
              <CircleDashed size={12} />
              {t('dashboard.status.lastUpdate', {
                time: lastUpdated ? new Date(lastUpdated).toLocaleTimeString(language === 'zh-Hans' ? 'zh-CN' : 'en-GB', { hour: '2-digit', minute: '2-digit', hour12: false }) : t('dashboard.status.waiting'),
              })}
            </span>
          </div>
          {page === 'tools' && dashboard?.messages?.length ? (
            <p className="text-xs text-tertiary mt-2">
              {t('dashboard.errors.status', { messages: dashboard.messages.join(' · ') })}
            </p>
          ) : null}

          {toolsVisited && <div className="workspace-page" hidden={page !== 'tools'}><DashboardHome
            showOverview={true}
            showLocalStatistics={false}
            showTools={true}
            snapshot={dashboard?.codex?.snapshot}
            quotaSourceLabel={dashboard?.codex?.quota_source_label}
            leadershipSignal={dashboard?.leadership ?? null}
            onQuotaRefresh={refresh}
            requestedToolTab={requestedToolTab}
          /></div>}
          </div>
        </main>
      </div>
    </div>
  );
}
