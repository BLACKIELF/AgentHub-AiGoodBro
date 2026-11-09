# Explicit mixed legacy cooldown recovery — 1023v1

A credential can retain an old account quota together with partially migrated
model records. Even after a fresh official subscription observation shows
capacity, automatic recovery correctly refuses an unknown model error, while
the explicit legacy action previously rejected the mixture of known and unknown
records. This left no supported recovery action for that account.

The existing explicit stopped-helper recovery now accepts a proven credential
quota root alongside unknown legacy model records, proven credential quota
models, and explicitly absent propagated sibling errors with the same deadline.
At least one unknown legacy error must remain. Ordinary model limits,
authentication/permission failures, independent cooldown layers, egress records,
unknown fields, malformed booleans, different deadlines, and duplicate models
are rejected. The all-unknown legacy case remains supported.

Stopped state, absence of account leases, fresh official quota, credential
identity, exact private backup, one-shot confirmation, file version checks and
atomic replacement remain required. Automatic quota recovery, upstream SDK,
routing, participation, credentials and spending policy are unchanged.

Validation: the added mixed-record regression failed against the previous
production source. After the fix, all 119 native recovery fixture checks passed,
including unrelated-account preservation, exact backup, mixed-format recovery,
hidden independent restrictions, malformed provenance, cancellation, concurrent
changes, and the existing identity/quota/lease checks. Memory risk and whitespace
checks passed. Fixtures use isolated synthetic accounts and files.

An actual user-selected pool account completed a minimal model response and a
bounded source review using the existing independent subscription entry point.
That proves independent account usability; it does not prove production proxy
recovery. The review's boundary-test suggestions were added and passed.

Runtime boundary: the already-running helper has no supported hot repair for
these ambiguous records. Applying explicit recovery requires a maintenance
window after in-flight requests finish. No live cooldown record was rewritten,
no running app/helper was replaced, and no production proxy success is claimed
by this source-level validation. Preserve prior delivery artifacts for rollback.
