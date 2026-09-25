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
      if (args.feed === 'history') return JSON.stringify({ data: window.publicHistoryRows ?? [], meta: { api_version: 'v1', generated_at: new Date().toISOString() } });
      return JSON.stringify({ version: 1, messages: window.publicMessageRows ?? [] });
    };
  });
});

const openNotices = async page => {
  const section = page.locator('[data-home-section="notices"]');
  await section.getByRole('button', { name: 'Recommended Skills and official notices' }).click();
  await expect(section.getByRole('button', { name: 'Recommended Skills and official notices' })).toHaveAttribute('aria-expanded', 'true');
};

test('live forecast ticks without network calls, catches up and waits for confirmation at zero', async ({ page }) => {
  await page.goto('/');
  await openNotices(page);
  const timer = page.getByTestId('forecast-reset-countdown');
  await expect(timer).toContainText('00:00:10');
  const calls = await page.evaluate(() => window.feedCalls);
  // `pauseAt` rather than `fastForward`: fast-forwarding leaves the clock ticking, so
  // the polling assertion below lets real time leak in and the countdown can run past
  // the second being asserted before it is ever read. That is why this missed
  // `00:00:07` on a busy runner while passing on an idle machine.
  await page.clock.pauseAt(new Date('2026-09-22T12:00:03Z'));
  await expect(timer).toContainText('00:00:07');
  // Same reasoning at the other end: pause at the instant rather than run past it.
  await page.clock.pauseAt(new Date('2026-09-22T12:00:13Z'));
  await expect(timer).toContainText('awaiting confirmation');
  expect(await page.evaluate(() => window.feedCalls)).toBe(calls);
  await expect(page.getByRole('region', { name: 'Public reset updates' })).toHaveScreenshot('public-reset-expired.png');
});

test('home categories collapse independently and persist after reload', async ({ page }) => {
  await page.goto('/');
  await openNotices(page);
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


test('reset updates retain the latest three notices and complete sources without a calendar', async ({ page }) => {
  await page.clock.setFixedTime(new Date('2026-09-22T12:00:00Z'));
  await page.addInitScript(() => {
    window.publicHistoryRows = [1, 3, 2, 4].map(index => ({
      id: `200${index}`, reset_type: 'regular', announced_at: `2026-09-${17 + index}T10:00:00Z`,
      text: `Synthetic public reset ${index}. Full announcement body.`,
      source: { type: 'x_post', author: 'thsottiaux', url: `https://x.com/thsottiaux/status/200${index}` },
    }));
    window.publicMessageRows = [1, 3, 2, 4].map(index => ({
      id: `message-${index}`, title: `Synthetic publisher notice ${index}`, body: `Full publisher body ${index}.`,
      publishedAt: `2026-09-${17 + index}T10:00:00Z`, expiresAt: '2026-09-23T10:00:00Z',
      url: `https://aigoodbro.com/notices/synthetic-${index}`,
    }));
  });
  await page.goto('/');
  await openNotices(page);
  const region = page.getByRole('region', { name: 'Public reset updates' });
  await expect(region.getByTestId('forecast-reset-countdown')).toContainText('00:00:10');
  await expect(region.getByRole('link', { name: 'Source announcement', exact: true })).toHaveAttribute('href', 'https://x.com/thsottiaux/status/2102254445082116335');
  await expect(region.getByText('Calendar and details', { exact: true })).toHaveCount(0);
  await expect(page.getByLabel('Reset history calendar', { exact: true })).toHaveCount(0);
  await expect(region).toHaveScreenshot('public-reset-compact.png');
  await region.getByText('Latest 3 historical records', { exact: true }).click();
  await expect(region.locator('li p')).toHaveText([4, 3, 2].map(index => `Synthetic public reset ${index}. Full announcement body.`));
  const historySources = region.getByRole('link', { name: 'Original source', exact: true });
  await expect(historySources).toHaveCount(3);
  for (const [position, index] of [4, 3, 2].entries()) {
    await expect(historySources.nth(position)).toHaveAttribute('href', `https://x.com/thsottiaux/status/200${index}`);
  }
  await expect(region).toHaveScreenshot('public-reset-recent-history.png');
  const messages = page.getByRole('region', { name: 'Publisher announcements' });
  await expect(messages.locator('li p')).toHaveText([4, 3, 2].map(index => `Full publisher body ${index}.`));
  const messageSources = messages.getByRole('link', { name: 'Original source', exact: true });
  await expect(messageSources).toHaveCount(3);
  for (const [position, index] of [4, 3, 2].entries()) {
    await expect(messageSources.nth(position)).toHaveAttribute('href', `https://aigoodbro.com/notices/synthetic-${index}`);
  }
  await region.getByText('Latest 3 historical records', { exact: true }).click();
  await expect(historySources.first()).not.toBeVisible();
  await expect(messages).toBeVisible();
});
