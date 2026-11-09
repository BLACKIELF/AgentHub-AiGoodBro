# Model and allowance display parity

Reviewed against `yetone/magpie` commit `e3f1efdaac97790611d514e7a35173c04d4f735e` (2026-11-09). This change covers the four existing authorized account pools and the existing local CLI surfaces. It adds no provider, sign-in flow or model alias. Codex's main view is unchanged.

| Existing provider | Upstream allowance source | Actual granularity |
| --- | --- | --- |
| Antigravity | `google.go`: `fetchAvailableModels`, `retrieveUserQuotaSummary` with the existing account's project | Each reported model's remaining fraction/reset, plus provider-reported shared pools and their 5-hour/weekly windows. A shared pool is not a separate budget for every model. |
| Claude | `subscription_usage.go`: the same account's Claude Code `/usage`, or limits reported by an actual Claude Code response | Shared 5-hour/7-day windows and explicitly scoped Opus/Sonnet/Fable windows. Current Magpie does not request Anthropic's usage endpoint itself. A local account's reading cannot be attributed to a different browser-authorized pool account. |
| Kimi | `planquota.go`: `GET https://api.kimi.com/coding/v1/usages`; official Kimi CLI resolves its existing OAuth credential for the same query | Shared shorter/week/month windows. Numeric counts retain their units only when supplied. No model-specific percentage is inferred. |
| Grok / xAI | Magpie's maintained Grok plugin: `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` with its existing OAuth access token | Current billing-period credit percentage/reset, with on-demand usage separate. These are account windows, not per-model budgets. |

Existing local CLI surfaces retain their actual scope:

| Local CLI | Displayed quota dimensions |
| --- | --- |
| Antigravity | Actual model IDs/names from `GetUserStatus`, plus independent `RetrieveUserQuotaSummary` shared windows; common family overview and complete model expansion. |
| Gemini | Official bucket model IDs as quota dimensions, without claiming they are client-selectable aliases; missing/invalid fractions remain unknown. |
| Claude Code | Account 5h/7d and explicit scoped windows. A scoped model ID is kept only when supplied; otherwise it remains a shared group. |
| Grok | Account billing credits/balance; never copied into every model. |
| OpenCode | All reported Go rolling/weekly/monthly windows. |
| Kimi | All reported monthly total, 5h, 7d and monthly code windows. |
| TRAE | Reported account credits, without per-model percentages. |
| ZCode | Coding Plan/MCP windows or valid billing grants; a grant's display name is not a model ID. |
| MiMo, WorkBuddy | Existing source has no supported quota reading; unknown is retained. |

Display rules:

- Friendly names come from the provider; selection keeps the real model ID. Antigravity's catalog follows `agentModelSorts[].groups[].modelIds`, with unranked IDs after it. Disabled and internal `chat_`/`tab_` entries are hidden; an exhausted model remains visible and does not gain launch eligibility.
- The default Antigravity overview orders Gemini, Claude, then other families; a model-specific shared pool follows family pools. Shorter windows precede longer ones. A family uses its tightest current reading, never a sum or an average. Unknown members are counted explicitly beside the lowest known reading; an entirely unknown family has no percentage. Full readings remain available under “Every model”.
- Shared windows and model windows remain separate unless membership and an equivalent 5-hour window are confirmed. A weekly-only pool never suppresses a model's 5-hour reading. A known model outside an existing family pool keeps its real name in the default overview. The display layer does not invent membership from a family name.
- The account card, detail and picker use the existing `QuotaPercentageRing` and Codex's metrics. `0` is a known empty ring; absent, stale, stopped or past-reset observations are unknown. Passing a reset time does not manufacture a full allowance.
- Model readings remain bound to their account and generation. The picker shows each account separately. Its launch admission still uses the helper's callable catalog; display-only IDs never extend it.
- The complete real catalog is reachable through an explicit expansion or scroll. A refresh failure keeps the model list and distinguishes unavailable shared allowance. No production account data is used by the fixtures.

Primary source locations:

- [Magpie Google model and quota parser](https://github.com/yetone/magpie/blob/e3f1efdaac97790611d514e7a35173c04d4f735e/internal/provider/google.go), especially `modelInfo`, `quota`, `pools`, `PooledWindows`.
- [Magpie common quota rendering](https://github.com/yetone/magpie/blob/e3f1efdaac97790611d514e7a35173c04d4f735e/internal/gui/assets/app.js): `quotaText`, `familyWindows`, `poolWindows`, `familyQuota`, `quotaWindows`.
- [Magpie subscription readings](https://github.com/yetone/magpie/blob/e3f1efdaac97790611d514e7a35173c04d4f735e/internal/provider/subscription_usage.go) and [Kimi plan parser](https://github.com/yetone/magpie/blob/e3f1efdaac97790611d514e7a35173c04d4f735e/internal/provider/planquota.go).
- [Grok plugin immutable source blob](https://api.github.com/repos/magpie-community/plugins/git/blobs/7d1c2bd74b4ba8ff769480c872f324b036dd6d6e): `packages/grok/index.mjs`, `usage`, lines 865–897; its CPA import maps the same xAI OAuth access token.
- [Official Kimi CLI immutable usage source blob](https://api.github.com/repos/MoonshotAI/kimi-cli/git/blobs/0c46a31dccb99a9bb9007786de5556127620ed31): `src/kimi_cli/ui/shell/usage.py`, lines 56 and 91–105, resolves OAuth before the `/usages` GET.

Validation: `python3 -B tests/test_provider_model_quota.py` passed 48 assertions by compiling the real production DTO/projection with synthetic fixtures for empty/unknown/stale readings, identity separation, ordering, independent models beside family pools, weekly-only pools, exact launch IDs and counts. Live readings and installed UI acceptance are separate checks.
