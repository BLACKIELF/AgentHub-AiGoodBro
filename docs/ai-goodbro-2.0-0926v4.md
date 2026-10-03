# AiGoodBro 2.0 · 0926v4

**状态：当前产物已通过构建、签名和 33 组原生自测，并覆盖到本机 AiGoodBro.app；安装版尚未启动验收。用户新增的“直接复用原版代码、尺寸完全一致”要求仍未完成，不能把当前版本视为视觉验收通过。** 对外产品版本名为 **AiGoodBro 2.0**；当前内部构建标识为 **9.6.12 (61) · 0926v4**。应用显示名与 Bundle ID 保持现有值，菜单栏与弹窗沿用 AiGoodBro 图标和名称。

## 右侧停靠栏：接入与验收中

用户补充的红框截图明确对应上游 Edge Dock：顶部今日用量、中央多个平台额度环、底部 `tok/s`。此前的“总计／工具／模型”截图是它的悬停详情卡。原生接入沿用上游的屏幕边缘把手、凹肩窄栏与带尾巴详情卡，复用 AiGoodBro 的统计、额度、图标和双语界面。

图标按用户最新要求统一采用上游的 Agent／工具标识，覆盖导航、额度、统计与侧栏；AiGoodBro 的产品名称和应用图标保留。图标资源与调用点在本轮候选中统一，安装结果以最终回执为准。

当前已确认的视觉差异：上游常规额度环为 42×42、图标 17×17；紧凑模式为 34×34、图标 14×14。当前原生额度图标仍受旧 `.scaleEffect(0.63)` 影响，实际仅约 10.7pt。用户要求连同尺寸、圆环、留白以及其他复用界面直接使用原版代码，不能继续凭感觉重绘。已按用户追加要求另行下载并安装官方 Token Monitor v0.62.0，供直接对照；AiGoodBro 后续源码修正与再次验收仍待完成。

待核对：右侧首次显示、悬停展开与移出收起、点击固定、拖动位置及重启恢复、左右侧切换、常显模式、工具／模型排行和精确 Token 数，以及多屏与小屏边界。默认按红框顺序提供“今天”、最多三个已有额度平台和速率；“总计”可从设置添加，用户明确清空项目时保留空列表。未知额度、成本或历史覆盖不足时不补成零；最近会话按实际采集时间展示。速率沿用上游真实输出 Token 增量除以同批性能记录的耗时增量，不能拿两次界面刷新间隔当作生成耗时；无样本时显示“—”，样本过期后标为空闲并最终清除。

代码来源为固定 vendor 的 `edgeDock/geometry.js`、`renderer/edgeDock/shapes.js`、`dock.css` 与 `tokenRatePresentation.js`。本轮通过 GitHub 只读接口再次核对 [上游提交 3479107](https://github.com/Javis603/token-monitor/commit/347910736860acd659ac953628a2b90ebde2b0e3) 与 [MIT 许可](https://github.com/Javis603/token-monitor/blob/347910736860acd659ac953628a2b90ebde2b0e3/LICENSE)：相较 vendor，形状、几何及速率模块未变；新额度耗尽保护另行对照。未将整个采集依赖包升级到未经验证的主分支。

## README 开篇候选文案

### 中文

**AiGoodBro 2.0** 是一款原生 macOS Codex 多账号工作台，集中查看账号额度、Token 用量和服务状态，右侧停靠栏方便随时查看今日用量与额度。开启重置消息推送并配置飞书机器人后，公开重置预告有更新时会自动发送提醒，方便及时安排任务、减少反复刷网页。菜单栏可查看 Home、Status 和 Totals，也可按需切换账号或启动隔离 CLI。

### English

**AiGoodBro 2.0** is a native macOS workspace for Codex accounts and multi-agent work, bringing quota, token usage, and service health together. Its edge dock keeps today's usage and limits within reach. Enable reset-message delivery and configure a Feishu bot to automatically receive new public reset announcements, so you can plan work sooner and check the website less often. The menu bar offers Home, Status, and Totals; switch accounts or launch isolated CLIs when needed.

## 版本简介候选

### 中文

2.0 将公开重置公告推送、账号额度与多 Agent 用量放进同一工作流，并增加原生 Token 统计、菜单栏 Home / Status / Totals、右侧用量与额度栏，以及官方服务状态查看。开启重置消息推送并配置飞书机器人后，新公开预告会自动发送提醒，便于安排任务、少刷网页。统计页提供 8 项用量指标、365 天热图、趋势以及模型和工具排行；美元成本为用量估算，不是账单。默认界面使用原生毛玻璃效果，Agent／工具标识统一复用上游图标，并支持中文、英文和系统降低透明度偏好。AiGoodBro 的名称与应用图标保留。版本继续提供 GPT-6 Sol、Luna 等模型档位与既有多账号 CLI 工作流。Hub 读数据和发布本机数据是彼此独立的可选操作，默认关闭。

### English

Version 2.0 brings public reset-announcement delivery, account quota, and multi-agent usage into one workflow. Enable reset-message delivery and configure a Feishu bot to automatically receive new public announcements, helping you plan tasks sooner and check the website less often. It adds a native Usage Dashboard, menu-bar Home / Status / Totals, an edge dock for usage and quota, and official service-status views. The dashboard includes eight usage metrics, a 365-day heatmap, trends, and model and tool rankings; USD costs are usage estimates, not bills. The default interface uses native frosted glass, consistently reuses upstream agent and tool artwork, and respects the system's Reduce Transparency preference. The application keeps its AiGoodBro name and icon. The interface is available in Chinese and English, alongside the existing multi-account CLI workflow and GPT-6 Sol / Luna model presets. Hub reading and publishing local data are separate opt-in actions and remain off by default.

## 仓库 About 短简介候选

**中文：** 原生 macOS Codex 多账号工作台：额度、Token 统计、服务状态、账号切换与隔离 CLI。开启重置推送并配置飞书后，公开预告更新会自动提醒，方便安排任务、少刷网页。

**English:** Native macOS workspace for Codex accounts: quota, usage dashboard, service health, account switching, and isolated CLIs. Enable reset delivery and configure Feishu to get new public announcements automatically, plan work sooner, and check the website less often.

## 表述边界

- 重置提醒只跟进已公开发布的公告，帮助安排任务并减少反复查看网页；不预测尚未公开的官方时间，也不表示账号额度已经到账。
- 用量金额是根据本机记录估算的美元成本，不是供应商账单或实收金额。
- Hub 不默认读取或上传本机数据；读取 Hub 与发布本机用量需要分别开启，发布另需确认范围。
- 通知是否送达取决于 macOS 通知权限；没有权限时仍可在应用内查看。
- 2.0 是对外产品版本名，不替换应用显示名、Bundle ID 或内部构建版本。
- 保留原有截图与引导、AiGoodBro 联系方式、MIT 许可及 `Resources/THIRD_PARTY_NOTICES.txt` 中的开源致谢。Token Monitor v0.62.0 是固定的上游采集与统计来源；应用使用原生 SwiftUI 界面，不宣称已移植上游 Electron 应用。不改写历史版本说明、上游原文或 Windows 版本介绍。

## 验证状态与证据

| 项目 | 状态 |
|---|---|
| 全 Swift 源文件 typecheck 与原生自测 | 新增 Edge Dock 后 229 个 Swift 源文件 typecheck 无错误；两处收口修复和图标统一后的最终产物 33/33 组自测通过，包含 Edge Dock 数据投影、速率与几何自测 |
| 标准优化构建 | 最终构建退出 0，签名、离线包内运行时与资源验证通过；记录位于 `edge-dock/build-final3.log`、`self-tests-final.log` 和 `verify-runtime-final.log` |
| Token 统计、菜单栏、Status / Totals 原生预览 | 17 张合成 PNG 渲染通过；宽／中／窄 8／4／2 列 KPI 和关键品牌、字体、热图已目检；真实桌面上的原生毛玻璃仍待实机回执 |
| 账号与设置升级保留、直接覆盖安装核对 | 已覆盖本机唯一 AiGoodBro.app；内部版本 9.6.12(61)，安装二进制与候选 SHA256 一致，签名通过，auth/config 前后哈希未变；安装版尚未启动验收 |
| 上游 Token Monitor vendor 闭包及 MIT 致谢 | v0.62.0 来源、987 文件清单、16 个 Darwin arm64 依赖归档、Node 22.23.2 与许可证已核对；候选包离线资源验证通过 |
| 包内引擎额度兼容与桥接 | 使用候选包 Node/依赖跑上游额度相关测试 122/122、传输依赖测试 7/7 通过；最终包内桥接的 capabilities、collectUsage、collectLimits 三个空源入口均返回成功，网络与凭据刷新均关闭 |

包内引擎测试记录位于 `.local-artifacts/token-monitor-native-0926v1/packaged-limits-tests-0926v4.log` 与 `packaged-undici-tests-0926v4.log`，vendor 来源证据见 [审核清单](token-monitor-vendor-review-evidence-0926v1.json)。桥接测试使用空源与禁用网络的请求，不证明真实账号额度、Hub 写入或通知送达。当前 Swift 5 模式的构造期 actor 警告经审查未发现 `self` 逃逸；迁移至 Swift 6 模式前仍需消除相应诊断。安装与运行证据待本轮回执；本机候选不是已公开下载的安装包。

## 后续阶段：七套主题逐套落地

用户认可现有七套主题缩略图的配色。下表是**后续待实现、待实机验收**的工作，不计入本轮 2.0 已完成项。逐套以对应缩略图和深浅色 token 为基准，落实背景、原生毛玻璃面板、按钮与选中态；不能只替换强调色，也不能把七套主题刷成相同的底色。服务健康、错误等安全状态色可继续保持语义。

| 主题 | 背景 | 玻璃面板 | 按钮与选中态 | 深色／浅色 | 主窗口 | 菜单栏弹窗 | 设置窗口 |
|---|---|---|---|---|---|---|---|
| 液态键帽 | □ | □ | □ | □ | □ | □ | □ |
| 敦煌飞天 | □ | □ | □ | □ | □ | □ | □ |
| 故宫红墙 | □ | □ | □ | □ | □ | □ | □ |
| 蒙特雷曙霞 | □ | □ | □ | □ | □ | □ | □ |
| 默认 | □ | □ | □ | □ | □ | □ | □ |
| 千里江山 | □ | □ | □ | □ | □ | □ | □ |
| 青花瓷 | □ | □ | □ | □ | □ | □ | □ |

每格只有在该主题的实际界面与缩略图配色一致、文字和控件在浅深模式均清楚、主窗口及菜单栏 Home／Status／Totals 和设置窗口逐套实机核对后才能勾选。另需验证系统自动外观切换、降低透明度与提高对比度的回退；这些回退可以使用实色，但不能出现难辨文字或丢失操作入口。
