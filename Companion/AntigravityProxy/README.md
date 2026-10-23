# Local provider account pool — 1022v1

This helper embeds the pinned CLIProxyAPI v8.0.38 executors and translators. It does not run CLIProxyAPI's service, management API, file credential store, watchers, plugins, request logger or updater. The native AiGoodBro host owns Keychain and the browser.

## Entry and storage

The native host launches `aigoodbro-antigravity-proxy` with a clean environment and private stdin/stdout pipes. The first stdin line is a strict JSON bootstrap: `schemaVersion: 1`, `clientKey`, `port`, optional `networkProxy`, and `accounts`. Each account contains an enabled flag, concurrency limit, optional persisted cooldown epoch, and a typed credential obtained only from the app's dedicated Keychain namespace. No path, command, general configuration or credential-export field exists.

Credentials never go into argv, HTTP responses, request logs, source fixtures, or token files. The parent stores masked account metadata separately. `persist_credential` is a private IPC message, not a UI/log event: the parent must verify provider/account/generation and acknowledge a successful Keychain commit with `persist_result`. Refreshed material cannot become active before that acknowledgement. A removed generation cannot be restored by a late refresh. Failed persistence after a rotating refresh requires reauthorization.

The helper starts only on explicit user action. Closing stdin or terminating this exact child stops its listener. The host waits for confirmed child exit during application termination.

## Public listener

The listener binds IPv4 `127.0.0.1` only (native default port 18081). It requires the exact loopback Host header and the local client key in Bearer, `X-Goog-Api-Key`, or `X-Api-Key`; conflicting keys, cross-site browser headers and unknown routes are rejected. There is no management or OAuth HTTP endpoint on this listener.

Provider roots are `/providers/antigravity`, `/providers/claude`, `/providers/kimi`, and `/providers/xai`. Only adapters compiled and registered into the helper appear in `ready.providers`. The unprefixed compatibility routes always use Antigravity. Provider roots and account identities isolate even identical model IDs.

Routes under each root:

- `GET /v1/models`, `GET /v1beta/models`
- `POST /v1/responses`, `POST /v1/responses/compact`
- `POST /v1/chat/completions`
- `POST /v1/messages`, `POST /v1/messages/count_tokens`
- `POST /v1beta/models/<id>:generateContent`, `:streamGenerateContent`, `:countTokens`

Each selected adapter determines which translations/actions its verified upstream supports. The existence of a route does not assert that a particular provider supports every action. xAI subscription inference is restricted to the official CLI chat-proxy Responses route; compact and API-billed inference routes are rejected. Stateful Responses retrieval and background requests are not implemented; callers send full request history.

## Authorization and pool

Antigravity uses the upstream public desktop-client registration plus a native loopback callback bound to a random IPv4 loopback port. It adds S256 PKCE, random state, strict callback Host/path/method/state validation, one-shot consumption, a five-minute deadline and cancellation. The native host validates the browser URL before opening it. Google identity and project discovery use fixed TLS endpoints. No current IDE/CLI token is imported and no system identity is switched.

Other provider adapters register their independently verified browser/device authorization flow. `open_browser` may contain a user-visible device `userCode`; it must never contain a secret device code or token. Refresh/token endpoint selection is fixed inside adapters, never supplied through IPC.

Accounts have a default concurrency limit of one (bounded 1–8), balanced admission, in-flight counts, cancellation on removal, 429 cooldown, and reauthorization state on 401/403. Quota retries can select another account only before output starts; a partial stream never replays through another identity. Credits-based fallback is not enabled.

Model IDs come from each account's actual upstream catalog, refreshed on startup, after authorization, on explicit refresh and every five minutes; catalog admission expires after fifteen minutes. There is no static fallback model list. Antigravity explicitly exhausted (`quotaInfo.remainingFraction <= 0`), malformed quota and expired reset-time models are excluded. A missing quota field means unknown remaining quota, not a fabricated allowance. Other providers' catalogs may not expose balances; successful model discovery alone is not proof of remaining subscription quota. Actual quota errors close admission and enter cooldown.

## IPC events and commands

Events are `ready` (port and supported providers), `snapshot` (masked accounts, per-provider `providerModels`, legacy Antigravity `models`), `open_browser` (provider/session/URL/optional user code), `persist_credential`, `auth_result`, and fixed-code `error`. Private credential events must never be forwarded into diagnostics or UI.

Commands are `auth` (provider/request ID), `cancel_auth`, `persist_result`, `remove` (account ID/generation), `set_enabled`, `snapshot`, `refresh_models`, and `shutdown`. The JSON vocabulary is closed and bounded. All credentials include provider, account ID, generation, masked identity, access/refresh tokens and expiry; only allowlisted typed fields exist for project, account subject, organization, ID token, device ID and refresh expiry.

## Validation and limits

Run `go test -mod=readonly -race ./...` and `go vet -mod=readonly ./...`. `bash test-native-host.sh` compiles a signed mock child and uses an in-memory Keychain substitute: it does not read real credentials, open a browser, listen on an external network, or contact a provider. Fixtures cover PKCE/state/replay, four-provider catalog isolation, provider/prefix mismatches, cancellation and revocation after late IPC, refresh persistence failures, pool limits and cooldown. SDK tests use synthetic upstream responses, preserve production origin/route guards and replace only the dial-capable HTTP transport. They verify Antigravity Responses/Gemini translation and Claude/Kimi/xAI gateway Responses text/function calls in both streaming and nonstreaming modes, including SSE separators and terminal events. The root packaging script collects dependency notices, signs the helper and verifies its manifest.

Real browser consent, provider token exchange/renewal, real quotas, agy model display-name selection and helper-model availability, real Codex generations, and installed application behavior remain separate live acceptance steps. The Antigravity IDE/Desktop's proxy configuration is not established by this CLI integration. No test fixture proves those live behaviors.
