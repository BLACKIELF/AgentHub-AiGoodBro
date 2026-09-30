# AiGoodBro Token Monitor Desktop host adapter

This directory adapts the pinned Token Monitor v0.62.0 Electron desktop app for inclusion inside AiGoodBro. The renderer, preload, Edge Dock, visual geometry, provider icons, and collectors remain upstream code. The adapter is applied **only to a disposable packaging stage**; it never edits `../TokenMonitorEngine/upstream` or the independently installed original app. Preserve upstream MIT notices and third-party licenses in the helper package.

The packager stages upstream `src/`, `assets/`, and its native Node module closure at their original relative paths, copies `bootstrap.cjs` and `hostBridge.cjs` to `aigoodbro/`, sets `package.json.main` to `aigoodbro/bootstrap.cjs`, substitutes AiGoodBro's existing `Resources/AiGoodBro-icon.png` for the staged `assets/icon.png`, then runs:

```sh
node Companion/TokenMonitorDesktop/transform-stage.cjs /absolute/staging/app/root
```

The transformer checks exact pinned SHA-256 inputs and single anchors before writing any staged file. It exposes the original Home, all nine views, Dashboard, and Settings; gives the original tray AiGoodBro branding and native-workbench actions; disables upstream self-update and helper-only login startup; and routes Codex account switching to the native AiGoodBro transaction guard. The original floating Settings overlay links to the AiGoodBro workbench, Accounts & auto-resume, and app settings through the existing private host socket. Its update button calls the native host's `checkForUpdates` action; a successful handoff hides the floating window so the native destination is visible, and the menu bar reopens its original Home. Original CSS dimensions and provider SVGs are unchanged. The packaging script must rebuild ASAR integrity, sign the complete nested app, and verify it before installation.

Clickable product links in the staged UI point to [AiGoodBro's website](https://aigoodbro.com/) and [repository](https://github.com/BLACKIELF/AgentHub-AiGoodBro). About-page feedback opens the repository's `/issues` page, while the help link opens `docs/usage-guide.md`; this replaces the original WSL-specific guide link with the available AiGoodBro guide. Discord Rich Presence's repository button also points to AiGoodBro, although its registered Discord client ID remains upstream's. The embedded updater stays disabled, so its repository metadata cannot start an independent update. Provider APIs, status pages, TokScale attribution, network referers, and upstream MIT/third-party license notices retain their original URLs and ownership.

The Swift host starts the helper directly from its own bundle with these environment variables:

| Name | Value |
| --- | --- |
| `AIGOODBRO_TOKEN_MONITOR_EMBEDDED` | `1` |
| `AIGOODBRO_TOKEN_MONITOR_USER_DATA` | Existing or newly created private `TokenMonitorDesktop` support directory, mode 0700 |
| `TOKEN_MONITOR_SHARED_DIR` | Private `shared` child, mode 0700 |
| `TOKEN_MONITOR_DEVICE_ID` | Stable, AiGoodBro-specific identifier |
| `AIGOODBRO_TOKEN_MONITOR_SOCKET` | New short AF_UNIX path in a session-private 0700 directory |
| `AIGOODBRO_TOKEN_MONITOR_HOST_SOCKET` | Native host's 0600 AF_UNIX socket in that directory |
| `AIGOODBRO_TOKEN_MONITOR_PARENT_PID` | Direct Swift host process ID |
| `AIGOODBRO_TOKEN_MONITOR_LANGUAGE` | Optional `zh-CN` or `en`, applied only when upstream settings have no saved language |

Swift sends one JSON line per connection to the helper socket: `{ "id": "uuid", "cmd": "showHome" }`. `showSettings` optionally accepts an allowlisted `section` (`menuBar` or `floatingBubble`) to expand and focus the corresponding controls. The native host owns the right-side dock and its proxy activity; the embedded dock stays off, and its settings link opens the native dock settings. Previous dock visibility, order and placement migrate once without replacing later native edits. Commands are `showDashboard`, `showHome`, `showSettings`, `showView` with one of `home/tool/status/device/model/project/session/limits/trends`, `status`, and `quit`. Replies echo `id` and include `ok`; `status` includes `ready`, actual `trayVisible`, `pid`, and `version`. The native tray remains available if the upstream tray is hidden. The helper creates a 0600 socket, limits messages to 4096 bytes, rejects unknown commands/fields, and exits when its parent process disappears.

If Launch Services opens the nested helper directly with no embedded environment, bootstrap verifies the fixed helper/parent bundle layout, both bundle IDs and executables, then opens that exact parent AiGoodBro app and exits before loading upstream. Partial, unknown, or forged embedded environment data exits without creating a renderer. Normal launches still require the direct native parent PID and executable, private data directories, and private sockets.

The helper sends only allowlisted actions to the native host socket: `openWorkbench`, `openAccounts`, `openTasks`, `openSettings`, `checkForUpdates`, `quitHost`, `getManagedCodexAccounts`, and `switchCodexAccount`. The managed-account response contains opaque IDs, composite `sha256:` identity keys, workspace IDs, private home paths, and display aliases; no email or token enters that response, and imported accounts render their aliases. The helper rechecks each local auth identity, keeps these records in memory, and refreshes the original limits collector before opening views. Host-owned account creation and management return to AiGoodBro. The switch request contains only an upstream managed-account ID and its identity key. The native host independently matches that key to a current local profile and runs the existing guarded transaction. A missing or mismatched confirmation fails; Electron never writes the system Codex authentication file in embedded mode.

The original macOS WidgetKit extension needs AiGoodBro-owned signing and App Group entitlements. Until those are available, packaging keeps the original extension in a non-active archive, and embedded runtime skips its registration and snapshot publication. The original Electron Home, dashboard and floating bubble remain enabled; the native Edge Dock provides the account and proxy rail.

Run focused adapter checks with `node --test Companion/TokenMonitorDesktop/test/desktop.test.cjs`. These cover direct-open recovery without a real system launch, trusted and invalid embedded startup, permissions, routes, fail-closed account forwarding, exact staging hashes, syntax, and branded asset paths. Full Electron runtime, widget signing, and native UI must also pass packaging and live app verification; this test suite alone does not establish them.
