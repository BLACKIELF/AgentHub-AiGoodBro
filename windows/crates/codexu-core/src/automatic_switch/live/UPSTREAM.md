# Official local daemon transport adaptation — 1030v1

The directory/peer verification and async AF_UNIX wrapper are adapted from
OpenAI Codex, commit `f276b82185f021e7b8d532a3851413bc79a67594`:

- `codex-rs/uds/src/windows_socket_validation.rs`
- `codex-rs/uds/src/windows_peer.rs`
- `codex-rs/uds/src/lib.rs`
- `codex-rs/app-server-client/src/remote.rs`

Upstream: <https://github.com/openai/codex>. License: Apache-2.0, included as
`LICENSE.OpenAI-Codex`. This is a Windows-only read-side adaptation; no upstream
workspace is vendored, no daemon is started, no credential/config file is
modified, and an untrusted listener's ACL is never repaired.

Additional local restrictions bind process creation time to verified system
activation, validate and retain an OpenAI-signed executable file handle, and
require AccountManager's exact system-scope recheck. A bounded nonblocking
Winsock connection precedes the upstream `uds_windows`/`async-io`/Tokio compat
stream wrapper, so monitor cancellation does not leave an unbounded blocking
connect worker.

Only plain WebSocket frames are requested. An unsolicited compression header
is rejected; upstream's optional `zstd-stream-v1` mode is not negotiated.
Complete loaded-thread rosters and official per-thread read/metadata calls are
bounded and kept in memory. No SQLite or archive scan supplies live evidence.
Runtime ThreadStatus and current Turn status are independent: terminal turn
metadata never clears a busy runtime, and a response from an older refresh
cannot overwrite a newer notification. Connection generations increase per
source lifecycle; disconnect, cancellation and protocol uncertainty revoke
previous snapshots. Home matching never case-folds distinct Windows paths.

This observer sends only initialize/initialized, thread/loaded/list,
thread/read (without turns) and thread/turns/list (notLoaded items). It does
not call account/read, getAuthStatus or account/rateLimits/read. At the pinned
source, getAuthStatus with refreshToken=false calls AuthManager::auth(), which
can proactively refresh a credential; rate-limit reads use that same refresh
path. Future source quota/identity work therefore needs its own native writer
authority and AccountManager rotation reconciliation, not an added observer
RPC represented as side-effect free.

The native target needs upstream-reviewed `uds_windows` 1.1.0, `async-io` 2.6.0
and `tokio-util` compat support (existing locked version 0.7.19). These target
dependencies and native execution remain pending root's current CI freeze.
No source-file presence or test definition is a successful native validation.
The in-memory WebSocket/reducer fixtures exercise the actual client source.
Windows-only kernel-handle/creation-time/exit and socket-directory refusal
fixtures are separate from official signed-peer or Desktop acceptance.
