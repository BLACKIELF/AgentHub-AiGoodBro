# Original Desktop owner adapter · 1031v2

Protocol authority is the official OpenAI Windows MSIX `OpenAI.Codex`
26.1027.3384.0, Electron Codex 26.1027.30824/build22943, fetched statically
from `https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix`.
Official deployment reference: https://developers.openai.com/codex/enterprise/windows-deployment/.

Pinned extracted app.asar SHA256:
`6fbedf054a8d8cafaf5c745b40aa59176512e106e0bd6308275ae123b60fd074`.
Exact selected source hashes, raw UTF-8 offsets and extraction receipt are in
task evidence `desktop-owner-authority-1031v1/{AUTHORITY-1031v1.md,authority-receipt-1031v1.json,static-proof-points.json}`.
This adapter implements only the narrow observed messages, not the upstream code.

The Windows endpoint is `\\.\pipe\codex-ipc`, byte-mode LE32 JSON.
Local follower messages omit top-level hostId: initialize0, discovery1,
start2, interrupt4, following1, state11. The broker uses logical client IDs;
handledByClientId is not an OS PID. Generic error envelopes have no method or
handler-origin proof and may be returned after an action executed. All post-write
outcomes except precisely correlated success are Unknown and never auto-replayed.

Production supports only the verified MSIX package/publisher and exact registered
app/ChatGPT.exe image with a valid OpenAI signature. Unpackaged/unknown installation,
unreadable security, or mismatched process/token/session/package is refused rather
than guessed absent. No router, app-server or task is launched. No account change.
The pipe is authenticated before initialize and before mutation, retaining the
server process birth and image lock. The same-user broker remains the logical
owner trust boundary; individual broker client IDs do not identify signed PIDs.

Tests connect only their own synthetic endpoint and exact unsigned fixture image.
That package/signature substitute is cfg(test) only, never production policy.
Host tests do not prove Windows ACL/Job behavior. Native tests do not prove real
official-app acceptance; no real user pipe/account/model/chat is exercised here.
Durable cross-restart incoming-operation claims remain the caller's responsibility.
