# Source publication record — 2026-09-29

## Candidate scope

This is AiGoodBro 9.6.32 (82), source follow-up 0929v3, based on the published `c34c96a` candidate. It retains the frozen source baseline and adds the macOS repairs below. This change updates PR 13 for review; it is not merged to `main`, and there is no official downloadable package.

For the earlier 0929v2 baseline, the frozen patch checksum was verified before application. Before the CI style pass, all 1,299 source-file hashes in the candidate receipt matched this snapshot. The repository's `make lint` check then reported 443 Swift formatting diagnostics across 18 changed Swift files. Those 18 files were normalized with the repository's `.swift-format` configuration only; formatter output was reproduced byte-for-byte from saved pre-format copies, and Swift parsing passed afterward. The normalized source therefore differs byte-for-byte from the original receipt in those 18 files; no claim is made that the formatted tree has the receipt's original file hashes. That baseline used a verified 9.6.32 (82) bundle for pure self-tests. The 0929v3 results below instead use a newly compiled candidate; its Swift sources were hashed before compilation and checked again afterward.

The current public index excludes `HANDOFF.md`; `.local-artifacts` and local handoff files remain ignored. Earlier repository history still contains prior handoff material; no history rewrite was performed.

## Fixed upstream sources and licenses

The pinned upstream identities and adaptation scope are recorded in the [Token Monitor desktop source manifest](../Companion/TokenMonitorDesktop/SOURCE.json), [Token Monitor engine source manifest](../Companion/TokenMonitorEngine/SOURCE.json), and [LocalProxy source manifest](../Companion/LocalProxy/SOURCE.json). The manifests pin Token Monitor v0.62.0 at `dcccfb0`, CLIProxyAPI v8.0.2, and the Hazmat wrapper reference at `c112d22`. The corresponding shipped license texts are [Token Monitor](../Companion/TokenMonitorEngine/upstream/LICENSE), [CLIProxyAPI](../Companion/LocalProxy/LICENSE.CLIProxyAPI), and [Hazmat](../Companion/LocalProxy/LICENSE.Hazmat); the complete notice index is [THIRD_PARTY_NOTICES.txt](../Resources/THIRD_PARTY_NOTICES.txt).

## Validation results

The rebuilt, optimized macOS arm64 candidate passes **all 33 pure self-tests**. The earlier 31/33 baseline and macOS CI compile failure were repaired as follows:

- WebKit: the test delegate now dispatches renderer callbacks to `MainActor`, matching the production coordinator. Local optimized compilation and the WebKit bridge self-test pass. Remote validation against the CI SDK is tracked in [PR 13 checks](https://github.com/BLACKIELF/AgentHub-AiGoodBro/pull/13/checks).
- `workspace-screenshot`: long account labels caused `ViewThatFits` to select a tall card before truncating the label. Explicit ideal widths retain the existing compact columns and all controls. Row height is now 74 pt, including spacing, at widths 805, 820, 980 and 1280 pt in both appearances; the original 48–90 pt assertion is unchanged. Synthetic narrow-window rendering was also inspected visually.
- `token-monitor-ui`: the first synthetic message was rejected during ID validation in the optimized build. A small reproduction combined the ID predicate with the existing control-character filtering expression and reproduced the failure; an explicit predicate closure fixes it while keeping the same ASCII allowlist. New regression cases accept all 64 allowed characters and reject empty, oversized, punctuation, whitespace, control-character, Chinese and emoji IDs. Owner authorization, CAS conflict, retry deduplication, ambiguous-write readback and outbox assertions remain intact. The fixture uses an in-memory API and does not publish a real message.

Current local checks:

- Optimized Swift compilation, `make lint`, `git diff --check`, all 33 manifest self-tests and 132 isolated dispatch-participation tests pass. The dispatch suite skips its root-only unowned-file case when running without root.
- Candidate deep/strict signature verification, companion and local-proxy resources, the frozen statistics engine/runtime smoke check, five runtime PNGs, and the Token Core ASAR/signature checks pass. The installed Token Core helper was read and copied only after the current source verifier accepted its pinned resources, adapter and signature; the isolated copy was verified again. The main executable was compiled from this candidate, not copied from the installed app.
- No installed application was replaced or restarted. The six public screenshots remain the actual 2026-09-29 build 82 captures documented in [their source notes](images/0929v2/README.md); they were not regenerated from synthetic fixtures.

Earlier baseline checks retained for context:

- `make lint` passed after the scoped formatting pass; Swift frontend parsing passed for the 18 formatted files.
- The default staged `git diff --check` reports 10 trailing-whitespace lines in the pinned upstream `Resources/UpstreamCharts/desktop/dashboard.js`. Its bytes match the SHA-256 recorded in its source manifest, so the upstream file is preserved exactly; staged `git diff --check` passes when this one file is excluded.
- `go test ./...`, `go test -race -timeout=180s ./...`, and `go vet ./...` passed offline in `Companion/LocalProxy`; no dependencies were installed.
- The local-proxy-host fixture passed 186 synthetic checks. The OpenCode native CLI fixture passed. The three CLI quota pytest files passed all 8 tests. The home-dashboard cost projection fixture passed.
- A separate review reported that 57 published screenshots produced 1,885 OCR lines with no privacy-marker hits; the screenshots were not changed in this snapshot.

Historical blueprint-plan paths and one Windows Codex-state SQL test fixture were generalized to example values to remove machine-specific user paths and identifiers. Windows code was not built or run as part of this publication check.

## Verification limits

The validation tests did not make live AI-provider or paid-model requests, or send real notifications. This check did not launch the normal application or proxy, sign in or switch accounts, or verify live routing, image generation, automatic pause/account switching/resume behavior, or Windows runtime behavior. The repaired offline tests do not establish live application acceptance. Historical interface screenshots document their capture-time states and are not proof that the current source passed every UI workflow. Windows development and validation are on hold; no Windows code or workflow was changed in this repair.

The full Playwright dashboard test was not run because Playwright was unavailable. The desktop adapter test was not run because it exercises a real app-server integration rather than only fake fixtures.
