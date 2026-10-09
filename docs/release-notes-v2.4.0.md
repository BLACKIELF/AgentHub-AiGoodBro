# AiGoodBro 2.4.0 (141)

Release name: 1009v2 · 2026-10-09

2.4 承接已验证的本地 139 功能，统一产品与更新版本为 2.4.0。下面是相较 GitHub 公开 9.6.80 (130) 的变化。

## 主要更新

- **统计引擎与定价**：内置 Token Monitor 从 0.62.0 升至固定 0.68.0，TokScale 固定 4.18.0。更新用量解析与定价，修正 Claude 重复和缓存 Token 统计；保留首页、工具、状态、设备、模型、项目、会话、额度及趋势视图。用量历史尚未完成时可先显示已读取额度，用量保持未知。
- **Claude 订阅账号与额度**：先在官方 Claude Code CLI 登录，身份核验完成后再由用户明确保存当前订阅；可关联已有 Claude-swap 订阅、手动切换和刷新额度。5 小时、7 天分别显示，独立模型额度仅在 API 实际返回时按返回名称展示，缺失值不补成满额。额度与本机 Token 用量分别计算。
- **动态反代队列**：Go SDK CLIProxyAPI 更新至 8.0.20。运行中取消参与后，尚未准入的等待和重试也会跳过该账号，已接入响应继续完成。优先、最后使用、排序、点数许可和底线与账号页同步；Pro20x 默认最后使用，可自行调整，桌面账号在所在分组作后备。已回滚的无效准入不再重复等待；首帧前失败可在已准入账号间轮换，已开始的流式响应不重放。
- **统一 TPM 与紧凑布局**：顶部、浮窗底部与侧栏共用缓存的每分钟 Token 消耗量，统一格式化、本地化单位和舍入，复用已有采样。账号列表的 5h / 7d 圆环放在信息右侧、顶部并排，邀请为小图标，操作按钮分两排。首页中文明确显示重置卡、可用点数（点）与可用金额（美元）；编号保持单行。
- **侧栏与引导**：侧栏支持大小、75–150% 缩放、可选刷新按钮和运行指示，继续使用已有刷新调度。手动 Claude 引导不覆盖安装引导进度；Claude 卡片跟随卡片大小设置。保留 ⌘I、图钉、触控板轻触反馈、明暗主题和新用户／老用户安装引导。
- **重置卡与安装方式**：保留到期信息、逐账号临期自动使用和下载校验。自动使用默认关闭、默认提前 30 分钟；仅在身份核验通过且空闲时尝试，结果不明则暂停核对。安装包下载不自动退出、覆盖应用或开启可选功能。

## 本轮 141 修复

- **Claude 解除关联**：活跃订阅或身份状态未知时，不能解除关联；过时菜单触发的操作也重新核验，避免删掉仍在使用的订阅。
- **Claude 过期目标切换**：用户明确切换到已过期的目标订阅时，按 Claude-swap 协议续期，先持久化旋转后的令牌，再继续切换。续期结果未知时不重复消费令牌，要求通过官方流程重新登录。
- **Grok 会话标题**：摘要中的 `generated_title` 实为原始写作提示词，不再作为显示标题或同步标题。保留日期、项目等非内容元数据及其他来源的真实标题；不回写或迁移已保存的历史标题。
- **反代故障说明**：网关连接拒绝、超时、取消和普通转发失败分别说明；HTTP 503 与不自动重连的行为保持不变。
- **反代退出清理**：已确认退出的子进程，租约清理遇到忙碌锁时最多重试 3 次、间隔 200 毫秒；不清理新的运行或仍活跃子进程的租约。

## 升级与下载

仅提供 **macOS 13+、Apple Silicon ARM64**。本包为本地 ad-hoc 完整性签名，**未做 Apple 公证**。

**9.6.x 用户需手动下载覆盖。**旧客户端按 SemVer 比较，会把 2.4.0 视为低于 9.6.x，因此无法识别为新版；2.3.0 客户端可正常发现 2.4.0。等待任务结束并正常退出旧版，备份旧 App 和本机数据，再使用 DMG 或 ZIP 替换。重新打开后核对 2.4.0 (141) / 1009v2，并按引导检查微信、飞书和新设置。

[下载 DMG](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v2.4.0/AiGoodBro-2.4.0-mac-arm64.dmg) · [下载 ZIP](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v2.4.0/AiGoodBro-2.4.0-mac-arm64.zip) · [GitHub Release](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/tag/v2.4.0)

## 验证依据与运行边界

2.4.0 (141) 正在重新构建与核验。Grok 相关 94 项测试通过；Claude 服务与存储测试使用模拟 Keychain / HTTP，通过不等于真实账号验收。网关错误分类通过聚焦 Go race 检查；租约清理通过 28 项隔离检查，发布工作树复验仍待完成。

Desktop 与 Engine 已从固定来源隔离重建：Desktop 的 ASAR、23 个 Mach-O 文件及签名检查通过，Engine 的依赖、冻结源码、清单与独立 receipt 校验通过，8 项运行时自检通过；两处均包含相同的 Grok 修复源码。**最终 141 应用的 35 组原生自测、全部资源、完整应用签名及 DMG / ZIP 包核验待补**。旧 140 的 SHA256、字节数和 2,144 项文件树记录不适用于 141。

139 功能基线还包含 436 项 Swift 反代检查、248 项 Go race 检查（3 项需主动开启的检查跳过）、Go vet 及 58 项生产 Swift IPC + Go 本机 HTTP 组合检查。这些为已有基线记录，不称为本轮 141 全部重新执行。

141 尚未安装或进行正常启动验收。本轮检查不代表真实账号登录、切换、真实提供方调用、重置卡兑换、微信／飞书送达或全局快捷键交互已验收。本轮用户再次反馈反代异常需重启后恢复，原因仍在排查；重启仅是恢复动作，本次不保证真实反代稳定性，也不声称历史未知退出事件已全部归因。

已知界面限制：Codex 专用页在窄窗口列表模式下，“反代／调度／优先／最后使用”控件可能挤压，按用户决定留待下一版修正。本次既有布局改进不代表所有页面的窄窗问题都已解决；当前可使用卡片模式或加宽窗口。

内嵌模式保留宿主策略：不自动开启 Dots 观察及 Cursor / Antigravity 自同步，Cloud 按已保存的明确设置运行；原 macOS WidgetKit 扩展保留为不可注册的归档，不提供其功能。实际额度覆盖取决于工具、登录状态和提供方返回，不能把上游功能总数视为本机已接通数量。见[宿主适配说明](../Companion/TokenMonitorDesktop/README.md)。

README 新增 `docs/images/1009v2` 的六张真实登录、引导和设置图，于 2026-10-09 拍摄于已安装的 2.3.0 (139)，所示设置在 2.4 中沿用相同呈现。总览、账号与用量复用已公开的 2.3.0 (137) 主界面原图；反代及侧栏复用用户提供的 `1009v1` 局部图，该图未显示版本编号。所有数值仅代表截图当时状态，不作为 141 实机验收证据；Claude 只展示真实登录入口，未使用测试账号额度图。来源与图片校验值见[最新图片记录](public-ui-1009v2.md)，旧清理记录保留在 [1008v1](public-ui-1008v1.md)。

## 固定来源

| 组件 | 版本 / 修订 | 来源记录 |
|---|---|---|
| Token Monitor | 0.68.0 / `5d2db368d8313415763860d594de00e46a663418` | [桌面运行时固定清单](../Companion/TokenMonitorDesktop/SOURCE.json) |
| TokScale fork | 4.18.0 / `d5e8ad9b25bfafb43b5b6804940929b728a6f48a`，`token-monitor-d5e8ad9b` | [引擎固定清单](../Companion/TokenMonitorEngine/SOURCE.json) |
| CLIProxyAPI | 8.0.20 / `0f96f568e4dbf6f84ad7399a74b78344c5eac7e6` | [反代固定清单](../Companion/LocalProxy/SOURCE.json) |

保留原许可证与版权声明，见[第三方声明](../Resources/THIRD_PARTY_NOTICES.txt)。本次不提供 Intel 或 Windows 安装包。

## 安装包与 SHA256

| 文件 | SHA256 |
|---|---|
| `AiGoodBro-2.4.0-mac-arm64.dmg` | 待最终 141 安装包核验 |
| `AiGoodBro-2.4.0-mac-arm64.zip` | 待最终 141 安装包核验 |

最终核验后，每个安装包附同名 `.sha256` 文件；本表的 SHA256、字节数和完整文件树结果待 141 安装包生成后填写。不得使用旧 140 的校验值验证 141。

## English

AiGoodBro 2.4.0 (141), release 1009v2, carries the verified local build 139 feature baseline. Compared with public 9.6.80 (130), it pins Token Monitor 0.68.0, TokScale 4.18.0 and CLIProxyAPI 8.0.20; updates parsing and pricing; and fixes duplicate and cached Claude tokens. Home, tool, status, device, model, project, session, limits and trend views remain available. Previously read quotas can appear before usage history finishes; unfinished usage stays unknown.

Build 141 includes five further fixes:

- Active Claude subscriptions and subscriptions with unknown identity cannot be unlinked, including actions from stale menus.
- An explicitly selected expired Claude target is refreshed using the Claude-swap protocol. Rotated tokens are persisted before switching; an uncertain result is not consumed again and requires official sign-in.
- Grok's `generated_title` writer prompt is no longer used as a displayed or synced title. Dates, project metadata and genuine titles from other sources remain; previously saved titles are not migrated.
- Gateway connection refusal, timeout, cancellation and other forwarding failures receive distinct messages. HTTP 503 and no automatic reconnection are retained.
- Lease cleanup for confirmed exited children retries a busy lock at most three times, 200 ms apart, while protecting new runs and active children.

Claude subscriptions use official Claude Code CLI sign-in, followed by explicit saving after identity verification. Existing Claude-swap subscriptions can be linked and switched manually. The 5-hour, 7-day and API-returned independent model limits appear separately, with missing or previous observations labeled. Quota and local Token statistics remain separate.

Disabling proxy participation skips admissions still waiting or retrying, while admitted responses finish. Priority, Use last, order and credit floors stay synchronized with account controls. Pro20x defaults to Use last and is adjustable; Desktop is a fallback within its group. Subscription quota precedes credits; credit continuation remains opt-in. An abandoned reservation is not waited on repeatedly, and a started stream is not replayed through another account.

Home, the floating bubble footer and sidebar share cached TPM without extra scans. Compact account rows use adjacent quota rings, an invitation icon and two rows of controls. Sidebar sizes, 75–150% scaling, optional refresh and running indicators are available. Manual Claude setup keeps its progress separate from installation setup; Claude cards respect the card-size setting. Reset-card controls, themes and new/returning-user setup remain available. Automatic reset-card use is off by default with a 30-minute lead and requires an idle, verified account; uncertain outcomes pause for review. Downloads do not install or enable optional features automatically.

**macOS 13+ on Apple Silicon ARM64 only; ad-hoc signed, not Apple-notarized.** Clients on 9.6.x require a manual DMG / ZIP download because SemVer considers 2.4.0 lower. Clients on 2.3.0 can discover 2.4.0 normally. Finish active work, quit normally, back up the old app and local data, replace it, and check 2.4.0 (141) / 1009v2 on reopening.

Build 141 is being rebuilt and verified. The 94 Grok-related tests passed. Claude service and store tests use simulated Keychain / HTTP; gateway error classification passed focused Go race checks. Lease cleanup passed 28 isolated checks, with release-worktree verification still pending. Desktop and Engine were rebuilt from pinned inputs; Desktop ASAR and 23 Mach-O signature checks, Engine manifests and the independent receipt, and eight runtime smoke checks passed. Both payloads contain the same fixed Grok source. **The final build 141 native self-test groups, all resources, whole-app signing and DMG / ZIP validation remain pending.** Build 140 hashes, byte counts and its 2,144-entry package tree do not apply to build 141. Earlier Swift / Go proxy checks remain inherited build 139 evidence.

Build 141 has not been installed or accepted through a normal launch. Real provider calls, account sign-in and switching, card redemption, message delivery and global hotkey interactions were not exercised. A user-reported proxy runtime fault required a restart to recover; its cause remains under investigation. This does not establish a permanent fix or guarantee real proxy stability. Historical unexplained exits are not claimed fully resolved. Embedded Dots observation and Cursor / Antigravity self-sync stay disabled; Cloud uses saved explicit settings, and the original WidgetKit extension is archived and inactive.

Known UI limitation: Proxy / Scheduling / Priority / Use last controls can become cramped in narrow list mode on the dedicated Codex page. The user deferred that fix to the next version; existing layout improvements do not resolve every narrow-window case. Use cards or a wider window for now.

The six new 1009v2 sign-in, setup and settings images were captured from installed 2.3.0 (139) on 2026-10-09; 2.4 retains the same presentation of those settings. Overview, accounts and usage reuse the published build 137 home image. The retained user-provided proxy and sidebar crop shows no build number. These are capture-time records, not build 141 acceptance images. Claude is shown through its real sign-in entry, without synthetic quota fixtures. The [image record](public-ui-1009v2.md) lists sources, actual formats and image hashes. The final build 141 package hashes and byte counts above remain pending verification.
