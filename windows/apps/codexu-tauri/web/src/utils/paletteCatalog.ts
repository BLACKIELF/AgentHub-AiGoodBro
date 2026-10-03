import defaultDark from '../../../../../../Resources/Palettes/codexu.default/tokens/dark.json';
import defaultLight from '../../../../../../Resources/Palettes/codexu.default/tokens/light.json';
import liquidKeycapDark from '../../../../../../Resources/Palettes/codexu.liquid-keycap/tokens/dark.json';
import liquidKeycapLight from '../../../../../../Resources/Palettes/codexu.liquid-keycap/tokens/light.json';
import porcelainDark from '../../../../../../Resources/Palettes/codexu.blue-white-porcelain/tokens/dark.json';
import porcelainLight from '../../../../../../Resources/Palettes/codexu.blue-white-porcelain/tokens/light.json';
import dunhuangDark from '../../../../../../Resources/Palettes/codexu.dunhuang-apsara/tokens/dark.json';
import dunhuangLight from '../../../../../../Resources/Palettes/codexu.dunhuang-apsara/tokens/light.json';
import forbiddenCityDark from '../../../../../../Resources/Palettes/codexu.forbidden-city-red/tokens/dark.json';
import forbiddenCityLight from '../../../../../../Resources/Palettes/codexu.forbidden-city-red/tokens/light.json';
import orchidDark from '../../../../../../Resources/Palettes/codexu.orchid-dawn/tokens/dark.json';
import orchidLight from '../../../../../../Resources/Palettes/codexu.orchid-dawn/tokens/light.json';
import landscapeDark from '../../../../../../Resources/Palettes/codexu.thousand-li-landscape/tokens/dark.json';
import landscapeLight from '../../../../../../Resources/Palettes/codexu.thousand-li-landscape/tokens/light.json';

export type PaletteTokens = {
  accent: {
    primary: string;
    primaryStrong: string;
    primaryLight: string;
    secondary: string;
    secondaryStrong: string;
    highlight: string;
  };
  quota: {
    primary: { start: string; end: string; track: string; label: string };
    secondary: { start: string; end: string; track: string; label: string };
  };
  data: {
    tokenInput: string;
    tokenCached: string;
    tokenOutput: string;
    zero?: string;
    series: string[];
    modelSeries: string[];
    heatmap: string[];
    valueProgress: string[];
    milestones: string[];
    tokenInputLabel?: string;
  };
  selection: {
    foreground: string;
    fill: string;
    stroke: string;
    focusRing: string;
  };
  ornament: {
    ink: string;
    inkSoft: string;
    secondaryInk: string;
    highlight: string;
    metal: string;
  };
  surfaceTint: {
    color: string;
    maximumOpacity: number;
  };
};

export type PaletteId =
  | 'codexu.liquid-keycap'
  | 'codexu.default'
  | 'codexu.blue-white-porcelain'
  | 'codexu.dunhuang-apsara'
  | 'codexu.forbidden-city-red'
  | 'codexu.orchid-dawn'
  | 'codexu.thousand-li-landscape';

export type PaletteLocale = 'zh-Hans' | 'en';

export interface PaletteDescriptor {
  id: PaletteId;
  displayName: Record<PaletteLocale, string>;
  shortDescription: Record<PaletteLocale, string>;
  light: PaletteTokens;
  dark: PaletteTokens;
}

export const DEFAULT_PALETTE_ID: PaletteId = 'codexu.liquid-keycap';

export const PALETTE_CATALOG: readonly PaletteDescriptor[] = [
  {
    id: 'codexu.liquid-keycap',
    displayName: { 'zh-Hans': '液态键帽', en: 'Liquid Keycap' },
    shortDescription: {
      'zh-Hans': '克制的蓝色玻璃与暖金刻度',
      en: 'Blue glass with restrained warm-gold accents',
    },
    light: liquidKeycapLight as PaletteTokens,
    dark: liquidKeycapDark as PaletteTokens,
  },
  {
    id: 'codexu.default',
    displayName: { 'zh-Hans': '默认', en: 'Default' },
    shortDescription: {
      'zh-Hans': 'Next 经典蓝紫配色',
      en: 'The classic Next blue and violet palette',
    },
    light: defaultLight as PaletteTokens,
    dark: defaultDark as PaletteTokens,
  },
  {
    id: 'codexu.blue-white-porcelain',
    displayName: { 'zh-Hans': '青花瓷', en: 'Blue & White Porcelain' },
    shortDescription: {
      'zh-Hans': '白瓷钴蓝与宋瓷冰裂纹',
      en: 'Cobalt porcelain with Song celadon crackle',
    },
    light: porcelainLight as PaletteTokens,
    dark: porcelainDark as PaletteTokens,
  },
  {
    id: 'codexu.dunhuang-apsara',
    displayName: { 'zh-Hans': '敦煌飞天', en: 'Dunhuang Apsara' },
    shortDescription: {
      'zh-Hans': '石青、飘带朱与飞砂金',
      en: 'Mineral teal, ribbon red, and sand gold',
    },
    light: dunhuangLight as PaletteTokens,
    dark: dunhuangDark as PaletteTokens,
  },
  {
    id: 'codexu.forbidden-city-red',
    displayName: { 'zh-Hans': '故宫红墙', en: 'Forbidden City Red' },
    shortDescription: {
      'zh-Hans': '宫墙朱红、琉璃黄与黛瓦灰',
      en: 'Vermilion walls, glazed gold, and roof gray',
    },
    light: forbiddenCityLight as PaletteTokens,
    dark: forbiddenCityDark as PaletteTokens,
  },
  {
    id: 'codexu.orchid-dawn',
    displayName: { 'zh-Hans': '蒙特雷曙霞', en: 'Monterey Dawn' },
    shortDescription: {
      'zh-Hans': '兰紫、霞粉与克制晨橙',
      en: 'Orchid violet, dawn pink, and restrained orange',
    },
    light: orchidLight as PaletteTokens,
    dark: orchidDark as PaletteTokens,
  },
  {
    id: 'codexu.thousand-li-landscape',
    displayName: { 'zh-Hans': '千里江山', en: 'A Thousand Li of Rivers' },
    shortDescription: {
      'zh-Hans': '石青、石绿与绢本金',
      en: 'Mineral blue, green, and silk gold',
    },
    light: landscapeLight as PaletteTokens,
    dark: landscapeDark as PaletteTokens,
  },
];

export function resolvePalette(id: string | null | undefined): PaletteDescriptor {
  return PALETTE_CATALOG.find((palette) => palette.id === id)
    ?? PALETTE_CATALOG.find((palette) => palette.id === 'codexu.default')!;
}
