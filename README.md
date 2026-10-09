# AiGoodBro · AgentHub（2.4）

**看清额度、用量和任务占用；需要时，让本机任务使用自己的 Codex 账号池。**

AiGoodBro 是面向个人自用的 macOS AI 工作台，汇总 Codex 多账号额度、Token 用量、本机 CLI 和公开重置消息，并提供可选的本地反代。界面支持中文和英文，主页名为 AgentHub。

**中文** | [English](README.en.md)

本次发布为 **2.4 · 1009v2**，更新版本 **2.4.0 (141)**。相较公开的 9.6.80 (130)，升级内置用量与反代引擎，加入 Claude 订阅账号、独立额度圆环和更紧凑的账号列表；顶部、浮窗与侧栏共用缓存的 TPM。重置卡和新用户／老用户安装引导继续保留。见[2.4 发布说明](docs/release-notes-v2.4.0.md)、[使用说明](docs/usage-guide.md)和[变更记录](CHANGELOG.md)。

[下载 Apple Silicon DMG](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v2.4.0/AiGoodBro-2.4.0-mac-arm64.dmg) · [备用 ZIP](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v2.4.0/AiGoodBro-2.4.0-mac-arm64.zip) · [GitHub Release](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/tag/v2.4.0)

[总览](#overview) · [账号](#accounts) · [用量](#usage) · [反代](#proxy) · [重置卡与消息](#messages) · [侧栏](#dock) · [连接引导](#setup) · [主题](#themes) · [下载](#downloads) · [源码与文档](#sources)

<a id="overview"></a>

## 01 · 工作台总览

首页把账号、额度、Token 用量、重置消息与已连接工具放在一起。剩余额度、重置时间和任务占用分别呈现；公开消息与账号实际额度分开显示，费用是本机数据估算。分区支持缩放，账号支持卡片与列表，重置消息两列共用宽度，并保存用户调整的比例。

<p align="center">
  <a href="docs/images/1009v1/home-live.png"><img src="docs/images/1009v1/home-live.png" width="1000" alt="AiGoodBro 137 主界面实机长截图：重置消息、Token 用量热图与趋势、多账号额度卡片和其他已连接工具状态。"></a>
</p>

*本页均使用真实界面原图。首页长图于 2026-10-09 采集自已安装的 2.3.0 (137)；新增登录、引导和设置图同日采集自 2.3.0 (139)，所示设置在 2.4 中沿用相同呈现；用户提供的侧栏局部图未显示版本。141 尚未安装，图中数值为拍摄时快照，不作为 141 覆盖升级或真实调用验收。点击图片可查看原尺寸，详见[截图来源与校验值](docs/public-ui-1009v2.md)。*

**2.4 相较公开 130 的变化**

- **用量统计升级**：固定 Token Monitor 0.68.0 与 TokScale 4.18.0，更新解析与定价，修正 Claude 重复和缓存 Token 统计；继续提供用量、模型、项目、会话、额度及趋势视图。
- **Claude 订阅集中查看**：先在官方 Claude Code CLI 登录，再明确保存当前订阅；支持关联已有 Claude-swap 订阅和手动切换。5 小时、7 天分别显示，独立模型额度只按 API 实际返回的名称和数值展示。
- **反代运行中调整队列**：CLIProxyAPI 更新至 8.0.20。取消参与会跳过尚未准入的等待和重试，已接入响应继续完成；优先、最后使用、排序和点数底线与账号页同步。
- **同一份 TPM，更紧凑的布局**：顶部、浮窗底部与侧栏复用已有 Token 消耗采样；账号列表把 5h / 7d 圆环放在信息右侧，邀请保留为小图标，操作按钮分两排。重置卡、可用点数与可用金额的中文标签更明确。
- **侧栏与引导完善**：增加侧栏大小、75–150% 缩放、可选刷新按钮和运行指示设置；手动 Claude 引导与安装引导分别保留进度，Claude 卡片跟随卡片大小设置。

本轮 141 还修正 Claude 订阅解除关联与过期目标切换、Grok 会话标题，以及反代故障提示与退出后的租约清理，详见[五项修复与验证边界](docs/release-notes-v2.4.0.md#本轮-141-修复)。

六张独立功能原图：[Claude 登录](docs/images/1009v2/claude-login.jpg) · [工具连接](docs/images/1009v2/guide.jpg) · [重置卡设置](docs/images/1009v2/reset-auto.jpg) · [微信／飞书引导](docs/images/1009v2/notifications-guide.jpg) · [侧栏设置](docs/images/1009v2/edge-dock-settings.jpg) · [外观设置](docs/images/1009v2/appearance-settings.jpg)。均来自已安装的 139；账号与用量目前仍复用下方已公开的 137 首页原图，独立实拍待补。

下文按功能配图说明；[使用引导](#setup)可连接工具并查看相关设置。查看介绍不会自动开启可选功能。

<a id="accounts"></a>

## 02 · Codex 与 Claude 账号

**多账号一页掌握。** Codex 卡片和列表显示剩余额度、重置时间、点数、重置卡及任务占用，支持刷新、排序、模型选择和独立 CLI 入口。5 小时与 7 天额度分别显示；账号页与反代面板的参与、优先和最后使用设置同步。

<p align="center">
  <a href="docs/images/1009v1/home-live.png"><img src="docs/images/1009v1/home-live.png" width="1000" alt="本机 137 已公开主界面原图，包含 Codex 账号卡片、额度、重置时间和操作入口。"></a>
</p>

*复用已公开的 137 主界面原图展示账号区；账号及数值仅代表当时状态，不能据此验证 2.4 新增布局。*

已知限制：Codex 专用页在窄窗口列表模式下，“反代／调度／优先／最后使用”控件可能挤压，已安排下一版修正；当前可使用卡片模式或加宽窗口。

**Claude 订阅账号按官方流程连接。** 先在官方 Claude Code CLI 登录，身份核验后选择“添加当前登录账号”／“保存订阅”。已有 Claude-swap 订阅可以关联；保存后可手动切换与刷新额度。添加另一个账号前先保存当前订阅，再到官方 CLI 登录另一个，不要先 `/logout`，以免已保存凭据失效。

Claude 的 5 小时、7 天与 API 实际返回的独立模型额度分别用圆环展示，按返回名称显示，不补出缺失额度；旧快照明确标记。额度与本机 Token 统计分别计算，Claude 卡片跟随卡片大小设置。

<p align="center">
  <a href="docs/images/1009v2/claude-login.jpg"><img src="docs/images/1009v2/claude-login.jpg" width="1000" alt="本机 139 Claude 账号页与官方登录入口真实截图。"></a>
</p>

*先完成官方 CLI 登录，再返回保存当前订阅；登录入口的展示不代表已完成账号登录或额度读取。*

其他工具按提供方能力读取，连接状态和额度读取结果分别呈现。ZCode 是桌面工具；WorkBuddy 桌面额度目前不可读。Kimi CLI 页面展示上次快照，使用前请刷新确认。详见[原生 CLI 读取范围](docs/local-cli-accounts.md)。

<p align="center">
  <a href="docs/images/1009v2/guide.jpg"><img src="docs/images/1009v2/guide.jpg" width="1000" alt="本机 139 工具连接引导真实截图，Kimi Code 显示已发现认证配置。"></a>
</p>

*图中 Kimi Code 显示“已发现认证配置”；这张连接引导图不代表 Kimi 额度读取成功。旧额度快照仅供参考，使用前请刷新。*

<a id="usage"></a>

## 03 · Token 用量、热图与趋势

**内置 Token Monitor：35+ 种工具的 Token 用量追踪、28+ 家提供方的额度检测。** 该口径来自本版固定的 [Token Monitor 0.68.0 上游说明](Companion/TokenMonitorEngine/upstream/README.zh-CN.md#功能特性)；其总览列有 43 项工具，表格中 35 项支持 Token 追踪、28 项支持额度。数字描述上游覆盖，具体在本机接通的项目取决于工具、登录状态、提供方返回和内嵌宿主策略，以界面状态为准。

用量看板汇总累计 Token、估算成本、活动热图和趋势，支持按工具、设备、模型、项目或会话查看；会话详情与导出保留既有统计入口。成本基于本机记录和定价估算，不能当作供应商账单。

首页实机图中的“用量统计”展示累计总计、热图与趋势；点击侧栏或菜单栏的统计入口，可进入更多分项视图。选择工具／模型和时间范围后，按当前已读取数据查看变化。

<p align="center">
  <a href="docs/images/1009v1/home-live.png"><img src="docs/images/1009v1/home-live.png" width="1000" alt="本机 137 已公开主界面原始长截图，其中用量统计展示累计 Token、热图与趋势。"></a>
</p>

*复用已公开的 137 主界面完整原图展示用量区域；数据来自拍摄时的本机记录，35+／28+ 是上游支持范围。*

主页与菜单栏共用累计总计快照；顶部、浮窗底部与侧栏共用缓存的每分钟 Token 消耗量（TPM），统一单位和格式，不增加扫描频率。Token Monitor 0.68.0 与 TokScale 4.18.0 更新解析和定价，修正 Claude 重复及缓存 Token 统计；历史尚未完成时可先呈现已读取的额度，用量仍保持未知。

<a id="proxy"></a>

## 04 · 本机反代与账号队列

<p align="center">
  <a href="docs/images/1009v1/proxy-status-edge-dock.png"><img src="docs/images/1009v1/proxy-status-edge-dock.png" width="360" alt="用户提供且已公开的反代状态与侧栏实机原图，图中未显示版本编号。"></a>
</p>

*用户提供且已公开的反代状态原图，版本未知；可查看运行状态与账号额度并进入反代设置。图片不作为 141 安装或真实请求验收。*

本地反代是可选的个人工具。兼容客户端把模型请求发到本机代理，再由 AiGoodBro 按参与状态、优先／普通／最后使用分组和保存顺序选择本人已连接的账号。Pro20x 默认最后使用，可自行调整；当前 Desktop 账号在所在分组作后备。全部参与账号的可用订阅额度先于点数使用。

运行中可以取消参与，尚未准入的等待和重试也会跳过该账号，已接入的响应继续完成。优先、最后使用和排序对新请求生效；账号页与反代面板同步，点数许可与底线保留。已回滚的无效准入不会持续重复等待。

点数接续默认关闭；只有用户主动开启后，订阅额度用尽才会进入点数档。忙碌或未知状态不算额度用尽；点数底线用于请求间的账号轮换，不是单次请求的硬限额。

反代只转发推理请求。Codex Desktop 保留自己的 OpenAI 登录身份、每段对话的模型和推理强度；使用代理不改系统认证文件或全局配置。未退出并重新接入的现有 Codex 进程不会自动改走代理。

**自己开启与停止：**

1. 在 AiGoodBro 中手动开启反代；应用重启后不会自动启动它。
2. 先退出 Codex。反代成功启动且连接信息就绪后，“接入桌面”按钮才会出现；点击后重新启动 Codex 并使用本机路由。
3. 工作完成后，在反代面板停用服务。关闭主窗口只会隐藏窗口；退出应用前会确认是否停止反代。停用后正常重新打开 Codex。

已开始输出的流式响应不会切换到另一个账号重放；请求结果不明时也不会自动再次发送，避免重复执行任务。反代开关和“接入桌面”入口的存在不等于真实端到端验收完成。

141 将网关连接拒绝、超时、取消与普通转发失败分别说明，保留 HTTP 503，不自动重连。已确认退出的子进程，其租约清理遇到忙碌锁时短暂重试，避免遗留占用；保护新的运行和仍活跃的子进程。

本轮用户反馈反代异常需重启后恢复，原因仍在排查。这两项修复不证明已覆盖该异常的全部原因，重启恢复也不证明永久修复；本次验证不保证真实反代链路的稳定性。

反代为个人自用场景设计，用于自己的账号和本机任务；本项目不提供账号、凭据共享、额度转售或公共代理服务。

<a id="messages"></a>

## 05 · 重置卡、邀请与微信／飞书

**重置卡到期不容易忘。** 账号旁显示最近到期时间，悬停查看全部明细；点击重置卡数量、到期时间或信息按钮打开“到期自动使用”。逐账号自选，默认关闭、默认提前 **30 分钟**，可自行调整，减少忘记使用造成的过期浪费。

桌面账号通过已核验同身份的独立入口执行；缺少入口、任务状态不明或不空闲时暂停。应用须保持运行，结果不明时提示核对并阻止重发。查看设置不会兑换卡片。见[重置卡功能边界](docs/reset-credit-control.md)。

<p align="center">
  <a href="docs/images/1009v2/reset-auto.jpg"><img src="docs/images/1009v2/reset-auto.jpg" width="820" alt="本机 139 重置卡临期自动使用设置真实截图。"></a>
</p>

*先选择账号，再调整提前时间；图中的 25 分钟为本机自定义值，产品默认仍为 30 分钟。可选功能由用户手动开启。*

**邀请好友集中处理。** 支持批量邀请、查看邀请状态和邀请点数，奖励按官方条件发放；接受邀请不等于奖励已到账。

**微信与飞书接收提醒。** 可配置额度、重置与重置卡消息。个人微信通过腾讯官方 iLink 扫码连接，支持查询缓存状态；明确开启后，可以继续选定的 Codex 原聊天。

<p align="center">
  <a href="docs/images/1009v2/notifications-guide.jpg"><img src="docs/images/1009v2/notifications-guide.jpg" width="1000" alt="本机 139 通知连接引导：macOS 通知、微信等待会话和飞书投递待验证状态。"></a>
</p>

*连接引导分别显示功能开关与连接状态；微信仍等待会话，飞书本机授权就绪但投递待验证。*

项目工作台区分执行状态与成果状态，保留手动暂缓、取消、完成、剩余事项与原聊天入口。普通展示不调用模型；手机收件和真实对话仍待验收。见[微信与项目工作台](docs/wechat-workbench-0930v1.md)。

<a id="dock"></a>

## 06 · 侧栏与状态浮窗

<p align="center">
  <a href="docs/images/1009v1/proxy-status-edge-dock.png"><img src="docs/images/1009v1/proxy-status-edge-dock.png" width="360" alt="用户提供的实机截图：屏幕边缘的额度侧栏和展开的反代状态浮窗，显示各账号额度圆环、倒计时与点数。"></a>
</p>

*用户提供的实机局部截图；账号状态、额度和点数为截图当时的数据。*

侧栏贴在屏幕边缘，集中显示所选账号额度、Token 统计等项目；额度支持圆环、小鱼等样式。按 **⌘I** 唤出或隐藏，悬停展开详情，拖动顶部调整位置，图钉可固定侧栏或将详情保持置顶。

悬停侧栏的反代条目，展开「反代状态」浮窗：查看运行状态、请求数和账号列表，各账号显示 **5h / 7d 额度圆环、重置倒计时与点数余额**，并提供「反代设置」入口。请求快照每分钟更新，额度来自最近一次读取；缺少额度时显示「—」。

指针进入或切换侧栏条目时，支持触感反馈的触控板会给出轻触反馈，让移动和定位更有手感。可在侧栏设置关闭「触控板轻触反馈」。

<p align="center">
  <a href="docs/images/1009v2/edge-dock-settings.jpg"><img src="docs/images/1009v2/edge-dock-settings.jpg" width="820" alt="本机 139 侧栏设置真实截图，展示显示方式、缩放及刷新相关设置。"></a>
</p>

*在侧栏设置选择大小、75–150% 缩放、刷新按钮和运行指示；快照刷新复用已有账号设置。*

<a id="setup"></a>

## 07 · 官方工具连接与安装引导

按引导在官方工具或账号入口完成登录，再回到工作台检查连接状态；需要哪个工具时，再按需连接。Codex 独立 CLI 可使用自己的本机登录目录；Claude 按上方订阅流程明确保存账号，凭据只在官方流程中填写。

可识别的新装或覆盖后，新用户走完整引导，老用户检查微信、飞书和新功能并保留原有配置。手动 Claude 引导与安装引导分别保留进度；查看或关闭功能介绍不自动完成安装引导，也不自动开启可选设置。

更新弹窗展示版本和内容，支持下载进度、取消与重试；校验大小和 SHA256 后打开安装包，覆盖安装由用户完成。下载不会自动退出应用或替换文件。

<p align="center">
  <a href="docs/images/1009v2/guide.jpg"><img src="docs/images/1009v2/guide.jpg" width="1000" alt="本机 139 使用引导真实截图。"></a>
</p>

*从使用引导连接所需工具；登录、消息连接与可选设置均按用户选择进行。*

<a id="themes"></a>

## 08 · 九套主题与原生玻璃

在设置的“显示与图标”中选择配色，分别支持浅色和深色。默认灰保留原有中性界面；其他主题用统一的原生玻璃、颜色和渐变呈现，玻璃透明度与深度可调，系统“减少透明度”和“增强对比度”优先。

<p align="center">
  <a href="docs/images/1009v2/appearance-settings.jpg"><img src="docs/images/1009v2/appearance-settings.jpg" width="820" alt="本机 139 显示与图标设置，展示明暗模式、配色入口、语言、玻璃浓度和层次。"></a>
</p>

*实机图展示当前默认配色及外观设置入口；下表列出可选主题。*

| 主题 | 视觉特点 |
|---|---|
| 默认灰 · Default | 中性灰背景与蓝紫强调色，保持默认选择。 |
| 液态键帽 · Liquid Keycap | 冷调蓝青，轻盈的玻璃层次。 |
| 青花瓷 · Blue & White Porcelain | 瓷白与钴蓝，清晰克制。 |
| 蒙特雷曙霞 · Monterey Dawn | 兰紫、粉色与黎明暖色。 |
| 千里江山 · A Thousand Li of Rivers | 青绿与矿物色。 |
| 敦煌飞天 · Dunhuang Apsara | 沙金、赭色与青绿。 |
| 故宫红墙 · Forbidden City Red | 红墙、金色与深色对照。 |
| 紫蓝流光 · Violet Glow | 默认蓝紫配色的独立玻璃背景变体。 |
| WAICY 流彩 | 粉红到橙色的三段渐变，借鉴工牌候选的色值。 |

主题仅提供色值；WAICY 主题没有复制品牌图形、工牌、吉祥物或字体，也不表示官方背书。

<a id="downloads"></a>

## 09 · 下载、升级与构建

2.4 提供 **macOS 13+、Apple Silicon ARM64** 的 DMG 与 ZIP，采用本地 ad-hoc 签名，未做 Apple 公证。更新弹窗展示版本与内容，点击下载后校验大小和 SHA256；打开安装包后由用户完成覆盖安装。下载不会自动退出应用或替换文件。

**从 9.6.x 升级需手动下载：**旧客户端按 SemVer 比较版本，会把 2.4.0 视为低于 9.6.x，因此不会将它识别为新版。请使用上方 DMG／ZIP 手动覆盖；2.3.0 客户端可正常发现 2.4.0。

安装前等待任务结束并正常退出旧版，保留旧 App 与本机数据备份。新装与覆盖后的引导会检查微信、飞书和新功能。本次未执行实机覆盖升级或上游付费调用验收；本地测试与预览也不代表真实重置卡兑换、微信／飞书送达或全局快捷键交互验收。详见[本次验证与校验值](docs/release-notes-v2.4.0.md)。

源码与安装包对应 `v2.4.0`：

```sh
git clone --branch v2.4.0 https://github.com/BLACKIELF/AgentHub-AiGoodBro.git AiGoodBro-2.4
cd AiGoodBro-2.4
```

源码构建要求 macOS、Go 1.26+ 和经 SHA256 校验的 Token Monitor v0.68.0 macOS 运行时；将 `TOKEN_MONITOR_DESKTOP_RUNTIME` 和 `TOKEN_MONITOR_DESKTOP_DMG` 指向对应官方输入，再运行 `make build`。本次不提供 Intel 或 Windows 安装包，既有 Windows 源码保留。历史安装记录见 [114 发布记录](docs/source-publication-1003v1.md)。

<a id="sources"></a>

## 10 · 源码、许可证与文档入口

功能设计借鉴了相关开源项目；实际直接复用或适配的代码与资源在下表列明，并保留对应许可证和版权声明。

| 项目 | 来源关系 |
|---|---|
| [Tencent/openclaw-weixin 2.4.9](https://github.com/Tencent/openclaw-weixin/tree/24de5c9eb0dd5e595d7e2d090ed8a3f82870d42c) | iLink 协议与扫码流程的原生适配；MIT 声明保留，不安装 OpenClaw。 |
| [codexU](https://github.com/shanggqm/codexU) | 历史固定源码的二次开发与宿主适配：SwiftUI、额度、配色和 Windows 基础承接后由 AiGoodBro 维护。 |
| [Token Monitor v0.68.0](https://github.com/Javis603/token-monitor/tree/5d2db368d8313415763860d594de00e46a663418) | 固定源码与官方 macOS 运行时的宿主适配；统计引擎、桌面看板、图表和资源随包保留，AiGoodBro 通过 bridge、hooks 与 Swift 外壳接入。内嵌模式的运行边界见[宿主适配说明](Companion/TokenMonitorDesktop/README.md)。 |
| [TokScale 4.18.0 fork](https://github.com/Javis603/tokscale/tree/d5e8ad9b25bfafb43b5b6804940929b728a6f48a) · [原项目](https://github.com/junhoyeo/tokscale) | 固定修订 `d5e8ad9b25bfafb43b5b6804940929b728a6f48a`，发布输入 `token-monitor-d5e8ad9b`；统计采集基础与许可证随包保留。 |
| [CLIProxyAPI v8.0.20](https://github.com/router-for-me/CLIProxyAPI/tree/v8.0.20) | 固定 Go SDK 的宿主适配：复用调度、Codex 执行器与 Responses 处理器，保留身份、额度、点数底线和已开始流式响应不重放的检查。 |
| [Codex-Manager](https://github.com/qxcnm/Codex-Manager) | 协议适配与静态研究参考；暖号请求结构与 SSE 完成规则独立实现，见 [`CodexAccountActions.swift`](Sources/CodexUsageWidget/Services/CodexAccountActions.swift#L850)。 |
| [Hazmat wrapper 脚本](https://github.com/dredozubov/hazmat/blob/c112d222bb53e888dd17a8927927286792f7c20e/scripts/check-codex-desktop-attach-smoke.sh) | 协议适配与静态研究参考：仅参考 `CODEX_CLI_PATH` 的 stdio wrapper 入口，未集成 Hazmat 沙箱或服务。 |
| [BlackHole1/aswap v1.1.0](https://github.com/BlackHole1/aswap/releases/tag/v1.1.0) | X 帖子对应的 Claude 多账号 CLI/Chrome 资料隔离工具；协议适配与静态研究参考，未复制、未打包，也未接入 Codex、Feishu 或企业微信。 |

AiGoodBro 使用 [MIT 许可证](LICENSE)。第三方完整许可和版权文本见 [`Resources/THIRD_PARTY_NOTICES.txt`](Resources/THIRD_PARTY_NOTICES.txt)、[`Companion/LocalProxy/LICENSE.CLIProxyAPI`](Companion/LocalProxy/LICENSE.CLIProxyAPI)、[`Companion/LocalProxy/LICENSE.Hazmat`](Companion/LocalProxy/LICENSE.Hazmat) 与 [`Companion/LocalProxy/THIRD-PARTY-NOTICES.txt`](Companion/LocalProxy/THIRD-PARTY-NOTICES.txt)。

**文档入口**

[详细使用说明](docs/usage-guide.md) · [本机 CLI 额度范围](docs/local-cli-accounts.md) · [反代实现与验证记录](docs/local-proxy-0928v1.md) · [2.4 发布记录](docs/release-notes-v2.4.0.md) · [历史 130 发布记录](docs/release-notes-v9.6.80.md) · [最新截图来源与校验值](docs/public-ui-1009v2.md) · [问题反馈](https://github.com/BLACKIELF/AgentHub-AiGoodBro/issues) · [安全说明](SECURITY.md)

[MIT 许可证](LICENSE) · [第三方声明](Resources/THIRD_PARTY_NOTICES.txt) · [品牌兼容表](docs/brand-compat-0911v1.md)
