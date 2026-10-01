# AiGoodBro · AgentHub (2.0 candidate)

**See quota, usage and task occupancy at a glance; when needed, route local work through your own Codex account pool.**

AiGoodBro is a macOS AI workspace for personal use. It brings together quotas for multiple Codex accounts, token usage, local CLIs and public reset announcements, with an optional local proxy. The interface supports Chinese and English; its home page is called AgentHub.

[中文](README.md) | **English**

The current source candidate is **9.6.63 (113) · 1002v2**. These previews are rendered by the candidate’s native interface with synthetic data. The [full gallery](docs/images/1002v2/README.md) covers home, accounts, proxy, settings, setup, usage panels and all nine themes. Historical real captures retain their version labels.

## See what is happening

Home shows each account's remaining quota, reset time and task occupancy. Public reset announcements stay distinct from an account's actual quota. Usage views summarize token, model and tool activity; estimated costs are based on local data, not provider bills.

![AgentHub home, 9.6.63 (113), native synthetic preview](docs/images/1002v2/home/compact-en.png)

*Home supports resizable sections, cards and rows. The two reset panels share the available width and preserve the user’s chosen proportions.*

Codex's isolated CLI can use its own local sign-in directory; support for other tools depends on the provider. Account cards and rows let you refresh quota, change order, choose a model or start an isolated CLI. See the [CLI quota coverage](docs/local-cli-accounts.md) for supported providers and limits.

![Codex account cards, 9.6.63 (113), native synthetic preview](docs/images/1002v2/accounts/cards-en-dark.png)

*Codex account cards.*

The workspace shows quota and status for connected tools; availability depends on the tool and current sign-in. ZCode is a desktop tool, not a CLI. WorkBuddy desktop quota is currently unreadable. The Kimi CLI view shows its previous snapshot; refresh it before relying on the value.

![Multi-provider workspace, 9.6.63 (113), native synthetic preview](docs/images/1002v2/workspace/providers-en-dark.png)

*Tool status, quotas and controls follow each provider’s capabilities; unreadable quotas retain an explicit notice.*

![Project workbench, 9.6.63 (113), native synthetic preview](docs/images/1002v2/workbench/workbench-900-dark.png)

*The project workbench distinguishes execution from accepted outcomes and keeps remaining work and the original chat available. This preview is in Chinese.*

## Setup guide: connect official tools and accounts

Follow the guide to sign in to an official tool or account, then return to the workspace to check its connection status. Connect each tool when you need it.

![Guide to connecting official tools and accounts, 9.6.63 (113), native synthetic preview](docs/images/1002v2/setup/en-dark-step1.png)

## Local proxy: route requests through your own account pool

The optional local proxy is a personal tool. Compatible clients send model requests to a service on this Mac; AiGoodBro selects an enrolled account by participation, priority and saved order. Available subscription quota across participating accounts is used before credits, and the current Desktop account is tried last in each quota phase.

Credit continuation is off by default. Only if the user enables it does the proxy enter credit phases after subscription quota is exhausted. Busy or unknown accounts do not count as exhausted. The credit threshold guides account selection between requests; it is not a per-request hard cap.

The proxy routes inference requests only. Codex Desktop keeps its OpenAI sign-in, each conversation's model and reasoning effort; using the proxy does not change system authentication files or global configuration. An already-running Codex process does not switch routes until it is restarted and connected again.

![Local proxy controls, 9.6.63 (113), native synthetic preview](docs/images/1002v2/proxy/en-dark-830.png)

*The synthetic preview shows account order, quotas and credit floors. The standalone window now uses one rounded glass surface with a transparent titlebar and no dark separator. The AppKit frame still needs a real-window check after a normal restart.*

**Start and stop it yourself:**

1. Turn on the proxy manually in AiGoodBro. It does not start automatically when the app restarts.
2. Quit Codex. The **Connect Desktop** button appears only after the proxy starts successfully and its connection details are ready; choose it to relaunch Codex with the local route.
3. When finished, stop the service in the proxy panel. Closing the main window only hides it; quitting the app asks whether to stop the proxy. Reopen Codex normally after stopping it.

Once a streamed response has begun, an error is not replayed through another account. An uncertain result is not sent again automatically, avoiding duplicate task execution. Proxy controls and the Connect Desktop entry are present in the candidate UI; their presence does not prove end-to-end acceptance.

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

![WAICY Sunset dark palette, native synthetic preview](docs/images/1002v2/themes/codexu.waicy-dark.png)

[View light and dark previews of all nine themes](docs/images/1002v2/README.md#themes). Themes supply color tokens only. WAICY artwork, logos, mascots and fonts are not copied, and the palette does not imply official endorsement.

## Candidate status and acceptance limits

The current source is **AiGoodBro 9.6.63 (113) · source candidate 1002v2**, on [`codex/reset-messages-0926v1`](https://github.com/BLACKIELF/AgentHub-AiGoodBro/tree/codex/reset-messages-0926v1) and under review in [PR #13](https://github.com/BLACKIELF/AgentHub-AiGoodBro/pull/13). It remains a candidate, is not merged into `main`, and has no official download.

[![Candidate branch CI](https://github.com/BLACKIELF/AgentHub-AiGoodBro/actions/workflows/ci.yml/badge.svg?branch=codex%2Freset-messages-0926v1)](https://github.com/BLACKIELF/AgentHub-AiGoodBro/pull/13/checks)

The installed local build is **9.6.62 (112) · 1002v1**. Candidate 113 passes an optimized build, source/resource verification, strict signatures, 35 packaged self-test groups, Swift lint and synthetic desktop protocol regressions. Home, settings, setup, login, usage-panel and theme previews are rendered offscreen with synthetic data; they do not show live accounts or real model requests. The running proxy was not restarted. Phone delivery, real original-chat conversation, automatic pause/switch/resume, real image generation and the new AppKit titlebar remain unaccepted. See the [current publication record](docs/source-publication-1002v2.md) and [PR #13 checks](https://github.com/BLACKIELF/AgentHub-AiGoodBro/pull/13/checks).

Build the 2.0 candidate:

```sh
git clone --branch codex/reset-messages-0926v1 https://github.com/BLACKIELF/AgentHub-AiGoodBro.git AiGoodBro-2.0
cd AiGoodBro-2.0
make build
```

Source builds require macOS, Go 1.26+ and the verified Token Monitor v0.62.0 macOS runtime; see the [build and publication record](docs/source-publication-1002v2.md). No 2.0 installer is currently available. Further Windows work remains on hold.

## Inspiration, code sources and licenses

Feature design borrows from related open-source projects. Code and resources directly reused or adapted are listed below, with their applicable licenses and copyright notices retained.

| Project | Relationship |
|---|---|
| [Tencent/openclaw-weixin 2.4.9](https://github.com/Tencent/openclaw-weixin/tree/24de5c9eb0dd5e595d7e2d090ed8a3f82870d42c) | Native adaptation of iLink protocol and QR pairing; MIT notice retained, without installing OpenClaw. |
| [codexU](https://github.com/shanggqm/codexU) | Historical SwiftUI, quota, palette and Windows foundations inherited. |
| [Token Monitor v0.62.0](https://github.com/Javis603/token-monitor/tree/dcccfb01557e2786888fd5479552f392ac6c0d32) | Statistics engine, desktop dashboard, charts and resources directly reused with host adaptation. |
| [Tokscale fork](https://github.com/Javis603/tokscale) · [original](https://github.com/junhoyeo/tokscale) | Statistics collection foundation; bundled revision `06a9f1625d5a505f01b39eff29f7be44a2c52188`, as recorded in [`SOURCE.json`](Companion/TokenMonitorEngine/SOURCE.json). |
| [CLIProxyAPI v8.0.2](https://github.com/router-for-me/CLIProxyAPI/tree/v8.0.2) | SDK scheduler, Codex executor and Responses handler directly reused. |
| [Codex-Manager](https://github.com/qxcnm/Codex-Manager) | Warm-up request structure and SSE completion rules adapted in the implementation; see [`CodexAccountActions.swift`](Sources/CodexUsageWidget/Services/CodexAccountActions.swift#L850). |
| [Hazmat wrapper script](https://github.com/dredozubov/hazmat/blob/c112d222bb53e888dd17a8927927286792f7c20e/scripts/check-codex-desktop-attach-smoke.sh) | Reference for the `CODEX_CLI_PATH` stdio-wrapper entry point; no Hazmat sandbox or service is integrated. |

AiGoodBro is licensed under [MIT](LICENSE). Full third-party license texts and copyright notices are in [`Resources/THIRD_PARTY_NOTICES.txt`](Resources/THIRD_PARTY_NOTICES.txt), [`Companion/LocalProxy/LICENSE.CLIProxyAPI`](Companion/LocalProxy/LICENSE.CLIProxyAPI), [`Companion/LocalProxy/LICENSE.Hazmat`](Companion/LocalProxy/LICENSE.Hazmat) and [`Companion/LocalProxy/THIRD-PARTY-NOTICES.txt`](Companion/LocalProxy/THIRD-PARTY-NOTICES.txt).

## More information

[Detailed guide (Chinese)](docs/usage-guide.md) · [CLI quota coverage](docs/local-cli-accounts.md) · [Proxy implementation and validation](docs/local-proxy-0928v1.md) · [Current source publication record](docs/source-publication-1002v2.md) · [Historical real captures: 0929v2](docs/images/0929v2/README.md) · [Historical screenshots: 0927v6](docs/images/0927v6/README.md) · [Historical screenshots: 0910v1](docs/images/0910v1/README.md) · [Report an issue](https://github.com/BLACKIELF/AgentHub-AiGoodBro/issues) · [Security](SECURITY.md)

[MIT license](LICENSE) · [Third-party notices](Resources/THIRD_PARTY_NOTICES.txt) · [Brand compatibility](docs/brand-compat-0911v1.md)
