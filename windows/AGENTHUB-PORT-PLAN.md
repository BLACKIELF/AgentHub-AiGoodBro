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
| S5 | 派单协调：共享占用契约（线格式、校验、冲突判定、心跳、历史上限） | 已实现（契约层） |
| S6 | 消息通道：掩码 DTO、webhook 目标白名单、去重与投递语义 | 已实现（策略/契约层） |
| S7 | 多 CLI 账号：支持矩阵、额度结果契约、失败保留与同一登录判定 | 已实现（契约层） |
| S8 | 自动切换策略 + 切换请求校验（手动与自动共用同一形状与门禁） | 已实现（策略层） |
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

### S5 · 派单协调（契约层）

`crates/codexu-core/src/models/dispatch.rs`，逐条移植 `DispatchActivityStore`——它是与 `next_dispatch_activity.py` 和 Hub 共享的**版本化本地契约**，字段名、密钥派生、状态集合与校验必须逐字节一致，否则两侧会静默看不见对方的预约。

- **共享文件**：`dispatch-activity-v1.json`、`.dispatch-activity.lock`、`operations-issues-v1.jsonl`。
- **状态集合**：活跃 `preparing / starting / running / cancel_requested / uncertain`；终结 `awaiting_acceptance / accepted / rejected / failed / cancelled`。
- **线格式**：camelCase，`leaseId / ownerThreadId / taskId / accountKey / aliasKey / projectKey / code? / route / state / createdAt / updatedAt / heartbeatDueAt / pid?`。未设置的 `code` / `pid` 不写出。
- **密钥派生**：SHA-256 十六进制。`accountKey = hash(account)`（不归一化）；`aliasKey = hash(alias.trim().lowercase())`；账户路由 `projectKey = hash("<route>:<accountKey>")`；终端 `projectKey = hash(已解析的真实目录)`。用 `sha2` crate 而非手写摘要——摘要错一位就会静默破坏互通。
- **校验**（与另外两个读取方同规则）：`schemaVersion == 1`、≤2000 条、`leaseId` 唯一、三个 key 均为 64 位**小写**十六进制、标识非空、时间戳有限。任一条不过即视为**不可读**，而不是部分信任——部分信任的预约集会让两个运行器抢同一账号。
- **心跳**：账户路由 600s、终端 120s；`heartbeatDueAt` 已过或 `updatedAt` 超前 5s 以上 → 判定为 `uncertain`，但**记录状态不变**，因此预约继续占位。
- **冲突判定**：账户路由按 accountKey **或** aliasKey 冲突；终端额外按 projectKey 冲突（同账号不能在同一真实项目目录并发）。判定读**记录状态**而非 `effectiveState`，所以过期心跳照样阻断。
- **历史上限**：保留全部活跃 + 最近 100 条终结记录，按 `updatedAt` 排序、`leaseId` 破平——刚结束的记录可能排在数组首位，必须按完成时间保留，否则下一次写入会在验收前把它挤掉。
- **问题日志**：append-only JSONL，UTC `recordedAt`（`Z`）+ 同一时刻的 `dateShanghai`（`+08:00`），`component` 固定 `next`，可选 `code` 为单个大写字母。

三条硬规则：

1. **心跳超时不等于空闲。** 只降级为 `uncertain`，预约继续占位，绝不自动释放别人的占用。
2. **契约不符即不可读。** 校验失败不是"跳过坏记录"，而是整体拒绝——否则并发保护会退化成部分保护。
3. **日志不得泄露本地状态。** `validate_issue_summary` 按 token 判定绝对路径（POSIX 与 Windows 盘符）、URL scheme 与邮箱，藏在句子中间的路径同样拦截；`5h/7d` 这类词内斜杠仍放行。

> 本切片只实现**契约层**（纯函数 + 测试）。文件锁、原子替换与进程存活判定属平台层，尚未实现。

### S6 · 消息通道（策略 / 契约层）

`crates/codexu-core/src/models/messaging.rs`，逐条移植 `Domain/MessageChannel.swift`。

核心思想是**依靠构造让敏感内容无法被表达**：prompt、模型回复、文件路径、原始账号标识与自由文本在 `MessageTaskStatus` 里根本构造不出来，因为构成它的两个标签类型在构造时就把这些形状拒掉了。通道就算行为异常，也没有东西可泄露。

- **通道生命周期**：`MessageChannelPhase` 从 `Disabled` 起步，**没有任何自我启用**，`Ready` 需要一次用户发起的验证发送；只有 `Ready` 允许发送。
- **掩码 DTO**：`MessageChannelAccountLabel` 两种构造——显示名（≤48 字，字母数字 + ` .-•·()（）` + 其他符号 + ZWJ/VS16）与掩码值（≤64 字，必须含 `***` 或 `•••`）。`MessageChannelTaskLabel`（≤48 字）拒绝 `@`、`:`、`/` 与 `\`，因此邮箱、URL 与路径进不来。
- **唯一可外发载荷**：`MessageTaskStatus` 只带事件种类、两个标签、任务状态、两个额度百分比、失败原因、时间与事件 ID。百分比必须有限且落在 0–100；除连接测试外，必须至少指明账号或任务之一。
- **规范化渲染**：`summary()` 放在域里，保证不同通道**披露的字段不会漂移**。
- **去重**：`MessageEventDeduplicator` 先占位（in-flight）再认领（seen），失败 `release` 可重试，历史有界。
- **出站目标白名单**：`WebhookTargetPolicy` + `validate_webhook_target` 强制 https、拒绝 URL 内凭据、按 host 与 path 前缀白名单放行，**默认拒绝 query string**（密钥不得搭便车）、拒绝 fragment，并把解析后的 `Url` 交回调用方，避免"校验过的字符串被重新解析成另一个地址"。
- **重定向必须拒绝**：bot token 与 webhook key 在 URL 里，跟随重定向就是跨源泄露。

三条硬规则：

1. **默认关闭，验证后才发。** 通道不自我启用。
2. **出站目标必须落在白名单内**，且默认不接受 query。
3. **API 接受 ≠ 送达人。** `MessageDeliveryOutcome` 只表示平台收下。

#### 实现中发现并补上的接缝

`readers/codex_accounts.rs::mask_email` 产出 `a***@example.com`，但共享的消息通道标签规则**不含 `@`**（域名仍是身份事实），所以掩码邮箱不能进消息。已新增 `account_label_from_masked_email` 把 `a***@example.com` 收敛为 `a***`，并有测试固定该行为。

> 本切片只实现**策略 / 契约层**。凭据存储（Keychain / 凭据管理器）、HTTP 传输与重定向守卫属平台层，尚未实现。

### S7 · 多 CLI 账号（契约层）

修正 `models/account.rs` 的 `LocalCliKind` 并新增 `models/local_cli.rs`。

#### 修正了三处与产品不符的地方

先前的 `LocalCliKind` 与 macOS 和 `docs/local-cli-accounts.md` 都不一致，本轮按文档改正：

| 项 | 先前（错） | 现在（按文档） |
|---|---|---|
| 枚举成员 | 8 个，**含 Codex** | 9 个，**不含 Codex**（Codex 是主账号体系，由 `AccountRecord` 承载；放进这里会让同一登录有两套表示） |
| 缺失成员 | 无 TRAE、无 WorkBuddy | 补 `Trae` / `WorkBuddy` |
| 额度接通判定 | 只有 MiMo / ZCode 未接通 | MiMo 仅读账号元数据；**WorkBuddy 与 TRAE SOLO 原生额度未接通**；**ZCode 对已配置的 GLM/Z.AI Coding Plan 是接通的**（与原生订阅额度分开） |

现在 `quota_wiring()` 返回 `Wired | NotWired(reason)`，把"未接通"的原因也带出去，界面才能说「暂未接通」而不是含糊的 0。

同时按 macOS 补齐能力矩阵：`command_name`、`default_config_directory`（相对 home 的路径）、`supports_terminal_sign_in`（grok/openCode/workBuddy/zcode）、`supports_native_open`（另加 trae）、`supports_linked_environments`（`!= Trae`——TRAE SOLO 是个人版，不能给关联环境，否则等于暗示企业版 `traecli`）。

#### 新增额度结果契约

`models/local_cli.rs`：

- `LocalCliQuotaState`：`available / unavailable / needsLogin / unsupported / rateLimited`，只有 `available` 算有数据。
- `LocalCliQuotaResult` + `LocalCliQuotaWindow` + `LocalCliResetCard`，含**独立的重置卡观测时间**——官方请求若不带卡字段，就不能让旧的一组看起来是新观测的。
- `retain_last_valid_result`：**刷新失败时保留该账号自己的上次有效快照**，并写入 `retained_from` 记录这些数字真正的观测时间，**重置卡不随额度刷新继承**。没有上次快照时保持原状、绝不推算成 0。
- `shares_login`：只有同族且双方都有指纹时才判定同一登录；**没有可靠标识时返回 unknown，绝不猜测共用额度**。
- `LocalCliPresentation`：`bounded_label` / `valid_identity` / `masked_identity` / `valid_windows` / `valid_reset_cards`，全部有界并拒绝控制字符与越界百分比。
- `CliReadPolicy`：总时限 + 响应大小上限，**Cookie、重定向、自动重试全部关闭**（重定向可能把凭据带到用户没选的主机）。
- `LocalCliProfile` 只保存名称与目录标签，**不复制任何厂商凭据**。

三条硬规则：

1. **未接通 ≠ 0。** 界面必须能说「暂未读到」或「暂未接通」。
2. **同登录只在可确认时才提示。** 无可靠标识即 unknown。
3. **不以命令退出码冒充成功。** 未知状态保持未知。

> 本切片只实现**契约层**。各 CLI 的适配器、进程启动与目录隔离属平台层，尚未实现。

### S8 · 自动切换策略（策略层）

新增 `crates/codexu-core/src/models/automatic_switch.rs`，移植 `Domain/AutomaticAccountSwitch.swift`。

#### 先说一处文档与代码不符

根 `AGENTS.md` 提到的 `DesktopSwitchCoordinator / DesktopSwitchTransaction / DesktopSwitchJournal / DesktopSwitchVerifier` **在本仓库从未存在过**——不在 HEAD，也不在任何分支的提交历史里（`git log --all -S "DesktopSwitchTransaction"` 无结果）。真正的切换实现是 `Domain/AutomaticAccountSwitch.swift` 与 `Services/CodexSwitchPreparation.swift`。本切片按**实际存在的代码**移植，并在此记录该偏差，避免后续按文档去找不存在的文件。

#### 移植内容

- `LowQuotaAlertThresholds`：可选项 `[5, 10, 15, 20, 25]`，标准值 (5, 10)。**无法识别的取值回落到标准值**，因为阈值是安全设置，静默放宽会触发用户没要求的切换；设置读取只接受"整数且在可选项内"。
- `PausedAutomationFeature`：可被启动覆盖暂停的五项（5h 暖号 / 7d 暖号 / 低额度提醒 / 飞书通知 / 系统通知）。**只有显式的 `no` / `false` / `0` 才算暂停**，缺失或无法识别的一律不暂停——否则一个拼写错误就会静默关掉安全网。
- `AutomaticSwitchQuotaState`：剩余百分比被 clamp 到 0–100，非有限值变成 `None`，**未知窗口永不触发切换**。触发规则沿用产品一贯口径：**5h 包含（≤），7d 不包含（<）**。
- `AutomaticSwitchPolicy` 及其门禁：
  - 常量：5h 触发 5%、7d 触发 10%、候选下限 30%、失败重试 3600s、成功冷却 1800s、额度快照上限 45s、任务快照上限 45s、Codex 空闲要求 120s、时钟偏移容差 5s。
  - `has_no_active_tasks`：**断连快照是"未知"而非"空"，因此阻断**；任务状态中 `running / waitingInput / recorded / disconnected` 阻断（`recorded` 与 `disconnected` 也阻断，因为未完成或未核实的任务不等于账号空闲）。
  - `has_safe_task_state`：必须先观测到 Codex 空闲且已满 120s，再看无活跃任务。
  - `should_evaluate`：启用 + 额度新鲜 + 有触发窗口 + 任务状态安全 + 不在成功冷却内 + 不在失败重试内，全部满足才考虑。
  - `preferred_candidate`：**候选必须上报每一个触发窗口**，缺任何一个即视为未知并取消资格；得分取触发窗口中的最小值且必须 ≥30；同分时取**较小的 profile id**，保证选择确定。
  - `lowest_trigger`：触发窗口中最紧张的那个。
- `SwitchRequest`：`Manual` 与 `Automatic` **共用同一形状与同一校验**，落实「手动与自动切换必须共用同一条身份、锁、优雅退出、原子写入、校验、回滚与恢复路径」。校验要求两端都非空且不同——**两端必须在同一把锁内一起预约**（`dispatch.rs` 的 `reserveMaintenance(accounts:)` 已实现该语义），否则第二个预约失败时会留下第一个账号的孤立准备状态。

三条硬规则：

1. **自动化默认关闭且 fail-closed。** 额度缺失/陈旧、任务快照缺失/陈旧、连接状态未知、旧管理器在跑、Codex 未确认空闲——任一项即阻断。
2. **未知不等于空闲。** 断连、缺失窗口、未上报的窗口，全部按未知处理。
3. **手动与自动同构。** 不做两套判定。

> 本切片只实现**策略层**。事务本身（锁、原子写入、回滚、恢复日志）属平台层，尚未实现。

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
| Rust 单元测试 | `cargo test -p codexu-core` | **229 passed / 0 failed** |
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

1. **S8 事务平台层**：在 `automatic_switch.rs` 的判定之下实现切换事务本身——同一把锁内同时预约来源与目标身份、优雅退出、原子写入、校验、回滚与恢复日志。任一方冲突即不建立部分预约；恢复事务未完成时保留占用。
2. **S5 平台层**：实现 `dispatch.rs` 契约之下的文件锁、原子替换与进程存活判定。Windows 需要 `LockFileEx`、`MoveFileEx(MOVEFILE_REPLACE_EXISTING)`、`OpenProcess`，不能照搬 POSIX 的 `flock` / `rename` / `kill(pid, 0)`；还要复刻 macOS 的目录与锁文件属主/权限检查（Windows 侧对应 ACL 检查）。随后接 Tauri 命令与 UI。
2. **S4 运行层**：把 `warm_up_decision` 接到定时器与真实的最小请求发送，复用 `QuotaGate` 与 `can_accept_new_task` 作为发送前的二次校验；`can_continue_after_async_check` 已备好用于异步查完后的生命周期复核。
3. **S3 收尾**：扩展 `read_installed_codex_quota` 支持自定义 `CODEX_HOME`，让托管资料也能读额度；并从真实响应中解析重置卡数量与到期。
4. **`occupancy.rs` 与 `dispatch.rs` 的关系**：前者是工作台自己的占用视图（面向界面），后者是与外部工具共享的线格式契约。平台层落地时应让两者由同一份状态派生，避免出现两套互相矛盾的占用真相。
5. **集成**：最终集成线是 `windows-port/ui-dev`，该分支检出在另一个 worktree，需在那边合并。

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
