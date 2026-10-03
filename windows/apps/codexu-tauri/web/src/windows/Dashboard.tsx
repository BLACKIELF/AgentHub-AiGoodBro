import { useEffect } from 'react';
import { Activity, CircleDashed } from 'lucide-react';
import { Header } from '../components/Header';
import { DashboardHome } from '../components/DashboardHome';
import { ProfilesPanel } from '../components/ProfilesPanel';
import { HomeSection } from '../components/HomeSection';
import { PublicResetPanel, PublisherMessagePanel } from '../components/PublicResetPanel';
import { RecommendedSkills } from '../components/RecommendedSkills';
import { UsagePanel } from '../components/UsagePanel';
import { ToolUsageList } from '../components/ToolUsageList';
import { useSettings } from '../hooks/useSettings';
import { useUsage } from '../hooks/useUsage';
import { applyAppTheme } from '../utils/appTheme';
import { DEFAULT_PALETTE_ID, type PaletteId } from '../utils/paletteCatalog';
import { useI18n } from '../i18n/I18nProvider';

export function Dashboard() {
  const { t, language } = useI18n();
  const { dashboard, loading, error, refresh, changeSource } = useUsage();
  const { settings, update, error: settingsError, paletteFallbackNotice } = useSettings();

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
  const usageStatistics = <div id="windows-usage"><HomeSection id="usage-summary" title={language === 'zh-Hans' ? '用量统计' : 'Usage statistics'} initialOpen={false}>
    <div className="space-y-3"><UsagePanel usage={localUsage} /><ToolUsageList tools={localUsage?.tool_usages ?? []} /></div>
  </HomeSection></div>;

  if (error) {
    return (
      <div className="h-full flex flex-col">
        <Header
          lastUpdated={null}
          theme={settings?.config.theme ?? 'dark'}
          onThemeChange={handleThemeChange}
          paletteId={settings?.config.palette_id ?? DEFAULT_PALETTE_ID}
          onPaletteChange={handlePaletteChange}
          onRefresh={refresh}
          refreshing={loading}
        />
        <div className="flex-1 overflow-auto p-4 space-y-4">
          {settingsError && <p role="alert" className="text-xs text-status-warn">{language === 'zh-Hans' ? '外观设置暂不可用，请重试。' : 'Appearance settings are unavailable. Try again.'}</p>}
          {paletteFallbackNotice && <p role="status" className="text-xs text-status-warn">{language === 'zh-Hans' ? '原配色不可用，已使用经典默认配色。' : 'Saved palette is unavailable; the classic default is in use.'}</p>}
          {notices}
          {usageStatistics}
          <div id="windows-accounts"><HomeSection id="accounts" title={language === 'zh-Hans' ? '已登录账号' : 'Linked accounts'}><ProfilesPanel onSourceChange={changeSource} /></HomeSection></div>
          <div className="glass-panel p-6 max-w-md border-status-error/30 bg-status-error/8">
            <h2 className="text-lg font-semibold text-status-error mb-2">{t('dashboard.errors.failedToLoadUsage')}</h2>
            <p className="text-sm opacity-90 text-status-error/90">{error}</p>
            <button
              onClick={refresh}
              className="mt-4 px-4 py-2 rounded-full glass-button-solid text-sm"
            >
              {t('common.retry')}
            </button>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="h-full flex flex-col">
      <Header
        lastUpdated={lastUpdated}
        theme={settings?.config.theme ?? 'dark'}
        onThemeChange={handleThemeChange}
        paletteId={settings?.config.palette_id ?? DEFAULT_PALETTE_ID}
        onPaletteChange={handlePaletteChange}
        onRefresh={refresh}
        refreshing={loading}
      />

      <main id="windows-home" className="flex-1 min-h-0 overflow-auto p-4 md:p-5">
        {!dashboard && (
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
          <div className="home-notice-strip">{notices}</div>
          {usageStatistics}
          <div id="windows-accounts"><HomeSection id="accounts" title={language === 'zh-Hans' ? '已登录账号' : 'Linked accounts'}><ProfilesPanel onSourceChange={changeSource} /></HomeSection></div>
          <div className="flex items-center justify-between gap-2">
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
                time: lastUpdated ? new Date(lastUpdated).toLocaleTimeString() : t('dashboard.status.waiting'),
              })}
            </span>
          </div>
          {dashboard?.messages?.length ? (
            <p className="text-xs text-tertiary mt-2">
              {t('dashboard.errors.status', { messages: dashboard.messages.join(' · ') })}
            </p>
          ) : null}

          <DashboardHome
            snapshot={dashboard?.codex?.snapshot}
            quotaSourceLabel={dashboard?.codex?.quota_source_label}
            leadershipSignal={dashboard?.leadership ?? null}
            onQuotaRefresh={refresh}
          />
        </div>
      </main>
    </div>
  );
}
