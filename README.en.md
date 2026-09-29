# AiGoodBro · AgentHub (2.0 candidate)

**See quota, usage and task occupancy at a glance; when needed, route local work through your own Codex account pool.**

AiGoodBro is a macOS AI workspace for personal use. It brings together quotas for multiple Codex accounts, token usage, local CLIs and public reset announcements, with an optional local proxy. The interface supports Chinese and English; its home page is called AgentHub.

[中文](README.md) | **English**

The screenshots below show the real 9.6.32 (82) interface captured on 2026-09-29. See the [screenshot notes](docs/images/0929v2/README.md) for provenance.

## See what is happening

Home shows each account's remaining quota, reset time and task occupancy. Public reset announcements stay distinct from an account's actual quota. Usage views summarize token, model and tool activity; estimated costs are based on local data, not provider bills.

![AgentHub home and usage summary, 9.6.32 (82), captured 2026-09-29](docs/images/0929v2/01-home.jpg)

*Usage overview, activity heatmap, trends and account quotas on one page.*

Codex's isolated CLI can use its own local sign-in directory; support for other tools depends on the provider. Account cards and rows let you refresh quota, change order, choose a model or start an isolated CLI. See the [CLI quota coverage](docs/local-cli-accounts.md) for supported providers and limits.

![Codex account cards, 9.6.32 (82), captured 2026-09-29](docs/images/0929v2/02-codex.jpg)

*Codex account cards.*

The workspace shows quota and status for connected tools; availability depends on the tool and current sign-in. ZCode is a desktop tool, not a CLI. WorkBuddy desktop quota is currently unreadable. The Kimi CLI view shows its previous snapshot; refresh it before relying on the value.

![ZCode desktop account view, 9.6.32 (82), captured 2026-09-29](docs/images/0929v2/03-zcode.jpg)

*The ZCode desktop account page brings models, expiration dates and token balances together.*

![Kimi CLI quota view, 9.6.32 (82), captured 2026-09-29](docs/images/0929v2/06-kimi.jpg)

*Kimi shows its previous snapshot; refresh before use.*

## Setup guide: connect official tools and accounts

Follow the guide to sign in to an official tool or account, then return to the workspace to check its connection status. Connect each tool when you need it.

![Guide to connecting official tools and accounts, 9.6.32 (82), captured 2026-09-29](docs/images/0929v2/05-guide.jpg)

## Local proxy: route requests through your own account pool

The optional local proxy is a personal tool. Compatible clients send model requests to a service on this Mac; AiGoodBro selects an enrolled account by participation, priority and saved order. Available subscription quota across participating accounts is used before credits, and the current Desktop account is tried last in each quota phase.

Credit continuation is off by default. Only if the user enables it does the proxy enter credit phases after subscription quota is exhausted. Busy or unknown accounts do not count as exhausted. The credit threshold guides account selection between requests; it is not a per-request hard cap.

The proxy routes inference requests only. Codex Desktop keeps its OpenAI sign-in, each conversation's model and reasoning effort; using the proxy does not change system authentication files or global configuration. An already-running Codex process does not switch routes until it is restarted and connected again.

![Local proxy controls, 9.6.32 (82), captured 2026-09-29](docs/images/0929v2/04-proxy.jpg)

*The proxy was stopped and showed an unavailable notice in this screenshot. It shows the controls only; the proxy was not enabled for the capture and request forwarding was not tested.*

**Start and stop it yourself:**

1. Turn on the proxy manually in AiGoodBro. It does not start automatically when the app restarts.
2. Quit Codex. The **Connect Desktop** button appears only after the proxy starts successfully and its connection details are ready; choose it to relaunch Codex with the local route.
3. When finished, stop the service in the proxy panel. Closing the main window only hides it; quitting the app asks whether to stop the proxy. Reopen Codex normally after stopping it.

Once a streamed response has begun, an error is not replayed through another account. An uncertain result is not sent again automatically, avoiding duplicate task execution. Proxy controls and the Connect Desktop entry are present in the candidate UI; their presence does not prove end-to-end acceptance.

The proxy is designed for personal use with your own accounts and local tasks. This project does not provide accounts, credential sharing, quota resale or a public proxy service.

## Candidate status and acceptance limits

The current source is **AiGoodBro 9.6.32 (82) · 0929v2**, on [`codex/reset-messages-0926v1`](https://github.com/BLACKIELF/AgentHub-AiGoodBro/tree/codex/reset-messages-0926v1) and under review in [PR #13](https://github.com/BLACKIELF/AgentHub-AiGoodBro/pull/13). It remains a candidate, is not merged into `main`, and has no official download.

[![Candidate branch CI](https://github.com/BLACKIELF/AgentHub-AiGoodBro/actions/workflows/ci.yml/badge.svg?branch=codex%2Freset-messages-0926v1)](https://github.com/BLACKIELF/AgentHub-AiGoodBro/pull/13/checks)

The latest candidate recheck passed 31 of 33 pure self-tests. `workspace-screenshot` and `token-monitor-ui` failed; details are in the [source publication record](docs/source-publication-0929v1.md). The macOS CI run for the latest source commit [`c5c35ee`](https://github.com/BLACKIELF/AgentHub-AiGoodBro/commit/c5c35ee) failed with a MainActor-related compile error; see [PR #13 checks](https://github.com/BLACKIELF/AgentHub-AiGoodBro/pull/13/checks). This README and screenshot update adds no new application acceptance.

Current build 82 Desktop routing, real proxy image generation, long-conversation recovery, automatic pause → account switch → continuation and final UI regression remain unaccepted. See the [source publication record](docs/source-publication-0929v1.md) and [proxy integration notes](docs/local-proxy-0928v1.md) for implementation details and verification boundaries.

Build the 2.0 candidate:

```sh
git clone --branch codex/reset-messages-0926v1 https://github.com/BLACKIELF/AgentHub-AiGoodBro.git AiGoodBro-2.0
cd AiGoodBro-2.0
make build
```

To build the existing mainline, use `main`; it does not include candidate 82. Source builds require Go 1.26+ and the verified Token Monitor v0.62.0 macOS runtime; see the [source publication record](docs/source-publication-0929v1.md). No 2.0 installer is currently available.

## Inspiration, code sources and licenses

Feature design borrows from related open-source projects. Code and resources directly reused or adapted are listed below, with their applicable licenses and copyright notices retained.

| Project | Relationship |
|---|---|
| [codexU](https://github.com/shanggqm/codexU) | Historical SwiftUI, quota, palette and Windows foundations inherited. |
| [Token Monitor v0.62.0](https://github.com/Javis603/token-monitor/tree/dcccfb01557e2786888fd5479552f392ac6c0d32) | Statistics engine, desktop dashboard, charts and resources directly reused with host adaptation. |
| [Tokscale fork](https://github.com/Javis603/tokscale) · [original](https://github.com/junhoyeo/tokscale) | Statistics collection foundation; bundled revision `06a9f1625d5a505f01b39eff29f7be44a2c52188`, as recorded in [`SOURCE.json`](Companion/TokenMonitorEngine/SOURCE.json). |
| [CLIProxyAPI v8.0.2](https://github.com/router-for-me/CLIProxyAPI/tree/v8.0.2) | SDK scheduler, Codex executor and Responses handler directly reused. |
| [Codex-Manager](https://github.com/qxcnm/Codex-Manager) | Warm-up request structure and SSE completion rules adapted in the implementation; see [`CodexAccountActions.swift`](Sources/CodexUsageWidget/Services/CodexAccountActions.swift#L850). |
| [Hazmat wrapper script](https://github.com/dredozubov/hazmat/blob/c112d222bb53e888dd17a8927927286792f7c20e/scripts/check-codex-desktop-attach-smoke.sh) | Reference for the `CODEX_CLI_PATH` stdio-wrapper entry point; no Hazmat sandbox or service is integrated. |

AiGoodBro is licensed under [MIT](LICENSE). Full third-party license texts and copyright notices are in [`Resources/THIRD_PARTY_NOTICES.txt`](Resources/THIRD_PARTY_NOTICES.txt), [`Companion/LocalProxy/LICENSE.CLIProxyAPI`](Companion/LocalProxy/LICENSE.CLIProxyAPI), [`Companion/LocalProxy/LICENSE.Hazmat`](Companion/LocalProxy/LICENSE.Hazmat) and [`Companion/LocalProxy/THIRD-PARTY-NOTICES.txt`](Companion/LocalProxy/THIRD-PARTY-NOTICES.txt).

## More information

[Detailed guide (Chinese)](docs/usage-guide.md) · [CLI quota coverage](docs/local-cli-accounts.md) · [Proxy implementation and validation](docs/local-proxy-0928v1.md) · [Current source publication record](docs/source-publication-0929v1.md) · [Historical screenshots: 0927v6](docs/images/0927v6/README.md) · [Historical screenshots: 0910v1](docs/images/0910v1/README.md) · [Report an issue](https://github.com/BLACKIELF/AgentHub-AiGoodBro/issues) · [Security](SECURITY.md)

[MIT license](LICENSE) · [Third-party notices](Resources/THIRD_PARTY_NOTICES.txt) · [Brand compatibility](docs/brand-compat-0911v1.md)
