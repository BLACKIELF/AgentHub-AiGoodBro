# Current source publication · 1002v2 · 2026-10-02

AiGoodBro 9.6.63 (113) is the current macOS arm64 source candidate on `codex/reset-messages-0926v1`, reviewed in PR 13. It updates the existing candidate with the compact home layout, reset-message ordering and sizing, invitation entry points, nine color-token themes, WeChat/workbench changes, and the standalone proxy-window edge treatment.

The proxy window now uses a full-size transparent titlebar, removes the default titlebar separator, and lets one rounded glass surface extend under the traffic lights. The content backdrop ignores the safe area so the outer edge reads as one surface. The installed 9.6.62 (112) app was left running; the new AppKit frame was not installed or restarted during this publication pass.

## Public gallery

The gallery in [`docs/images/1002v2`](images/1002v2/README.md) is rendered from the candidate’s native SwiftUI components with synthetic fixtures. It covers home cards and rows, account layouts, local proxy controls, settings, setup steps, device-login states, usage panels, project workbench states, provider cards, and all nine themes. It does not contain live account names, credentials, prompts, responses, QR codes or provider results. Historical real captures remain in their original versioned directories.

## Validation

- The isolated candidate build completed with optimized arm64 compilation, strict bundle signing, companion and local-proxy resource checks, Token Monitor runtime smoke, and frozen-source consistency.
- The final formatted source passed `make lint`, `git diff --check`, 35 packaged self-test groups, 132 dispatch-participation fixture cases, the WeChat credential/thread-recovery fixtures, 275 local-proxy host cases, Go race tests and vet, quota-refresh fixtures, desktop protocol and peer-authorization fixtures, seven Token Monitor desktop tests, the Chromium dashboard layout/interaction fixture, and native synthetic preview rendering.
- Preview and protocol fixtures used temporary homes and fake accounts. They did not call a paid model, send a real notification, modify account credentials, or change the running proxy. The protected authentication/configuration files were hash-checked around the isolated tests.
- The Chromium dashboard fixture used the bundled Playwright runtime and the installed Chrome executable after the checkout-local package was unavailable. Network requests were blocked by the fixture. A real AppKit window, phone delivery, original-chat continuation, automatic pause/switch/resume, image generation, and Windows runtime remain unaccepted.

## Scope and publication

Only the source branch and public documentation/gallery are being updated. This candidate is not merged into `main`, tagged, or packaged as an official download. The current PR is [BLACKIELF/AgentHub-AiGoodBro#13](https://github.com/BLACKIELF/AgentHub-AiGoodBro/pull/13); its remote checks are the acceptance record for the pushed commit.
