import { test, expect } from '@playwright/test';
import { SYNTHETIC_DASHBOARD, SYNTHETIC_SETTINGS } from './synthetic-fixtures.mjs';
import { installTauriStub } from './tauri-stub.mjs';

test.beforeEach(async ({ page }) => {
  await page.clock.install({ time: new Date('2026-09-22T12:00:00Z') });
  await installTauriStub(page, { settings: SYNTHETIC_SETTINGS, dashboard: SYNTHETIC_DASHBOARD });
  await page.addInitScript(() => {
    const base = window.__TAURI_INTERNALS__.invoke;
    window.feedCalls = 0;
    window.__TAURI_INTERNALS__.invoke = async (cmd, args) => {
      if (cmd !== 'read_public_feed') return base(cmd, args);
      window.feedCalls++;
      if (args.feed === 'forecast') return '<html><div class="hero-figure">codex-resets</div><div data-role="scheduled-reset" data-scheduled-for="2026-09-22T12:00:10Z"><a href="https://x.com/thsottiaux/status/2102254445082116335">source</a></div></html>';
      if (args.feed === 'history') return JSON.stringify({ data: [], meta: { api_version: 'v1', generated_at: new Date().toISOString() } });
      return JSON.stringify({ version: 1, messages: [] });
    };
  });
});

test('live forecast ticks without network calls, catches up and waits for confirmation at zero', async ({ page }) => {
  await page.goto('/');
  const timer = page.getByTestId('forecast-reset-countdown');
  await expect(timer).toContainText('00:00:10');
  const calls = await page.evaluate(() => window.feedCalls);
  await page.clock.fastForward(3000);
  await expect(timer).toContainText('00:00:07');
  await page.clock.fastForward(10000);
  await expect(timer).toContainText('awaiting confirmation');
  expect(await page.evaluate(() => window.feedCalls)).toBe(calls);
  await expect(page.getByRole('region', { name: 'Public reset updates' })).toHaveScreenshot('public-reset-expired.png');
});

test('home categories collapse independently and persist after reload', async ({ page }) => {
  await page.goto('/');
  const recommendations = page.locator('[data-home-section="recommendations"]');
  await recommendations.getByRole('button', { name: 'Recommended Skills and apps', exact: true }).click();
  await expect(recommendations.getByText('Oracle', { exact: true })).toHaveCount(0);
  await expect(page.getByRole('region', { name: 'Public reset updates' })).toBeVisible();
  await page.reload();
  await expect(recommendations.getByRole('button')).toHaveAttribute('aria-expanded', 'false');
  await recommendations.getByRole('button').click();
  await expect(recommendations.getByText('Oracle', { exact: true })).toBeVisible();
  await expect(recommendations).toHaveScreenshot('recommended-skills-expanded.png');
  await page.setViewportSize({ width: 720, height: 600 });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBeTruthy();
  await expect(recommendations).toHaveScreenshot('recommended-skills-narrow.png');
});

test('forecast parser rejects changed markup and ambiguous source; known empty state clears cache', async ({ page }) => {
  await page.goto('/');
  const result = await page.evaluate(async () => {
    const { parseForecast } = await import('/src/utils/publicFeeds.ts');
    const now = Date.now();
    const results = [];
    for (const html of ['<html>codex-resets hero-figure changed</html>', '<html>codex-resets hero-figure<div data-role="scheduled-reset" data-scheduled-for="invalid"></div></html>']) {
      try { parseForecast(html, now); results.push(false); } catch { results.push(true); }
    }
    results.push(parseForecast('<html>codex-resets hero-figure<div data-role="pending-reset"></div></html>', now) === null);
    return results;
  });
  expect(result).toEqual([true, true, true]);
});

test('About bundles the full QR, copy feedback, enlargement and Escape close', async ({ page, context }) => {
  await context.grantPermissions(['clipboard-read', 'clipboard-write']);
  await installTauriStub(page, { settings: SYNTHETIC_SETTINGS, dashboard: SYNTHETIC_DASHBOARD, windowLabel: 'settings' });
  await page.goto('/');
  const about = page.getByRole('region', { name: 'About AiGoodBro' });
  await about.getByRole('button', { name: 'Copy WeChat ID' }).click();
  await expect(about.getByRole('button', { name: 'Copied' })).toBeVisible();
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe('AiGoodBro');
  await about.getByRole('button', { name: 'Enlarge WeChat QR code' }).click();
  await expect(page.getByRole('dialog')).toBeVisible();
  const image = page.getByRole('dialog').locator('img');
  await expect(image).toBeVisible();
  expect(await image.evaluate(element => element.naturalWidth > 0 && element.naturalHeight > element.naturalWidth)).toBeTruthy();
  await expect(page.getByRole('dialog')).toHaveScreenshot('assistant-qr-expanded.png');
  await page.keyboard.press('Escape');
  await expect(page.getByRole('dialog')).not.toBeVisible();
  await expect(about).toHaveScreenshot('assistant-contact.png');
});


test('reset history calendar has explicit empty dates and independent close', async ({ page }) => {
  await page.goto('/');
  const region = page.getByRole('region', { name: 'Public reset updates' });
  await region.getByText('Calendar and details', { exact: true }).click();
  const calendar = region.getByLabel('Reset history calendar', { exact: true });
  await expect(calendar).toContainText('September 2026');
  await calendar.getByRole('button', { name: '2026-09-21', exact: true }).click();
  await expect(calendar).toContainText('No recorded announcements on this date.');
  await expect(calendar.getByRole('button', { name: '2026-09-21', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await expect(calendar.getByRole('button', { name: '2026-09-23', exact: true })).toBeDisabled();
  await expect(calendar).toHaveScreenshot('reset-calendar.png');
  await region.getByText('Calendar and details', { exact: true }).click();
  await expect(calendar).not.toBeVisible();
});
