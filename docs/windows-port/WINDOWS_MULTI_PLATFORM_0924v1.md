# Windows 非 Codex 多账号、额度与 Antigravity 适配 · 0924v1

本版本在草稿 PR #12 的最新提交上继续实现，保留已有 UI 与额度修复，把 macOS 的
`LocalCLIAccount` / `LocalCLIQuotaReader` / `AntigravityCLIQuotaReader` 契约落到 Windows
原生实现（Tauri + Rust），不引入新的运行时依赖之外的第三方服务。

## 新增能力

### 1. 平台目录（`windows/crates/codexu-core/src/local_cli.rs`）

- 11 个平台与 macOS `LocalCLIKind` 对齐：Codex、Claude Code、Grok、OpenCode、TRAE、
  WorkBuddy、Kimi Code、MiMo、ZCode、Gemini CLI、Antigravity。
- 每个平台给出 Windows 默认账号目录（`%USERPROFILE%` / `%APPDATA%` / `%LOCALAPPDATA%`），
  WorkBuddy 额外识别 `.workbuddy-ai`（国际版）。
- 目录识别使用平台自身的标记文件／子目录；标记只用于识别，**从不读取凭据内容**。
- 旧 `settings.json` 中只有 Codex 目录的档案会自动升级为 `kind = codex`。

### 2. 账号隔离（`IsolationMode`）

| 模式 | 平台 | 含义 |
| --- | --- | --- |
| `managed` | Codex、Claude Code、Grok、Kimi、WorkBuddy | 平台支持账号主目录覆盖，用独立目录隔离，不改写全局凭据 |
| `default_only` | Gemini CLI | 只支持默认目录，无法再隔离第二个账号 |
| `unsupported` | OpenCode、TRAE、ZCode、MiMo、Antigravity | Windows 上不支持隔离；仍可关联已有目录做只读查看 |

OpenCode 明确标为 `unsupported`：macOS 侧用的是 POSIX `XDG_*`，Windows 构建不读这些变量，
因此不假装它生效。`inherited_environment_to_clear()` 保留需要清掉的继承变量，避免全局凭据
覆盖本账号目录。

### 3. 额度契约（`windows/crates/codexu-core/src/readers/local_cli_quota.rs`）

- 与 macOS `LocalCLIQuotaResult` 对齐：`state`、`fetched_at`、掩码身份、身份指纹（SHA-256）、
  套餐标签、窗口、余额、来源标签、`message_code`、`period_resets_at`。
- 状态只有 5 种：`available` / `unavailable` / `needs_login` / `unsupported` / `rate_limited`。
- 硬规则：
  - 平台未在本地提供额度 → `unsupported` + `local_cli_quota_not_exposed_by_platform`，**不显示绿色成功**；
  - 目录里没有登录证据 → `needs_login`；有登录证据但无额度 → 仍是 `unsupported`，**不把“已登录”当额度成功**；
  - 缺窗口就是缺窗口，不会补成 0% 或 100%；
  - 不用 token 消耗推算套餐余量；
  - 身份只以掩码形式出网，指纹用于区分账号而不暴露身份。

### 4. Antigravity（`windows/crates/codexu-core/src/readers/local_cli_quota/antigravity.rs`）

Windows 版把 macOS 的内核级校验逐条映射：

| macOS | Windows |
| --- | --- |
| `proc_pidpath` + bundle id | `CreateToolhelp32Snapshot` + `QueryFullProcessImageNameW`，要求 `language_server*.exe` 且位于 `Antigravity` 安装根 |
| `pbi_uid == geteuid()` | `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` 成功（他人进程在无调试权限时失败） |
| `pbi_start_tvsec` | `GetProcessTimes` 创建的 100ns 计数换算秒 |
| `lsof` 监听端口 | `GetExtendedTcpTable(TCP_TABLE_OWNER_PID_LISTENER)`，只接受该 PID 拥有的 `127.0.0.1` 端口 |
| 命令行 `--csrf_token` | `NtQueryInformationProcess(ProcessCommandLineInformation)` |
| `URLSession` + 自签名信任 | WinHTTP，`NO_PROXY`、禁重定向／Cookie／自动认证，仅对已验证环回端点放宽证书 |

行为与 macOS 一致：请求前后各读一次 `GetUserStatus` 核对账号，不一致直接返回
`local_cli_antigravity_account_changed`；已发现运行端点但读取失败时返回不可用，
**不用历史缓存替代当前账号**；仅当没有任何运行端点时才读
`User/globalStorage/state.vscdb`（`rusqlite` 只读 + 最小 protobuf 解析），且结果标记为
历史缓存（`state = unavailable`、来源 `Antigravity · cached IDE quota`），不构成额度或登录证明。

## 界面

- 账号卡片显示平台徽标；关联目录时可选择平台，并显示该平台的隔离说明。
- 非 Codex 账号使用独立的只读额度区块：手动读取、逐行隔离、失败可重试。
- 历史缓存与不支持状态使用警示色和明确文案，`data-state` 属性可供测试断言。
- 非 Codex 目录不会出现在“查看用量”入口里：只有 Codex 目录可以成为仪表盘数据源。

## 验证入口

```powershell
cargo +1.97.1-x86_64-pc-windows-msvc test --workspace --locked
cd windows/apps/codexu-tauri/web; npm test; npm run build
```

新增 Rust 单测覆盖：平台目录映射、隔离模式、目录标记与识别、登录证据（含不泄露凭据值）、
窗口校验、指纹稳定性、Antigravity 发现／校验／账号切换／缓存边界、base64 与 protobuf 边界。
新增前端契约测试覆盖：平台目录校验、额度结果校验、历史／不支持状态文案、隔离说明文案。

## 本轮实机验收结果（2026-09-24，Windows 11 / x64）

发布入口 `windows/scripts/Invoke-ReleaseReadiness.ps1 -Version 9.6.9` **18/18 步通过**，
报告 `dirty=false`、`source_unchanged=true`，宿主机 Windows PowerShell 5.1.26100.7920 与
PowerShell 7.6.5。Rust 工作区 129 项测试、Web 36 项契约、视觉基线 + 复跑各 38/38 通过。

| 安装包 | 字节 | SHA-256 |
| --- | --- | --- |
| `CodexAccountManagerNext-9.6.9-windows-x86_64.msi` | 11,358,208 | `9b9ff80a8fec4c621df3990618339c845e0fac6c54aecc933bb23a0f255bf946` |
| `CodexAccountManagerNext-9.6.9-windows-x86_64-setup.exe` | 9,575,812 | `49bba271dad95a9425f958b8754f6ec40b87b2de596955740b7d01bda118d01b` |

**NSIS（按用户）**：静默安装 exit 0 → 安装目录含 `codexu-tauri.exe` 与 `uninstall.exe`、
开始菜单快捷方式、卸载注册项 `Codex Account Manager Next 9.6.9`；覆盖安装 exit 0；
卸载 exit 0 → 目录、快捷方式、注册项全部清理。安装与卸载前后用户 `~/.codex` 的内容未变
（用户在应用打开后仅新增了 SQLite 的 `-shm`/`-wal` 伴生文件，数据文件本身未变）。

**MSI（按用户，`INSTALLDIR = %LOCALAPPDATA%\Codex Account Manager Next`）**：
安装 / 覆盖安装 / 卸载 **exit 全 0**，Windows Installer 引擎日志记录
`Product: Codex Account Manager Next -- Installation completed successfully.`。
需要提权执行（包会写机器级安装器键）。已知残留：`/x` 之后仍会留下 `uninstall.exe`、
开始菜单快捷方式与一个 HKCU 卸载项。

**原生界面**：由用户在本机交互启动安装后的应用确认界面正常渲染（概览、用量与额度概览、
AI 领导力、任务/项目/Skills 标签、设置窗口、账号目录面板均可见，且新加入的多平台说明文案
在真实应用中显示）。本机 agent 会话内无法自动采集该原生画面：该会话中 WebView2 不合成、
不暴露无障碍树（`msedgewebview2.exe` browser 进程在启动数秒内产生一个
`SubCode=0x80000003` 转储，UIA 树里只有 `WRY_WEBVIEW` 无子节点，激活并最大化后屏幕截取得到
“黑底 + 上次合成区域”），因此 `windows/scripts/Capture-NativeVisuals.ps1` 会在等待
`dashboard-home-tab-tasks` 时超时。该现象与本轮改动无关：应用默认 profile 的 Crashpad 目录里
存在一个 **2026-09-17** 的同签名转储（当时运行时为 153.0.4234.32），且本机其它 WebView2 宿主
应用的转储数均为 0。

## 尚未在 Windows 完成的边界

- Antigravity 的 Google 代码签名校验未在 Windows 侧实现（改为安装根目录 + 同用户可打开进程 +
  端口归属三重校验）；Authenticode 验证需要额外的信任链实现。
- 未对真实安装的 Antigravity 桌面端做在线额度实测：本机未运行该应用，真实账号登录由用户完成。
- 非 Codex 平台的交互式终端启动仍只到“隔离环境计划”一层，尚未接入交互式终端。
- 维护者消息的 Windows 原生通知、首次基线与去重仍未接线。
- 原生视觉采集工作流需要在一个可正常合成 WebView2 的交互式桌面会话中复跑。
