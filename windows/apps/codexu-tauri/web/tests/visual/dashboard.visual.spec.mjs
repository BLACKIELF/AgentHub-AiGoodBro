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

  test('header region', async ({ page }) => {
    await expect(page.locator('header').first()).toHaveScreenshot('dashboard-header.png');
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
