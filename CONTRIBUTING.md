# Contributing

## Windows contribution clarification · 0916v1

Changes since 0915v1: clarify external Windows contributions, scope-based acceptance and shared resources; retire the historical UI integration branch and include shared-resource changes in Windows CI.

## Source baseline and branch lifecycle · 0915v1

Changes since the earlier branch workflow: use `main` as the integration entry, keep the rebuilt V1.0 application as the accepted macOS baseline, and distinguish source integration from native acceptance.

- `V1.0` permanently identifies commit `517f2daeccca54fe9c388660c52889aef48f54dd`, corresponding to macOS 9.6.1 (50). Later documentation, CI or Windows fixes must not move this tag or restore an older macOS implementation.
- Compare branch contents and commit ancestry before integration. Old branch names and timestamps are not evidence that a feature is missing from the current app.
- Use focused pull requests into `main` and preserve their commit history with merge commits. Delete completed development branches only after their commits are reachable from `main`.
- If a superseded branch was replaced rather than merged, preserve its exact head under an archive tag before retiring the branch. `archive/app-backups` contains historical built applications and stays outside the source integration flow.
- Keep unfinished Windows migration work separate until its changed execution paths, Tauri/Web builds and required native behavior are verified. A macOS pass, a pure policy test or a configured CLI is not proof of Windows behavior or a successful model request.
- CI runs on pull requests and pushes to `main` or `codex/**`. Windows changes, shared palette/badge resource changes, and CI-selection changes automatically run the Rust and Web jobs. `CI required` succeeds only when the selected checks passed; unavailable diff history cannot silently skip Windows. Superseded runs remain cancelled instead of producing a synthetic gate failure. Branch protection requires both the summary and platform check contexts, so cancelled platform checks cannot satisfy it. Unchanged Windows code may be skipped, and manual runs retain the explicit Windows option.

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

Use `cargo fmt --all -- --check` and `cargo test --workspace --locked` from `windows/`, with the MSVC toolchain described in `windows/README.md`. A contributor without the toolchain may open a draft PR and report the limitation; selected Windows CI and any required native acceptance remain merge gates. CI currently runs Rust tests and the Web build, not full Tauri end-to-end or visual acceptance. Report the exact tested commit, commands, results and unverified behavior; do not attach real local workload data.

### Shared resources

The Windows frontend consumes the tracked root `Resources/LeadershipBadges/` and `Resources/Palettes/` directories. Use a complete repository checkout, or include those directories with `windows/` in a sparse checkout. Copying only `windows/` is not a supported standalone build input.

Keep these root resources as the single source of truth. No Windows resource copy or macOS implementation change is required. A narrowly scoped alias improvement may be proposed with matching TypeScript/Vite resolution and build verification, but aliases cannot repair missing checkout files. Changes to either shared directory select Windows CI as well as existing macOS checks.

### Current contribution priorities

Prioritize account switching, invocation stability and CLI invocation efficiency in the existing Windows implementation:

- Account switching: verify the intended identity takes effect, displayed state matches actual state, and failures preserve or restore the original account safely.
- Invocation stability: reproduce startup failures, timeouts and interruptions; provide accurate outcomes and prevent duplicate execution.
- CLI efficiency: measure repeated detection, process startup and unnecessary waits; reuse existing processes or connections only when identity and lifecycle isolation remain correct.

Begin with one reproducible problem and document the reproduction, suspected cause, minimal scope and acceptance checks before implementation. Efficiency changes should include before/after timing or invocation counts. Do not weaken identity, locking, rollback or authorization checks to improve speed. Use synthetic fixtures or explicitly authorized isolated accounts; do not use real account operations without authorization.

The next-stage list in `windows/README.md` is the current backlog, not a committed cross-platform parity schedule. Automatic account switching and the Feishu control center require separate design, safety and Windows acceptance work before parity can be claimed. Installation, signing, releases and real account operations require their own authorization.
