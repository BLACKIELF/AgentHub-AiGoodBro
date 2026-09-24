# 复审修复与实机验证 · 0924v2

本文件记录 0924v1 提交复审后提出的 10 项修复、以及实机验证过程中发现的第 11 项。
所有改动都在同一草稿 PR 上，未新开 PR。基线为 0924v1 的最新提交。

## 复审提出的 10 项

| # | 问题 | 修复 | 位置 | 验证 |
| --- | --- | --- | --- | --- |
| 1 | 进程重验：发现阶段的一次性快照被复用，PID 复用或进程退出后仍会把 CSRF 令牌发出去 | `AntigravityReader::verify` 按**当前**进程表与端口表重新核对；`request` 在交换前后各调用一次 | `antigravity.rs` | `verification_rejects_a_reused_pid_or_a_moved_port` |
| 2 | 监听地址匹配：接受整个 127/8，得到实际不可达的端点 | `reachable_at_loopback` 只接受 `127.0.0.1`（`0x0100_007F`）与 IPv4 通配 | `antigravity.rs` | `loopback_matching_accepts_only_the_wildcard_and_127_0_0_1` |
| 3 | 用户身份：以 `OpenProcess` 成功推断同用户，提权调用方对他人进程同样成功 | 进程令牌的用户 SID 与本进程用 `EqualSid` 比较（不匹配以错误返回，故读 `.is_ok()`） | `antigravity.rs` | 实机 `native_process_snapshot_only_returns_language_server_candidates` |
| 4 | 安装来源：字符串前缀判断，`C:\Program Files Elsewhere` 会被当成 `C:\Program Files` | `path_starts_with` 按路径分量、忽略大小写比较；`install_roots()` 在环境变量缺失时回退到 `%USERPROFILE%` / `%SystemDrive%` 布局；新增 Authenticode 签发者校验（签发者须含 `google`） | `antigravity.rs` | `install_root_matching_uses_path_components_not_string_prefixes`、实机 `a_trusted_signer_is_read_in_either_authenticode_form` |
| 5 | 缓存越界：`User` / `globalStorage` 是 junction 时会读到别的安装的缓存 | `cache_file` 规范化根目录、两级都拒绝 symlink / reparse point、要求解析后的文件仍在解析后的根之下 | `antigravity.rs` | `cache_file_lookup_stays_inside_the_selected_directory`、`a_linked_cache_directory_is_never_followed` |
| 6 | WinHTTP 错误码：只留原始 HRESULT，数字本身无意义 | 该适配器区分的 `ERROR_WINHTTP_*` 成为具名常量，配 `summary()`，可重试信号由 `requests_resend()` 显式判断 | `antigravity.rs` | `named_winhttp_failures_explain_themselves` |
| 7 | UTF-8 截断：按字节切片，落在字符边界外会 panic | `truncate_chars` 按字符计数 | `antigravity.rs` | `character_truncation_never_splits_a_code_point` |
| 8 | 跨平台目录调用：三处各自重算 `%USERPROFILE%` / `%APPDATA%` / `%LOCALAPPDATA%` | 收敛到 `PlatformDirectories`（`detect()` 只读一次环境，`default_directory` / `alternate_directory` 委托同一套映射） | `local_cli.rs`、`profiles.rs`、`profile_quota.rs` | `the_directory_root_set_is_the_single_source_of_truth`、`detected_roots_are_absolute_and_never_empty` |
| 9 | 过期额度展示：只看 `state`，报过 `available` 的旧读数会一直按实时展示（绿条、实时倒计时） | `isLocalQuotaLive` 同时看 `state`、300 秒新鲜度、时间戳是否在未来、窗口是否都已过重置时刻；过期读数加显式说明，`data-live` 可供断言 | `localCliQuota.ts`、`LocalProfileQuota.tsx` | `an expired reading is never presented as the current quota`、视觉用例 |
| 10 | 视觉测试输出冲突：`outputDir` 是机器级固定路径，第二次运行会清掉第一次的产物 | 每次运行用唯一叶子目录（仍可用 `CODEXU_VISUAL_SCRATCH_ROOT` 指定）；端口可经 `CODEXU_VISUAL_PORT` 迁移；新增契约测试断言两棵树互不包含、跨进程不共享 | `playwright.config.mjs` | `visual-output-isolation.test.mjs` |

### 顺带修掉的副作用

第 8 项的重构发现一个既有测试会往调用者**真实**的 `%APPDATA%\Antigravity` 写目录。该测试
现在跑在临时根集合上，不触碰临时目录以外的任何东西。

## 实机验证发现的第 11 项：代码签名形式

第 4 项加的 Authenticode 校验在实机上**误拒了合法签名的文件**。

Windows 有两种 Authenticode 形式：**内嵌**签名在文件内部，**目录（catalog）**签名存在系统
目录文件里、按哈希引用文件。对后者用 `WTD_CHOICE_FILE` 询问 `WinVerifyTrust` 会返回
`TRUST_E_NOSIGNATURE`（`0x800B0100`），而不是 `TRUST_E_BAD_DIGEST`——也就是说它报的是
「没有签名」，不是「签名坏了」。本机实测：

| 文件 | `Get-AuthenticodeSignature` | 内嵌路径 |
| --- | --- | --- |
| `notepad.exe` / `cmd.exe` / `where.exe` | `Valid`，`Catalog` | `0x800B0100` |
| `Git\mingw64\bin\git.exe` | `Valid`，`Authenticode` | 读到签发者 |

只查内嵌形式，就会把一个已安装、已签名的 Google 应用判成不可信；失败方式还是静默的——
界面会显示「请先打开并登录官方 Antigravity 桌面端」，而它其实开着。`signature_publisher`
现在先试内嵌、再回退到目录：目录由文件自身哈希定位，同一个哈希用作 member tag，经
`WTD_CHOICE_CATALOG` 验证。admin 与枚举上下文都由 guard 释放，两条路径都不泄漏。

发现该问题的用例保留为实机检查，并改为断言「是哪种形式给出的答案」，同时固定这个检查存在
的两个性质：能读到受信任的签发者，且它不被当作官方签发者。未签名文件与不存在的路径断言在
两种形式下都取不到签发者。

## 验证入口

```powershell
windows/scripts/Invoke-ReleaseReadiness.ps1 -Version 9.6.9
cd windows; cargo +1.97.1-x86_64-pc-windows-msvc test --workspace --locked
cd windows/apps/codexu-tauri/web; npm test; npm run build; npm run test:visual
```

- 发布入口 **18/18 步通过**，报告 `dirty=false`、`source_unchanged=true`。
- Rust 工作区 **138 项**测试通过（其中 `codexu-core` 98 项）。
- Web **42 项**契约测试通过；视觉基线 + 复跑各 **38/38**。
- PowerShell 契约测试在 5.1.26100.7920 与 7.6.5 两个宿主下各跑一遍。

## 本机能力前提（供复现）

- 本机**未安装** Antigravity，也没有 `language_server.exe` 在运行，因此真实在线额度读取
  仍由用户在自己的登录环境完成。
- 本机可以创建目录符号链接（`os.symlink(..., target_is_directory=True)` 成功），
  所以第 5 项的链接拒绝用例会真正走到拒绝分支，而不是被跳过。
- 本机 `System32` 下的镜像全部是目录签名，因此第 11 项一定会在本机复现。

## 未完成 / 未验证

- 未对真实安装的 Antigravity 桌面端做在线额度实测；真实账号登录由用户操作。
- 非 Codex 平台的交互式终端启动仍只到「隔离环境计划」一层。
- 维护者消息的 Windows 原生通知、首次基线与去重仍未接线。
- 原生视觉采集工作流需要在一个可正常合成 WebView2 的交互式桌面会话中复跑。
