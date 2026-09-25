import { defineConfig } from '@playwright/test';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const webRoot = path.resolve(here, '..', '..');
// <repo>/windows/apps/codexu-tauri/web/tests/visual -> <repo>
const repoRoot = path.resolve(here, '..', '..', '..', '..', '..', '..');

// Baselines, actuals and diffs are local artifacts only. `.local-artifacts/`
// is Git-ignored at the repository root, so nothing here can be committed.
const artifactRoot = path.join(repoRoot, '.local-artifacts', 'visual').replace(/\\/g, '/');

// Baselines, actuals and diffs stay under `artifactRoot/snapshots`. Only the
// per-run scratch directory (traces, videos, error context) is transient, and it
// is kept in the operating-system temp directory: a repository volume with no
// usable recycle bin, or a locked file left by an interrupted run, must not be
// able to break the whole visual suite before a single assertion runs.
//
// The leaf is unique per run. Playwright empties `outputDir` when a run starts,
// so a fixed path lets a second run wipe the first one's traces — and on Windows
// a still-open file turns that delete into a hard failure before any assertion
// runs. An explicit `CODEXU_VISUAL_SCRATCH_ROOT` still wins, for a caller that
// needs a known path.
const scratchRoot = (process.env.CODEXU_VISUAL_SCRATCH_ROOT
    || path.join(os.tmpdir(), 'codexu-visual', `${process.pid}-${Date.now()}`))
    .replace(/\\/g, '/');

// The port is fixed by default so a local run is reproducible, but a machine that
// already uses it (a leftover dev server, a second worktree) can move the suite
// instead of failing on `--strictPort`. Anything outside the usable range is
// ignored rather than handed to the dev server.
const requestedPort = Number.parseInt(process.env.CODEXU_VISUAL_PORT || '', 10);
const PORT = Number.isInteger(requestedPort) && requestedPort > 0 && requestedPort <= 65535
    ? requestedPort
    : 1421;

export default defineConfig({
  testDir: here,
  testMatch: '**/*.visual.spec.mjs',
  outputDir: `${scratchRoot}/test-results`,
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
      // Text-heavy panels cannot be byte-identical: a sub-pixel line box rounds
      // differently between runs and shifts glyph antialiasing plus the rounded
      // panel corners. Measured noise on a 1280x391 panel is 8 pixels with
      // Playwright's default colour threshold; the allowance below is ~100 pixels
      // there, still far below any real regression (a moved row, a missing badge
      // or a changed colour differs by hundreds to thousands of pixels).
      maxDiffPixelRatio: 0.0002,
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
