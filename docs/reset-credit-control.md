# Reset-credit control

Manual reset-card redemption uses two separate confirmations. The 1005v2 / 124 candidate also adds an
explicitly opt-in expiry policy described below. A one-time manual redemption never enables that policy.
No public CLI, Hub or URL redemption endpoint is exposed.
The first performs a fresh `account/rateLimits/read` and shows the account number, remark and
expiry of one specifically verified card. The second repeats the account, explains that eligible windows
reset and the weekly reset time changes, and has the sole destructive button for one card. Cancellation, selection/identity
change, challenge expiry, or view disappearance invalidates the sequence.

The implementation adapts—not copies—the Apache-2.0 OpenAI Codex `rust-v0.154.0` protocol snapshot at
[the tagged protocol source](https://github.com/openai/codex/blob/rust-v0.154.0/codex-rs/app-server-protocol/src/protocol/v2/account.rs): `app-server-protocol/src/protocol/v2/account.rs` defines card details, request fields,
and outcomes; `protocol/common.rs` maps `account/rateLimitResetCredit/consume`; the app-server and
backend-client processors establish timeout/idempotency and exact-`creditId` behavior; and the TUI
establishes available-card filtering and earliest-expiry selection. The product behavior is also
described by the [official banked resets article](https://help.openai.com/en/articles/20001498-how-banked-codex-resets-work).
The activity reservation uses the same normalized account key and Hub alias as login, warm-up and CLI launch; a configured Hub must report idle. Managed accounts use their isolated home and account-scoped reservation, so unrelated Codex processes no longer block redemption. The system-home path retains the conservative process gate. The pipe reader has a 15-second deadline, nonblocking polling and a total 1 MiB output limit so a retained descendant pipe cannot keep its reader alive.

Reusing the existing Swift app-server process, per-home credential gate, process bounds, shared activity
lease, and private atomic store is smaller and safer than importing the Rust clients or adding a manager.

Only detailed rows whose `resetType` is `codexRateLimits`, status is `available`, identifier is non-empty,
and expiry is still future are eligible. Account IDs and card IDs are bounded and reject control
characters. Reset counts and timestamps accept only exact bounded JSON integers: booleans, fractions,
nonfinite values, and overflow fail closed. An absent or JSON-null `expiresAt` follows the official
no-expiry schema; any present malformed value invalidates the details. Duplicate card IDs, mixed or
oversized detail arrays, and missing detail remain unavailable rather than selecting an ambiguous card.
Purchased usage balance is never used as reset-card evidence.

The consume conversation re-reads account identity and the exact chosen card before sending one RPC.
It checks the card expiry against a fresh clock reading and checks the two-minute review lifetime again
after executable/version/process/app-server preflight, immediately before the write. It always supplies
`creditId`; an uncertain request is never retried automatically.

RPC stage, terminal result, write permission, and the "consume may have been sent" bit share one lock.
Only the expected response ID can advance `initialize -> rateLimits -> consume`; duplicate or
out-of-order IDs are ignored. Timeout, EOF, output-bound failure, and shutdown acquire that same lock and
close write permission before publishing a terminal result. If timeout wins before response 2, the late
response sees terminal state and cannot write consume, so the result is `requestNotSent`. If response 2
wins, it validates and performs the consume write while holding the lock; timeout waits and then reports
`outcomeUnknown`, retaining the attempt because the write may have reached the child. Automatic admission
adds a cancellation lock around the actual write; cancellation never acquires the RPC stage lock, so it
cannot form a reverse lock cycle.

One logical attempt has one UUID idempotency key. Before the RPC, Next stores a 0600 Next-scoped pending
envelope in a verified 0700 directory. Creation and clearing use
`DispatchParticipationSync.withSnapshotLock` plus `writeSnapshot`: each transaction re-reads the bounded
16 KiB file while locked, compares the expected bytes, atomically replaces it, and re-reads the result.
Creation never replaces an existing pending attempt. Clearing requires the exact expected account hash,
profile, card, expiry, and idempotency key, so a different process cannot erase another account's attempt.
Malformed, oversized, wrong-owner, linked, or group/world-accessible state fails closed.

An unknown outcome retains the pending attempt. The only allowed product retry repeats both explicit
confirmations for the same account and exact card and sends the same idempotency key; no new key is
generated while uncertainty exists. A different account or card remains blocked. If the recorded card is
no longer reported as available, simply starting the flow again cannot reconcile or clear the attempt;
there is intentionally no bypass or clear control. Raw account/card identifiers, email, response bodies,
and private paths are never rendered or logged.

## Optional expiry policy · 1005v2

The purpose is to reduce reset cards expiring unused when their owner forgets to redeem them. It is off
by default and requires per-profile consent bound to the hash of the verified official account ID.
The default lead time is 30 minutes, configurable from 1 to 1440 minutes. The app must remain running;
sleep, offline periods, busy accounts, verification failures or an already expired card can prevent use.

Only independent managed accounts are eligible. The current desktop account and managed mirrors of
that same official identity are excluded. Startup and desktop identity changes first revoke pending
admission; a successfully saved fresh identity snapshot is required before automation resumes. An
unverified identity is retried at most once per minute, without concurrent identity reads. Missing Hub
alias, unknown occupancy, activity lease conflicts and stale quota evidence block the attempt.

A local timer inspects due cards once per minute. It does not refresh the entire account pool every
minute. Candidates are deduplicated by official identity; a blocked first account does not prevent later
eligible accounts from being considered. A fresh official review chooses the exact earliest available
card. The reader rechecks identity, card and expiry before the actual RPC write. Changing settings,
removing the account, changing its identity/home or stopping the app revokes unsent admission. A request
that already passed admission still needs its outcome reconciled.

An atomic private auto journal claims each account/card attempt before the existing pending record and
RPC. The terminal auto result is persisted before the pending record is cleared. Only the matching
attempt, account, card and expiry can finish a claim. Crashed or uncertain journal entries survive restarts and block replay. When the runner encounters
them again, the account page reports that manual review is needed; restarting does not issue another key. Expired terminal records may be
compacted with a rejection watermark, while pending and uncertain records are preserved. Corrupt or
oversized storage fails closed.

`reset` means a confirmed reset. `noCredit` and `alreadyRedeemed` stop that card and refresh data without
claiming a new redemption. `nothingToReset` waits at least 60 seconds and also requires a changed quota
fingerprint from the same official review before another attempt. A positively unsent request may be
reviewed again after cooldown; unknown outcomes are never automatically replayed.

The Codex account page provides the account toggles and the latest in-session outcome status. An existing opt-in
can still be switched off when its account becomes temporarily ineligible. Manual redemption retains
its two confirmations. No real automatic redemption was performed during candidate development;
isolated tests use synthetic RPC, identity, activity and storage fixtures.

## Receipt observations · 0930v2

The reset-message panel separates public predictions from verified personal balances.
Balances are grouped by verified account ID so mirrored profiles are counted once.
A receipt is saved only when two chronological, successful official quota snapshots
for the same account and limit show a positive balance increase. The record stores
both observation times, not a guessed server grant timestamp. First reads, unknown
counts, unchanged mirrors and older observations never create receipts. Each profile
keeps at most 32 observations and clears them when its bound account changes.

Feishu reset cards show the change, current quota/balance, expiry details and detection
time in Beijing time. Public forecasts remain unconfirmed even after their expected
window ends; public announcements do not prove receipt by a particular account.


## Integration

The main workspace places the control on independently signed-in account cards outside preview mode and supplies the card's profile identity and existing refresh callback. It does not change the monitored or desktop account:

```swift
ResetCreditButton(
    profile: profile,
    selectedProfileID: profile.id,
    hubAccountAlias: hubAccountAlias,
    onConfirmedResult: { refreshProfile(profile.id) },
    displayNumber: displayNumber
)
```

`onConfirmedResult` runs for a parsed official outcome (`reset`, `nothingToReset`, `noCredit`, or
`alreadyRedeemed`) and should refresh limits. Result copy states only the concrete outcome and that limits
will refresh.

The SwiftUI source keeps two separate `alert(isPresented:)` stages. Each stage is reachable only from
its preceding explicit button, every stage has Cancel with the cancel shortcut, and the final destructive
button has no default-action shortcut. Alert dismissal calls `cancel()` only when that same stage remains
active, so advancing from a deliberate button does not cancel the next stage or consume automatically.

## Validation and installation boundary

Fifteen isolated checks compile the production controller with synthetic RPC and activity boundaries.
They cover both confirmations, cancellation at each stage, changed identity, expired review, occupied
account/Hub, duplicate final actions, one refresh callback, unknown outcomes and idempotent reconciliation.
The official installed CLI protocol schema was re-generated locally before the explicitly requested
live redemptions. Two requested accounts each returned `reset`; an identity-matched follow-up read
confirmed exactly one fewer card and restored limit windows. This is protocol evidence, not a test of
the candidate SwiftUI dialogs. Private operation receipts remain outside published source.

The installed build was last verified as 9.6.64 (114); candidate 124 is not installed. Candidate build
qualification is recorded separately in the current handoff. Installed dialog interaction and real candidate CPU
measurements still require a later normal app lifecycle; the ordinary previews exclude redemption.
