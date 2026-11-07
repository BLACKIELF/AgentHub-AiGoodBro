# Mac upstream adoption · 1107v1

This candidate retains the pinned Token Monitor 0.68.0 Electron/runtime and existing TokScale 1027v1 scanner, then selectively adopts compatible source fixes through Token Monitor 0.87.0. It does not claim a complete 0.87.0 application upgrade. CLIProxyAPI is upgraded separately to 8.0.58. The native AiGoodBro candidate is 3.0.0 build 167.

## Adopted source

| Upstream | Source revision | Applied behavior |
| --- | --- | --- |
| [PR1106](https://github.com/Javis603/token-monitor/pull/1106) | `ce26462f78f93cf9c0b6877d852a8007e471c9bf` | Settings/account refresh awaits limits without forcing usage scans; explicit App/EdgeDock history refresh and tray usage refresh retain their separate behavior. |
| [PR1266](https://github.com/Javis603/token-monitor/pull/1266) | `4713492b983030138e1c7a9606be9f0549f89075` | Reconcile retained usage by session identity, preserve reported saved input, and replace corrected values including zero. |
| [PR1268](https://github.com/Javis603/token-monitor/pull/1268) | `08eeb2d7145035dee94802b46e588d46973a9cc6` | Retain real per-model token components in session archives; missing legacy components remain unknown. |
| [PR1288](https://github.com/Javis603/token-monitor/pull/1288) | `a6870fd8a12bc44a8a32998b6cf84f9ab80838b8` | Recognize Claude Max/Ultra labels, week-only quota output and PTY completion. |
| [PR1320](https://github.com/Javis603/token-monitor/pull/1320) | `66a640c6309382fc68ffbc74763884dc6b595d1a` | Pin Kiro `/usage` to v2 and limit legacy-command fallback so the query does not become a chat request. |
| [PR1350](https://github.com/Javis603/token-monitor/pull/1350) | `6f01d38444aef68386b1e7ea7513467e2caf101b` | Close invalidated outbound proxy agents without retaining failed cleanup promises. |
| [v0.87.0](https://github.com/Javis603/token-monitor/releases/tag/v0.87.0) | `b3dd5e25bd9ab89620eb6380c863e335d8b8751e` | Adopt the service-status module and tests: 12 providers, scoped components, official formats and failure details. |
| [PR1379](https://github.com/Javis603/token-monitor/pull/1379) | `c12462d6db68895e28914263d0de3fa1d129912a` | Refresh status when re-enabled and schedule newly visible providers while a refresh is in flight. |

The status adoption also includes PR1370 (`c6533e6fa70af9d6ac9f3e606b00e7446c831195`), PR1343 (`09b6cc0e490263bbb4d08b881772ee541d850680`) and PR1380 (`33b8ef98a141ca0119deca23d51f0a46f0245628`). The native status panel supports the nine providers using the shared Statuspage shape; DeepSeek, Zed and OpenCode special formats are supported in the statistics window, not newly claimed in the native panel. Status network calls use the existing injected transport with omitted credentials. Provider-account credentials are not added to status requests.

PR1285 is deferred: it selects a newer TokScale binary. AiGoodBro currently retains a scanner with additional reviewed Qwen, Codex and Cursor fixes; substituting that upstream binary would lose those adaptations. Its Rust pre-decode size guard requires a separate source backport, arm64 rebuild and report/fixture reconciliation.

## Native corrections

Kimi's monthly total is the primary subscription metric. The five-hour, seven-day and Code monthly windows remain independent. A missing monthly total stays unknown instead of substituting a full short-period allowance. The reader accepts the upstream `data` wrapper, `usedRatio` and `resetTime` aliases. The fixture matching the reported 49.39% usage displays 50.61% remaining; that is synthetic verification, not a new read of the user's account.

The proxy queue and dock carry the remaining credit balance and the nearest known reset-card expiry, including date and time. Missing or stale auxiliary details remain explicit. New or legacy policies missing an explicit credit flag default to disabled; an existing deliberate choice is preserved. Per-account rules start expanded in a compact wrapping layout.

## Integration contract

The package lock, dependency roots, Electron/Node pins, scanner pins, account isolation, capability gates and existing host adapters are preserved. `SOURCE.json` changes only the reviewed source/test inventory and review metadata. Desktop staging changes the exact main.js and renderer/app.js input pins after reviewing the refresh, transport and status edits; all other transformation input pins stay fixed. Hub build metadata is regenerated with the upstream script, then copied to the Worker using its official synchronization script.

Independent source review found no blocking issue in refresh semantics, archived session identity, per-model accounting or outbound-agent cleanup. Targeted refresh tests passed 44/44 and archive tests 165/165. The accounting set initially passed 458/459 because the generated Hub marker needed regeneration; the corrected Hub identity group passed 13/13. Native policy, Kimi, account and service-status fixture checks are separate from final bundled runtime checks. Desktop staging tests passed 14/14. Changed upstream JavaScript lint passed for all 24 changed/new non-generated files. Full upstream `npm run verify` is not green: six pre-existing unused-symbol lint errors remain in the intentionally disabled Antigravity OAuth implementation, whose two files are unchanged against the base commit. Separately, the full test run recorded 6,278 passes, 11 failures and 10 skips: six Antigravity OAuth expectation failures and five unavailable optional Electron/widget/release development dependencies. These are not reported as passes, and this adoption does not re-enable the prohibited OAuth implementation to satisfy them. Final packaging and visual receipts belong to the build-167 evidence, and must be read before claiming delivery acceptance.

No real account query, paid model request, reset-card consumption, notification, installed-app restart or installation is part of these source tests. The complete application, new providers, remote deployment features and unrelated upstream UI changes are not imported by this selective adoption. Rollback uses the preserved candidate-166 source and signed application; the installed application is not replaced by producing this candidate.
