import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const homePath = new URL('../src/components/DashboardHome.tsx', import.meta.url);
const modelsPath = new URL('../src/types/models.ts', import.meta.url);
const panelPath = new URL('../src/components/SkillsPanel.tsx', import.meta.url);

test('activates the Dashboard Skills tab with safe local-read metadata only', async () => {
  const [home, models, panel] = await Promise.all([
    readFile(homePath, 'utf8'),
    readFile(modelsPath, 'utf8'),
    readFile(panelPath, 'utf8'),
  ]);

  assert.match(home, /<SkillsPanel skills=\{usage\?\.skill_usages \?\? \[\]\} \/>/);
  assert.match(panel, /useI18n/);
  assert.match(panel, /skills\.usage/);
  assert.match(panel, /skills\.tracked/);
  assert.match(panel, /skills\.localReads/);
  assert.match(panel, /skills\.sessions/);
  assert.match(panel, /style=\{\{ '--skill-intensity':/);
  assert.match(panel, /skills\.relativeActivityValue/);
  assert.match(panel, /skills\.privacyFiltered/);
  assert.match(panel, /skills\.localOnly/);

  const skillUsage = models.match(/export interface SkillUsage \{([\s\S]*?)\n\}/)?.[1] ?? '';
  assert.match(skillUsage, /load_count: number;/);
  assert.match(skillUsage, /thread_count: number;/);
  assert.match(skillUsage, /last_loaded_at: number \| null;/);
  assert.doesNotMatch(skillUsage, /path:/);
  assert.doesNotMatch(skillUsage, /static_token_estimate|static_byte_count/);
});

// The scrolling layout is verified against the rendered workspace in
// visual/mac-layout.visual.spec.mjs; it does not depend on utility class names.
