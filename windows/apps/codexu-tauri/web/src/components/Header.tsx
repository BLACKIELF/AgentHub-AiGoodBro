import { RefreshCw, Settings, Sun, Moon, Monitor } from 'lucide-react';
import { invoke } from '@tauri-apps/api/core';
import { isTauriRuntimeAvailable } from '../utils/tauri';
import type { ThemeMode } from '../types/settings';
import { useI18n } from '../i18n/I18nProvider';
import { PALETTE_CATALOG, type PaletteId } from '../utils/paletteCatalog';
import { useState } from 'react';

interface HeaderProps {
  lastUpdated: number | null;
  theme: ThemeMode;
  onThemeChange: (theme: ThemeMode) => void;
  paletteId: PaletteId;
  onPaletteChange: (palette: PaletteId) => void;
  onRefresh: () => void;
  refreshing: boolean;
}

export function Header({
  lastUpdated,
  theme,
  onThemeChange,
  paletteId,
  onPaletteChange,
  onRefresh,
  refreshing,
}: HeaderProps) {
  const { t, language } = useI18n();
  const text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const [activeNavigation, setActiveNavigation] = useState<'home' | 'accounts' | 'usage'>('home');
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
    <header className="mx-4 mt-4 glass-toolbar px-4 py-2.5 rounded-xl flex flex-wrap items-center justify-between gap-3">
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
              {t('header.updated', { time: new Date(lastUpdated).toLocaleTimeString() })}
            </p>
          )}
        </div>
      </div>

      <nav className="home-navigation" aria-label={text('首页导航', 'Home navigation')}>
        <a href="#windows-home" className={activeNavigation === 'home' ? 'is-active' : ''} aria-current={activeNavigation === 'home' ? 'page' : undefined} onClick={() => setActiveNavigation('home')}>{text('概览', 'Overview')}</a>
        <a href="#windows-accounts" className={activeNavigation === 'accounts' ? 'is-active' : ''} aria-current={activeNavigation === 'accounts' ? 'page' : undefined} onClick={() => setActiveNavigation('accounts')}>Codex</a>
        <a href="#windows-usage" className={activeNavigation === 'usage' ? 'is-active' : ''} aria-current={activeNavigation === 'usage' ? 'page' : undefined} onClick={() => setActiveNavigation('usage')}>{text('使用额度', 'Usage')}</a>
      </nav>

      <div className="flex items-center gap-2">
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
