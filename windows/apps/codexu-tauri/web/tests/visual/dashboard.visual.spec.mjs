import { test, expect } from '@playwright/test';
import { FIXED_NOW_ISO, SYNTHETIC_DASHBOARD, SYNTHETIC_SETTINGS } from './synthetic-fixtures.mjs';
import { installTauriStub } from './tauri-stub.mjs';

// Rendered, locator-level assertions for the Windows dashboard.
//
// Requirements these cover (see windows/AGENTS.md and CONTRIBUTING.md):
//   - reproducible rendered evidence instead of source-text contract tests;
//   - isolated temporary service, browser context and synthetic data only;
//   - fixed viewport, theme and clock;
//   - baselines/actuals/diffs stay under the Git-ignored `.local-artifacts/`.

const TABS = ['tasks', 'leadership', 'usage', 'projects', 'skills'];

test('new settings without a palette use liquid keycap', async ({ page }) => {
  await page.clock.setFixedTime(new Date(FIXED_NOW_ISO));
  const settings = { ...SYNTHETIC_SETTINGS };
  delete settings.palette_id;
  await installTauriStub(page, { settings, dashboard: SYNTHETIC_DASHBOARD });
  await page.goto('/');
  await expect(page.locator('html')).toHaveAttribute('data-palette', 'codexu.liquid-keycap');
  await expect(page.getByRole('combobox', { name: 'Theme palette' })).toHaveValue('codexu.liquid-keycap');
});

test('unavailable saved palette uses the classic safe fallback with a notice', async ({ page }) => {
  await page.clock.setFixedTime(new Date(FIXED_NOW_ISO));
  await installTauriStub(page, { settings: { ...SYNTHETIC_SETTINGS, palette_id: 'missing.palette' }, dashboard: SYNTHETIC_DASHBOARD });
  await page.goto('/');
  await expect(page.locator('html')).toHaveAttribute('data-palette', 'codexu.default');
  await expect(page.getByRole('combobox', { name: 'Theme palette' })).toHaveValue('codexu.default');
  await expect(page.getByText('Saved palette is unavailable; the classic default is in use.')).toBeVisible();
});

test.describe('Windows dashboard rendering (synthetic fixtures)', () => {
  test.beforeEach(async ({ page }) => {
    // Freeze Date so relative-time labels and trend cutoffs do not drift.
    await page.clock.setFixedTime(new Date(FIXED_NOW_ISO));
    await installTauriStub(page, { settings: SYNTHETIC_SETTINGS, dashboard: SYNTHETIC_DASHBOARD });
    await page.goto('/');
    await expect(page.locator('.dashboard-home')).toBeVisible();
    await page.waitForLoadState('networkidle');
  });

  test('the synthetic bridge feeds real data into the dashboard', async ({ page }) => {
    // Guards against silently screenshotting an empty or error shell.
    await expect(page.locator('.dashboard-home-overview')).toBeVisible();
    await expect(page.locator('.dashboard-home-metrics')).toBeVisible();
    await expect(page.getByRole('tab')).toHaveCount(TABS.length);
    await expect(page.locator('main')).not.toContainText('Failed to load usage data');
    await expect(page.locator('main')).not.toContainText('Tauri runtime is unavailable');
  });

  test('home usage statistics follow notices as a separate collapsed section and preserve explicit preferences', async ({ page }) => {
    // Fit the existing chart module and tool details inside the scrolling workspace.
    await page.setViewportSize({ width: 1440, height: 1900 });
    const section = page.locator('[data-home-section="usage-summary"]');
    const toggle = section.getByRole('button', { name: 'Usage statistics', exact: true });
    const notices = page.locator('[data-home-section="notices"]');
    await expect(toggle).toHaveAttribute('aria-expanded', 'false');
    await expect(section.locator('.usage-panel')).toHaveCount(0);
    await expect(notices.locator('[data-home-section="usage-summary"]')).toHaveCount(0);
    expect(await page.locator('.home-notice-strip').evaluate(element => element.nextElementSibling?.id)).toBe('windows-usage');
    expect(await page.locator('#windows-usage').evaluate(element => element.nextElementSibling?.id)).toBe('windows-accounts');
    await expect(notices.locator(':scope > button')).toHaveAttribute('aria-expanded', 'false');
    await expect(section).toHaveScreenshot('home-usage-statistics-collapsed.png');
    await toggle.click();
    await expect(section.locator('.usage-panel')).toBeVisible();
    await expect(section.locator('.usage-panel .recharts-wrapper')).toBeVisible();
    await expect(section.getByText('Recent usage', { exact: true })).toBeVisible();
    await expect(section.getByText('apply_patch', { exact: true })).toBeVisible();
    await expect(notices.locator(':scope > button')).toHaveAttribute('aria-expanded', 'false');
    await expect(section).toHaveScreenshot('home-usage-statistics.png');
    await page.reload();
    await expect(toggle).toHaveAttribute('aria-expanded', 'true');
    await expect(section.locator('.usage-panel')).toBeVisible();
    await expect(section.getByText('apply_patch', { exact: true })).toBeVisible();
    await toggle.click();
    await expect(toggle).toHaveAttribute('aria-expanded', 'false');
    await expect(section.locator('.usage-panel')).toHaveCount(0);
    await page.reload();
    await expect(page.locator('[data-home-section="usage-summary"] > button')).toHaveAttribute('aria-expanded', 'false');
    await expect(page.locator('[data-home-section="overview"] > button')).toHaveAttribute('aria-expanded', 'true');
    await page.locator('#dashboard-home-tab-usage').click();
    await expect(page.locator('#dashboard-home-panel-usage .usage-panel')).toBeVisible();
  });

  test('header region', async ({ page }) => {
    await expect(page.locator('header').first()).toHaveScreenshot('dashboard-header.png');
  });

  test('palette choice changes the actual dashboard tokens without replacing saved appearance', async ({ page }) => {
    await page.evaluate(settings => {
      const original = window.__TAURI_INTERNALS__.invoke;
      window.themePatches = [];
      window.__TAURI_INTERNALS__.invoke = async (cmd, args) => {
        if (cmd === 'set_settings') {
          window.themePatches.push(args.req);
          return { ...settings, ...args.req };
        }
        return original(cmd, args);
      };
    }, SYNTHETIC_SETTINGS);
    const picker = page.getByRole('combobox', { name: 'Theme palette' });
    await expect(picker.locator('option')).toHaveCount(7);
    await picker.selectOption('codexu.liquid-keycap');
    await expect(page.locator('html')).toHaveAttribute('data-palette', 'codexu.liquid-keycap');
    expect(await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--accent').trim())).toBe('#4E9AFF');
    expect(await page.evaluate(() => window.themePatches)).toEqual([{ palette_id: 'codexu.liquid-keycap' }]);
    await expect(page.locator('header').first()).toHaveScreenshot('dashboard-header-liquid-keycap.png');
  });

  test('failed palette save restores the previous theme and reports the problem', async ({ page }) => {
    await page.evaluate(() => {
      const original = window.__TAURI_INTERNALS__.invoke;
      window.__TAURI_INTERNALS__.invoke = (cmd, args) => cmd === 'set_settings' ? Promise.reject(new Error('Synthetic save failure')) : original(cmd, args);
    });
    await page.getByRole('combobox', { name: 'Theme palette' }).selectOption('codexu.liquid-keycap');
    await expect(page.getByRole('alert')).toContainText('Appearance settings are unavailable');
    await expect(page.locator('html')).toHaveAttribute('data-palette', 'codexu.default');
  });

  test('overview region (leadership + quota + metrics + monthly value)', async ({ page }) => {
    await expect(page.locator('.dashboard-home-overview')).toHaveScreenshot('dashboard-overview.png');
  });

  for (const tab of TABS) {
    test(`${tab} tab panel`, async ({ page }) => {
      const tabButton = page.locator(`#dashboard-home-tab-${tab}`);
      await tabButton.click();
      await expect(tabButton).toHaveAttribute('aria-selected', 'true');

      const panel = page.locator(`#dashboard-home-panel-${tab}`);
      await expect(panel).toBeVisible();
      await expect(panel).toHaveScreenshot(`dashboard-panel-${tab}.png`);
    });
  }
});
