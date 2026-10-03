# Theme and upstream follow-up · 1004v1

This update targets the macOS app and the embedded Token Monitor 0.62.0 adapter. It preserves pinned vendor sources, the saved account order, and the existing account/credit authorization checks.

## User-visible changes

- Text and action icons use foreground colors chosen separately from filled-control accents. Light and dark themes retain readable warning, error, success and link colors. Account and navigation ellipses use the native foreground.
- Account cards expose an information button. Narrow cards wrap actions below the identity instead of squeezing out the name. Information starts with reset-card expiry dates, nearest upcoming first; dates within 48 hours are highlighted only when the quota read is fresh and successful. Expired records and unknown dates stay distinct. The same reminder appears on the home overview.
- Account information includes saved warm-up history and safe failure categories, reported quota/statistics, subscription evidence and local model settings. Private credentials and full account identifiers are not displayed.
- The proxy window uses the shared background/hosting path for the default theme as well as custom themes. The synthetic audit opens the actual AppKit proxy window, checks its content, and returns from custom themes to default in both appearances.
- Manual proxy refresh displays newly returned evidence immediately. Live credit-fallback changes are captured per new request, together with its account order. Active requests keep their existing policy snapshot. Failed preference writes roll back the attempted change.
- Native usage coverage is indexed once per response, preserving unknown/partial/excluded semantics. Side-panel account details retain scrolling, measure content height and paginate multiple non-Codex accounts.

## Upstream reports and disposition

Reports were read from GitHub on 2026-10-04. Similar reports or comments establish recurring demand, not independent proof of a proposed cause.

| Reports | Finding and disposition in this update |
| --- | --- |
| Token Monitor [#579](https://github.com/Javis603/token-monitor/issues/579), [#916](https://github.com/Javis603/token-monitor/issues/916) | The pinned device state waits for usage before publishing a combined record. A separate local presentation event now delivers available quotas while history is still loading. It does not invent zero usage or upload a quota-only record to Hub. Loading and failure text distinguish an unfinished scan from an empty history. This does not repair a history scan that actually exceeds its timeout. |
| Token Monitor [#637](https://github.com/Javis603/token-monitor/issues/637), [#856](https://github.com/Javis603/token-monitor/issues/856) | The embedded watcher now bounds trailing debounce at 10 seconds and gives slow scans idle time proportional to their duration, capped at 30 seconds. It recalculates that delay if a scan finishes after a timer was armed. Pending client changes survive; manual/history refresh stays intact. This reduces repeated automatic scans, but does not eliminate the cost of one full history scan or establish a measured energy saving. |
| Token Monitor [#145](https://github.com/Javis603/token-monitor/issues/145), [#793](https://github.com/Javis603/token-monitor/issues/793), [#934](https://github.com/Javis603/token-monitor/issues/934) | Existing native managed accounts and dock settings are reused. Multiple provider accounts can be paged and tall single-account details fit their content. Arbitrary custom sidebar font/width controls and universal multi-account credentials are not added. |
| CLIProxyAPI [#5404](https://github.com/router-for-me/CLIProxyAPI/issues/5404), [#5639](https://github.com/router-for-me/CLIProxyAPI/issues/5639) | Host display recovery after quota refresh is covered. The separate upstream model-cooldown issue remains unresolved: removing a cooldown without reconciling identity, newer 429s and fresh provider evidence could re-enable an unavailable account. This update does not claim to reset that scheduler state. |
| CLIProxyAPI [#5545](https://github.com/router-for-me/CLIProxyAPI/issues/5545); Codex-Manager [#231](https://github.com/qxcnm/Codex-Manager/issues/231) | The local proxy already distinguishes an empty stream before output from a partially delivered response. Regression tests preserve no replay after partial output and do not misclassify an upstream timeout as an empty stream. The reported real upstream silence/disconnection is not reproduced or declared fixed. |
| Weixin [#268](https://github.com/Tencent/openclaw-weixin/issues/268), [#266](https://github.com/Tencent/openclaw-weixin/issues/266), [#239](https://github.com/Tencent/openclaw-weixin/issues/239) | Existing API-accepted versus delivered semantics and incoming-message ledger deduplication remain. The local send-validity checks run on the main actor, including credential/revision changes. No real message is sent, and server-side phone delivery is not established. |
| tokscale [#960](https://github.com/junhoyeo/tokscale/issues/960), [#862](https://github.com/junhoyeo/tokscale/issues/862); Token Monitor [#926](https://github.com/Javis603/token-monitor/issues/926) | Timezone rebucketing and long-context billing require source/request-level evidence. Reported provider zero cost is not silently replaced with an estimate; stored totals are not rewritten. These accounting reports remain upstream work. The embedded fork has issues disabled, so the original tokscale repository was also inspected. |
| codexU [#21](https://github.com/shanggqm/codexU/issues/21), [#49](https://github.com/shanggqm/codexU/issues/49) | AiGoodBro already uses its own native status item and CLI discovery. No unrelated upstream UI implementation or credential location is copied based on these reports. |

## Validation boundary

Quota-before-history, no invented Hub record, observer failure isolation, stopped-runtime callbacks, bounded debounce, slow-scan idle time, client preservation and shutdown are exercised against the transformed production functions with synthetic data. Packaging checks enforce exact vendor hashes and the allowlisted staged changes.

Native checks cover the 48-hour boundary, stale/failed evidence, duplicate dates, saved ordering, appearance-specific foreground contrast and the real proxy-window host. Runtime previews contain only synthetic accounts. Live model requests, actual upstream 429 recovery, phone delivery and prolonged real-history energy consumption require separate evidence.

## 1004v2 correction: visible cold-start quotas

The 115 test replaced `renderLimits` and `signalContentReady` with counters. It proved event delivery but missed the production hidden panel and the readiness guard requiring stats. The default Home module also read only combined stats, and the initial local empty aggregate could masquerade as a completed baseline.

116 reuses Home quota rows and the Limits panel while keeping usage unknown until a real local record exists. A real zero-token record remains known zero. The initial embedded local placeholder carries an explicit pending marker; current pending quotas replay after renderer reload and are invalidated by stop or real collection. Tests extract the production render, quota builders, panel visibility and readiness functions instead of replacing those guards. Vendor inputs and hash checks remain pinned.
