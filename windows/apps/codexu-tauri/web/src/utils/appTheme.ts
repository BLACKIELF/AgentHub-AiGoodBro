import type { ThemeMode } from '../types/settings';
import {
  DEFAULT_PALETTE_ID,
  resolvePalette,
  type PaletteId,
  type PaletteTokens,
} from './paletteCatalog';

const FIXED_VISUAL_TOKENS = {
  light: {
    surface: '#fafbfe',
    surfaceElevated: 'rgba(250, 251, 254, 0.88)',
    surfaceElevatedStrong: 'rgba(250, 251, 254, 0.96)',
    surfaceInset: 'rgba(233, 236, 242, 0.68)',
    pageBg: '#e9ecf2',
    textPrimary: '#111827',
    textSecondary: '#4b5563',
    textTertiary: '#6b7280',
    border: 'rgba(148, 163, 184, 0.30)',
    statusOk: '#16a34a',
    statusWarn: '#d97706',
    statusError: '#dc2626',
    shadowSoft: '0 16px 42px -30px rgba(15, 23, 42, 0.33)',
  },
  dark: {
    surface: '#292c34',
    surfaceElevated: 'rgba(53, 56, 65, 0.72)',
    surfaceElevatedStrong: 'rgba(53, 56, 65, 0.9)',
    surfaceInset: 'rgba(18, 20, 26, 0.52)',
    pageBg: '#15171e',
    textPrimary: '#f4f5f8',
    textSecondary: '#c6cad3',
    textTertiary: '#969ba7',
    border: 'rgba(255, 255, 255, 0.10)',
    statusOk: '#30d158',
    statusWarn: '#f59e0b',
    statusError: '#ff453a',
    shadowSoft: '0 16px 42px -30px rgba(2, 6, 23, 0.55)',
  },
} as const;

const clampHexAlpha = (hex: string, alpha: number): string => {
  const normalized = hex.replace('#', '').trim();
  if (!/^[0-9a-fA-F]{6}$/.test(normalized)) {
    return hex;
  }

  const clamped = Math.max(0, Math.min(1, alpha));
  return `#${normalized}${Math.round(clamped * 255)
    .toString(16)
    .padStart(2, '0')
    .toUpperCase()}`;
};

const applySeriesVariables = (root: HTMLElement, palette: PaletteTokens) => {
  palette.data.series.forEach((color, index) => {
    root.style.setProperty(`--data-series-${index + 1}`, color);
  });
  palette.data.modelSeries.forEach((color, index) => {
    root.style.setProperty(`--data-model-${index + 1}`, color);
  });
};

const applyPaletteVariables = (theme: ThemeMode, paletteId: PaletteId) => {
  const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  const isDark = theme === 'dark' || (theme === 'system' && prefersDark);
  const paletteDescriptor = resolvePalette(paletteId);
  const palette = (isDark ? paletteDescriptor.dark : paletteDescriptor.light) as PaletteTokens;
  const root = document.documentElement;

  root.classList.toggle('dark', isDark);
  root.dataset.palette = paletteDescriptor.id;

  root.style.setProperty('--accent', palette.accent.primary);
  root.style.setProperty('--accent-secondary', palette.accent.secondary);
  root.style.setProperty('--accent-strong', palette.accent.primaryStrong);
  root.style.setProperty('--accent-light', palette.accent.primaryLight);

  root.style.setProperty('--quota-primary-start', palette.quota.primary.start);
  root.style.setProperty('--quota-primary-end', palette.quota.primary.end);
  root.style.setProperty('--quota-primary-track', palette.quota.primary.track);
  root.style.setProperty('--quota-primary-label', palette.quota.primary.label);
  root.style.setProperty('--quota-secondary-start', palette.quota.secondary.start);
  root.style.setProperty('--quota-secondary-end', palette.quota.secondary.end);
  root.style.setProperty('--quota-secondary-track', palette.quota.secondary.track);
  root.style.setProperty('--quota-secondary-label', palette.quota.secondary.label);

  root.style.setProperty('--data-primary', palette.data.tokenInput);
  root.style.setProperty('--data-secondary', palette.data.tokenCached);
  root.style.setProperty('--data-tertiary', palette.data.tokenOutput);
  root.style.setProperty('--data-zero', palette.data.zero ?? 'transparent');
  root.style.setProperty(
    '--data-heatmap-strong',
    palette.data.heatmap?.[palette.data.heatmap.length - 1] ?? clampHexAlpha(palette.accent.primary, 0.96),
  );
  applySeriesVariables(root, palette);

  root.style.setProperty('--selection-foreground', palette.selection.foreground);
  root.style.setProperty('--selection-fill', palette.selection.fill);
  root.style.setProperty('--selection-stroke', palette.selection.stroke);
  root.style.setProperty('--selection-focus-ring', palette.selection.focusRing);

  root.style.setProperty('--ornament-ink', palette.ornament.ink);
  root.style.setProperty('--ornament-ink-soft', palette.ornament.inkSoft);
  root.style.setProperty('--ornament-secondary', palette.ornament.secondaryInk);
  root.style.setProperty('--ornament-highlight', palette.ornament.highlight);
  root.style.setProperty('--ornament-metal', palette.ornament.metal);
  root.style.setProperty('--palette-surface-tint', palette.surfaceTint.color);
  root.style.setProperty('--palette-surface-tint-opacity', String(palette.surfaceTint.maximumOpacity));
  root.style.setProperty('--palette-tint-strength', `${Math.min(palette.surfaceTint.maximumOpacity * 100, 8)}%`);

  const paletteVisual = isDark ? FIXED_VISUAL_TOKENS.dark : FIXED_VISUAL_TOKENS.light;
  root.style.setProperty('--surface', paletteVisual.surface);
  root.style.setProperty('--surface-elevated', paletteVisual.surfaceElevated);
  root.style.setProperty('--surface-elevated-strong', paletteVisual.surfaceElevatedStrong);
  root.style.setProperty('--surface-inset', paletteVisual.surfaceInset);
  root.style.setProperty('--text-primary', paletteVisual.textPrimary);
  root.style.setProperty('--text-secondary', paletteVisual.textSecondary);
  root.style.setProperty('--text-tertiary', paletteVisual.textTertiary);
  root.style.setProperty('--border', paletteVisual.border);
  root.style.setProperty('--status-ok', paletteVisual.statusOk);
  root.style.setProperty('--status-warn', paletteVisual.statusWarn);
  root.style.setProperty('--status-error', paletteVisual.statusError);
  root.style.setProperty('--shadow-soft', paletteVisual.shadowSoft);
  root.style.setProperty('--page-bg', paletteVisual.pageBg);
};

export function applyAppTheme(theme: ThemeMode, paletteId: PaletteId = DEFAULT_PALETTE_ID) {
  applyPaletteVariables(theme, paletteId);
}
