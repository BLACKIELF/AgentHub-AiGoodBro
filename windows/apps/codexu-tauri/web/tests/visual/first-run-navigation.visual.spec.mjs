import { test, expect } from '@playwright/test';
import { installTauriStub } from './tauri-stub.mjs';
import { SYNTHETIC_SETTINGS } from './synthetic-fixtures.mjs';

function pendingInstallation() {
  // The native event plugin supplies this cleanup hook. Keep this fixture's
  // StrictMode cleanup valid without changing the shared browser bridge.
  window.__TAURI_EVENT_PLUGIN_INTERNALS__ = { unregisterListener() {} };
  const invoke = window.__TAURI_INTERNALS__.invoke;
  const setup = {
    version: '3.0.0', eventId: 'files:v1:1:2:3:4:5:6', status: 'pending',
    audience: null, shouldPresent: true, failureCode: null,
  };
  window.firstRunSetupCalls = [];
  window.__TAURI_INTERNALS__.invoke = async (command, args) => {
    if (command === 'get_setup_context') return structuredClone(setup);
    if (command === 'update_setup_onboarding') {
      window.firstRunSetupCalls.push(structuredClone(args));
      if (args.eventId !== setup.eventId || args.audience !== null || args.outcome !== 'deferred') {
        throw Error('unexpected_setup_update');
      }
      setup.status = 'deferred';
      setup.shouldPresent = false;
      return structuredClone(setup);
    }
    return invoke(command, args);
  };
}

async function accessibleHomeButtons(session, homeLabel) {
  const tree = await session.send('Accessibility.getFullAXTree');
  return tree.nodes.filter(node => !node.ignored && node.role?.value === 'button'
    && node.name?.value === homeLabel).length;
}

for (const language of ['en', 'zh-Hans']) {
  test(`first-run guide defers through its visible action before Workspace navigation: ${language}`, async ({ page }) => {
    await page.route('**/*', route => new URL(route.request().url()).hostname === '127.0.0.1'
      ? route.continue() : route.abort());
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await installTauriStub(page, {
      settings: { ...SYNTHETIC_SETTINGS, language }, dashboard: null,
    }, pendingInstallation);
    await page.goto('/');

    const zh = language === 'zh-Hans';
    const homeLabel = zh ? '首页' : 'Home';
    const guide = page.getByRole('dialog', { name: zh ? '欢迎使用 AiGoodBro' : 'Welcome to AiGoodBro' });
    await expect(guide).toBeVisible();
    expect(await guide.evaluate(element => element.matches(':modal'))).toBe(true);
    expect(await page.evaluate(() => window.firstRunSetupCalls)).toEqual([]);
    await expect(page.locator('#workspace-nav-home')).toBeVisible();

    // DOM visibility/role lookup can still find an inert background button.
    // Check Chromium's actual accessibility tree; this is not Windows UIA proof.
    const session = await page.context().newCDPSession(page);
    await expect.poll(() => accessibleHomeButtons(session, homeLabel)).toBe(0);
    await guide.getByRole('button', { name: zh ? '稍后设置' : 'Set up later', exact: true }).click();
    await expect(guide).toHaveCount(0);
    await expect.poll(() => accessibleHomeButtons(session, homeLabel)).toBe(1);
    expect(await page.evaluate(() => window.firstRunSetupCalls)).toEqual([
      { eventId: 'files:v1:1:2:3:4:5:6', audience: null, outcome: 'deferred' },
    ]);

    await page.getByRole('navigation', { name: zh ? '首页导航' : 'Home navigation', exact: true })
      .getByRole('button', { name: zh ? '工作台' : 'Workspace', exact: true }).click();
    await expect(page.locator('#windows-home')).toHaveAttribute('data-page', 'tools');
    await expect(page.locator('#dashboard-home-tab-tasks')).toBeVisible();
    await expect(page.locator('#dashboard-home-tab-tasks')).toHaveAttribute('aria-selected', 'true');
    await expect(page.locator('#dashboard-home-panel-tasks .live-tasks-panel')).toBeVisible();
    expect(errors).toEqual([]);
    await session.detach();
  });
}
