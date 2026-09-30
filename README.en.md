# AiGoodBro 2.0 · AgentHub

**AiGoodBro 2.0** is a macOS workspace for Codex accounts, with **AgentHub** as its Home view. It brings account quota, token usage, and service health together, with an edge dock for checking today's usage and limits at a glance. Enable reset-message delivery and configure a Feishu bot to receive new public reset forecasts automatically, so you can plan tasks sooner and check the website less often. The menu bar opens usage, limits, trends and service health, with links back to account management and isolated CLIs. Upgrades preserve existing accounts and settings.

[中文](README.md) | **English**

![AiGoodBro 2.0 usage dashboard](docs/images/0927v6/dashboard.jpg)

> Captured from the installed app on 2026-09-27, showing token activity and model/tool rankings. Costs are estimates, not bills. [View the new workspace and screenshot notes](docs/images/0927v6/README.md).

Before starting work, answer four questions: how much quota remains, when it resets, whether the account is usable now, and how far the task has progressed.

AiGoodBro puts quota alerts and reset news first, so you can see when work can continue and choose the account to use.

| What you need | What AiGoodBro provides |
|---|---|
| Check remaining quota | Officially returned windows, including five-hour and weekly limits, with remaining percentages, reset times and snapshot timestamps. Alert thresholds are adjustable; unknown values stay “—”. |
| Review multi-agent usage | The pinned [Token Monitor v0.62.0](https://github.com/Javis603/token-monitor) desktop module provides its original Dashboard, heatmap, trends, model/tool rankings, icons, dimensions, fonts and glass styling. |
| Glance at usage and limits | Enable Edge Dock for today's tokens, estimated cost and provider quota rings at the screen edge. Hover for details, auto-hide or pin the rail, and drag it to move. The rate appears when measured performance samples are available. |
| Hear about resets | Public forecasts and completed announcements from [Codex Resets](https://codex-resets.com/), with publication times and source links. New forecasts can be sent automatically to a configured Feishu bot; account quota still needs its own refresh. |
| Check service health | The menu-bar Status view reads public Claude and OpenAI service summaries and marks stale snapshots. |
| Receive notifications | Native macOS notifications, optional Feishu alerts, and configurable Telegram / WeCom group bots. Permissions, configuration and supported event types apply to each channel; see below. |
| Switch accounts | Start a Desktop switch from an account card and follow preparation, graceful exit, write, relaunch and verification. Isolated CLIs can use other accounts independently. |
| Continue after low quota (in validation) | Controls for pausing at 1%, switching and continuing the original task are implemented. Integration and real end-to-end validation with the current Desktop are still in progress. Unknown task state blocks switching, and uncertain submissions are not repeated. |
| Coordinate and troubleshoot | Per-account CLI environments and model preferences, reservations before launch, task states, execution receipts and operational issue logs. |

A single account can use read-only monitoring. A public announcement, an account's recovered quota and its available reset credits are separate facts: an announcement neither spends a credit nor replaces an account refresh. The personal WeChat candidate uses Tencent’s official iLink connection for reset notifications, cached queries and the selected original Codex chat. WeCom remains independently configured. Phone receipt and live conversation acceptance still require QR pairing. [WeChat bot and project workbench](docs/wechat-workbench-0930v1.md).

**Installed: AiGoodBro 2.0 · 0930v2, version 9.6.37 (87).** Navigation sits in a left icon rail with a bottom settings menu. Compact account cards and rows preserve numbering, thin quota bars, reset times, credits and dispatch controls. The home calendar, bars and candlesticks reuse Token Monitor interactions, with model/tool details collapsed. ZCode Start Plan shows exact token balances; Kimi and Grok renew sessions to read quota, and TRAE CN displays personal credits. The proxy supports live order/priority changes and uses all enrolled subscription quotas before credits, leaving the Desktop account last within each phase. Native image generation and editing preserve the image model, prompt and references; uncertain failures are not replayed. CC Switch moylor is available to Claude CLI only. Build, signatures, CLI quota regressions, proxy/race regressions and isolated official app-server verification passed. The update is installed and the user starts the proxy manually; final UI regression and live proxy image generation acceptance remain pending. [Integration notes](docs/local-proxy-0928v1.md). No GitHub 2.0 download has been released.

**Local proxy and Desktop connection.** The optional proxy supports participation, priority and account ordering, reserves accounts per request and tries the next available account after quota exhaustion. Quit Codex, then choose Connect Desktop to reopen tasks with each conversation's model and reasoning effort. Desktop retains its OpenAI sign-in; only inference requests enter the local account pool. Authentication and global configuration files are unchanged. After stopping the proxy, reopen Codex normally; legacy tasks can continue after one resume through the repaired adapter. Isolated tests with the real app-server cover legacy recovery, workspace identity, ordinary resume after disabling the proxy and history listing. A 40 MiB image request, 40 MiB compaction request and 65 MiB Desktop message pass. Build 75 preserves the official signed process ancestry using exec and a separate gateway child; all three native peer-authorization fixtures pass without relaxing checks. Real Desktop-to-pool requests were verified on build80; build82 awaits the user's manual proxy startup and Desktop reconnection. WAICY large-message recovery and the earlier pause → switch → continuation flow still await real-task acceptance; this candidate is not merged into main or released. [Proxy integration record](docs/local-proxy-0928v1.md) · [Previous acceptance record](docs/source-snapshot-0927v6.md).

### Local proxy: personal use only

The local proxy is for personal use only, with your own accounts and tasks on your own machine. It does not provide credential sharing, quota resale, or a public proxy service for others.

On July 12, 2026, Tibo (@thsottiaux) wrote **“Step 1: Install CLIProxyAPI”** while explaining how to use GPT through Claude Code. [Original post](https://x.com/thsottiaux/status/2076119366647894371). This citation documents the technical background; it is not OpenAI's authorization of AiGoodBro or of other uses. Dependencies retain their own licenses and attribution.

The 2.0 candidate source is in [PR #13](https://github.com/BLACKIELF/AgentHub-AiGoodBro/pull/13); `main` does not yet include this integration. Check the version before building; an installation prompt and four task prompts are below.

[![CI](https://github.com/BLACKIELF/AgentHub-AiGoodBro/actions/workflows/ci.yml/badge.svg)](https://github.com/BLACKIELF/AgentHub-AiGoodBro/actions/workflows/ci.yml)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-111111?logo=apple)
[![MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Install it with your local agent

```text
Install or upgrade AiGoodBro from https://github.com/BLACKIELF/AgentHub-AiGoodBro. Read the README and check the system, dependencies and existing installation first. Record current settings, wait for the app's own operations to finish, move the old build to a dedicated rollback folder, then migrate to one AiGoodBro.app. Preserve accounts, dispatch participation, execution preferences and the current Codex sign-in. Verify the app name, running version and restored settings. Do not leave two launchable copies, terminate other CLI tasks, start real tasks, switch accounts or send notifications just to test the installation. Let me complete any official sign-in manually.
```

Requires macOS 13+, a working Codex sign-in and Xcode Command Line Tools. A single account can start with read-only monitoring. CLI launch and warm-up also require a configured local Hub and account mapping; those controls remain blocked when required evidence is missing. Setup checks existing Python 3.9+ and Codex CLI and can prepare the companion Skill. External Python and Codex are not bundled. Companion Hub setup requires a selected project and accounts and preserves existing services.

To build yourself:

```sh
git clone --branch main https://github.com/BLACKIELF/AgentHub-AiGoodBro.git
cd AgentHub-AiGoodBro
make build
```

Source builds also require Go 1.26+ to compile the local proxy against pinned CLIProxyAPI v8.0.2. The installed helper needs no external Go runtime. The complete desktop build also needs the verified official Token Monitor v0.62.0 macOS arm64 runtime, read from `/Applications/Token Monitor.app` by default. See the [integration record](docs/ai-goodbro-2.0-0927v5.md) for configuration and limitations.

The build result should be `build/AiGoodBro.app`. Building does not install or launch it. Back up the old build, then migrate to one `AiGoodBro.app` without leaving a second launchable copy. See the [compatibility map](docs/brand-compat-0911v1.md). Local builds use ad-hoc signing; no Apple-notarized 2.0 download has been published.

Future installer assets should use `AiGoodBro-<version>-mac-<arch>.dmg`. No 2.0 installer is currently available.

## Start with the workspace

![AiGoodBro 2.0 workspace with reset forecasts](docs/images/0927v6/workspace.jpg)

*Installed app, with account cards collapsed. Cache and unconfirmed states are shown as captured.*

Choose **Professional** or **Simple** at the top of Home. Professional starts with the full interface expanded. Simple offers Overview, Account cards, or Custom with four optional modules. These preferences affect presentation only; provider tabs retain their full controls. Overview preserves per-account status and shows “—” for unavailable quota. The native Settings window has Display & Icons, Menu Bar, Floating window, Automation, Workspace, Usage dashboard, and About sections.

![Current account cards rendered with synthetic data](docs/images/0910v1/02-workspace-cards-en-dark@2x.png)

See remaining 5-hour and weekly quota alongside reported reset times. A missing window shows “—”; the workspace preserves the limits actually returned by the official source. Switch between a compact list and cards without changing account order or behavior.

Home now lists accounts across providers in one sequence. Pin one account first; accounts with freshly verified reset cards expiring within 72 hours follow it and receive a red border. Cards and rows share that order. Grok card details remain unknown when the official response provides no card fields.

Refresh each account, set its model and open an isolated CLI environment. Saved preferences apply to subsequent tasks. New accounts default to **GPT-6 Astra / Low / Standard**; actual availability depends on the account and provider.

> Workspace screenshots are retained native renders of the 0910v1 production SwiftUI views using synthetic accounts, quota and dates. “Unverified” means that the demo is not connected to a Hub. The English header illustration is retained from 0909v4. [Image provenance and prompts](docs/images/0910v1/README.md)

> Images may show an earlier layout and are included only to introduce the interface. The [2.0 integration record](docs/ai-goodbro-2.0-0927v5.md) tracks current source and runtime verification.

## Usage Dashboard

Home places Agent navigation first, followed by public reset news, Token totals and signed-in accounts. Forecasts and completed announcements remain distinct, with publication time, explanation and source link. A forecast does not prove that an account's quota has returned. The menu bar opens Home, Tool, Status, Device, Model, Project, Session, Limits and Trends; service health uses public status summaries.

The default statistics mode uses pinned Token Monitor v0.62.0 collection and aggregation, shown in the bundled upstream dashboard with eight metrics, a 365-day heatmap, trends, and model and tool rankings. USD costs are estimates derived from local usage, not provider bills. Keep the previous custom mode for unsupported sources via Settings → Workspace → Statistics mode. Modes do not combine their totals. Historical account ownership and unavailable values remain unassigned rather than guessed.

The app bundles its statistics runtime and verified dependencies; installed statistics do not require a separate Node.js installation. A first source build must prepare the verified dependency cache. See the [2.0 integration record](docs/ai-goodbro-2.0-0927v5.md) for current integration and validation boundaries. Hub reading and publishing local usage are separate opt-in choices, both off by default; publishing also requires scope confirmation.

The default interface uses native frosted glass, supports Chinese and English, and respects the system's Reduce Transparency setting.

Settings → Edge Dock provides an independent screen-edge rail, showing Today, up to three connected limit providers, and `tok/s` by default. Hover for a detail card, click to pin the rail, or drag its top to move it. Auto-hide and always-visible modes are available. Add Total and other items in Settings; usage cards show exact token counts and tool/model breakdowns. Rates use actual output and duration increments from newly collected performance records; between collections, the dock may show the last sample or a dash.

## Choose a CLI, preset and message fields

The workspace can show installed Codex, Grok, Kimi Code, Claude Code, OpenCode, Gemini CLI, MiMo and ZCode environments. Link existing signed-in directories, name them and refresh their individual quota. See the [coverage table](docs/local-cli-accounts.md); ZCode supports identity-matched personal Coding Plan and Start Plan allowances, including exact model token counts. TRAE China personal credits are read from its current desktop session. MiMo quota and unreadable WorkBuddy desktop sessions remain explicit limitations; an installed tool alone does not prove a quota connection.

Three presets start with the saved model, Sol High with Luna Max children, and Luna Max directly. Names, main model, reasoning effort and child configuration are editable. Launches validate the effective settings and keep configuration separate from observed execution.

Feishu fields include the account label, quota, reset times, card count and nearest or all expiries. Agent name and reported balance are optional. The primary balance rounds to a whole number, with “≈” when rounded. Its details retain the exact reported value, source and time without inventing a currency or conversion.

The 9.6.36 candidate exposes a reset-card button directly on each independently signed-in account card. Two confirmations verify the account/card and authorize consuming one card with the stated reset effects; fresh identity, expiry and activity checks remain. Unknown outcomes preserve the original attempt and never trigger an automatic retry. Isolated confirmation tests and two explicitly authorized official redemptions have passed; the new button still awaits installed UI acceptance. See the [implementation boundary](docs/reset-credit-control.md).

Telegram and WeCom can be configured separately in Automation Center and default to off. Codex completion alerts require an observed running-to-completed transition; archived and initial historical snapshots do not trigger them. Credentials use AiGoodBro's isolated Keychain namespace. Offline tests do not prove delivery. [Channel details](docs/message-channels-0911v1.md)


## Stop watching the reset countdown

Five-hour and weekly warm-up have separate switches. AiGoodBro refreshes official quota first, checks identity and occupancy, then sends one minimal request when the checks pass.

AiGoodBro must remain running on an awake, connected Mac. Warm-up consumes quota. Busy accounts, exhausted weekly quota or uncertain state defer the attempt; failures are rechecked after a delay. A successful request followed by 100% remaining quota no longer causes repeated warm-up every minute.

Dispatch participation only controls new task eligibility. Excluded accounts still refresh and follow the global warm-up switches. Warm-up does not add quota or redeem reset credits.

## Reserve before starting

With the companion coordination protocol, a new call reserves its account and real project directory before environment checks and process launch. Other cooperating calls can read that reservation immediately; AiGoodBro refreshes its view roughly every ten seconds.

| State | Meaning |
|---|---|
| Online · preparing | Reserved; execution has not been proven |
| Online · running | Actual process or Hub execution evidence exists |
| Online · maintenance | Warm-up or an authorized maintenance reservation |
| Ended · awaiting acceptance | The process ended; its output still needs review |
| Unverified | Evidence is incomplete and occupancy remains blocked |

Concurrent reservations for the same account or real project directory are rejected. An expired heartbeat does not make an account idle. Observations, fixes and verification are appended with dates to one issue journal, accessible from the workspace.

AiGoodBro's Terminal button registers occupancy and waits for a private launch receipt. Exit code zero only means that the session ended. The companion Hub checks shared occupancy when creating and approving tasks; older CLI entry points and older Hub builds still require process checks. AiGoodBro does not adopt those sessions. [Protocol and integration requirements](docs/dispatch-coordination.md)

## Receive public reset announcements

“Receive reset updates” is on by default. While AiGoodBro is running, it checks [Codex Resets](https://codex-resets.com/) every five minutes without consuming account quota, choosing an account or configuring Feishu. The first check establishes a baseline without sending old announcements. Later updates use macOS notifications, subject to system permission. With Feishu forwarding enabled and a bot configured, AiGoodBro also sends newly published forecasts automatically, helping you plan tasks and check the website less often.

“Reset updates” is the first section in the workspace's Automation center. Read the latest update there even without notification permission. Expand “Also send to Feishu (optional)” only if you want that delivery channel. Upgrades preserve an existing off setting.

Cards show 5-hour and 7-day limits side by side, with three columns available at the 820-point minimum window width. Common actions stay below the limits; detailed warm-up and reset records remain in Details.

Feishu uses the pool code and account label. Connection tests, manual switches, restart tests and automatic low-limit events carry distinct reasons; low-limit alerts show only the condition that was actually met.

Connect Feishu directly in Getting started. For a saved bot, choose Authorize connection when permission is needed. Enter your login password only in the macOS dialog; choose Always Allow, if offered, to remember access. Background checks stay silent. A replaced local ad-hoc build may need authorization again.

![Automation center rendered with synthetic state](docs/images/0910v1/04-automation-center-en-dark@2x.png)

This is a third-party public feed. An announcement does not prove that your account has reset and does not redeem a reset credit. Verify quota and available credits through the official account refresh.

The clock beside dispatch participation sets allowed or excluded times, weekdays and an IANA time zone, including intervals across midnight. It only controls new tasks; refresh and warm-up keep their own switches. The companion Skill enforces these windows. Equivalent Hub API protection requires the matching Hub build.

## Follow Desktop switch progress

The Desktop switch button immediately shows preparation progress. You can cancel while waiting for an existing refresh. Identity and quota checks run concurrently in the background, followed by visible closing, switching, opening and verification stages. Both identities remain reserved for maintenance throughout the transaction.

Changing the actual identity still requires Codex to exit and reopen. Network and process state affect the duration. An ordinary switch does not silently force termination after a timeout; forced switching requires the explicit warning. Finish active work before changing accounts.

## Four prompts to use after setup

Give these to an agent with the necessary local tools and configuration. They are not a built-in chat interface in AiGoodBro.

**1. Check before work**

```text
Read AiGoodBro's current 5-hour and weekly remaining quota, reset times in my time zone, task occupancy and execution preferences. Distinguish fresh evidence, old snapshots and unknown state. Do not start a task.
```

**2. Use a specific account**

```text
Use account A for the currently authorized task. Verify the required tools, project directory and identity; reserve the account as soon as preparation starts, then refresh quota and check occupancy. Use AiGoodBro's saved execution preferences and do not silently substitute another account. Collect and validate the output as soon as execution ends, then release the reservation.
```

**3. Diagnose missing warm-up**

```text
Check AiGoodBro's warm-up switches, recent success and failure records, official reset times, weekly quota and occupancy. Append the findings with today's date to the same issue journal. Start with the smallest diagnostic check instead of repeatedly sending real warm-up requests.
```

**4. Restore settings after an upgrade**

```text
Record AiGoodBro's settings, account order, participation and model preferences before upgrading. Wait for existing calls to finish, reserve the accounts for maintenance, back up the old build and migrate to one AiGoodBro.app. Verify the name and version, restore settings and admission controls, and release all maintenance reservations. Do not start test tasks.
```

## Defaults for a new installation

| Setting | Default |
|---|---|
| Language, layout, appearance | Chinese, list, system appearance, standard palette |
| Menu bar | Classic, weekly remaining quota, no reset countdown |
| Shortcut | ⌘U |
| New account execution | GPT-6 Astra / Low / Standard |
| Window maintenance | Five-hour and weekly warm-up enabled |
| Alerts | Reset updates, low quota, local notifications, Feishu and both quota event options enabled |
| Low quota thresholds | 5-hour ≤5%; weekly <10%, independently adjustable |

Saved choices take precedence, including disabled features. New users still receive onboarding. Local notifications require macOS authorization; Feishu requires a configured robot. An enabled switch does not prove delivery. New accounts participate in dispatch by default; existing participation choices are preserved.

## Version 2.0 and validation

Version 2.0 integrates the original Usage Dashboard, all nine menu-bar views, and Edge Dock for usage and quota, public Claude and OpenAI status views, and optional automatic Feishu delivery for new public reset forecasts. Agent and tool marks reuse upstream artwork consistently while the application keeps its AiGoodBro name and icon. It pins Token Monitor v0.62.0 source and runtime dependencies while retaining account, switching, CLI, and automation workflows. The interface supports Chinese and English, native frosted glass, and Reduce Transparency.

The [0927v5 record](docs/ai-goodbro-2.0-0927v5.md) distinguishes local tests, installation, and runtime behavior still unverified. A full official reset cycle, multiple CLI sign-ins and real calls, Desktop switching, and notification delivery need separate evidence. No real notification or account switch was performed for this validation.

The existing packaging flow plans to include `Companion Skill/multi-agent-management` and Chinese instructions in both Mac installers. There is no 2.0 Release installer; the release wrapper must verify its contents if one is made. Compare and back up an existing Skill, preserving personal configuration. Installing the Skill does not configure a Hub.

[2.0 integration record](docs/ai-goodbro-2.0-0927v5.md) · [V1.0 history](docs/release-notes-v9.6.1.md) · [Changelog](CHANGELOG.md) · [Dispatch Skill instructions (Chinese)](.agents/skills/multi-agent-management/使用说明.md) · [Detailed guide (Chinese)](docs/usage-guide.md)

## The rest of the workspace

Single-account menus, full PNG exports, labels and ordering, model and reasoning selection, Standard/Fast, apply-to-all preferences, isolated Chrome sign-in, explicit Desktop switching, low-quota suggestions, Feishu alerts, palettes and workspace settings remain available.

AiGoodBro is an independent third-party open-source project. It does not supply accounts or increase quota. An isolated CLI leaves the current Desktop sign-in unchanged; explicit Desktop switching uses a separate identity transaction. Webhooks are stored in an isolated Keychain namespace. Remove credentials, account details, task content and private paths before sharing diagnostics.

Development checks:

```sh
make build
scripts/run-self-tests.sh --skip-build --build-dir build
python3 tests/test_dispatch_activity.py
python3 tests/test-dispatch-activity-interop.py
make test-macos-compatibility
make memory-risk-check
git diff --check
```

This update targets macOS. Windows sources remain in the repository and were not validated for this version.

[Report an issue](https://github.com/BLACKIELF/AgentHub-AiGoodBro/issues) · [Security](SECURITY.md) · [Brand compatibility](docs/brand-compat-0911v1.md) · [Design](docs/DESIGN_SYSTEM.md) · [MIT license](LICENSE) · [Third-party notices](Resources/THIRD_PARTY_NOTICES.txt)
