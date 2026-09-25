# Security Policy

Only the latest default-branch version is supported. Report vulnerabilities through a private GitHub Security Advisory when they include credentials, account identifiers, local paths, thread data, or webhook information.

## Local trust boundary

AiGoodBro may read:

- `~/.codex/auth.json` and saved-profile `auth.json` files for identity validation and account switching.
- responses from the locally installed `codex app-server` for identity, quota, and task state.
- local Codex metadata used by retained usage, task, performance, and leadership views.
- optional `~/.cc-switch/cc-switch.db` in read-only mode.
- existing supported CLI/provider configuration, credentials and local usage records through the selected provider adapter; saved configuration, readable quota and a successful model call are separate states.
- isolated state under `~/.codex-account-manager-next`, Application Support, Caches, and UserDefaults.

Credential values must never be displayed, logged, emitted by diagnostics, included in Feishu cards, or committed. Saved credentials and account-switch locks use restrictive local permissions.

Device login runs the installed `codex login --device-auth` in a private staging home. Its short-lived authorization code is displayed only in the active login panel and copied only on an explicit user action; raw CLI output and codes are excluded from logs and persisted application state. The target account stays fixed until the session ends. Cancellation and expiry retain the maintenance reservation until the owned process exits and staging files are removed. Successful browser authorization still requires matching staged identity, guarded credential promotion, and a fresh quota read before the UI reports completion.

Local analytics and session caches may retain project, Skill, and rollout source paths for record grouping. Those path fields are not uploaded, and known full paths are omitted from the diagnostics JSON and analytics UI. Do not attach those caches to a public report.

The active Codex login is inherently shared at `~/.codex/auth.json`. Low-quota automatic switching is opt-in: when enabled, it may select an eligible saved account and update the shared login through the same guarded transaction as a manual Desktop switch. It requires fresh source and target identity/quota evidence, safe task state and the foreground/session-restoration checks; missing or changed evidence blocks the transaction. Manual Desktop switching starts without waiting for an in-progress quota refresh, while retaining identity, lock and transaction checks. Isolated CLI launches continue to use their own saved account environment and Hub gate. System-profile re-authentication and recovery of an unfinished switch may also update the shared login through their guarded paths. Legacy-process checks are repeated around a write, but the legacy manager does not participate in the Next lock protocol.

## Network boundary

Network access is limited to explicit product functions:

- the installed Codex CLI and `codex app-server` communicate with OpenAI services for login, identity, quota, and tasks; user-enabled warm-up sends a minimal request directly to the ChatGPT Codex backend endpoint;
- official profile metadata may be requested from `https://chatgpt.com/backend-api/wham/profiles/me` using the selected local account;
- the updater reads public metadata from `https://api.github.com/repos/BLACKIELF/AgentHub-AiGoodBro/releases` and never installs silently;
- public reset announcements are read anonymously from `codex-resets.com`, and AI hotspot metadata from `aihot.news`; neither feed receives account credentials or local usage records, and a public announcement does not prove a personal quota reset;
- supported provider quota adapters and explicitly opened official CLIs communicate with their corresponding provider services using that provider's configuration. Detecting existing local configuration does not send a model request or prove a successful response;
- optional Feishu, Telegram and WeCom group-robot notifications send reduced account/task event fields to the channel's configured destination on `open.feishu.cn`, `open.larksuite.com`, `api.telegram.org` or `qyapi.weixin.qq.com`; adapters validate their allowed targets and reject redirects;
- source builds may download pinned toolchains and dependencies, including the bundled Token Monitor runtime. Provenance and hashes are checked during packaging; building dependencies is separate from account login or model use.

Each notification channel is a user-enabled third-party disclosure boundary. Notification failure never changes local account or quota state. Standard transport metadata such as IP address, TLS information, User-Agent, and request time remains visible to the contacted service. Opening source links or an official login uses the external browser or vendor tool and its own privacy boundary.

Automatic Feishu cards require the notification toggle. Once a valid webhook is stored, the explicit Send Test button can send one test card even while automatic notifications are disabled.

## Account-switch guarantees

- target email and stable `chatgpt_account_id` must match the saved profile, and conflicting token/account claims are rejected;
- a Next-private cross-process lock serializes manual and automatic switches initiated by Next;
- Codex receives a graceful termination request first; after a timeout the app or a remaining shared runtime may be force-terminated, and the write is aborted if shutdown still fails;
- source credentials are compared with the previously captured state immediately before an atomic `0600` write;
- before that write, a private `0600` pending-switch journal records the original state and target fingerprint; startup recovery uses compare-and-swap and never overwrites a newer external credential;
- the write is verified; on a later failure, Next restores the original credential only while it still owns the target state, and otherwise preserves the external program's newer state and reports that rollback was incomplete;

The legacy manager does not acquire the Next-private lock. Repeated legacy-process checks plus credential compare-and-swap reduce the race window, but cannot guarantee zero race when both versions run concurrently. Do not switch accounts from both managers at the same time. These guards reduce local race and corruption risk; they do not make third-party account automation officially supported by OpenAI.
