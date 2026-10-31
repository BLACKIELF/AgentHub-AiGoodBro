# Statistics cache and bridge cleanup review — 1023v2

This review adds persistent isolated-source scanner caches and confirmed child cleanup to build 154. It preserves the prior frozen source review, whose evidence SHA-256 is `286d07a10a34c6d2a6c620800417804eb4cf2e341047ee4c5f20732ebf36dfd8`, including its upstream selection, plan-type propagation and disabled authentication adaptations.

## Reviewed behavior

- Pass the request cache directory into each usage source. Isolated Codex and log roots use a stable cache namespace derived from canonical path, path role and provider set. A display ID change retains the cache; unrelated roots remain isolated. User-home source behavior is unchanged.
- Validate an optional cache directory as an absolute path without NUL bytes, reject a symlink at the source-cache leaf, and initialize the cache before creating the temporary source home. Initialization failure therefore leaves no temporary source home.
- Preserve the caller's temporary directory for isolated source execution and test fixtures.
- Keep tracked child processes registered when a signal error does not prove exit. On bridge timeout or cancellation, await actual exit confirmation, send SIGKILL after the existing 250 ms escalation interval, and bound unconfirmed cleanup at 750 ms from cleanup initiation. If exit cannot be confirmed, report the existing internal-error envelope and a sanitized diagnostic instead of claiming successful timeout/cancellation cleanup.
- The original native host retains its dedicated process-group ownership and cleanup. No timeout ceiling, provider, account, credential route or billing calculation changes are included.

## Exact production delta

Only these six entries of the 1,183-file source inventory change. The other 1,177 file pins, dependency lock, native runtime pins and security adaptations remain unchanged. The packaging verifier and source-drift checks are retained.

| Source path | Previous SHA-256 | Reviewed SHA-256 |
| --- | --- | --- |
| `bridge.cjs` | `0b6bd05ab840edcea40390f58ce043c25987f767d9ccd91e3deef07635f01250` | `711786b92406bf2af6fb4de96b13f5960be09ead83a8774cf8e6042d180631cd` |
| `lib/handler.cjs` | `9a161237046d1742f959c33dfeaa1f32689538908f84c17eec6c8a2384e24900` | `c6a8b705c0df53decac2dacf2c2832c08c97edc259a32e20807025059ca918ee` |
| `lib/protocol.cjs` | `5c0b57965a9f419884cbd2dd356340623f60ab7486deba4565c2501fd83ef83a` | `6116ed55617a15ad6073022538f2ffdac3a7bd3ad6ac82653620e5fee7af0bd9` |
| `lib/runtime/descendants.cjs` | `f32d00de388310cbe4ffe8ff66beee38dec5956e55a6a55c04b2b3f9baeca283` | `87743f791758518b3fdebbce80ab912fe3029ece976bc74a397ad014b43c357c` |
| `lib/runtime/scope.cjs` | `8dba2bf0ab74e31c06db1d0473a666f667d6ecde7a4537a6cca00babe3b77ded` | `e8792a38fdbbae55cfd13164a4fa0ff85be45d2da7451ad4b67f5c640ee906d7` |
| `lib/runtime/source-scope.cjs` | `a70de3c0a820781ee20a5475ff37980b07da77aa9abbd102bb17f5949aa0133e` | `d71f80fcb6c11b4f581f18195fb8458c63374be45b098c3b2356573c6ea140af` |

## Validation evidence

- A regression fixture reproduced a scanner surviving bridge timeout before the fix. The fixture isolates its process group and cleans up only its own child.
- All 73 engine tests passed, including persistent cache reuse, root isolation, cache-init failure without a temporary-home leak, timeout/cancellation against a child that ignores SIGTERM, signal-error handling, bounded unconfirmed cleanup, the bridge internal-error response, and repeated cancellation preserving the first reason and cleanup promise.
- All native engine fixtures passed, including cancellation, timeout, held/closed-pipe descendants, bounded completion and preservation of an unrelated host descriptor.
- An independent Oracle browser review reported no confirmed new production blocker. Its two additional suggested boundary tests (unconfirmed bridge cleanup and repeated cancellation) were added and passed. Review output is advisory; local tests and exact source pins provide the acceptance evidence.
- Earlier small, real Codex-session checks preserved source bytes and token totals between cold and warm scans. A controlled incremental fixture matched warm and fresh-cold totals after append and new-file changes.

Evidence digests (local logs retained separately; no account data is included here):

| Evidence | SHA-256 |
| --- | --- |
| Engine regression log, 73 passed | `f4ed65485bf63ad8abb65b5435344271e173b942c8c2630663c0e248c1248f4b` |
| Native host lifecycle log | `a39727d40c5931b7a4cbb0c14b3f8f2430096aa15093a7123fecad419a0f71dc` |
| Oracle advisory review | `02b380466764fa68db265722a4d8dcb0ab50bb8a59e2358082ed9a6e325626d5` |

## Acceptance limits

This source review does not certify the large system-wide history scan, final account-wide totals, installed-app behavior or Apple notarization. The roughly 40 GB system history was not rescanned during concurrent user work. Direct in-process handler reuse after cancellation remains outside the production one-process-per-request path and is not changed here. The standalone registry confirms its directly tracked children; it does not claim arbitrary descendant-tree ownership. Packaged-app checks are recorded separately after the candidate is built.
