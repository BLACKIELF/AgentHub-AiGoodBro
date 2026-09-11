# AiGoodBro macOS UI/brand adversarial review · 0911v3

Scope: uncommitted macOS UI/brand files only. Windows, `.workbuddy-ai`, and other executors' work were not reviewed.

## Summary

The 0911v2 UI/brand pass still holds its hard constraints:

- `blocksLocalCLI` is still `isBusy || phase == .unavailable`. The new `HubCLIBlockDetail` / `blockingReason` path is presentation-only; every CLI disable site still gates on `blocksLocalCLI`.
- `ResetCreditButton` (three confirmations), `AccountCardFooterSlots`, five footer tabs, and `LocalCLIIcon` are still present.
- `FixedVisualPalette` status\* values, `surfaceTrack` 0.10, and `sectionFill` are unchanged. New `surface*` aliases and `primarySurface(_:)` only wrap existing opacities.
- Combined token totals still use `map` + 「暂无记录」; `QuotaAvailabilityPresentation.percentText(nil)` is still `—`, not `0%`.
- `PublicResetAnnouncementMonitor` remains; `seedPreviewLatest` is preview-guarded and does not start a check or rewrite ledgers.
- No auth, quota math, scheduling, notification, persistence, or adapter changes in this UI set. `CodexProfileStore` only retitled 「7 天额度」→「7 天窗口」.

Prior 0911v2 findings:

- **A (RMB `cost * 6.8`)**: fixed. `TokenTotalsHeader` now shows `≈ $%.0f` with help that it is not a currency conversion. The `$` mark is product, not a new defect.
- **B (`minHeight: 188`)**: still only on the 5h/7d `quotaOverview` card (`CodexAccountManagerView.swift:1620`), not the totals card. Progress docs still over-claim.
- **C (brand self-test MIT/icns)**: still in place in `AHBrandAssetsSelfTest`.
- **D (bare `.unavailable` inferred as `.hubOffline`)**: fixed. `inferredDetail(.unavailable)` is `nil`; the self-test now locks the generic copy.

One new correctness issue: the reset-card count on `ResetUpdatesBanner` treats unknown as 0 and bypasses `UsageStore.availableResetCredits(for:)`. Remaining items are copy/layout/DX, not gate regressions.

This pass did not run a GUI, install, or click the banner.

## Issues

### Issue 1 -- Severity: bug
- File: Sources/CodexUsageWidget/UI/CodexAccountManagerView.swift:343
- Description: `accountsWithAvailableResetCards` counts `store.profiles` with `($0.lastSnapshot?.availableResetCredits ?? 0) > 0`. That does three wrong things at once. (1) `nil` credit counts become 0, so a workspace with only unread/unknown cards renders 「无可用重置卡」 / "No reset cards available" — unknown presented as none. Account cards already distinguish 「官方未返回」 vs 「可用重置卡次数未知」 vs a real 0. (2) The monitored account's live value is `store.availableResetCredits(for:)`, which reads `snapshot.credits?.resetCredits` for the selected profile, not `lastSnapshot`. The banner can disagree with the card on the account the user is actually watching. (3) `store.profiles` includes linked system+managed pairs that `presentedProfiles` de-duplicates, so one recorded account can count as two.
- Suggestion: Count `presentedProfiles` (or the same de-dupe as the home list). Use `store.availableResetCredits(for:)`. If every visible count is `nil`, show unknown copy, not 「无可用重置卡」. Keep `> 0` only for confirmed integers.
- Status: fixed — `presentedProfiles` + `availableResetCredits(for:)`; all-nil is unknown copy, not none

### Issue 2 -- Severity: suggestion
- File: Sources/CodexUsageWidget/Services/HubConsoleModel.swift:241
- Description: The new resolver maps every non-online connection, including initial `HubConnectionState.loading` and a nil `lastSuccessfulRefreshAt`, to `.hubOffline` ("Hub 概览未连接"). `HubAccountTaskStatusModel.connectionState` starts at `.loading` with `lastSuccessfulRefreshAt == nil`, so the first paint of every blocked CLI control claims Hub is disconnected. `blocksLocalCLI` is still correctly fail-closed; only the new sentence is wrong. `.loading` and `.offline` are distinct states and were collapsed.
- Suggestion: Add a loading/unverified `HubCLIBlockDetail` (or reuse the generic nil-detail copy) when `connectionState != .online` but this is not a completed offline refresh. Keep `.hubOffline` for `.offline`.
- Status: fixed — `.loading` keeps nil detail / generic copy; `.offline` still `.hubOffline`

### Issue 3 -- Severity: suggestion
- File: Sources/CodexUsageWidget/UI/LocalCLIWorkspaceView.swift:506
- Description: T06 wires `LocalCLIModelAvailabilityView` by calling `LocalCLIModelAvailabilityStore.load(root:now:)` inside a `ViewBuilder` helper, with `now: Date()`. The view's own comment says the parent must supply a snapshot and that the view does not read files. `load` does `lstat`/`open`/`read` on the isolated evidence file. Home unified accounts rebuild this on `TimelineView` ticks and any other invalidation, once per visible local profile, on the main thread. Fail-closed (empty snapshot) so it should not crash, but it can hitch and it ignores the existing `binding:` argument.
- Suggestion: Load from `LocalCLIAccountStore` (or a cached snapshot on the model) and pass it in. Do not open files from `body`. Pass a `LocalCLICurrentBinding` when one exists; if none, hide the dispatch line instead of claiming ineligible.
- Status: open

### Issue 4 -- Severity: suggestion
- File: Sources/CodexUsageWidget/Domain/LocalCLIModelAvailability.swift:660
- Description: `cardSummary` labels `rows.count` as 「可用模型」. `rows` is the union of documented free facts and evidence, including untested, expired, and invalid models. `dispatchEligible` is also forced to `false` whenever `binding` is missing or the row is not the bound model (`LocalCLIModelAvailability.swift:612`). The compact card therefore says "N available models" and, once expanded, every row says 「不可用于受管派单」. English ("N models · M verified") is accurate; Chinese is not.
- Suggestion: Use 「列出模型」 / "N models · M verified". If `binding == nil`, omit `dispatchText` rather than printing a definite no.
- Status: open

### Issue 5 -- Severity: suggestion
- File: Sources/CodexUsageWidget/UI/CodexAccountManagerView.swift:4585
- Description: T07 stopped truncating 「窗口重置 …（2...）」 in the 380-wide menu by making `prominent` tiles show `compactReset` only (absolute `MMMd HHmm`, relative time in `.help`). The same `QuotaDetailTile(prominent: true)` is used on the main-window `quotaOverview` (`CodexAccountManagerView.swift:1605`). The 980-wide 5h/7d card now also hides relative time, which used to be on-screen. Help still has the full string, so this is information architecture, not data loss.
- Suggestion: Keep compact copy for the menu (or a `compactResetText` flag). Let the workspace prominent tile keep absolute + relative.
- Status: open

### Issue 6 -- Severity: nit
- File: scripts/generate-ah-brand-icons.py:40
- Description: `FINAL_VARIANT = "c5"` (ring hub + inner frame). `AHBrandSymbol.drawGlyph` also strokes a closed ring, not the c6 reset-cycle gap. Progress/acceptance text still says the mark is "C2 AH 枢纽连字". C2 in the generator is a filled dot. Implementation is internally consistent (c5); the handoff label is not. The in-app tile also fills the whole view, while the PNG/ICNS tile is the macOS 82.4% safe-area squircle — fine for badges, but the "lockstep" comment overstates it.
- Suggestion: Call the shipped mark c5 in docs, or change `FINAL_VARIANT` only with a new icon pass. Do not retouch `FixedVisualPalette` token values to "fix" this.
- Status: open

### Issue 7 -- Severity: nit
- File: Sources/CodexUsageWidget/UI/LocalCLIWorkspaceView.swift:144
- Description: T11 moved several Grok expiring accents to `FixedVisualPalette.statusDanger`, but two sibling marks are still `Color.red` / `.red` (expiring caption at line 144, card stroke at line 278). Same file, same state, two colors.
- Suggestion: Use `statusDanger` for both remaining marks.
- Status: open
