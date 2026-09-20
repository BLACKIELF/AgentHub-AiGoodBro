# Windows dashboard visual assertions

Rendered, locator-level screenshot assertions for the Windows dashboard, in a
browser context with **synthetic data only**.

This exists because `windows/AGENTS.md` requires reproducible rendered evidence
for UI changes, and because the existing `tests/*.test.mjs` files are
source-text contract tests — they cannot prove rendering or interaction.

## How it works

The dashboard refuses to render outside a Tauri runtime
(`src/utils/tauri.ts` → `requireTauriRuntime()`). Rather than weakening that
production guard, `tauri-stub.mjs` installs the same globals the real WebView
receives (`window.isTauri`, `window.__TAURI_INTERNALS__`) and answers the IPC
commands with `synthetic-fixtures.mjs`.

**No application source file is modified.** The real app keeps using the genuine
Tauri internals.

Determinism comes from:

- a fixed clock (`page.clock.setFixedTime`) so relative-time labels and trend
  cutoffs do not drift between days;
- an explicit `theme` in the fixture (no `prefers-color-scheme` dependency);
- an explicit `language` in the fixture (no `navigator.language` dependency);
- a fixed viewport, `timezoneId: 'UTC'` and `locale: 'en-US'`;
- `animations: 'disabled'` plus a zero pixel-diff tolerance.

## Running

```bash
cd windows/apps/codexu-tauri/web
npm run test:visual           # compare against local baselines
npm run test:visual:update    # (re)write baselines after an intended UI change
```

The config starts its own Vite server on `127.0.0.1:1421`; it does not reuse or
disturb a dev server on the default `1420`.

The default browser comes from the OS (`channel: 'msedge'`). On a machine without
Edge, install the locked Playwright Chromium and set `CODEXU_VISUAL_BROWSER=chromium`.
Keep each machine/browser's baselines local; do not compare Edge baselines to Chromium.

```bash
npx playwright install chromium
CODEXU_VISUAL_BROWSER=chromium npx playwright test --config tests/visual/playwright.config.mjs --update-snapshots=all profiles.visual.spec.mjs
CODEXU_VISUAL_BROWSER=chromium npm run test:visual -- profiles.visual.spec.mjs
```

## Artifacts stay local

Baselines, actuals, diffs and traces are written to
`<repo>/.local-artifacts/visual/`, which is Git-ignored at the repository root.
Never commit them. Any screenshot published outside this machine must be
regenerated from these synthetic fixtures — see `docs/windows-port/README.md`.

## Coverage

| Assertion | Locator |
|---|---|
| Header region | `header` |
| Account directories: selected, failed save, confirmed unlink | region `Account directories` |
| Overview (leadership + quota + metrics + monthly value) | `.dashboard-home-overview` |
| Tasks panel | `#dashboard-home-panel-tasks` |
| AI Leadership panel | `#dashboard-home-panel-leadership` |
| Usage panel | `#dashboard-home-panel-usage` |
| Projects panel | `#dashboard-home-panel-projects` |
| Skills panel | `#dashboard-home-panel-skills` |

A guard test also asserts that the synthetic bridge actually fed data into the
dashboard, so a blank or error shell cannot silently pass as a baseline.
Account-directory interactions also cover one-step stable ordering, cancelled folder selection,
draft retention on save failure, unlink confirmation, and late old-source responses.

## Not covered yet

- The Settings window (`windowLabel: 'settings'` — pass it through
  `installTauriStub`).
- Interaction states beyond tab switching (hover, focus rings, empty and error
  states).
- Light theme and non-default palettes.
- The native WebView2 surface itself; this runs in a browser context.
