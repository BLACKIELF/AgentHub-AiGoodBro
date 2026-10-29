import { useCallback, useEffect, useRef, useState } from 'react';
import { listen } from '@tauri-apps/api/event';
import { Activity, CircleDashed } from 'lucide-react';
import { Header } from '../components/Header';
import { DashboardHome } from '../components/DashboardHome';
import { ProfilesPanel } from '../components/ProfilesPanel';
import { HomeSection } from '../components/HomeSection';
import { PublicResetPanel, PublisherMessagePanel } from '../components/PublicResetPanel';
import { RecommendedSkills } from '../components/RecommendedSkills';
import { LocalProxyPanel } from '../components/LocalProxyPanel';
import { ManagedAccountsPanel } from '../components/ManagedAccountsPanel';
import { ClaudeSubscriptionsPanel } from '../components/ClaudeSubscriptionsPanel';
import { useSettings } from '../hooks/useSettings';
import { useUsage } from '../hooks/useUsage';
import { useTokenMonitor } from '../hooks/useTokenMonitor';
import { TokenMonitorPanel } from '../components/TokenMonitorPanel';
import { applyAppTheme } from '../utils/appTheme';
import { DEFAULT_PALETTE_ID, type PaletteId } from '../utils/paletteCatalog';
import { useI18n } from '../i18n/I18nProvider';
import { parseWorkspaceNavigation, readChoice, saveChoice, type WorkspaceMode, type WorkspacePage } from '../utils/workspacePreferences';

export function Dashboard() {
  const { t, language } = useI18n();
  const [page, setPage] = useState<WorkspacePage>(() => readChoice('aigoodbro.workspace.page', ['home', 'accounts', 'usage', 'proxy', 'tools'], 'home'));
  const [mode, setMode] = useState<WorkspaceMode>(() => readChoice('aigoodbro.workspace.mode', ['professional', 'simple'], 'professional'));
  const [managedVisited, setManagedVisited] = useState(page === 'accounts');
  const [proxyVisited, setProxyVisited] = useState(page === 'proxy');
  const [toolsVisited, setToolsVisited] = useState(page === 'tools');
  const [requestedToolTab, setRequestedToolTab] = useState<{ tab: 'tasks'; sequence: number }>();
  const main = useRef<HTMLElement>(null);
  const navigate = useCallback((next: WorkspacePage) => { if (next === 'accounts') setManagedVisited(true); if (next === 'proxy') setProxyVisited(true); if (next === 'tools') setToolsVisited(true); setPage(next); saveChoice('aigoodbro.workspace.page', next); main.current?.scrollTo({ top: 0 }); }, []);
  const changeMode = (next: WorkspaceMode) => { setMode(next); saveChoice('aigoodbro.workspace.mode', next); };
  const { dashboard, loading, error, refresh, changeSource } = useUsage();
  const statistics=useTokenMonitor();
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
  const noticeTitle = language === 'zh-Hans' ? '推荐 Skills 与官方公告' : 'Recommended Skills and official notices';
  const notices = <HomeSection id="notices" title={noticeTitle} initialOpen={false}>
    <div className="space-y-3 pt-1"><PublicResetPanel /><PublisherMessagePanel /><HomeSection id="recommendations" title={language === 'zh-Hans' ? '推荐 Skills 与应用' : 'Recommended Skills and apps'}><RecommendedSkills /></HomeSection></div>
  </HomeSection>;
  const usageStatistics = <div id="windows-usage" className="workspace-page" hidden={page !== 'home' && page !== 'usage'}><HomeSection forceOpen={page === 'usage'} id="usage-summary" title={language === 'zh-Hans' ? '用量统计' : 'Usage statistics'} initialOpen={false}>
    <TokenMonitorPanel controller={statistics}/>
  </HomeSection></div>;


  return (
    <div className={`h-full flex flex-col workspace-shell workspace-mode-${mode}`} data-workspace-mode={mode}>
      <Header
        lastUpdated={page==='home'||page==='usage'?(statistics.state?.snapshot?Date.parse(statistics.state.snapshot.collectedAt):null):lastUpdated}
        theme={settings?.config.theme ?? 'dark'}
        onThemeChange={handleThemeChange}
        paletteId={settings?.config.palette_id ?? DEFAULT_PALETTE_ID}
        onPaletteChange={handlePaletteChange}
        onRefresh={()=>{void refresh();if(page==='home'||page==='usage')void statistics.refresh();}}
        refreshing={loading||statistics.busy}
        page={page} mode={mode} onNavigate={navigate} onModeChange={changeMode}
      />

      <main ref={main} id="windows-home" className="workspace-main flex-1 min-h-0 overflow-auto p-4 md:p-5" data-page={page}>
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

        <div className="max-w-7xl mx-auto w-full space-y-4">
          {settingsError && <p role="alert" className="text-xs text-status-warn">{language === 'zh-Hans' ? '外观设置暂不可用，请重试。' : 'Appearance settings are unavailable. Try again.'}</p>}
          {paletteFallbackNotice && <p role="status" className="text-xs text-status-warn">{language === 'zh-Hans' ? '原配色不可用，已使用经典默认配色。' : 'Saved palette is unavailable; the classic default is in use.'}</p>}
          <div className="home-notice-strip workspace-page" hidden={page !== 'home'}>{notices}</div>
          {managedVisited && <div className="workspace-page space-y-4" hidden={page !== 'accounts'}><ManagedAccountsPanel /><ClaudeSubscriptionsPanel /></div>}
          {usageStatistics}
          <div id="windows-accounts" className="workspace-page" hidden={page !== 'home' && page !== 'accounts'}><HomeSection forceOpen={page === 'accounts'} id="accounts" title={language === 'zh-Hans' ? '账号目录' : 'Account directories'}><ProfilesPanel onSourceChange={changeSource} /></HomeSection></div>
          {proxyVisited && <div className="workspace-page" hidden={page !== 'proxy'}><LocalProxyPanel /></div>}
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
  );
}
