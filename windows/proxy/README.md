# Windows LocalProxy — 1029v1

The Windows native host uses the existing `Companion/LocalProxy` router and its
pinned CLIProxyAPI v8.0.38 metadata patch. No Mac implementation is changed.
`build.py` stages the small adapter, verifies exact platform-boundary hashes,
adds Windows glue, then calls the shared checksum-verifying `go.py` builder.
It never copies the full repository or rewrites the shared module cache.

Go 1.26+, Python 3 and the checked-in dependencies are needed at build time.
The resulting helper needs no Go/Python/Node runtime. Choose a task-owned
absolute build directory and set `GOMODCACHE`, `GOCACHE`, `GOTMPDIR` and `TMPDIR`
to the existing task cache before running these commands from the repository:

```text
python windows/proxy/build.py --build-root <build-root> --target windows-amd64 build -mod=readonly -trimpath -buildvcs=false -ldflags="-s -w" -o <bundle-resources>/aigoodbro-local-proxy.exe .
python windows/proxy/build.py --build-root <build-root> --target windows-amd64 test -mod=readonly -run "^TestWindows" .
python windows/proxy/build.py --build-root <build-root> --target host test -mod=readonly ./...
```

Run the second command on Windows. The shared full regression suite still uses
POSIX fixtures; run it on the host platform, with `CGO_ENABLED=1` and `-race`
for the race run. Windows-specific tests exercise the IPv4 TCP control protocol,
protected owner ACLs, reparse rejection, cooldown persistence and an owned
kill-on-close Job Object. Cross compilation proves only compilation.

Each successful command saves an input/provenance receipt in the chosen build
root. Receipt arguments distinguish execution from `test -c`; an output hash
binds a built binary. Distribute the existing `SOURCE.json`, both licenses,
notices and `upstream-patches` alongside the helper.

For Tauri bundling, run this before the native build:

```text
python windows/proxy/prepare-resource.py --build-root <build-root> --target windows-amd64
```

It prepares `windows/apps/codexu-tauri/src-tauri/resources/proxy/` only after Git
confirms that generated folder is ignored. The helper is built and PE-checked;
Windows also runs its no-socket `--version` check. It copies the pinned notices,
licenses and patch and generates `models.json` directly from the current Mac
`CodexExecutionPreference.Model` cases. `resource-receipt.json` binds every file
and the exact Swift declaration; nested display switches never become models.
The optional `--resource-dir` selects an explicit task-owned candidate folder.

## Native integration

Create one `Arc<LocalProxyService>` with a native `ProxyAccountGate` and encrypted
`ProxySecretStore`. Register its result in the command module's `LocalProxyState`
so initialization failure returns an explicit feature error while the App opens.
No fixture implementation belongs in
the product. `activate_run` must bind a unique durable run before spawn.
`reserve` rechecks identity, generation, official quota, policy and the same
cross-process exclusion used by account switching. `resolve` first installs a
deny marker for the exact tuple. An absent or unknown record never authorizes
credentials. `retire_run` clears only a confirmed owned exit.

The service exposes saved preferences, start/stop/status, explicit connection
copy, safe `self_check`/`probe` commands and atomic Plus 5h used-limit editing.
Network/port/key-mode changes require a stopped helper. Dynamic participation,
priority, last-use and manual order affect subsequent requests; removal also
revokes old waiting/retry admissions, while admitted responses retain their
leases. Unknown quota fails closed. Pro/Prolite inherit last-use and can opt out.

`start_recovery_monitor()` is an explicit lifecycle action that returns an owned
`ProxyRecoveryMonitor`. Keep the handle and cancel/join it on shutdown. Its
default-off saved setting never starts a previously stopped proxy. Recovery
requires confirmed child exit and successful exact retirement. User Stop
invalidates pending starts immediately. Recovery is limited to three attempts
per command epoch; a minute of healthy running resets that budget. Confirmed
Force Quit may call `force_stop_owned()`; it does not declare lease cleanup.
The lifecycle monitor also observes owned exits and fatal lease events while
recovery is disabled. Fatal lease events immediately fence new admissions;
confirmed child exit must precede retirement and any later restart.

The control listener is ephemeral `127.0.0.1` TCP with an independent random
256-bit key supplied only over helper stdin. Client bearer keys are separate,
with persistent keys stored by the encrypted native vault. Windows cooldown and
Desktop connection files require protected owner ACLs and reject reparse paths.
Only held child handles are terminated; Windows Jobs own their descendants.

Source and receipt text I/O explicitly uses UTF-8 with LF output. Generated
resource files are copied as verified bytes. No global `PYTHONUTF8` setting is
required. The builder regression runs a real child interpreter with UTF-8 mode
disabled and cp1252 default text streams: its non-ANSI negative control must
fail, while actual staging and resource-byte readback must succeed.

The Windows Desktop wrapper preserves the shared argument and RPC transforms,
uses the same authenticated gateway and a held-handle Job for the backend. It
cannot use POSIX exec replacement. The explicit connector discovers the official
`OpenAI.Codex` MSIX manifest, then separately validates the GUI and CLI through
the existing embedded/catalog Authenticode verifier and pins executable handles.
It refuses an existing or unidentifiable Codex process and accepts managed
account IDs, never browser-supplied executable or credential paths. The native
GUI is assigned its private Job atomically by Windows 10+ process creation
(`PROC_THREAD_ATTRIBUTE_JOB_LIST`), remains suspended until its receipt is
durable, then resumes. A crash cannot strand a process between creation and
Job assignment.

The account module supplies one persistent private Desktop home per managed
account. A durable writer claim fences every other refresh/write actor for that
identity. The same already-owned Desktop app-server supplies account/read and
account/rateLimits/read over its existing RPC stream. Internal replies stay out
of the GUI stream; authenticated evidence binds writer, backend, current proxy
run, observation time and an unchanged auth digest. The host reads current auth
read-only and rejects unknown/stale/mixed-generation evidence without falling
back to an old vault grant. No second refresh actor is started while Desktop runs.

Only confirmed exit of every held Job descendant allows the official verifier
to import the current grant to the encrypted vault, release the exact writer and
remove the transient loopback connection. History and the persistent home stay
available for the next connection. Cancellation and transient cleanup failure
retain exact guards for retry; unknown exit retains the writer/home. Prepared
but never launched failures have a separate verified abandon path.

A proxy restart can rebind the same held Desktop writer and backend to the new
run. Its private connection is replaced atomically; subsequent gateway requests
reload the endpoint/key. Old-run evidence cannot revive the new connection.
The lifecycle monitor must be retained by the application even when no panel is
open. Preparing a connection reports Prepared; spawning reports Launched with
unknown routing verification. Real Windows Codex Desktop peer authorization,
installed discovery/launch, historical-thread visibility and long-duration
refresh/inference remain separate acceptance checks.

## Confirmed owner recovery

`LocalProxyService::recover_stale_owned_run()` and
`ProxyDesktopConnector::recover_stale_owned()` return `Result<(), ProxyFailure>`.
Create the real account/gate/services first, then run helper recovery followed by
Desktop recovery on a background startup worker. Neither operation starts the
proxy, Desktop, a replacement writer, or an inference request.

Each new Windows launch writes a DPAPI-bound receipt for the exact native owner
PID/birth/SID/session/image hash and writer/profile/identity/initial generation. A named
owner-private Job carries kill-on-close, no breakaway, and a fresh nonce. Its
held child PID/birth and Job are sealed before app code resumes. A new owner may
construct a private recovery proof only after the old owner and all Job children
are positively gone. A live owner, live child, access failure, partial launch,
legacy anonymous Job, absent receipt, another Windows session, or mismatched
tuple stays unknown.

The receipt keeps its initial proxy run across rebind. The registry authenticates
that immutable run before returning the current claim. Helper and GUI receipts
are independent. Prepared recovery abandons only a positively unlaunched claim;
launched recovery rebuilds the fixed home guard and uses official finalize,
registry release and marker completion. Exact finalized-writer DPAPI evidence
also closes a crash after release but before marker completion. An ordinary
Managed write lease must approve that completion before a new writer is claimed;
a plain leftover marker never authorizes deletion. Auth and history stay intact.

The native contract follows Microsoft documentation for [Job object lifetime and
kill-on-close](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects)
and [atomic process Job-list attributes](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute),
read on 2026-10-29. `actual_helper_windows_*` ignored Rust tests use only the test
executable's short-lived owner/child/grandchild fixtures, real DPAPI and real Jobs.
Run them on Windows via `cargo test --locked -p codexu-core actual_helper -- --ignored`.
A host compile or cross-compiled Go binary does not count as native recovery
execution or installed Desktop acceptance.

The connector's MSIX identity is from the [official Windows deployment
guide](https://learn.chatgpt.com/codex/enterprise/windows-deployment.md), read on
2026-10-29. Candidate names never substitute for trusted signature checks.

## Isolated host integration checks

Build `--target host` into a task-owned path, then set only
`AIGOODBRO_TEST_PROXY_HELPER` to that freshly built binary and run:

```text
cargo test --locked -p codexu-core proxy::
cargo test --locked -p codexu-core actual_helper -- --ignored
```

These tests use synthetic accounts, isolated directories and ephemeral loopback
ports. They perform no provider inference, real account login/switch or native
App launch. The product account/vault adapter and Windows installer require
their own integration tests.

Windows `-run '^TestWindows'` additionally starts the actual test-built adapter
against one synthetic backend, checks authenticated same-backend quota evidence,
private RPC suppression and EOF exit. No official app-server or model request is
used in that fixture.
