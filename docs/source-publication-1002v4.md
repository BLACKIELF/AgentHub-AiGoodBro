# macOS source update · 1002v4

This source update builds on AiGoodBro 9.6.63 (113). It makes invitations, proxy spending controls, quota refresh and the home overview easier to use while preserving verified identity, quota and request outcomes. It also includes the earlier workbench and recommendation-shelf improvements from the same local session.

## Behavior

- **Invitations:** accept up to five unique email addresses, limited by the latest official capacity. The send action checks the current account, offer and consent again. Each recipient retains a sent, rejected or unconfirmed result; an uncertain send is never automatically repeated. Official history supports this month, the past 90 days and pagination. Accepted status does not assert that credits were awarded.
- **Independent reads:** invitation and proxy credential reads use bounded, stable snapshots instead of waiting behind unrelated quota-refresh locks. Identity changes still block access. Same-account token rotation is accepted only after identity and token validity checks.
- **Live proxy rules:** each account has its own maximum five-hour used percentage, credit permission and two credit floors. Rules can be saved while the proxy runs and apply to subsequent requests. Active requests keep their leases. A changed rule during admission causes rollback before a bounded retry; it does not replay a model request.
- **Subscription and credits:** a verified Pro weekly-only subscription can be used even when its credit balance is positive and credit fallback is disabled. Turning off credits for an account stops it after subscription exhaustion. A custom five-hour cap below 100% also blocks credit fallback at that cap. Missing evidence remains unknown.
- **Refresh all:** the small icon between the account layout selector and Add Account refreshes all saved Codex quota snapshots. It does not invoke a model or membership refresh. Partial results keep the previous snapshots and report the successful count.
- **Overview sizing:** the total-cost cell shows USD and CNY using the user-selected fixed factor of 6.8. Labels distinguish unknown, partial estimates and recorded zero. Default column widths follow the actual formatted numbers, currencies and translated labels. Manual widths persist, and double-clicking a divider restores automatic allocation.
- **Workbench and recommendations:** metadata-only task search, state filters, attention reasons and acceptance counts; clearer quota-snapshot ages; Skills/App filtering and copyable installation prompts. These presentation actions do not start a model or install software.
- **Purchase link:** every macOS build checks the public invitation-credit product page. Unavailable pages, unexpected redirects and malformed responses select the website homepage. The UI reads the checked link from its bundle.

## Verification and previews

The former 1002v4 gallery used synthetic data and has been withdrawn from public display; see [the cleanup record](public-ui-1008v1.md). Native panels are rendered from SwiftUI; the overview is captured in isolated Chromium with network requests blocked. These are source previews, not live-account screenshots.

Local checks cover invitation batches and lifecycle, live policy persistence and admission races, quota-only refresh, purchase-link fallback, numeric-width allocation, manual resizing and bilingual narrow layouts. The final verification counts are recorded in this PR after the candidate completes its build and pure self-tests.

The previous CI run exhausted the entire Go race package's 90-second budget while processing the retained 65 MiB Desktop-input fixture. This update keeps that test and race instrumentation, increases the package budget to three minutes and allows 25 minutes for the macOS job. CI also runs the new purchase-link and home-dashboard checks.

## Remaining limits

The preview bundle is not an installable release. No installed app or running proxy is replaced or restarted. Real invitations, credit awards, paid model calls, long-running reconnection behavior, image generation, phone delivery and original-chat continuation are not established by synthetic tests. The reported live reconnection incident has not been reproduced; the changes address verified lock and quota misclassification cases.

WorkBuddy desktop credits remain unsupported by the current adapter. Reading another CLI's quota does not establish support for routing that provider through the Codex proxy. Windows development remains paused; this update does not change its sources. Website and design-tool work are separate.

Only the existing [PR 13 source branch](https://github.com/BLACKIELF/AgentHub-AiGoodBro/pull/13), documentation and synthetic gallery are updated. This is not a merge, tag or official download release. Private conversation audits, build logs, local paths and account data are excluded from publication.
