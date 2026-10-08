# AiGoodBro · AgentHub (2.2)

**See quota, usage and task occupancy at a glance; when needed, route local work through your own Codex account pool.**

AiGoodBro is a macOS AI workspace for personal use. It brings together quotas for multiple Codex accounts, token usage, local CLIs and public reset announcements, with an optional local proxy. The interface supports Chinese and English; its home page is called AgentHub.

[中文](README.md) | **English**

The current public GitHub installer is **2.2 · 1006v3**, with internal update version **9.6.80 (130)**. Home and the menu bar share the same all-time token and cost snapshot. It includes the unexpected-exit fix, an update dialog with release notes and downloads, and new/returning-user installation setup. After a detectable installation or replacement, new users get full setup; returning users review WeChat, Feishu and new settings while keeping existing preferences. See the [usage guide](docs/usage-guide.md) and [changelog](CHANGELOG.md).

[Download for Apple Silicon](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v9.6.80/AiGoodBro-9.6.80-mac-arm64.dmg) · [Release notes and alternate ZIP](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/tag/v9.6.80)

<p align="center">
  <img src="docs/images/1009v1/home-live.png" width="1000" alt="Live AiGoodBro home screenshot with reset announcements, token usage heatmap and trends, multi-account quota cards, and other connected tool states.">
</p>

*Home exported from the running local build 2.3.0 (137) on 2026-10-09. Values are a snapshot; the public download remains build 130. Click the image for its original size.*

## Features at a glance

**AiGoodBro is a macOS AI workspace that brings accounts, quotas, tasks and messages together.**

- **Multiple accounts on one page:** See remaining quota, reset times and task occupancy to know which account is ready to use.
- **Understand token consumption:** Usage totals, heatmaps, trends and cost estimates show which tools and models you use most.
- **Manage multiple tools:** View quota and status for connected tools such as Codex, Kimi, Grok and Claude Code. AiGoodBro includes Token Monitor, whose [latest upstream version](https://github.com/Javis603/token-monitor/blob/main/README.md) supports **token tracking for 35+ tools and quota detection for 28+ providers**. This version uses a pinned upstream with selected fixes; see [quota coverage](docs/local-cli-accounts.md) for the providers connected in AiGoodBro.
- **Route requests through your own account pool:** Enable the optional local proxy and set participating accounts, priority and call order. Changes stay synchronized between account cards and the proxy panel.
- **Invite friends from the workspace:** Send invitations in batches and view invitation status and referral credits. Rewards follow the provider's official requirements.
- **Help avoid unused reset cards expiring:** See the nearest expiry inline and hover for all expiry times. Opt in per account to use cards before expiry, with an adjustable default lead time of **30 minutes**.
- **Receive WeChat and Feishu reminders:** Configure quota, reset and reset-card messages. WeChat can also query status and continue a selected Codex conversation.
- **Show the sidebar when you need it:** Press **⌘I** to show or hide it, hover for details, or pin it with one click. View quota rings, proxy requests and account status, with optional trackpad haptics as the pointer moves between items.
- **Guided installation and updates:** New users receive full setup; returning users review WeChat, Feishu and new features. The update dialog shows changes and lets you download an installer; installation remains a user action.
- **An interface that fits your habits:** Chinese and English, multiple light and dark themes, and card or list layouts keep information clear and controls easy to find.

**Help avoid forgotten reset cards expiring unused.** Click an account’s reset-card count, nearest expiry date or information button to open its automatic-use settings. This is off by default and requires per-account opt-in. The default lead time is 30 minutes and can be adjusted. A desktop account uses an existing, verified independent entry for the same identity; missing entries, unknown task state or busy tasks pause the attempt. The app must remain running. Uncertain outcomes require review rather than automatic retries. See the [reset-card behavior and limits](docs/reset-credit-control.md).

**Interface documentation update · 1009v1:** Older screenshots, synthetic galleries and HTML mockups have been withdrawn from public display. A full live home screenshot and a user-provided sidebar crop are now included. As of 2026-10-09, the verified local installation is **2.3.0 (137)**; this build and later candidates have not been publicly released. Values reflect the moment of capture. The home image comes from local build 137; the sidebar crop does not show a build number. See [interface evidence and version scope](docs/public-ui-1008v1.md).

## See what is happening

Home shows each account's remaining quota, reset time and task occupancy. Public reset announcements stay distinct from an account's actual quota. Usage views summarize token, model and tool activity; estimated costs are based on local data, not provider bills.

Home supports resizable sections, cards and rows. The two reset panels share the available width and preserve the user’s chosen proportions.

Codex's isolated CLI can use its own local sign-in directory; support for other tools depends on the provider. Account cards and rows let you refresh quota, change order, choose a model or start an isolated CLI. See the [CLI quota coverage](docs/local-cli-accounts.md) for supported providers and limits.

The workspace shows quota and status for connected tools; availability depends on the tool and current sign-in. ZCode is a desktop tool, not a CLI. WorkBuddy desktop quota is currently unreadable. The Kimi CLI view shows its previous snapshot; refresh it before relying on the value.

The project workbench distinguishes execution from accepted outcomes and keeps remaining work and the original chat available.

## Sidebar and proxy status panel

<p align="center">
  <img src="docs/images/1009v1/proxy-status-edge-dock.png" width="360" alt="User-provided live UI screenshot showing the edge sidebar and expanded proxy status panel, with per-account quota rings, reset countdowns and credits.">
</p>

*User-provided live UI crop; account state, quota and credits reflect the moment of capture.*

The sidebar sits at the screen edge and shows selected account quotas, token statistics and other items. Choose ring or fish quota styles, press **⌘I** to show or hide it, hover for details, and drag the top to move it. Pins keep the sidebar visible or its detail panel on top.

Hover over the proxy item to open its status panel: see its running state, request count and account list, with **5h / 7d quota rings, reset countdowns and credit balances** for each account, plus a Proxy settings shortcut. Request snapshots update every minute; quota comes from the latest read. Unavailable quota appears as “—”.

On a trackpad that supports haptic feedback, entering or switching sidebar items gives a light tactile cue. Turn it off with **Trackpad haptics** in the sidebar settings.

## Setup guide: connect official tools and accounts

Follow the guide to sign in to an official tool or account, then return to the workspace to check its connection status. Connect each tool when you need it.

## Local proxy: route requests through your own account pool

The optional local proxy is a personal tool. Compatible clients send model requests to a service on this Mac; AiGoodBro selects an enrolled account by participation, priority and saved order. Available subscription quota across participating accounts is used before credits, and the current Desktop account is tried last in each quota phase.

Credit continuation is off by default. Only if the user enables it does the proxy enter credit phases after subscription quota is exhausted. Busy or unknown accounts do not count as exhausted. The credit threshold guides account selection between requests; it is not a per-request hard cap.

The proxy routes inference requests only. Codex Desktop keeps its OpenAI sign-in, each conversation's model and reasoning effort; using the proxy does not change system authentication files or global configuration. An already-running Codex process does not switch routes until it is restarted and connected again.

**Start and stop it yourself:**

1. Turn on the proxy manually in AiGoodBro. It does not start automatically when the app restarts.
2. Quit Codex. The **Connect Desktop** button appears only after the proxy starts successfully and its connection details are ready; choose it to relaunch Codex with the local route.
3. When finished, stop the service in the proxy panel. Closing the main window only hides it; quitting the app asks whether to stop the proxy. Reopen Codex normally after stopping it.

Once a streamed response has begun, an error is not replayed through another account. An uncertain result is not sent again automatically, avoiding duplicate task execution. The presence of proxy controls and the Connect Desktop entry does not prove end-to-end acceptance.

The proxy is designed for personal use with your own accounts and local tasks. This project does not provide accounts, credential sharing, quota resale or a public proxy service.

Personal WeChat uses the official Tencent iLink QR connection for reset notifications, cached status commands and explicitly enabled conversation in a chosen original Codex chat. The project workbench separates execution and outcome, preserving manual pause, cancellation, acceptance and remaining work. Normal display does not call a model; phone delivery and real conversation remain unaccepted. See the [WeChat and workbench guide (Chinese)](docs/wechat-workbench-0930v1.md).

## Nine themes and native glass

Choose a palette in Settings → Appearance. Each theme supports light and dark modes. Default keeps the neutral interface; other palettes share the native glass renderer with adjustable transparency and depth. macOS Reduce Transparency and Increase Contrast take precedence.

| Theme | Visual character |
|---|---|
| Default | Neutral gray with blue-violet accents; remains the default. |
| Liquid Keycap | Cool blue and cyan with light glass layers. |
| Blue & White Porcelain | Porcelain white and cobalt blue. |
| Monterey Dawn | Orchid purple, pink and warm dawn tones. |
| A Thousand Li of Rivers | Mineral green and blue. |
| Dunhuang Apsara | Sand gold, ochre and turquoise. |
| Forbidden City Red | Red walls, gold and deep contrasting surfaces. |
| Violet Glow | An independent glass variant of the existing default blue-violet tokens. |
| WAICY Sunset | A three-stop pink-to-orange gradient based on badge-candidate colors. |

Themes supply color tokens only. WAICY artwork, logos, mascots and fonts are not copied, and the palette does not imply official endorsement.

## Downloads and source builds

130 provides an Apple Silicon installer for macOS 13+. It is ad-hoc signed and has not been notarized by Apple. The update dialog displays the version and changes, downloads on click, then verifies the size and SHA256. The user completes replacement after opening the installer; downloading does not quit the app or install it automatically.

Wait for active work to finish and quit the old app normally before replacement. Keep backups of the old app and local data. Installation setup reviews WeChat, Feishu and new settings. Isolated tests and previews do not verify real reset-card redemption, message delivery or global hotkey interactions. See the [validation record and checksums](docs/release-notes-v9.6.80.md).

Source and installer correspond to `v9.6.80`:

```sh
git clone --branch v9.6.80 https://github.com/BLACKIELF/AgentHub-AiGoodBro.git AiGoodBro-2.2
cd AiGoodBro-2.2
```

Source builds require macOS, Go 1.26+ and the SHA256-verified Token Monitor v0.62.0 macOS runtime. Set `TOKEN_MONITOR_DESKTOP_RUNTIME` and `TOKEN_MONITOR_DESKTOP_DMG` to those official inputs before running `make build`. This release does not provide Intel or Windows installers; existing Windows sources remain intact. See the [historical 114 publication record](docs/source-publication-1003v1.md).

## Inspiration, code sources and licenses

Feature design borrows from related open-source projects. Code and resources directly reused or adapted are listed below, with their applicable licenses and copyright notices retained.

| Project | Relationship |
|---|---|
| [Tencent/openclaw-weixin 2.4.9](https://github.com/Tencent/openclaw-weixin/tree/24de5c9eb0dd5e595d7e2d090ed8a3f82870d42c) | Native adaptation of iLink protocol and QR pairing; MIT notice retained, without installing OpenClaw. |
| [codexU](https://github.com/shanggqm/codexU) | Second-developed host integration from the historical fixed source: SwiftUI, quota, palette and Windows foundations were inherited and are maintained by AiGoodBro. |
| [Token Monitor v0.62.0](https://github.com/Javis603/token-monitor/tree/dcccfb01557e2786888fd5479552f392ac6c0d32) | Second-developed native integration from the fixed upstream source: the statistics engine, dashboard, charts and resources remain bundled with the AiGoodBro bridge and Swift host. The local zero-quota fix and review of later releases are in the [current publication record](docs/source-publication-1003v1.md). |
| [Tokscale fork](https://github.com/Javis603/tokscale) · [original](https://github.com/junhoyeo/tokscale) | Second-developed native integration from the pinned revision; the collection foundation and license remain bundled as revision `06a9f1625d5a505f01b39eff29f7be44a2c52188`. |
| [CLIProxyAPI v8.0.2](https://github.com/router-for-me/CLIProxyAPI/tree/v8.0.2) | Host adapter over fixed upstream code: the SDK scheduler, Codex executor and Responses handler are reused, with a narrow adaptation of v8.0.7's pre-first-frame disconnect 502/failover behavior. The dependency was not upgraded wholesale. |
| [Codex-Manager](https://github.com/qxcnm/Codex-Manager) | Protocol adaptation and static research reference; the warm-up request structure and SSE completion rules are independently implemented in [`CodexAccountActions.swift`](Sources/CodexUsageWidget/Services/CodexAccountActions.swift#L850). |
| [Hazmat wrapper script](https://github.com/dredozubov/hazmat/blob/c112d222bb53e888dd17a8927927286792f7c20e/scripts/check-codex-desktop-attach-smoke.sh) | Protocol adaptation and static research reference for the `CODEX_CLI_PATH` stdio-wrapper entry point; no Hazmat sandbox or service is integrated. |
| [BlackHole1/aswap v1.1.0](https://github.com/BlackHole1/aswap/releases/tag/v1.1.0) | The Claude multi-account CLI/Chrome profile tool from the referenced X post; protocol adaptation and static research reference only, with no copied, bundled or Codex, Feishu or WeCom integration. |

AiGoodBro is licensed under [MIT](LICENSE). Full third-party license texts and copyright notices are in [`Resources/THIRD_PARTY_NOTICES.txt`](Resources/THIRD_PARTY_NOTICES.txt), [`Companion/LocalProxy/LICENSE.CLIProxyAPI`](Companion/LocalProxy/LICENSE.CLIProxyAPI), [`Companion/LocalProxy/LICENSE.Hazmat`](Companion/LocalProxy/LICENSE.Hazmat) and [`Companion/LocalProxy/THIRD-PARTY-NOTICES.txt`](Companion/LocalProxy/THIRD-PARTY-NOTICES.txt).

## More information

[Detailed guide (Chinese)](docs/usage-guide.md) · [CLI quota coverage](docs/local-cli-accounts.md) · [Proxy implementation and validation](docs/local-proxy-0928v1.md) · [Public build 130 release record](docs/release-notes-v9.6.80.md) · [Interface evidence and version scope](docs/public-ui-1008v1.md) · [Report an issue](https://github.com/BLACKIELF/AgentHub-AiGoodBro/issues) · [Security](SECURITY.md)

[MIT license](LICENSE) · [Third-party notices](Resources/THIRD_PARTY_NOTICES.txt) · [Brand compatibility](docs/brand-compat-0911v1.md)
