# Contributing

## Windows contribution clarification · 0916v1

Changes since 0915v1: clarify external Windows contributions, scope-based acceptance and shared resources; retire the historical UI integration branch and include shared-resource changes in Windows CI.

## Source baseline and branch lifecycle · 1004v1

Use `main` for AiGoodBro source integration. Source integration, installed builds and real account-operation acceptance remain separate; see the [2.2 publication and validation scope](docs/source-publication-1003v1.md).

- `V1.0` permanently identifies commit `517f2daeccca54fe9c388660c52889aef48f54dd`, corresponding to macOS 9.6.1 (50). Later documentation, CI or Windows fixes must not move this tag or restore an older macOS implementation.
- Compare branch contents and commit ancestry before integration. Old branch names and timestamps are not evidence that a feature is missing from the current app.
- Use focused pull requests into `main` and preserve their commit history with merge commits. Delete completed development branches only after their commits are reachable from `main`.
- If a superseded branch was replaced rather than merged, preserve its exact head under an archive tag before retiring the branch. `archive/app-backups` contains historical built applications and stays outside the source integration flow.
- Keep unfinished Windows migration work separate until its changed execution paths, Tauri/Web builds and required native behavior are verified. A macOS pass, a pure policy test or a configured CLI is not proof of Windows behavior or a successful model request.
- CI runs on pull requests and pushes to `main`; feature branch pushes use the PR check run. Windows changes, shared palette/badge resource changes, and CI-selection changes select Rust, Web and native capture jobs. `CI required` succeeds only when the selected checks passed; unavailable diff history cannot silently skip Windows. Superseded runs remain cancelled. Unchanged Windows code may be skipped, and manual runs retain the explicit Windows option.

### Stable Windows packaging baselines

`main` remains the single integration line, as agreed in [#4](https://github.com/BLACKIELF/AgentHub-AiGoodBro/issues/4). For the stable packaging environment requested in [#9](https://github.com/BLACKIELF/AgentHub-AiGoodBro/issues/9), pin a complete commit SHA reachable from `main` whose selected CI checks passed, and retain an isolated checkout at that SHA. Keep its toolchain and dependency caches between packaging runs. A moving long-lived `win_dev` branch would require separate integration and conflict resolution without fixing the tested source in place.

Record the exact SHA, toolchain/WebView2 versions, commands, package hashes and install/upgrade/uninstall outcomes in the run report. Advance the checkout deliberately to a newer verified SHA for the next cycle. A green native capture job verifies that capture path, not installer acceptance or every real account operation. Existing release tags can identify a released baseline; a new tag or prerelease is not needed for each test run and remains a separate publication action.

Fixes discovered on the pinned checkout should be submitted through a focused branch and PR into `main`. After merge and passing checks, advance the packaging checkout. This keeps a stable test environment while retaining one source integration line; no remote `win_dev` branch or maintainer assignment is required.

## Local verification

Build without launching the App:

```bash
make build
make test-palettes
./scripts/test-status-item.sh
```

For account automation changes, also run:

```bash
build/AiGoodBro.app/Contents/MacOS/AiGoodBro --self-test-automatic-account-switch
build/AiGoodBro.app/Contents/MacOS/AiGoodBro --self-test-account-switch-safety
build/AiGoodBro.app/Contents/MacOS/AiGoodBro --self-test-feishu-webhook
build/AiGoodBro.app/Contents/MacOS/AiGoodBro --self-test-account-automation-audit
```

Keep changes focused, preserve the local-first boundary, and update documentation when behavior, permissions, storage, packaging, or network disclosure changes. Never attach real account data, webhooks, thread titles, local databases, or screenshots containing private tasks to an issue or pull request.

Windows runtime captures and probe output must remain under the Git-ignored `.local-artifacts/` directory. Any public visual evidence must be regenerated from fully synthetic fixtures under the rules in [`docs/windows-port/README.md`](docs/windows-port/README.md).

Palette packages remain declarative under `Resources/Palettes/<stable-id>/` and must pass `make test-palettes`. Historical palette IDs, project-local tool IDs and Windows package paths remain internal compatibility details, not current product names. Public product copy, issue routing and macOS releases use AiGoodBro; the in-app workspace name remains AgentHub.

## Windows contributions

Focused external contributions to the Windows React/Vite frontend, contract tests and Rust/Tauri integration are welcome. Start from the latest upstream `main`, work in a fork branch, and open a PR targeting `main`. `windows-port/ui-dev` is a historical integration name, not a current target. Keep unfinished migration work separate and do not change the macOS implementation to accommodate Windows.

### Acceptance by scope

- Documentation-only PRs: verify references and consistency; retain the checks selected by CI.
- Frontend or shared-resource PRs: run `npm ci --no-audit --no-fund`, `npm test` and `npm run build` in `windows/apps/codexu-tauri/web`. Include regression coverage for changed behavior. Windows Rust formatting/workspace tests and the existing required checks must also pass in CI, even when no Rust source changes.
- UI changes: additionally provide reproducible rendered, locator-level screenshot assertions for affected regions and relevant interaction states under `windows/AGENTS.md`. Source-text contract tests alone do not prove rendering or interaction. Test code may be committed; baseline/actual/diff images remain local artifacts. Any public visual evidence must be separately generated from fully synthetic fixtures under `docs/windows-port/README.md`.
- IPC, persistence, native-window, filesystem or packaging changes: additionally build the affected Tauri application and verify changed behavior on Windows. Frontend build success and Rust unit tests do not replace this native evidence. Unrelated native workflows need not be rerun for a frontend-only change.

Use `cargo fmt --all -- --check` and `cargo test --workspace --locked` from `windows/`, with the MSVC toolchain described in `windows/README.md`. A contributor without the toolchain may open a draft PR and report the limitation; selected Windows CI and any required native acceptance remain merge gates. CI runs Rust tests, Web contracts/build and browser visual assertions, PowerShell 5.1/7 script checks, and two fresh-data cold starts of the built Tauri application through the [native capture workflow](docs/windows-port/WINDOWS_NATIVE_VISUAL_WORKFLOW.md). This covers UIA and Dashboard capture, not full product end-to-end, real-account, installer or upgrade acceptance. Report the exact tested commit, commands, results and unverified behavior; do not attach real local workload data.

### Shared resources

The Windows frontend consumes the tracked root `Resources/LeadershipBadges/` and `Resources/Palettes/` directories. Use a complete repository checkout, or include those directories with `windows/` in a sparse checkout. Copying only `windows/` is not a supported standalone build input.

Keep these root resources as the single source of truth. No Windows resource copy or macOS implementation change is required. A narrowly scoped alias improvement may be proposed with matching TypeScript/Vite resolution and build verification, but aliases cannot repair missing checkout files. Changes to either shared directory select Windows CI as well as existing macOS checks.

The root `.gitattributes` fixes shell scripts and `Makefile` to LF, Windows batch scripts to CRLF, and keeps binary assets out of text conversion. Other files retain automatic text detection. Do not run a repository-wide renormalization to contribute a focused change.

### Current contribution priorities

Prioritize account switching, invocation stability and CLI invocation efficiency in the existing Windows implementation:

- Account switching: verify the intended identity takes effect, displayed state matches actual state, and failures preserve or restore the original account safely.
- Invocation stability: reproduce startup failures, timeouts and interruptions; provide accurate outcomes and prevent duplicate execution.
- CLI efficiency: measure repeated detection, process startup and unnecessary waits; reuse existing processes or connections only when identity and lifecycle isolation remain correct.

Begin with one reproducible problem and document the reproduction, suspected cause, minimal scope and acceptance checks before implementation. Efficiency changes should include before/after timing or invocation counts. Do not weaken identity, locking, rollback or authorization checks to improve speed. Use synthetic fixtures or explicitly authorized isolated accounts; do not use real account operations without authorization.

The next-stage list in `windows/README.md` is the current backlog, not a committed cross-platform parity schedule. Automatic account switching and the Feishu control center require separate design, safety and Windows acceptance work before parity can be claimed. Installation, signing, releases and real account operations require their own authorization.
