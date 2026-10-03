# Local Proxy validation · 0928v1

2026-09-28: synthetic adapter validation passed against pinned CLIProxyAPI v8.0.2 (`4a2c81864f31f39308e946c4c65e72147855da6e`). The following initial engine checks are supplemented by the Desktop adapter and installed-host checks below.

- `go test -mod=readonly -race -timeout=90s ./...`: 10 tests passed; no race reports.
- `go vet -mod=readonly ./...`: passed.
- `CGO_ENABLED=0 go build -mod=readonly -trimpath -buildvcs=false -ldflags='-s -w'`: passed on macOS arm64.
- Built helper `--version`: exact expected version string.
- Separate helper process: synthetic startup → JSON ready → bearer-authenticated GET /v1/models returned the explicit fixture model → stdin stop → JSON stopped → exit 0. Listener no longer accepted connections; stderr was empty.
- Go module resolution verified the downloaded v8.0.2 module's origin commit and checksums against SOURCE.json. No absolute replacement is present in go.mod.

The tests cover lease admission before upstream transmission, 429 failover and next-request cooling, 401 fallback without retained/refresh credentials, all-busy fail-closed behavior, route/auth restrictions, no replay after partial SSE delivery, concurrent account exclusion, cancellation release, cooldown restart preservation and 0700/0600 permissions, symlink rejection, redirect blocking, ambiguous release events, expiry rejection before transmission, and heartbeat failure cancellation/cleanup.

These are fixture checks using loopback HTTP and a fake Unix control bridge. No real credentials, accounts, OAuth refresh, ChatGPT request, desktop app launch or installation was performed. Real host identity/quota/lease behavior and desktop integration require the host component's own validation. Intel packaging is owned by the parent build workflow and was not executed here.

## Cross-language process fixture

`python3 fixtures/test-cross-language.py --helper <built-helper>` passed both cases using the production Swift LocalProxyBridge class and actual request/reply DTO source:

1. Production Go executable: startup → authenticated models → Responses tries A/B through the actual Swift Unix socket → busy rejection returns HTTP 503 → stdin EOF → stopped and clean exit. No upstream request occurs.
2. Go test executable containing the same runtime: Swift returns synthetic leased access-token snapshots → loopback upstream returns A=429 and B=success → response contains the B fixture → both attempt leases released through Swift → stdin EOF and clean exit. Bridge ends with held=0.

The second case injects a loopback upstream only through `_test.go`; no upstream override exists in the production helper. The Swift bridge transport and Codable protocol are production source, but the admission policy in this cross-language fixture is synthetic. Actual host policy/credential-reader tests remain the host suite's responsibility. Both children returned no stderr output. No production files were changed for this fixture.

## Explicit system network proxy

After adding optional startup networkProxy, all 12 tests passed under race detection. The added validation table rejects credential-bearing URLs, missing/invalid ports, paths/query/fragments, control characters and unsupported schemes. The integration fixture sends a TLS Responses request through a loopback HTTP CONNECT proxy, with synthetic lease/access identity. It verifies the selected proxy is used even when environment proxy variables point elsewhere; CONNECT carries neither upstream Authorization nor Proxy-Authorization; stdout contains no proxy URL or token; no refresh/access token is retained by Manager. Only loopback servers were contacted. Production retains its fixed ChatGPT origin and redirect/expiry checks.

## Desktop adapter and installed native host

The subsequent full Go race suite passed with Desktop connection validation, field-preserving JSONL rewrites, child-process shutdown, and both compact routes. Compact fixtures verify lease admission before upstream transmission and release after the response.

`scripts/test-local-proxy-desktop.py` passed using the real bundled Codex app-server and a loopback mock provider: new thread, cold resume, history listing with the original provider filter, and two completed turns. Both requests retained GPT-6 Sol / Max, and the resumed request included the preceding reply. This fixture uses no live credentials or accounts and does not launch Desktop UI.

AiGoodBro 9.6.22 (72) was installed on macOS arm64 after 33 app self-tests, 106 isolated native-host checks and runtime resource/signature verification. The installed native host completed a real GPT-6 Sol / Max request with HTTP 200, matching model and verification response, an accepted native lease, and unchanged Desktop auth/global-config hashes. This live API result is distinct from the synthetic bridge tests above. Full Desktop UI routing and account rotation during resumed Desktop work still require live acceptance; no formal 2.0 release is asserted.

The host suite now includes short credential-lock contention beyond the old two-second limit, a bounded twelve-second timeout with a distinct credentials_busy state, and gate release. All 106 host checks passed. The installed build 72 also completed a live request using its configured priority account with eight non-Pro accounts enabled. These checks do not establish Desktop UI routing.
