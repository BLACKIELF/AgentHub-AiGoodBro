# AiGoodBro · AgentHub（2.0候选）

**看清额度、用量和任务占用；需要时，让本机任务使用自己的 Codex 账号池。**

AiGoodBro 是面向个人自用的 macOS AI 工作台，汇总 Codex 多账号额度、Token 用量、本机 CLI 和公开重置消息，并提供可选的本地反代。界面支持中文和英文，主页名为 AgentHub。

**中文** | [English](README.en.md)

当前源码候选为 **9.6.63 (113) · 1002v2**。下图由新版应用的原生界面使用模拟数据生成，展示当前布局；[完整图册](docs/images/1002v2/README.md)包含首页、账号、反代、设置、引导、用量浮层与九套主题。历史实机截图保留在各自版本目录。

## 一眼看懂工作状态

首页查看各账号剩余额度、重置时间和任务占用；公开重置消息与账号实际额度分开显示。用量统计汇总 Token、模型和工具活动，费用是本机数据估算，不是供应商账单。

![AgentHub 首页，9.6.63 (113)，原生模拟数据预览](docs/images/1002v2/home/compact-zh.png)

*紧凑首页支持分区缩放、卡片与列表切换，重置消息两列共用可用宽度，并保存用户调整的比例。*

Codex 独立 CLI 可使用各自的本机登录目录；其他工具按提供商能力读取。账号卡片和列表可以刷新额度、调整顺序、选择模型或启动独立 CLI。可读取范围与限制见[账号与额度说明](docs/local-cli-accounts.md)。

![Codex 账号卡片，9.6.63 (113)，原生模拟数据预览](docs/images/1002v2/accounts/cards-zh-dark.png)

*Codex 账号卡片。*

工作台会显示已连接工具的额度与状态，读取范围随工具和登录状态而异。ZCode 是桌面工具，不是 CLI；WorkBuddy 桌面额度目前不可读。Kimi CLI 页面显示上次快照，使用前请刷新确认。

![工具工作台与多提供商状态，9.6.63 (113)，原生模拟数据预览](docs/images/1002v2/workspace/providers-zh-dark.png)

*工具状态、额度和调用入口按提供商能力展示；无法读取的额度保留明确提示。*

![项目工作台，9.6.63 (113)，原生模拟数据预览](docs/images/1002v2/workbench/workbench-900-dark.png)

*执行状态与成果状态分开显示，保留剩余事项和原聊天入口。*

## 使用引导：连接官方工具和账号

按引导登录官方工具或账号，再回到工作台查看连接状态；需要哪个工具时，再按需连接。

![连接官方工具与账号的引导页，9.6.63 (113)，原生模拟数据预览](docs/images/1002v2/setup/zh-dark-step1.png)

## 本机反代：把请求交给自己的账号池

本地反代是可选的个人工具。兼容客户端把模型请求发到本机代理，再由 AiGoodBro 按参与状态、优先级和保存顺序选择本人已连接的账号。全部参与账号的可用订阅额度先于点数使用；当前 Desktop 账号在每个额度阶段最后尝试。

点数接续默认关闭；只有用户主动开启后，订阅额度用尽才会进入点数档。忙碌或未知状态不算额度用尽；点数底线用于请求间的账号轮换，不是单次请求的硬限额。

反代只转发推理请求。Codex Desktop 保留自己的 OpenAI 登录身份、每段对话的模型和推理强度；使用代理不改系统认证文件或全局配置。未退出并重新接入的现有 Codex 进程不会自动改走代理。

![本机反代控制面板，9.6.63 (113)，原生模拟数据预览](docs/images/1002v2/proxy/zh-dark-830.png)

*模拟预览展示账号队列、额度和点数底线。独立窗口使用连续的圆角玻璃背景，透明标题栏移除顶部黑色分隔线；标题栏实机效果待正常重开窗口后验收。*

**自己开启与停止：**

1. 在 AiGoodBro 中手动开启反代；应用重启后不会自动启动它。
2. 先退出 Codex。反代成功启动且连接信息就绪后，“接入桌面”按钮才会出现；点击后重新启动 Codex 并使用本机路由。
3. 工作完成后，在反代面板停用服务。关闭主窗口只会隐藏窗口；退出应用前会确认是否停止反代。停用后正常重新打开 Codex。

已开始输出的流式响应不会切换到另一个账号重放；请求结果不明时也不会自动再次发送，避免重复执行任务。反代开关和“接入桌面”入口已在候选界面中，但界面存在不等于真实端到端验收完成。

反代为个人自用场景设计，用于自己的账号和本机任务；本项目不提供账号、凭据共享、额度转售或公共代理服务。

个人微信通过腾讯官方 iLink 扫码连接，同一入口接收重置通知、查询缓存状态，并在明确开启后继续选定的 Codex 原聊天。项目工作台区分执行状态与成果状态，保留手动暂缓、取消、完成及剩余事项。普通展示不调用模型；手机收件与真实对话仍待验收。详见[微信与项目工作台](docs/wechat-workbench-0930v1.md)。

## 九套主题与原生玻璃

在设置的“外观”中选择配色，分别支持浅色和深色。默认灰保留原有中性界面；其他主题用统一的原生玻璃、颜色和渐变呈现，玻璃透明度与深度可调，系统“减少透明度”和“增强对比度”优先。

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

![WAICY 流彩深色主题，原生模拟数据预览](docs/images/1002v2/themes/codexu.waicy-dark.png)

[查看九套主题的浅色与深色预览](docs/images/1002v2/README.md#themes)。主题仅提供色值；WAICY 主题没有复制品牌图形、工牌、吉祥物或字体，也不表示官方背书。

## 当前候选与验收边界

当前源码是 **AiGoodBro 9.6.63 (113) · 1002v2 源码候选**，位于 [`codex/reset-messages-0926v1`](https://github.com/BLACKIELF/AgentHub-AiGoodBro/tree/codex/reset-messages-0926v1)，由 [PR #13](https://github.com/BLACKIELF/AgentHub-AiGoodBro/pull/13) 评审。它仍是候选，尚未合并到 `main`，没有正式下载包。

[![候选分支 CI](https://github.com/BLACKIELF/AgentHub-AiGoodBro/actions/workflows/ci.yml/badge.svg?branch=codex%2Freset-messages-0926v1)](https://github.com/BLACKIELF/AgentHub-AiGoodBro/pull/13/checks)

本机当前安装为 **9.6.62 (112) · 1002v1**。113 候选完成优化构建、源码及资源核对、严格签名、35 组整包自测、Swift 格式检查与模拟桌面协议回归。主页、设置、引导、登录、用量浮层和主题图片由候选原生组件离屏生成，使用模拟数据，不代表真实账号或模型请求。本次没有重启正在运行的反代，也没有用真实模型请求验证新窗口边缘。个人微信手机收件、原聊天真实对话、自动暂停后切号续做、真实生图与新标题栏实机效果仍待验收。详细来源和边界见[当前源码发布记录](docs/source-publication-1002v2.md)；远端 CI 以 [PR #13 检查页](https://github.com/BLACKIELF/AgentHub-AiGoodBro/pull/13/checks)为准。

构建 2.0 候选：

```sh
git clone --branch codex/reset-messages-0926v1 https://github.com/BLACKIELF/AgentHub-AiGoodBro.git AiGoodBro-2.0
cd AiGoodBro-2.0
make build
```

源码构建要求 macOS、Go 1.26+ 和经校验的 Token Monitor v0.62.0 macOS 运行时，详见[构建与发布记录](docs/source-publication-1002v2.md)。当前没有可下载的 2.0 安装包；Windows 后续工作仍搁置。

## 借鉴项目、代码来源与许可证

功能设计借鉴了相关开源项目；实际直接复用或适配的代码与资源在下表列明，并保留对应许可证和版权声明。

| 项目 | 来源关系 |
|---|---|
| [Tencent/openclaw-weixin 2.4.9](https://github.com/Tencent/openclaw-weixin/tree/24de5c9eb0dd5e595d7e2d090ed8a3f82870d42c) | iLink 协议与扫码流程的原生适配；MIT 声明保留，不安装 OpenClaw。 |
| [codexU](https://github.com/shanggqm/codexU) | 历史 SwiftUI、额度、配色和 Windows 基础直接承接。 |
| [Token Monitor v0.62.0](https://github.com/Javis603/token-monitor/tree/dcccfb01557e2786888fd5479552f392ac6c0d32) | 统计引擎、桌面看板、图表和资源直接复用并适配宿主。 |
| [Tokscale fork](https://github.com/Javis603/tokscale) · [原项目](https://github.com/junhoyeo/tokscale) | 统计采集基础；打包修订为 `06a9f1625d5a505f01b39eff29f7be44a2c52188`，见 [`SOURCE.json`](Companion/TokenMonitorEngine/SOURCE.json)。 |
| [CLIProxyAPI v8.0.2](https://github.com/router-for-me/CLIProxyAPI/tree/v8.0.2) | SDK 调度、Codex 执行器和 Responses 处理器直接复用。 |
| [Codex-Manager](https://github.com/qxcnm/Codex-Manager) | 暖号请求结构与 SSE 完成规则的实现适配，见 [`CodexAccountActions.swift`](Sources/CodexUsageWidget/Services/CodexAccountActions.swift#L850)。 |
| [Hazmat wrapper 脚本](https://github.com/dredozubov/hazmat/blob/c112d222bb53e888dd17a8927927286792f7c20e/scripts/check-codex-desktop-attach-smoke.sh) | 参考 `CODEX_CLI_PATH` 的 stdio wrapper 入口；未集成 Hazmat 沙箱或服务。 |

AiGoodBro 使用 [MIT 许可证](LICENSE)。第三方完整许可和版权文本见 [`Resources/THIRD_PARTY_NOTICES.txt`](Resources/THIRD_PARTY_NOTICES.txt)、[`Companion/LocalProxy/LICENSE.CLIProxyAPI`](Companion/LocalProxy/LICENSE.CLIProxyAPI)、[`Companion/LocalProxy/LICENSE.Hazmat`](Companion/LocalProxy/LICENSE.Hazmat) 与 [`Companion/LocalProxy/THIRD-PARTY-NOTICES.txt`](Companion/LocalProxy/THIRD-PARTY-NOTICES.txt)。

## 延伸阅读

[详细使用说明](docs/usage-guide.md) · [本机 CLI 额度范围](docs/local-cli-accounts.md) · [反代实现与验证记录](docs/local-proxy-0928v1.md) · [当前源码发布记录](docs/source-publication-1002v2.md) · [历史实机截图：0929v2](docs/images/0929v2/README.md) · [历史截图：0927v6](docs/images/0927v6/README.md) · [历史截图：0910v1](docs/images/0910v1/README.md) · [问题反馈](https://github.com/BLACKIELF/AgentHub-AiGoodBro/issues) · [安全说明](SECURITY.md)

[MIT 许可证](LICENSE) · [第三方声明](Resources/THIRD_PARTY_NOTICES.txt) · [品牌兼容表](docs/brand-compat-0911v1.md)
