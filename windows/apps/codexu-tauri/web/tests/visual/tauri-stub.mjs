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

let nextStubRevision = 0;

/**
 * Installs the synthetic bridge before any page script runs.
 *
 * @param {import('@playwright/test').Page} page
 * @param {{ settings: unknown, dashboard: unknown, windowLabel?: string }} payload
 * @param {() => void} [customize] Runs after the base bridge in the same init script.
 */
export async function installTauriStub(page, { settings, dashboard, windowLabel = 'main' }, customize = () => {}) {
  const revision = ++nextStubRevision;
  const initialize = ({ settingsPayload, dashboardPayload, label }) => {
      const callbacks = new Map();
      let nextCallbackId = 1;
      const statistics={phase:'idle',revision:0,contextKey:null,sources:[],timezone:null,snapshot:null,tokenRate:null,failureCode:null};

      const responses = {
        list_profiles: [],
        list_managed_accounts: [],
        list_claude_subscriptions: [],
        // Synthetic platform catalogue: one managed platform, one that only
        // supports its default directory, and the Antigravity desktop adapter.
        list_platforms: [
          { id: 'codex', name: 'Codex', command: 'codex', default_directory: 'C:\\Synthetic\\.codex', isolation: 'managed', quota_supported: true, desktop: false },
          { id: 'claude_code', name: 'Claude Code', command: 'claude', default_directory: 'C:\\Synthetic\\.claude', isolation: 'managed', quota_supported: false, desktop: false },
          { id: 'gemini', name: 'Gemini CLI', command: 'gemini', default_directory: 'C:\\Synthetic\\.gemini', isolation: 'default_only', quota_supported: false, desktop: false },
          { id: 'antigravity', name: 'Antigravity', command: 'antigravity', default_directory: 'C:\\Synthetic\\Antigravity', isolation: 'unsupported', quota_supported: true, desktop: true },
        ],
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
          if(cmd==='set_token_monitor_timezone'){statistics.timezone=args.timezone;return structuredClone(statistics);}
          if(cmd==='get_token_monitor_state'||cmd==='refresh_token_monitor_usage'||cmd==='set_token_monitor_sources')return structuredClone(statistics);
          if(cmd==='cancel_token_monitor_usage'){statistics.phase='stopped';statistics.revision++;return structuredClone(statistics);}
          // Event subscription plumbing used by `@tauri-apps/api/event`.
          if (cmd === 'plugin:event|listen') {
            return nextCallbackId++;
          }
          if (cmd === 'plugin:event|unlisten') {
            return undefined;
          }
          if (cmd === 'get_account_workflow') {
            return { profile_id: args.id, preference: { participating: false, model: null, effort: null, revision: 0 }, phase: 'idle', started_at: null, supported: true };
          }
          if (Object.prototype.hasOwnProperty.call(responses, cmd)) {
            return responses[cmd];
          }
          // Commands the dashboard fires without awaiting a result
          // (`sync_runtime_language`, `clear_cache`, tray helpers, ...).
          return undefined;
        },
      };
  };
  // Playwright does not order separate init scripts. Install the base bridge and
  // its dependent fixture atomically, and keep the latest explicit page setup
  // when a test changes window labels before navigating again.
  await page.addInitScript({ content: `
    if ((window.__codexuSyntheticStubRevision || 0) < ${revision}) {
      window.__codexuSyntheticStubRevision = ${revision};
      (${initialize.toString()})(${JSON.stringify({ settingsPayload: settings, dashboardPayload: dashboard, label: windowLabel })});
      (${customize.toString()})();
    }
  ` });
}
