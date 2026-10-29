import { RefreshCw, Settings, Sun, Moon, Monitor, House, Users, ChartNoAxesCombined, PanelsTopLeft, Network } from 'lucide-react';
import { invoke } from '@tauri-apps/api/core';
import { isTauriRuntimeAvailable } from '../utils/tauri';
import type { ThemeMode } from '../types/settings';
import { useI18n } from '../i18n/I18nProvider';
import { PALETTE_CATALOG, type PaletteId } from '../utils/paletteCatalog';
import type { WorkspaceMode, WorkspacePage } from '../utils/workspacePreferences';

interface HeaderProps {
  lastUpdated: number | null;
  theme: ThemeMode;
  onThemeChange: (theme: ThemeMode) => void;
  paletteId: PaletteId;
  onPaletteChange: (palette: PaletteId) => void;
  onRefresh: () => void;
  refreshing: boolean;
  page: WorkspacePage;
  mode: WorkspaceMode;
  onNavigate: (page: WorkspacePage) => void;
  onModeChange: (mode: WorkspaceMode) => void;
}

export function Header({
  lastUpdated,
  theme,
  onThemeChange,
  paletteId,
  onPaletteChange,
  onRefresh,
  refreshing,
  page,
  mode,
  onNavigate,
  onModeChange,
}: HeaderProps) {
  const { t, language } = useI18n();
  const text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const openSettings = async () => {
    if (!isTauriRuntimeAvailable()) {
      return;
    }

    try {
      await invoke('open_settings_window');
    } catch (error) {
      console.error('Failed to open settings window:', error);
    }
  };

  return (
    <header className="workspace-header glass-toolbar flex flex-wrap items-center justify-between gap-3">
      <div className="flex items-center gap-3">
        <div className="w-8 h-8 rounded-lg glass-button flex items-center justify-center overflow-hidden">
          <img
            src="/icons/icon.png"
            alt={t('header.codexIcon')}
            className="w-full h-full object-contain"
          />
        </div>
        <div>
          <h1 className="text-base font-semibold text-primary leading-tight">AiGoodBro</h1>
          {lastUpdated && (
            <p className="text-xs text-tertiary">
              {t('header.updated', { time: new Date(lastUpdated).toLocaleTimeString(language === 'zh-Hans' ? 'zh-CN' : 'en-GB', { hour: '2-digit', minute: '2-digit', hour12: false }) })}
            </p>
          )}
        </div>
      </div>

      <nav className="home-navigation" aria-label={text('首页导航', 'Home navigation')}>
        {[
          { id: 'home' as const, label: text('首页', 'Home'), icon: House },
          { id: 'accounts' as const, label: text('平台账号', 'Accounts'), icon: Users },
          { id: 'usage' as const, label: text('统计', 'Statistics'), icon: ChartNoAxesCombined },
          { id: 'proxy' as const, label: text('反代', 'Proxy'), icon: Network },
          { id: 'tools' as const, label: text('工作台', 'Workspace'), icon: PanelsTopLeft },
        ].map(item => <button key={item.id} id={`workspace-nav-${item.id}`} type="button" className={page === item.id ? 'is-active' : ''}
          aria-current={page === item.id ? 'page' : undefined} onClick={() => onNavigate(item.id)}>
          <item.icon size={14} aria-hidden="true" />{item.label}
        </button>)}
      </nav>

      <div className="workspace-header-actions flex items-center gap-2">
        <div className="workspace-mode-picker" role="group" aria-label={text('工作台显示', 'Workspace display')}>
          <button type="button" aria-pressed={mode === 'professional'} onClick={() => onModeChange('professional')}>{text('专业', 'Professional')}</button>
          <button type="button" aria-pressed={mode === 'simple'} onClick={() => onModeChange('simple')}>{text('极简', 'Simple')}</button>
        </div>
        <label className="sr-only" htmlFor="home-palette">{text('主题配色', 'Theme palette')}</label>
        <select id="home-palette" className="theme-palette-picker" value={paletteId} onChange={event => onPaletteChange(event.target.value as PaletteId)}>
          {PALETTE_CATALOG.map(palette => <option key={palette.id} value={palette.id}>{palette.displayName[language]}</option>)}
        </select>
        <div className="flex items-center glass-toolbar rounded-full p-0.5">
          <button
            onClick={() => onThemeChange('light')}
            className={`p-1.5 rounded-full transition-all ${
              theme === 'light'
                ? 'glass-button-solid'
                : 'text-secondary glass-button'
            }`}
            title={t('common.light')}
          >
            <Sun size={14} />
          </button>
          <button
            onClick={() => onThemeChange('dark')}
            className={`p-1.5 rounded-full transition-all ${
              theme === 'dark' ? 'glass-button-solid' : 'text-secondary glass-button'
            }`}
            title={t('common.dark')}
          >
            <Moon size={14} />
          </button>
          <button
            onClick={() => onThemeChange('system')}
            className={`p-1.5 rounded-full transition-all ${
              theme === 'system'
                ? 'glass-button-solid'
                : 'text-secondary glass-button'
            }`}
            title={t('common.system')}
          >
            <Monitor size={14} />
          </button>
        </div>

        <button
          onClick={onRefresh}
          disabled={refreshing}
          className="p-2 rounded-full glass-button text-secondary hover:text-primary transition-colors disabled:opacity-50"
          title={t('common.refresh')}
        >
          <RefreshCw size={16} className={refreshing ? 'animate-spin' : ''} />
        </button>

        <button
          onClick={openSettings}
          className="p-2 rounded-full glass-button-solid"
          title={t('common.settings')}
        >
          <Settings size={16} />
        </button>
      </div>
    </header>
  );
}
