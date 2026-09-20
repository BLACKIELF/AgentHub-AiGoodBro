import { defineConfig } from '@playwright/test';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const webRoot = path.resolve(here, '..', '..');
// <repo>/windows/apps/codexu-tauri/web/tests/visual -> <repo>
const repoRoot = path.resolve(here, '..', '..', '..', '..', '..', '..');

// Baselines, actuals and diffs are local artifacts only. `.local-artifacts/`
// is Git-ignored at the repository root, so nothing here can be committed.
const artifactRoot = path.join(repoRoot, '.local-artifacts', 'visual').replace(/\\/g, '/');

const PORT = 1421;

export default defineConfig({
  testDir: here,
  testMatch: '**/*.visual.spec.mjs',
  outputDir: `${artifactRoot}/test-results`,
  fullyParallel: false,
  workers: 1,
  forbidOnly: true,
  reporter: [['list']],

  snapshotPathTemplate: `${artifactRoot}/snapshots/{projectName}/{arg}{ext}`,

  expect: {
    toHaveScreenshot: {
      animations: 'disabled',
      caret: 'hide',
      scale: 'css',
      maxDiffPixelRatio: 0,
    },
  },

  use: {
    baseURL: `http://127.0.0.1:${PORT}`,
    // Uses the browser shipped with the OS instead of downloading a bundled
    // Chromium, so `npm ci` stays cheap. Pin a bundled browser if the project
    // later needs byte-identical rendering across contributor machines.
    channel: process.env.CODEXU_VISUAL_BROWSER === 'chromium' ? undefined : 'msedge',
    viewport: { width: 1440, height: 900 },
    deviceScaleFactor: 1,
    locale: 'en-US',
    timezoneId: 'UTC',
    colorScheme: 'dark',
    trace: 'off',
    screenshot: 'off',
    video: 'off',
  },

  projects: [{ name: 'dashboard-1440x900' }],

  webServer: {
    command: `npm run dev -- --port ${PORT} --strictPort`,
    cwd: webRoot,
    url: `http://127.0.0.1:${PORT}`,
    reuseExistingServer: false,
    timeout: 120_000,
    stdout: 'ignore',
    stderr: 'pipe',
  },
});
