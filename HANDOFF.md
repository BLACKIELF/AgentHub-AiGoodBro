# AiGoodBro — Source handoff

## Current entry · 0923v9

相较 0923v8：修复 Grok 已有余额／周期时间被空窗口遮蔽、OpenCode 打包桥接误判和 Kimi 新旧额度格式兼容；增加 Antigravity 与非 Codex 统一多账号入口。首页用量统计独立放在推荐／重置公告下方、账号区之前，默认折叠，保留热力图、趋势及工具明细。Jev 与可调度账号参与判断和对抗审查。源码统一从 [草稿 PR #12](https://github.com/BLACKIELF/AgentHub-AiGoodBro/pull/12) 的最新提交接手；旧 PR #3、#10、#11 的提交已包含，重复入口已关闭。实现、验证、安装及边界见 [CLI 额度与多账号修复 0923v9](docs/cli-quota-repair-0923v9.md)。Windows 已补余额／重置卡独立显示及用量模块，但非 Codex 原生适配并未完整移植；接手者须按 [Windows 交接](docs/windows-port/WINDOWS_AI_HANDOFF_0922v4.md) 继续，不能只做打包。

## Previous entry · 0923v8

相较 0922v4：完成毛玻璃首页、紧凑卡片／列表、统一编号与深色液态键帽默认值。用户先要求独立安装，随后明确要求覆盖安装；现已更新 `/Applications/AiGoodBro.app`，原生启动读回 11 个账号，主题为深色液态键帽，旧应用已保留备份。源码仍在本地工作树，不能将旧 PR 视为已含此增量。具体构建、自检、界面验收范围、安装回执与剩余项见 [0923v8 实现记录](docs/ui-implementation-0923v8.md)。Windows Web 同步完成，本机没有验证 Windows 原生打包。

## Previous entry · 0922v4

相较 0915v1：当前源码已集成 Mac **9.6.9（58）**、0919–0921 Windows 目录/额度基线及本轮两端修复。Mac 9.6.9 已本机安装并通过 32 项原生自检；Windows 原生运行与安装结果另行记录。入口是本分支最新 HEAD、[版本说明](docs/release-notes-v9.6.9.md)及[Windows AI 一次执行交接](docs/windows-port/WINDOWS_AI_HANDOFF_0922v4.md)；不要用下方历史版本覆盖当前源码。

已有本任务授权覆盖必要修复、复验、GitHub 推送；真实账号登录/系统切换/重置兑换仍不是代码测试步骤。Windows 执行者可修改所有完成对齐所需的 Windows 模块，不受历史“只做目录”描述限制。

## Historical source entry · 0915v1

Changes since the historical 0828v2 handoff: the accepted macOS implementation is the rebuilt **V1.0 / 0915v5 / 9.6.1 (50)** at `517f2daeccca54fe9c388660c52889aef48f54dd`. Use the current `main` source and [version notes](docs/release-notes-v9.6.1.md), together with [branch and verification guidance](CONTRIBUTING.md) and [current security boundaries](SECURITY.md).

Later repository maintenance may add documentation, CI and separately reviewed Windows fixes. Preserve the V1.0 macOS implementation unless a new task explicitly changes it; an older branch or the historical instructions below are not a reason to restore the pre-rebuild application. The V1.0 tag is immutable and does not publish a binary Release.

Configuration detection, quota reads and a successful model response remain separate evidence. Remaining provider/native Windows acceptance must be requested and recorded separately. No historical handoff grants fresh permission to switch accounts, log in, send notifications or overwrite an installed application.

## Historical record — Codex Account Manager Next 0828v2

The following sections preserve earlier decisions and results. Their references to “current”, “next step” or “next conversation” describe that historical task, not the active work item.

## 当前对话交接摘要（下一对话先读）

- 用户目标：把 Next 做成可靠的 Codex 多账号管理器，并立即完成从当前账号到目标账号卡的真实切换。
- 用户对原阻断逻辑的最终决定：不要再要求识别或恢复当前对话；只需先提醒“确认所有 Codex 对话都已关闭、没有任务运行”，用户确认后允许强制切换。
- 已完成代码：手动点击时，只要 ChatGPT/Codex 正在运行，就固定显示“强制切换账号？”；“取消”不写凭据，“强制切换”跳过会话识别、会话恢复和实时任务快照门禁。
- 未削弱的事务保护：来源/目标身份、账号卡匹配、互斥锁、退出、恢复 journal、原子写入、写后校验、冷启动身份确认、失败回滚。自动切换仍保持原 fail-closed 规则。
- 最终源码已编译并签名；相关两个自测和 `git diff --check` 通过。旧管理器进程已退出，最终构建已按完整路径启动，账号读取完成，旧的“请回到要保留的对话”文案未再出现。
- 尚未完成：用户还没有在最终构建中点击“强制切换”，所以没有目标身份、启动/监控状态或 pending journal 的成功验收。下一对话禁止声称已经切换成功。
- 下一步只做真实验收：用户点击目标卡“切换并打开”→核对确认框→点“强制切换”；随后只读核对目标身份、启动/监控一致、共享 daemon 正常、pending journal 已清理。不要再回到对话识别方案。

## 与 0828v1 的区别

- 用户已明确改变手动切换要求：ChatGPT/Codex 运行时不再依赖当前对话识别；第一次点击固定弹出“强制切换账号？”并要求确认所有对话已关闭、没有任务运行。点“强制切换”后不恢复当前对话，也不再受实时任务快照门禁阻断。
- 强制手动切换只跳过“识别/恢复当前对话”和实时任务快照门禁；目标/来源身份校验、切换锁、退出进程、恢复 journal、原子写入、写后校验、冷启动身份确认和失败回滚仍走同一个 `CodexAccountActions.launchCodex` 事务链。自动切换继续 fail-closed，不允许强制。
- 完整窗口与菜单账号页都挂载了相同的“强制切换 / 取消”确认框；取消不会写凭据。
- 旧管理器进程已按精确 PID 退出，`build-auth-refactor/CodexAccountManagerNext.app` 新构建已启动；只读界面状态确认没有旧阻断文案且账号读取已完成。
- `--self-test-account-switch-safety`、`--self-test-codex-session-link`、代码签名和 `git diff --check` 均通过。
- 真实目标账号切换仍待用户在新确认框点击“强制切换”后的身份验收；尚未取得写入、重启和目标身份成功证据，不能写成已切换。

## 0828v1 已保留的修复

- 0827v6 的会员日期纠偏、分页指纹、延迟提交、90 秒人工确认和失败回滚代码仍保留，供非强制恢复路径使用；当前手动产品入口以 0828v2 的显式强制确认要求为准。
- 找到此前多次“无法确认当前 Codex 对话”的遗漏根因：日志兜底被错误绑定到 `NSRunningApplication` 对 `com.openai.codex` 的进程枚举；当前 Desktop 由 ChatGPT 宿主运行时，这个枚举并不稳定，导致已有日志证据根本没有进入解析链。
- `CodexRuntimeProvider` 现已把项目中原有的只读任务板加载器接回运行时快照；此前该方法存在但返回的快照始终没有任务板，后续“任务仍存在且未归档”校验可能恒失败。
- 日志兜底不再依赖 bundle ID 或单一 PID：只扫描最近更新的 `codex-desktop-*.log` 尾部，只提取带 `rendererWindowFocused=true`、`rendererWindowVisible=true` 的末尾 `threadId` / `turnId` 元数据；5 分钟过期，最近 15 秒出现多个任务 ID 时继续 fail-closed，不读取、保存或输出消息正文。
- 最新真实环境只读验证已确认：前台日志精确命中当前任务，任务板也包含同一条未归档任务；会话识别自测、签名与 `git diff --check` 通过，新构建已按完整路径重新启动。
- 0828v1 阶段的真实账号切换没有完成：一次操作因账号数据尚在读取被拦，一次因当前回复仍在执行被拦，之后一次在旧日志门禁下仍报“无法确认当前对话”。0828v2 已按用户授权改为显式强制确认流程，但仍需最终运行时验收。
- 最新受限环境复跑纯测试时 20/23 通过；`global-shortcut`、`particle-animation`、`status-item` 三个 GUI 自测以状态 134 无输出退出。本轮修改直接相关的 `codex-session-link` 自测通过；此前非受限构建曾 23/23 通过，但不能替代最新 GUI 复测。

## 当前任务

共享事务链与用户授权的强制手动入口已落地。当前最高优先级是完成一次真实强制切换并验收：

1. 用户点击目标账号卡“切换并打开”，确认出现“强制切换账号？”以及“强制切换 / 取消”。
2. 用户确认所有对话已关闭后点击“强制切换”；强制模式明确不恢复原对话。
3. 切换后核对目标身份与账号卡一致、启动账号与监控账号一致、ChatGPT 冷启动正常、共享 daemon 正常。
4. 只读确认 pending switch journal 已清理；任一步失败则确认原账号已回滚，不能只看按钮或启动结果。

对话分页/renderer 消失问题仍保留为独立后续课题，不再作为用户本次强制手动切换的前置条件。

用户对最新现象的准确描述：打开同一个名为“继续修复真实账号切换”的任务时，切号前的一些对话不见了；下午自检产生的新对话起初可见，约十几分钟后也再次不见。不是任务卡消失，也不是用户切到了别的账号。

## 已确认事实

### 数据仍在

- 当前任务未归档，`history_mode` 为 `paginated`。
- `state_5.sqlite` 完整性检查为 `ok`。
- 诊断采样时，原始 rollout 已超过 62 MB、6500 行，包含 59 个 `turn_context` 和 9 个 `compacted`；整份 JSONL 可解析。
- 官方只读线程接口能返回最新分页，并明确 `hasMore=true`；旧页仍可继续读取。
- 用户指出的旧消息和下午新增消息仍能在原始 rollout 中定位。不要把“界面没显示”写成“数据已删除”。

### 0827v3 无切号基线

- 短诊断任务含两个完成轮次；至少 47 分钟后，官方只读分页仍返回两轮，`hasMore=false`。
- 最终构建通过隔离的本地 `app-server` 调用 `thread/turns/list`，以 `itemsView=notLoaded` 读取元数据，仍得到 2 个轮次 ID；没有读取、打印或保存消息正文。
- 这证明该短任务的服务端/本地分页元数据在观察期内没有丢失，不证明 Desktop renderer 已持续显示两轮。
- 本轮没有窗口失焦/恢复、分页重载或自然 `compacted` 的可见界面证据；这些仍是完成标准。

### 0827v4 真实 Next GUI

- 最终构建能读取 9 张账号卡，自动切换总览与安全规则均显示“Codex 已退出”。
- 受控换号操作命中“无法确认当前可见对话；为防止任务丢失，没有切换账号”，ChatGPT 保持运行。
- 检查时不存在 pending account-switch journal；该结果证明 fail-closed 门禁工作，不证明真实换号成功。
- ChatGPT renderer 不能由当前自动化读取；两个锚点是否同时显示必须由用户直接看屏幕确认。

### 0827v5 点击反馈与续费状态

- 原“没反应”包含两个独立问题：操作消息在滚动区最底部不可见；旧会员日期又与实时额度相冲突。
- 账号操作消息和历史确认按钮现固定在窗口底部；实际点击结果不会再因列表滚动位置而隐藏。
- 会员日期来自本机令牌声明，续费后可能滞后；实时切换资格继续以当前身份、最新权威额度和任务状态为准，缺失或陈旧的实时证据仍 fail-closed。
- 浏览器重新登录只证明登录页被调用、用户完成了网页端登录；目标管理卡独立凭据未更新，不能写成“重新认证成功”。
- 最终运行进程启动时间晚于新二进制修改时间，排除了旧进程仍映射旧代码；UI 已读回新文案与开关状态。

### 0827v6 当前对话识别与明确阻断反馈

- 最新真实点击命中“无法确认当前可见对话”；因此按钮、目标卡回调和 fail-closed 门禁都确实执行过，不是按钮事件丢失。
- 窗口标题已不足以标识新版 Codex 当前任务。新增证据只来自 Codex 前台期间唯一的实时活跃任务，不读取或记录消息正文，也不持久化任务 ID。
- 多活跃任务、断开、超过 45 秒的实时快照、超过 15 分钟的前台捕获、任务已归档或不在任务板都会拒绝使用该证据。
- `requestRestore` 只表示精确任务深链请求成功；分页指纹与 90 秒用户界面确认仍是提交前的独立硬门禁。
- 原生警告框用于手动阻断或强制切换确认；自动切换保持静默 fail-closed 与原审计/通知路径。

### 最新复发没有经过切号链路

- 最新复发期间没有账号切换，也没有 pending account-switch journal。
- ChatGPT、共享 app-server 和 Mimi 监督进程持续运行，没有与复发对应的 ChatGPT 重启。
- 因此 `UsageStore.launchCodex(with:)` 的账号写入、重启和回滚链路不是这次复发的直接触发器。

### 存在过两类界面干扰

- 17:21 和 17:24，Codex 动态任务工具曾把当前任务归档；随后已取消归档。
- 17:29，动态任务工具把主窗口从“继续修复真实账号切换”导航到另一个任务“修复真实账号切换对话丢失”。
- 这些操作解释了一次“整条任务像消失/被切走”，但不能完整解释用户最新确认的“同一任务内部消息过十几分钟消失”。
- 后续诊断禁止对当前长任务调用归档、取消归档、官方任务迁移或 `navigate_to_codex_page`，避免再次污染证据。

### 界面恢复证明不充分

- Desktop 日志出现过：窗口被认为 focused/visible，但页面 `documentVisibilityState=hidden`。
- `maybe_resume_success` 曾只报告 `turnCount=0` 或 `turnCount=5`，而原始任务实际远多于 5 个轮次。
- `navigate_to_codex_page`、深链打开或 `NSWorkspace.open` 返回成功，只能证明路由请求被接受，不能证明原任务历史已在用户屏幕完整渲染。
- `CodexSessionOpener.requestRestore` 只负责请求精确深链；切换成功判定仍要求分页指纹一致及用户确认界面历史，深链返回和窗口标题都不单独构成成功证明。

## 根因分层

### 根因 A：旧的切号触发故障，自动严格、手动显式强制

旧实现只在自动切换前检查实时任务；手动 UI 和 `--switch-profile-id` 仍可能终止活跃 Codex。线程因此停在 `inProgress`，分页投影又卡在大型 `compacted` 记录前。

自动切换继续统一复用 `CodexAutomaticSwitchPolicy.hasNoActiveTasks`，活跃、等待输入、断开、陈旧或无法确认都会阻止自动写入。手动切换按用户最新授权改为先显示强制确认；用户确认所有对话已关闭后，可跳过当前对话恢复和实时任务快照门禁，但不能跳过身份、锁、原子写入、验证或失败回滚。

### 根因 B：本次无切号复发，renderer 触发点仍待锁定

当前最强证据指向 Desktop 的 paginated 历史恢复链：

1. 原始记录和服务端分页仍在。
2. 同一任务的界面只恢复头部小分页，且页面可处于 hidden 状态。
3. 长任务发生 `compacted`、页面缓存回收或可见性切换后，已显示页可能被界面丢弃，用户只剩最新片段。

短诊断任务的元数据在至少 47 分钟内稳定，进一步支持 renderer/挂载侧而不是原始数据删除；但因本轮未打开诊断任务界面，仍不能排除更长历史或自然压缩才会触发 app-server 投影异常。尚未严格区分的两个候选触发器：

- `compacted` 写入后，paginated 投影/游标没有让 renderer 保留已加载页。
- renderer 隐藏、缓存回收或重新挂载后，只重新请求最新 5 个轮次，没有恢复旧页。

下一轮必须用同一时间轴同时采样 rollout 行号、`thread/turns/list` 游标、renderer 可见性和用户屏幕结果，不能凭单一日志猜二选一。

## 当前源码与本地构建

需要保留的工作树：

```text
M  HANDOFF.md
M  Sources/CodexUsageWidget/Domain/CodexSessionLinkSelfTest.swift
M  Sources/CodexUsageWidget/Providers/RuntimeProvider.swift
M  Sources/CodexUsageWidget/Services/CodexAccountActions.swift
M  Sources/CodexUsageWidget/Services/CodexAppServerTaskClient.swift
M  Sources/CodexUsageWidget/Services/CodexProfileStore.swift
M  Sources/CodexUsageWidget/Services/CodexSessionOpener.swift
M  Sources/CodexUsageWidget/UI/CodexAccountManagerView.swift
M  Sources/CodexUsageWidget/main.swift
?? build-auth-refactor/
?? docs/IMPROVEMENT-SUGGESTIONS-0824v1.md
```

本地构建为 `8.26.1 (2)`；交接时没有 Swift 源码比该二进制更新，说明 0828v2 强制手动切换修改已包含在该构建中。本轮实际执行并通过：

```bash
make BUILD_DIR=build-auth-refactor build

APP='build-auth-refactor/CodexAccountManagerNext.app'
BIN="$APP/Contents/MacOS/CodexAccountManagerNext"
"$BIN" --self-test-account-switch-safety
"$BIN" --self-test-codex-session-link
codesign --verify --deep --strict "$APP"
git diff --check
```

此前完整环境曾有 23 个自测入口全部通过；最新受限环境只复跑了与本轮直接相关的 `account-switch-safety` 和 `codex-session-link`，两者通过。另有代码签名与 `git diff --check` 通过。不要把此前 23/23 写成最新全量复测。

这些结果证明构建、纯逻辑、签名与元数据读取；不证明 Desktop 历史持续可见，也不证明真实切号已经完成验收。

## 已实现但仍需保护的切号逻辑

- 手动、命令行和自动切换进入同一身份校验、锁、优雅退出、原子写入、验证、回滚与恢复链。
- ChatGPT/Codex 运行时，手动切换先要求用户确认所有对话均已关闭；确认强制后不记录或恢复当前任务。
- 非强制恢复模式需要重启时，切换前读取完整分页轮次 ID 指纹；最多接受 4 页、1000 轮，异常或超限阻止写入。
- 非强制恢复模式会重复打开原任务并比对轮次 ID，随后等待 90 秒人工界面确认；强制模式明确跳过整段会话恢复流程。
- 自动切换仅在 Codex 已退出时继续；Codex 运行中因无法自动确认 renderer 而 fail-closed。
- 共享 daemon 的停止、陈旧 socket 清理、Mimi bootstrap 竞态重试和 30 秒启动验收已经加入。
- 除用户已明确授权的手动强制入口外，不要削弱身份、锁、原子写入、验证、journal 或回滚，也不要回到“猜最近任务”的方案。

## 产品需求追踪：本轮未重新逐项验收

以下均是用户已经明确提出的产品要求。当前工作树可能已有部分实现；接手时先查源码和测试，不要重做：

- 账号与快照页面显示每个账号的 5 小时额度。
- 5 小时额度降到 5% 时，按安全候选规则自动切换。
- 每个账号有“参与自动切换”开关；关闭后不消耗其额度，但仍参与 7 天暖号。
- 5 小时和 7 天暖号按各账号自己的官方重置时间执行，并覆盖官方随机重置场景；尽量少用 Token。
- Pro 倍率由用户选择 5x 或 20x，不硬编码替用户判断。
- 总消耗统计不得因切换账号反复变低；官方与本地累计口径要稳定、可解释。
- 设置页和账号页继续优化排版与视觉辨识度，避免像 CodexU；不得破坏原有功能。
- 发布前做对抗审查、脱敏截图、差异和秘密扫描；GitHub 合并/推送必须在修复与验收后再次明确授权。

## 下一轮最小行动

1. 先读本文件，不要重放整段旧对话。
2. 在现有最终构建中点击目标卡“切换并打开”，核对“强制切换账号？”文案后点“强制切换”。
3. 随后验收目标身份、启动/监控状态、共享 daemon 和 pending journal；强制模式不恢复原对话。
4. 只有真实切换验收结束后，才继续独立调查 renderer 的分页历史消失；不要再把该问题设为强制切换前置条件。

## 完成标准

在宣布“对话不会再丢”前，至少同时满足：

- 无切号情况下，两个新轮次锚点和一个旧轮次锚点经过 20 分钟、失焦/恢复及一次分页重载后仍在界面可见。
- `thread/turns/list` 的最新页和上一页连续、无重复、无断档，原始 JSONL 仍可解析。
- 若发生自然 `compacted`，压缩前后的锚点都能重新加载。
- 不靠归档/取消归档、切换到另一任务或人工改 SQLite 来恢复。
- 强制真实切号验收必须满足：目标身份与 auth 匹配、启动/监控一致、新 ChatGPT 进程正常、共享 daemon 正常、pending journal 不存在。强制模式不以原任务恢复为完成条件。

## 禁止重复的动作

- 不要把 `NSWorkspace.open`、深链返回成功、窗口标题匹配或 App 已启动当成历史恢复证明。
- 不要再归档/取消归档当前任务来“刷新”。
- 不要修改原始 rollout、SQLite、TCC、xattr 或系统安全权限来掩盖界面问题。
- 不要杀死全部 Codex/ChatGPT 进程，也不要从活跃长任务中触发真实切号。
- 不要输出或提交账号 ID、邮箱、token、Keychain 内容、消息正文、私有日志路径或 webhook。
- 不要覆盖现有未提交文件，不要影响旧版 App，不要发送飞书测试通知。
- 不要提交、合并或上传 GitHub，除非用户在当前修复验收完成后再次明确授权。

## 0827v1 / 0827v2 / 0827v3 历史说明

0827v1 完成了旧线程分页索引恢复，并在真实身份变化前加入共享活跃任务门禁。该结论仍有效，但它只覆盖“切号终止活跃任务”这一条触发链，不能再作为全部对话消失问题的单一根因。

0827v2 证明无切号复发时原始 rollout 和官方分页仍在，并把后续调查收敛到 paginated 投影与 Desktop renderer。0827v3 只在 Next 可控的共享切换链增加可验证、可回滚的防护，没有声称修复官方 renderer。
