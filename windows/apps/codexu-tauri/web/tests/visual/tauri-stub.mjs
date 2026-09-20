// Synthetic Tauri bridge for browser-context visual assertions.
//
// The dashboard refuses to render outside a Tauri runtime (see
// `src/utils/tauri.ts`). Instead of weakening that production guard, this
// helper installs the same globals the real WebView receives
// (`window.isTauri` and `window.__TAURI_INTERNALS__`) and answers the IPC
// commands with synthetic fixtures.
//
// Production code paths are untouched: the real app still goes through the
// genuine Tauri internals.

/**
 * Installs the synthetic bridge before any page script runs.
 *
 * @param {import('@playwright/test').Page} page
 * @param {{ settings: unknown, dashboard: unknown, windowLabel?: string }} payload
 */
export async function installTauriStub(page, { settings, dashboard, windowLabel = 'main' }) {
  await page.addInitScript(
    ({ settingsPayload, dashboardPayload, label }) => {
      const callbacks = new Map();
      let nextCallbackId = 1;

      const responses = {
        list_profiles: [],
        get_settings: settingsPayload,
        set_settings: settingsPayload,
        get_local_usage: dashboardPayload,
        refresh_usage: dashboardPayload,
      };

      // `@tauri-apps/api` reads these two globals directly.
      window.isTauri = true;
      window.__TAURI_INTERNALS__ = {
        metadata: {
          currentWindow: { label },
          currentWebview: { label },
        },
        transformCallback(callback, once = false) {
          const id = nextCallbackId++;
          const key = `_${id}`;
          window[key] = (payload) => {
            if (once) {
              delete window[key];
              callbacks.delete(id);
            }
            return callback(payload);
          };
          callbacks.set(id, window[key]);
          return id;
        },
        async invoke(cmd, args) {
          // Event subscription plumbing used by `@tauri-apps/api/event`.
          if (cmd === 'plugin:event|listen') {
            return nextCallbackId++;
          }
          if (cmd === 'plugin:event|unlisten') {
            return undefined;
          }
          if (Object.prototype.hasOwnProperty.call(responses, cmd)) {
            return responses[cmd];
          }
          // Commands the dashboard fires without awaiting a result
          // (`sync_runtime_language`, `clear_cache`, tray helpers, ...).
          return undefined;
        },
      };
    },
    { settingsPayload: settings, dashboardPayload: dashboard, label: windowLabel },
  );
}
