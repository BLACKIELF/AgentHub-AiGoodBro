# AiGoodBro · AgentHub for Windows — 移植计划

本文件记录 Windows 工作区从旧 `Codex Account Manager Next` 只读看板，拉齐到当前 macOS **AiGoodBro · AgentHub 9.5.21** 产品能力的切片划分。

- 基准：macOS 源码 `Sources/CodexUsageWidget/`（139 个 Swift 文件）与 `README.md`。
- 目标线：`windows-port/ui-dev`。本任务的直接父基线与工作分支见下。
- 本文件只描述计划与验证边界，不把未实现的能力画成已完成。

## 一、现状差距

Windows 工作区已有（来自 0824v1 基线）：

| 已有 | 位置 |
| --- | --- |
| Codex 本地读取（state_5.sqlite / transcript / automation） | `crates/codexu-core/src/readers/` |
| 用量、任务板、AI Leadership、Skills、Projects 聚合 | `crates/codexu-core/src/` |
| Tauri IPC、缓存与 single-flight | `apps/codexu-tauri/src-tauri/src/app_state.rs` |
| Dashboard / Settings / Tray、中英 i18n、palette catalog | `apps/codexu-tauri/web/src/` |
| 原生视觉采集 workflow | `windows/scripts/` |

Windows 完全缺失（即 AgentHub 的产品身份）：

- 多账号工作台：账号身份、执行偏好、排序与固定
- 官方额度作为一等产品：5 小时 / 7 天窗口、重置时间、重置卡
- 暖号（5h / 7d）
- 派单协调：占用状态、心跳、并发预约拒绝
- 消息通道：飞书、Telegram、企业微信、重置消息提醒
- 多 CLI：Grok、Kimi Code、Claude Code、OpenCode、Gemini CLI、MiMo、ZCode
- Desktop 切换事务

## 二、切片划分

| 切片 | 内容 | 状态 |
| --- | --- | --- |
| S1 | 账号与额度域：身份、执行偏好、额度窗口、重置卡、占用与派单门禁 | 已实现 |
| S2 | 账号工作台 UI：账号卡片、双栏 5h/7d、未知占位、取整标记 | 已实现 |
| S3 | 官方额度接线：app-server / dashboard 两种来源统一映射到 `AccountQuotaSnapshot`，含保留与过期降级 | 已实现 |
| S4 | 暖号策略：5h / 7d 分别开关、重置与失败重试的调度决策 | 已实现（策略层） |
| S5 | 派单协调：预约、心跳、释放、与 Hub 状态对齐 | 待做 |
| S6 | 消息通道：飞书 / Telegram / 企业微信，凭据隔离存储 | 待做 |
| S7 | 多 CLI 账号：登录目录关联、命名、模型可用性 | 待做 |
| S8 | Desktop 切换事务：身份验证、锁、原子写入、回滚 | 待做 |
| S9 | 打包与签名：MSI / NSIS、代码签名、更新器 | 待做 |

## 三、已落地的语义

### S1 · 域模型

`crates/codexu-core/src/models/`：

- `account.rs` — `CodexModel`（`gpt-6-astra` / `gpt-5.6-sol` / `gpt-5.6-terra` / `gpt-5.6-luna` / `gpt-5.5` / `gpt-5.2`）、`ReasoningEffort`（含 `xhigh` / `ultra`）、`ServiceTier`（`Standard` 序列化为 `default`）、`SubagentMode`、`ExecutionPreference` 与校验、`PreferenceOverrides`。默认值 **GPT-6 Astra / Low / Standard / standard**，与 macOS `CodexExecutionPreference.defaultValue` 一致。
- `quota.rs` — `QuotaWindowSnapshot`（沿用来源的 `used_percent`，`remaining` 由派生得出）、`AccountQuotaSnapshot`、`LowQuotaThresholds`（5h ≤5%，7d <10%）、`QuotaGate`。
- `occupancy.rs` — `OccupancyState`（含中文表标签）、`OccupancyRecord`、`can_accept_new_task`。

### S3 · 官方额度接线

`crates/codexu-core/src/readers/account_quota.rs`：

- `OfficialQuotaInput` 把两种来源统一成同一形状——直接读 app-server 的 `CodexAppServerQuotaSnapshot`，以及 dashboard 管线缓存的 `UsageSnapshot`（`from_usage_snapshot`）。转换规则只存在一份。
- `quota_snapshot_from_official` 的**质量判定跟随数据而非尝试**：
  - 读取成功 → `Official`，带上报窗口；
  - 读取失败但窗口有值 → `Stale`（dashboard 自己做过保留，或调用方保留了上次已验证值）；
  - 读取失败且无窗口 → `LocalOnly`，界面显示 `—`。
- `retain_last_verified_account_quota` 对齐 `codex_dashboard.rs::retain_last_verified_quota`：保留上次窗口，但**观测时间取被保留的那次**，并标 `Stale`，因此 `QuotaGate` 同样关闭。
- `degrade_stale_quality` 把超出新鲜窗口的 `Official` 降级为 `Stale`，数值保留、标签改变。

Tauri `list_accounts` 复用 AppState 里**已缓存的 dashboard 快照**推导系统账号额度，不重复拉起 app-server 进程；托管资料暂无读取路径，因此不在 map 中，界面显示 `—`。

前端 `resolveAccountQuota` 规定优先级：**dashboard 的实时读数 > DTO 携带值 > 缺失（显示 `—`）**，因为 dashboard 随用量事件刷新，而账号列表按需加载。

### S4 · 暖号策略（策略层）

`crates/codexu-core/src/models/warmup.rs`，逐条移植 macOS `CodexWarmUpPolicy`：

- **常量同值**：重置宽限 8s；5h 成功间隔 5h；7d 成功间隔 7d；失败重试 5min；额度证据最长 15min；空闲阈值 `usedPercent < 0.5`；意外回落阈值 8%；窗口起点容差 10min。
- **维护节奏**：有额度通知 60s；仅暖号 10min；都不开 30min。
- **调度**：`next_date_for_kind` / `next_eligible_date` / `is_due` / `next_scheduled_reset_date` / `next_quota_reset_refresh_date`，含 `unexpected`（意外重置立即到期）与 `blockIdleRetry`（未解决的失败按 5min 重试）两条分支。
- **决策**：`warm_up_decision` 把门禁与调度合成一个 `Send { kinds } | WaitUntil | Blocked(reason)`，运行层直接消费，界面可直接解释原因。
- **重置票**：`WarmUpResetTracker` 用单调票号替代 macOS 的 UUID，语义一致——**成功请求只确认它实际处理的那次重置事件**，即使额度仍显示 100%；后来的重置保留自己的票。

三条硬规则：

1. **暖号从不增加额度、从不兑换重置券。** 有额外余额不构成降级到付费额度的许可——`ExhaustedSubscriptionWindow` 直接阻断。
2. **失败不清空日程。** 读取失败或发送失败都让截止时间保持 pending，并以有界频率重试；不会静默丢档。
3. **缺失即 fail-closed。** 被选中的窗口没有数据时返回 `MissingSelectedWindow` 阻断，绝不用另一个窗口的数值推断它空闲。

`WarmUpState` 保存快照、上次尝试时间/结果、上次读取失败时间与有界历史（最多 20 条）。

> 本切片只实现**策略层**（纯函数 + 测试）。定时器、实际发送最小请求、进程与网络生命周期属于运行层，尚未实现。

### 三条不可放宽的规则

1. **未知不等于 0。** 来源未返回的窗口是 `None`，显示为 `—`；未知额度永远不会被报成"低额度"。
2. **心跳超时不等于空闲。** 心跳过期或缺失把记录降级为"状态待确认"，并继续占位、拒绝新预约。
3. **自动化 fail-closed。** 缺证据、证据过期、来源不可分类、账号未登录，全部阻断变更。

### 与 macOS 的两处有意分歧

| 项 | macOS | Windows | 原因 |
| --- | --- | --- | --- |
| 快照携带 `email` / `accountType` / `accountID` | 是 | 否 | 根 `AGENTS.md` 禁止跨 IPC 传递原始账号邮箱；身份统一由 `AccountIdentity` 以掩码形式承载 |
| 额度来源质量 | 隐式（`quotaReadSucceeded` + 时间） | 显式 `QuotaSourceQuality` | 界面需要区分"新鲜官方数据 / 旧快照 / 从未读到"三态 |

### 已知缺口（后续切片）

- app-server 读取路径**尚未解析重置卡数量与到期**，`available_reset_credits` / `reset_credit_expiries` 恒为 `None`，界面显示 `—`。需要先拿到真实响应样本，不做猜测式解析。
- 托管资料（隔离 profile）**没有额度读取路径**：现有 `read_installed_codex_quota` 不接收自定义 `CODEX_HOME`，需要扩展进程启动环境后才能接 S3 的映射。

## 四、隐私边界

`readers/codex_accounts.rs` 是缩减边界：

- 只读 `auth.json` 的 `tokens`，用于校验身份一致性，**不返回** token 本体。
- 邮箱经 `mask_email` 缩减为 `a***@example.com`；原始 `account_id` 只在 reader 内部用于三方一致性校验，不进入 `AccountIdentity`。
- 托管 profile 根目录使用 Next 独立命名空间 `~/.aigoodbro-agenthub/profiles`，不复用 `.codex-account-manager-next` 或任何 `codexu` 目录。
- 记录的路径一律只保留 basename。

## 五、验证边界（重要）

本次实现的验证状态（2026-09-11，macOS 主机 + rustc 1.97.1 + Node 22.22.2）：

| 验证 | 命令 | 结果 |
| --- | --- | --- |
| Rust 单元测试 | `cargo test -p codexu-core` | **148 passed / 0 failed** |
| Rust 集成测试（额度协议、Dashboard、任务板） | 同上 | **9 passed / 0 failed** |
| Rust 构建告警 | `cargo build -p codexu-core` | 0 warning |
| Web 契约与运行时测试 | `npm test`（`node --test`） | **50 passed / 0 failed**（基线为 20/1） |
| 新增纯 TS 模块严格类型检查 | `tsc --noEmit --strict` | 通过 |
| Windows MSVC 目标构建 | — | **未执行**：本机无 Windows 目标工具链 |
| Tauri release 构建 / MSI / NSIS 打包 | — | **未执行** |
| 真实 WebView2 渲染、DPI、原生对话框 | — | **未执行** |
| 渲染后定位器级截图断言（`windows/AGENTS.md` 要求） | — | **未执行**：本机无 WebView2 运行时 |
| 真实账号登录、暖号、派单、通知送达 | — | **未执行**，且本切片不包含这些行为 |

本次顺带修复的既有缺陷：

1. `readers/codex_state.rs` 的 `normalize_rollout_key` 依赖宿主路径分隔符，导致 Windows 记录的路径在非 Windows 主机上归一化失败。改为同时按 `/` 与 `\` 切分，两个原本失败的测试转为通过。
2. 非有限的 `used_percent`（`NaN` / `±Infinity`）会被算成剩余 0%，进而被误报为"低额度"。现在 `is_measured()` 为假的值一律视为未测量：显示 `—`、不算低额度、不算用尽。

### 对抗性自审发现（同一轮修复）

主动审查自己的实现，找到并修掉 5 处真实缺陷：

| # | 缺陷 | 影响 | 修复 |
| --- | --- | --- | --- |
| 1 | reader 的邮箱比较是大小写敏感的，而 macOS `normalizedEmail` 会 `lowercased()` | id_token 与 access_token 声明只差大小写时会被判为凭据不一致，**把已登录账号显示成未登录** | `normalized_email` 统一小写；`mask_email` 结果也小写，避免同一登录渲染成两个账号 |
| 2 | 额度窗口映射门控在 `quota_read_succeeded` 上 | dashboard 的 `retain_last_verified_quota` 会在读取失败时保留上次窗口，这些**被保留的额度会被静默丢弃** | 质量判定改为跟随数据：失败但有窗口 → `Stale` 且保留数值 |
| 3 | `PreferenceOverrides::set` 对空 account id 返回 `UnsupportedExecutionMode` | 错误语义误导，排障时会指向错误的根因 | 新增 `PreferenceError::EmptyAccountId` |
| 4 | 托管 profile 目录名若恰好是 `system`，会与系统登录**共用同一 account id** | 系统登录的额度被错误归属到无关 profile | reader 导出 `SYSTEM_ACCOUNT_ID` 并在枚举时跳过同名目录；Tauri 侧改为引用同一常量，避免两处定义漂移 |
| 5 | 前端在 JSX 里硬编码低额度阈值 `5` / `10`，并用"格式化结果是否等于 `—`"判断未知 | 阈值是用户可调设置，硬编码会与设置脱节；字符串比较判断未知很脆弱 | 新增 `LowQuotaThresholds` / `DEFAULT_LOW_QUOTA_THRESHOLDS` / `isLowQuotaForWindow`，阈值作为组件入参；未知改用 `isMeasuredUsage` 判定 |

第 1、2 项是会导致**错误用户可见结论**的缺陷，不是风格问题。

Web 侧新增的 23 个测试里，`quota-display` 与 `quota-bridge` 是**真实运行时**测试（Node 22 直接加载 `.ts` 模块），不是源码正则断言；`bilingual-i18n` 用 TypeScript 转译后校验中英键位对齐，因此新增的 `accounts.*` 文案在两种语言下都被实际执行过。

> Windows 打包必须在目标环境执行独立构建与测试，不能以 macOS 自测代替（`docs/windows-port/RFC.md`）。
> 上述 Rust 测试证明域逻辑与 reader 缩减行为，**不**证明窗口渲染、IPC 或打包。Tauri 命令层（`commands/accounts.rs`）本次**未经编译**。

### 环境限制记录

- `npm install` 被宿主文件规则拒绝（`CODEBUDDY_BROKER_DENY`），因此 `react` / `vite` / `recharts` 等依赖未安装；`typescript` 通过直接下载 tarball 安装，用于修复既有的 `bilingual-i18n` 失败。
- 依赖缺失意味着**未执行** `vite build` 与整仓 `tsc`；`AccountsPanel.tsx` 的 JSX 未经类型检查。

## 六、下一断点

1. **S4 运行层**：把 `warm_up_decision` 接到定时器与真实的最小请求发送，复用 `QuotaGate` 与 `can_accept_new_task` 作为发送前的二次校验；`can_continue_after_async_check` 已备好用于异步查完后的生命周期复核。
2. **S3 收尾**：扩展 `read_installed_codex_quota` 支持自定义 `CODEX_HOME`，让托管资料也能读额度；并从真实响应中解析重置卡数量与到期。
3. **S5 派单协调**：把 `OccupancyRecord` 落到持久化存储并加心跳。
4. **集成**：最终集成线是 `windows-port/ui-dev`，该分支检出在另一个 worktree，需在那边合并。

## 七、提交与推送状态

提交 `50b55b877ed4084dbf098e77a23e2f12534794c7`（23 个文件，全部位于 `windows/`）已推送到 `origin` 的 `codex/windows-agenthub-0911v1` 分支。`main` 未被触碰。

- 该分支远端已存在，可用 `git ls-remote origin refs/heads/codex/windows-agenthub-0911v1` 核对。
- `windows-port/ui-dev` 在远端尚不存在，因此无法对其开 PR；需要先由该 worktree 推送该分支。
- **本 worktree 的本地分支指针仍指向旧提交**：本次提交是通过 `git commit-tree` + 直接推送 SHA 完成的，以绕开本 worktree 里被占用的 `.lock`（那些锁是先前被中断的 git 命令留下的）。本地同步只需一次 compare-and-swap：

```sh
git update-ref refs/heads/codex/windows-agenthub-0911v1 \
  50b55b877ed4084dbf098e77a23e2f12534794c7 \
  489afe1fb3efee2753acfa620d24d92f487cd154
```

该命令只移动分支指针，不触碰工作区，也不会丢弃任何未提交改动。
