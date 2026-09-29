# Source publication record — 2026-09-29

## Candidate scope

This source snapshot is AiGoodBro 9.6.32 (82), snapshot 0929v2, based on `e578b43`. It contains the complete frozen source change set and its accompanying source notices. This change updates PR 13 for review; it is not merged to `main`, and there is no official downloadable package.

The frozen patch checksum was verified before application. Before the CI style pass, all 1,299 source-file hashes in the candidate receipt matched this snapshot. The repository's `make lint` check then reported 443 Swift formatting diagnostics across 18 changed Swift files. Those 18 files were normalized with the repository's `.swift-format` configuration only; formatter output was reproduced byte-for-byte from saved pre-format copies, and Swift parsing passed afterward. The normalized source therefore differs byte-for-byte from the original receipt in those 18 files; no claim is made that the formatted tree has the receipt's original file hashes. The verified 9.6.32 (82) application bundle was checked read-only and used only for pure self-test modes.

The current public index excludes `HANDOFF.md`; `.local-artifacts` and local handoff files remain ignored. Earlier repository history still contains prior handoff material; no history rewrite was performed.

## Fixed upstream sources and licenses

The pinned upstream identities and adaptation scope are recorded in the [Token Monitor desktop source manifest](../Companion/TokenMonitorDesktop/SOURCE.json), [Token Monitor engine source manifest](../Companion/TokenMonitorEngine/SOURCE.json), and [LocalProxy source manifest](../Companion/LocalProxy/SOURCE.json). The manifests pin Token Monitor v0.62.0 at `dcccfb0`, CLIProxyAPI v8.0.2, and the Hazmat wrapper reference at `c112d22`. The corresponding shipped license texts are [Token Monitor](../Companion/TokenMonitorEngine/upstream/LICENSE), [CLIProxyAPI](../Companion/LocalProxy/LICENSE.CLIProxyAPI), and [Hazmat](../Companion/LocalProxy/LICENSE.Hazmat); the complete notice index is [THIRD_PARTY_NOTICES.txt](../Resources/THIRD_PARTY_NOTICES.txt).

## Validation results

The manifest contains 33 pure self-tests. **31 passed and 2 failed.** These failures remain open and are not represented as acceptance:

- `workspace-screenshot`: the offline synthetic fixture measured a compact account row at 137 pt for widths 805 pt and 820 pt, above the 48–90 pt expected range including spacing. The narrow-width assertions failed in both appearance schemes; widths 980 pt and 1280 pt passed. This does not establish current application UI acceptance.
- `token-monitor-ui`: the offline publisher ownership/conflict/retry self-test failed. Its test uses an in-memory feed and an injected API closure with synthetic data; it does not contact GitHub or another network service. The available output does not identify which individual guard caused the overall fixture to return false.

Additional checks:

- `make lint` passed after the scoped formatting pass; Swift frontend parsing passed for the 18 formatted files.
- The default staged `git diff --check` reports 10 trailing-whitespace lines in the pinned upstream `Resources/UpstreamCharts/desktop/dashboard.js`. Its bytes match the SHA-256 recorded in its source manifest, so the upstream file is preserved exactly; staged `git diff --check` passes when this one file is excluded.
- `go test ./...`, `go test -race -timeout=180s ./...`, and `go vet ./...` passed offline in `Companion/LocalProxy`; no dependencies were installed.
- The local-proxy-host fixture passed 186 synthetic checks. The OpenCode native CLI fixture passed. The three CLI quota pytest files passed all 8 tests. The home-dashboard cost projection fixture passed.
- A separate review reported that 57 published screenshots produced 1,885 OCR lines with no privacy-marker hits; the screenshots were not changed in this snapshot.

Historical blueprint-plan paths and one Windows Codex-state SQL test fixture were generalized to example values to remove machine-specific user paths and identifiers. Windows code was not built or run as part of this publication check.

## Verification limits

The validation tests did not make live AI-provider or paid-model requests, or send real notifications. This check did not launch the normal application or proxy, sign in or switch accounts, or verify live routing, image generation, automatic pause/account switching/resume behavior, or Windows runtime behavior. The narrow-width workspace screenshot test and publisher ownership/conflict/retry test remain failed as listed above. Historical interface screenshots document earlier UI states and are not proof that this candidate's current interface passed UI acceptance.

The full Playwright dashboard test was not run because Playwright was unavailable. The desktop adapter test was not run because it exercises a real app-server integration rather than only fake fixtures.
