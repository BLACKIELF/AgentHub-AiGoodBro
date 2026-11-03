import { test, expect } from '@playwright/test';
import { FIXED_NOW_ISO, SYNTHETIC_DASHBOARD, SYNTHETIC_SETTINGS } from './synthetic-fixtures.mjs';
import { installTauriStub } from './tauri-stub.mjs';

// Compare the Windows layout at the two Mac165 reference widths. All account
// values are synthetic; neither the browser nor this fixture reads local state.
async function macLayout(page, { theme = 'dark', language = 'zh-Hans' } = {}) {
  await page.clock.setFixedTime(new Date(FIXED_NOW_ISO));
  await installTauriStub(page, {
    settings: { ...SYNTHETIC_SETTINGS, theme, language, palette_id: 'codexu.liquid-keycap' },
    dashboard: SYNTHETIC_DASHBOARD,
  }, () => {
    const original = window.__TAURI_INTERNALS__.invoke;
    const profiles = Array.from({ length: 8 }, (_, index) => ({
      id: `layout-${index + 1}`, label: `Synthetic ${String(index + 1).padStart(2, '0')}`,
      platform: 'codex', platform_name: 'Codex', selected: index === 0,
      can_view_usage: true,
    }));
    window.__TAURI_INTERNALS__.invoke = async (command, args) => {
      if (command === 'list_profiles') return structuredClone(profiles);
      if (command === 'read_profile_quota') {
        const index = Number(args.id.split('-').at(-1)) - 1;
        return {
          profile_id: args.id, checked_at: Date.now(),
          account: { account_type: 'chatgpt', plan_type: 'plus', email_present: false },
          credits: { usd: null, points: null, reset_cards: null },
          windows: [
            { kind: 'five_hour', remaining_percent: 100 - index * 3, resets_at: Date.now() + 10800000 },
            { kind: 'seven_day', remaining_percent: 80 - index * 8, resets_at: Date.now() + 86400000 },
          ],
        };
      }
      return original(command, args);
    };
  });
  await page.goto('/');
  await expect(page.getByTestId('profile-layout-1')).toBeVisible();
  for (let index = 1; index <= 8; index++) {
    const card = page.getByTestId(`profile-layout-${index}`);
    await card.getByRole('button', { name: language === 'zh-Hans' ? '读取额度' : 'Read quota', exact: true }).click();
    await expect(card.locator('.quota-ring[data-known="true"]')).toHaveCount(2);
  }
  await page.locator('.workspace-main').evaluate(element => { element.scrollTop = 0; });
  await page.mouse.move(0, 0);
}

for (const width of [820, 1440]) {
  test(`Mac layout keeps rail, content and account grid aligned at ${width}`, async ({ page }) => {
    await page.setViewportSize({ width, height: 980 });
    await macLayout(page);
    const rail = page.locator('.workspace-sidebar');
    const header = page.locator('.workspace-header');
    const main = page.locator('.workspace-main');
    const grid = page.locator('.account-directory-grid');
    const railBounds = await rail.boundingBox();
    const headerBounds = await header.boundingBox();
    const mainBounds = await main.boundingBox();
    expect(railBounds.x).toBe(0);
    expect(railBounds.width).toBe(64);
    expect(headerBounds.x).toBe(64);
    expect(mainBounds.x).toBe(64);
    expect(mainBounds.width).toBe(width - 64);
    expect(await grid.evaluate(element => getComputedStyle(element).gridTemplateColumns.split(' ').length)).toBe(width === 1440 ? 4 : 2);
    expect(await page.locator('body').evaluate(element => element.scrollWidth <= innerWidth)).toBe(true);
    await expect(header).toHaveScreenshot(`mac-layout-header-${width}.png`);
    await expect(rail).toHaveScreenshot(`mac-layout-rail-${width}.png`);
    await expect(grid).toHaveScreenshot(`mac-layout-accounts-${width}.png`);
    // Locator captures can scroll a tall grid. Restore the reference viewport
    // before comparing the whole shell at the narrow Mac window size.
    await main.evaluate(element => { element.scrollTop = 0; });
    await expect(page.locator('.workspace-shell')).toHaveScreenshot(`mac-layout-home-${width}.png`);

    await page.locator('#workspace-nav-home').focus();
    await page.keyboard.press('Tab');
    await expect(page.getByRole('navigation', { name: '账号平台' }).getByRole('button', { name: 'Codex', exact: true })).toBeFocused();

    // A provider opens account management without overwriting Home's collapse
    // preference; returning Home also restores the all-provider selection.
    await page.locator('.account-directory-collapse-toggle').click();
    await expect(page.locator('.account-directory-body')).toBeHidden();
    await page.getByRole('navigation', { name: '账号平台' }).getByRole('button', { name: 'Codex', exact: true }).click();
    await expect(main).toHaveAttribute('data-page', 'accounts');
    await expect(page.getByRole('region', { name: '托管账号', exact: true })).toBeVisible();
    await expect(page.locator('.account-directory-body')).toBeVisible();
    await expect(page.getByTestId('profile-layout-1').locator('.quota-ring[data-known="true"]')).toHaveCount(2);
    await page.locator('#workspace-nav-home').click();
    await expect(main).toHaveAttribute('data-page', 'home');
    await expect(page.locator('.account-directory-body')).toBeHidden();
    await expect(page.getByRole('navigation', { name: '账号平台' }).getByRole('button', { name: 'Codex', exact: true })).toHaveAttribute('aria-pressed', 'false');
    await page.locator('.account-directory-collapse-toggle').click();
    await expect(page.getByTestId('profile-layout-1').locator('.quota-ring[data-known="true"]')).toHaveCount(2);
  });
}

test('workspace overview fills the available content without an unused statistics column', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 980 });
  await macLayout(page, { language: 'en' });
  await page.locator('#workspace-nav-tools').click();
  const overview = page.locator('.dashboard-home-overview');
  await expect(overview).toHaveAttribute('data-local-statistics', 'false');
  const columns = await overview.evaluate(element => getComputedStyle(element).gridTemplateColumns.split(' ').map(Number.parseFloat));
  expect(columns).toHaveLength(2);
  expect(Math.abs(columns[0] - columns[1])).toBeLessThan(1);
  await expect(overview).toHaveScreenshot('mac-layout-workspace-overview.png');
  await expect(page.locator('.workspace-shell')).toHaveScreenshot('mac-layout-workspace.png');

  await page.locator('#dashboard-home-tab-skills').click();
  await page.setViewportSize({ width: 1440, height: 480 });
  const main = page.locator('.workspace-main');
  expect(await main.evaluate(element => getComputedStyle(element).overflowY)).toBe('auto');
  expect(await main.evaluate(element => element.scrollHeight > element.clientHeight)).toBe(true);
  const lastSkill = page.locator('#dashboard-home-panel-skills [role="listitem"]').last();
  await lastSkill.scrollIntoViewIfNeeded();
  await expect(lastSkill).toBeInViewport();
  expect(await main.evaluate(element => element.scrollTop)).toBeGreaterThan(0);
  expect(await page.locator('body').evaluate(element => element.scrollHeight <= innerHeight)).toBe(true);
});
