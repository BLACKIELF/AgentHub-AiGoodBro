import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const webRoot = path.resolve(here, '..');
const read = (relativePath) => fs.readFileSync(path.join(webRoot, relativePath), 'utf8');
const readIfExists = (relativePath) => {
  const filePath = path.join(webRoot, relativePath);
  return fs.existsSync(filePath) ? fs.readFileSync(filePath, 'utf8') : '';
};

const paletteIds = [
  'codexu.liquid-keycap',
  'codexu.default',
  'codexu.blue-white-porcelain',
  'codexu.dunhuang-apsara',
  'codexu.forbidden-city-red',
  'codexu.orchid-dawn',
  'codexu.thousand-li-landscape',
];

test('Windows palette catalog registers every macOS Palette Package v1', () => {
  const source = readIfExists('src/utils/paletteCatalog.ts');
  for (const paletteId of paletteIds) {
    assert.match(source, new RegExp(paletteId.replaceAll('.', '\\.'), 'u'));
  }
  assert.match(source, /DEFAULT_PALETTE_ID(?:\s*:\s*PaletteId)?\s*=\s*['"]codexu\.liquid-keycap['"]/u);
  assert.match(source, /resolvePalette\(/u);
});

test('settings contract persists palette identity independently from appearance mode', () => {
  const types = read('src/types/settings.ts');
  const rustState = read('../src-tauri/src/app_state.rs');
  const rustSettings = read('../src-tauri/src/commands/settings.rs');
  const settingsView = read('src/windows/Settings.tsx');

  assert.match(types, /palette_id:\s*PaletteId/u);
  assert.match(rustState, /pub palette_id:\s*String/u);
  assert.match(rustState, /codexu\.default/u);
  assert.match(rustSettings, /pub palette_id:\s*Option<String>/u);
  assert.match(rustSettings, /config\.palette_id\s*=\s*palette_id/u);
  assert.match(settingsView, /paletteCatalog/u);
  assert.match(settingsView, /handlePalette/u);
});

test('theme application accepts both appearance mode and palette identity', () => {
  const theme = read('src/utils/appTheme.ts');
  assert.match(theme, /applyAppTheme\(theme:\s*ThemeMode,\s*paletteId:\s*PaletteId/u);
  assert.match(theme, /resolvePalette\(paletteId\)/u);
  assert.match(theme, /palette\.data\.modelSeries/u);
});
