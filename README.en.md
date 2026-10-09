# AiGoodBro · AgentHub (2.4)

**See quota, usage and task occupancy at a glance; when needed, route local work through your own Codex account pool.**

AiGoodBro is a macOS AI workspace for personal use. It brings together quotas for multiple Codex accounts, token usage, local CLIs and public reset announcements, with an optional local proxy. The interface supports Chinese and English; its home page is called AgentHub.

[中文](README.md) | **English**

This release is **2.4 · 1009v2**, with update version **2.4.0 (141)**. Compared with public 9.6.80 (130), it upgrades the bundled usage and proxy engines, adds Claude subscription accounts and independent quota rings, and makes account rows more compact. Home, the floating bubble and sidebar share cached TPM. Reset-card controls and new/returning-user setup remain available. See the [2.4 release notes](docs/release-notes-v2.4.0.md), [usage guide](docs/usage-guide.md) and [changelog](CHANGELOG.md).

[Download Apple Silicon DMG](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v2.4.0/AiGoodBro-2.4.0-mac-arm64.dmg) · [Alternate ZIP](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v2.4.0/AiGoodBro-2.4.0-mac-arm64.zip) · [GitHub Release](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/tag/v2.4.0)

[Overview](#overview) · [Accounts](#accounts) · [Usage](#usage) · [Proxy](#proxy) · [Reset cards and messages](#messages) · [Sidebar](#dock) · [Setup](#setup) · [Themes](#themes) · [Downloads](#downloads) · [Sources and docs](#sources)

<a id="overview"></a>

## 01 · Workspace overview

Home brings accounts, quotas, token usage, reset announcements and connected tools together. Remaining quota, reset times and task occupancy are shown separately. Public announcements stay distinct from actual account limits, and costs are local estimates. Resize sections, switch between cards and rows, and adjust the shared width of reset panels; your chosen proportions are saved.

<p align="center">
  <a href="docs/images/1009v1/home-live.png"><img src="docs/images/1009v1/home-live.png" width="1000" alt="Live AiGoodBro build 137 home screenshot with reset announcements, token usage heatmap and trends, multi-account quota cards, and other connected tool states."></a>
</p>

*All images are original live UI captures. The published home image was captured from installed 2.3.0 (137) on 2026-10-09. New sign-in, setup and settings images were captured from 2.3.0 (139) that day; 2.4 retains the same presentation of those settings. The user-provided sidebar crop shows no build number. Build 141 is not installed; values reflect capture time and do not establish a build 141 upgrade or real-call acceptance. Click an image for its original size; see the [source and checksum record](docs/public-ui-1009v2.md).*

**Changes since public build 130**

- **Updated usage statistics:** Pinned Token Monitor 0.68.0 and TokScale 4.18.0 update parsing and pricing and fix duplicate and cached Claude tokens. Usage, model, project, session, limits and trend views remain available.
- **Claude subscriptions together:** Sign in through the official Claude Code CLI, then explicitly save the current subscription. Link existing Claude-swap subscriptions and switch manually. Separate rings show 5-hour and 7-day limits; independent model limits use only names and values actually returned by the API.
- **Adjust the running proxy queue:** CLIProxyAPI moves to 8.0.20. Disabling participation skips admissions still waiting or retrying; admitted responses finish. Priority, Use last, ordering and credit floors stay synchronized with the account page.
- **Shared TPM and compact layouts:** Home, the floating bubble footer and sidebar reuse existing token samples. Account rows place adjacent 5h / 7d rings to the right of account details, keep invitations as a small icon and use two rows of controls. Chinese reset-card, available-credit and available-amount labels are clearer.
- **Sidebar and setup improvements:** Sidebar sizes, 75–150% scaling, optional refresh controls and running indicators are available. Manual Claude setup keeps its progress separate from installation setup, and Claude cards respect the card-size setting.

Build 141 also fixes Claude subscription unlinking and expired-target switching, Grok session titles, proxy failure messages and lease cleanup after a child exits. See the [five fixes and validation boundaries](docs/release-notes-v2.4.0.md#english).

Six separate feature captures: [Claude sign-in](docs/images/1009v2/claude-login.jpg) · [Tool setup](docs/images/1009v2/guide.jpg) · [Reset-card settings](docs/images/1009v2/reset-auto.jpg) · [WeChat / Feishu setup](docs/images/1009v2/notifications-guide.jpg) · [Sidebar settings](docs/images/1009v2/edge-dock-settings.jpg) · [Appearance settings](docs/images/1009v2/appearance-settings.jpg). All are from installed build 139. Accounts and usage still reuse the published build 137 home image below; separate live captures remain pending.

The illustrated sections below explain each feature. Use [setup](#setup) to connect tools and review settings; viewing an introduction does not enable optional features.

<a id="accounts"></a>

## 02 · Codex and Claude accounts

**Multiple accounts on one page.** Codex cards and rows show remaining quota, reset times, credits, reset cards and task occupancy, with refresh, ordering, model selection and isolated CLI controls. The 5-hour and 7-day limits are separate. Participation, Priority and Use last settings stay synchronized with the proxy panel.

<p align="center">
  <a href="docs/images/1009v1/home-live.png"><img src="docs/images/1009v1/home-live.png" width="1000" alt="Previously published live build 137 home capture, including Codex account cards, quotas, reset times and controls."></a>
</p>

*The previously published build 137 home image illustrates the account section. Its values reflect capture time and do not verify the new 2.4 account layout.*

Known limitation: the Proxy / Scheduling / Priority / Use last controls can become cramped in the dedicated Codex page at narrow window widths in list mode. A fix is deferred to the next version; use cards or widen the window for now.

**Connect Claude subscriptions through the official flow.** Sign in through the official Claude Code CLI. After identity verification, choose **Add signed-in account** / **Save subscription**. Link existing Claude-swap subscriptions; saved subscriptions support manual switching and quota refresh. Before adding another account, save the current subscription, sign in to the other account in the official CLI, then return to add it. Do not use `/logout` first, as it may invalidate saved credentials.

Claude's 5-hour, 7-day and API-returned independent model limits appear as separate rings under the returned names. Missing limits stay unknown, and previous snapshots are labeled. Quota and local Token statistics remain separate, and Claude cards respect the card-size setting.

<p align="center">
  <a href="docs/images/1009v2/claude-login.jpg"><img src="docs/images/1009v2/claude-login.jpg" width="1000" alt="Live build 139 Claude account page and official sign-in entry."></a>
</p>

*Complete official CLI sign-in, then return to save the current subscription. Displaying the sign-in entry does not prove successful sign-in or a quota read.*

Other tools are read according to provider capabilities; connection state and quota-read results are separate. ZCode is a desktop tool. WorkBuddy desktop quota is currently unreadable. Kimi CLI shows its previous snapshot; refresh it before relying on the value. See [native CLI quota coverage](docs/local-cli-accounts.md).

<p align="center">
  <a href="docs/images/1009v2/guide.jpg"><img src="docs/images/1009v2/guide.jpg" width="1000" alt="Live build 139 tool setup showing Kimi Code with authentication configuration detected."></a>
</p>

*Kimi Code shows authentication configuration detected. This setup image does not prove a successful Kimi quota read. Previous quota snapshots are for reference; refresh before use.*

<a id="usage"></a>

## 03 · Token usage, heatmaps and trends

**Bundled Token Monitor: token tracking for 35+ tools and quota detection for 28+ providers.** These figures come from the pinned [Token Monitor 0.68.0 feature list](Companion/TokenMonitorEngine/upstream/README.md#features). Its overview lists 43 tools; 35 table entries support token tracking and 28 support quota reads. The figures describe upstream coverage. Actual local connections depend on the tool, sign-in, provider response and embedded host policies; check the state shown in the interface.

The usage dashboard summarizes all-time tokens, estimated cost, activity heatmaps and trends, with views by tool, device, model, project or session. Session details and export retain their existing statistics controls. Costs come from local records and pricing estimates; they are not provider bills.

The usage section in the live home image shows totals, the heatmap and trends. Open usage from the sidebar or menu bar for more detailed views, then choose a tool or model and time range to inspect the currently read data.

<p align="center">
  <a href="docs/images/1009v1/home-live.png"><img src="docs/images/1009v1/home-live.png" width="1000" alt="Previously published original live build 137 home capture, including all-time token totals, the heatmap and trends."></a>
</p>

*The published build 137 home image is repeated to illustrate the usage section. Usage reflects local records at capture time; 35+ / 28+ describe upstream support.*

Home and the menu bar share the same all-time snapshot. Home, the floating bubble footer and sidebar share cached token consumption per minute (TPM), with consistent units and formatting and no extra scans. Token Monitor 0.68.0 and TokScale 4.18.0 update parsing and pricing and fix duplicate and cached Claude tokens. Previously read quotas can appear before history finishes; unfinished usage stays unknown.

<a id="proxy"></a>

## 04 · Local proxy and account queue

<p align="center">
  <a href="docs/images/1009v1/proxy-status-edge-dock.png"><img src="docs/images/1009v1/proxy-status-edge-dock.png" width="360" alt="Previously published user-provided live proxy status and sidebar image, with no visible build number."></a>
</p>

*This published user-provided image shows proxy state, account limits and a settings entry; its build is unknown. It does not establish build 141 installation or real-request acceptance.*

The optional local proxy is a personal tool. Compatible clients send model requests to a service on this Mac; AiGoodBro selects an enrolled account by participation, Priority / Normal / Use last groups and saved order. Pro20x defaults to Use last and can be changed; the current Desktop account is a fallback within its group. Available subscription quota across participating accounts is used before credits.

Participation can be disabled while the proxy runs. Admissions still waiting or retrying then skip that account; admitted responses finish. Priority, Use last and ordering apply to new requests, stay synchronized with the account page, and retain credit permissions and floors. Invalid admissions that have been rolled back do not keep waiting on the same abandoned reservation.

Credit continuation is off by default. Only if the user enables it does the proxy enter credit phases after subscription quota is exhausted. Busy or unknown accounts do not count as exhausted. The credit threshold guides account selection between requests; it is not a per-request hard cap.

The proxy routes inference requests only. Codex Desktop keeps its OpenAI sign-in, each conversation's model and reasoning effort; using the proxy does not change system authentication files or global configuration. An already-running Codex process does not switch routes until it is restarted and connected again.

**Start and stop it yourself:**

1. Turn on the proxy manually in AiGoodBro. It does not start automatically when the app restarts.
2. Quit Codex. The **Connect Desktop** button appears only after the proxy starts successfully and its connection details are ready; choose it to relaunch Codex with the local route.
3. When finished, stop the service in the proxy panel. Closing the main window only hides it; quitting the app asks whether to stop the proxy. Reopen Codex normally after stopping it.

Once a streamed response has begun, an error is not replayed through another account. An uncertain result is not sent again automatically, avoiding duplicate task execution. The presence of proxy controls and the Connect Desktop entry does not prove end-to-end acceptance.

Build 141 distinguishes gateway connection refusal, timeout, cancellation and general forwarding failures, while retaining HTTP 503 and no automatic reconnection. Lease cleanup for a confirmed exited child retries briefly when its lock is busy, while protecting a new run and active children.

A user-reported proxy fault required a restart to recover during this round. Its cause is still under investigation. These two fixes do not establish that every cause of that fault is covered. Recovery after a restart does not establish a permanent fix, and this validation does not guarantee stability of the real proxy path.

The proxy is designed for personal use with your own accounts and local tasks. This project does not provide accounts, credential sharing, quota resale or a public proxy service.

<a id="messages"></a>

## 05 · Reset cards, invitations, WeChat and Feishu

**Help avoid unused reset cards expiring.** The nearest expiry appears beside the account; hover for all expiry times. Click the reset-card count, expiry date or information button to open automatic-use settings. This is off by default, requires per-account opt-in and has an adjustable default lead time of **30 minutes**.

A desktop account uses an existing, verified independent entry for the same identity. Missing entries, unknown task state or busy tasks pause the attempt. Keep the app running; uncertain outcomes require review and block automatic retries. Opening settings does not redeem a card. See [reset-card behavior and limits](docs/reset-credit-control.md).

<p align="center">
  <a href="docs/images/1009v2/reset-auto.jpg"><img src="docs/images/1009v2/reset-auto.jpg" width="820" alt="Live build 139 automatic-use settings for expiring reset cards."></a>
</p>

*Choose accounts and adjust the lead time. The pictured 25 minutes is a local custom setting; the product default remains 30 minutes. Automatic use requires the user's choice.*

**Handle invitations together.** Send invitations in batches and view invitation status and referral credits. Rewards follow the provider's official conditions; accepting an invitation does not mean the reward has arrived.

**Receive WeChat and Feishu reminders.** Configure quota, reset and reset-card messages. Personal WeChat connects through Tencent's official iLink QR flow and supports cached status queries. When explicitly enabled, it can continue a selected original Codex chat.

<p align="center">
  <a href="docs/images/1009v2/notifications-guide.jpg"><img src="docs/images/1009v2/notifications-guide.jpg" width="1000" alt="Live build 139 notification setup: macOS notifications, WeChat awaiting a conversation, and Feishu delivery awaiting verification."></a>
</p>

*Setup separates feature switches from connection state. WeChat awaits a conversation; Feishu local authorization is ready, but delivery remains unverified.*

The project workbench separates execution and accepted outcomes. It keeps manual pause, cancellation, completion, remaining work and the original chat available. Normal display does not call a model. Phone delivery and real conversation remain unaccepted. See the [WeChat and project workbench guide](docs/wechat-workbench-0930v1.md).

<a id="dock"></a>

## 06 · Sidebar and status panels

<p align="center">
  <a href="docs/images/1009v1/proxy-status-edge-dock.png"><img src="docs/images/1009v1/proxy-status-edge-dock.png" width="360" alt="User-provided live UI screenshot showing the edge sidebar and expanded proxy status panel, with per-account quota rings, reset countdowns and credits."></a>
</p>

*User-provided live UI crop; account state, quota and credits reflect the moment of capture.*

The sidebar sits at the screen edge and shows selected account quotas, token statistics and other items. Choose ring or fish quota styles, press **⌘I** to show or hide it, hover for details, and drag the top to move it. Pins keep the sidebar visible or its detail panel on top.

Hover over the proxy item to open its status panel: see its running state, request count and account list, with **5h / 7d quota rings, reset countdowns and credit balances** for each account, plus a Proxy settings shortcut. Request snapshots update every minute; quota comes from the latest read. Unavailable quota appears as “—”.

On a trackpad that supports haptic feedback, entering or switching sidebar items gives a light tactile cue. Turn it off with **Trackpad haptics** in the sidebar settings.

<p align="center">
  <a href="docs/images/1009v2/edge-dock-settings.jpg"><img src="docs/images/1009v2/edge-dock-settings.jpg" width="820" alt="Live build 139 sidebar settings showing visibility, scaling and refresh controls."></a>
</p>

*Choose a sidebar size, 75–150% scaling, refresh controls and running indicators. Snapshot refresh shares the existing account settings.*

<a id="setup"></a>

## 07 · Official tools and installation setup

Follow the guide to sign in through an official tool or account entry, then return to the workspace to check its connection state. Connect tools when you need them. Codex's isolated CLI can use its own local sign-in directory; Claude subscriptions follow the explicit-save flow above. Enter credentials only in the official flow.

After a detectable installation or replacement, new users receive full setup. Returning users review WeChat, Feishu and new settings while keeping existing preferences. Manual Claude setup and installation setup retain separate progress. Viewing or dismissing the feature introduction does not complete installation setup or enable optional controls.

The update dialog shows the version and changes and supports download progress, cancellation and retry. It verifies size and SHA256 before opening the installer; replacement is a user action. Downloading does not quit or replace the app automatically.

<p align="center">
  <a href="docs/images/1009v2/guide.jpg"><img src="docs/images/1009v2/guide.jpg" width="1000" alt="Live build 139 usage guide."></a>
</p>

*Use the guide to connect tools when needed. Sign-in, message connections and optional settings follow the user's choices.*

<a id="themes"></a>

## 08 · Nine themes and native glass

Choose a palette in Settings → Display and icons. Each theme supports light and dark modes. Default keeps the neutral interface; other palettes share the native glass renderer with adjustable transparency and depth. macOS Reduce Transparency and Increase Contrast take precedence.

<p align="center">
  <a href="docs/images/1009v2/appearance-settings.jpg"><img src="docs/images/1009v2/appearance-settings.jpg" width="820" alt="Live build 139 Display and icons settings with appearance modes, palette entry, language, glass intensity and depth."></a>
</p>

*The live image shows the current default palette and appearance controls. The table lists available themes.*

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

<a id="downloads"></a>

## 09 · Downloads, upgrades and source builds

2.4 provides DMG and ZIP installers for **macOS 13+ on Apple Silicon ARM64**. They are ad-hoc signed and have not been notarized by Apple. The update dialog displays the version and changes, downloads on click, then verifies the size and SHA256. The user completes replacement after opening the installer; downloading does not quit the app or install it automatically.

**Upgrading from 9.6.x requires a manual download:** Older clients compare SemVer versions and consider 2.4.0 lower than 9.6.x, so they do not detect it as an update. Use the DMG or ZIP above to replace the app manually. Clients on 2.3.0 can detect 2.4.0 normally.

Wait for active work to finish and quit the old app normally before replacement. Keep backups of the old app and local data. Installation setup reviews WeChat, Feishu and new settings. This release has not undergone a real installed upgrade or paid upstream-call acceptance. Local tests and previews also do not verify real reset-card redemption, message delivery or global hotkey interactions. See the [validation record and checksums](docs/release-notes-v2.4.0.md).

Source and installer correspond to `v2.4.0`:

```sh
git clone --branch v2.4.0 https://github.com/BLACKIELF/AgentHub-AiGoodBro.git AiGoodBro-2.4
cd AiGoodBro-2.4
```

Source builds require macOS, Go 1.26+ and the SHA256-verified Token Monitor v0.68.0 macOS runtime. Set `TOKEN_MONITOR_DESKTOP_RUNTIME` and `TOKEN_MONITOR_DESKTOP_DMG` to those official inputs before running `make build`. This release does not provide Intel or Windows installers; existing Windows sources remain intact. See the [historical 114 publication record](docs/source-publication-1003v1.md).

<a id="sources"></a>

## 10 · Sources, licenses and documentation

Feature design borrows from related open-source projects. Code and resources directly reused or adapted are listed below, with their applicable licenses and copyright notices retained.

| Project | Relationship |
|---|---|
| [Tencent/openclaw-weixin 2.4.9](https://github.com/Tencent/openclaw-weixin/tree/24de5c9eb0dd5e595d7e2d090ed8a3f82870d42c) | Native adaptation of iLink protocol and QR pairing; MIT notice retained, without installing OpenClaw. |
| [codexU](https://github.com/shanggqm/codexU) | Second-developed host integration from the historical fixed source: SwiftUI, quota, palette and Windows foundations were inherited and are maintained by AiGoodBro. |
| [Token Monitor v0.68.0](https://github.com/Javis603/token-monitor/tree/5d2db368d8313415763860d594de00e46a663418) | Host adaptation of the pinned source and official macOS runtime. The statistics engine, dashboard, charts and resources remain bundled with AiGoodBro's bridge, hooks and Swift host. See the [host adapter](Companion/TokenMonitorDesktop/README.md) for embedded runtime boundaries. |
| [TokScale 4.18.0 fork](https://github.com/Javis603/tokscale/tree/d5e8ad9b25bfafb43b5b6804940929b728a6f48a) · [original](https://github.com/junhoyeo/tokscale) | Pinned revision `d5e8ad9b25bfafb43b5b6804940929b728a6f48a`, release input `token-monitor-d5e8ad9b`; the collection foundation and license remain bundled. |
| [CLIProxyAPI v8.0.20](https://github.com/router-for-me/CLIProxyAPI/tree/v8.0.20) | Host adapter over the pinned Go SDK scheduler, Codex executor and Responses handler, preserving identity, quota and credit-floor guards and avoiding replay after a stream has begun. |
| [Codex-Manager](https://github.com/qxcnm/Codex-Manager) | Protocol adaptation and static research reference; the warm-up request structure and SSE completion rules are independently implemented in [`CodexAccountActions.swift`](Sources/CodexUsageWidget/Services/CodexAccountActions.swift#L850). |
| [Hazmat wrapper script](https://github.com/dredozubov/hazmat/blob/c112d222bb53e888dd17a8927927286792f7c20e/scripts/check-codex-desktop-attach-smoke.sh) | Protocol adaptation and static research reference for the `CODEX_CLI_PATH` stdio-wrapper entry point; no Hazmat sandbox or service is integrated. |
| [BlackHole1/aswap v1.1.0](https://github.com/BlackHole1/aswap/releases/tag/v1.1.0) | The Claude multi-account CLI/Chrome profile tool from the referenced X post; protocol adaptation and static research reference only, with no copied, bundled or Codex, Feishu or WeCom integration. |

AiGoodBro is licensed under [MIT](LICENSE). Full third-party license texts and copyright notices are in [`Resources/THIRD_PARTY_NOTICES.txt`](Resources/THIRD_PARTY_NOTICES.txt), [`Companion/LocalProxy/LICENSE.CLIProxyAPI`](Companion/LocalProxy/LICENSE.CLIProxyAPI), [`Companion/LocalProxy/LICENSE.Hazmat`](Companion/LocalProxy/LICENSE.Hazmat) and [`Companion/LocalProxy/THIRD-PARTY-NOTICES.txt`](Companion/LocalProxy/THIRD-PARTY-NOTICES.txt).

**Documentation**

[Detailed guide (Chinese)](docs/usage-guide.md) · [CLI quota coverage](docs/local-cli-accounts.md) · [Proxy implementation and validation](docs/local-proxy-0928v1.md) · [2.4 release record](docs/release-notes-v2.4.0.md) · [Historical build 130 release record](docs/release-notes-v9.6.80.md) · [Latest image sources and checksums](docs/public-ui-1009v2.md) · [Report an issue](https://github.com/BLACKIELF/AgentHub-AiGoodBro/issues) · [Security](SECURITY.md)

[MIT license](LICENSE) · [Third-party notices](Resources/THIRD_PARTY_NOTICES.txt) · [Brand compatibility](docs/brand-compat-0911v1.md)
