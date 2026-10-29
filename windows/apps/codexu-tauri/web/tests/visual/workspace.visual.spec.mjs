import { test, expect } from '@playwright/test';
import { FIXED_NOW_ISO, SYNTHETIC_DASHBOARD, SYNTHETIC_SETTINGS } from './synthetic-fixtures.mjs';
import { installTauriStub } from './tauri-stub.mjs';

async function workspace(page, { language = 'en', theme = 'dark' } = {}) {
  await page.clock.setFixedTime(new Date(FIXED_NOW_ISO));
  await installTauriStub(page, {
    settings: { ...SYNTHETIC_SETTINGS, language, theme }, dashboard: SYNTHETIC_DASHBOARD,
  }, () => {
    const original = window.__TAURI_INTERNALS__.invoke;
    const profiles = [
      { id: '1', label: 'Synthetic A', platform: 'codex', platform_name: 'Codex', selected: true, can_view_usage: true },
      { id: '2', label: 'Synthetic B', platform: 'codex', platform_name: 'Codex', selected: false, can_view_usage: true },
      { id: '3', label: 'Synthetic C', platform: 'claude_code', platform_name: 'Claude Code', selected: false, can_view_usage: false },
    ];
    const preferences = new Map();
    window.workspaceWrites = [];
    window.workspaceNavigationListeners = [];
    window.emitWorkspaceNavigation = payload => window.workspaceNavigationListeners.forEach(handler => window[`_${handler}`]({ event: 'workspace:navigate', id: 451, payload }));
    window.__TAURI_INTERNALS__.invoke = async (command, args) => {
      if (command === 'plugin:event|listen' && args.event === 'workspace:navigate') window.workspaceNavigationListeners.push(args.handler);
      if (command === 'list_profiles') return structuredClone(profiles);
      if (command === 'get_account_workflow' || command === 'set_account_workflow') {
        const prior = preferences.get(args.id) || { participating: false, model: null, effort: null, revision: 0 };
        if (command === 'set_account_workflow') {
          window.workspaceWrites.push({ command, id: args.id, action: structuredClone(args.action) });
          preferences.set(args.id, { ...prior, participating: args.action.value, revision: prior.revision + 1 });
        }
        return { profile_id: args.id, preference: preferences.get(args.id) || prior, phase: 'idle', started_at: null, supported: true };
      }
      if (command === 'read_profile_quota') return {
        profile_id: args.id, checked_at: Date.now(), account: { account_type: 'chatgpt', plan_type: 'plus', email_present: false },
        credits: { usd: null, points: 0, reset_cards: 2 },
        windows: [
          { kind: 'five_hour', remaining_percent: 71, resets_at: Date.now() + 3600000 },
          { kind: 'seven_day', remaining_percent: 37, resets_at: Date.now() + 86400000 },
          { kind: 'monthly', remaining_percent: 0, resets_at: null },
        ],
      };
      if (command === 'update_profile') { window.workspaceWrites.push({ command, action: args.action }); throw Error('This fixture does not mutate account order'); }
      return original(command, args);
    };
  });
  await page.goto('/');
  await expect(page.getByTestId('profile-1')).toBeVisible();
}

for (const scenario of [
  { theme: 'dark', language: 'en', width: 1440 },
  { theme: 'light', language: 'zh-Hans', width: 1280 },
  { theme: 'dark', language: 'zh-Hans', width: 480 },
  { theme: 'light', language: 'en', width: 760 },
]) {
  test(`workspace cards ${scenario.theme} ${scenario.language} ${scenario.width}`, async ({ page }) => {
    await page.setViewportSize({ width: scenario.width, height: 1000 });
    await workspace(page, scenario);
    const zh = scenario.language === 'zh-Hans';
    const first = page.getByTestId('profile-1');
    await expect(page.locator('.workspace-main')).toHaveScreenshot(`workspace-home-${scenario.theme}-${scenario.language}-${scenario.width}.png`);
    await first.getByRole('button', { name: zh ? '读取额度' : 'Read quota', exact: true }).click();
    await expect(first.locator('.quota-ring[data-known="true"]')).toHaveCount(3);
    await expect(first.getByRole('img', { name: /71%/ })).toBeVisible();
    await expect(first.getByRole('img', { name: /37%/ })).toBeVisible();
    await expect(first.locator('.quota-ring-number').last()).toHaveText('0%');
    await expect(first).not.toContainText('USD —');
    expect(await page.locator('body').evaluate(element => element.scrollWidth <= innerWidth)).toBe(true);
    expect(await first.locator('.account-directory-number').evaluate(element => element.scrollHeight <= element.clientHeight)).toBe(true);
    await expect(page.locator('.workspace-header')).toHaveScreenshot(`workspace-header-${scenario.theme}-${scenario.language}-${scenario.width}.png`);
    await expect(page.getByRole('region', { name: zh ? '账号目录' : 'Account directories', exact: true })).toHaveScreenshot(`workspace-cards-${scenario.theme}-${scenario.language}-${scenario.width}.png`);
  });
}

test('navigation and simple mode persist without losing tools or directory semantics', async ({ page }) => {
  await workspace(page);
  const nav = page.getByRole('navigation', { name: 'Home navigation' });
  await page.getByRole('button', { name: 'Simple', exact: true }).click();
  await expect(page.locator('.workspace-shell')).toHaveAttribute('data-workspace-mode', 'simple');
  await expect(page.getByRole('tab')).toHaveCount(0);
  await nav.getByRole('button', { name: 'Workspace', exact: true }).click();
  await expect(page.getByRole('tab')).toHaveCount(5);
  await expect(page.getByRole('tab', { name: 'Tasks', exact: true })).toBeVisible();
  await nav.getByRole('button', { name: 'Statistics', exact: true }).click();
  await expect(page.locator('#windows-usage .token-monitor-panel')).toBeVisible();
  await expect(page.getByTestId('profile-1')).toBeHidden();
  await nav.getByRole('button', { name: 'Accounts', exact: true }).click();
  await expect(page.getByTestId('profile-1')).toBeVisible();
  await expect(page.getByRole('region', { name: 'Account directories', exact: true })).toContainText('does not switch Codex login');
  await page.reload();
  await expect(nav.getByRole('button', { name: 'Accounts', exact: true })).toHaveAttribute('aria-current', 'page');
  await expect(page.getByRole('button', { name: 'Simple', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('.workspace-main')).toHaveScreenshot('workspace-accounts-simple.png');
});

test('native workspace navigation selects the actual tasks tab and ignores unknown pages', async ({ page }) => {
  await workspace(page);
  await page.getByRole('navigation').getByRole('button', { name: 'Workspace', exact: true }).click();
  await page.getByRole('tab', { name: 'Projects', exact: true }).click();
  await expect(page.getByRole('tab', { name: 'Projects', exact: true })).toHaveAttribute('aria-selected', 'true');
  await page.evaluate(() => window.emitWorkspaceNavigation({ page: 'tools', toolTab: 'tasks' }));
  await expect(page.getByRole('tab', { name: 'Tasks', exact: true })).toHaveAttribute('aria-selected', 'true');
  await expect(page.locator('#dashboard-home-panel-tasks')).toBeVisible();
  await page.evaluate(() => window.emitWorkspaceNavigation({ page: 'unrecognized', toolTab: 'tasks' }));
  await expect(page.locator('.workspace-main')).toHaveAttribute('data-page', 'tools');
  await expect(page.getByRole('tab', { name: 'Tasks', exact: true })).toHaveAttribute('aria-selected', 'true');
  await expect(page.locator('#dashboard-home-panel-tasks')).toHaveScreenshot('workspace-native-task-navigation.png');
});

test('card size, list and platform filter persist while preserving global numbering', async ({ page }) => {
  await workspace(page);
  const region = page.getByRole('region', { name: 'Account directories', exact: true });
  const first = page.getByTestId('profile-1');
  const small = (await first.boundingBox()).width;
  await region.getByRole('combobox', { name: 'Card size', exact: true }).selectOption('medium');
  expect((await first.boundingBox()).width).toBeGreaterThan(small);
  await expect(region).toHaveScreenshot('workspace-cards-medium.png');
  await region.getByRole('button', { name: 'List', exact: true }).click();
  await region.getByRole('combobox', { name: 'Filter platform' }).selectOption('claude');
  await expect(first).toBeHidden();
  await expect(page.getByTestId('profile-3').locator('.account-directory-number')).toHaveText('03');
  await region.getByRole('combobox', { name: 'Filter platform' }).selectOption('all');
  await page.reload();
  await expect(region.getByRole('combobox', { name: 'Card size', exact: true })).toHaveValue('medium');
  await expect(region.locator('.account-directory-grid')).toHaveClass(/is-list/);
  await expect(region).toHaveScreenshot('workspace-accounts-list.png');
  await page.setViewportSize({ width: 480, height: 1000 });
  expect(await region.evaluate(element => element.scrollWidth <= element.clientWidth)).toBe(true);
  await expect(region).toHaveScreenshot('workspace-accounts-list-narrow.png');
});

test('participation changes no display order and more menu keeps destructive actions explicit', async ({ page }) => {
  await workspace(page);
  const region = page.getByRole('region', { name: 'Account directories', exact: true });
  const first = page.getByTestId('profile-1');
  const ids = () => region.locator('li').evaluateAll(rows => rows.map(row => row.dataset.testid));
  const before = await ids();
  await first.getByRole('button', { name: 'Model and scheduling', exact: false }).click();
  await first.getByRole('switch', { name: 'Participate in scheduling' }).check();
  await expect(first.getByRole('switch')).toBeChecked();
  expect(await ids()).toEqual(before);
  expect(await page.evaluate(() => window.workspaceWrites.map(write => write.command))).toEqual(['set_account_workflow']);
  await first.locator('details.account-more > summary').click();
  await expect(first.getByRole('button', { name: 'Move up', exact: true })).toBeDisabled();
  await expect(first.getByRole('button', { name: 'Rename', exact: true })).toBeVisible();
  await expect(first).toHaveScreenshot('workspace-account-more.png');
  await page.keyboard.press('Escape');
  await expect(first.locator('details.account-more')).not.toHaveAttribute('open');
  await expect(first.locator('details.account-more > summary')).toBeFocused();
});
